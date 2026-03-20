using System;
using System.Collections.ObjectModel;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;

namespace HTCommander.Desktop.Dialogs
{
    public partial class RadioAudioClipsDialog : Window
    {
        private DataBrokerClient broker;
        private int deviceId;
        private ObservableCollection<AudioClipEntry> clips = new ObservableCollection<AudioClipEntry>();

        public RadioAudioClipsDialog()
        {
            InitializeComponent();
        }

        public RadioAudioClipsDialog(int deviceId)
        {
            InitializeComponent();
            this.deviceId = deviceId;
            ClipsGrid.ItemsSource = clips;

            broker = new DataBrokerClient();
            broker.Subscribe(deviceId, "AudioClips", OnAudioClipsChanged);
        }

        private void OnAudioClipsChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (data is AudioClipEntry[] entries)
                {
                    clips.Clear();
                    foreach (var entry in entries) { clips.Add(entry); }
                }
            });
        }

        private void PlayButton_Click(object sender, RoutedEventArgs e)
        {
            if (ClipsGrid.SelectedItem is AudioClipEntry clip)
            {
                broker.Dispatch(deviceId, "PlayAudioClip", clip.Name, store: false);
            }
        }

        private void DeleteButton_Click(object sender, RoutedEventArgs e)
        {
            if (ClipsGrid.SelectedItem is AudioClipEntry clip)
            {
                broker.Dispatch(deviceId, "DeleteAudioClip", clip.Name, store: false);
            }
        }

        private async void RenameButton_Click(object sender, RoutedEventArgs e)
        {
            if (ClipsGrid.SelectedItem is AudioClipEntry clip)
            {
                var dialog = new AudioClipRenameDialog();
                dialog.SetCurrentName(clip.Name);
                await dialog.ShowDialog(this);
                if (dialog.Confirmed && !string.IsNullOrWhiteSpace(dialog.NewName))
                {
                    broker.Dispatch(deviceId, "RenameAudioClip", new string[] { clip.Name, dialog.NewName }, store: false);
                }
            }
        }

        private void ImportButton_Click(object sender, RoutedEventArgs e)
        {
            broker.Dispatch(deviceId, "ImportAudioClip", null, store: false);
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

        protected override void OnClosed(EventArgs e)
        {
            broker?.Dispose();
            base.OnClosed(e);
        }
    }

}
