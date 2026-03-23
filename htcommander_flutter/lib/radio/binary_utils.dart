import 'dart:typed_data';

/// Big-endian binary read/write utilities.
/// Port of HTCommander.Core/radio/Utils.cs (GetShort, GetInt, SetShort, SetInt).
class BinaryUtils {
  /// Reads a big-endian 16-bit unsigned value from [d] at position [p].
  static int getShort(Uint8List d, int p) {
    if (p < 0 || p + 1 >= d.length) {
      throw ArgumentError('getShort: bounds check failed');
    }
    return (d[p] << 8) | d[p + 1];
  }

  /// Reads a big-endian 32-bit value from [d] at position [p].
  static int getInt(Uint8List d, int p) {
    if (p < 0 || p + 3 >= d.length) {
      throw ArgumentError('getInt: bounds check failed');
    }
    return (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];
  }

  /// Writes a big-endian 16-bit value [v] into [d] at position [p].
  static void setShort(Uint8List d, int p, int v) {
    if (p < 0 || p + 1 >= d.length) {
      throw ArgumentError('setShort: bounds check failed');
    }
    d[p] = (v >> 8) & 0xFF;
    d[p + 1] = v & 0xFF;
  }

  /// Writes a big-endian 32-bit value [v] into [d] at position [p].
  static void setInt(Uint8List d, int p, int v) {
    if (p < 0 || p + 3 >= d.length) {
      throw ArgumentError('setInt: bounds check failed');
    }
    d[p] = (v >> 24) & 0xFF;
    d[p + 1] = (v >> 16) & 0xFF;
    d[p + 2] = (v >> 8) & 0xFF;
    d[p + 3] = v & 0xFF;
  }

  /// Converts a byte list to a hex string.
  static String bytesToHex(Uint8List bytes, [int offset = 0, int? length]) {
    final len = length ?? (bytes.length - offset);
    if (offset < 0 || offset + len > bytes.length) {
      throw ArgumentError('bytesToHex: bounds check failed');
    }
    final sb = StringBuffer();
    for (var i = offset; i < offset + len; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  /// Converts a hex string to bytes.
  static Uint8List hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
