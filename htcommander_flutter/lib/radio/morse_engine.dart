import 'dart:math';
import 'dart:typed_data';

/// Static morse code PCM generator.
///
/// Port of HTCommander.Core/radio/MorseCodeEngine.cs
/// Generates 8-bit unsigned PCM mono at 32kHz using ITU standard timing.
class MorseEngine {
  MorseEngine._();

  static const int _sampleRate = 32000;
  static const int _amplitude = 127; // Max for unsigned 8-bit PCM centered at 128

  /// Morse code dictionary (A-Z, 0-9, space).
  static const Map<String, String> _morseCode = {
    'A': '.-',
    'B': '-...',
    'C': '-.-.',
    'D': '-..',
    'E': '.',
    'F': '..-.',
    'G': '--.',
    'H': '....',
    'I': '..',
    'J': '.---',
    'K': '-.-',
    'L': '.-..',
    'M': '--',
    'N': '-.',
    'O': '---',
    'P': '.--.',
    'Q': '--.-',
    'R': '.-.',
    'S': '...',
    'T': '-',
    'U': '..-',
    'V': '...-',
    'W': '.--',
    'X': '-..-',
    'Y': '-.--',
    'Z': '--..',
    '0': '-----',
    '1': '.----',
    '2': '..---',
    '3': '...--',
    '4': '....-',
    '5': '.....',
    '6': '-....',
    '7': '--...',
    '8': '---..',
    '9': '----.',
    ' ': ' ',
  };

  /// Generates 8-bit unsigned PCM mono audio at 32kHz for the given morse text.
  ///
  /// [text] — the text to encode as morse code.
  /// [frequency] — tone frequency in Hz (default 500).
  /// [wpm] — words per minute (default 15).
  /// Returns raw 8-bit unsigned PCM bytes.
  static Uint8List generateMorsePcm(String text,
      {int frequency = 500, int wpm = 15}) {
    final double unit = 1.2 / wpm; // seconds per dit (ITU standard)
    final int samplesPerUnit = (_sampleRate * unit).toInt();

    // Pre-generate tone and silence segments
    final Uint8List ditTone = _generateTone(frequency, samplesPerUnit);
    final Uint8List dahTone = _generateTone(frequency, samplesPerUnit * 3);
    final Uint8List intraCharSpace = _generateSilence(samplesPerUnit); // 1 unit
    final Uint8List interCharSpace =
        _generateSilence(samplesPerUnit * 3); // 3 units
    final Uint8List wordSpace =
        _generateSilence(samplesPerUnit * 8); // 8 units

    final builder = BytesBuilder(copy: false);

    for (final ch in text.toUpperCase().split('')) {
      final code = _morseCode[ch];
      if (code == null) continue;

      if (code == ' ') {
        builder.add(wordSpace);
        continue;
      }

      for (int i = 0; i < code.length; i++) {
        if (code[i] == '.') {
          builder.add(ditTone);
        } else if (code[i] == '-') {
          builder.add(dahTone);
        }

        if (i < code.length - 1) {
          builder.add(intraCharSpace);
        }
      }

      builder.add(interCharSpace);
    }

    return builder.toBytes();
  }

  /// Generates a sine tone at the given frequency for the given number of samples.
  /// Returns 8-bit unsigned PCM centered at 128.
  static Uint8List _generateTone(int frequency, int sampleCount) {
    final buffer = Uint8List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      final double t = i / _sampleRate;
      final double value = sin(2 * pi * frequency * t);
      buffer[i] = (128 + value * _amplitude).toInt();
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
