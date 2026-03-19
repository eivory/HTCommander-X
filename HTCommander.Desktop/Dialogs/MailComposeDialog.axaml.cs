using System;
using System.Collections.Generic;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace HTCommander.Desktop.Dialogs
{
    public partial class MailComposeDialog : Window
    {
        public WinLinkMail ResultMail { get; private set; }
        public bool Sent { get; private set; }
        public bool SavedAsDraft { get; private set; }

        private WinLinkMail existingMail;

        public MailComposeDialog()
        {
            InitializeComponent();
        }

        public MailComposeDialog(WinLinkMail mail) : this()
        {
            existingMail = mail;
            if (mail != null)
            {
                ToBox.Text = mail.To ?? "";
                CcBox.Text = mail.Cc ?? "";
                SubjectBox.Text = mail.Subject ?? "";
                BodyBox.Text = mail.Body ?? "";
            }
        }

        private WinLinkMail BuildMail(string mailbox)
        {
            string callsign = DataBroker.GetValue<string>(0, "CallSign", "");
            string from = callsign;
            if (DataBroker.GetValue<int>(0, "WinlinkUseStationId", 0) == 1)
            {
                int sid = DataBroker.GetValue<int>(0, "StationId", 0);
                if (sid > 0) from = $"{callsign}-{sid}";
            }

            var mail = existingMail != null ? existingMail : new WinLinkMail();
            mail.From = from;
            mail.To = ToBox.Text?.Trim() ?? "";
            mail.Cc = CcBox.Text?.Trim() ?? "";
            mail.Subject = SubjectBox.Text?.Trim() ?? "";
            mail.Body = BodyBox.Text ?? "";
            mail.DateTime = DateTime.UtcNow;
            mail.Mailbox = mailbox;
            if (string.IsNullOrEmpty(mail.MID))
                mail.MID = Guid.NewGuid().ToString("N").Substring(0, 12).ToUpper();
            if (mail.Attachments == null)
                mail.Attachments = new List<WinLinkMailAttachement>();
            return mail;
        }

        private void SendButton_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(ToBox.Text)) return;
            if (string.IsNullOrWhiteSpace(SubjectBox.Text)) return;

            ResultMail = BuildMail("Outbox");
            Sent = true;
            Close();
        }

        private void SaveDraftButton_Click(object sender, RoutedEventArgs e)
        {
            ResultMail = BuildMail("Draft");
            SavedAsDraft = true;
            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();
    }
}
