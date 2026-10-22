import AppKit
import ScreenCaptureKit
import ActivityTrackerCore

struct WindowSnapshot: Sendable {
    let jpeg: Data
    let fingerprint: ImageFingerprint
}

@MainActor
enum WindowCapture {
    static let maxLongSide: CGFloat = 1440

    static func captureFrontWindow(of processID: pid_t) async throws -> WindowSnapshot? {
        guard let windowID = frontWindowID(of: processID) else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

        let scale = min(backingScale, maxLongSide / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let fingerprint = ImageFingerprint(image: image), let jpeg = jpegData(from: image) else { return nil }
        return WindowSnapshot(jpeg: jpeg, fingerprint: fingerprint)
    }

    /// CGWindowList is ordered front-to-back, which ScreenCaptureKit's window list does not guarantee.
    private static func frontWindowID(of processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == processID
                && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 80
        }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    private static var backingScale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
    }

    private static func jpegData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}
