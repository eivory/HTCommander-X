/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/data_broker.dart';
import '../../core/data_broker_client.dart';
import '../models/tnc_data_fragment.dart';
import '../../radio/radio.dart';
import 'ax25_address.dart';
import 'ax25_packet.dart';

/// Connection state of the AX.25 session.
enum AX25ConnectionState {
  disconnected(1),
  connected(2),
  connecting(3),
  disconnecting(4);

  final int value;
  const AX25ConnectionState(this.value);
}

/// Callback types for AX.25 session events.
typedef AX25StateChangedCallback = void Function(
    AX25Session sender, AX25ConnectionState state);
typedef AX25DataReceivedCallback = void Function(
    AX25Session sender, Uint8List data);
typedef AX25ErrorCallback = void Function(AX25Session sender, String error);

/// Timer identifiers for the AX.25 session.
enum _TimerName { connect, disconnect, t1, t2, t3 }

/// Implements the AX.25 data link layer protocol for connected-mode communication.
/// Uses the DataBroker for sending and receiving packets through a specified radio device.
/// Supports both standard (modulo-8) and extended (modulo-128) sequence numbering.
///
/// Port of HTCommander.Core/radio/AX25Session.cs
class AX25Session {
  final DataBrokerClient _broker;
  final int _radioDeviceId;
  bool _disposed = false;

  /// Custom session state dictionary for storing application-specific data.
  /// Cleared when the session disconnects.
  final Map<String, Object> sessionState = {};

  /// Raised when the connection state changes.
  AX25StateChangedCallback? onStateChanged;

  /// Raised when I-frame data is received from the remote station.
  AX25DataReceivedCallback? onDataReceived;

  /// Raised when UI-frame data is received (connectionless data).
  AX25DataReceivedCallback? onUiDataReceived;

  /// Raised when an error occurs in the session.
  AX25ErrorCallback? onError;

  /// Optional callsign override. If set, uses this callsign instead of the one from DataBroker.
  String? callSignOverride;

  /// Optional station ID override. If >= 0, uses this ID instead of the one from DataBroker.
  int stationIdOverride = -1;

  /// Gets the callsign to use for this session.
  String get sessionCallsign =>
      callSignOverride ?? DataBroker.getValue<String>(0, 'CallSign', 'NOCALL');

  /// Gets the station ID to use for this session.
  int get sessionStationId =>
      stationIdOverride >= 0
          ? stationIdOverride
          : DataBroker.getValue<int>(0, 'StationId', 0);

  /// Gets the radio device ID associated with this session.
  int get radioDeviceId => _radioDeviceId;

  /// Maximum number of outstanding I-frames (window size).
  int maxFrames = 4;

  /// Maximum size of data payload in each I-frame.
  int packetLength = 256;

  /// Number of retries before giving up on a connection.
  int retries = 3;

  /// Baud rate used for timeout calculations.
  int hBaud = 1200;

  /// Use modulo-128 mode for extended sequence numbers.
  bool modulo128 = false;

  /// Enable trace logging for debugging.
  bool tracing = true;

  // Internal protocol state
  AX25ConnectionState _connectionState = AX25ConnectionState.disconnected;
  int _receiveSequence = 0; // V(R)
  int _sendSequence = 0; // V(S)
  int _remoteReceiveSequence = 0; // N(R) from remote
  bool _remoteBusy = false;
  bool _sentREJ = false;
  int _gotREJSequenceNum = -1;
  final List<AX25Packet> _sendBuffer = [];
  final Map<int, AX25Packet> _receiveBuffer = {};

  // Timers
  Timer? _connectTimer;
  Timer? _disconnectTimer;
  Timer? _t1Timer;
  Timer? _t2Timer;
  Timer? _t3Timer;
  int _connectAttempts = 0;
  int _disconnectAttempts = 0;
  int _t1Attempts = 0;
  int _t3Attempts = 0;

  /// Gets or sets the list of addresses for this session
  /// (destination, source, and optional digipeaters).
  List<AX25Address>? addresses;

  /// Gets the current connection state of the session.
  AX25ConnectionState get currentState => _connectionState;

  /// Gets the number of packets in the send buffer awaiting transmission or acknowledgment.
  int get sendBufferLength => _sendBuffer.length;

  /// Gets the number of out-of-order packets in the receive buffer.
  int get receiveBufferLength => _receiveBuffer.length;

