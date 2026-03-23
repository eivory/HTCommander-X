import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import '../core/data_broker.dart';
import '../core/data_broker_client.dart';
import '../platform/bluetooth_service.dart';
import 'binary_utils.dart';
import 'gaia_protocol.dart';
import 'radio_enums.dart';
import 'models/radio_dev_info.dart';
import 'models/radio_channel_info.dart';
import 'models/radio_settings.dart';
import 'models/radio_ht_status.dart';
import 'models/radio_position.dart';
import 'models/radio_bss_settings.dart';
import 'models/tnc_data_fragment.dart';

/// GAIA command groups.
class _CommandGroup {
  static const int basic = 2;
  static const int extended = 10;
}

/// GAIA basic commands.
class _BasicCmd {
  static const int getDevInfo = 4;
  static const int readStatus = 5;
  static const int registerNotification = 6;
  static const int cancelNotification = 7;
  static const int eventNotification = 9;
  static const int readSettings = 10;
  static const int writeSettings = 11;
  static const int readRfCh = 13;
  static const int writeRfCh = 14;
  static const int getHtStatus = 20;
  static const int getVolume = 22;
  static const int setVolume = 23;
  static const int htSendData = 31;
  static const int setPosition = 32;
  static const int readBssSettings = 33;
  static const int writeBssSettings = 34;
  static const int setRegion = 60;
  static const int getPosition = 76;
}

/// GAIA notification types.
class _Notification {
  static const int htStatusChanged = 1;
  static const int dataRxd = 2;
  static const int htSettingsChanged = 6;
  static const int positionChange = 13;
}

/// Power status request types.
class _PowerStatus {
  static const int batteryLevel = 1;
  static const int batteryVoltage = 2;
  static const int rcBatteryLevel = 3;
  static const int batteryAsPercentage = 4;
}

/// Radio lock state.
class RadioLockState {
  bool isLocked;
  String? usage;
  int regionId;
  int channelId;

  RadioLockState({
    this.isLocked = false,
    this.usage,
    this.regionId = -1,
    this.channelId = -1,
  });
}

/// Data for locking a radio to a specific channel/region.
class SetLockData {
  final String usage;
  final int regionId;
  final int channelId;
  const SetLockData({required this.usage, this.regionId = -1, this.channelId = -1});
}

/// Data for unlocking a radio.
class SetUnlockData {
  final String usage;
  const SetUnlockData({required this.usage});
}

/// Data for transmitting a data frame.
class TransmitDataFrameData {
  final Uint8List? packetData;
  final int channelId;
  final int regionId;
  final String? tag;
  final DateTime? deadline;

  const TransmitDataFrameData({
    this.packetData,
    this.channelId = -1,
    this.regionId = -1,
    this.tag,
    this.deadline,
  });
}

/// Fragment waiting in the transmit queue.
class _FragmentInQueue {
  final Uint8List fragment;
  final bool isLast;
  final int fragId;
  String? tag;
  DateTime deadline;
  bool deleted;

  _FragmentInQueue(this.fragment, this.isLast, this.fragId)
      : deadline = DateTime(9999),
        deleted = false;
}

/// GAIA protocol radio state machine.
///
/// Port of HTCommander.Core/radio/Radio.cs (1,629 lines).
/// Manages the full lifecycle: connect → init commands → channel reads →
/// event handling → disconnect.
class Radio {
  static const int _maxMtu = 50;

  final int deviceId;
  final String macAddress;
  String? friendlyName;

  final DataBrokerClient _broker = DataBrokerClient();
  RadioBluetoothTransport? _transport;
  final PlatformServices? _platformServices;

  // Public state
  RadioDevInfo? info;
  List<RadioChannelInfo?>? channels;
  RadioHtStatus? htStatus;
  RadioSettings? settings;
  RadioBssSettings? bssSettings;
  RadioPosition? position;
  bool hardwareModemEnabled = true;

  RadioState _state = RadioState.disconnected;
  RadioState get state => _state;

  // GPS state
  bool _gpsEnabled = false;
  int _gpsLock = 2;

  // Lock state
  RadioLockState? _lockState;
  String? get lockUsage =>
      _lockState != null && _lockState!.isLocked ? _lockState!.usage : null;
  int _savedRegionId = -1;
  int _savedChannelId = -1;
  bool _savedScan = false;
  int _savedDualWatch = 0;

