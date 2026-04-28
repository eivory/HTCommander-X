import 'package:flutter/material.dart';
import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../radio/models/radio_channel_info.dart';
import '../radio/models/radio_ht_status.dart';
import '../widgets/group_selector.dart';

/// Result returned when the user picks a channel in [ChannelPickerDialog].
///
/// One of the two fields is non-null depending on which action the user
/// took — a short tap picks, a long press asks to edit.
class ChannelPickerResult {
  final int? pickIndex;
  final int? editIndex;
  const ChannelPickerResult.pick(int this.pickIndex) : editIndex = null;
  const ChannelPickerResult.edit(int this.editIndex) : pickIndex = null;
}

/// Dialog for selecting a channel from the radio's channel list.
///
/// Subscribes to the broker so that switching channel groups (regions)
/// live-refreshes the visible channels — the radio re-reads its 30
/// channel slots whenever the active region changes.
class ChannelPickerDialog extends StatefulWidget {
  /// Initial channels list. The dialog also subscribes to broker
  /// updates so this list stays fresh after a group switch.
  final List<RadioChannelInfo?> channels;

  /// Dialog title (e.g., "VFO A Channel").
  final String title;

  /// Called when the user picks a different channel group. Pass
  /// through to `Radio.setRegion(int)` — the channel list will
  /// refresh on its own once HtStatus + Channels broker events
  /// arrive.
  final ValueChanged<int>? onGroupChange;

  const ChannelPickerDialog({
    super.key,
    required this.channels,
    required this.title,
    required this.isVfoA,
    this.onGroupChange,
  });

  /// True when the picker is selecting for VFO A (cyan/primary theme),
  /// false for VFO B (green/tertiary theme). Drives the accent color
  /// throughout the dialog so the user sees at a glance which slot
  /// they're picking for.
  final bool isVfoA;

  @override
  State<ChannelPickerDialog> createState() => _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends State<ChannelPickerDialog> {
  late final DataBrokerClient _broker;
  late List<RadioChannelInfo?> _channels;
  int _activeRegion = -1;

  @override
  void initState() {
    super.initState();
    _broker = DataBrokerClient();
    _channels = widget.channels;
    final ht = DataBroker.getValueDynamic(100, 'HtStatus');
    if (ht is RadioHtStatus) _activeRegion = ht.currRegion;
    _broker.subscribe(100, 'Channels', _onChannels);
    _broker.subscribe(100, 'HtStatus', _onHtStatus);
  }

  @override
  void dispose() {
    _broker.dispose();
    super.dispose();
  }

  void _onChannels(int deviceId, String name, Object? data) {
    if (!mounted || data is! List) return;
    setState(() => _channels = data.cast<RadioChannelInfo?>());
  }

  void _onHtStatus(int deviceId, String name, Object? data) {
    if (!mounted || data is! RadioHtStatus) return;
    setState(() => _activeRegion = data.currRegion);
  }

  Widget _channelCell(ColorScheme colors, Color accent, int index) {
    final ch = _channels[index];
    final isEmpty =
        ch == null || (ch.rxFreq == 0 && ch.nameStr.isEmpty);
    final freqMhz = ch != null && ch.rxFreq > 0
        ? (ch.rxFreq / 1000000).toStringAsFixed(4)
        : '---';
    final name = ch != null && ch.nameStr.isNotEmpty ? ch.nameStr : '';
    final dimColor = colors.onSurfaceVariant.withAlpha(102);
    return _gridCell(
      colors,
      accent: accent,
      cornerLabel: '${index + 1}',
      title: name.isNotEmpty
          ? name
          : (isEmpty ? 'Empty' : 'CH ${index + 1}'),
      subtitle: isEmpty ? '---' : freqMhz,
      titleColor: isEmpty ? dimColor : colors.onSurface,
      subtitleColor: isEmpty ? dimColor : accent,
      onTap: () =>
          Navigator.pop(context, ChannelPickerResult.pick(index)),
      onLongPress: () =>
          Navigator.pop(context, ChannelPickerResult.edit(index)),
    );
  }

  /// VFO sentinel cell. Tapping it returns the VFO sentinel id (0xFC
  /// for A, 0xFB for B); the screen's pick handler does the right
  /// thing — copy the currently-active saved channel's params into
  /// the sentinel before pointing the slot at it, mimicking the old
  /// "→ VFO" chip behaviour.
  Widget _vfoCell(ColorScheme colors, Color accent, bool isVfoA) {
    final sentinel = isVfoA ? 0xFC : 0xFB;
    // Each VFO button shows its own canonical color (A=primary,
    // B=tertiary) regardless of which slot the picker is filling, so
    // the user can always tell A from B.
    final cellColor = isVfoA ? colors.primary : colors.tertiary;
    return _gridCell(
      colors,
      accent: cellColor,
      cornerLabel: '',
      title: isVfoA ? 'VFO A' : 'VFO B',
      subtitle: 'AD-HOC',
      titleColor: cellColor,
      subtitleColor: colors.onSurfaceVariant,
      onTap: () =>
          Navigator.pop(context, ChannelPickerResult.pick(sentinel)),
      onLongPress: null,
    );
  }

  Widget _gridCell(
    ColorScheme colors, {
    required Color accent,
    required String cornerLabel,
    required String title,
    required String subtitle,
    required Color titleColor,
    required Color subtitleColor,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: accent.withAlpha(60),
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              if (cornerLabel.isNotEmpty)
                Positioned(
                  top: 0,
                  left: 0,
                  child: Text(
                    cornerLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              // Title sits a full line below the corner label so they
              // never collide horizontally on long names. Subtitle hugs
              // the bottom edge with the same margin the corner label
              // has at the top.
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: titleColor,
                          height: 1.0,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: subtitleColor,
                          height: 1.0,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = widget.isVfoA ? colors.primary : colors.tertiary;

    return Dialog(
      backgroundColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: accent.withAlpha(60), width: 1),
      ),
      child: SizedBox(
        width: 520,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: accent,
                      ),
                    ),
                  ),
                  // Close button — the active group is already shown
                  // by the highlight on the segment row below, so we
                  // don't repeat it as text here.
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (widget.onGroupChange != null)
                GroupSelector(
                  activeRegion: _activeRegion,
                  enabled: true,
                  onChanged: widget.onGroupChange!,
                  accentColor: accent,
                ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  // No scroll — the 32 cells are sized to fit the
                  // available area exactly. A scroll gesture here
                  // would just snap right back.
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    childAspectRatio: 2.19,
                  ),
                  // 30 saved channels + 2 VFO sentinel cells
                  // (VFO A = 0xFC, VFO B = 0xFB).
                  itemCount: _channels.length + 2,
                  itemBuilder: (context, index) {
                    if (index >= _channels.length) {
                      final cellIsVfoA = index == _channels.length;
                      return _vfoCell(colors, accent, cellIsVfoA);
                    }
                    return _channelCell(colors, accent, index);
                  },
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tap to select · Long-press to edit',
                style: TextStyle(
                  fontSize: 9,
                  color: colors.outline,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
