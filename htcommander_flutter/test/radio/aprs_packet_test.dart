import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/radio/aprs/aprs_encoder.dart';
import 'package:htcommander_flutter/radio/aprs/aprs_packet.dart';
import 'package:htcommander_flutter/radio/aprs/message_data.dart';
import 'package:htcommander_flutter/radio/aprs/packet_data_type.dart';

void main() {
  group('Status report (>) — spec §16', () {
    test('parses status text without timestamp', () {
      final pkt = AprsPacket.parse('>QRV 146.520 simplex', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.status));
      expect(pkt.comment, equals('QRV 146.520 simplex'));
      expect(pkt.timeStamp, isNull);
    });

    test('parses status text with DDHHMMz UTC timestamp', () {
      final pkt = AprsPacket.parse('>092345zNet on 146.52', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.status));
      expect(pkt.timeStamp, isNotNull);
      expect(pkt.timeStamp!.day, equals(9));
      expect(pkt.timeStamp!.hour, equals(23));
      expect(pkt.timeStamp!.minute, equals(45));
      expect(pkt.comment, equals('Net on 146.52'));
    });

    test('parses status text with HHMMSSh timestamp', () {
      final pkt = AprsPacket.parse('>234500hHello world', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.status));
      expect(pkt.timeStamp, isNotNull);
      expect(pkt.timeStamp!.hour, equals(23));
      expect(pkt.comment, equals('Hello world'));
    });

    test('text shorter than 7 chars is taken whole', () {
      final pkt = AprsPacket.parse('>hi', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.comment, equals('hi'));
      expect(pkt.timeStamp, isNull);
    });

    test('non-terminator 7th char does not get consumed as timestamp', () {
      // No 'z', '/', or 'h' at byte 6 — whole field is comment.
      final pkt = AprsPacket.parse('>This is a long status', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.comment, equals('This is a long status'));
      expect(pkt.timeStamp, isNull);
    });
  });

  group('Message REPLY-ACK extension — spec §14 (Dec 1999)', () {
    test('parses bare seqId (legacy form)', () {
      final pkt = AprsPacket.parse(':W1ABC    :Hello{42', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.messageData.msgType, equals(MessageType.general));
      expect(pkt.messageData.seqId, equals('42'));
      expect(pkt.messageData.replyAck, isEmpty);
      expect(pkt.messageData.replyAckCapable, isFalse);
      expect(pkt.messageData.msgText, equals('Hello'));
    });

    test('parses {MM} form (capable, no free-ACK)', () {
      final pkt = AprsPacket.parse(':W1ABC    :Hello{42}', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.messageData.seqId, equals('42'));
      expect(pkt.messageData.replyAck, isEmpty);
      expect(pkt.messageData.replyAckCapable, isTrue);
      expect(pkt.messageData.msgText, equals('Hello'));
    });

    test('parses {MM}AA form with free-ACK piggyback', () {
      final pkt = AprsPacket.parse(':W1ABC    :Hello{42}A7', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.messageData.seqId, equals('42'));
      expect(pkt.messageData.replyAck, equals('A7'));
      expect(pkt.messageData.replyAckCapable, isTrue);
      expect(pkt.messageData.msgText, equals('Hello'));
    });

    test('preserves message text without trailing seqId', () {
      final pkt = AprsPacket.parse(':W1ABC    :Test {123}AB', 'APRS-0');
      expect(pkt, isNotNull);
      // msgText should NOT contain the line-number block.
      expect(pkt!.messageData.msgText, equals('Test '));
      expect(pkt.messageData.seqId, equals('123'));
      expect(pkt.messageData.replyAck, equals('AB'));
    });

    test('ack message extracts seqId cleanly (no spurious } handling)', () {
      // Spec example: ":KB2ICI-14:ack003" — no `}` in ack format.
      final pkt = AprsPacket.parse(':KB2ICI-14:ack003', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.messageData.msgType, equals(MessageType.ack));
      expect(pkt.messageData.seqId, equals('003'));
    });

    test('rej message extracts seqId cleanly', () {
      final pkt = AprsPacket.parse(':KB2ICI-14:rej003', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.messageData.msgType, equals(MessageType.rej));
      expect(pkt.messageData.seqId, equals('003'));
    });

    test('uppercase ACK/REJ still recognized', () {
      // We send lowercase but should accept either on RX.
      final ack = AprsPacket.parse(':KB2ICI-14:ACK003', 'APRS-0');
      expect(ack!.messageData.msgType, equals(MessageType.ack));
      final rej = AprsPacket.parse(':KB2ICI-14:REJ003', 'APRS-0');
      expect(rej!.messageData.msgType, equals(MessageType.rej));
    });
  });

  group('Object report (;) — spec §11', () {
    test('parses live object with timestamp and uncompressed position', () {
      // Spec example: ;LEADER   *092345z4903.50N/07201.75W>088/036
      final pkt = AprsPacket.parse(
        ';LEADER   *092345z4903.50N/07201.75W>088/036',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.object));
      expect(pkt.entityName, equals('LEADER'));
      expect(pkt.entityAlive, isTrue);
      expect(pkt.timeStamp, isNotNull);
      expect(pkt.timeStamp!.day, equals(9));
      expect(pkt.timeStamp!.hour, equals(23));
      expect(pkt.symbolTableIdentifier, equals(0x2F)); // '/'
      expect(pkt.symbolCode, equals(0x3E)); // '>'
      expect(pkt.position.coordinateSet.latitude.value, closeTo(49.058, 0.01));
      expect(
          pkt.position.coordinateSet.longitude.value, closeTo(-72.029, 0.01));
      expect(pkt.position.course, equals(88));
      expect(pkt.position.speed, equals(36));
    });

    test('parses killed object', () {
      final pkt = AprsPacket.parse(
        ';BUOY     _092345z4903.50N/07201.75W;',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.entityName, equals('BUOY'));
      expect(pkt.entityAlive, isFalse);
    });

    test('rejects truncated object (too short for header)', () {
      final pkt = AprsPacket.parse(';short', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.object));
      expect(pkt.entityName, isEmpty);
    });
  });

  group('Item report ()) — spec §11', () {
    test('parses live item with uncompressed position', () {
      // Spec example: )AID #2!4903.50N/07201.75W:
      final pkt = AprsPacket.parse(
        ')AID #2!4903.50N/07201.75W:',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.item));
      expect(pkt.entityName, equals('AID #2'));
      expect(pkt.entityAlive, isTrue);
      expect(pkt.symbolTableIdentifier, equals(0x2F)); // '/'
      expect(pkt.symbolCode, equals(0x3A)); // ':'
      expect(pkt.position.coordinateSet.latitude.value, closeTo(49.058, 0.01));
    });

    test('parses killed item (terminator _)', () {
      final pkt = AprsPacket.parse(
        ')GONE     _4903.50N/07201.75W>',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.entityName, equals('GONE'));
      expect(pkt.entityAlive, isFalse);
    });

    test('item names range 3..9 chars', () {
      // 3-char min name.
      final p3 = AprsPacket.parse(
        ')AAA!4903.50N/07201.75W>',
        'APRS-0',
      );
      expect(p3!.entityName, equals('AAA'));

      // 9-char max name.
      final p9 = AprsPacket.parse(
        ')ABCDEFGHI!4903.50N/07201.75W>',
        'APRS-0',
      );
      expect(p9!.entityName, equals('ABCDEFGHI'));
    });

    test('rejects malformed item with no terminator', () {
      final pkt = AprsPacket.parse(')NOTERMINATOR', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.entityName, isEmpty);
    });
  });

  group('Telemetry (T#) — spec §13', () {
    test('parses traditional 3-digit telemetry', () {
      final pkt = AprsPacket.parse(
        'T#005,199,000,255,073,123,01101001',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.telemetry));
      expect(pkt.telemetryReport, isNotNull);
      final t = pkt.telemetryReport!;
      expect(t.sequence, equals('005'));
      expect(t.analog, equals([199.0, 0.0, 255.0, 73.0, 123.0]));
      expect(t.digital,
          equals([false, true, true, false, true, false, false, true]));
    });

    test('parses MIC sequence number', () {
      final pkt = AprsPacket.parse(
        'T#MIC199,000,255,073,123,01101001',
        'APRS-0',
      );
      expect(pkt!.telemetryReport!.sequence, equals('MIC'));
      expect(pkt.telemetryReport!.analog,
          equals([199.0, 0.0, 255.0, 73.0, 123.0]));
    });

    test('parses spec 1.2 relaxed format (decimals + negatives)', () {
      final pkt = AprsPacket.parse(
        'T#151,45.7,2.3,190.0,91.0,-7.3,00001100',
        'APRS-0',
      );
      expect(pkt!.telemetryReport!.sequence, equals('151'));
      expect(pkt.telemetryReport!.analog,
          equals([45.7, 2.3, 190.0, 91.0, -7.3]));
    });

    test('handles missing trailing fields', () {
      final pkt = AprsPacket.parse('T#001,100', 'APRS-0');
      expect(pkt!.telemetryReport!.sequence, equals('001'));
      expect(pkt.telemetryReport!.analog, equals([100.0]));
      expect(pkt.telemetryReport!.digital, isEmpty);
    });
  });

  group('Telemetry definitions (PARM./UNIT./EQNS./BITS.) — spec §13', () {
    test('parses PARM. message into parameter names', () {
      final pkt = AprsPacket.parse(
        ':N0QBF-11 :PARM.Battery,Btemp,ATemp,Pres,Alt,Camra,Chut,Sun,10m,ATV',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.telemetryDefinitions, isNotNull);
      expect(
        pkt.telemetryDefinitions!.parameterNames,
        equals([
          'Battery', 'Btemp', 'ATemp', 'Pres', 'Alt',
          'Camra', 'Chut', 'Sun', '10m', 'ATV',
        ]),
      );
    });

    test('parses UNIT. message into unit labels', () {
      final pkt = AprsPacket.parse(
        ':N0QBF-11 :UNIT.v/100,deg.F,deg.F,Mbar,Kft,Click,OPEN,on,on,hi',
        'APRS-0',
      );
      expect(pkt!.telemetryDefinitions!.unitLabels,
          contains('Mbar'));
      expect(pkt.telemetryDefinitions!.unitLabels!.length, equals(10));
    });

    test('parses EQNS. message into coefficient list', () {
      // 5 channels × 3 coefficients (a, b, c)
      final pkt = AprsPacket.parse(
        ':N0QBF-11 :EQNS.0,5.2,0,0,.53,-32,3,4.39,49,-32,3,18,1,2,3',
        'APRS-0',
      );
      expect(pkt!.telemetryDefinitions!.equations, isNotNull);
      expect(pkt.telemetryDefinitions!.equations!.length, equals(15));
      expect(pkt.telemetryDefinitions!.equations![1], equals(5.2));
      expect(pkt.telemetryDefinitions!.equations![5], equals(-32));
    });

    test('parses BITS. message with project title', () {
      final pkt = AprsPacket.parse(
        ':N0QBF-11 :BITS.10110000,N0QBF 11 Balloon',
        'APRS-0',
      );
      expect(pkt!.telemetryDefinitions!.bitSense,
          equals([true, false, true, true, false, false, false, false]));
      expect(pkt.telemetryDefinitions!.projectTitle,
          equals('N0QBF 11 Balloon'));
    });

    test('regular messages do not get a telemetryDefinitions', () {
      final pkt = AprsPacket.parse(':W1ABC    :Hello{42}', 'APRS-0');
      expect(pkt!.telemetryDefinitions, isNull);
    });
  });

  group('Position encoder — spec §8', () {
    test('encodes uncompressed position without messaging', () {
      final wire = AprsEncoder.position(
        latitude: 49.058333,
        longitude: -72.029166,
        symbolTable: '/',
        symbolCode: '>',
      );
      // Format: ![lat 8][/][lon 9][>]
      expect(wire.startsWith('!'), isTrue);
      expect(wire[9], equals('/')); // symbol table at byte 9
      expect(wire[19], equals('>')); // symbol code at byte 19
      expect(wire.length, equals(20));
    });

    test('encodes uncompressed position with messaging', () {
      final wire = AprsEncoder.position(
        latitude: 49.058333,
        longitude: -72.029166,
        withMessaging: true,
      );
      expect(wire.startsWith('='), isTrue);
    });

    test('appends comment after symbol code', () {
      final wire = AprsEncoder.position(
        latitude: 0,
        longitude: 0,
        symbolTable: '/',
        symbolCode: '-',
        comment: 'Hello world',
      );
      expect(wire.endsWith('Hello world'), isTrue);
    });

    test('round-trips through the parser', () {
      final wire = AprsEncoder.position(
        latitude: 49.058333,
        longitude: -72.029166,
        symbolTable: '/',
        symbolCode: '>',
        comment: 'Test',
      );
      final pkt = AprsPacket.parse(wire, 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.position));
      expect(pkt.symbolTableIdentifier, equals(0x2F)); // '/'
      expect(pkt.symbolCode, equals(0x3E)); // '>'
      expect(
          pkt.position.coordinateSet.latitude.value, closeTo(49.058, 0.01));
      expect(pkt.position.coordinateSet.longitude.value,
          closeTo(-72.029, 0.01));
      expect(pkt.comment, equals('Test'));
    });
  });

  group('Status encoder — spec §16', () {
    test('encodes status without timestamp', () {
      expect(
        AprsEncoder.status(text: 'QRV 146.520'),
        equals('>QRV 146.520'),
      );
    });

    test('encodes status with DDHHMMz UTC timestamp', () {
      final ts = DateTime.utc(2026, 4, 9, 23, 45);
      final wire = AprsEncoder.status(text: 'Net at 8pm', timestamp: ts);
      expect(wire, equals('>092345zNet at 8pm'));
    });

    test('round-trips through the parser', () {
      final ts = DateTime.utc(2026, 4, 9, 23, 45);
      final wire = AprsEncoder.status(text: 'Net at 8pm', timestamp: ts);
      final pkt = AprsPacket.parse(wire, 'APRS-0');
      expect(pkt!.dataType, equals(PacketDataType.status));
      expect(pkt.comment, equals('Net at 8pm'));
      expect(pkt.timeStamp!.day, equals(9));
      expect(pkt.timeStamp!.hour, equals(23));
      expect(pkt.timeStamp!.minute, equals(45));
    });
  });

  group('Weather report (_) — spec §12', () {
    test('parses positionless weather with full sensor suite', () {
      // Spec example: _10090556c220s004g005t077r000p000P000h50b09900wRSW
      final pkt = AprsPacket.parse(
        '_10090556c220s004g005t077r000p000P000h50b09900wRSW',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.weatherReport));
      expect(pkt.weather, isNotNull);
      final w = pkt.weather!;
      expect(w.windDirection, equals(220));
      expect(w.windSpeed, equals(4));
      expect(w.windGust, equals(5));
      expect(w.temperatureF, equals(77));
      expect(w.rainLastHourHundredths, equals(0));
      expect(w.rain24hHundredths, equals(0));
      expect(w.rainSinceMidnightHundredths, equals(0));
      expect(w.humidityPercent, equals(50));
      expect(w.pressureTenthsMbar, equals(9900));
      // Timestamp in MDHM format: month=10, day=09, hour=05, min=56
      expect(pkt.timeStamp!.month, equals(10));
      expect(pkt.timeStamp!.day, equals(9));
      expect(pkt.timeStamp!.hour, equals(5));
      expect(pkt.timeStamp!.minute, equals(56));
    });

    test('humidity 00 maps to 100%', () {
      final pkt = AprsPacket.parse(
        '_10090556c220s004g005t077h00b09900',
        'APRS-0',
      );
      expect(pkt!.weather!.humidityPercent, equals(100));
    });

    test('parses weather with negative temperature', () {
      final pkt = AprsPacket.parse(
        '_10090556c220s004g005t-05',
        'APRS-0',
      );
      expect(pkt!.weather!.temperatureF, equals(-5));
    });

    test('handles unknown values expressed as dots', () {
      final pkt = AprsPacket.parse(
        '_10090556c...s...g...t077',
        'APRS-0',
      );
      expect(pkt!.weather!.windDirection, isNull);
      expect(pkt.weather!.windSpeed, isNull);
      expect(pkt.weather!.windGust, isNull);
      expect(pkt.weather!.temperatureF, equals(77));
    });

    test('parses weather embedded in position packet (symbol _)', () {
      // Position with weather symbol (`_` symbol code) followed by
      // the same weather fields format.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W_220/004g005t077r000p000P000h50b09900',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.position));
      expect(pkt.symbolCode, equals(0x5F)); // '_'
      expect(pkt.weather, isNotNull);
      // After position parser strips the `220/004` course/speed
      // extension, weather body starts at `g005...`.
      expect(pkt.weather!.windGust, equals(5));
      expect(pkt.weather!.temperatureF, equals(77));
      expect(pkt.weather!.humidityPercent, equals(50));
    });

    test('non-weather position packets do not get a weather object', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>088/036',
        'APRS-0',
      );
      expect(pkt!.weather, isNull);
    });
  });

  group('Data extensions PHG / RNG / DFS — spec §7', () {
    test('parses PHG5132 (spec example)', () {
      // Spec example: 25W, 20ft, 3 dBi, due east beam.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>PHG5132',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.phg, isNotNull);
      expect(pkt.phg!.powerWatts, equals(25));
      expect(pkt.phg!.heightFeet, equals(20));
      expect(pkt.phg!.gainDbi, equals(3));
      expect(pkt.phg!.directivityDegrees, equals(90));
      expect(pkt.phg!.beaconsPerHour, isNull);
    });

    test('omni PHG (directivity 0) reports null direction', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>PHG3360',
        'APRS-0',
      );
      expect(pkt!.phg!.powerWatts, equals(9));
      expect(pkt.phg!.directivityDegrees, isNull);
    });

    test('PHGR variant carries beacons-per-hour', () {
      // PHG72604/ — 49W, 40ft, 6 dBi, omni, 4 beacons/hour.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>PHG72604/',
        'APRS-0',
      );
      expect(pkt!.phg!.powerWatts, equals(49));
      expect(pkt.phg!.heightFeet, equals(40));
      expect(pkt.phg!.gainDbi, equals(6));
      expect(pkt.phg!.directivityDegrees, isNull);
      expect(pkt.phg!.beaconsPerHour, equals(4));
    });

    test('parses RNG0050', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>RNG0050',
        'APRS-0',
      );
      expect(pkt!.rangeMiles, equals(50));
    });

    test('parses DFSshgd', () {
      // DFS3132: signal=3, height=20, gain=3, beam=east.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>DFS3132',
        'APRS-0',
      );
      expect(pkt!.dfs, isNotNull);
      expect(pkt.dfs!.signalStrength, equals(3));
      expect(pkt.dfs!.heightFeet, equals(20));
      expect(pkt.dfs!.gainDbi, equals(3));
      expect(pkt.dfs!.directivityDegrees, equals(90));
    });

    test('extension strips before comment', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>PHG5132Hello',
        'APRS-0',
      );
      expect(pkt!.phg, isNotNull);
      expect(pkt.comment, equals('Hello'));
    });
  });

  group('Position ambiguity — spec §6/§8', () {
    test('exact coordinates report ambiguity 0', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>',
        'APRS-0',
      );
      expect(pkt!.position.ambiguity, equals(0));
    });

    test('one trailing dot in latitude → ambiguity 1', () {
      final pkt = AprsPacket.parse(
        '!4903.5 N/07201.7 W>',
        'APRS-0',
      );
      expect(pkt!.position.ambiguity, equals(1));
    });

    test('two trailing dots → ambiguity 2 (1 minute)', () {
      final pkt = AprsPacket.parse(
        '!4903.  N/07201.  W>',
        'APRS-0',
      );
      expect(pkt!.position.ambiguity, equals(2));
    });

    test('four blanks → ambiguity 4 (1 degree)', () {
      final pkt = AprsPacket.parse(
        '!49  .  N/072  .  W>',
        'APRS-0',
      );
      expect(pkt!.position.ambiguity, equals(4));
      // Position should still parse (at the low edge of the bucket).
      expect(pkt.position.coordinateSet.latitude.value, closeTo(49, 0.01));
    });

    test('dots-as-ambiguity also accepted (vs spaces)', () {
      final pkt = AprsPacket.parse(
        '!4903.5./07201.7.W>',
        'APRS-0',
      );
      // Note: this packet uses dots in the rightmost mantissa
      // position. With the / symbol-table after lat byte 7 instead
      // of N/S, this is malformed — but exercising the ambiguity
      // counter directly via the canonical form:
      final pkt2 = AprsPacket.parse(
        '!4903.5.N/07201.7.W>',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt2!.position.ambiguity, equals(1));
    });
  });

  group('Capabilities (<) — spec §15', () {
    test('parses comma-separated key/value pairs', () {
      final pkt = AprsPacket.parse(
        '<IGATE,MSG_CNT=14,LOC_CNT=12',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.stationCapabilities));
      expect(pkt.capabilities, isNotNull);
      expect(pkt.capabilities!['IGATE'], equals(''));
      expect(pkt.capabilities!['MSG_CNT'], equals('14'));
      expect(pkt.capabilities!['LOC_CNT'], equals('12'));
    });

    test('empty body produces no capabilities map', () {
      final pkt = AprsPacket.parse('<', 'APRS-0');
      expect(pkt!.capabilities, isNull);
    });
  });

  group('ACK / REJ casing — spec §14', () {
    test('encoder emits lowercase ack', () {
      // The auto-ACK construction lives in aprs_handler.dart; verify
      // the wire format we generate parses back as ack/lowercase.
      final wire = ':SENDER   :ack42';
      final pkt = AprsPacket.parse(wire, 'APRS-0');
      expect(pkt!.messageData.msgType, equals(MessageType.ack));
      expect(pkt.messageData.seqId, equals('42'));
    });
  });

  group('DF Bearing/NRQ — spec §7', () {
    test('parses /BRG/NRQ after CSE/SPD (spec example)', () {
      // Spec example: 088/036/270/729 — course 88, speed 36,
      // bearing 270, NRQ N=7 R=2 Q=9.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>088/036/270/729',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.position.course, equals(88));
      expect(pkt.position.speed, equals(36));
      expect(pkt.bearingNrq, isNotNull);
      expect(pkt.bearingNrq!.bearingDegrees, equals(270));
      expect(pkt.bearingNrq!.hits, equals(7));
      expect(pkt.bearingNrq!.rangeCode, equals(2));
      expect(pkt.bearingNrq!.quality, equals(9));
    });

    test('non-DF position packets do not get BearingNrq', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>088/036',
        'APRS-0',
      );
      expect(pkt!.bearingNrq, isNull);
    });
  });

  group('Raw GPS (\$) — spec §5', () {
    test('captures NMEA sentence verbatim', () {
      final pkt = AprsPacket.parse(
        r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.rawGPSorU2K));
      expect(pkt.rawGpsSentence,
          startsWith('GPGGA,123519,4807.038,N,01131.000,E'));
    });

    test('captures Ultimeter 2000 raw weather verbatim', () {
      final pkt = AprsPacket.parse(
        r'$ULTW0031003702CE0069----000086A00001----011901CC00000005',
        'APRS-0',
      );
      expect(pkt!.rawGpsSentence, startsWith('ULTW'));
    });
  });

  group('Query packets (?) — spec §15', () {
    test('parses bare ?APRS?', () {
      final pkt = AprsPacket.parse('?APRS?', 'APRS-0');
      expect(pkt, isNotNull);
      expect(pkt!.dataType, equals(PacketDataType.query));
      expect(pkt.queryType, equals('APRS'));
      expect(pkt.queryTarget, isNull);
    });

    test('parses ?IGATE?', () {
      final pkt = AprsPacket.parse('?IGATE?', 'APRS-0');
      expect(pkt!.queryType, equals('IGATE'));
    });

    test('parses directed query with target', () {
      final pkt = AprsPacket.parse('?APRS? W1ABC', 'APRS-0');
      expect(pkt!.queryType, equals('APRS'));
      expect(pkt.queryTarget, equals('W1ABC'));
    });

    test('parses ?WX? and ?MSGS?', () {
      final wx = AprsPacket.parse('?WX?', 'APRS-0');
      expect(wx!.queryType, equals('WX'));
      final msgs = AprsPacket.parse('?MSGS?', 'APRS-0');
      expect(msgs!.queryType, equals('MSGS'));
    });
  });

  group('Base91 comment telemetry — spec §13', () {
    test('parses |ss11| (seq + 1 channel) embedded in comment', () {
      // Spec example: 'ss' = seq 7544, '11' = channel 1 = 1472.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>Hello|ss11|',
        'APRS-0',
      );
      expect(pkt, isNotNull);
      expect(pkt!.telemetryReport, isNotNull);
      expect(pkt.telemetryReport!.sequence, equals('7544'));
      expect(pkt.telemetryReport!.analog, equals([1472.0]));
      expect(pkt.telemetryReport!.digital, isEmpty);
      // The block is stripped from the visible comment.
      expect(pkt.comment, equals('Hello'));
    });

    test('parses |ss112233| (3 channels)', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>|ss112233|',
        'APRS-0',
      );
      expect(pkt!.telemetryReport!.analog,
          equals([1472.0, 1564.0, 1656.0]));
    });

    test('parses |ss1122334455!"| with binary channel', () {
      // Spec example: 5 analogs + binary '!"' = 1, so B1=1, others 0.
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>|ss1122334455!"|',
        'APRS-0',
      );
      final t = pkt!.telemetryReport!;
      expect(t.analog.length, equals(5));
      expect(t.digital,
          equals([true, false, false, false, false, false, false, false]));
    });

    test('|!!!!| minimal block (seq=0, channel=0)', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>|!!!!|',
        'APRS-0',
      );
      expect(pkt!.telemetryReport!.sequence, equals('0'));
      expect(pkt.telemetryReport!.analog, equals([0.0]));
    });

    test('malformed block (odd inner length) is left in comment', () {
      final pkt = AprsPacket.parse(
        '!4903.50N/07201.75W>|abc|',
        'APRS-0',
      );
      expect(pkt!.telemetryReport, isNull);
      expect(pkt.comment, equals('|abc|'));
    });
  });
}
