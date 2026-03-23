/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'ax25_address.dart';
import '../models/tnc_data_fragment.dart';

/// Authentication state for APRS packets.
enum AuthState {
  unknown,
  failed,
  success,
  none,
}

/// AX.25 frame type constants.
/// Values match the C# FrameType enum bit patterns exactly.
class FrameType {
  FrameType._();

  // Information frame
  static const int iFrame = 0;
  static const int iFrameMask = 1;

  // Supervisory frame and subtypes
  static const int sFrame = 1;
  static const int sFrameRR = 1; // Receive Ready
  static const int sFrameRNR = 1 | (1 << 2); // Receive Not Ready
  static const int sFrameREJ = 1 | (1 << 3); // Reject
  static const int sFrameSREJ = 1 | (1 << 2) | (1 << 3); // Selective Reject
  static const int sFrameMask = 1 | (1 << 2) | (1 << 3);

  // Unnumbered frame and subtypes
  static const int uFrame = 3;
  static const int uFrameSABM =
      3 | (1 << 2) | (1 << 3) | (1 << 5); // Set Async Balanced Mode
  static const int uFrameSABME =
      3 | (1 << 3) | (1 << 5) | (1 << 6); // SABM for modulo 128
  static const int uFrameDISC = 3 | (1 << 6); // Disconnect
  static const int uFrameDM = 3 | (1 << 2) | (1 << 3); // Disconnected Mode
  static const int uFrameUA = 3 | (1 << 5) | (1 << 6); // Acknowledge
  static const int uFrameFRMR = 3 | (1 << 2) | (1 << 7); // Frame Reject
  static const int uFrameUI = 3; // Information
  static const int uFrameXID =
      3 | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7); // Exchange ID
  static const int uFrameTEST =
      3 | (1 << 5) | (1 << 6) | (1 << 7); // Test
  static const int uFrameMask =
      3 | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7);
  static const int aCRH = 0x80; // C/R Bit Hardened
}

/// AX.25 protocol definition bitmasks.
class Defs {
  Defs._();

  static const int flag =
      (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6);

  // Address field - SSID subfield bitmasks
  static const int aCRH = 1 << 7;
  static const int aRR = (1 << 5) | (1 << 6);
  static const int aSSID = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4);

  // Control field bitmasks
  static const int pf = 1 << 4; // Poll/Final
  static const int ns = (1 << 1) | (1 << 2) | (1 << 3); // N(S)
  static const int nr = (1 << 5) | (1 << 6) | (1 << 7); // N(R)
  static const int pfModulo128 = 1 << 8;
  static const int nsModulo128 = 127 << 1;
  static const int nrModulo128 = 127 << 9;

  // Protocol ID field bitmasks
  static const int pidX25 = 1;
  static const int pidCtcpip = (1 << 1) | (1 << 2);
  static const int pidUctcpip = (1 << 0) | (1 << 1) | (1 << 2);
  static const int pidSegf = 1 << 4;
  static const int pidTexnet = (1 << 0) | (1 << 1) | (1 << 6) | (1 << 7);
  static const int pidLqp = (1 << 2) | (1 << 6) | (1 << 7);
  static const int pidAtalk = (1 << 1) | (1 << 3) | (1 << 6) | (1 << 7);
  static const int pidAtalkArp =
      (1 << 0) | (1 << 1) | (1 << 3) | (1 << 6) | (1 << 7);
  static const int pidArpaip = (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7);
  static const int pidArpaar =
      (1 << 0) | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7);
  static const int pidFlexnet =
      (1 << 1) | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7);
  static const int pidNetrom =
      (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7);
  static const int pidNone = (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7);
  static const int pidEsc = 255;
}

/// AX.25 packet — decoded frame with addresses, control, and payload.
/// Port of HTCommander.Core/radio/AX25Packet.cs
class AX25Packet {
  DateTime time;
  bool confirmed;
  int messageId;
  int channelId;
  String channelName;
  int frameSize;
  bool incoming;
  bool sent;
  AuthState authState;

  // Content of the packet
  List<AX25Address> addresses;
  bool pollFinal;
  bool command;
  int type; // FrameType constant
  int nr;
  int ns;
  int pid;
  bool modulo128;
  String? dataStr;
  Uint8List? data;

  // Tag and deadline for message send limiting
  String? tag;
  DateTime deadline;

