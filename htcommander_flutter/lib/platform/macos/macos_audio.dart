import 'dart:async';
import 'dart:typed_data';

import '../../core/data_broker.dart';
import '../../core/data_broker_client.dart';
import '../../radio/models/radio_channel_info.dart';
import '../../radio/models/radio_settings.dart';
import '../../radio/software_modem.dart' show AudioDataEvent;
import '../audio_service.dart';
import 'macos_bluetooth.dart';
import 'macos_native_audio.dart';
import 'macos_native_rfcomm.dart';

/// macOS audio output. Phase 2: routes through the native Swift
/// ``RfcommAudioPlugin`` (libsbc + IOBluetooth + AVAudioEngine), no
/// Python subprocess involved. Owns:
///   * The RFCOMM session lifecycle (open/close).
///   * The Mute → speaker-gating broker subscription (combines global
///     Mute toggle with the active channel's mute flag).
///   * Forwarding decoded PCM into ``AudioDataAvailable`` so the
///     SoftwareModem can demodulate AX.25/AFSK packets.
class MacOsAudioOutput implements AudioOutput {
  final MacOsRadioBluetooth? _bt;
  final DataBrokerClient _broker = DataBrokerClient();
  final MacOsNativeRfcommAudio _rfcomm = MacOsNativeRfcommAudio();
  StreamSubscription<Uint8List>? _rxPcmSub;
  bool _started = false;

  MacOsAudioOutput(this._bt);

