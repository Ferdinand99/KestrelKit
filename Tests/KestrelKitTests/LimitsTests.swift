import Foundation
import Testing
@testable import KestrelKit

@Suite("Limits and scrubbing")
struct LimitsTests {
    @Test("Signal types keep [A-Za-z0-9._-] and become at most 100 characters")
    func signalTypes() {
        #expect(Limits.signalType("Paywall.shown") == "Paywall.shown")
        #expect(Limits.signalType("Settings.dark-mode_on") == "Settings.dark-mode_on")
        #expect(Limits.signalType("  Paywall shown \n") == "Paywall_shown")
        #expect(Limits.signalType("Økonomi.åpnet") == "_konomi._pnet")
        #expect(Limits.signalType("") == nil)
        #expect(Limits.signalType("   ") == nil)
        #expect(Limits.signalType(String(repeating: "a", count: 150))?.count == 100)
    }

    @Test("A payload keeps at most 20 keys, the signal's own first")
    func payloadKeys() {
        var own: [String: String] = [:]
        for i in 0..<15 { own[i < 10 ? "own0\(i)" : "own\(i)"] = "\(i)" }
        var defaults: [String: String] = ["own00": "default"]
        for i in 0..<10 { defaults["def\(i)"] = "\(i)" }

        let payload = Limits.payload(own, defaults: defaults)
        #expect(payload.count == 20)
        #expect(payload["own00"] == "0")
        #expect(payload.keys.filter { $0.hasPrefix("own") }.count == 15)
        #expect(payload.keys.filter { $0.hasPrefix("def") }.sorted() == ["def0", "def1", "def2", "def3", "def4"])
    }

    @Test("Keys are cut to 40 characters and values to 200")
    func truncation() {
        let payload = Limits.payload([
            String(repeating: "k", count: 60): String(repeating: "v", count: 500),
            "  ": "empty keys are dropped",
            "ctl\u{0007}": "\u{0001}value\n",
        ])
        #expect(payload[String(repeating: "k", count: 40)] == String(repeating: "v", count: 200))
        #expect(payload["ctl"] == "value")
        #expect(payload.count == 2)
    }

    @Test("Truncation counts Unicode scalars and never splits a character")
    func unicodeTruncation() {
        let thumbs = String(repeating: "👍🏽", count: 150) // 2 scalars each
        let cut = Limits.truncate(thumbs, to: 200)
        #expect(cut.unicodeScalars.count == 200)
        #expect(cut.count == 100)

        let odd = "a" + String(repeating: "👍🏽", count: 150)
        let oddCut = Limits.truncate(odd, to: 200)
        #expect(oddCut.unicodeScalars.count == 199)
        #expect(Limits.truncate("short", to: 200) == "short")
    }

    @Test("Personal data in values is replaced by [Filtered]", arguments: [
        ("jane.doe@example.com", "[Filtered]"),
        ("Contact jane@example.co.uk now", "Contact [Filtered] now"),
        ("+47 912 34 567", "[Filtered]"),
        ("call 0047 91234567", "call [Filtered]"),
        ("(555) 123-4567", "[Filtered]"),
        ("4111 1111 1111 1111", "[Filtered]"),
        ("card 5500-0055-5555-5559 ok", "card [Filtered] ok"),
        ("Authorization: Bearer abc.def-123", "Authorization: Bearer [Filtered]"),
    ])
    func scrubbed(input: String, expected: String) {
        #expect(Scrubber.scrub(input) == expected)
    }

    @Test("Ordinary values are kept", arguments: [
        "pro",
        "1.4.0",
        "order 123456789",
        "2026-10-22",
        "12:30",
        "4111111111111112", // fails the Luhn check, and too long for a phone number
        "1792695598",
        "42",
        "true",
    ])
    func kept(input: String) {
        #expect(Scrubber.scrub(input) == input)
    }

    @Test("Scrubbing happens before truncation in payloads")
    func scrubbedPayload() {
        let payload = Limits.payload(["email": "jane@example.com", "plan": "pro"])
        #expect(payload == ["email": "[Filtered]", "plan": "pro"])
    }

    @Test("Luhn")
    func luhn() {
        #expect(Scrubber.luhn("4111111111111111"))
        #expect(Scrubber.luhn("5500 0055 5555 5559"))
        #expect(!Scrubber.luhn("4111111111111112"))
    }
}
