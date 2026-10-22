import Foundation

enum WindowPrivacy {
    case normal
    case `private`
    case unknown
}

struct BrowserTab {
    let url: String?
    let privacy: WindowPrivacy
}

/// Reads the active tab through AppleScript; macOS asks once per browser for Automation permission.
@MainActor
final class BrowserTabReader {
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "ai.perplexity.comet",
    ]
    private static let safariBundleIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Keyed by bundle ID and expression; nil marks a script the browser's dictionary can't compile (e.g. no `mode`).
    private var compiledScripts: [String: NSAppleScript?] = [:]

    static func isSafari(_ bundleID: String) -> Bool { safariBundleIDs.contains(bundleID) }

    /// Nil for non-browsers. Safari's privacy is resolved by the caller, since its dictionary has no `mode`.
    func activeTab(bundleID: String) -> BrowserTab? {
        let isChromium = Self.chromiumBundleIDs.contains(bundleID)
        guard isChromium || Self.isSafari(bundleID) else { return nil }
        let url = run(bundleID, isChromium ? "URL of active tab of front window" : "URL of current tab of front window")
        guard isChromium else { return BrowserTab(url: url, privacy: .unknown) }
        let privacy: WindowPrivacy = switch run(bundleID, "mode of front window") {
        case "incognito": .private
        case "normal": .normal
        default: .unknown
        }
        return BrowserTab(url: url, privacy: privacy)
    }

    private func run(_ bundleID: String, _ expression: String) -> String? {
        let key = "\(bundleID)|\(expression)"
        let script = compiledScripts[key] ?? Self.compile(bundleID: bundleID, expression: expression)
        compiledScripts[key] = script
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil,
              let value = result.stringValue, !value.isEmpty, value != "missing value" else { return nil }
        return value
    }

    private static func compile(bundleID: String, expression: String) -> NSAppleScript? {
        let source = """
            with timeout of 2 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    return \(expression)
                end tell
            end timeout
            """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        return script.compileAndReturnError(&error) ? script : nil
    }
}
