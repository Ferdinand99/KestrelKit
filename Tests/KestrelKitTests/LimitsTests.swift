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

    @Test("Control characters can't split an address past the scrubbing", arguments: [
        ("john@exa\tmple.com", "[Filtered]"),
        ("john@example.com\n", "[Filtered]"),
        ("jo\u{0}hn@exam\u{7}ple.com", "[Filtered]"),
        ("4111 1111 11\n11 1111", "[Filtered]"),
        ("41\t11 1111 1111 1111", "[Filtered]"),
        ("ip 203.0.\r113.7", "ip [Filtered]"),
        ("Bearer\u{0} abc.def", "Bearer [Filtered]"),
        ("tok\u{1}en=abc", "token=[Filtered]"),
    ])
    func controlCharacters(input: String, expected: String) {
        #expect(Limits.payload(["note": input]) == ["note": expected])
    }

    @Test("Card numbers grouped with dots or non-breaking spaces are scrubbed", arguments: [
        "4111.1111.1111.1111",
        "4111\u{00A0}1111\u{00A0}1111\u{00A0}1111",
        "4111\u{202F}1111\u{202F}1111\u{202F}1111",
        "4111-1111.1111 1111",
    ])
    func cardSeparators(input: String) {
        #expect(Scrubber.scrub(input) == "[Filtered]")
        #expect(Scrubber.scrub("paid with \(input) today") == "paid with [Filtered] today")
    }

    @Test("Shortened IPv6 addresses are replaced", arguments: [
        ("2001:db8::1", "[Filtered]"),
        ("::1", "[Filtered]"),
        ("fe80::1", "[Filtered]"),
        ("FE80::202:B3FF:FE1E:8329", "[Filtered]"),
        ("2001:db8:0:0:1::", "[Filtered]"),
        ("from 2001:db8::8a2e:370:7334, then", "from [Filtered], then"),
        ("/ip/::1/x", "/ip/[Filtered]/x"),
        ("[2001:db8::1]:8080", "[[Filtered]]:8080"),
    ])
    func shortenedIPv6(input: String, expected: String) {
        #expect(Scrubber.scrub(input) == expected)
    }

    @Test("Things that only look a bit like a shortened IPv6 address are kept", arguments: [
        "::",
        ":::1",
        "1::2::3",
        "std::fmt::Display",
        "Namespace::Item",
        "12:30:45",
        "a:b",
        "db8::12345",
    ])
    func notShortenedIPv6(input: String) {
        #expect(Scrubber.scrub(input) == input)
    }

    @Test("Keys that look like they hold a secret are dropped with their values", arguments: [
        "password", "Password", "passwd", "user_pass", "secret", "client_secret", "token", "apiToken",
        "auth", "Authorization", "key", "api_key", "apiKey", "card", "cardNumber", "cvv", "CVV2",
        "ssn", "SSN", "user_ssn", "ssn-last4", "cookie", "session_cookie",
    ])
    func sensitiveKeys(key: String) {
        #expect(Scrubber.isSensitiveKey(key), "\(key)")
        #expect(Limits.payload([key: "hunter2", "plan": "pro"]) == ["plan": "pro"])
    }

    @Test("The default payload's secret keys are dropped too")
    func sensitiveDefaultKeys() {
        #expect(Limits.payload(["plan": "pro"], defaults: ["api_token": "abc", "channel": "beta"]) == ["plan": "pro", "channel": "beta"])
    }

    @Test("Ordinary keys are kept", arguments: ["plan", "className", "classname", "screen", "count", "name", "email", "item00", "\u{212A}ey"])
    func ordinaryKeys(key: String) {
        #expect(!Scrubber.isSensitiveKey(key), "\(key)")
        #expect(Limits.payload([key: "x"]) == [key: "x"])
    }

    @Test("A huge value is cut before it is scrubbed and scrubs fast", arguments: [
        String(repeating: "a", count: 20_000),
        String(repeating: "a.", count: 10_000),
        String(repeating: "a@", count: 10_000),
        String(repeating: "1 ", count: 10_000),
        String(repeating: "token", count: 4_000),
        String(repeating: "pass-", count: 4_000),
        String(repeating: "1:", count: 10_000),
        "x@" + String(repeating: "a.", count: 10_000),
        String(repeating: "a", count: 20_000) + "@example.com",
    ])
    func hugeValues(value: String) {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let payload = Limits.payload(["note": value])
            #expect((payload["note"]?.unicodeScalars.count ?? 0) <= Limits.maxValueLength)
        }
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("A value is cut to 2,000 characters before scrubbing, then to 200")
    func rawCap() {
        let payload = Limits.payload(["note": String(repeating: "x", count: 2_100) + "jane@example.com"])
        #expect(payload["note"] == String(repeating: "x", count: 200))
        // An address in the first 200 characters is still found when the value is long.
        let early = Limits.payload(["note": "jane@example.com " + String(repeating: "x", count: 5_000)])
        #expect(early["note"] == "[Filtered] " + String(repeating: "x", count: 189))
    }

    @Test("Luhn")
    func luhn() {
        #expect(Scrubber.luhn("4111111111111111"))
        #expect(Scrubber.luhn("5500 0055 5555 5559"))
        #expect(!Scrubber.luhn("4111111111111112"))
    }

    // MARK: - The server's own test cases (Keen Kestrel's src/analytics/clean.rs,
    // src/analytics/app/mod.rs and src/event/scrub.rs), so both sides scrub alike.

    @Test("IP addresses in values are replaced", arguments: [
        ("from 203.0.113.7 now", "from [Filtered] now"),
        ("/ip/2001:db8:0:0:1:0:0:1", "/ip/[Filtered]"),
        ("203.0.113.7", "[Filtered]"),
        ("10.0.0.1, 192.168.1.20", "[Filtered], [Filtered]"),
        ("FE80:0:0:0:202:B3FF:FE1E:8329", "[Filtered]"),
        ("user@10.0.0.1", "user@[Filtered]"),
    ])
    func ipAddresses(input: String, expected: String) {
        #expect(Scrubber.scrub(input) == expected)
    }

    @Test("Things that only look a bit like addresses are kept", arguments: [
        "1.4.0",
        "/v/1.2.3",
        "12:30",
        "12:30:45",
    ])
    func notIPAddresses(input: String) {
        #expect(Scrubber.scrub(input) == input)
    }

    @Test("Paths and free text scrub like the server's", arguments: [
        ("/users/ada.lovelace@example.com/orders", "/users/[Filtered]/orders"),
        ("/pay/4111111111111111/x/ada@example.com", "/pay/[Filtered]/x/[Filtered]"),
        ("call +47 912 34 567", "call [Filtered]"),
        ("/call/(555) 123-4567", "/call/[Filtered]"),
        ("/call/0047-912-34-567", "/call/[Filtered]"),
        ("paid with 4111 1111 1111 1111 today", "paid with [Filtered] today"),
        ("header was Bearer abc.def-123=", "header was Bearer [Filtered]"),
        ("'step=pay&token=abc&api_key=k1'", "'step=pay&token=[Filtered]&api_key=[Filtered]'"),
        ("card=4111111111111111", "card=[Filtered]"),
    ])
    func serverCases(input: String, expected: String) {
        #expect(Scrubber.scrub(input) == expected)
    }

    @Test("The server keeps these, so KestrelKit does too", arguments: [
        "/orders/1234567890",
        "/blog/2026-10-22/autumn",
        "/posts/123/comments/456",
        "order 1234567890123 shipped",
        "0x0000000180044955",
        "token=[Filtered]",
        "plain words",
    ])
    func serverKeeps(input: String) {
        #expect(Scrubber.scrub(input) == input)
    }

    @Test("Keys that name an IP address or a user agent are dropped, ignoring ASCII case")
    func droppedKeys() {
        for key in ["ip", "IP", "ip_address", "client_ip", "REMOTE_ADDR", "X-Forwarded-For", "x-real-ip",
                    "Forwarded", "cf-connecting-ip", "true-client-ip", "x-client-ip", "x-cluster-client-ip",
                    "fastly-client-ip", "HTTP_X_FORWARDED_FOR", "http_x_real_ip", "http_forwarded",
                    "http_cf_connecting_ip", "http_true_client_ip", "http_x_client_ip",
                    "user-agent", "User-Agent", "user_agent", "HTTP_USER_AGENT"] {
            #expect(Scrubber.isDroppedKey(key), "\(key)")
        }
        for key in ["zip", "tip", "ip_hash", "ips", "agent", "user", "useragent", "plan", "\u{0130}P"] {
            #expect(!Scrubber.isDroppedKey(key), "\(key)")
        }
    }

    @Test("A payload is bounded and scrubbed like the server's")
    func serverPayload() {
        let payload = Limits.payload([
            "email": "jane.doe@example.com",
            "phone": "+47 912 34 567",
            "payment": "4111 1111 1111 1111",
            "header": "Authorization: Bearer abc.def-123",
            "card": "4111 1111 1111 1111",
            "auth": "Authorization: Bearer abc.def-123",
            "note": "order 123456789",
            "pages": "12",
            "pdf": "true",
            "ip": "203.0.113.7",
            "user_agent": "Mozilla/5.0",
            "where": "from 203.0.113.7",
            "long": String(repeating: "v", count: 500),
            String(repeating: "k", count: 60): "x",
        ])
        #expect(payload["email"] == "[Filtered]")
        #expect(payload["phone"] == "[Filtered]")
        #expect(payload["payment"] == "[Filtered]")
        #expect(payload["header"] == "Authorization: Bearer [Filtered]")
        #expect(payload["card"] == nil && payload["auth"] == nil)
        #expect(payload["note"] == "order 123456789")
        #expect(payload["pages"] == "12" && payload["pdf"] == "true")
        #expect(payload["ip"] == nil && payload["user_agent"] == nil)
        #expect(payload["where"] == "from [Filtered]")
        #expect(payload["long"]?.unicodeScalars.count == 200)
        #expect(payload[String(repeating: "k", count: 40)] == "x")
        #expect(payload.count == 10)
    }

    @Test("Dropped keys don't use up the 20, and are cleaned before the check")
    func droppedKeysInPayloads() {
        var own: [String: String] = [" IP\u{0007} ": "203.0.113.7", "User-Agent": "Mozilla/5.0"]
        for i in 0..<20 { own["item\(i < 10 ? "0" : "")\(i)"] = "\(i)" }
        let payload = Limits.payload(own, defaults: ["x-forwarded-for": "10.0.0.1"])
        #expect(payload.count == 20)
        #expect(payload.keys.allSatisfy { $0.hasPrefix("item") })
    }

    @Test("Every type KestrelKit sends is one the server accepts as it is", arguments: [
        "Paywall.shown",
        "  Paywall shown \n",
        "Økonomi.åpnet",
        "👍🏽 liked",
        "tab\there",
        "e\u{301}",
        "\r\nline",
        "a/b:c?d=e",
        "\u{00A0}nbsp\u{00A0}",
        "\u{212A}elvin",
        String(repeating: "é", count: 150),
        String(repeating: "x", count: 150),
        String(repeating: "👍🏽", count: 60),
    ])
    func typesTheServerAccepts(raw: String) throws {
        let type = try #require(Limits.signalType(raw))
        // The server's rule (src/analytics/app/mod.rs, `signal_type`): after trimming, 1–100
        // characters from [A-Za-z0-9._-], or the signal is dropped; longer types are cut.
        let allowed = type.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
        #expect(allowed, "\(type)")
        #expect((1...100).contains(type.unicodeScalars.count))
        #expect(type == type.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
