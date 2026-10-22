import CoreGraphics
import Foundation
import Testing
@testable import MindfulHoursCore

private let editor = ActivityContext(bundleID: "com.microsoft.VSCode", appName: "Code", windowTitle: "Recorder.swift — tracker")
private let browser = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", windowTitle: "PR #12", url: "https://github.com/x/y/pull/12")
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func insight(_ minute: Int, task: String, context: ActivityContext = editor, summary: String? = nil) -> Insight {
    Insight(
        minuteStart: t0.addingTimeInterval(Double(minute) * 60), context: context, summary: summary ?? "Did \(task) at \(minute)",
        task: task, project: nil, category: .coding, isReused: false, model: "test"
    )
}

private func temporaryStore() throws -> ActivityStore {
    try ActivityStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("tracker-\(UUID()).sqlite"))
}

@Suite struct InsightParsingTests {
    @Test func parsesFencedJSONWithChatter() {
        let reply = """
            Here you go:
            ```json
            {"summary": "Reviewing PR #12 in x/y", "task": "Review PR #12", "project": "x/y", "category": "Coding"}
            ```
            """
        #expect(Prompts.parseInsight(reply) == InsightPayload(summary: "Reviewing PR #12 in x/y", task: "Review PR #12", project: "x/y", category: .coding))
    }

    @Test func normalizesNullProjectAndUnknownCategory() {
        let payload = Prompts.parseInsight(#"{"summary": "Watching a talk", "task": "Talk", "project": "null", "category": "fun"}"#)
        #expect(payload?.project == nil)
        #expect(payload?.category == .other)
    }

    @Test func rejectsMissingOrEmptyFields() {
        #expect(Prompts.parseInsight("I cannot tell") == nil)
        #expect(Prompts.parseInsight(#"{"summary": "", "task": "x"}"#) == nil)
    }

    @Test func minutePromptCarriesContextAndRecentTasks() {
        let observation = MinuteObservation(
            minuteStart: t0, context: browser, secondsByApp: [("Chrome", 50), ("Slack", 10)],
            recentInsights: [insight(-1, task: "Review PR #12")], hasScreenshot: true
        )
        let prompt = Prompts.minuteUser(observation)
        #expect(prompt.contains("URL: https://github.com/x/y/pull/12"))
        #expect(prompt.contains("Chrome 50s, Slack 10s"))
        #expect(prompt.contains("Code [Review PR #12]"))
        #expect(!prompt.contains("Did Review PR #12"))
    }
}

@Suite struct TimelineTests {
    @Test func groupsContiguousMinutesOfSameTask() {
        let blocks = Timeline.blocks(from: [
            insight(0, task: "Build tracker"),
            insight(1, task: "build TRACKER", context: browser),
            insight(2, task: "Slack catch-up"),
            insight(3, task: "Build tracker"),
        ])
        #expect(blocks.map(\.task) == ["Build tracker", "Slack catch-up", "Build tracker"])
        #expect(blocks[0].duration == 120)
        #expect(blocks[0].apps == ["Code", "Chrome"])
    }

    @Test func splitsSameTaskAcrossLongGap() {
        let blocks = Timeline.blocks(from: [insight(0, task: "A"), insight(10, task: "A")], maxGap: 180)
        #expect(blocks.count == 2)
    }

    @Test func deduplicatesRepeatedSummaries() {
        let blocks = Timeline.blocks(from: [insight(0, task: "A", summary: "Same"), insight(1, task: "A", summary: "Same")])
        #expect(blocks[0].summaries == ["Same"])
    }

    @Test func appUsageClipsSpansToInterval() {
        let spans = [
            ActivitySpan(id: 1, start: t0.addingTimeInterval(-100), end: t0.addingTimeInterval(50), context: editor),
            ActivitySpan(id: 2, start: t0.addingTimeInterval(50), end: t0.addingTimeInterval(80), context: browser),
            ActivitySpan(id: 3, start: t0.addingTimeInterval(80), end: t0.addingTimeInterval(100), context: editor),
        ]
        let usage = Timeline.appUsage(from: spans, within: DateInterval(start: t0, duration: 3600))
        #expect(usage.map(\.appName) == ["Code", "Chrome"])
        #expect(usage.map(\.seconds) == [70, 30])
    }

