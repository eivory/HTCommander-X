# MCP & Skills Integration — Implementation Reference

This document is a complete record of the MCP (Model Context Protocol) and Claude Code Skills integration added to HTCommander-X. It serves as a reference for understanding, maintaining, or fully removing this feature.

---

## Overview

The MCP integration allows AI assistants (Claude Code, or any MCP-compatible client) to control HTCommander programmatically — reading radio state, changing channels/volume/squelch, toggling GPS and audio, sending messages, and inspecting application internals for debugging.

It consists of three parts:

1. **MCP Server** — an HTTP server embedded in HTCommander.Core that speaks JSON-RPC 2.0 / MCP protocol
2. **Claude Code Skills** — markdown prompt templates that guide the AI through multi-step workflows
3. **MCP Client Config** — a `.mcp.json` file that tells Claude Code how to connect to the server

---

## Part 1: MCP Server (Core)

### New Files

All four files are in `HTCommander.Core/Utils/`:

| File | Purpose | Lines |
|------|---------|-------|
| `McpServer.cs` | Data handler with `TlsHttpServer` lifecycle. Follows the same self-initializing pattern as `RigctldServer.cs`: subscribes to `McpServerEnabled` / `McpServerPort` / `McpDebugToolsEnabled` / `ServerBindAll` / `TlsEnabled` on device 0, auto-starts/stops an HTTP(S) server on the configured port (default 5678). Binds to `localhost` by default; when `ServerBindAll` is 1, binds to all interfaces for LAN access. When `TlsEnabled` is 1, serves over HTTPS with a self-signed certificate. | ~190 |
| `McpJsonRpc.cs` | JSON-RPC 2.0 message types (`JsonRpcRequest`, `JsonRpcResponse`, `JsonRpcError`) and MCP protocol dispatcher (`McpProtocolHandler`). Routes `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read` methods. Also defines MCP data model classes: `McpToolDefinition`, `McpToolInputSchema`, `McpToolProperty`, `McpResourceDefinition`, `McpResourceContent`, `McpToolContent`. | ~270 |
| `McpTools.cs` | Tool definitions and implementations (39 tools). Each tool maps to `DataBroker.GetValue()` or `DataBroker.Dispatch()` calls. Contains `GetToolDefinitions()` (returns JSON Schema for each tool) and `CallTool(name, arguments)` (dispatches to the right handler method). Includes PTT state management with silence keepalive timer, scratch channel frequency tuning, DTMF PCM generation, and whitelist-validated settings access. | ~1100 |
| `McpResources.cs` | Resource definitions and readers. Resources are read-only state exposed as JSON. Dynamically lists per-radio resources based on connected radios. Contains `GetResourceDefinitions()` and `ReadResource(uri)`. | ~270 |

### Tools Provided (39 total)

**Radio Query Tools (8, always available):**

| Tool | Description | DataBroker Access |
|------|-------------|-------------------|
| `get_connected_radios` | List all connected radios with device ID, MAC, state, friendly name | `GetValue<object>(1, "ConnectedRadios")` via reflection |
| `get_radio_state` | Connection state of a radio (Connected, Disconnected, etc.) | `GetValue<string>(deviceId, "State")` |
| `get_radio_info` | Device model, firmware, capabilities (VFO, DMR, NOAA, etc.) | `GetValue<object>(deviceId, "Info")` — reflects `RadioDevInfo` fields |
| `get_radio_settings` | Current VFO frequencies, squelch, volume, modulation | `GetValue<object>(deviceId, "Settings")` — reflects `RadioSettings` fields, adds `_mhz` convenience fields |
| `get_channels` | All programmed channels: name, RX/TX freq, bandwidth, power | `GetValue<object>(deviceId, "Channels")` — casts to `RadioChannelInfo[]` |
| `get_gps_position` | GPS latitude, longitude, altitude, speed, heading | `GetValue<object>(deviceId, "Position")` — reflects all properties and fields |
| `get_battery` | Battery percentage | `GetValue<int>(deviceId, "BatteryAsPercentage")` |
| `get_ht_status` | Live HT status: RSSI, TX/RX, squelch, scan, GPS lock, current channel | `GetValue<RadioHtStatus>(deviceId, "HtStatus")` |

**Basic Radio Control Tools (7, always available):**

