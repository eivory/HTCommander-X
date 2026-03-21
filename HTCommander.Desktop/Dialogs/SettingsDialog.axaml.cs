using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Net.Http;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;

namespace HTCommander.Desktop.Dialogs
{
    public class AprsRouteItem
    {
        public string Name { get; set; }
        public string Route { get; set; }
    }

    public partial class SettingsDialog : Window
    {
        private DataBrokerClient broker;
        private ObservableCollection<AprsRouteItem> aprsRoutes = new ObservableCollection<AprsRouteItem>();
        private string _originalGpsPort;
        private int _originalGpsBaud;
        private bool isLoading = true;
        private int activeDeviceId = -1;

        public SettingsDialog()
        {
            InitializeComponent();
            broker = new DataBrokerClient();
            LoadSettings();
            isLoading = false;
        }

        private void LoadSettings()
        {
            // Theme
            string theme = DataBroker.GetValue<string>(0, "Theme", "Dark");
            for (int i = 0; i < ThemeCombo.Items.Count; i++)
            {
                if (ThemeCombo.Items[i] is ComboBoxItem ti && ti.Tag?.ToString() == theme)
                {
                    ThemeCombo.SelectedIndex = i;
                    break;
                }
            }
            if (ThemeCombo.SelectedIndex < 0) ThemeCombo.SelectedIndex = 2; // Dark default

            // General
            CallSignBox.Text = DataBroker.GetValue<string>(0, "CallSign", "");
            for (int i = 0; i <= 15; i++) StationIdCombo.Items.Add(i.ToString());
            int stationId = DataBroker.GetValue<int>(0, "StationId", 0);
            StationIdCombo.SelectedIndex = Math.Min(stationId, 15);
            AllowTransmitCheck.IsChecked = DataBroker.GetValue<int>(0, "AllowTransmit", 0) == 1;
            CheckUpdatesCheck.IsChecked = DataBroker.GetValue<bool>(0, "CheckForUpdates", false);
            UpdateTransmitState();

            // APRS routes
            string routeStr = DataBroker.GetValue<string>(0, "AprsRoutes", "");
            if (string.IsNullOrEmpty(routeStr))
                routeStr = "Standard|APN000,WIDE1-1,WIDE2-2";
            foreach (string entry in routeStr.Split('|'))
            {
                int comma = entry.IndexOf(',');
                if (comma > 0)
                    aprsRoutes.Add(new AprsRouteItem { Name = entry.Substring(0, comma), Route = entry.Substring(comma + 1) });
            }
            AprsRoutesGrid.ItemsSource = aprsRoutes;

            // Voice
            VoiceLanguageCombo.Items.Add("auto");
            VoiceLanguageCombo.SelectedIndex = 0;
            string voiceLang = DataBroker.GetValue<string>(0, "VoiceLanguage", "auto");
            for (int i = 0; i < VoiceLanguageCombo.Items.Count; i++)
            {
                if (VoiceLanguageCombo.Items[i]?.ToString() == voiceLang) { VoiceLanguageCombo.SelectedIndex = i; break; }
            }

            var speech = Program.PlatformServices?.Speech;
            if (speech != null && speech.IsAvailable)
            {
                foreach (var voice in speech.GetVoices()) VoiceCombo.Items.Add(voice);
                string selectedVoice = DataBroker.GetValue<string>(0, "Voice", "");
                for (int i = 0; i < VoiceCombo.Items.Count; i++)
                {
                    if (VoiceCombo.Items[i]?.ToString() == selectedVoice) { VoiceCombo.SelectedIndex = i; break; }
                }
            }
            SpeechToTextCheck.IsChecked = DataBroker.GetValue<bool>(0, "SpeechToText", false);

            // Winlink
            WinlinkPasswordBox.Text = DataBroker.GetValue<string>(0, "WinlinkPassword", "");
            WinlinkUseStationIdCheck.IsChecked = DataBroker.GetValue<int>(0, "WinlinkUseStationId", 0) == 1;

            // Servers
            ServerBindAllCheck.IsChecked = DataBroker.GetValue<int>(0, "ServerBindAll", 0) == 1;
            TlsEnabledCheck.IsChecked = DataBroker.GetValue<int>(0, "TlsEnabled", 0) == 1;
            WebServerCheck.IsChecked = DataBroker.GetValue<int>(0, "WebServerEnabled", 0) == 1;
            WebPortUpDown.Value = DataBroker.GetValue<int>(0, "WebServerPort", 8080);
            AgwpeServerCheck.IsChecked = DataBroker.GetValue<int>(0, "AgwpeServerEnabled", 0) == 1;
            AgwpePortUpDown.Value = DataBroker.GetValue<int>(0, "AgwpeServerPort", 8000);
            RigctldServerCheck.IsChecked = DataBroker.GetValue<int>(0, "RigctldServerEnabled", 0) == 1;
            RigctldPortUpDown.Value = DataBroker.GetValue<int>(0, "RigctldServerPort", 4532);
            CatServerCheck.IsChecked = DataBroker.GetValue<int>(0, "CatServerEnabled", 0) == 1;
            // On Windows, show COM port selector for CAT server (com0com virtual pair)
            if (OperatingSystem.IsWindows())
            {
                CatComPortPanel.IsVisible = true;
                CatComPortCombo.Items.Add("None");
                try
                {
                    foreach (var port in System.IO.Ports.SerialPort.GetPortNames())
                        CatComPortCombo.Items.Add(port);
                }
                catch { }
                string savedCatPort = DataBroker.GetValue<string>(0, "CatComPort", "None");
                for (int i = 0; i < CatComPortCombo.Items.Count; i++)
                {
                    if (CatComPortCombo.Items[i]?.ToString() == savedCatPort) { CatComPortCombo.SelectedIndex = i; break; }
                }
                if (CatComPortCombo.SelectedIndex < 0) CatComPortCombo.SelectedIndex = 0;
            }
            string catPath = DataBroker.GetValue<string>(1, "CatPortPath", "");
            CatPortLabel.Text = string.IsNullOrEmpty(catPath) ? "" : $"CAT port: {catPath}";
            VirtualAudioCheck.IsChecked = DataBroker.GetValue<int>(0, "VirtualAudioEnabled", 0) == 1;
            McpServerCheck.IsChecked = DataBroker.GetValue<int>(0, "McpServerEnabled", 0) == 1;
            McpPortUpDown.Value = DataBroker.GetValue<int>(0, "McpServerPort", 5678);
            McpDebugCheck.IsChecked = DataBroker.GetValue<int>(0, "McpDebugToolsEnabled", 0) == 1;

            // Data Sources
            AirplaneServerBox.Text = DataBroker.GetValue<string>(0, "AirplaneServer", "");

            // GPS
            GpsPortCombo.Items.Add("None");
            try
            {
                foreach (var port in System.IO.Ports.SerialPort.GetPortNames())
                    GpsPortCombo.Items.Add(port);
            }
            catch { }
            _originalGpsPort = DataBroker.GetValue<string>(0, "GpsSerialPort", "None");
            _originalGpsBaud = DataBroker.GetValue<int>(0, "GpsBaudRate", 4800);
            for (int i = 0; i < GpsPortCombo.Items.Count; i++)
            {
                if (GpsPortCombo.Items[i]?.ToString() == _originalGpsPort) { GpsPortCombo.SelectedIndex = i; break; }
            }
            if (GpsPortCombo.SelectedIndex < 0) GpsPortCombo.SelectedIndex = 0;

            string baudStr = _originalGpsBaud.ToString();
            for (int i = 0; i < GpsBaudCombo.Items.Count; i++)
            {
                if (GpsBaudCombo.Items[i] is ComboBoxItem item && item.Content?.ToString() == baudStr)
                {
                    GpsBaudCombo.SelectedIndex = i; break;
                }
            }
            if (GpsBaudCombo.SelectedIndex < 0) GpsBaudCombo.SelectedIndex = 0;

            // RepeaterBook defaults
            foreach (var country in RepeaterBookClient.Countries.Keys)
                RBCountryCombo.Items.Add(country);
            string rbCountry = DataBroker.GetValue<string>(0, "RepeaterBookCountry", "United States");
            for (int i = 0; i < RBCountryCombo.Items.Count; i++)
            {
                if (RBCountryCombo.Items[i]?.ToString() == rbCountry) { RBCountryCombo.SelectedIndex = i; break; }
            }
            if (RBCountryCombo.SelectedIndex < 0 && RBCountryCombo.Items.Count > 0) RBCountryCombo.SelectedIndex = 0;
            PopulateRBStates(rbCountry);
            string rbState = DataBroker.GetValue<string>(0, "RepeaterBookState", "");
            for (int i = 0; i < RBStateCombo.Items.Count; i++)
            {
                if (RBStateCombo.Items[i]?.ToString() == rbState) { RBStateCombo.SelectedIndex = i; break; }
            }

            // Modem mode
            string modemMode = DataBroker.GetValue<string>(0, "SoftwareModemMode", "None");
            for (int i = 0; i < ModemModeCombo.Items.Count; i++)
            {
                if (ModemModeCombo.Items[i] is ComboBoxItem mItem && mItem.Tag?.ToString() == modemMode)
                {
                    ModemModeCombo.SelectedIndex = i;
                    break;
                }
            }
            if (ModemModeCombo.SelectedIndex < 0) ModemModeCombo.SelectedIndex = 0;

            // Audio devices
            var audio = Program.PlatformServices?.Audio;
            if (audio != null)
            {
                foreach (var dev in audio.GetOutputDevices()) OutputDeviceCombo.Items.Add(dev);
                foreach (var dev in audio.GetInputDevices()) InputDeviceCombo.Items.Add(dev);

                string savedOutput = DataBroker.GetValue<string>(0, "AudioOutputDevice", "");
                string savedInput = DataBroker.GetValue<string>(0, "AudioInputDevice", "");
                for (int i = 0; i < OutputDeviceCombo.Items.Count; i++)
                {
                    if (OutputDeviceCombo.Items[i]?.ToString() == savedOutput) { OutputDeviceCombo.SelectedIndex = i; break; }
                }
                for (int i = 0; i < InputDeviceCombo.Items.Count; i++)
                {
                    if (InputDeviceCombo.Items[i]?.ToString() == savedInput) { InputDeviceCombo.SelectedIndex = i; break; }
                }
            }

            // Audio controls — find active radio
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            if (radios is System.Collections.IEnumerable enumerable)
            {
                foreach (var r in enumerable)
                {
                    if (r == null) continue;
                    var prop = r.GetType().GetProperty("DeviceId");
                    if (prop != null)
                    {
                        object val = prop.GetValue(r);
                        if (val is int id && id > 0) { activeDeviceId = id; break; }
                    }
                }
            }

            if (activeDeviceId >= 0)
            {
                AudioControlsNote.IsVisible = false;

                // Subscribe to live updates
                broker.Subscribe(activeDeviceId, "Volume", OnVolumeLevelChanged);
                broker.Subscribe(activeDeviceId, "Settings", OnRadioSettingsChanged);

                // Volume from radio
                int volume = DataBroker.GetValue<int>(activeDeviceId, "Volume", 0);
                VolumeSlider.Value = volume;
                VolumeValueText.Text = volume.ToString();

                // Squelch from settings
                var settings = DataBroker.GetValue<RadioSettings>(activeDeviceId, "Settings", null);
                if (settings != null)
                {
                    SquelchSlider.Value = settings.squelch_level;
                    SquelchValueText.Text = settings.squelch_level.ToString();
                }

                // Software output volume
                int outputVol = broker.GetValue<int>(activeDeviceId, "OutputAudioVolume", 100);
                OutputVolumeSlider.Value = outputVol;
                OutputVolumeText.Text = $"{outputVol}%";

                // Mic gain
                int micGainPct = broker.GetValue<int>(activeDeviceId, "MicGain", 100);
                MicGainSlider.Value = micGainPct;
                MicGainText.Text = $"{micGainPct}%";

                // Mute
                bool muted = broker.GetValue<bool>(activeDeviceId, "Muted", false);
                MuteCheck.IsChecked = muted;

                // Request current volume
                DataBroker.Dispatch(activeDeviceId, "GetVolume", null, store: false);
            }
            else
            {
                AudioControlsNote.IsVisible = true;
                VolumeSlider.IsEnabled = false;
                SquelchSlider.IsEnabled = false;
                OutputVolumeSlider.IsEnabled = false;
                MicGainSlider.IsEnabled = false;
                MuteCheck.IsEnabled = false;
            }
        }

