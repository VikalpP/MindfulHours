import SwiftUI
import MindfulHoursCore

/// Every section keeps a constant height: when the popup resizes while open, macOS doesn't redraw its rounded
/// corners and shadow, leaving square corners and a gap (e.g. when an app without a window title comes to front).
struct MenuBarView: View {
    private static let recentBlockRows = 5

    @ObservedObject var model: AppModel
    @ObservedObject var recorder: ActivityRecorder
    @Environment(\.openWindow) private var openWindow
    @State private var today: DayActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.permissions.allGranted { permissionsBanner }
            nowSection
            todaySection(today ?? DayActivity(interval: Timeline.dayInterval(containing: .now)))
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 360)
        .task(id: recorder.dataRevision) { today = await model.activity(for: .now) }
        .onAppear { model.refreshPermissions() }
    }

    private var header: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.headline)
            statusIndicators
            Spacer()
            analysisBadge
        }
    }

    private var statusColor: Color {
        switch recorder.trackingStatus {
        case .tracking: .green
        case .away: .gray
        case .paused: .orange
        }
    }

    private var statusText: String {
        switch recorder.trackingStatus {
        case .tracking: "Tracking"
        case .away: "Away"
        case .paused(let until?): "Paused until \(TimeText.clock(until))"
        case .paused(nil): "Paused"
        }
    }

    private var statusIndicators: some View {
        HStack(spacing: 6) {
            if !recorder.currentProtection.isEmpty {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .help("Not captured: \(recorder.currentProtection.map(\.label).joined(separator: ", "))")
            }
            if !recorder.isTextScanReady {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                    .help("Preparing on-device text scan; screenshots start when it's ready")
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var analysisBadge: some View {
        switch recorder.analysisStatus {
        case .disabled: Label("AI off", systemImage: "sparkles").foregroundStyle(.secondary)
        case .ready: Label("AI", systemImage: "sparkles").foregroundStyle(.tint)
        case .analyzing: Label("Analyzing", systemImage: "sparkles").foregroundStyle(.tint)
        case .failed(let message): Label("AI error", systemImage: "exclamationmark.triangle").foregroundStyle(.red).help(message)
        }
    }

    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions needed").font(.subheadline.bold())
            if !model.permissions.accessibility {
                Button("Grant Accessibility (window titles)") { model.openPrivacySettings("Privacy_Accessibility") }
            }
            if !model.permissions.screenRecording {
                Button("Grant Screen Recording (in-app context)") { model.openPrivacySettings("Privacy_ScreenCapture") }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nowSection: some View {
        HStack(spacing: 8) {
            if let context = recorder.currentContext {
                AppIconView(bundleID: context.bundleID, size: 22)
            } else {
                Image(systemName: "moon.zzz").font(.title3).foregroundStyle(.secondary).frame(width: 22, height: 22)
            }
            ZStack(alignment: .leading) {
                appNameAndDetail(name: " ", detail: " ").hidden()
                appNameAndDetail(name: recorder.currentContext?.appName ?? "Not tracking right now", detail: nowDetail)
            }
        }
    }

    /// Drawn twice: hidden with placeholders to reserve two lines of height, and on top with the real text,
    /// which the ZStack centers vertically when there's no detail line.
    private func appNameAndDetail(name: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.callout.bold())
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var nowDetail: String? {
        guard let context = recorder.currentContext else { return "Tracking resumes when you're back at your Mac" }
        return context.windowTitle
            ?? context.url.flatMap { URL(string: $0)?.host() }
            ?? context.documentPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private func todaySection(_ day: DayActivity) -> some View {
        let recentBlocks = Array(day.blocks.suffix(Self.recentBlockRows).reversed())
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today").font(.subheadline.bold())
                Spacer()
                Text("\(Timeline.formatDuration(day.activeSeconds)) active").font(.caption).foregroundStyle(.secondary)
            }
            CategoryBar(usage: day.categoryUsage)
            ForEach(0..<Self.recentBlockRows, id: \.self) { index in
                if recentBlocks.indices.contains(index) {
                    blockRow(recentBlocks[index])
                } else if index == 0 {
                    Text("No activity yet today").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(" ").font(.callout)
                }
            }
        }
    }

    private func blockRow(_ block: ActivityBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TimeText.clock(block.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Circle().fill(block.category.color).frame(width: 6, height: 6)
            Text(block.task).font(.callout).lineLimit(1)
            Spacer()
            Text(Timeline.formatDuration(block.duration)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Timeline") { open(WindowID.timeline) }
                .keyboardShortcut("t")
            pauseControl
            Spacer()
            Button { open(WindowID.settings) } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
    }

    @ViewBuilder private var pauseControl: some View {
        if case .paused = recorder.trackingStatus {
            Button("Resume") { recorder.resume() }
        } else {
            Menu("Pause") {
                Button("15 minutes") { recorder.pause(for: 15 * 60) }
                Button("1 hour") { recorder.pause(for: 60 * 60) }
                Button("Until resumed") { recorder.pause(for: nil) }
            }
            .fixedSize()
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}
