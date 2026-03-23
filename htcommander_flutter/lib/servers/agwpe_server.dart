/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';

/// Represents the 36-byte AGW PE API frame header.
class AgwpeFrame {
  int port;
  int dataKind;
  String callFrom;
  String callTo;
  int dataLen;
  int user;
  Uint8List data;

  AgwpeFrame({
    this.port = 0,
    this.dataKind = 0,
    this.callFrom = '',
    this.callTo = '',
    this.dataLen = 0,
    this.user = 0,
    Uint8List? data,
  }) : data = data ?? Uint8List(0);

  /// Parse a frame from a byte buffer (at least 36 bytes).
  static AgwpeFrame? fromBytes(Uint8List header, [Uint8List? payload]) {
    if (header.length < 36) return null;
    final bd = ByteData.sublistView(header);
    final frame = AgwpeFrame(
      port: header[0],
      dataKind: header[4],
      callFrom: ascii.decode(header.sublist(8, 18), allowInvalid: true)
          .replaceAll('\x00', '')
          .trim(),
      callTo: ascii.decode(header.sublist(18, 28), allowInvalid: true)
          .replaceAll('\x00', '')
          .trim(),
      dataLen: bd.getUint32(28, Endian.little),
      user: bd.getUint32(32, Endian.little),
    );
    if (payload != null) {
      frame.data = payload;
    }
    return frame;
  }

  /// Serialize frame to bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(36 + data.length);
    buffer[0] = port;
    buffer[4] = dataKind;

    // Write callFrom (10 bytes, null-padded)
    final fromBytes = ascii.encode(callFrom.padRight(10, '\x00'));
    for (int i = 0; i < 10; i++) {
      buffer[8 + i] = i < fromBytes.length ? fromBytes[i] : 0;
    }
    // Write callTo (10 bytes, null-padded)
    final toBytes = ascii.encode(callTo.padRight(10, '\x00'));
    for (int i = 0; i < 10; i++) {
      buffer[18 + i] = i < toBytes.length ? toBytes[i] : 0;
    }

    final bd = ByteData.sublistView(buffer);
    bd.setUint32(28, data.length, Endian.little);
    bd.setUint32(32, user, Endian.little);

    if (data.isNotEmpty) {
      buffer.setRange(36, 36 + data.length, data);
    }

    return buffer;
  }
}

/// Cross-platform AGWPE server that integrates with DataBroker.
///
/// Port of HTCommander.Core/Utils/AgwpeServer.cs.
class AgwpeServer {
  final DataBrokerClient _broker = DataBrokerClient();
  ServerSocket? _serverSocket;
  final Map<String, _AgwpeClientHandler> _clients = {};
  final Map<String, Set<String>> _registeredCallsigns = {};
  static const int _maxClients = 20;
  int _port = 8000;
  bool _running = false;
  bool _bindAll = false;

  AgwpeServer() {
    _broker.subscribe(0, 'AgwpeServerEnabled', _onSettingChanged);
    _broker.subscribe(0, 'AgwpeServerPort', _onSettingChanged);
    _broker.subscribe(0, 'ServerBindAll', _onSettingChanged);
    _broker.subscribe(DataBroker.allDevices, 'UniqueDataFrame',
        _onUniqueDataFrame);

    final enabled = _broker.getValue<int>(0, 'AgwpeServerEnabled', 0);
    if (enabled == 1) {
      _port = _broker.getValue<int>(0, 'AgwpeServerPort', 8000);
      _bindAll = _broker.getValue<int>(0, 'ServerBindAll', 0) == 1;
      _start();
    }
  }

