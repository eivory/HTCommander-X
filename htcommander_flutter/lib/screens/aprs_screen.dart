import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class AprsScreen extends StatefulWidget {
  const AprsScreen({super.key});

  @override
  State<AprsScreen> createState() => _AprsScreenState();
}

class _AprsScreenState extends State<AprsScreen> {
  bool _showAll = false;
  bool _showWarning = true;
  String _selectedRoute = 'WIDE1-1,WIDE2-1';
  final TextEditingController _destinationController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  final List<String> _routes = [
    'WIDE1-1,WIDE2-1',
    'WIDE1-1',
    'WIDE2-1',
    'Direct',
  ];

  // Placeholder APRS data
  final List<_AprsEntry> _entries = [
    _AprsEntry(
      time: '14:32:15',
      from: 'W1AW-9',
      to: 'APRS',
      type: 'Position',
      message: '41.7147N 072.7272W /A=000150',
    ),
    _AprsEntry(
      time: '14:30:42',
      from: 'KD2ABC-7',
      to: 'APRS',
      type: 'Status',
      message: 'Mobile on I-95 North',
    ),
    _AprsEntry(
      time: '14:28:03',
      from: 'N0CALL-1',
      to: 'BLN1',
      type: 'Bulletin',
      message: 'Weekly net tonight 7:30 PM local',
    ),
    _AprsEntry(
      time: '14:25:11',
      from: 'WX4NHC',
      to: 'APRS',
      type: 'Weather',
      message: 'T078 R000 P000 H55 B10152',
    ),
    _AprsEntry(
      time: '14:22:30',
      from: 'KE5ABC-9',
      to: 'W1AW-9',
      type: 'Message',
      message: 'Are you on the net tonight?',
    ),
  ];

  @override
  void dispose() {
    _destinationController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _buildHeader(colors),
        if (_showWarning) _buildWarningBanner(colors),
        Expanded(
          child: _buildDataTable(colors),
        ),
        _buildTransmitBar(colors),
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
            'APRS DASHBOARD',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'N0CALL',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 28,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _showAll,
                  onChanged: (v) => setState(() => _showAll = v ?? false),
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
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
          Text(
            '${_entries.length} MESSAGES',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

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
            onPressed: () => setState(() => _showWarning = false),
          ),
        ],
      ),
    );
  }

  Widget _buildDataTable(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                'PACKET LOG',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: DataTable(
                    headingRowHeight: 32,
                    dataRowMinHeight: 28,
                    dataRowMaxHeight: 32,
                    columnSpacing: 24,
                    horizontalMargin: 16,
                    headingTextStyle: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                      color: colors.onSurfaceVariant,
                    ),
                    dataTextStyle: TextStyle(
                      fontSize: 11,
                      color: colors.onSurface,
                    ),
                    columns: const [
                      DataColumn(label: Text('TIME')),
                      DataColumn(label: Text('FROM')),
                      DataColumn(label: Text('TO')),
                      DataColumn(label: Text('TYPE')),
                      DataColumn(label: Text('MESSAGE')),
                    ],
                    rows: _entries.map((entry) {
                      return DataRow(cells: [
                        DataCell(Text(entry.time)),
                        DataCell(Text(
                          entry.from,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        )),
                        DataCell(Text(entry.to)),
                        DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _typeColor(entry.type).withAlpha(25),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              entry.type,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: _typeColor(entry.type),
                              ),
                            ),
                          ),
                        ),
                        DataCell(Text(entry.message)),
                      ]);
                    }).toList(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'Position':
        return Colors.blue;
      case 'Status':
        return Colors.green;
      case 'Weather':
        return Colors.orange;
      case 'Bulletin':
        return Colors.purple;
      case 'Message':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  Widget _buildTransmitBar(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: colors.surfaceContainerLow,
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
              onPressed: () {},
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

class _AprsEntry {
  const _AprsEntry({
    required this.time,
    required this.from,
    required this.to,
    required this.type,
    required this.message,
  });

  final String time;
  final String from;
  final String to;
  final String type;
  final String message;
}
