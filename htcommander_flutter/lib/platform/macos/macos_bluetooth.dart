import 'dart:async';
import 'dart:typed_data';

import '../bluetooth_service.dart';
import 'macos_debug.dart';
import 'macos_native_ble.dart';

/// macOS Bluetooth transport — Phase 2.
///
/// Pure Swift native: ``NativeBluetoothPlugin`` (CoreBluetooth) for
/// BLE control, ``RfcommAudioPlugin`` (IOBluetooth + libsbc +
/// AVAudioEngine) for RFCOMM audio. The bendio Python subprocess is
/// no longer involved.
///
/// This class owns BLE only. Audio lifecycle lives in
/// ``MacOsAudioOutput`` / ``MacOsMicCapture`` and the native RFCOMM
/// plugin behind them.
class MacOsRadioBluetooth extends RadioBluetoothTransport {
  final String _address;
  final MacOsNativeBle _ble = MacOsNativeBle();
  StreamSubscription<Uint8List>? _indicationSub;
  bool _connected = false;

  MacOsRadioBluetooth(this._address);

  /// CoreBluetooth UUID (or Classic-BT MAC) for this radio.
  /// MacOsAudioOutput passes this through to the RFCOMM plugin.
  String get address => _address;

  @override
  bool get isConnected => _connected;

  @override
  void connect() {
    if (_connected || _indicationSub != null) return;
    _connectAsync();
  }

  Future<void> _connectAsync() async {
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

    _connected = true;
    onConnected?.call();
  }

  @override
  void disconnect() {
    _connected = false;
    _indicationSub?.cancel();
    _indicationSub = null;
    unawaited(_ble.disconnect().catchError((_) {}));
  }

  @override
  void enqueueWrite(int expectedResponse, Uint8List cmdData) {
    if (!_connected) return;
    dprint('[TX] ${_hexEncode(cmdData)}');
    unawaited(_ble.write(cmdData).catchError((Object e) {
      onDataReceived?.call(Exception('BLE write failed: $e'), null);
    }));
  }

  static String _hexEncode(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
