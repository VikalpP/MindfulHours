import Foundation
import MindfulHoursCore

enum SettingsKey {
    static let aiEnabled = "aiEnabled"
    static let screenshotsEnabled = "screenshotsEnabled"
    static let proxyBaseURL = "proxyBaseURL"
    static let proxyAPIKey = "proxyAPIKey"
    static let model = "model"
    static let idleThresholdSeconds = "idleThresholdSeconds"
    static let sampleIntervalSeconds = "sampleIntervalSeconds"
    static let screenshotIntervalSeconds = "screenshotIntervalSeconds"
    static let excludedBundleIDs = "excludedBundleIDs"
    static let blockedURLPatterns = "blockedURLPatterns"
    static let sensitiveTitleKeywords = "sensitiveTitleKeywords"
    static let protectsPrivateWindows = "protectsPrivateWindows"
    static let scansScreenshotText = "scansScreenshotText"
}

enum SettingsDefault {
    static let aiEnabled = true
    static let screenshotsEnabled = true
    static let proxyBaseURL = "http://127.0.0.1:8317/v1"
    static let model = "claude-haiku-5-5"
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
    var llm: LLMConfiguration?
    var idleThreshold: TimeInterval
    var sampleInterval: TimeInterval
    /// Never shorter than the sample interval, since captures happen on activity checks.
    var screenshotInterval: TimeInterval
    var privacy: PrivacyRules
    var scansScreenshotText: Bool

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKey.aiEnabled: SettingsDefault.aiEnabled,
            SettingsKey.screenshotsEnabled: SettingsDefault.screenshotsEnabled,
            SettingsKey.proxyBaseURL: SettingsDefault.proxyBaseURL,
            SettingsKey.model: SettingsDefault.model,
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
        let baseURL = defaults.string(forKey: SettingsKey.proxyBaseURL).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        let model = defaults.string(forKey: SettingsKey.model)?.trimmingCharacters(in: .whitespaces) ?? ""
        let llm = baseURL.flatMap { url in
            model.isEmpty ? nil : LLMConfiguration(baseURL: url, apiKey: defaults.string(forKey: SettingsKey.proxyAPIKey) ?? "", model: model)
        }

        let sampleInterval = min(max(defaults.double(forKey: SettingsKey.sampleIntervalSeconds), 1), 60)
        return AppSettings(
            aiEnabled: defaults.bool(forKey: SettingsKey.aiEnabled),
            screenshotsEnabled: defaults.bool(forKey: SettingsKey.screenshotsEnabled),
            llm: llm,
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
}