  /// Primary constructor matching C# (addresses, nr, ns, pollFinal, command, type, [data]).
  AX25Packet({
    required this.addresses,
    this.nr = 0,
    this.ns = 0,
    this.pollFinal = false,
    this.command = false,
    this.type = FrameType.iFrame,
    this.data,
    this.pid = 240,
    DateTime? time,
  })  : time = time ?? DateTime.now(),
        confirmed = false,
        messageId = 0,
        channelId = 0,
        channelName = '',
        frameSize = 0,
        incoming = false,
        sent = false,
        authState = AuthState.unknown,
        modulo128 = false,
        deadline = DateTime(9999, 12, 31);

  /// Construct from addresses + dataStr + time (U_FRAME_UI default).
  AX25Packet.fromDataStr({
    required this.addresses,
    required this.dataStr,
    required this.time,
  })  : type = FrameType.uFrameUI,
        pid = 240,
        confirmed = false,
        messageId = 0,
        channelId = 0,
        channelName = '',
        frameSize = 0,
        incoming = false,
        sent = false,
        authState = AuthState.unknown,
        pollFinal = false,
        command = false,
        nr = 0,
        ns = 0,
        modulo128 = false,
        deadline = DateTime(9999, 12, 31);

  /// Construct from addresses + raw data + time (U_FRAME_UI default).
  AX25Packet.fromData({
    required this.addresses,
    required this.data,
    required this.time,
  })  : type = FrameType.uFrameUI,
        pid = 240,
        confirmed = false,
        messageId = 0,
        channelId = 0,
        channelName = '',
        frameSize = 0,
        incoming = false,
        sent = false,
        authState = AuthState.unknown,
        pollFinal = false,
        command = false,
        nr = 0,
        ns = 0,
        modulo128 = false,
        deadline = DateTime(9999, 12, 31);

  /// Compare two packets for equality (addresses, control fields, data).
  bool isSame(AX25Packet p) {
    if (p.dataStr != dataStr) return false;
    if (p.addresses.isEmpty || addresses.isEmpty) return false;
    final addrCount = min(2, min(p.addresses.length, addresses.length));
    for (int i = 0; i < addrCount; i++) {
      if (!p.addresses[i].isSame(addresses[i])) return false;
    }
    if (p.pollFinal != pollFinal) return false;
    if (p.command != command) return false;
    if (p.nr != nr) return false;
    if (p.ns != ns) return false;
    if (p.pid != pid) return false;
    if (p.modulo128 != modulo128) return false;
    return true;
  }

