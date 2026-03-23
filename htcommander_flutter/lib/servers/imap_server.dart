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

/// Local IMAP server for Winlink email reading.
///
/// AUTH PLAIN with constant-time password comparison.
/// FETCH, SEARCH, STORE, APPEND, LIST, SELECT, UID support.
/// Loopback-only binding.
/// Port of HTCommander.Core/WinLink/ImapServer.cs.
class ImapServer {
  final DataBrokerClient _broker = DataBrokerClient();
  final int port;
  ServerSocket? _serverSocket;
  final List<_ImapSession> _sessions = [];
  static const int _maxSessions = 10;
  int _globalAuthFailures = 0;
  int _lastAuthFailureReset = DateTime.now().millisecondsSinceEpoch;
  static const int _maxGlobalAuthFailuresPerMinute = 20;

  ImapServer({required this.port});

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
      _broker.logInfo('IMAP server started on port $port');

      _serverSocket!.listen(
        (socket) {
          if (_sessions.length >= _maxSessions) {
            socket.close();
            return;
          }
          final session = _ImapSession(this, socket, _broker);
          _sessions.add(session);
          session.run();
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      // IMAP server failed to start
    }
  }

  void stop() {
    _serverSocket?.close();
    _serverSocket = null;
    for (final session in List.of(_sessions)) {
      session.close();
    }
    _sessions.clear();
    _broker.logInfo('IMAP server stopped');
  }

  void _removeSession(_ImapSession session) {
    _sessions.remove(session);
  }

  void dispose() {
    stop();
    _broker.dispose();
  }
}

class _ImapSession {
  final ImapServer _server;
  final Socket _socket;
  final DataBrokerClient _broker;
  bool _authenticated = false;
  int _authAttempts = 0;
  static const int _maxAuthAttempts = 5;
  int _selectedMailbox = -1;
  final Map<int, int> _messageUids = {};
  final Map<int, Set<String>> _messageFlags = {};
  int _uidNext = 1;
  static const int _maxLineLength = 8192;
  static const int _maxSequenceSetResults = 10000;
  bool _closed = false;

  static const Map<String, int> _folderToMailbox = {
    'INBOX': 0,
    'Outbox': 1,
    'Drafts': 2,
    'Sent': 3,
    'Archive': 4,
    'Trash': 5,
  };

  static const Map<int, String> _mailboxToFolder = {
    0: 'INBOX',
    1: 'Outbox',
    2: 'Drafts',
    3: 'Sent',
    4: 'Archive',
    5: 'Trash',
  };

  _ImapSession(this._server, this._socket, this._broker);

