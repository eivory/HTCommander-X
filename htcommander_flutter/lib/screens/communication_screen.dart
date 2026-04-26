import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../dialogs/channel_editor_dialog.dart';
import '../dialogs/channel_picker_dialog.dart';
import '../dialogs/sstv_send_dialog.dart';
import '../radio/radio.dart' as ht;
import '../platform/audio_service.dart';
import '../platform/bluetooth_service.dart' show PlatformServices;
import '../radio/models/radio_dev_info.dart';
import '../radio/models/radio_ht_status.dart';
import '../radio/models/radio_settings.dart';
import '../radio/models/radio_channel_info.dart';
import '../radio/models/radio_position.dart';
import '../radio/sstv/sstv_encoder.dart';
import '../widgets/glass_card.dart';
import '../widgets/vfo_display.dart';
import '../widgets/signal_bars.dart';
import '../widgets/radio_status_card.dart';
import '../widgets/ptt_button.dart';
import '../widgets/status_strip.dart';

/// Communication Hub — the flagship screen.
/// Layout: Control panel (left, 320px) + content area (right).
class CommunicationScreen extends StatefulWidget {
  const CommunicationScreen({super.key});

  @override
  State<CommunicationScreen> createState() => _CommunicationScreenState();
}

class _CommunicationScreenState extends State<CommunicationScreen> {
  final TextEditingController _inputController = TextEditingController();
  String _selectedMode = 'Chat';
  bool _isMuted = false;

  // DataBroker wiring
  late final DataBrokerClient _broker;

  // Live state from DataBroker
  bool _isConnected = false;
  String? _deviceName;
  int _rssi = 0;
  bool _isTransmitting = false;
  int _batteryPercent = 0;
  bool _isGpsLocked = false;
  double _vfoAFreq = 0;
  double _vfoBFreq = 0;
  String _vfoAName = '';
  String _vfoBName = '';
  final List<_ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();

  // SSTV decode state
  bool _sstvDecoding = false;
  String _sstvModeName = '';
  double _sstvProgress = 0;

  // Recording state
  bool _isRecording = false;

  // Cached radio data for deriving VFO info
  RadioSettings? _settings;
  List<RadioChannelInfo?> _channels = [];
  RadioChannelInfo? _vfoAInfo;
  RadioChannelInfo? _vfoBInfo;

  // Audio I/O
  MicCapture? _micCapture;
  AudioOutput? _audioOutput;
  bool _audioEnabled = false;

  // Audio levels — operational controls (Volume/Squelch on the radio
  // hardware via GAIA, Output Volume / Mute / Mic Gain host-side).
  // Moved here from Settings so the user can tweak during a QSO without
  // leaving Comms. Persisted via DataBroker on device 0.
  double _hwVolume = 8;
  double _hwSquelch = 3;
  double _outputVolume = 75;
  bool _audioMuted = false;
  double _micGain = 100;

  @override
  void initState() {
    super.initState();
    _broker = DataBrokerClient();
    _loadCurrentState();

    _broker.subscribe(100, 'State', _onState);
    _broker.subscribe(100, 'Info', _onInfo);
    _broker.subscribe(100, 'FriendlyName', _onFriendlyName);
    _broker.subscribe(100, 'HtStatus', _onHtStatus);
    _broker.subscribe(100, 'Settings', _onSettings);
    _broker.subscribe(100, 'Channels', _onChannels);
    _broker.subscribe(100, 'VfoAInfo', _onVfoAInfo);
    _broker.subscribe(100, 'VfoBInfo', _onVfoBInfo);
    _broker.subscribe(100, 'BatteryAsPercentage', _onBattery);
    _broker.subscribe(100, 'Position', _onPosition);
    _broker.subscribe(100, 'AudioState', _onAudioState);
    // Radio-reported volume — only fires in response to a getVolume
    // GAIA query reply. Knob turns on the radio do NOT propagate (see
    // the KNOWN LIMITATION block in radio.dart's notification
    // registration). VOL slider is effectively one-way; this
    // subscription keeps it in sync with app-side or MCP-driven
    // SetVolumeLevel changes.
    _broker.subscribe(100, 'Volume', (_, __, data) {
      if (data is int && mounted) {
        setState(() => _hwVolume = data.toDouble());
      }
    });
    _broker.subscribe(1, 'SstvDecodingStarted', _onSstvDecodingStarted);
    _broker.subscribe(1, 'SstvDecodingProgress', _onSstvDecodingProgress);
    _broker.subscribe(1, 'SstvDecodingComplete', _onSstvDecodingComplete);
    _broker.subscribe(1, 'DecodedText', _onDecodedText);
  }

