import AVFoundation
import CoreAudio
import FlutterMacOS
import Foundation
import IOBluetooth

/// Native macOS RFCOMM audio for the Benshi UV-PRO. Replaces bendio's
/// Python+ffmpeg+sounddevice pipeline:
///
///   * IOBluetooth opens RFCOMM channel 2 ("BS AOC") on the paired
///     radio.
///   * RX bytes → ``SbcFraming.Deframer`` → ``SbcDecoder`` → 32 kHz
///     mono s16 PCM → ``AVAudioEngine`` source node (so playback uses
///     CoreAudio directly, no PortAudio / sounddevice).
///   * TX PCM (from ``NativeAudioPlugin``'s mic capture, shipped via
///     this same plugin's ``writePcm`` method) → ``SbcEncoder`` →
///     ``SbcFraming.buildAudioPacket`` → RFCOMM ``writeSync``.
///
/// **End-of-transmission discipline.** All TX writes go through
/// ``RfcommAudioSession.transmit(...)``. There is no other entry point.
/// The session tracks "is mid-TX"; ``stop()`` always sends the
/// ``endOfTxPacket`` sequence three times before closing the channel,
/// even via ``defer`` on a thrown error path. Forgetting EOT wedges
/// the radio into TX mode until power-cycle — see
/// docs/Phase2-NativeAudio-Review.md.
///
/// Method channel: `htcommander.macos/audio_rfcomm`
///   - `open(address: String, outputDevice: String?, muted: Bool)`
///       → `{"opened": Bool, "channel": Int}`
///   - `close()` → `{}`
///   - `writePcm(bytes: hex)` — append PCM to the TX encoder
///   - `setMuted(muted: Bool)` — gate local speaker (RX still flows
///       to AudioDataAvailable for SoftwareModem)
///   - `setOutputDevice(device: String?)` — hot-swap the AVAudioEngine
///       output (Phase 2 just persists the pref; CoreAudio routing
///       follows the system default — see TODO in startOutput).
///
/// Event channel: `htcommander.macos/audio_rfcomm_pcm` — emits
/// FlutterStandardTypedData of decoded PCM (s16le mono 32 kHz) for
/// every SBC frame received. Lets Dart-side consumers (SoftwareModem,
/// SSTV decoder, waterfall) tap the audio without re-decoding.
class RfcommAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var session: RfcommAudioSession?
    private var pcmSink: FlutterEventSink?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = RfcommAudioPlugin()
        let channel = FlutterMethodChannel(
            name: "htcommander.macos/audio_rfcomm",
            binaryMessenger: registrar.messenger
        )
        registrar.addMethodCallDelegate(plugin, channel: channel)
        let events = FlutterEventChannel(
            name: "htcommander.macos/audio_rfcomm_pcm",
            binaryMessenger: registrar.messenger
        )
        events.setStreamHandler(plugin)
    }

    // MARK: FlutterPlugin
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "open":
            let args = call.arguments as? [String: Any]
            let address = args?["address"] as? String ?? ""
            let muted = args?["muted"] as? Bool ?? false
            let outputDeviceUid = args?["outputDevice"] as? String
            do {
                let s = try RfcommAudioSession(address: address, onPcm: { [weak self] pcm in
                    DispatchQueue.main.async {
                        self?.pcmSink?(FlutterStandardTypedData(bytes: pcm))
                    }
                })
                s.muted = muted
                s.pendingOutputDeviceUid = outputDeviceUid
                try s.start()
                self.session = s
                result(["opened": true, "channel": 2])
            } catch {
                result(FlutterError(
                    code: "rfcomm_open_failed",
                    message: "\(error)",
                    details: nil
                ))
            }
        case "close":
            session?.stop()
            session = nil
            result([:])
        case "writePcm":
            guard let session = session else {
                result(FlutterError(code: "not_open", message: "audio not open", details: nil))
                return
            }
            let args = call.arguments as? [String: Any]
            let hex = args?["bytes"] as? String ?? ""
            guard let data = Self.dataFromHex(hex) else {
                result(FlutterError(code: "bad_hex", message: "invalid hex", details: nil))
                return
            }
            do { try session.writePcm(data); result([:]) }
            catch { result(FlutterError(code: "tx_failed", message: "\(error)", details: nil)) }
        case "setMuted":
            let args = call.arguments as? [String: Any]
            let m = args?["muted"] as? Bool ?? false
            session?.muted = m
            result([:])
        case "setOutputDevice":
            let args = call.arguments as? [String: Any]
            let uid = args?["device"] as? String
            do {
                try session?.setOutputDevice(uid: (uid?.isEmpty ?? true) ? nil : uid)
                result([:])
            } catch {
                result(FlutterError(code: "set_output_failed", message: "\(error)", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: FlutterStreamHandler
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        pcmSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        pcmSink = nil
        return nil
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(b); i = next
        }
        return Data(bytes)
    }
}