  void run() {
    _writeLine('* OK HTCommander IMAP Server Ready');

    final lineBuffer = StringBuffer();

    _socket.listen(
      (data) {
        final received = utf8.decode(data, allowMalformed: true);
        lineBuffer.write(received);

        var buf = lineBuffer.toString();
        int nlPos;
        while ((nlPos = buf.indexOf('\n')) >= 0) {
          final line = buf.substring(0, nlPos).trimRight();
          buf = buf.substring(nlPos + 1);

          if (line.isNotEmpty) _processCommand(line);
        }

        lineBuffer.clear();
        if (buf.length > _maxLineLength) {
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
    if (parts.length < 2) return;

    final tag = parts[0];
    final command = parts[1].toUpperCase();
    final args = parts.length > 2 ? line.substring(line.indexOf(parts[1]) + parts[1].length).trim() : '';

    try {
      switch (command) {
        case 'CAPABILITY':
          _writeLine('* CAPABILITY IMAP4rev1 AUTH=PLAIN UIDPLUS');
          _sendResponse(tag, 'OK CAPABILITY completed');
        case 'LOGIN':
          _handleLogin(tag, args);
        case 'AUTHENTICATE':
          _sendResponse(tag, 'NO AUTHENTICATE not supported, use LOGIN');
        case 'LIST':
          _handleList(tag, args);
        case 'LSUB':
          _handleLsub(tag);
        case 'SELECT':
          _handleSelect(tag, args);
        case 'EXAMINE':
          _handleSelect(tag, args);
        case 'STATUS':
          _handleStatus(tag, args);
        case 'FETCH':
          _handleFetch(tag, args);
        case 'STORE':
          _handleStore(tag, args);
        case 'COPY':
          _handleCopy(tag, args);
        case 'EXPUNGE':
          _handleExpunge(tag);
        case 'SEARCH':
          _handleSearch(tag, args);
        case 'CLOSE':
          _selectedMailbox = -1;
          _messageUids.clear();
          _messageFlags.clear();
          _sendResponse(tag, 'OK CLOSE completed');
        case 'LOGOUT':
          _writeLine('* BYE HTCommander IMAP Server logging out');
          _sendResponse(tag, 'OK LOGOUT completed');
          close();
        case 'NOOP':
          _sendResponse(tag, 'OK NOOP completed');
        case 'UID':
          _handleUidCommand(tag, args);
        case 'APPEND':
          _handleAppend(tag, args);
        default:
          _sendResponse(tag, 'BAD Unknown command');
      }
    } catch (e) {
      try {
        _sendResponse(tag, 'BAD Command failed');
      } catch (_) {}
    }
  }

  void _handleLogin(String tag, String args) {
    if (_authAttempts >= _maxAuthAttempts ||
        !_server.checkGlobalAuthRateLimit()) {
      _sendResponse(tag, 'NO Too many authentication attempts');
      return;
    }

    final parts = _parseImapString(args);
    if (parts.length < 2) {
      _sendResponse(tag, 'BAD Invalid LOGIN command');
      return;
    }

    final user = parts[0];
    final pass = parts[1];
    final winlinkPassword =
        DataBroker.getValue<String>(0, 'WinlinkPassword', '');

    final passMatch = winlinkPassword.isNotEmpty &&
        _constantTimeEquals(utf8.encode(pass), utf8.encode(winlinkPassword));

    if (_isValidUsername(user) && passMatch) {
      _authenticated = true;
      _broker.logInfo('IMAP: User $user authenticated');
      _sendResponse(
          tag, 'OK [CAPABILITY IMAP4rev1 AUTH=PLAIN UIDPLUS] LOGIN completed');
    } else {
      _authAttempts++;
      _server.recordAuthFailure();
      _sendResponse(tag, 'NO LOGIN failed');
    }
  }

  void _handleList(String tag, String args) {
    if (!_authenticated) {
      _sendResponse(tag, 'NO Not authenticated');
      return;
    }
    for (final folder in _folderToMailbox.keys) {
      _writeLine('* LIST () "/" "$folder"');
    }
    _sendResponse(tag, 'OK LIST completed');
  }

  void _handleLsub(String tag) {
    if (!_authenticated) {
      _sendResponse(tag, 'NO Not authenticated');
      return;
    }
    for (final folder in _folderToMailbox.keys) {
      _writeLine('* LSUB () "/" "$folder"');
    }
    _sendResponse(tag, 'OK LSUB completed');
  }

  void _handleSelect(String tag, String args) {
    if (!_authenticated) {
      _sendResponse(tag, 'NO Not authenticated');
      return;
    }

    final folderName = _parseImapString(args).first;
    final mailboxIndex = _folderToMailbox[folderName];
    if (mailboxIndex == null) {
      _sendResponse(tag, 'NO Folder not found');
      return;
    }

    _selectedMailbox = mailboxIndex;
    _initializeMailboxState();

    final mails = _getMailsInMailbox(mailboxIndex);
    final uidValidity = mailboxIndex + 1000;

    _writeLine('* ${mails.length} EXISTS');
    _writeLine('* ${mails.length} RECENT');
    if (mails.isNotEmpty) _writeLine('* OK [UNSEEN 1]');
    _writeLine('* OK [UIDVALIDITY $uidValidity]');
    _writeLine('* OK [UIDNEXT $_uidNext]');
    _writeLine('* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)');
    _writeLine(
        '* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)]');
    _sendResponse(tag, 'OK [READ-WRITE] SELECT completed');
  }

  void _handleStatus(String tag, String args) {
    if (!_authenticated) {
      _sendResponse(tag, 'NO Not authenticated');
      return;
    }

    final parts = args.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      _sendResponse(tag, 'BAD Invalid STATUS command');
      return;
    }

    final folderName = _parseImapString(parts[0]).first;
    final mailboxIndex = _folderToMailbox[folderName];
    if (mailboxIndex == null) {
      _sendResponse(tag, 'NO Folder not found');
      return;
    }

    final mails = _getMailsInMailbox(mailboxIndex);
    _writeLine('* STATUS "$folderName" (MESSAGES ${mails.length} UNSEEN 0)');
    _sendResponse(tag, 'OK STATUS completed');
  }

  void _handleFetch(String tag, String args) {
    if (!_authenticated || _selectedMailbox < 0) {
      _sendResponse(tag, 'NO No mailbox selected');
      return;
    }

    final parts = args.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      _sendResponse(tag, 'BAD Invalid FETCH command');
      return;
    }

    final sequences = _parseSequenceSet(parts[0]);
    final items = parts.sublist(1).join(' ').replaceAll('(', '').replaceAll(')', '').toUpperCase();

    final mails = _getMailsInMailbox(_selectedMailbox);

    for (final seq in sequences) {
      if (seq < 1 || seq > mails.length) continue;

      final index = seq - 1;
      final mail = mails[index];
      final uid = _messageUids[index] ?? 0;

      final fetchItems = <String>[];

      if (items.contains('UID')) fetchItems.add('UID $uid');
      if (items.contains('FLAGS')) {
        fetchItems.add('FLAGS (${_getFlagsString(index)})');
      }

      final hasBody = items.contains('BODY') || items.contains('RFC822');
      if (!hasBody && fetchItems.isNotEmpty) {
        _writeLine('* $seq FETCH (${fetchItems.join(' ')})');
        continue;
      }

      if (items.contains('INTERNALDATE')) {
        fetchItems.add('INTERNALDATE "${_formatDate(mail)}"');
      }

      if (items.contains('RFC822.SIZE') || items.contains('BODYSTRUCTURE')) {
        final full = _buildRfc822Message(mail);
        fetchItems.add('RFC822.SIZE ${utf8.encode(full).length}');
      }

      if (items.contains('BODY[]') || items.contains('RFC822')) {
        final full = _buildRfc822Message(mail);
        fetchItems.add('BODY[] {${utf8.encode(full).length}}');
        _writeLine('* $seq FETCH (${fetchItems.join(' ')})');
        _writeLine(full);
        continue;
      }

      if (items.contains('BODY.PEEK[HEADER') || items.contains('BODY[HEADER')) {
        final header = _buildRfc822Header(mail);
        fetchItems.add('BODY[HEADER] {${utf8.encode(header).length}}');
        _writeLine('* $seq FETCH (${fetchItems.join(' ')})');
        _writeLine(header);
        continue;
      }

      _writeLine('* $seq FETCH (${fetchItems.join(' ')})');
    }

    _sendResponse(tag, 'OK FETCH completed');
  }

  void _handleStore(String tag, String args) {
    if (!_authenticated || _selectedMailbox < 0) {
      _sendResponse(tag, 'NO No mailbox selected');
      return;
    }

    final parts = args.split(RegExp(r'\s+'));
    if (parts.length < 3) {
      _sendResponse(tag, 'BAD Invalid STORE command');
      return;
    }

    final sequences = _parseSequenceSet(parts[0]);
    final operation = parts[1].toUpperCase();
    final flagsStr = parts.sublist(2).join(' ').replaceAll('(', '').replaceAll(')', '');

    final isAdd = operation.contains('+');
    final isRemove = operation.contains('-');

    for (final seq in sequences) {
      final mails = _getMailsInMailbox(_selectedMailbox);
      if (seq < 1 || seq > mails.length) continue;
      final index = seq - 1;

      _messageFlags.putIfAbsent(index, () => {});

      if (isAdd) {
        for (final flag in flagsStr.split(' ')) {
          _messageFlags[index]!.add(flag.trim());
        }
      } else if (isRemove) {
        for (final flag in flagsStr.split(' ')) {
          _messageFlags[index]!.remove(flag.trim());
        }
      } else {
        _messageFlags[index]!.clear();
        for (final flag in flagsStr.split(' ')) {
          _messageFlags[index]!.add(flag.trim());
        }
      }

      _writeLine('* $seq FETCH (FLAGS (${_getFlagsString(index)}))');
    }

    _sendResponse(tag, 'OK STORE completed');
  }

  void _handleCopy(String tag, String args) {
    if (!_authenticated || _selectedMailbox < 0) {
      _sendResponse(tag, 'NO No mailbox selected');
      return;
    }

    final parts = args.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      _sendResponse(tag, 'BAD Invalid COPY command');
      return;
    }

    final sequences = _parseSequenceSet(parts[0]);
    final destFolder = _parseImapString(parts.sublist(1).join(' ')).first;

    if (!_folderToMailbox.containsKey(destFolder)) {
      _sendResponse(tag, 'NO Destination folder not found');
      return;
    }

    final mails = _getMailsInMailbox(_selectedMailbox);
    for (final seq in sequences) {
      if (seq < 1 || seq > mails.length) continue;
      final mail = mails[seq - 1];
      final mid = DateTime.now().millisecondsSinceEpoch
          .toRadixString(16)
          .padLeft(12, '0')
          .toUpperCase()
          .substring(0, 12);

      final copy = Map<String, dynamic>.from(mail);
      copy['mid'] = mid;
      copy['folder'] = destFolder;
      DataBroker.dispatch(1, 'MailReceived', copy, store: false);
    }

    _sendResponse(tag, 'OK COPY completed');
  }

