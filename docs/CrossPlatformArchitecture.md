# HTCommander Cross-Platform Architecture

## Overview

HTCommander has been restructured from a monolithic Windows Forms application into a multi-project solution supporting Windows and Linux, with the architecture designed for future Android support.

## Solution Structure

```
HTCommander.sln
├── HTCommander.Core/              (net9.0 — all business logic, no UI/platform deps)
├── HTCommander.Platform.Windows/  (net9.0-windows — WinRT BT, NAudio, Registry, System.Speech)
├── HTCommander.Platform.Linux/    (net9.0 — BlueZ BT, PortAudio, espeak-ng, JSON settings)
├── HTCommander.Desktop/           (net9.0 — Avalonia Desktop UI, 11 tabs + 45 dialogs + Mapsui map)
├── src/                           (net9.0-windows — original WinForms app, still works)
├── packaging/linux/               (AppImage + .deb build scripts)
├── HTCommander.setup/             (Windows MSI installer)
└── Updater/                       (existing updater)
```

## Core Project (HTCommander.Core)

**154 C# files** — contains all business logic with zero Windows/UI dependencies.

### What's in Core
- **Radio protocol**: Radio.cs (GAIA protocol), AX25Session, AX25Packet, SoftwareModem
- **Data models**: RadioSettings, RadioChannelInfo, RadioDevInfo, RadioHtStatus, RadioPosition, etc.
- **Handlers**: AprsHandler, BbsHandler, VoiceHandler, Torrent, LogStore, PacketStore, FrameDeduplicator, MailStore, WinlinkClient, AirplaneHandler, GpsSerialHandler
- **Libraries**: hamlib (DSP/modem), sbc (codec), SSTV (image encode/decode), AprsParser, GPS/NMEA, WinLink, Airplanes, Adventurer
- **Infrastructure**: DataBroker, DataBrokerClient, AppCallbacks, AudioResampler, WavFileWriter, SkiaImageHelper

### Platform Abstraction Interfaces
All defined in `Core/Interfaces/`:

| Interface | Purpose | Windows Impl | Linux Impl |
|-----------|---------|-------------|------------|
| `IPlatformServices` | Service factory | WinPlatformServices | LinuxPlatformServices |
| `IRadioBluetooth` | BT command transport | RadioBluetoothWin (WinRT) | LinuxRadioBluetooth (BlueZ D-Bus) |
| `IRadioAudioTransport` | BT audio transport | WinRadioAudioTransport | LinuxRadioAudioTransport |
| `IAudioService` | Audio I/O | WinAudioService (NAudio/WASAPI) | LinuxAudioService (PortAudio) |
| `ISpeechService` | Text-to-speech | WinSpeechService (System.Speech) | LinuxSpeechService (espeak-ng) |
| `ISettingsStore` | Persistent settings | RegistrySettingsStore | JsonFileSettingsStore |
| `IFilePickerService` | File dialogs | WinFilePickerService (WinForms) | LinuxFilePickerService (zenity) |
| `IPlatformUtils` | OS utilities | WinPlatformUtils | LinuxPlatformUtils |
| `IRadioHost` | Radio→transport callback | Radio implements this | Radio implements this |
| `IRadioAudio` | Audio abstraction | RadioAudio implements | (pending) |
| `IWhisperEngine` | Speech-to-text | WhisperEngine implements | (pending) |

## Key Design Decisions

### 1. DataBroker: SynchronizationContext instead of Control.BeginInvoke

**Before**: `DataBroker` used `System.Windows.Forms.Control` for UI thread marshalling.
**After**: Uses `SynchronizationContext.Post()` — works with WinForms, Avalonia, and Android.

```csharp
// Old (WinForms-only):
uiContext.BeginInvoke(callback, deviceId, name, data);

// New (any UI framework):
syncContext.Post(_ => callback(deviceId, name, data), null);
```

### 2. ISettingsStore instead of RegistryHelper

**Before**: `DataBroker` directly used `RegistryHelper` for persistence.
**After**: Uses `ISettingsStore` interface. Windows uses Registry, Linux uses `~/.config/HTCommander/settings.json`.

### 3. IRadioHost breaks circular dependency

**Problem**: Platform BT transport needs to call `Radio.Debug()` and `Radio.Disconnect()`, but Radio is in Core while transports are in platform projects.
**Solution**: `IRadioHost` interface in Core defines `MacAddress`, `Debug()`, `Disconnect()`. Radio implements it. Transports reference only the interface.

### 4. Utils.cs as partial class

**Problem**: `Utils.cs` contains both cross-platform helpers (BytesToHex, GetShort, etc.) and WinForms-specific code (SetDoubleBuffered, AddFormattedEntry).
**Solution**: Split into `partial class Utils` — Core has the cross-platform part, src/ has the Windows-specific part.

### 5. SstvMonitor: SkiaSharp replaces System.Drawing

**Before**: Used `System.Drawing.Bitmap` with `BitmapData.LockBits` and `Marshal.Copy`.
**After**: Uses `SKBitmap` with `InstallPixels()`. SkiaSharp works on all platforms.

For the WinForms project, `SkiaBitmapConverter` bridges `SKBitmap` ↔ `System.Drawing.Bitmap` via PNG encode/decode.

### 6. VoiceHandler: ISpeechService + IWhisperEngine

