import 'dart:typed_data';
import '../radio_enums.dart';

/// GPS position data from the radio.
/// Port of HTCommander.Core/radio/RadioPosition.cs
class RadioPosition {
  RadioCommandState status;
  int latitudeRaw;
  int longitudeRaw;
  int altitude;
  int speed;
  int heading;
  int timeRaw;
  int accuracy;

  String latitudeStr;
  String longitudeStr;
  double latitude;
  double longitude;
  DateTime timeUtc;
  DateTime time;
  DateTime receivedTime;
  bool locked;

  bool get isGpsLocked =>
      locked &&
      status == RadioCommandState.success &&
      receivedTime
          .add(const Duration(seconds: 10))
          .isAfter(DateTime.now());

  /// Create from decimal-degree coordinates.
  RadioPosition.fromCoordinates({
    required double lat,
    required double lon,
    double altitudeMetres = 0,
    double speedKnots = 0,
    double headingDegrees = 0,
    required DateTime utcTime,
  })  : status = RadioCommandState.success,
        receivedTime = DateTime.now(),
        latitude = lat,
        longitude = lon,
        latitudeRaw = (lat * 60.0 * 500.0).round(),
        longitudeRaw = (lon * 60.0 * 500.0).round(),
        altitude = altitudeMetres.round(),
        speed = speedKnots.round(),
        heading = headingDegrees.round(),
        timeRaw = (utcTime.millisecondsSinceEpoch ~/ 1000),
        accuracy = 0,
        locked = true,
        latitudeStr = '',
        longitudeStr = '',
        timeUtc = utcTime,
        time = utcTime.toLocal() {
    latitudeStr = _convertToDms(latitudeRaw);
    longitudeStr = _convertToDms(longitudeRaw);
  }

  /// Parse from GAIA response bytes.
  RadioPosition.fromBytes(Uint8List msg)
      : status = RadioCommandState.fromValue(msg[4]),
        latitudeRaw = 0,
        longitudeRaw = 0,
        altitude = 0,
        speed = 0,
        heading = 0,
        timeRaw = 0,
        accuracy = 0,
        latitudeStr = '',
        longitudeStr = '',
        latitude = 0,
        longitude = 0,
        timeUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        time = DateTime.fromMillisecondsSinceEpoch(0),
        receivedTime = DateTime.now(),
        locked = false {
    if (msg.length < 5) {
      throw ArgumentError(
          'RadioPosition message too short (need >= 5 bytes)');
    }

    if (status == RadioCommandState.success) {
      if (msg.length < 11) {
        throw ArgumentError(
            'RadioPosition SUCCESS message too short (need >= 11 bytes)');
      }
      locked = true;
      latitudeRaw = (msg[5] << 16) | (msg[6] << 8) | msg[7];
      longitudeRaw = (msg[8] << 16) | (msg[9] << 8) | msg[10];
      latitudeStr = _convertToDms(latitudeRaw);
      longitudeStr = _convertToDms(longitudeRaw);
      latitude = _convertRawToDecimal(latitudeRaw);
      longitude = _convertRawToDecimal(longitudeRaw);

      if (msg.length >= 23) {
        altitude = (msg[11] << 8) | msg[12];
        speed = (msg[13] << 8) | msg[14];
        heading = (msg[15] << 8) | msg[16];
        timeRaw = (msg[17] << 24) | (msg[18] << 16) | (msg[19] << 8) | msg[20];
        timeUtc = DateTime.fromMillisecondsSinceEpoch(
            timeRaw * 1000,
            isUtc: true);
        time = timeUtc.toLocal();
        accuracy = (msg[21] << 8) | msg[22];
      }
    }
  }

  /// Convert 24-bit two's complement raw value to decimal degrees.
  static double _convertRawToDecimal(int raw) {
    // Sign-extend 24-bit to full int
    if ((raw & 0x00800000) != 0) {
      raw |= 0xFF000000; // negative
    } else {
      raw &= 0x00FFFFFF;
    }
    // Dart int is 64-bit; we need 32-bit sign extension
    if (raw > 0x7FFFFFFF) raw -= 0x100000000;
    return raw / 60.0 / 500.0;
  }

  /// Convert raw coordinate to DMS string.
  static String _convertToDms(int raw) {
    if ((raw & 0x00800000) != 0) {
      raw |= 0xFF000000;
    } else {
      raw &= 0x00FFFFFF;
    }
    if (raw > 0x7FFFFFFF) raw -= 0x100000000;

    var degreesDecimal = raw / 60.0 / 500.0;
    final direction = degreesDecimal >= 0 ? 'N' : 'S';
    degreesDecimal = degreesDecimal.abs();

    final degrees = degreesDecimal.floor();
    final minutesDecimal = (degreesDecimal - degrees) * 60;
    final minutes = minutesDecimal.floor();
    final seconds = (minutesDecimal - minutes) * 60;

    return "$degrees\u00B0 $minutes' ${seconds.toStringAsFixed(2)}\" $direction";
  }

  /// Serialize to 18-byte SET_POSITION payload.
  Uint8List toByteArray() {
    return Uint8List.fromList([
      (latitudeRaw >> 16) & 0xFF,
      (latitudeRaw >> 8) & 0xFF,
      latitudeRaw & 0xFF,
      (longitudeRaw >> 16) & 0xFF,
      (longitudeRaw >> 8) & 0xFF,
      longitudeRaw & 0xFF,
      (altitude >> 8) & 0xFF,
      altitude & 0xFF,
      (speed >> 8) & 0xFF,
      speed & 0xFF,
      (heading >> 8) & 0xFF,
      heading & 0xFF,
      (timeRaw >> 24) & 0xFF,
      (timeRaw >> 16) & 0xFF,
      (timeRaw >> 8) & 0xFF,
      timeRaw & 0xFF,
      (accuracy >> 8) & 0xFF,
      accuracy & 0xFF,
    ]);
  }
}
