import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../radio/ax25/ax25_packet.dart';
import '../radio/models/tnc_data_fragment.dart';

/// Deduplicates incoming AX.25 data frames.
///
/// Port of HTCommander.Core/FrameDeduplicator.cs
/// Listens for DataFrame events, decodes AX.25, and dispatches
/// UniqueDataFrame only for non-duplicate packets.
class FrameDeduplicator {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<_RecentFrame> _recentFrames = [];
  static const int _maxRecent = 100;
  static const Duration _dedupeWindow = Duration(seconds: 30);

  FrameDeduplicator() {
    _broker.subscribe(DataBroker.allDevices, 'DataFrame', _onDataFrame);
  }

  void _onDataFrame(int deviceId, String name, Object? data) {
    if (data is! TncDataFragment) return;
    final fragment = data;

    // Decode AX.25
    final packet = AX25Packet.decodeAx25Packet(fragment);
    if (packet == null) return;

    // Check for duplicates
    final now = DateTime.now();
    _recentFrames.removeWhere(
        (f) => now.difference(f.time) > _dedupeWindow);

    for (final recent in _recentFrames) {
      if (recent.packet.isSame(packet)) return; // Duplicate
    }

    // Not a duplicate — store and dispatch
    _recentFrames.add(_RecentFrame(packet, now));
    if (_recentFrames.length > _maxRecent) {
      _recentFrames.removeAt(0);
    }

    // Carry over fragment metadata
    packet.channelId = fragment.channelId;
    packet.channelName = fragment.channelName;
    packet.incoming = fragment.incoming;

    _broker.dispatch(deviceId, 'UniqueDataFrame', packet, store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}

class _RecentFrame {
  final AX25Packet packet;
  final DateTime time;
  const _RecentFrame(this.packet, this.time);
}
