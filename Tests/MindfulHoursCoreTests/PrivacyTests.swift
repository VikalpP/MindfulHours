import Foundation
import Testing
@testable import MindfulHoursCore

private let rules = PrivacyRules(
    excludedBundleIDs: ["com.1password.1password"],
    blockedURLPatterns: PrivacyRules.lines(PrivacyRules.defaultBlockedURLPatterns + "\n# comment\nchase.com\nexample.com/billing"),
    sensitiveTitleKeywords: PrivacyRules.lines(PrivacyRules.defaultSensitiveTitleKeywords),
    protectsPrivateWindows: true
)

private func chrome(title: String = "Docs", url: String) -> ActivityContext {
    ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: title, url: url)
}

@Suite struct PrivacyRulesTests {
    @Test func chromePasswordManagerHidesMetadata() {
        let verdict = rules.evaluate(chrome(title: "Google Password Manager", url: "chrome://password-manager/passwords"), signals: .init())
        #expect(verdict.reasons.contains(.sensitiveURL))
        #expect(verdict.matchedRule == "chrome://password-manager")
        #expect(verdict.hidesMetadata)
        #expect(!verdict.allowsScreenshot)
        #expect(!verdict.allowsAI)
    }

    @Test func domainRulesMatchSubdomainsAndPathPrefixes() {
        #expect(PrivacyRules.url("https://secure.chase.com/web/auth", matches: "chase.com"))
        #expect(!PrivacyRules.url("https://notchase.com", matches: "chase.com"))
        #expect(PrivacyRules.url("https://example.com/billing/invoices", matches: "example.com/billing"))
        #expect(!PrivacyRules.url("https://example.com/blog", matches: "example.com/billing"))
        #expect(PrivacyRules.url("CHROME://Password-Manager/settings", matches: "chrome://password-manager"))
    }

    @Test func titleKeywordsMatchWholeWordsOnly() {
        #expect(PrivacyRules.text("Reset your Password – GitHub", containsWord: "password"))
        #expect(!PrivacyRules.text("PasswordValidator.swift — tracker", containsWord: "password"))
        #expect(!PrivacyRules.text("Passwords", containsWord: "password"))
        #expect(PrivacyRules.text("System Settings — Passwords", containsWord: "passwords"))
    }

    @Test func screenshotOnlyProtectionsKeepMetadata() {
        let context = chrome(url: "https://docs.google.com/document/d/1")
        let cases: [(PrivacySignals, ProtectionReason)] = [
            (.init(isSecureInputActive: true), .secureInput),
            (.init(isFocusedElementSecure: true), .secureInput),
            (.init(isWindowCaptureBlocked: true), .captureBlockedWindow),
            (.init(isPrivateWindow: true), .privateWindow),
        ]
        for (signals, reason) in cases {
            let verdict = rules.evaluate(context, signals: signals)
            #expect(verdict.reasons == [reason])
            #expect(!verdict.allowsScreenshot)
            #expect(!verdict.hidesMetadata)
            #expect(verdict.allowsAI)
        }
    }

    @Test func unreadableBrowserStateFailsClosed() {
        let context = ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Docs")
        let urlUnknown = rules.evaluate(context, signals: .init(isBrowserURLUnknown: true))
        #expect(urlUnknown.reasons == [.unverifiedBrowser])
        #expect(!urlUnknown.allowsScreenshot && !urlUnknown.hidesMetadata)

        let modeUnknown = rules.evaluate(chrome(url: "https://github.com"), signals: .init(isPrivateWindowUnknown: true))
        #expect(modeUnknown.reasons == [.unverifiedBrowser])

        var relaxed = rules
        relaxed.protectsPrivateWindows = false
        #expect(relaxed.evaluate(chrome(url: "https://github.com"), signals: .init(isPrivateWindowUnknown: true)) == .clear)
        #expect(relaxed.evaluate(context, signals: .init(isBrowserURLUnknown: true)).reasons == [.unverifiedBrowser])
    }

