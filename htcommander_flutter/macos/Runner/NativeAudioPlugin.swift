import AVFoundation
import CoreAudio
import FlutterMacOS

/// Native CoreAudio mic capture + device enumeration for HTCommander-X.
///
/// sounddevice/PortAudio and ffmpeg-avfoundation both had issues on
/// this box (choppy TX audio, wrong dev-ID spaces). AVAudioEngine gives
/// us low-latency mic capture against any CoreAudio output device,
/// shipping 16-bit mono s16le PCM at 32 kHz back to Dart via an
/// EventChannel. Dart forwards the PCM to bendio over the existing
/// `audio_tx_pcm` JSON-RPC method.
///
/// Method channel: `htcommander.macos/audio`
///   - `listInputDevices()` → `[{"id": <uid>, "name": <str>, "default": <bool>}]`
///   - `startMic(deviceUid: String?)` → `{"started": true}`
///   - `stopMic()` → `{}`
///
/// Event channel: `htcommander.macos/audio_pcm` — emits `FlutterStandardTypedData.typedDataInt8`
/// chunks of s16le mono 32 kHz PCM during capture.
class NativeAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let engine = AVAudioEngine()
    private var sinkFormat: AVAudioFormat?
    private var eventSink: FlutterEventSink?
    private var running = false

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = NativeAudioPlugin()
        let channel = FlutterMethodChannel(
            name: "htcommander.macos/audio",
            binaryMessenger: registrar.messenger
        )
        registrar.addMethodCallDelegate(plugin, channel: channel)
        let events = FlutterEventChannel(
            name: "htcommander.macos/audio_pcm",
            binaryMessenger: registrar.messenger
        )
        events.setStreamHandler(plugin)
    }

    // MARK: - FlutterPlugin
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "listInputDevices":
            result(Self.listInputDevices())
        case "startMic":
            let args = call.arguments as? [String: Any]
            let deviceUid = args?["deviceUid"] as? String
            do {
                try startMic(deviceUid: deviceUid)
                result(["started": true])
            } catch {
                result(FlutterError(
                    code: "mic_start_failed",
                    message: "\(error)",
                    details: nil
                ))
            }
        case "stopMic":
            stopMic()
            result([:])
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Capture

    /// Enumerate CoreAudio input devices.
    static func listInputDevices() -> [[String: Any]] {
        // Ask the system audio object for the global list of all devices.
        var propsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propsAddr, 0, nil, &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propsAddr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        // Default input device (for marking in the UI).
        var defaultInput: AudioDeviceID = 0
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr, 0, nil, &defSize, &defaultInput
        )

        var out: [[String: Any]] = []
        for id in ids {
            // Only keep devices that have at least one input channel.
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                id, &streamAddr, 0, nil, &bufSize
            ) == noErr, bufSize > 0 else { continue }
            let bufList = UnsafeMutablePointer<AudioBufferList>.allocate(
                capacity: Int(bufSize)
            )
            defer { bufList.deallocate() }
            guard AudioObjectGetPropertyData(
                id, &streamAddr, 0, nil, &bufSize, bufList
            ) == noErr else { continue }
            let buffers = UnsafeMutableAudioBufferListPointer(bufList)
            var totalChannels: UInt32 = 0
            for b in buffers { totalChannels += b.mNumberChannels }
            if totalChannels == 0 { continue }

            // Device UID (stable across reboots; safe to pass back in startMic).
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            _ = AudioObjectGetPropertyData(
                id, &uidAddr, 0, nil, &uidSize, &uid
            )
            let uidStr = uid?.takeRetainedValue() as String? ?? "\(id)"

            // Human name.
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            _ = AudioObjectGetPropertyData(
                id, &nameAddr, 0, nil, &nameSize, &name
            )
            let nameStr = name?.takeRetainedValue() as String? ?? "Device \(id)"

            out.append([
                "id": uidStr,
                "name": nameStr,
                "default": id == defaultInput,
            ])
        }
        return out
    }

    private func startMic(deviceUid: String?) throws {
        stopMic()

        // Resolve the chosen device (if any) to an AudioDeviceID and tell
        // AVAudioEngine to use it. Nil = system default input.
        if let uid = deviceUid, !uid.isEmpty {
            if let devId = Self.deviceId(forUid: uid) {
                var inputDev = devId
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioOutputUnitProperty_CurrentDevice,
                    mScope: kAudioUnitScope_Global,
                    mElement: 0
                )
                let unit = engine.inputNode.audioUnit!
                _ = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &inputDev,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                _ = addr // silence unused
            }
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        // Target: 32 kHz mono s16le (what bendio / radio expect).
        let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 32000,
            channels: 1,
            interleaved: true
        )!
        sinkFormat = target

        // AVAudioEngine can't resample inside a tap, so install the tap
        // at the mic's native format and convert to the target format
        // per-buffer with AVAudioConverter.
        let converter = AVAudioConverter(from: inputFormat, to: target)
        guard converter != nil else {
            throw NSError(
                domain: "NativeAudioPlugin", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "no converter from \(inputFormat) to \(target)"]
            )
        }

        // 256-frame tap buffer ≈ 5-6 ms at 44.1–48 kHz. AVAudioEngine
        // may round up internally but this is the smallest it honors
        // reliably on macOS.
        input.installTap(
            onBus: 0,
            bufferSize: 256,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self = self, let sink = self.eventSink else { return }
            // Estimate target frame count: ratio of sample rates.
            let ratio = target.sampleRate / inputFormat.sampleRate
            let outFrameCap = AVAudioFrameCount(
                Double(buffer.frameLength) * ratio + 0.5
            )
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: outFrameCap
            ) else { return }
            var err: NSError?
            var fed = false
            converter!.convert(to: outBuf, error: &err) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if err != nil { return }
            let bytesPerFrame = Int(target.streamDescription.pointee.mBytesPerFrame)
            let byteCount = Int(outBuf.frameLength) * bytesPerFrame
            guard byteCount > 0 else { return }
            let data = Data(
                bytes: outBuf.int16ChannelData![0],
                count: byteCount
            )
            DispatchQueue.main.async {
                // FlutterEventChannel wants a plain Data / TypedData payload.
                sink(FlutterStandardTypedData(bytes: data))
            }
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    private func stopMic() {
        if !running { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    // MARK: - UID → AudioDeviceID

    private static func deviceId(forUid uid: String) -> AudioDeviceID? {
        var propsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propsAddr, 0, nil, &dataSize
        ) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propsAddr, 0, nil, &dataSize, &ids
        ) == noErr else { return nil }

        for id in ids {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var thisUid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            if AudioObjectGetPropertyData(
                id, &uidAddr, 0, nil, &uidSize, &thisUid
            ) == noErr {
                if let s = thisUid?.takeRetainedValue() as String?, s == uid {
                    return id
                }
            }
        }
        return nil
    }
}
