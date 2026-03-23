import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../radio/ax25/ax25_packet.dart';
import '../radio/aprs/aprs_packet.dart';

/// Handles incoming APRS packets — parses, stores, and dispatches events.
///
/// Port of HTCommander.Core/AprsHandler.cs (simplified for initial release)
class AprsHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<AprsEntry> _entries = [];
  static const int _maxEntries = 500;

  List<AprsEntry> get entries => List.unmodifiable(_entries);
  int get count => _entries.length;

  AprsHandler() {
    _broker.subscribe(
        DataBroker.allDevices, 'UniqueDataFrame', _onUniqueDataFrame);
  }

  void _onUniqueDataFrame(int deviceId, String name, Object? data) {
    if (data is! AX25Packet) return;
    final ax25 = data;

    // Only process UI frames with data
    if (ax25.type != FrameType.uFrameUI || ax25.dataStr == null) return;
    if (ax25.addresses.length < 2) return;

    // Parse APRS
    final destCallsign = ax25.addresses[0].toString();
    final aprs = AprsPacket.parse(ax25.dataStr!, destCallsign);
    if (aprs == null) return;

    final entry = AprsEntry(
      time: ax25.time,
      from: ax25.addresses.length > 1 ? ax25.addresses[1].toString() : '',
      to: ax25.addresses[0].toString(),
      packet: aprs,
      ax25Packet: ax25,
      incoming: ax25.incoming,
    );

    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }

    _broker.dispatch(1, 'AprsEntry', entry, store: false);
    _broker.dispatch(1, 'AprsStoreUpdated', _entries.length, store: false);
  }

  void clear() {
    _entries.clear();
    _broker.dispatch(1, 'AprsStoreUpdated', 0, store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}

/// A stored APRS entry with metadata.
class AprsEntry {
  final DateTime time;
  final String from;
  final String to;
  final AprsPacket packet;
  final AX25Packet ax25Packet;
  final bool incoming;

  const AprsEntry({
    required this.time,
    required this.from,
    required this.to,
    required this.packet,
    required this.ax25Packet,
    this.incoming = true,
  });
}
