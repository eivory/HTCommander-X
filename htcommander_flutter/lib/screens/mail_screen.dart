import 'package:flutter/material.dart';
import '../widgets/glass_card.dart';

class MailScreen extends StatefulWidget {
  const MailScreen({super.key});

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen> {
  String _selectedFolder = 'Inbox';
  int _selectedMailIndex = -1;

  final List<String> _folders = [
    'Inbox',
    'Outbox',
    'Draft',
    'Sent',
    'Archive',
    'Trash',
  ];

  final Map<String, IconData> _folderIcons = {
    'Inbox': Icons.inbox,
    'Outbox': Icons.outbox,
    'Draft': Icons.drafts,
    'Sent': Icons.send,
    'Archive': Icons.archive,
    'Trash': Icons.delete,
  };

  // Placeholder mail data
  final List<_MailEntry> _mails = [
    _MailEntry(
      from: 'W1AW',
      subject: 'Weekly bulletin #2847',
      date: '2026-03-22 14:30',
      body:
          'DE W1AW\r\nARRL BULLETIN 2847\r\n\r\nThis is a sample weekly bulletin message.\r\nPlease check your local repeater schedule.',
    ),
    _MailEntry(
      from: 'KD2ABC',
      subject: 'Re: Net check-in schedule',
      date: '2026-03-21 09:15',
      body:
          'Hi,\r\n\r\nThanks for the updated schedule.\r\nI will be available on Thursday evening.\r\n\r\n73,\r\nKD2ABC',
    ),
    _MailEntry(
      from: 'N0CALL',
      subject: 'Winlink test message',
      date: '2026-03-20 16:45',
      body:
          'This is a test message sent via Winlink.\r\nPlease confirm receipt.\r\n\r\n73 de N0CALL',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _buildHeader(colors),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Folder sidebar
              SizedBox(
                width: 160,
                child: _buildFolderSidebar(colors),
              ),
              // Mail content area
              Expanded(
                child: _buildMailContent(colors),
              ),
            ],
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
            'RADIO MAIL',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.tertiary.withAlpha(30),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'WINLINK: IDLE',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: colors.tertiary,
              ),
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.edit, size: 14),
            label: const Text('COMPOSE MESSAGE'),
            style: FilledButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              textStyle: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.refresh, size: 14),
            label: const Text('CHECK FOR MAIL'),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              textStyle: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSidebar(ColorScheme colors) {
    return Container(
      color: colors.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Text(
              'FOLDERS',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (context, index) {
                final folder = _folders[index];
                final isSelected = folder == _selectedFolder;
                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -3),
                  leading: Icon(
                    _folderIcons[folder],
                    size: 16,
                    color: isSelected
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  title: Text(
                    folder,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected
                          ? colors.onSurface
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  selected: isSelected,
                  selectedTileColor: colors.primaryContainer.withAlpha(80),
                  onTap: () => setState(() {
                    _selectedFolder = folder;
                    _selectedMailIndex = -1;
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMailContent(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          // Mail list table
          Expanded(
            flex: 3,
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      'MESSAGES',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: DataTable(
                          headingRowHeight: 32,
                          dataRowMinHeight: 28,
                          dataRowMaxHeight: 32,
                          columnSpacing: 24,
                          horizontalMargin: 16,
                          headingTextStyle: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: colors.onSurfaceVariant,
                          ),
                          dataTextStyle: TextStyle(
                            fontSize: 11,
                            color: colors.onSurface,
                          ),
                          columns: const [
                            DataColumn(label: Text('FROM')),
                            DataColumn(label: Text('SUBJECT')),
                            DataColumn(label: Text('DATE')),
                          ],
                          rows: List.generate(_mails.length, (index) {
                            final mail = _mails[index];
                            final isSelected =
                                index == _selectedMailIndex;
                            return DataRow(
                              selected: isSelected,
                              color: WidgetStateProperty.resolveWith(
                                  (states) {
                                if (states
                                    .contains(WidgetState.selected)) {
                                  return colors.primaryContainer
                                      .withAlpha(60);
                                }
                                return null;
                              }),
                              onSelectChanged: (_) {
                                setState(
                                    () => _selectedMailIndex = index);
                              },
                              cells: [
                                DataCell(Text(mail.from)),
                                DataCell(Text(mail.subject)),
                                DataCell(Text(mail.date)),
                              ],
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Message preview
          Expanded(
            flex: 2,
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      'MESSAGE PREVIEW',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: _selectedMailIndex >= 0
                          ? SelectableText(
                              _mails[_selectedMailIndex].body,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: colors.onSurface,
                                height: 1.5,
                              ),
                            )
                          : Center(
                              child: Text(
                                'Select a message to preview',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.outline,
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MailEntry {
  const _MailEntry({
    required this.from,
    required this.subject,
    required this.date,
    required this.body,
  });

  final String from;
  final String subject;
  final String date;
  final String body;
}