  // Fragment accumulator and transmit queue
  TncDataFragment? _frameAccumulator;
  final List<_FragmentInQueue> _tncQueue = [];
  bool _tncInFlight = false;

  // Clear channel timer
  Timer? _clearChannelTimer;

  bool get _packetTrace =>
      DataBroker.getValue<bool>(0, 'BluetoothFramesDebug', false);
  bool get _loopbackMode =>
      DataBroker.getValue<bool>(1, 'LoopbackMode', false);
  bool get _allowTransmit =>
      DataBroker.getValue<bool>(0, 'AllowTransmit', false);

  Radio(this.deviceId, this.macAddress, [this._platformServices]) {
    // Subscribe to events on this device
    _broker.subscribeMultiple(deviceId, [
      'ChannelChangeVfoA', 'ChannelChangeVfoB',
    ], _onChannelChangeEvent);

    _broker.subscribeMultiple(deviceId, [
      'WriteSettings', 'SetRegion', 'DualWatch', 'Scan', 'SetGPS', 'Region',
    ], _onSettingsChangeEvent);

    _broker.subscribe(deviceId, 'WriteChannel', _onWriteChannelEvent);
    _broker.subscribe(deviceId, 'GetPosition', _onGetPositionEvent);
    _broker.subscribe(deviceId, 'SetPosition', _onSetPositionEvent);
    _broker.subscribe(deviceId, 'TransmitDataFrame', _onTransmitDataFrameEvent);
    _broker.subscribe(deviceId, 'SetBssSettings', _onSetBssSettingsEvent);
    _broker.subscribe(deviceId, 'SetLock', _onSetLockEvent);
    _broker.subscribe(deviceId, 'SetUnlock', _onSetUnlockEvent);
    _broker.subscribe(deviceId, 'SetAudio', _onSetAudioEvent);
    _broker.subscribe(deviceId, 'SetVolumeLevel', _onSetVolumeLevelEvent);
    _broker.subscribe(deviceId, 'SetSquelchLevel', _onSetSquelchLevelEvent);
    _broker.subscribe(deviceId, 'GetVolume', _onGetVolumeEvent);
  }

  // ── Connection Management ──────────────────────────────────────────

  void connect() {
    if (_state == RadioState.connected || _state == RadioState.connecting) return;
    _updateState(RadioState.connecting);
    debug('Attempting to connect to radio MAC: $macAddress');

    final ps = _platformServices;
    if (ps == null) {
      throw StateError('PlatformServices must be provided to Radio constructor.');
    }
    _transport = ps.createRadioBluetooth(macAddress);
    _transport!.onDataReceived = _onReceivedData;
    _transport!.onConnected = _onTransportConnected;
    _transport!.connect();
  }

  void disconnect([String? msg, RadioState newState = RadioState.disconnected]) {
    if (msg != null) debug(msg);
    _updateState(newState);
    _transport?.disconnect();

    // Clear broker state
    _broker.dispatch(deviceId, 'Info', null);
    _broker.dispatch(deviceId, 'Channels', null);
    _broker.dispatch(deviceId, 'HtStatus', null);
    _broker.dispatch(deviceId, 'Settings', null);
    _broker.dispatch(deviceId, 'BssSettings', null);
    _broker.dispatch(deviceId, 'Position', null);
    _broker.dispatch(deviceId, 'AllChannelsLoaded', false);
    _broker.dispatch(deviceId, 'GpsEnabled', false);
    _broker.dispatch(deviceId, 'LockState', null);
    _broker.dispatch(deviceId, 'Volume', 0);
    _broker.dispatch(deviceId, 'BatteryAsPercentage', 0);
    _broker.dispatch(deviceId, 'BatteryLevel', 0);
    _broker.dispatch(deviceId, 'BatteryVoltage', 0.0);
    _broker.dispatch(deviceId, 'RcBatteryLevel', 0);

    // Clear local state
    info = null;
    channels = null;
    htStatus = null;
    settings = null;
    bssSettings = null;
    position = null;
    _frameAccumulator = null;
    _tncQueue.clear();
    _tncInFlight = false;
    _lockState = null;
    _gpsEnabled = false;
    _clearChannelTimer?.cancel();

    DataBroker.deleteDevice(deviceId);
  }

