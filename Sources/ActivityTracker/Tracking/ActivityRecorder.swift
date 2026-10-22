import CoreGraphics
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
    @Published private(set) var currentProtection: [ProtectionReason] = []
    @Published private(set) var latestInsight: Insight?
    @Published private(set) var dataRevision = 0

    let store: ActivityStore
    private let probe = ContextProbe()
    private let presence = PresenceMonitor()

    private var minuteStart = Date.now.flooredToMinute
    private var minute = MinuteAccumulator()
    private var snapshotsByBundleID: [String: WindowSnapshot] = [:]
    private var protectionByContinuityKey: [String: Set<ProtectionReason>] = [:]
    private var lastLoggedProtection: (bundleID: String, reasons: Set<ProtectionReason>)?
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
        currentProtection = []
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
            currentProtection = []
            return
        }

        let verdict = settings.privacy.evaluate(front.context, signals: front.signals)
        let context = verdict.hidesMetadata ? front.context.redacted : front.context
        trackingStatus = .tracking
        currentContext = context
        currentProtection = verdict.sortedReasons
        minute.record(context, seconds: Self.sampleInterval)
        recordSpan(context, at: now)
        noteProtection(verdict.reasons, for: context, detail: verdict.matchedRule, at: now)

        let mayCapture = settings.aiEnabled && settings.screenshotsEnabled && verdict.allowsScreenshot
        if mayCapture, let windowID = front.windowID, !isCapturing, now.timeIntervalSince(lastSnapshotAt) >= Self.snapshotInterval {
            captureSnapshot(windowID: windowID, context: context, scanningText: settings.scansScreenshotText, at: now)
        }
    }

    private func noteProtection(_ reasons: Set<ProtectionReason>, for context: ActivityContext, detail: String?, at now: Date) {
        guard !reasons.isEmpty else {
            if lastLoggedProtection?.bundleID == context.bundleID { lastLoggedProtection = nil }
            return
        }
        protectionByContinuityKey[context.continuityKey, default: []].formUnion(reasons)

        guard lastLoggedProtection?.bundleID != context.bundleID || lastLoggedProtection?.reasons != reasons else { return }
        lastLoggedProtection = (context.bundleID, reasons)
        let event = PrivacyEvent(occurredAt: now, bundleID: context.bundleID, appName: context.appName, reasons: reasons.sorted(), detail: detail)
        Task {
            do {
                try await store.logPrivacyEvent(event)
            } catch {
                NSLog("ActivityTracker: failed to log privacy event: \(error)")
            }
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

    private func captureSnapshot(windowID: CGWindowID, context: ActivityContext, scanningText: Bool, at now: Date) {
        isCapturing = true
        lastSnapshotAt = now
        Task {
            defer { isCapturing = false }
            do {
                switch try await WindowCapture.capture(windowID: windowID, scanningText: scanningText) {
                case .captured(let snapshot):
                    snapshotsByBundleID[context.bundleID] = snapshot
                case .withheld(let findings):
                    snapshotsByBundleID[context.bundleID] = nil
                    let detail = findings.map(\.rawValue).sorted().joined(separator: ", ")
                    noteProtection([.sensitiveText], for: context, detail: detail, at: now)
                case .unavailable:
                    break
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
        let protection = protectionByContinuityKey
        minuteStart = currentMinute
        minute.reset()
        snapshotsByBundleID.removeAll()
        protectionByContinuityKey.removeAll()

        guard accumulated.activeSeconds >= Self.minimumActiveSecondsPerMinute, let context = accumulated.dominantContext else { return }
        let reasons = protection[context.continuityKey] ?? []
        // Any protection seen during the minute withholds even a screenshot taken before it appeared.
        let snapshot = reasons.isEmpty ? snapshots[context.bundleID] : nil
        Task {
            await describe(minute: finishedMinute, context: context, accumulated: accumulated, snapshot: snapshot, protection: reasons, settings: settings)
        }
    }

    private func describe(
        minute: Date,
        context: ActivityContext,
        accumulated: MinuteAccumulator,
        snapshot: WindowSnapshot?,
        protection: Set<ProtectionReason>,
        settings: AppSettings
    ) async {
        if protection.contains(where: \.hidesMetadata) {
            await save(.privateContent(minuteStart: minute, context: context))
            return
        }

        let recent = (try? await store.latestInsights(limit: Self.recentInsightCount)) ?? []

        if let lastAnalyzed, isUnchanged(context: context, snapshot: snapshot, since: lastAnalyzed) {
            await save(lastAnalyzed.insight.reused(for: minute))
            return
        }

        let canUseAI = settings.aiEnabled && !isAnalyzing && Date.now >= retryAfter
        guard canUseAI, let llm = settings.llm else {
            await save(.fromMetadata(minuteStart: minute, context: context, previous: recent.last))
            return
        }

        let observation = MinuteObservation(
            minuteStart: minute,
            context: context,
            secondsByApp: accumulated.secondsByApp,
            recentInsights: recent.filter { !$0.isReused && $0.task != Insight.privateTask },
            hasScreenshot: snapshot != nil,
            screenshotWithheldBecause: protection.sorted()
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
