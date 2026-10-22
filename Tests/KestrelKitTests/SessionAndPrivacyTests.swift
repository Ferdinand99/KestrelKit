import Foundation
import Testing
@testable import KestrelKit

@Suite("Sessions")
struct SessionTests {
    @Test("A new session starts after 5 minutes or more in the background, not before")
    func rollover() async {
        let harness = Harness()
        let client = harness.client(.init(testMode: false, flushInterval: 0, automaticSignals: true))
        client.signal("A")

        await client.didEnterBackground()
        harness.clock.advance(by: 299)
        client.willEnterForeground()
        client.signal("B")

        await client.didEnterBackground()
        harness.clock.advance(by: 300)
        client.willEnterForeground()
        client.signal("C")
        await client.flush()

        let signals = harness.server.signals
        #expect(signals.map(\.type) == ["App.launched", "A", "B", "Session.started", "C"])
        let sessions = signals.map(\.sessionID)
        #expect(Set(sessions[0...2]).count == 1)
        #expect(sessions[3] == sessions[4])
        #expect(sessions[3] != sessions[0])
        #expect(UUID(uuidString: sessions[0]) != nil)
    }

    @Test("Without automatic signals the session still rolls over, silently")
    func silentRollover() async {
        let harness = Harness()
        let client = harness.client()
        client.signal("A")
        await client.didEnterBackground()
        harness.clock.advance(by: 600)
        client.willEnterForeground()
        client.signal("B")
        await client.flush()

        let signals = harness.server.signals
        #expect(signals.map(\.type) == ["A", "B"])
        #expect(signals[0].sessionID != signals[1].sessionID)
    }

    @Test("Each launch is a new session with App.launched")
    func launch() async {
        let harness = Harness()
        let configuration = Kestrel.Configuration(testMode: false, flushInterval: 0)
        let first = harness.client(configuration)
        await first.flush()
        first.shutdown()
        let second = harness.client(configuration)
        await second.flush()

        let signals = harness.server.signals
        #expect(signals.map(\.type) == ["App.launched", "App.launched"])
        #expect(signals[0].sessionID != signals[1].sessionID)
        #expect(signals[0].installID == signals[1].installID)
    }
}

@Suite("Privacy and gating")
struct PrivacyTests {
    @Test("The install id is a random UUID, kept across launches")
    func installID() async {
        let harness = Harness()
        let first = harness.client()
        first.signal("A")
        await first.flush()
        first.shutdown()
        let second = harness.client()
        second.signal("B")
        await second.flush()

        let ids = harness.server.signals.map(\.installID)
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1])
        #expect(UUID(uuidString: ids[0]) != nil)
        #expect(harness.store.string(forKey: SettingsKey.installID) == ids[0])
    }

    @Test("When opted out, nothing is stored or sent")
    func optedOut() async {
        let harness = Harness()
        harness.store.set(false, forKey: SettingsKey.isEnabled)
        let client = harness.client(.init(testMode: false, flushInterval: 0, automaticSignals: true))
        client.signal("A")
        await client.flush()

        #expect(harness.server.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.queueFile.path))
        #expect(harness.store.string(forKey: SettingsKey.installID) == nil)
    }

    @Test("Opting out deletes the queue and the install id; opting in starts fresh")
    func optOutAndBackIn() async {
        let harness = Harness()
        harness.server.respond { _ in .networkError }
        let client = harness.client()
        client.signal("A")
        await client.drain()
        let oldID = harness.store.string(forKey: SettingsKey.installID)
        #expect(oldID != nil)
        #expect(harness.queuedLines == 1)

        harness.store.set(false, forKey: SettingsKey.isEnabled)
        client.optOut()
        client.signal("B")
        await client.drain()
        #expect(harness.queuedLines == 0)
        #expect(harness.store.string(forKey: SettingsKey.installID) == nil)

        harness.store.set(true, forKey: SettingsKey.isEnabled)
        harness.server.respond { _ in .accepted }
        client.signal("C")
        harness.clock.advance(by: 3600)
        await client.flush()
        #expect(harness.server.signals.last?.type == "C")
        #expect(harness.server.signals.last?.installID != oldID)
        #expect(!harness.server.signals.contains { $0.type == "A" || $0.type == "B" })
    }

    @Test("Debug and test signals are sent but flagged by default")
    func flagged() async {
        let harness = Harness()
        let client = harness.client(.init(testMode: true, flushInterval: 0, automaticSignals: false))
        client.signal("A")
        await client.flush()
        #expect(harness.server.signals.first?.flags.debug == true)
    }

    @Test("Debug and test signals can be dropped entirely")
    func dropped() async {
        let harness = Harness()
        let client = harness.client(.init(debugSignals: .drop, testMode: true, flushInterval: 0, automaticSignals: true))
        client.signal("A")
        await client.flush()
        #expect(harness.server.requests.isEmpty)
        #expect(harness.queuedLines == 0)
    }

    @Test("Release signals aren't flagged, and the device flags come through")
    func releaseFlags() async {
        let harness = Harness()
        var environment = harness.environment
        environment.device.isTestFlight = true
        environment.device.isSimulator = true
        let client = Client(
            baseURL: harness.server.baseURL,
            key: TestKey.value,
            configuration: .init(debugSignals: .drop, testMode: false, flushInterval: 0, automaticSignals: false),
            environment: environment
        )
        client.signal("A")
        await client.flush()
        #expect(harness.server.signals.first?.flags == .init(debug: false, testflight: true, simulator: true))
    }

    @Test("Payload values are scrubbed and the default payload is merged")
    func payloads() async {
        let harness = Harness()
        let client = harness.client(.init(testMode: false, flushInterval: 0, defaultPayload: ["plan": "free", "tier": "1"], automaticSignals: false))
        client.signal("Signed.up", payload: ["email": "jane@example.com", "plan": "pro"])
        await client.flush()
        #expect(harness.server.signals.first?.payload == ["email": "[Filtered]", "plan": "pro", "tier": "1"])
    }

    @Test("Invalid types are cleaned, empty ones dropped")
    func types() async {
        let harness = Harness()
        let client = harness.client()
        client.signal("Paywall shown")
        client.signal("  ")
        await client.flush()
        #expect(harness.server.signals.map(\.type) == ["Paywall_shown"])
    }
}
