import Foundation

/// Signals waiting to be sent, kept in memory and mirrored to a JSON-lines file
/// (`signals.jsonl`, one encoded signal per line) so they survive restarts.
///
/// New signals are appended to the file; sending or dropping signals rewrites it
/// atomically. A line that isn't a JSON object (a write cut short by a crash) is skipped
/// when the file is read. When the queue holds more than `maxCount` signals or `maxBytes`
/// bytes, the oldest are dropped first. Only used from inside the ``Engine`` actor.
struct DiskQueue {
    let fileURL: URL
    let maxCount: Int
    let maxBytes: Int
    private(set) var lines: [Data] = []
    private var bytes = 0

    init(directory: URL, maxCount: Int, maxBytes: Int = 5 * 1024 * 1024) {
        self.fileURL = directory.appendingPathComponent("signals.jsonl")
        self.maxCount = max(1, maxCount)
        self.maxBytes = max(Limits.maxBodyBytes, maxBytes)
        Self.prepare(directory)

        guard let data = try? Data(contentsOf: fileURL) else { return }
        let all = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        lines = all.filter(Self.isSignal)
        bytes = lines.reduce(0) { $0 + $1.count }
        let trimmed = trimToLimits()
        if trimmed > 0 || lines.count != all.count || data.last != UInt8(ascii: "\n") {
            rewrite()
        }
    }

    var count: Int { lines.count }
    var isEmpty: Bool { lines.isEmpty }

    /// Adds a signal. Returns how many old signals were dropped to make room.
    @discardableResult
    mutating func append(_ line: Data) -> Int {
        lines.append(line)
        bytes += line.count
        let dropped = trimToLimits()
        if dropped > 0 {
            Log.debug("The queue is full; dropped the \(dropped) oldest signal(s).")
            rewrite()
        } else {
            appendToFile(line)
        }
        return dropped
    }

    /// Forgets the first `count` signals (sent, or dropped by the server).
    mutating func removeFirst(_ count: Int) {
        let count = min(count, lines.count)
        guard count > 0 else { return }
        bytes -= lines.prefix(count).reduce(0) { $0 + $1.count }
        lines.removeFirst(count)
        rewrite()
    }

    mutating func removeAll() {
        lines.removeAll()
        bytes = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private mutating func trimToLimits() -> Int {
        var dropped = 0
        // The newest signal always stays.
        while lines.count - dropped > 1, lines.count - dropped > maxCount || bytes > maxBytes {
            bytes -= lines[dropped].count
            dropped += 1
        }
        if dropped > 0 { lines.removeFirst(dropped) }
        return dropped
    }

    private func appendToFile(_ line: Data) {
        var record = line
        record.append(UInt8(ascii: "\n"))
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: record)
            } else {
                try record.write(to: fileURL, options: .atomic)
            }
        } catch {
            Log.debug("Couldn't write the queue: \(error)")
        }
    }

    private func rewrite() {
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        var data = Data(capacity: bytes + lines.count)
        for line in lines {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.debug("Couldn't write the queue: \(error)")
        }
    }

    private static func isSignal(_ line: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: line)) is [String: Any]
    }

    private static func prepare(_ directory: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.debug("Couldn't create \(directory.path): \(error)")
            return
        }
        #if canImport(Darwin)
        // Queued signals are worth nothing on another device.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
        #endif
    }
}
