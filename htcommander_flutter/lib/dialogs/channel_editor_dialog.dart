import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../radio/models/radio_channel_info.dart';
import '../radio/radio_enums.dart';

/// Dialog for editing or creating a RadioChannelInfo.
class ChannelEditorDialog extends StatefulWidget {
  /// Pass an existing channel for edit mode, or null for create mode.
  final RadioChannelInfo? channel;

  const ChannelEditorDialog({super.key, this.channel});

  @override
  State<ChannelEditorDialog> createState() => _ChannelEditorDialogState();
}

class _ChannelEditorDialogState extends State<ChannelEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _rxFreqController;
  late final TextEditingController _txFreqController;

  RadioModulationType _modulation = RadioModulationType.fm;
  RadioBandwidthType _bandwidth = RadioBandwidthType.narrow;
  int _txPower = 0; // 0=High, 1=Medium, 2=Low
  bool _scan = false;
  bool _txDisable = false;
  bool _mute = false;

  @override
  void initState() {
    super.initState();
    final ch = widget.channel;
    _nameController = TextEditingController(text: ch?.nameStr ?? '');
    _rxFreqController = TextEditingController(
      text: ch != null && ch.rxFreq > 0
          ? (ch.rxFreq / 1000000).toStringAsFixed(4)
          : '',
    );
    _txFreqController = TextEditingController(
      text: ch != null && ch.txFreq > 0
          ? (ch.txFreq / 1000000).toStringAsFixed(4)
          : '',
    );
    if (ch != null) {
      _modulation = ch.rxMod;
      _bandwidth = ch.bandwidth;
      _scan = ch.scan;
      _txDisable = ch.txDisable;
      _mute = ch.mute;
      if (ch.txAtMaxPower) {
        _txPower = 0;
      } else if (ch.txAtMedPower) {
        _txPower = 1;
      } else {
        _txPower = 2;
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _rxFreqController.dispose();
    _txFreqController.dispose();
    super.dispose();
  }

  void _onSave() {
    final rxMhz = double.tryParse(_rxFreqController.text);
    final txMhz = double.tryParse(_txFreqController.text);
    if (rxMhz == null || rxMhz <= 0) {
      return;
    }

    final result = widget.channel != null
        ? RadioChannelInfo.copy(widget.channel!)
        : RadioChannelInfo();

    result.nameStr =
        _nameController.text.length > 10
            ? _nameController.text.substring(0, 10)
            : _nameController.text;
    result.rxFreq = (rxMhz * 1000000).round();
    result.txFreq =
        txMhz != null && txMhz > 0
            ? (txMhz * 1000000).round()
            : result.rxFreq;
    result.rxMod = _modulation;
    result.txMod = _modulation;
    result.bandwidth = _bandwidth;
    result.scan = _scan;
    result.txDisable = _txDisable;
    result.mute = _mute;
    result.txAtMaxPower = _txPower == 0;
    result.txAtMedPower = _txPower == 1;

    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isEdit = widget.channel != null;

    return Dialog(
      backgroundColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 400,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEdit ? 'EDIT CHANNEL' : 'NEW CHANNEL',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              _buildTextField(
                'CHANNEL NAME',
                _nameController,
                colors,
                maxLength: 10,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                'RX FREQUENCY (MHZ)',
                _rxFreqController,
                colors,
                numeric: true,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                'TX FREQUENCY (MHZ)',
                _txFreqController,
                colors,
                numeric: true,
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                'MODULATION',
                _modulation.name.toUpperCase(),
                ['FM', 'AM', 'DMR'],
                (val) {
                  setState(() {
                    _modulation = RadioModulationType.values.firstWhere(
                      (e) => e.name.toUpperCase() == val,
                      orElse: () => RadioModulationType.fm,
                    );
                  });
                },
                colors,
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                'BANDWIDTH',
                _bandwidth == RadioBandwidthType.wide ? 'WIDE' : 'NARROW',
                ['NARROW', 'WIDE'],
                (val) {
                  setState(() {
                    _bandwidth = val == 'WIDE'
                        ? RadioBandwidthType.wide
                        : RadioBandwidthType.narrow;
                  });
                },
                colors,
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                'TX POWER',
                ['HIGH', 'MEDIUM', 'LOW'][_txPower],
                ['HIGH', 'MEDIUM', 'LOW'],
                (val) {
                  setState(() {
                    _txPower = ['HIGH', 'MEDIUM', 'LOW'].indexOf(val);
                  });
                },
                colors,
              ),
              const SizedBox(height: 12),
              _buildCheckbox('SCAN', _scan, (v) {
                setState(() => _scan = v);
              }, colors),
              const SizedBox(height: 8),
              _buildCheckbox('TX DISABLE', _txDisable, (v) {
                setState(() => _txDisable = v);
              }, colors),
              const SizedBox(height: 8),
              _buildCheckbox('MUTE', _mute, (v) {
                setState(() => _mute = v);
              }, colors),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
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
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _onSave,
                    child: Text(
                      'SAVE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    ColorScheme colors, {
    bool numeric = false,
    int? maxLength,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 32,
          child: TextField(
            controller: controller,
            maxLength: maxLength,
            maxLengthEnforcement: maxLength != null
                ? MaxLengthEnforcement.enforced
                : MaxLengthEnforcement.none,
            keyboardType:
                numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
            inputFormatters: numeric
                ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))]
                : null,
            style: TextStyle(fontSize: 11, color: colors.onSurface),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: colors.primary),
              ),
              filled: true,
              fillColor: colors.surfaceContainerLow,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown(
    String label,
    String value,
    List<String> items,
    ValueChanged<String> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: DropdownButton<String>(
              value: value,
              underline: const SizedBox(),
              isDense: true,
              isExpanded: true,
              dropdownColor: colors.surfaceContainerHigh,
              style: TextStyle(fontSize: 11, color: colors.onSurface),
              items: items
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckbox(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
    ColorScheme colors,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
