/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

// MCP tool definitions for HTCommander radio control and debugging.
// Each tool maps to DataBroker queries/dispatches.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using HTCommander.radio;

namespace HTCommander
{
    /// <summary>
    /// Implements MCP tools for radio control, state queries, and debugging.
    /// All tools communicate through the DataBroker pub/sub system.
    /// </summary>
    public class McpTools
    {
        private static readonly string[] SettingsWhitelist = new[]
        {
            "CallSign", "StationId", "AllowTransmit", "Theme", "CheckForUpdates",
            "VoiceLanguage", "Voice", "SpeechToText", "MicGain", "OutputVolume",
            "ServerBindAll", "TlsEnabled", "WebServerEnabled", "WebServerPort",
            "McpServerEnabled", "McpServerPort",
            "RigctldServerEnabled", "RigctldServerPort", "CatServerEnabled",
            "AgwpeServerEnabled", "AgwpeServerPort", "VirtualAudioEnabled",
            "WinlinkPassword", "WinlinkUseStationId",
            "AirplaneServer", "RepeaterBookCountry", "RepeaterBookState",
            "ShowAllChannels", "ShowAirplanesOnMap", "SoftwareModemMode",
            "AudioOutputDevice", "AudioInputDevice"
        };

        private readonly DataBrokerClient broker;
        private bool mcpPttActive = false;
        private Timer mcpPttSilenceTimer;
        private int activeRadioId = -1;

        public McpTools(DataBrokerClient broker)
        {
            this.broker = broker;
            broker.Subscribe(1, "ConnectedRadios", (d, n, data) => { activeRadioId = GetFirstConnectedRadioId(); });
        }

