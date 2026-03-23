// Copyright 2026 Ylian Saint-Hilaire
// Licensed under the Apache License, Version 2.0 (the "License");
// http://www.apache.org/licenses/LICENSE-2.0

import 'dart:typed_data';

/// Windowing coefficient tables and matrices for SBC encoder analysis filter.
class SbcEncoderTables {
  SbcEncoderTables._();

  /// Windowing coefficients for 4 subbands (fixed-point 2.13 format).
  /// Transposed and scrambled to fit circular buffer and DCT symmetry.
  /// Extended to 20 elements to support idx range 0-4 plus offset of 5.
  static final List<Int16List> window4 = <Int16List>[
    Int16List.fromList(const <int>[   0,  358, 4443,-4443, -358,    0,  358, 4443,-4443, -358,    0,  358, 4443,-4443, -358,    0,  358, 4443,-4443, -358]),
    Int16List.fromList(const <int>[  49,  946, 8082, -944,   61,   49,  946, 8082, -944,   61,   49,  946, 8082, -944,   61,   49,  946, 8082, -944,   61]),
    Int16List.fromList(const <int>[  18,  670, 6389,-2544, -100,   18,  670, 6389,-2544, -100,   18,  670, 6389,-2544, -100,   18,  670, 6389,-2544, -100]),
    Int16List.fromList(const <int>[  90, 1055, 9235,  201,  128,   90, 1055, 9235,  201,  128,   90, 1055, 9235,  201,  128,   90, 1055, 9235,  201,  128]),
  ];

  /// Windowing coefficients for 8 subbands (fixed-point 2.13 format).
  /// Transposed and scrambled to fit circular buffer and DCT symmetry.
  /// Extended to 20 elements to support idx range 0-4 plus offset of 5.
  static final List<Int16List> window8 = <Int16List>[
    Int16List.fromList(const <int>[   0,  185, 2228,-2228, -185,    0,  185, 2228,-2228, -185,    0,  185, 2228,-2228, -185,    0,  185, 2228,-2228, -185]),
    Int16List.fromList(const <int>[  27,  480, 4039, -480,   30,   27,  480, 4039, -480,   30,   27,  480, 4039, -480,   30,   27,  480, 4039, -480,   30]),
    Int16List.fromList(const <int>[   5,  263, 2719,-1743, -115,    5,  263, 2719,-1743, -115,    5,  263, 2719,-1743, -115,    5,  263, 2719,-1743, -115]),
    Int16List.fromList(const <int>[  58,  502, 4764,  290,   69,   58,  502, 4764,  290,   69,   58,  502, 4764,  290,   69,   58,  502, 4764,  290,   69]),
    Int16List.fromList(const <int>[  11,  343, 3197,-1280,  -54,   11,  343, 3197,-1280,  -54,   11,  343, 3197,-1280,  -54,   11,  343, 3197,-1280,  -54]),
    Int16List.fromList(const <int>[  48,  532, 4612,   96,   65,   48,  532, 4612,   96,   65,   48,  532, 4612,   96,   65,   48,  532, 4612,   96,   65]),
    Int16List.fromList(const <int>[  18,  418, 3644, -856,   -6,   18,  418, 3644, -856,   -6,   18,  418, 3644, -856,   -6,   18,  418, 3644, -856,   -6]),
    Int16List.fromList(const <int>[  37,  521, 4367, -161,   53,   37,  521, 4367, -161,   53,   37,  521, 4367, -161,   53,   37,  521, 4367, -161,   53]),
  ];

  /// Cosine matrix for 8-subband DCT (fixed-point 0.13 format).
  static final List<Int16List> cosMatrix8 = <Int16List>[
    Int16List.fromList(const <int>[  5793,  6811,  7568,  8035,   4551,  3135,  1598, 8192]),
    Int16List.fromList(const <int>[ -5793, -1598,  3135,  6811,  -8035, -7568, -4551, 8192]),
    Int16List.fromList(const <int>[ -5793, -8035, -3135,  4551,   1598,  7568,  6811, 8192]),
    Int16List.fromList(const <int>[  5793, -4551, -7568,  1598,   6811, -3135, -8035, 8192]),
    Int16List.fromList(const <int>[  5793,  4551, -7568, -1598,  -6811, -3135,  8035, 8192]),
    Int16List.fromList(const <int>[ -5793,  8035, -3135, -4551,  -1598,  7568, -6811, 8192]),
    Int16List.fromList(const <int>[ -5793,  1598,  3135, -6811,   8035, -7568,  4551, 8192]),
    Int16List.fromList(const <int>[  5793, -6811,  7568, -8035,  -4551,  3135, -1598, 8192]),
  ];
}
