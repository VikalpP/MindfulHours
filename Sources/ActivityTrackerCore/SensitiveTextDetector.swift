import Foundation

/// Classifies OCR'd screen text. Returns only the kind of finding, never the matched text.
public enum SensitiveTextDetector {
    public enum Finding: String, Sendable, CaseIterable {
        case paymentCard = "payment card number"
        case iban = "IBAN"
        case usSocialSecurityNumber = "SSN"
        case secretKey = "API key or token"
        case privateKeyBlock = "private key"
        case credentialLabel = "credential label"
    }

    private static let secretPatterns = [
        #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{20,}"#,
        #"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{30,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
    ]

    private static let credentialLabels = [
        "seed phrase", "recovery phrase", "secret recovery phrase", "recovery codes", "backup codes",
        "cvv", "cvc", "security code", "card verification", "routing number", "account number",
    ]

    public static func findings(in lines: [String]) -> Set<Finding> {
        var found = Set<Finding>()
        let text = lines.joined(separator: "\n")

        if containsLuhnValidCardNumber(text) { found.insert(.paymentCard) }
        if containsValidIBAN(text) { found.insert(.iban) }
        if text.range(of: #"\b\d{3}-\d{2}-\d{4}\b"#, options: .regularExpression) != nil { found.insert(.usSocialSecurityNumber) }
        if secretPatterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { found.insert(.secretKey) }
        if text.range(of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: .regularExpression) != nil { found.insert(.privateKeyBlock) }
        if credentialLabels.contains(where: { PrivacyRules.text(text, containsWord: $0) }) { found.insert(.credentialLabel) }
        return found
    }

    static func containsLuhnValidCardNumber(_ text: String) -> Bool {
        allMatches(of: #"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)"#, in: text).contains { match in
            let digits = match.compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && passesLuhn(digits)
        }
    }

    static func passesLuhn(_ digits: [Int]) -> Bool {
        let sum = digits.reversed().enumerated().reduce(0) { total, entry in
            guard entry.offset % 2 == 1 else { return total + entry.element }
            let doubled = entry.element * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    static func containsValidIBAN(_ text: String) -> Bool {
        allMatches(of: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#, in: text.uppercased()).contains { match in
            let compact = match.replacingOccurrences(of: " ", with: "")
            return (15...34).contains(compact.count) && passesMod97(compact)
        }
    }

    private static func allMatches(of pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            Range(result.range, in: text).map { String(text[$0]) }
        }
    }

    private static func passesMod97(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let value = character.isNumber ? character.wholeNumberValue : character.asciiValue.map({ Int($0) - 55 }) else { return false }
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }
}
