import Foundation

/// A value behind a lock, for the little shared state that can't live in an actor
/// because it is read synchronously (the facade's client, test doubles).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Messages for the developer. They are printed in debug builds only and never
/// leave the device.
enum Log {
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[KestrelKit] \(message())")
        #endif
    }
}

/// Where KestrelKit keeps its two small settings: the opt-out switch and the install id.
protocol SettingsStore: Sendable {
    func bool(forKey key: String) -> Bool?
    func string(forKey key: String) -> String?
    func set(_ value: Bool, forKey key: String)
    func set(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
}

enum SettingsKey {
    static let isEnabled = "KestrelKit.isEnabled"
    static let installID = "KestrelKit.installID"
}

extension SettingsStore {
    /// The app's opt-out switch. On unless the app turned it off.
    var isEnabled: Bool {
        bool(forKey: SettingsKey.isEnabled) ?? true
    }
}

/// The app's own `UserDefaults` (in its container; never an app group or iCloud).
struct DefaultsStore: SettingsStore {
    var suiteName: String?

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
