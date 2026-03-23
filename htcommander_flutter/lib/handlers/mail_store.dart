import '../core/data_broker_client.dart';

/// A Winlink mail message.
class WinlinkMail {
  final String mid;
  String from;
  String to;
  String subject;
  String body;
  DateTime date;
  String folder;
  bool read;
  List<String> attachments;

  WinlinkMail({
    required this.mid,
    required this.from,
    required this.to,
    required this.subject,
    this.body = '',
    DateTime? date,
    this.folder = 'Inbox',
    this.read = false,
    List<String>? attachments,
  })  : date = date ?? DateTime.now(),
        attachments = attachments ?? [];
}

/// In-memory mail store for Winlink mail.
///
/// Simplified port of HTCommander.Core/MailStore.cs
/// SQLite persistence will be added in a later phase.
class MailStore {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<WinlinkMail> _mails = [];

  MailStore() {
    _broker.subscribe(1, 'MailAdd', _onMailAdd);
    _broker.subscribe(1, 'MailDelete', _onMailDelete);
    _broker.subscribe(1, 'MailMove', _onMailMove);

    // Signal readiness
    _broker.dispatch(1, 'MailStoreReady', true, store: false);
  }

  void _onMailAdd(int deviceId, String name, Object? data) {
    if (data is! WinlinkMail) return;
    _mails.add(data);
    _dispatchMails();
  }

  void _onMailDelete(int deviceId, String name, Object? data) {
    if (data is! String) return;
    _mails.removeWhere((m) => m.mid == data);
    _dispatchMails();
  }

  void _onMailMove(int deviceId, String name, Object? data) {
    if (data is! Map) return;
    final mid = data['mid'];
    final newFolder = data['folder'];
    if (mid is! String || newFolder is! String) return;
    for (final mail in _mails) {
      if (mail.mid == mid) {
        mail.folder = newFolder;
        break;
      }
    }
    _dispatchMails();
  }

  /// Gets a mail by message ID, or null if not found.
  WinlinkMail? getMail(String mid) {
    for (final mail in _mails) {
      if (mail.mid == mid) return mail;
    }
    return null;
  }

  /// Returns all mails.
  List<WinlinkMail> getAllMails() => List.unmodifiable(_mails);

  /// Returns mails filtered by folder name.
  List<WinlinkMail> getMailsByFolder(String folder) =>
      _mails.where((m) => m.folder == folder).toList();

  /// Adds a mail to the store.
  void addMail(WinlinkMail mail) {
    _mails.add(mail);
    _dispatchMails();
  }

  /// Deletes a mail by message ID.
  void deleteMail(String mid) {
    _mails.removeWhere((m) => m.mid == mid);
    _dispatchMails();
  }

  /// Moves a mail to a new folder.
  void moveMail(String mid, String newFolder) {
    for (final mail in _mails) {
      if (mail.mid == mid) {
        mail.folder = newFolder;
        break;
      }
    }
    _dispatchMails();
  }

  void _dispatchMails() {
    _broker.dispatch(1, 'Mails', List<WinlinkMail>.from(_mails),
        store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}
