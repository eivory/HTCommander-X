import 'dart:typed_data';
import 'binary_utils.dart';

/// GAIA protocol frame encoding/decoding.
///
/// Frame format:
/// [0xFF] [0x01] [flags] [body_length] [group_hi] [group_lo] [cmd_hi] [cmd_lo] [body...]
///
/// - body_length = cmd body only (excludes 4-byte command header), max 255
/// - Total frame = body_length + 8
/// - Reply bit: cmd_hi | 0x80
class GaiaProtocol {
  /// Decodes a GAIA frame from [data] starting at [index] within [len] bytes.
  ///
  /// Returns a tuple of (bytesConsumed, commandPayload).
  /// - bytesConsumed > 0: a frame was decoded, commandPayload contains the 4-byte header + body
  /// - bytesConsumed == 0: not enough data yet (need more bytes)
  /// - bytesConsumed < 0: invalid frame header (not 0xFF 0x01)
  static (int consumed, Uint8List? cmd) decode(Uint8List data, int index, int len) {
    if (len < 8) return (0, null);
    if (data[index] != 0xFF || data[index + 1] != 0x01) return (-1, null);

    final payloadLen = data[index + 3];
    final hasChecksum = data[index + 2] & 1;
    final totalLen = payloadLen + 8 + hasChecksum;
    if (totalLen > len) return (0, null);

    final cmd = Uint8List(4 + payloadLen);
    cmd.setRange(0, cmd.length, data, index + 4);
    return (totalLen, cmd);
  }

  /// Encodes a command payload into a GAIA frame.
  ///
  /// [cmd] must be at least 4 bytes (group_hi, group_lo, cmd_hi, cmd_lo + optional body).
  /// Returns the framed bytes: [0xFF, 0x01, 0x00, bodyLen, ...cmd].
  static Uint8List encode(Uint8List cmd) {
    final payloadLen = cmd.length - 4;
    if (payloadLen < 0 || payloadLen > 255) return cmd;

    final bytes = Uint8List(cmd.length + 4);
    bytes[0] = 0xFF;
    bytes[1] = 0x01;
    bytes[2] = 0x00; // flags: no checksum
    bytes[3] = payloadLen;
    bytes.setRange(4, 4 + cmd.length, cmd);
    return bytes;
  }

  /// Builds a command payload from group, command ID, and optional body data.
  static Uint8List buildCommand(int group, int commandId, [Uint8List? body]) {
    final bodyLen = body?.length ?? 0;
    final cmd = Uint8List(4 + bodyLen);
    BinaryUtils.setShort(cmd, 0, group);
    BinaryUtils.setShort(cmd, 2, commandId);
    if (body != null) {
      cmd.setRange(4, 4 + bodyLen, body);
    }
    return cmd;
  }

  /// Builds a command payload with a single byte of data.
  static Uint8List buildCommandByte(int group, int commandId, int dataByte) {
    final cmd = Uint8List(5);
    BinaryUtils.setShort(cmd, 0, group);
    BinaryUtils.setShort(cmd, 2, commandId);
    cmd[4] = dataByte & 0xFF;
    return cmd;
  }

  /// Builds a command payload with an int (big-endian) body.
  static Uint8List buildCommandInt(int group, int commandId, int value) {
    final cmd = Uint8List(8);
    BinaryUtils.setShort(cmd, 0, group);
    BinaryUtils.setShort(cmd, 2, commandId);
    BinaryUtils.setInt(cmd, 4, value);
    return cmd;
  }
}
