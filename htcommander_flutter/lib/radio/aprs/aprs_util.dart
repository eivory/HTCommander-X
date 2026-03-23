import 'coordinate_set.dart';

/// Utility functions for APRS coordinate conversion, validation codes,
/// and grid square computation.
class AprsUtil {
  AprsUtil._();

  /// Computes the APRS-IS validation code (passcode) for a callsign.
  static String aprsValidationCode(String callsign) {
    int hash = 0x73e2; // magic number
    String cs = callsign.toUpperCase().trim();
    // Get just the callsign, no SSID
    final parts = cs.split('-');
    cs = parts[0];
    final len = cs.length;
    // In case callsign is odd length add null
    cs += '\x00';
    int i = 0;
    while (i < len) {
      hash = (cs.codeUnitAt(i) << 8) ^ hash;
      i += 1;
      hash = cs.codeUnitAt(i) ^ hash;
      i += 1;
    }
    return (hash & 0x7fff).toString();
  }

  /// Builds the login string for an APRS-IS server connection.
  static String getServerLogonString(
    String callsign,
    String product,
    String version,
  ) {
    return 'user $callsign pass ${aprsValidationCode(callsign)} '
        'vers $product $version';
  }

  /// Converts latitude and longitude to a Maidenhead grid square locator.
  static String latLonToGridSquare(double lat, double lon) {
    final buf = StringBuffer();

    var la = lat + 90.0;
    var lo = lon + 180.0;

    var v = lo ~/ 20;
    lo -= v * 20;
    buf.writeCharCode(0x41 + v); // 'A' + v

    v = la ~/ 10;
    la -= v * 10;
    buf.writeCharCode(0x41 + v);

    buf.write((lo ~/ 2).toString());
    buf.write(la.toInt().toString());

    lo -= (lo ~/ 2) * 2;
    la -= la.toInt();

    buf.writeCharCode(0x41 + (lo * 12).toInt());
    buf.writeCharCode(0x41 + (la * 24).toInt());

    return buf.toString();
  }

  /// Converts a [CoordinateSet] to a Maidenhead grid square locator.
  static String latLonToGridSquareFromCoords(CoordinateSet coords) {
    return latLonToGridSquare(coords.latitude.value, coords.longitude.value);
  }

  /// Converts a Maidenhead grid square locator to a [CoordinateSet].
  /// Returns null if the locator format is invalid.
  static CoordinateSet? gridSquareToLatLon(String locator) {
    var loc = locator.toUpperCase();
    if (loc.length == 4) {
      loc += 'IL'; // somewhere near the center of the grid
    }
    final pattern = RegExp(r'^[A-R]{2}[0-9]{2}[A-X]{2}$');
    if (!pattern.hasMatch(loc)) return null;

    final coords = CoordinateSet();
    coords.longitude.value = (loc.codeUnitAt(0) - 0x41) * 20.0 +
        (loc.codeUnitAt(2) - 0x30) * 2.0 +
        (loc.codeUnitAt(4) - 0x41 + 0.5) / 12.0 -
        180.0;
    coords.latitude.value = (loc.codeUnitAt(1) - 0x41) * 10.0 +
        (loc.codeUnitAt(3) - 0x30) +
        (loc.codeUnitAt(5) - 0x41 + 0.5) / 24.0 -
        90.0;
    return coords;
  }

  /// Converts a latitude value to NMEA format string (DDMM.MMN/S).
  static String convertLatToNmea(double lat) {
    final cd = lat < 0 ? 'S' : 'N';
    return _convertToNmea(lat, cd, true);
  }

  /// Converts a longitude value to NMEA format string (DDDMM.MME/W).
  static String convertLonToNmea(double lon) {
    final cd = lon < 0 ? 'W' : 'E';
    return _convertToNmea(lon, cd, false);
  }

  /// Converts an NMEA coordinate string to a [Coordinate].
  static Coordinate convertNmea(String nmea) {
    if (nmea.isEmpty) {
      return Coordinate();
    }
    final c = Coordinate();
    c.nmea = nmea;
    c.value = convertNmeaToFloat(nmea);
    return c;
  }

  /// Converts an NMEA coordinate string to a floating point value.
  ///
  /// Handles both latitude (8 chars: DDMM.MMN/S) and longitude
  /// (9 chars: DDDMM.MME/W) formats.
  static double convertNmeaToFloat(String nmea) {
    try {
      if (nmea.isEmpty) return 0;

      // Latitude format: 8 chars
      if (nmea.length == 8) {
        final degrees = double.tryParse(nmea.substring(0, 2));
        final minutes = double.tryParse(nmea.substring(2, 7));
        if (degrees == null || minutes == null) return 0;
        var d = degrees + minutes / 60.0;
        if (nmea.toUpperCase().endsWith('S')) d = -d;
        return d;
      }

      // Longitude format: 9 chars
      if (nmea.length == 9) {
        final degrees = double.tryParse(nmea.substring(0, 3));
        final minutes = double.tryParse(nmea.substring(3, 8));
        if (degrees == null || minutes == null) return 0;
        var d = degrees + minutes / 60.0;
        if (nmea.toUpperCase().endsWith('W')) d = -d;
        return d;
      }

      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// Internal: converts a coordinate to NMEA string format.
  static String _convertToNmea(double d, String direction, bool isLat) {
    final l = d.abs();
    final degrees = l.floor();
    final minutes = (l - degrees) * 60;

    final sD = isLat
        ? degrees.toString().padLeft(2, '0')
        : degrees.toString().padLeft(3, '0');
    final sM = minutes.toStringAsFixed(2).padLeft(5, '0');

    return '$sD$sM$direction';
  }
}
