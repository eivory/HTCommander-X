/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.TabControls
{
    public class PacketEntry
    {
        public string Time { get; set; }
        public string Direction { get; set; }
        public string Channel { get; set; }
        public string Encoding { get; set; }
        public string Data { get; set; }
        public object RawPacket { get; set; }
    }

    public partial class PacketCaptureTabControl : UserControl
    {
        private DataBrokerClient broker;
        private ObservableCollection<PacketEntry> packets = new ObservableCollection<PacketEntry>();

        public PacketCaptureTabControl()
        {
            InitializeComponent();
            PacketsGrid.ItemsSource = packets;

            broker = new DataBrokerClient();
            broker.Subscribe(1, "PacketStored", OnPacketStored);
            broker.Subscribe(1, "PacketList", OnPacketList);
            broker.Subscribe(1, "PacketStoreReady", OnPacketStoreReady);

            // Check if PacketStore is already ready
            bool packetStoreReady = DataBroker.GetValue<bool>(1, "PacketStoreReady", false);
            if (packetStoreReady)
            {
                broker.Dispatch(1, "RequestPacketList", null, store: false);
            }
        }

        private void OnPacketStoreReady(int deviceId, string name, object data)
        {
            DataBroker.Dispatch(1, "RequestPacketList", null, store: false);
        }

        private void OnPacketList(int deviceId, string name, object data)
        {
            if (data is List<TncDataFragment> packetList)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    packets.Clear();
                    foreach (var fragment in packetList)
                    {
                        packets.Add(FragmentToEntry(fragment));
                    }
                    PacketCount.Text = $"{packets.Count} packets";
                });
            }
        }

        private void OnPacketStored(int deviceId, string name, object data)
        {
            if (data is TncDataFragment fragment)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    packets.Insert(0, FragmentToEntry(fragment));
                    PacketCount.Text = $"{packets.Count} packets";
                });
            }
        }

        private PacketEntry FragmentToEntry(TncDataFragment fragment)
        {
            string encodingStr = "";
            if (fragment.encoding != TncDataFragment.FragmentEncodingType.Unknown)
            {
                encodingStr = fragment.encoding.ToString().Replace("Software", "").Replace("Hardware", "");
            }

            return new PacketEntry
            {
                Time = fragment.time.ToString("HH:mm:ss"),
                Direction = fragment.incoming ? "RX" : "TX",
                Channel = fragment.channel_name ?? "",
                Encoding = encodingStr,
                Data = Utils.TncDataFragmentToShortString(fragment),
                RawPacket = fragment
            };
        }

        private void PacketsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (PacketsGrid.SelectedItem is PacketEntry entry && entry.RawPacket is TncDataFragment fragment)
            {
                // Show detailed decode
                string decode = Utils.TncDataFragmentToShortString(fragment);
                string header = $"Time: {fragment.time:yyyy-MM-dd HH:mm:ss}  Channel: {fragment.channel_name}  Dir: {(fragment.incoming ? "Incoming" : "Outgoing")}";
                if (fragment.encoding != TncDataFragment.FragmentEncodingType.Unknown)
                    header += $"  Encoding: {fragment.encoding}";
                if (fragment.frame_type != TncDataFragment.FragmentFrameType.Unknown)
                    header += $"  Frame: {fragment.frame_type}";
                if (fragment.corrections >= 0)
                    header += $"  Corrections: {fragment.corrections}";

                DecodeText.Text = header + "\n\n" + decode + "\n\nRaw: " + Utils.BytesToHex(fragment.data);
            }
        }

        private void ShowDecode_Click(object sender, RoutedEventArgs e)
        {
            DataBroker.Dispatch(0, "ShowPacketDecode", ShowDecodeCheck.IsChecked == true);
        }

        private void ClearButton_Click(object sender, RoutedEventArgs e)
        {
            packets.Clear();
            PacketCount.Text = "0 packets";
            DecodeText.Text = "";
        }
    }
}
