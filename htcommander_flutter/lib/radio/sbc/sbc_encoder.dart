// Copyright 2026 Ylian Saint-Hilaire
// Licensed under the Apache License, Version 2.0 (the "License");
// http://www.apache.org/licenses/LICENSE-2.0

import 'dart:typed_data';

import 'sbc_bit_stream.dart';
import 'sbc_encoder_tables.dart';
import 'sbc_enums.dart';
import 'sbc_frame.dart';
import 'sbc_tables.dart';

/// SBC audio encoder - converts PCM samples to SBC frames.
class SbcEncoder {
  final List<_EncoderState> _channelStates;

  SbcEncoder()
      : _channelStates = <_EncoderState>[_EncoderState(), _EncoderState()] {
    reset();
  }

  /// Reset encoder state.
  void reset() {
    _channelStates[0].reset();
    _channelStates[1].reset();
  }

  /// Encode PCM samples to an SBC frame.
  ///
  /// [pcmLeft] is the input PCM samples for the left channel.
  /// [pcmRight] is the input PCM samples for the right channel (null for mono).
  /// [frame] is the frame configuration parameters.
  /// Returns encoded SBC frame data, or null on error.
  Uint8List? encode(Int16List pcmLeft, Int16List? pcmRight, SbcFrame frame) {
    // Override with mSBC if signaled
    SbcFrame activeFrame = frame;
    if (activeFrame.isMsbc) {
      activeFrame = SbcFrame.createMsbc();
    }

    // Validate frame
    if (!activeFrame.isValid()) return null;

    final int frameSize = activeFrame.getFrameSize();
    final int samplesPerChannel = activeFrame.blocks * activeFrame.subbands;

    if (pcmLeft.length < samplesPerChannel) return null;

    if (activeFrame.mode != SbcMode.mono &&
        (pcmRight == null || pcmRight.length < samplesPerChannel)) {
      return null;
    }

    // Analyze PCM to subband samples
    final List<Int16List> sbSamples = <Int16List>[
      Int16List(SbcFrame.maxSamples),
      Int16List(SbcFrame.maxSamples),
    ];

    _analyze(_channelStates[0], activeFrame, pcmLeft, 1, sbSamples[0]);
    if (activeFrame.mode != SbcMode.mono && pcmRight != null) {
      _analyze(_channelStates[1], activeFrame, pcmRight, 1, sbSamples[1]);
    }

    // Allocate output buffer
    final Uint8List output = Uint8List(frameSize);

    // Encode frame data
    final SbcBitStream dataBits =
        SbcBitStream(output, frameSize, isReader: false);
    dataBits.putBits(0, SbcFrame.headerSize * 8); // Reserve space for header

    _encodeFrameData(dataBits, activeFrame, sbSamples);
    dataBits.flush();

    if (dataBits.hasError) return null;

    // Encode header
    final SbcBitStream headerBits =
        SbcBitStream(output, SbcFrame.headerSize, isReader: false);
    _encodeHeader(headerBits, activeFrame);
    headerBits.flush();

    if (headerBits.hasError) return null;

    // Compute and set CRC
    final int crc = SbcTables.computeCrc(activeFrame, output, frameSize);
    if (crc < 0) return null;

    output[3] = crc & 0xFF;

    return output;
  }

  void _encodeHeader(SbcBitStream bits, SbcFrame frame) {
    bits.putBits(frame.isMsbc ? 0xad : 0x9c, 8);

    if (!frame.isMsbc) {
      bits.putBits(frame.frequency.index, 2);
      bits.putBits((frame.blocks >> 2) - 1, 2);
      bits.putBits(frame.mode.index, 2);
      bits.putBits(frame.allocationMethod.index, 1);
      bits.putBits((frame.subbands >> 2) - 1, 1);
      bits.putBits(frame.bitpool, 8);
    } else {
      bits.putBits(0, 16); // reserved
    }

    bits.putBits(0, 8); // CRC placeholder
  }

