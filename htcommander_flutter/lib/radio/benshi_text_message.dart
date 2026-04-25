import 'dart:convert';
import 'dart:typed_data';

/// A direct text message exchanged between Benshi-family radios.
///
/// This is *not* APRS — it's the radios' built-in "SMS-like" feature
/// which uses the same DATA_RXD GAIA notification but with a
/// proprietary, non-AX.25 payload. We see it on UV-PRO when another
/// Benshi radio in range sends a text via its keypad menu.
///
/// Wire format (best-effort reverse-engineered from RX captures —
/// no benlink/HTCommander reference exists). The fragment payload is:
///
///     01 07 <SSID> <6-char-callsign>          // 9 bytes: SENDER
///     <variant>...
///
/// where ``<variant>`` is one of:
///
/// * Broadcast (no named addressee) ::
///
///       01 21 <LL> <LL bytes of text starting with '$'>
///
/// * Direct (with named addressee) ::
///
///       07 21 <6-char-addressee> 02 <text-bytes-until-end-of-fragment>
///
/// The leading ``$`` on the text body is a marker we keep — different
/// servers / firmware versions seem to use it as a delimiter.
class BenshiTextMessage {
  /// Addressee callsign as it appeared on the wire (stripped of
  /// padding). Empty when the message was a broadcast.
  final String to;

  /// Source callsign — the sender. Always present (the first
  /// callsign block in the fragment is the originator).
  final String from;

  /// The textual message body (with the leading ``$`` retained).
  final String text;

  /// Raw bytes for debugging / forwarding.
  final Uint8List raw;

  const BenshiTextMessage({
    required this.to,
    required this.from,
    required this.text,
    required this.raw,
  });

  /// Try to parse a Benshi text-message fragment payload. Returns
  /// null if the bytes don't match either known shape.
  static BenshiTextMessage? tryParse(Uint8List data) {
    if (data.length < 9) return null;
    // First block is the SENDER: 01 07 <ssid> <6 chars>.
    if (data[0] != 0x01 || data[1] != 0x07) return null;
    // Address block value starts at byte 2: [ssid][6 callsign chars].
    final from = _readCallsign(data, 2);
    if (from.isEmpty) return null;

    int pos = 9;
    if (pos >= data.length) return null;

    String to = '';
    String text = '';

    if (data[pos] == 0x01 && pos + 2 < data.length && data[pos + 1] == 0x21) {
      // Broadcast variant: 01 21 LL <bytes>.
      final len = data[pos + 2];
      final start = pos + 3;
      final end = start + len;
      if (end > data.length) return null;
      text = utf8.decode(data.sublist(start, end), allowMalformed: true);
    } else if (data[pos] == 0x07 &&
        pos + 1 < data.length &&
        data[pos + 1] == 0x21 &&
        pos + 9 < data.length) {
      // Direct variant: 07 21 <6-char addressee> 02 <text>.
      to = _readCallsign(data, pos + 2, length: 6);
      if (data[pos + 8] != 0x02) return null;
      final start = pos + 9;
      text = utf8.decode(data.sublist(start), allowMalformed: true);
    } else {
      return null;
    }

    return BenshiTextMessage(
      to: to,
      from: from,
      text: text,
      raw: Uint8List.fromList(data),
    );
  }

  /// Read a callsign starting at [offset]. The default 7-byte block
  /// has a 1-byte SSID byte (offset+0) followed by 6 ASCII callsign
  /// chars (offset+1..offset+6). Pass ``length: 6`` for the embedded
  /// addressee form which omits the SSID byte and is just 6 ASCII
  /// chars.
  static String _readCallsign(Uint8List data, int offset, {int length = 7}) {
    if (offset + length > data.length) return '';
    final start = length == 7 ? offset + 1 : offset;
    final end = length == 7 ? offset + 7 : offset + 6;
    return utf8
        .decode(data.sublist(start, end), allowMalformed: true)
        .trim();
  }

  @override
  String toString() =>
      to.isEmpty ? '[$from broadcast] $text' : '[$from → $to] $text';
}
