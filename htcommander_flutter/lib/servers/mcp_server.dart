/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../handlers/log_store.dart';
import '../radio/dtmf_engine.dart';
import '../radio/radio.dart' as ht;
import '../radio/models/radio_dev_info.dart';
import '../radio/models/radio_channel_info.dart';
import '../radio/models/radio_settings.dart';
import '../radio/models/radio_ht_status.dart';
import '../radio/models/radio_position.dart';
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
  bool _mcpPttActive = false;
  Timer? _mcpPttSilenceTimer;
  Timer? _mcpPttTimeoutTimer;
  int _mcpPttDeviceId = -1;

  static const List<String> _debugBlacklist = [
    'McpApiToken', 'McpDebugToolsEnabled', 'TlsEnabled', 'ServerBindAll', 'WinlinkPassword',
  ];

  // Screen names for MCP navigation (matches sidebar + hidden screens)
  static const List<String> _screenNames = [
    'communication', 'contacts', 'logbook', 'packets', 'terminal',
    'bbs', 'mail', 'torrent', 'aprs', 'map', 'debug', 'settings',
  ];

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
    tools.add(_toolDef('get_radio_settings',
        'Get current radio settings including VFO frequencies, squelch, volume.',
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

    // Navigation tools
    tools.add(_toolDef('navigate_to',
        'Navigate to a specific screen/tab in the application.',
        props: {
          'screen': prop('string', 'Screen name', enumValues: _screenNames),
        },
        required: ['screen']));
    tools.add(_toolDef('get_current_screen',
        'Get the name of the currently active screen.'));

    // Debug tools
    tools.add(_toolDef('get_logs',
        'Get recent application log entries.',
        props: {
          'count': prop('integer', 'Max entries (default 50)', minimum: 1, maximum: 500),
        }));

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

    // Radio control tools
    tools.add(_toolDef('set_vfo_frequency', 'Set VFO to a specific frequency by writing a scratch channel.',
        props: {
          'device_id': deviceIdProp,
          'frequency_mhz': prop('number', 'Frequency in MHz'),
          'vfo': prop('string', 'Which VFO', enumValues: ['A', 'B']),
          'modulation': prop('string', 'Modulation type', enumValues: ['FM', 'AM', 'DMR']),
          'bandwidth': prop('string', 'Channel bandwidth', enumValues: ['narrow', 'wide']),
          'power': prop('integer', 'TX power level', minimum: 0, maximum: 2),
        },
        required: ['device_id', 'frequency_mhz']));
    tools.add(_toolDef('set_ptt', 'Key or unkey the radio PTT (push-to-talk). Auto-releases after 30 seconds.',
        props: {
          'device_id': deviceIdProp,
          'enabled': prop('boolean', 'true to key PTT, false to release'),
        },
        required: ['device_id', 'enabled']));
    tools.add(_toolDef('set_dual_watch', 'Enable or disable dual watch on a radio.',
        props: {'device_id': deviceIdProp, 'enabled': prop('boolean', 'Enable dual watch')},
        required: ['device_id', 'enabled']));
    tools.add(_toolDef('set_scan', 'Start or stop channel scanning on a radio.',
        props: {'device_id': deviceIdProp, 'enabled': prop('boolean', 'Enable scanning')},
        required: ['device_id', 'enabled']));
    tools.add(_toolDef('set_output_volume', 'Set the audio output volume (0-100).',
        props: {'device_id': deviceIdProp, 'level': prop('integer', 'Volume 0-100', minimum: 0, maximum: 100)},
        required: ['device_id', 'level']));
    tools.add(_toolDef('set_mute', 'Mute or unmute radio audio output.',
        props: {'device_id': deviceIdProp, 'enabled': prop('boolean', 'Mute audio')},
        required: ['device_id', 'enabled']));
    tools.add(_toolDef('set_audio', 'Enable or disable Bluetooth audio on a radio.',
        props: {'device_id': deviceIdProp, 'enabled': prop('boolean', 'Enable audio')},
        required: ['device_id', 'enabled']));
    tools.add(_toolDef('set_gps', 'Enable or disable GPS on a radio.',
        props: {'device_id': deviceIdProp, 'enabled': prop('boolean', 'Enable GPS')},
        required: ['device_id', 'enabled']));

    // Transmission tools
    tools.add(_toolDef('send_chat_message', 'Send a text chat message via radio.',
        props: {'message': prop('string', 'Message text (max 4096 chars)')},
        required: ['message']));
    tools.add(_toolDef('send_morse', 'Transmit text as Morse code.',
        props: {'text': prop('string', 'Text to send as Morse')},
        required: ['text']));
    tools.add(_toolDef('send_dtmf', 'Send DTMF tones via radio.',
        props: {'device_id': deviceIdProp, 'digits': prop('string', 'DTMF digits (0-9, A-D, *, #)')},
        required: ['device_id', 'digits']));

    // Audio clip tools
    tools.add(_toolDef('list_audio_clips', 'List all recorded audio clips.'));
    tools.add(_toolDef('play_audio_clip', 'Play a recorded audio clip.',
        props: {'device_id': deviceIdProp, 'clip_name': prop('string', 'Name of the clip to play')},
        required: ['device_id', 'clip_name']));
    tools.add(_toolDef('stop_audio_clip', 'Stop audio clip playback.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('delete_audio_clip', 'Delete a recorded audio clip.',
        props: {'clip_name': prop('string', 'Name of the clip to delete')},
        required: ['clip_name']));
    tools.add(_toolDef('enable_recording', 'Start recording radio audio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));
    tools.add(_toolDef('disable_recording', 'Stop recording radio audio.',
        props: {'device_id': deviceIdProp},
        required: ['device_id']));

    // Channel management tools
    tools.add(_toolDef('write_channel', 'Write a channel configuration to the radio.',
        props: {
          'device_id': deviceIdProp,
          'channel_index': prop('integer', 'Channel index (0-based)', minimum: 0),
          'rx_frequency_mhz': prop('number', 'Receive frequency in MHz'),
          'tx_frequency_mhz': prop('number', 'Transmit frequency in MHz'),
          'name': prop('string', 'Channel name (max 10 chars)'),
          'modulation': prop('string', 'Modulation', enumValues: ['FM', 'AM', 'DMR']),
          'bandwidth': prop('string', 'Bandwidth', enumValues: ['narrow', 'wide']),
          'power': prop('integer', 'TX power', minimum: 0, maximum: 2),
          'tx_tone_hz': prop('number', 'CTCSS/DCS TX tone in Hz (0 for none)'),
          'rx_tone_hz': prop('number', 'CTCSS/DCS RX tone in Hz (0 for none)'),
        },
        required: ['device_id', 'channel_index', 'rx_frequency_mhz']));
    tools.add(_toolDef('set_software_modem', 'Set the software packet modem mode.',
        props: {
          'mode': prop('string', 'Modem mode', enumValues: ['None', 'AFSK1200', 'PSK2400', 'PSK4800', 'G3RUH9600']),
        },
        required: ['mode']));

    // Debug tools (conditional)
    if (DataBroker.getValue<int>(0, 'McpDebugToolsEnabled', 0) == 1) {
      tools.add(_toolDef('get_databroker_state', 'Get all DataBroker values for a device (debug).',
          props: {'device_id': prop('integer', 'Device ID to inspect')},
          required: ['device_id']));
      tools.add(_toolDef('get_app_setting', 'Read any application setting by name (debug).',
          props: {'name': prop('string', 'Setting name')},
          required: ['name']));
      tools.add(_toolDef('set_app_setting', 'Write any application setting (debug).',
          props: {'name': prop('string', 'Setting name'), 'value': prop('string', 'Setting value')},
          required: ['name', 'value']));
      tools.add(_toolDef('dispatch_event', 'Dispatch a raw DataBroker event (debug).',
          props: {
            'device_id': prop('integer', 'Target device ID'),
            'name': prop('string', 'Event name'),
            'value': prop('string', 'Event value'),
          },
          required: ['device_id', 'name']));
    }

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
          return _toolResult(_serializeRadioInfo(_intArg(args, 'device_id')));
        case 'get_radio_settings':
          return _toolResult(_serializeRadioSettings(_intArg(args, 'device_id')));
        case 'get_channels':
          return _toolResult(_serializeChannels(_intArg(args, 'device_id')));
        case 'get_gps_position':
          return _toolResult(_serializePosition(_intArg(args, 'device_id')));
        case 'get_battery':
          final batt = _broker.getValue<int>(_intArg(args, 'device_id'), 'BatteryAsPercentage', -1);
          return _toolResult(batt < 0 ? 'No battery data' : '$batt%');
        case 'get_ht_status':
          return _toolResult(_serializeHtStatus(_intArg(args, 'device_id')));
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
        case 'navigate_to':
          return _callNavigateTo(args);
        case 'get_current_screen':
          return _callGetCurrentScreen();
        case 'get_logs':
          return _callGetLogs(args);
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
        case 'set_vfo_frequency':
          return _callSetVfoFrequency(args);
        case 'set_ptt':
          return _callSetPtt(args);
        case 'set_dual_watch':
          final did = _intArg(args, 'device_id');
          final en = _boolArg(args, 'enabled');
          _broker.dispatch(did, 'DualWatch', en, store: false);
          return _toolResult('Dual watch ${en ? "enabled" : "disabled"}');
        case 'set_scan':
          final did = _intArg(args, 'device_id');
          final en = _boolArg(args, 'enabled');
          _broker.dispatch(did, 'Scan', en, store: false);
          return _toolResult('Scanning ${en ? "started" : "stopped"}');
        case 'set_output_volume':
          final did = _intArg(args, 'device_id');
          final lvl = _intArg(args, 'level');
          if (lvl < 0 || lvl > 100) return _toolError('Volume must be 0-100');
          _broker.dispatch(did, 'SetOutputVolume', lvl, store: false);
          return _toolResult('Output volume set to $lvl');
        case 'set_mute':
          final did = _intArg(args, 'device_id');
          final en = _boolArg(args, 'enabled');
          _broker.dispatch(did, 'SetMute', en, store: false);
          return _toolResult('Audio ${en ? "muted" : "unmuted"}');
        case 'set_audio':
          final did = _intArg(args, 'device_id');
          final en = _boolArg(args, 'enabled');
          _broker.dispatch(did, 'SetAudio', en, store: false);
          return _toolResult('Audio ${en ? "enabled" : "disabled"}');
        case 'set_gps':
          final did = _intArg(args, 'device_id');
          final en = _boolArg(args, 'enabled');
          _broker.dispatch(did, 'SetGPS', en, store: false);
          return _toolResult('GPS ${en ? "enabled" : "disabled"}');
        case 'send_chat_message':
          final msg = _stringArg(args, 'message');
          if (msg.length > 4096) return _toolError('Message too long (max 4096)');
          _broker.dispatch(1, 'Chat', msg, store: false);
          return _toolResult('Chat message sent');
        case 'send_morse':
          final text = _stringArg(args, 'text');
          _broker.dispatch(1, 'Morse', text, store: false);
          return _toolResult('Morse transmission started');
        case 'send_dtmf':
          return _callSendDtmf(args);
        case 'list_audio_clips':
          return _callListAudioClips();
        case 'play_audio_clip':
          final did = _intArg(args, 'device_id');
          final name = _stringArg(args, 'clip_name');
          _broker.dispatch(did, 'PlayAudioClip', name, store: false);
          return _toolResult('Playing clip: $name');
        case 'stop_audio_clip':
          final did = _intArg(args, 'device_id');
          _broker.dispatch(did, 'StopAudioClip', null, store: false);
          return _toolResult('Playback stopped');
        case 'delete_audio_clip':
          final clipName = _stringArg(args, 'clip_name');
          _broker.dispatch(DataBroker.allDevices, 'DeleteAudioClip', clipName, store: false);
          return _toolResult('Deleted clip: $clipName');
        case 'enable_recording':
          final did = _intArg(args, 'device_id');
          _broker.dispatch(1, 'RecordingEnable', did, store: false);
          return _toolResult('Recording enabled for device $did');
        case 'disable_recording':
          final did = _intArg(args, 'device_id');
          _broker.dispatch(1, 'RecordingDisable', did, store: false);
          return _toolResult('Recording disabled');
        case 'write_channel':
          return _callWriteChannel(args);
        case 'set_software_modem':
          final mode = _stringArg(args, 'mode');
          const validModes = ['None', 'AFSK1200', 'PSK2400', 'PSK4800', 'G3RUH9600'];
          if (!validModes.contains(mode)) return _toolError('Invalid mode. Use: ${validModes.join(", ")}');
          _broker.dispatch(0, 'SetSoftwareModemMode', mode);
          return _toolResult('Software modem set to $mode');
        case 'get_databroker_state':
          return _callGetDataBrokerState(args);
        case 'get_app_setting':
          return _callGetAppSetting(args);
        case 'set_app_setting':
          return _callSetAppSetting(args);
        case 'dispatch_event':
          return _callDispatchEvent(args);
        default:
          return _toolError('Unknown tool');
      }
    } catch (e) {
      _log('MCP tool error ($name): $e');
      return _toolError('Tool execution failed');
    }
  }

  bool _boolArg(Map<String, dynamic> args, String name) {
    final val = args[name];
    if (val is bool) return val;
    if (val is int) return val != 0;
    if (val is String) return val.toLowerCase() == 'true' || val == '1';
    throw ArgumentError('Missing or invalid argument: $name');
  }

  double _doubleArg(Map<String, dynamic> args, String name) {
    final val = args[name];
    if (val is double) return val;
    if (val is int) return val.toDouble();
    if (val is String) {
      final d = double.tryParse(val);
      if (d != null) return d;
    }
    throw ArgumentError('Missing or invalid argument: $name');
  }

  String _optStringArg(Map<String, dynamic> args, String name, String defaultValue) {
    final val = args[name];
    if (val is String && val.isNotEmpty) return val;
    return defaultValue;
  }

  int _optIntArg(Map<String, dynamic> args, String name, int defaultValue) {
    final val = args[name];
    if (val is int) return val;
    if (val is String) {
      final i = int.tryParse(val);
      if (i != null) return i;
    }
    return defaultValue;
  }

  double _optDoubleArg(Map<String, dynamic> args, String name, double defaultValue) {
    final val = args[name];
    if (val is double) return val;
    if (val is int) return val.toDouble();
    if (val is String) {
      final d = double.tryParse(val);
      if (d != null) return d;
    }
    return defaultValue;
  }

  Map<String, dynamic> _callNavigateTo(Map<String, dynamic> args) {
    final screen = _stringArg(args, 'screen').toLowerCase();
    if (!_screenNames.contains(screen)) {
      return _toolError('Unknown screen "$screen". Valid: ${_screenNames.join(", ")}');
    }
    _broker.dispatch(1, 'McpNavigateTo', screen, store: false);
    return _toolResult('Navigated to $screen');
  }

  Map<String, dynamic> _callGetCurrentScreen() {
    final screen = _broker.getValue<String>(1, 'CurrentScreen', 'communication');
    return _toolResult(screen);
  }

  Map<String, dynamic> _callGetConnectedRadios() {
    final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
    if (radios is List) {
      final radioList = <Map<String, dynamic>>[];
      for (final item in radios) {
        if (item is ht.Radio) {
          radioList.add({
            'device_id': item.deviceId,
            'mac_address': item.macAddress,
            'state': _broker.getValue<String>(item.deviceId, 'State', 'Unknown'),
            'friendly_name': _broker.getValue<String>(item.deviceId, 'FriendlyName', 'Radio'),
          });
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

  Map<String, dynamic> _callGetLogs(Map<String, dynamic> args) {
    final count = (args['count'] as num?)?.toInt() ?? 50;
    final handler = DataBroker.getDataHandler('LogStore');
    if (handler is LogStore) {
      final entries = handler.entries;
      final start = entries.length > count ? entries.length - count : 0;
      final lines = entries
          .skip(start)
          .map((e) => e.toString())
          .join('\n');
      return _toolResult(lines.isEmpty ? '(no logs)' : lines);
    }
    return _toolResult('(log store not available)');
  }

  // --- Data serializers ---

  String _serializeRadioInfo(int deviceId) {
    final info = _broker.getValueDynamic(deviceId, 'Info');
    if (info is RadioDevInfo) {
      return jsonEncode({
        'vendor_id': info.vendorId,
        'product_id': info.productId,
        'hw_ver': info.hwVer,
        'soft_ver': info.softVer,
        'support_radio': info.supportRadio,
        'support_medium_power': info.supportMediumPower,
        'region_count': info.regionCount,
        'channel_count': info.channelCount,
        'support_vfo': info.supportVfo,
        'support_dmr': info.supportDmr,
        'support_noaa': info.supportNoaa,
        'gmrs': info.gmrs,
        'freq_range_count': info.freqRangeCount,
      });
    }
    return 'No radio info available';
  }

  String _serializeRadioSettings(int deviceId) {
    final settings = _broker.getValueDynamic(deviceId, 'Settings');
    if (settings is RadioSettings) {
      return jsonEncode({
        'squelch_level': settings.squelchLevel,
        'scan': settings.scan,
        'channel_a': settings.channelA,
        'channel_b': settings.channelB,
        'double_channel': settings.doubleChannel,
        'mic_gain': settings.micGain,
        'local_speaker': settings.localSpeaker,
        'bt_mic_gain': settings.btMicGain,
        'vfo_x': settings.vfoX,
      });
    }
    return 'No settings available';
  }

  String _serializeChannels(int deviceId) {
    final channels = _broker.getValueDynamic(deviceId, 'Channels');
    if (channels is List) {
      final list = <Map<String, dynamic>>[];
      for (int i = 0; i < channels.length; i++) {
        final ch = channels[i];
        if (ch is RadioChannelInfo && ch.rxFreq > 0) {
          list.add({
            'index': i,
            'name': ch.nameStr,
            'rx_freq_mhz': ch.rxFreq / 1000000.0,
            'tx_freq_mhz': ch.txFreq / 1000000.0,
            'modulation': ch.rxMod.name,
            'bandwidth': ch.bandwidth.name,
            'tx_at_max_power': ch.txAtMaxPower,
            'tx_sub_audio': ch.txSubAudio,
            'rx_sub_audio': ch.rxSubAudio,
            'scan': ch.scan,
          });
        }
      }
      return jsonEncode(list);
    }
    return 'No channel data available';
  }

  String _serializePosition(int deviceId) {
    final pos = _broker.getValueDynamic(deviceId, 'Position');
    if (pos is RadioPosition) {
      return jsonEncode({
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'altitude': pos.altitude,
        'speed': pos.speed,
        'heading': pos.heading,
        'locked': pos.locked,
      });
    }
    return 'No GPS position available';
  }

  String _serializeHtStatus(int deviceId) {
    final status = _broker.getValueDynamic(deviceId, 'HtStatus');
    if (status is RadioHtStatus) {
      return jsonEncode({
        'rssi': status.rssi,
        'is_in_tx': status.isInTx,
        'is_in_rx': status.isInRx,
        'squelch_open': status.isSq,
        'current_channel': status.channelId,
        'channel_name': status.nameStr,
        'is_scan': status.isScan,
        'gps_locked': status.isGpsLocked,
      });
    }
    return 'No HT status available';
  }

  // --- Helpers ---

  List<int> _getConnectedRadioIds() {
    final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
    if (radios is List) {
      return radios
          .whereType<ht.Radio>()
          .map((r) => r.deviceId)
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

  Map<String, dynamic> _callSetVfoFrequency(Map<String, dynamic> args) {
    final deviceId = _intArg(args, 'device_id');
    final freqMhz = _doubleArg(args, 'frequency_mhz');
    final vfo = _optStringArg(args, 'vfo', 'A');
    final modStr = _optStringArg(args, 'modulation', 'FM');
    final bwStr = _optStringArg(args, 'bandwidth', 'narrow');
    final power = _optIntArg(args, 'power', 0);

    final freqHz = (freqMhz * 1000000).round();
    if (freqHz <= 0) return _toolError('Invalid frequency');

    final modulation = modStr == 'AM' ? 1 : (modStr == 'DMR' ? 2 : 0);
    final bandwidth = bwStr == 'wide' ? 1 : 0;

    // Create scratch channel and write it
    final channelData = <String, dynamic>{
      'Index': 999,
      'RxFrequency': freqHz,
      'TxFrequency': freqHz,
      'Name': 'MCP',
      'Modulation': modulation,
      'Bandwidth': bandwidth,
      'Power': power,
    };
    _broker.dispatch(deviceId, 'WriteChannel', channelData, store: false);

    // Switch VFO to the scratch channel
    final event = vfo == 'B' ? 'ChannelChangeVfoB' : 'ChannelChangeVfoA';
    _broker.dispatch(deviceId, event, 999, store: false);

    return _toolResult('VFO $vfo set to ${freqMhz}MHz ($modStr, $bwStr, power $power)');
  }

  Map<String, dynamic> _callSetPtt(Map<String, dynamic> args) {
    final deviceId = _intArg(args, 'device_id');
    final enabled = _boolArg(args, 'enabled');

    if (enabled) {
      if (_mcpPttActive) return _toolResult('PTT already active');
      _mcpPttActive = true;
      _mcpPttDeviceId = deviceId;
      _broker.dispatch(1, 'ExternalPttState', true, store: false);

      // Send periodic silence frames (6400 bytes = 100ms at 32kHz 16-bit mono)
      _mcpPttSilenceTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        if (!_mcpPttActive) return;
        final silence = Uint8List(6400);
        _broker.dispatch(_mcpPttDeviceId, 'TransmitVoicePCM', silence, store: false);
      });

      // Auto-release after 30 seconds
      _mcpPttTimeoutTimer = Timer(const Duration(seconds: 30), () {
        if (_mcpPttActive) {
          _releasePtt();
          _log('MCP PTT auto-released after 30s timeout');
        }
      });

      return _toolResult('PTT keyed on device $deviceId');
    } else {
      if (!_mcpPttActive) return _toolResult('PTT not active');
      _releasePtt();
      return _toolResult('PTT released');
    }
  }

  void _releasePtt() {
    _mcpPttActive = false;
    _mcpPttSilenceTimer?.cancel();
    _mcpPttSilenceTimer = null;
    _mcpPttTimeoutTimer?.cancel();
    _mcpPttTimeoutTimer = null;
    _broker.dispatch(1, 'ExternalPttState', false, store: false);
  }

  Map<String, dynamic> _callSendDtmf(Map<String, dynamic> args) {
    final deviceId = _intArg(args, 'device_id');
    final digits = _stringArg(args, 'digits');

    // Validate DTMF digits
    final validChars = RegExp(r'^[0-9A-Da-d*#]+$');
    if (!validChars.hasMatch(digits)) {
      return _toolError('Invalid DTMF digits. Use 0-9, A-D, *, #');
    }

    try {
      final pcm = DtmfEngine.generateDtmfPcm(digits);
      _broker.dispatch(deviceId, 'TransmitVoicePCM', pcm, store: false);
      return _toolResult('DTMF sent: $digits');
    } catch (e) {
      return _toolError('DTMF generation failed');
    }
  }

  Map<String, dynamic> _callListAudioClips() {
    final clips = _broker.getValueDynamic(0, 'AudioClips');
    if (clips is! List || clips.isEmpty) {
      return _toolResult('No audio clips');
    }
    final clipList = <Map<String, dynamic>>[];
    for (final clip in clips) {
      if (clip is Map) {
        clipList.add({
          'name': clip['Name'] ?? clip['name'] ?? '',
          'duration': clip['Duration'] ?? clip['duration'] ?? 0,
          'size': clip['Size'] ?? clip['size'] ?? 0,
        });
      }
    }
    return _toolResult(jsonEncode(clipList));
  }

  Map<String, dynamic> _callWriteChannel(Map<String, dynamic> args) {
    final deviceId = _intArg(args, 'device_id');
    final index = _intArg(args, 'channel_index');
    final rxFreqMhz = _doubleArg(args, 'rx_frequency_mhz');
    final txFreqMhz = _optDoubleArg(args, 'tx_frequency_mhz', rxFreqMhz);
    final name = _optStringArg(args, 'name', '');
    final modStr = _optStringArg(args, 'modulation', 'FM');
    final bwStr = _optStringArg(args, 'bandwidth', 'narrow');
    final power = _optIntArg(args, 'power', 0);
    final txTone = _optDoubleArg(args, 'tx_tone_hz', 0);
    final rxTone = _optDoubleArg(args, 'rx_tone_hz', 0);

    final rxHz = (rxFreqMhz * 1000000).round();
    final txHz = (txFreqMhz * 1000000).round();
    if (rxHz <= 0) return _toolError('Invalid RX frequency');

    final modulation = modStr == 'AM' ? 1 : (modStr == 'DMR' ? 2 : 0);
    final bandwidth = bwStr == 'wide' ? 1 : 0;

    final channelData = <String, dynamic>{
      'Index': index,
      'RxFrequency': rxHz,
      'TxFrequency': txHz,
      'Name': name.length > 10 ? name.substring(0, 10) : name,
      'Modulation': modulation,
      'Bandwidth': bandwidth,
      'Power': power,
      'TxTone': (txTone * 10).round(),
      'RxTone': (rxTone * 10).round(),
    };
    _broker.dispatch(deviceId, 'WriteChannel', channelData, store: false);
    return _toolResult('Channel $index written: ${rxFreqMhz}MHz');
  }

  Map<String, dynamic> _callGetDataBrokerState(Map<String, dynamic> args) {
    if (DataBroker.getValue<int>(0, 'McpDebugToolsEnabled', 0) != 1) {
      return _toolError('Debug tools not enabled');
    }
    final deviceId = _intArg(args, 'device_id');
    final values = DataBroker.getDeviceValues(deviceId);
    if (values.isEmpty) {
      return _toolResult('No values for device $deviceId');
    }
    final filtered = <String, dynamic>{};
    for (final entry in values.entries) {
      if (!_debugBlacklist.contains(entry.key)) {
        filtered[entry.key] = '${entry.value}';
      }
    }
    return _toolResult(jsonEncode(filtered));
  }

  Map<String, dynamic> _callGetAppSetting(Map<String, dynamic> args) {
    if (DataBroker.getValue<int>(0, 'McpDebugToolsEnabled', 0) != 1) {
      return _toolError('Debug tools not enabled');
    }
    final name = _stringArg(args, 'name');
    if (_debugBlacklist.contains(name)) return _toolError('Setting is restricted');
    final value = DataBroker.getValueDynamic(0, name);
    return _toolResult('$name = ${value ?? "(not set)"}');
  }

  Map<String, dynamic> _callSetAppSetting(Map<String, dynamic> args) {
    if (DataBroker.getValue<int>(0, 'McpDebugToolsEnabled', 0) != 1) {
      return _toolError('Debug tools not enabled');
    }
    final name = _stringArg(args, 'name');
    final value = _stringArg(args, 'value');
    if (_debugBlacklist.contains(name)) return _toolError('Setting is restricted');
    final intVal = int.tryParse(value);
    if (intVal != null) {
      _broker.dispatch(0, name, intVal);
    } else {
      _broker.dispatch(0, name, value);
    }
    return _toolResult('$name set to $value');
  }

  Map<String, dynamic> _callDispatchEvent(Map<String, dynamic> args) {
    if (DataBroker.getValue<int>(0, 'McpDebugToolsEnabled', 0) != 1) {
      return _toolError('Debug tools not enabled');
    }
    final deviceId = _intArg(args, 'device_id');
    final name = _stringArg(args, 'name');
    final value = args['value'];
    if (_debugBlacklist.contains(name)) return _toolError('Event name is restricted');
    _broker.dispatch(deviceId, name, value, store: false);
    return _toolResult('Event dispatched: $name to device $deviceId');
  }

  void dispose() {
    _releasePtt();
    _stop();
    _broker.dispose();
  }
}
