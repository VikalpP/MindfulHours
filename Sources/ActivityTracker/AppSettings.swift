import Foundation
import ActivityTrackerCore

enum SettingsKey {
    static let aiEnabled = "aiEnabled"
    static let screenshotsEnabled = "screenshotsEnabled"
    static let proxyBaseURL = "proxyBaseURL"
    static let proxyAPIKey = "proxyAPIKey"
    static let model = "model"
    static let idleThresholdSeconds = "idleThresholdSeconds"
    static let excludedBundleIDs = "excludedBundleIDs"
}

enum SettingsDefault {
    static let aiEnabled = true
    static let screenshotsEnabled = true
    static let proxyBaseURL = "http://127.0.0.1:8317/v1"
    static let model = "claude-haiku-5-5"
    static let idleThresholdSeconds = 180.0
    static let excludedBundleIDs = """
        com.1password.1password
        com.agilebits.onepassword7
        com.apple.keychainaccess
        com.apple.Passwords
        com.bitwarden.desktop
        """
}

struct AppSettings: Sendable {
    var aiEnabled: Bool
    var screenshotsEnabled: Bool
    var llm: LLMConfiguration?
    var idleThreshold: TimeInterval
    var excludedBundleIDs: Set<String>

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKey.aiEnabled: SettingsDefault.aiEnabled,
            SettingsKey.screenshotsEnabled: SettingsDefault.screenshotsEnabled,
            SettingsKey.proxyBaseURL: SettingsDefault.proxyBaseURL,
            SettingsKey.model: SettingsDefault.model,
            SettingsKey.idleThresholdSeconds: SettingsDefault.idleThresholdSeconds,
            SettingsKey.excludedBundleIDs: SettingsDefault.excludedBundleIDs,
        ])
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        let baseURL = defaults.string(forKey: SettingsKey.proxyBaseURL).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        let model = defaults.string(forKey: SettingsKey.model)?.trimmingCharacters(in: .whitespaces) ?? ""
        let llm = baseURL.flatMap { url in
            model.isEmpty ? nil : LLMConfiguration(baseURL: url, apiKey: defaults.string(forKey: SettingsKey.proxyAPIKey) ?? "", model: model)
        }

        return AppSettings(
            aiEnabled: defaults.bool(forKey: SettingsKey.aiEnabled),
            screenshotsEnabled: defaults.bool(forKey: SettingsKey.screenshotsEnabled),
            llm: llm,
            idleThreshold: defaults.double(forKey: SettingsKey.idleThresholdSeconds),
            excludedBundleIDs: Set(
                (defaults.string(forKey: SettingsKey.excludedBundleIDs) ?? "")
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        )
    }
}