    @Test func formatsDurations() {
        #expect(Timeline.formatDuration(45 * 60) == "45m")
        #expect(Timeline.formatDuration(120 * 60) == "2h")
        #expect(Timeline.formatDuration(95 * 60) == "1h 35m")
    }

    @Test func accumulatorPicksDominantContext() {
        var minute = MinuteAccumulator()
        minute.record(editor, seconds: 35)
        minute.record(browser, seconds: 20)
        minute.record(editor, seconds: 5)
        #expect(minute.dominantContext == editor)
        #expect(minute.activeSeconds == 60)
    }

    @Test func redactedContextDropsTitleURLAndPath() {
        let redacted = browser.redacted
        #expect(redacted == ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome"))
        #expect(Insight.fromMetadata(minuteStart: t0, context: redacted, previous: nil).summary == "Chrome")
    }

    @Test func dominantAppIsChosenByTotalTimeAcrossItsPages() {
        var minute = MinuteAccumulator()
        let code = ActivityContext(bundleID: "com.microsoft.VSCode", appName: "Code", windowTitle: "README.md")
        let terminalTitles = ["node ◂ claude", "zsh", "swift test"]
        minute.record(code, seconds: 20)
        for (title, seconds) in zip(terminalTitles, [15.0, 12, 10]) {
            minute.record(ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: title), seconds: seconds)
        }
        #expect(minute.dominantContext?.appName == "Terminal")
        #expect(minute.dominantContext?.windowTitle == "node ◂ claude")
    }

    @Test func dominantAppTieGoesToMostRecentlyUsed() {
        var minute = MinuteAccumulator()
        minute.record(editor, seconds: 30)
        minute.record(browser, seconds: 30)
        #expect(minute.dominantContext == browser)
        minute.record(editor, seconds: 0)
        #expect(minute.dominantContext == editor)
    }

    @Test func metadataInsightContinuesPreviousTaskInSameApp() {
        let previous = insight(0, task: "Build tracker")
        let fallback = Insight.fromMetadata(minuteStart: t0.addingTimeInterval(60), context: editor, previous: previous)
        #expect(fallback.task == "Build tracker")
        #expect(fallback.summary == "Code — Recorder.swift — tracker")
        #expect(Insight.fromMetadata(minuteStart: t0, context: browser, previous: previous).task == "Chrome")
    }
}

@Suite struct StoreTests {
    @Test func presenceExtendsAndSwitchesSpansWithoutGaps() async throws {
        let store = try temporaryStore()
        try await store.recordPresence(editor, at: t0, maxGap: 12)
        try await store.recordPresence(editor, at: t0.addingTimeInterval(5), maxGap: 12)
        try await store.recordPresence(browser, at: t0.addingTimeInterval(10), maxGap: 12)
        try await store.recordPresence(browser, at: t0.addingTimeInterval(100), maxGap: 12)

        let spans = try await store.spans(overlapping: DateInterval(start: t0, duration: 3600))
        #expect(spans.map(\.context) == [editor, browser, browser])
        #expect(spans.map(\.start) == [t0, t0.addingTimeInterval(5), t0.addingTimeInterval(100)])
        #expect(spans.map(\.end) == [t0.addingTimeInterval(5), t0.addingTimeInterval(10), t0.addingTimeInterval(100)])
    }

    @Test func endPresenceStartsFreshSpan() async throws {
        let store = try temporaryStore()
        try await store.recordPresence(editor, at: t0, maxGap: 12)
        await store.endPresence()
        try await store.recordPresence(editor, at: t0.addingTimeInterval(5), maxGap: 12)
        try await store.recordPresence(editor, at: t0.addingTimeInterval(10), maxGap: 12)
        let spans = try await store.spans(overlapping: DateInterval(start: t0.addingTimeInterval(-1), duration: 60))
        #expect(spans.map(\.start) == [t0, t0.addingTimeInterval(5)])
    }

    @Test func insightsRoundTripAndReplacePerMinute() async throws {
        let store = try temporaryStore()
        try await store.saveInsight(insight(0, task: "First"))
        try await store.saveInsight(insight(0, task: "Replaced", context: browser))
        try await store.saveInsight(insight(1, task: "Second").reused(for: t0.addingTimeInterval(60)))

        let saved = try await store.insights(in: DateInterval(start: t0, duration: 3600))
        #expect(saved.map(\.task) == ["Replaced", "Second"])
        #expect(saved[0].context == browser)
        #expect(saved[1].isReused)
        #expect(try await store.latestInsights(limit: 1).map(\.task) == ["Second"])
    }

