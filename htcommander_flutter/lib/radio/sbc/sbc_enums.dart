// Copyright 2026 Ylian Saint-Hilaire
// Licensed under the Apache License, Version 2.0 (the "License");
// http://www.apache.org/licenses/LICENSE-2.0

/// SBC sampling frequencies.
enum SbcFrequency {
  /// 16 kHz
  freq16K, // 0

  /// 32 kHz
  freq32K, // 1

  /// 44.1 kHz
  freq44K1, // 2

  /// 48 kHz
  freq48K, // 3
}

/// SBC channel modes.
enum SbcMode {
  /// Mono (1 channel)
  mono, // 0

  /// Dual channel (2 independent channels)
  dualChannel, // 1

  /// Stereo (2 channels)
  stereo, // 2

  /// Joint stereo (2 channels with joint encoding)
  jointStereo, // 3
}

/// SBC bit allocation method.
enum SbcBitAllocationMethod {
  /// Loudness allocation
  loudness, // 0

  /// SNR allocation
  snr, // 1
}
