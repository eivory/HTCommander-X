import 'aprs_util.dart';
import 'callsign.dart';
import 'coordinate_set.dart';
import 'message_data.dart';
import 'packet_data_type.dart';
import 'position.dart';
import 'telemetry_data.dart';
import 'weather_data.dart';

/// Represents a parsed APRS packet (TNC2 format) with all basic elements.
///
/// Use [AprsPacket.parse] to decode a raw packet from an AX.25 data string
/// and destination callsign.
class AprsPacket {
  /// The raw packet data string.
  String rawPacket = '';

  /// The destination callsign parsed from the AX.25 header.
  Callsign? destCallsign;

  /// The data type character from the information field.
  int dataTypeCh = 0;

  /// The parsed packet data type.
  PacketDataType dataType = PacketDataType.unknown;

  /// The information field (payload after the data type character).
  String informationField = '';

  /// Comment text extracted from the packet.
  String comment = '';

  /// Third-party header if this is a third-party packet.
  String? thirdPartyHeader;

  /// APRS symbol table identifier character.
  int symbolTableIdentifier = 0;

  /// APRS symbol code character.
  int symbolCode = 0;

  /// True if the packet originates from a Kenwood TH-D7.
  bool fromD7 = false;

  /// True if the packet originates from a Kenwood TM-D700.
  bool fromD700 = false;

  /// Authentication code extracted from the packet.
  String? authCode;

  /// Parsed position data.
  Position position = Position();

  /// Parsed timestamp from the packet.
  DateTime? timeStamp;

  /// Parsed message data.
  MessageData messageData = MessageData();

  /// Parsed weather report (spec §12). Populated for positionless
  /// weather (`_`) packets and for position packets whose symbol
  /// code is `_` (the weather symbol).
  WeatherReport? weather;

  /// Telemetry data report (`T#`, spec §13). Populated only for
  /// telemetry packets.
  TelemetryReport? telemetryReport;

  /// Telemetry parameter/unit/equation/bit-sense definition (spec
  /// §13). Populated when a `:` message addressed to the telemetry
  /// source carries `PARM.` / `UNIT.` / `EQNS.` / `BITS.` text. The
  /// addressee field of the underlying message tells you which
  /// callsign these definitions describe.
  TelemetryDefinitions? telemetryDefinitions;

  /// Object/Item entity name (spec §11). Object names are exactly 9
  /// chars (right-padded with spaces); Item names are 3–9 chars
  /// terminated by `!` (live) or `_` (killed). Trimmed on parse.
  /// Empty when the packet is not an object or item.
  String entityName = '';

  /// True when an object (`;`) or item (`)`) is alive — flag char `*`
  /// for objects, `!` for items. False when the flag char is `_`
  /// (killed), which signals consumers to remove the entity from
  /// their displays. Defaults to true; meaningless for non-object/
  /// non-item packets.
  bool entityAlive = true;

  AprsPacket._();

  /// Parses an APRS packet from a raw AX.25 data string and destination
  /// callsign string.
  ///
  /// [dataStr] is the information field from the AX.25 packet.
  /// [destCallsignStr] is the destination callsign with SSID
  /// (e.g. "APRS-0").
  ///
  /// Returns null if parsing fails.
  static AprsPacket? parse(String dataStr, String destCallsignStr) {
    final r = AprsPacket._();
    try {
      var data = dataStr;

      // Handle third-party traffic wrapper
      if (data.isNotEmpty && data.codeUnitAt(0) == 0x7D) {
        // '}'
        final i = data.indexOf('*:');
        if (i >= 0) {
          r.thirdPartyHeader = data.substring(1, i);
          data = data.substring(i + 2);
        }
      }

      r.position.clear();
      r.rawPacket = data;
      r.destCallsign = Callsign.parseCallsign(destCallsignStr);
      r.dataType = PacketDataType.unknown;

      if (data.isEmpty) {
        r.dataType = PacketDataType.beacon;
        r.informationField = '';
        return r;
      }

      r.dataTypeCh = data.codeUnitAt(0);
      r.dataType = getDataType(r.dataTypeCh);
      if (r.dataType == PacketDataType.unknown) {
        r.dataTypeCh = 0;
      }
      if (r.dataType != PacketDataType.unknown) {
        r.informationField = data.substring(1);
      } else {
        r.informationField = data;
      }

      // Parse authcode
      if (r.informationField.isNotEmpty) {
        final i = r.informationField.lastIndexOf('}');
        if (i >= 0 && i == r.informationField.length - 7) {
          r.authCode = r.informationField.substring(i + 1, i + 7);
          r.informationField = r.informationField.substring(0, i);
        } else if (i >= 0 &&
            i < r.informationField.length - 7 &&
            r.informationField.codeUnitAt(i + 7) == 0x7B) {
          // '{'
          r.authCode = r.informationField.substring(i + 1, i + 7);
          r.informationField = r.informationField.substring(0, i) +
              r.informationField.substring(i + 7);
        }
      }

      // Parse information field
      if (r.informationField.isNotEmpty) {
        r._parseInformationField();
      } else {
        r.dataType = PacketDataType.beacon;
      }

      // Compute gridsquare if not given
      if (r.position.isValid && r.position.gridsquare.isEmpty) {
        r.position.gridsquare =
            AprsUtil.latLonToGridSquareFromCoords(r.position.coordinateSet);
      }

      return r;
    } catch (_) {
      return null;
    }
  }