**Before**: Directly used `System.Speech.SpeechSynthesizer` and `WhisperEngine`.
**After**: Takes `ISpeechService` via constructor. Uses `VoiceHandler.WhisperEngineFactory` static delegate for STT creation. `WavFileWriter` replaces NAudio's `WaveFileWriter`.

### 7. AppCallbacks: Core→Host bridge

**Problem**: Core code (Radio.cs) called `Program.BlockBoxEvent()` which is in the host app.
**Solution**: `AppCallbacks` static class with `Action<string>` delegates that the host app wires up at startup.

### 8. RadioState and CompatibleDevice extracted to Core

**Before**: Nested types inside `Radio` class (`Radio.RadioState`, `Radio.CompatibleDevice`).
**After**: Top-level types in Core. All references updated (e.g., `Radio.RadioState.Connected` → `RadioState.Connected`).

## Linux Bluetooth Implementation

### Strategy: BlueZ ProfileManager1 D-Bus API

The Linux BT transport (`LinuxRadioBluetooth`) uses BlueZ's ProfileManager1 to get RFCOMM connections:

1. **Register** an SPP profile via `ProfileManager1.RegisterProfile()` with UUID `00001101`
2. **Connect** via `device.ConnectProfile(SPP_UUID)`
3. **Receive** file descriptor in `Profile1.NewConnection()` callback
4. **dup()** the fd before the D-Bus callback returns (critical — Tmds.DBus closes the original)
5. **Read/write** using native `read()`/`write()` P/Invoke on the fd

**Why not ConnectProfile alone?** BlueZ requires a registered profile handler before `ConnectProfile` works for SPP. Without it: `org.bluez.Error.BREDR.ProfileUnavailable`.

**Why not sdptool?** Deprecated on modern BlueZ 5; requires SDP compatibility daemon which is disabled by default.

**Why dup()?** Tmds.DBus passes the fd as `CloseSafeHandle` which auto-closes when `NewConnection` returns. `dup()` creates a copy we own.

**Why native read()/write() instead of NetworkStream?** .NET's Socket/NetworkStream may not correctly handle raw Bluetooth RFCOMM file descriptors from D-Bus.

**Fallback**: If ProfileManager1 doesn't deliver an fd within 10 seconds, probes channels 1-30 with native RFCOMM sockets, sending a GAIA GET_DEV_ID command and checking for response.

### Current Status (Known Issue)

The BlueZ ProfileManager1 connection succeeds — fd is obtained, validated (correct socket type), and writes succeed. However, the radio does not respond to GAIA commands. The fd socket diagnostics show `domain=AF_BLUETOOTH, type=STREAM, protocol=BTPROTO_RFCOMM` confirming it's a real RFCOMM socket. Investigation is ongoing; the issue may be related to BlueZ's fd handling or the RFCOMM channel selection.

## Avalonia Desktop Application

### Tab Controls (10)
Each tab control is an Avalonia UserControl with DataBroker subscriptions matching the WinForms originals:
Debug, Contacts, Packets, Terminal, BBS, Mail, Torrent, APRS, Voice, Map

### Dialogs (39)
All 39 WinForms dialogs have Avalonia equivalents. Key patterns:
- `WindowStartupLocation="CenterOwner"`
- `Confirmed` property pattern for OK/Cancel dialogs
- `Dispatcher.UIThread.Post()` for broker callback UI updates

### Map Integration
Uses **Mapsui.Avalonia** with OpenStreetMap tiles. `AirplaneMapFeature` replaces the GMap.NET `AirplaneMarker`.

## Data Handler Initialization

Both WinForms and Desktop apps initialize the same set of data handlers:

```csharp
DataBroker.AddDataHandler("FrameDeduplicator", new FrameDeduplicator());
DataBroker.AddDataHandler("SoftwareModem", new SoftwareModem());
DataBroker.AddDataHandler("PacketStore", new PacketStore());
DataBroker.AddDataHandler("VoiceHandler", new VoiceHandler(platformServices.Speech));
DataBroker.AddDataHandler("LogStore", new LogStore());
DataBroker.AddDataHandler("AprsHandler", new AprsHandler());
DataBroker.AddDataHandler("Torrent", new Torrent());
DataBroker.AddDataHandler("BbsHandler", new BbsHandler());
DataBroker.AddDataHandler("MailStore", new MailStore());
DataBroker.AddDataHandler("WinlinkClient", new WinlinkClient());
DataBroker.AddDataHandler("AirplaneHandler", new AirplaneHandler());
DataBroker.AddDataHandler("GpsSerialHandler", new GpsSerialHandler());
```

## Linux Packaging

### AppImage
```bash
./packaging/linux/build-appimage.sh [Release|Debug]
```
Self-contained, no install required. Output: `releases/HTCommander-x86_64.AppImage`

### Debian Package
```bash
./packaging/linux/build-deb.sh [Release|Debug]
```
Dependencies: `libportaudio2`, `bluez`. Recommends: `espeak-ng`.

## Future: Android Port

The architecture supports Android without rework:
- All interfaces include `RequestPermissionsAsync()` and `OnPause()`/`OnResume()` lifecycle methods
- Create `HTCommander.Platform.Android/` implementing `IPlatformServices` with Android BT/Audio/TTS
- Create `HTCommander.Android/` with `AvaloniaMainActivity` — Avalonia renders the same XAML on Android
- `JsonFileSettingsStore` works on Android with a different base path
