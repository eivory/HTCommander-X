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

/// macOS audio output. On macOS we let bendio play the decoded PCM
/// directly via ``sounddevice``'s RawOutputStream — the audio hop
/// through Dart + ffplay on this box was consistently choppy. This
/// class therefore doesn't own any local playback; it just watches
/// the Mute / Settings / Channels broker and asks bendio to gate its
/// output stream when the user (or the active channel) is muted.
class MacOsAudioOutput implements AudioOutput {
  final MacOsRadioBluetooth? _bt;
  final DataBrokerClient _broker = DataBrokerClient();
  StreamSubscription<Uint8List>? _rxPcmSub;
  bool _started = false;

  MacOsAudioOutput(this._bt);

  @override
  Future<void> start(int radioDeviceId) async {
    final bt = _bt;
    if (_started || bt == null) return;
    _started = true;

    // ignore: avoid_print
    print('[MacOsAudioOutput] calling audio_open');
    // Pass the user's chosen output device (sounddevice index) if any.
    // -1 / unset means "let bendio pick the system default".
    final storedDevice =
        DataBroker.getValue<int>(0, 'MacOsOutputDevice', -1);
    final outputDevice = storedDevice >= 0 ? storedDevice : null;
    final ok = await bt.audioOpen(outputDevice: outputDevice);

    // Local speaker muting has two independent sources:
    //   1. The global Mute toggle (Audio settings) — per-user choice.
    //   2. The ``mute`` flag on the *active* channel — per-channel,
    //      set via the channel editor and honored by the HT's own
    //      speaker. We mirror it to the Mac side so a muted channel
    //      is silent everywhere.
    // Combine the two: speaker goes silent whenever either is true.
    Future<void> applyMute() async {
      final global = _broker.getValue<int>(0, 'Mute', 0) != 0;
      final channelMuted = _currentChannelMuted();
      final muted = global || channelMuted;
      // ignore: avoid_print
      print('[MacOsAudioOutput] apply mute '
          'global=$global channel=$channelMuted → muted=$muted');
      await bt.audioSetMuted(muted);
    }

    unawaited(applyMute());
    _broker.subscribe(0, 'Mute', (_, __, ___) => applyMute());
    _broker.subscribe(100, 'Settings', (_, __, ___) => applyMute());
    _broker.subscribe(100, 'Channels', (_, __, ___) => applyMute());
    // ignore: avoid_print
    print('[MacOsAudioOutput] audio_open returned $ok');
    if (!ok) {
      _started = false;
      return;
    }

    // Default the software modem to AFSK1200 on macOS the first time
    // we open audio, so APRS decoding just works. User can change it
    // via the Modem settings tab. (The stored value is preserved.)
    final modemMode = _broker.getValue<String>(0, 'SoftwareModemMode', 'None');
    if (modemMode.toUpperCase() == 'NONE') {
      DataBroker.dispatch(0, 'SetSoftwareModemMode', 'AFSK1200', store: true);
    }

    // Feed RX PCM into SoftwareModem so AFSK 1200 / PSK / etc.
    // packets can be decoded. The radio's hardware TNC only emits
    // Benshi's proprietary text-message format in DATA_RXD events, so
    // actual over-the-air APRS (AX.25) has to come through here.
    _rxPcmSub = bt.rxPcmStream.listen((pcm) {
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
    // Not used on macOS — PCM arrives from bendio via rxPcmStream, not
    // from RadioAudioManager (which is the Linux/Windows Dart-side codec
    // path).
  }

  /// Inspects the currently-active channel (or VFO slot in ad-hoc
  /// mode) for its ``mute`` flag. Returns false if the radio state
  /// isn't populated yet or the channel couldn't be resolved.
  bool _currentChannelMuted() {
    final settings =
        DataBroker.getValueDynamic(100, 'Settings') as RadioSettings?;
    if (settings == null) return false;
    // doubleChannel: 1=A, 2=B, 0=both (treat as A).
    final useB = settings.doubleChannel == 2;
    final activeId = useB ? settings.channelB : settings.channelA;
    RadioChannelInfo? ch;
    String src;
    if (activeId == 0xFC) {
      ch = DataBroker.getValueDynamic(100, 'VfoAInfo') as RadioChannelInfo?;
      src = 'vfoA';
    } else if (activeId == 0xFB) {
      ch = DataBroker.getValueDynamic(100, 'VfoBInfo') as RadioChannelInfo?;
      src = 'vfoB';
    } else {
      final channels =
          DataBroker.getValueDynamic(100, 'Channels') as List?;
      if (channels != null &&
          activeId >= 0 &&
          activeId < channels.length &&
          channels[activeId] is RadioChannelInfo) {
        ch = channels[activeId] as RadioChannelInfo;
      }
      src = 'channels[$activeId]';
    }
    // ignore: avoid_print
    print('[MacOsAudioOutput] channel detect '
        'doubleChannel=${settings.doubleChannel} '
        '(${useB ? "B" : "A"}) activeId=$activeId src=$src '
        'name=${ch?.nameStr ?? "?"} mute=${ch?.mute}');
    return ch?.mute ?? false;
  }

  @override
  void stop() {
    _started = false;
    _rxPcmSub?.cancel();
    _rxPcmSub = null;
    _broker.dispose();
  }
}

/// macOS mic capture. Uses the native Swift ``NativeAudioPlugin``
/// (AVAudioEngine + CoreAudio) for low-latency mic capture, then
/// ships 32 kHz mono s16le PCM chunks to bendio via the
/// ``audio_tx_pcm`` JSON-RPC method for SBC encode + RFCOMM send.
///
/// Earlier versions routed mic capture through ``sounddevice``
/// (PortAudio) inside bendio. That was simpler but produced choppy
/// TX audio on Bluetooth inputs — PortAudio has a bad rep on macOS
/// BT. Going native fixed it.
class MacOsMicCapture implements MicCapture {
  final MacOsRadioBluetooth? _bt;
  final MacOsNativeAudio _nativeAudio = MacOsNativeAudio();
  StreamSubscription<Uint8List>? _pcmSub;
  bool _started = false;

  MacOsMicCapture(this._bt);

  @override
  Future<void> start(int radioDeviceId) async {
    final bt = _bt;
    if (_started || bt == null) return;
    _started = true;

    // Ensure the RFCOMM audio channel is open so audio_tx_pcm works.
    final ok = await bt.audioOpen();
    if (!ok) {
      // ignore: avoid_print
      print('[MacOsMicCapture] audio_open failed — TX will be silent');
      _started = false;
      return;
    }

    final storedUid = DataBroker.getValue<String>(0, 'MacOsInputDeviceUid', '');
    final deviceUid = storedUid.isEmpty ? null : storedUid;
    try {
      final pcmStream = await _nativeAudio.startMic(deviceUid: deviceUid);
      _pcmSub = pcmStream.listen((pcm) {
        bt.audioTxPcm(pcm);
      });
      // ignore: avoid_print
      print('[MacOsMicCapture] native mic started (device=$deviceUid)');
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
  }
}
