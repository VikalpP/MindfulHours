import CoreGraphics
import Foundation
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device Foundation Model. Text needs macOS 26; screenshots need macOS 27 and an SDK that has
/// image attachments (`compiler(>=6.4)`, Xcode 27). Requests never leave the Mac: only `SystemLanguageModel`
/// is used, never Private Cloud Compute.
public enum AppleIntelligence {
    public static let modelName = "apple-on-device"
    static let screenshotMaxPixelSize = 768
    static let minuteReplyTokens = 200
    static let dayReplyTokens = 800
    private static let maxFieldLength = 300

    public static var availability: OnDeviceAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unavailable(.requiresNewerMacOS) }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
        case .unavailable: return .unavailable(.unknown)
        }
        #else
        return .unavailable(.notInThisBuild)
        #endif
    }

    public static func minuteDescriber(visionCache: UserDefaults = .standard) -> any MinuteDescriber {
        OnDeviceMinuteDescriber(visionCache: visionCache)
    }

    /// For Test Connection.
    public static func reply(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw OnDeviceModelError.unavailable(.requiresNewerMacOS) }
        try requireAvailable()
        return try await respondText(system: system, user: user, maxTokens: 64)
        #else
        throw OnDeviceModelError.unavailable(.notInThisBuild)
        #endif
    }

    public static func summarizeDay(day: String, blocks: [ActivityBlock], appUsage: [AppUsage]) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw OnDeviceModelError.unavailable(.requiresNewerMacOS) }
        try requireAvailable()
        let model = SystemLanguageModel.default
        // contextSize is 4096 before macOS 27 and 8192 on this generation of Macs; leave room for the reply and framing.
        let summarizer = DaySummarizer(
            promptBudget: model.contextSize - dayReplyTokens - 200,
            tokenCount: { await tokenCount($0) },
            complete: { system, user in try await respondText(system: system, user: user, maxTokens: dayReplyTokens) },
            writeSummary: { system, user in try await respondDaySummary(system: system, user: user) }
        )
        return try await summarizer.summarize(day: day, blocks: blocks, appUsage: appUsage)
        #else
        throw OnDeviceModelError.unavailable(.notInThisBuild)
        #endif
    }

    /// Whether minutes can include a screenshot, confirmed once per macOS build with a real image request.
    public static func supportsScreenshots(cache: UserDefaults = .standard) async throws -> Bool {
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        if let cached = cache.dictionary(forKey: visionCacheKey), cached["build"] as? String == build, let supported = cached["supported"] as? Bool {
            return supported
        }
        guard let supported = try await probeVision() else { return false }
        cache.set(["build": build, "supported": supported], forKey: visionCacheKey)
        return supported
    }

    static func rememberNoVision(cache: UserDefaults) {
        cache.set(["build": ProcessInfo.processInfo.operatingSystemVersionString, "supported": false], forKey: visionCacheKey)
    }

    private static let visionCacheKey = "appleIntelligenceVisionSupport"

    /// Nil when the answer is unknown (a transient failure), so it isn't cached.
    private static func probeVision() async throws -> Bool? {
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(macOS 27, *) else { return false }
        guard SystemLanguageModel.default.capabilities.contains(.vision) else { return false }
        guard let image = solidImage() else { return nil }
        let session = LanguageModelSession(model: .default, instructions: "Answer in one word.")
        do {
            _ = try await session.respond(options: GenerationOptions(maximumResponseTokens: 8)) {
                "What color is this image?"
                Attachment(image)
            }
            return true
        } catch where isUnsupportedCapability(error) {
            return false
        } catch {
            let classified = classify(error)
            if classified == .throttled { throw classified }
            return nil
        }
        #else
        return false
        #endif
    }

    static func downscaledImage(fromJPEG jpeg: Data, maxPixelSize: Int = screenshotMaxPixelSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Long titles and URLs would eat a 4K context; the start carries the meaning.
    static func trimmedForContext(_ observation: MinuteObservation) -> MinuteObservation {
        var observation = observation
        func trim(_ text: String?) -> String? { text.map { $0.count > maxFieldLength ? String($0.prefix(maxFieldLength)) + "…" : $0 } }
        observation.context.windowTitle = trim(observation.context.windowTitle)
        observation.context.url = trim(observation.context.url)
        observation.context.documentPath = trim(observation.context.documentPath)
        return observation
    }

    private static func solidImage() -> CGImage? {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context?.makeImage()
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct OnDeviceMinute {
    @Guide(description: "At most 18 words, starts with a verb, specific")
    var summary: String
    @Guide(description: "2-6 word label for the piece of work this minute serves")
    var task: String
    @Guide(description: "Repo, client, product or topic the work belongs to; empty if unclear")
    var project: String
    @Guide(description: "Kind of activity", .anyOf(ActivityCategory.allCases.map(\.rawValue)))
    var category: String

    var payload: InsightPayload? {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, !task.isEmpty else { return nil }
        let hasProject = !project.isEmpty && !["null", "none", "unknown"].contains(project.lowercased())
        return InsightPayload(summary: summary, task: task, project: hasProject ? project : nil, category: ActivityCategory(lenient: category))
    }
}

/// Guided generation keeps the overview / work log / focus layout that the small model drops from free text.
@available(macOS 26, *)
@Generable
struct OnDeviceDaySummary {
    @Guide(description: "2-3 sentence overview of the day")
    var overview: String
    @Guide(description: "Work log entries grouped by project or task, each with approximate time spent", .maximumCount(10))
    var workLog: [String]
    @Guide(description: "One or two observations about focus, context switches and interruptions")
    var focus: String

    var markdown: String {
        let entries = workLog.map { "- " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespacesAndNewlines)) }
        return ([overview.trimmingCharacters(in: .whitespacesAndNewlines), "", "**Work log**"] + entries + ["", "**Focus**", focus.trimmingCharacters(in: .whitespacesAndNewlines)])
            .joined(separator: "\n")
    }
}

