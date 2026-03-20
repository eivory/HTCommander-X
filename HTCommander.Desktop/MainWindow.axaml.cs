/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
using HamLib;
using HTCommander.Desktop.Dialogs;

namespace HTCommander.Desktop
{
    public class ChannelDisplayItem
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Frequency { get; set; }
        public IBrush Background { get; set; }
        public IBrush NameColor { get; set; }
        public int ChannelIndex { get; set; }
        public int DeviceId { get; set; }
    }

    public partial class MainWindow : Window
    {
        private DataBrokerClient broker;
        private List<Radio> connectedRadios = new List<Radio>();
        private const int StartingDeviceId = 100;
        private bool dataHandlersInitialized = false;
        private int activeDeviceId = -1;
        private RadioChannelInfo[] currentChannels;
        private RadioSettings currentSettings;
        private RadioHtStatus currentStatus;
        private RadioDevInfo currentDevInfo;
        private Dictionary<int, string> radioFriendlyNames = new Dictionary<int, string>();
        private bool showAllChannels;

        private string GetRadioName(int deviceId)
        {
            if (radioFriendlyNames.TryGetValue(deviceId, out string name) && !string.IsNullOrEmpty(name))
                return name;
            return $"Radio {deviceId}";
        }

        public MainWindow()
        {
            InitializeComponent();

            if (SynchronizationContext.Current != null)
            {
                DataBroker.SetSyncContext(SynchronizationContext.Current);
            }

            broker = new DataBrokerClient();
            InitializeDataHandlers();

            // Subscribe to radio state changes for status bar
            broker.Subscribe(DataBroker.AllDevices, "State", OnRadioStateChanged);
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);

            // Subscribe to radio data for the info panel
            broker.Subscribe(DataBroker.AllDevices, "HtStatus", OnHtStatusChanged);
            broker.Subscribe(DataBroker.AllDevices, "Settings", OnSettingsChanged);
            broker.Subscribe(DataBroker.AllDevices, "Channels", OnChannelsChanged);
            broker.Subscribe(DataBroker.AllDevices, "BatteryAsPercentage", OnBatteryChanged);
            broker.Subscribe(DataBroker.AllDevices, "Info", OnDevInfoChanged);
            broker.Subscribe(DataBroker.AllDevices, "FriendlyName", OnFriendlyNameChanged);
            broker.Subscribe(DataBroker.AllDevices, "AudioState", OnAudioStateChanged);
            broker.Subscribe(0, "SoftwareModemMode", OnSoftwareModemModeChanged);

            // Init software modem checkbox
            string modemMode = DataBroker.GetValue<string>(0, "SoftwareModemMode", "None");
            SoftwareModemCheck.IsChecked = modemMode != null && modemMode != "None";

            // Init all channels toggle
            showAllChannels = DataBroker.GetValue<int>(0, "ShowAllChannels", 0) == 1;
            AllChannelsCheck.IsChecked = showAllChannels;

            // Refresh channel list on theme change so colors update
            this.ActualThemeVariantChanged += (s, e) => UpdateChannelList();

            broker.LogInfo("HTCommander Desktop (Avalonia) started. Ready to connect.");
        }

        private void InitializeDataHandlers()
        {
            if (dataHandlersInitialized) return;
            dataHandlersInitialized = true;

            DataBroker.AddDataHandler("FrameDeduplicator", new FrameDeduplicator());
            DataBroker.AddDataHandler("SoftwareModem", new SoftwareModem());
            DataBroker.AddDataHandler("PacketStore", new PacketStore());
            DataBroker.AddDataHandler("VoiceHandler", new VoiceHandler(Program.PlatformServices?.Speech));
            DataBroker.AddDataHandler("LogStore", new LogStore());
            DataBroker.AddDataHandler("AprsHandler", new AprsHandler());
            DataBroker.AddDataHandler("Torrent", new Torrent());
            DataBroker.AddDataHandler("BbsHandler", new BbsHandler());
            DataBroker.AddDataHandler("MailStore", new MailStore());
            DataBroker.AddDataHandler("WinlinkClient", new WinlinkClient());
            DataBroker.AddDataHandler("AirplaneHandler", new HTCommander.Airplanes.AirplaneHandler());
            DataBroker.AddDataHandler("GpsSerialHandler", new HTCommander.Gps.GpsSerialHandler());
            DataBroker.AddDataHandler("AgwpeServer", new AgwpeServer());
            DataBroker.AddDataHandler("AudioClipHandler", new AudioClipHandler());
        }

        private void OnRadioStateChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                // Radio dispatches state as a string (e.g. "Connected")
                string stateStr = data?.ToString() ?? "";
                switch (stateStr)
                {
                    case "Connected":
                        if (!radioFriendlyNames.ContainsKey(deviceId))
                        {
                            string fn = DataBroker.GetValue<string>(deviceId, "FriendlyName", null);
                            if (!string.IsNullOrEmpty(fn)) radioFriendlyNames[deviceId] = fn;
                        }
                        StatusText.Text = $"{GetRadioName(deviceId)}: Connected";
                        StatusBarText.Text = $"Connected to {GetRadioName(deviceId)}";
                        ConnectButton.IsEnabled = true;
                        DisconnectButton.IsEnabled = true;
                        MenuDisconnect.IsEnabled = true;
                        MenuRadioInfo.IsEnabled = true;
                        MenuGpsInfo.IsEnabled = true;
                        MenuExportChannels.IsEnabled = true;
                        MenuDualWatch.IsEnabled = true;
                        MenuScan.IsEnabled = true;
                        MenuGpsEnabled.IsEnabled = true;
                        MenuAudioEnabled.IsEnabled = true;
                        MenuAudioClips.IsEnabled = true;
                        MainPttButton.IsVisible = true;
                        WavTransmitPanel.IsVisible = true;
                        activeDeviceId = deviceId;
                        if (RadioPanelCheck.IsChecked == true) RadioPanel.IsVisible = true;
                        RadioStateText.Text = "Connected";
                        RadioStateText.Foreground = new SolidColorBrush(Color.Parse("#4CAF50"));
                        break;
                    case "Connecting":
                        StatusText.Text = $"{GetRadioName(deviceId)}: Connecting...";
                        StatusBarText.Text = $"Connecting to {GetRadioName(deviceId)}...";
                        RadioPanel.IsVisible = RadioPanelCheck.IsChecked == true;
                        RadioStateText.Text = "Connecting...";
                        RadioStateText.Foreground = new SolidColorBrush(Color.Parse("#FFC107"));
                        break;
                    case "Disconnected":
                        StatusText.Text = connectedRadios.Count > 0 ? $"{GetRadioName(deviceId)}: Disconnected" : "Not connected";
                        StatusBarText.Text = "Ready";
                        ConnectButton.IsEnabled = true;
                        DisconnectButton.IsEnabled = false;
                        MenuDisconnect.IsEnabled = false;
                        MenuRadioInfo.IsEnabled = false;
                        MenuGpsInfo.IsEnabled = false;
                        MenuExportChannels.IsEnabled = false;
                        MenuDualWatch.IsEnabled = false;
                        MenuScan.IsEnabled = false;
                        MenuGpsEnabled.IsEnabled = false;
                        MenuAudioEnabled.IsEnabled = false;
                        MenuAudioClips.IsEnabled = false;
                        MainPttButton.IsVisible = false;
                        WavTransmitPanel.IsVisible = false;
                        MainWavStatus.Text = "";
                        BatteryStatusText.Text = "";
                        if (deviceId == activeDeviceId)
                        {
                            activeDeviceId = -1;
                            RadioPanel.IsVisible = false;
                            currentChannels = null;
                            currentSettings = null;
                            currentStatus = null;
                            currentDevInfo = null;
                        }
                        break;
                    case "UnableToConnect":
                        StatusText.Text = $"{GetRadioName(deviceId)}: Unable to connect";
                        StatusBarText.Text = "Connection failed";
                        ConnectButton.IsEnabled = true;
                        RadioPanel.IsVisible = false;
                        ShowCantConnectDialog();
                        break;
                    case "BluetoothNotAvailable":
                        StatusText.Text = "Bluetooth not available";
                        StatusBarText.Text = "Bluetooth not available";
                        ConnectButton.IsEnabled = true;
                        RadioPanel.IsVisible = false;
                        ShowBluetoothActivateDialog();
                        break;
                }
            });
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                // Rebuild radio selection submenu
                MenuRadioSelect.Items.Clear();
                if (data is System.Collections.IEnumerable enumerable)
                {
                    int count = 0;
                    foreach (var item in enumerable)
                    {
                        if (item == null) continue;
                        count++;
                        var did = (int?)item.GetType().GetProperty("DeviceId")?.GetValue(item);
                        if (!did.HasValue) continue;
                        int radioDevId = did.Value;
                        string radioName = GetRadioName(radioDevId);
                        var menuItem = new MenuItem { Header = radioName };
                        // Add check mark for active radio
                        if (radioDevId == activeDeviceId)
                        {
                            menuItem.Icon = new CheckBox { IsChecked = true, BorderThickness = new Avalonia.Thickness(0), IsHitTestVisible = false };
                        }
                        int capturedId = radioDevId;
                        menuItem.Click += (s, e) =>
                        {
                            activeDeviceId = capturedId;
                            // Reload data for this radio
                            var channels = DataBroker.GetValue<RadioChannelInfo[]>(capturedId, "Channels", null);
                            if (channels != null) { currentChannels = channels; }
                            var settings = DataBroker.GetValue<RadioSettings>(capturedId, "Settings", null);
                            if (settings != null) { currentSettings = settings; }
                            var devInfo = DataBroker.GetValue<RadioDevInfo>(capturedId, "Info", null);
                            if (devInfo != null) { currentDevInfo = devInfo; }
                            UpdateVfoDisplay();
                            UpdateChannelList();
                            UpdateVfoModeMenuItems();
                            // Re-trigger connected radios to update check marks
                            OnConnectedRadiosChanged(1, "ConnectedRadios", DataBroker.GetValue<object>(1, "ConnectedRadios", null));
                        };
                        MenuRadioSelect.Items.Add(menuItem);
                    }
                    MenuRadioSelect.IsVisible = count > 1;
                }
                else
                {
                    MenuRadioSelect.IsVisible = false;
                }
            });
        }

        private void OnFriendlyNameChanged(int deviceId, string name, object data)
        {
            string friendlyName = data?.ToString();
            if (!string.IsNullOrEmpty(friendlyName))
                radioFriendlyNames[deviceId] = friendlyName;

            if (deviceId != activeDeviceId) return;
            Dispatcher.UIThread.Post(() =>
            {
                RadioNameText.Text = friendlyName ?? "Radio";
                // Update status bar if connected
                string stateStr = DataBroker.GetValue<string>(deviceId, "State", "");
                if (stateStr == "Connected")
                {
                    StatusText.Text = $"{GetRadioName(deviceId)}: Connected";
                    StatusBarText.Text = $"Connected to {GetRadioName(deviceId)}";
                }
            });
        }

        private void OnHtStatusChanged(int deviceId, string name, object data)
        {
            if (data is not RadioHtStatus status) return;
            if (activeDeviceId < 0) activeDeviceId = deviceId;
            if (deviceId != activeDeviceId) return;
            currentStatus = status;

            Dispatcher.UIThread.Post(() =>
            {
                RssiBar.Value = status.rssi;
                int filled = Math.Min(status.rssi / 2, 8);
                ScreenRssiText.Text = "S " + new string('▮', filled) + new string('▯', 8 - filled);
                TxIndicatorFill.Background = status.is_in_tx ? Brushes.Red : new SolidColorBrush(Color.Parse("#333"));
                GpsText.Text = status.is_gps_locked ? "Locked" : "No fix";
                GpsText.Foreground = status.is_gps_locked ? Brushes.LimeGreen : GetThemeBrush("PrimaryText");
                ScanText.Text = status.is_scan ? "Active" : "Off";
                PowerText.Text = status.is_power_on ? "On" : "Off";

                UpdateVfoDisplay();
                UpdateChannelHighlights();
            });
        }

        private void OnSettingsChanged(int deviceId, string name, object data)
        {
            if (data is not RadioSettings settings) return;
            if (activeDeviceId < 0) activeDeviceId = deviceId;
            if (deviceId != activeDeviceId) return;
            currentSettings = settings;

            Dispatcher.UIThread.Post(() =>
            {
                SquelchText.Text = settings.squelch_level.ToString();
                DualWatchCheck.IsChecked = settings.double_channel == 1;
                ScanCheck.IsChecked = settings.scan;
                UpdateVfoDisplay();
                UpdateChannelList();
                UpdateVfoModeMenuItems();
            });
        }

        private void OnChannelsChanged(int deviceId, string name, object data)
        {
            if (data is not RadioChannelInfo[] channels) return;
            if (activeDeviceId < 0) activeDeviceId = deviceId;
            if (deviceId != activeDeviceId) return;
            currentChannels = channels;

            Dispatcher.UIThread.Post(() =>
            {
                UpdateVfoDisplay();
                UpdateChannelList();
            });
        }

        private void OnBatteryChanged(int deviceId, string name, object data)
        {
            if (deviceId != activeDeviceId && activeDeviceId >= 0) return;
            Dispatcher.UIThread.Post(() =>
            {
                string battStr;
                if (data is int pct)
                    battStr = $"{pct}%";
                else
                    battStr = data?.ToString() ?? "--%";

                BatteryText.Text = battStr;
                BatteryStatusText.Text = $"Battery: {battStr}";
            });
        }

        private IBrush GetThemeBrush(string resourceKey)
        {
            var themeVariant = this.ActualThemeVariant;
            if (this.TryFindResource(resourceKey, themeVariant, out object value) && value is IBrush brush)
                return brush;
            // Fallback: light text on dark theme, dark text on light theme
            bool isDark = themeVariant?.ToString() == "Dark";
            return isDark ? new SolidColorBrush(Color.Parse("#E0E0E0")) : new SolidColorBrush(Color.Parse("#1E1E1E"));
        }

        private static string FormatFrequency(int freq)
        {
            if (freq <= 0) return "--- .--- MHz";
            double mhz = freq / 1000000.0;
            return $"{mhz:F5} MHz";
        }

        private void UpdateVfoDisplay()
        {
            if (currentSettings == null || currentChannels == null) return;

            int chA = currentSettings.channel_a;
            int chB = currentSettings.channel_b;

            RadioChannelInfo infoA = (chA >= 0 && chA < currentChannels.Length) ? currentChannels[chA] : null;
            RadioChannelInfo infoB = (chB >= 0 && chB < currentChannels.Length) ? currentChannels[chB] : null;

            VfoAName.Text = infoA != null && !string.IsNullOrEmpty(infoA.name_str) ? infoA.name_str : $"CH {chA + 1}";
            VfoAFreq.Text = infoA != null ? FormatFrequency(infoA.rx_freq) : "--- .--- MHz";

            VfoBName.Text = infoB != null && !string.IsNullOrEmpty(infoB.name_str) ? infoB.name_str : $"CH {chB + 1}";
            VfoBFreq.Text = infoB != null ? FormatFrequency(infoB.rx_freq) : "--- .--- MHz";

            // Update the radio screen overlay
            ScreenVfoA.Text = infoA != null ? FormatFrequencyShort(infoA.rx_freq) : "----.---";
            ScreenVfoB.Text = infoB != null ? FormatFrequencyShort(infoB.rx_freq) : "----.---";
        }

        private static string FormatFrequencyShort(int freq)
        {
            if (freq <= 0) return "----.---";
            double mhz = freq / 1000000.0;
            return $"{mhz:F3}";
        }

        private void UpdateChannelList()
        {
            if (currentChannels == null) return;

            int activeA = currentSettings?.channel_a ?? -1;
            int activeB = currentSettings?.channel_b ?? -1;

            var items = new List<ChannelDisplayItem>();
            for (int i = 0; i < currentChannels.Length; i++)
            {
                var ch = currentChannels[i];
                if (ch == null) continue;
                if (!showAllChannels && string.IsNullOrEmpty(ch.name_str) && ch.rx_freq == 0) continue;

                bool isA = (i == activeA);
                bool isB = (i == activeB);

                IBrush bg;
                IBrush nameColor;
                if (isA) { bg = new SolidColorBrush(Color.Parse("#1B3A4B")); nameColor = new SolidColorBrush(Color.Parse("#64B5F6")); }
                else if (isB) { bg = new SolidColorBrush(Color.Parse("#2A1B3A")); nameColor = new SolidColorBrush(Color.Parse("#CE93D8")); }
                else { bg = Brushes.Transparent; nameColor = GetThemeBrush("PrimaryText"); }

                int deviceId = connectedRadios.Count > 0 ? connectedRadios[0].DeviceId : -1;
                items.Add(new ChannelDisplayItem
                {
                    Id = (i + 1).ToString(),
                    Name = !string.IsNullOrEmpty(ch.name_str) ? ch.name_str : $"CH {i + 1}",
                    Frequency = FormatFrequency(ch.rx_freq),
                    Background = bg,
                    NameColor = nameColor,
                    ChannelIndex = i,
                    DeviceId = deviceId
                });
            }

            ChannelList.ItemsSource = items;
        }

        private void UpdateChannelHighlights()
        {
            // Re-render channel list with updated active channel from HtStatus
            UpdateChannelList();
        }

        private async void ConnectButton_Click(object sender, RoutedEventArgs e)
        {
            var platform = Program.PlatformServices;
            if (platform == null)
            {
                broker.LogError("Platform services not initialized.");
                return;
            }

            // Use a temporary IRadioBluetooth for scanning
            var scanner = platform.CreateRadioBluetooth(null);

            try
            {
                broker.LogInfo("Checking Bluetooth...");
                bool btAvailable = await scanner.CheckBluetoothAsync();
                if (!btAvailable)
                {
                    broker.LogError("Bluetooth is not available.");
                    scanner.Dispose();
                    ShowBluetoothActivateDialog();
                    return;
                }

                broker.LogInfo("Scanning for compatible devices...");
                var devices = await scanner.FindCompatibleDevices();
                scanner.Dispose();

                if (devices.Length == 0)
                {
                    broker.LogInfo("No compatible radio devices found. Make sure your radio is paired.");
                    return;
                }

                broker.LogInfo($"Found {devices.Length} device(s).");

                if (devices.Length == 1)
                {
                    // Auto-connect to single device
                    ConnectToRadio(devices[0]);
                }
                else
                {
                    // Show selection dialog
                    var dialog = new RadioConnectionDialog(devices);
                    await dialog.ShowDialog(this);

                    if (dialog.ConnectRequested && dialog.SelectedMac != null)
                    {
                        var target = devices.First(d => d.mac == dialog.SelectedMac);
                        ConnectToRadio(target);
                    }
                    else if (dialog.DisconnectRequested && dialog.SelectedMac != null)
                    {
                        var radio = connectedRadios.FirstOrDefault(r =>
                            r.MacAddress.Equals(dialog.SelectedMac, StringComparison.OrdinalIgnoreCase));
                        if (radio != null)
                        {
                            DisconnectRadio(radio);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                broker.LogError($"Connection error: {ex.Message}");
            }
        }

        private void ConnectToRadio(CompatibleDevice device)
        {
            // Check if already connected
            if (connectedRadios.Any(r => r.MacAddress.Equals(device.mac, StringComparison.OrdinalIgnoreCase)))
            {
                broker.LogInfo($"Already connected to {device.name}.");
                return;
            }

            int deviceId = GetNextAvailableDeviceId();
            broker.LogInfo($"Connecting to {device.name} ({device.mac}) as device {deviceId}...");

            var radio = new Radio(deviceId, device.mac, Program.PlatformServices);
            radio.UpdateFriendlyName(device.name);

            string handlerName = "Radio_" + deviceId;
            DataBroker.AddDataHandler(handlerName, radio);
            connectedRadios.Add(radio);

            // Publish the connected radios list
            DataBroker.Dispatch(1, "ConnectedRadios", connectedRadios.ToArray(), store: true);

            ConnectButton.IsEnabled = false;
            StatusText.Text = $"Connecting to {device.name}...";
            radio.Connect();
        }

        private void DisconnectRadio(Radio radio)
        {
            broker.LogInfo($"Disconnecting radio {radio.DeviceId}...");
            radio.Disconnect();

            string handlerName = "Radio_" + radio.DeviceId;
            DataBroker.RemoveDataHandler(handlerName);
            connectedRadios.Remove(radio);

            DataBroker.Dispatch(1, "ConnectedRadios", connectedRadios.ToArray(), store: true);

            if (connectedRadios.Count == 0)
            {
                StatusText.Text = "Not connected";
                DisconnectButton.IsEnabled = false;
            }
        }

        private void DisconnectButton_Click(object sender, RoutedEventArgs e)
        {
            foreach (var radio in connectedRadios.ToArray())
            {
                DisconnectRadio(radio);
            }
            ConnectButton.IsEnabled = true;
        }

        private int GetNextAvailableDeviceId()
        {
            int id = StartingDeviceId;
            foreach (var radio in connectedRadios)
            {
                if (radio.DeviceId >= id) id = radio.DeviceId + 1;
            }
            return id;
        }

        private async void ShowBluetoothActivateDialog()
        {
            var dialog = new BluetoothActivateDialog();
            await dialog.ShowDialog(this);
        }

        private async void ShowCantConnectDialog()
        {
            var dialog = new CantConnectDialog();
            await dialog.ShowDialog(this);
        }

        private async void MenuSettings_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SettingsDialog();
            await dialog.ShowDialog(this);
        }

        private void MenuExit_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }

        private async void ChannelList_DoubleTapped(object sender, Avalonia.Input.TappedEventArgs e)
        {
            if (ChannelList.SelectedItem is ChannelDisplayItem item && item.DeviceId >= 0)
            {
                var dialog = new Dialogs.RadioChannelDialog(item.DeviceId, item.ChannelIndex);
                await dialog.ShowDialog(this);
            }
        }

        private void MenuDualWatch_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || currentSettings == null) return;
            bool newDualWatch = currentSettings.double_channel != 1;
            DataBroker.Dispatch(activeDeviceId, "DualWatch", newDualWatch, store: false);
        }

        private void MenuScan_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || currentSettings == null) return;
            bool newScan = !currentSettings.scan;
            DataBroker.Dispatch(activeDeviceId, "Scan", newScan, store: false);
        }

        private void MenuGpsEnabled_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            bool currently = GpsEnabledCheck.IsChecked == true;
            DataBroker.Dispatch(activeDeviceId, "SetGPS", !currently, store: false);
            GpsEnabledCheck.IsChecked = !currently;
        }

        private void MenuAudioEnabled_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            bool newState = !(AudioEnabledCheck.IsChecked == true);
            AudioEnabledCheck.IsChecked = newState;
            DataBroker.Dispatch(activeDeviceId, "SetAudio", newState, store: false);
            DataBroker.Dispatch(activeDeviceId, "AudioState", newState, store: true);
        }

        private void OnAudioStateChanged(int deviceId, string name, object data)
        {
            if (deviceId != activeDeviceId && activeDeviceId >= 0) return;
            Dispatcher.UIThread.Post(() =>
            {
                bool enabled = data is bool b && b;
                AudioEnabledCheck.IsChecked = enabled;
            });
        }

        private void OnSoftwareModemModeChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                string mode = data?.ToString() ?? "None";
                SoftwareModemCheck.IsChecked = mode != "None";
            });
        }

        private void MenuSoftwareModem_Click(object sender, RoutedEventArgs e)
        {
            bool newState = !(SoftwareModemCheck.IsChecked == true);
            SoftwareModemCheck.IsChecked = newState;
            string mode = newState ? DataBroker.GetValue<string>(0, "SoftwareModemMode", "AFSK1200") : "None";
            if (newState && mode == "None") mode = "AFSK1200";
            DataBroker.Dispatch(0, "SetSoftwareModemMode", mode);
        }

        private async void MenuExportChannels_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || currentChannels == null) return;

            var picker = Program.PlatformServices?.FilePicker;
            if (picker == null) return;

            string path = await picker.SaveFileAsync("Export Channels", "channels.csv",
                new[] { "CSV Files|*.csv", "All Files|*.*" });
            if (path == null) return;

            try
            {
                string content = ImportUtils.ExportToChirpFormat(currentChannels);
                System.IO.File.WriteAllText(path, content);
                broker.LogInfo($"Channels exported to {path}");
            }
            catch (Exception ex)
            {
                broker.LogError($"Export failed: {ex.Message}");
            }
        }

        private async void MenuImportChannels_Click(object sender, RoutedEventArgs e)
        {
            var picker = Program.PlatformServices?.FilePicker;
            if (picker == null) return;

            string path = await picker.PickFileAsync("Import Channels",
                new[] { "CSV Files|*.csv", "All Files|*.*" });
            if (path == null) return;

            try
            {
                RadioChannelInfo[] channels = ImportUtils.ParseChannelsFromFile(path);
                if (channels == null || channels.Length == 0)
                {
                    broker.LogInfo("No channels found in file.");
                    return;
                }

                var dialog = new Dialogs.ImportChannelsDialog(activeDeviceId >= 0 ? activeDeviceId : -1, channels);
                await dialog.ShowDialog(this);
                broker.LogInfo($"Imported {channels.Length} channels from {path}");
            }
            catch (Exception ex)
            {
                broker.LogError($"Import failed: {ex.Message}");
            }
        }

        private async void MenuGpsInfo_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            var dialog = new Dialogs.GpsDetailsDialog(activeDeviceId);
            await dialog.ShowDialog(this);
        }

        private void MenuRadioPanel_Click(object sender, RoutedEventArgs e)
        {
            bool show = !RadioPanel.IsVisible;
            RadioPanelCheck.IsChecked = show;
            if (activeDeviceId >= 0) RadioPanel.IsVisible = show;
        }

        private void MenuAllChannels_Click(object sender, RoutedEventArgs e)
        {
            showAllChannels = !showAllChannels;
            AllChannelsCheck.IsChecked = showAllChannels;
            DataBroker.Dispatch(0, "ShowAllChannels", showAllChannels ? 1 : 0);
            UpdateChannelList();
        }

        private async void MenuCheckUpdates_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SelfUpdateDialog();
            await dialog.ShowDialog(this);
        }

        private async void MenuSpectrogram_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new SpectrogramDialog();
            await dialog.ShowDialog(this);
        }

        private async void MenuAudioClips_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            var dialog = new RadioAudioClipsDialog(activeDeviceId);
            await dialog.ShowDialog(this);
        }

        private async void MenuRadioInfo_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            var dialog = new RadioInfoDialog(activeDeviceId);
            await dialog.ShowDialog(this);
        }

        private async void MenuAbout_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new AboutDialog();
            await dialog.ShowDialog(this);
        }

        #region VFO Channel Selection

        private async void VfoACard_DoubleTapped(object sender, Avalonia.Input.TappedEventArgs e)
        {
            await OpenChannelPicker("A");
        }

        private async void VfoBCard_DoubleTapped(object sender, Avalonia.Input.TappedEventArgs e)
        {
            await OpenChannelPicker("B");
        }

        private async void VfoAChangeChannel_Click(object sender, RoutedEventArgs e)
        {
            await OpenChannelPicker("A");
        }

        private async void VfoBChangeChannel_Click(object sender, RoutedEventArgs e)
        {
            await OpenChannelPicker("B");
        }

        private void OnDevInfoChanged(int deviceId, string name, object data)
        {
            if (data is not RadioDevInfo info) return;
            if (activeDeviceId < 0) activeDeviceId = deviceId;
            if (deviceId != activeDeviceId) return;
            currentDevInfo = info;

            Dispatcher.UIThread.Post(() =>
            {
                UpdateVfoModeMenuItems();
            });
        }

        private void UpdateVfoModeMenuItems()
        {
            bool supportsVfo = currentDevInfo?.support_vfo == true;
            VfoAFreqModeItem.IsVisible = supportsVfo;
            VfoBFreqModeItem.IsVisible = supportsVfo;
            ChannelVfoAFreqModeItem.IsVisible = supportsVfo;
            ChannelVfoBFreqModeItem.IsVisible = supportsVfo;

            if (currentSettings != null)
            {
                bool aIsFreq = (currentSettings.vfo_x & 1) != 0;
                bool bIsFreq = (currentSettings.vfo_x & 2) != 0;
                VfoAFreqModeCheck.IsChecked = aIsFreq;
                VfoBFreqModeCheck.IsChecked = bIsFreq;
                ChannelVfoAFreqModeCheck.IsChecked = aIsFreq;
                ChannelVfoBFreqModeCheck.IsChecked = bIsFreq;
            }
        }

        private void ToggleVfoMode(string vfo)
        {
            if (activeDeviceId < 0 || currentSettings == null) return;
            int currentVfoX = currentSettings.vfo_x;
            if (vfo == "A")
                currentVfoX ^= 1; // toggle bit 0
            else
                currentVfoX ^= 2; // toggle bit 1
            DataBroker.Dispatch(activeDeviceId, "WriteSettings",
                currentSettings.ToByteArray(currentSettings.channel_a, currentSettings.channel_b,
                    currentSettings.double_channel, currentSettings.scan, currentSettings.squelch_level, currentVfoX),
                store: false);
        }

        private void VfoAFreqMode_Click(object sender, RoutedEventArgs e) => ToggleVfoMode("A");
        private void VfoBFreqMode_Click(object sender, RoutedEventArgs e) => ToggleVfoMode("B");

        private async System.Threading.Tasks.Task OpenChannelPicker(string vfo)
        {
            if (activeDeviceId < 0 || currentChannels == null || currentSettings == null) return;
            int currentIndex = vfo == "A" ? currentSettings.channel_a : currentSettings.channel_b;
            var dialog = new Dialogs.ChannelPickerDialog(vfo, currentChannels, currentIndex);
            await dialog.ShowDialog(this);
            if (dialog.Confirmed && dialog.SelectedChannelIndex >= 0)
            {
                string dispatchName = vfo == "A" ? "ChannelChangeVfoA" : "ChannelChangeVfoB";
                DataBroker.Dispatch(activeDeviceId, dispatchName, dialog.SelectedChannelIndex, store: false);
            }
        }

        private async void VfoAEditFreq_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || currentSettings == null) return;
            var dialog = new Dialogs.RadioChannelDialog(activeDeviceId, currentSettings.channel_a);
            await dialog.ShowDialog(this);
        }

        private async void VfoBEditFreq_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || currentSettings == null) return;
            var dialog = new Dialogs.RadioChannelDialog(activeDeviceId, currentSettings.channel_b);
            await dialog.ShowDialog(this);
        }

        private void ChannelSetVfoA_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || ChannelList.SelectedItem is not ChannelDisplayItem item) return;
            DataBroker.Dispatch(activeDeviceId, "ChannelChangeVfoA", item.ChannelIndex, store: false);
        }

        private void ChannelSetVfoB_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0 || ChannelList.SelectedItem is not ChannelDisplayItem item) return;
            DataBroker.Dispatch(activeDeviceId, "ChannelChangeVfoB", item.ChannelIndex, store: false);
        }

        private async void ChannelEdit_Click(object sender, RoutedEventArgs e)
        {
            if (ChannelList.SelectedItem is ChannelDisplayItem item && item.DeviceId >= 0)
            {
                var dialog = new Dialogs.RadioChannelDialog(item.DeviceId, item.ChannelIndex);
                await dialog.ShowDialog(this);
            }
        }

        #endregion

        #region PTT (Push to Talk)

        private IAudioInput mainMicInput;
        private bool mainPttActive = false;

        private void EnsureMicCapture()
        {
            if (mainMicInput != null) return;
            try
            {
                var audio = Program.PlatformServices?.Audio;
                if (audio == null) return;
                mainMicInput = audio.CreateInput(48000, 16, 1);
                if (mainMicInput != null)
                {
                    mainMicInput.DataAvailable += OnMainMicData;
                    mainMicInput.Start();
                }
            }
            catch (Exception) { }
        }

        private void OnMainMicData(byte[] data, int bytesRecorded)
        {
            if (!mainPttActive || bytesRecorded == 0 || activeDeviceId < 0) return;
            byte[] pcm = ResampleTo32kHz(data, bytesRecorded, 48000);
            if (pcm != null && pcm.Length > 0)
                broker.Dispatch(activeDeviceId, "TransmitVoicePCM", pcm, store: false);
        }

        private static byte[] ResampleTo32kHz(byte[] input, int bytesRecorded, int srcRate)
        {
            if (srcRate == 32000)
            {
                byte[] copy = new byte[bytesRecorded];
                Array.Copy(input, 0, copy, 0, bytesRecorded);
                return copy;
            }
            int srcSamples = bytesRecorded / 2;
            int dstSamples = (int)((long)srcSamples * 32000 / srcRate);
            if (dstSamples <= 0) return null;
            byte[] output = new byte[dstSamples * 2];
            double ratio = (double)srcRate / 32000;
            for (int i = 0; i < dstSamples; i++)
            {
                double srcPos = i * ratio;
                int idx = (int)srcPos;
                double frac = srcPos - idx;
                int i0 = Math.Clamp(idx, 0, srcSamples - 1);
                int i1 = Math.Clamp(idx + 1, 0, srcSamples - 1);
                short s0 = (short)(input[i0 * 2] | (input[i0 * 2 + 1] << 8));
                short s1 = (short)(input[i1 * 2] | (input[i1 * 2 + 1] << 8));
                short val = (short)(s0 + (s1 - s0) * frac);
                output[i * 2] = (byte)(val & 0xFF);
                output[i * 2 + 1] = (byte)((val >> 8) & 0xFF);
            }
            return output;
        }

        private void StartMainPtt()
        {
            if (mainPttActive || activeDeviceId < 0) return;
            EnsureMicCapture();
            mainPttActive = true;
            MainPttButton.Background = new SolidColorBrush(Color.Parse("#C62828"));
            MainPttText.Text = "TRANSMITTING...";
        }

        private void StopMainPtt()
        {
            if (!mainPttActive) return;
            mainPttActive = false;
            MainPttButton.Background = new SolidColorBrush(Color.Parse("#444"));
            MainPttText.Text = "Push to Talk";
            // Don't cancel — let buffered audio finish transmitting naturally
        }

        private void MainPttButton_PointerPressed(object sender, Avalonia.Input.PointerPressedEventArgs e)
        {
            StartMainPtt();
        }

        private void MainPttButton_PointerReleased(object sender, Avalonia.Input.PointerReleasedEventArgs e)
        {
            StopMainPtt();
        }

        // Spacebar PTT disabled on main window — conflicts with text input

        #endregion

        #region WAV File Transmit

        private string mainSelectedWavPath;
        private bool mainIsTransmittingWav = false;

        private async void MainSelectWav_Click(object sender, RoutedEventArgs e)
        {
            var picker = Program.PlatformServices?.FilePicker;
            if (picker == null) return;

            string path = await picker.PickFileAsync("Select Audio File",
                new[] { "WAV Files|*.wav", "All Files|*.*" });
            if (path == null) return;

            mainSelectedWavPath = path;
            MainSelectWavButton.Content = Path.GetFileName(path);
            MainTransmitWavButton.IsEnabled = true;
            MainWavStatus.Text = "";
        }

        private void MainTransmitWav_Click(object sender, RoutedEventArgs e)
        {
            if (mainIsTransmittingWav || string.IsNullOrEmpty(mainSelectedWavPath) || activeDeviceId < 0) return;

            mainIsTransmittingWav = true;
            MainTransmitWavButton.IsEnabled = false;
            MainSelectWavButton.IsEnabled = false;
            MainWavStatus.Text = "Reading file...";

            string path = mainSelectedWavPath;
            float gain = broker.GetValue<int>(activeDeviceId, "MicGain", 100) / 100f;
            int devId = activeDeviceId;

            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    var (samples, wavParams) = WavFile.Read(path);

                    // Convert stereo to mono if needed
                    if (wavParams.NumChannels > 1)
                    {
                        int monoLen = samples.Length / wavParams.NumChannels;
                        short[] mono = new short[monoLen];
                        for (int i = 0; i < monoLen; i++)
                        {
                            int sum = 0;
                            for (int ch = 0; ch < wavParams.NumChannels; ch++)
                                sum += samples[i * wavParams.NumChannels + ch];
                            mono[i] = (short)(sum / wavParams.NumChannels);
                        }
                        samples = mono;
                    }

                    // Convert to byte array
                    byte[] pcmBytes = new byte[samples.Length * 2];
                    for (int i = 0; i < samples.Length; i++)
                    {
                        pcmBytes[i * 2] = (byte)(samples[i] & 0xFF);
                        pcmBytes[i * 2 + 1] = (byte)((samples[i] >> 8) & 0xFF);
                    }

                    // Resample to 32kHz if needed
                    if (wavParams.SampleRate != 32000)
                        pcmBytes = ResampleTo32kHz(pcmBytes, pcmBytes.Length, wavParams.SampleRate);

                    if (pcmBytes == null || pcmBytes.Length == 0)
                    {
                        Dispatcher.UIThread.Post(() => MainWavStatus.Text = "Error: resample failed");
                        return;
                    }

                    ApplyGain(pcmBytes, gain);

                    int chunkSize = 6400; // 100ms at 32kHz 16-bit mono
                    int totalChunks = (pcmBytes.Length + chunkSize - 1) / chunkSize;

                    for (int c = 0; c < totalChunks; c++)
                    {
                        if (!mainIsTransmittingWav) break;

                        int offset = c * chunkSize;
                        int len = Math.Min(chunkSize, pcmBytes.Length - offset);
                        byte[] chunk = new byte[len];
                        Array.Copy(pcmBytes, offset, chunk, 0, len);

                        DataBroker.Dispatch(devId, "TransmitVoicePCM", new { Data = chunk, PlayLocally = false }, store: false);

                        int pct = (c + 1) * 100 / totalChunks;
                        Dispatcher.UIThread.Post(() => MainWavStatus.Text = $"Transmitting... {pct}%");

                        Thread.Sleep(100);
                    }

                    Dispatcher.UIThread.Post(() => MainWavStatus.Text = mainIsTransmittingWav ? "Done" : "Cancelled");
                }
                catch (Exception ex)
                {
                    Dispatcher.UIThread.Post(() => MainWavStatus.Text = $"Error: {ex.Message}");
                }
                finally
                {
                    Dispatcher.UIThread.Post(() =>
                    {
                        mainIsTransmittingWav = false;
                        MainTransmitWavButton.IsEnabled = !string.IsNullOrEmpty(mainSelectedWavPath);
                        MainSelectWavButton.IsEnabled = true;
                    });
                }
            });
        }

        private static void ApplyGain(byte[] pcm16, float gain)
        {
            if (gain == 1.0f) return;
            int samples = pcm16.Length / 2;
            for (int i = 0; i < samples; i++)
            {
                int offset = i * 2;
                short s = (short)(pcm16[offset] | (pcm16[offset + 1] << 8));
                int amplified = (int)(s * gain);
                if (amplified > 32767) amplified = 32767;
                else if (amplified < -32768) amplified = -32768;
                pcm16[offset] = (byte)(amplified & 0xFF);
                pcm16[offset + 1] = (byte)((amplified >> 8) & 0xFF);
            }
        }

        #endregion

        #region Channel Drag & Drop

        private Avalonia.Point? channelDragStartPoint;
        private bool channelDragInProgress = false;

        protected override void OnLoaded(RoutedEventArgs e)
        {
            base.OnLoaded(e);
            ChannelList.AddHandler(InputElement.PointerPressedEvent, OnChannelPointerPressed, RoutingStrategies.Tunnel);
            ChannelList.AddHandler(InputElement.PointerMovedEvent, OnChannelPointerMoved, RoutingStrategies.Tunnel);
            ChannelList.AddHandler(DragDrop.DropEvent, OnChannelDrop);
            ChannelList.AddHandler(DragDrop.DragOverEvent, OnChannelDragOver);

            // Set up tab detach context menus
            foreach (var tabItem in MainTabControl.Items.OfType<TabItem>())
            {
                var menu = new ContextMenu();
                var detachItem = new MenuItem { Header = "Detach Tab" };
                detachItem.Click += DetachTab_Click;
                menu.Items.Add(detachItem);
                tabItem.ContextMenu = menu;
            }
        }

        private void DetachTab_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not MenuItem menuItem) return;
            var contextMenu = menuItem.Parent as ContextMenu;
            if (contextMenu?.PlacementTarget is not TabItem tabItem) return;

            string title = tabItem.Header?.ToString() ?? "Tab";
            var content = tabItem.Content as Control;
            if (content == null) return;

            // Remove content from tab and hide the tab
            tabItem.Content = null;
            tabItem.IsVisible = false;

            // Keep a reference to the content since DetachedTabDialog.OnClosed nulls it before raising Closed
            var detachedContent = content;

            // Create detached window (non-modal)
            var dialog = new DetachedTabDialog(title, detachedContent);
            dialog.Closed += (s, args) =>
            {
                // Re-attach on close
                tabItem.Content = detachedContent;
                tabItem.IsVisible = true;
            };
            dialog.Show();
        }

        private void OnChannelPointerPressed(object sender, PointerPressedEventArgs e)
        {
            channelDragStartPoint = e.GetPosition(ChannelList);
            channelDragInProgress = false;
        }

        private async void OnChannelPointerMoved(object sender, PointerEventArgs e)
        {
            if (channelDragStartPoint == null || channelDragInProgress) return;
            if (!e.GetCurrentPoint(ChannelList).Properties.IsLeftButtonPressed)
            {
                channelDragStartPoint = null;
                return;
            }

            var pos = e.GetPosition(ChannelList);
            var diff = pos - channelDragStartPoint.Value;
            if (Math.Abs(diff.X) < 8 && Math.Abs(diff.Y) < 8) return;

            if (ChannelList.SelectedItem is not ChannelDisplayItem sourceItem) return;

            channelDragInProgress = true;
            var dataObject = new DataObject();
            dataObject.Set("ChannelDisplayItem", sourceItem);
            await DragDrop.DoDragDrop(e, dataObject, DragDropEffects.Copy);
            channelDragStartPoint = null;
            channelDragInProgress = false;
        }

        private void OnChannelDragOver(object sender, DragEventArgs e)
        {
            e.DragEffects = DragDropEffects.None;
            if (!e.Data.Contains("ChannelDisplayItem")) return;

            // Find target item from position
            var target = GetChannelItemAtPosition(e);
            var source = e.Data.Get("ChannelDisplayItem") as ChannelDisplayItem;
            if (target != null && source != null && target.ChannelIndex != source.ChannelIndex)
                e.DragEffects = DragDropEffects.Copy;
        }

        private async void OnChannelDrop(object sender, DragEventArgs e)
        {
            if (!e.Data.Contains("ChannelDisplayItem")) return;
            var source = e.Data.Get("ChannelDisplayItem") as ChannelDisplayItem;
            var target = GetChannelItemAtPosition(e);
            if (source == null || target == null || source.ChannelIndex == target.ChannelIndex) return;
            if (activeDeviceId < 0 || currentChannels == null) return;

            var sourceChannel = currentChannels[source.ChannelIndex];
            if (sourceChannel == null) return;

            // Show confirmation
            var dialog = new MessageDialog($"Copy \"{source.Name}\" to channel slot {target.ChannelIndex + 1}?", "Copy Channel");
            await dialog.ShowDialog(this);
            if (!dialog.Confirmed) return;

            // Create a copy with the target channel_id
            var copy = new RadioChannelInfo(sourceChannel);
            copy.channel_id = target.ChannelIndex;
            broker.Dispatch(activeDeviceId, "WriteChannel", copy, store: false);
        }

        private ChannelDisplayItem GetChannelItemAtPosition(DragEventArgs e)
        {
            var pos = e.GetPosition(ChannelList);
            // Walk through items to find which one we're over
            if (ChannelList.ItemsSource is List<ChannelDisplayItem> items)
            {
                for (int i = 0; i < items.Count; i++)
                {
                    var container = ChannelList.ContainerFromIndex(i);
                    if (container == null) continue;
                    var bounds = container.Bounds;
                    if (pos.Y >= bounds.Top && pos.Y <= bounds.Bottom)
                        return items[i];
                }
            }
            return null;
        }

        #endregion

        protected override void OnClosed(EventArgs e)
        {
            // Cancel WAV transmit
            mainIsTransmittingWav = false;

            // Clean up mic
            if (mainMicInput != null)
            {
                mainMicInput.DataAvailable -= OnMainMicData;
                mainMicInput.Stop();
                mainMicInput.Dispose();
                mainMicInput = null;
            }

            // Disconnect all radios
            foreach (var radio in connectedRadios.ToArray())
            {
                try { radio.Disconnect(); } catch { }
                try { radio.Dispose(); } catch { }
            }
            connectedRadios.Clear();

            broker?.Dispose();
            DataBroker.RemoveAllDataHandlers();
            base.OnClosed(e);
        }
    }
}