        /// <summary>
        /// Returns all tool definitions for the tools/list response.
        /// </summary>
        public List<McpToolDefinition> GetToolDefinitions()
        {
            var tools = new List<McpToolDefinition>();

            // Radio query tools
            tools.Add(new McpToolDefinition
            {
                Name = "get_connected_radios",
                Description = "List all connected radios with their device IDs, MAC addresses, and connection state.",
                InputSchema = new McpToolInputSchema { Type = "object" }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_radio_state",
                Description = "Get the connection state of a specific radio (e.g. Connected, Disconnected, Connecting).",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_radio_info",
                Description = "Get device information for a connected radio: model, firmware version, capabilities (VFO, DMR, NOAA, GMRS), channel count, region count.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_radio_settings",
                Description = "Get current radio settings including VFO frequencies, squelch, volume, power level, and modulation mode.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_channels",
                Description = "Get all programmed channel configurations for a radio, including frequency, name, CTCSS tones, and power settings.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_gps_position",
                Description = "Get the GPS position from a connected radio (latitude, longitude, altitude, speed, heading).",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_battery",
                Description = "Get the battery percentage of a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            // Radio control tools
            tools.Add(new McpToolDefinition
            {
                Name = "set_vfo_channel",
                Description = "Switch VFO A or VFO B to a specific memory channel by channel index.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["vfo"] = new McpToolProperty { Type = "string", Description = "Which VFO to change", Enum = new List<string> { "A", "B" } },
                        ["channel_index"] = new McpToolProperty { Type = "integer", Description = "Channel index (0-based)", Minimum = 0 }
                    },
                    Required = new List<string> { "device_id", "vfo", "channel_index" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_volume",
                Description = "Set the hardware volume level of a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["level"] = new McpToolProperty { Type = "integer", Description = "Volume level", Minimum = 0, Maximum = 15 }
                    },
                    Required = new List<string> { "device_id", "level" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_squelch",
                Description = "Set the squelch level of a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["level"] = new McpToolProperty { Type = "integer", Description = "Squelch level", Minimum = 0, Maximum = 9 }
                    },
                    Required = new List<string> { "device_id", "level" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_audio",
                Description = "Enable or disable Bluetooth audio streaming on a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["enabled"] = new McpToolProperty { Type = "boolean", Description = "True to enable audio streaming, false to disable" }
                    },
                    Required = new List<string> { "device_id", "enabled" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_gps",
                Description = "Enable or disable GPS on a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["enabled"] = new McpToolProperty { Type = "boolean", Description = "True to enable GPS, false to disable" }
                    },
                    Required = new List<string> { "device_id", "enabled" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "disconnect_radio",
                Description = "Disconnect a connected radio by device ID.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "connect_radio",
                Description = "Connect to a radio by Bluetooth MAC address. If no MAC address is provided, connects to the last used radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["mac_address"] = new McpToolProperty { Type = "string", Description = "Bluetooth MAC address of the radio (e.g. '38D2000104E2'). If omitted, connects to the last used radio." }
                    }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "send_chat_message",
                Description = "Send a text chat message via the radio's voice handler (text-to-speech transmission).",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["message"] = new McpToolProperty { Type = "string", Description = "The text message to send" }
                    },
                    Required = new List<string> { "message" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "get_ht_status",
                Description = "Get live HT status: RSSI, TX/RX state, squelch, current channel, scan, GPS lock.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            // Extended radio control tools
            tools.Add(new McpToolDefinition
            {
                Name = "set_vfo_frequency",
                Description = "Tune VFO A or B to an arbitrary frequency using a scratch channel. This writes a temporary channel and switches the VFO to it.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["frequency_mhz"] = new McpToolProperty { Type = "number", Description = "Frequency in MHz (e.g. 146.52)" },
                        ["vfo"] = new McpToolProperty { Type = "string", Description = "Which VFO to tune (default A)", Enum = new List<string> { "A", "B" } },
                        ["modulation"] = new McpToolProperty { Type = "string", Description = "Modulation mode (default FM)", Enum = new List<string> { "FM", "AM", "DMR" } },
                        ["bandwidth"] = new McpToolProperty { Type = "string", Description = "Bandwidth (default wide)", Enum = new List<string> { "narrow", "wide" } },
                        ["power"] = new McpToolProperty { Type = "integer", Description = "Power level: 0=low, 1=medium, 2=high (default 2)", Minimum = 0, Maximum = 2 }
                    },
                    Required = new List<string> { "device_id", "frequency_mhz" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_ptt",
                Description = "Key (transmit) or unkey the radio. While PTT is active, silence frames are sent to keep the radio keyed. Use with audio streaming or external audio sources.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["enabled"] = new McpToolProperty { Type = "boolean", Description = "True to key the radio (start transmitting), false to unkey" }
                    },
                    Required = new List<string> { "enabled" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_dual_watch",
                Description = "Enable or disable dual watch mode (monitoring both VFO A and B).",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["enabled"] = new McpToolProperty { Type = "boolean", Description = "True to enable dual watch, false to disable" }
                    },
                    Required = new List<string> { "device_id", "enabled" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_scan",
                Description = "Enable or disable scan mode on a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["enabled"] = new McpToolProperty { Type = "boolean", Description = "True to enable scan, false to disable" }
                    },
                    Required = new List<string> { "device_id", "enabled" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_output_volume",
                Description = "Set the software output volume (separate from hardware volume). Controls local audio playback level.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["level"] = new McpToolProperty { Type = "integer", Description = "Output volume level", Minimum = 0, Maximum = 100 }
                    },
                    Required = new List<string> { "device_id", "level" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_mute",
                Description = "Mute or unmute audio output from a connected radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["enabled"] = new McpToolProperty { Type = "boolean", Description = "True to mute, false to unmute" }
                    },
                    Required = new List<string> { "device_id", "enabled" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "send_morse",
                Description = "Transmit a text message as Morse code via the radio's voice handler.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["text"] = new McpToolProperty { Type = "string", Description = "Text to transmit as Morse code" }
                    },
                    Required = new List<string> { "text" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "send_dtmf",
                Description = "Transmit DTMF tones over the radio. Valid digits: 0-9, *, #.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["digits"] = new McpToolProperty { Type = "string", Description = "DTMF digit string (0-9, *, #)" }
                    },
                    Required = new List<string> { "device_id", "digits" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "list_audio_clips",
                Description = "List all saved audio clips (WAV files) available for playback.",
                InputSchema = new McpToolInputSchema { Type = "object" }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "play_audio_clip",
                Description = "Play a saved audio clip over the radio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["clip_name"] = new McpToolProperty { Type = "string", Description = "Name of the audio clip to play" }
                    },
                    Required = new List<string> { "device_id", "clip_name" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "stop_audio_clip",
                Description = "Stop any currently playing audio clip.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "delete_audio_clip",
                Description = "Delete a saved audio clip.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["clip_name"] = new McpToolProperty { Type = "string", Description = "Name of the audio clip to delete" }
                    },
                    Required = new List<string> { "clip_name" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_software_modem",
                Description = "Set the software modem mode for packet radio operation.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["mode"] = new McpToolProperty { Type = "string", Description = "Modem mode", Enum = new List<string> { "None", "AFSK1200", "PSK2400", "PSK4800", "G3RUH9600" } }
                    },
                    Required = new List<string> { "mode" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "write_channel",
                Description = "Write/edit a radio channel slot with specified settings. Frequency values are in MHz, CTCSS tones in Hz (0 = none).",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" },
                        ["channel_index"] = new McpToolProperty { Type = "integer", Description = "Channel slot index (0-based)", Minimum = 0 },
                        ["rx_freq_mhz"] = new McpToolProperty { Type = "number", Description = "Receive frequency in MHz" },
                        ["tx_freq_mhz"] = new McpToolProperty { Type = "number", Description = "Transmit frequency in MHz (defaults to rx_freq_mhz if omitted)" },
                        ["name"] = new McpToolProperty { Type = "string", Description = "Channel name (max 10 characters)" },
                        ["modulation"] = new McpToolProperty { Type = "string", Description = "Modulation mode (default FM)", Enum = new List<string> { "FM", "AM", "DMR" } },
                        ["bandwidth"] = new McpToolProperty { Type = "string", Description = "Bandwidth (default wide)", Enum = new List<string> { "narrow", "wide" } },
                        ["power"] = new McpToolProperty { Type = "integer", Description = "Power level: 0=low, 1=medium, 2=high (default 2)", Minimum = 0, Maximum = 2 },
                        ["tx_tone_hz"] = new McpToolProperty { Type = "number", Description = "TX CTCSS tone in Hz (0 = none, e.g. 67.0, 100.0)" },
                        ["rx_tone_hz"] = new McpToolProperty { Type = "number", Description = "RX CTCSS tone in Hz (0 = none)" }
                    },
                    Required = new List<string> { "device_id", "channel_index", "rx_freq_mhz" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "enable_recording",
                Description = "Start recording radio audio to a WAV file.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "disable_recording",
                Description = "Stop recording radio audio.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["device_id"] = new McpToolProperty { Type = "integer", Description = "Radio device ID (100+)" }
                    },
                    Required = new List<string> { "device_id" }
                }
            });

            // Settings tools (production — whitelist-validated, no debug flag needed)
            var settingNames = new List<string>(SettingsWhitelist);
            settingNames.Sort();
            tools.Add(new McpToolDefinition
            {
                Name = "get_setting",
                Description = "Read an application setting by name. Returns the current value.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["name"] = new McpToolProperty { Type = "string", Description = "Setting name", Enum = settingNames }
                    },
                    Required = new List<string> { "name" }
                }
            });

            tools.Add(new McpToolDefinition
            {
                Name = "set_setting",
                Description = "Write an application setting. Changes take effect immediately.",
                InputSchema = new McpToolInputSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, McpToolProperty>
                    {
                        ["name"] = new McpToolProperty { Type = "string", Description = "Setting name", Enum = settingNames },
                        ["value"] = new McpToolProperty { Type = "string", Description = "Setting value (numeric values will be parsed as int)" }
                    },
                    Required = new List<string> { "name", "value" }
                }
            });

