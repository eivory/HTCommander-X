import 'dart:convert';
import 'settings_store.dart';
import 'data_broker_client.dart';

/// A global data broker for dispatching and receiving data across components.
/// Supports device-specific and named data channels with optional persistence.
///
/// Port of HTCommander.Core/DataBroker.cs
class DataBroker {
  /// Subscribe to all device IDs.
  static const int allDevices = -1;

  /// Subscribe to all names.
  static const String allNames = '*';

  static final Map<_DataKey, Object?> _dataStore = {};
  static final List<_Subscription> _subscriptions = [];
  static final Map<String, Object> _dataHandlers = {};
  static SettingsStore? _settingsStore;
  static bool _initialized = false;

  /// Initializes the data broker with a platform-specific settings store.
  static void initialize(SettingsStore settingsStore) {
    if (_initialized) return;
    _settingsStore = settingsStore;
    _initialized = true;
  }

  /// Dispatches data to the broker, optionally storing it and notifying subscribers.
  ///
  /// [deviceId] — use 0 for values that should persist to settings store.
  /// [name] — the data channel name/key.
  /// [data] — the data value.
  /// [store] — if true, value is stored; if false, only broadcast.
  static void dispatch(int deviceId, String name, Object? data,
      {bool store = true}) {
    if (store) {
      final key = _DataKey(deviceId, name);
      _dataStore[key] = data;

      // Persist to settings store if device 0
      if (deviceId == 0 && _settingsStore != null) {
        _persistValue(name, data);
      }
    }

    // Find matching subscriptions (copy list to avoid modification during iteration)
    final matching = _subscriptions.where((sub) {
      final deviceMatches =
          sub.deviceId == allDevices || sub.deviceId == deviceId;
      final nameMatches = sub.name == allNames || sub.name == name;
      return deviceMatches && nameMatches;
    }).toList();

    // Invoke callbacks — marshal to UI thread via WidgetsBinding if available
    for (final sub in matching) {
      try {
        _invokeCallback(sub.callback, deviceId, name, data);
      } catch (_) {
        // Swallow exceptions from callbacks to prevent broker failure
      }
    }
  }

  /// Invokes a callback, marshalling to the UI thread if possible.
  static void _invokeCallback(
    void Function(int, String, Object?) callback,
    int deviceId,
    String name,
    Object? data,
  ) {
    // Post to next microtask to marshal to UI thread and avoid issues during build
    Future.microtask(() {
      try {
        callback(deviceId, name, data);
      } catch (_) {}
    });
  }

  /// Persist a device-0 value to the settings store.
  static void _persistValue(String name, Object? data) {
    final store = _settingsStore;
    if (store == null || data == null) return;

    if (data is int) {
      store.writeInt(name, data);
    } else if (data is String) {
      store.writeString(name, data);
    } else if (data is bool) {
      store.writeBool(name, data);
    } else {
      // Serialize complex types with type marker prefix
      final typeName = data.runtimeType.toString();
      final json = jsonEncode(data);
      store.writeString(name, '~~JSON:$typeName:$json');
    }
  }

  /// Gets a typed value from the broker.
  ///
  /// For device 0, falls back to the settings store if not in memory.
  /// [T] determines the expected type. Supports int, String, bool natively.
  /// Complex types use JSON serialization with a `~~JSON:` prefix.
  static T getValue<T>(int deviceId, String name, T defaultValue) {
    final key = _DataKey(deviceId, name);

    if (_dataStore.containsKey(key)) {
      final value = _dataStore[key];
      if (value is T) return value;
      // Try int/string conversion for compatible types
      if (T == int && value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed as T;
      }
      return defaultValue;
    }

    // For device 0, try loading from settings store
    if (deviceId == 0 && _settingsStore != null) {
      final loaded = _loadFromStore<T>(name);
      if (loaded != null) {
        _dataStore[key] = loaded;
        return loaded;
      }
    }

    return defaultValue;
  }

  /// Try to load a typed value from the settings store.
  static T? _loadFromStore<T>(String name) {
    final store = _settingsStore;
    if (store == null) return null;

    if (T == int) {
      final val = store.readInt(name, null);
      if (val != null) return val as T;
    } else if (T == String) {
      final val = store.readString(name, null);
      if (val != null && !val.startsWith('~~JSON:')) {
        return val as T;
      }
    } else if (T == bool) {
      // Sentinel approach: read with both defaults to detect if value exists
      final val1 = store.readBool(name, false);
      final val2 = store.readBool(name, true);
      if (val1 == val2) return val1 as T;
    }
    // Complex JSON types would need a fromJson factory — handled per-type
    // by callers that register deserialization functions.
    return null;
  }

