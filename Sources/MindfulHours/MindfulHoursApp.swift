import SwiftUI

enum WindowID {
    static let timeline = "timeline"
    static let settings = "settings"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            Task {
                do {
                    try await AppWindowSnapshot.render(model: model, request: request)
                    print("Wrote \(request.outputPath)")
                } catch {
                    FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return
        }
        model.startTracking()
    }
}

@main
struct MindfulHoursApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, recorder: model.recorder)
        } label: {
            MenuBarLabel(recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)

        Window("Activity Timeline", id: WindowID.timeline) {
            TimelineView(model: model, recorder: model.recorder)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 720)

        Window("MindfulHours Settings", id: WindowID.settings) {
            SettingsView(model: model)
                .frame(minWidth: 560, minHeight: 520)
        }
        .defaultSize(width: 600, height: 780)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var recorder: ActivityRecorder

    var body: some View {
        switch recorder.trackingStatus {
        case .tracking: Image(systemName: recorder.currentProtection.isEmpty ? "record.circle" : "lock.shield")
        case .away: Image(systemName: "moon.zzz")
        case .paused: Image(systemName: "pause.circle")
        }
    }
}
