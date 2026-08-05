import Foundation
import Compression

/// Brotli decompression via the system Compression framework
/// (`COMPRESSION_BROTLI`).
///
/// Some OpenAI-compatible gateways and clients send `Content-Encoding: br`.
/// Codex CLI itself does not, but codex-router decodes it and so do we.
enum BrotliDecompression {
    static func decompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        return data.withUnsafeBytes { inBuffer -> Data? in
            guard let inBase = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }

            // C struct without a zeroed default init; give it valid pointers
            // that compression_stream_init will replace immediately.
            var dstPlaceholder: UInt8 = 0
            var srcPlaceholder: UInt8 = 0
            var stream = compression_stream(
                dst_ptr: &dstPlaceholder,
                dst_size: 0,
                src_ptr: &srcPlaceholder,
                src_size: 0,
                state: nil
            )
            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
            guard initStatus != COMPRESSION_STATUS_ERROR else { return nil }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = inBase
            stream.src_size = inBuffer.count

            var output = Data()
            let chunkCapacity = 64 * 1024
            var status: compression_status = COMPRESSION_STATUS_OK

            while status == COMPRESSION_STATUS_OK {
                var chunk = Data(count: chunkCapacity)
                let produced = chunk.withUnsafeMutableBytes { outBuffer -> Int in
                    guard let outBase = outBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    stream.dst_ptr = outBase
                    stream.dst_size = outBuffer.count
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    return outBuffer.count - Int(stream.dst_size)
                }
                guard produced >= 0 else { return nil }
                output.append(chunk.prefix(produced))
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { return nil }
            }
            return output
        }
    }
}