  /// Creates a new AX25 session using the DataBroker for communication.
  AX25Session(int radioDeviceId)
      : _radioDeviceId = radioDeviceId,
        _broker = DataBrokerClient() {
    // Subscribe to UniqueDataFrame events to receive incoming packets
    _broker.subscribe(
        DataBroker.allDevices, 'UniqueDataFrame', _onUniqueDataFrame);

    _broker.logInfo(
        '[AX25Session] Session created for radio device $radioDeviceId');
  }

  // ---------------------------------------------------------------------------
  // Event helpers
  // ---------------------------------------------------------------------------

  void _onErrorEvent(String error) {
    _trace('ERROR: $error');
    onError?.call(this, error);
  }

  void _onStateChangedEvent(AX25ConnectionState state) {
    onStateChanged?.call(this, state);
  }

  void _onUiDataReceivedEvent(Uint8List data) {
    onUiDataReceived?.call(this, data);
  }

  void _onDataReceivedEvent(Uint8List data) {
    onDataReceived?.call(this, data);
  }

  // ---------------------------------------------------------------------------
  // State management
  // ---------------------------------------------------------------------------

  void _setConnectionState(AX25ConnectionState state) {
    if (state != _connectionState) {
      _connectionState = state;
      _onStateChangedEvent(state);
      if (state == AX25ConnectionState.disconnected) {
        _sendBuffer.clear();
        _receiveBuffer.clear();
        addresses = null;
        sessionState.clear();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Tracing
  // ---------------------------------------------------------------------------

  void _trace(String msg) {
    if (tracing) {
      _broker.logInfo('[AX25Session/$_radioDeviceId] $msg');
    }
  }

  // ---------------------------------------------------------------------------
  // Timer management
  // ---------------------------------------------------------------------------

  int _getMaxPacketTime() {
    return ((600 + (packetLength * 8)) / hBaud * 1000).floor();
  }

  int _getTimeout() {
    int multiplier = 0;
    for (final packet in _sendBuffer) {
      if (packet.sent) multiplier++;
    }
    final mpt = _getMaxPacketTime();
    return (mpt * max<int>(1, (addresses?.length ?? 2) - 2) * 4) +
        (mpt * max<int>(1, multiplier));
  }

  int _getTimerTimeout(_TimerName timerName) {
    switch (timerName) {
      case _TimerName.connect:
      case _TimerName.disconnect:
      case _TimerName.t1:
        return _getTimeout();
      case _TimerName.t2:
        return _getMaxPacketTime() * 2;
      case _TimerName.t3:
        return _getTimeout() * 7;
    }
  }

  void _setTimer(_TimerName timerName) {
    _clearTimer(timerName);
    if (addresses == null) return;

    final timeout = _getTimerTimeout(timerName);
    _trace('SetTimer $timerName to ${timeout}ms');

    final timer = Timer(Duration(milliseconds: timeout), () {
      switch (timerName) {
        case _TimerName.connect:
          _connectTimerCallback();
          break;
        case _TimerName.disconnect:
          _disconnectTimerCallback();
          break;
        case _TimerName.t1:
          _t1TimerCallback();
          break;
        case _TimerName.t2:
          _t2TimerCallback();
          break;
        case _TimerName.t3:
          _t3TimerCallback();
          break;
      }
    });

    switch (timerName) {
      case _TimerName.connect:
        _connectTimer = timer;
        break;
      case _TimerName.disconnect:
        _disconnectTimer = timer;
        break;
      case _TimerName.t1:
        _t1Timer = timer;
        break;
      case _TimerName.t2:
        _t2Timer = timer;
        break;
      case _TimerName.t3:
        _t3Timer = timer;
        break;
    }
  }

  void _clearTimer(_TimerName timerName) {
    _trace('ClearTimer $timerName');

    switch (timerName) {
      case _TimerName.connect:
        _connectTimer?.cancel();
        _connectTimer = null;
        _connectAttempts = 0;
        break;
      case _TimerName.disconnect:
        _disconnectTimer?.cancel();
        _disconnectTimer = null;
        _disconnectAttempts = 0;
        break;
      case _TimerName.t1:
        _t1Timer?.cancel();
        _t1Timer = null;
        _t1Attempts = 0;
        break;
      case _TimerName.t2:
        _t2Timer?.cancel();
        _t2Timer = null;
        break;
      case _TimerName.t3:
        _t3Timer?.cancel();
        _t3Timer = null;
        _t3Attempts = 0;
        break;
    }
  }

  bool _isTimerActive(_TimerName timerName) {
    switch (timerName) {
      case _TimerName.connect:
        return _connectTimer != null;
      case _TimerName.disconnect:
        return _disconnectTimer != null;
      case _TimerName.t1:
        return _t1Timer != null;
      case _TimerName.t2:
        return _t2Timer != null;
      case _TimerName.t3:
        return _t3Timer != null;
    }
  }

  // ---------------------------------------------------------------------------
  // Timer callbacks
  // ---------------------------------------------------------------------------

  void _connectTimerCallback() {
    _trace('Timer - Connect');
    if (_connectAttempts >= (retries - 1)) {
      _clearTimer(_TimerName.connect);
      _setConnectionState(AX25ConnectionState.disconnected);
      return;
    }
    _connectEx();
  }

  void _disconnectTimerCallback() {
    _trace('Timer - Disconnect');
    if (_disconnectAttempts >= (retries - 1)) {
      _clearTimer(_TimerName.disconnect);
      _emitPacket(AX25Packet(
        addresses: addresses!,
        nr: _receiveSequence,
        ns: _sendSequence,
        pollFinal: false,
        command: false,
        type: FrameType.uFrameDM,
      ));
      _setConnectionState(AX25ConnectionState.disconnected);
      return;
    }
    disconnect();
  }

  void _t1TimerCallback() {
    _trace('** Timer - T1 expired');
    if (_t1Attempts >= retries) {
      _clearTimer(_TimerName.t1);
      disconnect();
      return;
    }
    _t1Attempts++;
    _sendRR(true);
  }

  void _t2TimerCallback() {
    _trace('** Timer - T2 expired');
    _clearTimer(_TimerName.t2);
    _drain(resend: true);
  }

  void _t3TimerCallback() {
    _trace('** Timer - T3 expired');
    if (_isTimerActive(_TimerName.t1)) return;
    if (_t3Attempts >= retries) {
      _clearTimer(_TimerName.t3);
      disconnect();
      return;
    }
    _t3Attempts++;
  }

  // ---------------------------------------------------------------------------
  // Protocol helpers
  // ---------------------------------------------------------------------------

  int get _modulus => modulo128 ? 128 : 8;

  /// Find the difference between 'leader' and 'follower' modulo 'modulus'.
  int _distanceBetween(int l, int f, int m) {
    return (l < f) ? (l + (m - f)) : (l - f);
  }

  void _receiveAcknowledgement(AX25Packet packet) {
    _trace('ReceiveAcknowledgement');
    for (int p = 0; p < _sendBuffer.length; p++) {
      if (_sendBuffer[p].sent &&
          (_sendBuffer[p].ns != packet.nr) &&
          (_distanceBetween(packet.nr, _sendBuffer[p].ns, _modulus) <=
              maxFrames)) {
        _sendBuffer.removeAt(p);
        p--;
      }
    }
    _remoteReceiveSequence = packet.nr;
  }

  void _sendRR(bool pollFinal) {
    _trace('SendRR');
    _emitPacket(AX25Packet(
      addresses: addresses!,
      nr: _receiveSequence,
      ns: _sendSequence,
      pollFinal: pollFinal,
      command: true,
      type: FrameType.sFrameRR,
    ));
  }

  /// Check if we have data to send and can piggyback acknowledgment.
  bool _shouldPiggybackAck() {
    return _sendBuffer.isNotEmpty && _sendBuffer.any((p) => !p.sent);
  }

  /// Send the packets in the out queue.
  void _drain({bool resend = true}) {
    _trace('Drain, Packets in Queue: ${_sendBuffer.length}, Resend: $resend');
    if (_remoteBusy) {
      _clearTimer(_TimerName.t1);
      return;
    }

    int sequenceNum = _sendSequence;
    if (_gotREJSequenceNum > 0) sequenceNum = _gotREJSequenceNum;

    bool startTimer = false;
    for (int packetIndex = 0; packetIndex < _sendBuffer.length; packetIndex++) {
      final dst =
          _distanceBetween(sequenceNum, _remoteReceiveSequence, _modulus);
      if (_sendBuffer[packetIndex].sent || (dst < maxFrames)) {
        _sendBuffer[packetIndex].nr = _receiveSequence;
        if (!_sendBuffer[packetIndex].sent) {
          _sendBuffer[packetIndex].ns = _sendSequence;
          _sendBuffer[packetIndex].sent = true;
          _sendSequence = (_sendSequence + 1) % _modulus;
          sequenceNum = (sequenceNum + 1) % _modulus;
        } else if (!resend) {
          continue;
        }
        startTimer = true;
        _emitPacket(_sendBuffer[packetIndex]);
      }
    }

    if ((_gotREJSequenceNum < 0) && !startTimer) {
      _sendRR(false);
    }

    _gotREJSequenceNum = -1;
    if (startTimer) {
      _setTimer(_TimerName.t1);
    } else {
      _clearTimer(_TimerName.t1);
    }
  }

  void _renumber() {
    _trace('Renumber');
    for (int p = 0; p < _sendBuffer.length; p++) {
      _sendBuffer[p].ns = p % _modulus;
      _sendBuffer[p].nr = 0;
      _sendBuffer[p].sent = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Packet I/O
  // ---------------------------------------------------------------------------

  void _onUniqueDataFrame(int deviceId, String name, Object? data) {
    if (data is! TncDataFragment) return;
    if (data.radioDeviceId != _radioDeviceId) return;

    final packet = AX25Packet.decodeAx25Packet(data);
    if (packet == null) return;

    receive(packet);
  }

  void _emitPacket(AX25Packet packet) {
    _trace('EmitPacket');

    final lockState = DataBroker.getValue<RadioLockState?>(
        _radioDeviceId, 'LockState', null);
    final channelId = lockState?.channelId ?? -1;
    final regionId = lockState?.regionId ?? -1;

    final packetBytes = packet.toByteArray();
    if (packetBytes == null) return;

    final txData = TransmitDataFrameData(
      packetData: packetBytes,
      channelId: channelId,
      regionId: regionId,
    );

    DataBroker.dispatch(_radioDeviceId, 'TransmitDataFrame', txData,
        store: false);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Initiates a connection to a remote station.
  /// [newAddresses]: destination (index 0), source (index 1), and optional digipeaters.
  /// Returns true if the connection attempt was started.
  bool connect(List<AX25Address> newAddresses) {
    _trace('Connect');
    if (currentState != AX25ConnectionState.disconnected) return false;
    if (newAddresses.length < 2) return false;
    addresses = newAddresses;
    _sendBuffer.clear();
    _clearTimer(_TimerName.connect);
    _clearTimer(_TimerName.t1);
    _clearTimer(_TimerName.t2);
    _clearTimer(_TimerName.t3);
    return _connectEx();
  }

  bool _connectEx() {
    _trace('ConnectEx');
    _setConnectionState(AX25ConnectionState.connecting);
    _receiveSequence = 0;
    _sendSequence = 0;
    _remoteReceiveSequence = 0;
    _remoteBusy = false;
    _gotREJSequenceNum = -1;
    _clearTimer(_TimerName.disconnect);
    _clearTimer(_TimerName.t3);

    _emitPacket(AX25Packet(
      addresses: addresses!,
      nr: _receiveSequence,
      ns: _sendSequence,
      pollFinal: true,
      command: true,
      type: modulo128 ? FrameType.uFrameSABME : FrameType.uFrameSABM,
    ));

    _renumber();
    _connectAttempts++;

    if (_connectAttempts >= retries) {
      _clearTimer(_TimerName.connect);
      _setConnectionState(AX25ConnectionState.disconnected);
      return true;
    }
    if (!_isTimerActive(_TimerName.connect)) {
      _setTimer(_TimerName.connect);
    }
    return true;
  }

  /// Initiates a disconnection from the remote station.
  void disconnect() {
    if (_connectionState == AX25ConnectionState.disconnected) return;
    _trace('Disconnect');
    _clearTimer(_TimerName.connect);
    _clearTimer(_TimerName.t1);
    _clearTimer(_TimerName.t2);
    _clearTimer(_TimerName.t3);

    if (_connectionState != AX25ConnectionState.connected) {
      _onErrorEvent('ax25.Session.disconnect: Not connected.');
      _setConnectionState(AX25ConnectionState.disconnected);
      _clearTimer(_TimerName.disconnect);
      return;
    }

    if (_disconnectAttempts >= retries) {
      _clearTimer(_TimerName.disconnect);
      _emitPacket(AX25Packet(
        addresses: addresses!,
        nr: _receiveSequence,
        ns: _sendSequence,
        pollFinal: false,
        command: false,
        type: FrameType.uFrameDM,
      ));
      _setConnectionState(AX25ConnectionState.disconnected);
      return;
    }

    _disconnectAttempts++;
    _setConnectionState(AX25ConnectionState.disconnecting);
    _emitPacket(AX25Packet(
      addresses: addresses!,
      nr: _receiveSequence,
      ns: _sendSequence,
      pollFinal: true,
      command: true,
      type: FrameType.uFrameDISC,
    ));
    if (!_isTimerActive(_TimerName.disconnect)) {
      _setTimer(_TimerName.disconnect);
    }
  }

  /// Sends a UTF-8 string over the connection.
  void sendString(String info) {
    sendData(Uint8List.fromList(utf8.encode(info)));
  }

  /// Sends data over the connection. The data is split into I-frames based on [packetLength].
  void sendData(Uint8List info) {
    _trace('Send');
    if (info.isEmpty) return;

    for (int i = 0; i < info.length; i += packetLength) {
      final length = min(packetLength, info.length - i);
      final packetInfo = Uint8List.fromList(info.sublist(i, i + length));

      _sendBuffer.add(AX25Packet(
        addresses: addresses!,
        nr: 0,
        ns: 0,
        pollFinal: false,
        command: true,
        type: FrameType.iFrame,
        data: packetInfo,
      ));
    }

    if (!_isTimerActive(_TimerName.t2)) {
      _drain(resend: false);
    }
  }

  /// Processes a received AX.25 packet.
  bool receive(AX25Packet packet) {
    if (packet.addresses.length < 2) return false;
    _trace('Receive ${packet.type}');

    AX25Packet? response = AX25Packet(
      addresses: addresses ?? [],
      nr: _receiveSequence,
      ns: _sendSequence,
      pollFinal: false,
      command: !packet.command,
      type: 0,
    );

    AX25ConnectionState newState = currentState;

    // Check if this is for the right station for this session
    if (addresses != null &&
        packet.addresses[1].callSignWithId != addresses![0].callSignWithId) {
      _trace(
          'Got packet from wrong station: ${packet.addresses[1].callSignWithId}, expected: ${addresses![0].callSignWithId}');
      return false;
    }

    // If we are not connected and this is not a connection request, respond with DM
    if (addresses == null &&
        packet.type != FrameType.uFrameSABM &&
        packet.type != FrameType.uFrameSABME) {
      response.addresses = [
        AX25Address.getAddress(packet.addresses[1].toString())!,
        AX25Address.getAddress(sessionCallsign, sessionStationId)!,
      ];
      response.command = false;
      response.pollFinal = true;
      response.type = (packet.type == FrameType.uFrameDISC)
          ? FrameType.uFrameUA
          : FrameType.uFrameDM;
      _emitPacket(response);
      return false;
    }

    switch (packet.type) {
      // SABM / SABME — incoming connection request
      case FrameType.uFrameSABM:
      case FrameType.uFrameSABME:
        if (currentState != AX25ConnectionState.disconnected) return false;
        addresses = [
          AX25Address.getAddress(packet.addresses[1].toString())!,
          AX25Address.getAddress(sessionCallsign, sessionStationId)!,
        ];
        response.addresses = addresses ?? [];
        _receiveSequence = 0;
        _sendSequence = 0;
        _remoteReceiveSequence = 0;
        _gotREJSequenceNum = -1;
        _remoteBusy = false;
        _sendBuffer.clear();
        _receiveBuffer.clear();
        _clearTimer(_TimerName.connect);
        _clearTimer(_TimerName.disconnect);
        _clearTimer(_TimerName.t1);
        _clearTimer(_TimerName.t2);
        _clearTimer(_TimerName.t3);
        modulo128 = (packet.type == FrameType.uFrameSABME);
        _renumber();
        response.type = FrameType.uFrameUA;
        if (packet.command && packet.pollFinal) response.pollFinal = true;
        newState = AX25ConnectionState.connected;
        break;

      // DISC — disconnect request
      case FrameType.uFrameDISC:
        if (_connectionState == AX25ConnectionState.connected) {
          _receiveSequence = 0;
          _sendSequence = 0;
          _remoteReceiveSequence = 0;
          _gotREJSequenceNum = -1;
          _remoteBusy = false;
          _receiveBuffer.clear();
          _clearTimer(_TimerName.connect);
          _clearTimer(_TimerName.disconnect);
          _clearTimer(_TimerName.t1);
          _clearTimer(_TimerName.t2);
          _clearTimer(_TimerName.t3);
          response.type = FrameType.uFrameUA;
          response.pollFinal = true;
          _emitPacket(response);
          _setConnectionState(AX25ConnectionState.disconnected);
        } else {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
          _emitPacket(response);
        }
        return true;

      // UA — Unnumbered Acknowledge
      case FrameType.uFrameUA:
        if (_connectionState == AX25ConnectionState.connecting) {
          _clearTimer(_TimerName.connect);
          _clearTimer(_TimerName.t2);
          _setTimer(_TimerName.t3);
          response = null;
          newState = AX25ConnectionState.connected;
        } else if (_connectionState == AX25ConnectionState.disconnecting) {
          _clearTimer(_TimerName.disconnect);
          _clearTimer(_TimerName.t2);
          _clearTimer(_TimerName.t3);
          response = null;
          newState = AX25ConnectionState.disconnected;
        } else if (_connectionState == AX25ConnectionState.connected) {
          response = null;
        } else {
          response.type = FrameType.uFrameDM;
          response.pollFinal = false;
        }
        break;

      // DM — Disconnected Mode
      case FrameType.uFrameDM:
        if (_connectionState == AX25ConnectionState.connected) {
          _connectEx();
          response = null;
        } else if (_connectionState == AX25ConnectionState.connecting ||
            _connectionState == AX25ConnectionState.disconnecting) {
          _receiveSequence = 0;
          _sendSequence = 0;
          _remoteReceiveSequence = 0;
          _gotREJSequenceNum = -1;
          _remoteBusy = false;
          _sendBuffer.clear();
          _receiveBuffer.clear();
          _clearTimer(_TimerName.connect);
          _clearTimer(_TimerName.disconnect);
          _clearTimer(_TimerName.t1);
          _clearTimer(_TimerName.t2);
          _clearTimer(_TimerName.t3);
          response = null;
          if (_connectionState == AX25ConnectionState.connecting) {
            modulo128 = false;
            _connectEx();
          } else {
            newState = AX25ConnectionState.disconnected;
          }
        } else {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
        }
        break;

      // UI — Unnumbered Information
      case FrameType.uFrameUI:
        if (packet.data != null && packet.data!.isNotEmpty) {
          _onUiDataReceivedEvent(packet.data!);
        }
        if (packet.pollFinal) {
          response.pollFinal = false;
          response.type =
              (_connectionState == AX25ConnectionState.connected)
                  ? FrameType.sFrameRR
                  : FrameType.uFrameDM;
        } else {
          response = null;
        }
        break;

      // XID — Exchange Identification
      case FrameType.uFrameXID:
        response.type = FrameType.uFrameDM;
        break;

      // TEST — Test frame
      case FrameType.uFrameTEST:
        response.type = FrameType.uFrameTEST;
        if (packet.data != null && packet.data!.isNotEmpty) {
          response.data = packet.data;
        }
        break;

      // FRMR — Frame Recovery (removed from standard)
      case FrameType.uFrameFRMR:
        if (_connectionState == AX25ConnectionState.connecting && modulo128) {
          modulo128 = false;
          _connectEx();
          response = null;
        } else if (_connectionState == AX25ConnectionState.connected) {
          _connectEx();
          response = null;
        } else {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
        }
        break;

      // RR — Receive Ready
      case FrameType.sFrameRR:
        if (_connectionState == AX25ConnectionState.connected) {
          _remoteBusy = false;
          if (packet.command && packet.pollFinal) {
            response.type = FrameType.sFrameRR;
            response.pollFinal = true;
          } else {
            response = null;
          }
          _receiveAcknowledgement(packet);

          if (_shouldPiggybackAck() && response == null) {
            _trace('Piggybacking ack on outgoing data after RR');
            if (!_isTimerActive(_TimerName.t2)) _drain(resend: false);
          } else {
            _setTimer(_TimerName.t2);
          }
        } else if (packet.command) {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
        }
        break;

      // RNR — Receive Not Ready
      case FrameType.sFrameRNR:
        if (_connectionState == AX25ConnectionState.connected) {
          _remoteBusy = true;
          _receiveAcknowledgement(packet);
          if (packet.command && packet.pollFinal) {
            response.type = FrameType.sFrameRR;
            response.pollFinal = true;
          } else {
            response = null;
          }
          _clearTimer(_TimerName.t2);
          _setTimer(_TimerName.t1);
        } else if (packet.command) {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
        }
        break;

      // REJ — Reject
      case FrameType.sFrameREJ:
        if (_connectionState == AX25ConnectionState.connected) {
          _remoteBusy = false;
          if (packet.command && packet.pollFinal) {
            response.type = FrameType.sFrameRR;
            response.pollFinal = true;
          } else {
            response = null;
          }
          _receiveAcknowledgement(packet);
          _gotREJSequenceNum = packet.nr;

          if (_shouldPiggybackAck() && response == null) {
            _trace('Piggybacking ack on outgoing data after REJ');
            if (!_isTimerActive(_TimerName.t2)) _drain(resend: false);
          } else {
            _setTimer(_TimerName.t2);
          }
        } else {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
        }
        break;

      // I-FRAME — Information
      case FrameType.iFrame:
        if (_connectionState == AX25ConnectionState.connected) {
          if (packet.pollFinal) response.pollFinal = true;

          if (packet.ns == _receiveSequence) {
            // In-sequence packet
            _sentREJ = false;
            _receiveSequence = (_receiveSequence + 1) % _modulus;
            if (packet.data != null && packet.data!.isNotEmpty) {
              _onDataReceivedEvent(packet.data!);
            }

            _processBufferedPackets();

            if (_shouldPiggybackAck() &&
                !response.pollFinal) {
              _trace('Piggybacking ack on outgoing data instead of sending RR');
              response = null;
              if (!_isTimerActive(_TimerName.t2)) _drain(resend: false);
            } else {
              response = null;
              _setTimer(_TimerName.t2);
            }
          } else if (_isWithinReceiveWindow(packet.ns) &&
              !_receiveBuffer.containsKey(packet.ns)) {
            // Out-of-order packet within receive window — buffer it
            _trace(
                'Buffering out-of-order packet NS=${packet.ns}, expected=$_receiveSequence');
            _receiveBuffer[packet.ns] = packet;

            if (!_sentREJ) {
              response.type = FrameType.sFrameREJ;
              _sentREJ = true;
            } else {
              response = null;
            }
          } else if (_sentREJ) {
            response = null;
          } else if (!_sentREJ) {
            response.type = FrameType.sFrameREJ;
            _sentREJ = true;
          }

          _receiveAcknowledgement(packet);

          if (response == null && !_shouldPiggybackAck()) {
            _setTimer(_TimerName.t2);
          }
        } else if (packet.command) {
          response.type = FrameType.uFrameDM;
          response.pollFinal = true;
        }
        break;

      default:
        response = null;
        break;
    }

    // Send response if one was constructed
    if (response != null) {
      if (response.addresses.isEmpty) {
        response.addresses = [
          AX25Address.getAddress(packet.addresses[1].toString())!,
          AX25Address.getAddress(sessionCallsign, sessionStationId)!,
        ];
      }
      _emitPacket(response);
    }

    if (newState != currentState) {
      if (currentState == AX25ConnectionState.disconnecting &&
          newState == AX25ConnectionState.connected) {
        return true;
      }
      _setConnectionState(newState);
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // Receive window helpers
  // ---------------------------------------------------------------------------

  void _processBufferedPackets() {
    while (_receiveBuffer.containsKey(_receiveSequence)) {
      final bufferedPacket = _receiveBuffer.remove(_receiveSequence)!;
      _trace('Processing buffered packet NS=${bufferedPacket.ns}');

      if (bufferedPacket.data != null && bufferedPacket.data!.isNotEmpty) {
        _onDataReceivedEvent(bufferedPacket.data!);
      }

      _receiveSequence = (_receiveSequence + 1) % _modulus;
    }
  }

  bool _isWithinReceiveWindow(int ns) {
    final distance = _distanceBetween(ns, _receiveSequence, _modulus);
    return distance < maxFrames;
  }

  // ---------------------------------------------------------------------------
  // Disposal
  // ---------------------------------------------------------------------------

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _broker.logInfo(
        '[AX25Session] Session disposing for radio device $_radioDeviceId');

    _clearTimer(_TimerName.connect);
    _clearTimer(_TimerName.disconnect);
    _clearTimer(_TimerName.t1);
    _clearTimer(_TimerName.t2);
    _clearTimer(_TimerName.t3);

    _sendBuffer.clear();
    _receiveBuffer.clear();
    addresses = null;
    sessionState.clear();

    _broker.dispose();
  }
}
