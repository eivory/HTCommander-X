import 'dart:convert';
import 'dart:typed_data';

/// Beacon/BSS settings.
/// Port of HTCommander.Core/radio/RadioBssSettings.cs
class RadioBssSettings {
  int maxFwdTimes;
  int timeToLive;
  bool pttReleaseSendLocation;
  bool pttReleaseSendIdInfo;
  bool pttReleaseSendBssUserId;
  bool shouldShareLocation;
  bool sendPwrVoltage;
  int packetFormat;
  bool allowPositionCheck;
  int aprsSsid;
  int locationShareInterval;
  int bssUserIdLower;
  String pttReleaseIdInfo;
  String beaconMessage;
  String aprsSymbol;
  String aprsCallsign;

  RadioBssSettings.fromBytes(Uint8List msg)
      : maxFwdTimes = (msg[5] & 0xF0) >> 4,
        timeToLive = msg[5] & 0x0F,
        pttReleaseSendLocation = (msg[6] & 0x80) != 0,
        pttReleaseSendIdInfo = (msg[6] & 0x40) != 0,
        pttReleaseSendBssUserId = (msg[6] & 0x20) != 0,
        shouldShareLocation = (msg[6] & 0x10) != 0,
        sendPwrVoltage = (msg[6] & 0x08) != 0,
        packetFormat = (msg[6] & 0x04) >> 2,
        allowPositionCheck = (msg[6] & 0x02) != 0,
        aprsSsid = (msg[7] & 0xF0) >> 4,
        locationShareInterval = msg[8] * 10,
        bssUserIdLower = _readInt32LE(msg, 9),
        pttReleaseIdInfo =
            ascii.decode(msg.sublist(13, 25)).replaceAll('\x00', ''),
        beaconMessage =
            ascii.decode(msg.sublist(25, 43)).replaceAll('\x00', ''),
        aprsSymbol =
            ascii.decode(msg.sublist(43, 45)).replaceAll('\x00', ''),
        aprsCallsign =
            ascii.decode(msg.sublist(45, 51)).replaceAll('\x00', '') {
    if (msg.length < 51) {
      throw ArgumentError('Invalid message length');
    }
  }

  /// Read little-endian int32 (matching C# BitConverter.ToInt32).
  static int _readInt32LE(Uint8List data, int offset) {
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  /// Write little-endian int32.
  static void _writeInt32LE(Uint8List data, int offset, int value) {
    data[offset] = value & 0xFF;
    data[offset + 1] = (value >> 8) & 0xFF;
    data[offset + 2] = (value >> 16) & 0xFF;
    data[offset + 3] = (value >> 24) & 0xFF;
  }

  /// Serialize to 46-byte GAIA write format.
  Uint8List toByteArray() {
    final msg = Uint8List(46);
    msg[0] = (maxFwdTimes << 4) | (timeToLive & 0x0F);
    msg[1] = (pttReleaseSendLocation ? 0x80 : 0) |
        (pttReleaseSendIdInfo ? 0x40 : 0) |
        (pttReleaseSendBssUserId ? 0x20 : 0) |
        (shouldShareLocation ? 0x10 : 0) |
        (sendPwrVoltage ? 0x08 : 0) |
        ((packetFormat & 0x01) << 2) |
        (allowPositionCheck ? 0x02 : 0);
    msg[2] = (aprsSsid & 0x0F) << 4;
    msg[3] = locationShareInterval ~/ 10;
    _writeInt32LE(msg, 4, bssUserIdLower);

    _writeAsciiPadded(msg, 8, pttReleaseIdInfo, 12);
    _writeAsciiPadded(msg, 20, beaconMessage, 18);
    _writeAsciiPadded(msg, 38, aprsSymbol, 2);
    _writeAsciiPadded(msg, 40, aprsCallsign, 6);

    return msg;
  }

  static void _writeAsciiPadded(
      Uint8List dest, int offset, String value, int maxLen) {
    final bytes = ascii.encode(value.padRight(maxLen, '\x00'));
    final len = bytes.length > maxLen ? maxLen : bytes.length;
    dest.setRange(offset, offset + len, bytes);
  }
}
