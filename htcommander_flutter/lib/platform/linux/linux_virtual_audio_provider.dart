/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Creates PulseAudio virtual audio devices for bridging radio audio
/// to desktop audio applications (e.g. fldigi, WSJT-X, JS8Call).
///
/// Port of HTCommander.Platform.Linux/LinuxVirtualAudioProvider.cs
class LinuxVirtualAudioProvider {
  int _rxSinkModuleId = -1;
  int _txSinkModuleId = -1;
  int _virtualSourceModuleId = -1;
  Process? _pacatProcess;
  Process? _parecordProcess;
  bool _running = false;
  int _sampleRate = 48000;
  StreamSubscription? _txSubscription;

  /// The name of the TX sink (where apps send audio to transmit).
  String get sinkName => 'HTCommander TX';

  /// The name of the virtual source (where apps receive radio audio).
  String get sourceName => 'HTCommander RX';

  /// Whether the virtual audio devices are currently active.
  bool get isRunning => _running;

  /// Callback invoked when TX audio data is available from the virtual sink.
  void Function(Uint8List data, int length)? onTxDataAvailable;

  /// Allowed PulseAudio module names for security.
  static const _allowedModules = {'module-null-sink', 'module-virtual-source'};

  /// Creates the virtual audio devices and starts audio streaming.
  ///
  /// Returns true on success, false on failure (devices are cleaned up).
  Future<bool> create(int sampleRate) async {
    try {
      _sampleRate = sampleRate;

      // Clean up any stale modules from previous runs
      await _cleanupStaleModules();

      // Load RX null sink — internal pipe for decoded radio audio.
      // The actual user-facing input device is the virtual source below.
      // This sink appears as an output device but is only used internally by pacat.
      _rxSinkModuleId = await _loadModule('module-null-sink',
          'sink_name=HTCommander_RX sink_properties=device.description="HTCommander\\sRX\\s(internal)"');
      if (_rxSinkModuleId < 0) {
        await destroy();
        return false;
      }

      // Load TX null sink — apps send audio here to transmit
      _txSinkModuleId = await _loadModule('module-null-sink',
          'sink_name=HTCommander_TX sink_properties=device.description="HTCommander\\sTX"');
      if (_txSinkModuleId < 0) {
        await destroy();
        return false;
      }

      // Load virtual source — exposes RX audio as a microphone/input device
      _virtualSourceModuleId = await _loadModule('module-virtual-source',
          'source_name=HTCommander_RX_Source master=HTCommander_RX.monitor source_properties=device.description="HTCommander\\sRX"');
      if (_virtualSourceModuleId < 0) {
        await destroy();
        return false;
      }

      // Start pacat — writes decoded radio PCM to the RX sink
      _pacatProcess = await Process.start('pacat', [
        '--device=HTCommander_RX',
        '--format=s16le',
        '--rate=$sampleRate',
        '--channels=1',
        '--raw',
        '--latency-msec=20',
      ]);

      // Start parecord — reads TX audio from the TX sink monitor
      _parecordProcess = await Process.start('parecord', [
        '--device=HTCommander_TX.monitor',
        '--format=s16le',
        '--rate=$sampleRate',
        '--channels=1',
        '--raw',
        '--latency-msec=20',
      ]);

      // Listen for TX audio data
      _txSubscription = _parecordProcess!.stdout.listen((chunk) {
        if (!_running) return;

        // Check for silence — sample every 64 bytes
        bool isSilent = true;
        for (var i = 0; i < chunk.length && isSilent; i += 64) {
          if (chunk[i] != 0) isSilent = false;
        }
        if (isSilent) return;

        final data = Uint8List.fromList(chunk);
        onTxDataAvailable?.call(data, data.length);
      });

      _running = true;
      return true;
    } catch (_) {
      await destroy();
      return false;
    }
  }

  /// Writes decoded radio PCM samples to the RX virtual sink.
  void writeSamples(Uint8List pcm) {
    if (!_running || _pacatProcess == null) return;
    try {
      _pacatProcess!.stdin.add(pcm);
    } catch (_) {
      // Process may have exited
    }
  }

  /// Destroys the virtual audio devices and stops all processes.
  Future<void> destroy() async {
    _running = false;

    // Cancel TX stream subscription
    await _txSubscription?.cancel();
    _txSubscription = null;

    // Kill pacat process
    if (_pacatProcess != null) {
      try {
        _pacatProcess!.stdin.close();
        _pacatProcess!.kill();
        await _pacatProcess!.exitCode.timeout(const Duration(seconds: 2),
            onTimeout: () => -1);
      } catch (_) {}
      _pacatProcess = null;
    }

    // Kill parecord process
    if (_parecordProcess != null) {
      try {
        _parecordProcess!.kill();
        await _parecordProcess!.exitCode.timeout(const Duration(seconds: 2),
            onTimeout: () => -1);
      } catch (_) {}
      _parecordProcess = null;
    }

    // Unload modules in reverse order
    if (_virtualSourceModuleId >= 0) {
      await _unloadModule(_virtualSourceModuleId);
      _virtualSourceModuleId = -1;
    }
    if (_txSinkModuleId >= 0) {
      await _unloadModule(_txSinkModuleId);
      _txSinkModuleId = -1;
    }
    if (_rxSinkModuleId >= 0) {
      await _unloadModule(_rxSinkModuleId);
      _rxSinkModuleId = -1;
    }
  }

  /// Loads a PulseAudio module and returns its module ID, or -1 on failure.
  Future<int> _loadModule(String moduleName, String arguments) async {
    // Security: only allow known module names
    if (!_allowedModules.contains(moduleName)) return -1;

    try {
      final result = await Process.run(
          'pactl', ['load-module', moduleName, ...arguments.split(' ')]);
      if (result.exitCode != 0) return -1;
      final output = (result.stdout as String).trim();
      return int.tryParse(output) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Unloads a PulseAudio module by ID.
  Future<void> _unloadModule(int moduleId) async {
    if (moduleId < 0) return;
    try {
      await Process.run('pactl', ['unload-module', '$moduleId'])
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Cleans up stale HTCommander PulseAudio modules from previous runs.
  Future<void> _cleanupStaleModules() async {
    try {
      final result = await Process.run('pactl', ['list', 'short', 'modules']);
      if (result.exitCode != 0) return;

      final output = result.stdout as String;
      // Cap output read at 512KB
      final lines =
          (output.length > 512 * 1024 ? output.substring(0, 512 * 1024) : output)
              .split('\n');

      for (final line in lines) {
        if (line.contains('HTCommander')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.isNotEmpty) {
            final moduleId = int.tryParse(parts[0]);
            if (moduleId != null) {
              await _unloadModule(moduleId);
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Disposes all resources.
  void dispose() {
    destroy();
  }
}
