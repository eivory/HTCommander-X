/*
DSP utility classes: Delay, ExponentialMovingAverage, SimpleMovingSum,
SimpleMovingAverage, Phasor, SchmittTrigger, FrequencyModulation,
ComplexConvolution.
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;
import 'complex.dart';

/// Digital delay line.
class Delay {
  final int length;
  final List<double> _buf;
  int _pos = 0;

  Delay(this.length) : _buf = List<double>.filled(length, 0);

  double push(double input) {
    final tmp = _buf[_pos];
    _buf[_pos] = input;
    if (++_pos >= length) _pos = 0;
    return tmp;
  }
}

/// Exponential Moving Average filter.
class ExponentialMovingAverage {
  double _alpha = 1;
  double _prev = 0;

  double avg(double input) {
    return _prev = _prev * (1 - _alpha) + _alpha * input;
  }

  void setAlpha(double alpha) {
    _alpha = alpha;
  }

  void setAlphaWithOrder(double alpha, int order) {
    setAlpha(math.pow(alpha, 1.0 / order).toDouble());
  }

  void cutoff(double freq, double rate, [int order = 1]) {
    final x = math.cos(2 * math.pi * freq / rate);
    setAlphaWithOrder(x - 1 + math.sqrt(x * (x - 4) + 3), order);
  }

  void reset() {
    _prev = 0;
  }
}

/// Simple Moving Sum using a tree structure.
class SimpleMovingSum {
  final List<double> _tree;
  int _leaf;
  final int length;

  SimpleMovingSum(this.length)
      : _tree = List<double>.filled(2 * length, 0),
        _leaf = length;

  void add(double input) {
    _tree[_leaf] = input;
    for (int child = _leaf, parent = _leaf ~/ 2; parent > 0; child = parent, parent ~/= 2) {
      _tree[parent] = _tree[child] + _tree[child ^ 1];
    }
    if (++_leaf >= _tree.length) _leaf = length;
  }

  double sum() => _tree[1];

  double sumWith(double input) {
    add(input);
    return sum();
  }
}

/// Simple Moving Average filter.
class SimpleMovingAverage extends SimpleMovingSum {
  SimpleMovingAverage(super.length);

  double avg(double input) {
    return sumWith(input) / length;
  }
}

/// Numerically controlled oscillator.
class Phasor {
  final Complex _value;
  final Complex _delta;

  Phasor(double freq, double rate)
      : _value = Complex(1, 0),
        _delta = Complex(
          math.cos(2 * math.pi * freq / rate),
          math.sin(2 * math.pi * freq / rate),
        );

  Complex rotate() {
    return _value.divScalar(_value.mul(_delta).abs());
  }
}

/// Schmitt trigger with hysteresis.
class SchmittTrigger {
  final double _low;
  final double _high;
  bool _previous = false;

  SchmittTrigger(this._low, this._high);

  bool latch(double input) {
    if (_previous) {
      if (input < _low) _previous = false;
    } else {
      if (input > _high) _previous = true;
    }
    return _previous;
  }
}

/// Frequency demodulation helper.
class FrequencyModulation {
  double _prev = 0;
  final double _scale;
  static const double _pi = math.pi;
  static const double _twoPi = 2 * math.pi;

  FrequencyModulation(double bandwidth, double sampleRate)
      : _scale = sampleRate / (bandwidth * math.pi);

  double _wrap(double value) {
    if (value < -_pi) return value + _twoPi;
    if (value > _pi) return value - _twoPi;
    return value;
  }

  double demod(Complex input) {
    final phase = input.arg();
    final delta = _wrap(phase - _prev);
    _prev = phase;
    return _scale * delta;
  }
}

/// Complex convolution (FIR filter for complex signals).
class ComplexConvolution {
  final int length;
  final List<double> taps;
  final List<double> _real;
  final List<double> _imag;
  final Complex _sum = Complex();
  int _pos = 0;

  ComplexConvolution(this.length)
      : taps = List<double>.filled(length, 0),
        _real = List<double>.filled(length, 0),
        _imag = List<double>.filled(length, 0);

  Complex push(Complex input) {
    _real[_pos] = input.real;
    _imag[_pos] = input.imag;
    if (++_pos >= length) _pos = 0;
    _sum.real = 0;
    _sum.imag = 0;
    for (int i = 0; i < taps.length; ++i) {
      _sum.real += taps[i] * _real[_pos];
      _sum.imag += taps[i] * _imag[_pos];
      if (++_pos >= length) _pos = 0;
    }
    return _sum;
  }
}
