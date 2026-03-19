/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Mapsui;
using Mapsui.Extensions;
using Mapsui.Layers;
using Mapsui.Projections;
using Mapsui.Styles;
using Mapsui.Tiling;
using aprsparser;
using HTCommander.radio;

namespace HTCommander.Desktop.TabControls
{
    public partial class MapTabControl : UserControl
    {
        private DataBrokerClient broker;
        private WritableLayer aprsLayer;
        private WritableLayer radioLayer;
        private Dictionary<string, AprsStationInfo> aprsStations = new Dictionary<string, AprsStationInfo>(StringComparer.OrdinalIgnoreCase);
        private bool showAprs = true;

        private class AprsStationInfo
        {
            public string Callsign;
            public double Latitude;
            public double Longitude;
            public DateTime LastSeen;
            public PointFeature Feature;
        }

        public MapTabControl()
        {
            InitializeComponent();
            InitializeMap();

            broker = new DataBrokerClient();
            broker.Subscribe(DataBroker.AllDevices, "Position", OnPositionChanged);
            broker.Subscribe(1, "AprsFrame", OnAprsFrame);
            broker.Subscribe(1, "AprsPacketList", OnAprsPacketList);
            broker.Subscribe(1, "AprsStoreReady", OnAprsStoreReady);

            // Request historical APRS packets
            broker.Dispatch(1, "RequestAprsPackets", null, store: false);
        }

        private void InitializeMap()
        {
            var map = MapControl.Map;

            // Add OpenStreetMap tile layer
            map.Layers.Add(OpenStreetMap.CreateTileLayer());

            // Radio position layer (connected radios' GPS)
            radioLayer = new WritableLayer { Name = "Radio Positions" };
            map.Layers.Add(radioLayer);

            // APRS stations layer
            aprsLayer = new WritableLayer { Name = "APRS Stations" };
            map.Layers.Add(aprsLayer);

            // Default view: center of continental US
            var center = SphericalMercator.FromLonLat(-98.5795, 39.8283);
            map.Navigator.CenterOnAndZoomTo(new MPoint(center.x, center.y), map.Navigator.Resolutions[5]);
        }

        #region Radio Position

        private void OnPositionChanged(int deviceId, string name, object data)
        {
            if (data is not RadioPosition pos) return;
            if (pos.Latitude == 0 && pos.Longitude == 0) return;

            Dispatcher.UIThread.Post(() =>
            {
                var coords = SphericalMercator.FromLonLat(pos.Longitude, pos.Latitude);
                var point = new MPoint(coords.x, coords.y);

                var feature = new PointFeature(point);
                feature.Styles.Add(new SymbolStyle
                {
                    SymbolScale = 0.6,
                    Fill = new Brush(Color.FromArgb(255, 0, 120, 215))
                });
                feature.Styles.Add(new LabelStyle
                {
                    Text = "My Radio",
                    ForeColor = Color.White,
                    BackColor = new Brush(Color.FromArgb(180, 0, 80, 160)),
                    HorizontalAlignment = LabelStyle.HorizontalAlignmentEnum.Center,
                    VerticalAlignment = LabelStyle.VerticalAlignmentEnum.Top,
                    Offset = new Offset(0, -18)
                });

                radioLayer.Clear();
                radioLayer.Add(feature);
                MapControl.Map.Navigator.CenterOn(point);
                MapControl.Refresh();
            });
        }

        #endregion

        #region APRS Markers

        private void OnAprsStoreReady(int deviceId, string name, object data)
        {
            broker.Dispatch(1, "RequestAprsPackets", null, store: false);
        }

        private void OnAprsPacketList(int deviceId, string name, object data)
        {
            if (data is System.Collections.IEnumerable list)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    foreach (var item in list)
                    {
                        if (item is AprsFrameEventArgs args && args.AprsPacket != null)
                            ProcessAprsPacket(args.AprsPacket);
                    }
                    RefreshAprsLayer();
                });
            }
        }

        private void OnAprsFrame(int deviceId, string name, object data)
        {
            if (data is AprsFrameEventArgs args && args.AprsPacket != null)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    ProcessAprsPacket(args.AprsPacket);
                    RefreshAprsLayer();
                });
            }
        }

        private void ProcessAprsPacket(AprsPacket aprsPacket)
        {
            if (aprsPacket?.Packet == null || aprsPacket.Position == null) return;

            double lat = aprsPacket.Position.CoordinateSet.Latitude.Value;
            double lon = aprsPacket.Position.CoordinateSet.Longitude.Value;
            if (lat == 0 && lon == 0) return;
            if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return;

            AX25Packet packet = aprsPacket.Packet;
            if (packet.addresses == null || packet.addresses.Count < 2) return;

            string callsign = packet.addresses[1].CallSignWithId;
            DateTime time = packet.time;

            var coords = SphericalMercator.FromLonLat(lon, lat);
            var point = new MPoint(coords.x, coords.y);

            if (aprsStations.TryGetValue(callsign, out var existing))
            {
                // Update existing station
                existing.Latitude = lat;
                existing.Longitude = lon;
                existing.LastSeen = time;
                existing.Feature = CreateAprsFeature(point, callsign);
            }
            else
            {
                // Add new station
                aprsStations[callsign] = new AprsStationInfo
                {
                    Callsign = callsign,
                    Latitude = lat,
                    Longitude = lon,
                    LastSeen = time,
                    Feature = CreateAprsFeature(point, callsign)
                };
            }
        }

        private PointFeature CreateAprsFeature(MPoint point, string callsign)
        {
            var feature = new PointFeature(point);
            feature.Styles.Add(new SymbolStyle
            {
                SymbolScale = 0.4,
                Fill = new Brush(Color.FromArgb(255, 220, 50, 50))
            });
            feature.Styles.Add(new LabelStyle
            {
                Text = callsign,
                ForeColor = Color.White,
                BackColor = new Brush(Color.FromArgb(160, 180, 40, 40)),
                Font = new Font { Size = 10 },
                HorizontalAlignment = LabelStyle.HorizontalAlignmentEnum.Center,
                VerticalAlignment = LabelStyle.VerticalAlignmentEnum.Top,
                Offset = new Offset(0, -14)
            });
            return feature;
        }

        private void RefreshAprsLayer()
        {
            aprsLayer.Clear();
            if (!showAprs) return;

            foreach (var station in aprsStations.Values)
            {
                if (station.Feature != null)
                    aprsLayer.Add(station.Feature);
            }
            MapControl.Refresh();
        }

        #endregion

        #region UI Events

        private void CenterButton_Click(object sender, RoutedEventArgs e)
        {
            // Center on radio position first, then APRS stations
            var extent = radioLayer.Extent;
            if (extent == null) extent = aprsLayer.Extent;
            if (extent != null)
            {
                MapControl.Map.Navigator.CenterOn(extent.Centroid);
                MapControl.Refresh();
            }
        }

        private void ShowAirplanes_Click(object sender, RoutedEventArgs e)
        {
            bool show = ShowAirplanesCheck.IsChecked == true;
            DataBroker.Dispatch(0, "ShowAirplanesOnMap", show);
        }

        private void ShowAprs_Click(object sender, RoutedEventArgs e)
        {
            showAprs = ShowAprsCheck.IsChecked == true;
            RefreshAprsLayer();
        }

        #endregion
    }
}
