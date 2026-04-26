import 'package:data_table_2/data_table_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../handlers/aprs_handler.dart';
import '../radio/benshi_text_message.dart';
import '../radio/models/radio_channel_info.dart';
import '../radio/models/radio_ht_status.dart';
import '../radio/radio_enums.dart';
import '../widgets/glass_card.dart';
import '../widgets/status_strip.dart';

class AprsScreen extends StatefulWidget {
  const AprsScreen({super.key});

  @override
  State<AprsScreen> createState() => _AprsScreenState();
}

class _AprsScreenState extends State<AprsScreen> {
  final DataBrokerClient _broker = DataBrokerClient();
  bool _showAll = false;
  bool _warningDismissed = false;
  bool _isTransmitting = false;
  bool _isConnected = false;
  int _rssi = 0; // 0–15 S-meter scale from HtStatus
  int? _selectedEntryIndex;
  final MapController _mapController = MapController();
  String _selectedRoute = 'WIDE1-1,WIDE2-1';
  final TextEditingController _destinationController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  final List<String> _routes = [
    'WIDE1-1,WIDE2-1',
    'WIDE1-1',
    'WIDE2-1',
    'Direct',
  ];

  List<AprsEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _broker.subscribe(1, 'AprsStoreUpdated', _onAprsStoreUpdated);
    _broker.subscribe(100, 'Channels', (_, __, ___) => setState(() {}));
    _broker.subscribe(0, 'AprsChannelId', (_, __, ___) => setState(() {}));
    _broker.subscribe(100, 'HtStatus', _onHtStatus);
    _broker.subscribe(100, 'State', _onState);
    _broker.subscribe(100, 'BenshiTextReceived', _onBenshiText);
    // Seed current TX state and radio connection in case they were
    // published before we subscribed.
    final status = DataBroker.getValueDynamic(100, 'HtStatus');
    if (status is RadioHtStatus) {
      _isTransmitting = status.isInTx;
      _rssi = status.rssi;
    }
    final state = DataBroker.getValue<String>(100, 'State', '');
    _isConnected = state.toLowerCase() == 'connected';
    // Enable/disable the SEND button as the user types.
    _destinationController.addListener(() => setState(() {}));
    _messageController.addListener(() => setState(() {}));
    // Load initial data
    _loadEntries();
  }

  void _loadEntries() {
    final handler =
        DataBroker.getDataHandlerTyped<AprsHandler>('AprsHandler');
    if (handler != null) {
      setState(() {
        _entries = handler.entries;
      });
    }
  }

  void _onAprsStoreUpdated(int deviceId, String name, Object? data) {
    _loadEntries();
  }

  void _onState(int deviceId, String name, Object? data) {
    if (!mounted || data is! String) return;
    final connected = data.toLowerCase() == 'connected';
    if (_isConnected == connected) return;
    setState(() => _isConnected = connected);
  }

  void _onBenshiText(int deviceId, String name, Object? data) {
    if (!mounted || data is! BenshiTextMessage) return;
    final msg = data;
    final label = msg.to.isEmpty
        ? '${msg.from} (broadcast): ${msg.text}'
        : '${msg.from} → ${msg.to}: ${msg.text}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Direct text — $label',
            style: const TextStyle(fontSize: 11)),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onHtStatus(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioHtStatus) return;
    if (_isTransmitting == data.isInTx && _rssi == data.rssi) return;
    setState(() {
      _isTransmitting = data.isInTx;
      _rssi = data.rssi;
    });
  }

  /// Click handler for an APRS table row. Selects the row and, if the
  /// underlying packet has valid lat/lon, recentres + zooms the map
  /// onto that station's marker.
  void _onAprsRowSelected(int index) {
    setState(() => _selectedEntryIndex = index);
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final pos = entry.packet.position;
    if (!pos.isValid) return;
    final lat = pos.coordinateSet.latitude.value;
    final lon = pos.coordinateSet.longitude.value;
    if (lat == 0 && lon == 0) return;
    _mapController.move(LatLng(lat, lon), 14);
  }

  // ── APRS message send ─────────────────────────────────────────────

  /// Enable the SEND button only when we have all the ingredients:
  /// connected radio, detected APRS channel, a destination callsign,
  /// and a non-empty message.
  bool _canSend() {
    return _isConnected &&
        _aprsChannelId() >= 0 &&
        _destinationController.text.trim().isNotEmpty &&
        _messageController.text.trim().isNotEmpty;
  }

  /// Dispatches a ``SendAprsMessage`` event. AprsHandler builds the
  /// AX.25 UI frame and routes it to the radio via TransmitDataFrame.
  ///
  /// ``_selectedRoute`` is the string from the ROUTE dropdown
  /// ("WIDE1-1,WIDE2-1", "Direct", etc.). We split it into the
  /// digipeater list that AprsHandler expects as
  /// ``route = [<source-placeholder>, <destination>, <digis...>]``.
  /// The source is filled in by the handler from settings; we just
  /// pass an empty string as a placeholder at index 0.
  void _sendAprsMessage() {
    final destination = _destinationController.text.trim();
    final message = _messageController.text.trim();
    if (destination.isEmpty || message.isEmpty) return;

    final digis = _selectedRoute == 'Direct'
        ? <String>[]
        : _selectedRoute
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

    // AprsHandler expects index 1 = destination, index 2+ = digipeaters.
    final route = <String>['', 'APRS', ...digis];

    DataBroker.dispatch(
      1,
      'SendAprsMessage',
      AprsSendMessageData(
        destination: destination,
        message: message,
        radioDeviceId: 100,
        route: route,
      ),
      store: false,
    );

    // Clear the message so the user can type the next one.
    _messageController.clear();
    setState(() {});
  }

  /// Returns the RX frequency of the detected APRS channel formatted
  /// as MHz with 3 decimals, or a dashed placeholder if no channel is set.
  String _aprsFreqMhz() {
    final ch = _aprsChannel();
    if (ch == null || ch.rxFreq <= 0) return '---.---';
    return (ch.rxFreq / 1000000.0).toStringAsFixed(3);
  }

  /// Returns a short label like "Wide-FM / APRS" or the channel name,
  /// falling back to a "not configured" message.
  String _aprsChannelLabel() {
    final ch = _aprsChannel();
    if (ch == null) return 'No APRS channel';
    final name = ch.nameStr.trim();
    return name.isNotEmpty ? '$name / APRS' : 'APRS';
  }

  String _aprsModeLabel() {
    final ch = _aprsChannel();
    if (ch == null) return '—';
    return ch.rxMod == RadioModulationType.am ? 'AM' : 'FM';
  }

  String _aprsBandwidthLabel() {
    final ch = _aprsChannel();
    if (ch == null) return '—';
    return ch.bandwidth == RadioBandwidthType.wide ? '25 kHz' : '12.5 kHz';
  }

  RadioChannelInfo? _aprsChannel() {
    final id = _aprsChannelId();
    if (id < 0) return null;
    final channels = DataBroker.getValueDynamic(100, 'Channels');
    if (channels is! List || id >= channels.length) return null;
    final ch = channels[id];
    return ch is RadioChannelInfo ? ch : null;
  }

  /// Returns the radio channel id that will be used for APRS on the
  /// currently connected radio, or -1 if none is configured / detected.
  /// Mirrors AprsHandler._getAprsChannelId so the UI and handler agree.
  int _aprsChannelId() {
    final channels = DataBroker.getValueDynamic(100, 'Channels');
    if (channels is! List) return -1;
    final override = DataBroker.getValue<int>(0, 'AprsChannelId', -1);
    if (override >= 0 &&
        override < channels.length &&
        channels[override] is RadioChannelInfo) {
      return override;
    }
    for (var i = 0; i < channels.length; i++) {
      final ch = channels[i];
      if (ch is RadioChannelInfo && ch.nameStr.toUpperCase() == 'APRS') {
        return i;
      }
    }
    return -1;
  }

  @override
  void dispose() {
    _broker.dispose();
    _destinationController.dispose();
    _messageController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  String _formatPosition(AprsEntry entry) {
    final lat = entry.packet.position.coordinateSet.latitude.value;
    final lon = entry.packet.position.coordinateSet.longitude.value;
    if (lat == 0 && lon == 0) return '--';
    final latDir = lat >= 0 ? 'N' : 'S';
    final lonDir = lon >= 0 ? 'E' : 'W';
    return '${lat.abs().toStringAsFixed(4)}$latDir '
        '${lon.abs().toStringAsFixed(4)}$lonDir';
  }

  /// Count unique callsigns (stations) from entries.
  int get _activeStations {
    final seen = <String>{};
    for (final e in _entries) {
      seen.add(e.from);
    }
    return seen.length;
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'position':
      case 'positionMsg':
      case 'positionTime':
      case 'positionTimeMsg':
        return Colors.blue;
      case 'status':
        return Colors.green;
      case 'weatherReport':
        return Colors.orange;
      case 'beacon':
        return Colors.purple;
      case 'message':
        return Colors.teal;
      case 'micE':
      case 'micECurrent':
      case 'micEOld':
        return Colors.indigo;
      case 'object':
      case 'item':
        return Colors.deepOrange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const sectionStyle = TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.5,
    );

    return Column(
      children: [
        if (!_warningDismissed && _aprsChannelId() < 0) _buildWarningBanner(colors),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // --- Left column (flex 3) ---
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      // Frequency monitor panel
                      _buildFrequencyPanel(colors, sectionStyle),
                      const SizedBox(height: 10),
                      // Live APRS Feed
                      Expanded(
                        child: _buildFeedPanel(colors, sectionStyle),
                      ),
                      const SizedBox(height: 10),
                      // Transmit bar
                      _buildTransmitBar(colors),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // --- Right column (flex 2): full-height map ---
                Expanded(
                  flex: 2,
                  child: _buildMapPlaceholder(colors, sectionStyle),
                ),
              ],
            ),
          ),
        ),
        StatusStrip(
          isConnected: _isConnected,
          encoding: 'AX.25 / APRS',
          extraItems: [
            StatusStripItem(text: '$_activeStations STATIONS'),
            StatusStripItem(text: '${_entries.length} PACKETS'),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Frequency monitor panel
  // ---------------------------------------------------------------------------
  Widget _buildFrequencyPanel(ColorScheme colors, TextStyle sectionStyle) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'FREQUENCY MONITOR',
            style: sectionStyle.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Large frequency display — from the detected APRS channel,
              // or a placeholder if none is configured.
              Text(
                _aprsFreqMhz(),
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 2,
                  color: colors.primary,
                  height: 1,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'MHz',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: colors.primary.withAlpha(180),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  _aprsChannelLabel(),
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const Spacer(),
              // PTT Active indicator — only when the radio is actually
              // transmitting (from HtStatus.isInTx).
              if (_isTransmitting)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.error.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.error,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'PTT ACTIVE',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                          color: colors.error,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // Signal metrics row. The UV-PRO exposes a 4-bit RSSI
          // (S-meter 0–15) over GAIA — not a dBm value — and does not
          // expose SNR at all, so we show what we actually have.
          Row(
            children: [
              _buildMetric(colors, 'SIGNAL', 'S$_rssi/15'),
              const SizedBox(width: 24),
              _buildMetric(colors, 'MODE', _aprsModeLabel()),
              const SizedBox(width: 24),
              _buildMetric(colors, 'BANDWIDTH', _aprsBandwidthLabel()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(ColorScheme colors, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Live APRS Feed panel
  // ---------------------------------------------------------------------------
  Widget _buildFeedPanel(ColorScheme colors, TextStyle sectionStyle) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          _buildFeedPanelBody(colors, sectionStyle),
          if (_selectedEntryIndex != null &&
              _selectedEntryIndex! < _entries.length)
            Positioned(
              top: 12,
              right: 12,
              width: 320,
              height: 260,
              child: _buildAprsDecodePanel(colors, sectionStyle),
            ),
        ],
      ),
    );
  }

  Widget _buildFeedPanelBody(ColorScheme colors, TextStyle sectionStyle) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Text(
                  'LIVE APRS FEED',
                  style:
                      sectionStyle.copyWith(color: colors.onSurfaceVariant),
                ),
                const Spacer(),
                SizedBox(
                  height: 22,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: Checkbox(
                          value: _showAll,
                          onChanged: (v) =>
                              setState(() => _showAll = v ?? false),
                          visualDensity: const VisualDensity(
                            horizontal: -4,
                            vertical: -4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'SHOW ALL',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: colors.primary.withAlpha(25),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$_activeStations STATIONS ACTIVE',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: colors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Divider
          Divider(
            height: 1,
            thickness: 0.5,
            color: colors.outlineVariant.withAlpha(38),
          ),
          // Table
          Expanded(
            child: DataTable2(
                  // fixedTopRows: 1 keeps the header pinned during
                  // vertical scroll. Horizontal overflow is handled
                  // internally by the package.
                  fixedTopRows: 1,
                  showCheckboxColumn: false,
                  headingRowHeight: 32,
                  dataRowHeight: 32,
                  columnSpacing: 24,
                  horizontalMargin: 16,
                  minWidth: 600,
                  headingTextStyle: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: colors.onSurfaceVariant,
                  ),
                  dataTextStyle: TextStyle(
                    fontSize: 11,
                    color: colors.onSurface,
                  ),
                  columns: const [
                    // Fits the worst case: 6-char call + ``-`` + 2-digit
                    // SSID (e.g. WA1ABCD-15) plus the leading status dot.
                    DataColumn2(label: Text('CALLSIGN'), fixedWidth: 130),
                    DataColumn2(label: Text('POSITION'), size: ColumnSize.M),
                    DataColumn2(label: Text('DISTANCE'), size: ColumnSize.S),
                    DataColumn2(label: Text('LAST HEARD'), size: ColumnSize.S),
                  ],
                  // Newest first: the underlying handler appends, so
                  // reverse the list view (the original index is still
                  // captured for selection / map zoom).
                  rows: _entries
                      .asMap()
                      .entries
                      .toList()
                      .reversed
                      .map((kv) {
                    final index = kv.key;
                    final entry = kv.value;
                    // Use the full from including SSID — single column.
                    final callsign = entry.from;

                    final typeColor =
                        _typeColor(entry.packet.dataType.name);

                    return DataRow(
                      selected: _selectedEntryIndex == index,
                      onSelectChanged: (_) => _onAprsRowSelected(index),
                      cells: [
                      DataCell(Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: typeColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            callsign,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                            ),
                          ),
                        ],
                      )),
                      DataCell(Text(
                        _formatPosition(entry),
                        style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      )),
                      DataCell(Text(
                        '--',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                        ),
                      )),
                      DataCell(Text(_formatTime(entry.time))),
                    ]);
                  }).toList(),
                ),
          ),
        ],
    );
  }

  // ---------------------------------------------------------------------------
  // Decode panel — shows the parsed contents of the currently-selected
  // APRS row. Mirrors the Packets pane decode panel so users can see
  // the full message body without truncation.
  Widget _buildAprsDecodePanel(ColorScheme colors, TextStyle sectionStyle) {
    final entry = (_selectedEntryIndex != null &&
            _selectedEntryIndex! < _entries.length)
        ? _entries[_selectedEntryIndex!]
        : null;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'MESSAGE DETAILS',
                  style: sectionStyle.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
              InkWell(
                onTap: () => setState(() => _selectedEntryIndex = null),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: colors.outline),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(6),
              ),
              child: entry == null
                  ? Center(
                      child: Text(
                        'Select an APRS row to view decode',
                        style: TextStyle(fontSize: 11, color: colors.outline),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        _formatAprsDecode(entry),
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: colors.onSurface,
                          height: 1.5,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatAprsDecode(AprsEntry entry) {
    final pkt = entry.packet;
    final pos = pkt.position;
    final lines = <String>[
      'Time:    ${entry.time.toLocal()}',
      'From:    ${entry.from}',
      'To:      ${entry.to}',
      'Type:    ${pkt.dataType.name}',
      'Channel: ${entry.ax25Packet.channelName}',
    ];
    if (pos.isValid) {
      final lat = pos.coordinateSet.latitude.value;
      final lon = pos.coordinateSet.longitude.value;
      if (!(lat == 0 && lon == 0)) {
        lines.add('Lat:     ${lat.toStringAsFixed(5)}');
        lines.add('Lon:     ${lon.toStringAsFixed(5)}');
        if (pos.gridsquare.isNotEmpty) {
          lines.add('Grid:    ${pos.gridsquare}');
        }
      }
    }
    final raw = entry.ax25Packet.dataStr;
    if (raw != null && raw.isNotEmpty) {
      lines.add('');
      lines.add('Raw:');
      lines.add(raw);
    }
    return lines.join('\n');
  }

  // ---------------------------------------------------------------------------
  // Real APRS map: OpenStreetMap tiles + a marker per station-with-position.
  // ---------------------------------------------------------------------------
  Widget _buildAprsMap(ColorScheme colors) {
    // Collect the latest position fix per callsign — APRS stations
    // typically beacon the same position multiple times, so dedupe
    // by callsign and keep the most recent valid coordinate.
    final byCallsign = <String, AprsEntry>{};
    for (final e in _entries) {
      final pos = e.packet.position;
      if (!pos.isValid) continue;
      final lat = pos.coordinateSet.latitude.value;
      final lon = pos.coordinateSet.longitude.value;
      if (lat == 0 && lon == 0) continue;
      final call = e.from.isNotEmpty ? e.from : e.to;
      byCallsign[call] = e;
    }

    final markers = byCallsign.entries.map((kv) {
      final pos = kv.value.packet.position.coordinateSet;
      return Marker(
        point: LatLng(pos.latitude.value, pos.longitude.value),
        width: 64,
        height: 36,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on, size: 18, color: colors.primary),
            Text(
              kv.key,
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ),
      );
    }).toList();

    // Default center: average of stations, or a reasonable fallback
    // when no positioned stations have been heard yet.
    LatLng center;
    double zoom;
    if (markers.isEmpty) {
      center = const LatLng(39.8283, -98.5795); // continental US center
      zoom = 3;
    } else {
      final lats = markers.map((m) => m.point.latitude);
      final lons = markers.map((m) => m.point.longitude);
      center = LatLng(
        (lats.reduce((a, b) => a + b)) / markers.length,
        (lons.reduce((a, b) => a + b)) / markers.length,
      );
      zoom = markers.length == 1 ? 11 : 8;
    }

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        interactionOptions:
            const InteractionOptions(flags: InteractiveFlag.all),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.htcommander.htcommanderFlutter',
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Map placeholder (right column)
  // ---------------------------------------------------------------------------
  Widget _buildMapPlaceholder(ColorScheme colors, TextStyle sectionStyle) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'STATION MAP',
                  style:
                      sectionStyle.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            ),
            Expanded(child: _buildAprsMap(colors)),
            // Station counter badge at bottom
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: colors.primary.withAlpha(12),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.cell_tower, size: 14, color: colors.primary),
                  const SizedBox(width: 8),
                  Text(
                    '$_activeStations STATIONS TRACKED',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: colors.primary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_entries.length} PACKETS',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Warning banner
  // ---------------------------------------------------------------------------
  Widget _buildWarningBanner(ColorScheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: Colors.amber.withAlpha(25),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'No APRS channel configured. Set an APRS channel in Settings to enable packet reception.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.amber[700],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: () => setState(() => _warningDismissed = true),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Transmit bar
  // ---------------------------------------------------------------------------
  Widget _buildTransmitBar(ColorScheme colors) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          // Route dropdown
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ROUTE',
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: DropdownButton<String>(
                  value: _selectedRoute,
                  underline: const SizedBox(),
                  isDense: true,
                  dropdownColor: colors.surfaceContainerHigh,
                  style: TextStyle(fontSize: 10, color: colors.onSurface),
                  items: _routes
                      .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _selectedRoute = v ?? _selectedRoute),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // Destination
          SizedBox(
            width: 100,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'DESTINATION',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 30,
                  child: TextField(
                    controller: _destinationController,
                    style: TextStyle(fontSize: 11, color: colors.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Callsign',
                      hintStyle:
                          TextStyle(fontSize: 10, color: colors.outline),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
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
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Message
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'MESSAGE',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 30,
                  child: TextField(
                    controller: _messageController,
                    style: TextStyle(fontSize: 11, color: colors.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Type APRS message...',
                      hintStyle:
                          TextStyle(fontSize: 10, color: colors.outline),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
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
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton(
              onPressed: _canSend() ? _sendAprsMessage : null,
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              child: const Text('SEND'),
            ),
          ),
        ],
      ),
    );
  }
}
