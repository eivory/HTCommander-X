import 'aprs_util.dart';

/// APRS information-field encoders. Parsing lives in `aprs_packet.dart`;
/// transmission lives here.
///
/// All encoders produce the bytes that go after the AX.25 PID — i.e.
/// the data type identifier (`!`, `=`, `>`, etc.) is included as the
/// first character of the returned string.
class AprsEncoder {
  AprsEncoder._();

  /// Uncompressed position report (spec §8).
  ///
  /// Format: `[!|=][lat][/symTable][lon][symCode][comment]`
  ///   • `lat` is 8 chars `DDMM.MMN/S`
  ///   • `lon` is 9 chars `DDDMM.MMW/E`
  ///   • symbolTable is a single char (`/` primary, `\` alternate, or
  ///     overlay digit `0-9` / `A-Z`)
  ///   • symbolCode is a single char from the chosen table
  ///   • [withMessaging] selects `=` (true) vs `!` (false)
  ///
  /// Optional [comment] is appended verbatim. Course/speed and
  /// altitude data extensions are NOT yet supported by this encoder
  /// — pass them through [comment] manually if needed in the
  /// short term.
  static String position({
    required double latitude,
    required double longitude,
    String symbolTable = '/',
    String symbolCode = '>',
    String comment = '',
    bool withMessaging = false,
  }) {
    final dti = withMessaging ? '=' : '!';
    final lat = AprsUtil.convertLatToNmea(latitude);
    final lon = AprsUtil.convertLonToNmea(longitude);
    return '$dti$lat$symbolTable$lon$symbolCode$comment';
  }

  /// Status report (spec §16).
  ///
  /// Format: `>[DDHHMMz][text]`. Pass [timestamp] (UTC) to prepend a
  /// 7-byte time field; otherwise the report is just `>[text]`.
  static String status({
    required String text,
    DateTime? timestamp,
  }) {
    if (timestamp == null) return '>$text';
    final ts = timestamp.toUtc();
    final dd = ts.day.toString().padLeft(2, '0');
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    return '>$dd$hh${mm}z$text';
  }
}
