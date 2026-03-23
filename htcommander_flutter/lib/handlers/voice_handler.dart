import 'dart:typed_data';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../radio/morse_engine.dart';

/// Simplified VoiceHandler stub.
///
/// Port of HTCommander.Core/Utils/VoiceHandler.cs (simplified).
/// Subscribes to Chat, Speak, and Morse commands and processes them.
/// Full STT/TTS/SSTV/recording functionality will be added later.
class VoiceHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  bool _disposed = false;
  bool _enabled = false;
  int _targetDeviceId = -1; // -1 means disabled

  VoiceHandler() {
    // Subscribe to VoiceHandlerEnable/Disable commands on device 1
    _broker.subscribe(1, 'VoiceHandlerEnable', _onVoiceHandlerEnable);
    _broker.subscribe(1, 'VoiceHandlerDisable', _onVoiceHandlerDisable);

    // Subscribe to Chat, Speak, Morse from all devices
    _broker.subscribe(DataBroker.allDevices, 'Chat', _onChat);
    _broker.subscribe(DataBroker.allDevices, 'Speak', _onSpeak);
    _broker.subscribe(DataBroker.allDevices, 'Morse', _onMorse);

    _broker.logInfo('[VoiceHandler] Voice Handler initialized');
  }

  /// Handles VoiceHandlerEnable command.
  /// Expected data: Map with 'DeviceId', 'Language', 'Model' keys.
  void _onVoiceHandlerEnable(int deviceId, String name, Object? data) {
    if (_disposed || data == null) return;

    try {
      if (data is Map) {
        final targetDevice = data['DeviceId'] as int?;
        final language = data['Language'] as String?;
        // ignore: unused_local_variable
        final model = data['Model'] as String?;

        if (targetDevice == null || language == null) {
          _broker.logError(
              '[VoiceHandler] Invalid VoiceHandlerEnable data format');
          return;
        }

        // Validate that the radio is connected
        final radioState =
            DataBroker.getValue<String>(targetDevice, 'State', '');
        if (radioState != 'Connected') {
          _broker.logError(
              '[VoiceHandler] Cannot enable for device $targetDevice: '
              'Radio is not connected (state: $radioState)');
          return;
        }

        _enabled = true;
        _targetDeviceId = targetDevice;
        _broker.logInfo(
            '[VoiceHandler] Enabled for device $targetDevice, language: $language');
      } else {
        _broker.logError(
            '[VoiceHandler] Invalid VoiceHandlerEnable data format');
      }
    } catch (e) {
      _broker.logError('[VoiceHandler] Error in OnVoiceHandlerEnable: $e');
    }
  }

  /// Handles VoiceHandlerDisable command.
  void _onVoiceHandlerDisable(int deviceId, String name, Object? data) {
    if (_disposed) return;
    _enabled = false;
    _targetDeviceId = -1;
    _broker.logInfo('[VoiceHandler] Disabled');
  }

  /// Handles Chat command — dispatches message to DecodedText on device 1.
  /// In the full implementation, this sends a BSS packet via the radio.
  /// For now, it dispatches the message text to DecodedText for display.
  void _onChat(int deviceId, String name, Object? data) {
    if (_disposed || data == null) return;

    final message = data is String ? data : null;
    if (message == null || message.isEmpty) return;

    // Validate message length (must be > 0 and < 255 characters)
    if (message.length >= 255) {
      _broker.logError(
          '[VoiceHandler] Cannot send chat: Message length must be between '
          '1 and 254 characters (got ${message.length})');
      return;
    }

    // Determine the target device for transmission
    final transmitDeviceId = _resolveTransmitDevice(deviceId);
    if (transmitDeviceId == null) {
      _broker.logError(
          '[VoiceHandler] Cannot send chat: No radio is voice-enabled');
      return;
    }

    try {
      final callsign =
          _broker.getValue<String>(0, 'CallSign', '');
      if (callsign.isEmpty) {
        _broker.logError(
            '[VoiceHandler] Cannot send chat: Callsign not configured');
        return;
      }

      _broker.logInfo(
          '[VoiceHandler] Sending chat on device $transmitDeviceId: '
          '$callsign: $message');

      // Dispatch to DecodedText for display in the Communication tab
      _broker.dispatch(1, 'DecodedText', '$callsign: $message', store: false);
    } catch (e) {
      _broker.logError('[VoiceHandler] Error sending chat: $e');
    }
  }

  /// Handles Speak command — TTS not yet implemented.
  void _onSpeak(int deviceId, String name, Object? data) {
    if (_disposed || data == null) return;

    final textToSpeak = data is String ? data : null;
    if (textToSpeak == null || textToSpeak.isEmpty) return;

    final transmitDeviceId = _resolveTransmitDevice(deviceId);
    if (transmitDeviceId == null) {
      _broker.logError(
          '[VoiceHandler] Cannot speak: No radio is voice-enabled');
      return;
    }

    _broker.logInfo(
        '[VoiceHandler] TTS not yet implemented. Text: $textToSpeak');
  }

  /// Handles Morse command — generates morse PCM and dispatches TransmitVoicePCM.
  void _onMorse(int deviceId, String name, Object? data) {
    if (_disposed || data == null) return;

    final textToMorse = data is String ? data : null;
    if (textToMorse == null || textToMorse.isEmpty) return;

    final transmitDeviceId = _resolveTransmitDevice(deviceId);
    if (transmitDeviceId == null) {
      _broker.logError(
          '[VoiceHandler] Cannot transmit morse: No radio is voice-enabled');
      return;
    }

    try {
      _broker.logInfo(
          '[VoiceHandler] Generating morse code on device $transmitDeviceId: '
          '$textToMorse');

      // Generate morse code PCM (8-bit unsigned, 32kHz)
      final morsePcm8bit = MorseEngine.generateMorsePcm(textToMorse);

      if (morsePcm8bit.isEmpty) {
        _broker.logError('[VoiceHandler] Failed to generate morse code PCM');
        return;
      }

      // Convert 8-bit unsigned PCM to 16-bit signed PCM
      // 8-bit unsigned: 0-255, with 128 as center (silence)
      // 16-bit signed: -32768 to 32767, with 0 as center (silence)
      final pcmData = Uint8List(morsePcm8bit.length * 2);
      for (int i = 0; i < morsePcm8bit.length; i++) {
        final int sample16 = ((morsePcm8bit[i] - 128) * 256);
        pcmData[i * 2] = sample16 & 0xFF;
        pcmData[i * 2 + 1] = (sample16 >> 8) & 0xFF;
      }

      // Send PCM data to the radio for transmission via DataBroker
      // Include PlayLocally=true so the user can hear the morse output
      _broker.dispatch(
          transmitDeviceId,
          'TransmitVoicePCM',
          <String, Object>{'Data': pcmData, 'PlayLocally': true},
          store: false);
      _broker.logInfo(
          '[VoiceHandler] Transmitted ${pcmData.length} bytes of morse PCM '
          'to device $transmitDeviceId');
    } catch (e) {
      _broker.logError('[VoiceHandler] Error generating morse code: $e');
    }
  }

  /// Whether the voice handler is currently enabled.
  bool get isEnabled => _enabled;

  /// Resolves the target device ID for transmission.
  /// Returns null if no valid target is available.
  int? _resolveTransmitDevice(int deviceId) {
    if (deviceId == 1) {
      // Device 1: use the currently voice-enabled radio
      if (!_enabled || _targetDeviceId <= 0) return null;
      return _targetDeviceId;
    } else if (deviceId >= 100) {
      // Device 100+: use that device ID directly
      return deviceId;
    }
    // Other device IDs (2-99): ignore
    return null;
  }

  /// Disposes the voice handler and unsubscribes from all events.
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _enabled = false;
      _targetDeviceId = -1;
      _broker.dispose();
    }
  }
}
