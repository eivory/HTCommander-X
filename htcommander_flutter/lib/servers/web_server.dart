/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import 'http_server.dart';

/// WebSocket audio bridge for mobile PTT and bidirectional audio streaming.
///
/// Protocol: 0x01+PCM=audio, 0x02=PTT start, 0x03=PTT stop,
///           0x04=PTT rejected, 0x05=PTT acquired.
/// Port of HTCommander.Core/Utils/WebAudioBridge.cs.
class WebAudioBridge {
  final DataBrokerClient _broker = DataBrokerClient();
  final Map<String, WebSocket> _clients = {};
  final Map<String, int> _clientLastAudioTime = {};
  static const int _maxAudioFramesPerSecond = 200;
  static const int _maxClients = 20;
  int _activeRadioId = -1;
  String? _pttOwner;
  Timer? _pttSilenceTimer;
  Timer? _pttTimeoutTimer;
  int _lastAudioFromPttOwner = 0;
  static const int _pttTimeoutMs = 30000;

  WebAudioBridge() {
    _broker.subscribe(1, 'ConnectedRadios', _onConnectedRadiosChanged);
    _broker.subscribe(DataBroker.allDevices, 'AudioDataAvailable',
        _onAudioDataAvailable);
  }

  void _onConnectedRadiosChanged(int deviceId, String name, Object? data) {
    _activeRadioId = _getFirstConnectedRadioId();
  }

