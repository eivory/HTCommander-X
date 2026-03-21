using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.Dialogs
{
    public class RepeaterBookResultItem : INotifyPropertyChanged
    {
        private bool _isSelected = true;
        public bool IsSelected
        {
            get => _isSelected;
            set { _isSelected = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected))); }
        }

        public string Callsign { get; set; }
        public string FrequencyDisplay { get; set; }
        public string OffsetDisplay { get; set; }
        public string Tone { get; set; }
        public string Mode { get; set; }
        public string City { get; set; }
        public string DistanceDisplay { get; set; }
        public string Status { get; set; }
        public string Use { get; set; }
        public RepeaterBookEntry Source { get; set; }

        public event PropertyChangedEventHandler PropertyChanged;
    }

    public partial class RepeaterBookDialog : Window
    {
        private int deviceId;
        private RadioChannelInfo[] currentChannels;
        private List<RepeaterBookEntry> cachedResults;
        private List<RepeaterBookResultItem> displayItems;
        private bool isLoading = true;

        public bool Confirmed { get; private set; }

        public RepeaterBookDialog()
        {
            InitializeComponent();
        }

        public RepeaterBookDialog(int deviceId, RadioChannelInfo[] currentChannels) : this()
        {
            this.deviceId = deviceId;
            this.currentChannels = currentChannels;

            // Populate countries
            foreach (var country in RepeaterBookClient.Countries.Keys)
                CountryCombo.Items.Add(country);

            // Load defaults
            string defaultCountry = DataBroker.GetValue<string>(0, "RepeaterBookCountry", "United States");
            string defaultState = DataBroker.GetValue<string>(0, "RepeaterBookState", "");

            for (int i = 0; i < CountryCombo.Items.Count; i++)
            {
                if (CountryCombo.Items[i]?.ToString() == defaultCountry)
                {
                    CountryCombo.SelectedIndex = i;
                    break;
                }
            }

            // Populate states for default country, then select default state
            PopulateStates(defaultCountry);
            if (!string.IsNullOrEmpty(defaultState))
            {
                for (int i = 0; i < StateCombo.Items.Count; i++)
                {
                    if (StateCombo.Items[i]?.ToString() == defaultState)
                    {
                        StateCombo.SelectedIndex = i;
                        break;
                    }
                }
            }

            // Auto-fill GPS coordinates
            TryAutoFillGps();

            // Wire manual slot radio button
            ManualSlotRadio.IsCheckedChanged += (s, e) =>
                StartChannelBox.IsEnabled = ManualSlotRadio.IsChecked == true;

            if (deviceId < 0)
                StatusLabel.Text = "No radio connected — import disabled.";

            isLoading = false;
        }

        private void TryAutoFillGps()
        {
            try
            {
                var gps = DataBroker.GetValue<Gps.GpsData>(1, "GpsData", null);
                if (gps != null && gps.IsFixed && gps.Latitude != 0 && gps.Longitude != 0)
                {
                    LatBox.Text = gps.Latitude.ToString("F6");
                    LonBox.Text = gps.Longitude.ToString("F6");
                }
            }
            catch { }
        }

        private void PopulateStates(string country)
        {
            StateCombo.Items.Clear();
            if (country != null && RepeaterBookClient.Countries.TryGetValue(country, out var states))
            {
                foreach (var state in states)
                    StateCombo.Items.Add(state);
            }
            if (StateCombo.Items.Count > 0)
                StateCombo.SelectedIndex = 0;
        }

        private void CountryCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (isLoading) return;
            string country = CountryCombo.SelectedItem?.ToString();
            PopulateStates(country);
        }

        private async void SearchButton_Click(object sender, RoutedEventArgs e)
        {
            string country = CountryCombo.SelectedItem?.ToString();
            string state = StateCombo.SelectedItem?.ToString();
            if (string.IsNullOrEmpty(country))
            {
                StatusLabel.Text = "Select a country.";
                return;
            }
            if (string.IsNullOrEmpty(state) && StateCombo.Items.Count > 0)
            {
                StatusLabel.Text = "Select a state/province.";
                return;
            }

            string city = CityBox.Text?.Trim();
            SearchButton.IsEnabled = false;
            StatusLabel.Text = "Searching...";

            try
            {
                using var client = new RepeaterBookClient();
                cachedResults = await client.SearchAsync(country, state ?? "", city, CancellationToken.None);
                ApplyFiltersAndDisplay();
                StatusLabel.Text = $"Found {cachedResults.Count} repeaters.";
            }
            catch (RepeaterBookRateLimitException)
            {
                StatusLabel.Text = "Rate limited. Please wait and try again.";
            }
            catch (Exception ex)
            {
                StatusLabel.Text = $"Error: {ex.Message}";
            }
            finally
            {
                SearchButton.IsEnabled = true;
            }
        }

        private async void LoadCsvButton_Click(object sender, RoutedEventArgs e)
        {
            var picker = Program.PlatformServices?.FilePicker;
            if (picker == null) return;

            string path = await picker.PickFileAsync("Load RepeaterBook CSV",
                new[] { "CSV Files|*.csv", "All Files|*.*" });
            if (path == null) return;

            cachedResults = RepeaterBookClient.ParseCsvExport(path);
            if (cachedResults.Count == 0)
            {
                StatusLabel.Text = "No repeaters found in CSV file.";
                return;
            }

            ApplyFiltersAndDisplay();
            StatusLabel.Text = $"Loaded {cachedResults.Count} repeaters from CSV.";
        }

        private void ApplyFiltersAndDisplay()
        {
            if (cachedResults == null) return;

            var filtered = new List<RepeaterBookEntry>(cachedResults);

            // Calculate distances if coordinates provided
            double lat = 0, lon = 0;
            bool hasCoords = double.TryParse(LatBox.Text, out lat) && double.TryParse(LonBox.Text, out lon)
                             && (lat != 0 || lon != 0);
            if (hasCoords)
                RepeaterBookClient.CalculateDistances(filtered, lat, lon);

            // Band filter
            int bandIdx = BandCombo.SelectedIndex;
            if (bandIdx > 0)
            {
                double minFreq = 0, maxFreq = 0;
                switch (bandIdx)
                {
                    case 1: minFreq = 144.0; maxFreq = 148.0; break;  // 2m
                    case 2: minFreq = 222.0; maxFreq = 225.0; break;  // 1.25m
                    case 3: minFreq = 420.0; maxFreq = 450.0; break;  // 70cm
                    case 4: minFreq = 1240.0; maxFreq = 1300.0; break; // 23cm
                }
                filtered = filtered.Where(r => r.Frequency >= minFreq && r.Frequency <= maxFreq).ToList();
            }

            // Mode filter
            string modeFilter = (ModeCombo.SelectedItem as ComboBoxItem)?.Content?.ToString();
            if (modeFilter != null && modeFilter != "All")
                filtered = filtered.Where(r => r.Mode != null && r.Mode.Equals(modeFilter, StringComparison.OrdinalIgnoreCase)).ToList();

            // Status filter
            string statusFilter = (StatusCombo.SelectedItem as ComboBoxItem)?.Content?.ToString();
            if (statusFilter != null && statusFilter != "All")
                filtered = filtered.Where(r => r.Status != null && r.Status.IndexOf(statusFilter, StringComparison.OrdinalIgnoreCase) >= 0).ToList();

            // Max distance filter
            if (hasCoords && double.TryParse(MaxDistBox.Text, out double maxDist) && maxDist > 0)
                filtered = filtered.Where(r => r.DistanceKm >= 0 && r.DistanceKm <= maxDist).ToList();

            // Sort
            if (hasCoords)
                filtered = filtered.OrderBy(r => r.DistanceKm < 0 ? double.MaxValue : r.DistanceKm).ToList();
            else
                filtered = filtered.OrderBy(r => r.Frequency).ToList();

            // Build display items
            displayItems = filtered.Select(r => new RepeaterBookResultItem
            {
                IsSelected = true,
                Callsign = r.Callsign ?? "",
                FrequencyDisplay = r.Frequency.ToString("F4"),
                OffsetDisplay = FormatOffset(r),
                Tone = string.IsNullOrEmpty(r.PL) || r.PL == "0" ? "" : r.PL,
                Mode = r.Mode ?? "FM",
                City = r.NearestCity ?? "",
                DistanceDisplay = r.DistanceKm >= 0 ? $"{r.DistanceKm:F1} km" : "---",
                Status = r.Status ?? "",
                Use = r.Use ?? "",
                Source = r
            }).ToList();

            ResultsGrid.ItemsSource = displayItems;
            UpdateSelectionInfo();
        }

        private string FormatOffset(RepeaterBookEntry r)
        {
            if (r.InputFreq <= 0 || r.Frequency <= 0) return "";
            double offset = r.InputFreq - r.Frequency;
            if (Math.Abs(offset) < 0.001) return "Simplex";
            string sign = offset > 0 ? "+" : "";
            return $"{sign}{offset:F3}";
        }

        private void FilterChanged(object sender, SelectionChangedEventArgs e)
        {
            if (isLoading) return;
            ApplyFiltersAndDisplay();
        }

        private void GpsButton_Click(object sender, RoutedEventArgs e) => TryAutoFillGps();

        private void SelectAll_Click(object sender, RoutedEventArgs e)
        {
            if (displayItems == null) return;
            foreach (var item in displayItems) item.IsSelected = true;
            ResultsGrid.ItemsSource = null;
            ResultsGrid.ItemsSource = displayItems;
            UpdateSelectionInfo();
        }

        private void DeselectAll_Click(object sender, RoutedEventArgs e)
        {
            if (displayItems == null) return;
            foreach (var item in displayItems) item.IsSelected = false;
            ResultsGrid.ItemsSource = null;
            ResultsGrid.ItemsSource = displayItems;
            UpdateSelectionInfo();
        }

        private void UpdateSelectionInfo()
        {
            if (displayItems == null)
            {
                SelectionInfo.Text = "";
                ImportButton.IsEnabled = false;
                return;
            }

            int selected = displayItems.Count(i => i.IsSelected);
            int total = displayItems.Count;
            SelectionInfo.Text = $"{selected} of {total} selected";
            ImportButton.IsEnabled = deviceId >= 0 && selected > 0;
        }

        private void ImportButton_Click(object sender, RoutedEventArgs e)
        {
            if (deviceId < 0 || displayItems == null) return;

            var selected = displayItems.Where(i => i.IsSelected).ToList();
            if (selected.Count == 0) return;

            List<int> slots;
            if (AutoFillRadio.IsChecked == true)
            {
                // Find empty channel slots
                slots = new List<int>();
                if (currentChannels != null)
                {
                    for (int i = 0; i < currentChannels.Length && slots.Count < selected.Count; i++)
                    {
                        var ch = currentChannels[i];
                        if (ch == null || (ch.rx_freq == 0 && string.IsNullOrEmpty(ch.name_str)))
                            slots.Add(i);
                    }
                }
                else
                {
                    // No channel data available, use slots 0..N
                    for (int i = 0; i < selected.Count; i++) slots.Add(i);
                }

                if (slots.Count < selected.Count)
                {
                    StatusLabel.Text = $"Only {slots.Count} empty slots available, need {selected.Count}.";
                    return;
                }
            }
            else
            {
                // Manual start slot
                int start = (int)(StartChannelBox.Value ?? 1) - 1; // Convert 1-based to 0-based
                slots = new List<int>();
                for (int i = 0; i < selected.Count; i++) slots.Add(start + i);
            }

            int written = 0;
            for (int i = 0; i < selected.Count; i++)
            {
                var channel = RepeaterBookClient.ToRadioChannel(selected[i].Source, slots[i]);
                if (channel == null) continue; // Unsupported mode
                DataBroker.Dispatch(deviceId, "WriteChannel", channel, store: false);
                written++;
            }

            Confirmed = true;
            StatusLabel.Text = $"Imported {written} channels.";

            // Save defaults
            DataBroker.Dispatch(0, "RepeaterBookCountry", CountryCombo.SelectedItem?.ToString() ?? "United States");
            DataBroker.Dispatch(0, "RepeaterBookState", StateCombo.SelectedItem?.ToString() ?? "");

            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();
    }
}
