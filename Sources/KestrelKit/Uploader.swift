import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the server said about a batch, reduced to what the SDK does next (docs/protocol.md).
enum UploadOutcome: Equatable, Sendable {
    /// 2xx: done.
    case accepted
    /// 400 and other 4xx: the batch can never succeed; drop it and don't retry.
    case rejected
    /// 401, 403 (wrong or disabled key, analytics off) and 404 (a server without app
    /// analytics): stop sending until the next launch, keep the queue.
    case unavailable
    /// 413: split the batch and send the halves.
    case tooLarge
    /// 429 and 503: wait `Retry-After` seconds, or back off when it's missing.
    case slowDown(retryAfter: TimeInterval?)
    /// Other 5xx, 408, or no answer: keep the batch and retry with backoff.
    case failed

    static func classify(status: Int, retryAfter: String?) -> UploadOutcome {
        switch status {
        case 200..<300: return .accepted
        case 401, 403, 404: return .unavailable
        case 408: return .failed
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
}

/// Posts batches to `{baseURL}/ingest/v1/signals`.
struct Uploader: Sendable {
    let endpoint: URL
    let key: String
    let session: URLSession

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
        let request = request(for: body)
        let answer: (status: Int, retryAfter: String?)? = await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request) { _, response, _ in
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (http.statusCode, Self.header("Retry-After", in: http)))
            }
            task.resume()
        }
        guard let answer else { return .failed }
        return UploadOutcome.classify(status: answer.status, retryAfter: answer.retryAfter)
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
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
