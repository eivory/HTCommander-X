/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:typed_data';

/// AX.25 address field (callsign + SSID + control bits).
/// Port of HTCommander.Core/radio/AX25Address.cs
class AX25Address {
  String address;
  int ssid;
  bool crBit1;
  bool crBit2;
  bool crBit3;

  AX25Address._(this.address, this.ssid)
      : crBit1 = false,
        crBit2 = false,
        crBit3 = true;

  String get callSignWithId => '$address-$ssid';

  /// Compare address and SSID only (control bits are NOT compared).
  bool isSame(AX25Address a) {
    if (address != a.address) return false;
    if (ssid != a.ssid) return false;
    return true;
  }

  /// Create an address from a callsign string and numeric SSID.
  /// Returns null if validation fails.
  static AX25Address? getAddress(String address, [int ssid = -1]) {
    if (ssid == -1) {
      // Parse "CALL-SSID" format
      if (address.length > 9) return null;
      final s = address.indexOf('-');
      int parsedSsid = 0;
      if (s == -1) {
        // No SSID, assume 0.
        if (address.length > 6) return null;
      } else {
        if (s < 1) return null;
        final ssidStr = address.substring(s + 1);
        parsedSsid = int.tryParse(ssidStr) ?? -1;
        if (parsedSsid < 0 || parsedSsid > 15) return null;
        address = address.substring(0, s);
      }
      if (address.isEmpty) return null;
      return _getAddressValidated(address, parsedSsid);
    } else {
      return _getAddressValidated(address, ssid);
    }
  }

  static AX25Address? _getAddressValidated(String address, int ssid) {
    if (address.length > 6) return null;
    if (ssid > 15 || ssid < 0) return null;
    return AX25Address._(address, ssid);
  }

  /// Decode a 7-byte AX.25 address from [data] at [index].
  /// Returns a record of the decoded address (or null) and whether this is the
  /// last address in the header.
  static (AX25Address?, bool) decodeAx25Address(Uint8List data, int index) {
    if (index + 7 > data.length) return (null, false);

    final buf = StringBuffer();
    for (int i = 0; i < 6; i++) {
      final c = data[index + i] >> 1;
      if (c < 0x20) return (null, false);
      if (c != 0x20) buf.writeCharCode(c);
      if ((data[index + i] & 0x01) != 0) return (null, false);
    }

    final ssid = (data[index + 6] >> 1) & 0x0F;
    final last = (data[index + 6] & 0x01) != 0;

    final addr = AX25Address._getAddressValidated(buf.toString(), ssid);
    if (addr == null) return (null, false);
    addr.crBit1 = (data[index + 6] & 0x80) != 0;
    addr.crBit2 = (data[index + 6] & 0x40) != 0;
    addr.crBit3 = (data[index + 6] & 0x20) != 0;
    return (addr, last);
  }

  /// Serialize to 7-byte AX.25 address field.
  /// Returns null if validation fails.
  Uint8List? toByteArray(bool last) {
    if (address.length > 6) return null;
    if (ssid > 15 || ssid < 0) return null;

    final rdata = Uint8List(7);
    final padded = address.padRight(6, ' ');
    for (int i = 0; i < 6; i++) {
      rdata[i] = padded.codeUnitAt(i) << 1;
    }
    rdata[6] = ssid << 1;
    if (crBit1) rdata[6] |= 0x80;
    if (crBit2) rdata[6] |= 0x40;
    if (crBit3) rdata[6] |= 0x20;
    if (last) rdata[6] |= 0x01;
    return rdata;
  }

  @override
  String toString() {
    if (ssid == 0) return address;
    return '$address-$ssid';
  }
}