  void _parseDateTime(String str) {
    try {
      if (str.isEmpty) return;

      // Assume current date/time
      timeStamp = DateTime.now().toUtc();

      // Formats:
      //   DDHHMM[z|/]    (z=UTC, /=local)
      //   HHMMSSh        (UTC)
      //   NNDDHHMM       NN=month (UTC)

      final l = str.length;
      final lastCh = str.codeUnitAt(l - 1);

      if (lastCh == 0x7A) {
        // 'z'
        try {
          final day = int.parse(str.substring(0, 2));
          final hour = int.parse(str.substring(2, 4));
          final minute = int.parse(str.substring(4, 6));
          timeStamp = DateTime.utc(
            timeStamp!.year,
            timeStamp!.month,
            day,
            hour,
            minute,
          );
        } catch (_) {
          timeStamp = DateTime.now().toUtc();
        }
      } else if (lastCh == 0x2F) {
        // '/'
        // Local times not supported
        timeStamp = null;
      } else if (lastCh == 0x68) {
        // 'h'
        final hour = int.parse(str.substring(0, 2));
        final minute = int.parse(str.substring(2, 4));
        final second = int.parse(str.substring(4, 6));
        timeStamp = DateTime.utc(
          timeStamp!.year,
          timeStamp!.month,
          timeStamp!.day,
          hour,
          minute,
          second,
        );
      } else if (l == 8) {
        final month = int.parse(str.substring(0, 2));
        final day = int.parse(str.substring(2, 4));
        final hour = int.parse(str.substring(4, 6));
        final minute = int.parse(str.substring(6, 8));
        timeStamp = DateTime.utc(timeStamp!.year, month, day, hour, minute);
      } else {
        timeStamp = null;
      }
    } catch (_) {
      timeStamp = null;
    }
  }

  void _parseInformationField() {
    switch (dataType) {
      case PacketDataType.unknown:
        break;
      case PacketDataType.position:
      case PacketDataType.positionMsg:
        _parsePosition();
        break;
      case PacketDataType.positionTime:
      case PacketDataType.positionTimeMsg:
        _parsePositionTime();
        break;
      case PacketDataType.message:
        _parseMessage(informationField);
        break;
      case PacketDataType.status:
        _parseStatus();
        break;
      case PacketDataType.object:
        _parseObject();
        break;
      case PacketDataType.item:
        _parseItem();
        break;
      case PacketDataType.telemetry:
        telemetryReport = TelemetryReport.parse(informationField);
        break;
      case PacketDataType.weatherReport:
        _parseWeather();
        break;
      case PacketDataType.micECurrent:
      case PacketDataType.micEOld:
      case PacketDataType.tmD700:
      case PacketDataType.micE:
        _parseMicE();
        break;
      // Not implemented - do nothing
      case PacketDataType.beacon:
      case PacketDataType.peetBrosUII1:
      case PacketDataType.peetBrosUII2:
      case PacketDataType.stationCapabilities:
      case PacketDataType.query:
      case PacketDataType.userDefined:
      case PacketDataType.invalidOrTestData:
      case PacketDataType.maidenheadGridLoc:
      case PacketDataType.rawGPSorU2K:
      case PacketDataType.thirdParty:
      case PacketDataType.microFinder:
      case PacketDataType.mapFeature:
      case PacketDataType.shelterData:
      case PacketDataType.spaceWeather:
        break;
    }
  }

