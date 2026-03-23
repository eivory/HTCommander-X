/*
SSTV mode definitions: IMode interface, BaseMode, and all concrete modes.
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;
import 'dart:typed_data';
import 'color_converter.dart';
import 'dsp_utils.dart';
import 'pixel_buffer.dart';

/// Interface for all SSTV modes.
abstract class SstvMode {
  String getName();
  int getVisCode();
  int getWidth();
  int getHeight();
  int getFirstPixelSampleIndex();
  int getFirstSyncPulseIndex();
  int getScanLineSamples();
  Int32List postProcessScopeImage(Int32List pixels, int width, int height);
  void resetState();

  /// Decode a scan line.
  /// [frequencyOffset] is the normalized correction of frequency (expected vs actual).
  /// Returns true if the scanline was decoded.
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  );
}

/// Base class for all modes, providing a default [postProcessScopeImage].
abstract class BaseMode implements SstvMode {
  @override
  Int32List postProcessScopeImage(Int32List pixels, int width, int height) {
    return pixels;
  }
}

// ---------------------------------------------------------------------------
// Robot 36 Color
// ---------------------------------------------------------------------------
class Robot36Color extends BaseMode {
  final ExponentialMovingAverage _lowPassFilter = ExponentialMovingAverage();
  final int _horizontalPixels = 320;
  final int _verticalPixels = 240;
  final int _scanLineSamples;
  final int _luminanceSamples;
  final int _separatorSamples;
  final int _chrominanceSamples;
  final int _beginSamples;
  final int _luminanceBeginSamples;
  final int _separatorBeginSamples;
  final int _chrominanceBeginSamples;
  final int _endSamples;
  bool _lastEven = false;

  Robot36Color(int sampleRate)
      : _scanLineSamples = (((0.009 + 0.003 + 0.088 + 0.0045 + 0.0015 + 0.044) * sampleRate).round()),
        _luminanceSamples = (0.088 * sampleRate).round(),
        _separatorSamples = (0.0045 * sampleRate).round(),
        _chrominanceSamples = (0.044 * sampleRate).round(),
        _luminanceBeginSamples = (0.003 * sampleRate).round(),
        _beginSamples = (0.003 * sampleRate).round(),
        _separatorBeginSamples = ((0.003 + 0.088) * sampleRate).round(),
        _chrominanceBeginSamples = ((0.003 + 0.088 + 0.0045 + 0.0015) * sampleRate).round(),
        _endSamples = ((0.003 + 0.088 + 0.0045 + 0.0015 + 0.044) * sampleRate).round();

  static double _freqToLevel(double frequency, double offset) {
    return 0.5 * (frequency - offset + 1.0);
  }

  @override
  String getName() => 'Robot 36 Color';
  @override
  int getVisCode() => 8;
  @override
  int getWidth() => _horizontalPixels;
  @override
  int getHeight() => _verticalPixels;
  @override
  int getFirstPixelSampleIndex() => _beginSamples;
  @override
  int getFirstSyncPulseIndex() => 0;
  @override
  int getScanLineSamples() => _scanLineSamples;

  @override
  void resetState() {
    _lastEven = false;
  }

  @override
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  ) {
    if (syncPulseIndex + _beginSamples < 0 || syncPulseIndex + _endSamples > scanLineBuffer.length) {
      return false;
    }
    double separator = 0;
    for (int i = 0; i < _separatorSamples; ++i) {
      separator += scanLineBuffer[syncPulseIndex + _separatorBeginSamples + i];
    }
    separator /= _separatorSamples;
    separator -= frequencyOffset;
    bool even = separator < 0;
    if (separator < -1.1 || (separator > -0.9 && separator < 0.9) || separator > 1.1) {
      even = !_lastEven;
    }
    _lastEven = even;
    _lowPassFilter.cutoff(_horizontalPixels.toDouble(), (2 * _luminanceSamples).toDouble(), 2);
    _lowPassFilter.reset();
    for (int i = _beginSamples; i < _endSamples; ++i) {
      scratchBuffer[i] = _lowPassFilter.avg(scanLineBuffer[syncPulseIndex + i]);
    }
    _lowPassFilter.reset();
    for (int i = _endSamples - 1; i >= _beginSamples; --i) {
      scratchBuffer[i] = _freqToLevel(_lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    for (int i = 0; i < _horizontalPixels; ++i) {
      final luminancePos = _luminanceBeginSamples + (i * _luminanceSamples) ~/ _horizontalPixels;
      final chrominancePos = _chrominanceBeginSamples + (i * _chrominanceSamples) ~/ _horizontalPixels;
      if (even) {
        pixelBuffer.pixels[i] = ColorConverter.rgb(scratchBuffer[luminancePos], 0, scratchBuffer[chrominancePos]);
      } else {
        final evenYUV = pixelBuffer.pixels[i];
        final oddYUV = ColorConverter.rgb(scratchBuffer[luminancePos], scratchBuffer[chrominancePos], 0);
        pixelBuffer.pixels[i] =
            ColorConverter.yuv2rgbPacked((evenYUV & 0x00ff00ff) | (oddYUV & 0x0000ff00));
        pixelBuffer.pixels[i + _horizontalPixels] =
            ColorConverter.yuv2rgbPacked((oddYUV & 0x00ffff00) | (evenYUV & 0x000000ff));
      }
    }
    pixelBuffer.width = _horizontalPixels;
    pixelBuffer.height = 2;
    return !even;
  }
}

// ---------------------------------------------------------------------------
// Robot 72 Color
// ---------------------------------------------------------------------------
class Robot72Color extends BaseMode {
  final ExponentialMovingAverage _lowPassFilter = ExponentialMovingAverage();
  final int _horizontalPixels = 320;
  final int _verticalPixels = 240;
  final int _scanLineSamples;
  final int _luminanceSamples;
  final int _chrominanceSamples;
  final int _beginSamples;
  final int _yBeginSamples;
  final int _vBeginSamples;
  final int _uBeginSamples;
  final int _endSamples;

  Robot72Color(int sampleRate)
      : _scanLineSamples = ((0.009 + 0.003 + 0.138 + 2 * (0.0045 + 0.0015 + 0.069)) * sampleRate).round(),
        _luminanceSamples = (0.138 * sampleRate).round(),
        _chrominanceSamples = (0.069 * sampleRate).round(),
        _yBeginSamples = (0.003 * sampleRate).round(),
        _beginSamples = (0.003 * sampleRate).round(),
        _vBeginSamples = ((0.003 + 0.138 + 0.0045 + 0.0015) * sampleRate).round(),
        _uBeginSamples = ((0.003 + 0.138 + 2 * (0.0045 + 0.0015) + 0.069) * sampleRate).round(),
        _endSamples = ((0.003 + 0.138 + 2 * (0.0045 + 0.0015 + 0.069)) * sampleRate).round();

  static double _freqToLevel(double frequency, double offset) {
    return 0.5 * (frequency - offset + 1.0);
  }

  @override
  String getName() => 'Robot 72 Color';
  @override
  int getVisCode() => 12;
  @override
  int getWidth() => _horizontalPixels;
  @override
  int getHeight() => _verticalPixels;
  @override
  int getFirstPixelSampleIndex() => _beginSamples;
  @override
  int getFirstSyncPulseIndex() => 0;
  @override
  int getScanLineSamples() => _scanLineSamples;
  @override
  void resetState() {}

  @override
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  ) {
    if (syncPulseIndex + _beginSamples < 0 || syncPulseIndex + _endSamples > scanLineBuffer.length) {
      return false;
    }
    _lowPassFilter.cutoff(_horizontalPixels.toDouble(), (2 * _luminanceSamples).toDouble(), 2);
    _lowPassFilter.reset();
    for (int i = _beginSamples; i < _endSamples; ++i) {
      scratchBuffer[i] = _lowPassFilter.avg(scanLineBuffer[syncPulseIndex + i]);
    }
    _lowPassFilter.reset();
    for (int i = _endSamples - 1; i >= _beginSamples; --i) {
      scratchBuffer[i] = _freqToLevel(_lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    for (int i = 0; i < _horizontalPixels; ++i) {
      final yPos = _yBeginSamples + (i * _luminanceSamples) ~/ _horizontalPixels;
      final uPos = _uBeginSamples + (i * _chrominanceSamples) ~/ _horizontalPixels;
      final vPos = _vBeginSamples + (i * _chrominanceSamples) ~/ _horizontalPixels;
      pixelBuffer.pixels[i] = ColorConverter.yuv2rgb(scratchBuffer[yPos], scratchBuffer[uPos], scratchBuffer[vPos]);
    }
    pixelBuffer.width = _horizontalPixels;
    pixelBuffer.height = 1;
    return true;
  }
}

// ---------------------------------------------------------------------------
// RGB Decoder (used by Martin, Scottie, Wraase SC2-180)
// ---------------------------------------------------------------------------
class RGBDecoder extends BaseMode {
  final ExponentialMovingAverage _lowPassFilter = ExponentialMovingAverage();
  final int _horizontalPixels;
  final int _verticalPixels;
  final int _firstSyncPulseIndex;
  final int _scanLineSamples;
  final int _beginSamples;
  final int _redBeginSamples;
  final int _redSamples;
  final int _greenBeginSamples;
  final int _greenSamples;
  final int _blueBeginSamples;
  final int _blueSamples;
  final int _endSamples;
  final String _name;
  final int _code;

  RGBDecoder(
    this._name,
    this._code,
    this._horizontalPixels,
    this._verticalPixels,
    double firstSyncPulseSeconds,
    double scanLineSeconds,
    double beginSeconds,
    double redBeginSeconds,
    double redEndSeconds,
    double greenBeginSeconds,
    double greenEndSeconds,
    double blueBeginSeconds,
    double blueEndSeconds,
    double endSeconds,
    int sampleRate,
  )   : _firstSyncPulseIndex = (firstSyncPulseSeconds * sampleRate).round(),
        _scanLineSamples = (scanLineSeconds * sampleRate).round(),
        _beginSamples = (beginSeconds * sampleRate).round(),
        _redBeginSamples = (redBeginSeconds * sampleRate).round() - (beginSeconds * sampleRate).round(),
        _redSamples = ((redEndSeconds - redBeginSeconds) * sampleRate).round(),
        _greenBeginSamples = (greenBeginSeconds * sampleRate).round() - (beginSeconds * sampleRate).round(),
        _greenSamples = ((greenEndSeconds - greenBeginSeconds) * sampleRate).round(),
        _blueBeginSamples = (blueBeginSeconds * sampleRate).round() - (beginSeconds * sampleRate).round(),
        _blueSamples = ((blueEndSeconds - blueBeginSeconds) * sampleRate).round(),
        _endSamples = (endSeconds * sampleRate).round();

  static double _freqToLevel(double frequency, double offset) {
    return 0.5 * (frequency - offset + 1.0);
  }

  @override
  String getName() => _name;
  @override
  int getVisCode() => _code;
  @override
  int getWidth() => _horizontalPixels;
  @override
  int getHeight() => _verticalPixels;
  @override
  int getFirstPixelSampleIndex() => _beginSamples;
  @override
  int getFirstSyncPulseIndex() => _firstSyncPulseIndex;
  @override
  int getScanLineSamples() => _scanLineSamples;
  @override
  void resetState() {}

  @override
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  ) {
    if (syncPulseIndex + _beginSamples < 0 || syncPulseIndex + _endSamples > scanLineBuffer.length) {
      return false;
    }
    _lowPassFilter.cutoff(_horizontalPixels.toDouble(), (2 * _greenSamples).toDouble(), 2);
    _lowPassFilter.reset();
    for (int i = 0; i < _endSamples - _beginSamples; ++i) {
      scratchBuffer[i] = _lowPassFilter.avg(scanLineBuffer[syncPulseIndex + _beginSamples + i]);
    }
    _lowPassFilter.reset();
    for (int i = _endSamples - _beginSamples - 1; i >= 0; --i) {
      scratchBuffer[i] = _freqToLevel(_lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    for (int i = 0; i < _horizontalPixels; ++i) {
      final redPos = _redBeginSamples + (i * _redSamples) ~/ _horizontalPixels;
      final greenPos = _greenBeginSamples + (i * _greenSamples) ~/ _horizontalPixels;
      final bluePos = _blueBeginSamples + (i * _blueSamples) ~/ _horizontalPixels;
      pixelBuffer.pixels[i] = ColorConverter.rgb(scratchBuffer[redPos], scratchBuffer[greenPos], scratchBuffer[bluePos]);
    }
    pixelBuffer.width = _horizontalPixels;
    pixelBuffer.height = 1;
    return true;
  }
}

// ---------------------------------------------------------------------------
// RGB mode factory methods (Martin, Scottie, Wraase SC2-180)
// ---------------------------------------------------------------------------
class RGBModes {
  static RGBDecoder martin(String name, int code, double channelSeconds, int sampleRate) {
    const syncPulseSeconds = 0.004862;
    const separatorSeconds = 0.000572;
    final scanLineSeconds = syncPulseSeconds + separatorSeconds + 3 * (channelSeconds + separatorSeconds);
    final greenBeginSeconds = separatorSeconds;
    final greenEndSeconds = greenBeginSeconds + channelSeconds;
    final blueBeginSeconds = greenEndSeconds + separatorSeconds;
    final blueEndSeconds = blueBeginSeconds + channelSeconds;
    final redBeginSeconds = blueEndSeconds + separatorSeconds;
    final redEndSeconds = redBeginSeconds + channelSeconds;
    return RGBDecoder('Martin $name', code, 320, 256, 0, scanLineSeconds, greenBeginSeconds,
        redBeginSeconds, redEndSeconds, greenBeginSeconds, greenEndSeconds,
        blueBeginSeconds, blueEndSeconds, redEndSeconds, sampleRate);
  }

  static RGBDecoder scottie(String name, int code, double channelSeconds, int sampleRate) {
    const syncPulseSeconds = 0.009;
    const separatorSeconds = 0.0015;
    final firstSyncPulseSeconds = syncPulseSeconds + 2 * (separatorSeconds + channelSeconds);
    final scanLineSeconds = syncPulseSeconds + 3 * (channelSeconds + separatorSeconds);
    final blueEndSeconds = -syncPulseSeconds;
    final blueBeginSeconds = blueEndSeconds - channelSeconds;
    final greenEndSeconds = blueBeginSeconds - separatorSeconds;
    final greenBeginSeconds = greenEndSeconds - channelSeconds;
    const redBeginSeconds = separatorSeconds;
    final redEndSeconds = redBeginSeconds + channelSeconds;
    return RGBDecoder('Scottie $name', code, 320, 256, firstSyncPulseSeconds, scanLineSeconds,
        greenBeginSeconds, redBeginSeconds, redEndSeconds, greenBeginSeconds, greenEndSeconds,
        blueBeginSeconds, blueEndSeconds, redEndSeconds, sampleRate);
  }

  static RGBDecoder wraaseSC2180(int sampleRate) {
    const syncPulseSeconds = 0.0055225;
    const syncPorchSeconds = 0.0005;
    const channelSeconds = 0.235;
    final scanLineSeconds = syncPulseSeconds + syncPorchSeconds + 3 * channelSeconds;
    const redBeginSeconds = syncPorchSeconds;
    final redEndSeconds = redBeginSeconds + channelSeconds;
    final greenBeginSeconds = redEndSeconds;
    final greenEndSeconds = greenBeginSeconds + channelSeconds;
    final blueBeginSeconds = greenEndSeconds;
    final blueEndSeconds = blueBeginSeconds + channelSeconds;
    return RGBDecoder('Wraase SC2\u2013180', 55, 320, 256, 0, scanLineSeconds, redBeginSeconds,
        redBeginSeconds, redEndSeconds, greenBeginSeconds, greenEndSeconds,
        blueBeginSeconds, blueEndSeconds, blueEndSeconds, sampleRate);
  }
}

// ---------------------------------------------------------------------------
// PaulDon (PD modes)
// ---------------------------------------------------------------------------
class PaulDon extends BaseMode {
  final ExponentialMovingAverage _lowPassFilter = ExponentialMovingAverage();
  final int _horizontalPixels;
  final int _verticalPixels;
  final int _scanLineSamples;
  final int _channelSamples;
  final int _beginSamples;
  final int _yEvenBeginSamples;
  final int _vAvgBeginSamples;
  final int _uAvgBeginSamples;
  final int _yOddBeginSamples;
  final int _endSamples;
  final String _name;
  final int _code;

  PaulDon(String name, this._code, this._horizontalPixels, this._verticalPixels,
      double channelSeconds, int sampleRate)
      : _name = 'PD $name',
        _scanLineSamples = ((0.02 + 0.00208 + 4 * channelSeconds) * sampleRate).round(),
        _channelSamples = (channelSeconds * sampleRate).round(),
        _yEvenBeginSamples = (0.00208 * sampleRate).round(),
        _beginSamples = (0.00208 * sampleRate).round(),
        _vAvgBeginSamples = ((0.00208 + channelSeconds) * sampleRate).round(),
        _uAvgBeginSamples = ((0.00208 + 2 * channelSeconds) * sampleRate).round(),
        _yOddBeginSamples = ((0.00208 + 3 * channelSeconds) * sampleRate).round(),
        _endSamples = ((0.00208 + 4 * channelSeconds) * sampleRate).round();

  static double _freqToLevel(double frequency, double offset) {
    return 0.5 * (frequency - offset + 1.0);
  }

  @override
  String getName() => _name;
  @override
  int getVisCode() => _code;
  @override
  int getWidth() => _horizontalPixels;
  @override
  int getHeight() => _verticalPixels;
  @override
  int getFirstPixelSampleIndex() => _beginSamples;
  @override
  int getFirstSyncPulseIndex() => 0;
  @override
  int getScanLineSamples() => _scanLineSamples;
  @override
  void resetState() {}

  @override
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  ) {
    if (syncPulseIndex + _beginSamples < 0 || syncPulseIndex + _endSamples > scanLineBuffer.length) {
      return false;
    }
    _lowPassFilter.cutoff(_horizontalPixels.toDouble(), (2 * _channelSamples).toDouble(), 2);
    _lowPassFilter.reset();
    for (int i = _beginSamples; i < _endSamples; ++i) {
      scratchBuffer[i] = _lowPassFilter.avg(scanLineBuffer[syncPulseIndex + i]);
    }
    _lowPassFilter.reset();
    for (int i = _endSamples - 1; i >= _beginSamples; --i) {
      scratchBuffer[i] = _freqToLevel(_lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    for (int i = 0; i < _horizontalPixels; ++i) {
      final position = (i * _channelSamples) ~/ _horizontalPixels;
      final yEvenPos = position + _yEvenBeginSamples;
      final vAvgPos = position + _vAvgBeginSamples;
      final uAvgPos = position + _uAvgBeginSamples;
      final yOddPos = position + _yOddBeginSamples;
      pixelBuffer.pixels[i] =
          ColorConverter.yuv2rgb(scratchBuffer[yEvenPos], scratchBuffer[uAvgPos], scratchBuffer[vAvgPos]);
      pixelBuffer.pixels[i + _horizontalPixels] =
          ColorConverter.yuv2rgb(scratchBuffer[yOddPos], scratchBuffer[uAvgPos], scratchBuffer[vAvgPos]);
    }
    pixelBuffer.width = _horizontalPixels;
    pixelBuffer.height = 2;
    return true;
  }
}

// ---------------------------------------------------------------------------
// HF Fax
// ---------------------------------------------------------------------------
class HFFax extends BaseMode {
  final ExponentialMovingAverage _lowPassFilter = ExponentialMovingAverage();
  final String _name = 'HF Fax';
  final int _sampleRate;
  final List<double> _cumulated;
  int _horizontalShift = 0;

  HFFax(this._sampleRate) : _cumulated = List<double>.filled(640, 0);

  static double _freqToLevel(double frequency, double offset) {
    return 0.5 * (frequency - offset + 1.0);
  }

  @override
  String getName() => _name;
  @override
  int getVisCode() => -1;
  @override
  int getWidth() => 640;
  @override
  int getHeight() => 1200;
  @override
  int getFirstPixelSampleIndex() => 0;
  @override
  int getFirstSyncPulseIndex() => -1;
  @override
  int getScanLineSamples() => _sampleRate ~/ 2;
  @override
  void resetState() {}

  @override
  Int32List postProcessScopeImage(Int32List pixels, int width, int height) {
    final realWidth = 1808;
    final realHorizontalShift = _horizontalShift * realWidth ~/ getWidth();
    final result = Int32List(realWidth * height);

    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < realWidth; ++x) {
        int srcX;
        if (_horizontalShift > 0 && x >= realWidth - realHorizontalShift) {
          srcX = (x - (realWidth - realHorizontalShift)) * _horizontalShift ~/ realHorizontalShift;
        } else {
          final srcWidth = getWidth() - _horizontalShift;
          final dstWidth = realWidth - realHorizontalShift;
          srcX = _horizontalShift + x * srcWidth ~/ dstWidth;
        }
        srcX = math.min(srcX, getWidth() - 1);
        srcX = math.max(srcX, 0);
        result[y * realWidth + x] = pixels[y * width + srcX];
      }
    }

    return result;
  }

  @override
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  ) {
    if (syncPulseIndex < 0 || syncPulseIndex + scanLineSamples > scanLineBuffer.length) {
      return false;
    }
    final horizontalPixels = getWidth();
    _lowPassFilter.cutoff(horizontalPixels.toDouble(), (2 * scanLineSamples).toDouble(), 2);
    _lowPassFilter.reset();
    for (int i = 0; i < scanLineSamples; ++i) {
      scratchBuffer[i] = _lowPassFilter.avg(scanLineBuffer[syncPulseIndex + i]);
    }
    _lowPassFilter.reset();
    for (int i = scanLineSamples - 1; i >= 0; --i) {
      scratchBuffer[i] = _freqToLevel(_lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    for (int i = 0; i < horizontalPixels; ++i) {
      final position = (i * scanLineSamples) ~/ horizontalPixels;
      final color = ColorConverter.gray(scratchBuffer[position]);
      pixelBuffer.pixels[i] = color;

      const decay = 0.99;
      final luminance = ((color >> 16) & 0xFF) / 255.0;
      _cumulated[i] = _cumulated[i] * decay + luminance * (1 - decay);
    }

    int bestIndex = 0;
    double bestValue = 0;
    for (int x = 0; x < getWidth(); ++x) {
      final val = _cumulated[x];
      if (val > bestValue) {
        bestIndex = x;
        bestValue = val;
      }
    }
    _horizontalShift = bestIndex;

    pixelBuffer.width = horizontalPixels;
    pixelBuffer.height = 1;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Raw Decoder
// ---------------------------------------------------------------------------
class RawDecoder extends BaseMode {
  final ExponentialMovingAverage _lowPassFilter = ExponentialMovingAverage();
  final int _smallPictureMaxSamples;
  final int _mediumPictureMaxSamples;
  final String _name;

  RawDecoder(this._name, int sampleRate)
      : _smallPictureMaxSamples = (0.125 * sampleRate).round(),
        _mediumPictureMaxSamples = (0.175 * sampleRate).round();

  static double _freqToLevel(double frequency, double offset) {
    return 0.5 * (frequency - offset + 1.0);
  }

  @override
  String getName() => _name;
  @override
  int getVisCode() => -1;
  @override
  int getWidth() => -1;
  @override
  int getHeight() => -1;
  @override
  int getFirstPixelSampleIndex() => 0;
  @override
  int getFirstSyncPulseIndex() => -1;
  @override
  int getScanLineSamples() => -1;
  @override
  void resetState() {}

  @override
  bool decodeScanLine(
    PixelBuffer pixelBuffer,
    List<double> scratchBuffer,
    List<double> scanLineBuffer,
    int scopeBufferWidth,
    int syncPulseIndex,
    int scanLineSamples,
    double frequencyOffset,
  ) {
    if (syncPulseIndex < 0 || syncPulseIndex + scanLineSamples > scanLineBuffer.length) {
      return false;
    }
    int horizontalPixels = scopeBufferWidth;
    if (scanLineSamples < _smallPictureMaxSamples) horizontalPixels ~/= 2;
    if (scanLineSamples < _mediumPictureMaxSamples) horizontalPixels ~/= 2;
    _lowPassFilter.cutoff(horizontalPixels.toDouble(), (2 * scanLineSamples).toDouble(), 2);
    _lowPassFilter.reset();
    for (int i = 0; i < scanLineSamples; ++i) {
      scratchBuffer[i] = _lowPassFilter.avg(scanLineBuffer[syncPulseIndex + i]);
    }
    _lowPassFilter.reset();
    for (int i = scanLineSamples - 1; i >= 0; --i) {
      scratchBuffer[i] = _freqToLevel(_lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    for (int i = 0; i < horizontalPixels; ++i) {
      final position = (i * scanLineSamples) ~/ horizontalPixels;
      pixelBuffer.pixels[i] = ColorConverter.gray(scratchBuffer[position]);
    }
    pixelBuffer.width = horizontalPixels;
    pixelBuffer.height = 1;
    return true;
  }
}