  @override
  Future<void> start(int radioDeviceId) async {
    final bt = _bt;
    if (_started || bt == null) return;
    _started = true;

    // ignore: avoid_print
    print('[MacOsAudioOutput] opening native RFCOMM audio for ${bt.address}');
    final storedOutUid =
        _broker.getValue<String>(0, 'MacOsOutputDeviceUid', '');
    try {
      await _rfcomm.open(
        address: bt.address,
        muted: _broker.getValue<int>(0, 'Mute', 0) != 0,
        outputDevice: storedOutUid.isEmpty ? null : storedOutUid,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[MacOsAudioOutput] RFCOMM open failed: $e');
      _started = false;
      return;
    }
    // ignore: avoid_print
    print('[MacOsAudioOutput] RFCOMM open succeeded');

    // Combine global Mute toggle + active-channel mute flag.
    Future<void> applyMute() async {
      final global = _broker.getValue<int>(0, 'Mute', 0) != 0;
      final channelMuted = _currentChannelMuted();
      final muted = global || channelMuted;
      // ignore: avoid_print
      print('[MacOsAudioOutput] apply mute '
          'global=$global channel=$channelMuted → muted=$muted');
      await _rfcomm.setMuted(muted);
    }

    unawaited(applyMute());
    _broker.subscribe(0, 'Mute', (_, __, ___) => applyMute());
    _broker.subscribe(100, 'Settings', (_, __, ___) => applyMute());
    _broker.subscribe(100, 'Channels', (_, __, ___) => applyMute());

    // Hot-swap the output device when the user picks a new SPEAKER in
    // Settings → Audio. Stored as a CoreAudio UID string.
    _broker.subscribe(0, 'MacOsOutputDeviceUid', (_, __, value) {
      final uid = value is String ? value : '';
      // ignore: avoid_print
      print('[MacOsAudioOutput] swap output device → '
          '${uid.isEmpty ? "(system default)" : uid}');
      unawaited(_rfcomm.setOutputDevice(uid).catchError((Object e) {
        // ignore: avoid_print
        print('[MacOsAudioOutput] setOutputDevice failed: $e');
      }));
    });

    // Default the software modem to AFSK1200 on first audio open so
    // APRS decoding just works. User can override via Modem settings.
    final modemMode = _broker.getValue<String>(0, 'SoftwareModemMode', 'None');
    if (modemMode.toUpperCase() == 'NONE') {
      DataBroker.dispatch(0, 'SetSoftwareModemMode', 'AFSK1200', store: true);
    }

    // Tap the decoded PCM stream → SoftwareModem. The radio's
    // hardware TNC delivers Benshi-proprietary text; over-the-air
    // AX.25 has to come through this software demod path.
    _rxPcmSub = _rfcomm.pcmStream().listen((pcm) {
      DataBroker.dispatch(
        radioDeviceId,
        'AudioDataAvailable',
        AudioDataEvent(data: pcm, length: pcm.length),
        store: false,
      );
    });
  }

  @override
  void writePcmMono(Uint8List monoSamples) {
    // Not used on macOS — PCM arrives natively from the RFCOMM
    // plugin, not from RadioAudioManager (the Linux/Windows
    // Dart-side codec path).
  }

  /// Inspects the currently-active channel (or VFO slot in ad-hoc
  /// mode) for its ``mute`` flag.
  bool _currentChannelMuted() {
    final settings =
        DataBroker.getValueDynamic(100, 'Settings') as RadioSettings?;
    if (settings == null) return false;
    final useB = settings.doubleChannel == 2;
    final activeId = useB ? settings.channelB : settings.channelA;
    RadioChannelInfo? ch;
    if (activeId == 0xFC) {
      ch = DataBroker.getValueDynamic(100, 'VfoAInfo') as RadioChannelInfo?;
    } else if (activeId == 0xFB) {
      ch = DataBroker.getValueDynamic(100, 'VfoBInfo') as RadioChannelInfo?;
    } else {
      final channels =
          DataBroker.getValueDynamic(100, 'Channels') as List?;
      if (channels != null &&
          activeId >= 0 &&
          activeId < channels.length &&
          channels[activeId] is RadioChannelInfo) {
        ch = channels[activeId] as RadioChannelInfo;
      }
    }
    return ch?.mute ?? false;
  }

  @override
  void stop() {
    _started = false;
    _rxPcmSub?.cancel();
    _rxPcmSub = null;
    // Native plugin's stop() handles the End-of-TX sequence + RFCOMM
    // close + AVAudioEngine teardown.
    unawaited(_rfcomm.close());
    _broker.dispose();
  }
}

/// macOS mic capture. Native Swift AVAudioEngine captures the mic;
/// the Phase 2 RFCOMM plugin owns the SBC encoder + RFCOMM write
/// internally. Dart just shovels PCM between the two.
class MacOsMicCapture implements MicCapture {
  final MacOsRadioBluetooth? _bt;
  final MacOsNativeAudio _nativeAudio = MacOsNativeAudio();
  final MacOsNativeRfcommAudio _rfcomm = MacOsNativeRfcommAudio();
  StreamSubscription<Uint8List>? _pcmSub;
  bool _started = false;

  MacOsMicCapture(this._bt);

  @override
  Future<void> start(int radioDeviceId) async {
    if (_started) return;
    _started = true;

    final storedUid = DataBroker.getValue<String>(0, 'MacOsInputDeviceUid', '');
    final deviceUid = storedUid.isEmpty ? null : storedUid;
    try {
      final pcmStream = await _nativeAudio.startMic(deviceUid: deviceUid);
      _pcmSub = pcmStream.listen((pcm) {
        unawaited(_rfcomm.writePcm(pcm));
      });
      // ignore: avoid_print
      print('[MacOsMicCapture] native mic → native RFCOMM (device=$deviceUid)');
    } catch (e) {
      // ignore: avoid_print
      print('[MacOsMicCapture] native mic start failed: $e');
      _started = false;
    }
  }

  @override
  void stop() {
    _started = false;
    _pcmSub?.cancel();
    _pcmSub = null;
    unawaited(_nativeAudio.stopMic());
    // Don't close the RFCOMM session here — RX still wants it open.
    // The TX side flushes on its own; the encoder's tail bytes
    // (and the End-of-TX packet on full session close) are handled
    // by RfcommAudioPlugin.
  }
}
