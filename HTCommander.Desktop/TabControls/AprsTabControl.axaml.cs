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
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using aprsparser;

namespace HTCommander.Desktop.TabControls
{
    public class AprsEntry
    {
        public string Time { get; set; }
        public string From { get; set; }
        public string To { get; set; }
        public string Type { get; set; }
        public string Message { get; set; }
        public bool Visible { get; set; } = true;
    }

    public partial class AprsTabControl : UserControl
    {
        private DataBrokerClient broker;
        private ObservableCollection<AprsEntry> aprsMessages = new ObservableCollection<AprsEntry>();
        private List<AprsEntry> allMessages = new List<AprsEntry>();
        private string _callsign = "";
        private string _stationId = "";
        private bool _showTelemetry = false;
        private List<string[]> aprsRoutes = new List<string[]>();
        private int selectedAprsRoute = 0;
        private HashSet<int> _subscribedRadioDeviceIds = new HashSet<int>();
        private bool _hasAprsChannel = false;

        public AprsTabControl()
        {
            InitializeComponent();
            AprsGrid.ItemsSource = aprsMessages;

            broker = new DataBrokerClient();
            broker.Subscribe(1, "AprsFrame", OnAprsFrame);
            broker.Subscribe(1, "AprsPacketList", OnAprsPacketList);
            broker.Subscribe(1, "AprsStoreReady", OnAprsStoreReady);
            broker.Subscribe(0, new[] { "CallSign", "StationId", "AllowTransmit", "AprsRoutes" }, OnSettingsChanged);
            broker.Subscribe(0, "Stations", OnStationsChanged);
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);

            // Load initial values
            _callsign = broker.GetValue<string>(0, "CallSign", "");
            int stationIdInt = broker.GetValue<int>(0, "StationId", 0);
            _stationId = stationIdInt > 0 ? stationIdInt.ToString() : "";
            CallSignLabel.Text = string.IsNullOrEmpty(_stationId) ? _callsign : $"{_callsign}-{_stationId}";

            // Load APRS routes
            ParseAprsRoutes(broker.GetValue<string>(0, "AprsRoutes", ""));
            selectedAprsRoute = broker.GetValue<int>(0, "SelectedAprsRoute", 0);
            if (selectedAprsRoute >= aprsRoutes.Count) selectedAprsRoute = 0;
            UpdateRouteCombo();

            // Load show telemetry
            _showTelemetry = broker.GetValue<int>(0, "AprsShowTelemetry", 0) == 1;
            ShowTelemetryCheck.IsChecked = _showTelemetry;

            // Load stations for destination combo
            var stations = broker.GetValue<List<StationInfoClass>>(0, "Stations", new List<StationInfoClass>());
            UpdateDestCombo(stations);

            // Load saved destination
            string savedDest = broker.GetValue<string>(0, "AprsDestination", "");
            if (!string.IsNullOrEmpty(savedDest)) DestCombo.Text = savedDest;

            // Load AllowTransmit
            int allowTransmit = broker.GetValue<int>(0, "AllowTransmit", 0);
            TransmitPanel.IsVisible = allowTransmit == 1;

            // Request stored APRS packets
            broker.Dispatch(1, "RequestAprsPackets", null, store: false);

            // Check initial connected radios
            CheckInitialConnectedRadios();
        }

        private void ParseAprsRoutes(string routeStr)
        {
            aprsRoutes.Clear();
            if (string.IsNullOrEmpty(routeStr))
                routeStr = "Standard|APN000,WIDE1-1,WIDE2-2";
            foreach (string entry in routeStr.Split('|'))
            {
                string[] parts = entry.Split(',');
                if (parts.Length >= 2)
                    aprsRoutes.Add(parts);
            }
        }

        private void UpdateRouteCombo()
        {
            RouteCombo.Items.Clear();
            foreach (var route in aprsRoutes)
            {
                RouteCombo.Items.Add(route[0]);
            }
            if (RouteCombo.Items.Count > 0)
            {
                if (selectedAprsRoute < RouteCombo.Items.Count)
                    RouteCombo.SelectedIndex = selectedAprsRoute;
                else
                    RouteCombo.SelectedIndex = 0;
            }
            RouteCombo.IsVisible = aprsRoutes.Count > 1;
        }

        private void UpdateDestCombo(List<StationInfoClass> stations)
        {
            string currentText = DestCombo.Text;
            var callsigns = new List<string>();
            if (stations != null)
            {
                foreach (var s in stations.Where(s => s.StationType == StationInfoClass.StationTypes.APRS))
                {
                    callsigns.Add(s.Callsign);
                }
            }
            DestCombo.ItemsSource = callsigns;
            DestCombo.Text = currentText;
        }