            // Debug tools
            bool debugEnabled = broker.GetValue<int>(0, "McpDebugToolsEnabled", 0) == 1;
            if (debugEnabled)
            {
                tools.Add(new McpToolDefinition
                {
                    Name = "get_logs",
                    Description = "Get recent application log entries (up to 500). Useful for debugging issues.",
                    InputSchema = new McpToolInputSchema
                    {
                        Type = "object",
                        Properties = new Dictionary<string, McpToolProperty>
                        {
                            ["count"] = new McpToolProperty { Type = "integer", Description = "Maximum number of recent log entries to return (default 50)", Minimum = 1, Maximum = 500 }
                        }
                    }
                });

                tools.Add(new McpToolDefinition
                {
                    Name = "get_databroker_state",
                    Description = "Dump all stored DataBroker values for a specific device. Device 0 = global settings, device 1 = app events, device 100+ = radios.",
                    InputSchema = new McpToolInputSchema
                    {
                        Type = "object",
                        Properties = new Dictionary<string, McpToolProperty>
                        {
                            ["device_id"] = new McpToolProperty { Type = "integer", Description = "Device ID to inspect" }
                        },
                        Required = new List<string> { "device_id" }
                    }
                });

                tools.Add(new McpToolDefinition
                {
                    Name = "get_app_setting",
                    Description = "Read an application setting by name from device 0.",
                    InputSchema = new McpToolInputSchema
                    {
                        Type = "object",
                        Properties = new Dictionary<string, McpToolProperty>
                        {
                            ["name"] = new McpToolProperty { Type = "string", Description = "Setting name (e.g. CallSign, AllowTransmit, WebServerEnabled)" }
                        },
                        Required = new List<string> { "name" }
                    }
                });

                tools.Add(new McpToolDefinition
                {
                    Name = "set_app_setting",
                    Description = "Write an application setting (device 0). Use with caution — changes take effect immediately.",
                    InputSchema = new McpToolInputSchema
                    {
                        Type = "object",
                        Properties = new Dictionary<string, McpToolProperty>
                        {
                            ["name"] = new McpToolProperty { Type = "string", Description = "Setting name" },
                            ["value"] = new McpToolProperty { Type = "string", Description = "Setting value (will be stored as string or parsed as int if numeric)" }
                        },
                        Required = new List<string> { "name", "value" }
                    }
                });

                tools.Add(new McpToolDefinition
                {
                    Name = "dispatch_event",
                    Description = "Dispatch an arbitrary event to the DataBroker. Advanced debugging tool — use with caution.",
                    InputSchema = new McpToolInputSchema
                    {
                        Type = "object",
                        Properties = new Dictionary<string, McpToolProperty>
                        {
                            ["device_id"] = new McpToolProperty { Type = "integer", Description = "Target device ID" },
                            ["name"] = new McpToolProperty { Type = "string", Description = "Event name" },
                            ["value"] = new McpToolProperty { Type = "string", Description = "Event value (string)" }
                        },
                        Required = new List<string> { "device_id", "name", "value" }
                    }
                });
            }

            return tools;
        }

