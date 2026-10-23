import Foundation
import Testing
@testable import KestrelKit

@Suite("Sending and responses")
struct DeliveryTests {
    @Test("202 sends the batch once with the key and the protocol's body")
    func accepted() async {
        let harness = Harness()
        let client = harness.client()
        client.signal("Paywall.shown", payload: ["plan": "pro"])
        client.signal("Export.finished", payload: [:])
        await client.flush()

        let requests = harness.server.requests
        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.method == "POST")
        #expect(request.path == "/ingest/v1/signals")
        #expect(request.header("X-Kestrel-Key") == TestKey.value)
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.types == ["Paywall.shown", "Export.finished"])
        #expect(request.signals[0].payload == ["plan": "pro"])
        #expect(request.signals[0].app == .init(bundleID: "com.example.app", version: "1.4.0", build: "57"))
        #expect(request.signals[0].time == "2026-10-22T18:59:58.123Z")

        await client.flush()
        #expect(harness.server.requests.count == 1)
        #expect(harness.queuedLines == 0)
    }

    @Test("A 202 that reports dropped signals (or says nothing readable) still ends the batch", arguments: [
        #"{"accepted":1,"dropped":1}"#,
        #"{"accepted":0,"dropped":2}"#,
        #"{"accepted":2}"#,
        "",
        "not json",
    ])
    func acceptedWithDropped(body: String) async {
        let harness = Harness()
        harness.server.script([.status(202, body: body)])
        let client = harness.client()
        client.signal("Kept")
        client.signal("Broken")
        await client.flush()
        #expect(harness.queuedLines == 0)

        // Nothing is resent: the next request is a new signal only.
        client.signal("Next")
        await client.flush()
        #expect(harness.server.requests.map(\.types) == [["Kept", "Broken"], ["Next"]])
    }

    @Test("The dropped count is read from the 202 body when it is there")
    func droppedCount() {
        #expect(UploadOutcome.droppedCount(in: Data(#"{"accepted":8,"dropped":2}"#.utf8)) == 2)
        #expect(UploadOutcome.droppedCount(in: Data(#"{"dropped":0,"accepted":3}"#.utf8)) == 0)
        #expect(UploadOutcome.droppedCount(in: Data(#"{"accepted":8}"#.utf8)) == nil)
        #expect(UploadOutcome.droppedCount(in: Data(#"{"dropped":"two"}"#.utf8)) == nil)
        #expect(UploadOutcome.droppedCount(in: Data("[]".utf8)) == nil)
        #expect(UploadOutcome.droppedCount(in: Data()) == nil)
    }

    @Test("Batches hold at most 100 signals")
    func batchSize() async {
        let harness = Harness()
        let client = harness.client()
        for n in 0..<250 { client.signal("Item.viewed", payload: ["n": "\(n)"]) }
        await client.flush()

        #expect(harness.server.requests.map(\.signals.count) == [100, 100, 50])
        #expect(harness.server.signals.map { $0.payload["n"]! } == (0..<250).map { "\($0)" })
    }

    @Test("Batches stay under 256 KB of JSON and big ones are gzipped")
    func batchBytes() async {
        let harness = Harness()
        let client = harness.client()
        var payload: [String: String] = [:]
        for key in 0..<20 { payload["key\(key)"] = String(repeating: "abcdefghij", count: 20) }
        for _ in 0..<80 { client.signal("Big.signal", payload: payload) }
        await client.flush()

        let requests = harness.server.requests
        #expect(requests.count > 1)
        #expect(requests.allSatisfy { $0.body.count <= Limits.maxBodyBytes })
        #expect(requests.allSatisfy { $0.header("Content-Encoding") == "gzip" })
        #expect(requests.map(\.signals.count).reduce(0, +) == 80)
    }

    @Test("400 drops the batch without retrying")
    func malformed() async {
        let harness = Harness()
        harness.server.script([.status(400)])
        let client = harness.client()
        client.signal("A")
        await client.flush()
        await client.flush()

        #expect(harness.server.requests.count == 1)
        #expect(harness.queuedLines == 0)
    }

    @Test("401, 403 and 404 stop sending until the next launch", arguments: [401, 403, 404])
    func unavailable(status: Int) async {
        let harness = Harness()
        harness.server.script([.status(status)])
        let client = harness.client()
        client.signal("A")
        await client.flush()
        client.signal("B")
        harness.clock.advance(by: 7200)
        await client.flush()
        #expect(harness.server.requests.count == 1)
        await client.drain()
        #expect(harness.queuedLines == 2)
        client.shutdown()

        // The next launch tries again and sends everything that was kept.
        let relaunched = harness.client()
        await relaunched.flush()
        #expect(harness.server.requests.count == 2)
        #expect(harness.server.requests.last?.types == ["A", "B"])
    }

    @Test("413 splits the batch until the halves fit")
    func tooLarge() async {
        let harness = Harness { request in
            request.signals.count > 2 ? .status(413) : .accepted
        }
        let client = harness.client()
        for n in 0..<5 { client.signal("S\(n)") }
        await client.flush()

        let counts = harness.server.requests.map(\.signals.count)
        #expect(counts == [5, 2, 3, 1, 2])
        let accepted = harness.server.requests.filter { $0.signals.count <= 2 }.flatMap(\.types)
        #expect(accepted == ["S0", "S1", "S2", "S3", "S4"])
        #expect(harness.queuedLines == 0)
    }

    @Test("413 for a single signal drops just that signal")
    func tooLargeSingle() async {
        let harness = Harness { request in
            request.types.contains("Huge") ? .status(413) : .accepted
        }
        let client = harness.client()
        client.signal("Before")
        client.signal("Huge")
        client.signal("After")
        await client.flush()

        let accepted = harness.server.requests.filter { !$0.types.contains("Huge") }.flatMap(\.types)
        #expect(accepted == ["Before", "After"])
        #expect(harness.queuedLines == 0)
    }

    @Test("429 and 503 wait for Retry-After", arguments: [429, 503])
    func retryAfter(status: Int) async {
        let harness = Harness()
        harness.server.script([.status(status, headers: ["Retry-After": "120"])])
        let client = harness.client()
        client.signal("A")
        await client.flush()
        #expect(harness.server.requests.count == 1)

        harness.clock.advance(by: 119)
        await client.flush()
        #expect(harness.server.requests.count == 1)

        harness.clock.advance(by: 2)
        await client.flush()
        #expect(harness.server.requests.count == 2)
        #expect(harness.server.requests[1].types == ["A"])
        #expect(harness.queuedLines == 0)
    }

    @Test("Without Retry-After, 503 backs off exponentially")
    func exponential() async {
        let harness = Harness()
        harness.server.script([.status(503), .status(503)])
        let client = harness.client()
        client.signal("A")
        await client.flush() // fails: wait 30 s

        harness.clock.advance(by: 29)
        await client.flush()
        #expect(harness.server.requests.count == 1)

        harness.clock.advance(by: 2)
        await client.flush() // fails again: wait 60 s
        #expect(harness.server.requests.count == 2)

        harness.clock.advance(by: 59)
        await client.flush()
        #expect(harness.server.requests.count == 2)

        harness.clock.advance(by: 2)
        await client.flush() // accepted
        #expect(harness.server.requests.count == 3)
        #expect(harness.queuedLines == 0)
    }

    @Test("Server errors and network errors keep the batch and retry", arguments: [Reply.status(500), .status(502), .status(408), .networkError])
    func transient(reply: Reply) async {
        let harness = Harness()
        harness.server.script([reply])
        let client = harness.client()
        client.signal("A")
        await client.flush()
        #expect(harness.queuedLines == 1)

        harness.clock.advance(by: 31)
        await client.flush()
        #expect(harness.server.requests.count == 2)
        #expect(harness.server.requests[1].types == ["A"])
        #expect(harness.queuedLines == 0)
    }

    @Test("A success resets the backoff")
    func backoffResets() async {
        let harness = Harness()
        harness.server.script([.status(500), .accepted, .status(500)])
        let client = harness.client()
        client.signal("A")
        await client.flush()
        harness.clock.advance(by: 31)
        await client.flush() // accepted
        client.signal("B")
        await client.flush() // fails: the first failure again, so 30 s
        harness.clock.advance(by: 31)
        await client.flush()
        #expect(harness.server.requests.map(\.types) == [["A"], ["A"], ["B"], ["B"]])
    }

    @Test("Backoff doubles from 30 s up to an hour, and caps Retry-After too")
    func backoffSteps() {
        var backoff = Backoff()
        let delays = (0..<10).map { _ in backoff.next(retryAfter: nil, jitter: 1) }
        #expect(delays == [30, 60, 120, 240, 480, 960, 1920, 3600, 3600, 3600])
        #expect(backoff.next(retryAfter: 86_400, jitter: 1) == 3600)
        #expect(backoff.next(retryAfter: 5, jitter: 1) == 5)
        var jittered = Backoff()
        #expect(jittered.next(retryAfter: nil, jitter: 0.8) == 24)
    }

    @Test("Response codes map to the protocol's actions")
    func classification() {
        #expect(UploadOutcome.classify(status: 202, retryAfter: nil) == .accepted)
        #expect(UploadOutcome.classify(status: 400, retryAfter: nil) == .rejected)
        #expect(UploadOutcome.classify(status: 422, retryAfter: nil) == .rejected)
        #expect(UploadOutcome.classify(status: 401, retryAfter: nil) == .unavailable)
        #expect(UploadOutcome.classify(status: 403, retryAfter: nil) == .unavailable)
        #expect(UploadOutcome.classify(status: 413, retryAfter: nil) == .tooLarge)
        #expect(UploadOutcome.classify(status: 429, retryAfter: "7") == .slowDown(retryAfter: 7))
        #expect(UploadOutcome.classify(status: 503, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT") == .slowDown(retryAfter: nil))
        #expect(UploadOutcome.classify(status: 500, retryAfter: nil) == .failed)
    }

    @Test("The timer sends queued signals on its own")
    func timer() async {
        let harness = Harness()
        let client = harness.client(.init(testMode: false, flushInterval: 0.1, automaticSignals: false))
        client.signal("A")
        let sent = await eventually { !harness.server.requests.isEmpty }
        #expect(sent)
        client.shutdown()
    }

    @Test("Moving to the background sends the queue")
    func backgroundFlush() async {
        let harness = Harness()
        let client = harness.client()
        client.signal("A")
        await client.didEnterBackground()
        #expect(harness.server.requests.count == 1)
    }

    @Test("Signals queued without a network are sent after a restart")
    func persistedAcrossLaunches() async {
        let harness = Harness()
        harness.server.respond { _ in .networkError }
        let first = harness.client()
        first.signal("A")
        first.signal("B")
        await first.flush()
        first.shutdown()
        #expect(harness.queuedLines == 2)

        harness.server.respond { _ in .accepted }
        let second = harness.client()
        await second.flush()
        #expect(harness.server.requests.last?.types == ["A", "B"])
        #expect(harness.queuedLines == 0)
    }
}

extension Harness {
    init(_ responder: @escaping @Sendable (RecordedRequest) -> Reply) {
        self.init(server: MockServer(responder))
    }
}
