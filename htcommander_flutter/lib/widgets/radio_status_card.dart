import 'package:flutter/material.dart';
import 'signal_bars.dart';

/// Compact radio status card showing connection state, signal, battery.
class RadioStatusCard extends StatelessWidget {
  const RadioStatusCard({
    super.key,
    this.deviceName,
    this.isConnected = false,
    this.rssi = 0,
    this.isTransmitting = false,
    this.batteryPercent = 0,
    this.isGpsLocked = false,
  });

  final String? deviceName;
  final bool isConnected;
  final int rssi;
  final bool isTransmitting;
  final int batteryPercent;
  final bool isGpsLocked;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row
          Row(
            children: [
              Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                size: 16,
                color: isConnected ? colors.primary : colors.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  deviceName ?? 'No Radio',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isConnected
                      ? colors.primary.withAlpha(30)
                      : colors.error.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isConnected ? 'ONLINE' : 'OFFLINE',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: isConnected ? colors.primary : colors.error,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),

          if (isConnected) ...[
            const SizedBox(height: 10),
            // Status row
            Row(
              children: [
                // Signal
                _StatusItem(
                  label: isTransmitting ? 'TX' : 'RSSI',
                  child: SignalBars(
                    level: rssi,
                    isTransmitting: isTransmitting,
                    height: 16,
                  ),
                ),
                const SizedBox(width: 16),
                // Battery
                _StatusItem(
                  label: 'BATTERY',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _batteryIcon(batteryPercent),
                        size: 16,
                        color: batteryPercent > 20
                            ? colors.tertiary
                            : colors.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$batteryPercent%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // GPS
                _StatusItem(
                  label: 'GPS',
                  child: Icon(
                    isGpsLocked ? Icons.gps_fixed : Icons.gps_off,
                    size: 16,
                    color: isGpsLocked ? colors.tertiary : colors.outline,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _batteryIcon(int percent) {
    if (percent > 80) return Icons.battery_full;
    if (percent > 60) return Icons.battery_5_bar;
    if (percent > 40) return Icons.battery_3_bar;
    if (percent > 20) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }
}

class _StatusItem extends StatelessWidget {
  const _StatusItem({required this.label, required this.child});

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