| Tool | Description | DataBroker Dispatch |
|------|-------------|---------------------|
| `connect_radio` | Connect to a radio by MAC address (or last used) | `Dispatch(1, "McpConnectRadio", macAddress)` |
| `disconnect_radio` | Disconnect a connected radio by device ID | `Dispatch(1, "McpDisconnectRadio", deviceId)` |
| `set_vfo_channel` | Switch VFO A or B to a memory channel by index | `Dispatch(deviceId, "ChannelChangeVfoA"/"ChannelChangeVfoB", channelIndex)` |
| `set_volume` | Set hardware volume (0-15) | `Dispatch(deviceId, "SetVolumeLevel", level)` |
| `set_squelch` | Set squelch level (0-9) | `Dispatch(deviceId, "SetSquelchLevel", level)` |
| `set_audio` | Enable/disable Bluetooth audio streaming | `Dispatch(deviceId, "SetAudio", bool)` |
| `set_gps` | Enable/disable GPS | `Dispatch(deviceId, "SetGPS", bool)` |

**Extended Radio Control Tools (10, always available):**

| Tool | Description | DataBroker Dispatch |
|------|-------------|---------------------|
| `set_vfo_frequency` | Tune VFO A/B to arbitrary frequency via scratch channel (MHz, modulation, bandwidth, power) | Writes `RadioChannelInfo` at `channel_count-1`, dispatches `WriteChannel` + `ChannelChangeVfoA/B` |
| `set_ptt` | Key/unkey the radio (with 80ms silence keepalive timer) | `Dispatch(1, "ExternalPttState", bool)` + `TransmitVoicePCM` silence frames |
| `set_dual_watch` | Enable/disable dual watch mode | `Dispatch(deviceId, "DualWatch", bool)` |
| `set_scan` | Enable/disable scan mode | `Dispatch(deviceId, "Scan", bool)` |
| `set_output_volume` | Set software output volume (0-100) | `Dispatch(deviceId, "SetOutputVolume", level)` |
| `set_mute` | Mute/unmute audio output | `Dispatch(deviceId, "SetMute", bool)` |
| `send_chat_message` | Send text chat via voice handler (TTS) | `Dispatch(1, "Chat", message)` |
| `send_morse` | Transmit Morse code via voice handler | `Dispatch(1, "Morse", text)` |
| `send_dtmf` | Transmit DTMF tones (0-9, *, #) — generates PCM via `DmtfEngine` | `DmtfEngine.GenerateDmtfPcm()` → 8-to-16-bit conversion → `Dispatch(deviceId, "TransmitVoicePCM")` |
| `set_software_modem` | Set software modem mode (None, AFSK1200, PSK2400, PSK4800, G3RUH9600) | `Dispatch(0, "SetSoftwareModemMode", mode)` |

**Audio Clip Tools (4, always available):**

| Tool | Description | DataBroker Access |
|------|-------------|-------------------|
| `list_audio_clips` | List all saved WAV clips (name, duration, size) | `GetValue<object>(0, "AudioClips")` |
| `play_audio_clip` | Play a saved clip over the radio | `Dispatch(deviceId, "PlayAudioClip", clipName)` |
| `stop_audio_clip` | Stop current clip playback | `Dispatch(deviceId, "StopAudioClip")` |
| `delete_audio_clip` | Delete a saved clip | `Dispatch(AllDevices, "DeleteAudioClip", clipName)` |

**Channel & Recording Tools (3, always available):**

| Tool | Description | DataBroker Dispatch |
|------|-------------|---------------------|
| `write_channel` | Write/edit a channel slot (freq MHz, name, modulation, bandwidth, CTCSS tones, power) | Builds `RadioChannelInfo`, dispatches `WriteChannel` |
| `enable_recording` | Start recording radio audio to WAV | `Dispatch(deviceId, "RecordingEnable", deviceId)` |
| `disable_recording` | Stop recording | `Dispatch(deviceId, "RecordingDisable")` |

**Settings Tools (2, always available — whitelist-validated):**

| Tool | Description | Implementation |
|------|-------------|----------------|
| `get_setting` | Read a whitelisted application setting | `DataBroker.GetValue(0, name)` — validates name against `SettingsWhitelist` |
| `set_setting` | Write a whitelisted application setting | `DataBroker.Dispatch(0, name, value)` — validates name, parses int if numeric |

Whitelisted settings: `CallSign`, `StationId`, `AllowTransmit`, `Theme`, `CheckForUpdates`, `VoiceLanguage`, `Voice`, `SpeechToText`, `MicGain`, `OutputVolume`, `ServerBindAll`, `TlsEnabled`, `WebServerEnabled`, `WebServerPort`, `McpServerEnabled`, `McpServerPort`, `McpDebugToolsEnabled`, `RigctldServerEnabled`, `RigctldServerPort`, `CatServerEnabled`, `AgwpeServerEnabled`, `AgwpeServerPort`, `VirtualAudioEnabled`, `WinlinkPassword`, `WinlinkUseStationId`, `AirplaneServer`, `RepeaterBookCountry`, `RepeaterBookState`, `ShowAllChannels`, `ShowAirplanesOnMap`, `SoftwareModemMode`, `AudioOutputDevice`, `AudioInputDevice`.

**Debug Tools (5, only available when `McpDebugToolsEnabled` is 1):**

| Tool | Description | Implementation |
|------|-------------|----------------|
| `get_logs` | Get recent log entries (up to 500, default 50) | `DataBroker.GetDataHandler<LogStore>("LogStore").GetLogs()` |
| `get_databroker_state` | Dump all stored values for a device ID | `DataBroker.GetDeviceValues(deviceId)` |
| `get_app_setting` | Read any setting by name from device 0 (unrestricted) | `DataBroker.GetValue(0, name)` |
| `set_app_setting` | Write any setting to device 0 (unrestricted, use with caution) | `DataBroker.Dispatch(0, name, value)` |
| `dispatch_event` | Dispatch arbitrary event to DataBroker (advanced) | `DataBroker.Dispatch(deviceId, name, value)` |

### Resources Provided

| URI Pattern | Description | Content |
|-------------|-------------|---------|
| `htcommander://app/settings` | All device 0 settings | JSON dict of all `DataBroker.GetDeviceValues(0)` |
| `htcommander://app/logs` | Application log entries | Plain text, one `[timestamp] [level] message` per line |
| `htcommander://radio/{deviceId}/info` | Radio device information | JSON from `RadioDevInfo` fields (excludes `raw` byte array) |
| `htcommander://radio/{deviceId}/settings` | Radio settings | JSON from `RadioSettings` fields (excludes `raw`) |
| `htcommander://radio/{deviceId}/channels` | Channel list | JSON array with index, name, rx/tx freq (Hz + MHz), bandwidth, power |
| `htcommander://radio/{deviceId}/status` | Composite status | JSON with state, battery_percent, volume, audio_state, friendly_name |

Radio resources are generated dynamically — one set per connected radio.

### DataBroker Settings Keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `McpServerEnabled` | int (0/1) | 0 | Enable/disable the MCP HTTP server |
| `McpServerPort` | int | 5678 | TCP port for the HTTP listener |
| `McpDebugToolsEnabled` | int (0/1) | 0 | Enable/disable debug tools (DataBroker inspection, event dispatch) |
| `TlsEnabled` | int (0/1) | 0 | Enable TLS/HTTPS for WebServer and McpServer (shared setting) |

### Protocol Details

- **Transport**: HTTP or HTTPS on `localhost:{port}` (when `ServerBindAll` is 1, binds to all interfaces for LAN access)
- **TLS**: When `TlsEnabled` is 1, uses `TcpListener` + `SslStream` with a self-signed certificate (auto-generated, stored as PFX in config directory). Required for mobile `getUserMedia()` mic access over LAN.
- **Method**: `POST` to any path (e.g., `/`, `/mcp`)
- **Content-Type**: `application/json` (JSON-RPC 2.0)
- **CORS**: `Access-Control-Allow-Origin: *` (for browser-based MCP clients)
- **MCP Protocol Version**: `2024-11-05`
- **Server Info**: `name: "htcommander"`, `version: "1.0.0"`

---

## Part 2: Settings UI (Desktop)

### Modified Files

**`HTCommander.Desktop/Dialogs/SettingsDialog.axaml`** — Added in the Servers tab, after the Virtual Audio Bridge section and before the `PortWarning` TextBlock:

- `CheckBox` named `McpServerCheck` with content "Enable MCP Server (AI Control)"
- `NumericUpDown` named `McpPortUpDown` (port, default 5678)
- `CheckBox` named `McpDebugCheck` with content "Enable debug tools (DataBroker inspection, event dispatch)"
- `TextBlock` with description text

**`HTCommander.Desktop/Dialogs/SettingsDialog.axaml.cs`** — Added load/save lines:

- **Load** (in `LoadSettings` method, after `VirtualAudioCheck`):
  ```csharp
  McpServerCheck.IsChecked = DataBroker.GetValue<int>(0, "McpServerEnabled", 0) == 1;
  McpPortUpDown.Value = DataBroker.GetValue<int>(0, "McpServerPort", 5678);
  McpDebugCheck.IsChecked = DataBroker.GetValue<int>(0, "McpDebugToolsEnabled", 0) == 1;
  ```
- **Save** (in `SaveSettings` method, after `VirtualAudioEnabled`):
  ```csharp
  DataBroker.Dispatch(0, "McpServerEnabled", McpServerCheck.IsChecked == true ? 1 : 0);
  DataBroker.Dispatch(0, "McpServerPort", (int)(McpPortUpDown.Value ?? 5678));
  DataBroker.Dispatch(0, "McpDebugToolsEnabled", McpDebugCheck.IsChecked == true ? 1 : 0);
  ```

---

## Part 3: Data Handler Registration (Desktop)

### Modified File

**`HTCommander.Desktop/MainWindow.axaml.cs`** — Added one line at the end of `InitializeDataHandlers()`:

```csharp
DataBroker.AddDataHandler("McpServer", new McpServer());
```

---

## Part 4: Claude Code Skills

### New Files

| File | Purpose |
|------|---------|
| `.claude/skills/radio-status/SKILL.md` | Skill that guides Claude Code to check connected radio status using MCP tools: lists radios, gathers battery/GPS/VFO/settings, presents a summary table |
| `.claude/skills/debug-radio/SKILL.md` | Skill that guides Claude Code through debugging: checks connectivity, reads logs for errors, inspects DataBroker state, reports findings |

Skills are markdown files with YAML frontmatter. They are automatically discovered by Claude Code when present in `.claude/skills/`. They do not contain executable code — they are prompt templates that instruct the AI on which MCP tools to call and in what order.

---

## Part 5: MCP Client Config

### New File

**`.mcp.json`** (project root) — tells Claude Code to connect to the HTCommander MCP server:

```json
{
  "mcpServers": {
    "htcommander": {
      "type": "http",
      "url": "http://localhost:5678/"
    }
  }
}
```

---

## Complete File Inventory

### New files to remove for full cleanup

```
HTCommander.Core/Utils/McpServer.cs
HTCommander.Core/Utils/McpJsonRpc.cs
HTCommander.Core/Utils/McpTools.cs
HTCommander.Core/Utils/McpResources.cs
.claude/skills/radio-status/SKILL.md
.claude/skills/debug-radio/SKILL.md
.mcp.json
docs/MCP-Integration.md              (this file)
```

### Modified files to revert

**`HTCommander.Desktop/MainWindow.axaml.cs`** — remove this line from `InitializeDataHandlers()`:
```csharp
DataBroker.AddDataHandler("McpServer", new McpServer());
```

**`HTCommander.Desktop/Dialogs/SettingsDialog.axaml`** — remove the entire MCP `StackPanel` (the one containing `McpServerCheck`, `McpPortUpDown`, `McpDebugCheck`, and the description TextBlock).

**`HTCommander.Desktop/Dialogs/SettingsDialog.axaml.cs`** — remove these 3 lines from `LoadSettings`:
```csharp
McpServerCheck.IsChecked = DataBroker.GetValue<int>(0, "McpServerEnabled", 0) == 1;
McpPortUpDown.Value = DataBroker.GetValue<int>(0, "McpServerPort", 5678);
McpDebugCheck.IsChecked = DataBroker.GetValue<int>(0, "McpDebugToolsEnabled", 0) == 1;
```

And these 3 lines from `SaveSettings`:
```csharp
DataBroker.Dispatch(0, "McpServerEnabled", McpServerCheck.IsChecked == true ? 1 : 0);
DataBroker.Dispatch(0, "McpServerPort", (int)(McpPortUpDown.Value ?? 5678));
DataBroker.Dispatch(0, "McpDebugToolsEnabled", McpDebugCheck.IsChecked == true ? 1 : 0);
```

### User settings to clean up (optional)

If the MCP server was previously enabled, these keys persist in the user's settings store (`~/.config/HTCommander/` on Linux, Windows Registry on Windows):

- `McpServerEnabled`
- `McpServerPort`
- `McpDebugToolsEnabled`

These are harmless to leave behind (they will be ignored if the code is removed), but can be cleaned up by resetting settings in the app.

### No NuGet dependencies were added

The MCP implementation uses only `System.Net.HttpListener` and `System.Text.Json`, both of which are part of the .NET 9.0 base class library. No new NuGet packages were introduced.
