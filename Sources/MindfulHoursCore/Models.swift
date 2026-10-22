import Foundation

public struct ActivityContext: Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    public var documentPath: String?
    public var url: String?

    public init(bundleID: String, appName: String, windowTitle: String? = nil, documentPath: String? = nil, url: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.url = url
    }

    /// Keeps only the app identity so excluded apps never leak titles, URLs or paths into storage or prompts.
    public var redacted: ActivityContext {
        ActivityContext(bundleID: bundleID, appName: appName)
    }

    public var continuityKey: String {
        [bundleID, windowTitle ?? "", url ?? "", documentPath ?? ""].joined(separator: "\u{1F}")
    }
}

public enum ActivityCategory: String, CaseIterable, Sendable, Codable {
    case coding, writing, communication, meeting, research, design, planning, admin, learning, entertainment, other

    public init(lenient raw: String?) {
        let normalized = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = ActivityCategory(rawValue: normalized) ?? .other
    }

    public var label: String { rawValue.capitalized }
}

public struct ActivitySpan: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var start: Date
    public var end: Date
    public var context: ActivityContext

    public init(id: Int64, start: Date, end: Date, context: ActivityContext) {
        self.id = id
        self.start = start
        self.end = end
        self.context = context
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct Insight: Identifiable, Hashable, Sendable {
    public static let coveredDuration: TimeInterval = 60

    public var id: Int64
    public var minuteStart: Date
    public var context: ActivityContext
    public var summary: String
    public var task: String
    public var project: String?
    public var category: ActivityCategory
    public var isReused: Bool
    public var model: String

    public init(id: Int64 = 0, minuteStart: Date, context: ActivityContext, summary: String, task: String, project: String?, category: ActivityCategory, isReused: Bool, model: String) {
        self.id = id
        self.minuteStart = minuteStart
        self.context = context
        self.summary = summary
        self.task = task
        self.project = project
        self.category = category
        self.isReused = isReused
        self.model = model
    }

    public var minuteEnd: Date { minuteStart.addingTimeInterval(Self.coveredDuration) }
}

public struct DaySummary: Hashable, Sendable {
    public var day: String
    public var text: String
    public var createdAt: Date

    public init(day: String, text: String, createdAt: Date) {
        self.day = day
        self.text = text
        self.createdAt = createdAt
    }
}

extension Insight {
    public static let metadataModel = "metadata"

    /// Used when AI analysis is off, excluded, or unavailable, so every active minute still lands on the timeline.
    public static func fromMetadata(minuteStart: Date, context: ActivityContext, previous: Insight?) -> Insight {
        let detail = context.windowTitle ?? context.url ?? context.documentPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let continuesPrevious = previous?.context.bundleID == context.bundleID
        return Insight(
            minuteStart: minuteStart,
            context: context,
            summary: [context.appName, detail].compactMap { $0 }.joined(separator: " — "),
            task: continuesPrevious ? previous!.task : context.appName,
            project: continuesPrevious ? previous!.project : nil,
            category: continuesPrevious ? previous!.category : .other,
            isReused: false,
            model: metadataModel
        )
    }

    public static let privateTask = "Private"

    /// For minutes whose title or URL is itself sensitive: only the app name survives.
    public static func privateContent(minuteStart: Date, context: ActivityContext) -> Insight {
        Insight(
            minuteStart: minuteStart,
            context: context.redacted,
            summary: "\(context.appName) — private content hidden",
            task: privateTask,
            project: nil,
            category: .other,
            isReused: false,
            model: metadataModel
        )
    }

    public func reused(for minuteStart: Date) -> Insight {
        var copy = self
        copy.id = 0
        copy.minuteStart = minuteStart
        copy.isReused = true
        return copy
    }
}