        /// <summary>
        /// Calls a tool by name with the given arguments and returns the MCP result.
        /// </summary>
        public object CallTool(string name, JsonElement arguments)
        {
            try
            {
                switch (name)
                {
                    case "get_connected_radios": return CallGetConnectedRadios();
                    case "get_radio_state": return CallGetRadioState(arguments);
                    case "get_radio_info": return CallGetRadioInfo(arguments);
                    case "get_radio_settings": return CallGetRadioSettings(arguments);
                    case "get_channels": return CallGetChannels(arguments);
                    case "get_gps_position": return CallGetGpsPosition(arguments);
                    case "get_battery": return CallGetBattery(arguments);
                    case "set_vfo_channel": return CallSetVfoChannel(arguments);
                    case "set_volume": return CallSetVolume(arguments);
                    case "set_squelch": return CallSetSquelch(arguments);
                    case "set_audio": return CallSetAudio(arguments);
                    case "set_gps": return CallSetGps(arguments);
                    case "disconnect_radio": return CallDisconnectRadio(arguments);
                    case "connect_radio": return CallConnectRadio(arguments);
                    case "send_chat_message": return CallSendChatMessage(arguments);
                    case "get_ht_status": return CallGetHtStatus(arguments);
                    case "set_vfo_frequency": return CallSetVfoFrequency(arguments);
                    case "set_ptt": return CallSetPtt(arguments);
                    case "set_dual_watch": return CallSetDualWatch(arguments);
                    case "set_scan": return CallSetScan(arguments);
                    case "set_output_volume": return CallSetOutputVolume(arguments);
                    case "set_mute": return CallSetMute(arguments);
                    case "send_morse": return CallSendMorse(arguments);
                    case "send_dtmf": return CallSendDtmf(arguments);
                    case "list_audio_clips": return CallListAudioClips();
                    case "play_audio_clip": return CallPlayAudioClip(arguments);
                    case "stop_audio_clip": return CallStopAudioClip(arguments);
                    case "delete_audio_clip": return CallDeleteAudioClip(arguments);
                    case "set_software_modem": return CallSetSoftwareModem(arguments);
                    case "write_channel": return CallWriteChannel(arguments);
                    case "enable_recording": return CallEnableRecording(arguments);
                    case "disable_recording": return CallDisableRecording(arguments);
                    case "get_setting": return CallGetSetting(arguments);
                    case "set_setting": return CallSetSetting(arguments);
                    case "get_logs": return CallGetLogs(arguments);
                    case "get_databroker_state": return CallGetDataBrokerState(arguments);
                    case "get_app_setting": return CallGetAppSetting(arguments);
                    case "set_app_setting": return CallSetAppSetting(arguments);
                    case "dispatch_event": return CallDispatchEvent(arguments);
                    default:
                        return MakeToolError("Unknown tool: " + name);
                }
            }
            catch (Exception ex)
            {
                broker.LogInfo("MCP tool error (" + name + "): " + ex.Message);
                return MakeToolError("Tool execution failed");
            }
        }

        // ---- Radio Query Tools ----

        private object CallGetConnectedRadios()
        {
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            var radioList = new List<Dictionary<string, object>>();

            if (radios is IEnumerable enumerable)
            {
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    var radio = new Dictionary<string, object>();

                    var deviceIdProp = item.GetType().GetProperty("DeviceId");
                    if (deviceIdProp != null) radio["device_id"] = deviceIdProp.GetValue(item);

                    var macProp = item.GetType().GetProperty("MacAddress");
                    if (macProp != null) radio["mac_address"] = macProp.GetValue(item);

                    var stateProp = item.GetType().GetProperty("State");
                    if (stateProp != null) radio["state"] = stateProp.GetValue(item)?.ToString();

                    var friendlyProp = item.GetType().GetProperty("FriendlyName");
                    if (friendlyProp != null) radio["friendly_name"] = friendlyProp.GetValue(item);

                    radioList.Add(radio);
                }
            }

