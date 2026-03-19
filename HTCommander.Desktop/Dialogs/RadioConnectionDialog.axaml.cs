using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.Dialogs
{
    public class RadioListEntry
    {
        public string Name { get; set; }
        public string Mac { get; set; }
        public string State { get; set; }
    }

    public partial class RadioConnectionDialog : Window
    {
        private DataBrokerClient broker;
        private ObservableCollection<RadioListEntry> radioEntries = new ObservableCollection<RadioListEntry>();
        private CompatibleDevice[] devices;
        private Dictionary<string, string> connectedMacs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public string SelectedMac { get; private set; }
        public string SelectedName { get; private set; }
        public bool ConnectRequested { get; private set; }
        public bool DisconnectRequested { get; private set; }

        public RadioConnectionDialog(CompatibleDevice[] devices)
        {
            InitializeComponent();
            this.devices = devices;
            RadiosGrid.ItemsSource = radioEntries;

            broker = new DataBrokerClient();
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);
            broker.Subscribe(DataBroker.AllDevices, "State", OnRadioStateChanged);

            // Get initial connected radios
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            UpdateConnectedMacs(radios);
            PopulateDevices();
        }

        private void UpdateConnectedMacs(object data)
        {
            connectedMacs.Clear();
            if (data is System.Collections.IEnumerable enumerable)
            {
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    var t = item.GetType();
                    string mac = t.GetProperty("MacAddress")?.GetValue(item) as string;
                    if (mac != null)
                        connectedMacs[mac] = "Connected";
                }
            }
        }

        private void PopulateDevices()
        {
            radioEntries.Clear();

            // Load custom names
            var friendlyNames = broker.GetValue<Dictionary<string, string>>(0, "DeviceFriendlyName", null)
                                ?? new Dictionary<string, string>();

            foreach (var device in devices)
            {
                string displayName = device.name;
                if (friendlyNames.TryGetValue(device.mac, out string customName))
                    displayName = customName;

                string state = connectedMacs.ContainsKey(device.mac) ? "Connected" : "Available";

                radioEntries.Add(new RadioListEntry
                {
                    Name = displayName,
                    Mac = device.mac,
                    State = state
                });
            }
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                UpdateConnectedMacs(data);
                UpdateStates();
            });
        }

        private void OnRadioStateChanged(int deviceId, string name, object data)
        {
            if (data is string stateStr)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    // Find which radio this deviceId corresponds to
                    // Look through connected radios to find the MAC
                    var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
                    if (radios is System.Collections.IEnumerable enumerable)
                    {
                        foreach (var item in enumerable)
                        {
                            if (item == null) continue;
                            var t = item.GetType();
                            int? did = (int?)t.GetProperty("DeviceId")?.GetValue(item);
                            string mac = t.GetProperty("MacAddress")?.GetValue(item) as string;
                            if (did == deviceId && mac != null)
                            {
                                connectedMacs[mac] = stateStr;
                                break;
                            }
                        }
                    }
                    UpdateStates();
                });
            }
        }

        private void UpdateStates()
        {
            foreach (var entry in radioEntries)
            {
                if (connectedMacs.TryGetValue(entry.Mac, out string state))
                    entry.State = state;
                else
                    entry.State = "Available";
            }
            // Refresh grid
            RadiosGrid.ItemsSource = null;
            RadiosGrid.ItemsSource = radioEntries;
        }

        private void RadiosGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (RadiosGrid.SelectedItem is RadioListEntry entry)
            {
                bool isConnected = connectedMacs.ContainsKey(entry.Mac) &&
                                   connectedMacs[entry.Mac] == "Connected";
                ConnectButton.IsEnabled = !isConnected;
                DisconnectButton.IsEnabled = isConnected;
            }
            else
            {
                ConnectButton.IsEnabled = false;
                DisconnectButton.IsEnabled = false;
            }
        }

        private void ConnectButton_Click(object sender, RoutedEventArgs e)
        {
            if (RadiosGrid.SelectedItem is RadioListEntry entry)
            {
                SelectedMac = entry.Mac;
                SelectedName = entry.Name;
                ConnectRequested = true;
                Close();
            }
        }

        private void DisconnectButton_Click(object sender, RoutedEventArgs e)
        {
            if (RadiosGrid.SelectedItem is RadioListEntry entry)
            {
                SelectedMac = entry.Mac;
                SelectedName = entry.Name;
                DisconnectRequested = true;
                Close();
            }
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();

        protected override void OnClosed(EventArgs e)
        {
            broker?.Dispose();
            base.OnClosed(e);
        }
    }
}
