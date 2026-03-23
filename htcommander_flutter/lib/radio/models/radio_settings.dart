import 'dart:typed_data';
import '../binary_utils.dart';

/// Radio-wide settings parsed from GAIA READ_SETTINGS response.
/// Port of HTCommander.Core/radio/RadioSettings.cs
class RadioSettings {
  Uint8List rawData;
  int channelA;
  int channelB;
  bool scan;
  bool aghfpCallMode;
  int doubleChannel;
  int squelchLevel; // 0-9
  bool tailElim;
  bool autoRelayEn;
  bool autoPowerOn;
  bool keepAghfpLink;
  int micGain;
  int txHoldTime;
  int txTimeLimit;
  int localSpeaker; // 0-3
  int btMicGain; // 0-7
  bool adaptiveResponse;
  bool disTone;
  bool powerSavingMode;
  int autoPowerOff; // 0-8
  int autoShareLocCh; // 5 bits
  int hmSpeaker; // 2 bits
  int positioningSystem; // 4 bits
  int timeOffset; // 6 bits
  bool useFreqRange2;
  bool pttLock;
  bool leadingSyncBitEn;
  bool pairingAtPowerOn;
  int screenTimeout; // 5 bits
  int vfoX; // 2 bits
  bool imperialUnit;
  int wxMode; // 2 bits
  int noaaCh; // 4 bits
  int vfo1TxPowerX; // 2 bits
  int vfo2TxPowerX; // 2 bits
  bool disDigitalMute;
  bool signalingEccEn;
  bool chDataLock;
  int vfo1ModFreqX; // 4 bytes
  int vfo2ModFreqX; // 4 bytes

  /// Parse from GAIA response bytes.
  RadioSettings.fromBytes(Uint8List msg)
      : rawData = msg,
        channelA = ((msg[5] & 0xF0) >> 4) + (msg[14] & 0xF0),
        channelB = (msg[5] & 0x0F) + ((msg[14] & 0x0F) << 4),
        scan = (msg[6] & 0x80) != 0,
        aghfpCallMode = (msg[6] & 0x40) != 0,
        doubleChannel = (msg[6] & 0x30) >> 4,
        squelchLevel = msg[6] & 0x0F,
        tailElim = (msg[7] & 0x80) != 0,
        autoRelayEn = (msg[7] & 0x40) != 0,
        autoPowerOn = (msg[7] & 0x20) != 0,
        keepAghfpLink = (msg[7] & 0x10) != 0,
        micGain = (msg[7] & 0x0E) >> 1,
        txHoldTime = ((msg[7] & 0x01) << 4) + ((msg[8] & 0xE0) >> 4),
        txTimeLimit = msg[8] & 0x1F,
        localSpeaker = msg[9] >> 6,
        btMicGain = (msg[9] & 0x38) >> 3,
        adaptiveResponse = (msg[9] & 0x04) != 0,
        disTone = (msg[9] & 0x02) != 0,
        powerSavingMode = (msg[9] & 0x01) != 0,
        autoPowerOff = msg[10] >> 4,
        autoShareLocCh = msg[10] & 0x1F,
        hmSpeaker = msg[11] >> 6,
        positioningSystem = (msg[11] & 0x3C) >> 2,
        timeOffset = ((msg[11] & 0x03) << 4) + ((msg[12] & 0xF0) >> 4),
        useFreqRange2 = (msg[12] & 0x08) != 0,
        pttLock = (msg[12] & 0x04) != 0,
        leadingSyncBitEn = (msg[12] & 0x02) != 0,
        pairingAtPowerOn = (msg[12] & 0x01) != 0,
        screenTimeout = msg[13] >> 3,
        vfoX = (msg[13] & 0x06) >> 1,
        imperialUnit = (msg[13] & 0x01) != 0,
        wxMode = msg[15] >> 6,
        noaaCh = (msg[15] & 0x3C) >> 2,
        vfo1TxPowerX = msg[15] & 0x03,
        vfo2TxPowerX = msg[16] >> 6,
        disDigitalMute = (msg[16] & 0x20) != 0,
        signalingEccEn = (msg[16] & 0x10) != 0,
        chDataLock = (msg[16] & 0x08) != 0,
        vfo1ModFreqX = BinaryUtils.getInt(msg, 17),
        vfo2ModFreqX = BinaryUtils.getInt(msg, 21) {
    if (msg.length < 25) {
      throw ArgumentError(
          'RadioSettings message too short (need >= 25 bytes)');
    }
  }

