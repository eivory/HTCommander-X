// Copyright 2026 Ylian Saint-Hilaire
// Licensed under the Apache License, Version 2.0 (the "License");
// http://www.apache.org/licenses/LICENSE-2.0

import 'dart:math' as math;
import 'dart:typed_data';

import 'sbc_bit_stream.dart';
import 'sbc_decoder_tables.dart';
import 'sbc_enums.dart';
import 'sbc_frame.dart';
import 'sbc_tables.dart';

/// Result of decoding an SBC frame.
class SbcDecodeResult {
  /// Whether decoding succeeded.
  final bool success;

  /// PCM samples for the left (or mono) channel.
  final Int16List pcmLeft;

  /// PCM samples for the right channel, or null for mono.
  final Int16List? pcmRight;

  /// Frame parameters.
  final SbcFrame frame;

  const SbcDecodeResult({
    required this.success,
    required this.pcmLeft,
    this.pcmRight,
    required this.frame,
  });
}

/// SBC audio decoder - converts SBC frames to PCM samples.
class SbcDecoder {
  final List<_DecoderState> _channelStates;
  // ignore: unused_field
  int _numChannels = 0;
  // ignore: unused_field
  int _numBlocks = 0;
  // ignore: unused_field
  int _numSubbands = 0;

  SbcDecoder()
      : _channelStates = <_DecoderState>[_DecoderState(), _DecoderState()] {
    reset();
  }

  /// Reset decoder state.
  void reset() {
    _channelStates[0].reset();
    _channelStates[1].reset();
    _numChannels = 0;
    _numBlocks = 0;
    _numSubbands = 0;
  }

  /// Probe SBC data and extract frame parameters without full decoding.
  SbcFrame? probe(Uint8List data) {
    if (data.length < SbcFrame.headerSize) return null;

    final SbcBitStream bits =
        SbcBitStream(data, SbcFrame.headerSize, isReader: true);
    final SbcFrame frame = SbcFrame();
    final _HeaderResult hr = _decodeHeader(bits, frame);

    if (!hr.success) return null;
    return bits.hasError ? null : frame;
  }

  /// Decode an SBC frame to PCM samples.
  SbcDecodeResult decode(Uint8List sbcData) {
    final SbcFrame frame = SbcFrame();
    final Int16List emptyPcm = Int16List(0);

    if (sbcData.length < SbcFrame.headerSize) {
      return SbcDecodeResult(
          success: false, pcmLeft: emptyPcm, frame: frame);
    }

    // Decode header
    final SbcBitStream headerBits =
        SbcBitStream(sbcData, SbcFrame.headerSize, isReader: true);
    final _HeaderResult hr = _decodeHeader(headerBits, frame);
    if (!hr.success || headerBits.hasError) {
      return SbcDecodeResult(
          success: false, pcmLeft: emptyPcm, frame: frame);
    }

    final int frameSize = frame.getFrameSize();
    if (frameSize <= 0 || frameSize > 65536 || sbcData.length < frameSize) {
      return SbcDecodeResult(
          success: false, pcmLeft: emptyPcm, frame: frame);
    }

    // Verify CRC
    final int computedCrc = SbcTables.computeCrc(frame, sbcData, sbcData.length);
    if (computedCrc != hr.crc) {
      return SbcDecodeResult(
          success: false, pcmLeft: emptyPcm, frame: frame);
    }

    // Decode frame data
    final SbcBitStream dataBits =
        SbcBitStream(sbcData, frameSize, isReader: true);
    dataBits.getBits(SbcFrame.headerSize * 8); // Skip header

    final List<Int16List> sbSamples = <Int16List>[
      Int16List(SbcFrame.maxSamples),
      Int16List(SbcFrame.maxSamples),
    ];
    final Int32List sbScale = Int32List(2);

    _decodeFrameData(dataBits, frame, sbSamples, sbScale);
    if (dataBits.hasError) {
      return SbcDecodeResult(
          success: false, pcmLeft: emptyPcm, frame: frame);
    }

    _numChannels = frame.mode != SbcMode.mono ? 2 : 1;
    _numBlocks = frame.blocks;
    _numSubbands = frame.subbands;

    // Synthesize PCM
    final int samplesPerChannel = _numBlocks * _numSubbands;
    final Int16List pcmLeft = Int16List(samplesPerChannel);

    _synthesize(_channelStates[0], _numBlocks, _numSubbands, sbSamples[0],
        sbScale[0], pcmLeft, 1);

    Int16List? pcmRight;
    if (frame.mode != SbcMode.mono) {
      pcmRight = Int16List(samplesPerChannel);
      _synthesize(_channelStates[1], _numBlocks, _numSubbands, sbSamples[1],
          sbScale[1], pcmRight, 1);
    }

    return SbcDecodeResult(
      success: true,
      pcmLeft: pcmLeft,
      pcmRight: pcmRight,
      frame: frame,
    );
  }

