/*
Short Time Fourier Transform
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'complex.dart';
import 'fft.dart';
import 'filter.dart';

class ShortTimeFourierTransform {
  final FastFourierTransform _fft;
  final List<Complex> _prev;
  final List<Complex> _fold;
  final List<Complex> _freq;
  final List<double> _weight;
  final Complex _temp = Complex();
  int _index = 0;

  final List<double> power;

  ShortTimeFourierTransform(int length, int overlap)
      : _fft = FastFourierTransform(length),
        _prev = List<Complex>.generate(length * overlap, (_) => Complex()),
        _fold = List<Complex>.generate(length, (_) => Complex()),
        _freq = List<Complex>.generate(length, (_) => Complex()),
        power = List<double>.filled(length, 0),
        _weight = List<double>.generate(
          length * overlap,
          (i) => Filter.lowPass(1, length.toDouble(), i, length * overlap) * Hann.window(i, length * overlap),
        );

  bool push(Complex input) {
    _prev[_index].setFrom(input);
    _index = (_index + 1) % _prev.length;
    if (_index % _fold.length != 0) return false;
    for (int i = 0; i < _fold.length; ++i) {
      _fold[i].setFrom(_prev[_index]).mulScalar(_weight[i]);
      _index = (_index + 1) % _prev.length;
    }
    for (int i = _fold.length; i < _prev.length; ++i) {
      _fold[i % _fold.length].add(_temp.setFrom(_prev[_index]).mulScalar(_weight[i]));
      _index = (_index + 1) % _prev.length;
    }
    _fft.forward(_freq, _fold);
    for (int i = 0; i < power.length; ++i) {
      power[i] = _freq[i].norm();
    }
    return true;
  }
}
