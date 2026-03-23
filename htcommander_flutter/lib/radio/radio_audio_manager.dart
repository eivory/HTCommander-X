import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import '../core/data_broker_client.dart';
import '../platform/bluetooth_service.dart';
import 'sbc/sbc_decoder.dart';
import 'sbc/sbc_encoder.dart';
import 'sbc/sbc_enums.dart';
import 'sbc/sbc_frame.dart';

/// Audio framing protocol constants.
/// 0x7E = start/end marker, 0x7D = escape (XOR 0x20).
class _AudioFrame {
  static const int marker = 0x7E;
  static const int escape = 0x7D;
  static const int cmdAudioData = 0x00;
  // ignore: unused_field
  static const int cmdEnd = 0x01;
  // ignore: unused_field
  static const int cmdLoopback = 0x02;

  /// End audio frame sentinel.
  static final Uint8List endFrame = Uint8List.fromList([
    0x7E, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E
  ]);
}

/// Cross-platform radio audio pipeline.
///
/// Port of HTCommander.Core/radio/RadioAudioManager.cs (940 lines).
/// Manages bidirectional SBC-encoded audio over a Bluetooth RFCOMM channel:
/// - RX: BT audio → 0x7E deframe → SBC decode → PCM → speaker
/// - TX: PCM → SBC encode → 0x7E frame → BT audio
class RadioAudioManager {
  final int deviceId;
  final String macAddress;
  final DataBrokerClient _broker = DataBrokerClient();

  // Transport
  RadioAudioTransport? _transport;
  bool _running = false;
  bool _isConnecting = false;
  bool _isAudioEnabled = false;

  // SBC codec
  SbcDecoder? _sbcDecoder;
  SbcEncoder? _sbcEncoder;
  late SbcFrame _sbcEncoderFrame;
  late int _pcmInputSizePerFrame;

  // Audio state
  // ignore: unused_field
  double _outputVolume = 1.0;
  // ignore: unused_field
  bool _isMuted = false;
  final bool _recording = false;
  int currentChannelId = 0;
  String currentChannelName = '';

  // Voice transmission queue
  final Queue<Uint8List> _pcmQueue = Queue<Uint8List>();
  bool _isTransmitting = false;
  bool _voiceTransmitCancel = false;
  Completer<void>? _newDataAvailable;

  bool get isAudioEnabled => _isAudioEnabled;
  bool get recording => _recording;

