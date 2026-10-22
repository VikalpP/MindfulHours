import AppKit
import ApplicationServices
import ServiceManagement
import MindfulHoursCore

struct PermissionState: Equatable {
    var accessibility: Bool
    var screenRecording: Bool

    static var current: PermissionState {
        PermissionState(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    var allGranted: Bool { accessibility && screenRecording }
}

struct DayActivity {
    var interval: DateInterval
    var blocks: [ActivityBlock] = []
    var appUsage: [AppUsage] = []
    var categoryUsage: [CategoryUsage] = []
    var activeSeconds: TimeInterval = 0
    var summary: DaySummary?

    var dayKey: String { Timeline.dayKey(for: interval.start) }
}

@MainActor
final class AppModel: ObservableObject {
    let store: ActivityStore
    let recorder: ActivityRecorder
    @Published private(set) var permissions = PermissionState.current

    init() {
        AppSettings.registerDefaults()
        do {
            store = try ActivityStore()
        } catch {
            fatalError("MindfulHours cannot open its database at \(ActivityStore.defaultURL.path): \(error)")
        }
        recorder = ActivityRecorder(store: store)
    }

    func startTracking() {
        recorder.start()
        if !permissions.allGranted { requestMissingPermissions() }
    }

    func refreshPermissions() {
        permissions = .current
    }

    func requestMissingPermissions() {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    func openPrivacySettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func activity(for day: Date) async -> DayActivity {
        let interval = Timeline.dayInterval(containing: day)
        var activity = DayActivity(interval: interval)
        do {
            let insights = try await store.insights(in: interval)
            let spans = try await store.spans(overlapping: interval)
            activity.blocks = Timeline.blocks(from: insights)
            activity.appUsage = Timeline.appUsage(from: spans, within: interval)
            activity.activeSeconds = activity.appUsage.reduce(0) { $0 + $1.seconds }
            activity.categoryUsage = Timeline.categoryUsage(from: insights)
            activity.summary = try await store.daySummary(for: activity.dayKey)
        } catch {
            NSLog("MindfulHours: failed to load day: \(error)")
        }
        return activity
    }

    func summarize(_ activity: DayActivity) async throws -> DaySummary {
        guard let llm = AppSettings.load().llm else { throw LLMError.notConfigured }
        let text = try await LLMClient(configuration: llm).complete(
            system: Prompts.daySystem,
            user: Prompts.dayUser(day: activity.dayKey, blocks: activity.blocks, appUsage: activity.appUsage),
            maxTokens: 4000
        )
        let summary = DaySummary(day: activity.dayKey, text: text, createdAt: .now)
        try await store.saveDaySummary(summary)
        return summary
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MindfulHours: login item change failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        cache[bundleID] = icon
        return icon
    }
}
