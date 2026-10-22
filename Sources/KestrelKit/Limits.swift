import Foundation

/// The protocol's limits (docs/protocol.md), applied on the device so the server never
/// has to reject a signal. "Characters" are Unicode scalar values, as in Rust's `char`;
/// truncation never splits a character the user sees (a grapheme cluster).
enum Limits {
    static let maxSignalsPerRequest = 100
    static let maxBodyBytes = 256 * 1024
    static let maxTypeLength = 100
    static let maxPayloadKeys = 20
    static let maxKeyLength = 40
    static let maxValueLength = 200
    /// For the other strings (bundle id, versions, model, locale). A proposal in the protocol.
    static let maxFieldLength = 200

    /// A valid signal type: 1–100 characters from `[A-Za-z0-9._-]`. Other characters become
    /// `_` (so `Paywall shown` is sent as `Paywall_shown`); an empty type gives `nil`.
    static func signalType(_ raw: String) -> String? {
        var type = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                type.append(character)
            } else {
                type.append("_")
            }
            if type.count == maxTypeLength { break }
        }
        return type.isEmpty ? nil : type
    }

    /// The payload to send: the signal's own keys first (sorted), then the default payload's
    /// keys it doesn't have (sorted), at most 20, each key and value cleaned, scrubbed and cut.
    static func payload(_ own: [String: String], defaults: [String: String] = [:]) -> [String: String] {
        let ordered = own.keys.sorted().map { ($0, own[$0]!) }
            + defaults.keys.filter { own[$0] == nil }.sorted().map { ($0, defaults[$0]!) }
        var result: [String: String] = [:]
        for (rawKey, rawValue) in ordered {
            guard result.count < maxPayloadKeys else {
                Log.debug("A payload has more than \(maxPayloadKeys) keys; the rest are dropped.")
                break
            }
            let key = truncate(clean(rawKey), to: maxKeyLength)
            guard !key.isEmpty, result[key] == nil else { continue }
            result[key] = truncate(clean(Scrubber.scrub(rawValue)), to: maxValueLength)
        }
        return result
    }

    /// Any other string field: cleaned and cut to 200 characters.
    static func field(_ raw: String) -> String {
        truncate(clean(raw), to: maxFieldLength)
    }

    /// Trimmed, without control characters.
    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0.properties.generalCategory != .control })
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The longest prefix of whole characters with at most `limit` Unicode scalars.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var used = 0
        var end = text.startIndex
        for character in text {
            let size = character.unicodeScalars.count
            if used + size > limit { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
