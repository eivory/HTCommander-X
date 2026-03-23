import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedCategory = 'General';

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
  String _stationId = 'Primary';
  bool _allowTransmit = false;
  bool _checkForUpdates = true;

  // APRS
  final List<String> _aprsRoutes = ['WIDE1-1,WIDE2-1', 'WIDE1-1'];

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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _buildHeader(colors),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 180,
                child: _buildCategorySidebar(colors),
              ),
              Expanded(
                child: _buildContentPanel(colors),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(ColorScheme colors) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: colors.surfaceContainer,
      child: Row(
        children: [
          Text(
            'SYSTEM PARAMETERS',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildCategorySidebar(ColorScheme colors) {
    return Container(
      color: colors.surfaceContainerLow,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final cat = _categories[index];
          final isSelected = cat.name == _selectedCategory;
          return ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            leading: Icon(
              cat.icon,
              size: 16,
              color:
                  isSelected ? colors.primary : colors.onSurfaceVariant,
            ),
            title: Text(
              cat.name,
              style: TextStyle(
                fontSize: 11,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? colors.onSurface
                    : colors.onSurfaceVariant,
              ),
            ),
            selected: isSelected,
            selectedTileColor: colors.primaryContainer.withAlpha(80),
            onTap: () => setState(() => _selectedCategory = cat.name),
          );
        },
      ),
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
                (v) => setState(() => _theme = v),
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
              _textFieldRow('Call Sign', _callSign, 6, (v) {
                setState(() => _callSign = v);
              }, colors),
              const SizedBox(height: 10),
              _dropdownRow(
                'Station ID',
                _stationId,
                ['Primary', 'Secondary', 'Portable', 'Mobile'],
                (v) => setState(() => _stationId = v),
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
                (v) => setState(() => _allowTransmit = v),
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
                (v) => setState(() => _checkForUpdates = v),
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
                    onPressed: () {},
                    tooltip: 'Add Route',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._aprsRoutes.asMap().entries.map((entry) {
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
                            entry.value,
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
                        onPressed: () {},
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline,
                            size: 14, color: colors.error),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 28, minHeight: 28),
                        onPressed: () {},
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
                (v) => setState(() => _language = v),
                colors,
              ),
              const SizedBox(height: 10),
              _dropdownRow(
                'TTS Voice',
                _ttsVoice,
                ['Default', 'Male', 'Female'],
                (v) => setState(() => _ttsVoice = v),
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
                (v) => setState(() => _whisperStt = v),
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
              _passwordFieldRow('Password', _winlinkPassword, (v) {
                setState(() => _winlinkPassword = v);
              }, colors),
              const SizedBox(height: 10),
              _checkboxRow(
                'Use Station ID as Winlink Account',
                _useStationId,
                (v) => setState(() => _useStationId = v),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('NETWORK OPTIONS', colors),
              const SizedBox(height: 12),
              _checkboxRow(
                'Bind to All Interfaces (LAN Access)',
                _serverBindAll,
                (v) => setState(() => _serverBindAll = v),
                colors,
              ),
              const SizedBox(height: 6),
              _checkboxRow(
                'Enable TLS (HTTPS)',
                _tlsEnabled,
                (v) => setState(() => _tlsEnabled = v),
                colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'WEB SERVER',
          _webServerEnabled,
          _webServerPort,
          (v) => setState(() => _webServerEnabled = v),
          (v) => setState(() => _webServerPort = v),
          colors,
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'AGWPE SERVER',
          _agwpeEnabled,
          _agwpePort,
          (v) => setState(() => _agwpeEnabled = v),
          (v) => setState(() => _agwpePort = v),
          colors,
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'RIGCTLD SERVER',
          _rigctldEnabled,
          _rigctldPort,
          (v) => setState(() => _rigctldEnabled = v),
          (v) => setState(() => _rigctldPort = v),
          colors,
        ),
        const SizedBox(height: 10),
        _buildServerCard(
          'MCP SERVER',
          _mcpServerEnabled,
          _mcpServerPort,
          (v) => setState(() => _mcpServerEnabled = v),
          (v) => setState(() => _mcpServerPort = v),
          colors,
        ),
      ],
    );
  }

  Widget _buildServerCard(
    String label,
    bool enabled,
    int port,
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
                child: _portFieldRow('Port', port, onPortChanged, colors),
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
              _textFieldRow(
                'Tracking URL',
                _airplaneUrl,
                null,
                (v) => setState(() => _airplaneUrl = v),
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
              _textFieldRow(
                'Serial Port',
                _gpsSerialPort,
                null,
                (v) => setState(() => _gpsSerialPort = v),
                colors,
              ),
              const SizedBox(height: 10),
              _dropdownRow(
                'Baud Rate',
                _gpsBaud.toString(),
                ['4800', '9600', '19200', '38400', '57600', '115200'],
                (v) => setState(() => _gpsBaud = int.tryParse(v) ?? 9600),
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
              _textFieldRow(
                'Country',
                _repeaterBookCountry,
                null,
                (v) => setState(() => _repeaterBookCountry = v),
                colors,
              ),
              const SizedBox(height: 10),
              _textFieldRow(
                'State / Province',
                _repeaterBookState,
                null,
                (v) => setState(() => _repeaterBookState = v),
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
                (v) => setState(() => _volume = v),
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
                (v) => setState(() => _squelch = v),
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
                      (v) => setState(() => _outputVolume = v),
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
                        onChanged: (v) => setState(() => _mute = v),
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
                (v) => setState(() => _micGain = v),
                colors,
                valueLabel: '${_micGain.round()}%',
              ),
            ],
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
                (v) => setState(() => _modemMode = v),
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

  Widget _textFieldRow(
    String label,
    String value,
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
              controller: TextEditingController(text: value),
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

  Widget _passwordFieldRow(
    String label,
    String value,
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
              controller: TextEditingController(text: value),
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

  Widget _portFieldRow(
    String label,
    int value,
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
              controller: TextEditingController(text: value.toString()),
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
}

class _SettingsCategory {
  const _SettingsCategory(this.name, this.icon);
  final String name;
  final IconData icon;
}
