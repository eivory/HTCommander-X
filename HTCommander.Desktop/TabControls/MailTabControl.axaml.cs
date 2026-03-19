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
    public class MailEntry
    {
        public string From { get; set; }
        public string Subject { get; set; }
        public string DateStr { get; set; }
        public WinLinkMail Mail { get; set; }
    }

    public partial class MailTabControl : UserControl
    {
        private DataBrokerClient broker;
        private ObservableCollection<MailEntry> mailEntries = new ObservableCollection<MailEntry>();
        private List<WinLinkMail> allMails = new List<WinLinkMail>();
        private string selectedMailbox = "Inbox";
        private bool hasConnectedRadios = false;

        public MailTabControl()
        {
            InitializeComponent();
            MailList.ItemsSource = mailEntries;

            broker = new DataBrokerClient();
            broker.Subscribe(0, new[] { "MailsChanged", "MailList", "MailStoreReady" }, OnMailEvent);
            broker.Subscribe(1, "WinlinkBusy", OnWinlinkBusyChanged);
            broker.Subscribe(1, "WinlinkStateMessage", OnWinlinkStateMessageChanged);
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);

            // Check initial state
            bool mailStoreReady = DataBroker.GetValue<bool>(0, "MailStoreReady", false);
            if (mailStoreReady)
            {
                broker.Dispatch(0, "MailGet", "Inbox", store: false);
            }

            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            hasConnectedRadios = radios != null;
            UpdateConnectButtonState();
        }

        private void UpdateConnectButtonState()
        {
            ConnectButton.IsEnabled = hasConnectedRadios;
        }

        private void RefreshMailList()
        {
            mailEntries.Clear();
            var filtered = allMails.Where(m => m.Mailbox == selectedMailbox)
                                   .OrderByDescending(m => m.DateTime);
            foreach (var mail in filtered)
            {
                mailEntries.Add(new MailEntry
                {
                    From = mail.From ?? "",
                    Subject = mail.Subject ?? "(no subject)",
                    DateStr = mail.DateTime.ToString("yyyy-MM-dd HH:mm"),
                    Mail = mail
                });
            }
        }

        #region Event Handlers

        private void OnMailEvent(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (name == "MailList" && data is List<WinLinkMail> mails)
                {
                    allMails = mails;
                    RefreshMailList();
                }
                else if (name == "MailsChanged")
                {
                    // Re-request current mailbox
                    broker.Dispatch(0, "MailGet", selectedMailbox, store: false);
                }
                else if (name == "MailStoreReady")
                {
                    broker.Dispatch(0, "MailGet", selectedMailbox, store: false);
                }
            });
        }

        private void OnWinlinkBusyChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                bool busy = data is bool b && b;
                ConnectButton.IsEnabled = hasConnectedRadios && !busy;
                ConnectButton.Content = busy ? "Syncing..." : "Sync";
            });
        }

        private void OnWinlinkStateMessageChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                WinlinkStatus.Text = data as string ?? "";
            });
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            Dispatcher.UIThread.Post(() =>
            {
                hasConnectedRadios = false;
                if (data is System.Collections.IEnumerable enumerable)
                {
                    foreach (var item in enumerable)
                    {
                        if (item != null) { hasConnectedRadios = true; break; }
                    }
                }
                UpdateConnectButtonState();
            });
        }

        #endregion

        #region UI Events

        private void MailboxTree_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (MailboxTree.SelectedItem is TreeViewItem item && item.Tag is string mailbox)
            {
                selectedMailbox = mailbox;
                RefreshMailList();
            }
        }

        private void MailList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (MailList.SelectedItem is MailEntry entry && entry.Mail != null)
            {
                string preview = $"From: {entry.Mail.From}\nTo: {entry.Mail.To}\nSubject: {entry.Mail.Subject}\nDate: {entry.Mail.DateTime}\n\n{entry.Mail.Body}";
                MailPreview.Text = preview;
            }
            else
            {
                MailPreview.Text = "";
            }
        }

        private void ComposeButton_Click(object sender, RoutedEventArgs e)
        {
            // TODO: Open compose dialog
        }

        private void ConnectButton_Click(object sender, RoutedEventArgs e)
        {
            broker.Dispatch(1, "WinlinkSync", null, store: false);
        }

        #endregion
    }
}
