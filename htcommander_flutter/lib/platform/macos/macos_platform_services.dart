import 'dart:typed_data';

import '../audio_service.dart';
import '../bluetooth_service.dart';
import 'macos_audio.dart';
import 'macos_bluetooth.dart';
import 'macos_native_ble.dart';

/// macOS platform services — Phase 2.
///
/// Pure native: ``NativeBluetoothPlugin`` (CoreBluetooth) for BLE
/// control, ``RfcommAudioPlugin`` (IOBluetooth + libsbc +
/// AVAudioEngine) for RFCOMM audio, ``NativeAudioPlugin``
/// (AVAudioEngine) for mic capture. The bendio Python subprocess
/// is no longer involved.
class MacOsPlatformServices extends PlatformServices {
  /// The most recently created BT transport. Audio factories pass
  /// its address through to the native RFCOMM plugin.
  MacOsRadioBluetooth? _activeRadio;

  @override
  RadioBluetoothTransport createRadioBluetooth(String macAddress) {
    final t = MacOsRadioBluetooth(macAddress);
    _activeRadio = t;
    return t;
  }

  @override
  RadioAudioTransport createRadioAudioTransport() => _MacOsAudioStub();

  @override
  AudioOutput createAudioOutput() => MacOsAudioOutput(_activeRadio);

  @override
  MicCapture createMicCapture() => MacOsMicCapture(_activeRadio);

  /// Phase 2 TODO: native CoreAudio output-device enumeration so the
  /// Settings → Audio → SPEAKER dropdown can repopulate. For now the
  /// dropdown shows nothing and AVAudioEngine uses the macOS system
  /// default. Workaround: pick the speaker in System Settings → Sound.
  @override
  Future<Map<String, dynamic>?> listAudioDevices({bool refresh = false}) async {
    return null;
  }

  /// Native BLE scan via the CoreBluetooth plugin. Returns Benshi-
  /// family radios advertised on the air, identified by their
  /// CoreBluetooth UUID (which is what [createRadioBluetooth] needs).
  @override
  Future<List<CompatibleDevice>> scanForDevices() async {
    final ble = MacOsNativeBle();
    final raw = await ble.scan(timeout: 5.0);
    const benshiNames = [
      'UV-PRO', 'UV-Pro', 'UV-50PRO', 'GA-5WB',
      'VR-N75', 'VR-N76', 'VR-N7500', 'VR-N7600',
      'RT-660', 'GMRS-PRO',
    ];
    final out = <CompatibleDevice>[];
    for (final entry in raw) {
      final id = entry['id'] as String? ?? '';
      final name = entry['name'] as String? ?? '';
      if (id.isEmpty) continue;
      final isBenshi = entry['benshi_service'] == true ||
          benshiNames.any((n) => name.toUpperCase().contains(n.toUpperCase()));
      if (!isBenshi) continue;
      out.add(CompatibleDevice(name, id));
    }
    return out;
  }
}

// On macOS we don't expose a RadioAudioTransport. The Phase 2
// RFCOMM plugin owns the RFCOMM channel + SBC codec + AVAudioEngine
// playback in-process; the Radio class's Dart-side RadioAudioManager
// (Linux/Windows codec path) isn't used.
class _MacOsAudioStub implements RadioAudioTransport {
  @override
  bool get isConnected => false;
  @override
  Future<void> connect(String macAddress) async {}
  @override
  void disconnect() {}
  @override
  Future<Uint8List?> read(int maxBytes) async => null;
  @override
  Future<void> write(Uint8List data) async {}
  @override
  void dispose() {}
}