  _HeaderResult _decodeHeader(SbcBitStream bits, SbcFrame frame) {
    final int syncword = bits.getBits(8);
    frame.isMsbc = (syncword == 0xad);

    if (frame.isMsbc) {
      bits.getBits(16); // reserved
      final SbcFrame msbcFrame = SbcFrame.createMsbc();
      frame.frequency = msbcFrame.frequency;
      frame.mode = msbcFrame.mode;
      frame.allocationMethod = msbcFrame.allocationMethod;
      frame.blocks = msbcFrame.blocks;
      frame.subbands = msbcFrame.subbands;
      frame.bitpool = msbcFrame.bitpool;
    } else if (syncword == 0x9c) {
      final int freq = bits.getBits(2);
      frame.frequency = SbcFrequency.values[freq];

      final int blockCode = bits.getBits(2);
      frame.blocks = (1 + blockCode) << 2;

      final int modeCode = bits.getBits(2);
      frame.mode = SbcMode.values[modeCode];

      final int bam = bits.getBits(1);
      frame.allocationMethod = SbcBitAllocationMethod.values[bam];

      final int subbandCode = bits.getBits(1);
      frame.subbands = (1 + subbandCode) << 2;

      frame.bitpool = bits.getBits(8);
    } else {
      return _HeaderResult(false, 0);
    }

    final int crc = bits.getBits(8);

    if (!frame.isValid()) {
      return _HeaderResult(false, 0);
    }

    return _HeaderResult(true, crc);
  }

  void _decodeFrameData(SbcBitStream bits, SbcFrame frame,
      List<Int16List> sbSamples, Int32List sbScale) {
    final int nchannels = frame.mode != SbcMode.mono ? 2 : 1;
    final int nsubbands = frame.subbands;

    // Decode joint stereo mask
    int mjoint = 0;
    if (frame.mode == SbcMode.jointStereo) {
      final int v = bits.getBits(nsubbands);
      if (nsubbands == 4) {
        mjoint = ((0x00) << 3) |
            ((v & 0x02) << 1) |
            ((v & 0x04) >> 1) |
            ((v & 0x08) >> 3);
      } else {
        mjoint = ((0x00) << 7) |
            ((v & 0x02) << 5) |
            ((v & 0x04) << 3) |
            ((v & 0x08) << 1) |
            ((v & 0x10) >> 1) |
            ((v & 0x20) >> 3) |
            ((v & 0x40) >> 5) |
            ((v & 0x80) >> 7);
      }
    }

    // Decode scale factors
    final List<Int32List> scaleFactors = <Int32List>[
      Int32List(SbcFrame.maxSubbands),
      Int32List(SbcFrame.maxSubbands),
    ];

    for (int ch = 0; ch < nchannels; ch++) {
      for (int sb = 0; sb < nsubbands; sb++) {
        scaleFactors[ch][sb] = bits.getBits(4);
      }
    }

    // Compute bit allocation
    final List<Int32List> nbits = <Int32List>[
      Int32List(SbcFrame.maxSubbands),
      Int32List(SbcFrame.maxSubbands),
    ];

    _computeBitAllocation(frame, scaleFactors, nbits);
    if (frame.mode == SbcMode.dualChannel) {
      final List<Int32List> scaleFactors1 = <Int32List>[scaleFactors[1]];
      final List<Int32List> nbits1 = <Int32List>[nbits[1]];
      _computeBitAllocation(frame, scaleFactors1, nbits1);
    }

    // Compute scale for output samples
    for (int ch = 0; ch < nchannels; ch++) {
      int maxScf = 0;
      for (int sb = 0; sb < nsubbands; sb++) {
        final int scf = scaleFactors[ch][sb] + ((mjoint >> sb) & 1);
        if (scf > maxScf) maxScf = scf;
      }
      sbScale[ch] = (15 - maxScf) - (17 - 16);
    }

    if (frame.mode == SbcMode.jointStereo) {
      sbScale[0] = math.min(sbScale[0], sbScale[1]);
      sbScale[1] = sbScale[0];
    }

    // Decode samples
    for (int blk = 0; blk < frame.blocks; blk++) {
      for (int ch = 0; ch < nchannels; ch++) {
        for (int sb = 0; sb < nsubbands; sb++) {
          final int nbit = nbits[ch][sb];
          final int scf = scaleFactors[ch][sb];
          final int idx = blk * nsubbands + sb;

          if (nbit == 0) {
            sbSamples[ch][idx] = 0;
            continue;
          }

          int sample = bits.getBits(nbit);
          sample = ((sample << 1) | 1) * SbcTables.rangeScale[nbit - 1];
          sbSamples[ch][idx] =
              SbcTables.saturate16((sample - (1 << 28)) >> (28 - ((scf + 1) + sbScale[ch])));
        }
      }
    }

    // Uncouple joint stereo
    for (int sb = 0; sb < nsubbands; sb++) {
      if (((mjoint >> sb) & 1) == 0) continue;

      for (int blk = 0; blk < frame.blocks; blk++) {
        final int idx = blk * nsubbands + sb;
        final int s0 = sbSamples[0][idx];
        final int s1 = sbSamples[1][idx];
        sbSamples[0][idx] = SbcTables.saturate16(s0 + s1);
        sbSamples[1][idx] = SbcTables.saturate16(s0 - s1);
      }
    }

    // Skip padding
    final int paddingBits = 8 - (bits.bitPosition % 8);
    if (paddingBits < 8) {
      bits.getBits(paddingBits);
    }
  }

