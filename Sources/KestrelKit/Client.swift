import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything the engine does, in the order the app asked for it.
enum Command: Sendable {
    case signal(type: String, payload: [String: String], time: Date)
    case tick
    case flush(CheckedContinuation<Void, Never>)
    case background(time: Date, done: CheckedContinuation<Void, Never>?)
    case foreground(time: Date)
    case optOut
    case barrier(CheckedContinuation<Void, Never>)

    /// Lets whoever waits for this command go, for a command that will never be handled.
    func abandon() {
        switch self {
        case let .flush(done), let .barrier(done):
            done.resume()
        case let .background(_, done):
            done?.resume()
        case .signal, .tick, .foreground, .optOut:
            break
        }
    }
}

/// The outside world, swappable in tests.
struct Environment: Sendable {
    var store: any SettingsStore
    /// Where the queue file lives.
    var directory: URL
    var session: URLSession
    var device: DeviceInfo
    var now: @Sendable () -> Date = { Date() }
    /// A backoff jitter factor in 0...1.
    var jitter: @Sendable () -> Double = { Double.random(in: 0.8...1.0) }
    /// Whether to follow the app's lifecycle (UIKit, AppKit or WatchKit notifications).
    var observesLifecycle = true

    static func live(store: any SettingsStore) -> Environment {
        let device = DeviceInfo.current()
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = device.bundleID.replacingOccurrences(of: "/", with: "_")
        let directory = support
            .appendingPathComponent("KestrelKit", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return Environment(
            store: store,
            directory: directory,
            session: TransportDelegate.makeSession(configuration),
            device: device
        )
    }
}

/// One configured KestrelKit: takes calls from any thread without blocking and hands them,
/// in order, to the ``Engine`` actor through an `AsyncStream`.
final class Client: Sendable {
    /// The most commands waiting for the engine. When the engine is stuck (a slow network
    /// call, say) and an app sends signals faster than that, the oldest commands go first.
    static let maxPendingCommands = 1_000

    let configuration: Kestrel.Configuration
    let environment: Environment
    private let continuation: AsyncStream<Command>.Continuation
    private let uploader: Uploader
    private let timer: Task<Void, Never>?

    init(baseURL: URL, key: String, configuration: Kestrel.Configuration, environment: Environment) {
        self.configuration = configuration
        self.environment = environment

        let (stream, continuation) = AsyncStream.makeStream(
            of: Command.self,
            bufferingPolicy: .bufferingNewest(Self.maxPendingCommands)
        )
        self.continuation = continuation

        let uploader = Uploader(endpoint: Uploader.endpoint(for: baseURL), key: key, session: environment.session)
        self.uploader = uploader
        let engine = Engine(uploader: uploader, configuration: configuration, environment: environment)
        Task {
            for await command in stream {
                await engine.handle(command)
            }
        }

        let interval = configuration.flushInterval
        if interval > 0 {
            timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    if case .terminated = Self.enqueue(.tick, on: continuation) { break }
                }
            }
        } else {
            timer = nil
        }

        if !environment.store.isEnabled {
            // Opted out in an earlier run: make sure nothing is left behind.
            Self.enqueue(.optOut, on: continuation)
        } else if configuration.automaticSignals {
            Self.enqueue(.signal(type: "App.launched", payload: [:], time: environment.now()), on: continuation)
        }
    }

    deinit {
        shutdown()
    }

    var isEnabled: Bool {
        environment.store.isEnabled
    }

    func signal(_ type: String, payload: [String: String] = [:]) {
        guard isEnabled else { return }
        Self.enqueue(.signal(type: type, payload: payload, time: environment.now()), on: continuation)
    }

    func flush() async {
        await send { .flush($0) }
    }

    /// The app moved to the background: remember when (for sessions) and send the queue.
    func didEnterBackground() async {
        let time = environment.now()
        await send { .background(time: time, done: $0) }
    }

    /// The app is back: a new session starts if it was away for 5 minutes or more.
    func willEnterForeground() {
        Self.enqueue(.foreground(time: environment.now()), on: continuation)
    }

    /// Deletes the queue and the install id, and stops the upload in flight at once. The engine
    /// is busy while it waits for the server, so the opt-out can't wait for its turn.
    func optOut() {
        uploader.control.cancel()
        Self.enqueue(.optOut, on: continuation)
    }

    /// Returns once everything sent to the engine before it has been handled.
    func drain() async {
        await send { .barrier($0) }
    }

    func shutdown() {
        timer?.cancel()
        continuation.finish()
    }

    /// Hands a command to the engine. When the stream is full, the oldest command is dropped:
    /// its waiter is let go, and an opt-out is put back, because that one must not get lost.
    @discardableResult
    static func enqueue(
        _ command: Command,
        on continuation: AsyncStream<Command>.Continuation
    ) -> AsyncStream<Command>.Continuation.YieldResult {
        let result = continuation.yield(command)
        guard case let .dropped(oldest) = result else { return result }
        oldest.abandon()
        guard case .optOut = oldest else { return result }
        if case .optOut = command { return result }
        return enqueue(oldest, on: continuation)
    }

    private func send(_ command: (CheckedContinuation<Void, Never>) -> Command) async {
        await withCheckedContinuation { done in
            if case .terminated = Self.enqueue(command(done), on: continuation) {
                done.resume()
            }
        }
    }
}
