/*
Pixel buffer with dimensions and line cursor
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'dart:typed_data';

class PixelBuffer {
  Int32List pixels;
  int width;
  int height;
  int line;

  PixelBuffer(this.width, this.height)
      : line = 0,
        pixels = Int32List(width * height);
}
