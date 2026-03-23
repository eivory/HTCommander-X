import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/radio/ax25/ax25_address.dart';
import 'package:htcommander_flutter/radio/ax25/ax25_packet.dart';
import 'package:htcommander_flutter/radio/models/tnc_data_fragment.dart';

void main() {
  group('AX25Address', () {
    test('parse callsign without SSID', () {
      final addr = AX25Address.getAddress('KD2ABC');
      expect(addr, isNotNull);
      expect(addr!.address, equals('KD2ABC'));
      expect(addr.ssid, equals(0));
      expect(addr.toString(), equals('KD2ABC'));
    });

    test('parse callsign with SSID', () {
      final addr = AX25Address.getAddress('KD2ABC-7');
      expect(addr, isNotNull);
      expect(addr!.address, equals('KD2ABC'));
      expect(addr.ssid, equals(7));
      expect(addr.callSignWithId, equals('KD2ABC-7'));
    });

    test('rejects invalid callsign', () {
      expect(AX25Address.getAddress('TOOLONGCALL'), isNull);
      expect(AX25Address.getAddress('KD2ABC-16'), isNull); // SSID > 15
      expect(AX25Address.getAddress(''), isNull);
    });

    test('encode and decode roundtrip', () {
      final addr = AX25Address.getAddress('W1AW', 5)!;
      final bytes = addr.toByteArray(true);
      expect(bytes, isNotNull);
      expect(bytes!.length, equals(7));

      final (decoded, last) = AX25Address.decodeAx25Address(
          Uint8List.fromList(bytes), 0);
      expect(decoded, isNotNull);
      expect(decoded!.address, equals('W1AW'));
      expect(decoded.ssid, equals(5));
      expect(last, isTrue);
    });

    test('isSame comparison', () {
      final a = AX25Address.getAddress('KD2ABC', 7)!;
      final b = AX25Address.getAddress('KD2ABC', 7)!;
      final c = AX25Address.getAddress('KD2ABC', 8)!;
      expect(a.isSame(b), isTrue);
      expect(a.isSame(c), isFalse);
    });
  });

  group('AX25Packet', () {
    test('build and encode UI frame', () {
      final src = AX25Address.getAddress('KD2ABC', 7)!;
      final dst = AX25Address.getAddress('APRS', 0)!;
      final packet = AX25Packet.fromDataStr(
        addresses: [dst, src],
        dataStr: '>Hello World',
        time: DateTime.now(),
      );

      final bytes = packet.toByteArray();
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(14)); // 2 addresses (14) + control + pid + data
    });

    test('decode from TncDataFragment', () {
      // Build a valid AX.25 UI frame manually
      final dst = AX25Address.getAddress('APRS', 0)!;
      final src = AX25Address.getAddress('KD2ABC', 7)!;

      // Encode addresses
      final dstBytes = dst.toByteArray(false)!;
      final srcBytes = src.toByteArray(true)!;

      // Build frame: addresses + control(0x03=UI) + pid(0xF0) + data
      final dataBytes = utf8.encode('>Test APRS');
      final frame = Uint8List(14 + 2 + dataBytes.length);
      frame.setRange(0, 7, dstBytes);
      frame.setRange(7, 14, srcBytes);
      frame[14] = 0x03; // UI frame
      frame[15] = 0xF0; // No L3 protocol
      frame.setRange(16, 16 + dataBytes.length, dataBytes);

      // Wrap in TncDataFragment
      final fragment = TncDataFragment(
        finalFragment: true,
        fragmentId: 0,
        data: frame,
        channelId: 1,
        regionId: 0,
      );

      final packet = AX25Packet.decodeAx25Packet(fragment);
      expect(packet, isNotNull);
      expect(packet!.addresses.length, equals(2));
      expect(packet.addresses[0].address, equals('APRS'));
      expect(packet.addresses[1].address, equals('KD2ABC'));
      expect(packet.dataStr, equals('>Test APRS'));
      expect(packet.type, equals(FrameType.uFrameUI));
      expect(packet.pid, equals(0xF0));
    });

    test('rejects too-short data', () {
      final fragment = TncDataFragment(
        finalFragment: true,
        fragmentId: 0,
        data: Uint8List(5), // Too short
        channelId: -1,
        regionId: 0,
      );
      expect(AX25Packet.decodeAx25Packet(fragment), isNull);
    });

    test('encode then decode roundtrip', () {
      final src = AX25Address.getAddress('W1AW', 0)!;
      final dst = AX25Address.getAddress('APRS', 0)!;
      final original = AX25Packet.fromDataStr(
        addresses: [dst, src],
        dataStr: '!4903.50N/07201.75W-Test',
        time: DateTime.now(),
      );

      final bytes = original.toByteArray()!;
      final fragment = TncDataFragment(
        finalFragment: true,
        fragmentId: 0,
        data: bytes,
        channelId: 0,
        regionId: 0,
      );

      final decoded = AX25Packet.decodeAx25Packet(fragment);
      expect(decoded, isNotNull);
      expect(decoded!.dataStr, equals('!4903.50N/07201.75W-Test'));
      expect(decoded.addresses[0].address, equals('APRS'));
      expect(decoded.addresses[1].address, equals('W1AW'));
    });
  });
}
