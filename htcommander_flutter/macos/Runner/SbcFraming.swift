import Foundation

/// HDLC-style framing the Benshi audio RFCOMM channel uses on top of
/// SBC frames. Mirrors bendio's ``audio/framing.py`` byte for byte.
///
/// On-wire framing of one TX packet:
///
///     0x7E <cmd 0x00> <escape(SBC frame)> 0x7E
///
/// where escape replaces ``0x7E`` with ``0x7D 0x5E`` and ``0x7D``
/// with ``0x7D 0x5D``.
enum SbcFraming {
    static let frameDelimiter: UInt8 = 0x7E
    static let escapeByte: UInt8 = 0x7D
    static let txCommand: UInt8 = 0x00

    /// **End-of-transmission** packet. Sent three times with 50 ms
    /// gaps after the last SBC frame to un-wedge the radio's TX
    /// state machine. **Anything that ever calls
    /// ``RFCOMMChannel.write`` for audio MUST also send this on
    /// exit.** See docs/Phase2-NativeAudio-Review.md for context.
    static let endOfTxPacket: [UInt8] = [
        0x7E, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x7E,
    ]

    /// Wrap one 44-byte SBC frame as a ready-to-send RFCOMM packet.
    static func buildAudioPacket(_ sbcFrame: Data) -> Data {
        var out = Data()
        out.reserveCapacity(sbcFrame.count + 4)
        out.append(frameDelimiter)
        out.append(txCommand)
        out.append(contentsOf: escapeBytes(sbcFrame))
        out.append(frameDelimiter)
        return out
    }

    static func escapeBytes(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        for b in data {
            if b == frameDelimiter {
                out.append(escapeByte)
                out.append(0x5E)
            } else if b == escapeByte {
                out.append(escapeByte)
                out.append(0x5D)
            } else {
                out.append(b)
            }
        }
        return out
    }

    static func unescapeBytes(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            if data[i] == escapeByte && i + 1 < data.count {
                out.append(data[i + 1] ^ 0x20)
                i += 2
            } else {
                out.append(data[i])
                i += 1
            }
        }
        return out
    }

    /// Stateful deframer — feed any byte-chunk size, get back a list
    /// of fully-deframed packet payloads (everything between the
    /// start ``0x7E`` and the end ``0x7E``, with escapes resolved).
    final class Deframer {
        private var buf = Data()
        private var inFrame = false

        func feed(_ chunk: Data) -> [Data] {
            var out = [Data]()
            for b in chunk {
                if b == frameDelimiter {
                    if inFrame && !buf.isEmpty {
                        out.append(SbcFraming.unescapeBytes(buf))
                        buf.removeAll(keepingCapacity: true)
                    }
                    inFrame = !inFrame
                    if inFrame {
                        buf.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                if inFrame {
                    buf.append(b)
                }
            }
            return out
        }
    }

    /// Split a deframed RFCOMM packet payload into its constituent
    /// SBC frames. The first byte of the payload is the radio's TNC
    /// command byte (``0x00`` for audio); each frame after it is
    /// exactly 44 bytes for our codec config.
    static func splitSbcFrames(_ packet: Data,
                               headerBytes: Int = 1,
                               frameLen: Int = 44) -> [Data] {
        guard packet.count > headerBytes else { return [] }
        var frames = [Data]()
        var off = headerBytes
        while off + frameLen <= packet.count {
            frames.append(packet.subdata(in: off..<(off + frameLen)))
            off += frameLen
        }
        return frames
    }
}
