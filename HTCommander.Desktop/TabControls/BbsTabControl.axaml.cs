/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.TabControls
{
    public class BbsStatsEntry
    {
        public string Callsign { get; set; }
        public string LastSeenStr { get; set; }
        public int TotalPacketsIn { get; set; }
        public int TotalPacketsOut { get; set; }
        public int TotalBytesIn { get; set; }
        public int TotalBytesOut { get; set; }
    }

    public partial class BbsTabControl : UserControl
    {
        private DataBrokerClient broker;
        private ObservableCollection<BbsStatsEntry> bbsStats = new ObservableCollection<BbsStatsEntry>();
        private List<int> connectedRadioIds = new List<int>();
        private Dictionary<int, RadioLockState> lockStates = new Dictionary<int, RadioLockState>();
        private bool isActive = false;
        private int activeRadioId = -1;

        public BbsTabControl()
        {
            InitializeComponent();
            BbsGrid.ItemsSource = bbsStats;

            broker = new DataBrokerClient();
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);
            broker.Subscribe(DataBroker.AllDevices, "LockState", OnLockStateChanged);
            broker.Subscribe(DataBroker.AllDevices, new[] { "BbsTraffic", "BbsControlMessage", "BbsError" }, OnBbsEvent);
            broker.Subscribe(1, "BbsMergedStats", OnBbsMergedStats);

            // Check initial radios
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            if (radios != null) ProcessConnectedRadios(radios);
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
            UpdateActivateButtonState();
        }

        private void UpdateActivateButtonState()
        {
            if (isActive)
            {
                ActivateButton.Content = "Deactivate";
                ActivateButton.IsEnabled = true;
            }
            else
            {
                ActivateButton.Content = "Activate";
                bool canActivate = connectedRadioIds.Any(id =>
                {
                    if (lockStates.TryGetValue(id, out var state))
                        return !state.IsLocked;
                    return true;
                });
                ActivateButton.IsEnabled = canActivate;
            }
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() => ProcessConnectedRadios(data));
        }

        private void OnLockStateChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is RadioLockState state)
                {
                    lockStates[deviceId] = state;
                    if (isActive && deviceId == activeRadioId && (!state.IsLocked || state.Usage != "BBS"))
                    {
                        isActive = false;
                        activeRadioId = -1;
                        BbsStatus.Text = "Inactive";
                    }
                    UpdateActivateButtonState();
                }
            });
        }

        private void OnBbsEvent(int deviceId, string name, object data)
        {
            if (data is string msg)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    if (ViewTrafficCheck.IsChecked != true) return;

                    string prefix = name == "BbsError" ? "[ERR] " :
                                    name == "BbsControlMessage" ? "[CTL] " : "";
                    string timestamp = DateTime.Now.ToString("HH:mm:ss");
                    string current = TrafficLog.Text ?? "";
                    if (current.Length > 100000)
                        current = current.Substring(current.Length - 50000);
                    TrafficLog.Text = current + $"[{timestamp}] {prefix}{msg}\n";
                    TrafficLog.CaretIndex = TrafficLog.Text.Length;
                });
            }
        }

        private void OnBbsMergedStats(int deviceId, string name, object data)
        {
            if (data is List<MergedStationStats> stats)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    bbsStats.Clear();
                    foreach (var s in stats)
                    {
                        bbsStats.Add(new BbsStatsEntry
                        {
                            Callsign = s.Callsign,
                            LastSeenStr = s.LastSeen.ToString("yyyy-MM-dd HH:mm"),
                            TotalPacketsIn = s.TotalPacketsIn,
                            TotalPacketsOut = s.TotalPacketsOut,
                            TotalBytesIn = s.TotalBytesIn,
                            TotalBytesOut = s.TotalBytesOut
                        });
                    }
                });
            }
        }

        private void ViewTraffic_Click(object sender, RoutedEventArgs e)
        {
            // Toggle handled by checkbox binding
        }

        private void ActivateButton_Click(object sender, RoutedEventArgs e)
        {
            if (isActive)
            {
                // Deactivate
                if (activeRadioId >= 0)
                    broker.Dispatch(activeRadioId, "SetUnlock", new SetUnlockData { Usage = "BBS" }, store: false);
                isActive = false;
                activeRadioId = -1;
                BbsStatus.Text = "Inactive";
            }
            else
            {
                // Find available radio
                int radioId = connectedRadioIds.FirstOrDefault(id =>
                {
                    if (lockStates.TryGetValue(id, out var state))
                        return !state.IsLocked;
                    return true;
                }, -1);

                if (radioId < 0) return;

                broker.Dispatch(radioId, "SetLock", new SetLockData
                {
                    Usage = "BBS",
                    RegionId = -1,
                    ChannelId = -1
                }, store: false);

                activeRadioId = radioId;
                isActive = true;
                BbsStatus.Text = "Active";
            }
            UpdateActivateButtonState();
        }
    }
}
