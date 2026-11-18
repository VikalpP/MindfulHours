import Foundation

/// Which provider a person lands on: the one they picked in Settings, otherwise the default for this Mac.
public enum ProviderSelection {
    public static let providerKey = "aiProvider"

    public static func provider(in defaults: UserDefaults, onDevice availability: OnDeviceAvailability) -> AIProvider {
        defaults.string(forKey: providerKey).flatMap(AIProvider.init(rawValue:)) ?? defaultProvider(onDevice: availability)
    }

    /// Apple Intelligence wherever this Mac can ever run it; otherwise ChatGPT.
    public static func defaultProvider(onDevice availability: OnDeviceAvailability) -> AIProvider {
        switch availability {
        case .unavailable(.requiresNewerMacOS), .unavailable(.notInThisBuild), .unavailable(.deviceNotEligible): .chatGPT
        default: .appleIntelligence
        }
    }
}