  void _parseMessage(String infoField) {
    var s = infoField;

    // Addressee field must be 9 characters long
    if (s.length < 9) {
      dataType = PacketDataType.invalidOrTestData;
      return;
    }

    // Get addressee
    messageData.addressee = s.substring(0, 9).toUpperCase().trim();

    if (s.length < 10) return; // no message

    s = s.substring(10);

    // Look for ack and reject messages. Spec §14 lowercase per
    // example, but accept any case — it's free text we control on TX.
    if (s.length > 3) {
      final head = s.substring(0, 3).toLowerCase();
      if (head == 'ack' || head == 'rej') {
        messageData.msgType =
            head == 'ack' ? MessageType.ack : MessageType.rej;
        messageData.seqId = s.substring(3).trim();
        messageData.msgText = '';
        return;
      }
    }

    // Save sequence number if any. Spec §14 REPLY-ACK extension
    // (Dec 1999): the line number after `{` may be `MM}AA` where MM
    // is this message's seqId and AA is a free-ACK for one of the
    // peer's outstanding outgoing messages. The `}` alone (no AA)
    // signals REPLY-ACK capability.
    final idx = s.lastIndexOf('{');
    if (idx >= 0) {
      var rawId = s.substring(idx + 1);
      s = s.substring(0, idx);
      final braceIdx = rawId.indexOf('}');
      if (braceIdx >= 0) {
        messageData.replyAckCapable = true;
        messageData.replyAck = rawId.substring(braceIdx + 1).trim();
        rawId = rawId.substring(0, braceIdx);
      }
      messageData.seqId = rawId.trim();
    }

    // Assume standard message
    messageData.msgType = MessageType.general;

    // Further process message portion
    if (s.isNotEmpty) {
      final sUpper = s.toUpperCase();
      if (sUpper.startsWith('NWS-')) {
        messageData.msgType = MessageType.nws;
      } else if (sUpper.startsWith('NWS_')) {
        s = s.replaceFirst('NWS_', 'NWS-');
        messageData.msgType = MessageType.nws;
      } else if (sUpper.startsWith('BLN')) {
        final addrUpper = messageData.addressee.toUpperCase();
        if (RegExp(r'^BLN[A-Z]', caseSensitive: false).hasMatch(addrUpper)) {
          messageData.msgType = MessageType.announcement;
        } else if (RegExp(r'^BLN[0-9]', caseSensitive: false)
            .hasMatch(addrUpper)) {
          messageData.msgType = MessageType.bulletin;
        }
      } else if (RegExp(r'^AA:|^\[AA\]', caseSensitive: false).hasMatch(s)) {
        messageData.msgType = MessageType.autoAnswer;
      }
    }

    // Save text of message
    messageData.msgText = s;

    // Spec §13: telemetry definitions (PARM/UNIT/EQNS/BITS) are
    // delivered as messages addressed to the telemetry source. If
    // this message carries one, expose the parsed definition so
    // consumers can cache it per-addressee.
    final defs = TelemetryDefinitions.tryParse(s);
    if (defs != null && !defs.isEmpty) {
      telemetryDefinitions = defs;
    }
  }

  int _convertDest(int ch) {
    var ci = ch - 0x30; // adjust all to be 0 based
    if (ci == 0x1C) ci = 0x0A; // change L to be a space digit
    if (ci > 0x10 && ci <= 0x1B) ci = ci - 1; // A-K need to be decremented
    if ((ci & 0x0F) == 0x0A) {
      ci = ci & 0xF0; // space is converted to 0
    }
    return ci;
  }