extension AppleIntelligence {
    @available(macOS 26, *)
    static func respondDaySummary(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: system)
        do {
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: dayReplyTokens)
            return try await session.respond(to: user, generating: OnDeviceDaySummary.self, options: options).content.markdown
        } catch {
            throw classify(error)
        }
    }

    @available(macOS 26, *)
    static func requireAvailable() throws {
        if case .unavailable(let reason) = availability { throw OnDeviceModelError.unavailable(reason) }
    }

    @available(macOS 26, *)
    static func respondText(system: String, user: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: system)
        do {
            let response = try await session.respond(to: user, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens))
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw classify(error)
        }
    }

    @available(macOS 26, *)
    static func tokenCount(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return count
        }
        return DaySummarizer.estimatedTokens(text)
    }

    @available(macOS 26, *)
    static func describeMinute(_ observation: MinuteObservation, image: CGImage?) async throws -> InsightPayload {
        let session = LanguageModelSession(model: .default, instructions: Prompts.onDeviceMinuteSystem)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: minuteReplyTokens)
        let prompt = Prompts.minuteUser(observation)
        let minute: OnDeviceMinute
        do {
            #if compiler(>=6.4)
            if #available(macOS 27, *), let image {
                minute = try await session.respond(generating: OnDeviceMinute.self, options: options) {
                    prompt
                    Attachment(image)
                }.content
            } else {
                minute = try await session.respond(to: prompt, generating: OnDeviceMinute.self, options: options).content
            }
            #else
            minute = try await session.respond(to: prompt, generating: OnDeviceMinute.self, options: options).content
            #endif
        } catch {
            if image != nil, isUnsupportedCapability(error) { throw VisionUnsupported() }
            throw classify(error)
        }
        guard let payload = minute.payload else { throw OnDeviceModelError.failed("Apple Intelligence returned an empty description") }
        return payload
    }

    struct VisionUnsupported: Error {}

    @available(macOS 26, *)
    static func isUnsupportedCapability(_ error: Error) -> Bool {
        #if compiler(>=6.4)
        if #available(macOS 27, *), let error = error as? LanguageModelError {
            switch error {
            case .unsupportedCapability, .unsupportedTranscriptContent: return true
            default: return false
            }
        }
        #endif
        return false
    }

    @available(macOS 26, *)
    static func classify(_ error: Error) -> OnDeviceModelError {
        if let error = error as? OnDeviceModelError { return error }
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .rateLimited, .timeout: return .throttled
                case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: return .declined
                case .contextSizeExceeded: return .contextTooLong
                default: return .failed(error.localizedDescription)
                }
            }
            if let error = error as? SystemLanguageModel.Error, case .assetsUnavailable = error {
                return .unavailable(.modelNotReady)
            }
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests: return .throttled
            case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: return .declined
            case .exceededContextWindowSize: return .contextTooLong
            case .assetsUnavailable: return .unavailable(.modelNotReady)
            default: return .failed(error.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }
}
#endif

struct OnDeviceMinuteDescriber: MinuteDescriber {
    /// UserDefaults is thread-safe but not marked Sendable.
    nonisolated(unsafe) let visionCache: UserDefaults

    func describe(_ observation: MinuteObservation, screenshotJPEG: Data?) async throws -> MinuteDescription {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw OnDeviceModelError.unavailable(.requiresNewerMacOS) }
        try AppleIntelligence.requireAvailable()
        var observation = AppleIntelligence.trimmedForContext(observation)
        var image: CGImage?
        if let screenshotJPEG, try await AppleIntelligence.supportsScreenshots(cache: visionCache) {
            image = AppleIntelligence.downscaledImage(fromJPEG: screenshotJPEG)
        }
        observation.hasScreenshot = image != nil

        do {
            return MinuteDescription(payload: try await AppleIntelligence.describeMinute(observation, image: image), model: AppleIntelligence.modelName)
        } catch is AppleIntelligence.VisionUnsupported {
            AppleIntelligence.rememberNoVision(cache: visionCache)
            observation.hasScreenshot = false
            return MinuteDescription(payload: try await AppleIntelligence.describeMinute(observation, image: nil), model: AppleIntelligence.modelName)
        } catch OnDeviceModelError.contextTooLong {
            observation.recentInsights = []
            observation.hasScreenshot = false
            return MinuteDescription(payload: try await AppleIntelligence.describeMinute(observation, image: nil), model: AppleIntelligence.modelName)
        }
        #else
        throw OnDeviceModelError.unavailable(.notInThisBuild)
        #endif
    }
}
