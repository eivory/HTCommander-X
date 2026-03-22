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

GitHub Actions workflow (`.github/workflows/release.yml`) triggers on version tags (`v*`). Builds Linux and Windows self-contained packages on `ubuntu-latest`, produces: AppImage, .deb, .rpm, .pkg.tar.zst, and Windows zip. All artifacts are uploaded as a GitHub Release with auto-generated notes. Actions are pinned to commit SHAs for supply chain security. `fpm` gem pinned to version 1.15.1 for reproducible builds. `appimagetool` pinned to release 13 with SHA256 checksum verification (both in CI and `build-appimage.sh`).

**Versioning**: The assembly version is set in `HTCommander.Desktop/HTCommander.Desktop.csproj` `<Version>` property. This must match the git tag (e.g., tag `v0.1.4` → `<Version>0.1.4</Version>`). The About dialog and update checker both read `Assembly.GetEntryAssembly().GetName().Version`. Push to the `fork` remote (dikei100/HTCommander-X) with `--tags` to trigger a release build.

## Architecture

HTCommander is a ham radio controller for Bluetooth-enabled handhelds (UV-Pro, UV-50Pro, GA-5WB, VR-N75, VR-N76, VR-N7500, VR-N7600, RT-660). It was migrated from a monolithic WinForms app to a multi-project cross-platform architecture.

### Project Dependency Graph

```
HTCommander.Desktop (Avalonia UI) ──┐
                                     ├──> HTCommander.Core (all business logic)
HTCommander.Platform.Linux ──────────┤
HTCommander.Platform.Windows ────────┘
```

### HTCommander.Core (net9.0) — zero UI dependencies

