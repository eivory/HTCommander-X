// APRS data extensions that can follow position+symbol in position
// reports (spec §7). Each extension is fixed-width except PHGR
// which adds an extra character for the beacon-rate "probe" form.

/// PHGphgd — Power, Effective Antenna Height-Above-Average-Terrain,
/// antenna Gain, and antenna Directivity. Spec §7.
class PhgData {
  /// Transmitter power in watts (raw `p` digit squared per spec).
  final int powerWatts;

  /// Effective antenna height above average terrain, feet
  /// (10 × 2^h per spec; h may be a digit 0-9 or ASCII characters
  /// past `9` for very tall installations like aircraft / balloons).
  final int heightFeet;

  /// Antenna gain in dBi (raw `g` digit per spec).
  final int gainDbi;

  /// Beam direction in compass degrees (45=NE, 90=E, ..., 360=N).
  /// `null` = omni antenna (raw `d` = 0).
  final int? directivityDegrees;

  /// PHGR variant only — beacons per hour (raw `R` char: digits map
  /// 1:1, `A`+ for 10+). `null` for plain PHG.
  final int? beaconsPerHour;

  const PhgData({
    required this.powerWatts,
    required this.heightFeet,
    required this.gainDbi,
    required this.directivityDegrees,
    this.beaconsPerHour,
  });

  /// Try to parse a PHG / PHGR extension at the start of [s].
  ///
  /// Plain PHG is 7 bytes (`PHGphgd`). PHGR adds 1 byte for the
  /// beacon-rate digit + a mandatory trailing `/`, total 9 bytes
  /// (`PHGphgdR/`).
  ///
  /// Returns `(data, consumed)` on success, or null if the prefix
  /// doesn't match. Caller advances by `consumed` bytes.
  static (PhgData, int)? tryParse(String s) {
    if (s.length < 7) return null;
    if (!s.startsWith('PHG')) return null;

    final p = _digitVal(s.codeUnitAt(3));
    final h = _heightVal(s.codeUnitAt(4));
    final g = _digitVal(s.codeUnitAt(5));
    final d = _digitVal(s.codeUnitAt(6));
    if (p == null || h == null || g == null || d == null) return null;

    int? beacons;
    var consumed = 7;
    // PHGR: an extra char then a mandatory '/'.
    if (s.length >= 9 && s.codeUnitAt(8) == 0x2F) {
      final r = _phgrVal(s.codeUnitAt(7));
      if (r != null) {
        beacons = r;
        consumed = 9;
      }
    }

    return (
      PhgData(
        powerWatts: p * p,
        heightFeet: 10 * (1 << h),
        gainDbi: g,
        directivityDegrees: d == 0 ? null : d * 45,
        beaconsPerHour: beacons,
      ),
      consumed,
    );
  }

  static int? _digitVal(int ch) {
    if (ch >= 0x30 && ch <= 0x39) return ch - 0x30;
    return null;
  }

  /// Height code: ASCII `0`-`9` map to 0-9 in the formula. Spec also
  /// allows higher ASCII chars (`:` = 10, `;` = 11, etc.) for tall
  /// stations.
  static int? _heightVal(int ch) {
    if (ch < 0x30) return null;
    return ch - 0x30;
  }

  static int? _phgrVal(int ch) {
    if (ch >= 0x30 && ch <= 0x39) return ch - 0x30;
    if (ch >= 0x41 && ch <= 0x5A) return 10 + (ch - 0x41);
    return null;
  }
}

/// RNGrrrr — pre-calculated omni-directional radio range, in miles.
/// Spec §7.
class RngData {
  final int rangeMiles;

  const RngData({required this.rangeMiles});

  static (RngData, int)? tryParse(String s) {
    if (s.length < 7) return null;
    if (!s.startsWith('RNG')) return null;
    final r = int.tryParse(s.substring(3, 7));
    if (r == null) return null;
    return (RngData(rangeMiles: r), 7);
  }
}

/// DFSshgd — Omni-DF signal strength + effective antenna
/// height/gain/directivity. Spec §7. Same shape as PHG except the
/// `p` (power) field is replaced with `s` (signal strength 0-9).
class DfsData {
  final int signalStrength; // 0-9
  final int heightFeet;
  final int gainDbi;
  final int? directivityDegrees;

  const DfsData({
    required this.signalStrength,
    required this.heightFeet,
    required this.gainDbi,
    required this.directivityDegrees,
  });

  static (DfsData, int)? tryParse(String s) {
    if (s.length < 7) return null;
    if (!s.startsWith('DFS')) return null;

    final ss = PhgData._digitVal(s.codeUnitAt(3));
    final h = PhgData._heightVal(s.codeUnitAt(4));
    final g = PhgData._digitVal(s.codeUnitAt(5));
    final d = PhgData._digitVal(s.codeUnitAt(6));
    if (ss == null || h == null || g == null || d == null) return null;

    return (
      DfsData(
        signalStrength: ss,
        heightFeet: 10 * (1 << h),
        gainDbi: g,
        directivityDegrees: d == 0 ? null : d * 45,
      ),
      7,
    );
  }
}
