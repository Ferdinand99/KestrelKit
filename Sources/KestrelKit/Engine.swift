import Foundation

/// The single place where signals are stamped, queued and sent. Commands arrive one at a
/// time from the ``Client``'s stream, so the queue, the session and the backoff state never
/// race. File and network work happens here, never on the caller's thread.
actor Engine {
    /// A new session starts after this long in the background.
    static let sessionTimeout: TimeInterval = 5 * 60

    private let uploader: Uploader
    private let configuration: Kestrel.Configuration
    private let environment: Environment
    private let encoder = Wire.makeEncoder()
    private let app: WireSignal.App
    private let device: WireSignal.Device

    private var storedQueue: DiskQueue?
    private var installID: String?
    private var sessionID = UUID().uuidString
    private var backgroundedAt: Date?
    private var backoff = Backoff()
    private var retryAt: Date?
    /// Set after 401, 403 or 404; cleared by the next launch.
    private var stoppedUntilRelaunch = false

    init(uploader: Uploader, configuration: Kestrel.Configuration, environment: Environment) {
        self.uploader = uploader
        self.configuration = configuration
        self.environment = environment
        let info = environment.device
        app = WireSignal.App(
            bundleID: Limits.field(info.bundleID),
            version: Limits.field(info.appVersion),
            build: Limits.field(info.build)
        )
        device = WireSignal.Device(
            platform: Limits.field(info.platform),
            osVersion: Limits.field(info.osVersion),
            model: Limits.field(info.model),
            locale: Limits.field(info.locale)
        )
    }

    func handle(_ command: Command) async {
        switch command {
        case let .signal(type, payload, time):
            record(type, payload: payload, at: time)
        case .tick:
            await flush()
        case let .flush(done):
            await flush()
            done.resume()
        case let .background(time, done):
            backgroundedAt = time
            await flush()
            done?.resume()
        case let .foreground(time):
            foreground(at: time)
        case .optOut:
            optOut()
        case let .barrier(done):
            done.resume()
        }
    }

    // MARK: - Recording

    private var isEnabled: Bool {
        environment.store.isEnabled
    }

    private var isTest: Bool {
        configuration.testMode ?? environment.device.isDebugBuild
    }

    private func record(_ rawType: String, payload: [String: String], at time: Date) {
        guard isEnabled else { return }
        guard let type = Limits.signalType(rawType) else {
            Log.debug("Dropped a signal with an empty type.")
            return
        }
        if type != rawType {
            Log.debug("Signal type \"\(rawType)\" is sent as \"\(type)\" (allowed: A–Z, a–z, 0–9, . _ -, at most \(Limits.maxTypeLength)).")
        }
        if isTest, configuration.debugSignals == .drop { return }

        let signal = WireSignal(
            type: type,
            time: Wire.timestamp(time),
            installID: currentInstallID(),
            sessionID: sessionID,
            app: app,
            device: device,
            flags: WireSignal.Flags(
                debug: isTest,
                testflight: environment.device.isTestFlight,
                simulator: environment.device.isSimulator
            ),
            payload: Limits.payload(payload, defaults: configuration.defaultPayload)
        )
        do {
            let line = try encoder.encode(signal)
            withQueue { $0.append(line) }
        } catch {
            Log.debug("Couldn't encode signal \(type): \(error)")
        }
    }

    /// A random UUID, created once and kept in the app's own defaults.
    private func currentInstallID() -> String {
        if let installID { return installID }
        let id: String
        if let stored = environment.store.string(forKey: SettingsKey.installID), !stored.isEmpty {
            id = stored
        } else {
            id = UUID().uuidString
            environment.store.set(id, forKey: SettingsKey.installID)
        }
        installID = id
        return id
    }

    private func foreground(at time: Date) {
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt, time.timeIntervalSince(since) >= Self.sessionTimeout else { return }
        sessionID = UUID().uuidString
        if configuration.automaticSignals {
            record("Session.started", payload: [:], at: time)
        }
    }

    private func optOut() {
        withQueue { $0.removeAll() }
        environment.store.removeValue(forKey: SettingsKey.installID)
        installID = nil
        retryAt = nil
        backoff.reset()
    }

    @discardableResult
    private func withQueue<Result>(_ body: (inout DiskQueue) -> Result) -> Result {
        if storedQueue == nil {
            storedQueue = DiskQueue(directory: environment.directory, maxCount: configuration.maxQueuedSignals)
        }
        return body(&storedQueue!)
    }

    // MARK: - Sending

    private enum Stop {
        case unavailable
        case backoff(retryAfter: TimeInterval?)
    }

    private func flush() async {
        guard isEnabled, !stoppedUntilRelaunch else { return }
        if let retryAt, environment.now() < retryAt { return }

        while true {
            let batch = nextBatch()
            guard !batch.isEmpty else { return }
            let (handled, stop) = await deliver(batch)
            withQueue { $0.removeFirst(handled) }
            switch stop {
            case nil:
                backoff.reset()
                retryAt = nil
            case .unavailable:
                stoppedUntilRelaunch = true
                Log.debug("The server refused the key or has app analytics turned off; nothing more is sent until the next launch.")
                return
            case let .backoff(retryAfter):
                let delay = backoff.next(retryAfter: retryAfter, jitter: environment.jitter())
                retryAt = environment.now().addingTimeInterval(delay)
                Log.debug("Sending failed; trying again in \(Int(delay)) s.")
                return
            }
        }
    }

    /// The oldest signals that fit in one request: at most 100 and 256 KB of body.
    private func nextBatch() -> [Data] {
        withQueue { queue in
            var size = Wire.envelopeSize
            var count = 0
            for line in queue.lines.prefix(Limits.maxSignalsPerRequest) {
                let added = line.count + (count > 0 ? 1 : 0)
                if count > 0, size + added > Limits.maxBodyBytes { break }
                size += added
                count += 1
            }
            return Array(queue.lines.prefix(count))
        }
    }

    /// Sends `lines`, splitting on 413. Returns how many of the first lines are done with
    /// (accepted or dropped) and why it stopped early, if it did.
    private func deliver(_ lines: ArraySlice<Data>) async -> (handled: Int, stop: Stop?) {
        let body = Wire.body(lines: lines, sentAt: environment.now())
        switch await uploader.send(body) {
        case .accepted:
            return (lines.count, nil)
        case .rejected:
            Log.debug("The server rejected a batch of \(lines.count) signal(s) as malformed; dropped it.")
            return (lines.count, nil)
        case .unavailable:
            return (0, .unavailable)
        case let .slowDown(retryAfter):
            return (0, .backoff(retryAfter: retryAfter))
        case .failed:
            return (0, .backoff(retryAfter: nil))
        case .tooLarge:
            guard lines.count > 1 else {
                Log.debug("The server found a single signal too large; dropped it.")
                return (1, nil)
            }
            let middle = lines.startIndex + lines.count / 2
            let first = await deliver(lines[..<middle])
            if first.stop != nil { return first }
            let second = await deliver(lines[middle...])
            return (first.handled + second.handled, second.stop)
        }
    }

    private func deliver(_ lines: [Data]) async -> (handled: Int, stop: Stop?) {
        await deliver(lines[...])
    }
}