  void dispose() {
    disconnect();
    _broker.dispose();
  }

  void _onTransportConnected() {
    _sendCommand(_CommandGroup.basic, _BasicCmd.getDevInfo, body: Uint8List.fromList([3]));
    _sendCommand(_CommandGroup.basic, _BasicCmd.readSettings);
    _sendCommand(_CommandGroup.basic, _BasicCmd.readBssSettings);
    _requestPowerStatus(_PowerStatus.batteryAsPercentage);
  }

  void _updateState(RadioState newState) {
    if (_state == newState) return;
    _state = newState;
    _broker.dispatch(deviceId, 'State', newState.name, store: true);
    debug('State changed to: ${newState.name}');
  }

  // ── Command Sending ────────────────────────────────────────────────

  void _sendCommand(int group, int cmdId, {Uint8List? body}) {
    if (_transport == null) return;
    final cmd = GaiaProtocol.buildCommand(group, cmdId, body);
    if (_packetTrace) debug('Queue: $group, $cmdId: ${BinaryUtils.bytesToHex(cmd)}');
    _transport!.enqueueWrite(_getExpectedResponse(group, cmdId), cmd);
  }

  void _sendCommandByte(int group, int cmdId, int dataByte) {
    _sendCommand(group, cmdId, body: Uint8List.fromList([dataByte & 0xFF]));
  }

  void _sendCommandInt(int group, int cmdId, int value) {
    final body = Uint8List(4);
    BinaryUtils.setInt(body, 0, value);
    _sendCommand(group, cmdId, body: body);
  }

  int _getExpectedResponse(int group, int cmdId) {
    if (cmdId == _BasicCmd.registerNotification ||
        cmdId == _BasicCmd.writeSettings ||
        cmdId == _BasicCmd.setRegion) {
      return -1;
    }
    final rcmd = cmdId | 0x8000;
    return (group << 16) + rcmd;
  }

  // ── Response Handling ──────────────────────────────────────────────

  void _onReceivedData(Exception? error, Uint8List? value) {
    if (_state != RadioState.connected && _state != RadioState.connecting) return;
    if (error != null) debug('Notification ERROR SET');
    if (value == null) { debug('Notification: NULL'); return; }
    if (value.length < 4) { debug('Notification: too short (${value.length} bytes)'); return; }

    if (_packetTrace) debug('-----> ${BinaryUtils.bytesToHex(value)}');

    final group = BinaryUtils.getShort(value, 0);
    _broker.dispatch(deviceId, 'RawCommand', value, store: false);

    try {
      if (group == _CommandGroup.basic) {
        _handleBasicCommand(value);
      } else if (group == _CommandGroup.extended) {
        _handleExtendedCommand(value);
      } else {
        debug('Unexpected Command Group: $group');
      }
    } on ArgumentError catch (e) {
      debug('Malformed radio response: $e');
    }
  }

