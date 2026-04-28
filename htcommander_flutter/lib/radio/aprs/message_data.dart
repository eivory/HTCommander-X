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

  /// REPLY-ACK extension (Dec 1999, spec §14): when an outgoing
  /// message has a free-ACK piggybacked on the line number, the wire
  /// format is `{MM}AA` where `MM` is this message's seqId and `AA`
  /// is an ACK for one of the *peer's* outstanding outgoing messages.
  /// Empty when the message did not include a free-ACK.
  String replyAck;

  /// True when the line-number field included a `}` separator —
  /// signals that the *sender* is REPLY-ACK capable, even when no
  /// free-ACK rode along on this packet.
  bool replyAckCapable;

  MessageData()
      : addressee = '',
        seqId = '',
        msgText = '',
        msgType = MessageType.unknown,
        msgIndex = 0,
        replyAck = '',
        replyAckCapable = false;
}
