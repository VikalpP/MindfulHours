import Foundation
import MindfulHoursCore

enum SettingsKey {
    static let aiEnabled = "aiEnabled"
    static let screenshotsEnabled = "screenshotsEnabled"
    static let aiProvider = "aiProvider"
    static let customBaseURL = "customBaseURL"
    /// Read once at launch and moved to the Keychain; lets scripts/setup-proxy.sh hand over a key.
    static let customAPIKeyHandoff = "customAPIKey"
    static let chatGPTHostID = "chatGPTHostID"
    static let idleThresholdSeconds = "idleThresholdSeconds"
    static let sampleIntervalSeconds = "sampleIntervalSeconds"
    static let screenshotIntervalSeconds = "screenshotIntervalSeconds"
    static let excludedBundleIDs = "excludedBundleIDs"
    static let blockedURLPatterns = "blockedURLPatterns"
    static let sensitiveTitleKeywords = "sensitiveTitleKeywords"
    static let protectsPrivateWindows = "protectsPrivateWindows"
    static let scansScreenshotText = "scansScreenshotText"

    static func model(for provider: AIProvider) -> String { "model.\(provider.rawValue)" }
}

enum SettingsDefault {
    static let aiEnabled = true
    static let screenshotsEnabled = true
    static let aiProvider = AIProvider.chatGPT
    static let idleThresholdSeconds = 180.0
    static let sampleIntervalSeconds = 5.0
    static let screenshotIntervalSeconds = 25.0
    static let sampleIntervalChoices: [Double] = [2, 3, 5, 10, 15, 30]
    static let screenshotIntervalChoices: [Double] = [10, 15, 20, 25, 30, 45, 60, 90, 120]
    static let excludedBundleIDs = """
        com.1password.1password
        com.agilebits.onepassword7
        com.apple.keychainaccess
        com.apple.Passwords
        com.bitwarden.desktop
        """
    static let blockedURLPatterns = PrivacyRules.defaultBlockedURLPatterns
    static let sensitiveTitleKeywords = PrivacyRules.defaultSensitiveTitleKeywords
    static let protectsPrivateWindows = true
    static let scansScreenshotText = true
}

struct AppSettings: Sendable {
    var aiEnabled: Bool
    var screenshotsEnabled: Bool
    var provider: AIProvider
    var model: String
    var customBaseURL: URL?
    var idleThreshold: TimeInterval
    var sampleInterval: TimeInterval
    /// Never shorter than the sample interval, since captures happen on activity checks.
    var screenshotInterval: TimeInterval
    var privacy: PrivacyRules
    var scansScreenshotText: Bool

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        migrateLegacyProxySettings(in: defaults)
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { (SettingsKey.model(for: $0), $0.defaultModel) }))
        defaults.register(defaults: [
            SettingsKey.aiEnabled: SettingsDefault.aiEnabled,
            SettingsKey.screenshotsEnabled: SettingsDefault.screenshotsEnabled,
            SettingsKey.aiProvider: SettingsDefault.aiProvider.rawValue,
            SettingsKey.idleThresholdSeconds: SettingsDefault.idleThresholdSeconds,
            SettingsKey.sampleIntervalSeconds: SettingsDefault.sampleIntervalSeconds,
            SettingsKey.screenshotIntervalSeconds: SettingsDefault.screenshotIntervalSeconds,
            SettingsKey.excludedBundleIDs: SettingsDefault.excludedBundleIDs,
            SettingsKey.blockedURLPatterns: SettingsDefault.blockedURLPatterns,
            SettingsKey.sensitiveTitleKeywords: SettingsDefault.sensitiveTitleKeywords,
            SettingsKey.protectsPrivateWindows: SettingsDefault.protectsPrivateWindows,
            SettingsKey.scansScreenshotText: SettingsDefault.scansScreenshotText,
        ])
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        let provider = defaults.string(forKey: SettingsKey.aiProvider).flatMap(AIProvider.init(rawValue:)) ?? SettingsDefault.aiProvider
        let customBaseURL = defaults.string(forKey: SettingsKey.customBaseURL)?.trimmingCharacters(in: .whitespaces)
        let sampleInterval = min(max(defaults.double(forKey: SettingsKey.sampleIntervalSeconds), 1), 60)
        return AppSettings(
            aiEnabled: defaults.bool(forKey: SettingsKey.aiEnabled),
            screenshotsEnabled: defaults.bool(forKey: SettingsKey.screenshotsEnabled),
            provider: provider,
            model: defaults.string(forKey: SettingsKey.model(for: provider))?.trimmingCharacters(in: .whitespaces) ?? "",
            customBaseURL: customBaseURL.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            idleThreshold: defaults.double(forKey: SettingsKey.idleThresholdSeconds),
            sampleInterval: sampleInterval,
            screenshotInterval: max(defaults.double(forKey: SettingsKey.screenshotIntervalSeconds), sampleInterval),
            privacy: PrivacyRules(
                excludedBundleIDs: Set(PrivacyRules.lines(defaults.string(forKey: SettingsKey.excludedBundleIDs) ?? "")),
                blockedURLPatterns: PrivacyRules.lines(defaults.string(forKey: SettingsKey.blockedURLPatterns) ?? ""),
                sensitiveTitleKeywords: PrivacyRules.lines(defaults.string(forKey: SettingsKey.sensitiveTitleKeywords) ?? ""),
                protectsPrivateWindows: defaults.bool(forKey: SettingsKey.protectsPrivateWindows)
            ),
            scansScreenshotText: defaults.bool(forKey: SettingsKey.scansScreenshotText)
        )
    }

    /// Settings from before provider presets pointed at a CLIProxyAPI-style endpoint; they become the Custom provider.
    private static func migrateLegacyProxySettings(in defaults: UserDefaults) {
        guard let legacyBaseURL = defaults.string(forKey: "proxyBaseURL") else { return }
        defaults.set(AIProvider.custom.rawValue, forKey: SettingsKey.aiProvider)
        defaults.set(legacyBaseURL, forKey: SettingsKey.customBaseURL)
        if let model = defaults.string(forKey: "model") { defaults.set(model, forKey: SettingsKey.model(for: .custom)) }
        if let key = defaults.string(forKey: "proxyAPIKey") { defaults.set(key, forKey: SettingsKey.customAPIKeyHandoff) }
        for key in ["proxyBaseURL", "model", "proxyAPIKey"] { defaults.removeObject(forKey: key) }
    }
}
