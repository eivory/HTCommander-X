import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/data_broker.dart';
import '../audio_service.dart';
import 'macos_bluetooth.dart';
import 'macos_debug.dart';

/// macOS audio output. Receives decoded PCM from bendio's RFCOMM audio
/// channel and pipes it into an `ffplay` subprocess for playback on the
/// default output device. Parallels LinuxAudioOutput's paplay pattern.
///
/// We don't use Dart-side SBC decoding on macOS: bendio has ffmpeg-backed
/// decode built in, and we'd rather not port libsbc or bundle it.
class MacOsAudioOutput implements AudioOutput {
  final MacOsRadioBluetooth? _bt;
  Process? _ffplay;
  StreamSubscription<Uint8List>? _diagSub;
  StreamController<List<int>>? _pipe;
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
    // ignore: avoid_print
    print('[MacOsAudioOutput] audio_open returned $ok');
    if (!ok) {
      _started = false;
      return;
    }

    try {
      _ffplay = await Process.start('ffplay', [
        '-loglevel', 'info',
        '-nodisp',
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-probesize', '32',
        '-analyzeduration', '0',
        '-f', 's16le',
        '-ar', '32000',
        '-ch_layout', 'mono',
        '-i', 'pipe:0',
      ]);
    } catch (e) {
      // ignore: avoid_print
      print('[MacOsAudioOutput] could not spawn ffplay: $e');
      _started = false;
      return;
    }

    // ignore: avoid_print
    print('[MacOsAudioOutput] ffplay spawned pid=${_ffplay!.pid}');

    // ignore: avoid_print
    print('[MacOsAudioOutput] ffplay spawned pid=${_ffplay!.pid}');

    _ffplay!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => dprint('[ffplay] $line'));

    unawaited(_ffplay!.exitCode.then((code) {
      // ignore: avoid_print
      print('[MacOsAudioOutput] ffplay exited code=$code');
    }));

    // Feed ffplay via a dedicated StreamController. addStream handles
    // backpressure properly — manual add() calls on Process.stdin
    // have write-amplification that starves ffplay's audio queue.
    _pipe = StreamController<List<int>>();
    unawaited(_ffplay!.stdin.addStream(_pipe!.stream).catchError((Object e) {
      // ignore: avoid_print
      print('[MacOsAudioOutput] ffplay stdin addStream ended: $e');
    }));

    int rxFrames = 0;
    int rxBytes = 0;
    _diagSub = bt.rxPcmStream.listen((pcm) {
      rxFrames++;
      rxBytes += pcm.length;
      if (rxFrames == 1 || rxFrames % 50 == 0) {
        dprint('[MacOsAudioOutput] RX frames=$rxFrames bytes=$rxBytes');
      }
      if (_pipe != null && !_pipe!.isClosed) {
        _pipe!.add(pcm);
      }
    });
  }

  @override
  void writePcmMono(Uint8List monoSamples) {
    // Not used on macOS — PCM arrives from bendio via rxPcmStream, not
    // from RadioAudioManager (which is the Linux/Windows Dart-side codec
    // path).
  }

  @override
  void stop() {
    _started = false;
    _diagSub?.cancel();
    _diagSub = null;
    try {
      _pipe?.close();
    } catch (_) {}
    _pipe = null;
    try {
      _ffplay?.kill();
    } catch (_) {}
    _ffplay = null;
  }
}

/// macOS mic capture. Mic reading lives in bendio (via sounddevice)
/// for two reasons: avoids an avfoundation↔sounddevice index-space
/// mismatch with the speaker picker, and keeps the raw PCM off the
/// JSON-RPC wire. We just tell bendio when to start/stop and pass the
/// user-selected sounddevice input index (from DataBroker).
class MacOsMicCapture implements MicCapture {
  final MacOsRadioBluetooth? _bt;
  bool _started = false;

  MacOsMicCapture(this._bt);

  @override
  Future<void> start(int radioDeviceId) async {
    final bt = _bt;
    if (_started || bt == null) return;
    _started = true;

    // Ensure the RFCOMM audio channel is open.
    final ok = await bt.audioOpen();
    if (!ok) {
      // ignore: avoid_print
      print('[MacOsMicCapture] audio_open failed — TX will be silent');
      _started = false;
      return;
    }

    final stored = DataBroker.getValue<int>(0, 'MacOsInputDevice', -1);
    final inputDevice = stored >= 0 ? stored : null;
    final txOk = await bt.audioTxStart(inputDevice: inputDevice);
    if (!txOk) {
      // ignore: avoid_print
      print('[MacOsMicCapture] audio_tx_start failed');
      _started = false;
    }
  }

  @override
  void stop() {
    _started = false;
    final bt = _bt;
    if (bt != null) {
      unawaited(bt.audioTxStop());
    }
  }
}
