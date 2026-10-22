import Foundation

public struct ActivityBlock: Identifiable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var task: String
    public var project: String?
    public var category: ActivityCategory
    public var summaries: [String]
    public var apps: [String]

    public var id: Date { start }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct AppUsage: Identifiable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var seconds: TimeInterval

    public var id: String { bundleID }
}

public struct CategoryUsage: Identifiable, Hashable, Sendable {
    public var category: ActivityCategory
    public var seconds: TimeInterval

    public var id: ActivityCategory { category }
}

public enum Timeline {
    public static func blocks(from insights: [Insight], maxGap: TimeInterval = 180) -> [ActivityBlock] {
        var blocks: [ActivityBlock] = []
        for insight in insights.sorted(by: { $0.minuteStart < $1.minuteStart }) {
            if var last = blocks.last,
               last.task.caseInsensitiveCompare(insight.task) == .orderedSame,
               insight.minuteStart.timeIntervalSince(last.end) <= maxGap {
                last.end = insight.minuteEnd
                last.project = last.project ?? insight.project
                appendUnique(insight.summary, to: &last.summaries)
                appendUnique(insight.context.appName, to: &last.apps)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(ActivityBlock(
                    start: insight.minuteStart,
                    end: insight.minuteEnd,
                    task: insight.task,
                    project: insight.project,
                    category: insight.category,
                    summaries: [insight.summary],
                    apps: [insight.context.appName]
                ))
            }
        }
        return blocks
    }

    public static func appUsage(from spans: [ActivitySpan], within interval: DateInterval) -> [AppUsage] {
        var totals: [String: AppUsage] = [:]
        for span in spans {
            let start = max(span.start, interval.start)
            let end = min(span.end, interval.end)
            guard end > start else { continue }
            totals[span.context.bundleID, default: AppUsage(bundleID: span.context.bundleID, appName: span.context.appName, seconds: 0)]
                .seconds += end.timeIntervalSince(start)
        }
        return totals.values.sorted { $0.seconds > $1.seconds }
    }

    public static func activeSeconds(from spans: [ActivitySpan], within interval: DateInterval) -> TimeInterval {
        appUsage(from: spans, within: interval).reduce(0) { $0 + $1.seconds }
    }

    public static func categoryUsage(from insights: [Insight]) -> [CategoryUsage] {
        Dictionary(grouping: insights, by: \.category)
            .map { CategoryUsage(category: $0.key, seconds: Double($0.value.count) * Insight.coveredDuration) }
            .sorted { $0.seconds > $1.seconds }
    }

    public static func dayInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)!
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func appendUnique(_ value: String, to list: inout [String]) {
        if !list.contains(value) { list.append(value) }
    }
}

public struct MinuteAccumulator: Sendable {
    public private(set) var secondsByContext: [ActivityContext: TimeInterval] = [:]

    public init() {}

    public mutating func record(_ context: ActivityContext, seconds: TimeInterval) {
        secondsByContext[context, default: 0] += seconds
    }

    public var activeSeconds: TimeInterval { secondsByContext.values.reduce(0, +) }

    public var dominantContext: ActivityContext? {
        secondsByContext.max { $0.value < $1.value }?.key
    }

    public var secondsByApp: [(appName: String, seconds: TimeInterval)] {
        Dictionary(grouping: secondsByContext, by: \.key.appName)
            .map { (appName: $0.key, seconds: $0.value.reduce(0) { $0 + $1.value }) }
            .sorted { $0.seconds > $1.seconds }
    }

    public mutating func reset() {
        secondsByContext.removeAll()
    }
}

extension Timeline {
    public static func markdown(day: String, blocks: [ActivityBlock], summary: DaySummary?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var lines = ["# Activity — \(day)", ""]
        if let summary {
            lines += [summary.text, ""]
        }
        lines.append("## Timeline")
        for block in blocks {
            let project = block.project.map { " · \($0)" } ?? ""
            lines.append("- **\(formatter.string(from: block.start))–\(formatter.string(from: block.end))** \(block.task)\(project) (\(formatDuration(block.duration)))")
            for detail in block.summaries.prefix(5) {
                lines.append("  - \(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