  void _parseMicE() {
    if (destCallsign == null) return;
    final dest = destCallsign!.stationCallsign;
    if (dest.length < 6 || dest.length == 7) return;

    // Validate destination characters
    final custom = ((dest.codeUnitAt(0) >= 0x41 &&
            dest.codeUnitAt(0) <= 0x4B) || // A-K
        (dest.codeUnitAt(1) >= 0x41 && dest.codeUnitAt(1) <= 0x4B) ||
        (dest.codeUnitAt(2) >= 0x41 && dest.codeUnitAt(2) <= 0x4B));

    for (var j = 0; j < 3; j++) {
      final ch = dest.codeUnitAt(j);
      if (custom) {
        if (ch < 0x30 || ch > 0x4C || (ch > 0x39 && ch < 0x41)) return;
      } else {
        if (ch < 0x30 ||
            ch > 0x5A ||
            (ch > 0x39 && ch < 0x4C) ||
            (ch > 0x4C && ch < 0x50)) {
          return;
        }
      }
    }
    for (var j = 3; j < 6; j++) {
      final ch = dest.codeUnitAt(j);
      if (ch < 0x30 ||
          ch > 0x5A ||
          (ch > 0x39 && ch < 0x4C) ||
          (ch > 0x4C && ch < 0x50)) {
        return;
      }
    }
    if (dest.length > 6) {
      if (dest.codeUnitAt(6) != 0x2D ||
          dest.codeUnitAt(7) < 0x30 ||
          dest.codeUnitAt(7) > 0x39) {
        return;
      }
      if (dest.length == 9) {
        if (dest.codeUnitAt(8) < 0x30 || dest.codeUnitAt(8) > 0x39) {
          return;
        }
      }
    }

    // Parse the destination field
    var c = _convertDest(dest.codeUnitAt(0));
    var mes = 0; // message code
    if ((c & 0x10) != 0) mes = 0x08; // set the custom flag
    if (c >= 0x10) mes = mes + 0x04;
    var d = (c & 0x0F) * 10; // degrees

    c = _convertDest(dest.codeUnitAt(1));
    if (c >= 0x10) mes = mes + 0x02;
    d = d + (c & 0x0F);

    c = _convertDest(dest.codeUnitAt(2));
    if (c >= 0x10) mes += 1;
    messageData.msgIndex = mes;

    var m = (c & 0x0F) * 10; // minutes
    c = _convertDest(dest.codeUnitAt(3));
    final north = c >= 0x20;
    m = m + (c & 0x0F);

    c = _convertDest(dest.codeUnitAt(4));
    final hundred = c >= 0x20; // flag for adjustment
    var s = (c & 0x0F) * 10; // hundredths of minutes

    c = _convertDest(dest.codeUnitAt(5));
    final west = c >= 0x20;
    s = s + (c & 0x0F);

    var lat = d + (m / 60.0) + (s / 6000.0);
    if (!north) lat = -lat;
    position.coordinateSet.latitude = Coordinate.fromValue(lat, isLat: true);

    // Parse the symbol
    if (informationField.length > 6) {
      symbolCode = informationField.codeUnitAt(6);
    }
    if (informationField.length > 7) {
      symbolTableIdentifier = informationField.codeUnitAt(7);
    }

    // Set D7/D700 flags
    if (informationField.length > 8) {
      fromD7 = informationField.codeUnitAt(8) == 0x3E; // '>'
      fromD700 = informationField.codeUnitAt(8) == 0x5D; // ']'
    }

    // Parse the longitude
    d = informationField.codeUnitAt(0) - 28;
    m = informationField.codeUnitAt(1) - 28;
    s = informationField.codeUnitAt(2) - 28;

    // Validate
    if (d < 0 || d > 99 || m < 0 || m > 99 || s < 0 || s > 99) {
      position.clear();
      return;
    }

    // Adjust the degrees value
    if (hundred) d = d + 100;
    if (d >= 190) {
      d = d - 190;
    } else if (d >= 180) {
      d = d - 80;
    }
    // Adjust minutes 0-9 to proper spot
    if (m >= 60) m = m - 60;
    var lon = d + (m / 60.0) + (s / 6000.0);
    if (west) lon = -lon;
    position.coordinateSet.longitude = Coordinate.fromValue(lon, isLat: false);

    // Record comment
    comment =
        informationField.length > 8 ? informationField.substring(8) : '';

    // Check for altitude encoding
    if (comment.length >= 4 && comment.codeUnitAt(3) == 0x7D) {
      // '}'
      d = comment.codeUnitAt(0) - 33;
      m = comment.codeUnitAt(1) - 33;
      s = comment.codeUnitAt(2) - 33;
      if (d >= 0 && d <= 91 && m >= 0 && m <= 91 && s >= 0 && s <= 91) {
        position.altitude = (d * 91 * 91) + (m * 91) + s;
      }
      comment = comment.substring(4);
    } else if (comment.length >= 5 &&
        (comment.codeUnitAt(0) == 0x3E || comment.codeUnitAt(0) == 0x5D) &&
        comment.codeUnitAt(4) == 0x7D) {
      // '>' or ']' followed by altitude + '}'
      d = comment.codeUnitAt(1) - 33;
      m = comment.codeUnitAt(2) - 33;
      s = comment.codeUnitAt(3) - 33;
      if (d >= 0 && d <= 91 && m >= 0 && m <= 91 && s >= 0 && s <= 91) {
        position.altitude = (d * 91 * 91) + (m * 91) + s;
      }
      comment = comment.substring(5);
    }
    comment = comment.trim();

    if (informationField.length > 5) {
      // Parse the Speed/Course (s/d)
      m = informationField.codeUnitAt(4) - 28;
      if (m < 0 || m > 97) return;
      s = informationField.codeUnitAt(3) - 28;
      if (s < 0 || s > 99) return;
      s = ((s * 10) + (m ~/ 10) + 0.5).round(); // speed in knots
      d = informationField.codeUnitAt(5) - 28;
      if (d < 0 || d > 99) return;

      d = ((m % 10) * 100) + d; // course
      if (s >= 800) s = s - 800;
      if (d >= 400) d = d - 400;
      if (d > 0) {
        position.course = d;
        position.speed = s;
      }
    }
  }

