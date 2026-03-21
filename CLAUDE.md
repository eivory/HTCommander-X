# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Prerequisites

**.NET SDK 9.0** is required. On Linux, also install: `libportaudio2`, `bluez` (runtime deps), `espeak-ng` (optional TTS).

## Build Commands

```bash
# Build entire solution
dotnet build HTCommander.sln

# Build individual projects
dotnet build HTCommander.Core/HTCommander.Core.csproj
dotnet build HTCommander.Platform.Linux/HTCommander.Platform.Linux.csproj
dotnet build HTCommander.Desktop/HTCommander.Desktop.csproj

# Build original WinForms project (requires Windows or cross-compile flag)
dotnet build src/HTCommander.csproj -p:EnableWindowsTargeting=true

# Run the Avalonia Desktop app (Linux)
dotnet run --project HTCommander.Desktop/HTCommander.Desktop.csproj

# Publish self-contained (Linux)
dotnet publish HTCommander.Desktop/HTCommander.Desktop.csproj -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=false -p:PublishTrimmed=false -o publish/linux-x64

# Publish self-contained (Windows, cross-compiled from Linux)
dotnet publish HTCommander.Desktop/HTCommander.Desktop.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:PublishTrimmed=false -p:EnableWindowsTargeting=true -o publish/win-x64

# Linux packaging
./packaging/linux/build-appimage.sh Release
./packaging/linux/build-deb.sh Release
```

No test projects exist in this codebase.

## CI/CD

GitHub Actions workflow (`.github/workflows/release.yml`) triggers on version tags (`v*`). Builds Linux and Windows self-contained packages on `ubuntu-latest`, produces: AppImage, .deb, .rpm, .pkg.tar.zst, and Windows zip. All artifacts are uploaded as a GitHub Release with auto-generated notes.

**Versioning**: The assembly version is set in `HTCommander.Desktop/HTCommander.Desktop.csproj` `<Version>` property. This must match the git tag (e.g., tag `v0.1.4` → `<Version>0.1.4</Version>`). The About dialog and update checker both read `Assembly.GetEntryAssembly().GetName().Version`. Push to the `fork` remote (dikei100/HTCommander-X) with `--tags` to trigger a release build.

## Architecture

HTCommander is a ham radio controller for Bluetooth-enabled handhelds (UV-Pro, UV-50Pro, GA-5WB, VR-N75, VR-N76, VR-N7500, VR-N7600, RT-660). It was migrated from a monolithic WinForms app to a multi-project cross-platform architecture.

### Project Dependency Graph

```
HTCommander.Desktop (Avalonia UI) ──┐
                                     ├──> HTCommander.Core (all business logic)
HTCommander.Platform.Linux ──────────┤
HTCommander.Platform.Windows ────────┘
src/ (original WinForms) ────────────┘
```

### HTCommander.Core (net9.0) — zero UI dependencies

