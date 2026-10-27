import Foundation

/// Privacy-friendly app analytics for Keen Kestrel.
///
/// ```swift
/// Kestrel.configure(url: URL(string: "https://kestrel.example.com")!, key: "<project key>")
/// Kestrel.signal("Paywall.shown", payload: ["plan": "pro"])
/// ```
///
/// Every call is safe from any thread and returns at once; signals are stamped, queued on
/// disk and sent in batches in the background.
public enum Kestrel {
    /// The version of KestrelKit.
    public static let sdkVersion = kestrelKitVersion

    struct State {
        var client: Client?
        var store: any SettingsStore = DefaultsStore()
        /// Tests replace the live environment.
        var makeEnvironment: (@Sendable (any SettingsStore) -> Environment)?
    }

    static let state = Locked(State())

    /// Starts KestrelKit. Call it once, early, for example in your `App`'s initializer.
    ///
    /// Nothing is sent before this call. Later calls are ignored.
    ///
    /// KestrelKit only sends over HTTPS. An `http://` address is accepted for `localhost` and
    /// in debug builds (for a Kestrel on your own network); in a release build any other
    /// `http://` address is refused, and nothing is stored or sent.
    ///
    /// - Parameters:
    ///   - url: Your Keen Kestrel's address, such as `https://kestrel.example.com`.
    ///   - key: The project's public key: the 32 hex characters from its DSN
    ///     (`https://<key>@kestrel.example.com/1`).
    ///   - configuration: Test mode, flush interval, default payload and more.
    public static func configure(url: URL, key: String, configuration: Configuration = Configuration()) {
        let client: Client? = state.withLock { state in
            guard state.client == nil else {
                Log.debug("Kestrel.configure was called again; the first configuration stays.")
                return nil
            }
            guard isAllowedEndpoint(url) else {
                Log.debug("KestrelKit sends over https:// only (http:// is allowed for localhost and in debug builds); \(url.absoluteString) is refused and nothing is sent.")
                return nil
            }
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.count != 32 || !key.allSatisfy(\.isHexDigit) {
                Log.debug("The key should be the 32 hex characters from the project's DSN.")
            }
            let environment = state.makeEnvironment?(state.store) ?? .live(store: state.store)
            let client = Client(baseURL: url, key: key, configuration: configuration, environment: environment)
            state.client = client
            return client
        }
        guard let client, client.environment.observesLifecycle else { return }
        Task { @MainActor in
            Lifecycle.observe(client)
        }
    }

    /// Sends a signal: something that happened in the app, such as `Paywall.shown`.
    ///
    /// - Parameters:
    ///   - type: 1–100 characters from `A–Z a–z 0–9 . _ -`; other characters become `_`.
    ///   - payload: At most 20 keys (up to 40 characters) with values up to 200 characters.
    ///     Values that look like an email address, phone number, card number, credential or
    ///     IP address are replaced by `[Filtered]`; keys such as `ip` or `user_agent` are
    ///     dropped.
    public static func signal(_ type: String, payload: [String: String] = [:]) {
        guard let client = state.withLock({ $0.client }) else {
            Log.debug("Kestrel.signal(\"\(type)\") before Kestrel.configure; dropped.")
            return
        }
        client.signal(type, payload: payload)
    }

    /// Sends a signal with numbers, booleans or anything else that describes itself
    /// as text: `Kestrel.signal("Export.finished", payload: ["pages": 12, "pdf": true])`.
    public static func signal(_ type: String, payload: [String: any CustomStringConvertible]) {
        signal(type, payload: payload.mapValues { $0.description })
    }

    /// Sends the queued signals now and returns when done (or when the server asked
    /// KestrelKit to wait). Signals are also sent every 30 seconds and when the app moves to
    /// the background, so most apps never need this.
    public static func flush() async {
        await state.withLock({ $0.client })?.flush()
    }

    /// The app's opt-out switch, remembered across launches. When it's `false`, nothing is
    /// stored or sent, and turning it off deletes the queued signals and the install id.
    public static var isEnabled: Bool {
        get {
            state.withLock { $0.store.isEnabled }
        }
        set {
            let client = state.withLock { state in
                state.store.set(newValue, forKey: SettingsKey.isEnabled)
                return state.client
            }
            if !newValue {
                client?.optOut()
            }
        }
    }
}

extension Kestrel {
    #if DEBUG
    private static let isDebugBuild = true
    #else
    private static let isDebugBuild = false
    #endif

    /// Whether signals may be sent to `url`: `https://`, or `http://` for `localhost` and (when
    /// `allowsInsecure`, which debug builds default to) any other host. A key and the signals
    /// in clear text would be readable on the way.
    static func isAllowedEndpoint(_ url: URL, allowsInsecure: Bool = isDebugBuild) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            return allowsInsecure || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        default:
            return false
        }
    }

    /// Forgets the configured client, for tests.
    static func reset(store: any SettingsStore, makeEnvironment: (@Sendable (any SettingsStore) -> Environment)?) {
        let old = state.withLock { state in
            let old = state.client
            state = State(client: nil, store: store, makeEnvironment: makeEnvironment)
            return old
        }
        old?.shutdown()
    }

    static var client: Client? {
        state.withLock { $0.client }
    }
}
