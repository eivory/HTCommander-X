import 'package:data_table_2/data_table_2.dart';
import 'package:flutter/material.dart';
import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../handlers/packet_store.dart';
import '../radio/ax25/ax25_packet.dart';
import '../widgets/glass_card.dart';
import '../widgets/status_strip.dart';

class PacketsScreen extends StatefulWidget {
  const PacketsScreen({super.key});

  @override
  State<PacketsScreen> createState() => _PacketsScreenState();
}

class _PacketsScreenState extends State<PacketsScreen> {
  final DataBrokerClient _broker = DataBrokerClient();
  List<AX25Packet> _packets = [];
  int? _selectedIndex;

  @override
  void initState() {
    super.initState();
    _broker.subscribe(1, 'PacketStoreUpdated', _onPacketStoreUpdated);
    _loadPackets();
  }

  void _loadPackets() {
    final store = DataBroker.getDataHandlerTyped<PacketStore>('PacketStore');
    if (store != null) {
      setState(() => _packets = store.packets);
    }
  }

  void _onPacketStoreUpdated(int deviceId, String name, Object? data) {
    _loadPackets();
  }

  @override
  void dispose() {
    _broker.dispose();
    super.dispose();
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  String _getFrameTypeName(AX25Packet p) {
    if (p.type == FrameType.iFrame) return 'I';
    if (p.type == FrameType.uFrameUI) return 'UI';
    if (p.type == FrameType.uFrameSABM) return 'SABM';
    if (p.type == FrameType.uFrameSABME) return 'SABME';
    if (p.type == FrameType.uFrameDISC) return 'DISC';
    if (p.type == FrameType.uFrameDM) return 'DM';
    if (p.type == FrameType.uFrameUA) return 'UA';
    if (p.type == FrameType.uFrameFRMR) return 'FRMR';
    if (p.type == FrameType.uFrameXID) return 'XID';
    if (p.type == FrameType.uFrameTEST) return 'TEST';
    if ((p.type & FrameType.uFrame) == FrameType.sFrame) {
      if (p.type == FrameType.sFrameRR) return 'RR';
      if (p.type == FrameType.sFrameRNR) return 'RNR';
      if (p.type == FrameType.sFrameREJ) return 'REJ';
      if (p.type == FrameType.sFrameSREJ) return 'SREJ';
      return 'S';
    }
    return 'U';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: AX.25 Packet Stream
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildStreamHeader(colors),
                      const SizedBox(height: 10),
                      Expanded(child: _buildPacketTable(colors)),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Right: Packet Decode
                Expanded(
                  flex: 2,
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
                      const SizedBox(height: 10),
                      Expanded(child: _buildDecodePanel(colors)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        StatusStrip(
          isConnected: _packets.isNotEmpty,
          encoding: 'AX.25',
          extraItems: [
            StatusStripItem(text: '${_packets.length} PACKETS'),
          ],
        ),
      ],
    );
  }

  Widget _buildStreamHeader(ColorScheme colors) {
    return Row(
      children: [
        Text(
          'AX.25 PACKET STREAM',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: colors.primary.withAlpha(25),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${_packets.length} PACKETS',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: colors.primary,
              letterSpacing: 1,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPacketTable(ColorScheme colors) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: _packets.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.settings_input_antenna, size: 28, color: colors.outline),
                  const SizedBox(height: 8),
                  Text(
                    'No packets received',
                    style: TextStyle(fontSize: 11, color: colors.outline),
                  ),
                ],
              ),
            )
          : DataTable2(
                  // fixedTopRows: 1 keeps the header row pinned while
                  // the body scrolls vertically. Horizontal overflow
                  // is handled internally by the package.
                  fixedTopRows: 1,
                  // Hide the leading checkbox column. Row-tap selection
                  // still works via onSelectChanged.
                  showCheckboxColumn: false,
                  headingRowHeight: 32,
                  dataRowHeight: 32,
                  columnSpacing: 16,
                  horizontalMargin: 14,
                  minWidth: 600,
                  headingTextStyle: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                  dataTextStyle: TextStyle(fontSize: 11, color: colors.onSurface),
                  columns: const [
                    DataColumn2(label: Text('TIMESTAMP'), fixedWidth: 80),
                    DataColumn2(label: Text('SOURCE > DEST'), fixedWidth: 100),
                    DataColumn2(label: Text('TYPE'), fixedWidth: 40),
                    DataColumn2(label: Text('PAYLOAD DATA'), size: ColumnSize.L),
                  ],
                  // Newest first.
                  rows: List.generate(_packets.length, (k) {
                    final i = _packets.length - 1 - k;
                    final p = _packets[i];
                    final selected = _selectedIndex == i;
                    final from = p.addresses.length > 1
                        ? p.addresses[1].toString()
                        : '?';
                    final to = p.addresses.isNotEmpty
                        ? p.addresses[0].toString()
                        : '?';
                    return DataRow(
                      selected: selected,
                      color: selected
                          ? WidgetStateProperty.all(colors.primary.withAlpha(30))
                          : null,
                      onSelectChanged: (_) {
                        setState(() => _selectedIndex = i);
                      },
                      cells: [
                        DataCell(Text(_formatTime(p.time),
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: colors.onSurfaceVariant,
                            ))),
                        DataCell(Text('$from > $to',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                            ))),
                        DataCell(Text(_getFrameTypeName(p))),
                        DataCell(Text(
                          p.dataStr ?? '',
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: colors.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        )),
                      ],
                    );
                  }),
                ),
    );
  }

  Widget _buildDecodePanel(ColorScheme colors) {
    final packet = _selectedIndex != null && _selectedIndex! < _packets.length
        ? _packets[_selectedIndex!]
        : null;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                        style: TextStyle(fontSize: 11, color: colors.outline),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        'From: ${packet.addresses.length > 1 ? packet.addresses[1].toString() : ''}\n'
                        'To: ${packet.addresses.isNotEmpty ? packet.addresses[0].toString() : ''}\n'
                        'Type: ${_getFrameTypeName(packet)}\n'
                        'Channel: ${packet.channelName}\n'
                        'Data: ${packet.dataStr ?? ''}',
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
}