  void _handleBasicCommand(Uint8List value) {
    if (value.length < 5) { debug('Basic command too short'); return; }
    final cmd = BinaryUtils.getShort(value, 2) & 0x7FFF;

    switch (cmd) {
      case _BasicCmd.getDevInfo:
        info = RadioDevInfo(value);
        channels = List<RadioChannelInfo?>.filled(info!.channelCount, null);
        _updateState(RadioState.connected);
        _broker.dispatch(deviceId, 'Info', info);
        _broker.dispatch(deviceId, 'FriendlyName', friendlyName);
        _broker.dispatch(deviceId, 'GpsEnabled', _gpsEnabled);
        _broker.dispatch(deviceId, 'AllChannelsLoaded', false);
        _sendCommandInt(_CommandGroup.basic, _BasicCmd.registerNotification,
            _Notification.htStatusChanged);
        if (_gpsEnabled) {
          _sendCommandInt(_CommandGroup.basic, _BasicCmd.registerNotification,
              _Notification.positionChange);
        }
        break;

      case _BasicCmd.readRfCh:
        _handleReadRfChannel(value);
        break;

      case _BasicCmd.writeRfCh:
        if (value.length >= 6 && value[4] == 0) {
          _sendCommandByte(_CommandGroup.basic, _BasicCmd.readRfCh, value[5]);
        }
        break;

      case _BasicCmd.readBssSettings:
        bssSettings = RadioBssSettings.fromBytes(value);
        _broker.dispatch(deviceId, 'BssSettings', bssSettings);
        break;

      case _BasicCmd.writeBssSettings:
        if (value[4] != 0) {
          debug("WRITE_BSS_SETTINGS Error: '${value[4]}'");
        } else {
          _sendCommand(_CommandGroup.basic, _BasicCmd.readBssSettings);
        }
        break;

      case _BasicCmd.eventNotification:
        _handleEventNotification(value);
        break;

      case _BasicCmd.readStatus:
        _handleReadStatus(value);
        break;

      case _BasicCmd.readSettings:
        settings = RadioSettings.fromBytes(value);
        _broker.dispatch(deviceId, 'Settings', settings);
        break;

      case _BasicCmd.htSendData:
        _handleHtSendDataResponse(value);
        break;

      case _BasicCmd.getVolume:
        if (value.length >= 6) {
          _broker.dispatch(deviceId, 'Volume', value[5]);
        }
        break;

      case _BasicCmd.writeSettings:
        if (value[4] != 0) debug('WRITE_SETTINGS ERROR: ${BinaryUtils.bytesToHex(value)}');
        break;

      case _BasicCmd.getPosition:
        position = RadioPosition.fromBytes(value);
        if (_gpsEnabled) {
          _broker.dispatch(deviceId, 'Position', position);
        }
        break;

      case _BasicCmd.setPosition:
        if (value[4] != 0) debug("SET_POSITION Error: '${value[4]}'");
        break;

      case _BasicCmd.getHtStatus:
        _handleGetHtStatus(value);
        break;

      default:
        debug('Unexpected Basic Command: $cmd');
    }
  }

  void _handleReadRfChannel(Uint8List value) {
    final c = RadioChannelInfo.fromBytes(value);
    if (channels != null && c.channelId >= 0 && c.channelId < channels!.length) {
      channels![c.channelId] = c;
    }
    if (_allChannelsLoaded()) {
      _broker.dispatch(deviceId, 'Channels', channels);
      _broker.dispatch(deviceId, 'AllChannelsLoaded', true);
    }
  }

  void _handleEventNotification(Uint8List value) {
    final notify = value[4];

    switch (notify) {
      case _Notification.htStatusChanged:
        _handleHtStatusChanged(value);
        break;
      case _Notification.dataRxd:
        _handleDataReceived(value);
        break;
      case _Notification.htSettingsChanged:
        settings = RadioSettings.fromBytes(value);
        _broker.dispatch(deviceId, 'Settings', settings);
        break;
      case _Notification.positionChange:
        value[4] = 0; // Set status to success
        position = RadioPosition.fromBytes(value);
        if (_gpsLock > 0) _gpsLock--;
        position!.locked = (_gpsLock == 0);
        if (_gpsEnabled) {
          _broker.dispatch(deviceId, 'Position', position);
        }
        break;
      default:
        debug('Event: ${BinaryUtils.bytesToHex(value)}');
    }
  }

  void _handleHtStatusChanged(Uint8List value) {
    final oldRegion = htStatus?.currRegion ?? -1;
    htStatus = RadioHtStatus.fromBytes(value);
    _broker.dispatch(deviceId, 'HtStatus', htStatus);

    if (oldRegion != htStatus!.currRegion) {
      _broker.dispatch(deviceId, 'RegionChange', null, store: false);
      _broker.dispatch(deviceId, 'AllChannelsLoaded', false);
      if (channels != null) {
        channels = List<RadioChannelInfo?>.filled(channels!.length, null);
      }
      _broker.dispatch(deviceId, 'Channels', channels);
      _updateChannels();
    }

    _processTncQueue();
  }

  void _handleGetHtStatus(Uint8List value) {
    final oldRegion = htStatus?.currRegion ?? -1;
    htStatus = RadioHtStatus.fromBytes(value);
    if (_allChannelsLoaded()) {
      _broker.dispatch(deviceId, 'HtStatus', htStatus);
    }

    if (oldRegion != htStatus!.currRegion) {
      _broker.dispatch(deviceId, 'RegionChange', null);
      _broker.dispatch(deviceId, 'AllChannelsLoaded', false);
      if (channels != null) {
        channels = List<RadioChannelInfo?>.filled(channels!.length, null);
        _broker.dispatch(deviceId, 'Channels', channels);
      }
      _updateChannels();
    }

    _processTncQueue();
  }

