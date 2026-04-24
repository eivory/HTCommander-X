import '../../core/data_broker.dart';

/// Global macOS-platform diagnostic flag. Gate noisy per-frame prints
/// (TX/RX hex dumps, PCM counters, ffplay stats) behind this so the
/// terminal stays clean by default. Toggle via DataBroker key
/// ``MacOsDebug`` (stored under device 0 / SharedPreferences).
bool get macOsDebug =>
    DataBroker.getValue<bool>(0, 'MacOsDebug', false);

/// Prints [message] only when [macOsDebug] is true. Prefer this over
/// raw `print()` for any diagnostic output that fires per-frame or
/// otherwise produces enough volume to be noisy in normal use. Keep
/// one-shot lifecycle messages (spawn, open, connect result, error)
/// as raw prints — those are useful even when debug is off.
void dprint(String message) {
  if (macOsDebug) {
    // ignore: avoid_print
    print(message);
  }
}
