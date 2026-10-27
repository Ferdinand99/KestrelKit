import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the server said about a batch, reduced to what the SDK does next (docs/protocol.md).
enum UploadOutcome: Equatable, Sendable {
    /// `202` with Keen Kestrel's answer (`{"accepted": n}`): done, also when the server dropped
    /// some of the signals (`"dropped": m`).
    case accepted
    /// 400 and other 4xx that trying again won't fix: drop the batch.
    case rejected
    /// 401, 403 (wrong or disabled key, analytics off) and 404 (a server without app
    /// analytics): pause sending for an hour, keep the queue.
    case unavailable
    /// 413: split the batch and send the halves.
    case tooLarge
    /// 429 and 503: wait `Retry-After` seconds, or back off when it's missing.
    case slowDown(retryAfter: TimeInterval?)
    /// Everything else: a 2xx that isn't Kestrel's answer (a captive portal, a proxy), a
    /// redirect, 405, 407, 408, 410, other 5xx, or no answer. Keep the batch and retry with backoff.
    case failed

    static func classify(status: Int, retryAfter: String?, body: Data = Data()) -> UploadOutcome {
        switch status {
        case 202: return isKestrelAnswer(body) ? .accepted : .failed
        case 401, 403, 404: return .unavailable
        // Not Kestrel's verdict on the batch: a proxy, a gateway or a server that moved.
        case 405, 407, 408, 410: return .failed
        case 413: return .tooLarge
        case 429, 503: return .slowDown(retryAfter: retryAfter.flatMap(parseRetryAfter))
        case 400..<500: return .rejected
        default: return .failed
        }
    }

    /// `Retry-After` in seconds. HTTP dates aren't used by Kestrel, so they fall back to backoff.
    static func parseRetryAfter(_ value: String) -> TimeInterval? {
        guard let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds.isFinite else {
            return nil
        }
        return seconds
    }

    /// Whether a `202` body is what Keen Kestrel answers: a JSON object with the number of
    /// stored signals, `{"accepted": 8}` or `{"accepted": 8, "dropped": 2}`.
    static func isKestrelAnswer(_ body: Data) -> Bool {
        struct Answer: Decodable {
            var accepted: Int
            var dropped: Int?
        }
        return (try? JSONDecoder().decode(Answer.self, from: body)).map { $0.accepted >= 0 } ?? false
    }

    /// How many signals a `202` body says the server dropped (`{"accepted": 8, "dropped": 2}`),
    /// or `nil` when it doesn't say. Only for the debug log: the batch is done either way.
    static func droppedCount(in body: Data) -> Int? {
        struct Answer: Decodable {
            var dropped: Int?
        }
        return (try? JSONDecoder().decode(Answer.self, from: body))?.dropped
    }
}

/// Lets the app abort the upload in flight from any thread (the opt-out), and makes sure none
/// starts afterwards.
final class UploadControl: Sendable {
    private let state = Locked<(task: URLSessionTask?, cancelled: Bool)>((task: nil, cancelled: false))

    /// Remembers the task about to run. `false` when sending was cancelled: don't start it.
    func start(_ task: URLSessionTask) -> Bool {
        state.withLock { state in
            guard !state.cancelled else { return false }
            state.task = task
            return true
        }
    }

    func finish() {
        state.withLock { $0.task = nil }
    }

    /// Cancels the upload in flight and refuses new ones until ``reset()``.
    func cancel() {
        state.withLock { state in
            state.cancelled = true
            state.task?.cancel()
        }
    }

    /// Allows uploads again (sending was switched back on).
    func reset() {
        state.withLock { $0.cancelled = false }
    }
}

