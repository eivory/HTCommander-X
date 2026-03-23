/*
SSTV Decoder
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;
import 'dart:typed_data';
import 'demodulator.dart';
import 'dsp_utils.dart';
import 'pixel_buffer.dart';
import 'sstv_mode.dart';

class Decoder {
  final SimpleMovingAverage _pulseFilter;
  final Demodulator _demodulator;
  final PixelBuffer _pixelBuffer;
  final PixelBuffer _scopeBuffer;
  final PixelBuffer _imageBuffer;
  final List<double> _scanLineBuffer;
  final List<double> _scratchBuffer;
  final List<int> _last5msSyncPulses;
  final List<int> _last9msSyncPulses;
  final List<int> _last20msSyncPulses;
  final List<int> _last5msScanLines;
  final List<int> _last9msScanLines;
  final List<int> _last20msScanLines;
  final List<double> _last5msFrequencyOffsets;
  final List<double> _last9msFrequencyOffsets;
  final List<double> _last20msFrequencyOffsets;
  final List<double> _visCodeBitFrequencies;
  final int _pulseFilterDelay;
  final int _scanLineMinSamples;
  final int _syncPulseToleranceSamples;
  final int _scanLineToleranceSamples;
  final int _leaderToneSamples;
  final int _leaderToneToleranceSamples;
  final int _transitionSamples;
  final int _visCodeBitSamples;
  final int _visCodeSamples;
  final SstvMode _rawMode;
  final SstvMode _hfFaxMode;
  final List<SstvMode> _syncPulse5msModes;
  final List<SstvMode> _syncPulse9msModes;
  final List<SstvMode> _syncPulse20msModes;

  SstvMode? currentMode;
  bool _lockMode = false;
  int _currentSample = 0;
  int _leaderBreakIndex = 0;
  int _lastSyncPulseIndex = 0;
  int _currentScanLineSamples = 0;
  double _lastFrequencyOffset = 0;

  Decoder(this._scopeBuffer, this._imageBuffer, String rawName, int sampleRate)
      : _pixelBuffer = PixelBuffer(800, 2),
        _demodulator = Demodulator(sampleRate),
        _pulseFilterDelay = (((0.0025 * sampleRate).round() | 1) - 1) ~/ 2,
        _pulseFilter = SimpleMovingAverage((0.0025 * sampleRate).round() | 1),
        _scanLineBuffer = List<double>.filled((7 * sampleRate).round(), 0),
        _scratchBuffer = List<double>.filled((1.1 * sampleRate).round(), 0),
        _leaderToneSamples = (0.3 * sampleRate).round(),
        _leaderToneToleranceSamples = (0.3 * 0.2 * sampleRate).round(),
        _transitionSamples = (0.0005 * sampleRate).round(),
        _visCodeBitSamples = (0.03 * sampleRate).round(),
        _visCodeSamples = (0.3 * sampleRate).round(),
        _visCodeBitFrequencies = List<double>.filled(10, 0),
        _last5msScanLines = List<int>.filled(4, 0),
        _last9msScanLines = List<int>.filled(4, 0),
        _last20msScanLines = List<int>.filled(4, 0),
        _last5msSyncPulses = List<int>.filled(5, 0),
        _last9msSyncPulses = List<int>.filled(5, 0),
        _last20msSyncPulses = List<int>.filled(5, 0),
        _last5msFrequencyOffsets = List<double>.filled(5, 0),
        _last9msFrequencyOffsets = List<double>.filled(5, 0),
        _last20msFrequencyOffsets = List<double>.filled(5, 0),
        _scanLineMinSamples = (0.05 * sampleRate).round(),
        _syncPulseToleranceSamples = (0.03 * sampleRate).round(),
        _scanLineToleranceSamples = (0.001 * sampleRate).round(),
        _rawMode = RawDecoder(rawName, sampleRate),
        _hfFaxMode = HFFax(sampleRate),
        _syncPulse5msModes = <SstvMode>[],
        _syncPulse9msModes = <SstvMode>[],
        _syncPulse20msModes = <SstvMode>[] {
    _imageBuffer.line = -1;
    final robot36 = Robot36Color(sampleRate);
    currentMode = robot36;
    _currentScanLineSamples = robot36.getScanLineSamples();
    _syncPulse5msModes.add(RGBModes.wraaseSC2180(sampleRate));
    _syncPulse5msModes.add(RGBModes.martin('1', 44, 0.146432, sampleRate));
    _syncPulse5msModes.add(RGBModes.martin('2', 40, 0.073216, sampleRate));
    _syncPulse9msModes.add(robot36);
    _syncPulse9msModes.add(Robot72Color(sampleRate));
    _syncPulse9msModes.add(RGBModes.scottie('1', 60, 0.138240, sampleRate));
    _syncPulse9msModes.add(RGBModes.scottie('2', 56, 0.088064, sampleRate));
    _syncPulse9msModes.add(RGBModes.scottie('DX', 76, 0.3456, sampleRate));
    _syncPulse20msModes.add(PaulDon('50', 93, 320, 256, 0.09152, sampleRate));
    _syncPulse20msModes.add(PaulDon('90', 99, 320, 256, 0.17024, sampleRate));
    _syncPulse20msModes.add(PaulDon('120', 95, 640, 496, 0.1216, sampleRate));
    _syncPulse20msModes.add(PaulDon('160', 98, 512, 400, 0.195584, sampleRate));
    _syncPulse20msModes.add(PaulDon('180', 96, 640, 496, 0.18304, sampleRate));
    _syncPulse20msModes.add(PaulDon('240', 97, 640, 496, 0.24448, sampleRate));
    _syncPulse20msModes.add(PaulDon('290', 94, 800, 616, 0.2288, sampleRate));
  }

  static double _scanLineMean(List<int> lines) {
    double mean = 0;
    for (final diff in lines) {
      mean += diff;
    }
    mean /= lines.length;
    return mean;
  }

  static double _scanLineStdDev(List<int> lines, double mean) {
    double stdDev = 0;
    for (final diff in lines) {
      stdDev += (diff - mean) * (diff - mean);
    }
    stdDev = math.sqrt(stdDev / lines.length);
    return stdDev;
  }

  static double _frequencyOffsetMean(List<double> offsets) {
    double mean = 0;
    for (final diff in offsets) {
      mean += diff;
    }
    mean /= offsets.length;
    return mean;
  }

  SstvMode _detectMode(List<SstvMode> modes, int line) {
    SstvMode bestMode = _rawMode;
    int bestDist = 0x7fffffff; // int.MaxValue equivalent
    for (final mode in modes) {
      final dist = (line - mode.getScanLineSamples()).abs();
      if (dist <= _scanLineToleranceSamples && dist < bestDist) {
        bestDist = dist;
        bestMode = mode;
      }
    }
    return bestMode;
  }

  static SstvMode? _findModeByCode(List<SstvMode> modes, int code) {
    for (final mode in modes) {
      if (mode.getVisCode() == code) return mode;
    }
    return null;
  }

  static SstvMode? _findModeByName(List<SstvMode> modes, String name) {
    for (final mode in modes) {
      if (mode.getName() == name) return mode;
    }
    return null;
  }

  void _copyUnscaled() {
    final width = math.min(_scopeBuffer.width, _pixelBuffer.width);
    for (int row = 0; row < _pixelBuffer.height; ++row) {
      final line = _scopeBuffer.width * _scopeBuffer.line;
      _scopeBuffer.pixels.setRange(line, line + width, _pixelBuffer.pixels, row * _pixelBuffer.width);
      _scopeBuffer.pixels.fillRange(line + width, line + _scopeBuffer.width, 0);
      _scopeBuffer.pixels.setRange(
          _scopeBuffer.width * (_scopeBuffer.line + _scopeBuffer.height ~/ 2),
          _scopeBuffer.width * (_scopeBuffer.line + _scopeBuffer.height ~/ 2) + _scopeBuffer.width,
          _scopeBuffer.pixels,
          line);
      _scopeBuffer.line = (_scopeBuffer.line + 1) % (_scopeBuffer.height ~/ 2);
    }
  }

  void _copyScaled(int scale) {
    for (int row = 0; row < _pixelBuffer.height; ++row) {
      final line = _scopeBuffer.width * _scopeBuffer.line;
      for (int col = 0; col < _pixelBuffer.width; ++col) {
        for (int i = 0; i < scale; ++i) {
          _scopeBuffer.pixels[line + col * scale + i] = _pixelBuffer.pixels[_pixelBuffer.width * row + col];
        }
      }
      _scopeBuffer.pixels.fillRange(
          line + _pixelBuffer.width * scale, line + _scopeBuffer.width, 0);
      _scopeBuffer.pixels.setRange(
          _scopeBuffer.width * (_scopeBuffer.line + _scopeBuffer.height ~/ 2),
          _scopeBuffer.width * (_scopeBuffer.line + _scopeBuffer.height ~/ 2) + _scopeBuffer.width,
          _scopeBuffer.pixels,
          line);
      _scopeBuffer.line = (_scopeBuffer.line + 1) % (_scopeBuffer.height ~/ 2);
      for (int i = 1; i < scale; ++i) {
        _scopeBuffer.pixels.setRange(
            _scopeBuffer.width * _scopeBuffer.line,
            _scopeBuffer.width * _scopeBuffer.line + _scopeBuffer.width,
            _scopeBuffer.pixels,
            line);
        _scopeBuffer.pixels.setRange(
            _scopeBuffer.width * (_scopeBuffer.line + _scopeBuffer.height ~/ 2),
            _scopeBuffer.width * (_scopeBuffer.line + _scopeBuffer.height ~/ 2) + _scopeBuffer.width,
            _scopeBuffer.pixels,
            line);
        _scopeBuffer.line = (_scopeBuffer.line + 1) % (_scopeBuffer.height ~/ 2);
      }
    }
  }

  void _copyLines(bool okay) {
    if (!okay) return;
    bool finish = false;
    if (_imageBuffer.line >= 0 &&
        _imageBuffer.line < _imageBuffer.height &&
        _imageBuffer.width == _pixelBuffer.width) {
      final width = _imageBuffer.width;
      for (int row = 0; row < _pixelBuffer.height && _imageBuffer.line < _imageBuffer.height; ++row, ++_imageBuffer.line) {
        _imageBuffer.pixels.setRange(
            _imageBuffer.line * width,
            _imageBuffer.line * width + width,
            _pixelBuffer.pixels,
            row * width);
      }
      finish = _imageBuffer.line == _imageBuffer.height;
    }
    final scale = _scopeBuffer.width ~/ _pixelBuffer.width;
    if (scale <= 1) {
      _copyUnscaled();
    } else {
      _copyScaled(scale);
    }
    if (finish) _drawLines(0xff000000, 10);
  }

  void _drawLines(int color, int count) {
    for (int i = 0; i < count; ++i) {
      _scopeBuffer.pixels.fillRange(
          _scopeBuffer.line * _scopeBuffer.width,
          _scopeBuffer.line * _scopeBuffer.width + _scopeBuffer.width,
          color);
      _scopeBuffer.pixels.fillRange(
          (_scopeBuffer.line + _scopeBuffer.height ~/ 2) * _scopeBuffer.width,
          (_scopeBuffer.line + _scopeBuffer.height ~/ 2) * _scopeBuffer.width + _scopeBuffer.width,
          color);
      _scopeBuffer.line = (_scopeBuffer.line + 1) % (_scopeBuffer.height ~/ 2);
    }
  }

  static void _adjustSyncPulses(List<int> pulses, int shift) {
    for (int i = 0; i < pulses.length; ++i) {
      pulses[i] -= shift;
    }
  }

  void _shiftSamples(int shift) {
    if (shift <= 0 || shift > _currentSample) return;
    _currentSample -= shift;
    _leaderBreakIndex -= shift;
    _lastSyncPulseIndex -= shift;
    _adjustSyncPulses(_last5msSyncPulses, shift);
    _adjustSyncPulses(_last9msSyncPulses, shift);
    _adjustSyncPulses(_last20msSyncPulses, shift);
    _scanLineBuffer.setRange(0, _currentSample, _scanLineBuffer, shift);
  }

  bool _handleHeader() {
    if (_leaderBreakIndex < _visCodeBitSamples + _leaderToneToleranceSamples ||
        _currentSample <
            _leaderBreakIndex + _leaderToneSamples + _leaderToneToleranceSamples + _visCodeSamples + _visCodeBitSamples) {
      return false;
    }
    final breakPulseIndex = _leaderBreakIndex;
    _leaderBreakIndex = 0;
    double preBreakFreq = 0;
    for (int i = 0; i < _leaderToneToleranceSamples; ++i) {
      preBreakFreq += _scanLineBuffer[breakPulseIndex - _visCodeBitSamples - _leaderToneToleranceSamples + i];
    }
    const leaderToneFrequency = 1900.0;
    const centerFrequency = 1900.0;
    const toleranceFrequency = 50.0;
    const halfBandWidth = 400.0;
    preBreakFreq = preBreakFreq * halfBandWidth / _leaderToneToleranceSamples + centerFrequency;
    if ((preBreakFreq - leaderToneFrequency).abs() > toleranceFrequency) return false;
    double leaderFreq = 0;
    for (int i = _transitionSamples; i < _leaderToneSamples - _leaderToneToleranceSamples; ++i) {
      leaderFreq += _scanLineBuffer[breakPulseIndex + i];
    }
    final leaderFreqOffset = leaderFreq / (_leaderToneSamples - _transitionSamples - _leaderToneToleranceSamples);
    leaderFreq = leaderFreqOffset * halfBandWidth + centerFrequency;
    if ((leaderFreq - leaderToneFrequency).abs() > toleranceFrequency) return false;
    const stopBitFrequency = 1200.0;
    const syncPulseFrequency = 1200.0;
    final pulseThresholdFrequency = (stopBitFrequency + leaderToneFrequency) / 2;
    final pulseThresholdValue = (pulseThresholdFrequency - centerFrequency) / halfBandWidth;
    var visBeginIndex = breakPulseIndex + _leaderToneSamples - _leaderToneToleranceSamples;
    var visEndIndex = breakPulseIndex + _leaderToneSamples + _leaderToneToleranceSamples + _visCodeBitSamples;
    for (int i = 0; i < _pulseFilter.length; ++i) {
      _pulseFilter.avg(_scanLineBuffer[visBeginIndex++] - leaderFreqOffset);
    }
    while (++visBeginIndex < visEndIndex) {
      if (_pulseFilter.avg(_scanLineBuffer[visBeginIndex] - leaderFreqOffset) < pulseThresholdValue) {
        break;
      }
    }
    if (visBeginIndex >= visEndIndex) return false;
    visBeginIndex -= _pulseFilterDelay;
    visEndIndex = visBeginIndex + _visCodeSamples;
    _visCodeBitFrequencies.fillRange(0, _visCodeBitFrequencies.length, 0);
    for (int j = 0; j < 10; ++j) {
      for (int i = _transitionSamples; i < _visCodeBitSamples - _transitionSamples; ++i) {
        _visCodeBitFrequencies[j] += _scanLineBuffer[visBeginIndex + _visCodeBitSamples * j + i] - leaderFreqOffset;
      }
    }
    for (int i = 0; i < 10; ++i) {
      _visCodeBitFrequencies[i] =
          _visCodeBitFrequencies[i] * halfBandWidth / (_visCodeBitSamples - 2 * _transitionSamples) + centerFrequency;
    }
    if ((_visCodeBitFrequencies[0] - stopBitFrequency).abs() > toleranceFrequency ||
        (_visCodeBitFrequencies[9] - stopBitFrequency).abs() > toleranceFrequency) {
      return false;
    }
    const oneBitFrequency = 1100.0;
    const zeroBitFrequency = 1300.0;
    for (int i = 1; i < 9; ++i) {
      if ((_visCodeBitFrequencies[i] - oneBitFrequency).abs() > toleranceFrequency &&
          (_visCodeBitFrequencies[i] - zeroBitFrequency).abs() > toleranceFrequency) {
        return false;
      }
    }
    int visCode = 0;
    for (int i = 0; i < 8; ++i) {
      visCode |= (_visCodeBitFrequencies[i + 1] < stopBitFrequency ? 1 : 0) << i;
    }
    bool check = true;
    for (int i = 0; i < 8; ++i) {
      check ^= (visCode & (1 << i)) != 0;
    }
    visCode &= 127;
    if (!check) return false;
    const syncPorchFrequency = 1500.0;
    final syncThresholdFrequency = (syncPulseFrequency + syncPorchFrequency) / 2;
    final syncThresholdValue = (syncThresholdFrequency - centerFrequency) / halfBandWidth;
    var syncPulseIndex = visEndIndex - _visCodeBitSamples;
    final syncPulseMaxIndex = visEndIndex + _visCodeBitSamples;
    for (int i = 0; i < _pulseFilter.length; ++i) {
      _pulseFilter.avg(_scanLineBuffer[syncPulseIndex++] - leaderFreqOffset);
    }
    while (++syncPulseIndex < syncPulseMaxIndex) {
      if (_pulseFilter.avg(_scanLineBuffer[syncPulseIndex] - leaderFreqOffset) > syncThresholdValue) {
        break;
      }
    }
    if (syncPulseIndex >= syncPulseMaxIndex) return false;
    syncPulseIndex -= _pulseFilterDelay;
    SstvMode? mode;
    List<int> pulses;
    List<int> lines;
    if ((mode = _findModeByCode(_syncPulse5msModes, visCode)) != null) {
      pulses = _last5msSyncPulses;
      lines = _last5msScanLines;
    } else if ((mode = _findModeByCode(_syncPulse9msModes, visCode)) != null) {
      pulses = _last9msSyncPulses;
      lines = _last9msScanLines;
    } else if ((mode = _findModeByCode(_syncPulse20msModes, visCode)) != null) {
      pulses = _last20msSyncPulses;
      lines = _last20msScanLines;
    } else {
      if (!_lockMode) _drawLines(0xffff0000, 8);
      return false;
    }
    if (_lockMode && mode != currentMode) return false;
    mode!.resetState();
    _imageBuffer.width = mode.getWidth();
    _imageBuffer.height = mode.getHeight();
    _imageBuffer.line = 0;
    currentMode = mode;
    _lastSyncPulseIndex = syncPulseIndex + mode.getFirstSyncPulseIndex();
    _currentScanLineSamples = mode.getScanLineSamples();
    _lastFrequencyOffset = leaderFreqOffset;
    var oldestSyncPulseIndex = _lastSyncPulseIndex - (pulses.length - 1) * _currentScanLineSamples;
    if (mode.getFirstSyncPulseIndex() > 0) {
      oldestSyncPulseIndex -= _currentScanLineSamples;
    }
    for (int i = 0; i < pulses.length; ++i) {
      pulses[i] = oldestSyncPulseIndex + i * _currentScanLineSamples;
    }
    lines.fillRange(0, lines.length, _currentScanLineSamples);
    _shiftSamples(_lastSyncPulseIndex + mode.getFirstPixelSampleIndex());
    _drawLines(0xff00ff00, 8);
    _drawLines(0xff000000, 10);
    return true;
  }

  bool _processSyncPulse(
      List<SstvMode> modes, List<double> freqOffs, List<int> syncIndexes, List<int> lineLengths, int latestSyncIndex) {
    for (int i = 1; i < syncIndexes.length; ++i) {
      syncIndexes[i - 1] = syncIndexes[i];
    }
    syncIndexes[syncIndexes.length - 1] = latestSyncIndex;
    for (int i = 1; i < lineLengths.length; ++i) {
      lineLengths[i - 1] = lineLengths[i];
    }
    lineLengths[lineLengths.length - 1] = syncIndexes[syncIndexes.length - 1] - syncIndexes[syncIndexes.length - 2];
    for (int i = 1; i < freqOffs.length; ++i) {
      freqOffs[i - 1] = freqOffs[i];
    }
    freqOffs[syncIndexes.length - 1] = _demodulator.frequencyOffset;
    if (lineLengths[0] == 0) return false;
    final mean = _scanLineMean(lineLengths);
    final scanLineSamples = mean.round();
    if (scanLineSamples < _scanLineMinSamples || scanLineSamples > _scratchBuffer.length) return false;
    if (_scanLineStdDev(lineLengths, mean) > _scanLineToleranceSamples) return false;
    bool pictureChanged = false;
    if (_lockMode || (_imageBuffer.line >= 0 && _imageBuffer.line < _imageBuffer.height)) {
      if (currentMode != _rawMode &&
          (scanLineSamples - currentMode!.getScanLineSamples()).abs() > _scanLineToleranceSamples) {
        return false;
      }
    } else {
      final prevMode = currentMode;
      currentMode = _detectMode(modes, scanLineSamples);
      pictureChanged = currentMode != prevMode ||
          (_currentScanLineSamples - scanLineSamples).abs() > _scanLineToleranceSamples ||
          (_lastSyncPulseIndex + scanLineSamples - syncIndexes[syncIndexes.length - 1]).abs() >
              _syncPulseToleranceSamples;
    }
    if (pictureChanged) {
      _drawLines(0xff000000, 10);
      _drawLines(0xff00ffff, 8);
      _drawLines(0xff000000, 10);
    }
    final frequencyOffset = _frequencyOffsetMean(freqOffs);
    if (syncIndexes[0] >= scanLineSamples && pictureChanged) {
      final endPulse = syncIndexes[0];
      final extrapolate = endPulse ~/ scanLineSamples;
      final firstPulse = endPulse - extrapolate * scanLineSamples;
      for (int pulseIndex = firstPulse; pulseIndex < endPulse; pulseIndex += scanLineSamples) {
        _copyLines(currentMode!.decodeScanLine(
            _pixelBuffer, _scratchBuffer, _scanLineBuffer, _scopeBuffer.width, pulseIndex, scanLineSamples, frequencyOffset));
      }
    }
    for (int i = pictureChanged ? 0 : lineLengths.length - 1; i < lineLengths.length; ++i) {
      _copyLines(currentMode!.decodeScanLine(
          _pixelBuffer, _scratchBuffer, _scanLineBuffer, _scopeBuffer.width, syncIndexes[i], lineLengths[i], frequencyOffset));
    }
    _lastSyncPulseIndex = syncIndexes[syncIndexes.length - 1];
    _currentScanLineSamples = scanLineSamples;
    _lastFrequencyOffset = frequencyOffset;
    _shiftSamples(_lastSyncPulseIndex + currentMode!.getFirstPixelSampleIndex());
    return true;
  }

  bool process(List<double> recordBuffer, int channelSelect) {
    bool newLinesPresent = false;
    final syncPulseDetected = _demodulator.process(recordBuffer, channelSelect);
    var syncPulseIndex = _currentSample + _demodulator.syncPulseOffset;
    final channels = channelSelect > 0 ? 2 : 1;
    for (int j = 0; j < recordBuffer.length ~/ channels; ++j) {
      _scanLineBuffer[_currentSample++] = recordBuffer[j];
      if (_currentSample >= _scanLineBuffer.length) {
        _shiftSamples(_currentScanLineSamples);
        syncPulseIndex -= _currentScanLineSamples;
      }
    }
    if (syncPulseDetected) {
      switch (_demodulator.syncPulseWidthValue) {
        case SyncPulseWidth.fiveMilliSeconds:
          newLinesPresent = _processSyncPulse(
              _syncPulse5msModes, _last5msFrequencyOffsets, _last5msSyncPulses, _last5msScanLines, syncPulseIndex);
          break;
        case SyncPulseWidth.nineMilliSeconds:
          _leaderBreakIndex = syncPulseIndex;
          newLinesPresent = _processSyncPulse(
              _syncPulse9msModes, _last9msFrequencyOffsets, _last9msSyncPulses, _last9msScanLines, syncPulseIndex);
          break;
        case SyncPulseWidth.twentyMilliSeconds:
          _leaderBreakIndex = syncPulseIndex;
          newLinesPresent = _processSyncPulse(
              _syncPulse20msModes, _last20msFrequencyOffsets, _last20msSyncPulses, _last20msScanLines, syncPulseIndex);
          break;
      }
    } else if (_handleHeader()) {
      newLinesPresent = true;
    } else if (_currentSample > _lastSyncPulseIndex + (_currentScanLineSamples * 5) ~/ 4) {
      _copyLines(currentMode!.decodeScanLine(
          _pixelBuffer, _scratchBuffer, _scanLineBuffer, _scopeBuffer.width,
          _lastSyncPulseIndex, _currentScanLineSamples, _lastFrequencyOffset));
      _lastSyncPulseIndex += _currentScanLineSamples;
      newLinesPresent = true;
    }

    return newLinesPresent;
  }

  void setMode(String name) {
    if (_rawMode.getName() == name) {
      _lockMode = true;
      _imageBuffer.line = -1;
      currentMode = _rawMode;
      return;
    }
    SstvMode? mode = _findModeByName(_syncPulse5msModes, name);
    mode ??= _findModeByName(_syncPulse9msModes, name);
    mode ??= _findModeByName(_syncPulse20msModes, name);
    if (mode == null && _hfFaxMode.getName() == name) {
      mode = _hfFaxMode;
    }
    if (mode == currentMode) {
      _lockMode = true;
      return;
    }
    if (mode != null) {
      _lockMode = true;
      _imageBuffer.width = mode.getWidth();
      _imageBuffer.height = mode.getHeight();
      final required = _imageBuffer.width * _imageBuffer.height;
      if (_imageBuffer.pixels.length < required) {
        _imageBuffer.pixels = Int32List(required);
      }
      currentMode = mode;
      _currentScanLineSamples = mode.getScanLineSamples();
      if (mode.getVisCode() < 0) {
        _imageBuffer.line = 0;
      } else {
        _imageBuffer.line = -1;
      }
      return;
    }
    _lockMode = false;
  }
}