  void _computeBitAllocation(
      SbcFrame frame, List<Int32List> scaleFactors, List<Int32List> nbits) {
    final List<int> loudnessOffset = frame.subbands == 4
        ? SbcTables.loudnessOffset4[frame.frequency.index]
        : SbcTables.loudnessOffset8[frame.frequency.index];

    final bool stereoMode =
        frame.mode == SbcMode.stereo || frame.mode == SbcMode.jointStereo;
    final int nsubbands = frame.subbands;
    final int nchannels = stereoMode ? 2 : 1;

    final List<Int32List> bitneeds = <Int32List>[
      Int32List(SbcFrame.maxSubbands),
      Int32List(SbcFrame.maxSubbands),
    ];
    int maxBitneed = 0;

    for (int ch = 0; ch < nchannels; ch++) {
      for (int sb = 0; sb < nsubbands; sb++) {
        final int scf = scaleFactors[ch][sb];
        int bitneed;

        if (frame.allocationMethod == SbcBitAllocationMethod.loudness) {
          bitneed = scf != 0 ? scf - loudnessOffset[sb] : -5;
          bitneed >>= (bitneed > 0) ? 1 : 0;
        } else {
          bitneed = scf;
        }

        if (bitneed > maxBitneed) maxBitneed = bitneed;

        bitneeds[ch][sb] = bitneed;
      }
    }

    // Bit distribution
    final int bitpool = frame.bitpool;
    int bitcount = 0;
    int bitslice = maxBitneed + 1;

    for (int bc = 0; bc < bitpool;) {
      final int bs = bitslice--;
      bitcount = bc;
      if (bitcount == bitpool) break;

      for (int ch = 0; ch < nchannels; ch++) {
        for (int sb = 0; sb < nsubbands; sb++) {
          final int bn = bitneeds[ch][sb];
          bc += (bn >= bs && bn < bs + 15 ? 1 : 0) + (bn == bs ? 1 : 0);
        }
      }
    }

    // Assign bits
    for (int ch = 0; ch < nchannels; ch++) {
      for (int sb = 0; sb < nsubbands; sb++) {
        final int nbit = bitneeds[ch][sb] - bitslice;
        nbits[ch][sb] = nbit < 2 ? 0 : nbit > 16 ? 16 : nbit;
      }
    }

    // Allocate remaining bits
    for (int sb = 0; sb < nsubbands && bitcount < bitpool; sb++) {
      for (int ch = 0; ch < nchannels && bitcount < bitpool; ch++) {
        final int n = (nbits[ch][sb] > 0 && nbits[ch][sb] < 16)
            ? 1
            : (bitneeds[ch][sb] == bitslice + 1 && bitpool > bitcount + 1)
                ? 2
                : 0;
        nbits[ch][sb] += n;
        bitcount += n;
      }
    }

    for (int sb = 0; sb < nsubbands && bitcount < bitpool; sb++) {
      for (int ch = 0; ch < nchannels && bitcount < bitpool; ch++) {
        final int n = nbits[ch][sb] < 16 ? 1 : 0;
        nbits[ch][sb] += n;
        bitcount += n;
      }
    }
  }

