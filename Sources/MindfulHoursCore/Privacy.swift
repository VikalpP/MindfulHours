import Foundation

public enum ProtectionReason: String, CaseIterable, Codable, Sendable, Comparable {
    case excludedApp
    case sensitiveURL
    case sensitiveTitle
    case secureInput
    case captureBlockedWindow
    case privateWindow
    case unverifiedBrowser
    case sensitiveText

    public var label: String {
        switch self {
        case .excludedApp: "Excluded app"
        case .sensitiveURL: "Sensitive address"
        case .sensitiveTitle: "Sensitive window title"
        case .secureInput: "Password field focused"
        case .captureBlockedWindow: "Window blocks screen capture"
        case .privateWindow: "Private/incognito window"
        case .unverifiedBrowser: "Browser tab couldn't be checked"
        case .sensitiveText: "Sensitive text on screen"
        }
    }

    /// The title or URL itself is sensitive, so neither may be stored or sent anywhere.
    public var hidesMetadata: Bool {
        [.excludedApp, .sensitiveURL, .sensitiveTitle].contains(self)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct PrivacySignals: Equatable, Sendable {
    public var isSecureInputActive = false
    public var isFocusedElementSecure = false
    public var isWindowCaptureBlocked = false
    public var isPrivateWindow = false
    /// A supported browser is in front but its tab URL couldn't be read (e.g. Automation denied).
    public var isBrowserURLUnknown = false
    /// A supported browser is in front but whether the window is private couldn't be determined.
    public var isPrivateWindowUnknown = false

    public init(
        isSecureInputActive: Bool = false,
        isFocusedElementSecure: Bool = false,
        isWindowCaptureBlocked: Bool = false,
        isPrivateWindow: Bool = false,
        isBrowserURLUnknown: Bool = false,
        isPrivateWindowUnknown: Bool = false
    ) {
        self.isSecureInputActive = isSecureInputActive
        self.isFocusedElementSecure = isFocusedElementSecure
        self.isWindowCaptureBlocked = isWindowCaptureBlocked
        self.isPrivateWindow = isPrivateWindow
        self.isBrowserURLUnknown = isBrowserURLUnknown
        self.isPrivateWindowUnknown = isPrivateWindowUnknown
    }
}

public struct PrivacyVerdict: Equatable, Sendable {
    public var reasons: Set<ProtectionReason>
    public var matchedRule: String?

    public static let clear = PrivacyVerdict(reasons: [], matchedRule: nil)

    public var hidesMetadata: Bool { reasons.contains { $0.hidesMetadata } }
    public var allowsScreenshot: Bool { reasons.isEmpty }
    public var allowsAI: Bool { !hidesMetadata }
    public var sortedReasons: [ProtectionReason] { reasons.sorted() }
}

public struct PrivacyRules: Sendable {
    public static let defaultBlockedURLPatterns = """
        chrome://password-manager
        chrome://settings/passwords
        chrome://settings/payments
        chrome://settings/addresses
        chrome://settings/autofill
        brave://password-manager
        brave://settings/passwords
        brave://settings/payments
        edge://wallet
        edge://settings/passwords
        edge://settings/payments
        edge://settings/personalinfo
        vivaldi://password-manager
        opera://password-manager
        passwords.google.com
        pay.google.com
        my.1password.com
        vault.bitwarden.com
        """

    public static let defaultSensitiveTitleKeywords = """
        password
        passwords
        passkey
        passkeys
        keychain
        recovery code
        recovery codes
        backup codes
        seed phrase
        recovery phrase
        private key
        credit card
        card number
        """

    public var excludedBundleIDs: Set<String>
    public var blockedURLPatterns: [String]
    public var sensitiveTitleKeywords: [String]
    public var protectsPrivateWindows: Bool

    public init(excludedBundleIDs: Set<String>, blockedURLPatterns: [String], sensitiveTitleKeywords: [String], protectsPrivateWindows: Bool) {
        self.excludedBundleIDs = excludedBundleIDs
        self.blockedURLPatterns = blockedURLPatterns.map { $0.lowercased() }
        self.sensitiveTitleKeywords = sensitiveTitleKeywords.map { $0.lowercased() }
        self.protectsPrivateWindows = protectsPrivateWindows
    }

    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public func evaluate(_ context: ActivityContext, signals: PrivacySignals) -> PrivacyVerdict {
        var verdict = PrivacyVerdict.clear
        if excludedBundleIDs.contains(context.bundleID) {
            verdict.reasons.insert(.excludedApp)
        }
        if let url = context.url, let pattern = blockedURLPatterns.first(where: { Self.url(url, matches: $0) }) {
            verdict.reasons.insert(.sensitiveURL)
            verdict.matchedRule = pattern
        }
        if let title = context.windowTitle, let keyword = sensitiveTitleKeywords.first(where: { Self.text(title, containsWord: $0) }) {
            verdict.reasons.insert(.sensitiveTitle)
            verdict.matchedRule = verdict.matchedRule ?? keyword
        }
        if signals.isSecureInputActive || signals.isFocusedElementSecure {
            verdict.reasons.insert(.secureInput)
        }
        if signals.isWindowCaptureBlocked {
            verdict.reasons.insert(.captureBlockedWindow)
        }
        if protectsPrivateWindows && signals.isPrivateWindow {
            verdict.reasons.insert(.privateWindow)
        }
        // Fail closed: URL rules and private-window protection can't be trusted without the browser's answer.
        if signals.isBrowserURLUnknown || (protectsPrivateWindows && signals.isPrivateWindowUnknown && !signals.isPrivateWindow) {
            verdict.reasons.insert(.unverifiedBrowser)
        }
        return verdict
    }

    /// Patterns with a scheme match as URL prefixes; bare patterns match a host (and its subdomains) plus an optional path prefix.
    static func url(_ url: String, matches pattern: String) -> Bool {
        let lowered = url.lowercased()
        if pattern.contains("://") {
            return lowered.hasPrefix(pattern)
        }
        guard let components = URLComponents(string: lowered), let host = components.host else { return false }
        let patternHost = pattern.split(separator: "/", maxSplits: 1).first.map(String.init) ?? pattern
        let patternPath = String(pattern.dropFirst(patternHost.count))
        let hostMatches = host == patternHost || host.hasSuffix("." + patternHost)
        return hostMatches && (patternPath.isEmpty || components.path.hasPrefix(patternPath))
    }

    /// Whole-word match, so "password" flags "Reset your password" but not "PasswordValidator.swift".
    static func text(_ text: String, containsWord phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public struct PrivacyEvent: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var occurredAt: Date
    public var bundleID: String
    public var appName: String
    public var reasons: [ProtectionReason]
    public var detail: String?

    public init(id: Int64 = 0, occurredAt: Date, bundleID: String, appName: String, reasons: [ProtectionReason], detail: String?) {
        self.id = id
        self.occurredAt = occurredAt
        self.bundleID = bundleID
        self.appName = appName
        self.reasons = reasons
        self.detail = detail
    }
}
