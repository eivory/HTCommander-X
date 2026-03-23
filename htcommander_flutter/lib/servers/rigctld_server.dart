/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';

/// Hamlib rigctld TCP text protocol server.
///
/// Used by fldigi, WSJT-X, Direwolf, VaraFM.
/// Port of HTCommander.Core/Utils/RigctldServer.cs.
class RigctldServer {
  final DataBrokerClient _broker = DataBrokerClient();
  ServerSocket? _serverSocket;
  final Map<String, _RigctldClientHandler> _clients = {};
  static const int _maxClients = 10;
  int _port = 4532;
  bool _running = false;
  bool _bindAll = false;
  bool _pttActive = false;
  Timer? _pttSilenceTimer;
  Timer? _pttTimeoutTimer;
  static const int _pttTimeoutMs = 30000;
  int _cachedFrequency = 145500000;
  int _activeRadioId = -1;

  bool get pttActive => _pttActive;
  int get cachedFrequency => _cachedFrequency;

  RigctldServer() {
    _broker.subscribe(0, 'RigctldServerEnabled', _onSettingChanged);
    _broker.subscribe(0, 'RigctldServerPort', _onSettingChanged);
    _broker.subscribe(0, 'ServerBindAll', _onSettingChanged);
    _broker.subscribe(1, 'ConnectedRadios', _onConnectedRadiosChanged);
    _broker.subscribe(DataBroker.allDevices, 'Channels', _onChannelsChanged);
    _broker.subscribe(DataBroker.allDevices, 'Settings', _onSettingsChanged);

    final enabled = _broker.getValue<int>(0, 'RigctldServerEnabled', 0);
    if (enabled == 1) {
      _port = _broker.getValue<int>(0, 'RigctldServerPort', 4532);
      _bindAll = _broker.getValue<int>(0, 'ServerBindAll', 0) == 1;
      _start();
    }
  }

  void _onSettingChanged(int deviceId, String name, Object? data) {
    final enabled = _broker.getValue<int>(0, 'RigctldServerEnabled', 0);
    final newPort = _broker.getValue<int>(0, 'RigctldServerPort', 4532);
    final newBindAll = _broker.getValue<int>(0, 'ServerBindAll', 0) == 1;

    if (enabled == 1) {
      if (_running && (newPort != _port || newBindAll != _bindAll)) {
        _stop();
        _port = newPort;
        _bindAll = newBindAll;
        _start();
      } else if (!_running) {
        _port = newPort;
        _bindAll = newBindAll;
        _start();
      }
    } else {
      if (_running) _stop();
    }
  }

  void _onConnectedRadiosChanged(int deviceId, String name, Object? data) {
    _activeRadioId = _getFirstConnectedRadioId();
  }

