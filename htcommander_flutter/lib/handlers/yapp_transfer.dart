/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// YAPP (Yet Another Protocol for Packet) file transfer over AX.25 sessions.
///
/// Port of HTCommander.Core/Yapp.cs

/// Callback signature for sending data through the AX.25 session.
typedef YappSendCallback = void Function(Uint8List data);

/// Callback for session state changes.
typedef YappSessionStateCallback = void Function(bool connected);

/// YAPP control characters (from specification).
class _Control {
  _Control._();

  static const int ack = 0x06;
  static const int enq = 0x05;
  static const int soh = 0x01; // Start of Header
  static const int stx = 0x02; // Start of Text (Data)
  static const int etx = 0x03; // End of Text (EOF)
  static const int eot = 0x04; // End of Transmission
  static const int nak = 0x15; // Negative Acknowledge
  static const int can = 0x18; // Cancel
  static const int dle = 0x10; // Data Link Escape
}

/// YAPP packet types.
class _PacketType {
  _PacketType._();

  // Acknowledgments
  static const int rr = 0x01; // Receive Ready
  static const int rf = 0x02; // Receive File
  static const int af = 0x03; // Ack EOF
  static const int at = 0x04; // Ack EOT
  static const int ca = 0x05; // Cancel Ack
}

/// YAPP transfer state.
enum YappState {
  idle,
  receiveInit, // R — Receive Init
  receiveHeader, // RH — Receive Header
  receiveData, // RD — Receive Data
  cancelWait, // CW — Cancel Wait
}

/// YAPP mode.
enum YappMode {
  none,
  receive,
}

/// Progress event data.
class YappProgressEvent {
  final String? filename;
  final int fileSize;
  final int bytesTransferred;
  final int percentage;

  YappProgressEvent({
    this.filename,
    this.fileSize = 0,
    this.bytesTransferred = 0,
    this.percentage = 0,
  });
}

/// Transfer complete event data.
class YappCompleteEvent {
  final String? filename;
  final int fileSize;
  final int bytesTransferred;
  final String? filePath;

  YappCompleteEvent({
    this.filename,
    this.fileSize = 0,
    this.bytesTransferred = 0,
    this.filePath,
  });
}

/// Transfer error event data.
class YappErrorEvent {
  final String error;
  final String? filename;

  YappErrorEvent({required this.error, this.filename});
}

/// YAPP file transfer protocol implementation.
///
/// Supports downloading files from remote stations via AX.25 terminal sessions.
class YappTransfer {
  final YappSendCallback _send;

  Timer? _timeoutTimer;

  // Configuration
  bool useChecksum = true; // YappC support
  bool enableResume = true; // Resume support
  int maxRetries = 3;
  int timeoutMs = 60000; // 60 seconds

  // Transfer state
  YappState _currentState = YappState.idle;
  YappMode _mode = YappMode.none;

  YappState get currentState => _currentState;
  YappMode get mode => _mode;

  // File transfer properties
  String? _currentFilename;
  int _fileSize = 0;
  int _bytesTransferred = 0;
  int _resumeOffset = 0;
  RandomAccessFile? _fileHandle;
  String? _downloadPath;
  int _retryCount = 0;
  bool _useChecksumForTransfer = false;

  // Event callbacks
  void Function(YappProgressEvent)? onProgress;
  void Function(YappCompleteEvent)? onComplete;
  void Function(YappErrorEvent)? onError;

  /// Creates a YAPP transfer handler.
  ///
  /// [send] is called to transmit data through the AX.25 session.
  YappTransfer({required YappSendCallback send}) : _send = send;

  /// Start receive mode to accept incoming file transfers.
  void startReceiveMode([String? downloadPath]) {
    if (_currentState != YappState.idle) {
      _onError('Transfer already in progress');
      return;
    }

    _downloadPath = downloadPath ?? Directory.systemTemp.path;

    // Ensure download directory exists
    final dir = Directory(_downloadPath!);
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (e) {
        _onError('Cannot create download directory');
        return;
      }
    }

