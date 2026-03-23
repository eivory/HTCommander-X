import 'package:flutter/material.dart';

/// VFO frequency display widget — large monospace numbers.
/// VFO A = primary (cyan), VFO B = tertiary (green).
class VfoDisplay extends StatelessWidget {
  const VfoDisplay({
    super.key,
    required this.label,
    required this.frequency,
    this.channelName,
    this.isActive = false,
    this.isPrimary = true,
  });

  final String label;
  final double frequency; // in MHz
  final String? channelName;
  final bool isActive;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accentColor = isPrimary ? colors.primary : colors.tertiary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: isActive
            ? Border.all(color: accentColor.withAlpha(80), width: 1)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accentColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: accentColor,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const Spacer(),
              if (channelName != null && channelName!.isNotEmpty)
                Text(
                  channelName!,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            frequency > 0 ? _formatFreq(frequency) : '----.----',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: accentColor,
              letterSpacing: 1,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'MHz',
            style: TextStyle(
              fontSize: 10,
              color: colors.onSurfaceVariant,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  String _formatFreq(double mhz) {
    return mhz.toStringAsFixed(4).padLeft(9);
  }
}
