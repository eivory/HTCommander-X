/*
Color converter: YCbCr/RGB conversion
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;

class ColorConverter {
  static int _clampInt(int value) {
    return math.min(math.max(value, 0), 255);
  }

  static double _clampFloat(double value) {
    return math.min(math.max(value, 0), 1.0);
  }

  static int _float2Int(double level) {
    final intensity = (255 * level).round();
    return _clampInt(intensity);
  }

  static int _compress(double level) {
    final compressed = math.sqrt(_clampFloat(level));
    return _float2Int(compressed);
  }

  static int _yuv2rgbInt(int y, int u, int v) {
    y -= 16;
    u -= 128;
    v -= 128;
    final r = _clampInt((298 * y + 409 * v + 128) >> 8);
    final g = _clampInt((298 * y - 100 * u - 208 * v + 128) >> 8);
    final b = _clampInt((298 * y + 516 * u + 128) >> 8);
    return 0xff000000 | (r << 16) | (g << 8) | b;
  }

  static int gray(double level) {
    return 0xff000000 | 0x00010101 * _compress(level);
  }

  static int rgb(double red, double green, double blue) {
    return 0xff000000 | (_float2Int(red) << 16) | (_float2Int(green) << 8) | _float2Int(blue);
  }

  static int yuv2rgb(double y, double u, double v) {
    return _yuv2rgbInt(_float2Int(y), _float2Int(u), _float2Int(v));
  }

  static int yuv2rgbPacked(int yuv) {
    return _yuv2rgbInt(
      (yuv & 0x00ff0000) >> 16,
      (yuv & 0x0000ff00) >> 8,
      yuv & 0x000000ff,
    );
  }
}
