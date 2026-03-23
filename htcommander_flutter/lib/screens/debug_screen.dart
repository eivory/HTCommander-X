import 'package:flutter/material.dart';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  bool _showBtFrames = false;
  bool _showLoopback = false;
  final ScrollController _scrollController = ScrollController();

  // Placeholder debug log
  final String _debugLog = '''[14:32:15.123] Radio connected: VR-N76 (00:11:22:33:44:55)
[14:32:15.145] GAIA TX: FF 01 00 04 00 03 00 01
[14:32:15.198] GAIA RX: FF 01 80 0C 00 03 00 01 56 52 2D 4E 37 36 00 00
[14:32:15.201] Device info received: VR-N76, FW 2.01
[14:32:15.250] GAIA TX: FF 01 00 04 00 02 00 02
[14:32:15.312] GAIA RX: FF 01 80 20 00 02 00 02 ...
[14:32:15.315] Settings received: volume=8, squelch=3, vfo_a=ch0
[14:32:15.400] GAIA TX: FF 01 00 04 00 02 00 10
[14:32:15.468] GAIA RX: FF 01 80 08 00 02 00 10 00 00 00 05
[14:32:15.470] HT Status: RSSI=5, TX=0
[14:32:16.012] Audio transport connected on RFCOMM channel 2
[14:32:16.050] SBC decoder initialized: 32kHz, mono, 8 subbands
[14:32:18.105] GAIA TX: FF 01 00 04 00 02 00 03
[14:32:18.172] GAIA RX: FF 01 80 40 00 02 00 03 ...
[14:32:18.175] Channel list received: 128 channels
[14:32:20.300] GPS position update: 41.7147N, 72.7272W
[14:32:25.500] RSSI update: level=7
[14:32:30.501] RSSI update: level=6
[14:32:35.502] RSSI update: level=8''';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _buildHeader(colors),
        Expanded(
          child: _buildLogArea(colors),
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
            'DEBUG CONSOLE',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 28,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _showBtFrames,
                  onChanged: (v) =>
                      setState(() => _showBtFrames = v ?? false),
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
                Text(
                  'BT FRAMES',
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
          const SizedBox(width: 12),
          SizedBox(
            height: 28,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _showLoopback,
                  onChanged: (v) =>
                      setState(() => _showLoopback = v ?? false),
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
                Text(
                  'LOOPBACK',
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
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.delete_outline, size: 14),
            label: const Text('CLEAR'),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
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
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.save_outlined, size: 14),
            label: const Text('SAVE'),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
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
    );
  }

  Widget _buildLogArea(ColorScheme colors) {
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.outlineVariant.withAlpha(60),
        ),
      ),
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            _debugLog,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: colors.onSurface,
              height: 1.6,
            ),
          ),
        ),
      ),
    );
  }
}
