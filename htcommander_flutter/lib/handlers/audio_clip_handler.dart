import 'dart:io';

import '../core/data_broker.dart';
import '../core/data_broker_client.dart';

/// Metadata for an audio clip.
class AudioClipEntry {
  final String name;
  final String duration;
  final String size;

  const AudioClipEntry({
    required this.name,
    required this.duration,
    required this.size,
  });
}

/// Manages audio clips stored as WAV files.
///
/// Simplified port of HTCommander.Core/AudioClipHandler.cs
/// Validates clip names to prevent path traversal.
class AudioClipHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  String? _clipsDirectory;

  /// Maximum clip size in bytes (10 MB).
  static const int maxClipSize = 10 * 1024 * 1024;

  AudioClipHandler() {
    _broker.subscribe(
        DataBroker.allDevices, 'PlayAudioClip', _onPlayAudioClip);
    _broker.subscribe(
        DataBroker.allDevices, 'StopAudioClip', _onStopAudioClip);
    _broker.subscribe(
        DataBroker.allDevices, 'DeleteAudioClip', _onDeleteAudioClip);
    _broker.subscribe(
        DataBroker.allDevices, 'RenameAudioClip', _onRenameAudioClip);
    _broker.subscribe(
        DataBroker.allDevices, 'SaveAudioClip', _onSaveAudioClip);
    _broker.subscribe(
        DataBroker.allDevices, 'RequestAudioClips', _onRequestAudioClips);
  }

  /// Sets the clips directory path. Must be called before clip operations.
  void setClipsDirectory(String path) {
    _clipsDirectory = path;
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Validates a clip name and returns a safe file path, or null if invalid.
  String? _safeClipPath(String clipName) {
    if (clipName.isEmpty) return null;
    if (clipName.contains('..') ||
        clipName.contains('/') ||
        clipName.contains('\\')) {
      _broker.logError('AudioClipHandler: invalid clip name: $clipName');
      return null;
    }

    final dir = _clipsDirectory;
    if (dir == null) {
      _broker.logError('AudioClipHandler: clips directory not set');
      return null;
    }

    // Verify resolved path stays within clips directory
    final resolvedPath =
        File('$dir${Platform.pathSeparator}$clipName').resolveSymbolicLinksSync();
    if (!resolvedPath.startsWith(dir)) {
      _broker.logError(
          'AudioClipHandler: path traversal attempt: $clipName');
      return null;
    }

    return '$dir${Platform.pathSeparator}$clipName';
  }

  /// Validates a clip name without requiring the file to exist.
  bool _isValidClipName(String clipName) {
    if (clipName.isEmpty) return false;
    if (clipName.contains('..') ||
        clipName.contains('/') ||
        clipName.contains('\\')) {
      return false;
    }
    return true;
  }

  void _onPlayAudioClip(int deviceId, String name, Object? data) {
    if (data is! String) return;
    final path = _safeClipPath(data);
    if (path == null) return;

    // Stub: actual playback will use platform audio service
    _broker.logInfo('AudioClipHandler: play clip: $data');
  }

  void _onStopAudioClip(int deviceId, String name, Object? data) {
    _broker.logInfo('AudioClipHandler: stop clip playback');
  }

  void _onDeleteAudioClip(int deviceId, String name, Object? data) {
    if (data is! String) return;
    final path = _safeClipPath(data);
    if (path == null) return;

    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
      _broker.logInfo('AudioClipHandler: deleted clip: $data');
      _dispatchClipList();
    }
  }

  void _onRenameAudioClip(int deviceId, String name, Object? data) {
    if (data is! Map) return;
    final oldName = data['oldName'];
    final newName = data['newName'];
    if (oldName is! String || newName is! String) return;

    final oldPath = _safeClipPath(oldName);
    if (oldPath == null) return;
    if (!_isValidClipName(newName)) {
      _broker.logError(
          'AudioClipHandler: invalid new clip name: $newName');
      return;
    }

    final dir = _clipsDirectory;
    if (dir == null) return;

    final newPath = '$dir${Platform.pathSeparator}$newName';
    final oldFile = File(oldPath);
    if (oldFile.existsSync()) {
      oldFile.renameSync(newPath);
      _broker.logInfo(
          'AudioClipHandler: renamed clip: $oldName -> $newName');
      _dispatchClipList();
    }
  }

  void _onSaveAudioClip(int deviceId, String name, Object? data) {
    if (data is! Map) return;
    final clipName = data['name'];
    final clipData = data['data'];
    if (clipName is! String || clipData is! List<int>) return;
    if (!_isValidClipName(clipName)) {
      _broker.logError(
          'AudioClipHandler: invalid clip name: $clipName');
      return;
    }

    if (clipData.length > maxClipSize) {
      _broker.logError(
          'AudioClipHandler: clip too large: ${clipData.length} bytes');
      return;
    }

    final dir = _clipsDirectory;
    if (dir == null) {
      _broker.logError('AudioClipHandler: clips directory not set');
      return;
    }

    final path = '$dir${Platform.pathSeparator}$clipName';
    File(path).writeAsBytesSync(clipData);
    _broker.logInfo('AudioClipHandler: saved clip: $clipName');
    _dispatchClipList();
  }

  void _onRequestAudioClips(int deviceId, String name, Object? data) {
    _dispatchClipList();
  }

  void _dispatchClipList() {
    final dir = _clipsDirectory;
    if (dir == null) {
      _broker.dispatch(DataBroker.allDevices, 'AudioClips',
          <AudioClipEntry>[], store: false);
      return;
    }

    final directory = Directory(dir);
    if (!directory.existsSync()) {
      _broker.dispatch(DataBroker.allDevices, 'AudioClips',
          <AudioClipEntry>[], store: false);
      return;
    }

    final clips = <AudioClipEntry>[];
    for (final entity in directory.listSync()) {
      if (entity is File && entity.path.endsWith('.wav')) {
        final stat = entity.statSync();
        final name = entity.uri.pathSegments.last;
        clips.add(AudioClipEntry(
          name: name,
          duration: '', // WAV duration parsing deferred to later phase
          size: _formatSize(stat.size),
        ));
      }
    }

    clips.sort((a, b) => a.name.compareTo(b.name));
    _broker.dispatch(1, 'AudioClips', clips, store: false);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void dispose() {
    _broker.dispose();
  }
}
