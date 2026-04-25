import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../radio/ax25/ax25_address.dart';
import '../radio/ax25/ax25_packet.dart';
import '../radio/aprs/aprs_packet.dart';
import '../radio/aprs/message_data.dart';
import '../radio/aprs/packet_data_type.dart';
import '../radio/models/radio_channel_info.dart';
import '../radio/radio.dart' show TransmitDataFrameData;

/// Data class for APRS message send requests.
class AprsSendMessageData {
  final String destination;
  final String message;
  final int radioDeviceId;
  final List<String>? route;

  const AprsSendMessageData({
    required this.destination,
    required this.message,
    required this.radioDeviceId,
    this.route,
  });
}

/// Handles incoming APRS packets — parses, stores, sends, and dispatches events.
///
/// Port of HTCommander.Core/AprsHandler.cs
class AprsHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<AprsEntry> _entries = [];
  static const int _maxEntries = 1000;

  bool _storeReady = false;
  String? _localCallsignWithId;
  int _nextAprsMessageId = 1;

  List<AprsEntry> get entries => List.unmodifiable(_entries);
  int get count => _entries.length;
  bool get isStoreReady => _storeReady;

  AprsHandler() {
    // Incoming packet processing
    _broker.subscribe(
        DataBroker.allDevices, 'UniqueDataFrame', _onUniqueDataFrame);

    // Historical packet loading
    _broker.subscribe(1, 'PacketStoreReady', _onPacketStoreReady);
    _broker.subscribe(1, 'PacketList', _onPacketList);

    // Message sending from UI
    _broker.subscribe(1, 'SendAprsMessage', _onSendAprsMessage);

    // On-demand packet list requests
    _broker.subscribe(1, 'RequestAprsPackets', _onRequestAprsPackets);

    // Callsign/station ID changes
    _broker.subscribe(0, 'CallSign', _onCallsignChanged);
    _broker.subscribe(0, 'StationId', _onCallsignChanged);

    _updateLocalCallsignWithId();

    // Load persisted message ID
    _nextAprsMessageId =
        DataBroker.getValue<int>(0, 'NextAprsMessageId', 1);
    if (_nextAprsMessageId < 1 || _nextAprsMessageId > 999) {
      _nextAprsMessageId = 1;
    }

    // Check if PacketStore is already ready
    if (DataBroker.hasValue(1, 'PacketStoreReady')) {
      _broker.dispatch(1, 'RequestPacketList', null, store: false);
    }
  }

  void _updateLocalCallsignWithId() {
    final callsign = DataBroker.getValue<String>(0, 'CallSign', '');
    final stationId = DataBroker.getValue<int>(0, 'StationId', 0);

    if (callsign.isEmpty) {
      _localCallsignWithId = null;
    } else if (stationId > 0) {
      _localCallsignWithId = '$callsign-$stationId';
    } else {
      _localCallsignWithId = callsign;
    }
  }

  void _onCallsignChanged(int deviceId, String name, Object? data) {
    _updateLocalCallsignWithId();
  }

  int _getNextAprsMessageId() {
    final msgId = _nextAprsMessageId++;
    if (_nextAprsMessageId > 999) _nextAprsMessageId = 1;
    _broker.dispatch(0, 'NextAprsMessageId', _nextAprsMessageId, store: true);
    return msgId;
  }

  // ── Incoming packet processing ──

  void _onUniqueDataFrame(int deviceId, String name, Object? data) {
    if (data is! AX25Packet) return;
    final ax25 = data;

    // Only process UI frames with data
    if (ax25.type != FrameType.uFrameUI || ax25.dataStr == null) return;
    if (ax25.addresses.length < 2) return;

    // Parse APRS
    final destCallsign = ax25.addresses[0].toString();
    final aprs = AprsPacket.parse(ax25.dataStr!, destCallsign);
    if (aprs == null) return;

    final entry = AprsEntry(
      time: ax25.time,
      from: ax25.addresses.length > 1 ? ax25.addresses[1].toString() : '',
      to: ax25.addresses[0].toString(),
      packet: aprs,
      ax25Packet: ax25,
      incoming: ax25.incoming,
    );

    _entries.add(entry);
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }

    _broker.dispatch(1, 'AprsEntry', entry, store: false);
    _broker.dispatch(1, 'AprsStoreUpdated', _entries.length, store: false);

    // Auto-ACK if message is addressed to us
    _sendAckIfNeeded(aprs, ax25, deviceId);
  }

  // ── Historical packet loading ──

  void _onPacketStoreReady(int deviceId, String name, Object? data) {
    if (_storeReady) return;
    _broker.dispatch(1, 'RequestPacketList', null, store: false);
  }

  void _onPacketList(int deviceId, String name, Object? data) {
    if (_storeReady) return;
    if (data is! List) return;

    for (final item in data) {
      if (item is! AX25Packet) continue;
      final ax25 = item;

      if (ax25.type != FrameType.uFrameUI || ax25.dataStr == null) continue;
      if (ax25.addresses.length < 2) continue;

      final destCallsign = ax25.addresses[0].toString();
      final aprs = AprsPacket.parse(ax25.dataStr!, destCallsign);
      if (aprs == null) continue;

      _entries.add(AprsEntry(
        time: ax25.time,
        from: ax25.addresses[1].toString(),
        to: ax25.addresses[0].toString(),
        packet: aprs,
        ax25Packet: ax25,
        incoming: ax25.incoming,
      ));
    }

    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }

    _storeReady = true;
    _broker.dispatch(1, 'AprsStoreReady', true, store: false);
  }

  void _onRequestAprsPackets(int deviceId, String name, Object? data) {
    if (!_storeReady) return;
    _broker.dispatch(
        1, 'AprsPacketList', List<AprsEntry>.from(_entries), store: false);
  }

  // ── Message sending ──

  void _onSendAprsMessage(int deviceId, String name, Object? data) {
    if (data is! AprsSendMessageData) return;
    final messageData = data;

    final callsign = DataBroker.getValue<String>(0, 'CallSign', '');
    final stationIdInt = DataBroker.getValue<int>(0, 'StationId', 0);

    if (callsign.isEmpty) {
      _broker.logError('Cannot send APRS message: Callsign not configured');
      return;
    }

    final srcCallsignWithId =
        stationIdInt > 0 ? '$callsign-$stationIdInt' : callsign;

    // Build APRS message content
    final msgId = _getNextAprsMessageId();
    final paddedDest = messageData.destination.padRight(9);
    final aprsContent = ':$paddedDest:${messageData.message}{$msgId';

    // Build address list
    final addresses = <AX25Address>[];

    // Destination (from route or default APRS)
    String destAddress = 'APRS';
    if (messageData.route != null && messageData.route!.length >= 2) {
      destAddress = messageData.route![1];
    }
    final destAddr = AX25Address.getAddress(destAddress);
    if (destAddr != null) addresses.add(destAddr);

    // Source
    final srcAddr = AX25Address.getAddress(srcCallsignWithId);
    if (srcAddr != null) addresses.add(srcAddr);

    // Digipeater path from route
    if (messageData.route != null && messageData.route!.length > 2) {
      for (var i = 2; i < messageData.route!.length; i++) {
        if (messageData.route![i].isNotEmpty) {
          final pathAddr = AX25Address.getAddress(messageData.route![i]);
          if (pathAddr != null) addresses.add(pathAddr);
        }
      }
    }

    // Create AX.25 UI frame
    final ax25Packet = AX25Packet.fromDataStr(
      addresses: addresses,
      dataStr: aprsContent,
      time: DateTime.now(),
    );
    ax25Packet.type = FrameType.uFrameUI;
    ax25Packet.pid = 240;
    ax25Packet.command = true;
    ax25Packet.incoming = false;
    ax25Packet.sent = false;

    // Find APRS channel
    final aprsChannelId = _getAprsChannelId(messageData.radioDeviceId);
    if (aprsChannelId < 0) {
      _broker.logError(
          'Cannot send APRS message: No APRS channel found on radio ${messageData.radioDeviceId}');
      return;
    }

    ax25Packet.channelId = aprsChannelId;
    ax25Packet.channelName = 'APRS';

    // Encode the AX.25 frame and dispatch to the radio for TX.
    final packetBytes = ax25Packet.toByteArray();
    if (packetBytes == null) {
      _broker.logError('Cannot send APRS message: AX.25 encode failed');
      return;
    }
    // ignore: avoid_print
    print('[APRS-TX] dispatching ${packetBytes.length} bytes to '
        'radio ${messageData.radioDeviceId} on channel $aprsChannelId');
    _broker.dispatch(
      messageData.radioDeviceId,
      'TransmitDataFrame',
      TransmitDataFrameData(
        packetData: packetBytes,
        channelId: aprsChannelId,
      ),
      store: false,
    );

    // Add to local history so it appears in UI immediately
    final destCallsign = addresses.isNotEmpty ? addresses[0].toString() : '';
    final aprs = AprsPacket.parse(aprsContent, destCallsign);
    if (aprs != null) {
      final entry = AprsEntry(
        time: ax25Packet.time,
        from: srcCallsignWithId,
        to: destCallsign,
        packet: aprs,
        ax25Packet: ax25Packet,
        incoming: false,
      );
      _entries.add(entry);
      while (_entries.length > _maxEntries) {
        _entries.removeAt(0);
      }
      _broker.dispatch(1, 'AprsEntry', entry, store: false);
      _broker.dispatch(1, 'AprsStoreUpdated', _entries.length, store: false);
    }
  }

  // ── Auto-ACK ──

  void _sendAckIfNeeded(
      AprsPacket aprsPacket, AX25Packet ax25Packet, int radioDeviceId) {
    if (aprsPacket.dataType != PacketDataType.message) return;
    final msgData = aprsPacket.messageData;

    // Don't ACK ACKs or REJs
    if (msgData.msgType == MessageType.ack ||
        msgData.msgType == MessageType.rej) {
      return;
    }

    // Only ACK messages with sequence ID
    if (msgData.seqId.isEmpty) return;

    // Check if addressed to us
    final localCallsign = _localCallsignWithId;
    if (localCallsign == null || localCallsign.isEmpty) return;

    final addressee = msgData.addressee.trim();
    if (addressee.isEmpty) return;

    final callsignOnly = DataBroker.getValue<String>(0, 'CallSign', '');
    final isForUs =
        addressee.toUpperCase() == localCallsign.toUpperCase() ||
            addressee.toUpperCase() == callsignOnly.toUpperCase();
    if (!isForUs) return;

    if (ax25Packet.addresses.length < 2) return;
    final senderCallsign = ax25Packet.addresses[1].toString();

    final aprsChannelId = _getAprsChannelId(radioDeviceId);
    if (aprsChannelId < 0) return;

    // Build ACK message
    final paddedSender = senderCallsign.padRight(9);
    final ackContent = ':$paddedSender:ack${msgData.seqId}';

    final addresses = <AX25Address>[];
    final destAddr = AX25Address.getAddress('APRS');
    if (destAddr != null) addresses.add(destAddr);
    final srcAddr = AX25Address.getAddress(localCallsign);
    if (srcAddr != null) addresses.add(srcAddr);

    final ackPacket = AX25Packet.fromDataStr(
      addresses: addresses,
      dataStr: ackContent,
      time: DateTime.now(),
    );
    ackPacket.type = FrameType.uFrameUI;
    ackPacket.pid = 240;
    ackPacket.command = true;
    ackPacket.incoming = false;
    ackPacket.channelId = aprsChannelId;
    ackPacket.channelName = 'APRS';

    final ackBytes = ackPacket.toByteArray();
    if (ackBytes == null) {
      _broker.logError('APRS ACK encode failed');
      return;
    }
    _broker.dispatch(
      radioDeviceId,
      'TransmitDataFrame',
      TransmitDataFrameData(
        packetData: ackBytes,
        channelId: aprsChannelId,
      ),
      store: false,
    );

    // Add ACK to local history
    final aprs = AprsPacket.parse(ackContent, 'APRS');
    if (aprs != null) {
      final entry = AprsEntry(
        time: ackPacket.time,
        from: localCallsign,
        to: 'APRS',
        packet: aprs,
        ax25Packet: ackPacket,
        incoming: false,
      );
      _entries.add(entry);
      while (_entries.length > _maxEntries) {
        _entries.removeAt(0);
      }
      _broker.dispatch(1, 'AprsEntry', entry, store: false);
      _broker.dispatch(1, 'AprsStoreUpdated', _entries.length, store: false);
    }
  }

  // ── Helpers ──

  int _getAprsChannelId(int radioDeviceId) {
    final channels =
        DataBroker.getValueDynamic(radioDeviceId, 'Channels');
    if (channels is! List) return -1;
    // Prefer an explicit user-set override; otherwise auto-detect a
    // channel named "APRS" (case-insensitive).
    final override = DataBroker.getValue<int>(0, 'AprsChannelId', -1);
    if (override >= 0 && override < channels.length && channels[override] is RadioChannelInfo) {
      return override;
    }
    for (var i = 0; i < channels.length; i++) {
      final ch = channels[i];
      if (ch is RadioChannelInfo &&
          ch.nameStr.toUpperCase() == 'APRS') {
        return i;
      }
    }
    return -1;
  }

  void clear() {
    _entries.clear();
    _broker.dispatch(1, 'AprsStoreUpdated', 0, store: false);
  }

  void dispose() {
    _broker.dispose();
  }
}

/// A stored APRS entry with metadata.
class AprsEntry {
  final DateTime time;
  final String from;
  final String to;
  final AprsPacket packet;
  final AX25Packet ax25Packet;
  final bool incoming;

  const AprsEntry({
    required this.time,
    required this.from,
    required this.to,
    required this.packet,
    required this.ax25Packet,
    this.incoming = true,
  });
}