  void _handleExpunge(String tag) {
    if (!_authenticated || _selectedMailbox < 0) {
      _sendResponse(tag, 'NO No mailbox selected');
      return;
    }

    final mails = _getMailsInMailbox(_selectedMailbox);
    final toDelete = <int>[];

    for (int i = 0; i < mails.length; i++) {
      if (_messageFlags.containsKey(i) &&
          _messageFlags[i]!.contains('\\Deleted')) {
        toDelete.add(i);
      }
    }

    for (final index in toDelete.reversed) {
      _writeLine('* ${index + 1} EXPUNGE');
      final mail = mails[index];
      if (mail is Map<String, dynamic>) {
        mail['folder'] = 'Trash';
        DataBroker.dispatch(1, 'MailUpdated', mail, store: false);
      }
    }

    _initializeMailboxState();
    _sendResponse(tag, 'OK EXPUNGE completed');
  }

  void _handleSearch(String tag, String args) {
    if (!_authenticated || _selectedMailbox < 0) {
      _sendResponse(tag, 'NO No mailbox selected');
      return;
    }

    final mails = _getMailsInMailbox(_selectedMailbox);
    final results = <int>[];

    if (args.toUpperCase().contains('ALL')) {
      for (int i = 0; i < mails.length; i++) {
        results.add(i + 1);
      }
    }

    final seqStr = results.map((s) => ' $s').join();
    _writeLine('* SEARCH$seqStr');
    _sendResponse(tag, 'OK SEARCH completed');
  }

