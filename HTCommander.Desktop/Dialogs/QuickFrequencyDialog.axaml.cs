using System;
using Avalonia.Controls;
using Avalonia.Interactivity;
using static HTCommander.Radio;

namespace HTCommander.Desktop.Dialogs
{
    public partial class QuickFrequencyDialog : Window
    {
        // Standard CTCSS tones (Hz)
        private static readonly double[] CtcssTones = {
            67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
            94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
            131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
            171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
            203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1
        };

        public bool Confirmed { get; private set; }
        public int FrequencyHz { get; private set; }
        public RadioModulationType Modulation { get; private set; }
        public RadioBandwidthType Bandwidth { get; private set; }
        public int TxTone { get; private set; }
        public int RxTone { get; private set; }
        public string VfoTarget { get; private set; }
        public int PowerLevel { get; private set; }

        public QuickFrequencyDialog()
        {
            InitializeComponent();
        }

        public QuickFrequencyDialog(string defaultVfo)
        {
            InitializeComponent();
            PopulateToneCombos();
            LoadLastUsed();
            VfoCombo.SelectedIndex = (defaultVfo == "B") ? 1 : 0;
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

        private void LoadLastUsed()
        {
            FrequencyBox.Text = DataBroker.GetValue<string>(0, "QuickFreqLastFreq", "146.520000");
            ModeCombo.SelectedIndex = DataBroker.GetValue<int>(0, "QuickFreqLastMode", 0);
            BandwidthCombo.SelectedIndex = DataBroker.GetValue<int>(0, "QuickFreqLastBandwidth", 0);
            PowerCombo.SelectedIndex = DataBroker.GetValue<int>(0, "QuickFreqLastPower", 0);
            SelectTone(TxToneCombo, DataBroker.GetValue<int>(0, "QuickFreqLastTxTone", 0));
            SelectTone(RxToneCombo, DataBroker.GetValue<int>(0, "QuickFreqLastRxTone", 0));
        }

        private void SelectTone(ComboBox combo, int toneValue)
        {
            if (toneValue == 0) { combo.SelectedIndex = 0; return; }
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
            text = text.Replace(" Hz", "");
            if (double.TryParse(text, out double hz))
                return (int)(hz * 100);
            return 0;
        }

        private void SaveLastUsed()
        {
            DataBroker.Dispatch(0, "QuickFreqLastFreq", FrequencyBox.Text?.Trim() ?? "");
            DataBroker.Dispatch(0, "QuickFreqLastMode", ModeCombo.SelectedIndex);
            DataBroker.Dispatch(0, "QuickFreqLastBandwidth", BandwidthCombo.SelectedIndex);
            DataBroker.Dispatch(0, "QuickFreqLastPower", PowerCombo.SelectedIndex);
            DataBroker.Dispatch(0, "QuickFreqLastTxTone", TxTone);
            DataBroker.Dispatch(0, "QuickFreqLastRxTone", RxTone);
        }

        private void OkButton_Click(object sender, RoutedEventArgs e)
        {
            string freqText = FrequencyBox.Text?.Trim();
            if (string.IsNullOrEmpty(freqText) || !double.TryParse(freqText, out double freqMhz) || freqMhz <= 0)
            {
                FrequencyBox.Focus();
                return;
            }

            FrequencyHz = (int)(freqMhz * 1000000);
            Modulation = (RadioModulationType)ModeCombo.SelectedIndex;
            Bandwidth = BandwidthCombo.SelectedIndex == 1 ? RadioBandwidthType.WIDE : RadioBandwidthType.NARROW;
            PowerLevel = PowerCombo.SelectedIndex;
            TxTone = ParseTone(TxToneCombo);
            RxTone = ParseTone(RxToneCombo);
            VfoTarget = VfoCombo.SelectedIndex == 1 ? "B" : "A";
            Confirmed = true;

            SaveLastUsed();
            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();
    }
}
