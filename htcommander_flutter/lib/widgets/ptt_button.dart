import 'package:flutter/material.dart';

/// Large PTT (Push-To-Talk) button with press-and-hold interaction.
class PttButton extends StatefulWidget {
  const PttButton({
    super.key,
    this.onPttStart,
    this.onPttStop,
    this.isEnabled = false,
    this.isTransmitting = false,
    this.size = 64,
  });

  final VoidCallback? onPttStart;
  final VoidCallback? onPttStop;
  final bool isEnabled;
  final bool isTransmitting;
  final double size;

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isActive = widget.isTransmitting || _pressed;

    return GestureDetector(
      onTapDown: widget.isEnabled
          ? (_) {
              setState(() => _pressed = true);
              widget.onPttStart?.call();
            }
          : null,
      onTapUp: widget.isEnabled
          ? (_) {
              setState(() => _pressed = false);
              widget.onPttStop?.call();
            }
          : null,
      onTapCancel: widget.isEnabled
          ? () {
              setState(() => _pressed = false);
              widget.onPttStop?.call();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive
              ? const Color(0xFFC62828)
              : widget.isEnabled
                  ? colors.primary
                  : colors.surfaceContainerHighest,
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: const Color(0xFFC62828).withAlpha(100),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            'PTT',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
              color: isActive || widget.isEnabled
                  ? colors.onPrimary
                  : colors.outline,
            ),
          ),
        ),
      ),
    );
  }
}
