using System;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;
using static HTCommander.Radio;

namespace HTCommander.Desktop.Dialogs
{
    public partial class RadioChannelDialog : Window
    {
        private int deviceId;
        private int channelId;
        private RadioChannelInfo originalInfo;
        private DataBrokerClient broker;

        // Standard CTCSS tones (Hz × 10)
        private static readonly double[] CtcssTones = {
            67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
            94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
            131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
            171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
            203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1
        };

        public RadioChannelDialog(int deviceId, int channelId)
        {
            InitializeComponent();
            this.deviceId = deviceId;
            this.channelId = channelId;

            broker = new DataBrokerClient();
            broker.Subscribe(deviceId, "Channels", OnChannelsChanged);

            PopulateToneCombos();
            LoadChannel();
        }

        public RadioChannelDialog(RadioChannelInfo info) : this()
        {
            originalInfo = info;
            OkButton.IsEnabled = false;
            PopulateToneCombos();
            PopulateFromInfo(info);
        }

        private RadioChannelDialog()
        {
            InitializeComponent();
        }

        private void PopulateToneCombos()
        {
            TxToneCombo.Items.Add("None");
            RxToneCombo.Items.Add("None");
            foreach (var tone in CtcssTones)
            {
                string label = $"{tone:F1} Hz";
                TxToneCombo.Items.Add(label);
                RxToneCombo.Items.Add(label);
            }
            TxToneCombo.SelectedIndex = 0;
            RxToneCombo.SelectedIndex = 0;
        }

        private void OnChannelsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() => LoadChannel());
        }

        private void LoadChannel()
        {
            var channels = DataBroker.GetValue<RadioChannelInfo[]>(deviceId, "Channels");
            if (channels != null && channelId < channels.Length && channels[channelId] != null)
            {
                originalInfo = new RadioChannelInfo(channels[channelId]);
                PopulateFromInfo(channels[channelId]);
            }
        }

        private void PopulateFromInfo(RadioChannelInfo info)
        {
            if (info == null) return;

            ChannelIdText.Text = $"Channel {info.channel_id}";
            Title = $"Channel {info.channel_id} - {info.name_str}";

            FrequencyBox.Text = (info.rx_freq / 1000000.0).ToString("F6");
            ChannelNameBox.Text = info.name_str ?? "";

            // Mode
            ModeCombo.SelectedIndex = (int)info.rx_mod;

            // Bandwidth: 0=Narrow, 1=Wide
            BandwidthCombo.SelectedIndex = info.bandwidth == RadioBandwidthType.WIDE ? 1 : 0;

            // Power
            if (info.tx_at_max_power) PowerCombo.SelectedIndex = 2;
            else if (info.tx_at_med_power) PowerCombo.SelectedIndex = 1;
            else PowerCombo.SelectedIndex = 0;

            // Tones
            SelectTone(TxToneCombo, info.tx_sub_audio);
            SelectTone(RxToneCombo, info.rx_sub_audio);

            // Checkboxes
            MuteCheck.IsChecked = info.mute;
            DisableTransmitCheck.IsChecked = info.tx_disable;
            ScanCheck.IsChecked = info.scan;
            TalkAroundCheck.IsChecked = info.talk_around;
            DeemphasisCheck.IsChecked = info.pre_de_emph_bypass;

            // Advanced frequencies
            TxFrequencyBox.Text = (info.tx_freq / 1000000.0).ToString("F6");
            RxFrequencyBox.Text = (info.rx_freq / 1000000.0).ToString("F6");
        }

        private void SelectTone(ComboBox combo, int toneValue)
        {
            if (toneValue == 0)
            {
                combo.SelectedIndex = 0; // None
                return;
            }

            // CTCSS tones are stored as Hz × 100
            double toneHz = toneValue / 100.0;
            string search = $"{toneHz:F1} Hz";
            for (int i = 0; i < combo.Items.Count; i++)
            {
                if (combo.Items[i]?.ToString() == search)
                {
                    combo.SelectedIndex = i;
                    return;
                }
            }
            combo.SelectedIndex = 0;
        }

        private int ParseTone(ComboBox combo)
        {
            if (combo.SelectedIndex <= 0) return 0;
            string text = combo.SelectedItem?.ToString();
            if (text == null) return 0;
            // Parse "67.0 Hz" → 6700
            text = text.Replace(" Hz", "");
            if (double.TryParse(text, out double hz))
                return (int)(hz * 100);
            return 0;
        }

        private void AdvancedButton_Click(object sender, RoutedEventArgs e)
        {
            AdvancedPanel.IsVisible = !AdvancedPanel.IsVisible;
            AdvancedButton.Content = AdvancedPanel.IsVisible ? "Basic" : "Advanced";
        }

        private void OkButton_Click(object sender, RoutedEventArgs e)
        {
            if (originalInfo == null) { Close(); return; }

            // Build updated channel
            var updated = new RadioChannelInfo(originalInfo);

            // Parse frequency
            if (double.TryParse(FrequencyBox.Text, out double freqMhz))
            {
                updated.rx_freq = (int)(freqMhz * 1000000);
                // If advanced TX frequency wasn't changed separately, keep TX = RX
                if (double.TryParse(TxFrequencyBox.Text, out double txMhz))
                    updated.tx_freq = (int)(txMhz * 1000000);
                else
                    updated.tx_freq = updated.rx_freq;
            }

            updated.name_str = ChannelNameBox.Text?.Trim() ?? "";

            // Mode
            updated.rx_mod = (RadioModulationType)ModeCombo.SelectedIndex;
            updated.tx_mod = updated.rx_mod;

            // Bandwidth
            updated.bandwidth = BandwidthCombo.SelectedIndex == 1 ? RadioBandwidthType.WIDE : RadioBandwidthType.NARROW;

            // Power
            updated.tx_at_max_power = PowerCombo.SelectedIndex == 2;
            updated.tx_at_med_power = PowerCombo.SelectedIndex == 1;

            // Tones
            updated.tx_sub_audio = ParseTone(TxToneCombo);
            updated.rx_sub_audio = ParseTone(RxToneCombo);

            // Checkboxes
            updated.mute = MuteCheck.IsChecked == true;
            updated.tx_disable = DisableTransmitCheck.IsChecked == true;
            updated.scan = ScanCheck.IsChecked == true;
            updated.talk_around = TalkAroundCheck.IsChecked == true;
            updated.pre_de_emph_bypass = DeemphasisCheck.IsChecked == true;

            // Only write if changed
            if (!updated.Equals(originalInfo))
            {
                DataBroker.Dispatch(deviceId, "WriteChannel", updated, store: false);
            }

            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();

        protected override void OnClosed(EventArgs e)
        {
            broker?.Dispose();
            base.OnClosed(e);
        }
    }
}
