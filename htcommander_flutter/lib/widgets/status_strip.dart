import 'package:flutter/material.dart';

/// Reusable 28px status footer bar showing key metrics.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    this.isConnected = false,
    this.encoding = 'AX.25',
    this.extraItems = const [],
  });

  final bool isConnected;
  final String encoding;
  final List<StatusStripItem> extraItems;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: colors.surfaceContainerLow,
      child: Row(
        children: [
          // The flag here is "BT link to radio is up" — it does NOT
          // mean we are receiving anything over the air. Past wording
          // ("RX LINK STABLE") implied the latter and was misleading
          // on the APRS pane in particular.
          _StatusLabel(
            text: isConnected ? 'RADIO ONLINE' : 'OFFLINE',
            color: isConnected ? colors.tertiary : colors.error,
          ),
          _separator(colors),
          _StatusLabel(text: encoding, color: colors.onSurfaceVariant),
          for (final item in extraItems) ...[
            _separator(colors),
            _StatusLabel(text: item.text, color: item.color ?? colors.onSurfaceVariant),
          ],
          const Spacer(),
          _StatusLabel(
            text: 'DATA STREAM ACTIVE',
            color: isConnected ? colors.onSurfaceVariant : colors.outline,
          ),
        ],
      ),
    );
  }

  Widget _separator(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '|',
        style: TextStyle(fontSize: 9, color: colors.outline),
      ),
    );
  }
}

class StatusStripItem {
  const StatusStripItem({required this.text, this.color});
  final String text;
  final Color? color;
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 1,
      ),
    );
  }
}
