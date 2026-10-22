import Foundation
import ActivityTrackerCore

enum TrackingStatus: Equatable {
    case tracking
    case away
    case paused(until: Date?)
}

enum AnalysisStatus: Equatable {
    case disabled
    case ready
    case analyzing
    case failed(String)
}

@MainActor
final class ActivityRecorder: ObservableObject {
    static let sampleInterval: TimeInterval = 5
    private static let snapshotInterval: TimeInterval = 25
    private static let minimumActiveSecondsPerMinute: TimeInterval = 15
    private static let similarScreenMaxDistance = 5
    private static let maxInsightReuseAge: TimeInterval = 10 * 60
    private static let recentInsightCount = 6

    @Published private(set) var trackingStatus: TrackingStatus = .away
    @Published private(set) var analysisStatus: AnalysisStatus = .ready
    @Published private(set) var currentContext: ActivityContext?
    @Published private(set) var latestInsight: Insight?
    @Published private(set) var dataRevision = 0

    let store: ActivityStore
    private let probe = ContextProbe()
    private let presence = PresenceMonitor()

    private var minuteStart = Date.now.flooredToMinute
    private var minute = MinuteAccumulator()
    private var snapshotsByBundleID: [String: WindowSnapshot] = [:]
    private var lastSnapshotAt = Date.distantPast
    private var isCapturing = false

    private var lastAnalyzed: (continuityKey: String, fingerprint: ImageFingerprint?, insight: Insight, analyzedAt: Date)?
    private var isAnalyzing = false
    private var consecutiveFailures = 0
    private var retryAfter = Date.distantPast
    private var loop: Task<Void, Never>?

    init(store: ActivityStore) {
        self.store = store
    }