All radio protocol logic, data handlers, codecs, and parsers. Key subsystems:
- **Radio.cs**: GAIA protocol over Bluetooth RFCOMM — the central class managing radio connections, commands, channels, GPS
- **DataBroker / DataBrokerClient**: Global pub/sub event bus. Device-scoped data channels with optional persistence via `ISettingsStore`. Uses `SynchronizationContext.Post()` for UI thread marshalling
- **Interfaces/**: Platform abstractions (`IPlatformServices`, `IRadioBluetooth`, `IAudioService`, `ISpeechService`, `ISettingsStore`, `IFilePickerService`, `IPlatformUtils`, `IRadioHost`, `IWhisperEngine`, `IVirtualSerialPort`, `IVirtualAudioProvider`)
- **radio/**: AX.25 packet protocol, SoftwareModem (DSP), GAIA frame encode/decode
- **SSTV/**: Slow-scan TV image encode/decode using SkiaSharp (not System.Drawing)
- **VoiceHandler**: Speech processing — takes `ISpeechService` constructor param, uses `VoiceHandler.WhisperEngineFactory` static delegate for STT. Subscribes to `Chat`, `Speak`, `Morse` on AllDevices. Requires `VoiceHandlerEnable` with `{ DeviceId, Language, Model }` before it will transmit — fires when radio State becomes `"Connected"`
- **RadioAudioManager**: Cross-platform audio pipeline (replaces Windows-only `RadioAudio.cs`). Uses `IRadioAudioTransport` for BT audio socket + `IAudioService` for local playback. Handles `TransmitVoicePCM` → SBC encode → RFCOMM, and receive loop → SBC decode → PortAudio output. Created automatically in `Radio` constructor when `platformServices != null`. Supports recording via `WavFileWriter` — `RecordingEnable`/`RecordingDisable` DataBroker events trigger WAV file recording of decoded PCM to `~/Documents/HTCommander/Recordings/`
- **AgwpeServer**: AGWPE TCP server for external TNC client integration. Self-initializing DataBroker handler; auto-starts/stops based on `AgwpeServerEnabled`/`AgwpeServerPort` settings. Includes `AgwpeFrame` (36-byte header protocol) and per-client `AgwpeTcpClientHandler`. Forwards `UniqueDataFrame` as 'U' monitoring frames to connected clients.
- **SmtpServer / ImapServer**: Local SMTP/IMAP servers for Winlink email integration. Wired via DataBroker — SMTP dispatches `MailReceived` on incoming email, IMAP reads mail list via `DataBroker.GetValue<List<WinLinkMail>>(1, "Mails", ...)`. Both read `CallSign`, `StationId`, `WinlinkPassword` from DataBroker for authentication.
- **AudioClipHandler**: Manages audio clips stored as WAV files in `~/Documents/HTCommander/Clips/`. Handles `PlayAudioClip` (reads WAV, resamples to 32kHz, dispatches `TransmitVoicePCM`), `DeleteAudioClip`, `RenameAudioClip`, `SaveAudioClip`, `StopAudioClip`. Publishes `AudioClips` array of `AudioClipEntry` (Name, Duration, Size) on changes.
- **RigctldServer**: Hamlib rigctld TCP server (default port 4532) enabling external software (fldigi, WSJT-X, Direwolf, VaraFM) to control the radio. Implements rigctld text protocol — short-form and long-form commands (`\get_ptt`, `\set_ptt`, `\get_freq`, `\set_freq`, `\get_mode`, `\set_mode`, `\get_vfo`, `\set_vfo`, `\dump_state`). Dispatches `ExternalPttState` (bool) on device 1 when PTT changes; sends 100ms silence frames to `TransmitVoicePCM` to keep radio keyed during external PTT. Auto-starts/stops via `RigctldServerEnabled`/`RigctldServerPort` settings.
- **CatSerialServer**: Virtual serial port emulating Kenwood TS-2000 CAT protocol for VaraFM PTT. ASCII semicolon-terminated commands at 9600 baud. Supports TX/RX (PTT), FA/FB (VFO frequencies), MD (mode), IF (transceiver info), ID (radio ID). Uses `IPlatformServices.CreateVirtualSerialPort()` for platform-specific PTY/COM. Dispatches `ExternalPttState`; publishes `CatPortPath` (string) on device 1. Auto-starts/stops via `CatServerEnabled` setting.
- **VirtualAudioBridge**: Bidirectional audio routing via PulseAudio/PipeWire virtual devices. RX: radio PCM 32kHz → resample to 48kHz → virtual source ("HTCommander Radio Audio"). TX: virtual sink monitor ("HTCommander TX") → resample 48kHz→32kHz → `TransmitVoicePCM`. TX path gated on `ExternalPttState` from RigctldServer/CatSerialServer. Creates PulseAudio modules (`module-null-sink`, `module-virtual-source`), uses `pacat`/`parecord` subprocesses. Auto-starts/stops via `VirtualAudioEnabled` setting.
- **AudioResampler**: Pure managed audio resampler (linear interpolation) for 32kHz↔48kHz conversion. Methods: `Resample16BitMono()`, `ResampleStereoToMono16Bit()`. Replaces Windows-only MediaFoundationResampler.
- **McpServer**: MCP (Model Context Protocol) HTTP server for AI-powered radio control. JSON-RPC 2.0 over `HttpListener` on localhost (default port 5678). `McpTools` exposes 21 tools (radio queries including `get_ht_status` for live RSSI/TX/RX, control including connect/disconnect, debug) that map to DataBroker calls. Connect/disconnect tools dispatch `McpConnectRadio`/`McpDisconnectRadio` events to device 1, handled by MainWindow. `McpResources` exposes dynamic read-only resources (radio info/settings/channels/status, app logs/settings). `McpJsonRpc` handles protocol dispatch. Debug tools (DataBroker inspection, arbitrary event dispatch) gated behind `McpDebugToolsEnabled` setting. Auto-starts/stops via `McpServerEnabled`/`McpServerPort`/`McpDebugToolsEnabled`/`ServerBindAll` settings. `ServerBindAll` enables binding to all interfaces for LAN access. See `docs/MCP-Integration.md` for full implementation details and removal instructions.
- **WebServer**: HTTP static file server for the embedded web interface (`web/` directory). Serves files via `HttpListener` on localhost (default port 8080). Path traversal protection. Auto-starts/stops via `WebServerEnabled`/`WebServerPort` settings. `ServerBindAll` setting (shared with McpServer) switches to `http://*:{port}/` for LAN access. Exposes `/api/config` endpoint returning `{"mcpPort":N,"mcpEnabled":bool}` for the mobile web UI.
- **RepeaterBookClient**: API client for RepeaterBook repeater database. Supports live API search by country/state and CSV import. Haversine distance calculation for proximity sorting. `ToRadioChannel()` converts entries to `RadioChannelInfo` for channel import.
- **AdifExport**: ADIF 3.1.4 format writer for QSO logbook export. Standard `<TAG:length>value` encoding with `<EOR>` record terminators.
- **QsoEntry**: QSO log entry data model with `GetBand()` helper for frequency-to-band conversion (HF through 23cm).

### Platform Projects

**Platform.Windows** (net9.0-windows): WinRT Bluetooth, NAudio/WASAPI audio, System.Speech TTS, Windows Registry settings

**Platform.Linux** (net9.0): Direct native RFCOMM sockets for Bluetooth, BlueZ D-Bus for device discovery/ACL, PortAudio for audio output (always opened as stereo, mono samples duplicated to both channels), `parecord` subprocess for mic capture (PortAudio ALSA capture broken on PipeWire), espeak-ng TTS (22050→32kHz resampling), JSON file settings at `~/.config/HTCommander/`, `LinuxVirtualSerialPort` (PTY pair via `openpty()` P/Invoke, symlinks slave to `~/.config/HTCommander/cat-port`), `LinuxVirtualAudioProvider` (PulseAudio module management via `pactl`, `pacat`/`parecord` subprocesses for virtual device I/O)

### HTCommander.Desktop (net9.0) — Avalonia UI

- 11 tab controls + 45 dialogs + Mapsui map + left-side radio info panel with radio image overlay
- Platform auto-detected at startup via reflection in `Program.cs`; conditional project references load Windows or Linux platform assembly
- Single-instance enforcement via file lock (`~/.config/HTCommander/htcommander.lock`); bypass with `-multiinstance` flag
- Supports Light/Dark/Auto themes via `ThemeDictionaries` in `App.axaml` with `App.SetTheme()`
- Menu bar (File/Radio/View/Help), toolbar, and blue status bar
- Radio menu: Dual Watch, Scan, GPS, Audio Enabled toggle, Software Modem toggle, channel Import/Export — all auto-enable/disable on radio connect/disconnect
- View menu: Radio Panel toggle, All Channels toggle (show/hide empty channel slots, persisted via `ShowAllChannels` setting), Active Radio submenu (visible with 2+ radios, switches active radio panel), Spectrogram, Audio Clips
- Help menu: Radio Information, GPS Information, Check for Updates (`SelfUpdateDialog` — queries GitHub API `dikei100/HTCommander-X/releases/latest`, compares tag version to assembly version, offers "View Release" link), About (shows author, original project credit, version)
- Settings dialog tabs: General, APRS, Voice, Winlink, Servers, Data Sources, Audio, Modem. General tab has "Reset All Settings to Defaults". Audio controls (volume, squelch, output volume, mic gain, mute) in Settings → Audio tab
- Image assets in `Assets/` auto-included as `AvaloniaResource` via csproj ItemGroup
- Radio panel: device image with screen overlay (VFO frequencies, signal), VFO cards (double-click → channel picker, right-click → change channel or edit frequency), RSSI/TX bars, status grid, PTT button, WAV file transmit buttons (visible when connected)
- Channel list sidebar: double-click to edit channel, right-click for "Set as VFO A/B" or "Edit Channel", drag-and-drop to copy channel settings between slots. Channel name colors use `GetThemeBrush("PrimaryText")` and refresh on theme change via `ActualThemeVariantChanged`
- Detachable tabs: right-click any tab header → "Detach Tab" opens content in a separate `DetachedTabDialog` window; closing re-attaches the tab
- VFO channel switching dispatches `ChannelChangeVfoA` / `ChannelChangeVfoB` to the active radio device — no Core changes needed, Radio.cs already handles these
- VFO frequency mode toggle: `vfo_x` is a 2-bit field in `RadioSettings` (bit 0 = VFO A, bit 1 = VFO B; 0=memory, 1=frequency). Toggled via `WriteSettings` with `RadioSettings.ToByteArray(..., vfo_x)` overload. Context menu items only visible when `RadioDevInfo.support_vfo == true`
- Quick Frequency Entry: VFO right-click → "Quick Frequency..." writes a scratch channel (last slot, named "QF") and switches the VFO to it. Works on all radios including those without VFO firmware support. Last-used values persisted via DataBroker device 0.
- RepeaterBook Import: Radio → "Import from RepeaterBook..." dialog with live API search by country/state or CSV import. Filters by band/mode/status/distance. Auto-fill GPS coordinates. Import to auto-fill empty slots or manual start slot.
- Logbook Tab: QSO logging with Add/Edit/Remove and ADIF export. Data persisted on DataBroker device 0 (same pattern as Contacts). Auto-fills frequency/mode from connected radio and callsign from settings.
- Tab order: Communication, Contacts, Logbook, Packets, Terminal, BBS, Mail, Torrent, APRS, Map, Debug

### src/ (net9.0-windows) — Original WinForms app

Still builds and runs on Windows. References Core. Files moved to Core are excluded via `<Compile Remove>` in the csproj. Contains Windows-only code: RadioAudio.cs (NAudio+WinRT), Microphone.cs, WhisperEngine.cs, AirplaneMarker.cs (GMap.NET), and WinForms UI.

## Key Patterns

### DataBroker event flow
Components communicate via `DataBroker.Dispatch(deviceId, name, data)` and `broker.Subscribe(deviceId, name, callback)`. Device 0 = global settings (auto-persisted to ISettingsStore — int/string/bool written directly, complex types JSON-serialized with `~~JSON:{type}:{json}` prefix). Device 1 = app-level events. Device 100+ = connected radios. All UI callbacks are marshalled via `SynchronizationContext`. Settings dialog reads/writes via `DataBroker.GetValue<T>(0, name, default)` and `DataBroker.Dispatch(0, name, value)`.

### Data handler pattern
Data handlers are global objects registered via `DataBroker.AddDataHandler("name", handler)`. Each creates its own `DataBrokerClient` in its parameterless constructor, subscribes to relevant events, and self-initializes. Handlers registered in `MainWindow.InitializeDataHandlers()`: FrameDeduplicator, SoftwareModem, PacketStore, VoiceHandler, LogStore, AprsHandler, Torrent, BbsHandler, MailStore, WinlinkClient, AirplaneHandler, GpsSerialHandler, AgwpeServer, AudioClipHandler, RigctldServer, CatSerialServer, VirtualAudioBridge, McpServer, WebServer. Radio instances are also added as handlers dynamically on connect.

### Tab control DataBroker wiring
Each tab subscribes in its constructor and uses `Dispatcher.UIThread.Post()` for UI updates. Common pattern:
- `broker.Subscribe(1, "ConnectedRadios", ...)` — `Radio[]` array; extract `DeviceId` via reflection since tabs don't reference Radio directly
- `broker.Subscribe(DataBroker.AllDevices, "LockState", ...)` — `RadioLockState` per radio for exclusive access
- `broker.Subscribe(DataBroker.AllDevices, "UniqueDataFrame", ...)` — deduplicated incoming packets
- Tabs that need exclusive radio access (Terminal, BBS, Torrent) use the lock pattern: `Dispatch(radioId, "SetLock", new SetLockData { Usage = "Terminal", RegionId = -1, ChannelId = -1 })` and `Dispatch(radioId, "SetUnlock", new SetUnlockData { Usage = "Terminal" })`
- On startup, tabs call `broker.GetValue<T>()` to load initial state, then subscribe for live updates

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

### Audio pipeline (RadioAudioManager)
The radio uses a **separate RFCOMM channel** for audio (GenericAudio UUID `00001203`), distinct from the GAIA command channel. `RadioAudioManager` (Core) manages both directions:

**Receive**: BT audio socket → 0x7E-framed SBC data → `SbcDecoder` → 16-bit 32kHz mono PCM → `IAudioOutput` (PortAudio on Linux)

**Transmit**: Mic PCM (48kHz from `parecord`) → resample to 32kHz → `TransmitVoicePCM` dispatch → `SbcEncoder` → 0x7E escape framing → BT audio socket. Real-time pacing prevents BT buffer flooding.

**Audio framing protocol**: `0x7E` start/end markers, `0x7D` escape byte (XOR `0x20`). First byte after start = command: `0x00` = audio data (receive), `0x01` = end/control, `0x02` = transmit loopback. End audio frame: `{ 0x7e, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e }`.

**SBC codec settings**: 32kHz, 16 blocks, mono, loudness allocation, 8 subbands, bitpool 18.

**Linux audio transport** (`LinuxRadioAudioTransport`): Uses same native RFCOMM socket approach as command channel — `read()`/`write()` P/Invoke with `O_NONBLOCK`, not `NetworkStream` (which fails on RFCOMM fds with "not allowed on non-connected sockets").

**Linux mic capture**: `parecord --format=s16le --rate=48000 --channels=1 --raw --latency-msec=20` — PortAudio's ALSA capture path is broken on PipeWire systems (mmap errors). `parecord` works reliably on PipeWire, PulseAudio, and ALSA.

**PTT UI pattern**: Use `Border` with `PointerPressed`/`PointerReleased` (not `Button` — Avalonia `Button` swallows pointer events). Spacebar PTT needs 150ms debounce timer to handle Wayland key repeat (KeyUp+KeyDown pairs). On PTT release, don't cancel buffered audio — let transmission drain naturally.

**WAV file transmit**: Read WAV via `HamLib.WavFile.Read()`, convert stereo→mono, resample to 32kHz, apply mic gain, chunk into 6400-byte (100ms) pieces, dispatch `TransmitVoicePCM` with 100ms pacing. Both `RadioAudioDialog` and `MainWindow` have this capability.

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
- Avalonia `ComboBox` has no `.Text` property — use `AutoCompleteBox` for editable text+dropdown combos, or `SelectedItem?.ToString()` for read-only combos
- SSTV imaging uses SkiaSharp (`SKBitmap`), not System.Drawing. WinForms bridge: `SkiaBitmapConverter`

### Theme system
Avalonia Desktop supports Light, Dark, and Auto (follow OS) themes. Colors are defined as `DynamicResource` references in AXAML files, backed by `ThemeDictionaries` in `App.axaml`. Theme preference stored as `DataBroker.GetValue<string>(0, "Theme", "Dark")`. Apply via `App.SetTheme(themeTag)`.

**Theme resource keys** (use `{DynamicResource KeyName}` in AXAML):
| Key | Dark | Light | Usage |
|-----|------|-------|-------|
| `TabHeaderBackground` | `#2D2D30` | `#F0F0F0` | Tab header bars, toolbar |
| `CardBackground` | `#2D2D30` | `#F5F5F5` | Dialog section cards |
| `PanelBackground` | `#1E1E1E` | `#FFFFFF` | Radio panel, text area backgrounds |
| `TextAreaBackground` | `#1E1E1E` | `#FFFFFF` | TextBox read-only areas |
| `TextAreaForeground` | `#D4D4D4` | `#1E1E1E` | TextBox text color |
| `PanelBorder` | `#3F3F46` | `#D0D0D0` | Panel/card borders |
| `InfoCardBackground` | `#252526` | `#F0F0F0` | VFO cards, status cards |
| `SplitterColor` | `#444444` | `#C0C0C0` | GridSplitters |
| `SstvPreviewBackground` | `#1E1E1E` | `#F0F0F0` | SSTV preview area |
| `PrimaryText` | `#E0E0E0` | `#1E1E1E` | Data values (frequencies, battery, status values, channel names) |
| `SecondaryText` | `#888888` | `#555555` | Labels (Battery, GPS, RSSI, channel frequencies) |
| `TertiaryText` | `#666666` | `#777777` | Channel slot numbers |

For programmatic theme-aware colors in code-behind, use `GetThemeBrush(resourceKey)` in `MainWindow.axaml.cs`. When caching theme brushes in data items (e.g., channel list), subscribe to `ActualThemeVariantChanged` to rebuild the list so colors update on theme switch.

**Never use hardcoded dark colors** (`#2D2D30`, `#1E1E1E`, `#3F3F46`, `#252526`, `#444`) in AXAML backgrounds. Use the DynamicResource keys above. Accent/functional colors (PTT button red `#C62828`, status bar blue `#007ACC`, VFO frequency colors) are theme-independent.

### Other conventions
- Radio audio controls: `SetVolumeLevel` (int 0-15, hardware), `SetSquelchLevel` (int 0-9), `SetOutputVolume` (int 0-100, software), `SetAudio` (bool, streaming toggle), `SetMute` (bool). Radio reports back via `Volume` and `AudioState` events
- Voice transmit modes dispatch to device 1: `Chat`, `Speak`, `Morse` (text commands); DTMF generates PCM locally via `DmtfEngine` and dispatches `TransmitVoicePCM` to radio device. VoiceHandler must be enabled first via `VoiceHandlerEnable` dispatch (happens automatically when radio state becomes `"Connected"`)
- PTT mic transmit: captures at 48kHz via `parecord`, resamples to 32kHz with linear interpolation, dispatches `TransmitVoicePCM` directly to radio device (bypasses VoiceHandler)
- Map tab uses Mapsui 5.0 with `WritableLayer` + `PointFeature` + `LabelStyle` for APRS station markers and airplane markers. APRS positions from `AprsPacket.Position.CoordinateSet.Latitude/Longitude.Value`. Airplane markers rendered via `Airplanes` DataBroker event with orange dot + flight name/altitude labels; toggled via `ShowAirplanesOnMap` setting
- APRS tab has right-click context menu: Details, Show Location (if position data), Copy Message/Callsign, SMS Message, Weather Report (if weather data)
- Voice tab (Communication): Chat/Speak/Morse/DTMF modes, SSTV send, right-click Copy on messages, Mute toggle button
- Spectrogram dialog: built-in FFT + SkiaSharp rendering, subscribes to `AudioDataAvailable` from radio, configurable max frequency (4/8/16 kHz) and roll mode
- Recording playback dialog: plays WAV files via `IAudioService.CreateOutput()` with progress bar
- Settings are stored as int 0/1 for booleans that need cross-platform compat (e.g., `AllowTransmit`, `WebServerEnabled`), use `DataBroker.GetValue<int>(0, key, 0) == 1` to read
- `RadioChannelInfo` has a copy constructor: `new RadioChannelInfo(source)` — used for channel drag-and-drop copy operations
- Torrent file creation: compress with Brotli/Deflate (pick smallest), prepend compression type byte, hash with `Utils.ComputeShortSha256Hash()`, split into `Torrent.DefaultBlockSize` blocks
- Software modem mode: `DataBroker.Dispatch(0, "SetSoftwareModemMode", modeTag)` where modeTag is `None`, `AFSK1200`, `PSK2400`, `PSK4800`, or `G3RUH9600`

## Repository Structure

- `docs/CrossPlatformArchitecture.md` — detailed architecture documentation with design decision rationale
- `packaging/linux/` — AppImage and .deb build scripts
- `HTCommander.setup/` — Windows MSI installer project
- `Updater/` — HtCommanderUpdater project (Windows self-update helper)
- `web/` — embedded web interface (HTML/JS). `index.html` is the desktop Web Bluetooth UI; `mobile.html` is a mobile-first SPA that uses the MCP JSON-RPC API for remote radio control over LAN (status, VFO display, channel switching, chat)
- `releases/` — Windows MSI release artifacts + `version.txt`
- Two git remotes: `origin` (Ylianst/HTCommander upstream), `fork` (dikei100/HTCommander-X)
- Active branch: `main`

## Related Projects

- [khusmann/benlink](https://github.com/khusmann/benlink) — Python library for the same radios; reference for GAIA protocol, RFCOMM channel discovery, and audio codec details
- [SarahRoseLives/flutter_benlink](https://github.com/SarahRoseLives/flutter_benlink) — Flutter/Dart implementation; reference for initialization sequence and VR-N76 quirks (SYNC_SETTINGS handshake)
