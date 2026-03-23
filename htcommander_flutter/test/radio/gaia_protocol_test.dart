import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/radio/gaia_protocol.dart';
import 'package:htcommander_flutter/radio/binary_utils.dart';

void main() {
  group('GaiaProtocol encode', () {
    test('encodes command with no body', () {
      // Command: group=2, cmd=4 (GET_DEV_INFO), no body
      final cmd = Uint8List(4);
      BinaryUtils.setShort(cmd, 0, 2); // group
      BinaryUtils.setShort(cmd, 2, 4); // cmd
      final frame = GaiaProtocol.encode(cmd);

      expect(frame.length, equals(8)); // 4 header + 4 cmd
      expect(frame[0], equals(0xFF));
      expect(frame[1], equals(0x01));
      expect(frame[2], equals(0x00)); // flags
      expect(frame[3], equals(0));    // body length (cmd body = 0)
      expect(frame[4], equals(0));    // group hi
      expect(frame[5], equals(2));    // group lo
      expect(frame[6], equals(0));    // cmd hi
      expect(frame[7], equals(4));    // cmd lo
    });

    test('encodes command with body', () {
      // Command: group=2, cmd=23 (SET_VOLUME), body=[7]
      final cmd = Uint8List(5);
      BinaryUtils.setShort(cmd, 0, 2);
      BinaryUtils.setShort(cmd, 2, 23);
      cmd[4] = 7;
      final frame = GaiaProtocol.encode(cmd);

      expect(frame.length, equals(9)); // 4 + 5
      expect(frame[3], equals(1)); // body length = 1
      expect(frame[8], equals(7)); // body byte
    });
  });

  group('GaiaProtocol decode', () {
    test('decodes valid frame', () {
      // Frame: FF 01 00 01 00 02 80 04 03
      // group=2, cmd=0x8004 (reply to GET_DEV_INFO), body=[3]
      final frame = Uint8List.fromList([
        0xFF, 0x01, 0x00, 0x01, // header: flags=0, bodyLen=1
        0x00, 0x02, 0x80, 0x04, // group=2, cmd=0x8004
        0x03, // body
      ]);

      final (consumed, cmd) = GaiaProtocol.decode(frame, 0, frame.length);
      expect(consumed, equals(9)); // 1 + 8
      expect(cmd, isNotNull);
      expect(cmd!.length, equals(5)); // 4 header + 1 body
      expect(BinaryUtils.getShort(cmd, 0), equals(2)); // group
      expect(BinaryUtils.getShort(cmd, 2), equals(0x8004)); // cmd with reply bit
      expect(cmd[4], equals(3)); // body
    });

    test('returns 0 for incomplete frame', () {
      final frame = Uint8List.fromList([0xFF, 0x01, 0x00, 0x05]); // need more
      final (consumed, cmd) = GaiaProtocol.decode(frame, 0, frame.length);
      expect(consumed, equals(0));
      expect(cmd, isNull);
    });

    test('returns -1 for invalid header', () {
      final frame = Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final (consumed, cmd) = GaiaProtocol.decode(frame, 0, frame.length);
      expect(consumed, equals(-1));
      expect(cmd, isNull);
    });

    test('returns 0 for too-short data', () {
      final frame = Uint8List.fromList([0xFF, 0x01, 0x00]);
      final (consumed, cmd) = GaiaProtocol.decode(frame, 0, frame.length);
      expect(consumed, equals(0));
    });
  });

  group('GaiaProtocol encode/decode roundtrip', () {
    test('roundtrip with body', () {
      final original = GaiaProtocol.buildCommand(2, 14, Uint8List.fromList([1, 2, 3]));
      final frame = GaiaProtocol.encode(original);
      final (consumed, decoded) = GaiaProtocol.decode(frame, 0, frame.length);

      expect(consumed, greaterThan(0));
      expect(decoded, equals(original));
    });

    test('roundtrip no body', () {
      final original = GaiaProtocol.buildCommand(2, 10);
      final frame = GaiaProtocol.encode(original);
      final (consumed, decoded) = GaiaProtocol.decode(frame, 0, frame.length);

      expect(consumed, greaterThan(0));
      expect(decoded, equals(original));
    });
  });

  group('GaiaProtocol build helpers', () {
    test('buildCommandByte', () {
      final cmd = GaiaProtocol.buildCommandByte(2, 23, 7);
      expect(cmd.length, equals(5));
      expect(BinaryUtils.getShort(cmd, 0), equals(2));
      expect(BinaryUtils.getShort(cmd, 2), equals(23));
      expect(cmd[4], equals(7));
    });

    test('buildCommandInt', () {
      final cmd = GaiaProtocol.buildCommandInt(2, 6, 1);
      expect(cmd.length, equals(8));
      expect(BinaryUtils.getShort(cmd, 0), equals(2));
      expect(BinaryUtils.getShort(cmd, 2), equals(6));
      expect(BinaryUtils.getInt(cmd, 4), equals(1));
    });
  });
}
