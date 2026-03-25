import 'dart:io' show Platform, Process;
import 'package:flutter/material.dart';

import 'core/data_broker.dart';
import 'core/data_broker_client.dart';
import 'radio/radio.dart' as ht;
import 'radio/models/radio_dev_info.dart';
import 'radio/models/radio_settings.dart';
import 'radio/models/radio_channel_info.dart';
import 'platform/bluetooth_service.dart';
import 'platform/linux/linux_platform_services.dart';
import 'platform/windows/windows_platform_services.dart';
import 'theme/signal_protocol_theme.dart';
import 'widgets/sidebar_nav.dart';
import 'screens/communication_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/logbook_screen.dart';
import 'screens/packets_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/bbs_screen.dart';
import 'screens/mail_screen.dart';
import 'screens/torrent_screen.dart';
import 'screens/aprs_screen.dart';
import 'screens/map_screen.dart';
import 'screens/debug_screen.dart';
import 'screens/settings_screen.dart';

class HTCommanderApp extends StatelessWidget {
  const HTCommanderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HTCommander-X',
      debugShowCheckedModeBanner: false,
      theme: SignalProtocolTheme.light(),
      darkTheme: SignalProtocolTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedSidebarIndex = 0;
  bool _showSettings = false;
  int? _directScreenIndex; // For non-sidebar screens (logbook, map, debug)

  // Sidebar → IndexedStack screen mapping
  // Sidebar: Communication(0), Contacts(1), Packets(2), Terminal(3),
  //          BBS(4), Mail(5), Torrent(6), APRS(7)
  // IndexedStack keeps all 11 screens for backwards compatibility
  static const _sidebarToScreen = [0, 1, 3, 4, 5, 6, 7, 8];

  // DataBroker wiring
  final DataBrokerClient _broker = DataBrokerClient();

  // Radio connection
  static const int _radioDeviceId = 100;
  PlatformServices? _platformServices;
  ht.Radio? _radio;
  String _radioMac = '';
  String _radioState = 'Disconnected';
  String? _radioName;
  int _batteryPercent = 0;
  int _rssi = 0;

  // VFO frequency for sidebar
  double _vfoAFreq = 0;
  String _callSign = 'N0CALL';

  // Cached radio data for VFO info
  RadioSettings? _settings;
  List<RadioChannelInfo?> _channels = [];

  bool get _isConnected => _radioState == 'connected';
  bool get _isConnecting => _radioState == 'connecting';

  static const _screens = <Widget>[
    CommunicationScreen(), // 0
    ContactsScreen(),      // 1
    LogbookScreen(),       // 2 (not in sidebar, accessible elsewhere)
    PacketsScreen(),       // 3
    TerminalScreen(),      // 4
    BbsScreen(),           // 5
    MailScreen(),          // 6
    TorrentScreen(),       // 7
    AprsScreen(),          // 8
    MapScreen(),           // 9 (not in sidebar)
    DebugScreen(),         // 10 (not in sidebar)
  ];

  Widget _buildScreenArea() {
    if (_showSettings) return const SettingsScreen();
    return IndexedStack(
      index: _directScreenIndex ?? _sidebarToScreen[_selectedSidebarIndex],
      children: _screens,
    );
  }

  @override
  void initState() {
    super.initState();

    _radioMac = DataBroker.getValue<String>(0, 'LastRadioMac', '38:D2:00:01:04:E2');
    _callSign = DataBroker.getValue<String>(0, 'CallSign', 'N0CALL');

    _initPlatformServices();

    // Radio state subscriptions
    _broker.subscribe(DataBroker.allDevices, 'State', _onRadioStateChanged);
    _broker.subscribe(DataBroker.allDevices, 'Info', _onRadioInfoChanged);
    _broker.subscribe(DataBroker.allDevices, 'BatteryAsPercentage', _onBatteryChanged);
    _broker.subscribe(DataBroker.allDevices, 'FriendlyName', _onFriendlyNameChanged);
    _broker.subscribe(DataBroker.allDevices, 'HtStatus', _onHtStatusChanged);
    _broker.subscribe(DataBroker.allDevices, 'Settings', _onSettingsChanged);
    _broker.subscribe(DataBroker.allDevices, 'Channels', _onChannelsChanged);

    // MCP remote control
    _broker.subscribe(1, 'McpConnectRadio', _onMcpConnect);
    _broker.subscribe(1, 'McpDisconnectRadio', _onMcpDisconnect);
    _broker.subscribe(1, 'McpNavigateTo', _onMcpNavigate);

    // Publish initial screen
    DataBroker.dispatch(1, 'CurrentScreen', 'communication');
  }

  void _initPlatformServices() {
    if (Platform.isLinux) {
      _platformServices = LinuxPlatformServices();
    } else if (Platform.isWindows) {
      _platformServices = WindowsPlatformServices();
    }
    PlatformServices.instance = _platformServices;
  }