  void _parsePosition() {
    // After parsing position and symbol from the information field
    // all that can be left is a comment
    comment = _parsePositionAndSymbol(informationField);
    _maybeParseWeatherInComment();
  }

  /// Spec §12 says the four position DTIs (`!`, `=`, `/`, `@`) may
  /// also carry weather data — recognized by symbol code `_`. The
  /// weather fields appear immediately after the position+symbol,
  /// in [comment]. Parse them in place.
  void _maybeParseWeatherInComment() {
    if (symbolCode != 0x5F) return; // '_' weather symbol
    final w = WeatherReport.parseBody(comment);
    if (w != null && !w.isEmpty) weather = w;
  }

  String _parsePositionAndSymbol(String ps) {
    try {
      if (ps.isEmpty) {
        position.clear();
        return '';
      }

      // Compressed format if the first character is not a digit
      if (!_isDigit(ps.codeUnitAt(0))) {
        // Compressed position data (13 chars)
        if (ps.length < 13) {
          position.clear();
          return '';
        }
        final pd = ps.substring(0, 13);

        symbolTableIdentifier = pd.codeUnitAt(0);
        // Since compressed format never starts with a digit, to represent a
        // digit as the overlay character a letter (a..j) is used instead
        const overlayChars = 'abcdefghij';
        if (overlayChars
            .contains(String.fromCharCode(symbolTableIdentifier))) {
          // Convert to digit (0..9)
          symbolTableIdentifier =
              symbolTableIdentifier - 0x61 + 0x30; // 'a' -> '0'
        }
        symbolCode = pd.codeUnitAt(9);

        const sqr91 = 91 * 91;
        const cube91 = 91 * 91 * 91;

        // Latitude
        final sLat = pd.substring(1, 5);
        final dLat = 90 -
            ((sLat.codeUnitAt(0) - 33) * cube91 +
                    (sLat.codeUnitAt(1) - 33) * sqr91 +
                    (sLat.codeUnitAt(2) - 33) * 91 +
                    (sLat.codeUnitAt(3) - 33)) /
                380926.0;
        position.coordinateSet.latitude =
            Coordinate.fromValue(dLat, isLat: true);

        // Longitude
        final sLon = pd.substring(5, 9);
        final dLon = -180 +
            ((sLon.codeUnitAt(0) - 33) * cube91 +
                    (sLon.codeUnitAt(1) - 33) * sqr91 +
                    (sLon.codeUnitAt(2) - 33) * 91 +
                    (sLon.codeUnitAt(3) - 33)) /
                190463.0;
        position.coordinateSet.longitude =
            Coordinate.fromValue(dLon, isLat: false);

        // Strip off position report and return remainder
        ps = ps.substring(13);
      } else {
        if (ps.length < 19) {
          position.clear();
          return '';
        }

        // Normal (uncompressed)
        final pd = ps.substring(0, 19);
        final sLat = pd.substring(0, 8);
        symbolTableIdentifier = pd.codeUnitAt(8);
        final sLon = pd.substring(9, 18);
        symbolCode = pd.codeUnitAt(18);

        position.coordinateSet.latitude = Coordinate.fromNmea(sLat);
        position.coordinateSet.longitude = Coordinate.fromNmea(sLon);

        // Check for valid lat/lon values
        if (position.coordinateSet.latitude.value < -90 ||
            position.coordinateSet.latitude.value > 90 ||
            position.coordinateSet.longitude.value < -180 ||
            position.coordinateSet.longitude.value > 180) {
          position.clear();
        }

        // Strip off position report and return remainder
        ps = ps.substring(19);

        // Look for course and speed
        if (ps.length >= 7 &&
            ps.codeUnitAt(3) == 0x2F && // '/'
            _isDigit(ps.codeUnitAt(0)) &&
            _isDigit(ps.codeUnitAt(1)) &&
            _isDigit(ps.codeUnitAt(2)) &&
            _isDigit(ps.codeUnitAt(4)) &&
            _isDigit(ps.codeUnitAt(5)) &&
            _isDigit(ps.codeUnitAt(6))) {
          position.course = int.parse(ps.substring(0, 3));
          position.speed = int.parse(ps.substring(4, 7));
          ps = ps.substring(7);
        }

        // Look for altitude
        if (ps.length >= 9 &&
            ps.codeUnitAt(0) == 0x2F && // '/'
            ps.codeUnitAt(1) == 0x41 && // 'A'
            ps.codeUnitAt(2) == 0x3D && // '='
            _isDigit(ps.codeUnitAt(3)) &&
            _isDigit(ps.codeUnitAt(4)) &&
            _isDigit(ps.codeUnitAt(5)) &&
            _isDigit(ps.codeUnitAt(6)) &&
            _isDigit(ps.codeUnitAt(7)) &&
            _isDigit(ps.codeUnitAt(8))) {
          position.altitude = int.parse(ps.substring(3, 9));
          ps = ps.substring(9);
        }
      }
      return ps;
    } catch (_) {
      return informationField;
    }
  }

