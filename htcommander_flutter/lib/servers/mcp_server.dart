/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import 'http_server.dart';

/// MCP (Model Context Protocol) HTTP server for AI-powered radio control.
///
/// JSON-RPC 2.0 over HTTP on localhost. Requires Bearer token auth when
/// ServerBindAll is enabled. Port of HTCommander.Core/Utils/McpServer.cs,
/// McpJsonRpc.cs, McpTools.cs, McpResources.cs.
class McpServer {
  final DataBrokerClient _broker = DataBrokerClient();
  SimpleHttpServer? _server;
  int _port = 5678;
  bool _running = false;
  String _apiToken = '';

  McpServer() {
    // Ensure API token exists
    _apiToken = _broker.getValue<String>(0, 'McpApiToken', '');
    if (_apiToken.isEmpty) {
      _apiToken = _generateApiToken();
      _broker.dispatch(0, 'McpApiToken', _apiToken);
    }

    _broker.subscribe(0, 'McpServerEnabled', _onSettingChanged);
    _broker.subscribe(0, 'McpServerPort', _onSettingChanged);
    _broker.subscribe(0, 'McpDebugToolsEnabled', _onSettingChanged);
    _broker.subscribe(0, 'ServerBindAll', _onSettingChanged);
    _broker.subscribe(0, 'McpApiToken', _onTokenChanged);

    final enabled = _broker.getValue<int>(0, 'McpServerEnabled', 0);
    if (enabled == 1) {
      _port = _broker.getValue<int>(0, 'McpServerPort', 5678);
      _start();
    }
  }

  static String _generateApiToken() {
    final rng = Random.secure();
    final bytes = Uint8List(32); // 256 bits
    for (int i = 0; i < 32; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64.encode(bytes);
  }

  void _onTokenChanged(int deviceId, String name, Object? data) {
    if (data is String && data.isNotEmpty) _apiToken = data;
  }

  void _onSettingChanged(int deviceId, String name, Object? data) {
    final enabled = _broker.getValue<int>(0, 'McpServerEnabled', 0);
    final newPort = _broker.getValue<int>(0, 'McpServerPort', 5678);

    // Regenerate API token when ServerBindAll transitions to enabled
    if (name == 'ServerBindAll' && data is int && data == 1) {
      _apiToken = _generateApiToken();
      _broker.dispatch(0, 'McpApiToken', _apiToken);
    }

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
      _server = SimpleHttpServer(
        port: _port,
        bindAll: bindAll,
        handler: _handleRequest,
        logger: _log,
      );
      await _server!.start();
      _running = true;
      _log('MCP server started on port $_port');
    } catch (e) {
      _log('MCP server start failed: $e');
      _running = false;
    }
  }

