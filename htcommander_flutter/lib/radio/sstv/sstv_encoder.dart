/*
SSTV Encoder: pixel array to audio samples.
Supports all modes present in the decoder.
Ported to Dart from C#.
*/

import 'dart:math' as math;
import 'dart:typed_data';

/// Encodes pixel data into SSTV audio samples using frequency modulation.
/// Supports Robot 36, Robot 72, Martin 1/2, Scottie 1/2/DX,
/// Wraase SC2-180, PD 50/90/120/160/180/240/290, and HF Fax modes.
class SstvEncoder {
  final int sampleRate;
  double _phase = 0;

  // SSTV standard frequencies
  static const double syncPulseFrequency = 1200.0;
  static const double syncPorchFrequency = 1500.0;
  static const double blackFrequency = 1500.0;
  static const double whiteFrequency = 2300.0;
  static const double leaderToneFrequency = 1900.0;
  static const double visBitOneFrequency = 1100.0;
  static const double visBitZeroFrequency = 1300.0;

  SstvEncoder(this.sampleRate);

  /// Reset the oscillator phase.
  void reset() {
    _phase = 0;
  }

  /// Generate a tone at the given frequency for the given duration and append samples.
  void _addTone(List<double> samples, double frequency, double durationSeconds) {
    final count = (durationSeconds * sampleRate).round();
    final delta = 2.0 * math.pi * frequency / sampleRate;
    for (int i = 0; i < count; i++) {
      samples.add(math.sin(_phase));
      _phase += delta;
      if (_phase > 2.0 * math.pi) _phase -= 2.0 * math.pi;
    }
  }

  /// Convert a pixel luminance/color level [0..1] to SSTV frequency.
  static double _levelToFrequency(double level) {
    level = level.clamp(0, 1);
    return blackFrequency + level * (whiteFrequency - blackFrequency);
  }

  /// Add a single sample at the given frequency.
  void _addSample(List<double> samples, double frequency) {
    final delta = 2.0 * math.pi * frequency / sampleRate;
    samples.add(math.sin(_phase));
    _phase += delta;
    if (_phase > 2.0 * math.pi) _phase -= 2.0 * math.pi;
  }

  /// Add a scan line of pixels as frequency-modulated samples.
  void _addPixelLine(List<double> samples, List<double> levels, double durationSeconds) {
    final count = (durationSeconds * sampleRate).round();
    for (int i = 0; i < count; i++) {
      int pixelIndex = (i * levels.length) ~/ count;
      pixelIndex = math.min(pixelIndex, levels.length - 1);
      final freq = _levelToFrequency(levels[pixelIndex]);
      _addSample(samples, freq);
    }
  }

  /// Generate the SSTV VIS header (leader tone + break + VIS code + sync).
  void _addVisHeader(List<double> samples, int visCode) {
    // Leader tone (300ms)
    _addTone(samples, leaderToneFrequency, 0.3);
    // Break (10ms at 1200Hz)
    _addTone(samples, syncPulseFrequency, 0.01);
    // Leader tone (300ms)
    _addTone(samples, leaderToneFrequency, 0.3);

    // VIS start bit (30ms at 1200Hz)
    _addTone(samples, syncPulseFrequency, 0.03);

    // Compute even parity for bit 7 over the lower 7 data bits
    int parity = 0;
    for (int i = 0; i < 7; i++) {
      parity ^= (visCode >> i) & 1;
    }
    final visCodeWithParity = (visCode & 0x7F) | (parity << 7);

    // 8 VIS bits (7 data + 1 parity, LSB first), 30ms each
    for (int i = 0; i < 8; i++) {
      final bit = (visCodeWithParity & (1 << i)) != 0;
      _addTone(samples, bit ? visBitOneFrequency : visBitZeroFrequency, 0.03);
    }

    // VIS stop bit (30ms at 1200Hz)
    _addTone(samples, syncPulseFrequency, 0.03);
  }

  /// Extract RGB from a packed ARGB int.
  static ({double r, double g, double b}) _unpackRgb(int argb) {
    return (
      r: ((argb >> 16) & 0xFF) / 255.0,
      g: ((argb >> 8) & 0xFF) / 255.0,
      b: (argb & 0xFF) / 255.0,
    );
  }

  /// Convert RGB [0..1] to YUV [0..1] (BT.601).
  static ({double y, double u, double v}) _rgbToYuv(double r, double g, double b) {
    return (
      y: 0.299 * r + 0.587 * g + 0.114 * b,
      u: -0.169 * r - 0.331 * g + 0.500 * b + 0.5,
      v: 0.500 * r - 0.419 * g - 0.081 * b + 0.5,
    );
  }

