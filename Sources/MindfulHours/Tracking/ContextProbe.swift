import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MindfulHoursCore

struct FrontmostApp {
    let processID: pid_t
    let windowID: CGWindowID?
    let context: ActivityContext
    let signals: PrivacySignals
}

@MainActor
final class ContextProbe {
    private let browser = BrowserTabReader()

    func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let application = AXUIElement.application(app.processIdentifier)
        let window = application.element(kAXFocusedWindowAttribute)
        let frontWindow = FrontWindow.lookup(processID: app.processIdentifier)
        let tab = browser.activeTab(bundleID: bundleID)
        let windowPrivacy = BrowserTabReader.isSafari(bundleID) ? safariWindowPrivacy(application) : tab?.privacy

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
            // Without Screen Recording permission every window reports "no sharing", and capture can't happen anyway.
            isWindowCaptureBlocked: CGPreflightScreenCaptureAccess() && (frontWindow?.blocksCapture ?? false),
            isPrivateWindow: windowPrivacy == .private,
            isBrowserURLUnknown: tab != nil && frontWindow != nil && tab?.url == nil,
            isPrivateWindowUnknown: windowPrivacy == .unknown
        )
        return FrontmostApp(processID: app.processIdentifier, windowID: frontWindow?.id, context: context, signals: signals)
    }

    /// Safari exposes no scripting property for this; its Window menu offers "Move Tab to New Private Window" only in
    /// private windows. The labels are English-only, so any other UI language or menu layout yields `.unknown`.
    private func safariWindowPrivacy(_ application: AXUIElement) -> WindowPrivacy {
        guard Locale.preferredLanguages.first?.hasPrefix("en") == true,
              let menuBar = application.element(kAXMenuBarAttribute),
              let windowMenu = menuBar.children.first(where: { $0.title == "Window" })?.children.first else { return .unknown }
        let titles = Set(windowMenu.children.compactMap(\.title))
        if titles.contains("Move Tab to New Private Window") { return .private }
        if titles.contains("Move Tab to New Window") { return .normal }
        return .unknown
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
