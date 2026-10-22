import Foundation

/// One signal as it goes over the wire (docs/protocol.md). Keys are snake_case.
struct WireSignal: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        var bundleID: String
        var version: String
        var build: String

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case version
            case build
        }
    }

    struct Device: Codable, Equatable, Sendable {
        var platform: String
        var osVersion: String
        var model: String
        var locale: String

        enum CodingKeys: String, CodingKey {
            case platform
            case osVersion = "os_version"
            case model
            case locale
        }
    }

    struct Flags: Codable, Equatable, Sendable {
        var debug: Bool
        var testflight: Bool
        var simulator: Bool
    }

    var type: String
    var time: String
    var installID: String
    var sessionID: String
    var app: App
    var device: Device
    var flags: Flags
    var payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case type
        case time
        case installID = "install_id"
        case sessionID = "session_id"
        case app
        case device
        case flags
        case payload
    }
}

enum Wire {
    static let sdkName = "kestrelkit"

    /// Compact JSON with sorted keys, so a batch is the same bytes on every platform.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The request body for already-encoded signals (one JSON object per line in the queue).
    /// Built by hand so queued signals don't have to be decoded and encoded again.
    static func body<Lines: Collection>(lines: Lines, sentAt: Date) -> Data where Lines.Element == Data {
        var body = Data(#"{"sdk":{"name":"\#(sdkName)","version":"\#(kestrelKitVersion)"},"sent_at":"\#(timestamp(sentAt))","signals":["#.utf8)
        var first = true
        for line in lines {
            if !first { body.append(UInt8(ascii: ",")) }
            body.append(line)
            first = false
        }
        body.append(contentsOf: Array("]}".utf8))
        return body
    }

    /// The bytes a body has besides its signals and the commas between them.
    static let envelopeSize = body(lines: [Data](), sentAt: Date(timeIntervalSince1970: 0)).count

    /// `2026-10-22T18:59:58.123Z`: UTC, milliseconds, always 24 characters.
    static func timestamp(_ date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = floorDiv(millis, 1000)
        let days = floorDiv(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civilDate(daysSince1970: days)
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
            + "T" + pad(secondOfDay / 3600, 2) + ":" + pad(secondOfDay / 60 % 60, 2) + ":" + pad(secondOfDay % 60, 2)
            + "." + pad(millis - seconds * 1000, 3) + "Z"
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : (a - b + 1) / b
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// Year, month and day of a day count since 1970-01-01 (Howard Hinnant's civil_from_days).
    private static func civilDate(daysSince1970 days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