  /// Decode an AX.25 packet from a TNC data fragment.
  /// Returns null on malformed input.
  static AX25Packet? decodeAx25Packet(TncDataFragment frame) {
    final data = frame.data;
    if (data.length < 6) return null;

    // Decode the address headers
    int i = 0;
    bool done = false;
    final addresses = <AX25Address>[];
    do {
      if (i + 7 > data.length) return null;
      final (addr, last) = AX25Address.decodeAx25Address(data, i);
      if (addr == null) return null;
      if (addresses.length >= 10) return null; // AX.25 spec max
      addresses.add(addr);
      done = last;
      i += 7;
    } while (!done);
    if (addresses.isEmpty) return null;

    final bool command = addresses[0].crBit1;
    final bool modulo128 = !addresses[0].crBit2;
    if (data.length < (i + 1)) return null;

    // Decode control and PID
    int control = data[i++];
    bool pollFinal = false;
    int type;
    int pid = 0;
    int nr = 0;
    int ns = 0;

    if ((control & FrameType.uFrame) == FrameType.uFrame) {
      // Unnumbered frame
      pollFinal = ((control & Defs.pf) >> 4) != 0;
      type = control & FrameType.uFrameMask;
      if (type == FrameType.uFrameUI) {
        if (data.length <= i) return null;
        pid = data[i++];
      }
      // XID and TEST: parse but no special handling yet
    } else if ((control & FrameType.uFrame) == FrameType.sFrame) {
      // Supervisory frame
      type = control & FrameType.sFrameMask;
      if (modulo128) {
        if (data.length <= i) return null;
        control |= (data[i++] << 8);
        nr = (control & Defs.nrModulo128) >> 8;
        pollFinal = ((control & Defs.pf) >> 7) != 0;
      } else {
        nr = (control & Defs.nr) >> 5;
        pollFinal = ((control & Defs.pf) >> 4) != 0;
      }
    } else if ((control & 1) == FrameType.iFrame) {
      // Information frame
      type = FrameType.iFrame;
      if (modulo128) {
        if (data.length <= i) return null;
        control |= (data[i++] << 8);
        nr = (control & Defs.nrModulo128) >> 8;
        ns = (control & Defs.nsModulo128) >> 1;
        pollFinal = ((control & Defs.pf) >> 7) != 0;
      } else {
        nr = (control & Defs.nr) >> 5;
        ns = (control & Defs.ns) >> 1;
        pollFinal = ((control & Defs.pf) >> 4) != 0;
      }
      if (data.length <= i) return null;
      pid = data[i++];
    } else {
      return null; // Invalid packet
    }

    // Extract payload
    String? xdataStr;
    Uint8List? xdata;
    final payloadLen = data.length - i;
    if (payloadLen > 65536) return null; // Reject unreasonably large payloads
    if (payloadLen > 0) {
      xdataStr = utf8.decode(data.sublist(i, i + payloadLen), allowMalformed: true);
      xdata = Uint8List.fromList(data.sublist(i, i + payloadLen));
    }

    final packet = AX25Packet.fromDataStr(
      addresses: addresses,
      dataStr: xdataStr,
      time: frame.time,
    );
    packet.data = xdata;
    packet.command = command;
    packet.modulo128 = modulo128;
    packet.pollFinal = pollFinal;
    packet.type = type;
    packet.pid = pid;
    packet.nr = nr;
    packet.ns = ns;
    packet.channelId = frame.channelId;
    packet.channelName = frame.channelName;
    packet.incoming = frame.incoming;
    packet.frameSize = data.length;
    return packet;
  }

  int _getControl() {
    int control = type;
    if (type == FrameType.iFrame ||
        (type & FrameType.uFrame) == FrameType.sFrame) {
      control |= (nr << (modulo128 ? 9 : 5));
    }
    if (type == FrameType.iFrame) {
      control |= (ns << 1);
    }
    if (pollFinal) {
      control |= (1 << (modulo128 ? 8 : 4));
    }
    return control;
  }

  /// Serialize the packet to bytes. Returns null if addresses are invalid.
  Uint8List? toByteArray() {
    if (addresses.isEmpty) return null;

    Uint8List? dataBytes;
    int dataBytesLen = 0;
    if (data != null) {
      dataBytes = data;
      dataBytesLen = data!.length;
    } else if (dataStr != null && dataStr!.isNotEmpty) {
      dataBytes = Uint8List.fromList(utf8.encode(dataStr!));
      dataBytesLen = dataBytes.length;
    }

    // Compute packet size & control bits
    int packetSize = (7 * addresses.length) +
        (modulo128 ? 2 : 1) +
        dataBytesLen;
    if (type == FrameType.iFrame || type == FrameType.uFrameUI) {
      packetSize++; // PID is present
    }
    final rdata = Uint8List(packetSize);
    final control = _getControl();

    // Write addresses
    int i = 0;
    for (int j = 0; j < addresses.length; j++) {
      final a = addresses[j];
      a.crBit1 = false;
      a.crBit2 = true;
      a.crBit3 = true;
      if (j == 0) a.crBit1 = command;
      if (j == 1) {
        a.crBit1 = !command;
        a.crBit2 = modulo128 ? false : true;
      }
      final ab = a.toByteArray(j == (addresses.length - 1));
      if (ab == null) return null;
      rdata.setRange(i, i + 7, ab);
      i += 7;
    }

    // Write control byte(s)
    rdata[i++] = control & 0xFF;
    if (modulo128) rdata[i++] = (control >> 8) & 0xFF;

    // Write PID if needed
    if (type == FrameType.iFrame || type == FrameType.uFrameUI) {
      rdata[i++] = pid;
    }

    // Write data
    if (dataBytesLen > 0 && dataBytes != null) {
      rdata.setRange(i, i + dataBytesLen, dataBytes);
    }

    return rdata;
  }

  @override
  String toString() {
    final buf = StringBuffer();
    for (final a in addresses) {
      buf.write('[${a.toString()}]');
    }
    buf.write(': $data');
    return buf.toString();
  }
}
