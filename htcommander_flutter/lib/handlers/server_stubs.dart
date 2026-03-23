import '../core/data_broker_client.dart';

/// Stub for the MCP server (desktop-only feature).
///
/// Subscribes to McpServerEnabled and logs start/stop.
class McpServerStub {
  final DataBrokerClient _broker = DataBrokerClient();

  McpServerStub() {
    _broker.subscribe(0, 'McpServerEnabled', _onEnabledChanged);
  }

  void _onEnabledChanged(int deviceId, String name, Object? data) {
    final enabled = data is int && data == 1;
    if (enabled) {
      _broker.logInfo('McpServer: start requested (stub — not available on mobile)');
    } else {
      _broker.logInfo('McpServer: stop requested (stub)');
    }
  }

  void dispose() {
    _broker.dispose();
  }
}

/// Stub for the web server (desktop-only feature).
///
/// Subscribes to WebServerEnabled and logs start/stop.
class WebServerStub {
  final DataBrokerClient _broker = DataBrokerClient();

  WebServerStub() {
    _broker.subscribe(0, 'WebServerEnabled', _onEnabledChanged);
  }

  void _onEnabledChanged(int deviceId, String name, Object? data) {
    final enabled = data is int && data == 1;
    if (enabled) {
      _broker.logInfo('WebServer: start requested (stub — not available on mobile)');
    } else {
      _broker.logInfo('WebServer: stop requested (stub)');
    }
  }

  void dispose() {
    _broker.dispose();
  }
}

/// Stub for the rigctld server (desktop-only feature).
///
/// Subscribes to RigctldServerEnabled and logs start/stop.
class RigctldServerStub {
  final DataBrokerClient _broker = DataBrokerClient();

  RigctldServerStub() {
    _broker.subscribe(0, 'RigctldServerEnabled', _onEnabledChanged);
  }

  void _onEnabledChanged(int deviceId, String name, Object? data) {
    final enabled = data is int && data == 1;
    if (enabled) {
      _broker.logInfo('RigctldServer: start requested (stub — not available on mobile)');
    } else {
      _broker.logInfo('RigctldServer: stop requested (stub)');
    }
  }

  void dispose() {
    _broker.dispose();
  }
}

/// Stub for the AGWPE server (desktop-only feature).
///
/// Subscribes to AgwpeServerEnabled and logs start/stop.
class AgwpeServerStub {
  final DataBrokerClient _broker = DataBrokerClient();

  AgwpeServerStub() {
    _broker.subscribe(0, 'AgwpeServerEnabled', _onEnabledChanged);
  }

  void _onEnabledChanged(int deviceId, String name, Object? data) {
    final enabled = data is int && data == 1;
    if (enabled) {
      _broker.logInfo('AgwpeServer: start requested (stub — not available on mobile)');
    } else {
      _broker.logInfo('AgwpeServer: stop requested (stub)');
    }
  }

  void dispose() {
    _broker.dispose();
  }
}
