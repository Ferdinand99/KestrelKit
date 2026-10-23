import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import KestrelKit

// MARK: - Settings and clock

final class MemoryStore: SettingsStore, @unchecked Sendable {
    private let values = Locked<[String: Any]>([:])

    func bool(forKey key: String) -> Bool? { values.withLock { $0[key] as? Bool } }
    func string(forKey key: String) -> String? { values.withLock { $0[key] as? String } }
    func set(_ value: Bool, forKey key: String) { values.withLock { $0[key] = value } }
    func set(_ value: String, forKey key: String) { values.withLock { $0[key] = value } }
    func removeValue(forKey key: String) { _ = values.withLock { $0.removeValue(forKey: key) } }
}

final class TestClock: Sendable {
    private let current = Locked(Date(timeIntervalSince1970: 1_792_695_598.123))

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

// MARK: - A fake Kestrel behind URLProtocol

struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    /// The body as sent (possibly gzip).
    var rawBody: Data
    /// The body after gunzip.
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var signals: [WireSignal] {
        (try? JSONDecoder().decode(Batch.self, from: body))?.signals ?? []
    }

    var types: [String] { signals.map(\.type) }

    struct Batch: Decodable {
        var sentAt: String
        var sdk: [String: String]
        var signals: [WireSignal]

        enum CodingKeys: String, CodingKey {
            case sentAt = "sent_at"
            case sdk
            case signals
        }
    }
}

enum Reply: Sendable {
    /// `body` is sent as given; without one, a 202 says `{"accepted":1}` and others say nothing.
    case status(Int, headers: [String: String] = [:], body: String? = nil)
    case networkError

    static let accepted = Reply.status(202)
}

/// One fake server per test, on its own host name, so tests can run in parallel.
final class MockServer: Sendable {
    let host = "kestrel-\(UUID().uuidString.lowercased()).test"
    private let state = Locked<(requests: [RecordedRequest], responder: @Sendable (RecordedRequest) -> Reply)>(
        (requests: [], responder: { _ in .accepted })
    )

    init(_ responder: @escaping @Sendable (RecordedRequest) -> Reply = { _ in .accepted }) {
        state.withLock { $0.responder = responder }
        MockURLProtocol.servers.withLock { $0[host] = self }
    }

    var baseURL: URL { URL(string: "https://\(host)")! }

    var requests: [RecordedRequest] { state.withLock { $0.requests } }

    var signals: [WireSignal] { requests.flatMap(\.signals) }

    func respond(_ responder: @escaping @Sendable (RecordedRequest) -> Reply) {
        state.withLock { $0.responder = responder }
    }

    /// Replies with each of `replies` in turn, then with 202.
    func script(_ replies: [Reply]) {
        let remaining = Locked(replies)
        respond { _ in
            remaining.withLock { $0.isEmpty ? .accepted : $0.removeFirst() }
        }
    }

    func handle(_ request: RecordedRequest) -> Reply {
        state.withLock { state in
            state.requests.append(request)
            return state.responder(request)
        }
    }
}

final class MockURLProtocol: URLProtocol {
    static let servers = Locked<[String: MockServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let raw = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let headers = request.allHTTPHeaderFields ?? [:]
        let gzipped = headers.contains { $0.key.lowercased() == "content-encoding" && $0.value == "gzip" }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            headers: headers,
            rawBody: raw,
            body: gzipped ? gunzip(raw) : raw
        )
        switch server.handle(recorded) {
        case let .status(code, replyHeaders, replyBody):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: replyHeaders)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = replyBody.map { Data($0.utf8) } ?? (code == 202 ? Data(#"{"accepted":1}"#.utf8) : Data())
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - Clients

struct Harness {
    let server: MockServer
    let clock: TestClock
    let store: MemoryStore
    let directory: URL

    init(server: MockServer = MockServer(), store: MemoryStore = MemoryStore(), directory: URL? = nil) {
        self.server = server
        self.clock = TestClock()
        self.store = store
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrelkit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    var environment: Environment {
        let clock = clock
        return Environment(
            store: store,
            directory: directory,
            session: mockSession(),
            device: .fixture,
            now: { clock.now },
            jitter: { 1 },
            observesLifecycle: false
        )
    }

    /// A client like a fresh launch of the app. No timer and no automatic signals unless asked.
    func client(_ configuration: Kestrel.Configuration = .init(testMode: false, flushInterval: 0, automaticSignals: false)) -> Client {
        Client(baseURL: server.baseURL, key: TestKey.value, configuration: configuration, environment: environment)
    }

    var queueFile: URL { directory.appendingPathComponent("signals.jsonl") }

    var queuedLines: Int {
        guard let data = try? Data(contentsOf: queueFile) else { return 0 }
        return data.split(separator: UInt8(ascii: "\n")).count
    }
}

enum TestKey {
    static let value = "0123456789abcdef0123456789abcdef"
}

extension DeviceInfo {
    static let fixture = DeviceInfo(
        bundleID: "com.example.app",
        appVersion: "1.4.0",
        build: "57",
        platform: "iOS",
        osVersion: "18.2",
        model: "iPhone16,2",
        locale: "nb_NO",
        isDebugBuild: false,
        isSimulator: false,
        isTestFlight: false
    )
}

/// Waits up to `timeout` seconds for `condition`.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: - gzip

/// Decompresses with the system's `gzip`, an independent check of the encoder.
func gunzip(_ data: Data) -> Data {
    let input = FileManager.default.temporaryDirectory.appendingPathComponent("kestrelkit-\(UUID().uuidString).gz")
    defer { try? FileManager.default.removeItem(at: input) }
    do {
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzipPath)
        process.arguments = ["-dc", input.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? result : Data()
    } catch {
        return Data()
    }
}

let gzipPath = ["/usr/bin/gzip", "/bin/gzip"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/gzip"
