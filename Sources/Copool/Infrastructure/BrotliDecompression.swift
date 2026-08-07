import Foundation
import Compression

/// Brotli decompression via the system Compression framework
/// (`COMPRESSION_BROTLI`).
///
/// Some OpenAI-compatible gateways and clients send `Content-Encoding: br`.
/// Codex CLI itself does not, but codex-router decodes it and so do we.
enum BrotliDecompression {
    static func decompress(_ data: Data, outputLimit: Int = ProxyRuntimeLimits.maxInboundRequestDecodedBytes) -> Data? {
        guard !data.isEmpty else { return Data() }

        return data.withUnsafeBytes { inBuffer -> Data? in
            guard let inBase = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }

            var dstPlaceholder: UInt8 = 0
            var srcPlaceholder: UInt8 = 0
            let initialized: (compression_stream, compression_status) = withUnsafeMutablePointer(to: &dstPlaceholder) { dstPointer in
                withUnsafeMutablePointer(to: &srcPlaceholder) { srcPointer in
                    var stream = compression_stream(
                        dst_ptr: dstPointer,
                        dst_size: 0,
                        src_ptr: UnsafePointer(srcPointer),
                        src_size: 0,
                        state: nil
                    )
                    let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
                    return (stream, status)
                }
            }
            var stream = initialized.0
            guard initialized.1 != COMPRESSION_STATUS_ERROR else { return nil }
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
                // SEC-11：解压后大小超限视为炸弹攻击，拒绝并返回 nil。
                if output.count > outputLimit { return nil }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { return nil }
            }
            return output
        }
    }
}