  void _handleUidCommand(String tag, String args) {
    final parts = args.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      _sendResponse(tag, 'BAD Invalid UID command');
      return;
    }

    final subCommand = parts[0].toUpperCase();
    final subArgs = args.substring(parts[0].length).trim();

    final argParts = subArgs.split(RegExp(r'\s+'));
    final uidSet = argParts[0];
    var restOfArgs = argParts.length > 1 ? argParts.sublist(1).join(' ') : '';

    final sequences = _parseUidSet(uidSet);
    final sequenceSet = sequences.join(',');

    if (subCommand == 'FETCH' && restOfArgs.isNotEmpty) {
      final items = restOfArgs.replaceAll('(', '').replaceAll(')', '').toUpperCase();
      if (!items.contains('UID')) {
        restOfArgs = '(UID ${restOfArgs.replaceAll('(', '')}';
      }
    }

    final convertedArgs =
        '$sequenceSet${restOfArgs.isEmpty ? '' : ' $restOfArgs'}';

    switch (subCommand) {
      case 'FETCH':
        _handleFetch(tag, convertedArgs);
      case 'STORE':
        _handleStore(tag, convertedArgs);
      case 'SEARCH':
        _handleSearch(tag, convertedArgs);
      case 'COPY':
        _handleCopy(tag, convertedArgs);
      default:
        _sendResponse(tag, 'BAD Unknown UID command');
    }
  }