        private void SaveSettings()
        {
            // Theme
            string themeTag = "Dark";
            if (ThemeCombo.SelectedItem is ComboBoxItem tci) themeTag = tci.Tag?.ToString() ?? "Dark";
            DataBroker.Dispatch(0, "Theme", themeTag);
            App.SetTheme(themeTag);

            DataBroker.Dispatch(0, "CallSign", CallSignBox.Text?.ToUpper() ?? "");
            DataBroker.Dispatch(0, "StationId", StationIdCombo.SelectedIndex);
            DataBroker.Dispatch(0, "AllowTransmit", AllowTransmitCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "CheckForUpdates", CheckUpdatesCheck.IsChecked == true);

            // APRS routes
            var parts = new List<string>();
            foreach (var r in aprsRoutes) parts.Add($"{r.Name},{r.Route}");
            DataBroker.Dispatch(0, "AprsRoutes", string.Join("|", parts));

            // Voice
            DataBroker.Dispatch(0, "VoiceLanguage", VoiceLanguageCombo.SelectedItem?.ToString() ?? "auto");
            DataBroker.Dispatch(0, "Voice", VoiceCombo.SelectedItem?.ToString() ?? "");
            DataBroker.Dispatch(0, "SpeechToText", SpeechToTextCheck.IsChecked == true);

            // Winlink
            DataBroker.Dispatch(0, "WinlinkPassword", WinlinkPasswordBox.Text ?? "");
            DataBroker.Dispatch(0, "WinlinkUseStationId", WinlinkUseStationIdCheck.IsChecked == true ? 1 : 0);

            // Servers
            DataBroker.Dispatch(0, "ServerBindAll", ServerBindAllCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "TlsEnabled", TlsEnabledCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "WebServerEnabled", WebServerCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "WebServerPort", (int)(WebPortUpDown.Value ?? 8080));
            DataBroker.Dispatch(0, "AgwpeServerEnabled", AgwpeServerCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "AgwpeServerPort", (int)(AgwpePortUpDown.Value ?? 8000));
            DataBroker.Dispatch(0, "RigctldServerEnabled", RigctldServerCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "RigctldServerPort", (int)(RigctldPortUpDown.Value ?? 4532));
            DataBroker.Dispatch(0, "CatServerEnabled", CatServerCheck.IsChecked == true ? 1 : 0);
            if (OperatingSystem.IsWindows())
            {
                DataBroker.Dispatch(0, "CatComPort", CatComPortCombo.SelectedItem?.ToString() ?? "None");
            }
            DataBroker.Dispatch(0, "VirtualAudioEnabled", VirtualAudioCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "McpServerEnabled", McpServerCheck.IsChecked == true ? 1 : 0);
            DataBroker.Dispatch(0, "McpServerPort", (int)(McpPortUpDown.Value ?? 5678));
            DataBroker.Dispatch(0, "McpDebugToolsEnabled", McpDebugCheck.IsChecked == true ? 1 : 0);

            // Data sources
            DataBroker.Dispatch(0, "AirplaneServer", AirplaneServerBox.Text ?? "");
            DataBroker.Dispatch(0, "GpsSerialPort", GpsPortCombo.SelectedItem?.ToString() ?? "None");
            int baud = 4800;
            if (GpsBaudCombo.SelectedItem is ComboBoxItem bi) int.TryParse(bi.Content?.ToString(), out baud);
            DataBroker.Dispatch(0, "GpsBaudRate", baud);

            // RepeaterBook defaults
            DataBroker.Dispatch(0, "RepeaterBookCountry", RBCountryCombo.SelectedItem?.ToString() ?? "United States");
            DataBroker.Dispatch(0, "RepeaterBookState", RBStateCombo.SelectedItem?.ToString() ?? "");

            // Audio devices
            DataBroker.Dispatch(0, "AudioOutputDevice", OutputDeviceCombo.SelectedItem?.ToString() ?? "");
            DataBroker.Dispatch(0, "AudioInputDevice", InputDeviceCombo.SelectedItem?.ToString() ?? "");

            // Modem mode
            string modemTag = "None";
            if (ModemModeCombo.SelectedItem is ComboBoxItem mci) modemTag = mci.Tag?.ToString() ?? "None";
            DataBroker.Dispatch(0, "SetSoftwareModemMode", modemTag);
        }