  void _synthesize(_DecoderState state, int nblocks, int nsubbands,
      Int16List input, int scale, Int16List output, int pitch) {
    for (int blk = 0; blk < nblocks; blk++) {
      final int inOffset = blk * nsubbands;
      final int outOffset = blk * nsubbands * pitch;

      if (nsubbands == 4) {
        _synthesize4(state, input, inOffset, scale, output, outOffset, pitch);
      } else {
        _synthesize8(state, input, inOffset, scale, output, outOffset, pitch);
      }
    }
  }

  void _synthesize4(_DecoderState state, Int16List input, int inOffset,
      int scale, Int16List output, int outOffset, int pitch) {
    final int dctIdx = state.index != 0 ? 10 - state.index : 0;
    final int odd = dctIdx & 1;

    _dct4(input, inOffset, scale, state.v[odd], state.v[1 - odd], dctIdx);
    _applyWindow4(state.v[odd], state.index, output, outOffset, pitch);

    state.index = state.index < 9 ? state.index + 1 : 0;
  }

  void _synthesize8(_DecoderState state, Int16List input, int inOffset,
      int scale, Int16List output, int outOffset, int pitch) {
    final int dctIdx = state.index != 0 ? 10 - state.index : 0;
    final int odd = dctIdx & 1;

    _dct8(input, inOffset, scale, state.v[odd], state.v[1 - odd], dctIdx);
    _applyWindow8(state.v[odd], state.index, output, outOffset, pitch);

    state.index = state.index < 9 ? state.index + 1 : 0;
  }

  void _dct4(Int16List input, int offset, int scale,
      List<Int16List> out0, List<Int16List> out1, int idx) {
    final Int16List cos8 = SbcTables.cos8;

    final int s03 = (input[offset + 0] + input[offset + 3]) >> 1;
    final int d03 = (input[offset + 0] - input[offset + 3]) >> 1;
    final int s12 = (input[offset + 1] + input[offset + 2]) >> 1;
    final int d12 = (input[offset + 1] - input[offset + 2]) >> 1;

    int a0 = (s03 - s12) * cos8[2];
    int b1 = -(s03 + s12) << 13;
    int a1 = d03 * cos8[3] - d12 * cos8[1];
    int b0 = -d03 * cos8[1] - d12 * cos8[3];

    final int shr = 12 + scale;
    a0 = (a0 + (1 << (shr - 1))) >> shr;
    b0 = (b0 + (1 << (shr - 1))) >> shr;
    a1 = (a1 + (1 << (shr - 1))) >> shr;
    b1 = (b1 + (1 << (shr - 1))) >> shr;

    out0[0][idx] = SbcTables.saturate16(a0);
    out0[3][idx] = SbcTables.saturate16(-a1);
    out0[1][idx] = SbcTables.saturate16(a1);
    out0[2][idx] = SbcTables.saturate16(0);

    out1[0][idx] = SbcTables.saturate16(-a0);
    out1[3][idx] = SbcTables.saturate16(b0);
    out1[1][idx] = SbcTables.saturate16(b0);
    out1[2][idx] = SbcTables.saturate16(b1);
  }

