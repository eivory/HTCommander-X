import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/radio/binary_utils.dart';

void main() {
  group('BinaryUtils getShort/setShort', () {
    test('roundtrip 16-bit value', () {
      final buf = Uint8List(4);
      BinaryUtils.setShort(buf, 1, 0x1234);
      expect(BinaryUtils.getShort(buf, 1), equals(0x1234));
    });

    test('big-endian byte order', () {
      final buf = Uint8List.fromList([0x00, 0xAB, 0xCD, 0x00]);
      expect(BinaryUtils.getShort(buf, 1), equals(0xABCD));
    });

    test('bounds check on getShort', () {
      final buf = Uint8List(2);
      expect(() => BinaryUtils.getShort(buf, 1), throwsArgumentError);
    });

    test('bounds check on setShort', () {
      final buf = Uint8List(2);
      expect(() => BinaryUtils.setShort(buf, 1, 0), throwsArgumentError);
    });
  });

  group('BinaryUtils getInt/setInt', () {
    test('roundtrip 32-bit value', () {
      final buf = Uint8List(6);
      BinaryUtils.setInt(buf, 1, 0x12345678);
      expect(BinaryUtils.getInt(buf, 1), equals(0x12345678));
    });

    test('big-endian byte order', () {
      final buf = Uint8List.fromList([0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00]);
      expect(BinaryUtils.getInt(buf, 1), equals(0xDEADBEEF));
    });

    test('bounds check on getInt', () {
      final buf = Uint8List(4);
      expect(() => BinaryUtils.getInt(buf, 1), throwsArgumentError);
    });
  });

  group('BinaryUtils hex conversion', () {
    test('bytes to hex', () {
      final buf = Uint8List.fromList([0xFF, 0x01, 0x0A, 0xB0]);
      expect(BinaryUtils.bytesToHex(buf), equals('FF010AB0'));
    });

    test('hex to bytes', () {
      final bytes = BinaryUtils.hexToBytes('FF010AB0');
      expect(bytes, equals(Uint8List.fromList([0xFF, 0x01, 0x0A, 0xB0])));
    });

    test('hex roundtrip', () {
      final original = Uint8List.fromList([0x00, 0x7E, 0x7D, 0xFF]);
      final hex = BinaryUtils.bytesToHex(original);
      final decoded = BinaryUtils.hexToBytes(hex);
      expect(decoded, equals(original));
    });
  });
}
