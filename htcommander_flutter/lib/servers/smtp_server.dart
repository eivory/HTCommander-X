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

/// Local SMTP server for Winlink email integration.
///
/// AUTH PLAIN with WinlinkPassword validation (constant-time comparison).
/// Loopback-only binding.
/// Port of HTCommander.Core/WinLink/SmtpServer.cs.
class SmtpServer {
  final DataBrokerClient _broker = DataBrokerClient();
  final int port;
  ServerSocket? _serverSocket;
  final List<_SmtpSession> _sessions = [];
  static const int _maxSessions = 10;
  int _globalAuthFailures = 0;
  int _lastAuthFailureReset = DateTime.now().millisecondsSinceEpoch;
  static const int _maxGlobalAuthFailuresPerMinute = 20;

  SmtpServer({required this.port});

  bool checkGlobalAuthRateLimit() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAuthFailureReset > 60000) {
      _globalAuthFailures = 0;
      _lastAuthFailureReset = now;
    }
    return _globalAuthFailures < _maxGlobalAuthFailuresPerMinute;
  }

  void recordAuthFailure() {
    _globalAuthFailures++;
  }

  Future<void> start() async {
    try {
      _serverSocket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _broker.logInfo('SMTP server started on port $port');

      _serverSocket!.listen(
        (socket) {
          if (_sessions.length >= _maxSessions) {
            socket.close();
            return;
          }
          final session = _SmtpSession(this, socket, _broker);
          _sessions.add(session);
          session.run();
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      // SMTP server failed to start
    }
  }

  void stop() {
    _serverSocket?.close();
    _serverSocket = null;
    for (final session in List.of(_sessions)) {
      session.close();
    }
    _sessions.clear();
    _broker.logInfo('SMTP server stopped');
  }

  void _removeSession(_SmtpSession session) {
    _sessions.remove(session);
  }

  void dispose() {
    stop();
    _broker.dispose();
  }
}

class _SmtpSession {
  final SmtpServer _server;
  final Socket _socket;
  final DataBrokerClient _broker;
  String? _mailFrom;
  final List<String> _rcptTo = [];
  bool _inDataMode = false;
  final StringBuffer _dataBuffer = StringBuffer();
  bool _authenticated = false;
  int _authAttempts = 0;
  static const int _maxAuthAttempts = 5;
  static const int _maxDataSize = 10 * 1024 * 1024; // 10MB

  _SmtpSession(this._server, this._socket, this._broker);

  void run() {
    // Send greeting
    _sendLine('220 localhost ESMTP');

    final lineBuffer = StringBuffer();

    _socket.listen(
      (data) {
        final received = ascii.decode(data, allowInvalid: true);
        lineBuffer.write(received);

        var buf = lineBuffer.toString();
        int nlPos;
        while ((nlPos = buf.indexOf('\n')) >= 0) {
          final line = buf.substring(0, nlPos).trimRight();
          buf = buf.substring(nlPos + 1);

          if (line.isNotEmpty || _inDataMode) {
            if (_inDataMode) {
              _processDataLine(line);
            } else {
              _processCommand(line);
            }
          }
        }

        lineBuffer.clear();
        if (buf.length > _maxDataSize || _dataBuffer.length > _maxDataSize) {
          _sendLine('552 Too much data');
          close();
          return;
        }
        lineBuffer.write(buf);
      },
      onError: (_) => close(),
      onDone: close,
      cancelOnError: false,
    );
  }

  void _processCommand(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.isEmpty) return;

    final command = parts[0].toUpperCase();
    final args = parts.length > 1 ? line.substring(parts[0].length).trim() : '';

    switch (command) {
      case 'HELO':
      case 'EHLO':
        if (command == 'EHLO') {
          _sendLine('250-localhost');
          _sendLine('250-AUTH PLAIN');
          _sendLine('250-8BITMIME');
          _sendLine('250-SIZE 10240000');
          _sendLine('250 HELP');
        } else {
          _sendLine('250 localhost');
        }
      case 'AUTH':
        _handleAuth(args);
      case 'MAIL':
        if (!_authenticated) {
          _sendLine('530 Authentication required');
        } else {
          _handleMailFrom(args);
        }
      case 'RCPT':
        if (!_authenticated) {
          _sendLine('530 Authentication required');
        } else {
          _handleRcptTo(args);
        }
      case 'DATA':
        if (!_authenticated) {
          _sendLine('530 Authentication required');
        } else {
          _handleData();
        }
      case 'RSET':
        _mailFrom = null;
        _rcptTo.clear();
        _dataBuffer.clear();
        _inDataMode = false;
        _sendLine('250 OK');
      case 'NOOP':
        _sendLine('250 OK');
      case 'QUIT':
        _sendLine('221 Bye');
        close();
      default:
        _sendLine('500 Command not recognized');
    }
  }

  void _handleAuth(String args) {
    if (_authAttempts >= _maxAuthAttempts ||
        !_server.checkGlobalAuthRateLimit()) {
      _sendLine('421 Too many authentication attempts');
      close();
      return;
    }
    _authAttempts++;

    final authParts = args.split(RegExp(r'\s+'));
    if (authParts.length < 2 ||
        authParts[0].toUpperCase() != 'PLAIN') {
      _sendLine('504 Unrecognized authentication type');
      return;
    }

    try {
      final decoded = base64Decode(authParts[1].trim());
      final decodedStr = utf8.decode(decoded, allowMalformed: true);
      final parts = decodedStr.split('\x00');
      final user = parts.length > 1 ? parts[1] : '';
      final pass = parts.length > 2 ? parts[2] : '';

      if (!_isValidUsername(user)) {
        _sendLine('535 Authentication failed');
        return;
      }

      final winlinkPassword =
          DataBroker.getValue<String>(0, 'WinlinkPassword', '');
      if (winlinkPassword.isEmpty) {
        _sendLine('535 Authentication failed');
        return;
      }

      // Constant-time comparison
      if (_constantTimeEquals(
          utf8.encode(pass), utf8.encode(winlinkPassword))) {
        _authenticated = true;
        _sendLine('235 Authentication successful');
      } else {
        _server.recordAuthFailure();
        _sendLine('535 Authentication failed');
      }
    } on FormatException {
      _server.recordAuthFailure();
      _sendLine('501 Malformed AUTH data');
    }
  }

  void _handleMailFrom(String args) {
    if (!args.toUpperCase().startsWith('FROM:')) {
      _sendLine('501 Syntax error in MAIL FROM command');
      return;
    }
    var address = args.substring(5).trim();
    if (address.startsWith('<') && address.endsWith('>')) {
      address = address.substring(1, address.length - 1);
    }
    _mailFrom = address;
    _rcptTo.clear();
    _sendLine('250 OK');
  }

  void _handleRcptTo(String args) {
    if (!args.toUpperCase().startsWith('TO:')) {
      _sendLine('501 Syntax error in RCPT TO command');
      return;
    }
    var address = args.substring(3).trim();
    if (address.startsWith('<') && address.endsWith('>')) {
      address = address.substring(1, address.length - 1);
    }
    if (_rcptTo.length >= 100) {
      _sendLine('452 Too many recipients');
      return;
    }
    _rcptTo.add(address);
    _sendLine('250 OK');
  }

  void _handleData() {
    if (_mailFrom == null || _mailFrom!.isEmpty || _rcptTo.isEmpty) {
      _sendLine('503 Bad sequence of commands');
      return;
    }
    _sendLine('354 Start mail input; end with <CRLF>.<CRLF>');
    _inDataMode = true;
    _dataBuffer.clear();
  }

  void _processDataLine(String line) {
    if (line == '.') {
      _inDataMode = false;
      _processEmailData();
      return;
    }
    if (line.startsWith('..')) {
      line = line.substring(1);
    }
    _dataBuffer.writeln(line);
  }

  void _processEmailData() {
    try {
      final emailData = _dataBuffer.toString();
      String from = _mailFrom ?? '';
      String to = _rcptTo.join('; ');
      String cc = '';
      String subject = '';
      String body = '';
      DateTime dateTime = DateTime.now();

      final lines = emailData.split('\n');
      bool inHeaders = true;
      final bodyBuilder = StringBuffer();

      for (final rawLine in lines) {
        final line = rawLine.trimRight();
        if (inHeaders) {
          if (line.isEmpty) {
            inHeaders = false;
            continue;
          }
          final lower = line.toLowerCase();
          if (lower.startsWith('from:')) {
            from = _extractAddress(line.substring(5).trim());
          } else if (lower.startsWith('to:')) {
            to = line.substring(3).trim();
          } else if (lower.startsWith('cc:')) {
            cc = line.substring(3).trim();
          } else if (lower.startsWith('subject:')) {
            subject = line.substring(8).trim();
          } else if (lower.startsWith('date:')) {
            final dateStr = line.substring(5).trim();
            dateTime = DateTime.tryParse(dateStr) ?? DateTime.now();
          }
        } else {
          bodyBuilder.writeln(line);
        }
      }
      body = bodyBuilder.toString().trimRight();

      final mid = DateTime.now().millisecondsSinceEpoch.toRadixString(16)
          .padLeft(12, '0')
          .toUpperCase()
          .substring(0, 12);

      final mail = {
        'mid': mid,
        'from': from,
        'to': to,
        'cc': cc,
        'subject': subject,
        'body': body,
        'date': dateTime.toIso8601String(),
        'folder': 'Outbox',
      };

      DataBroker.dispatch(1, 'MailReceived', mail, store: false);
      _broker.logInfo('SMTP: Email queued - From: $from, To: $to');
      _sendLine('250 OK: Message accepted for delivery');
    } catch (_) {
      _sendLine('554 Transaction failed');
    } finally {
      _mailFrom = null;
      _rcptTo.clear();
      _dataBuffer.clear();
    }
  }

  String _extractAddress(String from) {
    if (from.contains('<') && from.contains('>')) {
      final start = from.indexOf('<') + 1;
      final end = from.indexOf('>');
      return from.substring(start, end);
    }
    return from;
  }

  bool _isValidUsername(String user) {
    final callsign = DataBroker.getValue<String>(0, 'CallSign', '');
    final stationId = DataBroker.getValue<int>(0, 'StationId', 0);

    if (user.isEmpty || callsign.isEmpty) return false;

    final upperUser = user.toUpperCase();
    final upperCallsign = callsign.toUpperCase();
    final callsignWithId =
        stationId > 0 ? '$upperCallsign-$stationId' : upperCallsign;

    return upperUser == upperCallsign ||
        upperUser == callsignWithId ||
        upperUser == '$upperCallsign@WINLINK.ORG' ||
        upperUser == '$callsignWithId@WINLINK.ORG';
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  void _sendLine(String text) {
    try {
      _socket.write('$text\r\n');
    } catch (_) {}
  }

  void close() {
    try {
      _socket.close();
    } catch (_) {}
    _server._removeSession(this);
  }
}

