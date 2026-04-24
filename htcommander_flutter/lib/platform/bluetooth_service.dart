import 'dart:typed_data';
import 'audio_service.dart';

/// Callback types for Bluetooth transport events.
typedef OnDataReceived = void Function(Exception? error, Uint8List? data);
typedef OnConnected = void Function();

/// Abstract Bluetooth RFCOMM transport for radio communication.
///
/// Platform implementations:
/// - Linux: Native RFCOMM sockets via dart:ffi
/// - Android: flutter_blue_plus or flutter_bluetooth_serial
/// - Windows: Method channel to WinRT Bluetooth APIs
abstract class RadioBluetoothTransport {
  /// Callback fired when GAIA command data is received (decoded from GAIA frames).
  OnDataReceived? onDataReceived;

  /// Callback fired when the Bluetooth connection is established.
  OnConnected? onConnected;

  /// Initiates Bluetooth connection to the radio.
  void connect();

  /// Disconnects from the radio.
  void disconnect();

  /// Encodes [cmdData] as a GAIA frame and writes it to the RFCOMM socket.
  /// [expectedResponse] is used for command/response matching.
  void enqueueWrite(int expectedResponse, Uint8List cmdData);

  /// Whether the transport is currently connected.
  bool get isConnected;
}

/// Abstract audio transport for the radio's audio RFCOMM channel.
///
/// The radio uses a separate RFCOMM channel (GenericAudio UUID 00001203)
/// for SBC-encoded bidirectional audio.
abstract class RadioAudioTransport {
  /// Connects to the audio RFCOMM channel.
  Future<void> connect(String macAddress);

  /// Disconnects from the audio channel.
  void disconnect();

  /// Reads audio data from the transport.
  Future<Uint8List?> read(int maxBytes);

  /// Writes audio data to the transport.
  Future<void> write(Uint8List data);

  /// Whether the audio transport is connected.
  bool get isConnected;

  /// Disposes resources.
  void dispose();
}

/// Discovered Bluetooth device.
class CompatibleDevice {
  final String name;
  final String mac;

  const CompatibleDevice(this.name, this.mac);
}

/// Abstract platform services factory.
abstract class PlatformServices {
  /// Global instance set during app initialization.
  static PlatformServices? instance;

  /// Creates a Bluetooth transport for the given radio.
  RadioBluetoothTransport createRadioBluetooth(String macAddress);

  /// Creates an audio transport for the given radio.
  RadioAudioTransport createRadioAudioTransport();

  /// Creates an audio output for decoded radio audio playback.
  AudioOutput createAudioOutput();

  /// Creates a microphone capture for radio transmission.
  MicCapture createMicCapture();

  /// Scans for compatible Bluetooth devices.
  Future<List<CompatibleDevice>> scanForDevices();

  /// Lists available audio input/output devices for UI device pickers.
  /// Platforms that don't support enumeration return null.
  ///
  /// Shape: `{"output": [{index, name}], "input": [...],
  ///          "default_output": int, "default_input": int}`.
  Future<Map<String, dynamic>?> listAudioDevices() async => null;
}
