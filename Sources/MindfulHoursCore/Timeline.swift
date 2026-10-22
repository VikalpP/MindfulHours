import Foundation

public struct ActivityBlock: Identifiable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var task: String
    public var project: String?
    public var category: ActivityCategory
    public var summaries: [String]
    public var apps: [String]
    /// Every app used during the block, from activity checks rather than AI minutes, so secondary apps show up too.
    public var appUsage: [AppUsage] = []

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
    private var lastRecordedOrder: [ActivityContext: Int] = [:]
    private var recordCount = 0

    public init() {}

    public mutating func record(_ context: ActivityContext, seconds: TimeInterval) {
        secondsByContext[context, default: 0] += seconds
        recordCount += 1
        lastRecordedOrder[context] = recordCount
    }

    public var activeSeconds: TimeInterval { secondsByContext.values.reduce(0, +) }

    /// The app with the most time this minute (ties go to the one used last), then that app's most-used page.
    /// Choosing the page first would let one stable page beat an app whose title kept changing, like a terminal.
    public var dominantContext: ActivityContext? {
        let secondsByApp = Dictionary(grouping: secondsByContext, by: \.key.bundleID)
            .mapValues { $0.reduce(0) { $0 + $1.value } }
        let lastUseByApp = Dictionary(grouping: lastRecordedOrder, by: \.key.bundleID)
            .mapValues { $0.map(\.value).max() ?? 0 }
        guard let app = secondsByApp.max(by: { ($0.value, lastUseByApp[$0.key] ?? 0) < ($1.value, lastUseByApp[$1.key] ?? 0) })?.key else {
            return nil
        }
        return secondsByContext
            .filter { $0.key.bundleID == app }
            .max { ($0.value, lastRecordedOrder[$0.key] ?? 0) < ($1.value, lastRecordedOrder[$1.key] ?? 0) }?
            .key
    }

    public var secondsByApp: [(appName: String, seconds: TimeInterval)] {
        Dictionary(grouping: secondsByContext, by: \.key.appName)
            .map { (appName: $0.key, seconds: $0.value.reduce(0) { $0 + $1.value }) }
            .sorted { $0.seconds > $1.seconds }
    }

    public mutating func reset() {
        secondsByContext.removeAll()
        lastRecordedOrder.removeAll()
        recordCount = 0
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

public struct LaneSegment: Hashable, Sendable {
    public var start: Date
    public var end: Date
    /// The window title with the most time inside the segment.
    public var title: String?

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct AppLane: Identifiable, Hashable, Sendable {
    public static let otherBundleID = "other"

    public var bundleID: String
    public var appName: String
    public var seconds: TimeInterval
    public var segments: [LaneSegment]

    public var id: String { bundleID }
    public var isOther: Bool { bundleID == Self.otherBundleID }
}

extension Timeline {
    public static func withAppUsage(_ blocks: [ActivityBlock], from spans: [ActivitySpan]) -> [ActivityBlock] {
        blocks.map { block in
            var block = block
            block.appUsage = appUsage(from: spans, within: DateInterval(start: block.start, end: block.end)).filter { $0.seconds >= 1 }
            return block
        }
    }

    /// One lane per top app plus an "Other" lane, with spans closer than `mergeGap` joined so quick switches stay readable.
    public static func lanes(from spans: [ActivitySpan], within interval: DateInterval, maxLanes: Int = 6, mergeGap: TimeInterval = 30) -> [AppLane] {
        let usage = appUsage(from: spans, within: interval)
        let topApps = Set(usage.prefix(maxLanes).map(\.bundleID))
        var lanes = usage.prefix(maxLanes).map { app in
            AppLane(
                bundleID: app.bundleID, appName: app.appName, seconds: app.seconds,
                segments: mergedSegments(spans.filter { $0.context.bundleID == app.bundleID }, within: interval, mergeGap: mergeGap)
            )
        }
        let otherSpans = spans.filter { !topApps.contains($0.context.bundleID) }
        let otherSeconds = usage.dropFirst(maxLanes).reduce(0) { $0 + $1.seconds }
        if otherSeconds > 0 {
            let labelled = otherSpans.map { span in
                var span = span
                span.context.windowTitle = span.context.appName
                return span
            }
            lanes.append(AppLane(
                bundleID: AppLane.otherBundleID, appName: "Other", seconds: otherSeconds,
                segments: mergedSegments(labelled, within: interval, mergeGap: mergeGap)
            ))
        }
        return lanes
    }

    /// The hours that contain any activity, so the lanes don't stretch over an empty night.
    public static func activeHours(of spans: [ActivitySpan], within interval: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        let clipped = spans.compactMap { span -> DateInterval? in
            let start = max(span.start, interval.start), end = min(span.end, interval.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
        guard let first = clipped.map(\.start).min(), let last = clipped.map(\.end).max() else { return nil }
        let start = calendar.dateInterval(of: .hour, for: first)!.start
        let lastHour = calendar.dateInterval(of: .hour, for: last)!
        let end = last == lastHour.start ? last : lastHour.end
        return DateInterval(start: start, end: min(max(end, start.addingTimeInterval(3600)), interval.end))
    }

    private static func mergedSegments(_ spans: [ActivitySpan], within interval: DateInterval, mergeGap: TimeInterval) -> [LaneSegment] {
        var segments: [LaneSegment] = []
        var titleSeconds: [String: TimeInterval] = [:]

        func closeSegment() {
            guard !segments.isEmpty else { return }
            segments[segments.count - 1].title = titleSeconds.max { $0.value < $1.value }?.key
            titleSeconds.removeAll()
        }

        for span in spans.sorted(by: { $0.start < $1.start }) {
            let start = max(span.start, interval.start), end = min(span.end, interval.end)
            guard end > start else { continue }
            if let last = segments.last, start.timeIntervalSince(last.end) <= mergeGap {
                segments[segments.count - 1].end = max(last.end, end)
            } else {
                closeSegment()
                segments.append(LaneSegment(start: start, end: end, title: nil))
            }
            if let title = span.context.windowTitle {
                titleSeconds[title, default: 0] += end.timeIntervalSince(start)
            }
        }
        closeSegment()
        return segments
    }

    public static func formatCompactDuration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds.rounded()))s" : formatDuration(seconds)
    }
}
