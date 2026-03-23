import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Placeholder state — will be wired to DataBroker later
  final bool _isConnected = false;
  final List<String> _outputLines = [];
  final List<String> _stations = [];
  String? _selectedStation;

  @override
  void dispose() {
    _inputController.dispose();
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
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _buildTerminalArea(colors),
          ),
        ),
        _buildInputBar(colors),
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
            'SYSTEM TERMINAL',
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
              color: _isConnected
                  ? Colors.green.withAlpha(40)
                  : colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _isConnected ? 'CONNECTED' : 'IDLE',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: _isConnected
                    ? Colors.green.shade300
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          // Station selector
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: DropdownButton<String>(
              value: _selectedStation,
              hint: Text(
                'Station',
                style: TextStyle(fontSize: 11, color: colors.outline),
              ),
              underline: const SizedBox(),
              isDense: true,
              dropdownColor: colors.surfaceContainerHigh,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              items: _stations
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedStation = v),
            ),
          ),
          const SizedBox(width: 6),
          _HeaderButton(
            label: 'Connect',
            onPressed: !_isConnected ? () {} : null,
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalArea(ColorScheme colors) {
    return GlassCard(
      padding: const EdgeInsets.all(0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _outputLines.isEmpty
            ? Center(
                child: Text(
                  'Terminal ready',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: colors.onSurfaceVariant,
                  ),
                ),
              )
            : SingleChildScrollView(
                controller: _scrollController,
                child: SelectableText(
                  _outputLines.join('\n'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Color(0xFFE6EDF3),
                    height: 1.5,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: colors.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: colors.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'Enter command...',
                hintStyle: TextStyle(fontSize: 12, color: colors.outline),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              onSubmitted: _isConnected ? (_) => _transmit() : null,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _isConnected ? _transmit : null,
            style: FilledButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('TRANSMIT'),
          ),
        ],
      ),
    );
  }

  void _transmit() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _outputLines.add('> $text');
      _inputController.clear();
    });
  }
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
