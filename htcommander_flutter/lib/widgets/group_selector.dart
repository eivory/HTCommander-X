import 'package:flutter/material.dart';

/// Six-segment channel-group selector. The Benshi radios expose six
/// channel groups (regions, in protocol terminology), each holding 30
/// channel slots. Switching the active group causes the radio to
/// re-read its channel list — so this widget just calls back, the
/// channels list refresh happens via the broker.
class GroupSelector extends StatelessWidget {
  const GroupSelector({
    super.key,
    required this.activeRegion,
    required this.onChanged,
    this.enabled = true,
    this.accentColor,
  });

  /// 0-based active region (0..5). -1 if unknown / not connected.
  final int activeRegion;

  /// Called with the 0-based region the user tapped. Already filtered
  /// to skip taps on the already-active group.
  final ValueChanged<int> onChanged;

  /// False when the radio isn't connected — segments render dimmed
  /// and don't fire callbacks.
  final bool enabled;

  /// Optional override for the active-segment highlight. Defaults to
  /// the theme's primary color. Pass colors.tertiary when this lives
  /// inside a VFO B-themed picker, etc.
  final Color? accentColor;

  static const int _groupCount = 6;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = accentColor ?? colors.primary;
    return Row(
      children: List.generate(_groupCount, (i) {
        final isActive = i == activeRegion;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i == _groupCount - 1 ? 0 : 4),
            child: _segment(colors, accent, i + 1, isActive, () {
              if (!enabled || isActive) return;
              onChanged(i);
            }),
          ),
        );
      }),
    );
  }

  Widget _segment(ColorScheme colors, Color accent, int displayNumber,
      bool isActive, VoidCallback onTap) {
    final fg = !enabled
        ? colors.onSurfaceVariant.withAlpha(80)
        : isActive
            ? accent
            : colors.onSurfaceVariant;
    final bg = isActive
        ? accent.withAlpha(30)
        : colors.surfaceContainerHigh;
    final border = isActive
        ? accent.withAlpha(120)
        : colors.outlineVariant;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 26,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: border, width: 1),
          ),
          alignment: Alignment.center,
          child: Text(
            '$displayNumber',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
