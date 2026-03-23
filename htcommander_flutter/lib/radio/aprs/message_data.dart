/// APRS message types.
enum MessageType {
  unknown,
  general,
  bulletin,
  announcement,
  nws,
  ack,
  rej,
  autoAnswer,
}

/// Parsed APRS message data.
class MessageData {
  String addressee;
  String seqId;
  String msgText;
  MessageType msgType;
  int msgIndex;

  MessageData()
      : addressee = '',
        seqId = '',
        msgText = '',
        msgType = MessageType.unknown,
        msgIndex = 0;
}