  void _stop() {
    if (!_running) return;
    _log('MCP server stopping...');
    _running = false;
    _server?.stop();
    _server = null;
    _log('MCP server stopped');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    final origin = request.headers.value('Origin');
    SimpleHttpServer.addCorsHeaders(response, origin);

    // Handle preflight
    if (request.method == 'OPTIONS') {
      final allowed = SimpleHttpServer.validateCorsOrigin(origin);
      if (allowed == null) {
        response.statusCode = HttpStatus.forbidden;
        response.headers.contentType = ContentType.json;
        response.write('{"error":"Origin not allowed"}');
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    // Only accept POST
    if (request.method != 'POST') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.contentType = ContentType.json;
      response.write('{"error":"Method not allowed. Use POST."}');
      await response.close();
      return;
    }

    // Authenticate: require Bearer token when binding to all interfaces
    final bindAll = _broker.getValue<int>(0, 'ServerBindAll', 0) == 1;
    if (bindAll) {
      final currentToken = _apiToken;
      if (currentToken.isEmpty) {
        response.statusCode = HttpStatus.serviceUnavailable;
        response.headers.contentType = ContentType.json;
        response.write('{"error":"Server not ready"}');
        await response.close();
        return;
      }

      final authHeader = request.headers.value('Authorization');
      final expectedAuth = 'Bearer $currentToken';
      final authValid = authHeader != null &&
          _constantTimeEquals(
              utf8.encode(authHeader), utf8.encode(expectedAuth));

      if (!authValid) {
        response.statusCode = HttpStatus.unauthorized;
        response.headers.contentType = ContentType.json;
        response.write(
            '{"error":"Bearer token required. Set Authorization: Bearer <token> header."}');
        await response.close();
        return;
      }
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final responseBody = _processJsonRpc(body);

      if (responseBody == null) {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }

      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(responseBody);
      await response.close();
    } catch (e) {
      _log('MCP request error: $e');
      response.statusCode = HttpStatus.internalServerError;
      response.headers.contentType = ContentType.json;
      response.write(
          '{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal server error"}}');
      await response.close();
    }
  }

  // --- JSON-RPC 2.0 Protocol ---

  String? _processJsonRpc(String requestJson) {
    Map<String, dynamic> request;
    try {
      request = jsonDecode(requestJson) as Map<String, dynamic>;
      if (request['method'] == null) {
        return _serializeError(null, -32600, 'Invalid request');
      }
    } catch (_) {
      return _serializeError(null, -32700, 'Parse error');
    }

    try {
      return _handleMethod(request);
    } catch (_) {
      return _serializeError(request['id'], -32603, 'Internal error');
    }
  }

  String? _handleMethod(Map<String, dynamic> request) {
    final method = request['method'] as String;
    final id = request['id'];
    final params = request['params'];

    switch (method) {
      case 'initialize':
        return _serializeResult(id, {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}, 'resources': {}},
          'serverInfo': {'name': 'htcommander', 'version': '1.0.0'},
        });
      case 'notifications/initialized':
        return null; // Notification
      case 'ping':
        return _serializeResult(id, {});
      case 'tools/list':
        return _serializeResult(id, {'tools': _getToolDefinitions()});
      case 'tools/call':
        return _handleToolsCall(id, params);
      case 'resources/list':
        return _serializeResult(id, {'resources': _getResourceDefinitions()});
      case 'resources/read':
        return _handleResourcesRead(id, params);
      default:
        return _serializeError(id, -32601, 'Method not found');
    }
  }

  String _handleToolsCall(Object? id, Object? params) {
    if (params is! Map<String, dynamic>) {
      return _serializeError(id, -32602, 'Missing params');
    }
    final toolName = params['name'] as String?;
    if (toolName == null || toolName.isEmpty) {
      return _serializeError(id, -32602, 'Missing tool name');
    }
    final arguments =
        params['arguments'] as Map<String, dynamic>? ?? {};
    final result = _callTool(toolName, arguments);
    return _serializeResult(id, result);
  }

  String _handleResourcesRead(Object? id, Object? params) {
    if (params is! Map<String, dynamic>) {
      return _serializeError(id, -32602, 'Missing params');
    }
    final uri = params['uri'] as String?;
    if (uri == null || uri.isEmpty) {
      return _serializeError(id, -32602, 'Missing resource URI');
    }
    final result = _readResource(uri);
    return _serializeResult(id, result);
  }

  String _serializeResult(Object? id, Object result) {
    return jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  String _serializeError(Object? id, int code, String message) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  // --- MCP Tools ---

  static const List<String> _settingsWhitelist = [
    'CallSign', 'StationId', 'AllowTransmit', 'Theme', 'CheckForUpdates',
    'VoiceLanguage', 'Voice', 'SpeechToText', 'MicGain', 'OutputVolume',
    'WebServerEnabled', 'WebServerPort',
    'McpServerEnabled', 'McpServerPort',
    'RigctldServerEnabled', 'RigctldServerPort', 'CatServerEnabled',
    'AgwpeServerEnabled', 'AgwpeServerPort', 'VirtualAudioEnabled',
    'WinlinkUseStationId',
    'AirplaneServer', 'RepeaterBookCountry', 'RepeaterBookState',
    'ShowAllChannels', 'ShowAirplanesOnMap', 'SoftwareModemMode',
    'AudioOutputDevice', 'AudioInputDevice',
  ];

  List<Map<String, dynamic>> _getToolDefinitions() {
    final tools = <Map<String, dynamic>>[];

    Map<String, dynamic> prop(String type, String desc,
        {List<String>? enumValues, int? minimum, int? maximum}) {
      final p = <String, dynamic>{'type': type, 'description': desc};
      if (enumValues != null) p['enum'] = enumValues;
      if (minimum != null) p['minimum'] = minimum;
      if (maximum != null) p['maximum'] = maximum;
      return p;
    }

    final deviceIdProp = prop('integer', 'Radio device ID (100+)');

    // Query tools
    tools.add(_toolDef('get_connected_radios',
        'List all connected radios with their device IDs and state.'));
    tools.add(_toolDef('get_radio_state',
        'Get the connection state of a specific radio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('get_radio_info',
        'Get device information for a connected radio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('get_channels',
        'Get all programmed channel configurations for a radio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('get_gps_position',
        'Get the GPS position from a connected radio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('get_battery',
        'Get the battery percentage of a connected radio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('get_ht_status',
        'Get live HT status: RSSI, TX/RX state, squelch, current channel.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));

    // Control tools
    tools.add(_toolDef('set_vfo_channel',
        'Switch VFO A or VFO B to a specific memory channel.',
        props: {
          'device_id': deviceIdProp,
          'vfo': prop('string', 'Which VFO', enumValues: ['A', 'B']),
          'channel_index':
              prop('integer', 'Channel index (0-based)', minimum: 0),
        },
        required: ['device_id', 'vfo', 'channel_index']));
    tools.add(_toolDef('set_volume',
        'Set the hardware volume level of a connected radio.',
        props: {
          'device_id': deviceIdProp,
          'level': prop('integer', 'Volume level', minimum: 0, maximum: 15),
        },
        required: ['device_id', 'level']));
    tools.add(
        _toolDef('set_squelch', 'Set the squelch level of a connected radio.',
            props: {
              'device_id': deviceIdProp,
              'level':
                  prop('integer', 'Squelch level', minimum: 0, maximum: 9),
            },
            required: ['device_id', 'level']));
    tools.add(_toolDef('connect_radio',
        'Connect to a radio by Bluetooth MAC address.',
        props: {
          'mac_address':
              prop('string', 'Bluetooth MAC address of the radio'),
        }));
    tools.add(_toolDef('disconnect_radio',
        'Disconnect a connected radio by device ID.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));

    // Settings tools
    final settingNames = List<String>.from(_settingsWhitelist)..sort();
    tools.add(_toolDef('get_setting',
        'Read an application setting by name.',
        props: {
          'name':
              prop('string', 'Setting name', enumValues: settingNames),
        },
        required: ['name']));
    tools.add(_toolDef('set_setting',
        'Write an application setting.',
        props: {
          'name':
              prop('string', 'Setting name', enumValues: settingNames),
          'value': prop('string', 'Setting value'),
        },
        required: ['name', 'value']));

    return tools;
  }

  Map<String, dynamic> _toolDef(String name, String description,
      {Map<String, dynamic>? props, List<String>? required}) {
    final schema = <String, dynamic>{'type': 'object'};
    if (props != null) schema['properties'] = props;
    if (required != null) schema['required'] = required;
    return {
      'name': name,
      'description': description,
      'inputSchema': schema,
    };
  }

  Map<String, dynamic> _callTool(
      String name, Map<String, dynamic> args) {
    try {
      switch (name) {
        case 'get_connected_radios':
          return _callGetConnectedRadios();
        case 'get_radio_state':
          return _toolResult(
              _broker.getValue<String>(_intArg(args, 'device_id'), 'State', 'Unknown'));
        case 'get_radio_info':
          final info = _broker.getValueDynamic(_intArg(args, 'device_id'), 'Info');
          return _toolResult(info?.toString() ?? 'No radio info available');
        case 'get_channels':
          final channels = _broker.getValueDynamic(_intArg(args, 'device_id'), 'Channels');
          return _toolResult(channels?.toString() ?? 'No channel data available');
        case 'get_gps_position':
          final pos = _broker.getValueDynamic(_intArg(args, 'device_id'), 'Position');
          return _toolResult(pos?.toString() ?? 'No GPS position available');
        case 'get_battery':
          final batt = _broker.getValue<int>(_intArg(args, 'device_id'), 'BatteryAsPercentage', -1);
          return _toolResult(batt < 0 ? 'No battery data' : '$batt%');
        case 'get_ht_status':
          final status = _broker.getValueDynamic(_intArg(args, 'device_id'), 'HtStatus');
          return _toolResult(status?.toString() ?? 'No HT status available');
        case 'set_vfo_channel':
          final deviceId = _intArg(args, 'device_id');
          final vfo = _stringArg(args, 'vfo');
          final ch = _intArg(args, 'channel_index');
          final event = vfo == 'B' ? 'ChannelChangeVfoB' : 'ChannelChangeVfoA';
          _broker.dispatch(deviceId, event, ch, store: false);
          return _toolResult('VFO $vfo set to channel $ch');
        case 'set_volume':
          final deviceId = _intArg(args, 'device_id');
          final level = _intArg(args, 'level');
          if (level < 0 || level > 15) return _toolError('Volume must be 0-15');
          _broker.dispatch(deviceId, 'SetVolumeLevel', level, store: false);
          return _toolResult('Volume set to $level');
        case 'set_squelch':
          final deviceId = _intArg(args, 'device_id');
          final level = _intArg(args, 'level');
          if (level < 0 || level > 9) return _toolError('Squelch must be 0-9');
          _broker.dispatch(deviceId, 'SetSquelchLevel', level, store: false);
          return _toolResult('Squelch set to $level');
        case 'connect_radio':
          final mac = args['mac_address'] as String? ?? '';
          _broker.dispatch(1, 'McpConnectRadio', mac, store: false);
          return _toolResult('Connect requested${mac.isEmpty ? " (last used)" : " for $mac"}');
        case 'disconnect_radio':
          final deviceId = _intArg(args, 'device_id');
          _broker.dispatch(1, 'McpDisconnectRadio', deviceId, store: false);
          return _toolResult('Disconnect requested for device $deviceId');
        case 'get_setting':
          final settingName = _stringArg(args, 'name');
          if (!_settingsWhitelist.contains(settingName)) {
            return _toolError('Setting \'$settingName\' is not available.');
          }
          final value = DataBroker.getValueDynamic(0, settingName);
          return _toolResult('$settingName = ${value ?? "(not set)"}');
        case 'set_setting':
          final settingName = _stringArg(args, 'name');
          final settingValue = _stringArg(args, 'value');
          if (!_settingsWhitelist.contains(settingName)) {
            return _toolError('Setting \'$settingName\' is not available.');
          }
          final intVal = int.tryParse(settingValue);
          if (intVal != null) {
            _broker.dispatch(0, settingName, intVal);
          } else {
            _broker.dispatch(0, settingName, settingValue);
          }
          return _toolResult('Setting \'$settingName\' set to: $settingValue');
        default:
          return _toolError('Unknown tool');
      }
    } catch (e) {
      _log('MCP tool error ($name): $e');
      return _toolError('Tool execution failed');
    }
  }

  Map<String, dynamic> _callGetConnectedRadios() {
    final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
    if (radios is List) {
      final radioList = <Map<String, dynamic>>[];
      for (final item in radios) {
        if (item is Map) {
          radioList.add(Map<String, dynamic>.from(item));
        }
      }
      return _toolResult(jsonEncode(radioList));
    }
    return _toolResult('[]');
  }

  // --- MCP Resources ---

  List<Map<String, dynamic>> _getResourceDefinitions() {
    final resources = <Map<String, dynamic>>[];
    resources.add({
      'uri': 'htcommander://app/settings',
      'name': 'Application Settings',
      'description': 'All application settings stored on device 0',
      'mimeType': 'application/json',
    });
    resources.add({
      'uri': 'htcommander://app/logs',
      'name': 'Application Logs',
      'description': 'Recent application log entries (up to 500)',
      'mimeType': 'text/plain',
    });

    // Dynamic per-radio resources
    final radioIds = _getConnectedRadioIds();
    for (final radioId in radioIds) {
      resources.add({
        'uri': 'htcommander://radio/$radioId/info',
        'name': 'Radio $radioId Info',
        'mimeType': 'application/json',
      });
      resources.add({
        'uri': 'htcommander://radio/$radioId/status',
        'name': 'Radio $radioId Status',
        'mimeType': 'application/json',
      });
    }

    return resources;
  }

  Map<String, dynamic> _readResource(String uri) {
    if (uri == 'htcommander://app/settings') {
      final values = DataBroker.getDeviceValues(0);
      final filtered = <String, String>{};
      for (final e in values.entries) {
        if (e.key == 'McpApiToken' || e.key == 'WinlinkPassword') continue;
        filtered[e.key] = e.value?.toString() ?? 'null';
      }
      return {
        'contents': [
          {
            'uri': uri,
            'mimeType': 'application/json',
            'text': jsonEncode(filtered),
          }
        ]
      };
    }

    return {
      'contents': [
        {'uri': uri, 'text': 'Resource not found'}
      ]
    };
  }

  // --- Helpers ---

  List<int> _getConnectedRadioIds() {
    final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
    if (radios is List) {
      return radios
          .whereType<Map>()
          .map((m) => m['deviceId'] as int?)
          .whereType<int>()
          .where((id) => id > 0)
          .toList();
    }
    return [];
  }

  int _intArg(Map<String, dynamic> args, String name) {
    final val = args[name];
    if (val is int) return val;
    if (val is num) return val.toInt();
    throw ArgumentError('Missing required argument: $name');
  }

  String _stringArg(Map<String, dynamic> args, String name) {
    final val = args[name];
    if (val is String) return val;
    throw ArgumentError('Missing required argument: $name');
  }

  Map<String, dynamic> _toolResult(String text) {
    return {
      'content': [
        {'type': 'text', 'text': text}
      ]
    };
  }

  Map<String, dynamic> _toolError(String text) {
    return {
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isError': true,
    };
  }

  /// Constant-time comparison to prevent timing attacks.
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
    _broker.dispose();
  }
}
