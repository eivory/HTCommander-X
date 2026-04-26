import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart façade over the Swift ``RfcommAudioPlugin`` that lives in
/// ``macos/Runner/RfcommAudioPlugin.swift``.
///
/// Replaces bendio's Python+ffmpeg+sounddevice audio path entirely.
/// All RFCOMM / SBC / playback work is in-process Swift backed by
/// libsbc (vendored in ``Runner/sbc/``), IOBluetooth, and
/// AVAudioEngine.
class MacOsNativeRfcommAudio {
  static const MethodChannel _method =
      MethodChannel('htcommander.macos/audio_rfcomm');
  static const EventChannel _events =
      EventChannel('htcommander.macos/audio_rfcomm_pcm');

  /// Open the RFCOMM audio channel on the paired radio identified by
  /// [address]. Accepts either a Classic-BT MAC ("AA:BB:..") or the
  /// CoreBluetooth UUID we use elsewhere — the Swift side resolves
  /// either to a paired ``IOBluetoothDevice`` by name match for
  /// Benshi-family radios. If the user hasn't paired in System
  /// Settings → Bluetooth, throws a ``PlatformException`` with a
  /// user-readable message.
  Future<void> open({
    required String address,
    bool muted = false,
    String? outputDevice,
  }) async {
    await _method.invokeMethod('open', {
      'address': address,
      'muted': muted,
      if (outputDevice != null && outputDevice.isNotEmpty)
        'outputDevice': outputDevice,
    });
  }

  /// Hot-swap the AVAudioEngine output device by CoreAudio UID. Pass
  /// null/empty to revert to system default. Causes a brief glitch
  /// because AVAudioEngine doesn't support live retargeting.
  Future<void> setOutputDevice(String? uid) async {
    await _method.invokeMethod('setOutputDevice', {'device': uid ?? ''});
  }

  Future<void> close() async {
    await _method.invokeMethod('close');
  }

  /// Append [pcm] (s16le mono 32 kHz) to the TX encoder. PCM is
  /// buffered server-side until a whole 128-sample frame is
  /// available, then encoded + framed + written to RFCOMM.
  Future<void> writePcm(Uint8List pcm) async {
    await _method.invokeMethod('writePcm', {'bytes': _hex(pcm)});
  }

  /// Mute / unmute local AVAudioEngine playback. RX PCM still flows
  /// to [pcmStream] when muted so the SoftwareModem can decode
  /// packets in silence.
  Future<void> setMuted(bool muted) async {
    await _method.invokeMethod('setMuted', {'muted': muted});
  }

  /// Decoded PCM tap (s16le mono 32 kHz). Fires once per SBC frame
  /// (~4 ms of audio). Plug into SoftwareModem / SSTV / waterfall.
  Stream<Uint8List> pcmStream() {
    return _events
        .receiveBroadcastStream()
        .map((e) => e is Uint8List ? e : Uint8List(0))
        .where((b) => b.isNotEmpty);
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