  void _handleDataReceived(Uint8List value) {
    if (!hardwareModemEnabled) return;
    debug('RawData: ${BinaryUtils.bytesToHex(value)}');

    final fragment = TncDataFragment.fromBytes(value);
    fragment.encoding = FragmentEncodingType.hardwareAfsk1200;
    fragment.corrections = 0;
    if (fragment.channelId == -1 && htStatus != null) {
      fragment.channelId = htStatus!.currChId;
    }
    fragment.channelName = _getDataFragmentChannelName(fragment.channelId);

    _accumulateFragment(fragment);
  }

  void _handleReadStatus(Uint8List value) {
    if (value.length < 9) { debug('READ_STATUS response too short'); return; }
    final powerStatus = BinaryUtils.getShort(value, 5);

    switch (powerStatus) {
      case _PowerStatus.batteryLevel:
        _broker.dispatch(deviceId, 'BatteryLevel', value[7]);
        break;
      case _PowerStatus.batteryVoltage:
        final voltage = BinaryUtils.getShort(value, 7) / 1000.0;
        _broker.dispatch(deviceId, 'BatteryVoltage', voltage);
        break;
      case _PowerStatus.rcBatteryLevel:
        _broker.dispatch(deviceId, 'RcBatteryLevel', value[7]);
        break;
      case _PowerStatus.batteryAsPercentage:
        _broker.dispatch(deviceId, 'BatteryAsPercentage', value[7]);
        break;
    }
  }

  void _handleHtSendDataResponse(Uint8List value) {
    _clearTransmitQueue();

    if (_tncQueue.isEmpty) { _tncInFlight = false; return; }

    final channelFree = _isTncFree();
    final errorCode = RadioCommandState.fromValue(value[4]);

    if (errorCode == RadioCommandState.incorrectState) {
      if (_tncQueue[0].fragId == 0) {
        if (channelFree) {
          _tncInFlight = true;
          debug('TNC Fragment failed, TRYING AGAIN.');
          _sendCommand(_CommandGroup.basic, _BasicCmd.htSendData, body: _tncQueue[0].fragment);
        } else {
          _tncInFlight = false;
        }
        return;
      } else {
        debug('TNC Fragment failed, check Bluetooth connection.');
        while (_tncQueue.isNotEmpty && !_tncQueue[0].isLast) {
          _tncQueue.removeAt(0);
        }
        if (_tncQueue.isNotEmpty) _tncQueue.removeAt(0);
      }
    } else {
      _tncQueue.removeAt(0);
    }

    if (_tncQueue.isNotEmpty && (_tncQueue[0].fragId != 0 || channelFree)) {
      _tncInFlight = true;
      _sendCommand(_CommandGroup.basic, _BasicCmd.htSendData, body: _tncQueue[0].fragment);
    } else {
      _tncInFlight = false;
    }
  }

  void _handleExtendedCommand(Uint8List value) {
    final xcmd = BinaryUtils.getShort(value, 2) & 0x7FFF;
    debug('Unexpected Extended Command: $xcmd');
  }

  // ── Channel Management ─────────────────────────────────────────────

  bool _allChannelsLoaded() {
    if (channels == null) return false;
    return channels!.every((ch) => ch != null);
  }

  void _updateChannels() {
    if (_state != RadioState.connected || info == null) return;
    for (var i = 0; i < info!.channelCount; i++) {
      _sendCommandByte(_CommandGroup.basic, _BasicCmd.readRfCh, i);
    }
  }

  String getChannelNameById(int channelId) {
    if (channelId >= 254) return 'NOAA';
    if (channelId >= 0 && channels != null && channelId < channels!.length &&
        channels![channelId] != null) {
      return channels![channelId]!.nameStr;
    }
    return '';
  }

  String _getDataFragmentChannelName(int channelId) {
    if (channelId >= 0 && channels != null && channelId < channels!.length &&
        channels![channelId] != null) {
      final ch = channels![channelId]!;
      if (ch.nameStr.isNotEmpty) return ch.nameStr.replaceAll(',', '');
      if (ch.rxFreq != 0) return '${ch.rxFreq / 1000000.0} Mhz';
    }
    return (channelId + 1).toString();
  }

