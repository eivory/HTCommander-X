/// Parsed APRS telemetry report (`T#` data line, spec §13).
///
/// The traditional format is `T#sssss,aaa,aaa,aaa,aaa,aaa,bbbbbbbb`
/// where:
///   • `sss` is a 3-digit sequence number (000-999), or the literal
///     `MIC` for Kantronics MIM-style packets
///   • the five `aaa` are 8-bit analog values (000-255), but spec 1.2
///     relaxes this to allow longer strings, decimals, and negatives
///   • `bbbbbbbb` is the 8-bit digital channel (LSB = B1, MSB = B8)
class TelemetryReport {
  /// Sequence number string (3 digits like "001", or "MIC"). Stored
  /// raw rather than parsed because some senders use letters and the
  /// raw form is what telemetry consumers expect to display.
  final String sequence;

  /// 5 analog channel values, parsed as doubles (spec 1.2 relaxes the
  /// 3-digit integer rule). Empty fields parse as 0.0; missing
  /// trailing fields are not included in the list.
  final List<double> analog;

  /// 8 digital channel values (LSB-first: index 0 = B1). Empty if the
  /// digital field was missing or malformed.
  final List<bool> digital;

  /// Free-text comment after the digital field (rare).
  final String comment;

  const TelemetryReport({
    required this.sequence,
    required this.analog,
    required this.digital,
    this.comment = '',
  });

  /// Parse a telemetry data line. Returns null if the line doesn't
  /// look like a valid `T#` payload (caller should pass the substring
  /// AFTER the `T` data type identifier).
  ///
  /// Field positions per spec §13:
  ///   parts[0]       — sequence number
  ///   parts[1..5]    — up to 5 analog channels
  ///   parts[6]       — optional digital channel (8 bits) + optional
  ///                    space-delimited comment
  /// Position-based rather than content-sniffing because some
  /// telemetry analog values legitimately look like `010` (3 digits
  /// of 0/1) and we can't distinguish from a digital field by content.
  static TelemetryReport? parse(String body) {
    var s = body;
    if (s.startsWith('#')) s = s.substring(1);

    final parts = s.split(',');
    if (parts.length < 2) return null; // need at least seq + 1 analog

    var seq = parts[0];
    if (seq.isEmpty) return null;

    // Spec §13: "In the case of MIC, there may or may not be a comma
    // preceding the first analog data value." If we see a MIC prefix
    // followed by digits in the same field, split it.
    if (seq.length > 3 && seq.toUpperCase().startsWith('MIC')) {
      parts[0] = seq.substring(3);
      parts.insert(0, seq.substring(0, 3));
      seq = parts[0];
    }

    final analog = <double>[];
    final analogEnd = parts.length < 6 ? parts.length : 6;
    for (var i = 1; i < analogEnd; i++) {
      analog.add(double.tryParse(parts[i]) ?? 0.0);
    }

    var digital = <bool>[];
    var comment = '';
    if (parts.length > 6) {
      var digitalRaw = parts[6];
      // Digital may have a comment glued on after a space.
      final spaceIdx = digitalRaw.indexOf(' ');
      if (spaceIdx >= 0) {
        comment = digitalRaw.substring(spaceIdx + 1);
        digitalRaw = digitalRaw.substring(0, spaceIdx);
      }
      digital = digitalRaw.split('').map((c) => c == '1').toList();
    }

    return TelemetryReport(
      sequence: seq,
      analog: analog,
      digital: digital,
      comment: comment,
    );
  }

