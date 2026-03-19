using System;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.Dialogs
{
    public partial class RadioAudioDialog : Window
    {
        private DataBrokerClient broker;
        private int deviceId;
        private bool isLoading = true;

        public RadioAudioDialog(int deviceId)
        {
            InitializeComponent();
            this.deviceId = deviceId;

            broker = new DataBrokerClient();
            broker.Subscribe(deviceId, "Volume", OnVolumeLevelChanged);
            broker.Subscribe(deviceId, "Settings", OnSettingsChanged);
            broker.Subscribe(deviceId, "AudioState", OnAudioStateChanged);
            broker.Subscribe(deviceId, "HtStatus", OnHtStatusChanged);

            LoadInitialValues();
            isLoading = false;

            // Request current volume from radio
            DataBroker.Dispatch(deviceId, "GetVolume", null, store: false);
        }

        private void LoadInitialValues()
        {
            // Audio state
            bool audioEnabled = DataBroker.GetValue<bool>(deviceId, "AudioState", false);
            AudioEnabledCheck.IsChecked = audioEnabled;
            AudioStatusText.Text = audioEnabled ? "Audio streaming is active" : "Audio streaming is off";

            // Squelch from settings
            var settings = DataBroker.GetValue<RadioSettings>(deviceId, "Settings", null);
            if (settings != null)
            {
                SquelchSlider.Value = settings.squelch_level;
                SquelchValueText.Text = settings.squelch_level.ToString();
            }

            // Volume from radio (may arrive later via event)
            int volume = DataBroker.GetValue<int>(deviceId, "Volume", 0);
            VolumeSlider.Value = volume;
            VolumeValueText.Text = volume.ToString();

            // Software output volume
            int outputVol = broker.GetValue<int>(deviceId, "OutputAudioVolume", 100);
            OutputVolumeSlider.Value = outputVol;
            OutputVolumeText.Text = $"{outputVol}%";
        }

        #region DataBroker Event Handlers

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

        private void OnSettingsChanged(int devId, string name, object data)
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

        private void OnAudioStateChanged(int devId, string name, object data)
        {
            if (data is bool enabled)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    AudioEnabledCheck.IsChecked = enabled;
                    AudioStatusText.Text = enabled ? "Audio streaming is active" : "Audio streaming is off";
                });
            }
        }

        private void OnHtStatusChanged(int devId, string name, object data)
        {
            // Could update signal/TX indicators here if needed
        }

        #endregion

        #region UI Event Handlers

        private void AudioEnabled_Click(object sender, RoutedEventArgs e)
        {
            bool enable = AudioEnabledCheck.IsChecked == true;
            DataBroker.Dispatch(deviceId, "SetAudio", enable, store: false);
            AudioStatusText.Text = enable ? "Audio streaming is active" : "Audio streaming is off";
        }

        private void VolumeSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading) return;
            int level = (int)VolumeSlider.Value;
            VolumeValueText.Text = level.ToString();
            DataBroker.Dispatch(deviceId, "SetVolumeLevel", level, store: false);
        }

        private void SquelchSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading) return;
            int level = (int)SquelchSlider.Value;
            SquelchValueText.Text = level.ToString();
            DataBroker.Dispatch(deviceId, "SetSquelchLevel", level, store: false);
        }

        private void OutputVolumeSlider_Changed(object sender, Avalonia.Controls.Primitives.RangeBaseValueChangedEventArgs e)
        {
            if (isLoading) return;
            int vol = (int)OutputVolumeSlider.Value;
            OutputVolumeText.Text = $"{vol}%";
            DataBroker.Dispatch(deviceId, "SetOutputVolume", vol, store: false);
            broker.Dispatch(deviceId, "OutputAudioVolume", vol);
        }

        private void Mute_Click(object sender, RoutedEventArgs e)
        {
            DataBroker.Dispatch(deviceId, "SetMute", MuteCheck.IsChecked == true, store: false);
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

        #endregion

        protected override void OnClosed(EventArgs e)
        {
            broker?.Dispose();
            base.OnClosed(e);
        }
    }
}
