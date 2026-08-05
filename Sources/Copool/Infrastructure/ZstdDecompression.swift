import Foundation
import CZstd

/// Streaming zstd decompression backed by the vendored single-file decoder
/// (`Sources/CZstd`).
///
/// Codex CLI compresses Responses API request bodies with
/// `Content-Encoding: zstd` (feature `enable_request_compression`, on by
/// default), so the proxy must be able to inflate them before reading the
/// model id. macOS has no system zstd, hence the vendored C decoder.
enum ZstdDecompression {
    /// Decompresses a complete zstd frame. Returns nil when the frame is
    /// malformed or the output would exceed `outputLimit` bytes.
    static func decompress(_ data: Data, outputLimit: Int = ProxyRuntimeLimits.maxInboundRequestBytes) -> Data? {
        guard !data.isEmpty else { return Data() }

        // Fast path: the frame header usually declares the content size.
        // (ZSTD_CONTENTSIZE_UNKNOWN == UInt64.max, ERROR == UInt64.max - 1 in
        // the vendored header, imported with C type UInt32 in some toolchains.)
        let contentsizeUnknown: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        let contentsizeError: UInt64 = 0xFFFF_FFFF_FFFF_FFFE
        let declared = data.withUnsafeBytes { buffer -> UInt64 in
            guard let base = buffer.baseAddress else { return contentsizeError }
            return ZSTD_getFrameContentSize(base, buffer.count)
        }
        if declared != contentsizeUnknown && declared != contentsizeError {
            guard declared <= UInt64(outputLimit) else { return nil }
            var output = Data(count: Int(declared))
            let written = output.withUnsafeMutableBytes { outBuffer -> Int in
                data.withUnsafeBytes { inBuffer -> Int in
                    guard let outBase = outBuffer.baseAddress, let inBase = inBuffer.baseAddress else { return -1 }
                    let result = ZSTD_decompress(outBase, outBuffer.count, inBase, inBuffer.count)
                    return ZSTD_isError(result) != 0 ? -1 : Int(result)
                }
            }
            guard written >= 0 else { return nil }
            return written == output.count ? output : output.prefix(written)
        }

        // Streaming path: size unknown (or error). Feed the frame through a
        // `ZSTD_DStream` until it reports end-of-frame.
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { return nil }

        var input = data
        var output = Data()
        let chunkCapacity = 64 * 1024

        while !input.isEmpty {
            var chunk = Data(count: chunkCapacity)
            let consumed = chunk.withUnsafeMutableBytes { chunkBuffer -> Int in
                input.withUnsafeBytes { inBuffer -> Int in
                    var inBuf = ZSTD_inBuffer(src: inBuffer.baseAddress, size: inBuffer.count, pos: 0)
                    var outBuf = ZSTD_outBuffer(dst: chunkBuffer.baseAddress, size: chunkBuffer.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &outBuf, &inBuf)
                    if ZSTD_isError(result) != 0 { return -1 }
                    input.removeFirst(Int(inBuf.pos))
                    return Int(outBuf.pos)
                }
            }
            guard consumed >= 0 else { return nil }
            output.append(chunk.prefix(consumed))
            if output.count > outputLimit { return nil }
            if input.isEmpty {
                // One more call with an empty input drains the final bytes.
                var chunk = Data(count: chunkCapacity)
                let drained = chunk.withUnsafeMutableBytes { chunkBuffer -> Int in
                    var inBuf = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
                    var outBuf = ZSTD_outBuffer(dst: chunkBuffer.baseAddress, size: chunkBuffer.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &outBuf, &inBuf)
                    if ZSTD_isError(result) != 0 { return -1 }
                    return Int(outBuf.pos)
                }
                guard drained >= 0 else { return nil }
                output.append(chunk.prefix(drained))
                if output.count > outputLimit { return nil }
            }
        }
        return output
    }
}
