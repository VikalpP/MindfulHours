import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MindfulHoursCore

private func scratchDefaults() -> UserDefaults {
    let name = "MindfulHoursTests-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// What the app does at launch: migrate, then fall back to the registered default when nothing is persisted.
/// (Registered defaults are process-wide, so tests mustn't register them.)
private func launch(_ defaults: UserDefaults, hasChatGPTSession: Bool = false, onDevice: OnDeviceAvailability = .available) -> AIProvider? {
    ProviderSelection.migrateLegacyProxySettings(in: defaults)
    ProviderSelection.keepChatGPTIfInUse(in: defaults, hasChatGPTSession: hasChatGPTSession)
    return defaults.string(forKey: ProviderSelection.providerKey).flatMap(AIProvider.init(rawValue:))
        ?? ProviderSelection.defaultProvider(onDevice: onDevice)
}

@Suite struct ProviderSelectionTests {
    @Test func freshInstallDefaultsToAppleIntelligenceWithoutPersistingIt() {
        let defaults = scratchDefaults()
        #expect(launch(defaults) == .appleIntelligence)
        #expect(defaults.object(forKey: ProviderSelection.providerKey) == nil)
    }

    @Test func fixableUnavailabilityStillDefaultsToAppleIntelligence() {
        #expect(launch(scratchDefaults(), onDevice: .unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligence)
        #expect(launch(scratchDefaults(), onDevice: .unavailable(.modelNotReady)) == .appleIntelligence)
    }

    @Test func macsThatCanNeverRunItDefaultToChatGPT() {
        #expect(launch(scratchDefaults(), onDevice: .unavailable(.deviceNotEligible)) == .chatGPT)
        #expect(launch(scratchDefaults(), onDevice: .unavailable(.requiresNewerMacOS)) == .chatGPT)
        #expect(launch(scratchDefaults(), onDevice: .unavailable(.notInThisBuild)) == .chatGPT)
    }

    @Test func explicitChoiceIsKept() {
        for provider in AIProvider.allCases {
            let defaults = scratchDefaults()
            defaults.set(provider.rawValue, forKey: ProviderSelection.providerKey)
            #expect(launch(defaults, hasChatGPTSession: true) == provider)
        }
    }

    @Test func v010ProxySettingsBecomeCustomWithOldDefaults() {
        let defaults = scratchDefaults()
        defaults.set("sk-local", forKey: "proxyAPIKey")
        #expect(launch(defaults) == .custom)
        #expect(defaults.string(forKey: ProviderSelection.customBaseURLKey) == "http://127.0.0.1:8317/v1")
        #expect(defaults.string(forKey: ProviderSelection.modelKey(for: .custom)) == "claude-haiku-5-5")
        #expect(defaults.string(forKey: ProviderSelection.customAPIKeyHandoffKey) == "sk-local")
        #expect(defaults.object(forKey: "proxyAPIKey") == nil)
    }

    @Test func v010ChangedValuesAreCarriedOver() {
        let defaults = scratchDefaults()
        defaults.set("http://10.0.0.2:9000/v1", forKey: "proxyBaseURL")
        defaults.set("gpt-x", forKey: "model")
        #expect(launch(defaults) == .custom)
        #expect(defaults.string(forKey: ProviderSelection.customBaseURLKey) == "http://10.0.0.2:9000/v1")
        #expect(defaults.string(forKey: ProviderSelection.modelKey(for: .custom)) == "gpt-x")
        #expect(defaults.string(forKey: ProviderSelection.customAPIKeyHandoffKey) == nil)
    }

    @Test func chatGPTInUseUnderTheOldDefaultIsKept() {
        let signedIn = scratchDefaults()
        #expect(launch(signedIn, hasChatGPTSession: true) == .chatGPT)

        let choseModel = scratchDefaults()
        choseModel.set("gpt-6.1-mini", forKey: ProviderSelection.modelKey(for: .chatGPT))
        #expect(launch(choseModel) == .chatGPT)
    }

    @Test func otherProviderSetupWithoutChoosingDoesNotOverrideDefault() {
        let defaults = scratchDefaults()
        defaults.set("claude-haiku-5-5", forKey: ProviderSelection.modelKey(for: .claude))
        #expect(launch(defaults) == .appleIntelligence)
    }

    @Test func pickerOrder() {
        #expect(AIProvider.allCases == [.appleIntelligence, .chatGPT, .ollama, .lmStudio, .claude, .openAI, .gemini, .openRouter, .custom])
        #expect(AIProvider.appleIntelligence.isOnDevice && AIProvider.appleIntelligence.baseURL == nil)
    }
}

@Suite struct ThrottleBackoffTests {
    @Test func doublesFromOneMinuteUpToFifteen() {
        var backoff = ThrottleBackoff()
        let t0 = Date(timeIntervalSince1970: 0)
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            backoff.recordThrottle(at: t0)
            delays.append(backoff.retryAfter.timeIntervalSince(t0))
        }
        #expect(delays == [60, 120, 240, 480, 900, 900])
        #expect(!backoff.allowsAttempt(at: t0.addingTimeInterval(899)))
        #expect(backoff.allowsAttempt(at: t0.addingTimeInterval(900)))
        backoff.recordSuccess()
        #expect(backoff.allowsAttempt(at: t0) && backoff.consecutiveThrottles == 0)
    }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor MockDescriber: MinuteDescriber {
    private var results: [Result<String, Error>]
    private(set) var calls = 0

    init(_ results: [Result<String, Error>]) {
        self.results = results
    }

    func describe(_ observation: MinuteObservation, screenshotJPEG: Data?) async throws -> MinuteDescription {
        calls += 1
        let result = results.count > 1 ? results.removeFirst() : results[0]
        let model = try result.get()
        return MinuteDescription(payload: InsightPayload(summary: "Did work", task: "Work", project: nil, category: .coding), model: model)
    }
}

private struct BackupDown: Error {}

private let observation = MinuteObservation(
    minuteStart: Date(timeIntervalSince1970: 1_800_000_000),
    context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "Router.swift"),
    secondsByApp: [("Xcode", 60)], recentInsights: [], hasScreenshot: false
)

