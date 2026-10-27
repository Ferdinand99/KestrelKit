import Foundation

/// Replaces payload values that look like personal data before they are stored on the
/// device, and names the payload keys that are dropped. The rules match Keen Kestrel's own
/// scrubbing (`src/analytics/clean.rs` with `src/event/scrub.rs`), which runs again on the
/// server, so a value missed here is still caught there. In this order:
///
/// - Card numbers: 13–19 digits, optionally grouped by single spaces, dashes, dots or
///   non-breaking spaces, that pass the Luhn check.
/// - `Bearer …` and `Basic …` credentials.
/// - `name=value` pairs whose name contains `pass`, `secret`, `token`, `auth`, `key`, `card`
///   or `cookie`: `token=abc` becomes `token=[Filtered]`.
/// - Email addresses.
/// - IP addresses: IPv4, IPv6 written out with at least four groups
///   (`2001:db8:0:0:1:0:0:1`), and IPv6 shortened with `::` (`2001:db8::1`, `::1`).
/// - Phone numbers: 9–15 digits that start with `+` or `00`, or are written in at least
///   three groups. Plain digit runs (order numbers, ids) and dates are kept.
///
/// Callers remove control characters and cut the value to ``Limits/maxRawValueLength``
/// before scrubbing (see ``Limits/payload(_:defaults:)``): control characters would otherwise
/// split an address past the patterns, and the runs below are bounded so that a long value
/// can't make a pattern slow.
enum Scrubber {
    static let filtered = "[Filtered]"

    private static let card = Pattern(#"\b(?:\d[ .\-\x{00A0}\x{2007}\x{202F}]?){12,18}\d\b"#)
    private static let credential = Pattern(#"(?i)\b(bearer|basic)\s+[A-Za-z0-9\-._~+/]+=*"#)
    private static let sensitivePair = Pattern(
        #"(?i)([\w.\-]{0,40}(?:pass|secret|token|auth|key|card|cookie)[\w.\-]{0,40})=([^&\s'",;]+)"#
    )
    // A local part is at most 64 characters and a label 63; longer runs only shorten the match.
    private static let email = Pattern(
        #"(?i)[a-z0-9._%+\-]{1,64}@[a-z0-9\-]{1,63}(?:\.[a-z0-9\-]{1,63}){0,8}\.[a-z]{2,63}"#
    )
    private static let ip = Pattern(#"(?i)\b(?:(?:\d{1,3}\.){3}\d{1,3}|(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4})\b"#)
    /// A run of hex digits and colons on its own (not part of a word, and not the start of an
    /// IPv4 tail such as `::ffff:1.2.3.4`); ``isCompressedIPv6(_:)`` decides.
    private static let ipv6Candidate = Pattern(#"(?i)(?<![\w:])[0-9a-f:]{2,39}(?![\w:]|\.\d)"#)
    private static let phone = Pattern(#"(?:\+|\(\d|\b\d)[0-9 ().\-]{6,22}\d"#)

    /// Keys that carry an IP address (the server's `IP_KEYS`), lower-case.
    static let ipKeys: Set<String> = [
        "ip_address", "ip", "client_ip", "remote_addr",
        "x-forwarded-for", "x-real-ip", "forwarded", "cf-connecting-ip", "true-client-ip",
        "x-client-ip", "x-cluster-client-ip", "fastly-client-ip",
        // The same headers as a WSGI/CGI environment names them.
        "http_x_forwarded_for", "http_x_real_ip", "http_forwarded", "http_cf_connecting_ip",
        "http_true_client_ip", "http_x_client_ip",
    ]

    /// Keys that carry a user agent (the server's `USER_AGENT_KEYS`), lower-case.
    static let userAgentKeys: Set<String> = ["user-agent", "user_agent", "http_user_agent"]

    static func scrub(_ text: String) -> String {
        var out = replace(card, in: text) { luhn($0) ? filtered : nil }
        out = replace(credential, in: out) { match in
            let scheme = match.prefix { !$0.isWhitespace }
            return "\(scheme) \(filtered)"
        }
        out = replace(sensitivePair, in: out) { match in
            // The name can't contain `=`, so the first one ends it. A value that is already
            // filtered (a card number, say) stays as it is.
            guard let equals = match.firstIndex(of: "=") else { return nil }
            let value = match[match.index(after: equals)...]
            return value == filtered ? nil : "\(match[..<equals])=\(filtered)"
        }
        out = replace(email, in: out) { _ in filtered }
        // Shortened IPv6 first: the full-form pattern would take the groups of `2001:db8:0:0:1::`
        // and leave the `::`.
        out = replace(ipv6Candidate, in: out) { isCompressedIPv6($0) ? filtered : nil }
        out = replace(ip, in: out) { _ in filtered }
        out = replace(phone, in: out) { looksLikePhone($0) ? filtered : nil }
        return out
    }

    /// Whether a payload key (already cleaned and cut) names an IP address or a user agent,
    /// ignoring ASCII case. Kestrel drops such keys with their values, so KestrelKit doesn't
    /// send them.
    static func isDroppedKey(_ key: String) -> Bool {
        let lowered = lowercasedASCII(key)
        return ipKeys.contains(lowered) || userAgentKeys.contains(lowered)
    }

    /// Parts of a payload key that mark its value as a secret: the server's list for web
    /// properties (`SENSITIVE_KEY`), plus `cvv`, lower-case. `ssn` counts only as a word of its
    /// own, not inside one (`classname`).
    static let sensitiveKeyParts = ["pass", "secret", "token", "auth", "key", "card", "cookie", "cvv"]

    /// Whether a payload key (already cleaned and cut) looks like it holds a secret or a card
    /// detail: it contains one of ``sensitiveKeyParts`` or is a word `ssn` (`ssn`, `user_ssn`),
    /// ignoring ASCII case. The value is dropped with the key, because no pattern can tell what
    /// a secret looks like.
    static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = lowercasedASCII(key)
        if sensitiveKeyParts.contains(where: { lowered.contains($0) }) { return true }
        return lowered.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.contains("ssn")
    }

    /// Only A–Z are lowered, like Rust's `eq_ignore_ascii_case`, so no other character
    /// (the Kelvin sign, say) can turn into a listed key.
    private static func lowercasedASCII(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    /// Whether `candidate` (hex digits and colons) is an IPv6 address shortened with one `::`:
    /// one to seven groups of one to four hex digits around it.
    static func isCompressedIPv6(_ candidate: String) -> Bool {
        let halves = candidate.components(separatedBy: "::")
        guard halves.count == 2 else { return false }
        let groups = halves.flatMap { $0.isEmpty ? [] : $0.split(separator: ":", omittingEmptySubsequences: false) }
        guard (1...7).contains(groups.count) else { return false }
        return groups.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy(\.isHexDigit) }
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