  @override
  void dispose() {
    _broker.dispose();
    _radio?.dispose();
    super.dispose();
  }

  // ── DataBroker callbacks ───────────────────────────────────────────

  void _onRadioStateChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100) return;
    if (data is String && mounted) {
      setState(() => _radioState = data);
    }
  }

  void _onRadioInfoChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100) return;
    if (data is RadioDevInfo && mounted) {
      setState(() => _radioName = 'Radio ${data.productId}');
    } else if (data == null && mounted) {
      setState(() => _radioName = null);
    }
  }

  void _onBatteryChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100) return;
    if (data is int && mounted) {
      setState(() => _batteryPercent = data);
    }
  }

  void _onFriendlyNameChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100 || data is! String) return;
    if (mounted) setState(() => _radioName = data);
  }

  void _onHtStatusChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100) return;
    if (data != null && mounted) {
      // Extract RSSI from HtStatus
      try {
        final dynamic ht = data;
        setState(() => _rssi = (ht as dynamic).rssi as int);
      } catch (_) {}
    }
  }

  void _onSettingsChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100 || data is! RadioSettings || !mounted) return;
    setState(() {
      _settings = data;
      _updateVfoFromChannels();
    });
  }

  void _onChannelsChanged(int deviceId, String name, Object? data) {
    if (deviceId < 100 || data is! List || !mounted) return;
    setState(() {
      _channels = data.cast<RadioChannelInfo?>();
      _updateVfoFromChannels();
    });
  }

  void _updateVfoFromChannels() {
    final s = _settings;
    if (s == null) return;
    final chA = s.channelA;
    if (chA >= 0 && chA < _channels.length && _channels[chA] != null) {
      _vfoAFreq = _channels[chA]!.rxFreq / 1000000.0;
    }
  }

  // ── MCP remote connect/disconnect ──────────────────────────────

  void _onMcpConnect(int deviceId, String name, Object? data) {
    if (_isConnected || _isConnecting) return;
    final mac = (data is String && data.isNotEmpty)
        ? data
        : DataBroker.getValue<String>(0, 'LastRadioMac', '');
    if (mac.isNotEmpty) _connectToRadio(mac);
  }

  void _onMcpDisconnect(int deviceId, String name, Object? data) {
    if (!_isConnected && !_isConnecting) return;
    _disconnectRadio();
  }

  // Screen name → sidebar index mapping (null = not a sidebar item)
  static const _screenToSidebar = <String, int>{
    'communication': 0, 'contacts': 1, 'packets': 2, 'terminal': 3,
    'bbs': 4, 'mail': 5, 'torrent': 6, 'aprs': 7,
  };
  // Screen name → IndexedStack index for non-sidebar screens
  static const _screenToStack = <String, int>{
    'logbook': 2, 'map': 9, 'debug': 10,
  };

  void _onMcpNavigate(int deviceId, String name, Object? data) {
    if (data is! String || !mounted) return;
    final screen = data.toLowerCase();
    if (screen == 'settings') {
      setState(() => _showSettings = true);
      DataBroker.dispatch(1, 'CurrentScreen', 'settings');
      return;
    }
    final sidebarIdx = _screenToSidebar[screen];
    if (sidebarIdx != null) {
      setState(() {
        _selectedSidebarIndex = sidebarIdx;
        _directScreenIndex = null;
        _showSettings = false;
      });
      DataBroker.dispatch(1, 'CurrentScreen', screen);
      return;
    }
    final stackIdx = _screenToStack[screen];
    if (stackIdx != null) {
      setState(() {
        _directScreenIndex = stackIdx;
        _showSettings = false;
      });
      DataBroker.dispatch(1, 'CurrentScreen', screen);
    }
  }

  // ── Radio connection ───────────────────────────────────────────────

  void _onPowerTap() {
    if (_isConnected || _isConnecting) {
      _disconnectRadio();
    } else if (_radioMac.isNotEmpty) {
      _connectToRadio(_radioMac);
    } else {
      _showConnectDialog();
    }
  }

  void _connectToRadio(String mac) {
    if (mac.isEmpty) return;
    _radioMac = mac;
    DataBroker.dispatch(0, 'LastRadioMac', mac);

    if (_platformServices == null) {
      DataBroker.dispatch(1, 'LogInfo',
          'Bluetooth not yet implemented for this platform.',
          store: false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth transport not yet implemented for this platform'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    _radio?.dispose();
    _radio = ht.Radio(_radioDeviceId, mac, _platformServices);
    DataBroker.addDataHandler('Radio_$_radioDeviceId', _radio!);
    _lookupBluetoothName(mac);
    DataBroker.dispatch(1, 'ConnectedRadios', [_radio!]);
    _radio!.connect();
  }

  Future<void> _lookupBluetoothName(String mac) async {
    final clean = mac.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    final macColon = List.generate(6, (i) => clean.substring(i * 2, i * 2 + 2)).join(':');
    try {
      final result = await Process.run('bluetoothctl', ['info', macColon]);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final nameMatch = RegExp(r'Name:\s*(.+)').firstMatch(output);
        if (nameMatch != null) {
          final name = nameMatch.group(1)!.trim();
          if (name.isNotEmpty) _radio?.updateFriendlyName(name);
        }
      }
    } catch (_) {}
  }

  void _disconnectRadio() {
    if (_radio != null) {
      _radio!.disconnect();
      DataBroker.removeDataHandler('Radio_$_radioDeviceId');
      _radio = null;
    }
    DataBroker.dispatch(1, 'ConnectedRadios', <ht.Radio>[]);
    setState(() {
      _radioState = 'Disconnected';
      _radioName = null;
      _batteryPercent = 0;
      _rssi = 0;
      _vfoAFreq = 0;
    });
  }

  void _showConnectDialog() {
    final controller = TextEditingController(text: _radioMac);
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: colors.surfaceContainerHigh,
          title: Text(
            'CONNECT RADIO',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BLUETOOTH MAC ADDRESS',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: colors.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: 'XX:XX:XX:XX:XX:XX',
                  hintStyle: TextStyle(color: colors.outline),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Compatible: UV-Pro, VR-N76, VR-N7500, GA-5WB, RT-660',
                style: TextStyle(fontSize: 10, color: colors.outline),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _connectToRadio(controller.text.trim());
              },
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
  }

  // ── Navigation ─────────────────────────────────────────────────────

  void _onDestinationSelected(int sidebarIndex) {
    // Map sidebar index back to screen name for CurrentScreen
    const sidebarScreenNames = [
      'communication', 'contacts', 'packets', 'terminal',
      'bbs', 'mail', 'torrent', 'aprs',
    ];
    setState(() {
      _selectedSidebarIndex = sidebarIndex;
      _directScreenIndex = null;
      _showSettings = false;
    });
    if (sidebarIndex >= 0 && sidebarIndex < sidebarScreenNames.length) {
      DataBroker.dispatch(1, 'CurrentScreen', sidebarScreenNames[sidebarIndex]);
    }
  }

  void _onSettingsTap() {
    setState(() => _showSettings = true);
    DataBroker.dispatch(1, 'CurrentScreen', 'settings');
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width > 800;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            SidebarNav(
              selectedIndex: _showSettings ? -1 : _selectedSidebarIndex,
              onDestinationSelected: _onDestinationSelected,
              onSettingsTap: _onSettingsTap,
              onPowerTap: _onPowerTap,
              vfoAFrequency: _vfoAFreq,
              callSign: _callSign,
              isConnected: _isConnected,
              batteryPercent: _batteryPercent,
              rssi: _rssi,
            ),
            Expanded(child: _buildScreenArea()),
          ],
        ),
      );
    }

    // Mobile layout
    return Scaffold(
      body: Column(
        children: [
          _buildMobileStatusBar(),
          Expanded(child: _buildScreenArea()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _showSettings
            ? sidebarDestinations.length
            : _selectedSidebarIndex.clamp(0, 4),
        onDestinationSelected: (index) {
          if (index < _mobileDestinations.length) {
            setState(() {
              _selectedSidebarIndex = _mobileIndexMap[index];
              _showSettings = false;
            });
          }
        },
        destinations: _mobileDestinations
            .map((d) => NavigationDestination(icon: Icon(d.icon), label: d.label))
            .toList(),
      ),
    );
  }

  Widget _buildMobileStatusBar() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: colors.surfaceContainerLow,
      child: Row(
        children: [
          Text(
            'HTCommander-X',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: colors.primary,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isConnected
                  ? colors.tertiary
                  : _isConnecting ? Colors.amber : colors.outline,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _isConnected
                  ? '${_radioName ?? "Radio"} | ${_vfoAFreq > 0 ? "${_vfoAFreq.toStringAsFixed(3)} MHz" : ""}'
                  : _isConnecting ? 'Connecting...' : 'Disconnected',
              style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: _onPowerTap,
            child: Icon(
              _isConnected ? Icons.bluetooth_disabled : Icons.bluetooth,
              size: 16,
              color: _isConnected ? colors.error : colors.primary,
            ),
          ),
        ],
      ),
    );
  }

  // Mobile: show 5 key items in bottom nav
  static const _mobileIndexMap = [0, 1, 7, 5, 2]; // Comm, Contacts, APRS, Mail, Packets
  static final _mobileDestinations = [
    sidebarDestinations[0], // Communication
    sidebarDestinations[1], // Contacts
    sidebarDestinations[7], // APRS
    sidebarDestinations[5], // Mail
    sidebarDestinations[2], // Packets
  ];

}
