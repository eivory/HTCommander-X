/*
SSTV Demodulator
Ported to Dart from https://github.com/xdsopl/robot36
*/

import 'complex.dart';
import 'dsp_utils.dart';
import 'filter.dart';

enum SyncPulseWidth {
  fiveMilliSeconds,
  nineMilliSeconds,
  twentyMilliSeconds,
}

class Demodulator {
  final SimpleMovingAverage _syncPulseFilter;
  final ComplexConvolution _baseBandLowPass;
  final FrequencyModulation _frequencyModulation;
  final SchmittTrigger _syncPulseTrigger;
  final Phasor _baseBandOscillator;
  final Delay _syncPulseValueDelay;
  final double _syncPulseFrequencyValue;
  final double _syncPulseFrequencyTolerance;
  final int _syncPulse5msMinSamples;
  final int _syncPulse5msMaxSamples;
  final int _syncPulse9msMaxSamples;
  final int _syncPulse20msMaxSamples;
  final int _syncPulseFilterDelay;
  int _syncPulseCounter = 0;
  Complex _baseBand = Complex();

  SyncPulseWidth syncPulseWidthValue = SyncPulseWidth.fiveMilliSeconds;
  int syncPulseOffset = 0;
  double frequencyOffset = 0;

  static const double syncPulseFrequency = 1200;
  static const double blackFrequency = 1500;
  static const double whiteFrequency = 2300;

  // Static helpers for initializer list computation
  static const double _lowestFrequency = 1000;
  static const double _highestFrequency = 2800;
  static const double _centerFreq = (_lowestFrequency + _highestFrequency) / 2;
  static const double _bandwidth = whiteFrequency - blackFrequency;
  static const double _syncPorchFreq = 1500.0;

  static double _normFreq(double frequency) {
    return (frequency - _centerFreq) * 2 / _bandwidth;
  }

  Demodulator(int sampleRate)
      : _frequencyModulation = FrequencyModulation(_bandwidth, sampleRate.toDouble()),
        _syncPulse5msMinSamples = (0.005 / 2 * sampleRate).round(),
        _syncPulse5msMaxSamples = (((0.005 + 0.009) / 2) * sampleRate).round(),
        _syncPulse9msMaxSamples = (((0.009 + 0.020) / 2) * sampleRate).round(),
        _syncPulse20msMaxSamples = ((0.020 + 0.005) * sampleRate).round(),
        _syncPulseFilterDelay = (((0.005 / 2 * sampleRate).round() | 1) - 1) ~/ 2,
        _syncPulseFilter = SimpleMovingAverage((0.005 / 2 * sampleRate).round() | 1),
        _syncPulseValueDelay = Delay((0.005 / 2 * sampleRate).round() | 1),
        _baseBandLowPass = ComplexConvolution((0.002 * sampleRate).round() | 1),
        _baseBandOscillator = Phasor(-_centerFreq, sampleRate.toDouble()),
        _syncPulseFrequencyValue = _normFreq(syncPulseFrequency),
        _syncPulseFrequencyTolerance = 50 * 2 / _bandwidth,
        _syncPulseTrigger = SchmittTrigger(
          _normFreq((syncPulseFrequency + (syncPulseFrequency + _syncPorchFreq) / 2) / 2),
          _normFreq((syncPulseFrequency + _syncPorchFreq) / 2),
        ) {
    final kaiser = Kaiser();
    final cutoffFrequency = (_highestFrequency - _lowestFrequency) / 2;
    for (int i = 0; i < _baseBandLowPass.length; ++i) {
      _baseBandLowPass.taps[i] =
          kaiser.window(2.0, i, _baseBandLowPass.length) *
          Filter.lowPass(cutoffFrequency, sampleRate.toDouble(), i, _baseBandLowPass.length);
    }
  }

  bool process(List<double> buffer, int channelSelect) {
    bool syncPulseDetected = false;
    final channels = channelSelect > 0 ? 2 : 1;
    for (int i = 0; i < buffer.length ~/ channels; ++i) {
      switch (channelSelect) {
        case 1:
          _baseBand.setValues(buffer[2 * i]);
          break;
        case 2:
          _baseBand.setValues(buffer[2 * i + 1]);
          break;
        case 3:
          _baseBand.setValues(buffer[2 * i] + buffer[2 * i + 1]);
          break;
        case 4:
          _baseBand.setValues(buffer[2 * i], buffer[2 * i + 1]);
          break;
        default:
          _baseBand.setValues(buffer[i]);
          break;
      }
      _baseBand = _baseBandLowPass.push(_baseBand.mul(_baseBandOscillator.rotate()));
      final frequencyValue = _frequencyModulation.demod(_baseBand);
      final syncPulseValue = _syncPulseFilter.avg(frequencyValue);
      final syncPulseDelayedValue = _syncPulseValueDelay.push(syncPulseValue);
      buffer[i] = frequencyValue;
      if (!_syncPulseTrigger.latch(syncPulseValue)) {
        ++_syncPulseCounter;
      } else if (_syncPulseCounter < _syncPulse5msMinSamples ||
          _syncPulseCounter > _syncPulse20msMaxSamples ||
          (syncPulseDelayedValue - _syncPulseFrequencyValue).abs() > _syncPulseFrequencyTolerance) {
        _syncPulseCounter = 0;
      } else {
        if (_syncPulseCounter < _syncPulse5msMaxSamples) {
          syncPulseWidthValue = SyncPulseWidth.fiveMilliSeconds;
        } else if (_syncPulseCounter < _syncPulse9msMaxSamples) {
          syncPulseWidthValue = SyncPulseWidth.nineMilliSeconds;
        } else {
          syncPulseWidthValue = SyncPulseWidth.twentyMilliSeconds;
        }
        syncPulseOffset = i - _syncPulseFilterDelay;
        frequencyOffset = syncPulseDelayedValue - _syncPulseFrequencyValue;
        syncPulseDetected = true;
        _syncPulseCounter = 0;
      }
    }
    return syncPulseDetected;
  }
}
