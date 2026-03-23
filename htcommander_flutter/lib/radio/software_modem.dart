/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import 'models/tnc_data_fragment.dart';
import 'models/radio_ht_status.dart';
import 'radio_enums.dart';

/// Software modem mode types.
enum SoftwareModemModeType {
  none,
  afsk1200,
  psk2400,
  psk4800,
  g3ruh9600,
}

/// Audio data event payload dispatched via DataBroker.
class AudioDataEvent {
  final Uint8List data;
  final int offset;
  final int length;
  final String channelName;
  final bool transmit;

  const AudioDataEvent({
    required this.data,
    this.offset = 0,
    required this.length,
    this.channelName = '',
    this.transmit = false,
  });
}

/// A PCM payload waiting to be transmitted once the channel is clear.
class _PendingTransmission {
  final Uint8List pcmData;
  final DateTime deadline;
  const _PendingTransmission({required this.pcmData, required this.deadline});
}

/// Per-radio modem state for handling audio processing.
class _RadioModemState {
  int deviceId;
  String macAddress = '';
  String currentChannelName = '';
  int currentChannelId = 0;
  int currentRegionId = 0;
  SoftwareModemModeType mode;
  bool initialized = false;

  // AFSK 1200 demodulator state
  _AfskDemodulator? afskDemodulator;

  // Clear-channel transmit queue
  final List<_PendingTransmission> transmitQueue = [];
  bool waitingForChannel = false;
  bool channelIsClear = false;
  Timer? channelWaitTimer;

  _RadioModemState({
    required this.deviceId,
    required this.mode,
  });

  void dispose() {
    afskDemodulator = null;
    channelWaitTimer?.cancel();
    channelWaitTimer = null;
    transmitQueue.clear();
    waitingForChannel = false;
    initialized = false;
  }
}

// ---------------------------------------------------------------------------
// AFSK 1200 Bell 202 modulator/demodulator (mark=1200 Hz, space=2200 Hz)
// ---------------------------------------------------------------------------

/// CRC-16 CCITT (x^16 + x^12 + x^5 + 1), init 0xFFFF, bit-reversed I/O.
class _Crc16Ccitt {
  int _crc = 0xFFFF;

  void reset() => _crc = 0xFFFF;

  void addBit(int bit) {
    final xorBit = ((_crc & 1) ^ bit);
    _crc >>= 1;
    if (xorBit != 0) _crc ^= 0x8408;
  }

  void addByte(int b) {
    for (int i = 0; i < 8; i++) {
      addBit((b >> i) & 1);
    }
  }

  int get value => _crc ^ 0xFFFF;

  bool get isValid => _crc == 0xF0B8; // magic residual
}

/// HDLC frame decoder — receives a stream of bits, detects 0x7E flags,
/// removes bit-stuffing, checks CRC-16 and emits complete frames.
class _HdlcDecoder {
  int _shiftReg = 0;
  int _onesCount = 0;
  bool _inFrame = false;
  final List<int> _frameBuffer = [];
  final _Crc16Ccitt _crc = _Crc16Ccitt();
  int _currentByte = 0;
  int _currentBitIndex = 0;

  /// Process a single demodulated bit.  Returns a complete frame (without
  /// CRC bytes) when one is available, otherwise null.
  Uint8List? processBit(int bit) {
    _shiftReg = ((_shiftReg << 1) | bit) & 0xFF;

    // Detect flag 0x7E (01111110)
    if (_shiftReg == 0x7E) {
      if (_inFrame && _frameBuffer.length >= 2) {
        // End of frame — check CRC
        // The last 16 bits in the stream are FCS; they are already in _frameBuffer
        // as the last 2 bytes. Validate by checking the CRC residual.
        if (_crc.isValid && _frameBuffer.length > 2) {
          // Strip 2-byte FCS
          final frame =
              Uint8List.fromList(_frameBuffer.sublist(0, _frameBuffer.length - 2));
          _resetFrame();
          return frame;
        }
      }
      _resetFrame();
      _inFrame = true;
      return null;
    }

    if (!_inFrame) return null;

    // Bit-stuffing: after 5 consecutive ones, a zero is a stuff bit — discard
    if (bit == 1) {
      _onesCount++;
      if (_onesCount > 6) {
        // Abort — 7+ ones in a row
        _inFrame = false;
        _resetFrame();
        return null;
      }
    } else {
      if (_onesCount == 5) {
        // Stuff bit — discard
        _onesCount = 0;
        return null;
      }
      _onesCount = 0;
    }

    // Accumulate data bits LSB-first
    _currentByte = (_currentByte >> 1) | ((bit & 1) << 7);
    _crc.addBit(bit);
    _currentBitIndex++;

    if (_currentBitIndex == 8) {
      _frameBuffer.add(_currentByte);
      _currentByte = 0;
      _currentBitIndex = 0;
    }

    return null;
  }

