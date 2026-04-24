import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../audio_service.dart';
import 'macos_bluetooth.dart';

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
    final ok = await bt.audioOpen();
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
        .listen((line) {
      // ignore: avoid_print
      print('[ffplay] $line');
    });

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
        // ignore: avoid_print
        print('[MacOsAudioOutput] RX frames=$rxFrames bytes=$rxBytes');
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

/// macOS mic capture. Spawns `ffmpeg -f avfoundation` to read from the
/// default audio input, producing s16le 32 kHz mono PCM. PCM is fed to
/// bendio via JSON-RPC `audio_tx_pcm`, which encodes to SBC and emits it
/// on RFCOMM channel 2.
class MacOsMicCapture implements MicCapture {
  final MacOsRadioBluetooth? _bt;
  Process? _ffmpeg;
  StreamSubscription<List<int>>? _stdoutSub;
  final _buffer = BytesBuilder();
  bool _started = false;

  static const int _chunkBytes = 256; // 128 samples mono s16 = one SBC frame

  MacOsMicCapture(this._bt);

  @override
  Future<void> start(int radioDeviceId) async {
    final bt = _bt;
    if (_started || bt == null) return;
    _started = true;

    // Ensure the RFCOMM audio channel is open. It's idempotent in the
    // right direction (bendio closes the previous session first), but
    // if MacOsAudioOutput hasn't opened it yet we need to now — otherwise
    // audio_tx_pcm calls will fail with "audio not open".
    final ok = await bt.audioOpen();
    if (!ok) {
      // ignore: avoid_print
      print('[MacOsMicCapture] audio_open failed — TX will be silent');
      _started = false;
      return;
    }

    // ignore: avoid_print
    print('[MacOsMicCapture] spawning ffmpeg avfoundation');
    _ffmpeg = await Process.start('ffmpeg', [
      '-loglevel', 'error',
      '-nostdin',
      '-f', 'avfoundation',
      '-i', ':0',
      '-ar', '32000',
      '-ac', '1',
      '-f', 's16le',
      '-',
    ]);

    _ffmpeg!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      // ignore: avoid_print
      print('[ffmpeg-mic] $line');
    });

    int totalSent = 0;
    _stdoutSub = _ffmpeg!.stdout.listen(
      (chunk) {
        _buffer.add(chunk);
        while (_buffer.length >= _chunkBytes) {
          final all = _buffer.takeBytes();
          final n = (all.length ~/ _chunkBytes) * _chunkBytes;
          bt.audioTxPcm(Uint8List.fromList(all.sublist(0, n)));
          totalSent += n;
          if (n < all.length) {
            _buffer.add(all.sublist(n));
          }
        }
      },
      onDone: () {
        // ignore: avoid_print
        print('[MacOsMicCapture] ffmpeg stdout closed (sent=$totalSent bytes)');
      },
      onError: (Object err) {
        // ignore: avoid_print
        print('[MacOsMicCapture] ffmpeg stdout error: $err');
      },
      cancelOnError: false,
    );

    unawaited(_ffmpeg!.exitCode.then((code) {
      // ignore: avoid_print
      print('[MacOsMicCapture] ffmpeg exited code=$code (sent=$totalSent bytes)');
    }));
  }

  @override
  void stop() {
    _started = false;
    _stdoutSub?.cancel();
    _stdoutSub = null;
    try {
      _ffmpeg?.kill();
    } catch (_) {}
    _ffmpeg = null;
    _buffer.clear();
  }
}
