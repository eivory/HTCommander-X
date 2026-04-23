import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bluetooth_service.dart';

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
  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _connected = false;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  MacOsRadioBluetooth(this._address);

  @override
  bool get isConnected => _connected;

  @override
  void connect() {
    if (_proc != null) return;
    _spawn();
  }

  Future<void> _spawn() async {
    try {
      // ignore: avoid_print
      print('[macos-bt] spawning python3 -m bendio.cli server for $_address');
      final proc = await Process.start(
        'python3',
        ['-m', 'bendio.cli', 'server'],
        mode: ProcessStartMode.normal,
      );
      _proc = proc;
      // ignore: avoid_print
      print('[macos-bt] spawned pid=${proc.pid}');

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
        _connected = false;
        onDataReceived?.call(
          Exception('bendio exited (code $code)'),
          null,
        );
        _cleanup();
      }));

      // ignore: avoid_print
      print('[macos-bt] sending connect to bendio');
      final result = await _call('connect', {'address': _address});
      // ignore: avoid_print
      print('[macos-bt] connect result: $result');
      if (result.containsKey('error')) {
        final err = result['error'] as Map<String, dynamic>;
        onDataReceived?.call(
          Exception('bendio connect failed: ${err['message']}'),
          null,
        );
        return;
      }
      _connected = true;
      onConnected?.call();
    } catch (e, st) {
      // ignore: avoid_print
      print('[macos-bt] spawn failed: $e\n$st');
      onDataReceived?.call(
        Exception('Failed to start bendio: $e. '
            'Install with: pip3 install git+https://github.com/eivory/bendio.git'),
        null,
      );
      _cleanup();
    }
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

    // Server-initiated notification
    final method = msg['method'] as String?;
    if (method == 'ble_indication') {
      final params = msg['params'] as Map<String, dynamic>?;
      final hex = params?['bytes'] as String?;
      if (hex == null) return;
      // ignore: avoid_print
      print('[RX] $hex');
      final bytes = _hexDecode(hex);
      onDataReceived?.call(null, bytes);
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
    return completer.future.timeout(
      const Duration(seconds: 15),
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
    if (_proc != null) {
      // Best-effort graceful shutdown; kill follows after a short grace period.
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
    if (!_connected || _proc == null) return;
    final hex = _hexEncode(cmdData);
    // ignore: avoid_print
    print('[TX] $hex');
    try {
      _proc!.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': _nextId++,
        'method': 'ble_write',
        'params': {'bytes': hex},
      }));
    } catch (e) {
      onDataReceived?.call(Exception('write failed: $e'), null);
    }
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
