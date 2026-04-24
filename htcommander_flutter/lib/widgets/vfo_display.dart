import 'package:flutter/material.dart';

/// VFO frequency display widget — large monospace numbers.
/// VFO A = primary (cyan), VFO B = tertiary (green).
class VfoDisplay extends StatelessWidget {
  const VfoDisplay({
    super.key,
    required this.label,
    required this.frequency,
    this.channelName,
    this.modulation,
    this.isActive = false,
    this.isPrimary = true,
    this.onTap,
    this.onLongPress,
    this.onActivate,
  });

  final String label;
  final double frequency; // in MHz
  final String? channelName;
  final String? modulation;
  final bool isActive;
  final bool isPrimary;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accentColor = isPrimary ? colors.primary : colors.tertiary;

    final card = Container(
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
              const SizedBox(width: 8),
              // Active-VFO dot. Filled = this VFO is the active TX/RX
              // target. Tap (when inactive) to make this one active.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: isActive ? null : onActivate,
                child: Tooltip(
                  message: isActive ? 'Active' : 'Tap to activate',
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive ? accentColor : Colors.transparent,
                      border: Border.all(color: accentColor, width: 1.2),
                    ),
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
              shadows: [
                Shadow(
                  color: accentColor.withAlpha(40),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                'MHz',
                style: TextStyle(
                  fontSize: 10,
                  color: colors.onSurfaceVariant,
                  letterSpacing: 1,
                ),
              ),
              if (modulation != null) ...[
                const SizedBox(width: 8),
                Text(
                  modulation!,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    if (onTap == null && onLongPress == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: card,
      ),
    );
  }

  String _formatFreq(double mhz) {
    return mhz.toStringAsFixed(4).padLeft(9);
  }
}