  /// Encode a full image using Robot 36 Color mode.
  List<double> encodeRobot36(Int32List pixels, int width, int height) {
    const visCode = 8;
    const syncPulseSec = 0.009;
    const syncPorchSec = 0.003;
    const luminanceSec = 0.088;
    const separatorSec = 0.0045;
    const porchSec = 0.0015;
    const chrominanceSec = 0.044;
    const hPixels = 320;
    const vPixels = 240;

    final samples = <double>[];
    _addVisHeader(samples, visCode);

    for (int line = 0; line < vPixels; line += 2) {
      final yEven = List<double>.filled(hPixels, 0);
      final yOdd = List<double>.filled(hPixels, 0);
      final uAvg = List<double>.filled(hPixels, 0);
      final vAvg = List<double>.filled(hPixels, 0);

      for (int x = 0; x < hPixels; x++) {
        final srcXEven = (x * width) ~/ hPixels;
        final srcYEven = (line * height) ~/ vPixels;
        final srcXOdd = srcXEven;
        var srcYOdd = ((line + 1) * height) ~/ vPixels;
        srcYOdd = math.min(srcYOdd, height - 1);

        final rgbE = _unpackRgb(pixels[srcYEven * width + srcXEven]);
        final yuvE = _rgbToYuv(rgbE.r, rgbE.g, rgbE.b);
        final rgbO = _unpackRgb(pixels[srcYOdd * width + srcXOdd]);
        final yuvO = _rgbToYuv(rgbO.r, rgbO.g, rgbO.b);

        yEven[x] = yuvE.y;
        yOdd[x] = yuvO.y;
        uAvg[x] = (yuvE.u + yuvO.u) / 2;
        vAvg[x] = (yuvE.v + yuvO.v) / 2;
      }

      // Even line
      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, syncPorchSec);
      _addPixelLine(samples, yEven, luminanceSec);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addTone(samples, syncPorchFrequency, porchSec);
      _addPixelLine(samples, vAvg, chrominanceSec);

      // Odd line
      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, syncPorchSec);
      _addPixelLine(samples, yOdd, luminanceSec);
      _addTone(samples, whiteFrequency, separatorSec);
      _addTone(samples, syncPorchFrequency, porchSec);
      _addPixelLine(samples, uAvg, chrominanceSec);
    }

    return samples;
  }

  /// Encode a full image using Robot 72 Color mode.
  List<double> encodeRobot72(Int32List pixels, int width, int height) {
    const visCode = 12;
    const syncPulseSec = 0.009;
    const syncPorchSec = 0.003;
    const luminanceSec = 0.138;
    const separatorSec = 0.0045;
    const porchSec = 0.0015;
    const chrominanceSec = 0.069;
    const hPixels = 320;
    const vPixels = 240;

    final samples = <double>[];
    _addVisHeader(samples, visCode);

    for (int line = 0; line < vPixels; line++) {
      final yLine = List<double>.filled(hPixels, 0);
      final uLine = List<double>.filled(hPixels, 0);
      final vLine = List<double>.filled(hPixels, 0);

      for (int x = 0; x < hPixels; x++) {
        final srcX = (x * width) ~/ hPixels;
        final srcY = (line * height) ~/ vPixels;
        final rgb = _unpackRgb(pixels[srcY * width + srcX]);
        final yuv = _rgbToYuv(rgb.r, rgb.g, rgb.b);
        yLine[x] = yuv.y;
        uLine[x] = yuv.u;
        vLine[x] = yuv.v;
      }

      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, syncPorchSec);
      _addPixelLine(samples, yLine, luminanceSec);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addTone(samples, syncPorchFrequency, porchSec);
      _addPixelLine(samples, vLine, chrominanceSec);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addTone(samples, syncPorchFrequency, porchSec);
      _addPixelLine(samples, uLine, chrominanceSec);
    }

    return samples;
  }

  /// Encode a full image using a Martin mode (Martin 1 or Martin 2).
  List<double> encodeMartin(Int32List pixels, int width, int height, String variant) {
    int visCode;
    double channelSeconds;
    if (variant == '1') {
      visCode = 44;
      channelSeconds = 0.146432;
    } else {
      visCode = 40;
      channelSeconds = 0.073216;
    }

    const syncPulseSec = 0.004862;
    const separatorSec = 0.000572;
    const hPixels = 320;
    const vPixels = 256;

    final samples = <double>[];
    _addVisHeader(samples, visCode);

    for (int line = 0; line < vPixels; line++) {
      final red = List<double>.filled(hPixels, 0);
      final green = List<double>.filled(hPixels, 0);
      final blue = List<double>.filled(hPixels, 0);

      for (int x = 0; x < hPixels; x++) {
        final srcX = (x * width) ~/ hPixels;
        final srcY = (line * height) ~/ vPixels;
        final rgb = _unpackRgb(pixels[srcY * width + srcX]);
        red[x] = rgb.r;
        green[x] = rgb.g;
        blue[x] = rgb.b;
      }

      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addPixelLine(samples, green, channelSeconds);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addPixelLine(samples, blue, channelSeconds);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addPixelLine(samples, red, channelSeconds);
    }

    return samples;
  }

  /// Encode a full image using a Scottie mode (Scottie 1, 2, or DX).
  List<double> encodeScottie(Int32List pixels, int width, int height, String variant) {
    int visCode;
    double channelSeconds;
    if (variant == '1') {
      visCode = 60;
      channelSeconds = 0.138240;
    } else if (variant == '2') {
      visCode = 56;
      channelSeconds = 0.088064;
    } else {
      visCode = 76;
      channelSeconds = 0.3456;
    }

    const syncPulseSec = 0.009;
    const separatorSec = 0.0015;
    const hPixels = 320;
    const vPixels = 256;

    final samples = <double>[];
    _addVisHeader(samples, visCode);

    for (int line = 0; line < vPixels; line++) {
      final red = List<double>.filled(hPixels, 0);
      final green = List<double>.filled(hPixels, 0);
      final blue = List<double>.filled(hPixels, 0);

      for (int x = 0; x < hPixels; x++) {
        final srcX = (x * width) ~/ hPixels;
        final srcY = (line * height) ~/ vPixels;
        final rgb = _unpackRgb(pixels[srcY * width + srcX]);
        red[x] = rgb.r;
        green[x] = rgb.g;
        blue[x] = rgb.b;
      }

      _addTone(samples, syncPorchFrequency, separatorSec);
      _addPixelLine(samples, green, channelSeconds);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addPixelLine(samples, blue, channelSeconds);
      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, separatorSec);
      _addPixelLine(samples, red, channelSeconds);
    }

    return samples;
  }

  /// Encode a full image using Wraase SC2-180 mode.
  List<double> encodeWraaseSC2180(Int32List pixels, int width, int height) {
    const visCode = 55;
    const syncPulseSec = 0.0055225;
    const syncPorchSec = 0.0005;
    const channelSec = 0.235;
    const hPixels = 320;
    const vPixels = 256;

    final samples = <double>[];
    _addVisHeader(samples, visCode);

    for (int line = 0; line < vPixels; line++) {
      final red = List<double>.filled(hPixels, 0);
      final green = List<double>.filled(hPixels, 0);
      final blue = List<double>.filled(hPixels, 0);

      for (int x = 0; x < hPixels; x++) {
        final srcX = (x * width) ~/ hPixels;
        final srcY = (line * height) ~/ vPixels;
        final rgb = _unpackRgb(pixels[srcY * width + srcX]);
        red[x] = rgb.r;
        green[x] = rgb.g;
        blue[x] = rgb.b;
      }

      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, syncPorchSec);
      _addPixelLine(samples, red, channelSec);
      _addPixelLine(samples, green, channelSec);
      _addPixelLine(samples, blue, channelSec);
    }

    return samples;
  }

  /// Encode a full image using a PD (PaulDon) mode.
  /// Valid variants: "50", "90", "120", "160", "180", "240", "290"
  List<double> encodePaulDon(Int32List pixels, int width, int height, String variant) {
    int visCode;
    int hPixels;
    int vPixels;
    double channelSec;

    switch (variant) {
      case '50':
        visCode = 93; hPixels = 320; vPixels = 256; channelSec = 0.09152;
        break;
      case '90':
        visCode = 99; hPixels = 320; vPixels = 256; channelSec = 0.17024;
        break;
      case '120':
        visCode = 95; hPixels = 640; vPixels = 496; channelSec = 0.1216;
        break;
      case '160':
        visCode = 98; hPixels = 512; vPixels = 400; channelSec = 0.195584;
        break;
      case '180':
        visCode = 96; hPixels = 640; vPixels = 496; channelSec = 0.18304;
        break;
      case '240':
        visCode = 97; hPixels = 640; vPixels = 496; channelSec = 0.24448;
        break;
      case '290':
        visCode = 94; hPixels = 800; vPixels = 616; channelSec = 0.2288;
        break;
      default:
        throw ArgumentError('Unknown PD variant: $variant');
    }

    const syncPulseSec = 0.02;
    const syncPorchSec = 0.00208;

    final samples = <double>[];
    _addVisHeader(samples, visCode);

    for (int line = 0; line < vPixels; line += 2) {
      final yEven = List<double>.filled(hPixels, 0);
      final yOdd = List<double>.filled(hPixels, 0);
      final uAvg = List<double>.filled(hPixels, 0);
      final vAvg = List<double>.filled(hPixels, 0);

      for (int x = 0; x < hPixels; x++) {
        final srcXEven = (x * width) ~/ hPixels;
        final srcYEven = (line * height) ~/ vPixels;
        final srcXOdd = srcXEven;
        var srcYOdd = ((line + 1) * height) ~/ vPixels;
        srcYOdd = math.min(srcYOdd, height - 1);

        final rgbE = _unpackRgb(pixels[srcYEven * width + srcXEven]);
        final yuvE = _rgbToYuv(rgbE.r, rgbE.g, rgbE.b);
        final rgbO = _unpackRgb(pixels[srcYOdd * width + srcXOdd]);
        final yuvO = _rgbToYuv(rgbO.r, rgbO.g, rgbO.b);

        yEven[x] = yuvE.y;
        yOdd[x] = yuvO.y;
        uAvg[x] = (yuvE.u + yuvO.u) / 2;
        vAvg[x] = (yuvE.v + yuvO.v) / 2;
      }

      _addTone(samples, syncPulseFrequency, syncPulseSec);
      _addTone(samples, syncPorchFrequency, syncPorchSec);
      _addPixelLine(samples, yEven, channelSec);
      _addPixelLine(samples, vAvg, channelSec);
      _addPixelLine(samples, uAvg, channelSec);
      _addPixelLine(samples, yOdd, channelSec);
    }

    return samples;
  }

  /// Encode a grayscale image using HF Fax mode (IOC 576, 120 LPM).
  List<double> encodeHFFax(Int32List pixels, int width, int height) {
    const hPixels = 640;
    const totalLines = 1200;
    const scanLineSec = 0.5;

    final samples = <double>[];

    for (int line = 0; line < totalLines; line++) {
      final gray = List<double>.filled(hPixels, 0);
      var srcY = (line * height) ~/ totalLines;
      srcY = math.min(srcY, height - 1);

      for (int x = 0; x < hPixels; x++) {
        var srcX = (x * width) ~/ hPixels;
        srcX = math.min(srcX, width - 1);
        final argb = pixels[srcY * width + srcX];
        final r = ((argb >> 16) & 0xFF) / 255.0;
        final g = ((argb >> 8) & 0xFF) / 255.0;
        final b = (argb & 0xFF) / 255.0;
        gray[x] = 0.299 * r + 0.587 * g + 0.114 * b;
      }

      _addPixelLine(samples, gray, scanLineSec);
    }

    return samples;
  }

  /// Convenience method to encode any supported mode by name.
  List<double> encode(Int32List pixels, int width, int height, String modeName) {
    switch (modeName) {
      case 'Robot 36 Color':
        return encodeRobot36(pixels, width, height);
      case 'Robot 72 Color':
        return encodeRobot72(pixels, width, height);
      case 'Martin 1':
        return encodeMartin(pixels, width, height, '1');
      case 'Martin 2':
        return encodeMartin(pixels, width, height, '2');
      case 'Scottie 1':
        return encodeScottie(pixels, width, height, '1');
      case 'Scottie 2':
        return encodeScottie(pixels, width, height, '2');
      case 'Scottie DX':
        return encodeScottie(pixels, width, height, 'DX');
      case 'Wraase SC2\u2013180':
        return encodeWraaseSC2180(pixels, width, height);
      case 'PD 50':
        return encodePaulDon(pixels, width, height, '50');
      case 'PD 90':
        return encodePaulDon(pixels, width, height, '90');
      case 'PD 120':
        return encodePaulDon(pixels, width, height, '120');
      case 'PD 160':
        return encodePaulDon(pixels, width, height, '160');
      case 'PD 180':
        return encodePaulDon(pixels, width, height, '180');
      case 'PD 240':
        return encodePaulDon(pixels, width, height, '240');
      case 'PD 290':
        return encodePaulDon(pixels, width, height, '290');
      case 'HF Fax':
        return encodeHFFax(pixels, width, height);
      default:
        throw ArgumentError('Unknown mode: $modeName');
    }
  }

  /// Get the list of all supported mode names.
  static List<String> getSupportedModes() {
    return [
      'Robot 36 Color',
      'Robot 72 Color',
      'Martin 1',
      'Martin 2',
      'Scottie 1',
      'Scottie 2',
      'Scottie DX',
      'Wraase SC2\u2013180',
      'PD 50',
      'PD 90',
      'PD 120',
      'PD 160',
      'PD 180',
      'PD 240',
      'PD 290',
      'HF Fax',
    ];
  }
}
