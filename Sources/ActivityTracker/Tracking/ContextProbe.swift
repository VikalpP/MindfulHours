import AppKit
import ApplicationServices
import ActivityTrackerCore

struct FrontmostApp {
    let processID: pid_t
    let context: ActivityContext
}

@MainActor
final class ContextProbe {
    private let browserURLReader = BrowserURLReader()

    func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let window = focusedWindow(of: app.processIdentifier)
        let context = ActivityContext(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: window.flatMap { stringAttribute(kAXTitleAttribute, of: $0) }.flatMap(nonEmpty),
            documentPath: window.flatMap { stringAttribute(kAXDocumentAttribute, of: $0) }.flatMap(Self.filePath(fromDocument:)),
            url: browserURLReader.activeTabURL(bundleID: bundleID)
        )
        return FrontmostApp(processID: app.processIdentifier, context: context)
    }

    private func focusedWindow(of processID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
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