  RadioChannelInfo? getChannelByFrequency(double freq, RadioModulationType mod) {
    if (channels == null) return null;
    final xfreq = (freq * 1000000).round();
    for (final ch in channels!) {
      if (ch != null && ch.rxFreq == xfreq && ch.txFreq == xfreq &&
          ch.rxMod == mod && ch.txMod == mod) {
        return ch;
      }
    }
    return null;
  }

  RadioChannelInfo? getChannelByName(String name) {
    if (channels == null) return null;
    for (final ch in channels!) {
      if (ch != null && ch.nameStr == name) return ch;
    }
    return null;
  }

  // ── GPS Management ─────────────────────────────────────────────────

  void gpsEnabled(bool enabled) {
    if (_gpsEnabled == enabled) return;
    _gpsEnabled = enabled;
    _broker.dispatch(deviceId, 'GpsEnabled', _gpsEnabled);

    if (_state == RadioState.connected) {
      _gpsLock = 2;
      final cmdId = _gpsEnabled
          ? _BasicCmd.registerNotification
          : _BasicCmd.cancelNotification;
      _sendCommandInt(_CommandGroup.basic, cmdId, _Notification.positionChange);
    }

    if (!_gpsEnabled) {
      position = null;
      _broker.dispatch(deviceId, 'Position', null);
    }
  }

  void getPosition() {
    _sendCommand(_CommandGroup.basic, _BasicCmd.getPosition);
  }

  void setPosition(RadioPosition pos) {
    _sendCommand(_CommandGroup.basic, _BasicCmd.setPosition, body: pos.toByteArray());
  }

  // ── Settings & Control ─────────────────────────────────────────────

  void writeSettings(Uint8List data) {
    _sendCommand(_CommandGroup.basic, _BasicCmd.writeSettings, body: data);
  }

  void setChannel(RadioChannelInfo channel) {
    _sendCommand(_CommandGroup.basic, _BasicCmd.writeRfCh, body: channel.toByteArray());
  }

  void setRegion(int region) {
    _sendCommandByte(_CommandGroup.basic, _BasicCmd.setRegion, region);
  }

  void setVolumeLevel(int level) {
    if (level < 0 || level > 15) return;
    _sendCommand(_CommandGroup.basic, _BasicCmd.setVolume,
        body: Uint8List.fromList([level]));
  }

  void setSquelchLevel(int level) {
    if (level < 0 || level > 9 || settings == null) return;
    writeSettings(settings!.toByteArrayWithChannels(
        settings!.channelA, settings!.channelB,
        settings!.doubleChannel, settings!.scan, level));
  }

  void getVolumeLevel() {
    _sendCommand(_CommandGroup.basic, _BasicCmd.getVolume);
  }

  void setBssSettings(RadioBssSettings bss) {
    _sendCommand(_CommandGroup.basic, _BasicCmd.writeBssSettings,
        body: bss.toByteArray());
  }

  void _requestPowerStatus(int powerStatus) {
    final data = Uint8List(2);
    data[1] = powerStatus;
    _sendCommand(_CommandGroup.basic, _BasicCmd.readStatus, body: data);
  }

  // ── Fragment Accumulation ──────────────────────────────────────────

  void _accumulateFragment(TncDataFragment fragment) {
    if (_frameAccumulator == null) {
      if (fragment.fragmentId == 0) _frameAccumulator = fragment;
    } else {
      _frameAccumulator = _frameAccumulator!.append(fragment);
    }

    if (_frameAccumulator != null && _frameAccumulator!.finalFragment) {
      final packet = _frameAccumulator!;
      _frameAccumulator = null;
      packet.incoming = true;
      packet.time = DateTime.now();

      if (_lockState != null && _lockState!.isLocked &&
          packet.channelId == _lockState!.channelId) {
        packet.usage = _lockState!.usage;
      }

      _dispatchDataFrame(packet);
    }
  }

  // ── Transmit Queue ─────────────────────────────────────────────────

  bool _isTncFree() => htStatus != null && !htStatus!.isInTx && !htStatus!.isInRx;

  void _clearTransmitQueue() {
    if (_tncQueue.isEmpty || _tncQueue[0].fragId != 0) return;
    final now = DateTime.now();
    _tncQueue.removeWhere((f) => f.deleted || f.deadline.isBefore(now));
  }

