import AppKit
import ScreenCaptureKit
import SwiftUI

/// `MindfulHours --snapshot-settings|--snapshot-timeline <file.png> [--appearance light|dark] [--no-frame]`
struct SnapshotRequest {
    enum Target {
        case settings
        case timeline

        var title: String {
            switch self {
            case .settings: "MindfulHours Settings"
            case .timeline: "Activity Timeline"
            }
        }

        var width: CGFloat {
            switch self {
            case .settings: 600
            case .timeline: 1040
            }
        }
    }

    let target: Target
    let outputPath: String
    let appearance: NSAppearance.Name?
    let includesWindowFrame: Bool

    init?(arguments: [String]) {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let path = value(after: "--snapshot-settings") {
            target = .settings
            outputPath = (path as NSString).expandingTildeInPath
        } else if let path = value(after: "--snapshot-timeline") {
            target = .timeline
            outputPath = (path as NSString).expandingTildeInPath
        } else {
            return nil
        }
        appearance = switch value(after: "--appearance") {
        case "dark": .darkAqua
        case "light": .aqua
        default: nil
        }
        includesWindowFrame = !arguments.contains("--no-frame")
    }
}

enum SnapshotError: Error {
    case windowNotCapturable
    case encodingFailed
}

/// Renders a window at its full content height, which the system screenshot tool can't do for a scrolling window.
/// With the frame, the window server's own title bar, toolbar, corners and shadow are captured, matching a
/// ⌘⇧4-Space window screenshot.
@MainActor
enum AppWindowSnapshot {
    static func render(model: AppModel, request: SnapshotRequest) async throws {
        let controller = switch request.target {
        case .settings: fixedSizeHost(SettingsView(model: model))
        case .timeline: fixedSizeHost(TimelineView(model: model, recorder: model.recorder))
        }
        let window = UnconstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: request.target.width, height: 2_000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentViewController = controller
        window.title = request.target.title
        window.isReleasedWhenClosed = false
        window.appearance = request.appearance.flatMap(NSAppearance.init(named:))
        window.setContentSize(NSSize(width: request.target.width, height: 2_000))
        let hosting = controller.view
        // ScreenCaptureKit only captures windows that touch a display, so leave a 1-point sliver at the right edge;
        // ignoring the global clip then captures the rest of the window that hangs off-screen.
        let screen = NSScreen.main?.frame ?? .zero
        window.setFrameOrigin(NSPoint(x: screen.maxX - 1, y: screen.minY))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(for: 1.0)

        if let scrollView = hosting.firstDescendant(ofType: NSScrollView.self), let document = scrollView.documentView {
            let insets = scrollView.contentInsets
            window.setContentSize(NSSize(width: request.target.width, height: ceil(document.frame.height + insets.top + insets.bottom)))
            await settle(for: 0.5)
        }

        let image = try await withRetries { try await capture(window, includingFrame: request.includesWindowFrame) }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        try png.write(to: URL(fileURLWithPath: request.outputPath))
    }

    /// Without this the controller resizes the window to the view's ideal size instead of the full-height size set here.
    private static func fixedSizeHost<V: View>(_ view: V) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        return controller
    }

    private static func capture(_ window: NSWindow, includingFrame: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw SnapshotError.windowNotCapturable
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.ignoreShadowsSingleWindow = !includingFrame
        configuration.shouldBeOpaque = false
        configuration.showsCursor = false
        // Capture at true size onto a canvas with room for the shadow, then trim to the shadow's edge;
        // scaling to fit would shrink the window to make room for its own shadow.
        let shadowRoom: CGFloat = includingFrame ? 160 : 0
        configuration.scalesToFit = false
        configuration.width = Int((filter.contentRect.width + shadowRoom) * scale)
        configuration.height = Int((filter.contentRect.height + shadowRoom) * scale)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard !includingFrame else { return trimmingTransparentEdges(of: image) }

        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        let cropTop = Int(titleBarHeight * scale)
        return image.cropping(to: CGRect(x: 0, y: cropTop, width: image.width, height: image.height - cropTop)) ?? image
    }

    private static func trimmingTransparentEdges(of image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? image
    }

    /// ScreenCaptureKit occasionally fails the first capture right after the app is (re)installed.
    private static func withRetries<T>(_ attempts: Int = 3, _ operation: () async throws -> T) async throws -> T {
        for _ in 1..<attempts {
            if let result = try? await operation() { return result }
            await settle(for: 1.0)
        }
        return try await operation()
    }

    private static func settle(for seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Titled windows are normally shrunk to fit the screen; a full-height snapshot needs to be taller than any display.
/// It also always draws as the active window (colored traffic lights), since the snapshot runs while another app is in front.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
