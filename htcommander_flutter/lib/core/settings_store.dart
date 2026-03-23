import 'package:shared_preferences/shared_preferences.dart';

/// Platform-agnostic settings persistence.
/// Wraps SharedPreferences for Flutter (Linux, Windows, Android, iOS).
abstract class SettingsStore {
  void writeString(String key, String value);
  String? readString(String key, String? defaultValue);
  void writeInt(String key, int value);
  int? readInt(String key, int? defaultValue);
  void writeBool(String key, bool value);
  bool readBool(String key, bool defaultValue);
  void deleteValue(String key);
}

/// SharedPreferences-backed implementation of SettingsStore.
class SharedPrefsSettingsStore implements SettingsStore {
  final SharedPreferences _prefs;

  SharedPrefsSettingsStore(this._prefs);

  static Future<SharedPrefsSettingsStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsSettingsStore(prefs);
  }

  @override
  void writeString(String key, String value) {
    _prefs.setString(key, value);
  }

  @override
  String? readString(String key, String? defaultValue) {
    return _prefs.getString(key) ?? defaultValue;
  }

  @override
  void writeInt(String key, int value) {
    _prefs.setInt(key, value);
  }

  @override
  int? readInt(String key, int? defaultValue) {
    final val = _prefs.getInt(key);
    return val ?? defaultValue;
  }

  @override
  void writeBool(String key, bool value) {
    _prefs.setBool(key, value);
  }

  @override
  bool readBool(String key, bool defaultValue) {
    return _prefs.getBool(key) ?? defaultValue;
  }

  @override
  void deleteValue(String key) {
    _prefs.remove(key);
  }
}
