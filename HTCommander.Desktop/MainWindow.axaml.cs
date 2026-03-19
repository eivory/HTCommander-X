/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Linq;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
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
            broker.Subscribe(DataBroker.AllDevices, "FriendlyName", OnFriendlyNameChanged);

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
                        StatusText.Text = $"Radio {deviceId}: Connected";
                        StatusBarText.Text = $"Connected to radio {deviceId}";
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
                        MenuAudioControls.IsEnabled = true;
                        activeDeviceId = deviceId;
                        if (RadioPanelCheck.IsChecked == true) RadioPanel.IsVisible = true;
                        RadioStateText.Text = "Connected";
                        RadioStateText.Foreground = new SolidColorBrush(Color.Parse("#4CAF50"));
                        break;
                    case "Connecting":
                        StatusText.Text = $"Radio {deviceId}: Connecting...";
                        StatusBarText.Text = $"Connecting to radio {deviceId}...";
                        RadioPanel.IsVisible = RadioPanelCheck.IsChecked == true;
                        RadioStateText.Text = "Connecting...";
                        RadioStateText.Foreground = new SolidColorBrush(Color.Parse("#FFC107"));
                        break;
                    case "Disconnected":
                        StatusText.Text = connectedRadios.Count > 0 ? $"Radio {deviceId}: Disconnected" : "Not connected";
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
                        MenuAudioControls.IsEnabled = false;
                        BatteryStatusText.Text = "";
                        if (deviceId == activeDeviceId)
                        {
                            activeDeviceId = -1;
                            RadioPanel.IsVisible = false;
                            currentChannels = null;
                            currentSettings = null;
                            currentStatus = null;
                        }
                        break;
                    case "UnableToConnect":
                        StatusText.Text = $"Radio {deviceId}: Unable to connect";
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
            // Update the connected radios list in DataBroker
        }

        private void OnFriendlyNameChanged(int deviceId, string name, object data)
        {
            if (deviceId != activeDeviceId) return;
            Dispatcher.UIThread.Post(() =>
            {
                RadioNameText.Text = data?.ToString() ?? "Radio";
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
                GpsText.Foreground = status.is_gps_locked ? Brushes.LimeGreen : new SolidColorBrush(Color.Parse("#E0E0E0"));
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
                if (string.IsNullOrEmpty(ch.name_str) && ch.rx_freq == 0) continue;

                bool isA = (i == activeA);
                bool isB = (i == activeB);

                IBrush bg;
                IBrush nameColor;
                if (isA) { bg = new SolidColorBrush(Color.Parse("#1B3A4B")); nameColor = new SolidColorBrush(Color.Parse("#64B5F6")); }
                else if (isB) { bg = new SolidColorBrush(Color.Parse("#2A1B3A")); nameColor = new SolidColorBrush(Color.Parse("#CE93D8")); }
                else { bg = Brushes.Transparent; nameColor = new SolidColorBrush(Color.Parse("#E0E0E0")); }

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
            bool currently = DataBroker.GetValue<bool>(activeDeviceId, "AudioState", false);
            DataBroker.Dispatch(activeDeviceId, "SetAudio", !currently, store: false);
            AudioEnabledCheck.IsChecked = !currently;
        }

        private async void MenuAudioControls_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            var dialog = new Dialogs.RadioAudioDialog(activeDeviceId);
            await dialog.ShowDialog(this);
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

        protected override void OnClosed(EventArgs e)
        {
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
