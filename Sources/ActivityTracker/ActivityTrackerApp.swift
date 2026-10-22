import SwiftUI

enum WindowID {
    static let timeline = "timeline"
    static let settings = "settings"
}

@main
struct ActivityTrackerApp: App {
    @StateObject private var model = AppModel()

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

        Window("Activity Tracker Settings", id: WindowID.settings) {
            SettingsView(model: model)
                .frame(width: 560)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var recorder: ActivityRecorder

    var body: some View {
        switch recorder.trackingStatus {
        case .tracking: Image(systemName: "record.circle")
        case .away: Image(systemName: "moon.zzz")
        case .paused: Image(systemName: "pause.circle")
        }
    }
}
