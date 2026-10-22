import Foundation

/// Reads the active tab URL through AppleScript; macOS asks once per browser for Automation permission.
@MainActor
final class BrowserURLReader {
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
    private static let safariBundleIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    private var compiledScripts: [String: NSAppleScript] = [:]

    func activeTabURL(bundleID: String) -> String? {
        guard let script = script(for: bundleID) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let url = result.stringValue, !url.isEmpty, url != "missing value" else { return nil }
        return url
    }

    private func script(for bundleID: String) -> NSAppleScript? {
        if let cached = compiledScripts[bundleID] { return cached }
        let tabURLExpression: String
        if Self.chromiumBundleIDs.contains(bundleID) {
            tabURLExpression = "URL of active tab of front window"
        } else if Self.safariBundleIDs.contains(bundleID) {
            tabURLExpression = "URL of current tab of front window"
        } else {
            return nil
        }
        let source = """
            with timeout of 2 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    return \(tabURLExpression)
                end tell
            end timeout
            """
        guard let script = NSAppleScript(source: source) else { return nil }
        script.compileAndReturnError(nil)
        compiledScripts[bundleID] = script
        return script
    }
}
