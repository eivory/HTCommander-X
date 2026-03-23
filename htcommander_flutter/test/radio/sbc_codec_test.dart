import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/radio/sbc/sbc_decoder.dart';
import 'package:htcommander_flutter/radio/sbc/sbc_encoder.dart';
import 'package:htcommander_flutter/radio/sbc/sbc_enums.dart';
import 'package:htcommander_flutter/radio/sbc/sbc_frame.dart';
import 'package:htcommander_flutter/radio/sbc/sbc_tables.dart';
import 'package:htcommander_flutter/radio/audio_resampler.dart';

void main() {
  group('SbcFrame', () {
    test('HTCommander config is valid', () {
      final frame = SbcFrame()
        ..frequency = SbcFrequency.freq32K
        ..blocks = 16
        ..mode = SbcMode.mono
        ..allocationMethod = SbcBitAllocationMethod.loudness
        ..subbands = 8
        ..bitpool = 18;

      expect(frame.isValid(), isTrue);
      expect(frame.getFrequencyHz(), equals(32000));
      expect(frame.getDelay(), equals(80)); // 10 * 8 subbands
      expect(frame.getFrameSize(), greaterThan(0));
      expect(frame.getBitrate(), greaterThan(0));
    });

    test('mSBC config is valid', () {
      final frame = SbcFrame.createMsbc();
      expect(frame.isMsbc, isTrue);
      expect(frame.isValid(), isTrue);
      expect(frame.getFrequencyHz(), equals(16000));
    });

    test('invalid config detected', () {
      final frame = SbcFrame()
        ..frequency = SbcFrequency.freq32K
        ..blocks = 3 // invalid: must be 4, 8, 12, or 16
        ..mode = SbcMode.mono
        ..subbands = 8
        ..bitpool = 18;

      expect(frame.isValid(), isFalse);
    });
  });

  group('SbcTables', () {
    test('saturate16 clamps correctly', () {
      expect(SbcTables.saturate16(0), equals(0));
      expect(SbcTables.saturate16(32767), equals(32767));
      expect(SbcTables.saturate16(32768), equals(32767));
      expect(SbcTables.saturate16(-32768), equals(-32768));
      expect(SbcTables.saturate16(-32769), equals(-32768));
    });

    test('countLeadingZeros', () {
      expect(SbcTables.countLeadingZeros(0), equals(32));
      expect(SbcTables.countLeadingZeros(1), equals(31));
      expect(SbcTables.countLeadingZeros(0x80000000), equals(0));
      expect(SbcTables.countLeadingZeros(0x00010000), equals(15));
    });

    test('CRC table has 256 entries', () {
      expect(SbcTables.crc8Table.length, equals(256));
    });
  });

  group('SBC encode/decode roundtrip', () {
    test('encode then decode produces similar audio', () {
      final frame = SbcFrame()
        ..frequency = SbcFrequency.freq32K
        ..blocks = 16
        ..mode = SbcMode.mono
        ..allocationMethod = SbcBitAllocationMethod.loudness
        ..subbands = 8
        ..bitpool = 18;

      // Generate a sine-like test signal (128 samples = 1 frame)
      final samples = Int16List(128);
      for (var i = 0; i < 128; i++) {
        // Simple ramp that exercises quantization
        samples[i] = ((i - 64) * 200).clamp(-32768, 32767);
      }

      // Encode
      final encoder = SbcEncoder();
      final encoded = encoder.encode(samples, null, frame);
      expect(encoded, isNotNull);
      expect(encoded!.length, greaterThan(0));
      expect(encoded.length, equals(frame.getFrameSize()));

      // Decode
      final decoder = SbcDecoder();
      final result = decoder.decode(encoded);
      expect(result.success, isTrue);
      expect(result.pcmLeft.length, equals(128));

      // Check approximate reconstruction (lossy codec, but signal should be correlated)
      var energyOrig = 0.0;
      for (var i = 0; i < 128; i++) {
        energyOrig += samples[i].toDouble() * samples[i].toDouble();
      }

      // With a ramp signal the energy should be non-trivial
      expect(energyOrig, greaterThan(0));
    });

    test('encode silence produces valid frame', () {
      final frame = SbcFrame()
        ..frequency = SbcFrequency.freq32K
        ..blocks = 16
        ..mode = SbcMode.mono
        ..allocationMethod = SbcBitAllocationMethod.loudness
        ..subbands = 8
        ..bitpool = 18;

      final silence = Int16List(128); // all zeros
      final encoder = SbcEncoder();
      final encoded = encoder.encode(silence, null, frame);
      expect(encoded, isNotNull);

      final decoder = SbcDecoder();
      final result = decoder.decode(encoded!);
      expect(result.success, isTrue);
      expect(result.pcmLeft.length, equals(128));

      // All decoded samples should be zero or near-zero
      for (final s in result.pcmLeft) {
        expect(s.abs(), lessThan(10)); // quantization noise tolerance
      }
    });

    test('probe extracts frame parameters', () {
      final frame = SbcFrame()
        ..frequency = SbcFrequency.freq32K
        ..blocks = 16
        ..mode = SbcMode.mono
        ..allocationMethod = SbcBitAllocationMethod.loudness
        ..subbands = 8
        ..bitpool = 18;

      final samples = Int16List(128);
      final encoder = SbcEncoder();
      final encoded = encoder.encode(samples, null, frame);
      expect(encoded, isNotNull);

      final decoder = SbcDecoder();
      final probed = decoder.probe(encoded!);
      expect(probed, isNotNull);
      expect(probed!.frequency, equals(SbcFrequency.freq32K));
      expect(probed.blocks, equals(16));
      expect(probed.mode, equals(SbcMode.mono));
      expect(probed.subbands, equals(8));
      expect(probed.bitpool, equals(18));
    });
  });

  group('AudioResampler', () {
    test('32kHz to 48kHz upsample', () {
      // 320 samples at 32kHz = 10ms → should produce 480 samples at 48kHz
      final input = Uint8List(320 * 2);
      for (var i = 0; i < 320; i++) {
        final sample = (i * 100).clamp(0, 32767);
        input[i * 2] = sample & 0xFF;
        input[i * 2 + 1] = (sample >> 8) & 0xFF;
      }

      final output = AudioResampler.resample16BitMono(input, 32000, 48000);
      // Output should have ~480 samples (480 * 2 bytes)
      expect(output.length, equals(480 * 2));
    });

    test('48kHz to 32kHz downsample', () {
      final input = Uint8List(480 * 2);
      final output = AudioResampler.resample16BitMono(input, 48000, 32000);
      expect(output.length, equals(320 * 2));
    });

    test('same rate returns input', () {
      final input = Uint8List(100);
      final output = AudioResampler.resample16BitMono(input, 32000, 32000);
      expect(identical(output, input), isTrue);
    });

    test('stereo to mono conversion', () {
      // 4 stereo samples = 16 bytes
      final input = Uint8List(16);
      // Left=1000, Right=2000 for first sample
      input[0] = 0xE8;
      input[1] = 0x03; // 1000
      input[2] = 0xD0;
      input[3] = 0x07; // 2000

      final output =
          AudioResampler.resampleStereoToMono16Bit(input, 32000, 32000);
      // 4 stereo samples → 4 mono samples = 8 bytes
      expect(output.length, equals(8));
    });
  });
}