        #region Audio Control Handlers

        private void OnVolumeLevelChanged(int devId, string name, object data)
        {
            int volume = 0;
            if (data is int i) volume = i;
            else if (data is byte b) volume = b;
            else return;

            Dispatcher.UIThread.Post(() =>
            {
                isLoading = true;
                VolumeSlider.Value = Math.Clamp(volume, 0, 15);
                VolumeValueText.Text = volume.ToString();
                isLoading = false;
            });
        }

        private void OnRadioSettingsChanged(int devId, string name, object data)
        {
            if (data is RadioSettings settings)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    isLoading = true;
                    SquelchSlider.Value = settings.squelch_level;
                    SquelchValueText.Text = settings.squelch_level.ToString();
                    isLoading = false;
                });
            }
        }

        private void VolumeSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading || activeDeviceId < 0) return;
            int level = (int)VolumeSlider.Value;
            VolumeValueText.Text = level.ToString();
            DataBroker.Dispatch(activeDeviceId, "SetVolumeLevel", level, store: false);
        }

        private void SquelchSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading || activeDeviceId < 0) return;
            int level = (int)SquelchSlider.Value;
            SquelchValueText.Text = level.ToString();
            DataBroker.Dispatch(activeDeviceId, "SetSquelchLevel", level, store: false);
        }

        private void OutputVolumeSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading || activeDeviceId < 0) return;
            int vol = (int)OutputVolumeSlider.Value;
            OutputVolumeText.Text = $"{vol}%";
            DataBroker.Dispatch(activeDeviceId, "SetOutputVolume", vol, store: false);
            broker.Dispatch(activeDeviceId, "OutputAudioVolume", vol);
        }

        private void MicGainSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading || activeDeviceId < 0) return;
            int pct = (int)MicGainSlider.Value;
            MicGainText.Text = $"{pct}%";
            broker.Dispatch(activeDeviceId, "MicGain", pct);
        }

        private void Mute_Click(object sender, RoutedEventArgs e)
        {
            if (activeDeviceId < 0) return;
            DataBroker.Dispatch(activeDeviceId, "SetMute", MuteCheck.IsChecked == true, store: false);
        }

        #endregion

        private void UpdateTransmitState()
        {
            string callSign = CallSignBox.Text?.Trim() ?? "";
            bool valid = callSign.Length >= 3;
            AllowTransmitCheck.IsEnabled = valid;
            TransmitWarning.IsVisible = !valid;
            if (!valid) AllowTransmitCheck.IsChecked = false;
        }

        private void CallSignBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            UpdateTransmitState();
        }

        private void AprsRoutesGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            bool hasSelection = AprsRoutesGrid.SelectedItem != null;
            EditRouteBtn.IsEnabled = hasSelection;
            DeleteRouteBtn.IsEnabled = hasSelection;
        }

        private async void AddRoute_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new AprsRouteDialog();
            await dialog.ShowDialog(this);
            if (dialog.Confirmed)
            {
                aprsRoutes.Add(new AprsRouteItem { Name = dialog.RouteName, Route = dialog.RouteValue });
            }
        }

        private async void EditRoute_Click(object sender, RoutedEventArgs e)
        {
            if (AprsRoutesGrid.SelectedItem is not AprsRouteItem item) return;
            var dialog = new AprsRouteDialog(item.Name, item.Route);
            await dialog.ShowDialog(this);
            if (dialog.Confirmed)
            {
                item.Name = dialog.RouteName;
                item.Route = dialog.RouteValue;
                var items = new ObservableCollection<AprsRouteItem>(aprsRoutes);
                aprsRoutes = items;
                AprsRoutesGrid.ItemsSource = aprsRoutes;
            }
        }

        private void DeleteRoute_Click(object sender, RoutedEventArgs e)
        {
            if (AprsRoutesGrid.SelectedItem is AprsRouteItem item)
                aprsRoutes.Remove(item);
        }

        private void PopulateRBStates(string country)
        {
            RBStateCombo.Items.Clear();
            if (country != null && RepeaterBookClient.Countries.TryGetValue(country, out var states))
            {
                foreach (var s in states)
                    RBStateCombo.Items.Add(s);
            }
            if (RBStateCombo.Items.Count > 0)
                RBStateCombo.SelectedIndex = 0;
        }

        private void RBCountryCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (isLoading) return;
            PopulateRBStates(RBCountryCombo.SelectedItem?.ToString());
        }

        private async void TestAirplaneServer_Click(object sender, RoutedEventArgs e)
        {
            string url = AirplaneServerBox.Text?.Trim();
            if (string.IsNullOrEmpty(url))
            {
                AirplaneTestResult.Text = "Enter a URL first.";
                AirplaneTestResult.Foreground = new SolidColorBrush(Color.Parse("#F44336"));
                return;
            }

            AirplaneTestResult.Text = "Testing...";
            AirplaneTestResult.Foreground = new SolidColorBrush(Color.Parse("#888"));
            try
            {
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(5);
                var response = await client.GetAsync(url);
                if (response.IsSuccessStatusCode)
                {
                    AirplaneTestResult.Text = "Connection successful!";
                    AirplaneTestResult.Foreground = new SolidColorBrush(Color.Parse("#4CAF50"));
                }
                else
                {
                    AirplaneTestResult.Text = $"HTTP {(int)response.StatusCode}: {response.ReasonPhrase}";
                    AirplaneTestResult.Foreground = new SolidColorBrush(Color.Parse("#F44336"));
                }
            }
            catch (Exception ex)
            {
                AirplaneTestResult.Text = $"Error: {ex.Message}";
                AirplaneTestResult.Foreground = new SolidColorBrush(Color.Parse("#F44336"));
            }
        }

        private async void ResetDefaults_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new MessageDialog(
                "This will reset all settings to their defaults. The application will close.\n\nAre you sure?",
                "Reset Settings");
            await dialog.ShowDialog(this);
            if (!dialog.Confirmed) return;

            // Clear all device 0 settings
            DataBroker.ClearDevice(0);

            // Also try to delete the config file on Linux
            try
            {
                string configPath = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "HTCommander", "settings.json");
                if (System.IO.File.Exists(configPath))
                    System.IO.File.Delete(configPath);

                // Also try ~/.config/HTCommander/settings.json
                string configDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string linuxPath = System.IO.Path.Combine(configDir, ".config", "HTCommander", "settings.json");
                if (System.IO.File.Exists(linuxPath))
                    System.IO.File.Delete(linuxPath);
            }
            catch { }

            // Close the application
            if (Avalonia.Application.Current?.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime lifetime)
            {
                lifetime.Shutdown(0);
            }
        }

        private bool ValidateSettings()
        {
            // Collect all enabled TCP server ports
            var ports = new List<(string name, int port)>();
            if (WebServerCheck.IsChecked == true) ports.Add(("Web Server", (int)(WebPortUpDown.Value ?? 8080)));
            if (AgwpeServerCheck.IsChecked == true) ports.Add(("AGWPE Server", (int)(AgwpePortUpDown.Value ?? 8000)));
            if (RigctldServerCheck.IsChecked == true) ports.Add(("Rigctld Server", (int)(RigctldPortUpDown.Value ?? 4532)));
            if (McpServerCheck.IsChecked == true) ports.Add(("MCP Server", (int)(McpPortUpDown.Value ?? 5678)));

            for (int i = 0; i < ports.Count; i++)
            {
                for (int j = i + 1; j < ports.Count; j++)
                {
                    if (ports[i].port == ports[j].port)
                    {
                        PortWarning.Text = $"{ports[i].name} and {ports[j].name} cannot use the same port.";
                        return false;
                    }
                }
            }
            PortWarning.Text = "";
            return true;
        }

        private void OkButton_Click(object sender, RoutedEventArgs e)
        {
            if (!ValidateSettings()) return;
            SaveSettings();
            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            DataBroker.Dispatch(0, "GpsSerialPort", _originalGpsPort);
            DataBroker.Dispatch(0, "GpsBaudRate", _originalGpsBaud);
            Close();
        }

        protected override void OnClosed(EventArgs e)
        {
            broker?.Dispose();
            base.OnClosed(e);
        }
    }
}
