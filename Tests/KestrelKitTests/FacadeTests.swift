import Foundation
import Testing
@testable import KestrelKit

/// The public `Kestrel` API. It has global state, so these tests run one at a time.
@Suite("Kestrel API", .serialized)
struct FacadeTests {
    let harness = Harness()

    init() {
        let harness = harness
        Kestrel.reset(store: harness.store) { _ in harness.environment }
    }

    @Test("Nothing is sent or stored before configure")
    func nothingBeforeConfigure() async {
        Kestrel.signal("Too.early")
        await Kestrel.flush()
        #expect(Kestrel.client == nil)
        #expect(harness.server.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.path))

        Kestrel.configure(url: harness.server.baseURL, key: TestKey.value, configuration: .init(testMode: false, flushInterval: 0))
        await Kestrel.flush()
        #expect(harness.server.signals.map(\.type) == ["App.launched"])
    }

    @Test("configure, signal and flush")
    func quickStart() async {
        Kestrel.configure(url: harness.server.baseURL, key: TestKey.value, configuration: .init(testMode: false, flushInterval: 0, automaticSignals: false))
        Kestrel.signal("Plain")
        Kestrel.signal("Strings", payload: ["plan": "pro"])
        Kestrel.signal("Values", payload: ["pages": 12, "pdf": true, "ratio": 0.5, "name": "report"])
        await Kestrel.flush()

        let signals = harness.server.signals
        #expect(signals.map(\.type) == ["Plain", "Strings", "Values"])
        #expect(signals[1].payload == ["plan": "pro"])
        #expect(signals[2].payload == ["pages": "12", "pdf": "true", "ratio": "0.5", "name": "report"])
    }

    @Test("A second configure is ignored")
    func configureOnce() async {
        let other = MockServer()
        Kestrel.configure(url: harness.server.baseURL, key: TestKey.value, configuration: .init(testMode: false, flushInterval: 0, automaticSignals: false))
        let first = Kestrel.client
        Kestrel.configure(url: other.baseURL, key: TestKey.value)
        #expect(Kestrel.client === first)

        Kestrel.signal("A")
        await Kestrel.flush()
        #expect(harness.server.signals.map(\.type) == ["A"])
        #expect(other.requests.isEmpty)
    }

    @Test("isEnabled is remembered and stops everything")
    func optOut() async {
        #expect(Kestrel.isEnabled)
        Kestrel.configure(url: harness.server.baseURL, key: TestKey.value, configuration: .init(testMode: false, flushInterval: 0, automaticSignals: false))
        Kestrel.isEnabled = false
        #expect(!Kestrel.isEnabled)
        #expect(harness.store.bool(forKey: SettingsKey.isEnabled) == false)

        Kestrel.signal("A")
        await Kestrel.flush()
        #expect(harness.server.requests.isEmpty)

        Kestrel.isEnabled = true
        Kestrel.signal("B")
        await Kestrel.flush()
        #expect(harness.server.signals.map(\.type) == ["B"])
    }
}
