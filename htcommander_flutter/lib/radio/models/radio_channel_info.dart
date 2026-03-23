import 'dart:convert';
import 'dart:typed_data';
import '../binary_utils.dart';
import '../radio_enums.dart';

/// Radio channel configuration.
/// Port of HTCommander.Core/radio/RadioChannelInfo.cs
class RadioChannelInfo {
  Uint8List? raw;
  int channelId;
  RadioModulationType txMod;
  int txFreq;
  RadioModulationType rxMod;
  int rxFreq;
  int txSubAudio;
  int rxSubAudio;
  bool scan;
  bool txAtMaxPower;
  bool talkAround;
  RadioBandwidthType bandwidth;
  bool preDeEmphBypass;
  bool sign;
  bool txAtMedPower;
  bool txDisable;
  bool fixedFreq;
  bool fixedBandwidth;
  bool fixedTxPower;
  bool mute;
  String nameStr;

  /// Default constructor for empty channels.
  RadioChannelInfo()
      : channelId = 0,
        txMod = RadioModulationType.fm,
        txFreq = 0,
        rxMod = RadioModulationType.fm,
        rxFreq = 0,
        txSubAudio = 0,
        rxSubAudio = 0,
        scan = false,
        txAtMaxPower = false,
        talkAround = false,
        bandwidth = RadioBandwidthType.narrow,
        preDeEmphBypass = false,
        sign = false,
        txAtMedPower = false,
        txDisable = false,
        fixedFreq = false,
        fixedBandwidth = false,
        fixedTxPower = false,
        mute = false,
        nameStr = '';

  /// Parse from GAIA response bytes.
  RadioChannelInfo.fromBytes(Uint8List msg)
      : raw = msg,
        channelId = msg[5],
        txMod = RadioModulationType.fromValue(msg[6] >> 6),
        txFreq = BinaryUtils.getInt(msg, 6) & 0x3FFFFFFF,
        rxMod = RadioModulationType.fromValue(msg[10] >> 6),
        rxFreq = BinaryUtils.getInt(msg, 10) & 0x3FFFFFFF,
        txSubAudio = BinaryUtils.getShort(msg, 14),
        rxSubAudio = BinaryUtils.getShort(msg, 16),
        scan = (msg[18] & 0x80) != 0,
        txAtMaxPower = (msg[18] & 0x40) != 0,
        talkAround = (msg[18] & 0x20) != 0,
        bandwidth = (msg[18] & 0x10) != 0
            ? RadioBandwidthType.wide
            : RadioBandwidthType.narrow,
        preDeEmphBypass = (msg[18] & 0x08) != 0,
        sign = (msg[18] & 0x04) != 0,
        txAtMedPower = (msg[18] & 0x02) != 0,
        txDisable = (msg[18] & 0x01) != 0,
        fixedFreq = (msg[19] & 0x80) != 0,
        fixedBandwidth = (msg[19] & 0x40) != 0,
        fixedTxPower = (msg[19] & 0x20) != 0,
        mute = (msg[19] & 0x10) != 0,
        nameStr = _parseName(msg) {
    if (msg.length < 30) {
      throw ArgumentError(
          'RadioChannelInfo message too short (need >= 30 bytes)');
    }
  }

  /// Copy constructor.
  RadioChannelInfo.copy(RadioChannelInfo other)
      : channelId = other.channelId,
        txMod = other.txMod,
        txFreq = other.txFreq,
        rxMod = other.rxMod,
        rxFreq = other.rxFreq,
        txSubAudio = other.txSubAudio,
        rxSubAudio = other.rxSubAudio,
        scan = other.scan,
        txAtMaxPower = other.txAtMaxPower,
        talkAround = other.talkAround,
        bandwidth = other.bandwidth,
        preDeEmphBypass = other.preDeEmphBypass,
        sign = other.sign,
        txAtMedPower = other.txAtMedPower,
        txDisable = other.txDisable,
        fixedFreq = other.fixedFreq,
        fixedBandwidth = other.fixedBandwidth,
        fixedTxPower = other.fixedTxPower,
        mute = other.mute,
        nameStr = other.nameStr;

  static String _parseName(Uint8List msg) {
    final nameBytes = msg.sublist(20, 30);
    var name = utf8.decode(nameBytes, allowMalformed: true).trim();
    final nullIdx = name.indexOf('\x00');
    if (nullIdx >= 0) name = name.substring(0, nullIdx);
    return name;
  }

  /// Serialize to 25-byte GAIA write format.
  Uint8List toByteArray() {
    final r = Uint8List(25);
    r[0] = channelId;
    BinaryUtils.setInt(r, 1, txFreq);
    r[1] = r[1] | ((txMod.value & 0x03) << 6);
    BinaryUtils.setInt(r, 5, rxFreq);
    r[5] = r[5] | ((rxMod.value & 0x03) << 6);
    BinaryUtils.setShort(r, 9, txSubAudio);
    BinaryUtils.setShort(r, 11, rxSubAudio);

    if (scan) r[13] |= 0x80;
    if (txAtMaxPower) r[13] |= 0x40;
    if (talkAround) r[13] |= 0x20;
    if (bandwidth == RadioBandwidthType.wide) r[13] |= 0x10;
    if (preDeEmphBypass) r[13] |= 0x08;
    if (sign) r[13] |= 0x04;
    if (txAtMedPower) r[13] |= 0x02;
    if (txDisable) r[13] |= 0x01;
    if (fixedFreq) r[14] |= 0x80;
    if (fixedBandwidth) r[14] |= 0x40;
    if (fixedTxPower) r[14] |= 0x20;
    if (mute) r[14] |= 0x10;

    final nameBytes = utf8.encode(nameStr);
    final nameLen = nameBytes.length > 10 ? 10 : nameBytes.length;
    r.setRange(15, 15 + nameLen, nameBytes);

    return r;
  }

  @override
  bool operator ==(Object other) {
    if (other is! RadioChannelInfo) return false;
    return channelId == other.channelId &&
        txMod == other.txMod &&
        txFreq == other.txFreq &&
        rxMod == other.rxMod &&
        rxFreq == other.rxFreq &&
        txSubAudio == other.txSubAudio &&
        rxSubAudio == other.rxSubAudio &&
        scan == other.scan &&
        txAtMaxPower == other.txAtMaxPower &&
        talkAround == other.talkAround &&
        bandwidth == other.bandwidth &&
        preDeEmphBypass == other.preDeEmphBypass &&
        sign == other.sign &&
        txAtMedPower == other.txAtMedPower &&
        txDisable == other.txDisable &&
        fixedFreq == other.fixedFreq &&
        fixedBandwidth == other.fixedBandwidth &&
        fixedTxPower == other.fixedTxPower &&
        mute == other.mute &&
        nameStr == other.nameStr;
  }

  @override
  int get hashCode => Object.hash(
        channelId, txMod, txFreq, rxMod, rxFreq,
        txSubAudio, rxSubAudio, scan, txAtMaxPower, talkAround,
        bandwidth, preDeEmphBypass, sign, txAtMedPower, txDisable,
        fixedFreq, fixedBandwidth, fixedTxPower, mute, nameStr,
      );
}