  /// Copy constructor.
  RadioSettings.copy(RadioSettings other)
      : rawData = other.rawData,
        channelA = other.channelA,
        channelB = other.channelB,
        scan = other.scan,
        aghfpCallMode = other.aghfpCallMode,
        doubleChannel = other.doubleChannel,
        squelchLevel = other.squelchLevel,
        tailElim = other.tailElim,
        autoRelayEn = other.autoRelayEn,
        autoPowerOn = other.autoPowerOn,
        keepAghfpLink = other.keepAghfpLink,
        micGain = other.micGain,
        txHoldTime = other.txHoldTime,
        txTimeLimit = other.txTimeLimit,
        localSpeaker = other.localSpeaker,
        btMicGain = other.btMicGain,
        adaptiveResponse = other.adaptiveResponse,
        disTone = other.disTone,
        powerSavingMode = other.powerSavingMode,
        autoPowerOff = other.autoPowerOff,
        autoShareLocCh = other.autoShareLocCh,
        hmSpeaker = other.hmSpeaker,
        positioningSystem = other.positioningSystem,
        timeOffset = other.timeOffset,
        useFreqRange2 = other.useFreqRange2,
        pttLock = other.pttLock,
        leadingSyncBitEn = other.leadingSyncBitEn,
        pairingAtPowerOn = other.pairingAtPowerOn,
        screenTimeout = other.screenTimeout,
        vfoX = other.vfoX,
        imperialUnit = other.imperialUnit,
        wxMode = other.wxMode,
        noaaCh = other.noaaCh,
        vfo1TxPowerX = other.vfo1TxPowerX,
        vfo2TxPowerX = other.vfo2TxPowerX,
        disDigitalMute = other.disDigitalMute,
        signalingEccEn = other.signalingEccEn,
        chDataLock = other.chDataLock,
        vfo1ModFreqX = other.vfo1ModFreqX,
        vfo2ModFreqX = other.vfo2ModFreqX;

  /// Returns raw settings data minus the 5-byte GAIA header.
  Uint8List toByteArray() {
    final buf = Uint8List(rawData.length - 5);
    buf.setRange(0, buf.length, rawData, 5);
    return buf;
  }

  /// Returns settings with modified channel/scan/squelch.
  Uint8List toByteArrayWithChannels(
      int cha, int chb, int xDoubleChannel, bool xScan, int xSquelch) {
    final buf = toByteArray();
    buf[0] = ((cha & 0x0F) << 4) | (chb & 0x0F);
    buf[1] = (xScan ? 0x80 : 0) |
        (aghfpCallMode ? 0x40 : 0) |
        ((xDoubleChannel & 0x03) << 4) |
        (xSquelch & 0x0F);
    buf[9] = (cha & 0xF0) | ((chb & 0xF0) >> 4);
    return buf;
  }

  /// Returns settings with modified channel/scan/squelch/vfo mode.
  Uint8List toByteArrayWithVfo(
      int cha, int chb, int xDoubleChannel, bool xScan, int xSquelch,
      int xVfoX) {
    final buf = toByteArrayWithChannels(
        cha, chb, xDoubleChannel, xScan, xSquelch);
    // Byte 8 of buf (= byte 13 of raw): screen_timeout(7:3) | vfo_x(2:1) | imperial_unit(0)
    buf[8] = (buf[8] & 0xF9) | ((xVfoX & 0x03) << 1);
    return buf;
  }
}
