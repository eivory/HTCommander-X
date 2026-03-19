/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.TabControls
{
    public partial class TerminalTabControl : UserControl
    {
        private DataBrokerClient broker;
        private List<int> connectedRadioIds = new List<int>();
        private Dictionary<int, RadioLockState> lockStates = new Dictionary<int, RadioLockState>();
        private int connectedRadioId = -1;
        private bool isConnected = false;
        private List<StationInfoClass> terminalStations = new List<StationInfoClass>();

        public TerminalTabControl()
        {
            InitializeComponent();
            broker = new DataBrokerClient();

            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);
            broker.Subscribe(DataBroker.AllDevices, "LockState", OnLockStateChanged);
            broker.Subscribe(DataBroker.AllDevices, "UniqueDataFrame", OnUniqueDataFrame);
            broker.Subscribe(0, "Stations", OnStationsChanged);

            // Load terminal stations from contacts
            var stations = broker.GetValue<List<StationInfoClass>>(0, "Stations", new List<StationInfoClass>());
            UpdateStationCombo(stations);

            // Check initial radio state
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            if (radios != null) ProcessConnectedRadios(radios);
        }

        private void UpdateStationCombo(List<StationInfoClass> stations)
        {
            terminalStations = stations?.Where(s =>
                s.StationType == StationInfoClass.StationTypes.Terminal ||
                s.StationType == StationInfoClass.StationTypes.Generic).ToList()
                ?? new List<StationInfoClass>();

            StationCombo.Items.Clear();
            foreach (var s in terminalStations)
            {
                StationCombo.Items.Add(s.Callsign);
            }
        }

        private void ProcessConnectedRadios(object data)
        {
            connectedRadioIds.Clear();
            if (data is System.Collections.IEnumerable enumerable)
            {
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    int? deviceId = (int?)item.GetType().GetProperty("DeviceId")?.GetValue(item);
                    if (deviceId.HasValue) connectedRadioIds.Add(deviceId.Value);
                }
            }
            UpdateConnectButtonState();
        }

        private void UpdateConnectButtonState()
        {
            if (isConnected)
            {
                ConnectButton.Content = "Disconnect";
                ConnectButton.IsEnabled = true;
            }
            else
            {
                ConnectButton.Content = "Connect";
                // Can connect if we have radios and at least one is not locked
                bool canConnect = connectedRadioIds.Any(id =>
                {
                    if (lockStates.TryGetValue(id, out var state))
                        return !state.IsLocked;
                    return true; // Not locked if no state
                });
                ConnectButton.IsEnabled = canConnect;
            }
        }

        #region Event Handlers

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                ProcessConnectedRadios(data);
            });
        }

        private void OnLockStateChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is RadioLockState state)
                {
                    lockStates[deviceId] = state;

                    // Check if our connection was broken
                    if (isConnected && deviceId == connectedRadioId)
                    {
                        if (!state.IsLocked || state.Usage != "Terminal")
                        {
                            isConnected = false;
                            connectedRadioId = -1;
                            ConnectionStatus.Text = "Disconnected";
                            ConnectionStatus.Foreground = Avalonia.Media.Brushes.Gray;
                            InputBox.IsEnabled = false;
                            SendButton.IsEnabled = false;
                        }
                    }
                    UpdateConnectButtonState();
                }
            });
        }

        private void OnUniqueDataFrame(int deviceId, string name, object data)
        {
            if (data is TncDataFragment fragment && fragment.usage == "Terminal")
            {
                Dispatcher.UIThread.Post(() =>
                {
                    string decoded = Utils.TncDataFragmentToShortString(fragment);
                    string from = "";
                    AX25Packet packet = AX25Packet.DecodeAX25Packet(fragment);
                    if (packet != null && packet.addresses.Count > 1)
                        from = packet.addresses[1].CallSignWithId;

                    AppendOutput($"[{from}] {decoded}\n", false);
                });
            }
        }

        private void OnStationsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is List<StationInfoClass> stations) UpdateStationCombo(stations);
            });
        }

        #endregion

        private void AppendOutput(string text, bool outgoing)
        {
            string current = TerminalOutput.Text ?? "";
            if (current.Length > 100000)
                current = current.Substring(current.Length - 50000);

            string prefix = outgoing ? "> " : "";
            TerminalOutput.Text = current + prefix + text;
            TerminalOutput.CaretIndex = TerminalOutput.Text.Length;
        }

        private void ConnectButton_Click(object sender, RoutedEventArgs e)
        {
            if (isConnected)
            {
                // Disconnect: unlock the radio
                if (connectedRadioId >= 0)
                {
                    broker.Dispatch(connectedRadioId, "SetUnlock", new SetUnlockData { Usage = "Terminal" }, store: false);
                }
                isConnected = false;
                connectedRadioId = -1;
                ConnectionStatus.Text = "Disconnected";
                ConnectionStatus.Foreground = Avalonia.Media.Brushes.Gray;
                InputBox.IsEnabled = false;
                SendButton.IsEnabled = false;
                AppendOutput("--- Disconnected ---\n", false);
            }
            else
            {
                // Find an available radio (not locked)
                int radioId = connectedRadioIds.FirstOrDefault(id =>
                {
                    if (lockStates.TryGetValue(id, out var state))
                        return !state.IsLocked;
                    return true;
                }, -1);

                if (radioId < 0) return;

                // Get station from combo
                StationInfoClass station = null;
                if (StationCombo.SelectedIndex >= 0 && StationCombo.SelectedIndex < terminalStations.Count)
                    station = terminalStations[StationCombo.SelectedIndex];

                // Lock the radio for terminal use
                broker.Dispatch(radioId, "SetLock", new SetLockData
                {
                    Usage = "Terminal",
                    RegionId = -1,
                    ChannelId = -1
                }, store: false);

                if (station != null)
                    broker.Dispatch(radioId, "TerminalStation", station, store: false);

                connectedRadioId = radioId;
                isConnected = true;
                ConnectionStatus.Text = station != null ? $"Connected ({station.Callsign})" : "Connected";
                ConnectionStatus.Foreground = Avalonia.Media.Brushes.LightGreen;
                InputBox.IsEnabled = true;
                SendButton.IsEnabled = true;
                AppendOutput("--- Connected ---\n", false);
            }
            UpdateConnectButtonState();
        }

        private void SendButton_Click(object sender, RoutedEventArgs e)
        {
            SendMessage();
        }

        private void InputBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                SendMessage();
                e.Handled = true;
            }
        }

        private void SendMessage()
        {
            string text = InputBox.Text?.Trim();
            if (string.IsNullOrEmpty(text) || connectedRadioId < 0) return;

            AppendOutput(text + "\n", true);
            InputBox.Text = "";

            // Dispatch as terminal send
            broker.Dispatch(connectedRadioId, "TerminalSend", text, store: false);
        }
    }
}