  void _onChannelsChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100) return;
    if (data is List && data.isNotEmpty) {
      final first = data[0];
      if (first is Map && (first['rx_freq'] as int? ?? 0) > 0) {
        _cachedFrequency = first['rx_freq'] as int;
      }
    }
  }

  void _onSettingsChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100) return;
    if (data is Map) {
      final freq = data['vfo1_mod_freq_x'];
      if (freq is int && freq > 0) _cachedFrequency = freq;
    }
  }

  Future<void> _start() async {
    if (_running) return;
    try {
      final address =
          _bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      _serverSocket = await ServerSocket.bind(address, _port);
      _running = true;
      _log('Rigctld server started on port $_port'
          '${_bindAll ? " (all interfaces)" : " (loopback only)"}');

      _serverSocket!.listen(
        (socket) {
          if (_clients.length >= _maxClients) {
            _log('Rigctld connection rejected: max clients reached');
            socket.close();
            return;
          }
          final handler = _RigctldClientHandler(socket, this);
          _clients[handler.id] = handler;
          _log('Rigctld client connected');
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (e) {
      _log('Rigctld server start failed: $e');
      _running = false;
    }
  }

  void _stop() {
    if (!_running) return;
    _log('Rigctld server stopping...');
    _running = false;
    setPtt(false);
    _serverSocket?.close();
    _serverSocket = null;

    for (final client in _clients.values) {
      client.dispose();
    }
    _clients.clear();
    _log('Rigctld server stopped');
  }

  String processCommand(String line) {
    if (line.trim().isEmpty) return '';

    var cmd = line.trim();
    bool extended = cmd.startsWith('+');
    if (extended) cmd = cmd.substring(1).trimLeft();

    // dump_state
    if (cmd == r'\dump_state') return _getDumpState();

    String command;
    String args = '';
    if (cmd.length == 1) {
      command = cmd;
    } else if (cmd.startsWith(r'\')) {
      final spaceIdx = cmd.indexOf(' ');
      if (spaceIdx > 0) {
        command = cmd.substring(0, spaceIdx);
        args = cmd.substring(spaceIdx + 1).trim();
      } else {
        command = cmd;
      }
    } else {
      command = cmd.substring(0, 1);
      args = cmd.length > 1 ? cmd.substring(1).trim() : '';
    }

    switch (command) {
      case 'T':
      case r'\set_ptt':
        final pttVal = int.tryParse(args) ?? 0;
        setPtt(pttVal != 0);
        return extended ? 'set_ptt: $pttVal\nRPRT 0\n' : 'RPRT 0\n';
      case 't':
      case r'\get_ptt':
        final v = _pttActive ? 1 : 0;
        return extended ? 'get_ptt:\nPTT: $v\n' : '$v\n';
      case 'f':
      case r'\get_freq':
        return extended
            ? 'get_freq:\nFreq: $_cachedFrequency\n'
            : '$_cachedFrequency\n';
      case 'F':
      case r'\set_freq':
        final freq = int.tryParse(args);
        if (freq != null && freq > 0 && freq <= 2147483647) {
          _cachedFrequency = freq;
          _setRadioFrequency(freq, 'A');
        }
        final safeArgs = _sanitize(args);
        return extended
            ? 'set_freq: $safeArgs\nRPRT 0\n'
            : 'RPRT 0\n';
      case 'm':
      case r'\get_mode':
        return extended
            ? 'get_mode:\nMode: FM\nPassband: 15000\n'
            : 'FM\n15000\n';
      case 'M':
      case r'\set_mode':
        final safeArgs = _sanitize(args);
        return extended ? 'set_mode: $safeArgs\nRPRT 0\n' : 'RPRT 0\n';
      case 'v':
      case r'\get_vfo':
        return extended ? 'get_vfo:\nVFO: VFOA\n' : 'VFOA\n';
      case 'V':
      case r'\set_vfo':
        final safeArgs = _sanitize(args);
        return extended ? 'set_vfo: $safeArgs\nRPRT 0\n' : 'RPRT 0\n';
      case 's':
      case r'\get_split_vfo':
        return extended
            ? 'get_split_vfo:\nSplit: 0\nTX VFO: VFOA\n'
            : '0\nVFOA\n';
      case 'q':
      case r'\quit':
        return ''; // Signal disconnect handled by caller
      default:
        return extended ? '$command:\nRPRT -1\n' : 'RPRT -1\n';
    }
  }

  String _getDumpState() {
    final sb = StringBuffer();
    sb.writeln('2'); // Protocol version
    sb.writeln('2'); // Rig model
    sb.writeln('2'); // ITU region
    sb.writeln(
        '100000.000000 1300000000.000000 0x40000000 -1 -1 0x16000003 0x3');
    sb.writeln('0 0 0 0 0 0 0');
    sb.writeln(
        '100000.000000 1300000000.000000 0x40000000 -1 -1 0x16000003 0x3');
    sb.writeln('0 0 0 0 0 0 0');
    sb.writeln('0x40000000 1');
    sb.writeln('0 0');
    sb.writeln('0');
    sb.writeln('0');
    sb.writeln('0');
    sb.writeln('0');
    sb.writeln(
        '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0');
    sb.writeln(
        '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0');
    sb.writeln('0x1e000000');
    sb.writeln('0x1e000000');
    sb.writeln('0x40000000');
    sb.writeln('0x40000000');
    sb.writeln('0');
    sb.writeln('0');
    sb.writeln('vfo_op=0x0');
    sb.writeln('done');
    return sb.toString();
  }

  void _setRadioFrequency(int freqHz, String vfo) {
    if (freqHz <= 0 || freqHz > 2147483647) return;

    int radioId = _activeRadioId;
    if (radioId < 0) radioId = _getFirstConnectedRadioId();
    if (radioId < 0) return;

    final info = _broker.getValueDynamic(radioId, 'Info');
    if (info == null) return;

    final channelCount =
        (info is Map ? info['channel_count'] as int? : null) ?? 0;
    if (channelCount <= 0) return;

    final scratchIndex = channelCount - 1;
    _broker.dispatch(
        radioId,
        'WriteChannel',
        {
          'channel_id': scratchIndex,
          'rx_freq': freqHz,
          'tx_freq': freqHz,
          'name_str': 'QF',
        },
        store: false);

    final eventName =
        vfo == 'B' ? 'ChannelChangeVfoB' : 'ChannelChangeVfoA';
    _broker.dispatch(radioId, eventName, scratchIndex, store: false);
    _log('Rigctld set_freq: $freqHz Hz on VFO $vfo');
  }

  void setPtt(bool on) {
    final wasActive = _pttActive;
    _pttActive = on;

    if (on && !wasActive) {
      _pttSilenceTimer?.cancel();
      _pttSilenceTimer =
          Timer.periodic(const Duration(milliseconds: 80), (_) {
        _dispatchSilence();
      });
      _pttTimeoutTimer?.cancel();
      _pttTimeoutTimer = Timer(
          const Duration(milliseconds: _pttTimeoutMs), _pttTimeoutCallback);
      _log('Rigctld PTT ON');
      _broker.dispatch(1, 'ExternalPttState', true, store: false);
    } else if (!on && wasActive) {
      _pttSilenceTimer?.cancel();
      _pttSilenceTimer = null;
      _pttTimeoutTimer?.cancel();
      _pttTimeoutTimer = null;
      _log('Rigctld PTT OFF');
      _broker.dispatch(1, 'ExternalPttState', false, store: false);
    }
  }

  void _pttTimeoutCallback() {
    _log('Rigctld PTT auto-released after timeout');
    setPtt(false);
  }

  void _dispatchSilence() {
    if (!_pttActive) return;
    int radioId = _activeRadioId;
    if (radioId < 0) radioId = _getFirstConnectedRadioId();
    if (radioId < 0) return;

    // 100ms of 32kHz 16-bit mono silence = 6400 bytes
    final silence = List<int>.filled(6400, 0);
    _broker.dispatch(radioId, 'TransmitVoicePCM', silence, store: false);
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

  void removeClient(String clientId) {
    if (_clients.remove(clientId) != null) {
      _log('Rigctld client disconnected');
      if (_pttActive && _clients.isEmpty) {
        _log('Rigctld: releasing PTT (last client disconnected)');
        setPtt(false);
      }
    }
  }

  String _sanitize(String s) {
    return s
        .replaceAll('\r', '')
        .replaceAll('\n', '')
        .replaceAll('\u2028', '')
        .replaceAll('\u2029', '');
  }

  void _log(String message) {
    _broker.logInfo(message);
  }

  void dispose() {
    _stop();
    _broker.dispose();
  }
}

class _RigctldClientHandler {
  final Socket _socket;
  final RigctldServer _server;
  final String id;
  final StringBuffer _lineBuffer = StringBuffer();
  Timer? _idleTimer;
  static const int _maxLineLength = 1024;
  static const Duration _idleTimeout = Duration(seconds: 30);
  bool _disposed = false;

  _RigctldClientHandler(this._socket, this._server)
      : id = DateTime.now().microsecondsSinceEpoch.toString() {
    _resetIdleTimer();
    _socket.listen(
      _onData,
      onError: (_) => _disconnect(),
      onDone: _disconnect,
      cancelOnError: false,
    );
  }

  void _onData(List<int> data) {
    _resetIdleTimer();
    final chars = ascii.decode(data, allowInvalid: true);
    _lineBuffer.write(chars);

    while (true) {
      final buf = _lineBuffer.toString();
      final nlIdx = buf.indexOf('\n');
      if (nlIdx < 0) break;

      final line = buf.substring(0, nlIdx).trimRight();
      _lineBuffer.clear();
      if (nlIdx + 1 < buf.length) {
        _lineBuffer.write(buf.substring(nlIdx + 1));
      }

      if (_lineBuffer.length > _maxLineLength) {
        _disconnect();
        return;
      }

      final response = _server.processCommand(line);
      if (response.isEmpty && (line.trim() == 'q' || line.trim() == r'\quit')) {
        _disconnect();
        return;
      }
      if (response.isNotEmpty) {
        try {
          _socket.write(response);
        } catch (_) {
          _disconnect();
          return;
        }
      }
    }

    if (_lineBuffer.length > _maxLineLength) {
      _disconnect();
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _disconnect);
  }

  void _disconnect() {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    try {
      _socket.close();
    } catch (_) {}
    _server.removeClient(id);
  }

  void dispose() {
    _disconnect();
  }
}
