import '../core/data_broker_client.dart';

/// A log entry with timestamp, level, and message.
class LogEntry {
  final DateTime time;
  final String level;
  final String message;

  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  @override
  String toString() =>
      '[${time.toIso8601String()}] $level: $message';
}

/// Stores log entries in a circular buffer.
///
/// Port of HTCommander.Core/LogStore.cs
/// Subscribes to LogInfo/LogError on device 1, dispatches LogList on request.
class LogStore {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<LogEntry> _entries = [];
  static const int _maxEntries = 500;

  /// Unmodifiable view of current log entries.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Number of log entries currently stored.
  int get logCount => _entries.length;

  LogStore() {
    _broker.subscribe(1, 'LogInfo', _onLogInfo);
    _broker.subscribe(1, 'LogError', _onLogError);
    _broker.subscribe(0, 'RequestLogList', _onRequestLogList);
  }

  void _onLogInfo(int deviceId, String name, Object? data) {
    if (data is! String) return;
    _addEntry(LogEntry(
      time: DateTime.now(),
      level: 'Info',
      message: data,
    ));
  }

  void _onLogError(int deviceId, String name, Object? data) {
    if (data is! String) return;
    _addEntry(LogEntry(
      time: DateTime.now(),
      level: 'Error',
      message: data,
    ));
  }

  void _addEntry(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
  }

  void _onRequestLogList(int deviceId, String name, Object? data) {
    _broker.dispatch(1, 'LogList', List<LogEntry>.from(_entries),
        store: false);
  }

  /// Clears all log entries.
  void clearLogs() {
    _entries.clear();
    _broker.dispatch(1, 'LogList', <LogEntry>[], store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}
