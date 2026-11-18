import Foundation

/// Writes the day summary within a model's context window. When the whole day doesn't fit, the timeline is split
/// into parts that each fit, every part is condensed into notes, and the notes are summarized (repeating if needed).
public struct DaySummarizer: Sendable {
    public typealias Complete = @Sendable (_ system: String, _ user: String) async throws -> String
    public typealias TokenCount = @Sendable (String) async -> Int

    /// Tokens available for instructions plus prompt, after reserving room for the reply.
    public let promptBudget: Int
    private let tokenCount: TokenCount
    private let complete: Complete
    private let writeSummary: Complete

    /// `writeSummary` makes the final call (default: `complete`), so it can enforce the summary's format.
    public init(promptBudget: Int, tokenCount: @escaping TokenCount, complete: @escaping Complete, writeSummary: Complete? = nil) {
        self.promptBudget = promptBudget
        self.tokenCount = tokenCount
        self.complete = complete
        self.writeSummary = writeSummary ?? complete
    }

    /// About 3 characters per token: deliberately pessimistic for English so estimated prompts still fit.
    public static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    public func summarize(day: String, blocks: [ActivityBlock], appUsage: [AppUsage]) async throws -> String {
        var timeline = ["Timeline blocks:"] + Prompts.dayBlockLines(blocks)
        for _ in 0..<Self.maxCondensingRounds {
            let user = Prompts.dayUser(day: day, timeline: timeline, appUsage: appUsage)
            if await tokenCount(Prompts.daySystem + user) <= promptBudget {
                return try await writeSummary(Prompts.daySystem, user)
            }
            let parts = await split(Array(timeline.dropFirst()), day: day)
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                notes.append(try await complete(Prompts.dayPartSystem, Prompts.dayPartUser(day: day, part: index + 1, of: parts.count, lines: part)))
            }
            timeline = ["Notes on each part of the day, in order:"] + notes
        }
        throw OnDeviceModelError.contextTooLong
    }

    private static let maxCondensingRounds = 4

    /// Greedy split in timeline order; a single line too long for any part is truncated rather than dropped.
    func split(_ lines: [String], day: String) async -> [[String]] {
        let overhead = await tokenCount(Prompts.dayPartSystem + Prompts.dayPartUser(day: day, part: 99, of: 99, lines: []))
        let budget = max(promptBudget - overhead, 64)
        var parts: [[String]] = []
        var current: [String] = []
        var currentTokens = 0
        for line in lines {
            var line = line
            var tokens = await tokenCount(line) + 1
            if tokens > budget {
                line = String(line.prefix(budget * 3))
                tokens = await tokenCount(line) + 1
            }
            if currentTokens + tokens > budget, !current.isEmpty {
                parts.append(current)
                current = []
                currentTokens = 0
            }
            current.append(line)
            currentTokens += tokens
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
