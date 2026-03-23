import 'aprs_util.dart';

/// A single coordinate value with both decimal and NMEA representations.
class Coordinate {
  /// Decimal degrees value.
  double value;

  /// NMEA string representation.
  String nmea;

  /// Creates an empty coordinate (value = 0, nmea = '').
  Coordinate()
      : value = 0,
        nmea = '';

  /// Creates a coordinate from a decimal degrees value.
  /// [isLat] determines whether this is a latitude (true) or longitude (false).
  Coordinate.fromValue(this.value, {required bool isLat})
      : nmea = isLat
            ? AprsUtil.convertLatToNmea(value)
            : AprsUtil.convertLonToNmea(value);

  /// Creates a coordinate from an NMEA string.
  Coordinate.fromNmea(String nmeaStr)
      : nmea = nmeaStr.trim(),
        value = AprsUtil.convertNmeaToFloat(nmeaStr.trim());

  /// Resets this coordinate to zero.
  void clear() {
    value = 0;
    nmea = '';
  }
}

/// A pair of latitude and longitude coordinates.
class CoordinateSet {
  Coordinate latitude;
  Coordinate longitude;

  /// Creates an empty coordinate set.
  CoordinateSet()
      : latitude = Coordinate(),
        longitude = Coordinate();

  /// Creates a coordinate set from decimal degree values.
  CoordinateSet.fromValues(double lat, double lon)
      : latitude = Coordinate.fromValue(lat, isLat: true),
        longitude = Coordinate.fromValue(lon, isLat: false);

  /// Resets both coordinates to zero.
  void clear() {
    latitude.clear();
    longitude.clear();
  }

  /// Returns true if the position is valid (not 0,0).
  bool get isValid => !(latitude.value == 0 && longitude.value == 0);
}
