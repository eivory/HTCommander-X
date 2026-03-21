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

namespace HTCommander
{
    /// <summary>
    /// Implements MCP tools for radio control, state queries, and debugging.
    /// All tools communicate through the DataBroker pub/sub system.
    /// </summary>
    public class McpTools
    {
        private readonly DataBrokerClient broker;

        public McpTools(DataBrokerClient broker)
        {
            this.broker = broker;
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
                return MakeToolError("Tool error: " + ex.Message);
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

        private object CallSetAppSetting(JsonElement args)
        {
            if (broker.GetValue<int>(0, "McpDebugToolsEnabled", 0) != 1)
                return MakeToolError("Debug tools are disabled.");

            string name = GetStringArg(args, "name");
            string value = GetStringArg(args, "value");

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
