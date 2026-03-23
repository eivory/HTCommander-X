import 'dart:typed_data';
import '../binary_utils.dart';

/// Radio device information parsed from GAIA GET_DEV_INFO response.
/// Port of HTCommander.Core/radio/RadioDevInfo.cs
class RadioDevInfo {
  final Uint8List raw;
  final int vendorId;
  final int productId;
  final int hwVer;
  final int softVer;
  final bool supportRadio;
  final bool supportMediumPower;
  final bool fixedLocSpeakerVol;
  final bool notSupportSoftPowerCtrl;
  final bool haveNoSpeaker;
  final bool haveHmSpeaker;
  final int regionCount;
  final bool supportNoaa;
  final bool gmrs;
  final bool supportVfo;
  final bool supportDmr;
  final int channelCount;
  final int freqRangeCount;

  RadioDevInfo(Uint8List msg)
      : raw = msg,
        vendorId = msg[5],
        productId = BinaryUtils.getShort(msg, 6),
        hwVer = msg[8],
        softVer = BinaryUtils.getShort(msg, 9),
        supportRadio = (msg[11] & 0x80) != 0,
        supportMediumPower = (msg[11] & 0x40) != 0,
        fixedLocSpeakerVol = (msg[11] & 0x20) != 0,
        notSupportSoftPowerCtrl = (msg[11] & 0x10) != 0,
        haveNoSpeaker = (msg[11] & 0x08) != 0,
        haveHmSpeaker = (msg[11] & 0x04) != 0,
        regionCount = ((msg[11] & 0x03) << 4) + ((msg[12] & 0xF0) >> 4),
        supportNoaa = (msg[12] & 0x08) != 0,
        gmrs = (msg[12] & 0x04) != 0,
        supportVfo = (msg[12] & 0x02) != 0,
        supportDmr = (msg[12] & 0x01) != 0,
        channelCount = msg[13],
        freqRangeCount = _clampFreqRange((msg[14] & 0xF0) >> 4) {
    if (msg.length < 15) {
      throw ArgumentError(
          'RadioDevInfo message too short (need >= 15 bytes)');
    }
  }

  static int _clampFreqRange(int v) => v > 8 ? 8 : v;
}
