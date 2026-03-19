# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build individual projects
dotnet build HTCommander.Core/HTCommander.Core.csproj
dotnet build HTCommander.Platform.Linux/HTCommander.Platform.Linux.csproj
dotnet build HTCommander.Desktop/HTCommander.Desktop.csproj

# Build original WinForms project (requires Windows or cross-compile flag)
dotnet build src/HTCommander.csproj -p:EnableWindowsTargeting=true

# Run the Avalonia Desktop app (Linux)
dotnet run --project HTCommander.Desktop/HTCommander.Desktop.csproj

# Linux packaging
./packaging/linux/build-appimage.sh Release
./packaging/linux/build-deb.sh Release
```

No test projects exist in this codebase.

## Architecture

HTCommander is a ham radio controller for Bluetooth-enabled handhelds (UV-PRO, VR-N75, VR-N76, VR-N7500, etc.). It was migrated from a monolithic WinForms app to a multi-project cross-platform architecture.

### Project Dependency Graph

```
HTCommander.Desktop (Avalonia UI) ──┐
                                     ├──> HTCommander.Core (all business logic)
HTCommander.Platform.Linux ──────────┤
HTCommander.Platform.Windows ────────┘
src/ (original WinForms) ────────────┘
```

### HTCommander.Core (net9.0) — 154 files, zero UI dependencies

All radio protocol logic, data handlers, codecs, and parsers. Key subsystems:
- **Radio.cs**: GAIA protocol over Bluetooth RFCOMM — the central class managing radio connections, commands, channels, GPS
- **DataBroker / DataBrokerClient**: Global pub/sub event bus. Device-scoped data channels with optional persistence via `ISettingsStore`. Uses `SynchronizationContext.Post()` for UI thread marshalling
- **Interfaces/**: Platform abstractions (`IPlatformServices`, `IRadioBluetooth`, `IAudioService`, `ISpeechService`, `ISettingsStore`, `IFilePickerService`, `IPlatformUtils`, `IRadioHost`, `IWhisperEngine`)
- **radio/**: AX.25 packet protocol, SoftwareModem (DSP), GAIA frame encode/decode
- **SSTV/**: Slow-scan TV image encode/decode using SkiaSharp (not System.Drawing)
- **VoiceHandler**: Speech processing — takes `ISpeechService` constructor param, uses `VoiceHandler.WhisperEngineFactory` static delegate for STT

### Platform Projects

**Platform.Windows** (net9.0-windows): WinRT Bluetooth, NAudio/WASAPI audio, System.Speech TTS, Windows Registry settings

**Platform.Linux** (net9.0): Direct native RFCOMM sockets for Bluetooth, BlueZ D-Bus for device discovery/ACL, PortAudio audio, espeak-ng TTS, JSON file settings at `~/.config/HTCommander/`

### HTCommander.Desktop (net9.0) — Avalonia UI

10 tab controls + 40 dialogs + Mapsui map + left-side radio info panel with radio image overlay. Platform auto-detected at startup via reflection in `Program.cs`. Conditional project references load Windows or Linux platform assembly. Dark theme (`RequestedThemeVariant="Dark"` in App.axaml). Menu bar (File/Settings/View/About), toolbar, and blue status bar. Image assets in `Assets/` are auto-included as `AvaloniaResource` via csproj ItemGroup. Radio panel shows device image with screen overlay (VFO frequencies, signal), plus VFO cards, RSSI/TX bars, status grid, and channel list.

### src/ (net9.0-windows) — Original WinForms app

Still builds and runs on Windows. References Core. Files moved to Core are excluded via `<Compile Remove>` in the csproj. Contains Windows-only code: RadioAudio.cs (NAudio+WinRT), Microphone.cs, WhisperEngine.cs, AirplaneMarker.cs (GMap.NET), and WinForms UI.

## Key Patterns

### DataBroker event flow
Components communicate via `DataBroker.Dispatch(deviceId, name, data)` and `broker.Subscribe(deviceId, name, callback)`. Device 0 = global settings (auto-persisted to ISettingsStore — int/string/bool written directly, complex types JSON-serialized with `~~JSON:{type}:{json}` prefix). Device 1 = app-level events. Device 100+ = connected radios. All UI callbacks are marshalled via `SynchronizationContext`. Settings dialog reads/writes via `DataBroker.GetValue<T>(0, name, default)` and `DataBroker.Dispatch(0, name, value)`.

### Radio connection lifecycle
1. `IPlatformServices.CreateRadioBluetooth(IRadioHost)` creates transport
2. `Radio.Connect()` → `IRadioBluetooth.Connect()` → async BT connection
3. Transport fires `OnConnected` → Radio sends GAIA GET_DEV_INFO, READ_SETTINGS, etc.
4. Transport fires `ReceivedData(Exception, byte[])` → Radio processes GAIA responses
5. Radio dispatches state/data to DataBroker → UI tabs update via subscriptions

### IRadioHost interface
Breaks circular dependency: platform BT transports need `Radio.Debug()` and `Radio.Disconnect()` but can't reference Radio directly. `IRadioHost` in Core defines `MacAddress`, `Debug(string)`, `Disconnect(string, RadioState)`. Radio implements it.

### Linux Bluetooth (direct RFCOMM sockets)
Connection flow: BlueZ D-Bus for ACL connect + device discovery → SDP channel discovery via `sdptool` (fallback: probe channels 1-30) → native RFCOMM socket per candidate channel → **GAIA verification**: send GET_DEV_ID, accept only channels responding with valid `FF 01` header → non-blocking read loop.

**Critical**: `poll()` and `SO_RCVTIMEO` do NOT work on RFCOMM sockets (kernel/BlueZ bug). The read loop must use `O_NONBLOCK` + `Thread.Sleep(50)` instead. The `VerifyGaiaResponse` step uses `poll()` for a single check and works; the issue only manifests in sustained read loops.

**Critical**: `OnConnected` must fire on a background thread (`ThreadPool.QueueUserWorkItem`) so Radio's ~35 initialization commands don't block the read loop. Without concurrent reads, RFCOMM flow control stalls.

RFCOMM channel numbers vary by radio model and even between connections (VR-N76 uses channel 1 or 4 for commands, channel 2 for audio). Never hardcode channels.

### GAIA protocol frame format
```
[0xFF] [0x01] [flags] [body_length] [group_hi] [group_lo] [cmd_hi] [cmd_lo] [body...]
```
- `body_length` = cmd body only (excludes 4-byte command header)
- Total frame = body_length + 8
- Reply bit: `cmd_hi | 0x80`
- Radio frequency values stored in Hz (divide by 1,000,000 for MHz display)

## Code Conventions

- **Target**: net9.0 (Core, Linux, Desktop), net9.0-windows (WinForms, Platform.Windows)
- **Nullable**: disabled across all projects
- **ImplicitUsings**: disabled — all usings are explicit
- **AllowUnsafeBlocks**: enabled (SBC codec, SkiaSharp pixel ops, native P/Invoke)
- **Namespace**: `HTCommander` for Core and src/, `HTCommander.Platform.Linux`, `HTCommander.Platform.Windows`, `HTCommander.Desktop` for other projects
- Radio dispatches state as **string** (e.g., `"Connected"`, not the enum), so subscribers must compare strings
- `Utils` is a **partial class** — cross-platform methods in Core, WinForms-specific (SetDoubleBuffered, SendMessage) in src/
- Avalonia dialogs use `Confirmed` bool property pattern for OK/Cancel results
- SSTV imaging uses SkiaSharp (`SKBitmap`), not System.Drawing. WinForms bridge: `SkiaBitmapConverter`
- Avalonia Desktop uses **dark theme** (`RequestedThemeVariant="Dark"`) — tab headers use `#2D2D30`, text areas use `#1E1E1E`/`#D4D4D4`. Never use `Silver`, `LightGray`, or `#F0F0F0` backgrounds
- Settings are stored as int 0/1 for booleans that need cross-platform compat (e.g., `AllowTransmit`, `WebServerEnabled`), use `DataBroker.GetValue<int>(0, key, 0) == 1` to read

## Repository Structure

- `docs/CrossPlatformArchitecture.md` — detailed architecture documentation with design decision rationale
- `packaging/linux/` — AppImage and .deb build scripts
- `HTCommander.setup/` — Windows MSI installer project
- Two git remotes: `origin` (Ylianst/HTCommander upstream), `fork` (dikei100/HTCommander)
- Active branch: `cross-platform`

## Related Projects

- [khusmann/benlink](https://github.com/khusmann/benlink) — Python library for the same radios; reference for GAIA protocol, RFCOMM channel discovery, and audio codec details
- [SarahRoseLives/flutter_benlink](https://github.com/SarahRoseLives/flutter_benlink) — Flutter/Dart implementation; reference for initialization sequence and VR-N76 quirks (SYNC_SETTINGS handshake)