    _mode = YappMode.receive;
    _setState(YappState.receiveInit);
  }

  /// Cancel the current transfer.
  void cancelTransfer([String reason = 'Transfer cancelled by user']) {
    if (_currentState == YappState.idle) return;

    _sendCancel(reason);
    _setState(YappState.cancelWait);
    _cleanupTransfer();
    _onError('Transfer cancelled: $reason');
  }

  /// Process incoming data and determine if it's YAPP protocol data.
  ///
  /// Returns true if data was handled by YAPP, false otherwise.
  bool processIncomingData(Uint8List data) {
    if (data.isEmpty) return false;

    // Always check for YAPP Send Init packet first
    if (_isYappTransferRequest(data)) {
      // Auto-start receive mode if not already active
      if (_mode != YappMode.receive) {
        final downloadPath = _getDefaultDownloadPath();
        startReceiveMode(downloadPath);
      }

      _processYappPacket(data);
      return true;
    }

    // If in receive mode, check if this is other YAPP data
    if (_mode == YappMode.receive && _isYappData(data)) {
      _processYappPacket(data);
      return true;
    }

    return false;
  }

  /// Auto-start YAPP in receive mode when session begins.
  void enableAutoReceive() {
    final downloadPath = _getDefaultDownloadPath();
    startReceiveMode(downloadPath);
  }

  /// Called when the AX.25 session disconnects.
  void onSessionDisconnected() {
    if (_currentState != YappState.idle) {
      // Session disconnected during transfer
    }
    reset();
  }

  /// Reset YAPP state to prepare for a new session.
  void reset() {
    _cleanupTransfer();
    _setState(YappState.idle);
    _mode = YappMode.none;
  }

  /// Dispose resources.
  void dispose() {
    _cleanupTransfer();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  // --- Private methods ---

  String _getDefaultDownloadPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/Documents/HTCommander Downloads';
  }

  bool _isYappTransferRequest(Uint8List data) {
    return data.length >= 2 &&
        data[0] == _Control.enq &&
        data[1] == _PacketType.rr; // SI uses PacketType.SI = 0x01 = RR
  }

  bool _isYappData(Uint8List data) {
    if (data.isEmpty) return false;
    final firstByte = data[0];
    return firstByte == _Control.enq ||
        firstByte == _Control.soh ||
        firstByte == _Control.stx ||
        firstByte == _Control.etx ||
        firstByte == _Control.eot ||
        firstByte == _Control.ack ||
        firstByte == _Control.nak ||
        firstByte == _Control.can ||
        firstByte == _Control.dle;
  }

  void _processYappPacket(Uint8List data) {
    if (_currentState == YappState.idle) return;

    final type = data[0];

    switch (_currentState) {
      case YappState.receiveInit:
        _processReceiveInitState(data, type);
      case YappState.receiveHeader:
        _processReceiveHeaderState(data, type);
      case YappState.receiveData:
        _processReceiveDataState(data, type);
      case YappState.cancelWait:
        _processCancelWaitState(data, type);
      case YappState.idle:
        break;
    }
  }

  void _processReceiveInitState(Uint8List data, int type) {
    if (type == _Control.enq && data.length >= 2 && data[1] == _PacketType.rr) {
      // SI packet — start transfer
      _sendReceiveReady();
      _setState(YappState.receiveHeader);
      _startTimeout();
    } else if (type == _Control.soh) {
      _processHeaderPacket(data);
    } else if (type == _Control.eot) {
      _sendAckEOT();
      _completeTransfer();
    } else if (type == _Control.can) {
      _processCancelPacket(data);
    }
  }

  void _processReceiveHeaderState(Uint8List data, int type) {
    if (type == _Control.soh) {
      _processHeaderPacket(data);
    } else if (type == _Control.eot) {
      _sendAckEOT();
      _completeTransfer();
    } else if (type == _Control.can) {
      _processCancelPacket(data);
    }
  }

  void _processReceiveDataState(Uint8List data, int type) {
    if (type == _Control.stx) {
      _processDataPacket(data);
    } else if (type == _Control.etx) {
      _processEndOfFile();
    } else if (type == _Control.can) {
      _processCancelPacket(data);
    }
  }

  void _processCancelWaitState(Uint8List data, int type) {
    if (type == _Control.ack &&
        data.length >= 2 &&
        data[1] == _PacketType.ca) {
      _cleanupTransfer();
    } else if (type == _Control.can) {
      _sendCancelAck();
    }
  }

  void _processHeaderPacket(Uint8List data) {
    if (data.length < 3) {
      _sendNotReady('Invalid header packet');
      return;
    }

    final length = data[1];
    if (data.length < 2 + length) {
      _sendNotReady('Incomplete header packet');
      return;
    }

    final headerData = data.sublist(2, 2 + length);
    final parts = _parseNullSeparatedStrings(headerData);

    if (parts.length < 2) {
      _sendNotReady('Invalid header format');
      return;
    }

    // Path traversal protection
    final rawFilename = parts[0];
    final filename = rawFilename.split('/').last.split('\\').last;
    if (filename.isEmpty ||
        filename.contains('..') ||
        filename != rawFilename.trim()) {
      _sendNotReady('Invalid filename');
      return;
    }
    _currentFilename = filename;

    final parsedSize = int.tryParse(parts[1]);
    if (parsedSize == null || parsedSize < 0) {
      _sendNotReady('Invalid file size');
      return;
    }
    if (parsedSize > 100 * 1024 * 1024) {
      // 100MB max
      _sendNotReady('File too large');
      return;
    }
    _fileSize = parsedSize;

    // Path traversal check
    final filePath =
        File('${_downloadPath!}${Platform.pathSeparator}$_currentFilename')
            .absolute
            .path;
    final fullDownloadPath = Directory(_downloadPath!).absolute.path;
    if (!filePath
        .startsWith('$fullDownloadPath${Platform.pathSeparator}')) {
      _sendNotReady('Invalid filename');
      return;
    }

    _resumeOffset = 0;

    // Check for resume
    final existingFile = File(filePath);
    if (enableResume && existingFile.existsSync()) {
      _resumeOffset = existingFile.lengthSync();

      if (_resumeOffset > 0 && _resumeOffset < _fileSize) {
        _bytesTransferred = _resumeOffset;
        _sendResume(_resumeOffset, useChecksum);
        _setState(YappState.receiveData);

        try {
          _fileHandle =
              existingFile.openSync(mode: FileMode.append);
          _useChecksumForTransfer = useChecksum;
          _fireProgress();
        } catch (_) {
          _fileHandle = null;
          _sendNotReady('Cannot open file for resume');
        }
        return;
      } else if (_resumeOffset >= _fileSize) {
        _sendNotReady('File already exists and is complete');
        return;
      }
    }

    // Create new file
    try {
      _fileHandle = File(filePath).openSync(mode: FileMode.write);
      _bytesTransferred = 0;
      _resumeOffset = 0;
    } catch (_) {
      _sendNotReady('Cannot create file');
      return;
    }

    _setState(YappState.receiveData);

    if (useChecksum) {
      _sendReceiveTPK();
      _useChecksumForTransfer = true;
    } else {
      _sendReceiveFile();
      _useChecksumForTransfer = false;
    }

    _fireProgress();
  }

  void _processDataPacket(Uint8List data) {
    if (data.length < 2) {
      cancelTransfer('Invalid data packet');
      return;
    }

    final lengthByte = data[1];
    final dataLength = lengthByte == 0 ? 256 : lengthByte;

    // Validate data length against actual packet size
    final minRequired =
        _useChecksumForTransfer ? (dataLength + 3) : (dataLength + 2);
    if (data.length < minRequired) {
      cancelTransfer('Data packet too short for declared length');
      return;
    }

    Uint8List packetData;

    if (_useChecksumForTransfer) {
      // YappC mode — last byte is checksum
      packetData = data.sublist(2, 2 + dataLength);
      final checksum = data[2 + dataLength];

      // Verify checksum
      int calculatedChecksum = 0;
      for (final b in packetData) {
        calculatedChecksum = (calculatedChecksum + b) & 0xFF;
      }

      if (calculatedChecksum != checksum) {
        cancelTransfer('Checksum error - data corruption detected');
        return;
      }
    } else {
      packetData = data.sublist(2, 2 + dataLength);
    }

    // Write data to file
    try {
      // Validate total received data doesn't exceed declared file size (with 1KB tolerance)
      if (_bytesTransferred + packetData.length > _fileSize + 1024) {
        cancelTransfer('Received more data than declared file size');
        return;
      }

      _fileHandle?.writeFromSync(packetData);
      _fileHandle?.flushSync();
      _bytesTransferred += packetData.length;

      _fireProgress();
      _restartTimeout();
      _sendDataAck();
    } catch (_) {
      cancelTransfer('File write error');
    }
  }

  void _processEndOfFile() {
    if (_fileHandle != null) {
      _fileHandle!.closeSync();
      _fileHandle = null;
    }

    _sendAckEOF();

    onComplete?.call(YappCompleteEvent(
      filename: _currentFilename,
      fileSize: _fileSize,
      bytesTransferred: _bytesTransferred,
      filePath: _downloadPath != null && _currentFilename != null
          ? '${_downloadPath!}${Platform.pathSeparator}$_currentFilename'
          : null,
    ));

    _setState(YappState.receiveHeader);
  }

  void _processCancelPacket(Uint8List data) {
    String reason = 'Transfer cancelled';
    if (data.length > 2) {
      final length = data[1];
      if (length > 0 && data.length >= 2 + length) {
        reason = utf8.decode(data.sublist(2, 2 + length),
            allowMalformed: true);
      }
    }

    _sendCancelAck();
    _setState(YappState.cancelWait);
    _onError('Remote cancelled: $reason');
  }

  // --- Packet Sending Methods ---

  void _sendReceiveReady() {
    _send(Uint8List.fromList([_Control.ack, _PacketType.rr]));
  }

  void _sendReceiveFile() {
    _send(Uint8List.fromList([_Control.ack, _PacketType.rf]));
  }

  void _sendReceiveTPK() {
    _send(Uint8List.fromList([_Control.ack, _Control.ack]));
  }

  void _sendAckEOF() {
    _send(Uint8List.fromList([_Control.ack, _PacketType.af]));
  }

  void _sendAckEOT() {
    _send(Uint8List.fromList([_Control.ack, _PacketType.at]));
  }

  void _sendNotReady(String reason) {
    var reasonBytes = utf8.encode(reason);
    if (reasonBytes.length > 255) {
      reasonBytes = reasonBytes.sublist(0, 255);
    }
    final packet = Uint8List(2 + reasonBytes.length);
    packet[0] = _Control.nak;
    packet[1] = reasonBytes.length;
    packet.setRange(2, 2 + reasonBytes.length, reasonBytes);
    _send(packet);
  }

  void _sendCancel([String reason = 'Transfer cancelled']) {
    var reasonBytes = utf8.encode(reason);
    if (reasonBytes.length > 255) {
      reasonBytes = reasonBytes.sublist(0, 255);
    }
    final packet = Uint8List(2 + reasonBytes.length);
    packet[0] = _Control.can;
    packet[1] = reasonBytes.length;
    packet.setRange(2, 2 + reasonBytes.length, reasonBytes);
    _send(packet);
  }

  void _sendCancelAck() {
    _send(Uint8List.fromList([_Control.ack, _PacketType.ca]));
  }

  void _sendDataAck() {
    _send(Uint8List.fromList([_Control.ack, _PacketType.rr]));
  }

  void _sendResume(int receivedLength, bool useYappC) {
    final data = <int>[];
    data.add(0x52); // 'R'
    data.add(0x00); // NUL
    data.addAll(ascii.encode(receivedLength.toString()));
    data.add(0x00); // NUL
    if (useYappC) {
      data.add(0x43); // 'C'
      data.add(0x00); // NUL
    }
    final packet = Uint8List(2 + data.length);
    packet[0] = _Control.nak;
    packet[1] = data.length;
    packet.setRange(2, 2 + data.length, data);
    _send(packet);
  }

  // --- Helper Methods ---

  List<String> _parseNullSeparatedStrings(Uint8List data) {
    final result = <String>[];
    final current = <int>[];

    for (final b in data) {
      if (b == 0x00) {
        if (current.isNotEmpty) {
          result.add(utf8.decode(current, allowMalformed: true));
          current.clear();
        }
      } else {
        current.add(b);
      }
    }

    if (current.isNotEmpty) {
      result.add(utf8.decode(current, allowMalformed: true));
    }

    return result;
  }

  void _setState(YappState newState) {
    if (_currentState != newState) {
      _currentState = newState;

      if (newState == YappState.idle) {
        _stopTimeout();
        _mode = YappMode.none;
      } else {
        _restartTimeout();
      }
    }
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(Duration(milliseconds: timeoutMs), _onTimeout);
  }

  void _restartTimeout() {
    _timeoutTimer?.cancel();
    _startTimeout();
  }

  void _stopTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void _onTimeout() {
    if (_retryCount < maxRetries) {
      _retryCount++;
      _restartTimeout();
    } else {
      cancelTransfer('Timeout - max retries exceeded');
    }
  }

  void _completeTransfer() {
    final wasReceive = _mode == YappMode.receive;

    _cleanupTransfer();

    onComplete?.call(YappCompleteEvent(
      filename: '',
      fileSize: 0,
      bytesTransferred: 0,
      filePath: '',
    ));

    if (wasReceive) {
      _setState(YappState.receiveInit);
    }
    _currentState = YappState.idle;
  }

  void _cleanupTransfer() {
    _stopTimeout();

    if (_fileHandle != null) {
      try {
        _fileHandle!.closeSync();
      } catch (_) {}
      _fileHandle = null;
    }
    _retryCount = 0;
    _currentFilename = null;
    _fileSize = 0;
    _bytesTransferred = 0;
    _resumeOffset = 0;
    _useChecksumForTransfer = false;
  }

  void _fireProgress() {
    onProgress?.call(YappProgressEvent(
      filename: _currentFilename,
      fileSize: _fileSize,
      bytesTransferred: _bytesTransferred,
      percentage:
          _fileSize > 0 ? ((_bytesTransferred * 100) ~/ _fileSize) : 0,
    ));
  }

  void _onError(String error) {
    final wasReceive = _mode == YappMode.receive;

    _cleanupTransfer();

    onError?.call(YappErrorEvent(
      error: error,
      filename: _currentFilename,
    ));

    if (wasReceive) {
      _setState(YappState.receiveInit);
    } else {
      _setState(YappState.idle);
    }
  }
}