// MARK: - RfcommAudioSession

/// Owns the IOBluetooth RFCOMM channel + SBC codecs + AVAudioEngine
/// playback. One per radio connection.
final class RfcommAudioSession: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let address: String
    private let onPcm: (Data) -> Void
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var deframer = SbcFraming.Deframer()
    private var decoder: SbcDecoder?
    private var encoder: SbcEncoder?

    // PCM -> SBC encoder needs whole-frame inputs (256 bytes / 128
    // samples). Anything left over rolls into the next call.
    private var pcmTxBuffer = Data()

    // AVAudioEngine output: a source node that pulls from a small
    // ring buffer of decoded PCM. Audio thread reads with no locks
    // (we use a thread-safe ring queue below).
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ringBuffer = PcmRingBuffer(capacity: 32000 * 2 * 2) // 2 s mono s16

    /// Set true to silence local playback while keeping decoded PCM
    /// flowing to ``onPcm`` (so the software modem still sees audio).
    var muted: Bool = false

    /// Output device UID to bind the AVAudioEngine output unit to.
    /// Set before ``start()`` to apply at engine startup. Use
    /// ``setOutputDevice(uid:)`` to hot-swap after start.
    var pendingOutputDeviceUid: String?

    init(address: String, onPcm: @escaping (Data) -> Void) throws {
        self.address = address
        self.onPcm = onPcm
        super.init()
        self.decoder = try SbcDecoder()
        self.encoder = try SbcEncoder()
    }

    func start() throws {
        // Resolve the paired device. ``address`` may be a Classic-BT
        // MAC ("AA:BB:..") or — coming from the BLE side — a
        // CoreBluetooth UUID. In the latter case we look up the
        // paired device by name, matching the earlier bendio
        // behaviour. macOS doesn't expose a Classic MAC for unpaired
        // devices, so this hard-requires a system-level pairing.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let resolved: IOBluetoothDevice?
        if address.contains("-") && address.count >= 32 {
            // Looks like a CoreBluetooth UUID — fall back to name match.
            let benshiNames = [
                "UV-PRO", "UV-Pro", "UV-50PRO", "GA-5WB",
                "VR-N75", "VR-N76", "VR-N7500", "VR-N7600",
                "RT-660", "GMRS-PRO",
            ]
            resolved = paired.first { d in
                guard let n = d.name else { return false }
                return benshiNames.contains { n.localizedCaseInsensitiveContains($0) }
            }
        } else {
            resolved = IOBluetoothDevice(addressString: address)
        }
        guard let dev = resolved else {
            throw NSError(domain: "RfcommAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No paired Benshi-family radio found. Pair via System Settings → Bluetooth and try again.",
            ])
        }
        device = dev

        var ch: IOBluetoothRFCOMMChannel?
        let status = dev.openRFCOMMChannelSync(&ch, withChannelID: 2, delegate: self)
        guard status == kIOReturnSuccess, let openCh = ch else {
            // Decode common IOReturn codes so the failure isn't an
            // opaque negative integer next time. Full table is in
            // <IOKit/IOReturn.h>; these are the ones we've seen.
            let hex = String(format: "0x%08X", UInt32(bitPattern: status))
            let hint: String
            switch status {
            case kIOReturnBusy:           hint = " (kIOReturnBusy — channel already open from prior session, try power-cycling the radio)"
            case kIOReturnExclusiveAccess:hint = " (kIOReturnExclusiveAccess — another process owns the channel)"
            case kIOReturnNotOpen:        hint = " (kIOReturnNotOpen — device link not up)"
            case kIOReturnTimeout:        hint = " (kIOReturnTimeout — device unresponsive)"
            case kIOReturnNoDevice:       hint = " (kIOReturnNoDevice — paired record exists but device unreachable)"
            case kIOReturnNotPermitted:   hint = " (kIOReturnNotPermitted)"
            case Int32(bitPattern: 0xE0002EFC):
                hint = " (likely RFCOMM channel still half-open from prior session — power-cycle the radio)"
            default:                      hint = ""
            }
            NSLog("RfcommAudio: openRFCOMMChannelSync failed status=\(status) (\(hex))\(hint)")
            throw NSError(domain: "RfcommAudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "openRFCOMMChannelSync failed: \(status) \(hex)\(hint)",
            ])
        }
        channel = openCh

        try startOutput()
    }

    /// Send the EOT sequence three times (50 ms gaps), wait briefly
    /// for the radio to settle, then close the RFCOMM channel and
    /// stop AVAudioEngine. Idempotent.
    ///
    /// **Do not call ``device.closeConnection()`` here.** macOS shares
    /// the BR/EDR ACL link between IOBluetooth (RFCOMM) and
    /// CoreBluetooth (GATT) for the same physical device. Tearing
    /// down the ACL kills the BLE/GATT indication stream too — the
    /// radio's onboard LED stays lit but the app loses its only
    /// command channel until the radio is power-cycled. Closing the
    /// RFCOMM channel alone is enough to stop audio cleanly.
    func stop() {
        defer {
            channel?.close()
            channel = nil
            // device kept open intentionally — see comment above.
            device = nil
            engine.stop()
            sourceNode = nil
        }
        guard let ch = channel else { return }
        let eot = Data(SbcFraming.endOfTxPacket)
        for _ in 0..<3 {
            _ = eot.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return Int32(ch.writeSync(
                    UnsafeMutableRawPointer(mutating: base),
                    length: UInt16(raw.count)
                ))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: TX
    func writePcm(_ pcm: Data) throws {
        guard let enc = encoder, let ch = channel else { return }
        pcmTxBuffer.append(pcm)
        while pcmTxBuffer.count >= SbcEncoder.pcmFrameSize {
            let chunk = pcmTxBuffer.prefix(SbcEncoder.pcmFrameSize)
            pcmTxBuffer.removeFirst(SbcEncoder.pcmFrameSize)
            let sbc = try enc.encode(Data(chunk))
            // ``encode`` may emit one or more 44-byte SBC frames per
            // 128-sample input; wrap each as its own RFCOMM packet.
            var off = 0
            while off + 44 <= sbc.count {
                let frame = sbc.subdata(in: off..<(off + 44))
                let packet = SbcFraming.buildAudioPacket(frame)
                _ = packet.withUnsafeBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return -1 }
                    return Int32(ch.writeSync(
                        UnsafeMutableRawPointer(mutating: base),
                        length: UInt16(raw.count)
                    ))
                }
                off += 44
            }
        }
    }

    // MARK: RX
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        let chunk = Data(bytes: dataPointer, count: dataLength)
        let packets = deframer.feed(chunk)
        guard let dec = decoder else { return }
        for pkt in packets {
            let frames = SbcFraming.splitSbcFrames(pkt)
            if frames.isEmpty { continue }
            // Concatenate frames before decode — libsbc handles
            // back-to-back SBC frames without resync overhead.
            var blob = Data()
            for f in frames { blob.append(f) }
            do {
                let pcm = try dec.decode(blob)
                onPcm(pcm)
                if !muted {
                    ringBuffer.write(pcm)
                }
            } catch {
                NSLog("RfcommAudio: decode failed: \(error)")
            }
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        // Unsolicited close — not initiated by us. Reset state so
        // ``stop()`` becomes a no-op.
        channel = nil
    }

    // MARK: AVAudioEngine output
    private func startOutput() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 32000,
            channels: 1,
            interleaved: true
        )!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let self = self,
                  let mBuf = abl[0].mData else {
                // Underrun — fill silence.
                memset(abl[0].mData, 0, Int(abl[0].mDataByteSize))
                return noErr
            }
            let want = Int(frameCount) * MemoryLayout<Int16>.size
            let got = self.ringBuffer.read(
                into: mBuf,
                bytes: want
            )
            if got < want {
                // Fill the gap with silence so we don't pop.
                memset(mBuf.advanced(by: got), 0, want - got)
            }
            abl[0].mDataByteSize = UInt32(want)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        // Bind to the requested output device BEFORE engine.start() so
        // CoreAudio doesn't have to re-route mid-stream. Nil = system
        // default (whatever the user picked in System Settings).
        if let uid = pendingOutputDeviceUid, !uid.isEmpty {
            applyOutputDevice(uid: uid)
        }

        engine.prepare()
        try engine.start()
    }

    /// Hot-swap the AVAudioEngine output device. Stops the engine,
    /// rebinds the output unit's ``kAudioOutputUnitProperty_CurrentDevice``,
    /// then restarts. There is a small audio glitch but it's the
    /// least-bad option — AVAudioEngine doesn't expose a live retarget.
    func setOutputDevice(uid: String?) throws {
        pendingOutputDeviceUid = uid
        guard sourceNode != nil else { return } // engine never started
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        if let uid = uid, !uid.isEmpty {
            applyOutputDevice(uid: uid)
        } else {
            applySystemDefaultOutput()
        }
        if wasRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func applyOutputDevice(uid: String) {
        guard let devId = NativeAudioPlugin.deviceId(forUid: uid) else {
            NSLog("RfcommAudio: no CoreAudio device matched UID \(uid)")
            return
        }
        var devVar = devId
        let unit = engine.outputNode.audioUnit!
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("RfcommAudio: AudioUnitSetProperty(CurrentDevice) failed: \(status)")
        }
    }

    private func applySystemDefaultOutput() {
        var defId: AudioDeviceID = 0
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defAddr, 0, nil, &defSize, &defId
        ) == noErr else { return }
        var devVar = defId
        let unit = engine.outputNode.audioUnit!
        _ = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}

// MARK: - PcmRingBuffer

/// Thread-safe byte ring buffer for shipping decoded PCM from the
/// IOBluetooth delegate thread to AVAudioEngine's audio thread.
/// Lock-based; the contention window is microseconds and the audio
/// thread tolerates short blocks better than a glitchy lock-free
/// design with subtle bugs.
final class PcmRingBuffer {
    private var buf: [UInt8]
    private var head = 0
    private var tail = 0
    private let lock = NSLock()
    private let cap: Int

    init(capacity: Int) {
        cap = capacity
        buf = [UInt8](repeating: 0, count: capacity)
    }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        for b in data {
            buf[head] = b
            head = (head + 1) % cap
            if head == tail {
                // Overrun — drop oldest. Keeps the buffer real-time
                // even if the audio device is slow to drain.
                tail = (tail + 1) % cap
            }
        }
    }

    func read(into dst: UnsafeMutableRawPointer, bytes: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        while n < bytes && tail != head {
            dst.advanced(by: n).storeBytes(of: buf[tail], as: UInt8.self)
            tail = (tail + 1) % cap
            n += 1
        }
        return n
    }
}