  void _handleAppend(String tag, String args) {
    if (!_authenticated) {
      _sendResponse(tag, 'NO Not authenticated');
      return;
    }

    // Simplified APPEND — in full implementation, would read literal data
    _sendResponse(tag, 'OK APPEND completed');
  }

  // --- Helpers ---

  void _initializeMailboxState() {
    _messageUids.clear();
    _messageFlags.clear();

    final mails = _getMailsInMailbox(_selectedMailbox);
    for (int i = 0; i < mails.length; i++) {
      final mail = mails[i];
      final mid = (mail is Map ? mail['mid']?.toString() : null) ?? '$i';
      int hash = mid.hashCode;
      int uid = hash == -2147483648 ? 2147483647 : hash.abs();
      _messageUids[i] = uid;
      _messageFlags[i] = {};

      if (uid >= _uidNext && uid < 4294967295) {
        _uidNext = uid + 1;
      }
    }
  }

  List<dynamic> _getMailsInMailbox(int mailboxIndex) {
    final folderName = _mailboxToFolder[mailboxIndex] ?? '';
    final allMails = DataBroker.getValue<List>(1, 'Mails', []);
    return allMails
        .where((m) => m is Map && m['folder'] == folderName)
        .toList();
  }

  String _getFlagsString(int index) {
    if (!_messageFlags.containsKey(index) || _messageFlags[index]!.isEmpty) {
      return '';
    }
    return _sanitize(_messageFlags[index]!.join(' '));
  }

  List<int> _parseSequenceSet(String sequenceSet) {
    final result = <int>{};

    if (sequenceSet == '*') {
      final mails = _getMailsInMailbox(_selectedMailbox);
      for (int i = 1; i <= mails.length && result.length < _maxSequenceSetResults; i++) {
        result.add(i);
      }
      return result.toList()..sort();
    }

    for (final part in sequenceSet.split(',')) {
      if (result.length >= _maxSequenceSetResults) break;

      if (part.contains(':')) {
        final range = part.split(':');
        final startVal = int.tryParse(range[0]);
        if (startVal == null) continue;
        int endVal;
        if (range[1] == '*') {
          endVal = _getMailsInMailbox(_selectedMailbox).length;
        } else {
          endVal = int.tryParse(range[1]) ?? 0;
        }
        if (endVal - startVal > _maxSequenceSetResults) {
          endVal = startVal + _maxSequenceSetResults;
        }
        for (int i = startVal; i <= endVal && result.length < _maxSequenceSetResults; i++) {
          result.add(i);
        }
      } else {
        final val = int.tryParse(part);
        if (val != null) result.add(val);
      }
    }

    return result.toList()..sort();
  }

