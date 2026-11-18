import SwiftUI
import MindfulHoursCore

struct AIProviderSection: View {
    @ObservedObject var accounts: ProviderAccounts
    @AppStorage(SettingsKey.aiProvider) private var provider = SettingsDefault.aiProvider
    @AppStorage(SettingsKey.customBaseURL) private var customBaseURL = ""
    @State private var connectionResult: Result<String, Error>?
    @State private var isTesting = false

    var body: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.pickerLabel).tag($0) }
            }
            access
            ModelField(provider: provider, accounts: accounts, customBaseURL: parsedCustomBaseURL)
                .id(provider)
            HStack {
                Button("Test Connection") { testConnection() }.disabled(isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                connectionStatus
            }
        } header: {
            Text("AI provider")
        } footer: {
            Text(LocalizedStringKey("\(provider.settingsNote) Screenshots need a model that accepts images."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: provider) { connectionResult = nil }
    }

    @ViewBuilder private var access: some View {
        switch provider.access {
        case .signIn:
            if let account = accounts.account(for: provider) {
                LabeledContent("Signed in") {
                    HStack {
                        Text(account)
                        Button("Sign Out") { accounts.signOut(of: provider) }
                    }
                }
            } else if accounts.signingIn == provider {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { accounts.cancelSignIn() }
                }
            } else {
                Button("Sign in with \(provider.displayName)…") { accounts.signIn(to: provider) }
            }
            if let error = accounts.signInError, error.provider == provider {
                Label(error.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        case .apiKey(let getKeyURL):
            SecureField("API key", text: apiKey(for: provider))
            Link("Get a \(provider.displayName) API key", destination: getKeyURL).font(.callout)
        case .localServer:
            EmptyView()
        case .customEndpoint:
            TextField("Base URL", text: $customBaseURL, prompt: Text("http://127.0.0.1:8317/v1"))
            SecureField("API key", text: apiKey(for: .custom), prompt: Text("Optional"))
        }
    }

    private var parsedCustomBaseURL: URL? {
        let trimmed = customBaseURL.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    private func apiKey(for provider: AIProvider) -> Binding<String> {
        Binding(get: { accounts.apiKey(for: provider) }, set: { accounts.setAPIKey($0, for: provider) })
    }

    @ViewBuilder private var connectionStatus: some View {
        switch connectionResult {
        case .success(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let error): Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        case nil: EmptyView()
        }
    }

    private func testConnection() {
        isTesting = true
        connectionResult = nil
        Task {
            defer { isTesting = false }
            do {
                let llm = try await accounts.configuration(for: AppSettings.load())
                let reply = try await LLMClient(configuration: llm).complete(system: "Reply with exactly: ok", user: "ping", maxTokens: 64, reasoningEffort: "none")
                connectionResult = .success("\(llm.model) replied “\(reply.prefix(20))”")
            } catch {
                connectionResult = .failure(error)
            }
        }
    }
}

/// The model for one provider, remembered separately per provider, with the provider's list of models to choose from.
private struct ModelField: View {
    let provider: AIProvider
    @ObservedObject var accounts: ProviderAccounts
    let customBaseURL: URL?
    @AppStorage private var model: String
    @State private var models: [String]?
    @State private var loadError: String?

    init(provider: AIProvider, accounts: ProviderAccounts, customBaseURL: URL?) {
        self.provider = provider
        self.accounts = accounts
        self.customBaseURL = customBaseURL
        _model = AppStorage(wrappedValue: provider.defaultModel, SettingsKey.model(for: provider))
    }

    var body: some View {
        HStack {
            TextField("Model", text: $model)
            if let models, !models.isEmpty {
                Menu("Choose") {
                    ForEach(models, id: \.self) { name in Button(name) { model = name } }
                }
                .fixedSize()
            }
        }
        .task(id: accounts.accessIdentity(for: provider, customBaseURL: customBaseURL)) { await loadModels() }

        if case .localServer(let downloadURL) = provider.access {
            localServerStatus(downloadURL: downloadURL)
        } else if let loadError {
            Text("Couldn't list models: \(loadError)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder private func localServerStatus(downloadURL: URL) -> some View {
        if loadError != nil {
            HStack {
                Text("\(provider.displayName) isn't running on this Mac.").foregroundStyle(.secondary)
                Link("Get \(provider.displayName)", destination: downloadURL)
                Spacer()
                Button("Check Again") { Task { await loadModels() } }
            }
            .font(.callout)
        } else if let models {
            Text(models.isEmpty ? "\(provider.displayName) is running but has no models yet." : "\(provider.displayName) is running with \(models.count) model\(models.count == 1 ? "" : "s").")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadModels() async {
        // Waits out typing in the API key field, which restarts this task on every keystroke.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        guard accounts.canConnect(to: provider, customBaseURL: customBaseURL) else {
            models = nil
            loadError = nil
            return
        }
        do {
            let connection = try await accounts.connection(to: provider, customBaseURL: customBaseURL)
            let available = try await LLMClient(configuration: connection).availableModels()
            guard !Task.isCancelled else { return }
            models = available
            loadError = nil
            if model.isEmpty, let preferred = provider.preferredModel(from: available) { model = preferred }
        } catch {
            guard !Task.isCancelled else { return }
            models = nil
            loadError = error.localizedDescription
        }
    }
}

private extension AIProvider {
    var pickerLabel: String {
        switch self {
        case .chatGPT: "ChatGPT — sign in with your plan"
        case .openRouter: "OpenRouter — sign in"
        case .claude, .openAI, .gemini: "\(displayName) — API key"
        case .ollama, .lmStudio: "\(displayName) — on this Mac"
        case .custom: "Custom OpenAI-compatible endpoint"
        }
    }

    var settingsNote: String {
        switch self {
        case .chatGPT: "Requests count toward your ChatGPT plan's usage; no API key needed."
        case .claude: "Billed per request to your Claude Console account. Claude subscriptions can't be used by other apps."
        case .openAI: "Billed per request to your OpenAI platform account; a ChatGPT subscription doesn't cover it."
        case .openRouter: "Signing in creates an OpenRouter key for MindfulHours, which you can limit or revoke on openrouter.ai."
        case .gemini: "Uses a Google AI Studio API key."
        case .ollama: "Runs entirely on this Mac. For screenshots, pull a vision model, e.g. `ollama pull gemma3`."
        case .lmStudio: "Runs entirely on this Mac. Start the server in LM Studio's Developer tab and load a vision model."
        case .custom: "Any OpenAI-compatible endpoint, such as a self-hosted gateway or CLIProxyAPI (scripts/setup-proxy.sh)."
        }
    }
}
