/*
FIR Filter, Kaiser window, and Hann window
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;

/// FIR filter utilities.
class Filter {
  static double sinc(double x) {
    if (x == 0) return 1;
    x *= math.pi;
    return math.sin(x) / x;
  }

  static double lowPass(double cutoff, double rate, int n, int bigN) {
    final f = 2 * cutoff / rate;
    final x = n - (bigN - 1) / 2.0;
    return f * sinc(f * x);
  }
}

/// Kaiser window function.
class Kaiser {
  final List<double> _summands = List<double>.filled(35, 0);

  static double _square(double value) => value * value;

  /// Zero-th order modified Bessel function of the first kind.
  double _i0(double x) {
    _summands[0] = 1;
    double val = 1;
    for (int n = 1; n < _summands.length; ++n) {
      val *= x / (2 * n);
      _summands[n] = _square(val);
    }
    _summands.sort();
    double sum = 0;
    for (int n = _summands.length - 1; n >= 0; --n) {
      sum += _summands[n];
    }
    return sum;
  }

  double window(double a, int n, int bigN) {
    return _i0(math.pi * a * math.sqrt(1 - _square((2.0 * n) / (bigN - 1) - 1))) /
        _i0(math.pi * a);
  }
}

/// Hann window function.
class Hann {
  static double window(int n, int bigN) {
    return 0.5 * (1.0 - math.cos((2.0 * math.pi * n) / (bigN - 1)));
  }
}
