import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  // Placeholder data — will be wired to DataBroker later
  final List<_ContactEntry> _contacts = [];
  int? _selectedIndex;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _buildHeader(colors),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: _buildContactTable(colors),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 280,
                  child: _buildDetailCard(colors),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(ColorScheme colors) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: colors.surfaceContainer,
      child: Row(
        children: [
          Text(
            'STATION ROSTER',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_contacts.length} stations',
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          _HeaderButton(label: 'Add', onPressed: () {}),
          const SizedBox(width: 6),
          _HeaderButton(
            label: 'Edit',
            onPressed: _selectedIndex != null ? () {} : null,
          ),
          const SizedBox(width: 6),
          _HeaderButton(
            label: 'Remove',
            onPressed: _selectedIndex != null ? () {} : null,
          ),
        ],
      ),
    );
  }

  Widget _buildContactTable(ColorScheme colors) {
    return GlassCard(
      padding: const EdgeInsets.all(0),
      child: _contacts.isEmpty
          ? Center(
              child: Text(
                'No stations in roster',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.outline,
                ),
              ),
            )
          : SingleChildScrollView(
              child: SizedBox(
                width: double.infinity,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 32,
                  columnSpacing: 24,
                  horizontalMargin: 14,
                  headingRowColor: WidgetStateProperty.all(
                    colors.surfaceContainerHigh,
                  ),
                  columns: [
                    DataColumn(
                      label: Text(
                        'CALLSIGN',
                        style: _columnHeaderStyle(colors),
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'NAME',
                        style: _columnHeaderStyle(colors),
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'TYPE',
                        style: _columnHeaderStyle(colors),
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'DESCRIPTION',
                        style: _columnHeaderStyle(colors),
                      ),
                    ),
                  ],
                  rows: List.generate(_contacts.length, (i) {
                    final c = _contacts[i];
                    final selected = _selectedIndex == i;
                    return DataRow(
                      selected: selected,
                      color: selected
                          ? WidgetStateProperty.all(
                              colors.primary.withAlpha(30),
                            )
                          : null,
                      onSelectChanged: (_) {
                        setState(() => _selectedIndex = i);
                      },
                      cells: [
                        DataCell(Text(c.callsign,
                            style: _cellStyle(colors))),
                        DataCell(
                            Text(c.name, style: _cellStyle(colors))),
                        DataCell(
                            Text(c.type, style: _cellStyle(colors))),
                        DataCell(Text(c.description,
                            style: _cellStyle(colors))),
                      ],
                    );
                  }),
                ),
              ),
            ),
    );
  }

  Widget _buildDetailCard(ColorScheme colors) {
    final contact =
        _selectedIndex != null ? _contacts[_selectedIndex!] : null;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'STATION DETAIL',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          if (contact == null)
            Expanded(
              child: Center(
                child: Text(
                  'Select a station',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.outline,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailField(
                        label: 'CALLSIGN', value: contact.callsign),
                    const SizedBox(height: 12),
                    _DetailField(label: 'NAME', value: contact.name),
                    const SizedBox(height: 12),
                    _DetailField(label: 'TYPE', value: contact.type),
                    const SizedBox(height: 12),
                    _DetailField(
                        label: 'DESCRIPTION',
                        value: contact.description),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _columnHeaderStyle(ColorScheme colors) {
    return TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
      color: colors.onSurfaceVariant,
    );
  }

  TextStyle _cellStyle(ColorScheme colors) {
    return TextStyle(
      fontSize: 12,
      color: colors.onSurface,
    );
  }
}

class _ContactEntry {
  final String callsign;
  final String name;
  final String type;
  final String description;

  const _ContactEntry({
    required this.callsign,
    required this.name,
    required this.type,
    required this.description,
  });
}

class _DetailField extends StatelessWidget {
  const _DetailField({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
        ),
      ],
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}
