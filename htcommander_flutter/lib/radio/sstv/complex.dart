/*
Complex math
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:math' as math;

class Complex {
  double real;
  double imag;

  Complex([this.real = 0, this.imag = 0]);

  Complex setFrom(Complex other) {
    real = other.real;
    imag = other.imag;
    return this;
  }

  Complex setValues(double real, [double imag = 0]) {
    this.real = real;
    this.imag = imag;
    return this;
  }

  double norm() {
    return real * real + imag * imag;
  }

  double abs() {
    return math.sqrt(norm());
  }

  double arg() {
    return math.atan2(imag, real);
  }

  Complex polar(double a, double b) {
    real = a * math.cos(b);
    imag = a * math.sin(b);
    return this;
  }

  Complex conj() {
    imag = -imag;
    return this;
  }

  Complex add(Complex other) {
    real += other.real;
    imag += other.imag;
    return this;
  }

  Complex sub(Complex other) {
    real -= other.real;
    imag -= other.imag;
    return this;
  }

  Complex mulScalar(double value) {
    real *= value;
    imag *= value;
    return this;
  }

  Complex mul(Complex other) {
    final tmp = real * other.real - imag * other.imag;
    imag = real * other.imag + imag * other.real;
    real = tmp;
    return this;
  }

  Complex divScalar(double value) {
    real /= value;
    imag /= value;
    return this;
  }

  Complex div(Complex other) {
    final den = other.norm();
    final tmp = (real * other.real + imag * other.imag) / den;
    imag = (imag * other.real - real * other.imag) / den;
    real = tmp;
    return this;
  }
}
