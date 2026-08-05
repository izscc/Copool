import Foundation
import zlib

/// gzip / deflate decompression via the system libz (`import zlib`).
///
/// Codex CLI only sends zstd, but older clients and generic OpenAI-compatible
/// tools may send gzip or deflate, and codex-router supports all three, so the
/// proxy does too. `inflateInit2` windowBits:
///   - 31: gzip only, 47: auto-detect zlib-or-gzip, -15: raw deflate.
enum LibzDecompression {
    static func decompressGzipOrZlib(_ data: Data) -> Data? {
        inflateData(data, windowBits: 47)
    }

    static func decompressRawDeflate(_ data: Data) -> Data? {
        inflateData(data, windowBits: -15)
    }

    private static func inflateData(_ data: Data, windowBits: Int32) -> Data? {
        guard !data.isEmpty else { return Data() }
        return data.withUnsafeBytes { inBuffer -> Data? in
            guard let inBase = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: inBase)
            stream.avail_in = uInt(inBuffer.count)

            let initResult = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initResult == Z_OK else { return nil }
            defer { inflateEnd(&stream) }

            var output = Data()
            let chunkCapacity = 64 * 1024
            var result: Int32 = Z_OK
            repeat {
                var chunk = Data(count: chunkCapacity)
                let produced = chunk.withUnsafeMutableBytes { outBuffer -> Int in
                    guard let outBase = outBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    stream.next_out = outBase
                    stream.avail_out = uInt(outBuffer.count)
                    result = inflate(&stream, Z_NO_FLUSH)
                    guard result == Z_OK || result == Z_STREAM_END else { return -1 }
                    return Int(outBuffer.count) - Int(stream.avail_out)
                }
                guard produced >= 0 else { return nil }
                output.append(chunk.prefix(produced))
            } while stream.avail_in > 0 || (result == Z_OK && stream.avail_out == 0)
            return output
        }
    }
}
