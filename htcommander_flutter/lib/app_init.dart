import 'dart:io';

import 'core/data_broker.dart';
import 'handlers/airplane_handler.dart';
import 'handlers/frame_deduplicator.dart';
import 'handlers/gps_serial_handler.dart';
import 'handlers/packet_store.dart';
import 'handlers/aprs_handler.dart';
import 'handlers/log_store.dart';
import 'handlers/log_file_handler.dart';
import 'handlers/mail_store.dart';
import 'handlers/audio_clip_handler.dart';
import 'handlers/torrent_handler.dart';
import 'handlers/bbs_handler.dart';
import 'handlers/voice_handler.dart';
import 'radio/software_modem.dart';
import 'handlers/winlink_client.dart';
import 'handlers/virtual_audio_bridge.dart';
import 'handlers/server_stubs.dart';
import 'platform/linux/linux_speech_service.dart';
import 'platform/linux/linux_whisper_engine.dart';
import 'platform/windows/windows_speech_service.dart';
import 'platform/windows/windows_whisper_engine.dart';
import 'servers/agwpe_server.dart';
import 'servers/cat_serial_server.dart';
import 'servers/mcp_server.dart';
import 'servers/rigctld_server.dart';
import 'servers/web_server.dart';

/// Registers all data handlers with the DataBroker.
/// Must be called after DataBroker.initialize().
/// Mirrors C# MainWindow.InitializeDataHandlers().
void initializeDataHandlers() {
  DataBroker.addDataHandler('FrameDeduplicator', FrameDeduplicator());
  DataBroker.addDataHandler('SoftwareModem', SoftwareModem());
  DataBroker.addDataHandler('PacketStore', PacketStore());
  DataBroker.addDataHandler('AprsHandler', AprsHandler());
  DataBroker.addDataHandler('LogStore', LogStore());
  DataBroker.addDataHandler('LogFileHandler', LogFileHandler());
  DataBroker.addDataHandler('MailStore', MailStore());
  DataBroker.addDataHandler('AudioClipHandler', AudioClipHandler());
  DataBroker.addDataHandler('TorrentHandler', TorrentHandler());
  DataBroker.addDataHandler('BbsHandler', BbsHandler());

  // Create VoiceHandler with platform-specific speech and STT services
  final voiceHandler = VoiceHandler();
  if (Platform.isLinux) {
    voiceHandler.speechService = LinuxSpeechService();
    VoiceHandler.whisperEngineFactory =
        (modelPath, language) => LinuxWhisperEngine(modelPath, language);
  } else if (Platform.isWindows) {
    voiceHandler.speechService = WindowsSpeechService();
    VoiceHandler.whisperEngineFactory =
        (modelPath, language) => WindowsWhisperEngine(modelPath, language);
  }
  DataBroker.addDataHandler('VoiceHandler', voiceHandler);
  DataBroker.addDataHandler('WinlinkClient', WinlinkClient());
  DataBroker.addDataHandler('AirplaneHandler', AirplaneHandler());
  DataBroker.addDataHandler('GpsSerialHandler', GpsSerialHandler());

  // Desktop servers (Linux/Windows) — use real implementations
  // Mobile platforms get stubs since they can't bind TCP servers
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    DataBroker.addDataHandler('McpServer', McpServer());
    DataBroker.addDataHandler('WebServer', WebServer());
    DataBroker.addDataHandler('RigctldServer', RigctldServer());
    DataBroker.addDataHandler('AgwpeServer', AgwpeServer());
    DataBroker.addDataHandler('CatSerialServer', CatSerialServer());
  } else {
    DataBroker.addDataHandler('McpServer', McpServerStub());
    DataBroker.addDataHandler('WebServer', WebServerStub());
    DataBroker.addDataHandler('RigctldServer', RigctldServerStub());
    DataBroker.addDataHandler('AgwpeServer', AgwpeServerStub());
    DataBroker.addDataHandler('CatSerialServer', CatSerialServerStub());
  }

  // Virtual audio bridge — desktop only (requires PulseAudio)
  if (Platform.isLinux) {
    DataBroker.addDataHandler('VirtualAudioBridge', VirtualAudioBridge());
  }
}

/// Initializes handlers that require file persistence paths.
/// Must be called after initializeDataHandlers() and after the app data
/// directory is resolved.
void initializeHandlerPaths(String appDataPath) {
  final dir = Directory(appDataPath);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  // Call initialize() on all handlers that need disk persistence
  DataBroker.getDataHandlerTyped<PacketStore>('PacketStore')
      ?.initialize(appDataPath);
  DataBroker.getDataHandlerTyped<VoiceHandler>('VoiceHandler')
      ?.initialize(appDataPath);
  DataBroker.getDataHandlerTyped<BbsHandler>('BbsHandler')
      ?.initialize(appDataPath);
  DataBroker.getDataHandlerTyped<TorrentHandler>('TorrentHandler')
      ?.initialize(appDataPath);
  DataBroker.getDataHandlerTyped<WinlinkClient>('WinlinkClient')
      ?.initialize(appDataPath);
  DataBroker.getDataHandlerTyped<LogFileHandler>('LogFileHandler')
      ?.initialize(appDataPath);
}
