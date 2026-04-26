import Foundation

/// Swift wrapper around BlueZ's libsbc (vendored under
/// ``Runner/sbc/``). One ``SbcDecoder`` per RX session, one
/// ``SbcEncoder`` per TX session. Codec parameters are pinned to the
/// Benshi UV-PRO's fixed config: 32 kHz / mono / 16 blocks / 8
/// subbands / loudness allocation / bitpool 18 → exactly 44 bytes
/// per encoded frame.
///
/// libsbc was validated bit-exact against ``ffmpeg -c:a sbc`` on
/// the same inputs (see docs/Phase2-NativeAudio-Review.md and the
/// /tmp/sbc-spike build logs).

enum SbcCodecError: Error {
    case initFailed
    case decodeFailed(consumed: Int)
    case encodeFailed(consumed: Int)
}

final class SbcDecoder {
    private var sbc = sbc_t()
    private var pcmBuf = [UInt8](repeating: 0, count: 4096)

    init() throws {
        if sbc_init(&sbc, 0) != 0 { throw SbcCodecError.initFailed }
    }

    deinit { sbc_finish(&sbc) }

    /// Decode every complete SBC frame in [data] and return the
    /// concatenated PCM (s16le mono 32 kHz). Leftover bytes that
    /// don't form a complete frame are dropped — the caller's
    /// HDLC deframer hands us whole packets, so this is a non-issue
    /// in practice.
    func decode(_ data: Data) throws -> Data {
        var out = Data()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = raw.count
            while off < total {
                var written: size_t = 0
                let consumed = pcmBuf.withUnsafeMutableBufferPointer { p in
                    sbc_decode(
                        &sbc,
                        base.advanced(by: off), total - off,
                        p.baseAddress, p.count,
                        &written
                    )
                }
                if consumed <= 0 {
                    throw SbcCodecError.decodeFailed(consumed: Int(consumed))
                }
                if written > 0 {
                    out.append(pcmBuf, count: written)
                }
                off += consumed
            }
        }
        return out
    }
}

final class SbcEncoder {
    private var sbc = sbc_t()
    private var sbcBuf = [UInt8](repeating: 0, count: 1024)

    /// Each call returns the SBC bytes for [pcm] which must be a
    /// whole multiple of one frame's PCM size (128 samples × 2 bytes
    /// = 256 bytes for the radio's config). Anything left over is
    /// returned as zero output and the caller should accumulate.
    static let pcmFrameSize = 256

    init() throws {
        if sbc_init(&sbc, 0) != 0 { throw SbcCodecError.initFailed }
        // Pin the codec config — see file header comment.
        sbc.frequency  = UInt8(SBC_FREQ_32000)
        sbc.subbands   = UInt8(SBC_SB_8)
        sbc.blocks     = UInt8(SBC_BLK_16)
        sbc.bitpool    = 18
        sbc.allocation = UInt8(SBC_AM_LOUDNESS)
        sbc.mode       = UInt8(SBC_MODE_MONO)
        sbc.endian     = UInt8(SBC_LE)
    }

    deinit { sbc_finish(&sbc) }

    func encode(_ pcm: Data) throws -> Data {
        var out = Data()
        try pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = raw.count
            while off < total {
                var written: ssize_t = 0
                let consumed = sbcBuf.withUnsafeMutableBufferPointer { p in
                    sbc_encode(
                        &sbc,
                        base.advanced(by: off), total - off,
                        p.baseAddress, p.count,
                        &written
                    )
                }
                if consumed <= 0 {
                    throw SbcCodecError.encodeFailed(consumed: Int(consumed))
                }
                if written > 0 {
                    out.append(sbcBuf, count: written)
                }
                off += consumed
            }
        }
        return out
    }
}
