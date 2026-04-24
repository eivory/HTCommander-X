import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../audio_service.dart';
import '../bluetooth_service.dart';
import 'macos_audio.dart';
import 'macos_bluetooth.dart';

/// macOS platform services. Phase A: BLE control only (no audio).
///
/// The bendio Python library handles all BLE transport via bleak; we spawn
/// it as a subprocess per connection. Audio (Phase B) will add a second
/// channel for SBC-encoded PCM, likely over a side stream since stdin/stdout
/// is reserved for JSON-RPC.
class MacOsPlatformServices extends PlatformServices {
  /// The most recently created BLE transport. Audio factories reach for
  /// it so they can share the same bendio subprocess (there's only one,
  /// and it owns both the BLE control channel and the RFCOMM audio
  /// channel). Nulled out when a new radio is connected.
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

  /// Scans for compatible BLE radios via the bendio JSON-RPC server.
  ///
  /// Spawns `bendio server` briefly, issues `scan`, then `shutdown`. Returns
  /// the CoreBluetooth per-device UUID as the `mac` field — on macOS apps
  /// never see a real MAC, so the UUID is what [createRadioBluetooth] needs
  /// as the connect address.
  @override
  Future<List<CompatibleDevice>> scanForDevices() async {
    Process? proc;
    try {
      proc = await Process.start('python3', ['-m', 'bendio.cli', 'server']);

      final lines = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // Swallow stderr (progress messages) so it doesn't clog the pipe.
      proc.stderr.drain<void>();

      final req = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'scan',
        'params': {'timeout': 5.0, 'only_benshi': true},
      });
      proc.stdin.writeln(req);

      final devices = <CompatibleDevice>[];
      await for (final line in lines) {
        if (line.isEmpty) continue;
        final msg = jsonDecode(line) as Map<String, dynamic>;
        if (msg['id'] != 1) continue;
        final result = msg['result'];
        if (result is List) {
          for (final entry in result) {
            final m = entry as Map<String, dynamic>;
            final address = (m['address'] as String?) ?? '';
            final name = (m['name'] as String?) ?? '';
            if (address.isEmpty) continue;
            devices.add(CompatibleDevice(name, address));
          }
        }
        break;
      }

      proc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'shutdown',
        'params': {},
      }));
      await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        proc!.kill();
        return -1;
      });
      return devices;
    } catch (_) {
      try {
        proc?.kill();
      } catch (_) {}
      return [];
    }
  }
}

// On macOS we don't expose a RadioAudioTransport: bendio handles the
// RFCOMM audio channel internally and decodes/encodes SBC itself, so
// the Radio class's Dart-side RadioAudioManager is bypassed. PCM flows
// directly between MacOsRadioBluetooth and MacOsAudioOutput/MicCapture.
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
