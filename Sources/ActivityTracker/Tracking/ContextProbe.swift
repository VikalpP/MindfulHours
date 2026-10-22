import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ActivityTrackerCore

struct FrontmostApp {
    let processID: pid_t
    let windowID: CGWindowID?
    let context: ActivityContext
    let signals: PrivacySignals
}

@MainActor
final class ContextProbe {
    private static let safariBundleIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private let browser = BrowserTabReader()

    func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let application = AXUIElement.application(app.processIdentifier)
        let window = application.element(kAXFocusedWindowAttribute)
        let frontWindow = FrontWindow.lookup(processID: app.processIdentifier)
        let tab = browser.activeTab(bundleID: bundleID)

        let context = ActivityContext(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: window?.title.flatMap(nonEmpty),
            documentPath: window?.string(kAXDocumentAttribute).flatMap(Self.filePath(fromDocument:)),
            url: tab?.url
        )
        let signals = PrivacySignals(
            isSecureInputActive: IsSecureEventInputEnabled(),
            isFocusedElementSecure: application.element(kAXFocusedUIElementAttribute)?.string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole,
            isWindowCaptureBlocked: frontWindow?.blocksCapture ?? false,
            isPrivateWindow: (tab?.isPrivate ?? false) || (Self.safariBundleIDs.contains(bundleID) && isSafariWindowPrivate(application))
        )
        return FrontmostApp(processID: app.processIdentifier, windowID: frontWindow?.id, context: context, signals: signals)
    }

    /// Safari exposes no scripting property for this; its Window menu offers "Move Tab to New Private Window" only in private windows.
    private func isSafariWindowPrivate(_ application: AXUIElement) -> Bool {
        guard let menuBar = application.element(kAXMenuBarAttribute),
              let windowMenu = menuBar.children.first(where: { $0.title == "Window" })?.children.first else { return false }
        return windowMenu.children.contains { $0.title == "Move Tab to New Private Window" }
    }

    private func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func filePath(fromDocument document: String) -> String? {
        guard let url = URL(string: document), url.isFileURL else { return nil }
        return url.path
    }
}

struct FrontWindow {
    let id: CGWindowID
    let blocksCapture: Bool

    /// CGWindowList is ordered front-to-back, which ScreenCaptureKit's window list does not guarantee.
    static func lookup(processID: pid_t) -> FrontWindow? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let info = windows.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == processID
                && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 80
        }
        guard let info, let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
        let sharingState = info[kCGWindowSharingState as String] as? Int
        return FrontWindow(id: id, blocksCapture: sharingState == Int(CGWindowSharingType.none.rawValue))
    }
}