  void _encodeFrameData(
      SbcBitStream bits, SbcFrame frame, List<Int16List> sbSamples) {
    final int nchannels = frame.mode != SbcMode.mono ? 2 : 1;
    final int nsubbands = frame.subbands;

    // Compute scale factors
    final List<Int32List> scaleFactors = <Int32List>[
      Int32List(SbcFrame.maxSubbands),
      Int32List(SbcFrame.maxSubbands),
    ];
    int mjoint = 0;

    if (frame.mode == SbcMode.jointStereo) {
      mjoint = _computeScaleFactorsJointStereo(frame, sbSamples, scaleFactors);
    } else {
      _computeScaleFactors(frame, sbSamples, scaleFactors);
    }

    if (frame.mode == SbcMode.dualChannel) {
      final List<Int16List> sbSamples1 = <Int16List>[sbSamples[1]];
      final List<Int32List> scaleFactors1 = <Int32List>[scaleFactors[1]];
      _computeScaleFactors(frame, sbSamples1, scaleFactors1);
    }

    // Write joint stereo mask
    if (frame.mode == SbcMode.jointStereo) {
      if (nsubbands == 4) {
        final int v = ((mjoint & 0x01) << 3) |
            ((mjoint & 0x02) << 1) |
            ((mjoint & 0x04) >> 1) |
            ((0x00) >> 3);
        bits.putBits(v, 4);
      } else {
        final int v = ((mjoint & 0x01) << 7) |
            ((mjoint & 0x02) << 5) |
            ((mjoint & 0x04) << 3) |
            ((mjoint & 0x08) << 1) |
            ((mjoint & 0x10) >> 1) |
            ((mjoint & 0x20) >> 3) |
            ((mjoint & 0x40) >> 5) |
            ((0x00) >> 7);
        bits.putBits(v, 8);
      }
    }

    // Write scale factors
    for (int ch = 0; ch < nchannels; ch++) {
      for (int sb = 0; sb < nsubbands; sb++) {
        bits.putBits(scaleFactors[ch][sb], 4);
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

    // Apply joint stereo coupling
    for (int sb = 0; sb < nsubbands; sb++) {
      if (((mjoint >> sb) & 1) == 0) continue;

      for (int blk = 0; blk < frame.blocks; blk++) {
        final int idx = blk * nsubbands + sb;
        final int s0 = sbSamples[0][idx];
        final int s1 = sbSamples[1][idx];
        sbSamples[0][idx] = SbcTables.saturate16((s0 + s1) >> 1);
        sbSamples[1][idx] = SbcTables.saturate16((s0 - s1) >> 1);
      }
    }

    // Quantize and write samples
    for (int blk = 0; blk < frame.blocks; blk++) {
      for (int ch = 0; ch < nchannels; ch++) {
        for (int sb = 0; sb < nsubbands; sb++) {
          final int nbit = nbits[ch][sb];
          if (nbit == 0) continue;

          final int scf = scaleFactors[ch][sb];
          final int idx = blk * nsubbands + sb;
          final int sample = sbSamples[ch][idx];
          final int range = (1 << nbit) - 1;

          final int quantized =
              (((sample * range) >> (scf + 1)) + range) >> 1;
          bits.putBits(quantized & ((1 << nbit) - 1), nbit);
        }
      }
    }

    // Write padding
    final int paddingBits = 8 - (bits.bitPosition % 8);
    if (paddingBits < 8) {
      bits.putBits(0, paddingBits);
    }
  }

  int _computeScaleFactorsJointStereo(SbcFrame frame,
      List<Int16List> sbSamples, List<Int32List> scaleFactors) {
    int mjoint = 0;

    for (int sb = 0; sb < frame.subbands; sb++) {
      int m0 = 0, m1 = 0;
      int mj0 = 0, mj1 = 0;

      for (int blk = 0; blk < frame.blocks; blk++) {
        final int idx = blk * frame.subbands + sb;
        final int s0 = sbSamples[0][idx];
        final int s1 = sbSamples[1][idx];

        final int abs0 = s0 < 0 ? -s0 : s0;
        final int abs1 = s1 < 0 ? -s1 : s1;
        m0 |= abs0;
        m1 |= abs1;

        final int sum = s0 + s1;
        final int diff = s0 - s1;
        final int absSum = sum < 0 ? -sum : sum;
        final int absDiff = diff < 0 ? -diff : diff;
        mj0 |= absSum;
        mj1 |= absDiff;
      }

      int scf0 = m0 != 0 ? 31 - SbcTables.countLeadingZeros(m0) : 0;
      int scf1 = m1 != 0 ? 31 - SbcTables.countLeadingZeros(m1) : 0;

      final int js0 = mj0 != 0 ? 31 - SbcTables.countLeadingZeros(mj0) : 0;
      final int js1 = mj1 != 0 ? 31 - SbcTables.countLeadingZeros(mj1) : 0;

      if (sb < frame.subbands - 1 && js0 + js1 < scf0 + scf1) {
        mjoint |= 1 << sb;
        scf0 = js0;
        scf1 = js1;
      }

      scaleFactors[0][sb] = scf0;
      scaleFactors[1][sb] = scf1;
    }

    return mjoint;
  }

  void _computeScaleFactors(
      SbcFrame frame, List<Int16List> sbSamples, List<Int32List> scaleFactors) {
    final int nchannels = frame.mode != SbcMode.mono ? 2 : 1;

    for (int ch = 0; ch < nchannels; ch++) {
      for (int sb = 0; sb < frame.subbands; sb++) {
        int m = 0;

        for (int blk = 0; blk < frame.blocks; blk++) {
          final int idx = blk * frame.subbands + sb;
          final int sample = sbSamples[ch][idx];
          final int abs = sample < 0 ? -sample : sample;
          m |= abs;
        }

        final int scf = m != 0 ? 31 - SbcTables.countLeadingZeros(m) : 0;
        scaleFactors[ch][sb] = scf;
      }
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

  void _analyze(_EncoderState state, SbcFrame frame, Int16List input,
      int pitch, Int16List output) {
    for (int blk = 0; blk < frame.blocks; blk++) {
      final int inOffset = blk * frame.subbands * pitch;
      final int outOffset = blk * frame.subbands;

      if (frame.subbands == 4) {
        _analyze4(state, input, inOffset, pitch, output, outOffset);
      } else {
        _analyze8(state, input, inOffset, pitch, output, outOffset);
      }
    }
  }

  void _analyze4(_EncoderState state, Int16List input, int inOffset, int pitch,
      Int16List output, int outOffset) {
    final List<Int16List> window = SbcEncoderTables.window4;
    final Int16List cos8 = SbcTables.cos8;

    final int idx = state.index >> 1;
    final int odd = state.index & 1;
    final int inIdx = idx != 0 ? 5 - idx : 0;

    // Load PCM samples into circular buffer (check bounds)
    state.x[odd][0][inIdx] = inOffset + 3 * pitch < input.length
        ? input[inOffset + 3 * pitch]
        : 0;
    state.x[odd][1][inIdx] = inOffset + 1 * pitch < input.length
        ? input[inOffset + 1 * pitch]
        : 0;
    state.x[odd][2][inIdx] = inOffset + 2 * pitch < input.length
        ? input[inOffset + 2 * pitch]
        : 0;
    state.x[odd][3][inIdx] = inOffset + 0 * pitch < input.length
        ? input[inOffset + 0 * pitch]
        : 0;

    // Apply window and process
    int y0 = 0, y1 = 0, y3 = 0;

    for (int j = 0; j < 5; j++) {
      y0 += state.x[odd][0][j] * window[0][idx + j];
      y1 += state.x[odd][2][j] * window[2][idx + j] +
          state.x[odd][3][j] * window[3][idx + j];
      y3 += state.x[odd][1][j] * window[1][idx + j];
    }

    y0 += state.y[0];
    state.y[0] = 0;
    for (int j = 0; j < 5; j++) {
      state.y[0] += state.x[odd][0][j] * window[0][idx + 5 + j];
    }

    int y2 = state.y[1];
    state.y[1] = 0;
    for (int j = 0; j < 5; j++) {
      state.y[1] += state.x[odd][2][j] * window[2][idx + 5 + j] -
          state.x[odd][3][j] * window[3][idx + 5 + j];
    }

    for (int j = 0; j < 5; j++) {
      y3 += state.x[odd][1][j] * window[1][idx + 5 + j];
    }

    final Int16List yArr = Int16List(4);
    yArr[0] = SbcTables.saturate16((y0 + (1 << 14)) >> 15);
    yArr[1] = SbcTables.saturate16((y1 + (1 << 14)) >> 15);
    yArr[2] = SbcTables.saturate16((y2 + (1 << 14)) >> 15);
    yArr[3] = SbcTables.saturate16((y3 + (1 << 14)) >> 15);

    state.index = state.index < 9 ? state.index + 1 : 0;

    // DCT to get subband samples
    final int s0 =
        yArr[0] * cos8[2] + yArr[1] * cos8[1] + yArr[2] * cos8[3] + (yArr[3] << 13);
    final int s1 =
        -yArr[0] * cos8[2] + yArr[1] * cos8[3] - yArr[2] * cos8[1] + (yArr[3] << 13);
    final int s2 =
        -yArr[0] * cos8[2] - yArr[1] * cos8[3] + yArr[2] * cos8[1] + (yArr[3] << 13);
    final int s3 =
        yArr[0] * cos8[2] - yArr[1] * cos8[1] - yArr[2] * cos8[3] + (yArr[3] << 13);

    output[outOffset + 0] = SbcTables.saturate16((s0 + (1 << 12)) >> 13);
    output[outOffset + 1] = SbcTables.saturate16((s1 + (1 << 12)) >> 13);
    output[outOffset + 2] = SbcTables.saturate16((s2 + (1 << 12)) >> 13);
    output[outOffset + 3] = SbcTables.saturate16((s3 + (1 << 12)) >> 13);
  }

  void _analyze8(_EncoderState state, Int16List input, int inOffset, int pitch,
      Int16List output, int outOffset) {
    final List<Int16List> window = SbcEncoderTables.window8;
    final List<Int16List> cosmat = SbcEncoderTables.cosMatrix8;

    final int idx = state.index >> 1;
    final int odd = state.index & 1;
    final int inIdx = idx != 0 ? 5 - idx : 0;

    // Load PCM samples into circular buffer
    final int maxIdx = input.length;
    state.x[odd][0][inIdx] =
        inOffset + 7 * pitch < maxIdx ? input[inOffset + 7 * pitch] : 0;
    state.x[odd][1][inIdx] =
        inOffset + 3 * pitch < maxIdx ? input[inOffset + 3 * pitch] : 0;
    state.x[odd][2][inIdx] =
        inOffset + 6 * pitch < maxIdx ? input[inOffset + 6 * pitch] : 0;
    state.x[odd][3][inIdx] =
        inOffset + 0 * pitch < maxIdx ? input[inOffset + 0 * pitch] : 0;
    state.x[odd][4][inIdx] =
        inOffset + 5 * pitch < maxIdx ? input[inOffset + 5 * pitch] : 0;
    state.x[odd][5][inIdx] =
        inOffset + 1 * pitch < maxIdx ? input[inOffset + 1 * pitch] : 0;
    state.x[odd][6][inIdx] =
        inOffset + 4 * pitch < maxIdx ? input[inOffset + 4 * pitch] : 0;
    state.x[odd][7][inIdx] =
        inOffset + 2 * pitch < maxIdx ? input[inOffset + 2 * pitch] : 0;

    // Apply window and process
    final Int32List yTemp = Int32List(8);

    for (int i = 0; i < 8; i++) {
      yTemp[i] = 0;
      for (int j = 0; j < 5; j++) {
        yTemp[i] += state.x[odd][i][j] * window[i][idx + j];
      }
    }

    int y0 = yTemp[0] + state.y[0];
    final int y1 = yTemp[2] + yTemp[3];
    final int y2 = yTemp[4] + yTemp[5];
    final int y3 = yTemp[6] + yTemp[7];
    int y4 = state.y[1];
    int y5 = state.y[2];
    int y6 = state.y[3];
    int y7 = yTemp[1];

    state.y[0] = 0;
    state.y[1] = 0;
    state.y[2] = 0;
    state.y[3] = 0;
    for (int j = 0; j < 5; j++) {
      state.y[0] += state.x[odd][0][j] * window[0][idx + 5 + j];
      state.y[1] += state.x[odd][2][j] * window[2][idx + 5 + j] -
          state.x[odd][3][j] * window[3][idx + 5 + j];
      state.y[2] += state.x[odd][4][j] * window[4][idx + 5 + j] -
          state.x[odd][5][j] * window[5][idx + 5 + j];
      state.y[3] += state.x[odd][6][j] * window[6][idx + 5 + j] -
          state.x[odd][7][j] * window[7][idx + 5 + j];
      y7 += state.x[odd][1][j] * window[1][idx + 5 + j];
    }

    final Int16List yArr = Int16List(8);
    yArr[0] = SbcTables.saturate16((y0 + (1 << 14)) >> 15);
    yArr[1] = SbcTables.saturate16((y1 + (1 << 14)) >> 15);
    yArr[2] = SbcTables.saturate16((y2 + (1 << 14)) >> 15);
    yArr[3] = SbcTables.saturate16((y3 + (1 << 14)) >> 15);
    yArr[4] = SbcTables.saturate16((y4 + (1 << 14)) >> 15);
    yArr[5] = SbcTables.saturate16((y5 + (1 << 14)) >> 15);
    yArr[6] = SbcTables.saturate16((y6 + (1 << 14)) >> 15);
    yArr[7] = SbcTables.saturate16((y7 + (1 << 14)) >> 15);

    state.index = state.index < 9 ? state.index + 1 : 0;

    // Apply cosine matrix to get subband samples
    for (int i = 0; i < 8; i++) {
      int s = 0;
      for (int j = 0; j < 8; j++) {
        s += yArr[j] * cosmat[i][j];
      }
      output[outOffset + i] = SbcTables.saturate16((s + (1 << 12)) >> 13);
    }
  }
}

class _EncoderState {
  int index = 0;

  /// X buffers: [2][maxSubbands][5]
  late final List<List<Int16List>> x;

  /// Y accumulator: [4]
  late final Int32List y;

  _EncoderState() {
    x = List<List<Int16List>>.generate(
      2,
      (_) => List<Int16List>.generate(
        SbcFrame.maxSubbands,
        (_) => Int16List(5),
      ),
    );
    y = Int32List(4);
  }

  void reset() {
    index = 0;
    for (int odd = 0; odd < 2; odd++) {
      for (int sb = 0; sb < SbcFrame.maxSubbands; sb++) {
        x[odd][sb].fillRange(0, 5, 0);
      }
    }
    y.fillRange(0, 4, 0);
  }
}
