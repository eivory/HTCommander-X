/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Net.Sockets;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace HTCommander
{
    public class SmtpServer
    {
        private DataBrokerClient broker;
        private TcpListener listener;
        private Thread listenerThread;
        private bool running;
        public readonly int Port;
        private const int MaxSessions = 10;
        private List<SmtpSession> sessions = new List<SmtpSession>();
        private int globalAuthFailures = 0;
        private long lastAuthFailureReset = Environment.TickCount64;
        private readonly object authRateLock = new object();
        private const int MaxGlobalAuthFailuresPerMinute = 20;

        public SmtpServer(int port)
        {
            this.Port = port;
            this.broker = new DataBrokerClient();
        }

        internal bool CheckGlobalAuthRateLimit()
        {
            lock (authRateLock)
            {
                long now = Environment.TickCount64;
                if (now - lastAuthFailureReset > 60000)
                {
                    globalAuthFailures = 0;
                    lastAuthFailureReset = now;
                }
                return globalAuthFailures < MaxGlobalAuthFailuresPerMinute;
            }
        }

        internal void RecordAuthFailure()
        {
            lock (authRateLock) { globalAuthFailures++; }
        }

        public void Start()
        {
            try
            {
                listener = new TcpListener(IPAddress.Loopback, Port);
                listener.Start();
                running = true;
                listenerThread = new Thread(ListenerLoop);
                listenerThread.IsBackground = true;
                listenerThread.Start();
                broker.LogInfo($"SMTP server started on port {Port}");
            }
            catch (Exception)
            {
                // SMTP server failed to start
            }
        }

        public void Stop()
        {
            running = false;
            if (listener != null) listener.Stop();
            lock (sessions)
            {
                SmtpSession[] sessionArray = new SmtpSession[sessions.Count];
                sessions.CopyTo(sessionArray, 0);
                foreach (var session in sessionArray)
                {
                    session.Close();
                }
                sessions.Clear();
            }
            broker.LogInfo("SMTP server stopped");
        }

        private void ListenerLoop()
        {
            while (running)
            {
                try
                {
                    TcpClient client = listener.AcceptTcpClient();
                    lock (sessions)
                    {
                        if (sessions.Count >= MaxSessions)
                        {
                            client.Close();
                            continue;
                        }
                    }
                    SmtpSession session = new SmtpSession(this, client, broker);
                    lock (sessions)
                    {
                        sessions.Add(session);
                    }
                    Thread sessionThread = new Thread(session.Run);
                    sessionThread.IsBackground = true;
                    sessionThread.Start();
                }
                catch (Exception)
                {
                    if (running) Thread.Sleep(100);
                }
            }
        }

        public void RemoveSession(SmtpSession session)
        {
            lock (sessions)
            {
                sessions.Remove(session);
            }
        }
    }

    public class SmtpSession
    {
        private SmtpServer server;
        private DataBrokerClient broker;
        private TcpClient client;
        private StreamReader reader;
        private StreamWriter writer;
        private string mailFrom;
        private List<string> rcptTo;
        private bool inDataMode;
        private StringBuilder dataBuffer;

        public SmtpSession(SmtpServer server, TcpClient client, DataBrokerClient broker)
        {
            this.server = server;
            this.client = client;
            this.broker = broker;
            this.reader = new StreamReader(client.GetStream(), Encoding.UTF8);
            this.writer = new StreamWriter(client.GetStream(), Encoding.UTF8) { AutoFlush = true };
            this.rcptTo = new List<string>();
            this.inDataMode = false;
            this.dataBuffer = new StringBuilder();
        }

        public void Run()
        {
            try
            {
                broker.LogInfo("SMTP: Client connected from " + ((System.Net.IPEndPoint)client.Client.RemoteEndPoint).Address);

                string greeting = "220 localhost ESMTP\r\n";
                byte[] greetingBytes = Encoding.UTF8.GetBytes(greeting);
                client.GetStream().Write(greetingBytes, 0, greetingBytes.Length);
                client.GetStream().Flush();

                // Read with timeout to detect disconnects
                NetworkStream stream = client.GetStream();
                stream.ReadTimeout = 30000; // 30 second timeout

                byte[] buffer = new byte[4096];
                StringBuilder lineBuffer = new StringBuilder();

                while (true)
                {
                    int bytesRead = 0;
                    try
                    {
                        bytesRead = stream.Read(buffer, 0, buffer.Length);
                    }
                    catch (IOException)
                    {
                        // Read timeout or connection closed
                        break;
                    }

                    if (bytesRead == 0)
                    {
                        break;
                    }

                    string received = Encoding.UTF8.GetString(buffer, 0, bytesRead);

                    lineBuffer.Append(received);

                    // Process complete lines
                    string bufferedText = lineBuffer.ToString();
                    int newlinePos;

                    while ((newlinePos = bufferedText.IndexOf('\n')) >= 0)
                    {
                        string line = bufferedText.Substring(0, newlinePos).TrimEnd('\r', '\n');
                        bufferedText = bufferedText.Substring(newlinePos + 1);

                        if (!string.IsNullOrWhiteSpace(line) || inDataMode)
                        {
                            if (inDataMode)
                            {
                                ProcessDataLine(line);
                            }
                            else
                            {
                                ProcessCommand(line);
                            }
                        }
                    }

                    lineBuffer.Clear();
                    // Check buffer sizes before append to prevent temporary memory spikes
                    if (bufferedText.Length > 10 * 1024 * 1024 || dataBuffer.Length > 10 * 1024 * 1024)
                    {
                        SendResponse("552 Too much data");
                        return;
                    }
                    lineBuffer.Append(bufferedText);

                    if (lineBuffer.Length > 10 * 1024 * 1024 || dataBuffer.Length > 10 * 1024 * 1024)
                    {
                        SendResponse("552 Too much data");
                        return;
                    }
                }
            }
            catch (Exception)
            {
                // SMTP session error
            }
            finally
            {
                Close();
            }
        }

        private void ProcessCommand(string line)
        {
            string[] parts = line.Split(new[] { ' ' }, 2);
            if (parts.Length == 0) return;

            string command = parts[0].ToUpper();
            string args = parts.Length > 1 ? parts[1] : "";

            try
            {
                switch (command)
                {
                    case "HELO":
                    case "EHLO":
                        HandleHelo(command, args);
                        break;
                    case "AUTH":
                        HandleAuth(args);
                        break;
                    case "MAIL":
                        if (!authenticated)
                        {
                            SendResponse("530 Authentication required");
                            break;
                        }
                        HandleMailFrom(args);
                        break;
                    case "RCPT":
                        if (!authenticated)
                        {
                            SendResponse("530 Authentication required");
                            break;
                        }
                        HandleRcptTo(args);
                        break;
                    case "DATA":
                        if (!authenticated)
                        {
                            SendResponse("530 Authentication required");
                            break;
                        }
                        HandleData();
                        break;
                    case "RSET":
                        HandleRset();
                        break;
                    case "NOOP":
                        SendResponse("250 OK");
                        break;
                    case "QUIT":
                        HandleQuit();
                        break;
                    default:
                        SendResponse("500 Command not recognized");
                        break;
                }
            }
            catch (Exception ex)
            {
                broker.LogInfo($"SMTP command error: {ex.Message}");
                SendResponse("451 Requested action aborted");
            }
        }

        private bool authenticated = false;
        private int authAttempts = 0;
        private const int MaxAuthAttempts = 5;

        private void HandleHelo(string command, string args)
        {
            if (command == "EHLO")
            {
                // RFC 5321 compliant EHLO response with extensions
                SendResponse("250-localhost");
                SendResponse("250-AUTH PLAIN");
                SendResponse("250-8BITMIME");
                SendResponse("250-SIZE 10240000");
                SendResponse("250 HELP");
            }
            else
            {
                // HELO response
                SendResponse("250 localhost");
            }
        }

        private void HandleAuth(string args)
        {
            if (authAttempts >= MaxAuthAttempts || !server.CheckGlobalAuthRateLimit())
            {
                SendResponse("421 Too many authentication attempts");
                Close();
                throw new InvalidOperationException("Max auth attempts exceeded");
            }
            authAttempts++;

            // AUTH PLAIN <base64> — base64 decodes to \0username\0password
            string[] authParts = args.Split(new[] { ' ' }, 2);
            if (authParts.Length < 2 || !authParts[0].Equals("PLAIN", StringComparison.OrdinalIgnoreCase))
            {
                SendResponse("504 Unrecognized authentication type");
                return;
            }

            try
            {
                byte[] decoded = Convert.FromBase64String(authParts[1].Trim());
                // PLAIN format: \0username\0password
                string decodedStr = Encoding.UTF8.GetString(decoded);
                string[] parts2 = decodedStr.Split('\0');
                // parts2[0] = authorization identity (usually empty), parts2[1] = username, parts2[2] = password
                string user = parts2.Length > 1 ? parts2[1] : "";
                string pass = parts2.Length > 2 ? parts2[2] : "";

                if (!IsValidUsername(user))
                {
                    SendResponse("535 Authentication failed");
                    return;
                }

                string winlinkPassword = DataBroker.GetValue<string>(0, "WinlinkPassword", "") ?? "";
                if (string.IsNullOrEmpty(winlinkPassword))
                {
                    // No password configured — reject authentication
                    SendResponse("535 Authentication failed");
                    return;
                }

                // Constant-time comparison to prevent timing attacks
                byte[] passBytes = Encoding.UTF8.GetBytes(pass);
                byte[] expectedBytes = Encoding.UTF8.GetBytes(winlinkPassword);
                if (System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(passBytes, expectedBytes))
                {
                    authenticated = true;
                    SendResponse("235 Authentication successful");
                }
                else
                {
                    server.RecordAuthFailure();
                    SendResponse("535 Authentication failed");
                }
            }
            catch (FormatException)
            {
                server.RecordAuthFailure();
                SendResponse("501 Malformed AUTH data");
            }
        }

        private void HandleMailFrom(string args)
        {
            // Parse MAIL FROM:<address>
            if (!args.ToUpper().StartsWith("FROM:"))
            {
                SendResponse("501 Syntax error in MAIL FROM command");
                return;
            }

            string address = args.Substring(5).Trim();
            if (address.StartsWith("<") && address.EndsWith(">"))
            {
                address = address.Substring(1, address.Length - 2);
            }

            mailFrom = address;
            rcptTo.Clear();
            SendResponse("250 OK");
        }

        private void HandleRcptTo(string args)
        {
            // Parse RCPT TO:<address>
            if (!args.ToUpper().StartsWith("TO:"))
            {
                SendResponse("501 Syntax error in RCPT TO command");
                return;
            }

            string address = args.Substring(3).Trim();
            if (address.StartsWith("<") && address.EndsWith(">"))
            {
                address = address.Substring(1, address.Length - 2);
            }

            if (rcptTo.Count >= 100)
            {
                SendResponse("452 Too many recipients");
                return;
            }
            rcptTo.Add(address);
            SendResponse("250 OK");
        }

        private void HandleData()
        {
            if (string.IsNullOrEmpty(mailFrom) || rcptTo.Count == 0)
            {
                SendResponse("503 Bad sequence of commands");
                return;
            }

            SendResponse("354 Start mail input; end with <CRLF>.<CRLF>");
            inDataMode = true;
            dataBuffer.Clear();
        }

        private void ProcessDataLine(string line)
        {
            // Check for end of data (single dot on a line)
            if (line == ".")
            {
                inDataMode = false;
                ProcessEmailData();
                return;
            }

            // Handle byte-stuffing (remove leading dot if present)
            if (line.StartsWith(".."))
            {
                line = line.Substring(1);
            }

            dataBuffer.AppendLine(line);
        }

        private bool IsValidUsername(string user)
        {
            string callsign = DataBroker.GetValue<string>(0, "CallSign", "");
            int stationId = DataBroker.GetValue<int>(0, "StationId", 0);

            if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(callsign))
                return false;

            user = user.ToUpper();
            callsign = callsign.ToUpper();
            string callsignWithId = callsign;
            if (stationId > 0)
                callsignWithId += "-" + stationId;

            return user == callsign ||
                   user == callsignWithId ||
                   user == callsign + "@WINLINK.ORG" ||
                   user == callsignWithId + "@WINLINK.ORG";
        }

        private void ProcessEmailData()
        {
            try
            {
                string emailData = dataBuffer.ToString();

                // Parse email headers and body
                string from = mailFrom;
                string to = string.Join("; ", rcptTo);
                string cc = "";
                string subject = "";
                string body = "";
                DateTime dateTime = DateTime.Now;

                // Simple header parsing
                StringReader sr = new StringReader(emailData);
                string line;
                bool inHeaders = true;
                StringBuilder bodyBuilder = new StringBuilder();

                while ((line = sr.ReadLine()) != null)
                {
                    if (inHeaders)
                    {
                        if (string.IsNullOrWhiteSpace(line))
                        {
                            inHeaders = false;
                            continue;
                        }

                        if (line.StartsWith("From:", StringComparison.OrdinalIgnoreCase))
                        {
                            from = line.Substring(5).Trim();
                            // Remove angle brackets if present
                            if (from.Contains("<") && from.Contains(">"))
                            {
                                int start = from.IndexOf('<') + 1;
                                int end = from.IndexOf('>');
                                from = from.Substring(start, end - start);
                            }
                        }
                        else if (line.StartsWith("To:", StringComparison.OrdinalIgnoreCase))
                        {
                            to = line.Substring(3).Trim();
                        }
                        else if (line.StartsWith("Cc:", StringComparison.OrdinalIgnoreCase))
                        {
                            cc = line.Substring(3).Trim();
                        }
                        else if (line.StartsWith("Subject:", StringComparison.OrdinalIgnoreCase))
                        {
                            subject = line.Substring(8).Trim();
                        }
                        else if (line.StartsWith("Date:", StringComparison.OrdinalIgnoreCase))
                        {
                            string dateStr = line.Substring(5).Trim();
                            DateTime.TryParse(dateStr, out dateTime);
                        }
                    }
                    else
                    {
                        bodyBuilder.AppendLine(line);
                    }
                }

                body = bodyBuilder.ToString().TrimEnd();

                // Create new email and add to Outbox
                WinLinkMail mail = new WinLinkMail
                {
                    MID = Guid.NewGuid().ToString("N").Substring(0, 12).ToUpper(),
                    From = from,
                    To = to,
                    Cc = cc,
                    Subject = subject,
                    Body = body,
                    DateTime = dateTime,
                    Mailbox = "Outbox"
                };

                DataBroker.Dispatch(1, "MailReceived", mail, store: false);

                broker.LogInfo($"SMTP: Email queued to Outbox - From: {from}, To: {to}, Subject: {subject}");
                SendResponse("250 OK: Message accepted for delivery");
            }
            catch (Exception)
            {
                // Error processing email
                SendResponse("554 Transaction failed");
            }
            finally
            {
                // Reset for next message
                mailFrom = null;
                rcptTo.Clear();
                dataBuffer.Clear();
            }
        }

        private void HandleRset()
        {
            mailFrom = null;
            rcptTo.Clear();
            dataBuffer.Clear();
            inDataMode = false;
            SendResponse("250 OK");
        }

        private void HandleQuit()
        {
            SendResponse("221 Bye");
            Close();
            // Throw exception to exit the read loop gracefully
            throw new InvalidOperationException("Client requested QUIT");
        }

        private void SendResponse(string response)
        {
            writer.WriteLine(response);
        }

        public void Close()
        {
            try
            {
                client?.Close();
            }
            catch { }
            server.RemoveSession(this);
        }
    }
}
