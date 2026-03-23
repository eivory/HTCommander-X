import 'package:flutter/material.dart';

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
  int _selectedIndex = 0;
  bool _showSettings = false;

  static const _screens = <Widget>[
    CommunicationScreen(),
    ContactsScreen(),
    LogbookScreen(),
    PacketsScreen(),
    TerminalScreen(),
    BbsScreen(),
    MailScreen(),
    TorrentScreen(),
    AprsScreen(),
    MapScreen(),
    DebugScreen(),
  ];

  Widget get _currentScreen {
    if (_showSettings) return const SettingsScreen();
    return _screens[_selectedIndex];
  }

  void _onDestinationSelected(int index) {
    setState(() {
      _selectedIndex = index;
      _showSettings = false;
    });
  }

  void _onSettingsTap() {
    setState(() {
      _showSettings = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width > 800;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            SidebarNav(
              selectedIndex: _showSettings ? -1 : _selectedIndex,
              onDestinationSelected: _onDestinationSelected,
              onSettingsTap: _onSettingsTap,
              onAboutTap: () => _showAboutDialog(context),
            ),
            VerticalDivider(width: 1, thickness: 1),
            Expanded(child: _currentScreen),
          ],
        ),
      );
    }

    // Mobile layout: bottom navigation bar
    return Scaffold(
      body: _currentScreen,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _showSettings
            ? sidebarDestinations.length
            : _selectedIndex.clamp(0, 4),
        onDestinationSelected: (index) {
          if (index < _mobileDestinations.length) {
            // Map mobile index back to full index
            setState(() {
              _selectedIndex = _mobileIndexMap[index];
              _showSettings = false;
            });
          }
        },
        destinations: _mobileDestinations
            .map(
              (d) => NavigationDestination(icon: Icon(d.icon), label: d.label),
            )
            .toList(),
      ),
    );
  }

  // Show a subset on mobile bottom nav
  static const _mobileIndexMap = [0, 1, 8, 9, 10];
  static final _mobileDestinations = [
    sidebarDestinations[0], // Communication
    sidebarDestinations[1], // Contacts
    sidebarDestinations[8], // APRS
    sidebarDestinations[9], // Map
    sidebarDestinations[10], // Debug
  ];

  void _showAboutDialog(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'HTCommander-X',
      applicationVersion: '0.1.0',
      children: [
        const Text('Flutter edition of HTCommander ham radio controller.'),
      ],
    );
  }
}