@Suite struct OnDeviceFallbackTests {
    private func describedModel(_ outcome: MinuteOutcome) -> String? {
        if case .described(let description) = outcome { return description.model }
        return nil
    }

    private func isMetadataOnly(_ outcome: MinuteOutcome) -> Bool {
        if case .metadataOnly = outcome { return true }
        return false
    }

    @Test func usesOnDeviceWhenItAnswers() async throws {
        let router = OnDeviceFirstRouter()
        let onDevice = MockDescriber([.success("apple")])
        let backup = MockDescriber([.success("cloud")])
        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)) == "apple")
        #expect(await backup.calls == 0)
    }

    @Test func throttlingWithoutBackupRecordsMetadataAndBacksOff() async throws {
        let clock = TestClock()
        let router = OnDeviceFirstRouter(now: { clock.now })
        let onDevice = MockDescriber([.failure(OnDeviceModelError.throttled), .success("apple")])

        #expect(isMetadataOnly(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)))
        #expect(await router.retryAfter == clock.now.addingTimeInterval(60))

        clock.now += 30
        #expect(isMetadataOnly(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)))
        #expect(await onDevice.calls == 1)

        clock.now += 31
        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)) == "apple")
        #expect(await onDevice.calls == 2)
        #expect(await router.retryAfter == nil)
    }

    @Test func throttlingUsesBackupAndSkipsOnDeviceDuringBackoff() async throws {
        let clock = TestClock()
        let router = OnDeviceFirstRouter(now: { clock.now })
        let onDevice = MockDescriber([.failure(OnDeviceModelError.throttled)])
        let backup = MockDescriber([.success("cloud")])

        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)) == "cloud")
        clock.now += 59
        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)) == "cloud")
        #expect(await onDevice.calls == 1)
        #expect(await backup.calls == 2)

        clock.now += 1
        _ = try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)
        #expect(await onDevice.calls == 2)
        #expect(await router.retryAfter == clock.now.addingTimeInterval(120))
    }

    @Test func declinedMinuteDoesNotBackOff() async throws {
        let router = OnDeviceFirstRouter()
        let onDevice = MockDescriber([.failure(OnDeviceModelError.declined), .success("apple")])
        #expect(isMetadataOnly(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)))
        #expect(await router.retryAfter == nil)
        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)) == "apple")
    }

    @Test func unavailableModelGoesToBackup() async throws {
        let router = OnDeviceFirstRouter()
        let onDevice = MockDescriber([.failure(OnDeviceModelError.unavailable(.appleIntelligenceNotEnabled))])
        let backup = MockDescriber([.success("local")])
        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)) == "local")

        let outcome = try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)
        #expect(outcome == .metadataOnly(reason: OnDeviceAvailability.unavailable(.appleIntelligenceNotEnabled).explanation))
    }

    @Test func unexpectedErrorsSurfaceOnlyWithoutBackup() async throws {
        let router = OnDeviceFirstRouter()
        let onDevice = MockDescriber([.failure(BackupDown())])
        await #expect(throws: BackupDown.self) {
            try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: nil)
        }
        let backup = MockDescriber([.success("cloud")])
        #expect(describedModel(try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)) == "cloud")
    }

    @Test func backupFailurePropagatesForTheRecorderBackoff() async {
        let router = OnDeviceFirstRouter()
        let onDevice = MockDescriber([.failure(OnDeviceModelError.throttled)])
        let backup = MockDescriber([.failure(BackupDown())])
        await #expect(throws: BackupDown.self) {
            try await router.describe(observation, screenshotJPEG: nil, onDevice: onDevice, backup: backup)
        }
    }
}

