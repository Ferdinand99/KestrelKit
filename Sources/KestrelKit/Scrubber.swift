import Foundation

/// Replaces payload values that look like personal data before they are stored on the
/// device. The rules match Keen Kestrel's own scrubbing (`src/analytics/clean.rs`), which
/// runs again on the server, so a value missed here is still caught there.
///
/// - Card numbers: 13–19 digits, optionally grouped by single spaces or dashes, that pass
///   the Luhn check.
/// - `Bearer …` and `Basic …` credentials.
/// - Email addresses.
/// - Phone numbers: 9–15 digits that start with `+` or `00`, or are written in at least
///   three groups. Plain digit runs (order numbers, ids) and dates are kept.
enum Scrubber {
    static let filtered = "[Filtered]"

    private static let card = Pattern(#"\b(?:\d[ -]?){12,18}\d\b"#)
    private static let credential = Pattern(#"(?i)\b(bearer|basic)\s+[A-Za-z0-9\-._~+/]+=*"#)
    private static let email = Pattern(#"(?i)[a-z0-9._%+\-]+@[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,}"#)
    private static let phone = Pattern(#"(?:\+|\(\d|\b\d)[0-9 ().\-]{6,22}\d"#)

    static func scrub(_ text: String) -> String {
        var out = replace(card, in: text) { luhn($0) ? filtered : nil }
        out = replace(credential, in: out) { match in
            let scheme = match.prefix { !$0.isWhitespace }
            return "\(scheme) \(filtered)"
        }
        out = replace(email, in: out) { _ in filtered }
        out = replace(phone, in: out) { looksLikePhone($0) ? filtered : nil }
        return out
    }

    /// The Luhn checksum over the digits in `text`.
    static func luhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            var value = digit
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    static func looksLikePhone(_ candidate: String) -> Bool {
        let digits = candidate.filter { $0.isASCII && $0.isNumber }.count
        guard (9...15).contains(digits) else { return false }
        let international = candidate.hasPrefix("+") || candidate.hasPrefix("00")
        let groups = candidate.split { !($0.isASCII && $0.isNumber) }.count
        return international || groups >= 3
    }

    /// `text` with each match of `pattern` replaced by `transform(match)`, or kept when it
    /// returns `nil`.
    private static func replace(
        _ pattern: Pattern,
        in text: String,
        _ transform: (String) -> String?
    ) -> String {
        let matches = pattern.regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            let found = String(text[range])
            result += text[cursor..<range.lowerBound]
            result += transform(found) ?? found
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// NSRegularExpression is immutable and safe to share between threads, but not marked
    /// `Sendable` in every SDK.
    struct Pattern: @unchecked Sendable {
        let regex: NSRegularExpression

        init(_ pattern: String) {
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                preconditionFailure("Invalid scrubbing pattern \(pattern): \(error)")
            }
        }
    }
}
