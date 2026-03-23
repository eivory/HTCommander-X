import 'dart:typed_data';

/// Pure-managed audio resampler using linear interpolation.
/// Port of HTCommander.Core/AudioResampler.cs
///
/// Sufficient for speech (32kHz↔48kHz conversion).
class AudioResampler {
  /// Resample 16-bit mono PCM audio from one sample rate to another.
  ///
  /// [input] is 16-bit signed little-endian PCM.
  /// Returns resampled PCM in the same format.
  static Uint8List resample16BitMono(
      Uint8List input, int inputSampleRate, int outputSampleRate) {
    if (input.length < 2) return input;
    if (inputSampleRate <= 0 || outputSampleRate <= 0) return input;
    if (inputSampleRate == outputSampleRate) return input;

    final inputSamples = input.length ~/ 2;
    final outputSamplesLong = inputSamples * outputSampleRate ~/ inputSampleRate;
    if (outputSamplesLong <= 0 || outputSamplesLong > (0x7FFFFFFF ~/ 2)) {
      return input;
    }
    final outputSamples = outputSamplesLong;
    final output = Uint8List(outputSamples * 2);

    final ratio = inputSampleRate / outputSampleRate;

    for (var i = 0; i < outputSamples; i++) {
      final srcPos = i * ratio;
      final srcIndex = srcPos.toInt();
      final frac = srcPos - srcIndex;

      final sample1 = _getSample16(input, srcIndex);
      final sample2 = _getSample16(
          input, srcIndex + 1 < inputSamples ? srcIndex + 1 : inputSamples - 1);

      // Linear interpolation
      var result = (sample1 + (sample2 - sample1) * frac).round();
      if (result > 32767) result = 32767;
      if (result < -32768) result = -32768;

      output[i * 2] = result & 0xFF;
      output[i * 2 + 1] = (result >> 8) & 0xFF;
    }

    return output;
  }

  /// Resample 16-bit stereo PCM to mono at a different sample rate.
  static Uint8List resampleStereoToMono16Bit(
      Uint8List input, int inputSampleRate, int outputSampleRate) {
    if (input.length < 4) return input;
    if (inputSampleRate <= 0 || outputSampleRate <= 0) return input;

    // Convert stereo to mono
    final stereoSamples = input.length ~/ 4;
    final mono = Uint8List(stereoSamples * 2);

    for (var i = 0; i < stereoSamples; i++) {
      final left = _getSample16(input, i * 2);
      final right = _getSample16(input, i * 2 + 1);
      final mixed = ((left + right) ~/ 2);
      mono[i * 2] = mixed & 0xFF;
      mono[i * 2 + 1] = (mixed >> 8) & 0xFF;
    }

    return resample16BitMono(mono, inputSampleRate, outputSampleRate);
  }

  static int _getSample16(Uint8List data, int sampleIndex) {
    final byteIndex = sampleIndex * 2;
    if (byteIndex + 1 >= data.length) return 0;
    final raw = data[byteIndex] | (data[byteIndex + 1] << 8);
    // Sign-extend 16-bit to full int
    return raw > 32767 ? raw - 65536 : raw;
  }
}