  void _loadCurrentState() {
    final state = _broker.getValue<String>(100, 'State', '');
    _isConnected = state.toLowerCase() == 'connected';

    final friendlyName = _broker.getValue<String>(100, 'FriendlyName', '');
    if (friendlyName.isNotEmpty) {
      _deviceName = friendlyName;
    } else {
      final info = _broker.getValueDynamic(100, 'Info');
      if (info is RadioDevInfo) {
        _deviceName = 'Radio ${info.productId}';
      }
    }

    final htStatus = _broker.getValueDynamic(100, 'HtStatus');
    if (htStatus is RadioHtStatus) {
      _rssi = htStatus.rssi;
      _isTransmitting = htStatus.isInTx;
    }

    final settings = _broker.getValueDynamic(100, 'Settings');
    if (settings is RadioSettings) {
      _settings = settings;
      _hwSquelch = settings.squelchLevel.toDouble();
    }

    final channels = _broker.getValueDynamic(100, 'Channels');
    if (channels is List) _channels = channels.cast<RadioChannelInfo?>();

    final vfoA = _broker.getValueDynamic(100, 'VfoAInfo');
    if (vfoA is RadioChannelInfo) _vfoAInfo = vfoA;
    final vfoB = _broker.getValueDynamic(100, 'VfoBInfo');
    if (vfoB is RadioChannelInfo) _vfoBInfo = vfoB;

    _batteryPercent = _broker.getValue<int>(100, 'BatteryAsPercentage', 0);

    final pos = _broker.getValueDynamic(100, 'Position');
    if (pos is RadioPosition) _isGpsLocked = pos.isGpsLocked;

    _hwVolume = _broker.getValue<int>(0, 'Volume', 8).toDouble();
    _hwSquelch = _broker.getValue<int>(0, 'Squelch', 3).toDouble();
    _outputVolume =
        _broker.getValue<int>(0, 'OutputVolume', 75).toDouble();
    _audioMuted = _broker.getValue<int>(0, 'Mute', 0) == 1;
    _micGain = _broker.getValue<int>(0, 'MicGain', 100).toDouble();

    _updateVfoFromChannels();
  }

  @override
  void dispose() {
    _stopMicCapture();
    _audioOutput?.stop();
    _broker.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── DataBroker callbacks ──────────────────────────────────────────

  void _onState(int deviceId, String name, Object? data) {
    if (!mounted) return;
    final connected = (data is String && data.toLowerCase() == 'connected');
    setState(() => _isConnected = connected);
    if (!connected) {
      _stopMicCapture();
      _audioOutput?.stop();
      _audioOutput = null;
      if (mounted) setState(() => _audioEnabled = false);
    }
  }

  void _onAudioState(int deviceId, String name, Object? data) {
    if (!mounted || data is! bool) return;
    setState(() => _audioEnabled = data);
    if (data && _audioOutput == null && PlatformServices.instance != null) {
      _audioOutput = PlatformServices.instance!.createAudioOutput();
      _audioOutput!.start(100);
    } else if (!data) {
      _audioOutput?.stop();
      _audioOutput = null;
    }
  }

  void _onInfo(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioDevInfo) return;
    if (_deviceName == null || _deviceName!.startsWith('Radio ')) {
      setState(() => _deviceName = 'Radio ${data.productId}');
    }
  }

  void _onFriendlyName(int deviceId, String name, Object? data) {
    if (!mounted || data is! String || data.isEmpty) return;
    setState(() => _deviceName = data);
  }

