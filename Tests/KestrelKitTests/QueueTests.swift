import Foundation
import Testing
@testable import KestrelKit

@Suite("Disk queue")
struct QueueTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kestrelkit-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    func line(_ n: Int) -> Data {
        Data(#"{"n":\#(n)}"#.utf8)
    }

    @Test("Signals survive a restart")
    func persistence() {
        var queue = DiskQueue(directory: directory, maxCount: 100)
        for n in 0..<5 { queue.append(line(n)) }

        let reopened = DiskQueue(directory: directory, maxCount: 100)
        #expect(reopened.lines == (0..<5).map(line))
    }

    @Test("Removing sent signals is persisted")
    func removeFirst() {
        var queue = DiskQueue(directory: directory, maxCount: 100)
        for n in 0..<5 { queue.append(line(n)) }
        queue.removeFirst(3)
        #expect(queue.lines == [line(3), line(4)])
        #expect(DiskQueue(directory: directory, maxCount: 100).lines == [line(3), line(4)])

        queue.removeFirst(10)
        #expect(queue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: queue.fileURL.path))
    }

    @Test("A full queue drops the oldest signals first")
    func countCap() {
        var queue = DiskQueue(directory: directory, maxCount: 3)
        var dropped = 0
        for n in 0..<5 { dropped += queue.append(line(n)) }
        #expect(dropped == 2)
        #expect(queue.lines == [line(2), line(3), line(4)])
        #expect(DiskQueue(directory: directory, maxCount: 3).lines == [line(2), line(3), line(4)])
    }

    @Test("A full queue appends to the file and rewrites it only now and then")
    func fullQueueRewritesRarely() throws {
        func fileLines(_ queue: DiskQueue) throws -> Int {
            try Data(contentsOf: queue.fileURL).split(separator: UInt8(ascii: "\n")).count
        }
        var queue = DiskQueue(directory: directory, maxCount: 3, compactAfter: 4)
        for n in 0..<5 { queue.append(line(n)) }
        #expect(queue.lines == [line(2), line(3), line(4)])
        // Two signals were dropped from memory, but the file still has them: no rewrite yet.
        #expect(try fileLines(queue) == 5)

        queue.append(line(5))
        #expect(try fileLines(queue) == 6)
        // The fourth dropped signal compacts the file.
        queue.append(line(6))
        #expect(queue.lines == [line(4), line(5), line(6)])
        #expect(try fileLines(queue) == 3)
        #expect(DiskQueue(directory: directory, maxCount: 3).lines == [line(4), line(5), line(6)])
    }

    @Test("Many signals into a full queue keep the file small")
    func fullQueueStaysBounded() throws {
        var queue = DiskQueue(directory: directory, maxCount: 100)
        for n in 0..<1_000 { queue.append(line(n)) }
        let fileLines = try Data(contentsOf: queue.fileURL).split(separator: UInt8(ascii: "\n")).count
        #expect(fileLines <= 100 + queue.compactAfter)
        #expect(DiskQueue(directory: directory, maxCount: 100).lines == (900..<1_000).map(line))
    }

    @Test("A smaller cap on the next launch trims the file")
    func capOnLoad() {
        var queue = DiskQueue(directory: directory, maxCount: 10)
        for n in 0..<6 { queue.append(line(n)) }
        let smaller = DiskQueue(directory: directory, maxCount: 2)
        #expect(smaller.lines == [line(4), line(5)])
    }

    @Test("The byte cap also drops the oldest")
    func byteCap() {
        let big = Data(#"{"v":"\#(String(repeating: "x", count: 100_000))"}"#.utf8)
        var queue = DiskQueue(directory: directory, maxCount: 1000, maxBytes: Limits.maxBodyBytes)
        for _ in 0..<4 { queue.append(big) }
        #expect(queue.count == 2)
    }

    @Test("A line cut short by a crash is skipped and the file repaired")
    func corruptLine() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("signals.jsonl")
        try Data("{\"n\":0}\nnot json\n{\"n\":1}\n{\"n\":2".utf8).write(to: file)

        var queue = DiskQueue(directory: directory, maxCount: 100)
        #expect(queue.lines == [line(0), line(1)])
        queue.append(line(3))
        #expect(DiskQueue(directory: directory, maxCount: 100).lines == [line(0), line(1), line(3)])
    }

    @Test("removeAll deletes the file")
    func removeAll() {
        var queue = DiskQueue(directory: directory, maxCount: 100)
        queue.append(line(1))
        queue.removeAll()
        #expect(!FileManager.default.fileExists(atPath: queue.fileURL.path))
        #expect(DiskQueue(directory: directory, maxCount: 100).isEmpty)
    }
}

@Suite("gzip")
struct GzipTests {
    @Test("CRC-32 matches the reference value")
    func crc() {
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(Gzip.crc32(Data()) == 0)
    }

    @Test("The system gzip decompresses what we compress", arguments: [0, 1, 2, 3, 100, 5_000, 70_000])
    func roundTrip(size: Int) throws {
        try #require(FileManager.default.isExecutableFile(atPath: gzipPath))
        var generator = SplitMix(seed: UInt64(size))
        // Half random bytes, half repetitive JSON, to exercise literals and long matches.
        var input = Data((0..<size / 2).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
        while input.count < size {
            input.append(contentsOf: Array(#"{"type":"App.launched","payload":{"plan":"pro"}},"#.utf8))
        }
        input = input.prefix(size)
        let compressed = Gzip.compress(input)
        #expect(gunzip(compressed) == input)
    }

    @Test("Batches shrink a lot")
    func ratio() throws {
        let line = try Wire.makeEncoder().encode(WireTests.signal)
        let body = Wire.body(lines: Array(repeating: line, count: 100), sentAt: Date())
        let compressed = Gzip.compress(body)
        #expect(compressed.count * 5 < body.count)
        if FileManager.default.isExecutableFile(atPath: gzipPath) {
            #expect(gunzip(compressed) == body)
        }
    }

    @Test("Large bodies are sent gzipped, small ones as they are")
    func requestEncoding() throws {
        let uploader = Uploader(endpoint: URL(string: "https://example.com/ingest/v1/signals")!, key: TestKey.value, session: mockSession())
        let line = try Wire.makeEncoder().encode(WireTests.signal)
        let small = uploader.request(for: Wire.body(lines: [line], sentAt: Date()))
        #expect(small.value(forHTTPHeaderField: "Content-Encoding") == nil)

        let body = Wire.body(lines: Array(repeating: line, count: 20), sentAt: Date())
        let large = uploader.request(for: body)
        #expect(large.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect((large.httpBody?.count ?? .max) < body.count)
    }
}

/// A small deterministic random number generator for test data.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