  void _onAudioDataAvailable(int deviceId, String name, Object? data) {
    if (_clients.isEmpty || deviceId < 100) return;
    if (data is! Map) return;

    try {
      final isTransmit = data['Transmit'] == true;
      if (isTransmit) return;

      final pcm = data['Data'];
      final length = data['Length'] as int? ?? 0;
      if (pcm == null || length <= 0) return;

      Uint8List pcmBytes;
      if (pcm is Uint8List) {
        pcmBytes = length < pcm.length ? pcm.sublist(0, length) : pcm;
      } else if (pcm is List<int>) {
        pcmBytes = Uint8List.fromList(
            length < pcm.length ? pcm.sublist(0, length) : pcm);
      } else {
        return;
      }

      // Prepend 0x01 command byte
      final frame = Uint8List(1 + pcmBytes.length);
      frame[0] = 0x01;
      frame.setRange(1, frame.length, pcmBytes);

      for (final entry in _clients.entries) {
        final ws = entry.value;
        if (ws.readyState == WebSocket.open) {
          try {
            ws.add(frame);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Handle an incoming WebSocket connection.
  Future<void> handleWebSocket(WebSocket ws) async {
    final clientId = DateTime.now().microsecondsSinceEpoch.toString();

    // Authenticate if ServerBindAll is enabled
    final bindAll = DataBroker.getValue<int>(0, 'ServerBindAll', 0) == 1;
    if (bindAll) {
      final expectedToken =
          DataBroker.getValue<String>(0, 'McpApiToken', '');
      if (expectedToken.isEmpty) {
        _log('WebSocket client rejected: API token not initialized');
        try {
          await ws.close(WebSocketStatus.policyViolation, 'Service unavailable');
        } catch (_) {}
        return;
      }

      bool authenticated = false;
      try {
        final authMsg = await ws.first.timeout(const Duration(seconds: 10));
        if (authMsg is String && authMsg.startsWith('AUTH:')) {
          final providedToken = authMsg.substring(5);
          authenticated = _constantTimeEquals(
              utf8.encode(providedToken), utf8.encode(expectedToken));
        }
      } catch (_) {}

      if (!authenticated) {
        _log('WebSocket client rejected: authentication failed');
        try {
          await ws.close(WebSocketStatus.policyViolation,
              'Authentication required');
        } catch (_) {}
        return;
      }
    }

    if (_clients.length >= _maxClients) {
      _log('WebSocket client rejected: max clients reached');
      try {
        await ws.close(WebSocketStatus.policyViolation, 'Too many connections');
      } catch (_) {}
      return;
    }

    _clients[clientId] = ws;
    _log('WebSocket audio client connected: ${clientId.substring(0, 8)}');

    try {
      await for (final message in ws) {
        if (message is! List<int> || message.isEmpty) continue;

        final cmd = message[0];
        switch (cmd) {
          case 0x02: // PTT start
            _handlePttStart(clientId, ws);
          case 0x03: // PTT stop
            _handlePttStop(clientId);
          case 0x01: // Audio data
            _handleAudioData(clientId, Uint8List.fromList(message));
        }
      }
    } catch (_) {
    } finally {
      _handlePttStop(clientId);
      _clients.remove(clientId);
      _clientLastAudioTime.remove(clientId);
      _log('WebSocket audio client disconnected: ${clientId.substring(0, 8)}');
    }
  }

  void _handlePttStart(String clientId, WebSocket ws) {
    if (_pttOwner != null && _pttOwner != clientId) {
      // PTT rejected
      try {
        ws.add(Uint8List.fromList([0x04]));
      } catch (_) {}
      return;
    }

    _pttSilenceTimer?.cancel();
    _pttTimeoutTimer?.cancel();
    _pttOwner = clientId;
    _lastAudioFromPttOwner = DateTime.now().millisecondsSinceEpoch;
    _pttSilenceTimer = Timer.periodic(
        const Duration(milliseconds: 80), (_) => _dispatchSilence());
    _pttTimeoutTimer = Timer.periodic(
        const Duration(milliseconds: _pttTimeoutMs),
        (_) => _checkPttTimeout(clientId));
    _log('WebSocket PTT ON (client ${clientId.substring(0, 8)})');
    _broker.dispatch(1, 'ExternalPttState', true, store: false);

    // PTT acquired confirmation
    try {
      ws.add(Uint8List.fromList([0x05]));
    } catch (_) {}
  }

  void _handlePttStop(String clientId) {
    if (_pttOwner != clientId) return;

    _pttSilenceTimer?.cancel();
    _pttSilenceTimer = null;
    _pttTimeoutTimer?.cancel();
    _pttTimeoutTimer = null;
    _pttOwner = null;
    _log('WebSocket PTT OFF (client ${clientId.substring(0, 8)})');
    _broker.dispatch(1, 'ExternalPttState', false, store: false);
  }

  void _checkPttTimeout(String clientId) {
    if (_pttOwner != clientId) return;
    if (DateTime.now().millisecondsSinceEpoch - _lastAudioFromPttOwner >
        _pttTimeoutMs) {
      _log('WebSocket PTT auto-released (timeout)');
      _pttSilenceTimer?.cancel();
      _pttSilenceTimer = null;
      _pttTimeoutTimer?.cancel();
      _pttTimeoutTimer = null;
      _pttOwner = null;
      _broker.dispatch(1, 'ExternalPttState', false, store: false);
    }
  }

  void _handleAudioData(String clientId, Uint8List data) {
    if (_pttOwner != clientId) return;
    _lastAudioFromPttOwner = DateTime.now().millisecondsSinceEpoch;

    // Rate limit
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final minInterval = 1000 ~/ _maxAudioFramesPerSecond;
    final lastMs = _clientLastAudioTime[clientId] ?? 0;
    if (nowMs - lastMs < minInterval) return;
    _clientLastAudioTime[clientId] = nowMs;

    int radioId = _activeRadioId;
    if (radioId < 0) radioId = _getFirstConnectedRadioId();
    if (radioId < 0) return;

    final pcmLength = data.length - 1;
    if (pcmLength <= 0 || pcmLength > 19200) return; // Cap frame size

    final pcm = data.sublist(1);
    _broker.dispatch(radioId, 'TransmitVoicePCM', pcm, store: false);
  }

  void _dispatchSilence() {
    if (_pttOwner == null) return;
    int radioId = _activeRadioId;
    if (radioId < 0) radioId = _getFirstConnectedRadioId();
    if (radioId < 0) return;

    final silence = Uint8List(6400); // 100ms of 32kHz 16-bit mono silence
    _broker.dispatch(radioId, 'TransmitVoicePCM', silence, store: false);
  }

  void disconnectAll() {
    for (final ws in _clients.values) {
      try {
        ws.close();
      } catch (_) {}
    }
    _clients.clear();
    _clientLastAudioTime.clear();

    if (_pttOwner != null) {
      _pttSilenceTimer?.cancel();
      _pttSilenceTimer = null;
      _pttTimeoutTimer?.cancel();
      _pttTimeoutTimer = null;
      _pttOwner = null;
      _broker.dispatch(1, 'ExternalPttState', false, store: false);
    }
  }

  int _getFirstConnectedRadioId() {
    final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
    if (radios is List) {
      for (final item in radios) {
        if (item is Map) {
          final id = item['deviceId'] as int?;
          if (id != null && id > 0) return id;
        }
      }
    }
    return -1;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  void _log(String message) {
    _broker.logInfo(message);
  }

  void dispose() {
    disconnectAll();
    _broker.dispose();
  }
}

/// HTTP static file server + WebSocket audio bridge.
///
/// Port of HTCommander.Core/Utils/WebServer.cs.
class WebServer {
  final DataBrokerClient _broker = DataBrokerClient();
  HttpServer? _httpServer;
  int _port = 8080;
  bool _running = false;
  String _webRoot = '';
  late WebAudioBridge _audioBridge;

  WebServer() {
    _audioBridge = WebAudioBridge();

    _broker.subscribe(0, 'WebServerEnabled', _onSettingChanged);
    _broker.subscribe(0, 'WebServerPort', _onSettingChanged);
    _broker.subscribe(0, 'ServerBindAll', _onSettingChanged);

    // Default web root
    _webRoot = '${Directory.current.path}/web';

    final enabled = _broker.getValue<int>(0, 'WebServerEnabled', 0);
    if (enabled == 1) {
      _port = _broker.getValue<int>(0, 'WebServerPort', 8080);
      _start();
    }
  }

  void _onSettingChanged(int deviceId, String name, Object? data) {
    final enabled = _broker.getValue<int>(0, 'WebServerEnabled', 0);
    final newPort = _broker.getValue<int>(0, 'WebServerPort', 8080);

    if (enabled == 1) {
      if (_running && newPort != _port) {
        _stop();
        _port = newPort;
        _start();
      } else if (!_running) {
        _port = newPort;
        _start();
      }
    } else {
      if (_running) _stop();
    }
  }

  Future<void> _start() async {
    if (_running) return;
    try {
      final bindAll = _broker.getValue<int>(0, 'ServerBindAll', 0) == 1;
      final address =
          bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      _httpServer = await HttpServer.bind(address, _port, shared: true);
      _running = true;
      _log('Web server started on port $_port');

      _httpServer!.listen(
        (request) async {
          // WebSocket upgrade
          if (request.uri.path == '/ws/audio' &&
              WebSocketTransformer.isUpgradeRequest(request)) {
            try {
              final ws = await WebSocketTransformer.upgrade(request);
              await _audioBridge.handleWebSocket(ws);
            } catch (_) {}
            return;
          }

          await _handleRequest(request);
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (e) {
      _log('Web server start failed: $e');
      _running = false;
    }
  }

  void _stop() {
    if (!_running) return;
    _log('Web server stopping...');
    _running = false;
    _audioBridge.disconnectAll();
    _httpServer?.close(force: true);
    _httpServer = null;
    _log('Web server stopped');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    var urlPath = request.uri.path;
    final response = request.response;

    // API endpoint: return config for mobile web UI
    if (urlPath == '/api/config') {
      final mcpPort = _broker.getValue<int>(0, 'McpServerPort', 5678);
      final mcpEnabled = _broker.getValue<int>(0, 'McpServerEnabled', 0);
      final bindAllSetting = _broker.getValue<int>(0, 'ServerBindAll', 0);

      // When ServerBindAll, require Bearer token to access config
      final mcpToken =
          _broker.getValue<String>(0, 'McpApiToken', '');
      if (bindAllSetting == 1) {
        if (mcpToken.isEmpty) {
          response.statusCode = HttpStatus.serviceUnavailable;
          response.write('503 - Service Unavailable');
          await response.close();
          return;
        }
        final authHeader = request.headers.value('Authorization');
        final expectedAuth = 'Bearer $mcpToken';
        final authValid = authHeader != null &&
            _constantTimeEquals(
                utf8.encode(authHeader), utf8.encode(expectedAuth));
        if (!authValid) {
          response.statusCode = HttpStatus.unauthorized;
          response.write('401 - Unauthorized');
          await response.close();
          return;
        }
      }

      final config = <String, dynamic>{
        'mcpPort': mcpPort,
        'mcpEnabled': mcpEnabled == 1,
        'tlsEnabled': false,
      };
      if (mcpToken.isNotEmpty) config['mcpToken'] = mcpToken;

      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.headers.set('Cache-Control', 'no-store, no-cache');

      final origin = request.headers.value('Origin');
      final allowed = SimpleHttpServer.validateCorsOrigin(origin);
      if (allowed != null) {
        response.headers.set('Access-Control-Allow-Origin', allowed);
      }
      response.headers.set('Vary', 'Origin');
      response.write(jsonEncode(config));
      await response.close();
      return;
    }

    if (urlPath == '/') urlPath = '/index.html';

    final relativePath = Uri.decodeComponent(
        urlPath.substring(1).replaceAll('/', Platform.pathSeparator));

    // Security: prevent path traversal
    if (relativePath.contains('..')) {
      response.statusCode = HttpStatus.badRequest;
      response.write('400 - Bad Request');
      await response.close();
      return;
    }

    final filePath = '$_webRoot${Platform.pathSeparator}$relativePath';
    final fullPath = File(filePath).absolute.path;
    final fullWebRoot = Directory(_webRoot).absolute.path;

    if (!fullPath.startsWith(fullWebRoot)) {
      response.statusCode = HttpStatus.forbidden;
      response.write('403 - Forbidden');
      await response.close();
      return;
    }

    await SimpleHttpServer.serveStaticFile(request, fullPath);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  void _log(String message) {
    _broker.logInfo(message);
  }

  void dispose() {
    _stop();
    _audioBridge.dispose();
    _broker.dispose();
  }
}