private actor CallLog {
    var calls: [(system: String, user: String)] = []
    func append(_ system: String, _ user: String) { calls.append((system, user)) }
}

@Suite struct DaySummarizerTests {
    private func blocks(_ count: Int) -> [ActivityBlock] {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let insights = (0..<count).map { index in
            Insight(minuteStart: t0.addingTimeInterval(Double(index) * 60),
                    context: ActivityContext(bundleID: "app.\(index % 3)", appName: "App \(index % 3)", windowTitle: "Window \(index)"),
                    summary: "Worked on a fairly detailed piece of task number \(index) with plenty of words", task: "Task \(index)",
                    project: "project-\(index % 4)", category: .coding, isReused: false, model: "test")
        }
        return Timeline.blocks(from: insights)
    }

    @Test func singleCallWhenTheDayFits() async throws {
        let log = CallLog()
        let summarizer = DaySummarizer(promptBudget: 8000, tokenCount: { DaySummarizer.estimatedTokens($0) }) { system, user in
            await log.append(system, user)
            return "summary"
        }
        #expect(try await summarizer.summarize(day: "2026-11-18", blocks: blocks(5), appUsage: []) == "summary")
        let calls = await log.calls
        #expect(calls.count == 1 && calls[0].system == Prompts.daySystem)
    }

    @Test func longDayIsSplitIntoPartsThatEachFit() async throws {
        let log = CallLog()
        let budget = 1200
        let summarizer = DaySummarizer(promptBudget: budget, tokenCount: { DaySummarizer.estimatedTokens($0) }) { system, user in
            await log.append(system, user)
            return system == Prompts.dayPartSystem ? "- 09:00-10:00 Task (project): 60 min" : "final"
        }
        let dayBlocks = blocks(120)
        #expect(DaySummarizer.estimatedTokens(Prompts.dayUser(day: "2026-11-18", blocks: dayBlocks, appUsage: [])) > budget)

        #expect(try await summarizer.summarize(day: "2026-11-18", blocks: dayBlocks, appUsage: []) == "final")
        let calls = await log.calls
        let parts = calls.filter { $0.system == Prompts.dayPartSystem }
        #expect(parts.count > 1)
        #expect(calls.last?.system == Prompts.daySystem)
        #expect(calls.allSatisfy { DaySummarizer.estimatedTokens($0.system + $0.user) <= budget })
        let partBlockLines = parts.flatMap { $0.user.split(separator: "\n").filter { $0.hasPrefix("- ") } }
        #expect(partBlockLines.count == dayBlocks.count)
    }
}

@Suite struct OnDevicePromptTests {
    @Test func onDevicePromptOmitsTheJSONReplyFormat() {
        #expect(Prompts.minuteSystem.contains("Reply with ONLY a JSON object"))
        #expect(!Prompts.onDeviceMinuteSystem.contains("JSON"))
        #expect(Prompts.onDeviceMinuteSystem.contains("judged from THIS minute's evidence"))
    }

    @Test func trimsLongFieldsForTheSmallContext() {
        var long = observation
        long.context.url = "https://example.com/" + String(repeating: "a", count: 2000)
        let trimmed = AppleIntelligence.trimmedForContext(long)
        #expect(trimmed.context.url!.count == 301)
        #expect(trimmed.context.windowTitle == "Router.swift")
    }

    @Test func downscalesScreenshotsTo768() throws {
        let context = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        let image = try #require(AppleIntelligence.downscaledImage(fromJPEG: jpeg as Data))
        #expect(image.width == 768 && image.height == 480)
    }
}

/// Calls the real on-device model: `MINDFULHOURS_LIVE_AI=1 swift test --filter LiveAppleIntelligence`. Skipped in CI.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MINDFULHOURS_LIVE_AI"] != nil && AppleIntelligence.availability.isAvailable))
struct LiveAppleIntelligenceTests {
    @Test func describesAMinuteFromText() async throws {
        let description = try await AppleIntelligence.minuteDescriber(visionCache: scratchDefaults()).describe(observation, screenshotJPEG: nil)
        print("Live minute:", description.payload)
        #expect(description.model == AppleIntelligence.modelName && !description.payload.summary.isEmpty)
    }

    @Test func summarizesALongDayInParts() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let insights = (0..<240).map { index in
            Insight(minuteStart: t0.addingTimeInterval(Double(index) * 60),
                    context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: index % 2 == 0 ? "Xcode" : "Safari", windowTitle: "File\(index / 10).swift"),
                    summary: "Editing File\(index / 10).swift to add the on-device fallback router and its tests", task: "Task \(index / 5)",
                    project: "MindfulHours", category: .coding, isReused: false, model: "test")
        }
        let summary = try await AppleIntelligence.summarizeDay(day: "2026-11-18", blocks: Timeline.blocks(from: insights), appUsage: [])
        print("Live day summary:", summary)
        #expect(!summary.isEmpty)
    }
}
