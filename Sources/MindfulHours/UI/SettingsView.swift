import SwiftUI
import MindfulHoursCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsKey.aiEnabled) private var aiEnabled = SettingsDefault.aiEnabled
    @AppStorage(SettingsKey.screenshotsEnabled) private var screenshotsEnabled = SettingsDefault.screenshotsEnabled
    @AppStorage(SettingsKey.proxyBaseURL) private var proxyBaseURL = SettingsDefault.proxyBaseURL
    @AppStorage(SettingsKey.proxyAPIKey) private var proxyAPIKey = ""
    @AppStorage(SettingsKey.model) private var modelName = SettingsDefault.model
    @AppStorage(SettingsKey.idleThresholdSeconds) private var idleThresholdSeconds = SettingsDefault.idleThresholdSeconds
    @AppStorage(SettingsKey.excludedBundleIDs) private var excludedBundleIDs = SettingsDefault.excludedBundleIDs
    @AppStorage(SettingsKey.blockedURLPatterns) private var blockedURLPatterns = SettingsDefault.blockedURLPatterns
    @AppStorage(SettingsKey.sensitiveTitleKeywords) private var sensitiveTitleKeywords = SettingsDefault.sensitiveTitleKeywords
    @AppStorage(SettingsKey.protectsPrivateWindows) private var protectsPrivateWindows = SettingsDefault.protectsPrivateWindows
    @AppStorage(SettingsKey.scansScreenshotText) private var scansScreenshotText = SettingsDefault.scansScreenshotText

    @State private var availableModels: [String] = []
    @State private var connectionResult: Result<String, Error>?
    @State private var isTesting = false
    @State private var isConfirmingDelete = false
    @State private var privacyEvents: [PrivacyEvent] = []

    var body: some View {
        Form {
            Section("AI analysis") {
                Toggle("Describe each minute with AI", isOn: $aiEnabled)
                Toggle("Include a screenshot of the focused window", isOn: $screenshotsEnabled)
                    .disabled(!aiEnabled)
                Text("Screenshots are sent to the model and never written to disk. Without them the model only sees app, window title and URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Base URL", text: $proxyBaseURL)
                SecureField("API key", text: $proxyAPIKey)
                HStack {
                    TextField("Model", text: $modelName)
                    if !availableModels.isEmpty {
                        Menu("Choose") {
                            ForEach(availableModels, id: \.self) { name in Button(name) { modelName = name } }
                        }
                        .fixedSize()
                    }
                }
                HStack {
                    Button("Test Connection") { testConnection() }.disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    connectionStatus
                }
            } header: {
                Text("Model provider (OpenAI-compatible, e.g. CLIProxyAPI)")
            } footer: {
                Text("Run scripts/setup-proxy.sh to install CLIProxyAPI and sign in with your Claude subscription.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Tracking") {
                Stepper(value: $idleThresholdSeconds, in: 60...1800, step: 60) {
                    Text("Away after \(Int(idleThresholdSeconds / 60)) min without input")
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchesAtLogin = $0 }))
            }

            Section {
                Toggle("Treat private/incognito browser windows as protected", isOn: $protectsPrivateWindows)
                Toggle("Scan screenshots on-device for card numbers, keys and codes", isOn: $scansScreenshotText)
                ruleEditor("Never analyze these apps (bundle IDs)", text: $excludedBundleIDs)
                ruleEditor("Sensitive addresses (URL prefixes like chrome://password-manager, or domains like bank.com)", text: $blockedURLPatterns)
                ruleEditor("Sensitive window-title words (whole-word match)", text: $sensitiveTitleKeywords)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Screenshots are always skipped while a password field is focused or the window blocks capture. Matching an app, address or title word also hides the title and URL; other protections keep them and only skip the screenshot.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Skipped screenshots") {
                if privacyEvents.isEmpty {
                    Text("Nothing skipped yet.").foregroundStyle(.secondary)
                }
                ForEach(privacyEvents) { event in
                    HStack(alignment: .firstTextBaseline) {
                        AppIconView(bundleID: event.bundleID, size: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(event.appName): \(event.reasons.map(\.label).joined(separator: ", "))")
                            if let detail = event.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Section("Permissions") {
                permissionRow("Accessibility", granted: model.permissions.accessibility, pane: "Privacy_Accessibility")
                permissionRow("Screen Recording", granted: model.permissions.screenRecording, pane: "Privacy_ScreenCapture")
            }

            Section("Data") {
                HStack {
                    Button("Show Database in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ActivityStore.defaultURL])
                    }
                    Spacer()
                    Button("Delete All Data…", role: .destructive) { isConfirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermissions() }
        .task { privacyEvents = (try? await model.store.latestPrivacyEvents(limit: 15)) ?? [] }
        .confirmationDialog("Delete all recorded activity?", isPresented: $isConfirmingDelete) {
            Button("Delete Everything", role: .destructive) {
                Task { try? await model.store.deleteAll() }
            }
        } message: {
            Text("This permanently removes every span, minute insight, day summary and privacy log entry.")
        }
    }

    private func ruleEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 80)
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch connectionResult {
        case .success(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let error): Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        case nil: EmptyView()
        }
    }

    private func permissionRow(_ name: String, granted: Bool, pane: String) -> some View {
        HStack {
            Label(name, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            if !granted { Button("Open Settings") { model.openPrivacySettings(pane) } }
        }
    }

    private func testConnection() {
        guard let llm = AppSettings.load().llm else {
            connectionResult = .failure(LLMError.notConfigured)
            return
        }
        isTesting = true
        connectionResult = nil
        Task {
            defer { isTesting = false }
            do {
                let client = LLMClient(configuration: llm)
                availableModels = (try? await client.availableModels()) ?? []
                let reply = try await client.complete(system: "Reply with exactly: ok", user: "ping", maxTokens: 64, reasoningEffort: "none")
                connectionResult = .success("\(llm.model) replied “\(reply.prefix(20))”")
            } catch {
                connectionResult = .failure(error)
            }
        }
    }
}
