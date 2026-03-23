/// Radio connection state.
enum RadioState {
  disconnected(1),
  connecting(2),
  connected(3),
  multiRadioSelect(4),
  unableToConnect(5),
  bluetoothNotAvailable(6),
  notRadioFound(7),
  accessDenied(8);

  final int value;
  const RadioState(this.value);
}

/// Radio channel type (OFF, VFO A, VFO B).
enum RadioChannelType {
  off(0),
  a(1),
  b(2);

  final int value;
  const RadioChannelType(this.value);

  static RadioChannelType fromValue(int v) {
    return RadioChannelType.values.firstWhere((e) => e.value == v,
        orElse: () => RadioChannelType.off);
  }
}

/// Radio modulation type.
enum RadioModulationType {
  fm(0),
  am(1),
  dmr(2);

  final int value;
  const RadioModulationType(this.value);

  static RadioModulationType fromValue(int v) {
    return RadioModulationType.values.firstWhere((e) => e.value == v,
        orElse: () => RadioModulationType.fm);
  }
}

/// Radio bandwidth type.
enum RadioBandwidthType {
  narrow(0),
  wide(1);

  final int value;
  const RadioBandwidthType(this.value);
}

/// GAIA command response status.
enum RadioCommandState {
  success(0),
  notSupported(1),
  notAuthenticated(2),
  insufficientResources(3),
  authenticating(4),
  invalidParameter(5),
  incorrectState(6),
  inProgress(7);

  final int value;
  const RadioCommandState(this.value);

  static RadioCommandState fromValue(int v) {
    return RadioCommandState.values.firstWhere((e) => e.value == v,
        orElse: () => RadioCommandState.success);
  }
}

/// TNC fragment encoding type.
enum FragmentEncodingType {
  unknown,
  loopback,
  hardwareAfsk1200,
  softwareAfsk1200,
  softwareG3ruh9600,
  softwarePsk2400,
  softwarePsk4800,
}

/// TNC fragment frame type.
enum FragmentFrameType {
  unknown,
  ax25,
  fx25,
}
