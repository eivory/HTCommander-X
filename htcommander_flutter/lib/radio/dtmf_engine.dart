import 'dart:math';
import 'dart:typed_data';

/// Static DTMF tone PCM generator.
///
/// Port of HTCommander.Core/radio/DmtfEngine.cs
/// Generates 8-bit unsigned PCM mono at 32kHz with standard DTMF frequency pairs.
class DtmfEngine {
  DtmfEngine._();

  static const int _sampleRate = 32000;
  static const int _amplitude = 63; // Half of 127 so two tones summed stay within 8-bit range

  /// DTMF frequency pairs: (row frequency, column frequency).
  static const Map<String, (int, int)> _dtmfFrequencies = {
    '1': (697, 1209),
    '2': (697, 1336),
    '3': (697, 1477),
    '4': (770, 1209),
    '5': (770, 1336),
    '6': (770, 1477),
    '7': (852, 1209),
    '8': (852, 1336),
    '9': (852, 1477),
    '*': (941, 1209),
    '0': (941, 1336),
    '#': (941, 1477),
  };

  /// Generates 8-bit unsigned PCM audio (32kHz, mono) for a DTMF digit string.
  ///
  /// Valid characters: 0-9, *, #. Unknown characters are silently skipped.
  /// [digits] — string of DTMF characters to encode.
  /// [toneDurationMs] — duration of each tone in milliseconds (default 150).
  /// [gapDurationMs] — silent gap between tones in milliseconds (default 80).
  /// Returns raw 8-bit unsigned PCM bytes at 32kHz mono.
  static Uint8List generateDtmfPcm(String digits,
      {int toneDurationMs = 150, int gapDurationMs = 80}) {
    final int toneSamples = (_sampleRate * toneDurationMs / 1000.0).toInt();
    final int gapSamples = (_sampleRate * gapDurationMs / 1000.0).toInt();

    final Uint8List gap = _generateSilence(gapSamples);

    final builder = BytesBuilder(copy: false);
    bool firstDigit = true;

    for (final ch in digits.split('')) {
      final freq = _dtmfFrequencies[ch];
      if (freq == null) continue;

      // Insert inter-digit gap before every digit except the first
      if (!firstDigit) {
        builder.add(gap);
      }
      firstDigit = false;

      final tone = _generateDualTone(freq.$1, freq.$2, toneSamples);
      builder.add(tone);
    }

    return builder.toBytes();
  }

  /// Generates a dual-tone signal by summing two sine waves.
  /// Returns 8-bit unsigned PCM centered at 128.
  static Uint8List _generateDualTone(
      int lowFreq, int highFreq, int sampleCount) {
    final buffer = Uint8List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      final double t = i / _sampleRate;
      final double low = sin(2 * pi * lowFreq * t);
      final double high = sin(2 * pi * highFreq * t);
      // Mix two tones and scale to 8-bit unsigned PCM centered at 128
      buffer[i] = (128 + (low + high) * _amplitude).toInt();
    }
    return buffer;
  }

  /// Generates silence (value 128) for the given number of samples.
  static Uint8List _generateSilence(int sampleCount) {
    final buffer = Uint8List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      buffer[i] = 128;
    }
    return buffer;
  }
}