    @Test func daySummaryRoundTrip() async throws {
        let store = try temporaryStore()
        try await store.saveDaySummary(DaySummary(day: "2027-01-15", text: "Shipped it", createdAt: t0))
        #expect(try await store.daySummary(for: "2027-01-15")?.text == "Shipped it")
        try await store.deleteAll()
        #expect(try await store.daySummary(for: "2027-01-15") == nil)
    }
}

@Suite struct FingerprintTests {
    private func gradient(reversed: Bool) -> CGImage {
        let width = 64, height = 48
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        for x in 0..<width {
            let level = CGFloat(reversed ? width - x : x) / CGFloat(width)
            context.setFillColor(gray: level, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()!
    }

    @Test func identicalImagesMatchAndDifferentImagesDiverge() throws {
        let image = try #require(ImageFingerprint(image: gradient(reversed: false)))
        let same = try #require(ImageFingerprint(image: gradient(reversed: false)))
        let flipped = try #require(ImageFingerprint(image: gradient(reversed: true)))
        #expect(image.distance(to: same) == 0)
        #expect(image.distance(to: flipped) > 40)
    }
}

@Suite struct MultiAppTimelineTests {
    private let day = DateInterval(start: t0, duration: 86_400)
    private let slack = ActivityContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#eng")

    private func span(_ context: ActivityContext, _ from: TimeInterval, _ to: TimeInterval, title: String? = nil) -> ActivitySpan {
        var context = context
        if let title { context.windowTitle = title }
        return ActivitySpan(id: 0, start: t0.addingTimeInterval(from), end: t0.addingTimeInterval(to), context: context)
    }

    @Test func blocksListEveryAppUsedDuringThemFromSpans() {
        let blocks = Timeline.withAppUsage(
            Timeline.blocks(from: [insight(0, task: "Fix bug"), insight(1, task: "Fix bug")]),
            from: [span(editor, 0, 70), span(browser, 70, 100), span(editor, 100, 130), span(slack, 200, 260)]
        )
        #expect(blocks[0].appUsage.map(\.appName) == ["Code", "Chrome"])
        #expect(blocks[0].appUsage.map(\.seconds) == [90, 30])
    }

    @Test func lanesMergeQuickSwitchesAndKeepLongestTitle() {
        let spans = [
            span(editor, 0, 50, title: "a.swift"), span(browser, 50, 60), span(editor, 60, 200, title: "b.swift"),
            span(editor, 500, 520, title: "c.swift"),
        ]
        let lanes = Timeline.lanes(from: spans, within: day, mergeGap: 30)
        let code = lanes.first { $0.appName == "Code" }!
        #expect(code.segments.count == 2)
        #expect(code.segments[0].start == t0 && code.segments[0].end == t0.addingTimeInterval(200))
        #expect(code.segments[0].title == "b.swift")
        #expect(lanes.map(\.appName) == ["Code", "Chrome"])
    }

    @Test func extraAppsCollapseIntoOtherLane() {
        let spans = [span(editor, 0, 300), span(browser, 300, 400), span(slack, 400, 420)]
        let lanes = Timeline.lanes(from: spans, within: day, maxLanes: 2)
        #expect(lanes.map(\.appName) == ["Code", "Chrome", "Other"])
        #expect(lanes.last?.seconds == 20)
        #expect(lanes.last?.segments.first?.title == "Slack")
    }

    @Test func activeHoursSnapToWholeHours() {
        let calendar = Calendar(identifier: .gregorian)
        let hours = Timeline.activeHours(of: [span(editor, 600, 4000)], within: day, calendar: calendar)!
        #expect(calendar.component(.minute, from: hours.start) == 0)
        #expect(hours.start <= t0.addingTimeInterval(600) && hours.end >= t0.addingTimeInterval(4000))
        #expect(hours.duration.truncatingRemainder(dividingBy: 3600) == 0)
    }

    @Test func compactDurationShowsSecondsUnderAMinute() {
        #expect(Timeline.formatCompactDuration(42) == "42s")
        #expect(Timeline.formatCompactDuration(8 * 60) == "8m")
    }
}