  void _dct8(Int16List input, int offset, int scale,
      List<Int16List> out0, List<Int16List> out1, int idx) {
    final Int16List cos16 = SbcTables.cos16;

    final int s07 = (input[offset + 0] + input[offset + 7]) >> 1;
    final int d07 = (input[offset + 0] - input[offset + 7]) >> 1;
    final int s16 = (input[offset + 1] + input[offset + 6]) >> 1;
    final int d16 = (input[offset + 1] - input[offset + 6]) >> 1;
    final int s25 = (input[offset + 2] + input[offset + 5]) >> 1;
    final int d25 = (input[offset + 2] - input[offset + 5]) >> 1;
    final int s34 = (input[offset + 3] + input[offset + 4]) >> 1;
    final int d34 = (input[offset + 3] - input[offset + 4]) >> 1;

    int a0 = ((s07 + s34) - (s25 + s16)) * cos16[4];
    int b3 = (-(s07 + s34) - (s25 + s16)) << 13;
    int a2 = (s07 - s34) * cos16[6] + (s25 - s16) * cos16[2];
    int b1 = (s34 - s07) * cos16[2] + (s25 - s16) * cos16[6];
    int a1 = d07 * cos16[5] - d16 * cos16[1] + d25 * cos16[7] + d34 * cos16[3];
    int b2 = -d07 * cos16[1] - d16 * cos16[3] - d25 * cos16[5] - d34 * cos16[7];
    int a3 = d07 * cos16[7] - d16 * cos16[5] + d25 * cos16[3] - d34 * cos16[1];
    int b0 = -d07 * cos16[3] + d16 * cos16[7] + d25 * cos16[1] + d34 * cos16[5];

    final int shr = 12 + scale;
    a0 = (a0 + (1 << (shr - 1))) >> shr;
    b0 = (b0 + (1 << (shr - 1))) >> shr;
    a1 = (a1 + (1 << (shr - 1))) >> shr;
    b1 = (b1 + (1 << (shr - 1))) >> shr;
    a2 = (a2 + (1 << (shr - 1))) >> shr;
    b2 = (b2 + (1 << (shr - 1))) >> shr;
    a3 = (a3 + (1 << (shr - 1))) >> shr;
    b3 = (b3 + (1 << (shr - 1))) >> shr;

    out0[0][idx] = SbcTables.saturate16(a0);
    out0[7][idx] = SbcTables.saturate16(-a1);
    out0[1][idx] = SbcTables.saturate16(a1);
    out0[6][idx] = SbcTables.saturate16(-a2);
    out0[2][idx] = SbcTables.saturate16(a2);
    out0[5][idx] = SbcTables.saturate16(-a3);
    out0[3][idx] = SbcTables.saturate16(a3);
    out0[4][idx] = SbcTables.saturate16(0);

    out1[0][idx] = SbcTables.saturate16(-a0);
    out1[7][idx] = SbcTables.saturate16(b0);
    out1[1][idx] = SbcTables.saturate16(b0);
    out1[6][idx] = SbcTables.saturate16(b1);
    out1[2][idx] = SbcTables.saturate16(b1);
    out1[5][idx] = SbcTables.saturate16(b2);
    out1[3][idx] = SbcTables.saturate16(b2);
    out1[4][idx] = SbcTables.saturate16(b3);
  }

  void _applyWindow4(List<Int16List> input, int index, Int16List output,
      int offset, int pitch) {
    final List<Int16List> window = SbcDecoderTables.window4;

    for (int i = 0; i < 4; i++) {
      int s = 0;
      for (int j = 0; j < 10; j++) {
        s += input[i][j] * window[i][index + j];
      }

      output[offset + i * pitch] =
          SbcTables.saturate16((s + (1 << 12)) >> 13);
    }
  }

  void _applyWindow8(List<Int16List> input, int index, Int16List output,
      int offset, int pitch) {
    final List<Int16List> window = SbcDecoderTables.window8;

    for (int i = 0; i < 8; i++) {
      int s = 0;
      for (int j = 0; j < 10; j++) {
        s += input[i][j] * window[i][index + j];
      }

      output[offset + i * pitch] =
          SbcTables.saturate16((s + (1 << 12)) >> 13);
    }
  }
}

class _HeaderResult {
  final bool success;
  final int crc;
  _HeaderResult(this.success, this.crc);
}

class _DecoderState {
  int index = 0;

  /// V buffers: [2][maxSubbands][10]
  late final List<List<Int16List>> v;

  _DecoderState() {
    v = List<List<Int16List>>.generate(
      2,
      (_) => List<Int16List>.generate(
        SbcFrame.maxSubbands,
        (_) => Int16List(10),
      ),
    );
  }

  void reset() {
    index = 0;
    for (int odd = 0; odd < 2; odd++) {
      for (int sb = 0; sb < SbcFrame.maxSubbands; sb++) {
        v[odd][sb].fillRange(0, 10, 0);
      }
    }
  }
}
