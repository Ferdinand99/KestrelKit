import Foundation

/// What a signal says about the app and the device. Read once when KestrelKit is configured.
/// Nothing here identifies a person: no IDFA, no IDFV, no device name, no fingerprinting.
struct DeviceInfo: Sendable, Equatable {
    var bundleID: String
    var appVersion: String
    var build: String
    var platform: String
    var osVersion: String
    var model: String
    var locale: String
    var isDebugBuild: Bool
    var isSimulator: Bool
    var isTestFlight: Bool

    static func current(bundle: Bundle = .main) -> DeviceInfo {
        let info = bundle.infoDictionary ?? [:]
        let model = hardwareModel()
        return DeviceInfo(
            bundleID: bundle.bundleIdentifier ?? "unknown",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            platform: platform(model: model),
            osVersion: osVersion(ProcessInfo.processInfo.operatingSystemVersion),
            model: model,
            locale: localeIdentifier(Locale.current.identifier),
            isDebugBuild: isDebugBuild,
            isSimulator: isSimulator,
            isTestFlight: isTestFlight(bundle: bundle)
        )
    }

    /// `18.2`, or `18.2.1` when there is a patch version.
    static func osVersion(_ version: OperatingSystemVersion) -> String {
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    /// `nb_NO`, without keywords such as `@calendar=…`.
    static func localeIdentifier(_ identifier: String) -> String {
        let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        return base.isEmpty ? "unknown" : base
    }

    /// The protocol's platform name. iPads report iPadOS; Mac Catalyst apps and iPhone or iPad
    /// apps running on a Mac report macOS.
    static func platform(model: String) -> String {
        #if os(visionOS)
        return "visionOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(iOS)
        #if targetEnvironment(macCatalyst)
        return "macOS"
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "macOS" }
        return model.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #endif
        #elseif os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "unknown"
        #endif
    }

    /// The hardware model identifier, such as `iPhone16,2` or `Mac14,2`.
    static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !model.isEmpty {
            return model
        }
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        if let model = sysctlString("hw.model") { return model }
        #elseif os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac, let model = sysctlString("hw.model") { return model }
        #endif
        return machine()
    }

    /// `utsname.machine`: the model on iPhone, iPad, Apple TV, Apple Watch and Vision Pro.
    static func machine() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    #if canImport(Darwin)
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
    #endif

    /// Whether this is a debug build. Xcode builds Swift packages with the app's
    /// configuration, so this follows the app.
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// TestFlight builds carry a sandbox App Store receipt (`sandboxReceipt`); App Store builds
    /// carry `receipt`, and builds from Xcode have none. On macOS the receipt has the same
    /// name in both cases, so Mac TestFlight builds aren't detected yet (see the README).
    static func isTestFlight(bundle: Bundle) -> Bool {
        #if canImport(Darwin) && !os(macOS) && !targetEnvironment(simulator)
        return bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #else
        return false
        #endif
    }
}
