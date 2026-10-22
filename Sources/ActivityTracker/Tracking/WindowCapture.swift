import AppKit
import ScreenCaptureKit
import Vision
import ActivityTrackerCore

struct WindowSnapshot: Sendable {
    let jpeg: Data
    let fingerprint: ImageFingerprint
}

enum CaptureOutcome: Sendable {
    case captured(WindowSnapshot)
    case withheld(Set<SensitiveTextDetector.Finding>)
    case unavailable
}

@MainActor
enum WindowCapture {
    static let maxLongSide: CGFloat = 1440

    static func capture(windowID: CGWindowID, scanningText: Bool) async throws -> CaptureOutcome {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return .unavailable }

        let scale = min(backingScale, maxLongSide / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        if scanningText {
            let findings = SensitiveTextDetector.findings(in: try await recognizedLines(in: image))
            if !findings.isEmpty { return .withheld(findings) }
        }
        guard let fingerprint = ImageFingerprint(image: image), let jpeg = jpegData(from: image) else { return .unavailable }
        return .captured(WindowSnapshot(jpeg: jpeg, fingerprint: fingerprint))
    }

    /// Runs on-device; nothing leaves the Mac.
    private nonisolated static func recognizedLines(in image: CGImage) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private static var backingScale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
    }

    private static func jpegData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}
