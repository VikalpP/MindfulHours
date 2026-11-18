import AppKit
import MindfulHoursCore

/// API keys and sign-ins for every provider, kept as one Keychain item so an updated (re-signed) build asks for access once.
@MainActor
final class ProviderAccounts: ObservableObject {
    private struct Credentials: Codable {
        var apiKeys: [String: String] = [:]
        var chatGPT: ChatGPTSession?
    }

    private static let keychainAccount = "provider-credentials"

    @Published private var credentials: Credentials
    /// False when the stored item exists but couldn't be read; saving would then overwrite every other credential.
    private let canSave: Bool
    @Published private(set) var signingIn: AIProvider?
    @Published private(set) var signInError: (provider: AIProvider, message: String)?
    private var signInTask: Task<Void, Never>?
    private var chatGPTRefresh: Task<ChatGPTSession, Error>?

    init() {
        do {
            let stored = try Keychain.read(account: Self.keychainAccount)
            credentials = stored.flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) } ?? Credentials()
            canSave = true
        } catch {
            credentials = Credentials()
            canSave = false
        }
    }

    func apiKey(for provider: AIProvider) -> String {
        credentials.apiKeys[provider.rawValue] ?? ""
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.apiKeys[provider.rawValue] = key.isEmpty ? nil : key
        save()
    }

    /// The signed-in account's name, or nil when signed out.
    func account(for provider: AIProvider) -> String? {
        switch provider {
        case .chatGPT: credentials.chatGPT.map { $0.email ?? "ChatGPT account" }
        case .openRouter: apiKey(for: .openRouter).isEmpty ? nil : "OpenRouter key for MindfulHours"
        default: nil
        }
    }

    /// Changes whenever the credentials that reach `provider` change, so model lists know to reload.
    func accessIdentity(for provider: AIProvider, customBaseURL: URL?) -> String {
        switch provider.access {
        case .onDevice: provider.rawValue
        case .signIn: account(for: provider) ?? ""
        case .apiKey: apiKey(for: provider)
        case .localServer: provider.rawValue
        case .customEndpoint: "\(customBaseURL?.absoluteString ?? "") \(apiKey(for: .custom))"
        }
    }

    func canConnect(to provider: AIProvider, customBaseURL: URL?) -> Bool {
        switch provider.access {
        case .onDevice: AppleIntelligence.availability.isAvailable
        case .signIn: account(for: provider) != nil
        case .apiKey: !apiKey(for: provider).isEmpty
        case .localServer: true
        case .customEndpoint: customBaseURL != nil
        }
    }

    func isReady(_ settings: AppSettings) -> Bool {
        if settings.provider.isOnDevice {
            return AppleIntelligence.availability.isAvailable || settings.onDeviceBackupSettings.map(isReady) == true
        }
        return !settings.model.isEmpty && canConnect(to: settings.provider, customBaseURL: settings.customBaseURL)
    }

    /// For providers reached over HTTP; the on-device model has no configuration.
    func configuration(for settings: AppSettings) async throws -> LLMConfiguration {
        guard !settings.provider.isOnDevice, isReady(settings) else { throw LLMError.notConfigured }
        return try await connection(to: settings.provider, model: settings.model, customBaseURL: settings.customBaseURL)
    }

    /// Like `configuration(for:)` but without requiring a model, for listing the models to choose from.
    func connection(to provider: AIProvider, model: String = "", customBaseURL: URL?) async throws -> LLMConfiguration {
        guard canConnect(to: provider, customBaseURL: customBaseURL), let baseURL = provider.baseURL ?? customBaseURL else {
            throw LLMError.notConfigured
        }
        let key = provider == .chatGPT ? try await freshChatGPTSession().accessToken : apiKey(for: provider)
        return LLMConfiguration(baseURL: baseURL, apiKey: key, model: model, dialect: provider.dialect)
    }

    func signIn(to provider: AIProvider) {
        signInTask?.cancel()
        signInError = nil
        signingIn = provider
        signInTask = Task {
            do {
                switch provider {
                case .chatGPT: credentials.chatGPT = try await signInWithChatGPT()
                case .openRouter: credentials.apiKeys[provider.rawValue] = try await signInWithOpenRouter()
                default: break
                }
                save()
                NSApp.activate()
            } catch is CancellationError {
            } catch {
                signInError = (provider, error.localizedDescription)
            }
            if signingIn == provider { signingIn = nil }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signingIn = nil
    }

    func signOut(of provider: AIProvider) {
        switch provider {
        case .chatGPT:
            guard let session = credentials.chatGPT else { return }
            credentials.chatGPT = nil
            Task { try? await ChatGPTSignIn.revoke(session) }
        default:
            credentials.apiKeys[provider.rawValue] = nil
        }
        save()
    }

    private func signInWithChatGPT() async throws -> ChatGPTSession {
        let server = try await LoopbackCallbackServer.start(path: ChatGPTSignIn.callbackPath, preferredPort: ChatGPTSignIn.preferredCallbackPort)
        defer { server.stop() }
        let previous = credentials.chatGPT
        let attempt = ChatGPTSignIn.Attempt(redirectURI: server.redirectURI(), savedClientID: previous?.clientID)
        NSWorkspace.shared.open(ChatGPTSignIn.authorizationURL(for: attempt, hostID: Self.chatGPTHostID, previous: previous))
        return try await ChatGPTSignIn.exchange(callback: try await server.callback(), for: attempt)
    }

    private func signInWithOpenRouter() async throws -> String {
        let server = try await LoopbackCallbackServer.start(path: OpenRouterSignIn.callbackPath)
        defer { server.stop() }
        let pkce = PKCE()
        // OpenRouter only accepts "localhost" callbacks; browsers fall back to 127.0.0.1 when ::1 refuses.
        NSWorkspace.shared.open(OpenRouterSignIn.authorizationURL(callbackURL: server.redirectURI(host: "localhost"), pkce: pkce))
        return try await OpenRouterSignIn.exchange(callback: try await server.callback(), pkce: pkce)
    }

    private func freshChatGPTSession() async throws -> ChatGPTSession {
        guard let session = credentials.chatGPT else { throw LLMError.notConfigured }
        guard session.needsRefresh() else { return session }
        if let chatGPTRefresh { return try await chatGPTRefresh.value }

        let refresh = Task { try await ChatGPTSignIn.refreshed(session) }
        chatGPTRefresh = refresh
        defer { chatGPTRefresh = nil }
        do {
            let refreshed = try await refresh.value
            if credentials.chatGPT?.clientID == session.clientID {
                credentials.chatGPT = refreshed
                save()
            }
            return refreshed
        } catch SignInError.http(let status, _) where [400, 401].contains(status) {
            if credentials.chatGPT == session {
                credentials.chatGPT = nil
                save()
            }
            throw LLMError.failed("ChatGPT sign-in expired; sign in again in Settings")
        }
    }

    private func save() {
        guard canSave, let data = try? JSONEncoder().encode(credentials) else { return }
        Keychain.write(data, account: Self.keychainAccount)
    }

    /// Stable per Mac, as Sign in with ChatGPT requires; not a secret.
    private static var chatGPTHostID: String {
        if let saved = UserDefaults.standard.string(forKey: SettingsKey.chatGPTHostID) { return saved }
        let hostID = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(hostID, forKey: SettingsKey.chatGPTHostID)
        return hostID
    }
}
