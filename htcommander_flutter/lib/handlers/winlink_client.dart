import '../core/data_broker_client.dart';

/// Connection state for the Winlink client.
enum WinlinkConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Stub Winlink client for initial release.
///
/// Port of HTCommander.Core/WinlinkClient.cs — methods are placeholders
/// that will be implemented when radio protocol integration is complete.
class WinlinkClient {
  final DataBrokerClient _broker = DataBrokerClient();
  WinlinkConnectionState _state = WinlinkConnectionState.disconnected;

  /// Current connection state.
  WinlinkConnectionState get state => _state;

  WinlinkClient() {
    _broker.subscribe(1, 'WinlinkSync', _onWinlinkSync);
    _broker.subscribe(1, 'WinlinkDisconnect', _onWinlinkDisconnect);
  }

  void _onWinlinkSync(int deviceId, String name, Object? data) {
    _broker.logInfo('WinlinkClient: sync not yet implemented');
    _setState(WinlinkConnectionState.connecting);
    // Stub: would initiate Winlink session here
    _setState(WinlinkConnectionState.disconnected);
  }

  void _onWinlinkDisconnect(int deviceId, String name, Object? data) {
    _broker.logInfo('WinlinkClient: disconnect not yet implemented');
    _setState(WinlinkConnectionState.disconnecting);
    _setState(WinlinkConnectionState.disconnected);
  }

  void _setState(WinlinkConnectionState newState) {
    _state = newState;
    _broker.dispatch(1, 'WinlinkState', _state.name, store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}
