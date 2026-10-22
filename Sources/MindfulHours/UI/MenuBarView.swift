import SwiftUI
import MindfulHoursCore

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: ActivityRecorder
    @Environment(\.openWindow) private var openWindow
    @State private var today: DayActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.permissions.allGranted { permissionsBanner }
            nowSection
            if let today { todaySection(today) }
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
        VStack(alignment: .leading, spacing: 6) {
            if let context = recorder.currentContext {
                HStack(spacing: 8) {
                    AppIconView(bundleID: context.bundleID, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.appName).font(.callout.bold())
                        if let title = context.windowTitle {
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !recorder.isTextScanReady {
                Label("Preparing on-device text scan — screenshots start when ready", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !recorder.currentProtection.isEmpty {
                Label("Not captured: \(recorder.currentProtection.map(\.label).joined(separator: ", "))", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func todaySection(_ day: DayActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today").font(.subheadline.bold())
                Spacer()
                Text("\(Timeline.formatDuration(day.activeSeconds)) active").font(.caption).foregroundStyle(.secondary)
            }
            if !day.categoryUsage.isEmpty { CategoryBar(usage: day.categoryUsage) }
            ForEach(day.blocks.suffix(5).reversed()) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TimeText.clock(block.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                    Circle().fill(block.category.color).frame(width: 6, height: 6)
                    Text(block.task).font(.callout).lineLimit(1)
                    Spacer()
                    Text(Timeline.formatDuration(block.duration)).font(.caption).foregroundStyle(.secondary)
                }
            }
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