  void _onHtStatus(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioHtStatus) return;
    setState(() {
      _rssi = data.rssi;
      _isTransmitting = data.isInTx;
    });
  }

  void _onSettings(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioSettings) return;
    setState(() {
      _settings = data;
      // Squelch knob turns on the radio fire htSettingsChanged
      // notifications, so the slider follows the hardware here.
      _hwSquelch = data.squelchLevel.toDouble();
      _updateVfoFromChannels();
    });
  }

  void _onChannels(int deviceId, String name, Object? data) {
    if (!mounted || data is! List) return;
    setState(() {
      _channels = data.cast<RadioChannelInfo?>();
      _updateVfoFromChannels();
    });
  }

  void _onVfoAInfo(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioChannelInfo) return;
    setState(() {
      _vfoAInfo = data;
      _updateVfoFromChannels();
    });
  }

  void _onVfoBInfo(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioChannelInfo) return;
    setState(() {
      _vfoBInfo = data;
      _updateVfoFromChannels();
    });
  }

  void _onBattery(int deviceId, String name, Object? data) {
    if (!mounted || data is! int) return;
    setState(() => _batteryPercent = data);
  }

  void _onPosition(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioPosition) return;
    setState(() => _isGpsLocked = data.isGpsLocked);
  }

  void _updateVfoFromChannels() {
    final settings = _settings;
    if (settings == null) return;
    final chA = settings.channelA;
    final chB = settings.channelB;

    if (chA >= 0 && chA < _channels.length && _channels[chA] != null) {
      final ch = _channels[chA]!;
      _vfoAFreq = ch.rxFreq / 1000000.0;
      _vfoAName = ch.nameStr;
    } else if (_isVfoSentinel(chA) && _vfoAInfo != null) {
      // VFO mode — use the channel info the radio sent for this VFO.
      _vfoAFreq = _vfoAInfo!.rxFreq / 1000000.0;
      _vfoAName = 'VFO';
    } else {
      _vfoAFreq = 0;
      _vfoAName = '';
    }

    if (chB >= 0 && chB < _channels.length && _channels[chB] != null) {
      final ch = _channels[chB]!;
      _vfoBFreq = ch.rxFreq / 1000000.0;
      _vfoBName = ch.nameStr;
    } else if (_isVfoSentinel(chB) && _vfoBInfo != null) {
      _vfoBFreq = _vfoBInfo!.rxFreq / 1000000.0;
      _vfoBName = 'VFO';
    } else {
      _vfoBFreq = 0;
      _vfoBName = '';
    }
  }

  /// Benshi radios report a high sentinel (0xFB = VFO B, 0xFC = VFO A)
  /// in settings.channelA/B when that VFO is in ad-hoc frequency mode.
  bool _isVfoSentinel(int ch) => ch >= 0xF0;

  // ── SSTV decode callbacks ─────────────────────────────────────────

  void _onSstvDecodingStarted(int deviceId, String name, Object? data) {
    if (!mounted) return;
    final modeName = (data is Map ? data['modeName'] : null) as String? ?? '';
    setState(() {
      _sstvDecoding = true;
      _sstvModeName = modeName;
      _sstvProgress = 0;
    });
  }

  void _onSstvDecodingProgress(int deviceId, String name, Object? data) {
    if (!mounted) return;
    final progress = (data is Map ? data['progress'] : null);
    if (progress is double) {
      setState(() => _sstvProgress = progress.clamp(0.0, 1.0));
    } else if (progress is int) {
      setState(() => _sstvProgress = (progress / 100.0).clamp(0.0, 1.0));
    }
  }

  void _onSstvDecodingComplete(int deviceId, String name, Object? data) {
    if (!mounted) return;
    setState(() {
      _sstvDecoding = false;
      _sstvProgress = 1.0;
    });
  }

  void _onDecodedText(int deviceId, String name, Object? data) {
    if (!mounted || data is! String || data.isEmpty) return;
    setState(() {
      _messages.add(_ChatMessage(text: data, outgoing: false));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── SSTV send ───────────────────────────────────────────────────

  Future<void> _sendSstv() async {
    final result = await showDialog<SstvSendResult>(
      context: context,
      builder: (_) => const SstvSendDialog(),
    );
    if (result == null || !mounted) return;

    // Load image pixels.
    final file = File(result.imagePath);
    if (!await file.exists()) return;
    final imageBytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return;

    // Convert RGBA → ARGB Int32List expected by SstvEncoder.
    final rgbaBytes = byteData.buffer.asUint8List();
    final pixelCount = image.width * image.height;
    final pixels = Int32List(pixelCount);
    for (int i = 0; i < pixelCount; i++) {
      final r = rgbaBytes[i * 4];
      final g = rgbaBytes[i * 4 + 1];
      final b = rgbaBytes[i * 4 + 2];
      final a = rgbaBytes[i * 4 + 3];
      pixels[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }

    // Encode to float PCM.
    final encoder = SstvEncoder(32000);
    final floatSamples =
        encoder.encode(pixels, image.width, image.height, result.modeName);

    // Convert float (-1..1) → 16-bit signed → bytes, chunk and transmit.
    const chunkSamples = 3200; // 100ms at 32kHz
    for (int offset = 0; offset < floatSamples.length; offset += chunkSamples) {
      final end = (offset + chunkSamples).clamp(0, floatSamples.length);
      final chunk = Uint8List((end - offset) * 2);
      final bd = ByteData.sublistView(chunk);
      for (int i = 0; i < end - offset; i++) {
        int s = (floatSamples[offset + i] * 32767).round().clamp(-32768, 32767);
        bd.setInt16(i * 2, s, Endian.little);
      }
      DataBroker.dispatch(100, 'TransmitVoicePCM', chunk, store: false);
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (mounted) {
      setState(() {
        _messages.add(_ChatMessage(
            text: 'Sent SSTV image (${result.modeName})', outgoing: true));
      });
      _scrollToBottom();
    }
  }

  // ── Recording toggle ────────────────────────────────────────────

  void _toggleRecording() {
    setState(() => _isRecording = !_isRecording);
    _broker.dispatch(1, 'SetRecordingEnabled', _isRecording, store: false);
  }

  // ── VFO / Channel picker ───────────────────────────────────────────

  Future<void> _onVfoTap(bool isVfoA) async {
    if (_channels.isEmpty || _settings == null) return;
    final result = await showDialog<ChannelPickerResult>(
      context: context,
      builder: (_) => ChannelPickerDialog(
        channels: _channels,
        title: isVfoA ? 'Select VFO A Channel' : 'Select VFO B Channel',
      ),
    );
    if (result == null) return;
    final radio = DataBroker.getDataHandlerTyped<ht.Radio>('Radio_100');
    if (radio == null) return;
    if (result.pickIndex != null) {
      final s = _settings!;
      final picked = result.pickIndex!;
      radio.writeSettings(s.toByteArrayWithChannels(
        isVfoA ? picked : s.channelA,
        isVfoA ? s.channelB : picked,
        s.doubleChannel, s.scan, s.squelchLevel,
      ));
    } else if (result.editIndex != null) {
      await _editChannelSlot(result.editIndex!);
    }
  }

  /// Open the channel editor for a channel slot and, on save, write it
  /// back to the radio.
  Future<void> _editChannelSlot(int channelIndex) async {
    if (channelIndex < 0 || channelIndex >= _channels.length) return;
    final current = _channels[channelIndex];
    if (current == null) return;
    final edited = await showDialog<RadioChannelInfo>(
      context: context,
      builder: (_) => ChannelEditorDialog(channel: current),
    );
    if (edited == null) return;
    edited.channelId = current.channelId;
    final radio = DataBroker.getDataHandlerTyped<ht.Radio>('Radio_100');
    radio?.setChannel(edited);
  }

  /// Make [isVfoA] the active TX/RX VFO. Writes settings with
  /// doubleChannel = 1 (VFO A) or 2 (VFO B).
  void _onVfoActivate(bool isVfoA) {
    if (_settings == null) return;
    final radio = DataBroker.getDataHandlerTyped<ht.Radio>('Radio_100');
    if (radio == null) return;
    final s = _settings!;
    radio.writeSettings(s.toByteArrayWithChannels(
      s.channelA, s.channelB,
      isVfoA ? 1 : 2,
      s.scan, s.squelchLevel,
    ));
  }

  /// Long-press a VFO display → edit that slot's channel properties
  /// (name, freq, modulation, bandwidth, power, flags). If the VFO is
  /// in ad-hoc frequency mode the sentinel channel id is edited
  /// directly; in channel mode the current channel slot is edited.
  Future<void> _onVfoEdit(bool isVfoA) async {
    if (_settings == null) return;
    final chId = isVfoA ? _settings!.channelA : _settings!.channelB;
    RadioChannelInfo? current;
    if (chId >= 0 && chId < _channels.length && _channels[chId] != null) {
      current = _channels[chId];
    } else if (chId == 0xFC) {
      current = _vfoAInfo;
    } else if (chId == 0xFB) {
      current = _vfoBInfo;
    }
    if (current == null) return;

    final edited = await showDialog<RadioChannelInfo>(
      context: context,
      builder: (_) => ChannelEditorDialog(channel: current),
    );
    if (edited == null) return;
    // Preserve the channelId — the editor dialog copies from the source
    // but we want to make sure we overwrite the same slot.
    edited.channelId = current.channelId;

    final radio = DataBroker.getDataHandlerTyped<ht.Radio>('Radio_100');
    radio?.setChannel(edited);
  }

  // ── PTT ────────────────────────────────────────────────────────────

  void _onPttStart() {
    if (!_isConnected) return;
    if (!_audioEnabled) {
      DataBroker.dispatch(100, 'SetAudio', true, store: false);
    }
    if (PlatformServices.instance != null) {
      _micCapture ??= PlatformServices.instance!.createMicCapture();
      _micCapture!.start(100);
    }
  }

  void _onPttStop() {
    _stopMicCapture();
    DataBroker.dispatch(100, 'CancelVoiceTransmit', null, store: false);
  }

  void _stopMicCapture() {
    _micCapture?.stop();
    _micCapture = null;
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Control panel
              SizedBox(
                width: 320,
                child: _buildControlPanel(colors),
              ),
              // Right: Content area
              Expanded(
                child: Column(
                  children: [
                    // Quick controls bar
                    _buildQuickControls(colors),
                    // Two-column content
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildPacketNodeCard(colors)),
                            const SizedBox(width: 14),
                            Expanded(child: _buildOperationLog(colors)),
                          ],
                        ),
                      ),
                    ),
                    // Input bar
                    _buildInputBar(colors),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Status strip at very bottom
        StatusStrip(isConnected: _isConnected),
      ],
    );
  }

  Widget _buildControlPanel(ColorScheme colors) {
    return Container(
      color: colors.surfaceContainerLow,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            // Device status
            RadioStatusCard(
              deviceName: _deviceName,
              isConnected: _isConnected,
              rssi: _rssi,
              isTransmitting: _isTransmitting,
              batteryPercent: _batteryPercent,
              isGpsLocked: _isGpsLocked,
            ),
            const SizedBox(height: 14),

            // Frequency Matrix title
            Row(
              children: [
                Text(
                  'FREQUENCY MATRIX',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // VFO A — "active" means the radio is TX/RX'ing on it.
            // settings.doubleChannel: 1 = A, 2 = B (0 = both).
            VfoDisplay(
              label: 'VFO A',
              frequency: _vfoAFreq,
              channelName: _vfoAName,
              modulation: 'FM',
              isActive: _settings?.doubleChannel != 2,
              isPrimary: true,
              onTap: () => _onVfoTap(true),
              onLongPress: () => _onVfoEdit(true),
              onActivate: () => _onVfoActivate(true),
            ),
            const SizedBox(height: 8),

            // VFO B
            VfoDisplay(
              label: 'VFO B',
              frequency: _vfoBFreq,
              channelName: _vfoBName,
              isActive: _settings?.doubleChannel == 2,
              isPrimary: false,
              onTap: () => _onVfoTap(false),
              onLongPress: () => _onVfoEdit(false),
              onActivate: () => _onVfoActivate(false),
            ),
            const SizedBox(height: 20),

            // PTT Button with integrated label
            Center(
              child: PttButton(
                isEnabled: _isConnected,
                isTransmitting: _isTransmitting,
                size: 80,
                onPttStart: _onPttStart,
                onPttStop: _onPttStop,
              ),
            ),
            const SizedBox(height: 16),

            // RSSI / TX bars
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  _MiniStatus(
                    label: 'RSSI',
                    child: SignalBars(level: _rssi, height: 14),
                  ),
                  const SizedBox(width: 16),
                  _MiniStatus(
                    label: 'TX',
                    child: SignalBars(
                      level: _isTransmitting ? 12 : 0,
                      isTransmitting: true,
                      height: 14,
                    ),
                  ),
                  const Spacer(),
                  if (_rssi > 0)
                    Text(
                      '${-113 + _rssi} dBm',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildAudioLevelsCard(colors),
          ],
        ),
      ),
    );
  }

  /// Hardware (radio-side, GAIA) + Host (Mac/PC-side) audio levels.
  /// Lives in the Comms control panel so the operator can adjust during
  /// a QSO. Values persist on DataBroker device 0; the ``Set*`` events
  /// dispatched to the radio device (100) actually push to hardware /
  /// AVAudioEngine.
  Widget _buildAudioLevelsCard(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AUDIO LEVELS',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          _audioSubheader('RADIO (HARDWARE)', colors),
          const SizedBox(height: 4),
          _audioSliderRow(
            colors,
            label: 'VOL',
            value: _hwVolume,
            min: 0, max: 15, divisions: 15,
            valueLabel: _hwVolume.round().toString(),
            onChanged: (v) {
              setState(() => _hwVolume = v);
              // Pushes the GAIA SET_VOLUME command to the radio. The
              // radio's reply re-publishes 'Volume' on device 100.
              _broker.dispatch(100, 'SetVolumeLevel', v.round(),
                  store: false);
              _broker.dispatch(0, 'Volume', v.round(), store: true);
            },
          ),
          _audioSliderRow(
            colors,
            label: 'SQL',
            value: _hwSquelch,
            min: 0, max: 9, divisions: 9,
            valueLabel: _hwSquelch.round().toString(),
            onChanged: (v) {
              setState(() => _hwSquelch = v);
              _broker.dispatch(100, 'SetSquelchLevel', v.round(),
                  store: false);
              _broker.dispatch(0, 'Squelch', v.round(), store: true);
            },
          ),
          const Divider(height: 14),
          _audioSubheader('HOST (MAC)', colors),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _audioSliderRow(
                  colors,
                  label: 'OUT',
                  value: _outputVolume,
                  min: 0, max: 100, divisions: 20,
                  valueLabel: '${_outputVolume.round()}%',
                  onChanged: (v) {
                    setState(() => _outputVolume = v);
                    // RadioAudioManager._onSetOutputVolume scales 0..1
                    // and applies to the host PCM mixer (Linux/Windows).
                    // macOS native RFCOMM plugin doesn't tap this yet —
                    // see TODO below.
                    _broker.dispatch(100, 'SetOutputVolume', v.round(),
                        store: false);
                    _broker.dispatch(0, 'OutputVolume', v.round(),
                        store: true);
                  },
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Mute audio output',
                child: Transform.scale(
                  scale: 0.7,
                  child: Switch(
                    value: _audioMuted,
                    onChanged: (v) {
                      setState(() => _audioMuted = v);
                      // Both: device 0 'Mute' int for macos_audio.dart
                      // gating subscription, plus device 100 'SetMute'
                      // bool for RadioAudioManager (Linux/Windows).
                      _broker.dispatch(0, 'Mute', v ? 1 : 0, store: true);
                      _broker.dispatch(100, 'SetMute', v, store: false);
                    },
                  ),
                ),
              ),
            ],
          ),
          _audioSliderRow(
            colors,
            label: 'MIC',
            value: _micGain,
            min: 0, max: 200, divisions: 20,
            valueLabel: '${_micGain.round()}%',
            onChanged: (v) {
              setState(() => _micGain = v);
              // No SetMicGain handler exists yet — value is stored but
              // not applied to the live mic stream. Wiring it up
              // requires a gain stage in MacOsMicCapture (and the
              // Linux/Windows mic capture paths).
              _broker.dispatch(0, 'MicGain', v.round(), store: true);
            },
          ),
        ],
      ),
    );
  }

  Widget _audioSubheader(String text, ColorScheme colors) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 8,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: colors.primary,
      ),
    );
  }

  Widget _audioSliderRow(
    ColorScheme colors, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required String valueLabel,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: colors.primary,
              inactiveTrackColor: colors.surfaceContainerHigh,
              thumbColor: colors.primary,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            valueLabel,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickControls(ColorScheme colors) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: colors.surfaceContainer,
      child: Row(
        children: [
          Flexible(
            child: Text(
              'COMMUNICATION HUB',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
                letterSpacing: 1,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              _isConnected ? 'Connected' : 'Idle',
              style: TextStyle(
                fontSize: 10,
                color: colors.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          _QuickButton(
            label: 'Send SSTV',
            onPressed: _isConnected ? _sendSstv : null,
          ),
          const SizedBox(width: 6),
          _QuickButton(
            label: _isMuted ? 'Unmute' : 'Mute',
            isActive: _isMuted,
            onPressed: () => setState(() => _isMuted = !_isMuted),
          ),
          const SizedBox(width: 6),
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: DropdownButton<String>(
              value: _selectedMode,
              underline: const SizedBox(),
              isDense: true,
              dropdownColor: colors.surfaceContainerHigh,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              items: ['Chat', 'Speak', 'Morse', 'DTMF']
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedMode = v!),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPacketNodeCard(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LOCAL PACKET NODE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          // SSTV / Data Link panel
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
            ),
            child: _sstvDecoding || _sstvProgress >= 1.0
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _sstvDecoding ? Icons.sync : Icons.check_circle,
                          size: 28,
                          color: _sstvDecoding
                              ? colors.primary
                              : colors.tertiary,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _sstvDecoding
                              ? 'DECODING $_sstvModeName'
                              : 'SSTV COMPLETE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: colors.onSurface,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: _sstvProgress,
                          backgroundColor:
                              colors.outlineVariant.withAlpha(38),
                          color: colors.primary,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${(_sstvProgress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.satellite_alt,
                            size: 32, color: colors.outline),
                        const SizedBox(height: 8),
                        Text(
                          'SSTV / DATA LINK',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Waiting for incoming data...',
                          style: TextStyle(
                              fontSize: 11, color: colors.outline),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          // Status / Protocol row
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STATUS',
                      style: TextStyle(
                        fontSize: 9,
                        color: colors.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Standby',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PROTOCOL',
                      style: TextStyle(
                        fontSize: 9,
                        color: colors.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'AX.25',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOperationLog(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'OPERATION',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 28, color: colors.outline),
                        const SizedBox(height: 8),
                        Text(
                          'No messages yet',
                          style:
                              TextStyle(fontSize: 11, color: colors.outline),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      return Align(
                        alignment: msg.outgoing
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: GestureDetector(
                          onLongPress: () {
                            Clipboard.setData(
                                ClipboardData(text: msg.text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Copied to clipboard'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                          child: Container(
                            constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width *
                                        0.65),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: msg.outgoing
                                  ? colors.primary.withAlpha(30)
                                  : colors.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: msg.outgoing
                                    ? colors.primary.withAlpha(50)
                                    : colors.outlineVariant
                                        .withAlpha(38),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  msg.text,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurface),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _formatTime(msg.time),
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: colors.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: colors.surfaceContainerLow,
      child: Row(
        children: [
          Text(
            '>',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: colors.primary,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _inputController,
              style: TextStyle(fontSize: 12, color: colors.onSurface),
              decoration: InputDecoration(
                hintText: 'Type message...',
                hintStyle: TextStyle(fontSize: 12, color: colors.outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant.withAlpha(38)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant.withAlpha(38)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.primary),
                ),
                filled: true,
                fillColor: colors.surfaceContainerLow,
              ),
              onSubmitted: _isConnected ? (_) => _sendMessage() : null,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _isConnected ? _sendMessage : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            child: const Text('Transmit'),
          ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: _isConnected ? _toggleRecording : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              backgroundColor: _isRecording
                  ? Theme.of(context).colorScheme.errorContainer
                  : null,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(_isRecording ? 'Stop' : 'Record'),
          ),
        ],
      ),
    );
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _broker.dispatch(1, 'Chat', text, store: false);
    setState(() {
      _messages.add(_ChatMessage(text: text, outgoing: true));
      _inputController.clear();
    });
    _scrollToBottom();
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}

/// A chat message with direction and timestamp.
class _ChatMessage {
  final String text;
  final bool outgoing;
  final DateTime time;
  _ChatMessage({required this.text, required this.outgoing})
      : time = DateTime.now();
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.label, this.onPressed, this.isActive = false});
  final String label;
  final VoidCallback? onPressed;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        backgroundColor: isActive ? colors.primaryContainer : null,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}

class _MiniStatus extends StatelessWidget {
  const _MiniStatus({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: colors.onSurfaceVariant,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
