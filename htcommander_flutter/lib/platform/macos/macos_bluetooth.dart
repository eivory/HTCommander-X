import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bluetooth_service.dart';
import 'macos_debug.dart';
import 'macos_native_ble.dart';

/// macOS Bluetooth transport that speaks JSON-RPC to a `bendio server`
/// subprocess over stdio.
///
/// macOS doesn't expose Classic RFCOMM to sandboxed third-party apps the
/// way Linux/Windows do, and the UV-PRO's BLE control channel requires
/// native CoreBluetooth calls. Rather than bundle a PyObjC/CoreBluetooth
/// Dart port, we shell out to the bendio Python library (which already
/// has a well-tested BLE stack via bleak) and talk to it in JSON-RPC.
///
/// Protocol (byte-level bridge — no GAIA framing on BLE per
/// bendio/docs/PROTOCOL_NOTES.md):
///
///   enqueueWrite(cmd, expectedResponse)
///     → {"method":"ble_write","params":{"bytes":"<hex>"}}
///   bendio emits {"method":"ble_indication","params":{"bytes":"<hex>"}}
///     → onDataReceived(null, bytes)
class MacOsRadioBluetooth extends RadioBluetoothTransport {
  final String _address;
  // Native Swift CoreBluetooth: scan/connect/write/indicate. Replaces
  // the bendio Python subprocess for the BLE control path.
  final MacOsNativeBle _ble = MacOsNativeBle();
  StreamSubscription<Uint8List>? _indicationSub;
  // bendio still runs as a subprocess for RFCOMM audio (Phase 2 will
  // move that to Swift IOBluetooth). All audio_* JSON-RPC methods
  // continue to flow over its stdio.
  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _connected = false;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Uint8List> _rxPcmCtrl =
      StreamController<Uint8List>.broadcast();

  MacOsRadioBluetooth(this._address);

  /// Classic-BT MAC address for the audio RFCOMM channel. macOS doesn't
  /// expose a MAC to apps, so we pass the CoreBluetooth UUID through —
  /// bendio's macOS RFCOMM layer resolves both.
  String get address => _address;

  /// Stream of decoded PCM chunks from bendio (s16le, 32 kHz, mono).
  /// Fires once per SBC frame (roughly every 4 ms during RX audio).
  Stream<Uint8List> get rxPcmStream => _rxPcmCtrl.stream;

  @override
  bool get isConnected => _connected;

  @override
  void connect() {
    if (_connected || _indicationSub != null) return;
    _connectAsync();
  }

  Future<void> _connectAsync() async {
    // 1. Native CoreBluetooth connect (BLE control path).
    try {
      await _ble.connect(_address);
    } catch (e) {
      // ignore: avoid_print
      print('[macos-bt] native BLE connect failed: $e');
      onDataReceived?.call(Exception('BLE connect failed: $e'), null);
      return;
    }
    // ignore: avoid_print
    print('[macos-bt] native BLE connected to $_address');

    // 2. Forward indications to the Radio's onDataReceived pipeline.
    _indicationSub = _ble.indications().listen(
      (bytes) {
        dprint('[RX] ${_hexEncode(bytes)}');
        onDataReceived?.call(null, bytes);
      },
      onError: (Object e) {
        _connected = false;
        onDataReceived?.call(Exception('BLE: $e'), null);
      },
    );

    // 3. Spawn bendio for RFCOMM audio only (Phase 2 will replace).
    await _spawnBendioForAudio();

    _connected = true;
    onConnected?.call();
  }

