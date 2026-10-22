import CoreGraphics
import Foundation
import MindfulHoursCore

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
    private static let minimumActiveSecondsPerMinute: TimeInterval = 15
    private static let similarScreenMaxDistance = 5
    private static let maxInsightReuseAge: TimeInterval = 10 * 60
    private static let recentInsightCount = 6
    private static let repeatedPrivacyEventInterval: TimeInterval = 5 * 60

    @Published private(set) var trackingStatus: TrackingStatus = .away
    @Published private(set) var analysisStatus: AnalysisStatus = .ready
    @Published private(set) var currentContext: ActivityContext?
    @Published private(set) var currentProtection: [ProtectionReason] = []
    @Published private(set) var dataRevision = 0
    /// Vision's text model can take ~30 s to load after a reboot; screenshots wait for it so none skip the scan.
    @Published private(set) var isTextScanReady = false

    let store: ActivityStore
    private let probe = ContextProbe()
    private let presence = PresenceMonitor()

    private var minuteStart = Date.now.flooredToMinute
    private var minute = MinuteAccumulator()
    private var snapshotsByContinuityKey: [String: (snapshot: WindowSnapshot, page: CapturedPage)] = [:]
    private var protectionByContinuityKey: [String: Set<ProtectionReason>] = [:]
    private var lastLoggedProtection: (bundleID: String, reasons: Set<ProtectionReason>, at: Date)?
    private var lastSnapshotAt = Date.distantPast
    /// Bumped whenever any protection is seen, so a capture that overlapped one can be discarded.
    private var protectionEpoch = 0
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
        Task {
            await WindowCapture.warmUpTextRecognition()
            isTextScanReady = true
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(at: .now)
                try? await Task.sleep(for: .seconds(AppSettings.load().sampleInterval))
            }
        }
    }

    /// Fills in the current app and a ready text scan without recording anything, so window snapshots show a live popup.
    func prepareForSnapshot() async {
        await WindowCapture.warmUpTextRecognition()
        isTextScanReady = true
        let settings = AppSettings.load()
        analysisStatus = settings.aiEnabled && settings.llm != nil ? .ready : .disabled
        guard let front = probe.frontmostApp(), !PresenceMonitor.isLockScreen(front.context.bundleID) else { return }
        let verdict = settings.privacy.evaluate(front.context, signals: front.signals)
        trackingStatus = .tracking
        currentContext = verdict.hidesMetadata ? front.context.redacted : front.context
        currentProtection = verdict.sortedReasons
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

        guard presence.isPresent(idleThreshold: settings.idleThreshold),
              let front = probe.frontmostApp(),
              !PresenceMonitor.isLockScreen(front.context.bundleID) else {
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
        minute.record(context, seconds: settings.sampleInterval)
        recordSpan(context, at: now, maxGap: settings.sampleInterval * 2.5)
        noteProtection(verdict.reasons, for: context, detail: verdict.matchedRule, at: now)

        let mayCapture = settings.aiEnabled && settings.screenshotsEnabled && verdict.allowsScreenshot
            && (isTextScanReady || !settings.scansScreenshotText)
        // Small tolerance so a 25 s interval isn't pushed to 30 s by 5 s ticks landing a hair early.
        let isScreenshotDue = now.timeIntervalSince(lastSnapshotAt) >= settings.screenshotInterval - 0.5
        if mayCapture, let windowID = front.windowID, !isCapturing, isScreenshotDue {
            captureSnapshot(windowID: windowID, context: context, settings: settings, at: now)
        }
    }

    private func noteProtection(_ reasons: Set<ProtectionReason>, for context: ActivityContext, detail: String?, at now: Date) {
        guard !reasons.isEmpty else { return }
        protectionEpoch += 1
        protectionByContinuityKey[context.continuityKey, default: []].formUnion(reasons)

        if let last = lastLoggedProtection, last.bundleID == context.bundleID, last.reasons == reasons,
           now.timeIntervalSince(last.at) < Self.repeatedPrivacyEventInterval {
            return
        }
        lastLoggedProtection = (context.bundleID, reasons, now)
        let event = PrivacyEvent(occurredAt: now, bundleID: context.bundleID, appName: context.appName, reasons: reasons.sorted(), detail: detail)
        Task {
            do {
                try await store.logPrivacyEvent(event)
            } catch {
                NSLog("MindfulHours: failed to log privacy event: \(error)")
            }
        }
    }

    private func recordSpan(_ context: ActivityContext, at now: Date, maxGap: TimeInterval) {
        Task {
            do {
                try await store.recordPresence(context, at: now, maxGap: maxGap)
            } catch {
                NSLog("MindfulHours: failed to record span: \(error)")
            }
        }
    }

    private func endSpan() {
        Task { await store.endPresence() }
    }

    private func captureSnapshot(windowID: CGWindowID, context: ActivityContext, settings: AppSettings, at now: Date) {
        isCapturing = true
        lastSnapshotAt = now
        let captureMinute = minuteStart
        let epochAtStart = protectionEpoch
        Task {
            defer { isCapturing = false }
            do {
                switch try await WindowCapture.capture(windowID: windowID, scanningText: settings.scansScreenshotText) {
                case .captured(let snapshot):
                    guard minuteStart == captureMinute,
                          isStillClear(windowID: windowID, context: context, settings: settings),
                          protectionEpoch == epochAtStart else { return }
                    let page = CapturedPage(continuityKey: context.continuityKey, bundleID: context.bundleID, capturedAt: now)
                    snapshotsByContinuityKey[context.continuityKey] = (snapshot, page)
                case .withheld(let findings):
                    snapshotsByContinuityKey[context.continuityKey] = nil
                    let detail = findings.map(\.rawValue).sorted().joined(separator: ", ")
                    noteProtection([.sensitiveText], for: context, detail: detail, at: now)
                case .unavailable:
                    break
                }
            } catch {
                NSLog("MindfulHours: screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    /// The window may have changed (tab switch, password field focus) while the capture and text scan ran.
    private func isStillClear(windowID: CGWindowID, context: ActivityContext, settings: AppSettings) -> Bool {
        guard let front = probe.frontmostApp(), front.windowID == windowID else { return false }
        let verdict = settings.privacy.evaluate(front.context, signals: front.signals)
        noteProtection(verdict.reasons, for: verdict.hidesMetadata ? front.context.redacted : front.context, detail: verdict.matchedRule, at: .now)
        // A different page (tab switch, navigation) means the image may show either page, so it can't be trusted.
        return verdict.allowsScreenshot && front.context.continuityKey == context.continuityKey
    }

    private func rollMinute(at now: Date, settings: AppSettings) {
        let currentMinute = now.flooredToMinute
        guard currentMinute > minuteStart else { return }
        let finishedMinute = minuteStart
        let accumulated = minute
        let snapshots = snapshotsByContinuityKey
        let protection = protectionByContinuityKey
        minuteStart = currentMinute
        minute.reset()
        snapshotsByContinuityKey.removeAll()
        protectionByContinuityKey.removeAll()

        guard accumulated.activeSeconds >= Self.minimumActiveSecondsPerMinute, let context = accumulated.dominantContext else { return }
        let pageProtection = protection[context.continuityKey] ?? []
        let chosenPage = ScreenshotSelection.page(
            describing: context,
            from: snapshots.values.map(\.page),
            protectedKeys: Set(protection.keys)
        )
        let snapshot = chosenPage.flatMap { snapshots[$0.continuityKey]?.snapshot }
        Task {
            await describe(
                minute: finishedMinute, context: context, accumulated: accumulated, snapshot: snapshot,
                hidesContext: pageProtection.contains(where: \.hidesMetadata),
                withheldBecause: pageProtection, settings: settings
            )
        }
    }

    private func describe(
        minute: Date,
        context: ActivityContext,
        accumulated: MinuteAccumulator,
        snapshot: WindowSnapshot?,
        hidesContext: Bool,
        withheldBecause: Set<ProtectionReason>,
        settings: AppSettings
    ) async {
        if hidesContext {
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
            screenshotWithheldBecause: snapshot == nil ? withheldBecause.sorted() : []
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
            dataRevision += 1
        } catch {
            NSLog("MindfulHours: failed to save insight: \(error)")
        }
    }
}

extension Date {
    var flooredToMinute: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
