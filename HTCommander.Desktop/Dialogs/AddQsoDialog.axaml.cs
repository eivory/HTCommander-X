using System;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace HTCommander.Desktop.Dialogs
{
    public partial class AddQsoDialog : Window
    {
        public bool Confirmed { get; private set; }

        public AddQsoDialog()
        {
            InitializeComponent();

            // Default to now UTC
            var now = DateTime.UtcNow;
            StartDatePicker.SelectedDate = new DateTimeOffset(now);
            StartTimePicker.SelectedTime = now.TimeOfDay;
            EndDatePicker.SelectedDate = new DateTimeOffset(now);
            EndTimePicker.SelectedTime = now.TimeOfDay;

            // Default RST
            RstSentBox.Text = "59";
            RstReceivedBox.Text = "59";

            // Auto-fill my callsign
            MyCallsignBox.Text = DataBroker.GetValue<string>(0, "CallSign", "");

            // Auto-fill frequency from active radio VFO A
            TryAutoFillFromRadio();
        }

        private void TryAutoFillFromRadio()
        {
            try
            {
                var radios = DataBroker.GetValue<object[]>(1, "ConnectedRadios", null);
                if (radios == null || radios.Length == 0) return;

                // Get the first radio's device ID via reflection (tabs don't reference Radio directly)
                var radio = radios[0];
                var devIdProp = radio.GetType().GetProperty("DeviceId");
                if (devIdProp == null) return;
                int deviceId = (int)devIdProp.GetValue(radio);

                var settings = DataBroker.GetValue<RadioSettings>(deviceId, "Settings", null);
                var channels = DataBroker.GetValue<RadioChannelInfo[]>(deviceId, "Channels", null);
                if (settings == null || channels == null) return;

                int chIdx = settings.channel_a;
                if (chIdx >= 0 && chIdx < channels.Length && channels[chIdx] != null)
                {
                    double freqMHz = channels[chIdx].rx_freq / 1000000.0;
                    FrequencyBox.Text = freqMHz.ToString("F6");

                    // Auto-select mode
                    string mode = channels[chIdx].rx_mod.ToString();
                    for (int i = 0; i < ModeCombo.Items.Count; i++)
                    {
                        if ((ModeCombo.Items[i] as ComboBoxItem)?.Content?.ToString() == mode)
                        {
                            ModeCombo.SelectedIndex = i;
                            break;
                        }
                    }
                }
            }
            catch { }
        }

        public void SetQso(QsoEntry qso)
        {
            CallsignBox.Text = qso.Callsign ?? "";
            StartDatePicker.SelectedDate = new DateTimeOffset(qso.StartTime);
            StartTimePicker.SelectedTime = qso.StartTime.TimeOfDay;
            EndDatePicker.SelectedDate = new DateTimeOffset(qso.EndTime);
            EndTimePicker.SelectedTime = qso.EndTime.TimeOfDay;
            FrequencyBox.Text = qso.FrequencyMHz > 0 ? qso.FrequencyMHz.ToString("F6") : "";
            RstSentBox.Text = qso.RstSent ?? "59";
            RstReceivedBox.Text = qso.RstReceived ?? "59";
            MyCallsignBox.Text = qso.MyCallsign ?? "";
            NotesBox.Text = qso.Notes ?? "";

            // Select mode
            string mode = qso.Mode ?? "FM";
            for (int i = 0; i < ModeCombo.Items.Count; i++)
            {
                if ((ModeCombo.Items[i] as ComboBoxItem)?.Content?.ToString() == mode)
                {
                    ModeCombo.SelectedIndex = i;
                    break;
                }
            }
        }

        public QsoEntry GetQso()
        {
            var startDate = StartDatePicker.SelectedDate?.DateTime ?? DateTime.UtcNow;
            var startTime = StartTimePicker.SelectedTime ?? TimeSpan.Zero;
            var endDate = EndDatePicker.SelectedDate?.DateTime ?? DateTime.UtcNow;
            var endTime = EndTimePicker.SelectedTime ?? TimeSpan.Zero;

            double freqMHz = 0;
            double.TryParse(FrequencyBox.Text, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out freqMHz);

            return new QsoEntry
            {
                Callsign = CallsignBox.Text?.Trim().ToUpper() ?? "",
                StartTime = startDate.Date + startTime,
                EndTime = endDate.Date + endTime,
                FrequencyMHz = freqMHz,
                Mode = (ModeCombo.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "FM",
                Band = QsoEntry.GetBand(freqMHz),
                RstSent = RstSentBox.Text?.Trim() ?? "",
                RstReceived = RstReceivedBox.Text?.Trim() ?? "",
                MyCallsign = MyCallsignBox.Text?.Trim().ToUpper() ?? "",
                Notes = NotesBox.Text?.Trim() ?? ""
            };
        }

        private void FrequencyBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (double.TryParse(FrequencyBox.Text, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out double freq))
            {
                string band = QsoEntry.GetBand(freq);
                BandLabel.Text = string.IsNullOrEmpty(band) ? "" : $"({band})";
            }
            else
            {
                BandLabel.Text = "";
            }
        }

        private void OkButton_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(CallsignBox.Text)) { CallsignBox.Focus(); return; }
            Confirmed = true;
            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();
    }
}
