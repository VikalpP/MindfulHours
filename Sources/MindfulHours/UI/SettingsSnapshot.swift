import AppKit
import SwiftUI

/// `MindfulHours --snapshot-settings <file.png> [--appearance light|dark] [--scale 2]`
struct SnapshotRequest {
    let outputPath: String
    let appearance: NSAppearance.Name?
    let scale: CGFloat
    let width: CGFloat = 600

    init?(arguments: [String]) {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let path = value(after: "--snapshot-settings") else { return nil }
        outputPath = (path as NSString).expandingTildeInPath
        appearance = switch value(after: "--appearance") {
        case "dark": .darkAqua
        case "light": .aqua
        default: nil
        }
        scale = value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 2
    }
}

enum SnapshotError: Error {
    case renderFailed
}

/// Renders the whole Settings form at its full content height, which the system screenshot tool can't do for a scrolling window.
@MainActor
enum SettingsSnapshot {
    static func render(model: AppModel, request: SnapshotRequest) throws {
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: request.width, height: 2_000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = request.appearance.flatMap(NSAppearance.init(named:))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(for: 1.0)

        if let scrollView = hosting.firstDescendant(ofType: NSScrollView.self), let document = scrollView.documentView {
            let insets = scrollView.contentInsets
            window.setContentSize(NSSize(width: request.width, height: ceil(document.frame.height + insets.top + insets.bottom)))
            settle(for: 0.5)
        }

        let bounds = hosting.bounds
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * request.scale), pixelsHigh: Int(bounds.height * request.scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw SnapshotError.renderFailed }
        bitmap.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.renderFailed }
        try png.write(to: URL(fileURLWithPath: request.outputPath))
    }

    private static func settle(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