  Future<void> _spawnBendioForAudio() async {
    try {
      // ignore: avoid_print
      print('[macos-bt] spawning python3 -m bendio.cli server (audio only)');
      final proc = await Process.start(
        'python3',
        ['-m', 'bendio.cli', 'server'],
        mode: ProcessStartMode.normal,
      );
      _proc = proc;

      _stdoutSub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: _onStdErr);

      _stderrSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // ignore: avoid_print
        print('[bendio] $line');
      });

      unawaited(proc.exitCode.then((code) {
        // ignore: avoid_print
        print('[macos-bt] bendio exited (code $code)');
        _proc = null;
      }));
    } catch (e, st) {
      // Audio is optional in Phase 1 — control still works without it.
      // ignore: avoid_print
      print('[macos-bt] bendio spawn failed (audio disabled): $e');
      // ignore: avoid_print
      print('$st');
    }
    return;
  }

  void _onLine(String line) {
    if (line.isEmpty) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      // ignore: avoid_print
      print('[bendio] non-JSON: $line');
      return;
    }

    final id = msg['id'];
    if (id is int && _pending.containsKey(id)) {
      _pending.remove(id)!.complete(msg);
      return;
    }

    // Only audio notifications still flow over JSON-RPC. BLE
    // indications come via the native CoreBluetooth plugin now.
    final method = msg['method'] as String?;
    if (method == 'audio_rx_pcm') {
      final params = msg['params'] as Map<String, dynamic>?;
      final hex = params?['bytes'] as String?;
      if (hex == null) return;
      if (_rxPcmCtrl.hasListener) {
        _rxPcmCtrl.add(_hexDecode(hex));
      }
    }
  }

  // ── Audio (RFCOMM channel 2 via bendio) ────────────────────────────

  /// Ask bendio to open the audio RFCOMM channel. Returns true on success.
  /// When [outputDevice] is non-null it's forwarded as the sounddevice
  /// index bendio should use for local RX playback.
  Future<bool> audioOpen({int? outputDevice}) async {
    if (!_connected || _proc == null) return false;
    final params = <String, Object>{'address': _address};
    if (outputDevice != null) params['output_device'] = outputDevice;
    final result = await _call('audio_open', params);
    if (result.containsKey('error')) {
      // ignore: avoid_print
      print('[macos-bt] audio_open error: ${result['error']}');
      return false;
    }
    return true;
  }

  /// Ask bendio for the list of available sounddevice input / output
  /// devices. When [refresh] is true, bendio re-enumerates PortAudio
  /// so newly-plugged-in devices appear.
  Future<Map<String, dynamic>?> listAudioDevices({bool refresh = false}) async {
    if (!_connected || _proc == null) return null;
    final params = <String, dynamic>{};
    if (refresh) params['refresh'] = true;
    final result = await _call('list_audio_devices', params);
    if (result.containsKey('error')) {
      // ignore: avoid_print
      print('[macos-bt] list_audio_devices error: ${result['error']}');
      return null;
    }
    final r = result['result'];
    if (r is Map) {
      return r.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  Future<void> audioClose() async {
    if (_proc == null) return;
    await _call('audio_close', {});
  }

  /// Tell bendio to start mic capture via sounddevice and feed the
  /// encoder → RFCOMM path. [inputDevice] is an optional sounddevice
  /// index (from list_audio_devices). Returns true on success.
  Future<bool> audioTxStart({int? inputDevice}) async {
    if (!_connected || _proc == null) return false;
    final params = <String, Object>{};
    if (inputDevice != null) params['input_device'] = inputDevice;
    final result = await _call('audio_tx_start', params);
    if (result.containsKey('error')) {
      // ignore: avoid_print
      print('[macos-bt] audio_tx_start error: ${result['error']}');
      return false;
    }
    return true;
  }

  Future<void> audioTxStop() async {
    if (_proc == null) return;
    await _call('audio_tx_stop', {});
  }

  /// Mute/unmute local speaker playback in bendio without tearing down
  /// the RFCOMM channel. The radio's own Mute setting only affects the
  /// HT's internal speaker; this covers the Mac speaker side.
  Future<void> audioSetMuted(bool muted) async {
    if (!_connected || _proc == null) return;
    await _call('audio_set_muted', {'muted': muted});
  }

  /// Hot-swap the currently active audio device without closing
  /// RFCOMM. [kind] is ``"input"`` or ``"output"``. [device] is the
  /// sounddevice index (null / -1 = system default). Returns true if
  /// bendio reported the swap applied.
  Future<bool> audioSetDevice({
    required String kind,
    required int? device,
  }) async {
    if (!_connected || _proc == null) return false;
    final params = <String, dynamic>{
      'kind': kind,
      'device': device ?? -1,
    };
    final result = await _call('audio_set_device', params);
    if (result.containsKey('error')) return false;
    final r = result['result'];
    return r is Map && r['applied'] == true;
  }

  int _txPcmCalls = 0;
  int _txPcmErrors = 0;

  /// Send PCM (s16le, 32 kHz, mono) to the radio via SBC encode in bendio.
  /// (Unused now that mic capture lives in bendio; kept for future
  /// pre-encoded audio like SSTV that needs to route through the TX path.)
  void audioTxPcm(Uint8List pcm) {
    if (!_connected || _proc == null) return;
    _txPcmCalls++;
    try {
      _proc!.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': _nextId++,
        'method': 'audio_tx_pcm',
        'params': {'bytes': _hexEncode(pcm)},
      }));
    } catch (e) {
      _txPcmErrors++;
      if (_txPcmErrors <= 3) {
        // ignore: avoid_print
        print('[macos-bt] audio_tx_pcm write #$_txPcmCalls failed: $e');
      }
    }
  }

  void _onStdErr(Object err) {
    onDataReceived?.call(Exception('bendio stdout error: $err'), null);
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params,
  ) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final req = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    _proc!.stdin.writeln(req);
    // macOS CoreBluetooth's first connect regularly takes 10–25 s while
    // the system resolves the per-device UUID. RFCOMM audio open can
    // also take 5–10 s while the server blocks its asyncio loop pumping
    // the NSRunLoop. Everything else is fast — a 15 s cap is plenty.
    final timeout = (method == 'connect' || method == 'audio_open')
        ? const Duration(seconds: 45)
        : const Duration(seconds: 15);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        return {
          'error': {'code': -1, 'message': 'timeout calling $method'}
        };
      },
    );
  }

  @override
  void disconnect() {
    _connected = false;
    // Tear down native BLE first so the Radio's onDataReceived doesn't
    // fire spurious indications mid-cleanup.
    _indicationSub?.cancel();
    _indicationSub = null;
    unawaited(_ble.disconnect().catchError((_) {}));
    if (_proc != null) {
      // Best-effort graceful shutdown of bendio (audio side); kill
      // follows after a short grace period.
      try {
        _proc!.stdin.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'id': _nextId++,
          'method': 'shutdown',
          'params': {},
        }));
      } catch (_) {}
      Future.delayed(const Duration(milliseconds: 500), _cleanup);
    } else {
      _cleanup();
    }
  }

  @override
  void enqueueWrite(int expectedResponse, Uint8List cmdData) {
    if (!_connected) return;
    dprint('[TX] ${_hexEncode(cmdData)}');
    // Fire-and-forget write to the native CoreBluetooth plugin. The
    // Radio class doesn't await write completion either; back-pressure
    // is the OS pipe / GATT MTU's job.
    unawaited(_ble.write(cmdData).catchError((Object e) {
      onDataReceived?.call(Exception('BLE write failed: $e'), null);
    }));
  }

  void _cleanup() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete({
          'error': {'code': -1, 'message': 'transport closed'}
        });
      }
    }
    _pending.clear();
    if (!_rxPcmCtrl.isClosed) _rxPcmCtrl.close();
  }

  static String _hexEncode(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
