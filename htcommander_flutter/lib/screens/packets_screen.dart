import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class PacketsScreen extends StatefulWidget {
  const PacketsScreen({super.key});

  @override
  State<PacketsScreen> createState() => _PacketsScreenState();
}

class _PacketsScreenState extends State<PacketsScreen> {
  // Placeholder data — will be wired to DataBroker later
  final List<_PacketEntry> _packets = [];
  int? _selectedIndex;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _buildHeader(colors),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildPacketTable(colors),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 180,
                  child: _buildDecodePanel(colors),
                ),
              ],
            ),
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
            'AX.25 PACKET STREAM',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_packets.length} packets',
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildPacketTable(ColorScheme colors) {
    return GlassCard(
      padding: const EdgeInsets.all(0),
      child: _packets.isEmpty
          ? Center(
              child: Text(
                'No packets received',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.outline,
                ),
              ),
            )
          : SingleChildScrollView(
              child: SizedBox(
                width: double.infinity,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 32,
                  columnSpacing: 20,
                  horizontalMargin: 14,
                  headingRowColor: WidgetStateProperty.all(
                    colors.surfaceContainerHigh,
                  ),
                  columns: [
                    DataColumn(
                      label:
                          Text('TIME', style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label:
                          Text('FROM', style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label:
                          Text('TO', style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label:
                          Text('TYPE', style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label: Text('CHANNEL',
                          style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label:
                          Text('DATA', style: _columnHeaderStyle(colors)),
                    ),
                  ],
                  rows: List.generate(_packets.length, (i) {
                    final p = _packets[i];
                    final selected = _selectedIndex == i;
                    return DataRow(
                      selected: selected,
                      color: selected
                          ? WidgetStateProperty.all(
                              colors.primary.withAlpha(30),
                            )
                          : null,
                      onSelectChanged: (_) {
                        setState(() => _selectedIndex = i);
                      },
                      cells: [
                        DataCell(
                            Text(p.time, style: _cellStyle(colors))),
                        DataCell(
                            Text(p.from, style: _cellStyle(colors))),
                        DataCell(Text(p.to, style: _cellStyle(colors))),
                        DataCell(
                            Text(p.type, style: _cellStyle(colors))),
                        DataCell(Text(p.channel,
                            style: _cellStyle(colors))),
                        DataCell(Text(
                          p.dataHex,
                          style: _cellMonoStyle(colors),
                          overflow: TextOverflow.ellipsis,
                        )),
                      ],
                    );
                  }),
                ),
              ),
            ),
    );
  }

  Widget _buildDecodePanel(ColorScheme colors) {
    final packet =
        _selectedIndex != null ? _packets[_selectedIndex!] : null;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PACKET DECODE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
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
              child: packet == null
                  ? Center(
                      child: Text(
                        'Select a packet to view decode',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.outline,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Text(
                        'From: ${packet.from}\n'
                        'To: ${packet.to}\n'
                        'Type: ${packet.type}\n'
                        'Channel: ${packet.channel}\n'
                        'Data: ${packet.dataHex}',
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

  TextStyle _columnHeaderStyle(ColorScheme colors) {
    return TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
      color: colors.onSurfaceVariant,
    );
  }

  TextStyle _cellStyle(ColorScheme colors) {
    return TextStyle(
      fontSize: 12,
      color: colors.onSurface,
    );
  }

  TextStyle _cellMonoStyle(ColorScheme colors) {
    return TextStyle(
      fontSize: 11,
      fontFamily: 'monospace',
      color: colors.onSurface,
    );
  }
}

class _PacketEntry {
  final String time;
  final String from;
  final String to;
  final String type;
  final String channel;
  final String dataHex;

  const _PacketEntry({
    required this.time,
    required this.from,
    required this.to,
    required this.type,
    required this.channel,
    required this.dataHex,
  });
}
