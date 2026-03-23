/*
Fast Fourier Transform
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;
import 'complex.dart';

class FastFourierTransform {
  final List<Complex> _tf;
  final Complex _tmpA = Complex();
  final Complex _tmpB = Complex();
  final Complex _tmpC = Complex();
  final Complex _tmpD = Complex();
  final Complex _tmpE = Complex();
  final Complex _tmpF = Complex();
  final Complex _tmpG = Complex();
  final Complex _tmpH = Complex();
  final Complex _tmpI = Complex();
  final Complex _tmpJ = Complex();
  final Complex _tmpK = Complex();
  final Complex _tmpL = Complex();
  final Complex _tmpM = Complex();
  final Complex _tin0 = Complex();
  final Complex _tin1 = Complex();
  final Complex _tin2 = Complex();
  final Complex _tin3 = Complex();
  final Complex _tin4 = Complex();
  final Complex _tin5 = Complex();
  final Complex _tin6 = Complex();

  FastFourierTransform(int length) : _tf = List<Complex>.generate(length, (_) => Complex()) {
    int rest = length;
    while (rest > 1) {
      if (rest % 2 == 0) {
        rest ~/= 2;
      } else if (rest % 3 == 0) {
        rest ~/= 3;
      } else if (rest % 5 == 0) {
        rest ~/= 5;
      } else if (rest % 7 == 0) {
        rest ~/= 7;
      } else {
        break;
      }
    }
    if (rest != 1) {
      throw ArgumentError(
          'Transform length must be a composite of 2, 3, 5 and 7, but was: $length');
    }
    for (int i = 0; i < length; ++i) {
      final x = -(2.0 * math.pi * i) / length;
      _tf[i] = Complex(math.cos(x), math.sin(x));
    }
  }

  int get length => _tf.length;

  static bool _isPowerOfTwo(int n) {
    return n > 0 && (n & (n - 1)) == 0;
  }

  static bool _isPowerOfFour(int n) {
    return _isPowerOfTwo(n) && (n & 0x55555555) != 0;
  }

  static double _cos(int n, int bigN) {
    return math.cos(n * 2.0 * math.pi / bigN);
  }

  static double _sin(int n, int bigN) {
    return math.sin(n * 2.0 * math.pi / bigN);
  }

  void _dft2(Complex out0, Complex out1, Complex in0, Complex in1) {
    out0.setFrom(in0).add(in1);
    out1.setFrom(in0).sub(in1);
  }

  void _radix2(List<Complex> output, List<Complex> input, int o, int i, int n, int s, bool f) {
    if (n == 2) {
      _dft2(output[o], output[o + 1], input[i], input[i + s]);
    } else {
      final q = n ~/ 2;
      _dit(output, input, o, i, q, 2 * s, f);
      _dit(output, input, o + q, i + s, q, 2 * s, f);
      for (int k0 = o, k1 = o + q, l1 = 0; k0 < o + q; ++k0, ++k1, l1 += s) {
        _tin1.setFrom(_tf[l1]);
        if (!f) _tin1.conj();
        _tin0.setFrom(output[k0]);
        _tin1.mul(output[k1]);
        _dft2(output[k0], output[k1], _tin0, _tin1);
      }
    }
  }

  void _fwd3(Complex out0, Complex out1, Complex out2, Complex in0, Complex in1, Complex in2) {
    _tmpA.setFrom(in1).add(in2);
    _tmpB.setValues(in1.imag - in2.imag, in2.real - in1.real);
    _tmpC.setFrom(_tmpA).mulScalar(_cos(1, 3));
    _tmpD.setFrom(_tmpB).mulScalar(_sin(1, 3));
    out0.setFrom(in0).add(_tmpA);
    out1.setFrom(in0).add(_tmpC).add(_tmpD);
    out2.setFrom(in0).add(_tmpC).sub(_tmpD);
  }

  void _radix3(List<Complex> output, List<Complex> input, int o, int i, int n, int s, bool f) {
    if (n == 3) {
      if (f) {
        _fwd3(output[o], output[o + 1], output[o + 2], input[i], input[i + s], input[i + 2 * s]);
      } else {
        _fwd3(output[o], output[o + 2], output[o + 1], input[i], input[i + s], input[i + 2 * s]);
      }
    } else {
      final q = n ~/ 3;
      _dit(output, input, o, i, q, 3 * s, f);
      _dit(output, input, o + q, i + s, q, 3 * s, f);
      _dit(output, input, o + 2 * q, i + 2 * s, q, 3 * s, f);
      for (int k0 = o, k1 = o + q, k2 = o + 2 * q, l1 = 0, l2 = 0;
          k0 < o + q;
          ++k0, ++k1, ++k2, l1 += s, l2 += 2 * s) {
        _tin1.setFrom(_tf[l1]);
        _tin2.setFrom(_tf[l2]);
        if (!f) {
          _tin1.conj();
          _tin2.conj();
        }
        _tin0.setFrom(output[k0]);
        _tin1.mul(output[k1]);
        _tin2.mul(output[k2]);
        if (f) {
          _fwd3(output[k0], output[k1], output[k2], _tin0, _tin1, _tin2);
        } else {
          _fwd3(output[k0], output[k2], output[k1], _tin0, _tin1, _tin2);
        }
      }
    }
  }

  void _fwd4(Complex out0, Complex out1, Complex out2, Complex out3,
      Complex in0, Complex in1, Complex in2, Complex in3) {
    _tmpA.setFrom(in0).add(in2);
    _tmpB.setFrom(in0).sub(in2);
    _tmpC.setFrom(in1).add(in3);
    _tmpD.setValues(in1.imag - in3.imag, in3.real - in1.real);
    out0.setFrom(_tmpA).add(_tmpC);
    out1.setFrom(_tmpB).add(_tmpD);
    out2.setFrom(_tmpA).sub(_tmpC);
    out3.setFrom(_tmpB).sub(_tmpD);
  }

  void _radix4(List<Complex> output, List<Complex> input, int o, int i, int n, int s, bool f) {
    if (n == 4) {
      if (f) {
        _fwd4(output[o], output[o + 1], output[o + 2], output[o + 3],
            input[i], input[i + s], input[i + 2 * s], input[i + 3 * s]);
      } else {
        _fwd4(output[o], output[o + 3], output[o + 2], output[o + 1],
            input[i], input[i + s], input[i + 2 * s], input[i + 3 * s]);
      }
    } else {
      final q = n ~/ 4;
      _radix4(output, input, o, i, q, 4 * s, f);
      _radix4(output, input, o + q, i + s, q, 4 * s, f);
      _radix4(output, input, o + 2 * q, i + 2 * s, q, 4 * s, f);
      _radix4(output, input, o + 3 * q, i + 3 * s, q, 4 * s, f);
      for (int k0 = o, k1 = o + q, k2 = o + 2 * q, k3 = o + 3 * q, l1 = 0, l2 = 0, l3 = 0;
          k0 < o + q;
          ++k0, ++k1, ++k2, ++k3, l1 += s, l2 += 2 * s, l3 += 3 * s) {
        _tin1.setFrom(_tf[l1]);
        _tin2.setFrom(_tf[l2]);
        _tin3.setFrom(_tf[l3]);
        if (!f) {
          _tin1.conj();
          _tin2.conj();
          _tin3.conj();
        }
        _tin0.setFrom(output[k0]);
        _tin1.mul(output[k1]);
        _tin2.mul(output[k2]);
        _tin3.mul(output[k3]);
        if (f) {
          _fwd4(output[k0], output[k1], output[k2], output[k3], _tin0, _tin1, _tin2, _tin3);
        } else {
          _fwd4(output[k0], output[k3], output[k2], output[k1], _tin0, _tin1, _tin2, _tin3);
        }
      }
    }
  }

  void _fwd5(Complex out0, Complex out1, Complex out2, Complex out3, Complex out4,
      Complex in0, Complex in1, Complex in2, Complex in3, Complex in4) {
    _tmpA.setFrom(in1).add(in4);
    _tmpB.setFrom(in2).add(in3);
    _tmpC.setValues(in1.imag - in4.imag, in4.real - in1.real);
    _tmpD.setValues(in2.imag - in3.imag, in3.real - in2.real);
    _tmpF.setFrom(_tmpA).mulScalar(_cos(1, 5)).add(_tmpE.setFrom(_tmpB).mulScalar(_cos(2, 5)));
    _tmpG.setFrom(_tmpC).mulScalar(_sin(1, 5)).add(_tmpE.setFrom(_tmpD).mulScalar(_sin(2, 5)));
    _tmpH.setFrom(_tmpA).mulScalar(_cos(2, 5)).add(_tmpE.setFrom(_tmpB).mulScalar(_cos(1, 5)));
    _tmpI.setFrom(_tmpC).mulScalar(_sin(2, 5)).sub(_tmpE.setFrom(_tmpD).mulScalar(_sin(1, 5)));
    out0.setFrom(in0).add(_tmpA).add(_tmpB);
    out1.setFrom(in0).add(_tmpF).add(_tmpG);
    out2.setFrom(in0).add(_tmpH).add(_tmpI);
    out3.setFrom(in0).add(_tmpH).sub(_tmpI);
    out4.setFrom(in0).add(_tmpF).sub(_tmpG);
  }

  void _radix5(List<Complex> output, List<Complex> input, int o, int i, int n, int s, bool f) {
    if (n == 5) {
      if (f) {
        _fwd5(output[o], output[o + 1], output[o + 2], output[o + 3], output[o + 4],
            input[i], input[i + s], input[i + 2 * s], input[i + 3 * s], input[i + 4 * s]);
      } else {
        _fwd5(output[o], output[o + 4], output[o + 3], output[o + 2], output[o + 1],
            input[i], input[i + s], input[i + 2 * s], input[i + 3 * s], input[i + 4 * s]);
      }
    } else {
      final q = n ~/ 5;
      _dit(output, input, o, i, q, 5 * s, f);
      _dit(output, input, o + q, i + s, q, 5 * s, f);
      _dit(output, input, o + 2 * q, i + 2 * s, q, 5 * s, f);
      _dit(output, input, o + 3 * q, i + 3 * s, q, 5 * s, f);
      _dit(output, input, o + 4 * q, i + 4 * s, q, 5 * s, f);
      for (int k0 = o, k1 = o + q, k2 = o + 2 * q, k3 = o + 3 * q, k4 = o + 4 * q,
              l1 = 0, l2 = 0, l3 = 0, l4 = 0;
          k0 < o + q;
          ++k0, ++k1, ++k2, ++k3, ++k4, l1 += s, l2 += 2 * s, l3 += 3 * s, l4 += 4 * s) {
        _tin1.setFrom(_tf[l1]);
        _tin2.setFrom(_tf[l2]);
        _tin3.setFrom(_tf[l3]);
        _tin4.setFrom(_tf[l4]);
        if (!f) {
          _tin1.conj();
          _tin2.conj();
          _tin3.conj();
          _tin4.conj();
        }
        _tin0.setFrom(output[k0]);
        _tin1.mul(output[k1]);
        _tin2.mul(output[k2]);
        _tin3.mul(output[k3]);
        _tin4.mul(output[k4]);
        if (f) {
          _fwd5(output[k0], output[k1], output[k2], output[k3], output[k4],
              _tin0, _tin1, _tin2, _tin3, _tin4);
        } else {
          _fwd5(output[k0], output[k4], output[k3], output[k2], output[k1],
              _tin0, _tin1, _tin2, _tin3, _tin4);
        }
      }
    }
  }

  void _fwd7(
      Complex out0, Complex out1, Complex out2, Complex out3,
      Complex out4, Complex out5, Complex out6,
      Complex in0, Complex in1, Complex in2, Complex in3,
      Complex in4, Complex in5, Complex in6) {
    _tmpA.setFrom(in1).add(in6);
    _tmpB.setFrom(in2).add(in5);
    _tmpC.setFrom(in3).add(in4);
    _tmpD.setValues(in1.imag - in6.imag, in6.real - in1.real);
    _tmpE.setValues(in2.imag - in5.imag, in5.real - in2.real);
    _tmpF.setValues(in3.imag - in4.imag, in4.real - in3.real);
    _tmpH.setFrom(_tmpA).mulScalar(_cos(1, 7)).add(_tmpG.setFrom(_tmpB).mulScalar(_cos(2, 7))).add(_tmpG.setFrom(_tmpC).mulScalar(_cos(3, 7)));
    _tmpI.setFrom(_tmpD).mulScalar(_sin(1, 7)).add(_tmpG.setFrom(_tmpE).mulScalar(_sin(2, 7))).add(_tmpG.setFrom(_tmpF).mulScalar(_sin(3, 7)));
    _tmpJ.setFrom(_tmpA).mulScalar(_cos(2, 7)).add(_tmpG.setFrom(_tmpB).mulScalar(_cos(3, 7))).add(_tmpG.setFrom(_tmpC).mulScalar(_cos(1, 7)));
    _tmpK.setFrom(_tmpD).mulScalar(_sin(2, 7)).sub(_tmpG.setFrom(_tmpE).mulScalar(_sin(3, 7))).sub(_tmpG.setFrom(_tmpF).mulScalar(_sin(1, 7)));
    _tmpL.setFrom(_tmpA).mulScalar(_cos(3, 7)).add(_tmpG.setFrom(_tmpB).mulScalar(_cos(1, 7))).add(_tmpG.setFrom(_tmpC).mulScalar(_cos(2, 7)));
    _tmpM.setFrom(_tmpD).mulScalar(_sin(3, 7)).sub(_tmpG.setFrom(_tmpE).mulScalar(_sin(1, 7))).add(_tmpG.setFrom(_tmpF).mulScalar(_sin(2, 7)));
    out0.setFrom(in0).add(_tmpA).add(_tmpB).add(_tmpC);
    out1.setFrom(in0).add(_tmpH).add(_tmpI);
    out2.setFrom(in0).add(_tmpJ).add(_tmpK);
    out3.setFrom(in0).add(_tmpL).add(_tmpM);
    out4.setFrom(in0).add(_tmpL).sub(_tmpM);
    out5.setFrom(in0).add(_tmpJ).sub(_tmpK);
    out6.setFrom(in0).add(_tmpH).sub(_tmpI);
  }

  void _radix7(List<Complex> output, List<Complex> input, int o, int i, int n, int s, bool f) {
    if (n == 7) {
      if (f) {
        _fwd7(output[o], output[o + 1], output[o + 2], output[o + 3],
            output[o + 4], output[o + 5], output[o + 6],
            input[i], input[i + s], input[i + 2 * s], input[i + 3 * s],
            input[i + 4 * s], input[i + 5 * s], input[i + 6 * s]);
      } else {
        _fwd7(output[o], output[o + 6], output[o + 5], output[o + 4],
            output[o + 3], output[o + 2], output[o + 1],
            input[i], input[i + s], input[i + 2 * s], input[i + 3 * s],
            input[i + 4 * s], input[i + 5 * s], input[i + 6 * s]);
      }
    } else {
      final q = n ~/ 7;
      _dit(output, input, o, i, q, 7 * s, f);
      _dit(output, input, o + q, i + s, q, 7 * s, f);
      _dit(output, input, o + 2 * q, i + 2 * s, q, 7 * s, f);
      _dit(output, input, o + 3 * q, i + 3 * s, q, 7 * s, f);
      _dit(output, input, o + 4 * q, i + 4 * s, q, 7 * s, f);
      _dit(output, input, o + 5 * q, i + 5 * s, q, 7 * s, f);
      _dit(output, input, o + 6 * q, i + 6 * s, q, 7 * s, f);
      for (int k0 = o, k1 = o + q, k2 = o + 2 * q, k3 = o + 3 * q,
              k4 = o + 4 * q, k5 = o + 5 * q, k6 = o + 6 * q,
              l1 = 0, l2 = 0, l3 = 0, l4 = 0, l5 = 0, l6 = 0;
          k0 < o + q;
          ++k0, ++k1, ++k2, ++k3, ++k4, ++k5, ++k6,
          l1 += s, l2 += 2 * s, l3 += 3 * s, l4 += 4 * s, l5 += 5 * s, l6 += 6 * s) {
        _tin1.setFrom(_tf[l1]);
        _tin2.setFrom(_tf[l2]);
        _tin3.setFrom(_tf[l3]);
        _tin4.setFrom(_tf[l4]);
        _tin5.setFrom(_tf[l5]);
        _tin6.setFrom(_tf[l6]);
        if (!f) {
          _tin1.conj();
          _tin2.conj();
          _tin3.conj();
          _tin4.conj();
          _tin5.conj();
          _tin6.conj();
        }
        _tin0.setFrom(output[k0]);
        _tin1.mul(output[k1]);
        _tin2.mul(output[k2]);
        _tin3.mul(output[k3]);
        _tin4.mul(output[k4]);
        _tin5.mul(output[k5]);
        _tin6.mul(output[k6]);
        if (f) {
          _fwd7(output[k0], output[k1], output[k2], output[k3],
              output[k4], output[k5], output[k6],
              _tin0, _tin1, _tin2, _tin3, _tin4, _tin5, _tin6);
        } else {
          _fwd7(output[k0], output[k6], output[k5], output[k4],
              output[k3], output[k2], output[k1],
              _tin0, _tin1, _tin2, _tin3, _tin4, _tin5, _tin6);
        }
      }
    }
  }

  void _dit(List<Complex> output, List<Complex> input, int o, int i, int n, int s, bool f) {
    if (n == 1) {
      output[o].setFrom(input[i]);
    } else if (_isPowerOfFour(n)) {
      _radix4(output, input, o, i, n, s, f);
    } else if (n % 7 == 0) {
      _radix7(output, input, o, i, n, s, f);
    } else if (n % 5 == 0) {
      _radix5(output, input, o, i, n, s, f);
    } else if (n % 3 == 0) {
      _radix3(output, input, o, i, n, s, f);
    } else if (n % 2 == 0) {
      _radix2(output, input, o, i, n, s, f);
    }
  }

  void forward(List<Complex> output, List<Complex> input) {
    if (input.length != _tf.length) {
      throw ArgumentError(
          'Input array length (${input.length}) must be equal to Transform length (${_tf.length})');
    }
    if (output.length != _tf.length) {
      throw ArgumentError(
          'Output array length (${output.length}) must be equal to Transform length (${_tf.length})');
    }
    _dit(output, input, 0, 0, _tf.length, 1, true);
  }

  void backward(List<Complex> output, List<Complex> input) {
    if (input.length != _tf.length) {
      throw ArgumentError(
          'Input array length (${input.length}) must be equal to Transform length (${_tf.length})');
    }
    if (output.length != _tf.length) {
      throw ArgumentError(
          'Output array length (${output.length}) must be equal to Transform length (${_tf.length})');
    }
    _dit(output, input, 0, 0, _tf.length, 1, false);
  }
}
