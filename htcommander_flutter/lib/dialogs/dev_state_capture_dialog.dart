import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/data_broker.dart';
import '../radio/radio.dart' show DevStateVarBurst;

// TEMPORARY-DIAGNOSTIC: remove this whole file once the DevStateVar
// (GAIA 0x4003) catalog is fully understood. Search for
// "TEMPORARY-DIAGNOSTIC" across the repo to find the matching tracker
// in radio.dart and the AppShell subscription in app.dart so the trio
// can be torn out together.

/// Crowdsourcing dialog: when the radio fires a burst of mysterious
/// DevStateVar (GAIA 0x4003) events, ask the user what they were
/// doing on the radio at that moment so we can build a varId catalog.
///
/// On save, the user's note + the captured events are written to
/// the app log with a `[DEV-STATE-CAPTURE]` prefix that's
/// grep-friendly, and a "share with Claude" pane shows the formatted
/// text with a copy-to-clipboard button.
class DevStateCaptureDialog extends StatefulWidget {
  const DevStateCaptureDialog({super.key, required this.burst});

  final DevStateVarBurst burst;

  @override
  State<DevStateCaptureDialog> createState() => _DevStateCaptureDialogState();
}

class _DevStateCaptureDialogState extends State<DevStateCaptureDialog> {
  final TextEditingController _notes = TextEditingController();
  String? _shareText;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  String _formatShareText() {
    final firstTs = widget.burst.events.first.time.toIso8601String();
    final lastTs = widget.burst.events.last.time.toIso8601String();
    final note = _notes.text.trim();
    final lines = <String>[
      'DevStateVar burst observation',
      '  count: ${widget.burst.events.length}',
      '  first: $firstTs',
      '  last:  $lastTs',
      '  user did: ${note.isEmpty ? "(no description)" : note}',
      '  events:',
      for (final e in widget.burst.events)
        '    - ${e.time.toIso8601String()} '
            '${e.varName}(varId=${e.varId}) '
            'payload=${e.payloadHex.isEmpty ? "(empty)" : e.payloadHex}',
    ];
    return lines.join('\n');
  }

  void _save() {
    final share = _formatShareText();
    // One-line, grep-friendly entry in the app log so a future
    // user / agent / log dump can collect every capture.
    final note = _notes.text.trim().replaceAll('\n', ' ');
    final eventSummary = widget.burst.events
        .map((e) => '${e.varName}:${e.payloadHex.isEmpty ? "-" : e.payloadHex}')
        .join(',');
    DataBroker.dispatch(
      1,
      'LogInfo',
      '[DEV-STATE-CAPTURE] count=${widget.burst.events.length} '
          'first=${widget.burst.events.first.time.toIso8601String()} '
          'note="$note" events=[$eventSummary]',
      store: false,
    );
    setState(() => _shareText = share);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 540,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _shareText == null
                    ? 'UNEXPLAINED RADIO EVENT BURST'
                    : 'CAPTURED — SHARE WITH CLAUDE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: 10),
              if (_shareText == null) ..._captureForm(colors),
              if (_shareText != null) ..._sharePane(colors),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _captureForm(ColorScheme colors) => [
        Text(
          'The radio just sent ${widget.burst.events.length} events the app '
          "doesn't fully understand yet. To help build a catalog of what they "
          'mean, briefly describe what you were doing on the radio:',
          style: TextStyle(fontSize: 12, color: colors.onSurface),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _notes,
          maxLines: 3,
          autofocus: true,
          style: TextStyle(fontSize: 12, color: colors.onSurface),
          decoration: InputDecoration(
            hintText: 'e.g. "pressed the orange button" / '
                '"plugged in USB" / "scrolled through the menu"',
            hintStyle: TextStyle(
              fontSize: 11,
              color: colors.onSurfaceVariant.withAlpha(160),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Captured events:',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(maxHeight: 140),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            child: Text(
              widget.burst.events
                  .map((e) => '${e.time.toIso8601String().substring(11, 19)}  '
                      '${e.varName.padRight(22)} '
                      '${e.payloadHex.isEmpty ? "(empty)" : e.payloadHex}')
                  .join('\n'),
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('SKIP'),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _save,
              child: const Text('SAVE'),
            ),
          ],
        ),
      ];

  List<Widget> _sharePane(ColorScheme colors) => [
        Text(
          'Saved to the log under the [DEV-STATE-CAPTURE] tag. To help '
          'the next investigation, copy the block below and paste it '
          'into your chat with Claude:',
          style: TextStyle(fontSize: 12, color: colors.onSurface),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              _shareText!,
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CLOSE'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _shareText!));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 14),
              label: const Text('COPY'),
            ),
          ],
        ),
      ];
}