  void _processTncQueue() {
    _clearTransmitQueue();
    final channelFree = _isTncFree();

    if (channelFree && !_tncInFlight && _tncQueue.isNotEmpty) {
      _tncInFlight = true;
      _sendCommand(_CommandGroup.basic, _BasicCmd.htSendData, body: _tncQueue[0].fragment);
    } else if (_tncInFlight && htStatus != null && htStatus!.isInRx) {
      _tncInFlight = false;
    }
  }

  int transmitTncData(Uint8List outboundData, {String? channelName,
      int channelId = -1, int regionId = -1, String? tag, DateTime? deadline}) {
    if (!_allowTransmit) return 0;

    if (channelId == -1 && settings != null) channelId = settings!.channelA;
    if (regionId == -1 && htStatus != null) regionId = htStatus!.currRegion;

    if ((channelName == null || channelName.isEmpty) &&
        channelId >= 0 && channels != null && channelId < channels!.length &&
        channels![channelId] != null) {
      channelName = channels![channelId]!.nameStr;
    }

    final fragment = TncDataFragment(
      finalFragment: true, fragmentId: 0,
      data: outboundData, channelId: channelId, regionId: regionId,
    )..incoming = false
     ..time = DateTime.now()
     ..channelName = channelName ?? '';

    if (_loopbackMode) {
      fragment.encoding = FragmentEncodingType.loopback;
      fragment.frameType = FragmentFrameType.ax25;
      _dispatchDataFrame(fragment);

      // Simulate receive
      final rx = TncDataFragment(
        finalFragment: true, fragmentId: 0,
        data: outboundData, channelId: channelId, regionId: regionId,
      )..incoming = true
       ..time = DateTime.now()
       ..encoding = FragmentEncodingType.loopback
       ..frameType = FragmentFrameType.ax25
       ..channelName = channelName ?? '';
      _dispatchDataFrame(rx);
    } else if (hardwareModemEnabled) {
      fragment.encoding = FragmentEncodingType.hardwareAfsk1200;
      fragment.frameType = FragmentFrameType.ax25;
      _dispatchDataFrame(fragment);

      // Fragment for BT MTU
      var i = 0, fragId = 0;
      while (i < outboundData.length) {
        final fragmentSize = min(outboundData.length - i, _maxMtu);
        final fragData = Uint8List.fromList(outboundData.sublist(i, i + fragmentSize));
        final isLast = (i + fragmentSize) == outboundData.length;
        final tncFrag = TncDataFragment(
          finalFragment: isLast, fragmentId: fragId,
          data: fragData, channelId: channelId, regionId: regionId,
        );
        final inQueue = _FragmentInQueue(tncFrag.toByteArray(), isLast, fragId)
          ..tag = tag
          ..deadline = deadline ?? DateTime(9999);
        _tncQueue.add(inQueue);
        i += fragmentSize;
        fragId++;
      }

      if (!_tncInFlight && _tncQueue.isNotEmpty && htStatus != null &&
          htStatus!.rssi == 0 && !htStatus!.isInTx) {
        _tncInFlight = true;
        _sendCommand(_CommandGroup.basic, _BasicCmd.htSendData, body: _tncQueue[0].fragment);
      }
    }

    return outboundData.length;
  }

  void deleteTransmitByTag(String tag) {
    for (final f in _tncQueue) {
      if (f.tag == tag) f.deleted = true;
    }
  }

  // ── Event Handlers (DataBroker subscriptions) ──────────────────────

  void _onChannelChangeEvent(int devId, String name, Object? data) {
    if (devId != deviceId || settings == null || _lockState != null) return;
    final channelId = data as int;

    if (name == 'ChannelChangeVfoA') {
      writeSettings(settings!.toByteArrayWithChannels(
          channelId, settings!.channelB, settings!.doubleChannel,
          settings!.scan, settings!.squelchLevel));
    } else if (name == 'ChannelChangeVfoB') {
      writeSettings(settings!.toByteArrayWithChannels(
          settings!.channelA, channelId, settings!.doubleChannel,
          settings!.scan, settings!.squelchLevel));
    }
  }

  void _onSettingsChangeEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;