  void _parsePositionTime() {
    if (informationField.length < 7) return;
    _parseDateTime(informationField.substring(0, 7));
    final psr = informationField.substring(7);

    // After parsing position and symbol from the information field
    // all that can be left is a comment
    comment = _parsePositionAndSymbol(psr);
    _maybeParseWeatherInComment();
  }

  /// Positionless weather report (`_`) — spec §12.
  ///
  /// Format: `_MMDDHHMM` 8-byte timestamp + weather data fields.
  /// Reuses [_parseDateTime] which understands the `MDHM` form when
  /// passed an 8-char numeric string.
  void _parseWeather() {
    if (informationField.length < 8) return;
    _parseDateTime(informationField.substring(0, 8));
    final body = informationField.substring(8);
    weather = WeatherReport.parseBody(body);
    // Spec doesn't define a separate comment for `_` packets, but
    // any trailing free text we couldn't classify as weather fields
    // is preserved in `weather` parsing or simply ignored. Leave
    // [comment] empty to signal "no plain-text comment."
  }

  /// Object report (`;`) — spec §11.
  ///
  /// Format: 9-char fixed-width name + flag char (`*` live, `_`
  /// killed) + 7-byte timestamp + position (compressed or
  /// uncompressed) + optional comment. Reuses the timestamp and
  /// position helpers used by position packets, so the resulting
  /// `position`, `symbolTableIdentifier`, `symbolCode`, `comment`,
  /// and `timeStamp` fields are populated identically.
  void _parseObject() {
    final s = informationField;
    if (s.length < 17) return; // 9 name + 1 flag + 7 timestamp
    entityName = s.substring(0, 9).trim();
    final flag = s.codeUnitAt(9);
    entityAlive = flag != 0x5F; // '_' = killed; '*' = live
    _parseDateTime(s.substring(10, 17));
    // After parsing position and symbol from the remaining info field
    // all that can be left is a comment.
    comment = _parsePositionAndSymbol(s.substring(17));
  }

