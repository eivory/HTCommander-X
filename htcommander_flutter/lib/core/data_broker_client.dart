import 'data_broker.dart';

/// A client for the DataBroker that manages subscriptions for a specific component.
/// When disposed, all subscriptions are automatically removed.
///
/// Port of HTCommander.Core/DataBrokerClient.cs
class DataBrokerClient {
  bool _disposed = false;

  /// Subscribes to data changes for a specific device ID and name.
  void subscribe(int deviceId, String name,
      void Function(int deviceId, String name, Object? data) callback) {
    if (_disposed) throw StateError('DataBrokerClient has been disposed');
    DataBroker.subscribe(this, deviceId, name, callback);
  }

  /// Subscribes to data changes for a specific device ID and multiple names.
  void subscribeMultiple(int deviceId, List<String> names,
      void Function(int deviceId, String name, Object? data) callback) {
    if (_disposed) throw StateError('DataBrokerClient has been disposed');
    for (final name in names) {
      DataBroker.subscribe(this, deviceId, name, callback);
    }
  }

  /// Subscribes to all data changes for a specific device ID.
  void subscribeAll(int deviceId,
      void Function(int deviceId, String name, Object? data) callback) {
    subscribe(deviceId, DataBroker.allNames, callback);
  }

  /// Subscribes to all data changes across all devices.
  void subscribeEverything(
      void Function(int deviceId, String name, Object? data) callback) {
    subscribe(DataBroker.allDevices, DataBroker.allNames, callback);
  }

  /// Unsubscribes from a specific device ID and name.
  void unsubscribe(int deviceId, String name) {
    if (_disposed) return;
    DataBroker.unsubscribeSpecific(this, deviceId, name);
  }

  /// Unsubscribes from all subscriptions for this client.
  void unsubscribeAll() {
    if (_disposed) return;
    DataBroker.unsubscribe(this);
  }

  /// Dispatches data to the broker.
  void dispatch(int deviceId, String name, Object? data,
      {bool store = true}) {
    if (_disposed) return;
    DataBroker.dispatch(deviceId, name, data, store: store);
  }

  /// Gets a typed value from the broker.
  T getValue<T>(int deviceId, String name, T defaultValue) {
    return DataBroker.getValue<T>(deviceId, name, defaultValue);
  }

  /// Gets a value from the broker as a dynamic object.
  Object? getValueDynamic(int deviceId, String name, {Object? defaultValue}) {
    return DataBroker.getValueDynamic(deviceId, name,
        defaultValue: defaultValue);
  }

  /// Checks if a value exists in the broker.
  bool hasValue(int deviceId, String name) {
    return DataBroker.hasValue(deviceId, name);
  }

  /// Publishes an informational log message to device 1.
  void logInfo(String msg) {
    if (_disposed) return;
    DataBroker.dispatch(1, 'LogInfo', msg, store: false);
  }

  /// Publishes an error log message to device 1.
  void logError(String msg) {
    if (_disposed) return;
    DataBroker.dispatch(1, 'LogError', msg, store: false);
  }

  /// Disposes the client and unsubscribes from all data changes.
  void dispose() {
    if (!_disposed) {
      DataBroker.unsubscribe(this);
      _disposed = true;
    }
  }
}
