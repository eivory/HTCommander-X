import 'dart:typed_data';
import '../binary_utils.dart';
import '../radio_enums.dart';

/// AX.25 packet fragment for TNC data.
/// Port of HTCommander.Core/radio/TncDataFragment.cs
class TncDataFragment {
  bool finalFragment;
  int fragmentId;
  Uint8List data;
  int regionId;
  int channelId;
  String channelName;
  bool incoming;
  DateTime time;
  FragmentEncodingType encoding;
  FragmentFrameType frameType;
  int corrections;
  String? radioMac;
  int radioDeviceId;
  String? usage;

  static const int _maxReassemblySize = 64 * 1024; // 64KB cap

  /// Construct from known values.
  TncDataFragment({
    required this.finalFragment,
    required this.fragmentId,
    required this.data,
    required this.channelId,
    required this.regionId,
  })  : channelName =
            channelId == -1 ? '' : (channelId + 1).toString(),
        incoming = false,
        time = DateTime.now(),
        encoding = FragmentEncodingType.unknown,
        frameType = FragmentFrameType.unknown,
        corrections = -1,
        radioDeviceId = 0;

  /// Parse from GAIA response bytes.
  TncDataFragment.fromBytes(Uint8List msg)
      : finalFragment = (msg[5] & 0x80) != 0,
        fragmentId = msg[5] & 0x3F,
        data = Uint8List(0),
        regionId = 0,
        channelId = -1,
        channelName = '',
        incoming = false,
        time = DateTime.now(),
        encoding = FragmentEncodingType.unknown,
        frameType = FragmentFrameType.unknown,
        corrections = -1,
        radioDeviceId = 0 {
    if (msg.length < 6) {
      throw ArgumentError(
          'TncDataFragment message too short (need >= 6 bytes)');
    }

    final withChannelId = (msg[5] & 0x40) != 0;
    final dataLen = msg.length - 6 - (withChannelId ? 1 : 0);
    if (dataLen < 0) {
      data = Uint8List(0);
      channelId = -1;
      return;
    }
    data = Uint8List.fromList(msg.sublist(6, 6 + dataLen));
    if (withChannelId) {
      channelId = msg[msg.length - 1];
    }
    channelName = channelId == -1 ? '' : (channelId + 1).toString();
  }

  /// Merge this fragment with [frame], returning the surviving fragment.
  TncDataFragment append(TncDataFragment frame) {
    if (frame.fragmentId == fragmentId + 1 && !finalFragment) {
      // Reject if merged size would exceed cap
      if (data.length + frame.data.length > _maxReassemblySize) return frame;

      final merged = Uint8List(data.length + frame.data.length);
      merged.setRange(0, data.length, data);
      merged.setRange(data.length, merged.length, frame.data);
      frame.data = merged;
      return frame;
    }
    return frame;
  }

  /// Serialize to GAIA protocol bytes.
  Uint8List toByteArray() {
    final hasChannel = channelId != -1;
    final len = 1 + data.length + (hasChannel ? 1 : 0);
    final rdata = Uint8List(len);
    if (finalFragment) rdata[0] |= 0x80;
    if (hasChannel) rdata[0] |= 0x40;
    rdata[0] |= fragmentId & 0x3F;
    rdata.setRange(1, 1 + data.length, data);
    if (hasChannel) rdata[len - 1] = channelId;
    return rdata;
  }

  String toHex() => BinaryUtils.bytesToHex(data);
}
