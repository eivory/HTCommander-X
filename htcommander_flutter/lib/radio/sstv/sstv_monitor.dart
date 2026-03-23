/*
SSTV Monitor: VIS header detection and mode auto-detect.
Wraps the SSTV Decoder to provide callback-driven notifications.
Ported to Dart from C#.
*/

import 'dart:math' as math;
import 'dart:typed_data';
import 'pixel_buffer.dart';
import 'sstv_decoder.dart';

class SstvDecodingStartedEvent {
  final String modeName;
  final int width;
  final int height;

  SstvDecodingStartedEvent({
    required this.modeName,
    required this.width,
    required this.height,
  });
}

class SstvDecodingProgressEvent {
  final String modeName;
  final int currentLine;
  final int totalLines;

  SstvDecodingProgressEvent({
    required this.modeName,
    required this.currentLine,
    required this.totalLines,
  });

  double get percentComplete => totalLines > 0 ? (currentLine / totalLines) * 100 : 0;
}

class SstvDecodingCompleteEvent {
  final String modeName;
  final int width;
  final int height;

  /// The decoded image as raw ARGB pixel data.
  final Int32List? pixels;

  SstvDecodingCompleteEvent({
    required this.modeName,
    required this.width,
    required this.height,
    this.pixels,
  });
}

/// Cross-platform SSTV monitor.
/// Wraps the SSTV Decoder to provide callback-driven notifications.
class SstvMonitor {
  Decoder? _decoder;
  PixelBuffer? _scopeBuffer;
  PixelBuffer? _imageBuffer;
  final int _sampleRate;
  bool _disposed = false;

  int _previousLine = -1;
  bool _isDecoding = false;
  String? _currentModeName;
  int _lastProgressLine = -1;
  static const int _progressLineInterval = 10;

  void Function(SstvDecodingStartedEvent)? onDecodingStarted;
  void Function(SstvDecodingProgressEvent)? onDecodingProgress;
  void Function(SstvDecodingCompleteEvent)? onDecodingComplete;

  SstvMonitor({int sampleRate = 32000}) : _sampleRate = sampleRate {
    _initialize();
  }

  void _initialize() {
    _scopeBuffer = PixelBuffer(800, 616);
    _imageBuffer = PixelBuffer(800, 616);
    _imageBuffer!.line = -1;
    _decoder = Decoder(_scopeBuffer!, _imageBuffer!, 'Raw', _sampleRate);
    _previousLine = -1;
    _isDecoding = false;
    _currentModeName = null;
    _lastProgressLine = -1;
  }

  void reset() {
    _initialize();
  }

  void processPcm16(Uint8List pcmData, int offset, int length) {
    if (_disposed || length <= 0) return;
    final sampleCount = length ~/ 2;
    final samples = List<double>.filled(sampleCount, 0);
    for (int i = 0; i < sampleCount; i++) {
      final byteIndex = offset + i * 2;
      if (byteIndex + 1 >= offset + length) break;
      final sample = (pcmData[byteIndex] | (pcmData[byteIndex + 1] << 8)).toSigned(16);
      samples[i] = sample / 32768.0;
    }
    processFloatSamples(samples);
  }

  void processFloatSamples(List<double> samples) {
    if (_disposed || samples.isEmpty) return;

    SstvDecodingStartedEvent? startedEvent;
    SstvDecodingProgressEvent? progressEvent;
    SstvDecodingCompleteEvent? completeEvent;

    if (_decoder == null) return;
    final newLines = _decoder!.process(samples, 0);
    final currentLine = _imageBuffer!.line;
    final height = _imageBuffer!.height;

    if (!_isDecoding && currentLine >= 0 && currentLine < height && _decoder!.currentMode != null) {
      _isDecoding = true;
      _currentModeName = _decoder!.currentMode!.getName();
      _lastProgressLine = 0;
      startedEvent = SstvDecodingStartedEvent(
        modeName: _currentModeName!,
        width: _decoder!.currentMode!.getWidth(),
        height: _decoder!.currentMode!.getHeight(),
      );
    }

    if (_isDecoding && newLines && currentLine > _previousLine && currentLine < height) {
      if (currentLine - _lastProgressLine >= _progressLineInterval) {
        _lastProgressLine = currentLine;
        progressEvent = SstvDecodingProgressEvent(
          modeName: _currentModeName!,
          currentLine: currentLine,
          totalLines: height,
        );
      }
    }

    if (_isDecoding && currentLine >= height && _previousLine < height) {
      final extractedPixels = _extractImage();
      final extractedWidth = extractedPixels != null ? _imageBuffer!.width : 0;
      final extractedHeight = extractedPixels != null ? _imageBuffer!.height : 0;
      completeEvent = SstvDecodingCompleteEvent(
        modeName: _currentModeName!,
        width: extractedWidth,
        height: extractedHeight,
        pixels: extractedPixels,
      );
      _isDecoding = false;
      _currentModeName = null;
      _previousLine = -1;
      _lastProgressLine = -1;
      _initialize();
    } else {
      _previousLine = currentLine;
    }

    if (startedEvent != null) onDecodingStarted?.call(startedEvent);
    if (progressEvent != null) onDecodingProgress?.call(progressEvent);
    if (completeEvent != null) onDecodingComplete?.call(completeEvent);
  }

  Int32List? _extractImage() {
    try {
      final width = _imageBuffer!.width;
      final height = _imageBuffer!.height;
      final pixels = _imageBuffer!.pixels;

      if (width <= 0 || height <= 0 || pixels.length < width * height) return null;

      var finalPixels = pixels;

      if (_decoder!.currentMode != null) {
        finalPixels = _decoder!.currentMode!.postProcessScopeImage(pixels, width, height);
      }

      // Return a copy of the pixel data
      return Int32List.fromList(finalPixels);
    } catch (_) {
      return null;
    }
  }

  /// Returns partial image pixels (ARGB) if decoding is in progress.
  Int32List? getPartialImage() {
    if (_imageBuffer == null || _imageBuffer!.line <= 0) return null;
    try {
      final width = _imageBuffer!.width;
      final fullHeight = _imageBuffer!.height;
      final decodedLines = math.min(_imageBuffer!.line, fullHeight);
      final pixels = _imageBuffer!.pixels;

      if (width <= 0 || fullHeight <= 0 || pixels.length < width * decodedLines) return null;

      final totalPixels = width * fullHeight;
      final fullPixels = Int32List(totalPixels);
      fullPixels.fillRange(0, totalPixels, 0xFF000000);
      fullPixels.setRange(0, width * decodedLines, pixels);

      return fullPixels;
    } catch (_) {
      return null;
    }
  }

  /// Returns the width of the partial/complete image, or 0 if not decoding.
  int get imageWidth => _imageBuffer?.width ?? 0;

  /// Returns the height of the partial/complete image, or 0 if not decoding.
  int get imageHeight => _imageBuffer?.height ?? 0;

  void dispose() {
    _disposed = true;
    _decoder = null;
    _scopeBuffer = null;
    _imageBuffer = null;
  }
}
