import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander_flutter/core/data_broker.dart';
import 'package:htcommander_flutter/core/data_broker_client.dart';
import 'package:htcommander_flutter/core/settings_store.dart';

/// In-memory settings store for testing.
class MemorySettingsStore implements SettingsStore {
  final Map<String, Object> _store = {};

  @override
  void writeString(String key, String value) => _store[key] = value;

  @override
  String? readString(String key, String? defaultValue) {
    final val = _store[key];
    return val is String ? val : defaultValue;
  }

  @override
  void writeInt(String key, int value) => _store[key] = value;

  @override
  int? readInt(String key, int? defaultValue) {
    final val = _store[key];
    return val is int ? val : defaultValue;
  }

  @override
  void writeBool(String key, bool value) => _store[key] = value;

  @override
  bool readBool(String key, bool defaultValue) {
    final val = _store[key];
    return val is bool ? val : defaultValue;
  }

  @override
  void deleteValue(String key) => _store.remove(key);

  bool containsKey(String key) => _store.containsKey(key);
}

void main() {
  late MemorySettingsStore settingsStore;

  setUp(() {
    DataBroker.reset();
    settingsStore = MemorySettingsStore();
    DataBroker.initialize(settingsStore);
  });

  group('DataBroker dispatch and getValue', () {
    test('stores and retrieves int values', () {
      DataBroker.dispatch(0, 'Volume', 10);
      expect(DataBroker.getValue<int>(0, 'Volume', 0), equals(10));
    });

    test('stores and retrieves string values', () {
      DataBroker.dispatch(0, 'CallSign', 'KD2ABC');
      expect(DataBroker.getValue<String>(0, 'CallSign', ''), equals('KD2ABC'));
    });

    test('stores and retrieves bool values', () {
      DataBroker.dispatch(0, 'GpsEnabled', true);
      expect(DataBroker.getValue<bool>(0, 'GpsEnabled', false), isTrue);
    });

    test('returns default when key not found', () {
      expect(DataBroker.getValue<int>(0, 'Missing', 42), equals(42));
      expect(DataBroker.getValue<String>(0, 'Missing', 'def'), equals('def'));
    });

    test('hasValue works correctly', () {
      expect(DataBroker.hasValue(0, 'Test'), isFalse);
      DataBroker.dispatch(0, 'Test', 'hello');
      expect(DataBroker.hasValue(0, 'Test'), isTrue);
    });

    test('removeValue works', () {
      DataBroker.dispatch(0, 'Test', 123);
      expect(DataBroker.removeValue(0, 'Test'), isTrue);
      expect(DataBroker.hasValue(0, 'Test'), isFalse);
      expect(DataBroker.removeValue(0, 'Test'), isFalse);
    });

    test('device scoping isolates data', () {
      DataBroker.dispatch(0, 'Key', 'global');
      DataBroker.dispatch(100, 'Key', 'radio1');
      DataBroker.dispatch(101, 'Key', 'radio2');

      expect(DataBroker.getValue<String>(0, 'Key', ''), equals('global'));
      expect(DataBroker.getValue<String>(100, 'Key', ''), equals('radio1'));
      expect(DataBroker.getValue<String>(101, 'Key', ''), equals('radio2'));
    });
  });

  group('DataBroker persistence (device 0)', () {
    test('int values persist to settings store', () {
      DataBroker.dispatch(0, 'Volume', 7);
      expect(settingsStore.readInt('Volume', null), equals(7));
    });

    test('string values persist to settings store', () {
      DataBroker.dispatch(0, 'CallSign', 'W1ABC');
      expect(settingsStore.readString('CallSign', null), equals('W1ABC'));
    });

    test('bool values persist to settings store', () {
      DataBroker.dispatch(0, 'Enabled', true);
      expect(settingsStore.readBool('Enabled', false), isTrue);
    });

    test('non-device-0 values do NOT persist', () {
      DataBroker.dispatch(100, 'RadioData', 'test');
      expect(settingsStore.containsKey('RadioData'), isFalse);
    });

    test('removeValue also removes from settings store', () {
      DataBroker.dispatch(0, 'Setting', 'value');
      DataBroker.removeValue(0, 'Setting');
      expect(settingsStore.containsKey('Setting'), isFalse);
    });

    test('getValue falls back to settings store for device 0', () {
      // Write directly to settings store (simulating previous session)
      settingsStore.writeInt('OldSetting', 99);

      // DataBroker should find it in settings store
      expect(DataBroker.getValue<int>(0, 'OldSetting', 0), equals(99));
    });
  });

  group('DataBroker subscriptions', () {
    test('callback fires on dispatch', () async {
      final client = DataBrokerClient();
      int receivedDevice = -1;
      String receivedName = '';
      Object? receivedData;

      client.subscribe(100, 'State', (deviceId, name, data) {
        receivedDevice = deviceId;
        receivedName = name;
        receivedData = data;
      });

      DataBroker.dispatch(100, 'State', 'Connected');

      // Callbacks are posted via Future.microtask
      await Future.delayed(Duration.zero);

      expect(receivedDevice, equals(100));
      expect(receivedName, equals('State'));
      expect(receivedData, equals('Connected'));

      client.dispose();
    });

    test('AllDevices subscription receives from any device', () async {
      final client = DataBrokerClient();
      final received = <int>[];

      client.subscribe(DataBroker.allDevices, 'State', (deviceId, name, data) {
        received.add(deviceId);
      });

      DataBroker.dispatch(100, 'State', 'a');
      DataBroker.dispatch(101, 'State', 'b');
      DataBroker.dispatch(0, 'State', 'c');

      await Future.delayed(Duration.zero);

      expect(received, containsAll([100, 101, 0]));

      client.dispose();
    });

    test('AllNames subscription receives all names for a device', () async {
      final client = DataBrokerClient();
      final names = <String>[];

      client.subscribeAll(100, (deviceId, name, data) {
        names.add(name);
      });

      DataBroker.dispatch(100, 'State', 'x');
      DataBroker.dispatch(100, 'Volume', 5);
      DataBroker.dispatch(100, 'Channel', 3);

      await Future.delayed(Duration.zero);

      expect(names, containsAll(['State', 'Volume', 'Channel']));

      client.dispose();
    });

    test('unsubscribe stops callbacks', () async {
      final client = DataBrokerClient();
      int callCount = 0;

      client.subscribe(100, 'State', (d, n, v) {
        callCount++;
      });

      DataBroker.dispatch(100, 'State', 'a');
      await Future.delayed(Duration.zero);
      expect(callCount, equals(1));

      client.unsubscribe(100, 'State');
      DataBroker.dispatch(100, 'State', 'b');
      await Future.delayed(Duration.zero);
      expect(callCount, equals(1)); // unchanged

      client.dispose();
    });

    test('dispose unsubscribes all', () async {
      final client = DataBrokerClient();
      int callCount = 0;

      client.subscribe(100, 'State', (d, n, v) => callCount++);
      client.subscribe(100, 'Volume', (d, n, v) => callCount++);

      client.dispose();

      DataBroker.dispatch(100, 'State', 'x');
      DataBroker.dispatch(100, 'Volume', 5);
      await Future.delayed(Duration.zero);
      expect(callCount, equals(0));
    });

    test('store=false does not store the value', () {
      DataBroker.dispatch(1, 'LogInfo', 'test message', store: false);
      expect(DataBroker.hasValue(1, 'LogInfo'), isFalse);
    });
  });

  group('DataBroker device operations', () {
    test('getDeviceValues returns all values for a device', () {
      DataBroker.dispatch(100, 'State', 'Connected');
      DataBroker.dispatch(100, 'Volume', 8);
      DataBroker.dispatch(101, 'State', 'Disconnected');

      final values = DataBroker.getDeviceValues(100);
      expect(values.length, equals(2));
      expect(values['State'], equals('Connected'));
      expect(values['Volume'], equals(8));
    });

    test('clearDevice removes all data for a device', () {
      DataBroker.dispatch(100, 'A', 1);
      DataBroker.dispatch(100, 'B', 2);
      DataBroker.dispatch(101, 'A', 3);

      DataBroker.clearDevice(100);

      expect(DataBroker.hasValue(100, 'A'), isFalse);
      expect(DataBroker.hasValue(100, 'B'), isFalse);
      expect(DataBroker.hasValue(101, 'A'), isTrue);
    });

    test('deleteDevice dispatches null then removes', () async {
      final client = DataBrokerClient();
      final nulled = <String>[];

      client.subscribe(100, DataBroker.allNames, (deviceId, name, data) {
        if (data == null) nulled.add(name);
      });

      DataBroker.dispatch(100, 'State', 'Connected');
      DataBroker.dispatch(100, 'Volume', 8);
      await Future.delayed(Duration.zero);

      DataBroker.deleteDevice(100);
      await Future.delayed(Duration.zero);

      expect(nulled, containsAll(['State', 'Volume']));
      expect(DataBroker.hasValue(100, 'State'), isFalse);

      client.dispose();
    });
  });

  group('DataBroker data handlers', () {
    test('add and get handler', () {
      final handler = Object();
      expect(DataBroker.addDataHandler('test', handler), isTrue);
      expect(DataBroker.getDataHandler('test'), same(handler));
    });

    test('duplicate handler name returns false', () {
      DataBroker.addDataHandler('test', Object());
      expect(DataBroker.addDataHandler('test', Object()), isFalse);
    });

    test('hasDataHandler works', () {
      expect(DataBroker.hasDataHandler('test'), isFalse);
      DataBroker.addDataHandler('test', Object());
      expect(DataBroker.hasDataHandler('test'), isTrue);
    });

    test('removeDataHandler works', () {
      DataBroker.addDataHandler('test', Object());
      expect(DataBroker.removeDataHandler('test'), isTrue);
      expect(DataBroker.hasDataHandler('test'), isFalse);
      expect(DataBroker.removeDataHandler('test'), isFalse);
    });

    test('removeAllDataHandlers clears everything', () {
      DataBroker.addDataHandler('a', Object());
      DataBroker.addDataHandler('b', Object());
      DataBroker.removeAllDataHandlers();
      expect(DataBroker.hasDataHandler('a'), isFalse);
      expect(DataBroker.hasDataHandler('b'), isFalse);
    });
  });

  group('DataBrokerClient convenience methods', () {
    test('logInfo dispatches to device 1', () async {
      final listener = DataBrokerClient();
      String? logMsg;

      listener.subscribe(1, 'LogInfo', (d, n, data) {
        logMsg = data as String?;
      });

      final client = DataBrokerClient();
      client.logInfo('Test log');

      await Future.delayed(Duration.zero);
      expect(logMsg, equals('Test log'));

      client.dispose();
      listener.dispose();
    });

    test('logError dispatches to device 1', () async {
      final listener = DataBrokerClient();
      String? logMsg;

      listener.subscribe(1, 'LogError', (d, n, data) {
        logMsg = data as String?;
      });

      final client = DataBrokerClient();
      client.logError('Something failed');

      await Future.delayed(Duration.zero);
      expect(logMsg, equals('Something failed'));

      client.dispose();
      listener.dispose();
    });

    test('disposed client ignores dispatch and log calls', () {
      final client = DataBrokerClient();
      client.dispose();
      // Should not throw
      client.dispatch(0, 'Test', 'value');
      client.logInfo('test');
      client.logError('test');
    });

    test('disposed client throws on subscribe', () {
      final client = DataBrokerClient();
      client.dispose();
      expect(() => client.subscribe(0, 'Test', (d, n, v) {}),
          throwsStateError);
    });
  });
}
