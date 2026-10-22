import Foundation

/// A small gzip encoder (RFC 1951 deflate with the fixed Huffman codes, RFC 1952 framing),
/// so KestrelKit needs no dependency and behaves the same on every platform.
/// Batches of signals repeat the same keys and values, so even this simple encoder
/// usually shrinks them to a fifth or less.
enum Gzip {
    /// Bodies smaller than this are sent as they are.
    static let threshold = 1024

    static func compress(_ input: Data) -> Data {
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(contentsOf: Deflate.compress([UInt8](input)))
        appendLittleEndian(crc32(input), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: input.count), to: &output)
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}

/// One final deflate block with the fixed Huffman codes and greedy LZ77 matching
/// (32 KB window, hash chains).
struct Deflate {
    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let window = 32_768
    private static let minMatch = 3
    private static let maxMatch = 258
    private static let maxChain = 48
    private static let hashSize = 1 << 15

    private var bits = BitWriter()

    static func compress(_ input: [UInt8]) -> [UInt8] {
        var deflate = Deflate()
        deflate.encode(input)
        return deflate.bits.finish()
    }

    private mutating func encode(_ input: [UInt8]) {
        bits.write(1, count: 1) // BFINAL: the only block
        bits.write(1, count: 2) // BTYPE 01: fixed Huffman codes

        let count = input.count
        var head = [Int32](repeating: -1, count: Self.hashSize)
        var previous = [Int32](repeating: -1, count: count)

        func hash(_ i: Int) -> Int {
            ((Int(input[i]) << 10) ^ (Int(input[i + 1]) << 5) ^ Int(input[i + 2])) & (Self.hashSize - 1)
        }

        var position = 0
        while position < count {
            var bestLength = 0
            var bestDistance = 0
            if position + Self.minMatch <= count {
                let h = hash(position)
                let longest = min(Self.maxMatch, count - position)
                var candidate = Int(head[h])
                var chain = 0
                while candidate >= 0, position - candidate <= Self.window, chain < Self.maxChain {
                    var length = 0
                    while length < longest, input[candidate + length] == input[position + length] {
                        length += 1
                    }
                    if length > bestLength {
                        bestLength = length
                        bestDistance = position - candidate
                        if length == longest { break }
                    }
                    candidate = Int(previous[candidate])
                    chain += 1
                }
                previous[position] = head[h]
                head[h] = Int32(position)
            }

            if bestLength >= Self.minMatch {
                writeLength(bestLength)
                writeDistance(bestDistance)
                let end = position + bestLength
                var next = position + 1
                while next < end {
                    if next + Self.minMatch <= count {
                        let h = hash(next)
                        previous[next] = head[h]
                        head[h] = Int32(next)
                    }
                    next += 1
                }
                position = end
            } else {
                writeLiteral(Int(input[position]))
                position += 1
            }
        }
        writeLiteral(256) // end of block
    }

    /// The fixed literal/length code for `symbol` (RFC 1951 §3.2.6).
    private mutating func writeLiteral(_ symbol: Int) {
        switch symbol {
        case 0...143: bits.writeCode(UInt32(0x30 + symbol), length: 8)
        case 144...255: bits.writeCode(UInt32(0x190 + symbol - 144), length: 9)
        case 256...279: bits.writeCode(UInt32(symbol - 256), length: 7)
        default: bits.writeCode(UInt32(0xC0 + symbol - 280), length: 8)
        }
    }

    private mutating func writeLength(_ length: Int) {
        var code = Self.lengthBase.count - 1
        while Self.lengthBase[code] > length { code -= 1 }
        writeLiteral(257 + code)
        if Self.lengthExtra[code] > 0 {
            bits.write(UInt32(length - Self.lengthBase[code]), count: Self.lengthExtra[code])
        }
    }

    private mutating func writeDistance(_ distance: Int) {
        var code = Self.distanceBase.count - 1
        while Self.distanceBase[code] > distance { code -= 1 }
        bits.writeCode(UInt32(code), length: 5)
        if Self.distanceExtra[code] > 0 {
            bits.write(UInt32(distance - Self.distanceBase[code]), count: Self.distanceExtra[code])
        }
    }
}

/// Packs bits least significant first, as deflate wants; Huffman codes go most
/// significant bit first, so they are reversed before they are written.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var buffer: UInt64 = 0
    private var used = 0

    mutating func write(_ value: UInt32, count: Int) {
        buffer |= UInt64(value) << UInt64(used)
        used += count
        while used >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: buffer))
            buffer >>= 8
            used -= 8
        }
    }

    mutating func writeCode(_ code: UInt32, length: Int) {
        var reversed: UInt32 = 0
        var rest = code
        for _ in 0..<length {
            reversed = (reversed << 1) | (rest & 1)
            rest >>= 1
        }
        write(reversed, count: length)
    }

    mutating func finish() -> [UInt8] {
        if used > 0 {
            bytes.append(UInt8(truncatingIfNeeded: buffer))
            buffer = 0
            used = 0
        }
        return bytes
    }
}
