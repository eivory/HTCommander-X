import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../dialogs/aprs_route_dialog.dart';
import '../platform/macos/macos_native_audio.dart';
import '../widgets/glass_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedCategory = 'General';
  late final DataBrokerClient _broker;

  final List<_SettingsCategory> _categories = [
    _SettingsCategory('General', Icons.settings),
    _SettingsCategory('APRS', Icons.cell_tower),
    _SettingsCategory('Voice', Icons.mic),
    _SettingsCategory('Winlink', Icons.email),
    _SettingsCategory('Servers', Icons.dns),
    _SettingsCategory('Data Sources', Icons.storage),
    _SettingsCategory('Audio', Icons.volume_up),
    _SettingsCategory('Modem', Icons.router),
  ];

  // General
  String _theme = 'Dark';
  String _callSign = '';
  int _stationId = 0;
  bool _allowTransmit = false;
  bool _checkForUpdates = true;

  // APRS
  List<Map<String, String>> _aprsRoutes = [];
  String? _portConflictWarning;

  // Voice
  String _language = 'English';
  String _ttsVoice = 'Default';
  bool _whisperStt = false;

  // Winlink
  String _winlinkPassword = '';
  bool _useStationId = false;

  // Servers
  bool _webServerEnabled = false;
  int _webServerPort = 8080;
  bool _agwpeEnabled = false;
  int _agwpePort = 8000;
  bool _rigctldEnabled = false;
  int _rigctldPort = 4532;
  bool _mcpServerEnabled = false;
  int _mcpServerPort = 5678;
  bool _serverBindAll = false;
  bool _tlsEnabled = false;

  // Data Sources
  String _airplaneUrl = '';
  String _gpsSerialPort = '';
  int _gpsBaud = 9600;
  String _repeaterBookCountry = 'United States';
  String _repeaterBookState = '';

  // Audio
  double _volume = 8;
  double _squelch = 3;
  double _outputVolume = 75;
  bool _mute = false;
  double _micGain = 100;

  // Modem
  String _modemMode = 'None';

  // Additional toggles
  bool _catServerEnabled = false;
  bool _virtualAudioEnabled = false;
  bool _mcpDebugToolsEnabled = false;
  bool _showAllChannels = false;
  bool _showAirplanesOnMap = false;

  // TextEditingControllers for persistent text fields
  late final TextEditingController _callSignController;
  late final TextEditingController _winlinkPasswordController;
  late final TextEditingController _airplaneUrlController;
  late final TextEditingController _gpsSerialPortController;
  late final TextEditingController _repeaterBookCountryController;
  late final TextEditingController _repeaterBookStateController;
  late final TextEditingController _webServerPortController;
  late final TextEditingController _agwpePortController;
  late final TextEditingController _rigctldPortController;
  late final TextEditingController _mcpServerPortController;

  @override
  void initState() {
    super.initState();
    _broker = DataBrokerClient();

    // Load all settings from DataBroker device 0
    _theme = DataBroker.getValue<String>(0, 'Theme', 'Dark');
    _callSign = DataBroker.getValue<String>(0, 'CallSign', '');
    _stationId = DataBroker.getValue<int>(0, 'StationId', 0);
    _loadAprsRoutes();
    _allowTransmit = DataBroker.getValue<int>(0, 'AllowTransmit', 0) == 1;
    _checkForUpdates =
        DataBroker.getValue<int>(0, 'CheckForUpdates', 1) == 1;

    _winlinkPassword =
        DataBroker.getValue<String>(0, 'WinlinkPassword', '');

    _webServerEnabled =
        DataBroker.getValue<int>(0, 'WebServerEnabled', 0) == 1;
    _webServerPort = DataBroker.getValue<int>(0, 'WebServerPort', 8080);
    _agwpeEnabled =
        DataBroker.getValue<int>(0, 'AgwpeServerEnabled', 0) == 1;
    _agwpePort = DataBroker.getValue<int>(0, 'AgwpeServerPort', 8000);
    _rigctldEnabled =
        DataBroker.getValue<int>(0, 'RigctldServerEnabled', 0) == 1;
    _rigctldPort = DataBroker.getValue<int>(0, 'RigctldServerPort', 4532);
    _mcpServerEnabled =
        DataBroker.getValue<int>(0, 'McpServerEnabled', 0) == 1;
    _mcpServerPort = DataBroker.getValue<int>(0, 'McpServerPort', 5678);
    _serverBindAll = DataBroker.getValue<int>(0, 'ServerBindAll', 0) == 1;
    _tlsEnabled = DataBroker.getValue<int>(0, 'TlsEnabled', 0) == 1;

    _airplaneUrl = DataBroker.getValue<String>(0, 'AirplaneUrl', '');
    _gpsSerialPort =
        DataBroker.getValue<String>(0, 'GpsSerialPort', '');
    _gpsBaud = DataBroker.getValue<int>(0, 'GpsBaud', 9600);
    _repeaterBookCountry =
        DataBroker.getValue<String>(0, 'RepeaterBookCountry', 'United States');
    _repeaterBookState =
        DataBroker.getValue<String>(0, 'RepeaterBookState', '');

    _volume = DataBroker.getValue<int>(0, 'Volume', 8).toDouble();
    _squelch = DataBroker.getValue<int>(0, 'Squelch', 3).toDouble();
    _outputVolume =
        DataBroker.getValue<int>(0, 'OutputVolume', 75).toDouble();
    _mute = DataBroker.getValue<int>(0, 'Mute', 0) == 1;
    _micGain = DataBroker.getValue<int>(0, 'MicGain', 100).toDouble();

    _modemMode = DataBroker.getValue<String>(0, 'ModemMode', 'None');

    _catServerEnabled =
        DataBroker.getValue<int>(0, 'CatServerEnabled', 0) == 1;
    _virtualAudioEnabled =
        DataBroker.getValue<int>(0, 'VirtualAudioEnabled', 0) == 1;
    _mcpDebugToolsEnabled =
        DataBroker.getValue<int>(0, 'McpDebugToolsEnabled', 0) == 1;
    _showAllChannels =
        DataBroker.getValue<int>(0, 'ShowAllChannels', 0) == 1;
    _showAirplanesOnMap =
        DataBroker.getValue<int>(0, 'ShowAirplanesOnMap', 0) == 1;

    _language = DataBroker.getValue<String>(0, 'Language', 'English');
    _ttsVoice = DataBroker.getValue<String>(0, 'TtsVoice', 'Default');
    _whisperStt = DataBroker.getValue<int>(0, 'WhisperStt', 0) == 1;
    _useStationId =
        DataBroker.getValue<int>(0, 'UseStationIdAsWinlink', 0) == 1;

    // Initialize text editing controllers with loaded values
    _callSignController = TextEditingController(text: _callSign);
    _winlinkPasswordController = TextEditingController(text: _winlinkPassword);
    _airplaneUrlController = TextEditingController(text: _airplaneUrl);
    _gpsSerialPortController = TextEditingController(text: _gpsSerialPort);
    _repeaterBookCountryController =
        TextEditingController(text: _repeaterBookCountry);
    _repeaterBookStateController =
        TextEditingController(text: _repeaterBookState);
    _webServerPortController =
        TextEditingController(text: _webServerPort.toString());
    _agwpePortController =
        TextEditingController(text: _agwpePort.toString());
    _rigctldPortController =
        TextEditingController(text: _rigctldPort.toString());
    _mcpServerPortController =
        TextEditingController(text: _mcpServerPort.toString());
  }

  @override
  void dispose() {
    _broker.dispose();
    _callSignController.dispose();
    _winlinkPasswordController.dispose();
    _airplaneUrlController.dispose();
    _gpsSerialPortController.dispose();
    _repeaterBookCountryController.dispose();
    _repeaterBookStateController.dispose();
    _webServerPortController.dispose();
    _agwpePortController.dispose();
    _rigctldPortController.dispose();
    _mcpServerPortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Tab bar replacing old header + sidebar
        Container(
          height: 42,
          color: colors.surfaceContainer,
          child: Row(
            children: [
              const SizedBox(width: 14),
              Text(
                'SYSTEM PARAMETERS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _categories.map((cat) {
                      final isSelected = cat.name == _selectedCategory;
                      return Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TextButton(
                          onPressed: () =>
                              setState(() => _selectedCategory = cat.name),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                            foregroundColor: isSelected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                            backgroundColor: isSelected
                                ? colors.primaryContainer.withAlpha(40)
                                : null,
                            textStyle: TextStyle(
                              fontSize: 10,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              letterSpacing: 0.5,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(cat.icon, size: 14),
                              const SizedBox(width: 6),
                              Text(cat.name),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(width: 14),
            ],
          ),
        ),
        // Content panel — full width (no sidebar)
        Expanded(
          child: _buildContentPanel(colors),
        ),
      ],
    );
  }

  Widget _buildContentPanel(ColorScheme colors) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: _buildCategoryContent(colors),
    );
  }

  Widget _buildCategoryContent(ColorScheme colors) {
    switch (_selectedCategory) {
      case 'General':
        return _buildGeneral(colors);
      case 'APRS':
        return _buildAprs(colors);
      case 'Voice':
        return _buildVoice(colors);
      case 'Winlink':
        return _buildWinlink(colors);
      case 'Servers':
        return _buildServers(colors);
      case 'Data Sources':
        return _buildDataSources(colors);
      case 'Audio':
        return _buildAudio(colors);
      case 'Modem':
        return _buildModem(colors);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── General ──────────────────────────────────────────────────────

  Widget _buildGeneral(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('APPEARANCE', colors),
              const SizedBox(height: 12),
              _dropdownRow(
                'Theme',
                _theme,
                ['Auto', 'Light', 'Dark'],
                (v) {
                  setState(() => _theme = v);
                  _broker.dispatch(0, 'Theme', v);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('STATION IDENTITY', colors),
              const SizedBox(height: 12),
              _textFieldRowWithController(
                'Call Sign',
                _callSignController,
                6,
                (v) {
                  _callSign = v;
                  _broker.dispatch(0, 'CallSign', v);
                },
                colors,
              ),
              const SizedBox(height: 10),
              _dropdownRow(
                'Station ID (SSID)',
                _stationId.toString(),
                List.generate(16, (i) => i.toString()),
                (v) {
                  setState(() => _stationId = int.tryParse(v) ?? 0);
                  _broker.dispatch(0, 'StationId', _stationId);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('TRANSMIT', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Allow Transmit',
                _allowTransmit,
                (v) {
                  setState(() => _allowTransmit = v);
                  _broker.dispatch(0, 'AllowTransmit', v ? 1 : 0);
                },
                colors,
              ),
              if (_allowTransmit)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 28),
                  child: Text(
                    'WARNING: Ensure you have a valid amateur radio license before transmitting.',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.amber[700],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('UPDATES', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Check for Updates on Startup',
                _checkForUpdates,
                (v) {
                  setState(() => _checkForUpdates = v);
                  _broker.dispatch(0, 'CheckForUpdates', v ? 1 : 0);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('CHANNELS', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Show All Channels',
                _showAllChannels,
                (v) {
                  setState(() => _showAllChannels = v);
                  _broker.dispatch(0, 'ShowAllChannels', v ? 1 : 0);
                },
                colors,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 28),
                child: Text(
                  'Show all channel slots including empty ones',
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('MAINTENANCE', colors),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.restore, size: 14),
                label: const Text('RESET ALL SETTINGS TO DEFAULTS'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.error,
                  side: BorderSide(color: colors.error.withAlpha(120)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  textStyle: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── APRS ─────────────────────────────────────────────────────────

  Widget _buildAprs(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: _sectionLabel('ROUTES', colors)),
                  IconButton(
                    icon: const Icon(Icons.add, size: 16),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => _addAprsRoute(),
                    tooltip: 'Add Route',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._aprsRoutes.asMap().entries.map((entry) {
                final route = entry.value;
                final name = route['name'] ?? '';
                final path = route['path'] ?? '';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            name.isNotEmpty ? '$name: $path' : path,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 28, minHeight: 28),
                        onPressed: () => _editAprsRoute(entry.key),
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline,
                            size: 14, color: colors.error),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 28, minHeight: 28),
                        onPressed: () => _deleteAprsRoute(entry.key),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Voice ────────────────────────────────────────────────────────

  Widget _buildVoice(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('TEXT-TO-SPEECH', colors),
              const SizedBox(height: 12),
              _dropdownRow(
                'Language',
                _language,
                ['English', 'Spanish', 'French', 'German', 'Japanese'],
                (v) {
                  setState(() => _language = v);
                  _broker.dispatch(0, 'Language', v);
                },
                colors,
              ),
              const SizedBox(height: 10),
              _dropdownRow(
                'TTS Voice',
                _ttsVoice,
                ['Default', 'Male', 'Female'],
                (v) {
                  setState(() => _ttsVoice = v);
                  _broker.dispatch(0, 'TtsVoice', v);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('SPEECH-TO-TEXT', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Enable Whisper STT',
                _whisperStt,
                (v) {
                  setState(() => _whisperStt = v);
                  _broker.dispatch(0, 'WhisperStt', v ? 1 : 0);
                },
                colors,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Winlink ──────────────────────────────────────────────────────

  Widget _buildWinlink(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('WINLINK AUTHENTICATION', colors),
              const SizedBox(height: 12),
              _passwordFieldRowWithController(
                'Password',
                _winlinkPasswordController,
                (v) {
                  _winlinkPassword = v;
                  _broker.dispatch(0, 'WinlinkPassword', v);
                },
                colors,
              ),
              const SizedBox(height: 10),
              _checkboxRow(
                'Use Station ID as Winlink Account',
                _useStationId,
                (v) {
                  setState(() => _useStationId = v);
                  _broker.dispatch(0, 'UseStationIdAsWinlink', v ? 1 : 0);
                },
                colors,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Servers ──────────────────────────────────────────────────────

  Widget _buildServers(ColorScheme colors) {
    _checkPortConflicts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_portConflictWarning != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 16, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _portConflictWarning!,
                      style: TextStyle(
                          fontSize: 10, color: colors.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('NETWORK OPTIONS', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Bind to All Interfaces (LAN Access)',
                _serverBindAll,
                (v) {
                  setState(() => _serverBindAll = v);
                  _broker.dispatch(0, 'ServerBindAll', v ? 1 : 0);
                },
                colors,
              ),
              const SizedBox(height: 6),
              _checkboxRow(
                'Enable TLS (HTTPS)',
                _tlsEnabled,
                (v) {
                  setState(() => _tlsEnabled = v);
                  _broker.dispatch(0, 'TlsEnabled', v ? 1 : 0);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'WEB SERVER',
          _webServerEnabled,
          _webServerPortController,
          (v) {
            setState(() => _webServerEnabled = v);
            _broker.dispatch(0, 'WebServerEnabled', v ? 1 : 0);
          },
          (v) {
            setState(() => _webServerPort = v);
            _broker.dispatch(0, 'WebServerPort', v);
          },
          colors,
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'AGWPE SERVER',
          _agwpeEnabled,
          _agwpePortController,
          (v) {
            setState(() => _agwpeEnabled = v);
            _broker.dispatch(0, 'AgwpeServerEnabled', v ? 1 : 0);
          },
          (v) {
            setState(() => _agwpePort = v);
            _broker.dispatch(0, 'AgwpeServerPort', v);
          },
          colors,
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'RIGCTLD SERVER',
          _rigctldEnabled,
          _rigctldPortController,
          (v) {
            setState(() => _rigctldEnabled = v);
            _broker.dispatch(0, 'RigctldServerEnabled', v ? 1 : 0);
          },
          (v) {
            setState(() => _rigctldPort = v);
            _broker.dispatch(0, 'RigctldServerPort', v);
          },
          colors,
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'MCP SERVER',
          _mcpServerEnabled,
          _mcpServerPortController,
          (v) {
            setState(() => _mcpServerEnabled = v);
            _broker.dispatch(0, 'McpServerEnabled', v ? 1 : 0);
          },
          (v) {
            setState(() => _mcpServerPort = v);
            _broker.dispatch(0, 'McpServerPort', v);
          },
          colors,
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('MCP DEBUG TOOLS', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Enabled',
                _mcpDebugToolsEnabled,
                (v) {
                  setState(() => _mcpDebugToolsEnabled = v);
                  _broker.dispatch(0, 'McpDebugToolsEnabled', v ? 1 : 0);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('CAT SERIAL (TS-2000)', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Enabled',
                _catServerEnabled,
                (v) {
                  setState(() => _catServerEnabled = v);
                  _broker.dispatch(0, 'CatServerEnabled', v ? 1 : 0);
                },
                colors,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 28),
                child: Text(
                  'Virtual serial port for Kenwood TS-2000 CAT control',
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildServerCard(
    String label,
    bool enabled,
    TextEditingController portController,
    ValueChanged<bool> onEnabledChanged,
    ValueChanged<int> onPortChanged,
    ColorScheme colors,
  ) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(label, colors),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _checkboxRow(
                  'Enabled',
                  enabled,
                  onEnabledChanged,
                  colors,
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 120,
                child: _portFieldRowWithController(
                    'Port', portController, onPortChanged, colors),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Data Sources ─────────────────────────────────────────────────

  Widget _buildDataSources(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('AIRPLANE TRACKING', colors),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _textFieldRowWithController(
                      'Tracking URL',
                      _airplaneUrlController,
                      null,
                      (v) {
                        _airplaneUrl = v;
                        _broker.dispatch(0, 'AirplaneUrl', v);
                      },
                      colors,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 28,
                    child: FilledButton.tonal(
                      onPressed: _testAirplaneUrl,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: const Text('TEST', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 1)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _checkboxRow(
                'Show Airplanes on Map',
                _showAirplanesOnMap,
                (v) {
                  setState(() => _showAirplanesOnMap = v);
                  _broker.dispatch(0, 'ShowAirplanesOnMap', v ? 1 : 0);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('GPS SERIAL', colors),
              const SizedBox(height: 12),
              _textFieldRowWithController(
                'Serial Port',
                _gpsSerialPortController,
                null,
                (v) {
                  _gpsSerialPort = v;
                  _broker.dispatch(0, 'GpsSerialPort', v);
                },
                colors,
              ),
              const SizedBox(height: 10),
              _dropdownRow(
                'Baud Rate',
                _gpsBaud.toString(),
                ['4800', '9600', '19200', '38400', '57600', '115200'],
                (v) {
                  final parsed = int.tryParse(v) ?? 9600;
                  setState(() => _gpsBaud = parsed);
                  _broker.dispatch(0, 'GpsBaud', parsed);
                },
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('REPEATERBOOK', colors),
              const SizedBox(height: 12),
              _textFieldRowWithController(
                'Country',
                _repeaterBookCountryController,
                null,
                (v) {
                  _repeaterBookCountry = v;
                  _broker.dispatch(0, 'RepeaterBookCountry', v);
                },
                colors,
              ),
              const SizedBox(height: 10),
              _textFieldRowWithController(
                'State / Province',
                _repeaterBookStateController,
                null,
                (v) {
                  _repeaterBookState = v;
                  _broker.dispatch(0, 'RepeaterBookState', v);
                },
                colors,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Audio ────────────────────────────────────────────────────────

  Widget _buildAudio(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('HARDWARE AUDIO', colors),
              const SizedBox(height: 12),
              _sliderRow(
                'Volume',
                _volume,
                0,
                15,
                15,
                (v) {
                  setState(() => _volume = v);
                  _broker.dispatch(0, 'Volume', v.round());
                },
                colors,
                valueLabel: _volume.round().toString(),
              ),
              const SizedBox(height: 10),
              _sliderRow(
                'Squelch',
                _squelch,
                0,
                9,
                9,
                (v) {
                  setState(() => _squelch = v);
                  _broker.dispatch(0, 'Squelch', v.round());
                },
                colors,
                valueLabel: _squelch.round().toString(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('SOFTWARE AUDIO', colors),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _sliderRow(
                      'Output Volume',
                      _outputVolume,
                      0,
                      100,
                      20,
                      (v) {
                        setState(() => _outputVolume = v);
                        _broker.dispatch(0, 'OutputVolume', v.round());
                      },
                      colors,
                      valueLabel: '${_outputVolume.round()}%',
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    children: [
                      Text(
                        'MUTE',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Switch(
                        value: _mute,
                        onChanged: (v) {
                          setState(() => _mute = v);
                          _broker.dispatch(0, 'Mute', v ? 1 : 0);
                        },
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _sliderRow(
                'Mic Gain',
                _micGain,
                0,
                200,
                10,
                (v) {
                  setState(() => _micGain = v);
                  _broker.dispatch(0, 'MicGain', v.round());
                },
                colors,
                valueLabel: '${_micGain.round()}%',
              ),
            ],
          ),
        ),
        if (Platform.isMacOS) ...[
          const SizedBox(height: 10),
          _buildMacAudioDevicesCard(colors),
        ],
        const SizedBox(height: 10),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('VIRTUAL AUDIO', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Enabled',
                _virtualAudioEnabled,
                (v) {
                  setState(() => _virtualAudioEnabled = v);
                  _broker.dispatch(0, 'VirtualAudioEnabled', v ? 1 : 0);
                },
                colors,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 28),
                child: Text(
                  'Route radio audio through virtual PulseAudio devices for external software',
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── macOS audio devices (Audio tab, macOS only) ──────────────────

  /// Speaker + Microphone dropdowns for the macOS native audio path.
  /// Both backed by the Swift ``NativeAudioPlugin`` CoreAudio
  /// enumeration. Choices stored as CoreAudio UID strings (stable
  /// across reboots) under ``MacOsOutputDeviceUid`` /
  /// ``MacOsInputDeviceUid``. SPEAKER hot-swaps the AVAudioEngine
  /// output unit via ``MacOsNativeRfcommAudio.setOutputDevice``;
  /// MICROPHONE applies on the next PTT. REFRESH re-queries CoreAudio
  /// so newly-plugged hardware (AirPods, USB headsets) appears.
  int _macAudioRefreshNonce = 0;

  Widget _buildMacAudioDevicesCard(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _sectionLabel('macOS AUDIO DEVICES', colors)),
              InkWell(
                onTap: () => setState(() => _macAudioRefreshNonce++),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 12, color: colors.primary),
                      const SizedBox(width: 4),
                      Text(
                        'REFRESH',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _nativeSpeakerDropdown(colors),
          const SizedBox(height: 8),
          _nativeMicDropdown(colors),
          const SizedBox(height: 10),
          Text(
            'SPEAKER applies immediately (brief audio glitch). MICROPHONE '
            'applies on next PTT. Tap REFRESH after plugging in AirPods '
            'or a USB headset.',
            style: TextStyle(
              fontSize: 10,
              color: colors.outline,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  /// Speaker dropdown backed by ``NativeAudioPlugin.listOutputDevices``.
  /// Stores the chosen CoreAudio UID under ``MacOsOutputDeviceUid`` and
  /// hot-swaps the active AVAudioEngine output via ``setOutputDevice``.
  Widget _nativeSpeakerDropdown(ColorScheme colors) {
    final nativeAudio = MacOsNativeAudio();
    return FutureBuilder<List<Map<String, dynamic>>>(
      key: ValueKey('mac-spk-$_macAudioRefreshNonce'),
      future: nativeAudio.listOutputDevices().catchError(
            (_) => <Map<String, dynamic>>[],
          ),
      builder: (context, snap) {
        final devices = snap.data ?? const <Map<String, dynamic>>[];
        final stored =
            DataBroker.getValue<String>(0, 'MacOsOutputDeviceUid', '');
        final items = <DropdownMenuItem<String>>[
          const DropdownMenuItem(
            value: '',
            child: Text('System default', style: TextStyle(fontSize: 11)),
          ),
          ...devices.map((d) {
            final uid = d['id'] as String? ?? '';
            final name = d['name'] as String? ?? uid;
            final isDefault = d['default'] == true;
            final label = isDefault ? '$name  (default)' : name;
            return DropdownMenuItem<String>(
              value: uid,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            );
          }),
        ];
        final value = items.any((i) => i.value == stored) ? stored : '';
        return _uidDropdownRow(
          colors,
          label: 'SPEAKER',
          value: value,
          items: items,
          onChanged: (v) {
            if (v == null) return;
            setState(() {});
            // Persist + broadcast — MacOsAudioOutput subscribes to
            // this and calls setOutputDevice on the open session.
            DataBroker.dispatch(0, 'MacOsOutputDeviceUid', v);
          },
        );
      },
    );
  }

  /// Microphone dropdown backed by the native Swift AVAudioEngine
  /// plugin. CoreAudio UIDs (strings) are used as the stable device
  /// identifier, stored under ``MacOsInputDeviceUid``.
  Widget _nativeMicDropdown(ColorScheme colors) {
    final nativeAudio = MacOsNativeAudio();
    return FutureBuilder<List<Map<String, dynamic>>>(
      key: ValueKey('mac-mic-$_macAudioRefreshNonce'),
      future: nativeAudio.listInputDevices().catchError(
            (_) => <Map<String, dynamic>>[],
          ),
      builder: (context, snap) {
        final devices = snap.data ?? const <Map<String, dynamic>>[];
        final stored =
            DataBroker.getValue<String>(0, 'MacOsInputDeviceUid', '');
        final items = <DropdownMenuItem<String>>[
          const DropdownMenuItem(
            value: '',
            child: Text('System default', style: TextStyle(fontSize: 11)),
          ),
          ...devices.map((d) {
            final uid = d['id'] as String? ?? '';
            final name = d['name'] as String? ?? uid;
            final isDefault = d['default'] == true;
            final label = isDefault ? '$name  (default)' : name;
            return DropdownMenuItem<String>(
              value: uid,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            );
          }),
        ];
        final value = items.any((i) => i.value == stored) ? stored : '';
        return _uidDropdownRow(
          colors,
          label: 'MICROPHONE',
          value: value,
          items: items,
          onChanged: (v) {
            if (v == null) return;
            setState(() {});
            DataBroker.dispatch(0, 'MacOsInputDeviceUid', v);
            // Mic picks up the new device on next PTT; no hot path
            // here because CoreAudio won't swap mic mid-capture
            // without tearing the engine down.
          },
        );
      },
    );
  }

  Widget _uidDropdownRow(
    ColorScheme colors, {
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: DropdownButton<String>(
              value: value,
              underline: const SizedBox(),
              isDense: true,
              isExpanded: true,
              dropdownColor: colors.surfaceContainerHigh,
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Modem ────────────────────────────────────────────────────────

  Widget _buildModem(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('SOFTWARE MODEM', colors),
              const SizedBox(height: 12),
              _dropdownRow(
                'Mode',
                _modemMode,
                ['None', 'AFSK 1200', 'PSK 2400', 'PSK 4800', 'G3RUH 9600'],
                (v) {
                  setState(() => _modemMode = v);
                  _broker.dispatch(0, 'ModemMode', v);
                },
                colors,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Shared UI helpers ────────────────────────────────────────────

  Widget _sectionLabel(String text, ColorScheme colors) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
        color: colors.onSurfaceVariant,
      ),
    );
  }

  Widget _dropdownRow(
    String label,
    String value,
    List<String> items,
    ValueChanged<String> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: DropdownButton<String>(
            value: value,
            underline: const SizedBox(),
            isDense: true,
            dropdownColor: colors.surfaceContainerHigh,
            style: TextStyle(fontSize: 11, color: colors.onSurface),
            items: items
                .map((i) => DropdownMenuItem(value: i, child: Text(i)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }

  Widget _textFieldRowWithController(
    String label,
    TextEditingController controller,
    int? maxLength,
    ValueChanged<String> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 30,
            child: TextField(
              controller: controller,
              maxLength: maxLength,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.primary),
                ),
                filled: true,
                fillColor: colors.surfaceContainerLow,
              ),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _passwordFieldRowWithController(
    String label,
    TextEditingController controller,
    ValueChanged<String> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 30,
            child: TextField(
              controller: controller,
              obscureText: true,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.primary),
                ),
                filled: true,
                fillColor: colors.surfaceContainerLow,
              ),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _portFieldRowWithController(
    String label,
    TextEditingController controller,
    ValueChanged<int> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 30,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: colors.primary),
                ),
                filled: true,
                fillColor: colors.surfaceContainerLow,
              ),
              onChanged: (v) {
                final parsed = int.tryParse(v);
                if (parsed != null) onChanged(parsed);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _checkboxRow(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            visualDensity:
                const VisualDensity(horizontal: -4, vertical: -4),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: colors.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> onChanged,
    ColorScheme colors, {
    String? valueLabel,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
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
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: colors.primary,
              inactiveTrackColor: colors.surfaceContainerHigh,
              thumbColor: colors.primary,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        if (valueLabel != null)
          SizedBox(
            width: 40,
            child: Text(
              valueLabel,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
          ),
      ],
    );
  }

  // ─── APRS route helpers ─────────────────────────────────────────

  void _loadAprsRoutes() {
    final routesJson = DataBroker.getValue<String>(0, 'AprsRoutes', '');
    if (routesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(routesJson);
        if (decoded is List) {
          _aprsRoutes = decoded
              .whereType<Map>()
              .map((m) => Map<String, String>.from(m))
              .toList();
        }
      } catch (_) {}
    }
    if (_aprsRoutes.isEmpty) {
      _aprsRoutes = [
        {'name': 'Default', 'path': 'WIDE1-1,WIDE2-1'},
      ];
    }
  }

  void _saveAprsRoutes() {
    _broker.dispatch(0, 'AprsRoutes', jsonEncode(_aprsRoutes));
  }

  Future<void> _addAprsRoute() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const AprsRouteDialog(),
    );
    if (result != null) {
      setState(() => _aprsRoutes.add(result));
      _saveAprsRoutes();
    }
  }

  Future<void> _editAprsRoute(int index) async {
    final route = _aprsRoutes[index];
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AprsRouteDialog(
        initialName: route['name'],
        initialPath: route['path'],
      ),
    );
    if (result != null) {
      setState(() => _aprsRoutes[index] = result);
      _saveAprsRoutes();
    }
  }

  void _deleteAprsRoute(int index) {
    setState(() => _aprsRoutes.removeAt(index));
    _saveAprsRoutes();
  }

  // ─── Port conflict detection ────────────────────────────────────

  void _checkPortConflicts() {
    final ports = <String, int>{};
    if (_webServerEnabled) ports['Web'] = _webServerPort;
    if (_agwpeEnabled) ports['AGWPE'] = _agwpePort;
    if (_rigctldEnabled) ports['Rigctld'] = _rigctldPort;
    if (_mcpServerEnabled) ports['MCP'] = _mcpServerPort;

    final seen = <int, String>{};
    final conflicts = <String>[];
    for (final entry in ports.entries) {
      if (seen.containsKey(entry.value)) {
        conflicts.add('${entry.key} and ${seen[entry.value]} share port ${entry.value}');
      } else {
        seen[entry.value] = entry.key;
      }
    }
    _portConflictWarning =
        conflicts.isNotEmpty ? 'Port conflict: ${conflicts.join('; ')}' : null;
  }

  // ─── Airplane tracking test ─────────────────────────────────────

  Future<void> _testAirplaneUrl() async {
    final url = _airplaneUrlController.text.trim();
    if (url.isEmpty) return;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      if (!mounted) return;
      final lines = body.split('\n').where((l) => l.trim().isNotEmpty).length;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('OK: ${response.statusCode}, $lines lines received'),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        duration: const Duration(seconds: 3),
      ));
    }
  }
}

class _SettingsCategory {
  const _SettingsCategory(this.name, this.icon);
  final String name;
  final IconData icon;
}
