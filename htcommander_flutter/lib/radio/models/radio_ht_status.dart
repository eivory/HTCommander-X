import 'dart:typed_data';
import '../radio_enums.dart';

/// Radio HT status snapshot.
/// Port of HTCommander.Core/radio/RadioHtStatus.cs
class RadioHtStatus {
  Uint8List? raw;

  // First two bytes
  bool isPowerOn;
  bool isInTx;
  bool isSq;
  bool isInRx;
  RadioChannelType doubleChannel;
  bool isScan;
  bool isRadio;
  int currChIdLower;
  bool isGpsLocked;
  bool isHfpConnected;
  bool isAocConnected;
  int channelId;
  String? nameStr;
  int currChId;

  // Extended fields (if msg >= 9 bytes)
  int rssi;
  int currRegion;
  int currChannelIdUpper;

  /// Parse from GAIA response bytes.
  RadioHtStatus.fromBytes(Uint8List msg)
      : raw = msg,
        isPowerOn = (msg[5] & 0x80) != 0,
        isInTx = (msg[5] & 0x40) != 0,
        isSq = (msg[5] & 0x20) != 0,
        isInRx = (msg[5] & 0x10) != 0,
        doubleChannel =
            RadioChannelType.fromValue((msg[5] & 0x0C) >> 2),
        isScan = (msg[5] & 0x02) != 0,
        isRadio = (msg[5] & 0x01) != 0,
        currChIdLower = msg[6] >> 4,
        isGpsLocked = (msg[6] & 0x08) != 0,
        isHfpConnected = (msg[6] & 0x04) != 0,
        isAocConnected = (msg[6] & 0x02) != 0,
        channelId = 0,
        currChId = 0,
        rssi = 0,
        currRegion = 0,
        currChannelIdUpper = 0 {
    if (msg.length < 7) {
      throw ArgumentError(
          'RadioHtStatus message too short (need >= 7 bytes)');
    }

    if (msg.length >= 9) {
      rssi = msg[7] >> 4;
      currRegion = ((msg[7] & 0x0F) << 2) + (msg[8] >> 6);
      currChannelIdUpper = (msg[8] & 0x3C) >> 2;
    }

    currChId = (currChannelIdUpper << 4) + currChIdLower;
  }

  /// Copy constructor.
  RadioHtStatus.copy(RadioHtStatus other)
      : isPowerOn = other.isPowerOn,
        isInTx = other.isInTx,
        isSq = other.isSq,
        isInRx = other.isInRx,
        doubleChannel = other.doubleChannel,
        isScan = other.isScan,
        isRadio = other.isRadio,
        currChIdLower = other.currChIdLower,
        isGpsLocked = other.isGpsLocked,
        isHfpConnected = other.isHfpConnected,
        isAocConnected = other.isAocConnected,
        channelId = other.channelId,
        nameStr = other.nameStr,
        currChId = other.currChId,
        rssi = other.rssi,
        currRegion = other.currRegion,
        currChannelIdUpper = other.currChannelIdUpper;

  /// Serialize to 4-byte format.
  Uint8List toByteArray() {
    final msg = Uint8List(4);
    msg[0] = (isPowerOn ? 0x80 : 0) |
        (isInTx ? 0x40 : 0) |
        (isSq ? 0x20 : 0) |
        (isInRx ? 0x10 : 0) |
        (doubleChannel.value << 2) |
        (isScan ? 0x02 : 0) |
        (isRadio ? 0x01 : 0);
    msg[1] = (currChIdLower << 4) |
        (isGpsLocked ? 0x08 : 0) |
        (isHfpConnected ? 0x04 : 0) |
        (isAocConnected ? 0x02 : 0);
    msg[2] = (rssi << 4) | ((currRegion >> 2) & 0x0F);
    msg[3] = ((currRegion & 0x03) << 6) | ((currChannelIdUpper << 2) & 0x3C);
    return msg;
  }
}
