/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.TabControls
{
    public class QsoDisplayItem
    {
        public string DateTimeDisplay { get; set; }
        public string Callsign { get; set; }
        public string FrequencyDisplay { get; set; }
        public string Mode { get; set; }
        public string Band { get; set; }
        public string RstSent { get; set; }
        public string RstReceived { get; set; }
        public string MyCallsign { get; set; }
        public string Notes { get; set; }
        public QsoEntry Source { get; set; }
    }

    public partial class LogbookTabControl : UserControl
    {
        private DataBrokerClient broker;
        private List<QsoEntry> qsoLog = new List<QsoEntry>();

        public LogbookTabControl()
        {
            InitializeComponent();
            broker = new DataBrokerClient();
            broker.Subscribe(0, "QsoLog", OnQsoLogChanged);

            // Load initial data
            var log = broker.GetValue<List<QsoEntry>>(0, "QsoLog", null);
            if (log != null)
            {
                qsoLog = log;
                RefreshGrid();
            }
        }

        private void OnQsoLogChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is List<QsoEntry> log)
                {
                    qsoLog = log;
                    RefreshGrid();
                }
            });
        }

        private void RefreshGrid()
        {
            var items = qsoLog.OrderByDescending(q => q.StartTime).Select(q => new QsoDisplayItem
            {
                DateTimeDisplay = q.StartTime.ToString("yyyy-MM-dd HH:mm"),
                Callsign = q.Callsign ?? "",
                FrequencyDisplay = q.FrequencyMHz > 0 ? q.FrequencyMHz.ToString("F4") + " MHz" : "",
                Mode = q.Mode ?? "",
                Band = q.Band ?? "",
                RstSent = q.RstSent ?? "",
                RstReceived = q.RstReceived ?? "",
                MyCallsign = q.MyCallsign ?? "",
                Notes = q.Notes ?? "",
                Source = q
            }).ToList();

            QsoGrid.ItemsSource = items;
            QsoCount.Text = $"{qsoLog.Count} QSOs";
        }

        private void QsoGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            bool hasSelection = QsoGrid.SelectedItem != null;
            EditButton.IsEnabled = hasSelection;
            RemoveButton.IsEnabled = hasSelection;
        }

        private async void AddButton_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new Dialogs.AddQsoDialog();
            await dialog.ShowDialog(Avalonia.Application.Current.ApplicationLifetime is
                Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop
                ? desktop.MainWindow : this.VisualRoot as Window);
            if (dialog.Confirmed)
            {
                qsoLog.Add(dialog.GetQso());
                DataBroker.Dispatch(0, "QsoLog", qsoLog);
                RefreshGrid();
            }
        }

        private async void EditButton_Click(object sender, RoutedEventArgs e)
        {
            if (QsoGrid.SelectedItem is not QsoDisplayItem item) return;
            var dialog = new Dialogs.AddQsoDialog();
            dialog.Title = "Edit QSO";
            dialog.SetQso(item.Source);
            await dialog.ShowDialog(Avalonia.Application.Current.ApplicationLifetime is
                Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop
                ? desktop.MainWindow : this.VisualRoot as Window);
            if (dialog.Confirmed)
            {
                var updated = dialog.GetQso();
                int idx = qsoLog.IndexOf(item.Source);
                if (idx >= 0) qsoLog[idx] = updated;
                DataBroker.Dispatch(0, "QsoLog", qsoLog);
                RefreshGrid();
            }
        }

        private void RemoveButton_Click(object sender, RoutedEventArgs e)
        {
            if (QsoGrid.SelectedItem is QsoDisplayItem item)
            {
                qsoLog.Remove(item.Source);
                DataBroker.Dispatch(0, "QsoLog", qsoLog);
                RefreshGrid();
            }
        }

        private async void ExportButton_Click(object sender, RoutedEventArgs e)
        {
            if (qsoLog.Count == 0) return;

            var picker = Program.PlatformServices?.FilePicker;
            if (picker == null) return;

            string path = await picker.SaveFileAsync("Export ADIF", "logbook.adi",
                new[] { "ADIF Files|*.adi", "All Files|*.*" });
            if (path == null) return;

            try
            {
                string adif = AdifExport.Export(qsoLog);
                System.IO.File.WriteAllText(path, adif);
                broker.LogInfo($"Exported {qsoLog.Count} QSOs to {path}");
            }
            catch (Exception ex)
            {
                broker.LogError($"ADIF export failed: {ex.Message}");
            }
        }
    }
}
