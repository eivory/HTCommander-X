import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart façade over the Swift ``NativeAudioPlugin`` that lives in
/// ``macos/Runner/NativeAudioPlugin.swift``.
///
/// Uses AVAudioEngine + CoreAudio directly — no PortAudio or ffmpeg —
/// for mic capture on macOS. That's what fixed the choppy TX we saw
/// when routing through ``sounddevice.RawInputStream``. Device
/// enumeration returns CoreAudio UIDs (stable across reboots), not
/// sounddevice indices, so the mic picker uses its own index space
/// and can't be confused with bendio's speaker picker.
class MacOsNativeAudio {
  static const MethodChannel _method =
      MethodChannel('htcommander.macos/audio');
  static const EventChannel _events =
      EventChannel('htcommander.macos/audio_pcm');

  /// List CoreAudio input devices. Each entry: `{"id": String, "name":
  /// String, "default": bool}`. Use the ``id`` field in [startMic].
  Future<List<Map<String, dynamic>>> listInputDevices() async {
    final raw = await _method.invokeListMethod<dynamic>('listInputDevices');
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Start mic capture; the returned [Stream] yields 32 kHz mono
  /// s16le PCM chunks. Caller is responsible for shipping the chunks
  /// to bendio's ``audio_tx_pcm``. Pass a CoreAudio device UID or null
  /// to use the system default input.
  Future<Stream<Uint8List>> startMic({String? deviceUid}) async {
    await _method.invokeMethod<Map>('startMic', {
      if (deviceUid != null) 'deviceUid': deviceUid,
    });
    return _events
        .receiveBroadcastStream()
        .map((event) => event is Uint8List ? event : Uint8List(0))
        .where((b) => b.isNotEmpty);
  }

  Future<void> stopMic() async {
    await _method.invokeMethod('stopMic');
  }
}
