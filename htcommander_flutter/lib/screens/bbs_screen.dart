import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class BbsScreen extends StatefulWidget {
  const BbsScreen({super.key});

  @override
  State<BbsScreen> createState() => _BbsScreenState();
}

class _BbsScreenState extends State<BbsScreen> {
  final ScrollController _trafficScrollController = ScrollController();

  // Placeholder state — will be wired to DataBroker later
  final bool _isActive = false;
  bool _viewTraffic = false;
  final List<_BbsNodeEntry> _nodes = [];
  final List<String> _trafficLog = [];
  int? _selectedIndex;

  @override
  void dispose() {
    _trafficScrollController.dispose();
    super.dispose();
  }

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
                  child: _buildNodeTable(colors),
                ),
                if (_viewTraffic) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 150,
                    child: _buildTrafficLog(colors),
                  ),
                ],
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
            'BBS BOARD',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _isActive
                  ? Colors.green.withAlpha(40)
                  : colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _isActive ? 'ACTIVE' : 'INACTIVE',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: _isActive
                    ? Colors.green.shade300
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          // View Traffic checkbox
          SizedBox(
            height: 30,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    value: _viewTraffic,
                    onChanged: (v) =>
                        setState(() => _viewTraffic = v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'View Traffic',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _HeaderButton(
            label: 'Activate',
            onPressed: !_isActive ? () {} : null,
          ),
        ],
      ),
    );
  }

  Widget _buildNodeTable(ColorScheme colors) {
    return GlassCard(
      padding: const EdgeInsets.all(0),
      child: _nodes.isEmpty
          ? Center(
              child: Text(
                'No BBS nodes discovered',
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
                  columnSpacing: 24,
                  horizontalMargin: 14,
                  headingRowColor: WidgetStateProperty.all(
                    colors.surfaceContainerHigh,
                  ),
                  columns: [
                    DataColumn(
                      label: Text('CALL SIGN',
                          style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label: Text('LAST SEEN',
                          style: _columnHeaderStyle(colors)),
                    ),
                    DataColumn(
                      label: Text('PACKETS IN',
                          style: _columnHeaderStyle(colors)),
                      numeric: true,
                    ),
                    DataColumn(
                      label: Text('PACKETS OUT',
                          style: _columnHeaderStyle(colors)),
                      numeric: true,
                    ),
                    DataColumn(
                      label: Text('BYTES IN',
                          style: _columnHeaderStyle(colors)),
                      numeric: true,
                    ),
                    DataColumn(
                      label: Text('BYTES OUT',
                          style: _columnHeaderStyle(colors)),
                      numeric: true,
                    ),
                  ],
                  rows: List.generate(_nodes.length, (i) {
                    final n = _nodes[i];
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
                        DataCell(Text(n.callSign,
                            style: _cellStyle(colors))),
                        DataCell(Text(n.lastSeen,
                            style: _cellStyle(colors))),
                        DataCell(Text('${n.packetsIn}',
                            style: _cellStyle(colors))),
                        DataCell(Text('${n.packetsOut}',
                            style: _cellStyle(colors))),
                        DataCell(Text('${n.bytesIn}',
                            style: _cellStyle(colors))),
                        DataCell(Text('${n.bytesOut}',
                            style: _cellStyle(colors))),
                      ],
                    );
                  }),
                ),
              ),
            ),
    );
  }

  Widget _buildTrafficLog(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TRAFFIC LOG',
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
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(6),
              ),
              child: _trafficLog.isEmpty
                  ? Center(
                      child: Text(
                        'No traffic',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.outline,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _trafficScrollController,
                      child: SelectableText(
                        _trafficLog.join('\n'),
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: colors.onSurface,
                          height: 1.4,
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
}

class _BbsNodeEntry {
  final String callSign;
  final String lastSeen;
  final int packetsIn;
  final int packetsOut;
  final int bytesIn;
  final int bytesOut;

  const _BbsNodeEntry({
    required this.callSign,
    required this.lastSeen,
    required this.packetsIn,
    required this.packetsOut,
    required this.bytesIn,
    required this.bytesOut,
  });
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}
