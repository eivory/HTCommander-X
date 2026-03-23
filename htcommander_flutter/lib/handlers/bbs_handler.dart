import '../core/data_broker_client.dart';

/// A BBS station entry.
class BbsStation {
  final String callSign;
  DateTime lastSeen;
  int packetsIn;
  int packetsOut;
  int bytesIn;
  int bytesOut;

  BbsStation({
    required this.callSign,
    DateTime? lastSeen,
    this.packetsIn = 0,
    this.packetsOut = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
  }) : lastSeen = lastSeen ?? DateTime.now();
}

/// Manages BBS station tracking.
///
/// Simplified stub port of HTCommander.Core/BbsHandler.cs
class BbsHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<BbsStation> _stations = [];

  BbsHandler() {
    _broker.subscribe(1, 'CreateBbs', _onCreateBbs);
    _broker.subscribe(1, 'RemoveBbs', _onRemoveBbs);
    _broker.subscribe(1, 'GetBbsStatus', _onGetBbsStatus);
  }

  void _onCreateBbs(int deviceId, String name, Object? data) {
    if (data is! String) return;
    // Check for duplicate
    for (final station in _stations) {
      if (station.callSign == data) return;
    }
    final station = BbsStation(callSign: data);
    _stations.add(station);
    _broker.dispatch(1, 'BbsCreated', station, store: false);
    _dispatchList();
  }

  void _onRemoveBbs(int deviceId, String name, Object? data) {
    if (data is! String) return;
    final removed = _stations.where((s) => s.callSign == data).toList();
    _stations.removeWhere((s) => s.callSign == data);
    for (final station in removed) {
      _broker.dispatch(1, 'BbsRemoved', station, store: false);
    }
    _dispatchList();
  }

  void _onGetBbsStatus(int deviceId, String name, Object? data) {
    _dispatchList();
  }

  void _dispatchList() {
    _broker.dispatch(1, 'BbsList', List<BbsStation>.from(_stations),
        store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}
