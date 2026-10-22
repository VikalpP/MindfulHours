import Foundation

public actor ActivityStore {
    private let database: SQLiteDatabase
    private var openSpan: (id: Int64, continuityKey: String, lastSeen: Date)?

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ActivityTracker", isDirectory: true).appendingPathComponent("activity.sqlite")
    }

    public init(url: URL = ActivityStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: url.path)
        try Self.migrate(database)
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        if database.userVersion < 1 { try createInitialSchema(database) }
        if database.userVersion < 2 { try addPrivacyEvents(database) }
    }

    private static func addPrivacyEvents(_ database: SQLiteDatabase) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE privacy_events (
                    id INTEGER PRIMARY KEY,
                    occurred_at REAL NOT NULL,
                    bundle_id TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    reasons TEXT NOT NULL,
                    detail TEXT
                )
                """)
            try database.execute("CREATE INDEX privacy_events_occurred_at ON privacy_events(occurred_at)")
            try database.setUserVersion(2)
        }
    }

    private static func createInitialSchema(_ database: SQLiteDatabase) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE spans (
                    id INTEGER PRIMARY KEY,
                    started_at REAL NOT NULL,
                    ended_at REAL NOT NULL,
                    bundle_id TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    window_title TEXT,
                    document_path TEXT,
                    url TEXT
                )
                """)
            try database.execute("CREATE INDEX spans_started_at ON spans(started_at)")
            try database.execute("CREATE INDEX spans_ended_at ON spans(ended_at)")
            try database.execute("""
                CREATE TABLE insights (
                    id INTEGER PRIMARY KEY,
                    minute_start REAL NOT NULL UNIQUE,
                    bundle_id TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    window_title TEXT,
                    document_path TEXT,
                    url TEXT,
                    summary TEXT NOT NULL,
                    task TEXT NOT NULL,
                    project TEXT,
                    category TEXT NOT NULL,
                    is_reused INTEGER NOT NULL,
                    model TEXT NOT NULL
                )
                """)
            try database.execute("""
                CREATE TABLE day_summaries (
                    day TEXT PRIMARY KEY,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """)
            try database.setUserVersion(1)
        }
    }

    // MARK: Spans

    /// Extends the open span while the context stays the same; a switch starts the next span where the last one ended.
    public func recordPresence(_ context: ActivityContext, at now: Date, maxGap: TimeInterval) throws {
        let key = context.continuityKey
        var start = now
        if let open = openSpan, now.timeIntervalSince(open.lastSeen) <= maxGap {
            if open.continuityKey == key {
                try extendSpan(id: open.id, to: now)
                openSpan?.lastSeen = now
                return
            }
            start = open.lastSeen
        }
        let id = try startSpan(context, at: start, until: now)
        openSpan = (id, key, now)
    }

    public func endPresence() {
        openSpan = nil
    }

    func startSpan(_ context: ActivityContext, at start: Date, until end: Date) throws -> Int64 {
        try database.execute(
            "INSERT INTO spans (started_at, ended_at, bundle_id, app_name, window_title, document_path, url) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)] + Self.contextValues(context)
        )
        return database.lastInsertRowID
    }

    func extendSpan(id: Int64, to end: Date) throws {
        try database.execute("UPDATE spans SET ended_at = ? WHERE id = ?", [.real(end.timeIntervalSince1970), .integer(id)])
    }

    public func spans(overlapping interval: DateInterval) throws -> [ActivitySpan] {
        try database.query(
            "SELECT id, started_at, ended_at, bundle_id, app_name, window_title, document_path, url FROM spans WHERE ended_at > ? AND started_at < ? ORDER BY started_at",
            [.real(interval.start.timeIntervalSince1970), .real(interval.end.timeIntervalSince1970)]
        ) { row in
            ActivitySpan(id: row.int(0), start: row.date(1), end: row.date(2), context: Self.context(from: row, startingAt: 3))
        }
    }

    // MARK: Insights

    public func saveInsight(_ insight: Insight) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO insights
                (minute_start, bundle_id, app_name, window_title, document_path, url, summary, task, project, category, is_reused, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.real(insight.minuteStart.timeIntervalSince1970)] + Self.contextValues(insight.context) + [
                .text(insight.summary),
                .text(insight.task),
                .optionalText(insight.project),
                .text(insight.category.rawValue),
                .integer(insight.isReused ? 1 : 0),
                .text(insight.model),
            ]
        )
    }

    public func insights(in interval: DateInterval) throws -> [Insight] {
        try database.query(
            Self.insightSelect + " WHERE minute_start >= ? AND minute_start < ? ORDER BY minute_start",
            [.real(interval.start.timeIntervalSince1970), .real(interval.end.timeIntervalSince1970)],
            map: Self.insight(from:)
        )
    }

    public func latestInsights(limit: Int) throws -> [Insight] {
        let newestFirst = try database.query(
            Self.insightSelect + " ORDER BY minute_start DESC LIMIT ?",
            [.integer(Int64(limit))],
            map: Self.insight(from:)
        )
        return newestFirst.reversed()
    }

    // MARK: Day summaries

    public func daySummary(for day: String) throws -> DaySummary? {
        try database.query("SELECT day, text, created_at FROM day_summaries WHERE day = ?", [.text(day)]) { row in
            DaySummary(day: row.text(0) ?? day, text: row.text(1) ?? "", createdAt: row.date(2))
        }.first
    }

    public func saveDaySummary(_ summary: DaySummary) throws {
        try database.execute(
            "INSERT OR REPLACE INTO day_summaries (day, text, created_at) VALUES (?, ?, ?)",
            [.text(summary.day), .text(summary.text), .real(summary.createdAt.timeIntervalSince1970)]
        )
    }

    // MARK: Privacy events

    public func logPrivacyEvent(_ event: PrivacyEvent) throws {
        try database.execute(
            "INSERT INTO privacy_events (occurred_at, bundle_id, app_name, reasons, detail) VALUES (?, ?, ?, ?, ?)",
            [
                .real(event.occurredAt.timeIntervalSince1970),
                .text(event.bundleID),
                .text(event.appName),
                .text(event.reasons.map(\.rawValue).joined(separator: ",")),
                .optionalText(event.detail),
            ]
        )
    }

    public func latestPrivacyEvents(limit: Int) throws -> [PrivacyEvent] {
        try database.query(
            "SELECT id, occurred_at, bundle_id, app_name, reasons, detail FROM privacy_events ORDER BY occurred_at DESC LIMIT ?",
            [.integer(Int64(limit))]
        ) { row in
            PrivacyEvent(
                id: row.int(0),
                occurredAt: row.date(1),
                bundleID: row.text(2) ?? "",
                appName: row.text(3) ?? "",
                reasons: (row.text(4) ?? "").split(separator: ",").compactMap { ProtectionReason(rawValue: String($0)) },
                detail: row.text(5)
            )
        }
    }

    public func deleteAll() throws {
        openSpan = nil
        try database.transaction {
            try database.execute("DELETE FROM privacy_events")
            try database.execute("DELETE FROM spans")
            try database.execute("DELETE FROM insights")
            try database.execute("DELETE FROM day_summaries")
        }
    }

    // MARK: Row mapping

    private static let insightSelect = """
        SELECT id, minute_start, bundle_id, app_name, window_title, document_path, url, summary, task, project, category, is_reused, model
        FROM insights
        """

    private static func insight(from row: SQLiteDatabase.Row) -> Insight {
        Insight(
            id: row.int(0),
            minuteStart: row.date(1),
            context: context(from: row, startingAt: 2),
            summary: row.text(7) ?? "",
            task: row.text(8) ?? "",
            project: row.text(9),
            category: ActivityCategory(lenient: row.text(10)),
            isReused: row.int(11) != 0,
            model: row.text(12) ?? ""
        )
    }

    private static func contextValues(_ context: ActivityContext) -> [SQLValue] {
        [
            .text(context.bundleID),
            .text(context.appName),
            .optionalText(context.windowTitle),
            .optionalText(context.documentPath),
            .optionalText(context.url),
        ]
    }

    private static func context(from row: SQLiteDatabase.Row, startingAt column: Int32) -> ActivityContext {
        ActivityContext(
            bundleID: row.text(column) ?? "",
            appName: row.text(column + 1) ?? "",
            windowTitle: row.text(column + 2),
            documentPath: row.text(column + 3),
            url: row.text(column + 4)
        )
    }
}