/// The session's delegate: refuses redirects, caps the size of answers and hands the answer
/// of each task to the ``Uploader`` that is waiting for it.
final class TransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Kestrel's answers are a few dozen bytes; anything bigger isn't from Kestrel.
    static let maxResponseBytes = 64 * 1024

    struct Answer {
        var status: Int
        var retryAfter: String?
        var body: Data
    }

    private struct Pending {
        var continuation: CheckedContinuation<Answer?, Never>
        var body = Data()
        var oversized = false
    }

    private let pending = Locked<[Int: Pending]>([:])

    /// A session with this delegate. The session keeps it alive.
    static func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: TransportDelegate(), delegateQueue: nil)
    }

    func register(_ task: URLSessionTask, _ continuation: CheckedContinuation<Answer?, Never>) {
        pending.withLock { $0[task.taskIdentifier] = Pending(continuation: continuation) }
    }

    func unregister(_ task: URLSessionTask) -> CheckedContinuation<Answer?, Never>? {
        pending.withLock { $0.removeValue(forKey: task.taskIdentifier)?.continuation }
    }

    // The signals and the key are only meant for the configured address, so a redirect is
    // never followed: its response counts as the answer, and it isn't a `202`.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(response.expectedContentLength > Int64(Self.maxResponseBytes) ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = pending.withLock { pending -> Bool in
            guard var entry = pending[dataTask.taskIdentifier] else { return false }
            entry.body.append(data)
            if entry.body.count > Self.maxResponseBytes {
                entry.body = Data()
                entry.oversized = true
            }
            pending[dataTask.taskIdentifier] = entry
            return entry.oversized
        }
        if oversized { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        guard error == nil, !entry.oversized, let http = task.response as? HTTPURLResponse else {
            entry.continuation.resume(returning: nil)
            return
        }
        entry.continuation.resume(returning: Answer(
            status: http.statusCode,
            retryAfter: Uploader.header("Retry-After", in: http),
            body: entry.body
        ))
    }
}

/// Posts batches to `{baseURL}/ingest/v1/signals`.
struct Uploader: Sendable {
    let endpoint: URL
    let key: String
    /// Made by ``TransportDelegate/makeSession(_:)``.
    let session: URLSession
    let control = UploadControl()

    static func endpoint(for baseURL: URL) -> URL {
        baseURL.appendingPathComponent("ingest").appendingPathComponent("v1").appendingPathComponent("signals")
    }

    func request(for body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Kestrel-Key")
        request.setValue("KestrelKit/\(kestrelKitVersion)", forHTTPHeaderField: "User-Agent")
        if body.count >= Gzip.threshold {
            let compressed = Gzip.compress(body)
            if compressed.count < body.count {
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                request.httpBody = compressed
                return request
            }
        }
        request.httpBody = body
        return request
    }

    func send(_ body: Data) async -> UploadOutcome {
        guard let delegate = session.delegate as? TransportDelegate else {
            Log.debug("The session has no TransportDelegate; nothing is sent.")
            return .failed
        }
        let request = request(for: body)
        let answer: TransportDelegate.Answer? = await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            delegate.register(task, continuation)
            guard control.start(task) else {
                // Sending was cancelled while this call was on its way.
                delegate.unregister(task)?.resume(returning: nil)
                return
            }
            task.resume()
        }
        control.finish()
        guard let answer else { return .failed }
        let outcome = UploadOutcome.classify(status: answer.status, retryAfter: answer.retryAfter, body: answer.body)
        if outcome == .accepted, let dropped = UploadOutcome.droppedCount(in: answer.body), dropped > 0 {
            Log.debug("The server dropped \(dropped) signal(s) of a batch because they broke the protocol's limits.")
        }
        return outcome
    }

    static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }
}

/// Exponential backoff after failures: 30 s, 1 min, 2 min … up to 1 hour, with jitter so
/// many devices don't come back at the same moment. `Retry-After` wins when the server
/// sends it (also capped at 1 hour).
struct Backoff: Sendable {
    static let initial: TimeInterval = 30
    static let cap: TimeInterval = 3600

    private(set) var failures = 0

    /// The delay before the next attempt. `jitter` is a factor in 0...1 (1 = no jitter).
    mutating func next(retryAfter: TimeInterval?, jitter: Double) -> TimeInterval {
        failures += 1
        if let retryAfter {
            return min(retryAfter, Self.cap)
        }
        let exponent = min(failures - 1, 16)
        let delay = min(Self.initial * Double(1 << exponent), Self.cap)
        return delay * min(max(jitter, 0), 1)
    }

    mutating func reset() {
        failures = 0
    }
}