  RadioAudioManager(this.deviceId, this.macAddress) {
    _broker.subscribe(deviceId, 'TransmitVoicePCM', _onTransmitVoicePcm);
    _broker.subscribe(deviceId, 'SetOutputVolume', _onSetOutputVolume);
    _broker.subscribe(deviceId, 'SetMute', _onSetMute);
    _broker.subscribe(deviceId, 'CancelVoiceTransmit', _onCancelVoiceTransmit);

    final storedVol = _broker.getValue<int>(deviceId, 'OutputAudioVolume', 100);
    _outputVolume = storedVol / 100.0;
    _isMuted = _broker.getValue<bool>(deviceId, 'Mute', false);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────

  /// Start the audio pipeline (connect BT audio transport + begin receive loop).
  Future<void> start(RadioAudioTransport transport) async {
    if (_running || _isConnecting) return;
    _isConnecting = true;

    _debug('Connecting audio transport...');
    try {
      _transport = transport;
      await _transport!.connect(macAddress);
      _isConnecting = false;
      _running = true;
      _debug('Audio transport connected.');
    } catch (e) {
      _debug('Audio transport connection error: $e');
      _transport?.dispose();
      _transport = null;
      _isConnecting = false;
      return;
    }

    // Initialize SBC codec
    _sbcDecoder = SbcDecoder();
    _sbcEncoder = SbcEncoder();

    _sbcEncoderFrame = SbcFrame()
      ..frequency = SbcFrequency.freq32K
      ..blocks = 16
      ..mode = SbcMode.mono
      ..allocationMethod = SbcBitAllocationMethod.loudness
      ..subbands = 8
      ..bitpool = 18;

    _pcmInputSizePerFrame = _sbcEncoderFrame.blocks * _sbcEncoderFrame.subbands * 2;

    _isAudioEnabled = true;
    _dispatchAudioState(true);

    // Start receive loop
    _receiveLoop();
  }

  /// Stop the audio pipeline.
  void stop() {
    _running = false;
    _transport?.disconnect();
    _transport?.dispose();
    _transport = null;
    _isAudioEnabled = false;
    _dispatchAudioState(false);
  }

  void dispose() {
    stop();
    _broker.dispose();
  }

  // ── Receive Loop ───────────────────────────────────────────────────

  Future<void> _receiveLoop() async {
    final accumulator = <int>[];
    bool inFrame = false;
    bool escaped = false;

    while (_running && _transport != null) {
      try {
        final data = await _transport!.read(4096);
        if (data == null || data.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }

        // Process 0x7E-framed data
        for (final b in data) {
          if (b == _AudioFrame.marker) {
            if (inFrame && accumulator.isNotEmpty) {
              _processAudioFrame(Uint8List.fromList(accumulator));
            }
            accumulator.clear();
            inFrame = true;
            escaped = false;
          } else if (inFrame) {
            if (escaped) {
              accumulator.add(b ^ 0x20);
              escaped = false;
            } else if (b == _AudioFrame.escape) {
              escaped = true;
            } else {
              accumulator.add(b);
            }
          }
        }
      } catch (e) {
        if (_running) _debug('Audio receive error: $e');
        break;
      }
    }
  }

  void _processAudioFrame(Uint8List frameData) {
    if (frameData.isEmpty) return;

    final cmd = frameData[0];
    if (cmd == _AudioFrame.cmdAudioData) {
      // SBC audio data — decode to PCM
      final sbcData = frameData.sublist(1);
      _decodeSbcFrame(sbcData);
    }
    // cmd 0x01 = end/control, cmd 0x02 = loopback — handled silently
  }

  void _decodeSbcFrame(Uint8List sbcData) {
    if (_sbcDecoder == null) return;

    final result = _sbcDecoder!.decode(sbcData);
    if (!result.success) return;

    // Convert Int16List PCM to bytes (16-bit LE) for dispatch
    final pcmLeft = result.pcmLeft;
    final pcmBytes = Uint8List(pcmLeft.length * 2);
    for (var i = 0; i < pcmLeft.length; i++) {
      pcmBytes[i * 2] = pcmLeft[i] & 0xFF;
      pcmBytes[i * 2 + 1] = (pcmLeft[i] >> 8) & 0xFF;
    }

    // Dispatch decoded audio for playback and data subscribers
    _broker.dispatch(deviceId, 'AudioDataAvailable', pcmBytes, store: false);
  }

  // ── Transmit Pipeline ──────────────────────────────────────────────

  void _onTransmitVoicePcm(int devId, String name, Object? data) {
    if (data == null || !_running || _transport == null) return;

    Uint8List? pcmData;
    if (data is Uint8List) {
      pcmData = data;
    } else if (data is Map) {
      pcmData = data['Data'] as Uint8List?;
    }

    if (pcmData != null && pcmData.isNotEmpty) {
      _transmitVoice(pcmData);
    }
  }

  void _transmitVoice(Uint8List pcmData) {
    _pcmQueue.add(pcmData);

    if (!_isTransmitting) {
      _isTransmitting = true;
      _voiceTransmitCancel = false;
      _startTransmissionLoop();
    } else {
      // Signal new data available
      _newDataAvailable?.complete();
    }
  }

  Future<void> _startTransmissionLoop() async {
    final transport = _transport;
    if (transport == null) { _isTransmitting = false; return; }

    try {
      while (_pcmQueue.isNotEmpty && !_voiceTransmitCancel && _running) {
        final pcmData = _pcmQueue.removeFirst();

        // Encode PCM to SBC frames
        var offset = 0;
        while (offset + _pcmInputSizePerFrame <= pcmData.length && !_voiceTransmitCancel) {
          final chunk = pcmData.sublist(offset, offset + _pcmInputSizePerFrame);
          // Convert bytes to Int16List PCM samples
          final pcmSamples = Int16List(chunk.length ~/ 2);
          for (var s = 0; s < pcmSamples.length; s++) {
            final raw = chunk[s * 2] | (chunk[s * 2 + 1] << 8);
            pcmSamples[s] = raw > 32767 ? raw - 65536 : raw;
          }
          final sbcFrame = _sbcEncoder?.encode(pcmSamples, null, _sbcEncoderFrame);
          if (sbcFrame != null) {
            final escaped = _escapeBytes(sbcFrame);
            await transport.write(escaped);
          }
          offset += _pcmInputSizePerFrame;

          // Real-time pacing: ~100ms per 128 samples at 32kHz
          await Future.delayed(const Duration(milliseconds: 90));
        }
      }

      // Send end-of-transmission frame
      if (_running && !_voiceTransmitCancel) {
        await transport.write(_AudioFrame.endFrame);
      }
    } catch (e) {
      _debug('Transmit error: $e');
    } finally {
      _isTransmitting = false;
    }
  }

  /// Escape bytes for 0x7E audio framing protocol.
  Uint8List _escapeBytes(Uint8List sbcFrame) {
    // Calculate escaped size
    var escapedSize = 2; // start + end markers
    escapedSize++; // command byte (0x00 = audio data)
    for (final b in sbcFrame) {
      escapedSize += (b == _AudioFrame.marker || b == _AudioFrame.escape) ? 2 : 1;
    }

    final escaped = Uint8List(escapedSize);
    var idx = 0;
    escaped[idx++] = _AudioFrame.marker;
    escaped[idx++] = _AudioFrame.cmdAudioData;
    for (final b in sbcFrame) {
      if (b == _AudioFrame.marker || b == _AudioFrame.escape) {
        escaped[idx++] = _AudioFrame.escape;
        escaped[idx++] = b ^ 0x20;
      } else {
        escaped[idx++] = b;
      }
    }
    escaped[idx++] = _AudioFrame.marker;
    return Uint8List.view(escaped.buffer, 0, idx);
  }

  // ── Event Handlers ─────────────────────────────────────────────────

  void _onSetOutputVolume(int devId, String name, Object? data) {
    if (data is int) {
      _outputVolume = data / 100.0;
      _broker.dispatch(deviceId, 'OutputAudioVolume', data);
    }
  }

  void _onSetMute(int devId, String name, Object? data) {
    if (data is bool) {
      _isMuted = data;
      _broker.dispatch(deviceId, 'Mute', data);
    }
  }

  void _onCancelVoiceTransmit(int devId, String name, Object? data) {
    _voiceTransmitCancel = true;
    _pcmQueue.clear();
  }

  // ── Helpers ────────────────────────────────────────────────────────

  void _dispatchAudioState(bool enabled) {
    _broker.dispatch(deviceId, 'AudioState', enabled);
  }

  void _debug(String msg) {
    _broker.dispatch(1, 'LogInfo', '[RadioAudio/$deviceId]: $msg', store: false);
  }
}
