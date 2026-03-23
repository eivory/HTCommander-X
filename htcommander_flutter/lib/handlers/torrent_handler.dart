import '../core/data_broker_client.dart';

/// A torrent file transfer entry.
class TorrentFile {
  final String id;
  final String fileName;
  final int fileSize;
  final String mode;
  final int totalBlocks;
  int receivedBlocks;

  TorrentFile({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.mode,
    required this.totalBlocks,
    this.receivedBlocks = 0,
  });

  /// Progress as a fraction from 0.0 to 1.0.
  double get progress =>
      totalBlocks > 0 ? receivedBlocks / totalBlocks : 0.0;
}

/// Manages torrent file transfers.
///
/// Simplified stub port of HTCommander.Core/Torrent.cs
class TorrentHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<TorrentFile> _files = [];

  TorrentHandler() {
    _broker.subscribe(0, 'TorrentAddFile', _onAddFile);
    _broker.subscribe(0, 'TorrentRemoveFile', _onRemoveFile);
    _broker.subscribe(0, 'TorrentGetFiles', _onGetFiles);
  }

  void _onAddFile(int deviceId, String name, Object? data) {
    if (data is! TorrentFile) return;
    _files.add(data);
    _dispatchFiles();
  }

  void _onRemoveFile(int deviceId, String name, Object? data) {
    if (data is! String) return;
    _files.removeWhere((f) => f.id == data);
    _dispatchFiles();
  }

  void _onGetFiles(int deviceId, String name, Object? data) {
    _dispatchFiles();
  }

  /// Adds a torrent file to the list.
  void add(TorrentFile file) {
    _files.add(file);
    _dispatchFiles();
  }

  /// Removes a torrent file by ID.
  void remove(String id) {
    _files.removeWhere((f) => f.id == id);
    _dispatchFiles();
  }

  /// Returns all torrent files.
  List<TorrentFile> getFiles() => List.unmodifiable(_files);

  void _dispatchFiles() {
    _broker.dispatch(1, 'TorrentFiles', List<TorrentFile>.from(_files),
        store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}
