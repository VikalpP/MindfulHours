import Foundation

/// Which provider a person lands on, and how settings from earlier versions carry over.
/// Someone "chose a provider" when the provider key is persisted: the Settings picker writes it, registered defaults don't.
/// Every migration here must run before defaults are registered, so `object(forKey:)` sees only persisted values.
public enum ProviderSelection {
    public static let providerKey = "aiProvider"
    public static let customBaseURLKey = "customBaseURL"
    /// Read once at launch and moved to the Keychain.
    public static let customAPIKeyHandoffKey = "customAPIKey"

    public static func modelKey(for provider: AIProvider) -> String { "model.\(provider.rawValue)" }

    /// Apple Intelligence wherever this Mac can ever run it; otherwise ChatGPT, the default before it.
    public static func defaultProvider(onDevice availability: OnDeviceAvailability) -> AIProvider {
        switch availability {
        case .unavailable(.requiresNewerMacOS), .unavailable(.notInThisBuild), .unavailable(.deviceNotEligible): .chatGPT
        default: .appleIntelligence
        }
    }

    /// v0.1.0 pointed at a CLIProxyAPI-style endpoint; those settings become the Custom provider.
    /// v0.1.0 persisted only the values the user changed, so missing ones take its defaults.
    public static func migrateLegacyProxySettings(in defaults: UserDefaults) {
        let legacyKeys = ["proxyBaseURL", "model", "proxyAPIKey"]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        defaults.set(AIProvider.custom.rawValue, forKey: providerKey)
        defaults.set(defaults.string(forKey: "proxyBaseURL") ?? "http://127.0.0.1:8317/v1", forKey: customBaseURLKey)
        defaults.set(defaults.string(forKey: "model") ?? "claude-haiku-5-5", forKey: modelKey(for: .custom))
        if let key = defaults.string(forKey: "proxyAPIKey"), !key.isEmpty { defaults.set(key, forKey: customAPIKeyHandoffKey) }
        for key in legacyKeys { defaults.removeObject(forKey: key) }
    }

    /// ChatGPT was the unpersisted default before Apple Intelligence; anyone already using it keeps it.
    /// A ChatGPT model is only chosen after signing in, so either signal means it was in use.
    public static func keepChatGPTIfInUse(in defaults: UserDefaults, hasChatGPTSession: Bool) {
        guard defaults.object(forKey: providerKey) == nil,
              hasChatGPTSession || defaults.object(forKey: modelKey(for: .chatGPT)) != nil else { return }
        defaults.set(AIProvider.chatGPT.rawValue, forKey: providerKey)
    }
}
