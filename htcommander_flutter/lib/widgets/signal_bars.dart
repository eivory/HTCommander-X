import 'package:flutter/material.dart';

/// Segmented signal strength bars (RSSI / TX).
class SignalBars extends StatelessWidget {
  const SignalBars({
    super.key,
    required this.level,
    this.maxLevel = 16,
    this.barCount = 8,
    this.isTransmitting = false,
    this.height = 20,
  });

  final int level;
  final int maxLevel;
  final int barCount;
  final bool isTransmitting;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activeColor = isTransmitting ? colors.error : colors.primary;
    final filledBars = (level / maxLevel * barCount).ceil().clamp(0, barCount);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(barCount, (i) {
        final isFilled = i < filledBars;
        final barHeight = height * (0.3 + 0.7 * (i + 1) / barCount);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Container(
            width: 4,
            height: barHeight,
            decoration: BoxDecoration(
              color: isFilled ? activeColor : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      }),
    );
  }
}
