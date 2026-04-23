# macOS Setup

HTCommander-X supports macOS via the [bendio](https://github.com/eivory/bendio)
Python library, which handles BLE transport to the radio. The Flutter app
spawns `bendio` as a subprocess and talks to it over JSON-RPC on stdio.

**Current status:** Phase A — BLE control only. You can connect, scan, change
channels, read/write settings, see status events. Audio (RX + TX) is Phase B.

## Why a subprocess?

macOS doesn't expose Classic RFCOMM the way Linux/Windows do, and the
UV-PRO's BLE control channel needs CoreBluetooth. Rather than port bendio's
BLE stack to Dart, we reuse the battle-tested Python library. Zero code
changes on the Linux/Windows path.

## Prerequisites

- macOS 12+ (CoreBluetooth is what macOS exposes to third-party apps)
- [Flutter](https://docs.flutter.dev/get-started/install/macos) stable
- Python 3.10+
- Xcode command-line tools (`xcode-select --install`)

## One-time setup

### 1. Scaffold the macOS Runner

From `htcommander_flutter/`:

```bash
flutter create --platforms=macos .
```

This generates the `macos/` Xcode project. It won't touch existing Linux,
Windows, or Android code.

### 2. Add TCC (privacy) descriptions

Edit `macos/Runner/Info.plist`. Inside the top-level `<dict>`, add:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>HTCommander-X uses Bluetooth to talk to your radio.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>HTCommander-X uses Bluetooth to talk to your radio.</string>
<key>NSMicrophoneUsageDescription</key>
<string>HTCommander-X uses the microphone for radio voice transmit.</string>
```

macOS attributes the bendio subprocess's Bluetooth use to HTCommander-X
(the "responsible process"), so the system permission prompt appears when
the Flutter app first scans — not when Python spawns.

### 3. Allow outbound network + JIT in the entitlements

Edit `macos/Runner/DebugProfile.entitlements` **and**
`macos/Runner/Release.entitlements`. Both need:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

(Flutter adds this by default in debug but not release.)

No additional Bluetooth entitlement is needed — the TCC description in
Info.plist is sufficient for a non-sandboxed app. If you later enable the
App Sandbox, add `com.apple.security.device.bluetooth` as well.

### 4. Install bendio

```bash
pip3 install git+https://github.com/eivory/bendio.git
```

Verify:

```bash
python3 -m bendio.cli server
# should block waiting for stdin; Ctrl+C to exit
```

## Running

```bash
cd htcommander_flutter
flutter run -d macos
```

First launch will prompt for Bluetooth access. Grant it and you can then
scan for your radio from the Communication screen.

## Pairing note

macOS hides the real Bluetooth MAC address from apps and gives each device
a per-app UUID. That UUID is what the "address" field contains on macOS.
Store it and reuse it — it's stable for the life of the pairing.

If a previously-paired radio doesn't show up in a scan, it may be that
macOS has it connected in the background. Either disconnect it from System
Settings → Bluetooth, or connect directly by its stored UUID.

## Troubleshooting

**"bendio exited (code N)" on connect**
- Ensure `pip3 show bendio` resolves. The Flutter app invokes
  `python3 -m bendio.cli server`, so the Python that's first in `PATH` when
  the app launches must be the one where you installed bendio.
- If you use `pyenv`/`asdf`/etc, launch Flutter from a shell where
  `python3 -c "import bendio"` works, or install bendio system-wide.

**No scan prompt**
- Delete and rebuild the Runner app to reset TCC state:
  `rm -rf build/macos && flutter clean && flutter run -d macos`
- If the prompt was denied, enable it in System Settings → Privacy &
  Security → Bluetooth.

**Radio connects but no indications arrive**
- Open a separate terminal and run `bendio sniff <UUID>` against the same
  radio (while HTCommander-X is disconnected). If that shows traffic, the
  BLE path works; the issue is in the Dart bridge. If it shows nothing,
  the radio or macOS pairing is the problem.

## What's in Phase B

Audio (RX + TX) is deferred. It needs a second channel between Flutter and
bendio for SBC-encoded PCM — likely a Unix socket since stdio is reserved
for JSON-RPC. Broadcast FM audio will remain unavailable on any platform
(firmware doesn't route it to Bluetooth; see
[bendio/docs/PROTOCOL_NOTES.md](https://github.com/eivory/bendio/blob/main/docs/PROTOCOL_NOTES.md)).

## Architecture

```
┌─────────────────────────┐       stdio JSON-RPC       ┌──────────────────┐
│ HTCommander-X (Flutter) │ ─────────────────────────► │ bendio (Python)  │
│   Radio class           │                            │   BleLink (bleak)│
│   MacOsRadioBluetooth   │ ◄───────────────────────── │   CoreBluetooth  │
│   (Dart subprocess I/O) │       ble_indication       └────────┬─────────┘
└─────────────────────────┘                                     │
                                                                ▼
                                                          UV-PRO / Benshi
                                                              radio
```

Phase A reuses HTCommander-X's existing Radio state machine end-to-end —
the macOS transport just delivers raw Message bytes, same as what the
Linux/Windows RFCOMM transports produce after GAIA decoding. BLE doesn't
use GAIA framing, so the decode step is a no-op on macOS.
