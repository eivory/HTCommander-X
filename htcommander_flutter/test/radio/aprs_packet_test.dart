import 'package:flutter_test/flutter_test.dart';
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
}
