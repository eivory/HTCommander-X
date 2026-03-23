/// Represents a parsed APRS callsign with optional SSID.
class Callsign {
  /// The full callsign including SSID (e.g. "W1AW-9").
  final String stationCallsign;

  /// The base callsign without SSID (e.g. "W1AW").
  final String baseCallsign;

  /// The SSID portion (0-15). Defaults to 0 if not present or invalid.
  final int ssid;

  Callsign._({
    required this.stationCallsign,
    required this.baseCallsign,
    required this.ssid,
  });

  /// Parses a callsign string, extracting the base callsign and SSID.
  factory Callsign(String callsign) {
    final station = callsign.toUpperCase().trim();
    if (station.contains('-')) {
      final parts = station.split('-');
      final parsedSsid = int.tryParse(parts[1]);
      if (parsedSsid != null && parsedSsid >= 0 && parsedSsid <= 255) {
        return Callsign._(
          stationCallsign: station,
          baseCallsign: parts[0].toUpperCase(),
          ssid: parsedSsid,
        );
      } else {
        // Not a valid SSID - treat entire string as callsign
        return Callsign._(
          stationCallsign: station,
          baseCallsign: station,
          ssid: 0,
        );
      }
    } else {
      return Callsign._(
        stationCallsign: station,
        baseCallsign: station,
        ssid: 0,
      );
    }
  }

  /// Convenience factory matching the C# static method.
  static Callsign parseCallsign(String callsign) => Callsign(callsign);
}
