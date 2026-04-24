import 'package:flutter/material.dart';
import '../radio/models/radio_channel_info.dart';

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
class ChannelPickerDialog extends StatelessWidget {
  /// The list of channels (null entries are empty slots).
  final List<RadioChannelInfo?> channels;

  /// Dialog title (e.g., "Select VFO A Channel").
  final String title;

  const ChannelPickerDialog({
    super.key,
    required this.channels,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Dialog(
      backgroundColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 380,
        height: 500,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: channels.length,
                  itemBuilder: (context, index) {
                    final ch = channels[index];
                    final isEmpty = ch == null || (ch.rxFreq == 0 && ch.nameStr.isEmpty);
                    final freqMhz = ch != null && ch.rxFreq > 0
                        ? (ch.rxFreq / 1000000).toStringAsFixed(4)
                        : '---';
                    final name = ch != null && ch.nameStr.isNotEmpty
                        ? ch.nameStr
                        : '';

                    return InkWell(
                      onTap: () => Navigator.pop(
                          context, ChannelPickerResult.pick(index)),
                      onLongPress: () => Navigator.pop(
                          context, ChannelPickerResult.edit(index)),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: colors.outlineVariant.withAlpha(51),
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: isEmpty
                                      ? colors.onSurfaceVariant.withAlpha(102)
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                name.isNotEmpty ? name : (isEmpty ? 'Empty' : 'CH ${index + 1}'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isEmpty
                                      ? colors.onSurfaceVariant.withAlpha(102)
                                      : colors.onSurface,
                                ),
                              ),
                            ),
                            Text(
                              '$freqMhz MHz',
                              style: TextStyle(
                                fontSize: 10,
                                color: isEmpty
                                    ? colors.onSurfaceVariant.withAlpha(102)
                                    : colors.primary,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Tap to select · Long-press to edit',
                style: TextStyle(
                  fontSize: 9,
                  color: colors.outline,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'CANCEL',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