            return MakeToolResult(JsonSerializer.Serialize(radioList, new JsonSerializerOptions { WriteIndented = true }));
        }

        private object CallGetRadioState(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var state = broker.GetValue<string>(deviceId, "State", "Unknown");
            return MakeToolResult(state);
        }

        private object CallGetRadioInfo(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var info = broker.GetValue<object>(deviceId, "Info", null);
            if (info == null) return MakeToolResult("No radio info available for device " + deviceId);

            var result = new Dictionary<string, object>();
            var type = info.GetType();

            foreach (var field in type.GetFields())
            {
                if (field.Name == "raw") continue; // Skip raw byte array
                result[field.Name] = field.GetValue(info);
            }

            return MakeToolResult(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }

        private object CallGetRadioSettings(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var settings = broker.GetValue<object>(deviceId, "Settings", null);
            if (settings == null) return MakeToolResult("No radio settings available for device " + deviceId);

            var result = new Dictionary<string, object>();
            var type = settings.GetType();

            foreach (var field in type.GetFields())
            {
                if (field.Name == "raw") continue;
                var val = field.GetValue(settings);
                // Convert frequency fields from Hz to MHz for readability
                if (field.Name.Contains("freq") && val is long freqVal && freqVal > 1000000)
                {
                    result[field.Name] = freqVal;
                    result[field.Name + "_mhz"] = freqVal / 1000000.0;
                }
                else
                {
                    result[field.Name] = val;
                }
            }

            return MakeToolResult(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }

        private object CallGetChannels(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var channels = broker.GetValue<object>(deviceId, "Channels", null);
            if (channels == null) return MakeToolResult("No channel data available for device " + deviceId);

            if (channels is RadioChannelInfo[] channelArray)
            {
                var channelList = new List<Dictionary<string, object>>();
                for (int i = 0; i < channelArray.Length; i++)
                {
                    var ch = channelArray[i];
                    if (ch == null) continue;
                    var chDict = new Dictionary<string, object>
                    {
                        ["index"] = i,
                        ["name"] = ch.name_str,
                        ["rx_freq"] = ch.rx_freq,
                        ["rx_freq_mhz"] = ch.rx_freq / 1000000.0,
                        ["tx_freq"] = ch.tx_freq,
                        ["tx_freq_mhz"] = ch.tx_freq / 1000000.0,
                        ["bandwidth"] = ch.bandwidth == 0 ? "narrow" : "wide",
                        ["tx_at_max_power"] = ch.tx_at_max_power
                    };
                    channelList.Add(chDict);
                }
                return MakeToolResult(JsonSerializer.Serialize(channelList, new JsonSerializerOptions { WriteIndented = true }));
            }

            return MakeToolResult("Channel data format not recognized");
        }

        private object CallGetGpsPosition(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var position = broker.GetValue<object>(deviceId, "Position", null);
            if (position == null) return MakeToolResult("No GPS position available for device " + deviceId);

            var result = new Dictionary<string, object>();
            var type = position.GetType();

            foreach (var prop in type.GetProperties())
            {
                result[prop.Name] = prop.GetValue(position);
            }
            foreach (var field in type.GetFields())
            {
                result[field.Name] = field.GetValue(position);
            }

            return MakeToolResult(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }

        private object CallGetBattery(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var battery = broker.GetValue<int>(deviceId, "BatteryAsPercentage", -1);
            if (battery < 0) return MakeToolResult("No battery data available for device " + deviceId);
            return MakeToolResult(battery + "%");
        }

        // ---- Radio Control Tools ----

        private object CallSetVfoChannel(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            string vfo = GetStringArg(args, "vfo");
            int channelIndex = GetIntArg(args, "channel_index");

            string eventName = (vfo == "B") ? "ChannelChangeVfoB" : "ChannelChangeVfoA";
            broker.Dispatch(deviceId, eventName, channelIndex, store: false);
            return MakeToolResult("VFO " + vfo + " set to channel " + channelIndex);
        }

        private object CallSetVolume(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            int level = GetIntArg(args, "level");
            if (level < 0 || level > 15) return MakeToolError("Volume must be 0-15");
            broker.Dispatch(deviceId, "SetVolumeLevel", level, store: false);
            return MakeToolResult("Volume set to " + level);
        }

        private object CallSetSquelch(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            int level = GetIntArg(args, "level");
            if (level < 0 || level > 9) return MakeToolError("Squelch must be 0-9");
            broker.Dispatch(deviceId, "SetSquelchLevel", level, store: false);
            return MakeToolResult("Squelch set to " + level);
        }

        private object CallSetAudio(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            bool enabled = GetBoolArg(args, "enabled");
            broker.Dispatch(deviceId, "SetAudio", enabled, store: false);
            return MakeToolResult("Audio streaming " + (enabled ? "enabled" : "disabled"));
        }

        private object CallSetGps(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            bool enabled = GetBoolArg(args, "enabled");
            broker.Dispatch(deviceId, "SetGPS", enabled, store: false);
            return MakeToolResult("GPS " + (enabled ? "enabled" : "disabled"));
        }

        private object CallDisconnectRadio(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            broker.Dispatch(1, "McpDisconnectRadio", deviceId, store: false);
            return MakeToolResult("Disconnect requested for device " + deviceId);
        }

        private object CallConnectRadio(JsonElement args)
        {
            string macAddress = null;
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty("mac_address", out JsonElement macElem))
            {
                macAddress = macElem.GetString();
            }
            broker.Dispatch(1, "McpConnectRadio", macAddress ?? "", store: false);
            return MakeToolResult("Connect requested" + (string.IsNullOrEmpty(macAddress) ? " (last used radio)" : " for " + macAddress));
        }

        private object CallSendChatMessage(JsonElement args)
        {
            string message = GetStringArg(args, "message");
            if (string.IsNullOrEmpty(message)) return MakeToolError("Message cannot be empty");
            if (message.Length > 4096) return MakeToolError("Message too long (max 4096 characters)");
            broker.Dispatch(1, "Chat", message, store: false);
            return MakeToolResult("Chat message sent: " + message);
        }

        private object CallGetHtStatus(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            var status = broker.GetValue<RadioHtStatus>(deviceId, "HtStatus", null);
            if (status == null) return MakeToolResult("No HT status available for device " + deviceId);

            var result = new Dictionary<string, object>
            {
                ["rssi"] = status.rssi,
                ["is_power_on"] = status.is_power_on,
                ["is_in_tx"] = status.is_in_tx,
                ["is_in_rx"] = status.is_in_rx,
                ["is_sq"] = status.is_sq,
                ["curr_ch_id"] = status.curr_ch_id,
                ["is_scan"] = status.is_scan,
                ["is_gps_locked"] = status.is_gps_locked,
                ["double_channel"] = status.double_channel.ToString()
            };

            return MakeToolResult(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }

        // ---- Extended Radio Control Tools ----

        private object CallSetVfoFrequency(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            double freqMhz = GetDoubleArg(args, "frequency_mhz");
            string vfo = GetOptionalStringArg(args, "vfo", "A");
            string mod = GetOptionalStringArg(args, "modulation", "FM");
            string bw = GetOptionalStringArg(args, "bandwidth", "wide");
            int power = GetOptionalIntArg(args, "power", 2);

            var info = broker.GetValue<RadioDevInfo>(deviceId, "Info", null);
            if (info == null) return MakeToolError("No radio info available for device " + deviceId);

            // Validate frequency fits in int (max ~2.1 GHz) to prevent integer overflow
            long freqHz = (long)(freqMhz * 1000000);
            if (freqHz <= 0 || freqHz > int.MaxValue)
                return MakeToolError("Frequency out of range (must be between 0 and ~2147 MHz)");

            int scratchIndex = info.channel_count - 1;
            var scratch = new RadioChannelInfo();
            scratch.channel_id = scratchIndex;
            scratch.rx_freq = (int)freqHz;
            scratch.tx_freq = (int)freqHz;
            scratch.rx_mod = ParseModulation(mod);
            scratch.tx_mod = ParseModulation(mod);
            scratch.bandwidth = bw == "narrow" ? Radio.RadioBandwidthType.NARROW : Radio.RadioBandwidthType.WIDE;
            scratch.tx_at_max_power = (power == 2);
            scratch.tx_at_med_power = (power == 1);
            scratch.name_str = "QF";

            broker.Dispatch(deviceId, "WriteChannel", scratch, store: false);
            string eventName = (vfo == "B") ? "ChannelChangeVfoB" : "ChannelChangeVfoA";
            broker.Dispatch(deviceId, eventName, scratchIndex, store: false);
            return MakeToolResult($"VFO {vfo} set to {freqMhz} MHz ({mod}, {bw}, power {power}) on scratch channel {scratchIndex}");
        }

        private object CallSetPtt(JsonElement args)
        {
            bool enabled = GetBoolArg(args, "enabled");

            if (enabled && !mcpPttActive)
            {
                mcpPttActive = true;
                mcpPttSilenceTimer = new Timer(McpPttDispatchSilence, null, 0, 80);
                broker.Dispatch(1, "ExternalPttState", true, store: false);
                return MakeToolResult("PTT ON — radio is transmitting");
            }
            else if (!enabled && mcpPttActive)
            {
                mcpPttSilenceTimer?.Dispose();
                mcpPttSilenceTimer = null;
                mcpPttActive = false;
                broker.Dispatch(1, "ExternalPttState", false, store: false);
                return MakeToolResult("PTT OFF — radio stopped transmitting");
            }

            return MakeToolResult("PTT already " + (enabled ? "on" : "off"));
        }

        private void McpPttDispatchSilence(object state)
        {
            if (!mcpPttActive) return;
            int radioId = activeRadioId;
            if (radioId < 0) radioId = GetFirstConnectedRadioId();
            if (radioId < 0) return;
            byte[] silence = new byte[6400]; // 100ms of 32kHz 16-bit mono silence
            broker.Dispatch(radioId, "TransmitVoicePCM", silence, store: false);
        }

        private object CallSetDualWatch(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            bool enabled = GetBoolArg(args, "enabled");
            broker.Dispatch(deviceId, "DualWatch", enabled, store: false);
            return MakeToolResult("Dual watch " + (enabled ? "enabled" : "disabled"));
        }

        private object CallSetScan(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            bool enabled = GetBoolArg(args, "enabled");
            broker.Dispatch(deviceId, "Scan", enabled, store: false);
            return MakeToolResult("Scan " + (enabled ? "enabled" : "disabled"));
        }

        private object CallSetOutputVolume(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            int level = GetIntArg(args, "level");
            if (level < 0 || level > 100) return MakeToolError("Output volume must be 0-100");
            broker.Dispatch(deviceId, "SetOutputVolume", level, store: false);
            return MakeToolResult("Output volume set to " + level);
        }

        private object CallSetMute(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            bool enabled = GetBoolArg(args, "enabled");
            broker.Dispatch(deviceId, "SetMute", enabled, store: false);
            return MakeToolResult("Audio " + (enabled ? "muted" : "unmuted"));
        }

        private object CallSendMorse(JsonElement args)
        {
            string text = GetStringArg(args, "text");
            if (string.IsNullOrEmpty(text)) return MakeToolError("Text cannot be empty");
            broker.Dispatch(1, "Morse", text, store: false);
            return MakeToolResult("Morse code sent: " + text);
        }

        private object CallSendDtmf(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            string digits = GetStringArg(args, "digits");
            if (string.IsNullOrEmpty(digits)) return MakeToolError("Digits cannot be empty");

            byte[] pcm8 = DmtfEngine.GenerateDmtfPcm(digits);
            byte[] pcm16 = new byte[pcm8.Length * 2];
            for (int i = 0; i < pcm8.Length; i++)
            {
                short s = (short)((pcm8[i] - 128) << 8);
                pcm16[i * 2] = (byte)(s & 0xFF);
                pcm16[i * 2 + 1] = (byte)((s >> 8) & 0xFF);
            }
            broker.Dispatch(deviceId, "TransmitVoicePCM", new { Data = pcm16, PlayLocally = true }, store: false);
            return MakeToolResult("DTMF tones sent: " + digits);
        }

        private object CallListAudioClips()
        {
            var clips = broker.GetValue<object>(0, "AudioClips", null);
            if (clips == null) return MakeToolResult("No audio clips available");

            if (clips is IEnumerable enumerable)
            {
                var clipList = new List<Dictionary<string, object>>();
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    var entry = new Dictionary<string, object>();
                    var nameProp = item.GetType().GetProperty("Name");
                    var durProp = item.GetType().GetProperty("Duration");
                    var sizeProp = item.GetType().GetProperty("Size");
                    if (nameProp != null) entry["name"] = nameProp.GetValue(item);
                    if (durProp != null) entry["duration_ms"] = durProp.GetValue(item);
                    if (sizeProp != null) entry["size_bytes"] = sizeProp.GetValue(item);
                    clipList.Add(entry);
                }
                return MakeToolResult(JsonSerializer.Serialize(clipList, new JsonSerializerOptions { WriteIndented = true }));
            }
            return MakeToolResult("Audio clips data format not recognized");
        }

        private object CallPlayAudioClip(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            string clipName = GetStringArg(args, "clip_name");
            if (string.IsNullOrEmpty(clipName)) return MakeToolError("Clip name cannot be empty");
            if (clipName.Length > 256) return MakeToolError("Clip name too long (max 256 characters)");
            broker.Dispatch(deviceId, "PlayAudioClip", clipName, store: false);
            return MakeToolResult("Playing audio clip: " + clipName);
        }

        private object CallStopAudioClip(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            broker.Dispatch(deviceId, "StopAudioClip", null, store: false);
            return MakeToolResult("Audio clip playback stopped");
        }

        private object CallDeleteAudioClip(JsonElement args)
        {
            string clipName = GetStringArg(args, "clip_name");
            if (string.IsNullOrEmpty(clipName)) return MakeToolError("Clip name cannot be empty");
            if (clipName.Length > 256) return MakeToolError("Clip name too long (max 256 characters)");
            broker.Dispatch(DataBroker.AllDevices, "DeleteAudioClip", clipName, store: false);
            return MakeToolResult("Audio clip deleted: " + clipName);
        }

        private object CallSetSoftwareModem(JsonElement args)
        {
            string mode = GetStringArg(args, "mode");
            var validModes = new[] { "None", "AFSK1200", "PSK2400", "PSK4800", "G3RUH9600" };
            bool valid = false;
            foreach (var m in validModes) { if (m == mode) { valid = true; break; } }
            if (!valid) return MakeToolError("Invalid modem mode. Valid: None, AFSK1200, PSK2400, PSK4800, G3RUH9600");
            broker.Dispatch(0, "SetSoftwareModemMode", mode, store: false);
            return MakeToolResult("Software modem set to " + mode);
        }

        private object CallWriteChannel(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            int channelIndex = GetIntArg(args, "channel_index");
            double rxFreqMhz = GetDoubleArg(args, "rx_freq_mhz");
            double txFreqMhz = GetOptionalDoubleArg(args, "tx_freq_mhz", rxFreqMhz);
            string name = GetOptionalStringArg(args, "name", "");
            string mod = GetOptionalStringArg(args, "modulation", "FM");
            string bw = GetOptionalStringArg(args, "bandwidth", "wide");
            int power = GetOptionalIntArg(args, "power", 2);
            double txToneHz = GetOptionalDoubleArg(args, "tx_tone_hz", 0);
            double rxToneHz = GetOptionalDoubleArg(args, "rx_tone_hz", 0);

            if (name.Length > 10) name = name.Substring(0, 10);

            var channel = new RadioChannelInfo();
            channel.channel_id = channelIndex;
            // Validate frequency fits in int (max ~2.1 GHz) to prevent integer overflow
            long rxFreqHz = (long)(rxFreqMhz * 1000000);
            long txFreqHz = (long)(txFreqMhz * 1000000);
            if (rxFreqHz <= 0 || rxFreqHz > int.MaxValue)
                return MakeToolError("RX frequency out of range (must be between 0 and ~2147 MHz)");
            if (txFreqHz <= 0 || txFreqHz > int.MaxValue)
                return MakeToolError("TX frequency out of range (must be between 0 and ~2147 MHz)");
            channel.rx_freq = (int)rxFreqHz;
            channel.tx_freq = (int)txFreqHz;
            channel.rx_mod = ParseModulation(mod);
            channel.tx_mod = ParseModulation(mod);
            channel.bandwidth = bw == "narrow" ? Radio.RadioBandwidthType.NARROW : Radio.RadioBandwidthType.WIDE;
            channel.tx_at_max_power = (power == 2);
            channel.tx_at_med_power = (power == 1);
            channel.tx_sub_audio = (int)(txToneHz * 100);
            channel.rx_sub_audio = (int)(rxToneHz * 100);
            channel.name_str = name;

            broker.Dispatch(deviceId, "WriteChannel", channel, store: false);
            return MakeToolResult($"Channel {channelIndex} written: {rxFreqMhz} MHz, {name}");
        }

        private object CallEnableRecording(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            broker.Dispatch(deviceId, "RecordingEnable", deviceId, store: false);
            return MakeToolResult("Recording started for device " + deviceId);
        }

        private object CallDisableRecording(JsonElement args)
        {
            int deviceId = GetIntArg(args, "device_id");
            broker.Dispatch(deviceId, "RecordingDisable", null, store: false);
            return MakeToolResult("Recording stopped for device " + deviceId);
        }

        // ---- Settings Tools ----

        private bool IsWhitelistedSetting(string name)
        {
            foreach (var s in SettingsWhitelist) { if (s == name) return true; }
            return false;
        }

        private object CallGetSetting(JsonElement args)
        {
            string name = GetStringArg(args, "name");
            if (!IsWhitelistedSetting(name)) return MakeToolError("Setting '" + name + "' is not available. Use get_app_setting (debug mode) for unrestricted access.");
            var value = DataBroker.GetValue(0, name, null);
            if (value == null) return MakeToolResult(name + " = (not set)");
            return MakeToolResult(name + " = " + value.ToString());
        }

        private object CallSetSetting(JsonElement args)
        {
            string name = GetStringArg(args, "name");
            string value = GetStringArg(args, "value");
            if (!IsWhitelistedSetting(name)) return MakeToolError("Setting '" + name + "' is not available. Use set_app_setting (debug mode) for unrestricted access.");

            if (int.TryParse(value, out int intValue))
                broker.Dispatch(0, name, intValue);
            else
                broker.Dispatch(0, name, value);

            return MakeToolResult("Setting '" + name + "' set to: " + value);
        }

        // ---- Debug Tools ----

        private object CallGetLogs(JsonElement args)
        {
            int count = 50;
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty("count", out JsonElement countElem))
            {
                count = countElem.GetInt32();
            }

            var logStore = DataBroker.GetDataHandler<LogStore>("LogStore");
            if (logStore == null) return MakeToolResult("LogStore not available");

            var logs = logStore.GetLogs();
            int startIndex = Math.Max(0, logs.Count - count);
            var recentLogs = logs.GetRange(startIndex, logs.Count - startIndex);

            var logLines = new List<string>();
            foreach (var entry in recentLogs)
            {
                logLines.Add(entry.ToString());
            }

            return MakeToolResult(string.Join("\n", logLines));
        }

        private object CallGetDataBrokerState(JsonElement args)
        {
            if (broker.GetValue<int>(0, "McpDebugToolsEnabled", 0) != 1)
                return MakeToolError("Debug tools are disabled. Enable McpDebugToolsEnabled in settings.");

            int deviceId = GetIntArg(args, "device_id");
            var values = DataBroker.GetDeviceValues(deviceId);

            var result = new Dictionary<string, string>();
            foreach (var kvp in values)
            {
                try
                {
                    if (kvp.Value is byte[] bytes)
                        result[kvp.Key] = $"byte[{bytes.Length}]";
                    else if (kvp.Value != null)
                        result[kvp.Key] = kvp.Value.ToString();
                    else
                        result[kvp.Key] = "null";
                }
                catch
                {
                    result[kvp.Key] = kvp.Value?.GetType().Name ?? "null";
                }
            }

            return MakeToolResult(JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }

        private object CallGetAppSetting(JsonElement args)
        {
            if (broker.GetValue<int>(0, "McpDebugToolsEnabled", 0) != 1)
                return MakeToolError("Debug tools are disabled.");

            string name = GetStringArg(args, "name");
            var value = DataBroker.GetValue(0, name, null);
            if (value == null) return MakeToolResult("Setting '" + name + "' not found");
            return MakeToolResult(name + " = " + value.ToString());
        }

        // Critical settings that must never be modified via debug tools
        private static readonly HashSet<string> DebugSettingsBlacklist = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "McpApiToken", "McpDebugToolsEnabled", "TlsEnabled", "ServerBindAll", "WinlinkPassword"
        };

        private object CallSetAppSetting(JsonElement args)
        {
            if (broker.GetValue<int>(0, "McpDebugToolsEnabled", 0) != 1)
                return MakeToolError("Debug tools are disabled.");

            string name = GetStringArg(args, "name");
            string value = GetStringArg(args, "value");

            if (DebugSettingsBlacklist.Contains(name))
                return MakeToolError("Setting '" + name + "' cannot be modified via debug tools.");

            // Try to parse as int for numeric settings
            if (int.TryParse(value, out int intValue))
            {
                broker.Dispatch(0, name, intValue);
            }
            else
            {
                broker.Dispatch(0, name, value);
            }

            return MakeToolResult("Setting '" + name + "' set to: " + value);
        }

        private object CallDispatchEvent(JsonElement args)
        {
            if (broker.GetValue<int>(0, "McpDebugToolsEnabled", 0) != 1)
                return MakeToolError("Debug tools are disabled.");

            int deviceId = GetIntArg(args, "device_id");
            string name = GetStringArg(args, "name");
            string value = GetStringArg(args, "value");

            if (DebugSettingsBlacklist.Contains(name))
                return MakeToolError("Event '" + name + "' cannot be dispatched via debug tools.");

            broker.Dispatch(deviceId, name, value, store: false);
            return MakeToolResult("Dispatched event '" + name + "' to device " + deviceId);
        }

        // ---- Helpers ----

        private int GetIntArg(JsonElement args, string name)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetInt32();
            }
            throw new ArgumentException("Missing required argument: " + name);
        }

        private string GetStringArg(JsonElement args, string name)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetString();
            }
            throw new ArgumentException("Missing required argument: " + name);
        }

        private bool GetBoolArg(JsonElement args, string name)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetBoolean();
            }
            throw new ArgumentException("Missing required argument: " + name);
        }

        private double GetDoubleArg(JsonElement args, string name)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetDouble();
            }
            throw new ArgumentException("Missing required argument: " + name);
        }

        private string GetOptionalStringArg(JsonElement args, string name, string defaultValue)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetString() ?? defaultValue;
            }
            return defaultValue;
        }

        private int GetOptionalIntArg(JsonElement args, string name, int defaultValue)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetInt32();
            }
            return defaultValue;
        }

        private double GetOptionalDoubleArg(JsonElement args, string name, double defaultValue)
        {
            if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty(name, out JsonElement elem))
            {
                return elem.GetDouble();
            }
            return defaultValue;
        }

        private Radio.RadioModulationType ParseModulation(string mod)
        {
            switch (mod)
            {
                case "AM": return Radio.RadioModulationType.AM;
                case "DMR": return Radio.RadioModulationType.DMR;
                default: return Radio.RadioModulationType.FM;
            }
        }

        private int GetFirstConnectedRadioId()
        {
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            if (radios is IEnumerable enumerable)
            {
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    var prop = item.GetType().GetProperty("DeviceId");
                    if (prop != null)
                    {
                        object val = prop.GetValue(item);
                        if (val is int id && id > 0) return id;
                    }
                }
            }
            return -1;
        }

        private object MakeToolResult(string text)
        {
            return new
            {
                content = new[] { new McpToolContent { Type = "text", Text = text } }
            };
        }

        private object MakeToolError(string text)
        {
            return new
            {
                content = new[] { new McpToolContent { Type = "text", Text = text } },
                isError = true
            };
        }
    }
}