  void _resetFrame() {
    _frameBuffer.clear();
    _crc.reset();
    _onesCount = 0;
    _currentByte = 0;
    _currentBitIndex = 0;
  }
}

/// NRZI decoder: in NRZI encoding a 0-bit is represented by a transition
/// and a 1-bit by no transition.
class _NrziDecoder {
  int _lastBit = 0;

  int decode(int bit) {
    final decoded = (bit == _lastBit) ? 1 : 0;
    _lastBit = bit;
    return decoded;
  }
}

/// Simple AFSK 1200 Bell 202 demodulator using a correlation (product
/// detector) approach.  Operates at a fixed sample rate of 32 kHz.
class _AfskDemodulator {
  static const int _sampleRate = 32000;
  static const int _baudRate = 1200;
  static const double _markFreq = 1200.0;
  static const double _spaceFreq = 2200.0;

  // Correlation filter length — one bit period of samples
  final int _samplesPerBit = _sampleRate ~/ _baudRate;

  // Circular buffer for the correlation detector
  late final Float64List _markI;
  late final Float64List _markQ;
  late final Float64List _spaceI;
  late final Float64List _spaceQ;
  // Bit timing / clock recovery
  double _phase = 0.0;
  double _lastCorrelation = 0.0;

  // Sub-components
  final _NrziDecoder _nrzi = _NrziDecoder();
  final _HdlcDecoder _hdlc = _HdlcDecoder();

  // Callback for decoded frames
  void Function(Uint8List frame)? onFrameDecoded;

  _AfskDemodulator() {
    _markI = Float64List(_samplesPerBit);
    _markQ = Float64List(_samplesPerBit);
    _spaceI = Float64List(_samplesPerBit);
    _spaceQ = Float64List(_samplesPerBit);

    // Pre-compute correlation reference signals
    for (int i = 0; i < _samplesPerBit; i++) {
      final t = i / _sampleRate;
      _markI[i] = cos(2.0 * pi * _markFreq * t);
      _markQ[i] = sin(2.0 * pi * _markFreq * t);
      _spaceI[i] = cos(2.0 * pi * _spaceFreq * t);
      _spaceQ[i] = sin(2.0 * pi * _spaceFreq * t);
    }
  }

  // Circular correlation buffers
  late final Float64List _sampleBuf = Float64List(_samplesPerBit);
  int _sampleBufIdx = 0;

