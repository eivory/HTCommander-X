import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/radio/binary_utils.dart';
import 'package:htcommander_flutter/radio/radio_enums.dart';
import 'package:htcommander_flutter/radio/models/radio_dev_info.dart';
import 'package:htcommander_flutter/radio/models/radio_channel_info.dart';
import 'package:htcommander_flutter/radio/models/radio_settings.dart';
import 'package:htcommander_flutter/radio/models/radio_ht_status.dart';
import 'package:htcommander_flutter/radio/models/radio_position.dart';
import 'package:htcommander_flutter/radio/models/tnc_data_fragment.dart';

void main() {
  group('RadioDevInfo', () {
    test('parses valid message', () {
      // Build a 15-byte message with known values
      final msg = Uint8List(15);
      msg[5] = 0x01; // vendor_id
      BinaryUtils.setShort(msg, 6, 0x0234); // product_id
      msg[8] = 0x03; // hw_ver
      BinaryUtils.setShort(msg, 9, 0x0100); // soft_ver
      msg[11] = 0xC0; // support_radio=1, support_medium_power=1
      msg[12] = 0x02; // support_vfo=1
      msg[13] = 128; // channel_count
      msg[14] = 0x20; // freq_range_count = 2

      final info = RadioDevInfo(msg);
      expect(info.vendorId, equals(1));
      expect(info.productId, equals(0x0234));
      expect(info.hwVer, equals(3));
      expect(info.softVer, equals(0x0100));
      expect(info.supportRadio, isTrue);
      expect(info.supportMediumPower, isTrue);
      expect(info.supportVfo, isTrue);
      expect(info.channelCount, equals(128));
      expect(info.freqRangeCount, equals(2));
    });

    test('rejects short message', () {
      expect(() => RadioDevInfo(Uint8List(14)), throwsArgumentError);
    });

    test('caps freq_range_count at 8', () {
      final msg = Uint8List(15);
      msg[14] = 0xF0; // freq_range_count = 15 (should cap at 8)
      final info = RadioDevInfo(msg);
      expect(info.freqRangeCount, equals(8));
    });
  });

  group('RadioChannelInfo', () {
    test('parse and serialize roundtrip', () {
      // Build a realistic 30-byte GAIA response
      final msg = Uint8List(30);
      msg[5] = 3; // channel_id = 3
      // tx_freq = 146520000 (0x08BC0F40), tx_mod = FM (0)
      BinaryUtils.setInt(msg, 6, 146520000);
      // rx_freq = 146520000, rx_mod = FM (0)
      BinaryUtils.setInt(msg, 10, 146520000);
      BinaryUtils.setShort(msg, 14, 0); // tx_sub_audio
      BinaryUtils.setShort(msg, 16, 0); // rx_sub_audio
      msg[18] = 0xC0; // scan=1, tx_at_max_power=1
      msg[19] = 0x00;
      // Name "CH3" at bytes 20-29
      final name = 'CH3';
      for (var i = 0; i < name.length; i++) {
        msg[20 + i] = name.codeUnitAt(i);
      }

      final ch = RadioChannelInfo.fromBytes(msg);
      expect(ch.channelId, equals(3));
      expect(ch.txFreq, equals(146520000));
      expect(ch.rxFreq, equals(146520000));
      expect(ch.txMod, equals(RadioModulationType.fm));
      expect(ch.scan, isTrue);
      expect(ch.txAtMaxPower, isTrue);
      expect(ch.nameStr, equals('CH3'));

      // Serialize and check key fields
      final bytes = ch.toByteArray();
      expect(bytes.length, equals(25));
      expect(bytes[0], equals(3)); // channel_id
    });

    test('copy constructor preserves all fields', () {
      final msg = Uint8List(30);
      msg[5] = 7;
      BinaryUtils.setInt(msg, 6, 445000000);
      BinaryUtils.setInt(msg, 10, 445000000);
      msg[18] = 0x90; // scan=1, bandwidth=wide
      final nameBytes = 'TEST'.codeUnits;
      for (var i = 0; i < nameBytes.length; i++) {
        msg[20 + i] = nameBytes[i];
      }

      final original = RadioChannelInfo.fromBytes(msg);
      final copy = RadioChannelInfo.copy(original);
      expect(copy, equals(original));
      expect(copy.nameStr, equals('TEST'));
    });

    test('rejects short message', () {
      expect(() => RadioChannelInfo.fromBytes(Uint8List(29)),
          throwsArgumentError);
    });
  });

  group('RadioSettings', () {
    test('parse and serialize roundtrip', () {
      final msg = Uint8List(25);
      msg[5] = 0x31; // channel_a lower=3, channel_b lower=1
      msg[6] = 0x85; // scan=1, squelch=5
      msg[13] = 0x08; // screen_timeout=1, vfo_x=0
      msg[14] = 0x10; // channel_a upper=0x10, channel_b upper=0x01
      msg[15] = 0x00;
      msg[16] = 0x00;
      // vfo1/2 mod_freq at 17-24 left as 0

      final settings = RadioSettings.fromBytes(msg);
      expect(settings.channelA, equals(3 + 0x10)); // 19
      expect(settings.channelB, equals(1 + ((0x10 & 0x0F) << 4))); // 1
      expect(settings.scan, isTrue);
      expect(settings.squelchLevel, equals(5));

      // Basic serialization roundtrip
      final buf = settings.toByteArray();
      expect(buf.length, equals(20)); // 25 - 5 header bytes
      expect(buf[0], equals(msg[5])); // first byte preserved
    });

    test('toByteArrayWithChannels modifies correct bytes', () {
      final msg = Uint8List(25);
      msg[6] = 0x40; // aghfp_call_mode=1
      final settings = RadioSettings.fromBytes(msg);

      final buf = settings.toByteArrayWithChannels(5, 3, 1, true, 7);
      expect(buf[0], equals((5 << 4) | 3)); // channel_a=5, channel_b=3
      expect(buf[1] & 0x80, equals(0x80)); // scan=true
      expect(buf[1] & 0x40, equals(0x40)); // aghfp preserved
      expect(buf[1] & 0x30, equals(0x10)); // double_channel=1
      expect(buf[1] & 0x0F, equals(7)); // squelch=7
    });

    test('copy constructor', () {
      final msg = Uint8List(25);
      msg[6] = 0x83;
      final original = RadioSettings.fromBytes(msg);
      final copy = RadioSettings.copy(original);
      expect(copy.scan, equals(original.scan));
      expect(copy.squelchLevel, equals(original.squelchLevel));
    });

    test('rejects short message', () {
      expect(
          () => RadioSettings.fromBytes(Uint8List(24)), throwsArgumentError);
    });
  });

  group('RadioHtStatus', () {
    test('parse minimal 7-byte message', () {
      final msg = Uint8List(7);
      msg[5] = 0xC2; // power_on=1, in_tx=1, scan=1
      msg[6] = 0x30; // curr_ch_id_lower=3

      final status = RadioHtStatus.fromBytes(msg);
      expect(status.isPowerOn, isTrue);
      expect(status.isInTx, isTrue);
      expect(status.isScan, isTrue);
      expect(status.currChIdLower, equals(3));
      expect(status.rssi, equals(0)); // not present
    });

    test('parse extended 9-byte message', () {
      final msg = Uint8List(9);
      msg[5] = 0x80; // power_on=1
      msg[6] = 0x50; // curr_ch_id_lower=5
      msg[7] = 0xA0; // rssi=10
      msg[8] = 0x08; // curr_channel_id_upper=2

      final status = RadioHtStatus.fromBytes(msg);
      expect(status.isPowerOn, isTrue);
      expect(status.rssi, equals(10));
      expect(status.currChannelIdUpper, equals(2));
      expect(status.currChId, equals((2 << 4) + 5)); // 37
    });

    test('serialize roundtrip', () {
      final msg = Uint8List(9);
      msg[5] = 0xB0; // power_on=1, sq=1, in_rx=1
      msg[6] = 0x28; // curr_ch_id_lower=2, gps_locked=1
      msg[7] = 0x50; // rssi=5
      msg[8] = 0x04; // curr_channel_id_upper=1

      final status = RadioHtStatus.fromBytes(msg);
      final bytes = status.toByteArray();
      expect(bytes[0] & 0x80, isNot(0)); // power_on
      expect(bytes[0] & 0x20, isNot(0)); // sq
    });

    test('copy constructor', () {
      final msg = Uint8List(9);
      msg[5] = 0xD0;
      msg[6] = 0x48;
      msg[7] = 0x70;
      msg[8] = 0x0C;
      final original = RadioHtStatus.fromBytes(msg);
      final copy = RadioHtStatus.copy(original);
      expect(copy.isPowerOn, equals(original.isPowerOn));
      expect(copy.rssi, equals(original.rssi));
      expect(copy.currChId, equals(original.currChId));
    });

    test('rejects short message', () {
      expect(
          () => RadioHtStatus.fromBytes(Uint8List(6)), throwsArgumentError);
    });
  });

  group('RadioPosition', () {
    test('parse SUCCESS position', () {
      // Build a 23-byte SUCCESS response
      final msg = Uint8List(23);
      msg[4] = 0; // SUCCESS
      // Latitude: ~40.7128 N = 40.7128 * 60 * 500 = 1221384 = 0x12A2C8
      msg[5] = 0x12;
      msg[6] = 0xA2;
      msg[7] = 0xC8;
      // Longitude: ~-74.006 = negative, two's complement 24-bit
      // -74.006 * 60 * 500 = -2220180 => 24-bit: 0x1000000 - 2220180 = 0xDE15EC
      final lonRaw = 0x1000000 - 2220180;
      msg[8] = (lonRaw >> 16) & 0xFF;
      msg[9] = (lonRaw >> 8) & 0xFF;
      msg[10] = lonRaw & 0xFF;
      // Altitude, speed, heading, time, accuracy
      msg[11] = 0;
      msg[12] = 10; // altitude 10m
      msg[13] = 0;
      msg[14] = 5; // speed 5 knots

      final pos = RadioPosition.fromBytes(msg);
      expect(pos.status, equals(RadioCommandState.success));
      // 24-bit encoding loses precision — latitude 1221384 / 60 / 500 = 40.7128
      // but integer truncation in encoding means we get approximate values
      expect(pos.latitude, closeTo(40.71, 0.01));
      expect(pos.longitude, closeTo(-74.006, 0.01));
      expect(pos.altitude, equals(10));
      expect(pos.speed, equals(5));
    });

    test('serialize roundtrip', () {
      final pos = RadioPosition.fromCoordinates(
        lat: 51.5074,
        lon: -0.1278,
        altitudeMetres: 100,
        speedKnots: 3,
        headingDegrees: 90,
        utcTime: DateTime.utc(2026, 1, 1),
      );

      final bytes = pos.toByteArray();
      expect(bytes.length, equals(18));

      // Verify lat/lon raw encoding in bytes
      final latRecon =
          (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
      expect(latRecon, equals(pos.latitudeRaw & 0xFFFFFF));
    });

    test('fromCoordinates creates valid position', () {
      final pos = RadioPosition.fromCoordinates(
        lat: 35.6762,
        lon: 139.6503,
        utcTime: DateTime.utc(2026, 3, 15),
      );
      expect(pos.isGpsLocked, isTrue);
      expect(pos.latitude, closeTo(35.6762, 0.001));
    });

    test('rejects short message', () {
      expect(
          () => RadioPosition.fromBytes(Uint8List(4)), throwsArgumentError);
    });

    test('rejects short SUCCESS message', () {
      final msg = Uint8List(6);
      msg[4] = 0; // SUCCESS but only 6 bytes
      expect(() => RadioPosition.fromBytes(msg), throwsArgumentError);
    });
  });

  group('TncDataFragment', () {
    test('parse from bytes', () {
      // final=1, with_channel=1, fragment_id=5, data=[0xAA, 0xBB], channel=7
      final msg = Uint8List(9);
      msg[5] = 0x80 | 0x40 | 5; // final=1, with_channel=1, id=5
      msg[6] = 0xAA;
      msg[7] = 0xBB;
      msg[8] = 7; // channel_id

      final frag = TncDataFragment.fromBytes(msg);
      expect(frag.finalFragment, isTrue);
      expect(frag.fragmentId, equals(5));
      expect(frag.data, equals(Uint8List.fromList([0xAA, 0xBB])));
      expect(frag.channelId, equals(7));
    });

    test('serialize roundtrip', () {
      final frag = TncDataFragment(
        finalFragment: true,
        fragmentId: 3,
        data: Uint8List.fromList([0x01, 0x02, 0x03]),
        channelId: 5,
        regionId: 0,
      );

      final bytes = frag.toByteArray();
      expect(bytes[0] & 0x80, isNot(0)); // final
      expect(bytes[0] & 0x40, isNot(0)); // with channel
      expect(bytes[0] & 0x3F, equals(3)); // fragment_id
      expect(bytes.sublist(1, 4), equals([0x01, 0x02, 0x03]));
      expect(bytes.last, equals(5)); // channel_id
    });

    test('append merges sequential fragments', () {
      final frag1 = TncDataFragment(
        finalFragment: false,
        fragmentId: 0,
        data: Uint8List.fromList([0x01, 0x02]),
        channelId: -1,
        regionId: 0,
      );
      final frag2 = TncDataFragment(
        finalFragment: true,
        fragmentId: 1,
        data: Uint8List.fromList([0x03, 0x04]),
        channelId: -1,
        regionId: 0,
      );

      final result = frag1.append(frag2);
      expect(result.data, equals([0x01, 0x02, 0x03, 0x04]));
      expect(result.finalFragment, isTrue);
    });

    test('append rejects non-sequential', () {
      final frag1 = TncDataFragment(
        finalFragment: false,
        fragmentId: 0,
        data: Uint8List.fromList([0x01]),
        channelId: -1,
        regionId: 0,
      );
      final frag3 = TncDataFragment(
        finalFragment: true,
        fragmentId: 3, // not sequential
        data: Uint8List.fromList([0x02]),
        channelId: -1,
        regionId: 0,
      );

      final result = frag1.append(frag3);
      expect(result.data, equals([0x02])); // original frag3 data only
    });

    test('rejects short message', () {
      expect(
          () => TncDataFragment.fromBytes(Uint8List(5)), throwsArgumentError);
    });
  });
}