  void _onSettingChanged(int deviceId, String name, Object? data) {
    final enabled = _broker.getValue<int>(0, 'AgwpeServerEnabled', 0);
    final newPort = _broker.getValue<int>(0, 'AgwpeServerPort', 8000);
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

  Future<void> _start() async {
    if (_running) return;
    try {
      final address =
          _bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      _serverSocket = await ServerSocket.bind(address, _port);
      _running = true;
      _log('AGWPE server started on port $_port'
          '${_bindAll ? " (all interfaces)" : " (loopback only)"}');

      _serverSocket!.listen(
        (socket) {
          if (_clients.length >= _maxClients) {
            _log('AGWPE connection rejected: max clients reached');
            socket.close();
            return;
          }
          final handler = _AgwpeClientHandler(socket, this);
          _clients[handler.id] = handler;
          _log('AGWPE client connected');
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (e) {
      _log('AGWPE server start failed: $e');
      _running = false;
    }
  }

  void _stop() {
    if (!_running) return;
    _log('AGWPE server stopping...');
    _running = false;
    _serverSocket?.close();
    _serverSocket = null;

    for (final client in _clients.values) {
      client.dispose();
    }
    _clients.clear();
    _registeredCallsigns.clear();
    _log('AGWPE server stopped');
  }

  void _onUniqueDataFrame(int deviceId, String name, Object? data) {
    if (data is! Map) return;
    final incoming = data['incoming'];
    if (incoming != true) return;

    // Broadcast as 'U' monitoring frame to connected clients
    try {
      final from = data['sourceCallsign']?.toString() ?? '';
      final to = data['destCallsign']?.toString() ?? '';
      final dataBytes = data['data'];
      final Uint8List payload;
      if (dataBytes is Uint8List) {
        payload = dataBytes;
      } else if (dataBytes is List<int>) {
        payload = Uint8List.fromList(dataBytes);
      } else {
        return;
      }

      final now = DateTime.now();
      final timeStr = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}';
      final str = '1:Fm $from To $to <UI pid=240 Len=${payload.length} >'
          '[$timeStr]\r${ascii.decode(payload, allowInvalid: true)}';
      final strBytes = Uint8List.fromList(ascii.encode(str));

      final frame = AgwpeFrame(
        dataKind: 0x55, // 'U'
        callFrom: from,
        callTo: to,
        data: strBytes,
      );

      final frameBytes = frame.toBytes();
      for (final client in _clients.values) {
        if (client.sendMonitoringFrames) {
          client.enqueueSend(frameBytes);
        }
      }
    } catch (_) {}
  }

  void onFrameReceived(String clientId, AgwpeFrame frame) {
    _log('AGWPE received: Kind=${String.fromCharCode(frame.dataKind)}'
        ' From=${frame.callFrom} To=${frame.callTo} Len=${frame.dataLen}');
    _processAgwCommand(clientId, frame);
  }

  void _processAgwCommand(String clientId, AgwpeFrame frame) {
    switch (String.fromCharCode(frame.dataKind)) {
      case 'G': // Get channel info
        _sendFrame(clientId, AgwpeFrame(
          dataKind: 0x47, // 'G'
          data: Uint8List.fromList(utf8.encode('1;Port1 HTCommander;')),
        ));
      case 'R': // Version
        final versionData = Uint8List(8);
        ByteData.sublistView(versionData)
          ..setUint32(0, 2000, Endian.little)
          ..setUint32(4, 0, Endian.little);
        _sendFrame(clientId, AgwpeFrame(
          dataKind: 0x52, // 'R'
          data: versionData,
        ));
      case 'X': // Register callsign
        bool success = false;
        if (frame.callFrom.isNotEmpty) {
          final existing = _getClientIdByCallsign(frame.callFrom);
          if (existing == null) {
            _registeredCallsigns
                .putIfAbsent(clientId, () => {})
                .add(frame.callFrom);
            success = true;
          }
        }
        _sendFrame(clientId, AgwpeFrame(
          port: frame.port,
          dataKind: 0x58, // 'X'
          callFrom: frame.callFrom,
          data: Uint8List.fromList([success ? 1 : 0]),
        ));
      case 'x': // Unregister callsign
        _registeredCallsigns[clientId]?.remove(frame.callFrom);
      case 'm': // Toggle monitoring
        final handler = _clients[clientId];
        if (handler != null) {
          handler.sendMonitoringFrames = !handler.sendMonitoringFrames;
        }
      case 'M': // Send UNPROTO (UI frame)
        final radioId = _getFirstConnectedRadioId();
        if (radioId >= 0) {
          _broker.dispatch(radioId, 'TransmitDataFrame', frame.data,
              store: false);
        }
      case 'D': // Send data in session
        final radioId = _getFirstConnectedRadioId();
        if (radioId >= 0) {
          _broker.dispatch(radioId, 'TransmitDataFrame', frame.data,
              store: false);
        }
      case 'd': // Disconnect request
        _sendFrame(clientId, AgwpeFrame(
          port: frame.port,
          dataKind: 0x64, // 'd'
          callFrom: frame.callTo,
          callTo: frame.callFrom,
        ));
      case 'Y': // Outstanding frames query
        final zeroData = Uint8List(4);
        _sendFrame(clientId, AgwpeFrame(
          port: frame.port,
          dataKind: 0x59, // 'Y'
          callFrom: frame.callFrom,
          callTo: frame.callTo,
          data: zeroData,
        ));
      case 'K':
      case 'k': // Raw AX.25 frame
        final radioId = _getFirstConnectedRadioId();
        if (radioId >= 0 && frame.data.isNotEmpty) {
          _broker.dispatch(radioId, 'TransmitDataFrame', frame.data,
              store: false);
        }
      default:
        _log('AGWPE unknown command'
            " '${String.fromCharCode(frame.dataKind)}'"
            ' (0x${frame.dataKind.toRadixString(16).padLeft(2, '0')})');
    }
  }

  void _sendFrame(String clientId, AgwpeFrame frame) {
    final handler = _clients[clientId];
    if (handler != null) {
      handler.enqueueSend(frame.toBytes());
    }
  }

  String? _getClientIdByCallsign(String callsign) {
    for (final entry in _registeredCallsigns.entries) {
      if (entry.value.contains(callsign)) return entry.key;
    }
    return null;
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
    _registeredCallsigns.remove(clientId);
    if (_clients.remove(clientId) != null) {
      _log('AGWPE client disconnected');
    }
  }

  void _log(String message) {
    _broker.logInfo(message);
  }

  void dispose() {
    _stop();
    _broker.dispose();
  }
}

/// Per-client handler for the AGWPE server.
class _AgwpeClientHandler {
  final Socket _socket;
  final AgwpeServer _server;
  final String id;
  bool sendMonitoringFrames = false;
  final Queue<Uint8List> _sendQueue = Queue();
  static const int _maxSendQueueSize = 1000;
  bool _disposed = false;
  bool _sending = false;

  // Frame parsing state
  final BytesBuilder _headerBuilder = BytesBuilder(copy: false);
  Uint8List? _currentHeader;
  int _expectedPayload = 0;
  final BytesBuilder _payloadBuilder = BytesBuilder(copy: false);

  _AgwpeClientHandler(this._socket, this._server)
      : id = DateTime.now().microsecondsSinceEpoch.toString() {
    _socket.listen(
      _onData,
      onError: (_) => _disconnect(),
      onDone: _disconnect,
      cancelOnError: false,
    );
  }

  void enqueueSend(Uint8List data) {
    if (_sendQueue.length >= _maxSendQueueSize) return;
    _sendQueue.add(data);
    _processSendQueue();
  }

  Future<void> _processSendQueue() async {
    if (_sending || _disposed) return;
    _sending = true;
    try {
      while (_sendQueue.isNotEmpty && !_disposed) {
        final data = _sendQueue.removeFirst();
        _socket.add(data);
        await _socket.flush();
      }
    } catch (_) {
      _disconnect();
    } finally {
      _sending = false;
    }
  }

  void _onData(Uint8List data) {
    int offset = 0;

    while (offset < data.length) {
      if (_currentHeader == null) {
        // Accumulating header bytes
        final needed = 36 - _headerBuilder.length;
        final available = data.length - offset;
        final take = needed < available ? needed : available;
        _headerBuilder.add(data.sublist(offset, offset + take));
        offset += take;

        if (_headerBuilder.length == 36) {
          _currentHeader = _headerBuilder.toBytes();
          _headerBuilder.clear();

          final bd = ByteData.sublistView(_currentHeader!);
          _expectedPayload = bd.getUint32(28, Endian.little);

          if (_expectedPayload > 65536) {
            _disconnect();
            return;
          }

          if (_expectedPayload == 0) {
            _processFrame(_currentHeader!, null);
            _currentHeader = null;
          }
        }
      } else {
        // Accumulating payload bytes
        final needed = _expectedPayload - _payloadBuilder.length;
        final available = data.length - offset;
        final take = needed < available ? needed : available;
        _payloadBuilder.add(data.sublist(offset, offset + take));
        offset += take;

        if (_payloadBuilder.length == _expectedPayload) {
          _processFrame(_currentHeader!, _payloadBuilder.toBytes());
          _payloadBuilder.clear();
          _currentHeader = null;
        }
      }
    }
  }

  void _processFrame(Uint8List header, Uint8List? payload) {
    final frame = AgwpeFrame.fromBytes(header, payload);
    if (frame != null) {
      _server.onFrameReceived(id, frame);
    }
  }

  void _disconnect() {
    if (_disposed) return;
    _disposed = true;
    try {
      _socket.close();
    } catch (_) {}
    _server.removeClient(id);
  }

  void dispose() {
    _disconnect();
  }
}
