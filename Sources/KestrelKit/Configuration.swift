import Foundation

extension Kestrel {
    /// Options for ``Kestrel/configure(url:key:configuration:)``. The defaults suit most apps.
    public struct Configuration: Sendable {
        /// What happens to signals from debug builds and from test mode.
        public enum DebugSignals: Sendable {
            /// Send them with `flags.debug` set, so the dashboards can show or hide them. The default.
            case flag
            /// Drop them on the device; nothing is stored or sent.
            case drop
        }

        /// What happens to signals from debug builds and from test mode. Default: ``DebugSignals/flag``.
        public var debugSignals: DebugSignals

        /// Treats every signal as a test signal (`true`) or as a real one (`false`).
        /// `nil`, the default, means "test signals when the app is a debug build".
        /// Turn it on for UI tests or internal builds, for example.
        public var testMode: Bool?

        /// How often queued signals are sent, in seconds. Default: 30.
        /// They are also sent when the app moves to the background. `0` turns the timer off.
        public var flushInterval: TimeInterval

        /// Payload added to every signal. A signal's own payload wins when a key is in both.
        public var defaultPayload: [String: String]

        /// Sends `App.launched` when KestrelKit is configured and `Session.started` when a
        /// new session starts after 5 minutes or more in the background. Default: on.
        public var automaticSignals: Bool

        /// The most signals kept on the device while they wait to be sent. When the queue is
        /// full, the oldest are dropped first. Default: 5,000.
        public var maxQueuedSignals: Int

        public init(
            debugSignals: DebugSignals = .flag,
            testMode: Bool? = nil,
            flushInterval: TimeInterval = 30,
            defaultPayload: [String: String] = [:],
            automaticSignals: Bool = true,
            maxQueuedSignals: Int = 5_000
        ) {
            self.debugSignals = debugSignals
            self.testMode = testMode
            self.flushInterval = flushInterval
            self.defaultPayload = defaultPayload
            self.automaticSignals = automaticSignals
            self.maxQueuedSignals = maxQueuedSignals
        }
    }
}