  /// Gets a value from the broker as a dynamic object.
  static Object? getValueDynamic(int deviceId, String name,
      {Object? defaultValue}) {
    final key = _DataKey(deviceId, name);
    return _dataStore.containsKey(key) ? _dataStore[key] : defaultValue;
  }

  /// Checks if a value exists in the broker.
  static bool hasValue(int deviceId, String name) {
    return _dataStore.containsKey(_DataKey(deviceId, name));
  }

  /// Removes a value from the broker.
  static bool removeValue(int deviceId, String name) {
    final key = _DataKey(deviceId, name);
    final removed = _dataStore.remove(key) != null;

    if (deviceId == 0 && _settingsStore != null) {
      _settingsStore!.deleteValue(name);
    }

    return removed;
  }

  /// Subscribes to data changes. Called internally by DataBrokerClient.
  static void subscribe(DataBrokerClient client, int deviceId, String name,
      void Function(int, String, Object?) callback) {
    _subscriptions.add(_Subscription(
      client: client,
      deviceId: deviceId,
      name: name,
      callback: callback,
    ));
  }

  /// Unsubscribes all subscriptions for a client.
  static void unsubscribe(DataBrokerClient client) {
    _subscriptions.removeWhere((s) => s.client == client);
  }

  /// Unsubscribes a specific subscription for a client.
  static void unsubscribeSpecific(
      DataBrokerClient client, int deviceId, String name) {
    _subscriptions.removeWhere(
        (s) => s.client == client && s.deviceId == deviceId && s.name == name);
  }

  /// Gets all stored values for a specific device.
  static Map<String, Object?> getDeviceValues(int deviceId) {
    final result = <String, Object?>{};
    for (final entry in _dataStore.entries) {
      if (entry.key.deviceId == deviceId) {
        result[entry.key.name] = entry.value;
      }
    }
    return result;
  }

  /// Clears all stored data for a specific device.
  static void clearDevice(int deviceId) {
    _dataStore.removeWhere((key, _) => key.deviceId == deviceId);
  }

  /// Deletes all data for a specific device, dispatching null to subscribers first.
  static void deleteDevice(int deviceId) {
    final keysToRemove = _dataStore.keys
        .where((key) => key.deviceId == deviceId)
        .toList();

    // Notify subscribers with null
    for (final key in keysToRemove) {
      dispatch(key.deviceId, key.name, null, store: false);
    }

    // Remove from storage
    for (final key in keysToRemove) {
      _dataStore.remove(key);
    }
  }

  /// Clears all stored data, subscriptions, handlers, and resets initialization state.
  static void reset() {
    _dataStore.clear();
    _subscriptions.clear();
    _dataHandlers.clear();
    _settingsStore = null;
    _initialized = false;
  }

  /// Adds a data handler to the broker.
  static bool addDataHandler(String name, Object handler) {
    if (_dataHandlers.containsKey(name)) return false;
    _dataHandlers[name] = handler;
    dispatch(0, 'DataHandlerAdded', name, store: false);
    return true;
  }

  /// Gets a data handler by name.
  static Object? getDataHandler(String name) {
    return _dataHandlers[name];
  }

  /// Gets a data handler by name with type casting.
  static T? getDataHandlerTyped<T>(String name) {
    final handler = _dataHandlers[name];
    return handler is T ? handler : null;
  }

  /// Removes a data handler by name.
  static bool removeDataHandler(String name) {
    final handler = _dataHandlers.remove(name);
    if (handler == null) return false;
    dispatch(0, 'DataHandlerRemoved', name, store: false);
    return true;
  }

  /// Checks if a data handler exists.
  static bool hasDataHandler(String name) {
    return _dataHandlers.containsKey(name);
  }

  /// Removes all data handlers.
  static void removeAllDataHandlers() {
    _dataHandlers.clear();
  }
}

/// Internal key for the data store.
class _DataKey {
  final int deviceId;
  final String name;

  const _DataKey(this.deviceId, this.name);

  @override
  bool operator ==(Object other) =>
      other is _DataKey && deviceId == other.deviceId && name == other.name;

  @override
  int get hashCode => deviceId.hashCode ^ name.hashCode;
}

/// Internal subscription record.
class _Subscription {
  final DataBrokerClient client;
  final int deviceId;
  final String name;
  final void Function(int, String, Object?) callback;

  const _Subscription({
    required this.client,
    required this.deviceId,
    required this.name,
    required this.callback,
  });
}
