import Foundation

public struct MinuteDescription: Sendable, Equatable {
    public var payload: InsightPayload
    public var model: String

    public init(payload: InsightPayload, model: String) {
        self.payload = payload
        self.model = model
    }
}

public protocol MinuteDescriber: Sendable {
    func describe(_ observation: MinuteObservation, screenshotJPEG: Data?) async throws -> MinuteDescription
}

public struct LLMMinuteDescriber: MinuteDescriber {
    public let client: LLMClient

    public init(client: LLMClient) {
        self.client = client
    }

    public func describe(_ observation: MinuteObservation, screenshotJPEG: Data?) async throws -> MinuteDescription {
        let reply = try await client.complete(
            system: Prompts.minuteSystem,
            user: Prompts.minuteUser(observation),
            imageJPEG: screenshotJPEG,
            reasoningEffort: "none"
        )
        guard let payload = Prompts.parseInsight(reply) else { throw LLMError.unparseableReply(reply) }
        return MinuteDescription(payload: payload, model: client.configuration.model)
    }
}

public enum OnDeviceAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    public enum Reason: Equatable, Sendable {
        case requiresNewerMacOS
        /// Built with an SDK that has no FoundationModels.
        case notInThisBuild
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }

    public var isAvailable: Bool { self == .available }

    public var explanation: String {
        switch self {
        case .available: "Apple Intelligence is ready on this Mac."
        case .unavailable(.requiresNewerMacOS): "Apple Intelligence needs macOS 26 or later."
        case .unavailable(.notInThisBuild): "This build of MindfulHours was made without Apple Intelligence support."
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple Intelligence (it needs Apple silicon)."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable(.unknown): "Apple Intelligence isn't available right now."
        }
    }

    public var fixHint: String? {
        switch self {
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): "Keep your Mac on power and connected to the internet; this can take a while."
        case .unavailable(.requiresNewerMacOS): "Update macOS, or choose another provider."
        case .unavailable(.notInThisBuild), .unavailable(.deviceNotEligible): "Choose another provider."
        case .available, .unavailable(.unknown): nil
        }
    }
}

public enum OnDeviceModelError: Error, LocalizedError, Equatable {
    case unavailable(OnDeviceAvailability.Reason)
    /// Rate limited, too many concurrent requests or timed out; Apple throttles background apps.
    case throttled
    /// The model's guardrails or a refusal stopped this request; other minutes may still work.
    case declined
    case contextTooLong
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): OnDeviceAvailability.unavailable(reason).explanation
        case .throttled: "Apple Intelligence is busy or limiting background requests"
        case .declined: "Apple Intelligence declined to describe this content"
        case .contextTooLong: "Too much text for Apple Intelligence's context window"
        case .failed(let message): message
        }
    }
}

/// Exponential backoff after the on-device model throttles: 1, 2, 4, 8, then 15 minutes.
public struct ThrottleBackoff: Sendable, Equatable {
    public static let initialDelay: TimeInterval = 60
    public static let maxDelay: TimeInterval = 15 * 60

    public private(set) var consecutiveThrottles = 0
    public private(set) var retryAfter = Date.distantPast

    public init() {}

    public func allowsAttempt(at now: Date) -> Bool { now >= retryAfter }

    public mutating func recordThrottle(at now: Date) {
        consecutiveThrottles += 1
        let delay = min(Self.initialDelay * pow(2, Double(consecutiveThrottles - 1)), Self.maxDelay)
        retryAfter = now.addingTimeInterval(delay)
    }

    public mutating func recordSuccess() {
        consecutiveThrottles = 0
        retryAfter = .distantPast
    }
}

public enum MinuteOutcome: Sendable, Equatable {
    case described(MinuteDescription)
    /// Nothing could describe the minute; it is recorded from metadata.
    case metadataOnly(reason: String)
}

/// Asks the on-device model first. When it is unavailable, throttled or declines, the minute goes to the
/// backup provider the person chose, or is recorded from metadata only. It never retries in a loop.
public actor OnDeviceFirstRouter {
    private var backoff = ThrottleBackoff()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    public var retryAfter: Date? {
        backoff.allowsAttempt(at: now()) ? nil : backoff.retryAfter
    }

    /// Throws only errors from the backup, or unexpected on-device errors when there is no backup.
    public func describe(
        _ observation: MinuteObservation,
        screenshotJPEG: Data?,
        onDevice: any MinuteDescriber,
        backup: (any MinuteDescriber)?
    ) async throws -> MinuteOutcome {
        let reason: String
        if backoff.allowsAttempt(at: now()) {
            do {
                let description = try await onDevice.describe(observation, screenshotJPEG: screenshotJPEG)
                backoff.recordSuccess()
                return .described(description)
            } catch OnDeviceModelError.throttled {
                // A menu-bar app is never frontmost, so Apple may throttle its requests (worst on battery).
                // Backing off keeps it from asking again every minute while throttled.
                backoff.recordThrottle(at: now())
                reason = busyReason
            } catch let error as OnDeviceModelError {
                reason = error.localizedDescription
            } catch {
                guard backup != nil else { throw error }
                reason = error.localizedDescription
            }
        } else {
            reason = busyReason
        }

        guard let backup else { return .metadataOnly(reason: reason) }
        return .described(try await backup.describe(observation, screenshotJPEG: screenshotJPEG))
    }

    private var busyReason: String {
        "Apple Intelligence is busy; trying again at \(Self.timeFormatter.string(from: backoff.retryAfter))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
