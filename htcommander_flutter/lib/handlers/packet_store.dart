import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../radio/ax25/ax25_packet.dart';

/// Stores received AX.25 packets for the Packets screen.
///
/// Port of HTCommander.Core/PacketStore.cs
class PacketStore {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<AX25Packet> _packets = [];
  static const int _maxPackets = 1000;

  List<AX25Packet> get packets => List.unmodifiable(_packets);
  int get count => _packets.length;

  PacketStore() {
    _broker.subscribe(
        DataBroker.allDevices, 'UniqueDataFrame', _onUniqueDataFrame);
  }

  void _onUniqueDataFrame(int deviceId, String name, Object? data) {
    if (data is! AX25Packet) return;
    final packet = data;

    _packets.add(packet);
    if (_packets.length > _maxPackets) {
      _packets.removeAt(0);
    }

    _broker.dispatch(1, 'PacketStoreUpdated', _packets.length, store: false);
  }

  void clear() {
    _packets.clear();
    _broker.dispatch(1, 'PacketStoreUpdated', 0, store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}