    switch (name) {
      case 'WriteSettings':
        if (_lockState != null) return;
        if (data is Uint8List) writeSettings(data);
        break;
      case 'SetRegion':
      case 'Region':
        if (_lockState != null) return;
        if (data is int) setRegion(data);
        break;
      case 'SetGPS':
        if (data is bool) gpsEnabled(data);
        break;
      case 'DualWatch':
        if (_lockState != null || settings == null) return;
        if (data is bool) {
          writeSettings(settings!.toByteArrayWithChannels(
              settings!.channelA, settings!.channelB,
              data ? 1 : 0, settings!.scan, settings!.squelchLevel));
        }
        break;
      case 'Scan':
        if (_lockState != null || settings == null) return;
        if (data is bool) {
          writeSettings(settings!.toByteArrayWithChannels(
              settings!.channelA, settings!.channelB,
              settings!.doubleChannel, data, settings!.squelchLevel));
        }
        break;
    }
  }

  void _onWriteChannelEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    if (data is RadioChannelInfo) setChannel(data);
  }

  void _onGetPositionEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    getPosition();
  }

  void _onSetPositionEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    if (data is RadioPosition) setPosition(data);
  }

  void _onTransmitDataFrameEvent(int devId, String name, Object? data) {
    if (devId != deviceId || data is! TransmitDataFrameData) return;
    final txData = data;
    if (txData.packetData != null) {
      transmitTncData(txData.packetData!,
          channelId: txData.channelId, regionId: txData.regionId,
          tag: txData.tag, deadline: txData.deadline);
    }
  }

  void _onSetBssSettingsEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    if (data is RadioBssSettings) setBssSettings(data);
  }

  void _onSetLockEvent(int devId, String name, Object? data) {
    if (devId != deviceId || data is! SetLockData) return;
    if (_lockState != null || settings == null || htStatus == null) return;

    final lockData = data;
    _savedRegionId = htStatus!.currRegion;
    _savedChannelId = settings!.channelA;
    _savedScan = settings!.scan;
    _savedDualWatch = settings!.doubleChannel;

    final targetRegion = lockData.regionId >= 0 ? lockData.regionId : htStatus!.currRegion;
    final targetChannel = lockData.channelId >= 0 ? lockData.channelId : settings!.channelA;

    _lockState = RadioLockState(
      isLocked: true, usage: lockData.usage,
      regionId: targetRegion, channelId: targetChannel,
    );
    _broker.dispatch(deviceId, 'LockState', _lockState);
    debug("Radio locked for '${lockData.usage}' - Region: $targetRegion, Channel: $targetChannel");

    if (targetRegion != htStatus!.currRegion) setRegion(targetRegion);
    writeSettings(settings!.toByteArrayWithChannels(
        targetChannel, settings!.channelB, 0, false, settings!.squelchLevel));
  }

  void _onSetUnlockEvent(int devId, String name, Object? data) {
    if (devId != deviceId || data is! SetUnlockData) return;
    if (_lockState == null || _lockState!.usage != data.usage || settings == null) return;

    debug("Radio unlocked from '${data.usage}'");

    if (htStatus != null && _savedRegionId != htStatus!.currRegion && _savedRegionId >= 0) {
      setRegion(_savedRegionId);
    }

    writeSettings(settings!.toByteArrayWithChannels(
        _savedChannelId, settings!.channelB,
        _savedDualWatch, _savedScan, settings!.squelchLevel));

    _lockState = null;
    _broker.dispatch(deviceId, 'LockState',
        RadioLockState(isLocked: false));
  }

  void _onSetAudioEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    // Audio management will be handled in Phase 5
  }

  void _onSetVolumeLevelEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    if (data is int) setVolumeLevel(data);
  }

  void _onSetSquelchLevelEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    if (data is int) setSquelchLevel(data);
  }

  void _onGetVolumeEvent(int devId, String name, Object? data) {
    if (devId != deviceId) return;
    getVolumeLevel();
  }

  // ── Dispatch Helpers ───────────────────────────────────────────────

  void debug(String msg) {
    _broker.dispatch(1, 'LogInfo', '[Radio/$deviceId]: $msg', store: false);
  }

  void _dispatchDataFrame(TncDataFragment frame) {
    frame.radioMac = macAddress;
    frame.radioDeviceId = deviceId;
    _broker.dispatch(deviceId, 'DataFrame', frame, store: false);
  }

  /// Updates the friendly name and dispatches event.
  void updateFriendlyName(String newName) {
    friendlyName = newName;
    _broker.dispatch(deviceId, 'FriendlyName', newName, store: false);
  }
}