        private void CheckInitialConnectedRadios()
        {
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            if (radios != null) ProcessConnectedRadios(radios);
        }

        private void ProcessConnectedRadios(object data)
        {
            if (data is System.Collections.IEnumerable enumerable)
            {
                _subscribedRadioDeviceIds.Clear();
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    int? deviceId = (int?)item.GetType().GetProperty("DeviceId")?.GetValue(item);
                    if (deviceId.HasValue)
                    {
                        _subscribedRadioDeviceIds.Add(deviceId.Value);
                        // Subscribe to channel events for this radio
                        broker.Subscribe(deviceId.Value, new[] { "Channels", "AllChannelsLoaded" }, OnRadioChannelsChanged);
                    }
                }
                UpdateAprsChannelState();
            }
        }

        private void UpdateAprsChannelState()
        {
            bool hasAprsChannel = false;
            bool hasRadioWithChannels = false;

            foreach (int deviceId in _subscribedRadioDeviceIds)
            {
                bool allLoaded = broker.GetValue<bool>(deviceId, "AllChannelsLoaded", false);
                if (!allLoaded) continue;
                hasRadioWithChannels = true;

                RadioChannelInfo[] channels = broker.GetValue<RadioChannelInfo[]>(deviceId, "Channels", null);
                if (channels != null)
                {
                    foreach (var ch in channels)
                    {
                        if (ch != null && !string.IsNullOrEmpty(ch.name_str) &&
                            ch.name_str.Equals("APRS", StringComparison.OrdinalIgnoreCase))
                        {
                            hasAprsChannel = true;
                            break;
                        }
                    }
                }
                if (hasAprsChannel) break;
            }

            _hasAprsChannel = hasAprsChannel;
            MissingChannelPanel.IsVisible = hasRadioWithChannels && !hasAprsChannel;
            UpdateSendButtonState();
        }

        private void UpdateSendButtonState()
        {
            bool canSend = _hasAprsChannel &&
                           !string.IsNullOrWhiteSpace(DestCombo.Text) &&
                           !string.IsNullOrWhiteSpace(AprsMessageBox.Text);
            SendAprsButton.IsEnabled = canSend;
        }

        private int GetPreferredAprsRadioDeviceId()
        {
            foreach (int deviceId in _subscribedRadioDeviceIds)
            {
                bool allLoaded = broker.GetValue<bool>(deviceId, "AllChannelsLoaded", false);
                if (!allLoaded) continue;
                RadioChannelInfo[] channels = broker.GetValue<RadioChannelInfo[]>(deviceId, "Channels", null);
                if (channels != null)
                {
                    foreach (var ch in channels)
                    {
                        if (ch != null && !string.IsNullOrEmpty(ch.name_str) &&
                            ch.name_str.Equals("APRS", StringComparison.OrdinalIgnoreCase))
                            return deviceId;
                    }
                }
            }
            return _subscribedRadioDeviceIds.Count > 0 ? _subscribedRadioDeviceIds.First() : -1;
        }

        #region Event Handlers

        private void OnAprsStoreReady(int deviceId, string name, object data)
        {
            broker.Dispatch(1, "RequestAprsPackets", null, store: false);
        }

        private void OnAprsFrame(int deviceId, string name, object data)
        {
            if (data is AprsFrameEventArgs args && args.AX25Packet != null && args.AprsPacket != null)
            {
                Dispatcher.UIThread.Post(() => AddAprsPacket(args.AprsPacket, args.AX25Packet, !args.AX25Packet.incoming));
            }
        }

        private void OnAprsPacketList(int deviceId, string name, object data)
        {
            if (data is System.Collections.IEnumerable list)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    allMessages.Clear();
                    aprsMessages.Clear();
                    foreach (var item in list)
                    {
                        if (item is AprsFrameEventArgs args && args.AprsPacket != null && args.AX25Packet != null)
                        {
                            AddAprsPacket(args.AprsPacket, args.AX25Packet, !args.AX25Packet.incoming);
                        }
                    }
                });
            }
        }

        private void AddAprsPacket(AprsPacket aprsPacket, AX25Packet ax25Packet, bool isSender)
        {
            string from = "";
            string to = "";
            string message = "";
            string type = aprsPacket.DataType.ToString();
            bool isMessage = aprsPacket.DataType == PacketDataType.Message;

            if (ax25Packet.addresses != null && ax25Packet.addresses.Count > 1)
                from = ax25Packet.addresses[1].CallSignWithId;
            if (ax25Packet.addresses != null && ax25Packet.addresses.Count > 0)
                to = ax25Packet.addresses[0].ToString();

            if (isMessage)
            {
                // Handle ACK/REJ silently
                if (aprsPacket.MessageData.MsgType == MessageType.mtAck ||
                    aprsPacket.MessageData.MsgType == MessageType.mtRej)
                    return;

                if (isSender)
                    to = "-> " + aprsPacket.MessageData.Addressee;
                else
                    to = from + " -> " + aprsPacket.MessageData.Addressee;

                message = aprsPacket.MessageData.MsgText ?? "";
                type = "Msg";

                // Deduplicate
                string msgId = aprsPacket.MessageData.SeqId;
                if (msgId != null)
                {
                    foreach (var existing in allMessages)
                    {
                        if (existing.From == from && existing.Message == message && existing.Type == "Msg")
                            return;
                    }
                }
            }
            else
            {
                message = aprsPacket.Comment ?? "";
                if (string.IsNullOrEmpty(message) && ax25Packet.dataStr != null)
                    message = ax25Packet.dataStr;
            }

            if (string.IsNullOrWhiteSpace(message)) return;

            var entry = new AprsEntry
            {
                Time = ax25Packet.time.ToString("HH:mm:ss"),
                From = from,
                To = to,
                Type = type,
                Message = message.Trim(),
                Visible = isMessage || _showTelemetry
            };

            allMessages.Add(entry);
            if (entry.Visible) aprsMessages.Add(entry);

            MessageCount.Text = $"{aprsMessages.Count} messages";
        }

        private void OnSettingsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                switch (name)
                {
                    case "CallSign":
                        _callsign = data as string ?? "";
                        CallSignLabel.Text = string.IsNullOrEmpty(_stationId) ? _callsign : $"{_callsign}-{_stationId}";
                        break;
                    case "StationId":
                        if (data is int sid) _stationId = sid > 0 ? sid.ToString() : "";
                        CallSignLabel.Text = string.IsNullOrEmpty(_stationId) ? _callsign : $"{_callsign}-{_stationId}";
                        break;
                    case "AllowTransmit":
                        int allow = 0;
                        if (data is int ai) allow = ai;
                        else if (data is bool ab && ab) allow = 1;
                        TransmitPanel.IsVisible = allow == 1;
                        break;
                    case "AprsRoutes":
                        ParseAprsRoutes(data as string ?? "");
                        UpdateRouteCombo();
                        break;
                }
            });
        }

        private void OnStationsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is List<StationInfoClass> stations) UpdateDestCombo(stations);
            });
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() => ProcessConnectedRadios(data));
        }

        private void OnRadioChannelsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() => UpdateAprsChannelState());
        }

        #endregion

        #region UI Events

        private void ShowTelemetry_Click(object sender, RoutedEventArgs e)
        {
            _showTelemetry = ShowTelemetryCheck.IsChecked == true;
            DataBroker.Dispatch(0, "AprsShowTelemetry", _showTelemetry ? 1 : 0);
            RefreshVisibleMessages();
        }

        private void RefreshVisibleMessages()
        {
            aprsMessages.Clear();
            foreach (var entry in allMessages)
            {
                entry.Visible = entry.Type == "Msg" || _showTelemetry;
                if (entry.Visible) aprsMessages.Add(entry);
            }
            MessageCount.Text = $"{aprsMessages.Count} messages";
        }

        private void SendAprsButton_Click(object sender, RoutedEventArgs e)
        {
            string destination = DestCombo.Text?.Trim().ToUpper();
            string message = AprsMessageBox.Text?.Trim();
            if (string.IsNullOrEmpty(destination) || string.IsNullOrEmpty(message)) return;

            int radioDeviceId = GetPreferredAprsRadioDeviceId();
            if (radioDeviceId == -1) return;

            string[] route = null;
            if (aprsRoutes.Count > 0)
            {
                int idx = RouteCombo.SelectedIndex >= 0 ? RouteCombo.SelectedIndex : 0;
                if (idx < aprsRoutes.Count) route = aprsRoutes[idx];
            }

            var messageData = new AprsSendMessageData
            {
                Destination = destination,
                Message = message,
                RadioDeviceId = radioDeviceId,
                Route = route
            };

            broker.Dispatch(1, "SendAprsMessage", messageData, store: false);
            AprsMessageBox.Text = "";

            // Save destination
            DataBroker.Dispatch(0, "AprsDestination", destination);
        }

        private void AprsMessageBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                SendAprsButton_Click(sender, e);
                e.Handled = true;
            }
        }

        #endregion
    }
}