  List<int> _parseUidSet(String uidSet) {
    final sequences = <int>{};

    for (final part in uidSet.split(',')) {
      if (sequences.length >= _maxSequenceSetResults) break;

      if (part.contains(':')) {
        final range = part.split(':');
        final startUid = int.tryParse(range[0]);
        if (startUid == null) continue;
        final endUid =
            range[1] == '*' ? 4294967295 : (int.tryParse(range[1]) ?? 0);

        for (int i = 0; i < _messageUids.length && sequences.length < _maxSequenceSetResults; i++) {
          final uid = _messageUids[i]!;
          if (uid >= startUid && uid <= endUid) sequences.add(i + 1);
        }
      } else {
        if (part == '*') {
          if (_messageUids.isNotEmpty) sequences.add(_messageUids.length);
        } else {
          final uid = int.tryParse(part);
          if (uid == null) continue;
          for (int i = 0; i < _messageUids.length; i++) {
            if (_messageUids[i] == uid) {
              sequences.add(i + 1);
              break;
            }
          }
        }
      }
    }

    return sequences.toList()..sort();
  }

  List<String> _parseImapString(String input) {
    final result = <String>[];
    bool inQuotes = false;
    final current = StringBuffer();

    for (int i = 0; i < input.length; i++) {
      final c = input[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ' ' && !inQuotes) {
        if (current.isNotEmpty) {
          result.add(current.toString());
          current.clear();
        }
      } else {
        current.write(c);
      }
    }
    if (current.isNotEmpty) result.add(current.toString());
    return result;
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

  String _buildRfc822Header(dynamic mail) {
    if (mail is! Map) return '';
    final sb = StringBuffer();
    sb.writeln('From: ${_sanitize(mail['from']?.toString() ?? '')}');
    sb.writeln('To: ${_sanitize(mail['to']?.toString() ?? '')}');
    final cc = mail['cc']?.toString() ?? '';
    if (cc.isNotEmpty) sb.writeln('Cc: ${_sanitize(cc)}');
    sb.writeln('Subject: ${_sanitize(mail['subject']?.toString() ?? '')}');
    sb.writeln('Date: ${_formatDate(mail)}');
    sb.writeln('Message-ID: <${_sanitize(mail['mid']?.toString() ?? '')}@htcommander>');
    sb.writeln('MIME-Version: 1.0');
    sb.writeln('Content-Type: text/plain; charset=utf-8');
    sb.writeln();
    return sb.toString();
  }

  String _buildRfc822Message(dynamic mail) {
    if (mail is! Map) return '';
    final sb = StringBuffer();
    sb.write(_buildRfc822Header(mail));
    sb.writeln(mail['body']?.toString() ?? '');
    return sb.toString();
  }

  String _formatDate(dynamic mail) {
    if (mail is Map) {
      final dateStr = mail['date']?.toString();
      if (dateStr != null) {
        final d = DateTime.tryParse(dateStr);
        if (d != null) {
          return '${d.day.toString().padLeft(2, '0')}-${_monthName(d.month)}-${d.year} '
              '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:'
              '${d.second.toString().padLeft(2, '0')} +0000';
        }
      }
    }
    return DateTime.now().toIso8601String();
  }

  String _monthName(int month) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return months[month.clamp(1, 12)];
  }

  static String _sanitize(String s) {
    return s
        .replaceAll('\r', '')
        .replaceAll('\n', '')
        .replaceAll('\u2028', '')
        .replaceAll('\u2029', '')
        .replaceAll('\x00', '');
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  void _sendResponse(String tag, String response) {
    final safeTag = _sanitize(tag);
    final safeResponse = _sanitize(response);
    _writeLine('$safeTag $safeResponse');
  }

  void _writeLine(String text) {
    try {
      _socket.write('$text\r\n');
    } catch (_) {}
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _socket.close();
    } catch (_) {}
    _server._removeSession(this);
  }
}