  /// Item report (`)`) — spec §11.
  ///
  /// Format: 3–9 char variable-width name terminated by `!` (live) or
  /// `_` (killed) + position (compressed or uncompressed) + optional
  /// comment. No timestamp.
  void _parseItem() {
    final s = informationField;
    if (s.length < 4) return;
    // Find the terminator within the first 3..9 chars of the name.
    // Names are 3-9 chars per spec, so terminator index ∈ [3, 9].
    int? termIdx;
    final maxIdx = s.length < 10 ? s.length : 10;
    for (var i = 3; i < maxIdx; i++) {
      final ch = s.codeUnitAt(i);
      if (ch == 0x21 || ch == 0x5F) {
        termIdx = i;
        break;
      }
    }
    if (termIdx == null) return; // malformed: no terminator
    entityName = s.substring(0, termIdx).trim();
    entityAlive = s.codeUnitAt(termIdx) != 0x5F;
    comment = _parsePositionAndSymbol(s.substring(termIdx + 1));
  }

  /// Status report (`>`) — spec §16.
  ///
  /// Format: optional 7-byte timestamp (`DDHHMMz` or `HHMMSSh`) followed
  /// by free-form text up to 62 chars (no timestamp) or 55 chars (with).
  /// We use the existing [_parseDateTime] helper, but only consume the
  /// 7-byte prefix when it has a recognized terminator (`z`, `/`, `h`)
  /// — otherwise the prefix is just text.
  void _parseStatus() {
    var s = informationField;
    if (s.isEmpty) return;
    if (s.length >= 7) {
      final tsCh = s.codeUnitAt(6);
      // 'z', '/', or 'h' marks a timestamp prefix. Anything else means
      // the whole field is comment text (timestamp is optional).
      if (tsCh == 0x7A || tsCh == 0x2F || tsCh == 0x68) {
        final saved = timeStamp;
        _parseDateTime(s.substring(0, 7));
        if (timeStamp != null) {
          s = s.substring(7);
        } else {
          // Fake terminator in the comment — keep the whole field.
          timeStamp = saved;
        }
      }
    }
    comment = s;
  }

  static bool _isDigit(int ch) => ch >= 0x30 && ch <= 0x39;

  @override
  String toString() {
    final sb = StringBuffer();
    sb.writeln('DataTypeCh           : ${String.fromCharCode(dataTypeCh)}');
    sb.writeln('DataType             : $dataType');
    sb.writeln('InformationField     : $informationField');
    if (comment.isNotEmpty) {
      sb.writeln('Comment              : $comment');
    }
    if (symbolTableIdentifier != 0) {
      sb.writeln(
        'SymbolTableIdentifier: ${String.fromCharCode(symbolTableIdentifier)}',
      );
    }
    if (symbolCode != 0) {
      sb.writeln('SymbolCode           : ${String.fromCharCode(symbolCode)}');
    }
    if (fromD7) sb.writeln('FromD7               : $fromD7');
    if (fromD700) sb.writeln('FromD700             : $fromD700');
    if (position.coordinateSet.latitude.value != 0 &&
        position.coordinateSet.longitude.value != 0) {
      sb.writeln('Position:');
      if (position.altitude != 0) {
        sb.writeln('  Altitude           : ${position.altitude}');
      }
      if (position.ambiguity != 0) {
        sb.writeln('  Ambiguity          : ${position.ambiguity}');
      }
      sb.writeln(
        '  Latitude           : ${position.coordinateSet.latitude.value}',
      );
      sb.writeln(
        '  Longitude          : ${position.coordinateSet.longitude.value}',
      );
      if (position.course != 0) {
        sb.writeln('  Course             : ${position.course}');
      }
      sb.writeln('  Gridsquare         : ${position.gridsquare}');
      if (position.speed != 0) {
        sb.writeln('  Speed              : ${position.speed}');
      }
    }
    if (timeStamp != null) sb.writeln('TimeStamp            : $timeStamp');
    if (messageData.msgText.isNotEmpty) {
      sb.writeln('Message:');
      sb.writeln('  Addressee          : ${messageData.addressee}');
      sb.writeln('  MsgIndex           : ${messageData.msgIndex}');
      sb.writeln('  MsgText            : ${messageData.msgText}');
      sb.writeln('  MsgType            : ${messageData.msgType}');
      sb.writeln('  SeqId              : ${messageData.seqId}');
    }
    return sb.toString();
  }
}