    @Test func privateWindowsCanBeAllowed() {
        var relaxed = rules
        relaxed.protectsPrivateWindows = false
        #expect(relaxed.evaluate(chrome(url: "https://news.ycombinator.com"), signals: .init(isPrivateWindow: true)) == .clear)
    }

    @Test func excludedAppHidesMetadata() {
        let verdict = rules.evaluate(ActivityContext(bundleID: "com.1password.1password", appName: "1Password", windowTitle: "Vault"), signals: .init())
        #expect(verdict.reasons == [.excludedApp])
        #expect(verdict.hidesMetadata)
    }

    @Test func ordinaryActivityIsClear() {
        #expect(rules.evaluate(chrome(url: "https://github.com/acme/api/pull/42"), signals: .init()) == .clear)
    }

    @Test func privateInsightKeepsOnlyAppName() {
        let insight = Insight.privateContent(minuteStart: .now, context: chrome(title: "Passwords", url: "chrome://password-manager"))
        #expect(insight.context.windowTitle == nil && insight.context.url == nil)
        #expect(insight.summary == "Google Chrome — private content hidden")
        #expect(insight.task == Insight.privateTask)
    }

    @Test func withheldScreenshotIsExplainedInPrompt() {
        let observation = MinuteObservation(
            minuteStart: .now, context: chrome(url: "https://accounts.google.com"), secondsByApp: [], recentInsights: [],
            hasScreenshot: false, screenshotWithheldBecause: [.secureInput]
        )
        #expect(Prompts.minuteUser(observation).contains("Screenshot withheld for privacy (Password field focused)"))
    }
}

@Suite struct SensitiveTextDetectorTests {
    @Test func detectsLuhnValidCardNumbersOnly() {
        #expect(SensitiveTextDetector.findings(in: ["Card", "4242 4242 4242 4242", "Exp 12/30"]).contains(.paymentCard))
        #expect(SensitiveTextDetector.findings(in: ["5555-5555-5555-4444"]).contains(.paymentCard))
        #expect(!SensitiveTextDetector.findings(in: ["Order 4242 4242 4242 4241"]).contains(.paymentCard))
        #expect(!SensitiveTextDetector.findings(in: ["timestamp 1792657315"]).contains(.paymentCard))
    }

    @Test func detectsValidIBAN() {
        #expect(SensitiveTextDetector.findings(in: ["IBAN: GB82 WEST 1234 5698 7654 32"]).contains(.iban))
        #expect(!SensitiveTextDetector.findings(in: ["GB82 WEST 1234 5698 7654 33"]).contains(.iban))
    }

    @Test func detectsSecretsAndKeys() {
        #expect(SensitiveTextDetector.findings(in: ["export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx1234"]).contains(.secretKey))
        #expect(SensitiveTextDetector.findings(in: ["AKIAIOSFODNN7EXAMPLE"]).contains(.secretKey))
        #expect(SensitiveTextDetector.findings(in: ["ghp_abcdefghijklmnopqrstuvwxyz0123456789"]).contains(.secretKey))
        #expect(SensitiveTextDetector.findings(in: ["-----BEGIN OPENSSH PRIVATE KEY-----"]).contains(.privateKeyBlock))
    }

    @Test func detectsCredentialLabelsAndSSN() {
        #expect(SensitiveTextDetector.findings(in: ["Your recovery codes"]).contains(.credentialLabel))
        #expect(SensitiveTextDetector.findings(in: ["CVV"]).contains(.credentialLabel))
        #expect(SensitiveTextDetector.findings(in: ["SSN 123-45-6789"]).contains(.usSocialSecurityNumber))
    }

    @Test func ordinaryCodeAndProseAreClean() {
        let screen = [
            "func validatePassword(_ input: String) -> Bool {",
            "let timeout: TimeInterval = 1792657315",
            "Reviewing PR #42 in acme/api",
            "2026-10-22 13:54:00",
        ]
        #expect(SensitiveTextDetector.findings(in: screen).isEmpty)
    }
}
