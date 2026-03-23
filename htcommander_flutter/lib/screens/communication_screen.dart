import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';
import '../widgets/vfo_display.dart';
import '../widgets/signal_bars.dart';
import '../widgets/radio_status_card.dart';
import '../widgets/ptt_button.dart';

/// Communication Hub — the flagship screen.
/// Layout: Radio panel (left) + two-column content (right).
class CommunicationScreen extends StatefulWidget {
  const CommunicationScreen({super.key});

  @override
  State<CommunicationScreen> createState() => _CommunicationScreenState();
}

class _CommunicationScreenState extends State<CommunicationScreen> {
  final TextEditingController _inputController = TextEditingController();
  String _selectedMode = 'Chat';
  bool _isMuted = false;

  // Placeholder state — will be wired to DataBroker in integration
  final bool _isConnected = false;
  final String? _deviceName = null;
  final int _rssi = 0;
  final bool _isTransmitting = false;
  final int _batteryPercent = 0;
  final bool _isGpsLocked = false;
  final double _vfoAFreq = 0;
  final double _vfoBFreq = 0;
  final String _vfoAName = '';
  final String _vfoBName = '';
  final List<String> _messages = [];

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Header bar
        _buildHeader(colors),
        // Main content
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Radio panel (left side)
              SizedBox(
                width: 280,
                child: _buildRadioPanel(colors),
              ),
              // Content area (right side, two columns)
              Expanded(
                child: _buildContentArea(colors),
              ),
            ],
          ),
        ),
        // Bottom input bar
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
            'Communication',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _isConnected ? 'Connected' : 'Idle',
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          // Send SSTV button
          _HeaderButton(
            label: 'Send SSTV',
            onPressed: _isConnected ? () {} : null,
          ),
          const SizedBox(width: 6),
          // Mute toggle
          _HeaderToggle(
            label: 'Mute',
            isActive: _isMuted,
            onPressed: () => setState(() => _isMuted = !_isMuted),
          ),
          const SizedBox(width: 6),
          // Mode selector
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: DropdownButton<String>(
              value: _selectedMode,
              underline: const SizedBox(),
              isDense: true,
              dropdownColor: colors.surfaceContainerHigh,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              items: ['Chat', 'Speak', 'Morse', 'DTMF']
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedMode = v!),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadioPanel(ColorScheme colors) {
    return Container(
      color: colors.surfaceContainerLow,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Radio status card
            RadioStatusCard(
              deviceName: _deviceName,
              isConnected: _isConnected,
              rssi: _rssi,
              isTransmitting: _isTransmitting,
              batteryPercent: _batteryPercent,
              isGpsLocked: _isGpsLocked,
            ),
            const SizedBox(height: 12),

            // VFO A
            VfoDisplay(
              label: 'VFO A',
              frequency: _vfoAFreq,
              channelName: _vfoAName,
              isActive: true,
              isPrimary: true,
            ),
            const SizedBox(height: 8),

            // VFO B
            VfoDisplay(
              label: 'VFO B',
              frequency: _vfoBFreq,
              channelName: _vfoBName,
              isActive: false,
              isPrimary: false,
            ),
            const SizedBox(height: 16),

            // PTT Button
            Center(
              child: PttButton(
                isEnabled: _isConnected,
                isTransmitting: _isTransmitting,
                size: 72,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isTransmitting ? 'TRANSMITTING' : 'PRESS TO TALK',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: _isTransmitting ? colors.error : colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // RSSI / TX bars
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  _MiniStatus(
                    label: 'RSSI',
                    child: SignalBars(level: _rssi, height: 14),
                  ),
                  const SizedBox(width: 16),
                  _MiniStatus(
                    label: 'TX',
                    child: SignalBars(
                      level: _isTransmitting ? 12 : 0,
                      isTransmitting: true,
                      height: 14,
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

  Widget _buildContentArea(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column: Local Packet Node / SSTV
          Expanded(
            child: _buildPacketNodeCard(colors),
          ),
          const SizedBox(width: 14),
          // Right column: Operation log
          Expanded(
            child: _buildOperationLog(colors),
          ),
        ],
      ),
    );
  }

  Widget _buildPacketNodeCard(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LOCAL PACKET NODE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          // SSTV / Data Link placeholder
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'SSTV / DATA LINK',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Waiting for incoming data...',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Status / Protocol row
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STATUS',
                      style: TextStyle(
                        fontSize: 9,
                        color: colors.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Standby',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PROTOCOL',
                      style: TextStyle(
                        fontSize: 9,
                        color: colors.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'AX.25',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOperationLog(ColorScheme colors) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'OPERATION',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.outline,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _messages.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _messages[index],
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurface,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
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
              style: TextStyle(fontSize: 12, color: colors.onSurface),
              decoration: InputDecoration(
                hintText: 'Type message...',
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
              onSubmitted: _isConnected ? (_) => _sendMessage() : null,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _isConnected ? _sendMessage : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('Transmit'),
          ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: _isConnected ? () {} : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: const Text('Record'),
          ),
        ],
      ),
    );
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(text);
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

class _HeaderToggle extends StatelessWidget {
  const _HeaderToggle({
    required this.label,
    required this.isActive,
    this.onPressed,
  });
  final String label;
  final bool isActive;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        backgroundColor: isActive ? colors.primaryContainer : null,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}

class _MiniStatus extends StatelessWidget {
  const _MiniStatus({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: colors.onSurfaceVariant,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
