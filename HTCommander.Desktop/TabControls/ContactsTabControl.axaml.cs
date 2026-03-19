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

namespace HTCommander.Desktop.TabControls
{
    public partial class ContactsTabControl : UserControl
    {
        private DataBrokerClient broker;
        private List<StationInfoClass> currentStations = new List<StationInfoClass>();

        public ContactsTabControl()
        {
            InitializeComponent();
            broker = new DataBrokerClient();
            broker.Subscribe(0, "Stations", OnStationsChanged);

            // Load initial stations
            var stations = broker.GetValue<List<StationInfoClass>>(0, "Stations", null);
            if (stations != null)
            {
                currentStations = stations;
                StationsGrid.ItemsSource = currentStations;
                StationCount.Text = $"{currentStations.Count} stations";
            }
        }

        private void OnStationsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is List<StationInfoClass> stations)
                {
                    currentStations = stations;
                    StationsGrid.ItemsSource = currentStations;
                    StationCount.Text = $"{currentStations.Count} stations";
                }
            });
        }

        private void StationsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            bool hasSelection = StationsGrid.SelectedItem != null;
            EditButton.IsEnabled = hasSelection;
            RemoveButton.IsEnabled = hasSelection;
        }

        private async void AddButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new Dialogs.AddStationDialog();
            await dialog.ShowDialog(Avalonia.Application.Current.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop
                ? desktop.MainWindow : this.VisualRoot as Window);
            if (dialog.Confirmed)
            {
                var station = new StationInfoClass
                {
                    Callsign = dialog.Callsign,
                    Name = dialog.StationName ?? "",
                    StationType = (StationInfoClass.StationTypes)dialog.StationType,
                    Description = dialog.Description ?? ""
                };
                currentStations.Add(station);
                DataBroker.Dispatch(0, "Stations", currentStations);
                StationsGrid.ItemsSource = null;
                StationsGrid.ItemsSource = currentStations;
                StationCount.Text = $"{currentStations.Count} stations";
            }
        }

        private async void EditButton_Click(object sender, RoutedEventArgs e)
        {
            if (StationsGrid.SelectedItem is not StationInfoClass station) return;
            var dialog = new Dialogs.AddStationDialog();
            dialog.Title = "Edit Station";
            dialog.SetStation(station.Callsign, station.Name, (int)station.StationType, station.Description);
            await dialog.ShowDialog(Avalonia.Application.Current.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop
                ? desktop.MainWindow : this.VisualRoot as Window);
            if (dialog.Confirmed)
            {
                station.Callsign = dialog.Callsign;
                station.Name = dialog.StationName ?? "";
                station.StationType = (StationInfoClass.StationTypes)dialog.StationType;
                station.Description = dialog.Description ?? "";
                DataBroker.Dispatch(0, "Stations", currentStations);
                StationsGrid.ItemsSource = null;
                StationsGrid.ItemsSource = currentStations;
            }
        }

        private void RemoveButton_Click(object sender, RoutedEventArgs e)
        {
            if (StationsGrid.SelectedItem is StationInfoClass station)
            {
                currentStations.Remove(station);
                DataBroker.Dispatch(0, "Stations", currentStations);
                StationsGrid.ItemsSource = null;
                StationsGrid.ItemsSource = currentStations;
                StationCount.Text = $"{currentStations.Count} stations";
            }
        }
    }
}