All radio protocol logic, data handlers, codecs, and parsers. Key subsystems:
- **Radio.cs**: GAIA protocol over Bluetooth RFCOMM — the central class managing radio connections, commands, channels, GPS
- **DataBroker / DataBrokerClient**: Global pub/sub event bus. Device-scoped data channels with optional persistence via `ISettingsStore`. Uses `SynchronizationContext.Post()` for UI thread marshalling
- **Interfaces/**: Platform abstractions (`IPlatformServices`, `IRadioBluetooth`, `IAudioService`, `ISpeechService`, `ISettingsStore`, `IFilePickerService`, `IPlatformUtils`, `IRadioHost`, `IWhisperEngine`, `IVirtualSerialPort`, `IVirtualAudioProvider`)
- **radio/**: AX.25 packet protocol, SoftwareModem (DSP), GAIA frame encode/decode. AX25Packet/AX25Address parsers validate bounds before every `data[i++]` access and null-check `GetAddress()` results — always return `null` on malformed input rather than throwing. Address parsing loop capped at 10 (AX.25 spec max). All radio data structure constructors (`RadioDevInfo`, `RadioChannelInfo`, `RadioSettings`, `RadioHtStatus`, `RadioPosition`, `TncDataFragment`) validate minimum message length and throw `ArgumentException` on malformed input. `Radio.RadioTransport_ReceivedData` catches `ArgumentException` from malformed responses.
- **SSTV/**: Slow-scan TV image encode/decode using SkiaSharp (not System.Drawing)
- **VoiceHandler**: Speech processing — takes `ISpeechService` constructor param, uses `VoiceHandler.WhisperEngineFactory` static delegate for STT. Subscribes to `Chat`, `Speak`, `Morse` on AllDevices. Requires `VoiceHandlerEnable` with `{ DeviceId, Language, Model }` before it will transmit — fires when radio State becomes `"Connected"`
- **RadioAudioManager**: Cross-platform audio pipeline (replaces Windows-only `RadioAudio.cs`). Uses `IRadioAudioTransport` for BT audio socket + `IAudioService` for local playback. Handles `TransmitVoicePCM` → SBC encode → RFCOMM, and receive loop → SBC decode → PortAudio output. Created automatically in `Radio` constructor when `platformServices != null`. Supports recording via `WavFileWriter` — `RecordingEnable`/`RecordingDisable` DataBroker events trigger WAV file recording of decoded PCM to `~/Documents/HTCommander/Recordings/`
- **AgwpeServer**: AGWPE TCP server for external TNC client integration. Self-initializing DataBroker handler; auto-starts/stops based on `AgwpeServerEnabled`/`AgwpeServerPort` settings. Respects `ServerBindAll` (default: loopback only). Frame `DataLen` capped at 65536 bytes. Max 20 concurrent client connections. Includes `AgwpeFrame` (36-byte header protocol) and per-client `AgwpeTcpClientHandler`. Forwards `UniqueDataFrame` as 'U' monitoring frames to connected clients.
- **SmtpServer / ImapServer**: Local SMTP/IMAP servers for Winlink email integration. Wired via DataBroker — SMTP requires AUTH PLAIN with WinlinkPassword validation (constant-time comparison via `CryptographicOperations.FixedTimeEquals()`) before accepting MAIL commands, dispatches `MailReceived` on incoming email (data buffer capped at 10MB, max 10 concurrent sessions), IMAP reads mail list via `DataBroker.GetValue<List<WinLinkMail>>(1, "Mails", ...)` (APPEND capped at 10MB, tag sanitized against CRLF injection). Both bind to loopback only. Both read `CallSign`, `StationId`, `WinlinkPassword` from DataBroker for authentication. Error responses use generic messages (no `ex.Message` leak).
- **AudioClipHandler**: Manages audio clips stored as WAV files in `~/Documents/HTCommander/Clips/`. All clip operations validated via `SafeClipPath()` — rejects path traversal (`..`, path separators) and verifies resolved path stays within clips directory. Handles `PlayAudioClip` (reads WAV, resamples to 32kHz, dispatches `TransmitVoicePCM`), `DeleteAudioClip`, `RenameAudioClip`, `SaveAudioClip`, `StopAudioClip`. Publishes `AudioClips` array of `AudioClipEntry` (Name, Duration, Size) on changes.
- **RigctldServer**: Hamlib rigctld TCP server (default port 4532) enabling external software (fldigi, WSJT-X, Direwolf, VaraFM) to control the radio. Implements rigctld text protocol — short-form and long-form commands (`\get_ptt`, `\set_ptt`, `\get_freq`, `\set_freq`, `\get_mode`, `\set_mode`, `\get_vfo`, `\set_vfo`, `\dump_state`). `set_freq` writes a scratch channel "QF" at last slot (`channel_count - 1`) and switches VFO A to it — same pattern as QuickFrequencyDialog. Dispatches `ExternalPttState` (bool) on device 1 when PTT changes; sends 100ms silence frames to `TransmitVoicePCM` to keep radio keyed during external PTT. Respects `ServerBindAll` (default: loopback only). Command lines capped at 1024 bytes; oversized commands disconnect the client. Auto-starts/stops via `RigctldServerEnabled`/`RigctldServerPort` settings.
- **CatSerialServer**: Virtual serial port emulating Kenwood TS-2000 CAT protocol for VaraFM PTT and frequency control. ASCII semicolon-terminated commands at 9600 baud. Command buffer capped at 1024 bytes. Supports TX/RX (PTT), FA/FB (VFO frequencies — writes scratch channel "QF" and switches VFO, same pattern as QuickFrequencyDialog), MD (mode), IF (transceiver info), ID (radio ID). Uses `IPlatformServices.CreateVirtualSerialPort()` for platform-specific PTY/COM. Dispatches `ExternalPttState`; publishes `CatPortPath` (string) on device 1. Auto-starts/stops via `CatServerEnabled` setting.
- **VirtualAudioBridge**: Bidirectional audio routing via PulseAudio/PipeWire virtual devices. RX: radio PCM 32kHz → resample to 48kHz → virtual source ("HTCommander Radio Audio"). TX: virtual sink monitor ("HTCommander TX") → resample 48kHz→32kHz → `TransmitVoicePCM`. TX path gated on `ExternalPttState` from RigctldServer/CatSerialServer. Creates PulseAudio modules (`module-null-sink`, `module-virtual-source`), uses `pacat`/`parecord` subprocesses. Auto-starts/stops via `VirtualAudioEnabled` setting.
- **AudioResampler**: Pure managed audio resampler (linear interpolation) for 32kHz↔48kHz conversion. Methods: `Resample16BitMono()`, `ResampleStereoToMono16Bit()`. Replaces Windows-only MediaFoundationResampler.
- **TlsHttpServer**: Lightweight HTTP server with optional TLS support, replacing `HttpListener` (which doesn't support HTTPS on Linux). Uses `TcpListener` + `SslStream` for connections, manual HTTP request/response parsing, and `WebSocket.CreateFromStream()` for WebSocket upgrade. Shared by both `WebServer` and `McpServer`. Connection limit: 100 concurrent. Response header values sanitized against CRLF injection. Inner types: `HttpRequest { Method, Path, Query, Headers, Body }`, `HttpResponse { StatusCode, StatusText, ContentType, Headers, Body }`. Constructor takes port, bindAll, useTls, certificate, requestHandler callback, optional webSocketPath + webSocketHandler. No keep-alive (connection-per-request). WebSocket upgrade: manual `Sec-WebSocket-Accept` computation + `101 Switching Protocols` response.
- **TlsCertificateManager**: Self-signed X.509 certificate generation and caching for TLS. Generates RSA 3072 cert with SAN entries for `localhost`, `127.0.0.1`, `::1`, and all local network IPs. Stored as PFX at `{configDir}/htcommander-tls.pfx` with chmod 600 on Linux, 10-year validity. Static `GetOrCreateCertificate(configDir)` method with thread-safe caching — both WebServer and McpServer share the same instance.
- **McpServer**: MCP (Model Context Protocol) HTTP/HTTPS server for AI-powered radio control. JSON-RPC 2.0 over `TlsHttpServer` on localhost (default port 5678). **Authentication**: When `ServerBindAll` is enabled, requires Bearer token in `Authorization` header. Token auto-generated on first run and stored as `McpApiToken` in DataBroker device 0. **CORS**: Reflects request `Origin` header (not wildcard) with `Vary: Origin`. Error responses use generic messages (no `ex.Message` leak). `McpTools` exposes 39 tools organized in categories: **Query** (8: get_connected_radios, get_radio_state/info/settings, get_channels, get_gps_position, get_battery, get_ht_status), **Basic Control** (7: set_vfo_channel, set_volume, set_squelch, set_audio, set_gps, disconnect/connect_radio), **Extended Control** (10: set_vfo_frequency via scratch channel, set_ptt with silence keepalive, set_dual_watch, set_scan, set_output_volume, set_mute, send_chat_message, send_morse, send_dtmf, set_software_modem), **Audio Clips** (4: list/play/stop/delete_audio_clip), **Channel/Recording** (3: write_channel, enable/disable_recording), **Settings** (2: get_setting/set_setting with whitelist validation — `McpDebugToolsEnabled`, `ServerBindAll`, `TlsEnabled` NOT in whitelist, must be toggled from UI only), **Debug** (5: get_logs, get_databroker_state, get/set_app_setting, dispatch_event — all gated behind `McpDebugToolsEnabled`; `get_logs` enforces debug check at dispatch, not just tool listing). Connect/disconnect tools dispatch `McpConnectRadio`/`McpDisconnectRadio` events to device 1, handled by MainWindow. `McpResources` exposes dynamic read-only resources (radio info/settings/channels/status, app logs/settings). `McpJsonRpc` handles protocol dispatch. Auto-starts/stops via `McpServerEnabled`/`McpServerPort`/`McpDebugToolsEnabled`/`ServerBindAll`/`TlsEnabled` settings. `ServerBindAll` enables binding to all interfaces for LAN access. See `docs/MCP-Integration.md` for full implementation details and removal instructions.
- **WebServer**: HTTP/HTTPS static file server for the embedded web interface (`web/` directory). Serves files via `TlsHttpServer` on localhost (default port 8080). Path traversal protection. WebSocket upgrade at `/ws/audio` delegates to `WebAudioBridge` for mobile PTT and audio streaming. Auto-starts/stops via `WebServerEnabled`/`WebServerPort`/`TlsEnabled` settings. `ServerBindAll` setting (shared with McpServer) enables binding to all interfaces for LAN access. Exposes `/api/config` endpoint returning `{"mcpPort":N,"mcpEnabled":bool,"tlsEnabled":bool}` for the mobile web UI. When `TlsEnabled` is 1, serves over HTTPS with a self-signed certificate from `TlsCertificateManager` — required for mobile `getUserMedia()` mic access over LAN. Static file responses include security headers: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`.
- **WebAudioBridge**: WebSocket audio bridge for mobile PTT and bidirectional audio streaming. **Authentication**: When `ServerBindAll` is enabled, the first WebSocket message must be a text frame `AUTH:<token>` with the MCP API token; unauthenticated clients are disconnected with `PolicyViolation`. When `ServerBindAll` is enabled but token is empty/uninitialized, connections are rejected (no auth bypass). Token comparison uses `CryptographicOperations.FixedTimeEquals()`. PTT timers are disposed before recreation to prevent resource leaks on repeated PTT start. Binary protocol: `0x01`+PCM=audio data, `0x02`=PTT start, `0x03`=PTT stop, `0x04`=PTT rejected (another client holds it), `0x05`=PTT acquired. RX: subscribes to `AudioDataAvailable`, resamples 32kHz→48kHz via `AudioResampler`, broadcasts to all connected WebSocket clients. TX: receives browser mic PCM at 48kHz, resamples to 32kHz, dispatches `TransmitVoicePCM`. Per-client rate limiting (200 frames/sec) and frame size cap (19200 bytes) prevent DoS. PTT ownership mutex — one client at a time, with silence frame keepalive (80ms interval). Multi-client support via `ConcurrentDictionary`. Accepts `WebSocket` directly (created by `TlsHttpServer` via `WebSocket.CreateFromStream()`).
- **RepeaterBookClient**: API client for RepeaterBook repeater database. Supports live API search by country/state and CSV import. Haversine distance calculation for proximity sorting. `ToRadioChannel()` converts entries to `RadioChannelInfo` for channel import.
- **AdifExport**: ADIF 3.1.4 format writer for QSO logbook export. Standard `<TAG:length>value` encoding with `<EOR>` record terminators.
- **QsoEntry**: QSO log entry data model with `GetBand()` helper for frequency-to-band conversion (HF through 23cm).

### Platform Projects

**Platform.Windows** (net9.0-windows): WinRT Bluetooth (volatile on cross-thread `running`/`isConnecting`), NAudio/WASAPI audio, System.Speech TTS, Windows Registry settings, `OpenUrl` validates http/https scheme, `OpenFileManager` uses `ArgumentList`

**Platform.Linux** (net9.0): Direct native RFCOMM sockets for Bluetooth, BlueZ D-Bus for device discovery/ACL, PortAudio for audio output (always opened as stereo, mono samples duplicated to both channels), `parecord` subprocess for mic capture (PortAudio ALSA capture broken on PipeWire), espeak-ng TTS (22050→32kHz resampling, voice/text arguments sanitized against injection), JSON file settings at `~/.config/HTCommander/` (chmod 600 on write), `LinuxVirtualSerialPort` (PTY pair via `openpty()` P/Invoke, symlinks slave to `~/.config/HTCommander/cat-port`), `LinuxVirtualAudioProvider` (PulseAudio module management via `pactl`, `pacat`/`parecord` subprocesses for virtual device I/O)

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

**ProbeChannels safety**: `VerifyGaiaResponse()` is wrapped in try-catch so that an exception during GAIA verification doesn't leak the RFCOMM socket file descriptor. The `NativeMethods.close(fd)` call always executes on non-matching channels.

### Audio pipeline (RadioAudioManager)
The radio uses a **separate RFCOMM channel** for audio (GenericAudio UUID `00001203`), distinct from the GAIA command channel. `RadioAudioManager` (Core) manages both directions:

**Receive**: BT audio socket → 0x7E-framed SBC data → `SbcDecoder` → 16-bit 32kHz mono PCM → `IAudioOutput` (PortAudio on Linux)

**Transmit**: Mic PCM (48kHz from `parecord`) → resample to 32kHz → `TransmitVoicePCM` dispatch → `SbcEncoder` → 0x7E escape framing → BT audio socket. Real-time pacing prevents BT buffer flooding.

**Audio framing protocol**: `0x7E` start/end markers, `0x7D` escape byte (XOR `0x20`). First byte after start = command: `0x00` = audio data (receive), `0x01` = end/control, `0x02` = transmit loopback. End audio frame: `{ 0x7e, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e }`.

**SBC codec settings**: 32kHz, 16 blocks, mono, loudness allocation, 8 subbands, bitpool 18.

**Linux audio transport** (`LinuxRadioAudioTransport`): Uses same native RFCOMM socket approach as command channel — `read()`/`write()` P/Invoke with `O_NONBLOCK`, not `NetworkStream` (which fails on RFCOMM fds with "not allowed on non-connected sockets").

**Linux mic capture**: `parecord --format=s16le --rate=48000 --channels=1 --raw --latency-msec=20` — PortAudio's ALSA capture path is broken on PipeWire systems (mmap errors). `parecord` works reliably on PipeWire, PulseAudio, and ALSA. The `capturing` flag is set only after `Thread.Start()` succeeds; on failure the process is killed and disposed.

**VirtualAudioBridge process safety**: `LinuxVirtualAudioProvider.Create()` starts `pacat` then `parecord` sequentially. If `parecord` fails to start, `pacat` is killed and disposed before the exception propagates. The outer catch calls `Destroy()` to clean up PulseAudio modules.

**PTT UI pattern**: Use `Border` with `PointerPressed`/`PointerReleased` (not `Button` — Avalonia `Button` swallows pointer events). Spacebar PTT needs 150ms debounce timer to handle Wayland key repeat (KeyUp+KeyDown pairs). On PTT release, don't cancel buffered audio — let transmission drain naturally.

**WAV file transmit**: Read WAV via `HamLib.WavFile.Read()`, convert stereo→mono, resample to 32kHz, apply mic gain, chunk into 6400-byte (100ms) pieces, dispatch `TransmitVoicePCM` with 100ms pacing. Both `RadioAudioDialog` and `MainWindow` have this capability.

### GAIA protocol frame format
```
[0xFF] [0x01] [flags] [body_length] [group_hi] [group_lo] [cmd_hi] [cmd_lo] [body...]
```
- `body_length` = cmd body only (excludes 4-byte command header), single byte (max 255); `GaiaEncode` validates payload length and rejects oversized commands
- Total frame = body_length + 8
- Reply bit: `cmd_hi | 0x80`
- Radio frequency values stored in Hz (divide by 1,000,000 for MHz display)

## Code Conventions

- **Target**: net9.0 (Core, Linux, Desktop), net9.0-windows (Platform.Windows)
- **Nullable**: disabled across all projects
- **ImplicitUsings**: disabled — all usings are explicit
- **AllowUnsafeBlocks**: enabled (SBC codec, SkiaSharp pixel ops, native P/Invoke)
- **Namespace**: `HTCommander` for Core, `HTCommander.Platform.Linux`, `HTCommander.Platform.Windows`, `HTCommander.Desktop` for other projects
- Radio dispatches state as **string** (e.g., `"Connected"`, not the enum), so subscribers must compare strings
- Avalonia dialogs use `Confirmed` bool property pattern for OK/Cancel results
- Avalonia `ComboBox` has no `.Text` property — use `AutoCompleteBox` for editable text+dropdown combos, or `SelectedItem?.ToString()` for read-only combos
- SSTV imaging uses SkiaSharp (`SKBitmap`), not System.Drawing

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
- `packaging/linux/` — AppImage and .deb build scripts. `build-deb.sh` extracts the version from `HTCommander.Desktop.csproj` automatically.
- `assets/` — shared assets (application icon)
- `web/` — embedded web interface (HTML/JS). `index.html` is the desktop Web Bluetooth UI; `mobile.html` is a mobile-first SPA that uses the MCP JSON-RPC API for remote radio control over LAN (status, VFO display, channel switching, chat, PTT with bidirectional audio via WebSocket). **XSS safety**: All user-controlled strings (channel names, callsigns, chat messages) must be passed through `escapeHtml()` before insertion into `innerHTML`. Both `app.js` (for index.html) and `mobile.js` define their own `escapeHtml()` function. **CSP**: Both pages include `Content-Security-Policy` meta tags restricting script/style sources.
- Two git remotes: `origin` (Ylianst/HTCommander upstream), `fork` (dikei100/HTCommander-X)
- Active branch: `main`

## Security Hardening

The codebase follows defense-in-depth principles. Key security patterns:

### Network server binding
All TCP servers (MCP, WebServer, AGWPE, Rigctld) default to **loopback only** (`IPAddress.Loopback`). LAN access requires explicit opt-in via `ServerBindAll` setting. SMTP and IMAP servers always bind to loopback.

### MCP authentication & authorization
When `ServerBindAll` is enabled, the MCP server requires a `Authorization: Bearer <token>` header on all POST requests. The token is auto-generated (32 random bytes / 256 bits of entropy, base64) on first run and stored as `McpApiToken` in DataBroker device 0. **Token comparison uses `CryptographicOperations.FixedTimeEquals()` without length pre-check** — `FixedTimeEquals` handles length mismatches internally in constant time, so no timing side-channel leaks length information. When `ServerBindAll` is enabled but the token is empty/uninitialized, requests are rejected with 503 (no auth bypass). **Token is automatically regenerated when `ServerBindAll` transitions to enabled** to ensure stale tokens from loopback-only mode cannot be reused. `McpDebugToolsEnabled`, `ServerBindAll`, `TlsEnabled`, and `WinlinkPassword` are **not** in the `SettingsWhitelist` — they can only be managed from the Settings UI, preventing remote modification via `set_setting`. Even when debug tools are enabled, a `DebugSettingsBlacklist` (`McpApiToken`, `McpDebugToolsEnabled`, `TlsEnabled`, `ServerBindAll`, `WinlinkPassword`) prevents both read and write of critical security settings via `get_app_setting`/`set_app_setting` or `dispatch_event`. `get_databroker_state` also filters blacklisted settings from device 0 output. `McpResources.ReadAppSettings()` filters `McpApiToken` and `WinlinkPassword` from the `htcommander://app/settings` resource. MCP `CallTool` catch handler returns a generic error message to clients (never `ex.Message`) and logs the actual error internally. MCP error responses use generic messages (no method name, URI, or tool name echoed).

### CORS origin validation
Both MCP and Web servers validate CORS `Origin` headers against an allowlist (localhost, loopback IPs, RFC 1918 private LAN ranges, IPv6 link-local/unique-local) via `ValidateCorsOrigin()`. IPv4-mapped IPv6 addresses (`::ffff:x.x.x.x`) are mapped to their inner IPv4 before validation. Unknown or public origins are **rejected with 403** (MCP) or omitted (WebServer) — never returns the string `"null"` as an origin. `Vary: Origin` header included for cache correctness.

### Input validation patterns
- **Path traversal**: `AudioClipHandler.SafeClipPath()` validates clip names via `Path.GetFileName()` + `Path.GetFullPath()` prefix check. `YappTransfer` uses the same `GetFullPath()` + prefix check pattern for received filenames. `WebServer` uses `..` check + `Path.GetFullPath()` canonicalization. `MailStore.GetAttachmentFilePath()` sanitizes filenames and validates resolved path stays within `_attachmentsPath` via `Path.GetFullPath()` prefix check (strict: requires directory separator); `LoadAttachments()` and `DeleteAttachmentFiles()` also validate `Path.GetFullPath()` prefix to prevent path traversal from database-stored paths.
- **Protocol bounds**: All radio data structure constructors validate minimum message length. `Radio.RadioTransport_ReceivedData` rejects messages < 4 bytes and catches `ArgumentException`. Channel ID bounds-checked before array access (including negative index validation in `GetChannelNameById`). `Utils.GetShort()` and `Utils.GetInt()` perform explicit bounds checking and throw `ArgumentException` on out-of-range positions. `AX25Packet` validates `i + 7 > data.Length` before each address decode iteration; `isSame()` null-checks and bounds-checks address lists before comparison. `RadioPosition` uses bitwise OR (`|`) instead of addition for byte combination to prevent integer overflow. `RadioAudioManager.EscapeBytes` validates `len <= b.Length` before unsafe pointer operations and uses `checked` arithmetic for buffer size calculation. `SoftwareModem.OnAudioDataAvailable` validates `offset + length <= pcmData.Length` before processing reflected event data. `Yapp.ProcessDataPacket` validates packet size against declared `dataLength` before any data or checksum access. `Yapp.SendNotReady`/`SendCancel` cap reason bytes to 255 (YAPP single-byte length field). `WinlinkClient` proposal parsing validates array bounds before index access. `GpsSerialHandler.ParseNmeaDateTime` validates minimum string lengths before `Substring` operations. `AudioClipHandler.GetDuration` validates WAV chunk sizes (negative check, fmt minimum 16 bytes, remaining-data bounds).
- **Buffer caps**: AGWPE DataLen ≤ 65536, AGWPE per-client send queue ≤ 1000 frames (drops when full), SMTP data ≤ 10MB (`lineBuffer` and `dataBuffer` checked *before* append to prevent temporary memory spikes), SMTP recipients ≤ 100, SMTP max 5 AUTH attempts per session + global rate limit (20 failures/minute across all sessions), IMAP max 5 AUTH attempts per session + global rate limit (20 failures/minute across all sessions), IMAP APPEND ≤ 10MB, IMAP `ParseUidSet` and `ParseSequenceSet` both capped at 10,000 results to prevent CPU DoS from wide ranges, IMAP read timeout 30s, IMAP line length limit 8KB, IMAP max 10 concurrent sessions, Rigctld uses byte-at-a-time `ReadLineLimitedAsync(1024)` with 30-second idle timeout to bound memory and prevent slowloris-style connection stalls, Rigctld max 10 concurrent clients with auto PTT release when last client disconnects, CAT command buffer ≤ 1024 bytes (protected by `commandBufferLock`) with frequency range validation (max 11 digits), TlsHttpServer ≤ 100 concurrent connections with 8KB per-header-line limit, `RadioAudioManager` audio accumulator checks size *before* write (prevents OOM from single oversized frame) with integer overflow guard on PCM buffer resize, AudioClipHandler SaveAudioClip ≤ 10MB, MailStore attachment writes ≤ 10MB per file, WebAudioBridge audio frames ≤ 19200 bytes with per-client rate limiting (200 frames/sec, minimum 1ms interval) and max 20 concurrent WebSocket clients (atomic TryAdd+post-check pattern), WebSocket AUTH message validated against buffer bounds, `TncDataFragment` reassembly capped at 64KB (appropriate for AX.25 protocol limits), AX.25 packet payload capped at 64KB, Brotli/Deflate decompression capped at 100MB with 100:1 compression ratio limit to prevent compression bombs, SMTP max 10 concurrent sessions, AGWPE max 20 concurrent clients, subprocess output reads (sdptool, bluetoothctl, pactl) capped at 512KB via `ReadProcessOutputLimited()` or bounded `Read()`, YAPP file transfers capped at 100MB with `bytesTransferred` validated against declared `fileSize` during write, Torrent data blocks require `p.data.Length >= 8` and `blockNumber` capped at 10000, Torrent control packets `sblockCount` capped at 10000, Torrent `ProcessFrame` catches `EndOfStreamException` from malformed control packets, WinlinkClient mail binary reception capped at 10MB, debug log file capped at 10MB with rotation, `Utils.SetShort()`/`SetInt()` perform explicit bounds checking matching `GetShort`/`GetInt` pattern, `Utils.BytesToHex(offset, length)` validates offset/length bounds.
- **Frequency overflow protection**: All frequency-setting paths (RigctldServer, CatSerialServer, McpTools `set_vfo_frequency`, McpTools `write_channel`, QuickFrequencyDialog, RadioChannelDialog, RepeaterBookClient `ToRadioChannel()`) validate `freqHz > 0 && freqHz <= int.MaxValue` before casting `long` to `int` for `RadioChannelInfo.rx_freq`/`tx_freq`. Prevents integer overflow that could cause undefined radio behavior with frequencies > 2.1 GHz. RigctldServer `\set_freq` and CatSerialServer `FA`/`FB` validate `<= int.MaxValue` at parse time (before caching) to prevent bogus cached frequency values from being reported back to clients.
- **Injection prevention**: All Linux subprocess calls (espeak-ng, pactl, pacat, parecord, xdg-open, sdptool, bluetoothctl, zenity, kdialog) use `ProcessStartInfo.ArgumentList` with separate key/value arguments (not `--key=value` concatenation) — prevents argument injection regardless of input content. `LinuxPlatformUtils.OpenUrl()` validates URLs via `Uri.TryCreate()` with scheme whitelist (http/https only) before passing to `xdg-open`. `LinuxPlatformUtils.OpenFileManager()` validates `Path.IsPathRooted()` to reject URLs and non-local paths. HTTP response headers stripped of CRLF, null bytes, and Unicode line separators (U+2028/U+2029). IMAP `SendResponse` sanitizes both tag AND response parameters against CRLF, Unicode line separators, and null bytes; `ParseSequenceSet` and `ParseUidSet` use `TryParse` (not `Parse`) to handle malformed input gracefully; UID computation handles `int.MinValue` hash to prevent `Math.Abs` overflow. espeak-ng voice names filtered to `[a-zA-Z0-9_\-+]`. `SelfUpdateDialog` validates release URL via `Uri.TryCreate()` with host (`github.com`) and path (`/dikei100/HTCommander-X/releases/`) validation. `LinuxVirtualAudioProvider.LoadModule()` validates module names against an allowlist (`module-null-sink`, `module-virtual-source`). `DataBroker` JSON deserialization validates stored type name matches requested `T` using `Type.FullName` (not short name) to prevent cross-namespace type confusion. Rigctld extended protocol responses sanitize echoed `args` by stripping `\r`/`\n`/`\u2028`/`\u2029` to prevent response injection. SMTP error responses use generic messages (no command echo). ADIF export sanitizes both `<` and `>` from field values to prevent tag injection. sdptool channel parsing uses `TryParse` and validates RFCOMM channels 1-30 (both `LinuxRadioBluetooth` and `LinuxRadioAudioTransport`). MCP `send_chat_message` capped at 4096 chars, `clip_name` parameters capped at 256 chars. `RadioDevInfo.freq_range_count` capped at 8 to prevent out-of-bounds access from malformed radio data. `Utils.GetShort()`/`Utils.GetInt()` use generic error messages (no array length/position disclosure).
- **Symlink safety**: `LinuxVirtualSerialPort` uses atomic symlink replacement (create temp symlink + `File.Move` overwrite) to eliminate TOCTOU window. Fallback path verifies `ReparsePoint` attribute before deleting — refuses to delete regular files to prevent symlink attacks.
- **APRS authentication**: HMAC-SHA256 with Base64 truncation. Time-based with ±5 minute window for clock skew tolerance. Auth key derived via SHA-256 hash of the station password. **Auth code comparison uses `CryptographicOperations.FixedTimeEquals()` without length pre-check** to prevent timing attacks — `FixedTimeEquals` handles mismatched lengths internally in constant time (both `AprsHandler` and legacy `AprsAuth`).
- **WAV header bounds**: `LinuxSpeechService.SynthesizeToWav()` validates `wavData.Length >= 44` (minimum valid WAV with header) before reading sample rate from WAV header bytes 24-27 and resampling from byte 44. Resampling validates `dstSamples` against `(int.MaxValue - 44) / 2` to prevent integer overflow on buffer allocation. File reads wrapped in try-catch for TOCTOU resilience.
- **Audio resampler safety**: `AudioResampler.Resample16BitMono()` and `ResampleStereoToMono16Bit()` validate `inputSampleRate > 0` and `outputSampleRate > 0` to prevent division by zero. Output sample count validated against `int.MaxValue / 2` to prevent integer overflow on buffer allocation.
- **SBC codec bounds**: `SbcDecoder.Decode()` validates `frameSize > 0 && frameSize <= 65536` before processing to reject malformed frames.
- **YAPP resource safety**: `Yapp` file transfer disposes `fileStream` in catch blocks when `OnProgress()` throws after file open, preventing resource leaks on event subscriber exceptions.

### Error handling
Protocol error responses (SMTP, IMAP, MCP JSON-RPC, MCP tool calls, YAPP transfer) use generic messages — never expose `ex.Message` to clients. `SelfUpdateDialog` uses generic error text instead of `ex.Message` to prevent information disclosure. IMAP sequence set parsing uses `TryParse` to prevent `FormatException` crashes from malformed client input. IMAP RFC822 header values sanitized via `SanitizeHeaderValue()` (strips CRLF, Unicode line separators) to prevent response injection from crafted mail content. SMTP requires authentication before `MAIL FROM`, `RCPT TO`, and `DATA` commands.

### File permissions
On Linux, PFX certificate files and settings JSON are written with chmod 600 (owner-only read/write). PFX files are exported with a randomly-generated passphrase stored in a separate `.key` file (chmod 600) for defense-in-depth beyond file permissions (backward-compatible loading of legacy hardcoded-passphrase and passwordless PFX). `JsonFileSettingsStore.Save()` uses **atomic write** (write to `.tmp`, chmod, then `File.Move` with overwrite) to prevent partial reads and permission windows. Debug log writes to `~/.config/HTCommander/debug.log` instead of CWD, with chmod 600 on Linux and 10MB size cap with rotation. `MailStore` storage directory set to chmod 700, database file to chmod 600, signal file to chmod 600, and attachments directory to chmod 700 on Linux — protects mail content and SQLite WAL journal files from other users. TLS certificates are loaded with `X509KeyStorageFlags.EphemeralKeySet` (not `Exportable`) to prevent private key extraction from memory. Temp files use GUID-based names to prevent predictable path attacks.

### Web security
Both `index.html` and `mobile.html` include Content-Security-Policy meta tags restricting `script-src` to `'self'` (no `unsafe-inline` — `index.html` inline script extracted to `app.js`), `connect-src` to `'self' ws: wss:` (no arbitrary http/https), `base-uri 'self'` (prevents base-href hijacking), and `frame-ancestors 'none'` (prevents clickjacking). `mobile.html` includes `Referrer-Policy: strict-origin-when-cross-origin`. CORS uses validated origin allowlist (localhost/loopback/private LAN/IPv6) with `Vary: Origin`. All innerHTML assignments use `escapeHtml()`. WebServer `/api/config` endpoint includes `Cache-Control: no-store` to prevent caching of sensitive configuration and provides `mcpToken` so the mobile web UI can authenticate with the MCP server when `ServerBindAll` is enabled. **When `ServerBindAll` is enabled, `/api/config` requires Bearer token authentication** (constant-time comparison without length pre-check) to prevent unauthenticated token disclosure; returns 503 if token is not yet initialized (no auth bypass). Mobile web UI (`mobile.js`) sends `Authorization: Bearer <token>` header on all MCP API calls, validates the MCP port (1-65535) before constructing URLs, and uses explicit `mode: 'cors'`/`credentials: 'omit'` on fetch calls. WebSocket authentication: mobile.js sends `AUTH:<token>` as first message on connect; `WebAudioBridge` validates with `FixedTimeEquals()` when `ServerBindAll` is enabled. WebServer static file responses include `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`. Service worker (`sw.js`) skips caching `/api/*` paths to prevent token persistence in browser cache. WebServer uses canonicalized `fullPath` (from `Path.GetFullPath`) with case-sensitive (`StringComparison.Ordinal`) prefix comparison for `File.ReadAllBytes` to close TOCTOU gap with symlinks. WebServer `/api/config` uses `JsonSerializer.Serialize()` for proper JSON encoding.

### Thread safety
`RadioAudioManager` uses `volatile` on all cross-thread fields (`transport`, `audioOutput`, `running`, `isConnecting`, `VoiceTransmitCancel`, `inAudioRun`, `_isMuted`, `_isAudioEnabled`, `PlayInputBack`); `StartTransmissionIfNeeded` uses `Interlocked.CompareExchange` on `_isTransmitting` to prevent double transmission start race. Voice transmission `TaskCompletionSource` (`newDataAvailable`) is protected by `newDataLock` to prevent race conditions between signal and reset that could cause transmission hangs. Both `OnTransmitVoicePCM` and `TransmitVoice` acquire `connectionLock` to prevent TOCTOU null reference races during disconnect. `Stop()` captures `audioLoopTask` under lock before waiting to prevent race with concurrent `Start()`. `Dispose()` uses `Interlocked.Exchange` on `_disposedFlag` for atomic double-dispose prevention. `TransmitVoice` validates `pcmOffset`/`pcmLength` bounds before `Buffer.BlockCopy`. `EscapeBytes` validates `len <= b.Length` before unsafe pointer operations. `StartRecording`/`StopRecording`/`DecodeSbcFrame` recording writes all use `recordingLock` to prevent race conditions between the audio loop thread and event dispatch; `_recording` is `volatile`; `StopRecording` nulls `_recorder` in a `finally` block to prevent use-after-dispose. `LinuxRadioBluetooth` uses `volatile` on `running` and `isConnecting` fields; `EnqueueWrite` captures `rfcommFd` under `connectionLock` to prevent TOCTOU race with concurrent `Disconnect()`, retries partial writes with EAGAIN handling to prevent GAIA protocol stream corruption; `CreateRfcommFd` validates `bdaddr` length before array access to prevent fd leaks on malformed input; `ConnectToGaiaChannel` wraps `VerifyGaiaResponse` in try/catch to always close the RFCOMM fd on exception. `LinuxRadioAudioTransport` uses `volatile` on `_isConnected` and `_disposed`; `nativeLock` serializes native buffer access in `ReadAsync`/`WriteAsync`/`Disconnect` to prevent use-after-free when `Disconnect()` frees `_readPtr`/`_writePtr` while I/O tasks are active; `errno` captured inside lock immediately after P/Invoke calls to prevent clobbering by concurrent I/O; pre-allocates native read/write buffers (4KB each) to avoid per-call `Marshal.AllocHGlobal` heap fragmentation; `ReadAsync` clamps `bytesRead` to both requested `count` and `buffer.Length - offset` before `Marshal.Copy` to prevent buffer overrun; `WriteAsync` validates `offset + count <= buffer.Length`; `CreateRfcommFd` validates `bdaddr` array length before access; `fcntl(F_GETFL)` return value is checked for errors before use (both in `LinuxRadioAudioTransport.ConnectAsync` and `LinuxRadioBluetooth.RunReadLoop` — the latter disconnects gracefully on failure). `RadioBluetoothWin` uses `volatile` on `running` and `isConnecting`; `OnConnected` fires via `ThreadPool.QueueUserWorkItem` to prevent Radio's initialization commands from blocking the read loop (matching Linux pattern). AX25Packet address count check (`>= 10`) is performed *before* adding to the list, preventing off-by-one that allowed 11 addresses. `TlsHttpServer` connection limit uses increment-then-check pattern (`Interlocked.Increment` first, then reject and decrement if > 100) to prevent race where multiple threads exceed the limit; `Stop()` uses `stopLock` + local variable capture to prevent TOCTOU on `cts`/`tcpListener`/`acceptTask`; `disposed` field is `volatile` for safe double-dispose check. `McpTools` PTT state (`mcpPttActive`, `mcpPttSilenceTimer`, `mcpPttTimeoutTimer`) protected by `mcpPttLock`; `mcpPttActive` is `volatile` for timer callback visibility; PTT auto-releases after 30s timeout via `McpPttTimeoutCallback` to prevent stuck transmit if MCP client disconnects. `WebAudioBridge` per-client `SemaphoreSlim` serializes `SendAsync` to prevent WebSocket framing corruption from concurrent sends, dropping frames for slow clients rather than queuing; rate limiting uses `ConcurrentDictionary.TryUpdate()` for atomic compare-and-swap to prevent concurrent frames bypassing the rate limit; `HandleAudioData` checks `pttOwner` under `pttLock` to prevent TOCTOU with concurrent PTT stop; PTT auto-releases after 30s of no audio from the owning client to prevent stuck PTT on disconnect; `DisconnectAll` disposes all per-client semaphores and clears rate-limit tracking. `AgwpeTcpClientHandler` constructor wraps `Task.Run` calls in try/catch to dispose on failure. `RigctldServer` uses `volatile` on shared fields (`pttActive`, `running`, `activeRadioId`); `SetPtt` uses `pttLock` to prevent race conditions on concurrent PTT toggling from multiple rigctld clients; PTT auto-releases after 30s timeout via `pttTimeoutTimer` to prevent stuck transmit on client disconnect; max 10 concurrent clients; auto-releases PTT when last client disconnects. `CatSerialServer` uses `volatile` on shared fields (`pttActive`, `running`, `activeRadioId`); `SetPtt` uses `pttLock` to prevent race conditions on concurrent PTT toggling; `commandBuffer` protected by `commandBufferLock` to prevent race conditions on concurrent `OnDataReceived` callbacks. `Radio.TncFragmentQueue` is consistently locked in `TransmitHardwareModem`, `ProcessTncQueue`, `HandleHtSendDataResponse`, `ClearTransmitQueue`, and `DeleteTransmitByTag`. `Radio.HandleBasicCommand` bounds-checks `value.Length` before accessing response fields (`WRITE_RF_CH` ≥ 6, `GET_VOLUME` ≥ 6, `READ_STATUS` ≥ 9). `SmtpServer` and `ImapServer` use `volatile` on `running` field for cross-thread visibility. `VirtualAudioBridge` uses `volatile` on `running` and `provider` fields. `WinRadioAudioTransport` uses `volatile` on `_isConnected` and `_disposed` fields. IMAP password comparison uses `CryptographicOperations.FixedTimeEquals()` to prevent timing attacks. `CatSerialServer` PTT auto-releases after 30s timeout via `pttTimeoutTimer` to prevent stuck transmit on serial port disconnect.

## Related Projects

- [khusmann/benlink](https://github.com/khusmann/benlink) — Python library for the same radios; reference for GAIA protocol, RFCOMM channel discovery, and audio codec details
- [SarahRoseLives/flutter_benlink](https://github.com/SarahRoseLives/flutter_benlink) — Flutter/Dart implementation; reference for initialization sequence and VR-N76 quirks (SYNC_SETTINGS handshake)