  /// Feed a single 16-bit PCM sample into the demodulator.
  void processSample(int sample) {
    final s = sample / 32768.0;

    // Store sample in circular buffer
    _sampleBuf[_sampleBufIdx] = s;
    _sampleBufIdx = (_sampleBufIdx + 1) % _samplesPerBit;

    // Correlate with mark and space reference tones
    double mI = 0, mQ = 0, sI = 0, sQ = 0;
    for (int i = 0; i < _samplesPerBit; i++) {
      final idx = (_sampleBufIdx + i) % _samplesPerBit;
      final v = _sampleBuf[idx];
      mI += v * _markI[i];
      mQ += v * _markQ[i];
      sI += v * _spaceI[i];
      sQ += v * _spaceQ[i];
    }

    final markPower = mI * mI + mQ * mQ;
    final spacePower = sI * sI + sQ * sQ;
    final correlation = markPower - spacePower;

    // Simple clock recovery: detect zero-crossings of the correlation signal
    // and nudge the phase accordingly
    if ((_lastCorrelation > 0 && correlation <= 0) ||
        (_lastCorrelation < 0 && correlation >= 0)) {
      // Transition detected — nudge phase toward centre of bit
      if (_phase < _samplesPerBit * 0.5) {
        _phase += _samplesPerBit * 0.025;
      } else {
        _phase -= _samplesPerBit * 0.025;
      }
    }
    _lastCorrelation = correlation;

    // Advance symbol clock
    _phase += 1.0;
    if (_phase >= _samplesPerBit) {
      _phase -= _samplesPerBit;

      // Sample the bit
      final rawBit = correlation > 0 ? 1 : 0;

      // NRZI decode
      final dataBit = _nrzi.decode(rawBit);

      // HDLC decode
      final frame = _hdlc.processBit(dataBit);
      if (frame != null && onFrameDecoded != null) {
        onFrameDecoded!(frame);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// AFSK 1200 modulator (Bell 202) + HDLC framing for transmit
// ---------------------------------------------------------------------------

/// CRC-16 CCITT for transmit (addByte interface, result for appending).
class _TxCrc16 {
  int _crc = 0xFFFF;

  void reset() => _crc = 0xFFFF;

  void addByte(int b) {
    for (int i = 0; i < 8; i++) {
      final xorBit = ((_crc & 1) ^ ((b >> i) & 1));
      _crc >>= 1;
      if (xorBit != 0) _crc ^= 0x8408;
    }
  }

  /// Returns the 2-byte FCS (little-endian, bit-inverted).
  List<int> get fcsBytes {
    final fcs = _crc ^ 0xFFFF;
    return [fcs & 0xFF, (fcs >> 8) & 0xFF];
  }
}

/// NRZI encoder: 0 → transition, 1 → no transition.
class _NrziEncoder {
  int _lastTone = 0; // 0 = mark, 1 = space

  int encode(int bit) {
    if (bit == 0) {
      _lastTone ^= 1;
    }
    return _lastTone;
  }
}

/// AFSK 1200 modulator: generates 16-bit PCM at 32 kHz.
class _AfskModulator {
  static const int _sampleRate = 32000;
  static const double _markFreq = 1200.0;
  static const double _spaceFreq = 2200.0;
  double _oscPhase = 0.0;

  /// Generate PCM samples for a single bit (mark=1, space=0 after NRZI).
  void generateBit(int tone, List<int> output) {
    final freq = tone == 0 ? _markFreq : _spaceFreq;
    final samplesPerBit = _sampleRate ~/ 1200;
    for (int i = 0; i < samplesPerBit; i++) {
      final sample = (sin(_oscPhase) * 25000).round().clamp(-32768, 32767);
      output.add(sample);
      _oscPhase += 2.0 * pi * freq / _sampleRate;
      if (_oscPhase > 2.0 * pi) _oscPhase -= 2.0 * pi;
    }
  }
}

/// Encode a raw AX.25 frame (without CRC) into AFSK 1200 PCM audio.
/// Produces: preamble flags + HDLC frame (bit-stuffed) + FCS + postamble flags.
Uint8List afsk1200Encode(Uint8List frameData,
    {int preambleFlags = 30, int postambleFlags = 10}) {
  final nrzi = _NrziEncoder();
  final mod = _AfskModulator();
  final samples = <int>[];

  void sendByte(int b, {bool stuff = false}) {
    int onesCount = 0;
    for (int i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final tone = nrzi.encode(bit);
      mod.generateBit(tone, samples);

      if (stuff) {
        if (bit == 1) {
          onesCount++;
          if (onesCount == 5) {
            // Insert zero stuff bit
            final stuffTone = nrzi.encode(0);
            mod.generateBit(stuffTone, samples);
            onesCount = 0;
          }
        } else {
          onesCount = 0;
        }
      }
    }
  }

  // Preamble: 0x7E flags (not stuffed)
  for (int i = 0; i < preambleFlags; i++) {
    sendByte(0x7E);
  }

  // Compute CRC over the frame data
  final crc = _TxCrc16();
  for (int i = 0; i < frameData.length; i++) {
    crc.addByte(frameData[i]);
  }

  // Frame data (bit-stuffed)
  for (int i = 0; i < frameData.length; i++) {
    sendByte(frameData[i], stuff: true);
  }

  // FCS (bit-stuffed)
  final fcs = crc.fcsBytes;
  sendByte(fcs[0], stuff: true);
  sendByte(fcs[1], stuff: true);

  // Postamble flags
  for (int i = 0; i < postambleFlags; i++) {
    sendByte(0x7E);
  }

  // Convert samples list to 16-bit little-endian PCM bytes
  final pcm = Uint8List(samples.length * 2);
  final bd = ByteData.sublistView(pcm);
  for (int i = 0; i < samples.length; i++) {
    bd.setInt16(i * 2, samples[i], Endian.little);
  }
  return pcm;
}

// ---------------------------------------------------------------------------
// FX.25 Reed-Solomon stub
// ---------------------------------------------------------------------------

// TODO: Implement FX.25 Reed-Solomon codec for forward error correction.
// FX.25 wraps standard AX.25 HDLC frames with a correlation tag and RS
// parity symbols, allowing the receiver to correct bit errors.  A full
// GF(2^8) RS encoder/decoder is non-trivial and is deferred to a future PR.

// ---------------------------------------------------------------------------
// SoftwareModem DataBroker handler
// ---------------------------------------------------------------------------

/// Software modem DataBroker handler that processes PCM audio from radios
/// and decodes/encodes TNC frames using various modulation schemes.
///
/// Port of HTCommander.Core/radio/SoftwareModem.cs
class SoftwareModem {
  final DataBrokerClient _broker;
  final Map<int, _RadioModemState> _radioModems = {};
  SoftwareModemModeType _currentMode = SoftwareModemModeType.none;
  bool _disposed = false;
  static final Random _rng = Random();

  SoftwareModem() : _broker = DataBrokerClient() {
    // Load saved mode from device 0
    final savedMode =
        _broker.getValue<String>(0, 'SoftwareModemMode', 'None');
    _currentMode = _parseMode(savedMode);

    // Subscribe to mode changes on device 0
    _broker.subscribe(0, 'SetSoftwareModemMode', _onSetModeRequested);

    // Subscribe to audio data from all radios
    _broker.subscribe(
        DataBroker.allDevices, 'AudioDataAvailable', _onAudioDataAvailable);

    // Subscribe to HtStatus changes from all radios to update channel info
    _broker.subscribe(
        DataBroker.allDevices, 'HtStatus', _onHtStatusChanged);

    // Subscribe to transmit packet requests from all radios
    _broker.subscribe(DataBroker.allDevices, 'SoftModemTransmitPacket',
        _onTransmitPacketRequested);

    // Subscribe to channel-clear notifications from all radios
    _broker.subscribe(
        DataBroker.allDevices, 'ChannelClear', _onChannelClear);

    // Publish initial mode
    _broker.dispatch(0, 'SoftwareModemMode', _currentMode.name, store: true);

    _debug('SoftwareModem initialized with mode: $_currentMode');
  }

  /// Current modem mode.
  SoftwareModemModeType get currentMode => _currentMode;

  /// Whether any modem mode is active.
  bool get isEnabled => _currentMode != SoftwareModemModeType.none;

  // ---------------------------------------------------------------------------
  // Mode management
  // ---------------------------------------------------------------------------

  static SoftwareModemModeType _parseMode(String mode) {
    switch (mode.toUpperCase()) {
      case 'AFSK1200':
        return SoftwareModemModeType.afsk1200;
      case 'PSK2400':
        return SoftwareModemModeType.psk2400;
      case 'PSK4800':
        return SoftwareModemModeType.psk4800;
      case 'G3RUH9600':
        return SoftwareModemModeType.g3ruh9600;
      default:
        return SoftwareModemModeType.none;
    }
  }

  FragmentEncodingType _getEncodingType(SoftwareModemModeType mode) {
    switch (mode) {
      case SoftwareModemModeType.afsk1200:
        return FragmentEncodingType.softwareAfsk1200;
      case SoftwareModemModeType.psk2400:
        return FragmentEncodingType.softwarePsk2400;
      case SoftwareModemModeType.psk4800:
        return FragmentEncodingType.softwarePsk4800;
      case SoftwareModemModeType.g3ruh9600:
        return FragmentEncodingType.softwareG3ruh9600;
      case SoftwareModemModeType.none:
        return FragmentEncodingType.unknown;
    }
  }

  void _onSetModeRequested(int deviceId, String name, Object? data) {
    if (_disposed) return;
    final modeStr = data is String ? data : data?.toString() ?? '';
    final newMode = _parseMode(modeStr);
    setMode(newMode);
  }

  /// Sets the software modem mode.
  void setMode(SoftwareModemModeType mode) {
    if (_currentMode == mode) return;

    _debug('Changing software modem mode from $_currentMode to $mode');

    // Cleanup all existing per-radio modem states
    for (final state in _radioModems.values) {
      state.dispose();
    }
    _radioModems.clear();

    _currentMode = mode;

    // Save to device 0
    _broker.dispatch(0, 'SoftwareModemMode', mode.name, store: true);

    _debug('Software modem mode changed to $mode');
  }

  // ---------------------------------------------------------------------------
  // HtStatus tracking
  // ---------------------------------------------------------------------------

  void _onHtStatusChanged(int deviceId, String name, Object? data) {
    if (_disposed || deviceId <= 0) return;

    final state = _radioModems[deviceId];
    if (state == null) return;

    if (data is RadioHtStatus) {
      state.currentChannelId = data.currChId;
      state.currentRegionId = data.currRegion;

      // Track whether the channel is currently clear
      final isClear = data.rssi == 0 && !data.isInTx;
      final wasClear = state.channelIsClear;
      state.channelIsClear = isClear;

      // If the channel just became clear while we're waiting, start the random-delay timer
      if (isClear &&
          !wasClear &&
          state.waitingForChannel &&
          state.transmitQueue.isNotEmpty) {
        _startChannelClearTimer(state);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Audio receive path
  // ---------------------------------------------------------------------------

  void _onAudioDataAvailable(int deviceId, String name, Object? data) {
    if (_disposed || deviceId <= 0) return;
    if (_currentMode == SoftwareModemModeType.none) return;

    try {
      if (data is! AudioDataEvent) return;
      if (data.transmit) return;

      final pcmData = data.data;
      if (pcmData.isEmpty) return;

      final offset = data.offset;
      final length = data.length;

      // Validate bounds
      if (offset < 0 ||
          length < 0 ||
          length > pcmData.length ||
          offset > pcmData.length - length) {
        return;
      }

      _processPcmData(deviceId, pcmData, offset, length, data.channelName);
    } catch (e) {
      _debug('OnAudioDataAvailable error: $e');
    }
  }

  void _processPcmData(
      int deviceId, Uint8List data, int offset, int length, String channelName) {
    if (_currentMode == SoftwareModemModeType.none) return;

    // Get or create modem state for this radio
    var state = _radioModems[deviceId];
    if (state == null) {
      state = _createRadioModemState(deviceId);
      if (state == null) return;
      _radioModems[deviceId] = state;
    }

    if (channelName.isNotEmpty) {
      state.currentChannelName = channelName;
    }

    try {
      switch (_currentMode) {
        case SoftwareModemModeType.afsk1200:
          if (state.afskDemodulator == null) return;
          for (int i = offset; i < offset + length - 1; i += 2) {
            final sample = (data[i] | (data[i + 1] << 8)).toSigned(16);
            state.afskDemodulator!.processSample(sample);
          }
          break;

        case SoftwareModemModeType.psk2400:
        case SoftwareModemModeType.psk4800:
          // PSK demodulation not yet implemented
          break;

        case SoftwareModemModeType.g3ruh9600:
          // G3RUH 9600 demodulation not yet implemented
          break;

        case SoftwareModemModeType.none:
          break;
      }
    } catch (e) {
      _debug('ProcessPcmData error for device $deviceId: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Per-radio state creation
  // ---------------------------------------------------------------------------

  _RadioModemState? _createRadioModemState(int deviceId) {
    try {
      // Get radio info from the broker
      final radioInfo = _broker.getValueDynamic(deviceId, 'Info');
      if (radioInfo == null) return null;

      String macAddress = '';
      // Try to get MAC address from connected radios list
      final connectedRadios =
          _broker.getValueDynamic(1, 'ConnectedRadios');
      if (connectedRadios is List) {
        for (final radio in connectedRadios) {
          if (radio is Map) {
            final devId = radio['DeviceId'];
            if (devId is int && devId == deviceId) {
              final mac = radio['MacAddress'];
              if (mac is String) macAddress = mac;
              break;
            }
          }
        }
      }

      final state = _RadioModemState(
        deviceId: deviceId,
        mode: _currentMode,
      )..macAddress = macAddress;

      // Get current HtStatus for channel info
      final htStatus =
          _broker.getValue<RadioHtStatus?>(deviceId, 'HtStatus', null);
      if (htStatus != null) {
        state.currentChannelId = htStatus.currChId;
        state.currentRegionId = htStatus.currRegion;
      }

      // Initialize modem based on current mode
      _initializeModemState(state, _currentMode);

      return state;
    } catch (e) {
      _debug('CreateRadioModemState error for device $deviceId: $e');
      return null;
    }
  }

  void _initializeModemState(
      _RadioModemState state, SoftwareModemModeType mode) {
    switch (mode) {
      case SoftwareModemModeType.afsk1200:
        _initializeAfsk1200(state);
        break;
      case SoftwareModemModeType.psk2400:
        _debug('PSK 2400 demodulator not yet implemented');
        break;
      case SoftwareModemModeType.psk4800:
        _debug('PSK 4800 demodulator not yet implemented');
        break;
      case SoftwareModemModeType.g3ruh9600:
        _debug('G3RUH 9600 demodulator not yet implemented');
        break;
      case SoftwareModemModeType.none:
        break;
    }

    state.initialized = true;
    _debug('Initialized $mode modem for device ${state.deviceId}');
  }

  void _initializeAfsk1200(_RadioModemState state) {
    state.afskDemodulator = _AfskDemodulator();
    state.afskDemodulator!.onFrameDecoded = (Uint8List frame) {
      _onFrameDecoded(state, frame, FragmentFrameType.ax25, 0);
    };
  }

  // ---------------------------------------------------------------------------
  // Frame reception
  // ---------------------------------------------------------------------------

  void _onFrameDecoded(_RadioModemState state, Uint8List frameData,
      FragmentFrameType frameType, int corrections) {
    try {
      final fragment = TncDataFragment(
        finalFragment: true,
        fragmentId: 0,
        data: frameData,
        channelId: state.currentChannelId,
        regionId: state.currentRegionId,
      );
      fragment.incoming = true;
      fragment.channelName = state.currentChannelName;
      fragment.encoding = _getEncodingType(state.mode);
      fragment.frameType = frameType;
      fragment.time = DateTime.now();
      fragment.radioMac = state.macAddress;
      fragment.radioDeviceId = state.deviceId;
      fragment.corrections = corrections;

      _dispatchDecodedFrame(state.deviceId, fragment);
    } catch (e) {
      _debug('OnFrameDecoded error: $e');
    }
  }

  void _dispatchDecodedFrame(int deviceId, TncDataFragment fragment) {
    _broker.dispatch(deviceId, 'DataFrame', fragment, store: false);
  }

  // ---------------------------------------------------------------------------
  // Packet transmission
  // ---------------------------------------------------------------------------

  void _onTransmitPacketRequested(int deviceId, String name, Object? data) {
    if (_disposed || deviceId <= 0) return;
    if (_currentMode == SoftwareModemModeType.none) return;
    if (data is! TncDataFragment) return;
    transmitPacket(deviceId, data);
  }

  /// Transmits a TNC packet through the software modem.
  void transmitPacket(int deviceId, TncDataFragment fragment) {
    if (fragment.data.isEmpty) {
      _debug('TransmitPacket: Invalid fragment');
      return;
    }

    if (_currentMode == SoftwareModemModeType.none) return;

    // Get or create modem state for this radio
    var state = _radioModems[deviceId];
    if (state == null) {
      state = _createRadioModemState(deviceId);
      if (state == null) {
        _debug(
            'TransmitPacket: Could not create modem state for device $deviceId');
        return;
      }
      _radioModems[deviceId] = state;
    }

    try {
      final Uint8List pcmData;

      switch (_currentMode) {
        case SoftwareModemModeType.afsk1200:
          pcmData = afsk1200Encode(fragment.data);
          break;
        case SoftwareModemModeType.psk2400:
        case SoftwareModemModeType.psk4800:
          _debug('PSK modulator not yet implemented');
          return;
        case SoftwareModemModeType.g3ruh9600:
          _debug('G3RUH 9600 modulator not yet implemented');
          return;
        case SoftwareModemModeType.none:
          return;
      }

      if (pcmData.isEmpty) return;

      // Queue the PCM payload — it will be sent once the channel clears
      state.transmitQueue.add(_PendingTransmission(
        pcmData: pcmData,
        deadline: DateTime.now().add(const Duration(seconds: 30)),
      ));
      _debug(
          'Queued packet: ${pcmData.length ~/ 2} samples, ${pcmData.length} bytes PCM on device $deviceId');

      if (state.channelIsClear && !state.waitingForChannel) {
        // Channel is already free — start the random back-off timer
        _startChannelClearTimer(state);
      } else if (!state.channelIsClear) {
        // Channel is busy — wait for the ChannelClear broker event
        state.waitingForChannel = true;
        _debug('Channel busy on device $deviceId, waiting for clear channel');
      }
    } catch (e) {
      _debug('TransmitPacket error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Channel-clear / transmit queue
  // ---------------------------------------------------------------------------

  void _onChannelClear(int deviceId, String name, Object? data) {
    if (_disposed || deviceId <= 0) return;

    final state = _radioModems[deviceId];
    if (state == null) return;
    if (!state.waitingForChannel || state.transmitQueue.isEmpty) return;

    state.channelIsClear = true;
    _startChannelClearTimer(state);
  }

  void _startChannelClearTimer(_RadioModemState state) {
    state.channelWaitTimer?.cancel();

    final delayMs = _rng.nextInt(601) + 200; // 200–800 ms random back-off
    state.waitingForChannel = true;

    final capturedDeviceId = state.deviceId;
    state.channelWaitTimer = Timer(
      Duration(milliseconds: delayMs),
      () => _flushTransmitQueue(capturedDeviceId),
    );
    _debug(
        'Channel clear on device ${state.deviceId}, transmitting in $delayMs ms');
  }

  void _flushTransmitQueue(int deviceId) {
    if (_disposed) return;

    final state = _radioModems[deviceId];
    if (state == null) return;

    state.waitingForChannel = false;

    // Drop any packets that have passed their deadline
    final now = DateTime.now();
    while (state.transmitQueue.isNotEmpty &&
        now.isAfter(state.transmitQueue.first.deadline)) {
      state.transmitQueue.removeAt(0);
      _debug('FlushTransmitQueue: dropped expired packet on device $deviceId');
    }

    if (state.transmitQueue.isEmpty) return;

    // If the channel became busy again since the timer was started, re-queue
    if (!state.channelIsClear) {
      state.waitingForChannel = true;
      _debug(
          'FlushTransmitQueue: channel busy again on device $deviceId, re-waiting');
      return;
    }

    final pcmData = state.transmitQueue.removeAt(0).pcmData;
    final moreQueued = state.transmitQueue.isNotEmpty;

    // If there are further packets, arm the wait state so the next ChannelClear fires them
    if (moreQueued) {
      state.waitingForChannel = true;
    }

    _broker.dispatch(
      deviceId,
      'TransmitVoicePCM',
      AudioDataEvent(
        data: pcmData,
        length: pcmData.length,
        transmit: true,
      ),
      store: false,
    );
    _debug(
        'Transmitted queued packet: ${pcmData.length ~/ 2} samples, ${pcmData.length} bytes PCM on device $deviceId');
  }

  // ---------------------------------------------------------------------------
  // Logging & disposal
  // ---------------------------------------------------------------------------

  void _debug(String msg) {
    _broker.dispatch(1, 'LogInfo', '[SoftwareModem]: $msg', store: false);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final state in _radioModems.values) {
      state.dispose();
    }
    _radioModems.clear();

    _broker.dispose();
  }
}
