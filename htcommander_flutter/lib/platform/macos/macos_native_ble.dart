import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart façade over the Swift ``NativeBluetoothPlugin`` that lives in
/// ``macos/Runner/NativeBluetoothPlugin.swift``.
///
/// Replaces the bendio Python subprocess + JSON-RPC stdio bridge for
/// BLE. Uses CoreBluetooth (CBCentralManager + CBPeripheral) directly
/// in-process — no subprocess overhead, no hex/JSON encoding, no
/// runloop-pump latency.
class MacOsNativeBle {
  static const MethodChannel _method =
      MethodChannel('htcommander.macos/ble');
  static const EventChannel _events =
      EventChannel('htcommander.macos/ble_indication');

  /// Scan for advertising BLE peripherals for [timeout] seconds and
  /// return a list of discovered devices. Each entry has ``id`` (the
  /// CBPeripheral UUID string), ``name``, ``rssi``, and optionally
  /// ``benshi_service`` if the radio service UUID was advertised.
  Future<List<Map<String, dynamic>>> scan({double timeout = 5.0}) async {
    final raw = await _method.invokeListMethod<dynamic>(
        'scan', {'timeout': timeout});
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Connect to the peripheral identified by [deviceUuid] (string form
  /// of a CoreBluetooth UUID). Throws on failure.
  Future<void> connect(String deviceUuid) async {
    await _method.invokeMethod('connect', {'deviceUuid': deviceUuid});
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
  }

  /// Write [bytes] (raw Message bytes — no GAIA framing on BLE) to
  /// the radio's write characteristic.
  Future<void> write(Uint8List bytes) async {
    await _method.invokeMethod('write', {'bytes': _hexEncode(bytes)});
  }

  /// Stream of indications from the radio's indicate characteristic.
  /// Each event is the raw value of one indication (radio Message
  /// bytes). On disconnect a [PlatformException] with code
  /// ``disconnected`` is emitted.
  Stream<Uint8List> indications() {
    return _events.receiveBroadcastStream().map((event) {
      if (event is Uint8List) return event;
      if (event is List<int>) return Uint8List.fromList(event);
      return Uint8List(0);
    }).where((b) => b.isNotEmpty);
  }

  static String _hexEncode(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