    func start() {
        guard loop == nil else { return }
        Task { latestInsight = try? await store.latestInsights(limit: 1).last }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(at: .now)
                try? await Task.sleep(for: .seconds(Self.sampleInterval))
            }
        }
    }

    func pause(for duration: TimeInterval?) {
        trackingStatus = .paused(until: duration.map { Date.now.addingTimeInterval($0) })
        endSpan()
        currentContext = nil
    }

    func resume() {
        trackingStatus = .away
        tick(at: .now)
    }

    private func tick(at now: Date) {
        let settings = AppSettings.load()
        if !settings.aiEnabled || settings.llm == nil {
            analysisStatus = .disabled
        } else if analysisStatus == .disabled {
            analysisStatus = .ready
        }

        rollMinute(at: now, settings: settings)

        if case .paused(let until) = trackingStatus {
            guard let until, now >= until else { return }
            trackingStatus = .away
        }

        guard presence.isPresent(idleThreshold: settings.idleThreshold), let front = probe.frontmostApp() else {
            trackingStatus = .away
            endSpan()
            currentContext = nil
            return
        }

        let isExcluded = settings.excludedBundleIDs.contains(front.context.bundleID)
        let context = isExcluded ? front.context.redacted : front.context
        trackingStatus = .tracking
        currentContext = context
        minute.record(context, seconds: Self.sampleInterval)
        recordSpan(context, at: now)

        let mayCapture = settings.aiEnabled && settings.screenshotsEnabled && !isExcluded
        if mayCapture, !isCapturing, now.timeIntervalSince(lastSnapshotAt) >= Self.snapshotInterval {
            captureSnapshot(of: front, at: now)
        }
    }

    private func recordSpan(_ context: ActivityContext, at now: Date) {
        Task {
            do {
                try await store.recordPresence(context, at: now, maxGap: Self.sampleInterval * 2.5)
            } catch {
                NSLog("ActivityTracker: failed to record span: \(error)")
            }
        }
    }

    private func endSpan() {
        Task { await store.endPresence() }
    }

    private func captureSnapshot(of front: FrontmostApp, at now: Date) {
        isCapturing = true
        lastSnapshotAt = now
        Task {
            defer { isCapturing = false }
            do {
                if let snapshot = try await WindowCapture.captureFrontWindow(of: front.processID) {
                    snapshotsByBundleID[front.context.bundleID] = snapshot
                }
            } catch {
                NSLog("ActivityTracker: screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func rollMinute(at now: Date, settings: AppSettings) {
        let currentMinute = now.flooredToMinute
        guard currentMinute > minuteStart else { return }
        let finishedMinute = minuteStart
        let accumulated = minute
        let snapshots = snapshotsByBundleID
        minuteStart = currentMinute
        minute.reset()
        snapshotsByBundleID.removeAll()

        guard accumulated.activeSeconds >= Self.minimumActiveSecondsPerMinute, let context = accumulated.dominantContext else { return }
        Task {
            await describe(minute: finishedMinute, context: context, accumulated: accumulated, snapshot: snapshots[context.bundleID], settings: settings)
        }
    }

    private func describe(minute: Date, context: ActivityContext, accumulated: MinuteAccumulator, snapshot: WindowSnapshot?, settings: AppSettings) async {
        let recent = (try? await store.latestInsights(limit: Self.recentInsightCount)) ?? []

        if let lastAnalyzed, isUnchanged(context: context, snapshot: snapshot, since: lastAnalyzed) {
            await save(lastAnalyzed.insight.reused(for: minute))
            return
        }

        let canUseAI = settings.aiEnabled && !settings.excludedBundleIDs.contains(context.bundleID) && !isAnalyzing && Date.now >= retryAfter
        guard canUseAI, let llm = settings.llm else {
            await save(.fromMetadata(minuteStart: minute, context: context, previous: recent.last))
            return
        }

        let observation = MinuteObservation(
            minuteStart: minute,
            context: context,
            secondsByApp: accumulated.secondsByApp,
            recentInsights: recent.filter { !$0.isReused && !settings.excludedBundleIDs.contains($0.context.bundleID) },
            hasScreenshot: snapshot != nil
        )

        isAnalyzing = true
        analysisStatus = .analyzing
        defer { isAnalyzing = false }

        do {
            let reply = try await LLMClient(configuration: llm).complete(
                system: Prompts.minuteSystem,
                user: Prompts.minuteUser(observation),
                imageJPEG: snapshot?.jpeg,
                reasoningEffort: "none"
            )
            guard let payload = Prompts.parseInsight(reply) else {
                throw LLMError.unparseableReply(reply)
            }
            let insight = Insight(
                minuteStart: minute, context: context, summary: payload.summary, task: payload.task,
                project: payload.project, category: payload.category, isReused: false, model: llm.model
            )
            lastAnalyzed = (context.continuityKey, snapshot?.fingerprint, insight, Date.now)
            consecutiveFailures = 0
            analysisStatus = .ready
            await save(insight)
        } catch {
            consecutiveFailures += 1
            retryAfter = Date.now.addingTimeInterval(min(60 * pow(2, Double(consecutiveFailures - 1)), 15 * 60))
            analysisStatus = .failed(error.localizedDescription)
            await save(.fromMetadata(minuteStart: minute, context: context, previous: recent.last))
        }
    }

    private func isUnchanged(
        context: ActivityContext,
        snapshot: WindowSnapshot?,
        since last: (continuityKey: String, fingerprint: ImageFingerprint?, insight: Insight, analyzedAt: Date)
    ) -> Bool {
        guard last.continuityKey == context.continuityKey, Date.now.timeIntervalSince(last.analyzedAt) < Self.maxInsightReuseAge else { return false }
        switch (snapshot?.fingerprint, last.fingerprint) {
        case let (current?, previous?): return current.distance(to: previous) <= Self.similarScreenMaxDistance
        case (nil, nil): return true
        default: return false
        }
    }

    private func save(_ insight: Insight) async {
        do {
            try await store.saveInsight(insight)
            latestInsight = insight
            dataRevision += 1
        } catch {
            NSLog("ActivityTracker: failed to save insight: \(error)")
        }
    }
}

extension Date {
    var flooredToMinute: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