  /// Parse a Base91-encoded telemetry block carried in the COMMENT
  /// field of any position packet (spec §13 "APRS Base91 Comment
  /// Telemetry"). Format: `|...|` where the body is pairs of
  /// printable Base91 digits (each digit = ASCII char minus 33,
  /// giving 0..90; pairs combine to 0..8280).
  ///
  /// Layout inside the delimiters:
  ///   • 2 bytes — sequence counter (0..8280)
  ///   • 2 bytes × 1..5 — analog channels
  ///   • 2 bytes (optional) — packed 8 binary channels (LSB = B1)
  ///
  /// Returns null when [body] doesn't include a well-formed `|...|`
  /// block. Returns a tuple of `(TelemetryReport, untouchedComment)`
  /// where the comment has the block stripped out — caller should
  /// store both. Spec §13 states the block MUST appear after the
  /// user comment but before any DAO / Mic-E type codes; we just
  /// take the first match.
  static (TelemetryReport, String)? tryParseBase91(String comment) {
    if (comment.length < 6) return null;
    final start = comment.indexOf('|');
    if (start < 0) return null;
    final end = comment.indexOf('|', start + 1);
    if (end < 0 || end == start + 1) return null;
    final inner = comment.substring(start + 1, end);
    // Must be even length, 4..14 bytes (seq + 1..5 analogs +
    // optional digital).
    if (inner.length < 4 || inner.length > 14 || inner.length.isOdd) {
      return null;
    }
    // All chars must be printable Base91 (33..123).
    for (var i = 0; i < inner.length; i++) {
      final c = inner.codeUnitAt(i);
      if (c < 33 || c > 123) return null;
    }
    int decode2(int idx) =>
        (inner.codeUnitAt(idx) - 33) * 91 + (inner.codeUnitAt(idx + 1) - 33);

    final seqVal = decode2(0);
    final pairs = (inner.length - 2) ~/ 2;
    final analog = <double>[];
    final analogPairs = pairs > 5 ? 5 : pairs;
    for (var i = 0; i < analogPairs; i++) {
      analog.add(decode2(2 + i * 2).toDouble());
    }
    var digital = <bool>[];
    if (pairs > 5) {
      // Pair past the 5 analog ones is the binary channel.
      final bin = decode2(2 + 5 * 2);
      for (var b = 0; b < 8; b++) {
        digital.add((bin & (1 << b)) != 0);
      }
    }

    final stripped =
        comment.substring(0, start) + comment.substring(end + 1);
    return (
      TelemetryReport(
        sequence: seqVal.toString(),
        analog: analog,
        digital: digital,
      ),
      stripped,
    );
  }
}

/// Telemetry parameter / unit / equation / bit-sense definitions
/// carried in `:` messages addressed to the telemetry source callsign
/// (spec §13). Receivers cache these per-callsign so future `T#`
/// reports can be displayed with friendly names and physical units.
///
/// Only one of [parameterNames], [unitLabels], [equations], or
/// [bitSense]/[projectTitle] is populated at a time — each maps to a
/// different `PARM.` / `UNIT.` / `EQNS.` / `BITS.` message.
class TelemetryDefinitions {
  /// PARM.: 5 analog labels then up to 8 digital labels.
  final List<String>? parameterNames;

  /// UNIT.: 5 analog units then up to 8 digital labels.
  final List<String>? unitLabels;

  /// EQNS.: 5 channels × 3 quadratic coefficients (a, b, c) such that
  /// `value = a*raw² + b*raw + c`. Up to 15 doubles, padded with 0.0
  /// if the message terminated early.
  final List<double>? equations;

  /// BITS.: 8-character `0`/`1` string (the active sense for each of
  /// B1..B8) followed by an optional project title.
  final List<bool>? bitSense;
  final String? projectTitle;

  const TelemetryDefinitions._({
    this.parameterNames,
    this.unitLabels,
    this.equations,
    this.bitSense,
    this.projectTitle,
  });

  /// True when this object holds no useful payload (callers should
  /// treat as null).
  bool get isEmpty =>
      parameterNames == null &&
      unitLabels == null &&
      equations == null &&
      bitSense == null;

  /// Try to parse [msgText] as a telemetry definition. Returns null
  /// if the text doesn't carry one.
  static TelemetryDefinitions? tryParse(String msgText) {
    if (msgText.length < 5) return null;
    final tag = msgText.substring(0, 5).toUpperCase();
    final body = msgText.substring(5);
    switch (tag) {
      case 'PARM.':
        return TelemetryDefinitions._(parameterNames: body.split(','));
      case 'UNIT.':
        return TelemetryDefinitions._(unitLabels: body.split(','));
      case 'EQNS.':
        final parts = body.split(',');
        final eqns = parts.map((p) => double.tryParse(p) ?? 0.0).toList();
        // Spec defines 15 (5 × 3); allow shorter messages.
        return TelemetryDefinitions._(equations: eqns);
      case 'BITS.':
        // First field is up to 8 chars of '0'/'1'; everything after a
        // comma is the project title.
        final commaIdx = body.indexOf(',');
        final senseStr =
            commaIdx >= 0 ? body.substring(0, commaIdx) : body;
        final title = commaIdx >= 0 ? body.substring(commaIdx + 1) : null;
        final senses = <bool>[];
        for (var i = 0; i < senseStr.length && i < 8; i++) {
          senses.add(senseStr.codeUnitAt(i) == 0x31);
        }
        return TelemetryDefinitions._(
          bitSense: senses,
          projectTitle: title,
        );
      default:
        return null;
    }
  }
}
