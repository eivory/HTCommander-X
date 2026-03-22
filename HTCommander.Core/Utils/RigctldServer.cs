/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

// Protocol: Hamlib rigctld text protocol
// Reference: https://hamlib.sourceforge.net/manuals/hamlib.html

using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    /// <summary>
    /// Cross-platform rigctld TCP server for PTT and rig control.
    /// Used by fldigi, WSJT-X, Direwolf, VaraFM (via Hamlib mode).
    /// Follows the AgwpeServer DataBroker integration pattern.
    /// </summary>
    public class RigctldServer : IDisposable
    {
        private DataBrokerClient broker;
        private TcpListener listener;
        private readonly ConcurrentDictionary<Guid, RigctldClientHandler> clients = new ConcurrentDictionary<Guid, RigctldClientHandler>();
        private const int MaxClients = 10;
        private CancellationTokenSource cts;
        private Task serverTask;
        private int port;
        private volatile bool running = false;
        private bool bindAll = false;
        private volatile bool pttActive = false;
        private Timer pttSilenceTimer;
        private Timer pttTimeoutTimer;
        private const int PttTimeoutMs = 30000;
        private readonly object pttLock = new object();
        private long cachedFrequency = 145500000; // Accessed from multiple threads; reads/writes are non-atomic on 32-bit but acceptable for cached display value
        private volatile int activeRadioId = -1;

        public bool PttActive => pttActive;
        public long CachedFrequency => cachedFrequency;

        public RigctldServer()
        {
            broker = new DataBrokerClient();
            broker.Subscribe(0, "RigctldServerEnabled", OnSettingChanged);
            broker.Subscribe(0, "RigctldServerPort", OnSettingChanged);
            broker.Subscribe(0, "ServerBindAll", OnSettingChanged);
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);
            broker.Subscribe(DataBroker.AllDevices, "Channels", OnChannelsChanged);
            broker.Subscribe(DataBroker.AllDevices, "Settings", OnSettingsChanged);

            int enabled = broker.GetValue<int>(0, "RigctldServerEnabled", 0);
            if (enabled == 1)
            {
                port = broker.GetValue<int>(0, "RigctldServerPort", 4532);
                bindAll = broker.GetValue<int>(0, "ServerBindAll", 0) == 1;
                Start();
            }
        }

        private void OnSettingChanged(int deviceId, string name, object data)
        {
            int enabled = broker.GetValue<int>(0, "RigctldServerEnabled", 0);
            int newPort = broker.GetValue<int>(0, "RigctldServerPort", 4532);
            bool newBindAll = broker.GetValue<int>(0, "ServerBindAll", 0) == 1;

            if (enabled == 1)
            {
                if (running && (newPort != port || newBindAll != bindAll))
                {
                    Stop();
                    port = newPort;
                    bindAll = newBindAll;
                    Start();
                }
                else if (!running)
                {
                    port = newPort;
                    bindAll = newBindAll;
                    Start();
                }
            }
            else
            {
                if (running) Stop();
            }
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            activeRadioId = GetFirstConnectedRadioId();
        }

        private void OnChannelsChanged(int deviceId, string name, object data)
        {
            if (deviceId < 100) return;
            try
            {
                if (data is RadioChannelInfo[] channels && channels.Length > 0)
                {
                    if (channels[0].rx_freq > 0) cachedFrequency = channels[0].rx_freq;
                }
            }
            catch { }
        }

        private void OnSettingsChanged(int deviceId, string name, object data)
        {
            if (deviceId < 100) return;
            try
            {
                if (data is RadioSettings settings)
                {
                    if (settings.vfo1_mod_freq_x > 0) cachedFrequency = settings.vfo1_mod_freq_x;
                }
            }
            catch { }
        }

        private void Start()
        {
            if (running) return;
            try
            {
                cts = new CancellationTokenSource();
                listener = new TcpListener(bindAll ? IPAddress.Any : IPAddress.Loopback, port);
                listener.Start();
                running = true;
                serverTask = Task.Run(() => AcceptClientsAsync(cts.Token), cts.Token);
                Log($"Rigctld server started on port {port}" + (bindAll ? " (all interfaces - WARNING: no authentication, any LAN client can control PTT and frequency)" : " (loopback only)"));
            }
            catch (Exception ex)
            {
                Log($"Rigctld server start failed: {ex.Message}");
                running = false;
            }
        }

        private void Stop()
        {
            if (!running) return;
            Log("Rigctld server stopping...");
            running = false;
            SetPtt(false);
            cts?.Cancel();

            try { listener?.Stop(); } catch { }

            try { serverTask?.Wait(TimeSpan.FromSeconds(3)); }
            catch (AggregateException) { }
            catch (OperationCanceledException) { }

            foreach (var client in clients.Values)
            {
                try { client.Dispose(); } catch { }
            }
            clients.Clear();

            cts?.Dispose();
            cts = null;
            serverTask = null;
            Log("Rigctld server stopped");
        }

        private async Task AcceptClientsAsync(CancellationToken ct)
        {
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    TcpClient tcpClient = await listener.AcceptTcpClientAsync();
                    if (clients.Count >= MaxClients)
                    {
                        Log("Rigctld connection rejected: max clients reached");
                        tcpClient.Close();
                        continue;
                    }
                    var handler = new RigctldClientHandler(tcpClient, this);
                    if (clients.TryAdd(handler.Id, handler))
                    {
                        Log($"Rigctld client connected: {handler.EndPoint}");
                    }
                    else
                    {
                        tcpClient.Close();
                    }
                }
            }
            catch (SocketException ex) when (ex.SocketErrorCode == SocketError.Interrupted) { }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Log($"Rigctld accept loop error: {ex.Message}");
            }
        }

        internal string ProcessCommand(string line)
        {
            if (string.IsNullOrWhiteSpace(line)) return "";

            line = line.Trim();

            // Handle extended protocol prefix
            bool extended = line.StartsWith("+");
            if (extended) line = line.Substring(1).TrimStart();

            // \dump_state — required by WSJT-X on connect
            if (line == "\\dump_state")
            {
                return GetDumpState();
            }

            // Parse command and arguments
            string cmd;
            string args = "";
            if (line.Length == 1)
            {
                cmd = line;
            }
            else if (line[0] == '\\')
            {
                // Long-form command like \set_ptt
                int spaceIdx = line.IndexOf(' ');
                if (spaceIdx > 0)
                {
                    cmd = line.Substring(0, spaceIdx);
                    args = line.Substring(spaceIdx + 1).Trim();
                }
                else
                {
                    cmd = line;
                }
            }
            else
            {
                cmd = line.Substring(0, 1);
                args = line.Length > 1 ? line.Substring(1).Trim() : "";
            }

            switch (cmd)
            {
                case "T":
                case "\\set_ptt":
                {
                    int pttVal = 0;
                    int.TryParse(args, out pttVal);
                    SetPtt(pttVal != 0);
                    return extended ? $"set_ptt: {pttVal}\nRPRT 0\n" : "RPRT 0\n"; // pttVal is int, safe from injection
                }
                case "t":
                case "\\get_ptt":
                    return extended ? $"get_ptt:\nPTT: {(pttActive ? 1 : 0)}\n" : $"{(pttActive ? 1 : 0)}\n";

                case "f":
                case "\\get_freq":
                    return extended ? $"get_freq:\nFreq: {cachedFrequency}\n" : $"{cachedFrequency}\n";

                case "F":
                case "\\set_freq":
                {
                    long freq;
                    if (long.TryParse(args, out freq) && freq > 0 && freq <= int.MaxValue)
                    {
                        cachedFrequency = freq;
                        SetRadioFrequency(freq, "A");
                    }
                    string safeArgs = args?.Replace("\r", "").Replace("\n", "").Replace("\u2028", "").Replace("\u2029", "") ?? "";
                    return extended ? $"set_freq: {safeArgs}\nRPRT 0\n" : "RPRT 0\n";
                }

                case "m":
                case "\\get_mode":
                    return extended ? "get_mode:\nMode: FM\nPassband: 15000\n" : "FM\n15000\n";

                case "M":
                case "\\set_mode":
                    { string safeArgs2 = args?.Replace("\r", "").Replace("\n", "").Replace("\u2028", "").Replace("\u2029", "") ?? ""; return extended ? $"set_mode: {safeArgs2}\nRPRT 0\n" : "RPRT 0\n"; }

                case "v":
                case "\\get_vfo":
                    return extended ? "get_vfo:\nVFO: VFOA\n" : "VFOA\n";

                case "V":
                case "\\set_vfo":
                    { string safeArgs3 = args?.Replace("\r", "").Replace("\n", "").Replace("\u2028", "").Replace("\u2029", "") ?? ""; return extended ? $"set_vfo: {safeArgs3}\nRPRT 0\n" : "RPRT 0\n"; }

                case "s":
                case "\\get_split_vfo":
                    return extended ? "get_split_vfo:\nSplit: 0\nTX VFO: VFOA\n" : "0\nVFOA\n";

                case "q":
                case "\\quit":
                    return null; // Signal disconnect

                default:
                    Log($"Rigctld unknown command: {line}");
                    return extended ? $"{cmd}:\nRPRT -1\n" : "RPRT -1\n";
            }
        }

        private string GetDumpState()
        {
            var sb = new StringBuilder();
            sb.AppendLine("2");           // Protocol version
            sb.AppendLine("2");           // Rig model (Dummy)
            sb.AppendLine("2");           // ITU region
            // Frequency range: 100kHz - 1.3GHz
            sb.AppendLine("100000.000000 1300000000.000000 0x40000000 -1 -1 0x16000003 0x3");
            sb.AppendLine("0 0 0 0 0 0 0");  // End freq range
            // TX range
            sb.AppendLine("100000.000000 1300000000.000000 0x40000000 -1 -1 0x16000003 0x3");
            sb.AppendLine("0 0 0 0 0 0 0");  // End TX range
            sb.AppendLine("0x40000000 1");    // FM mode
            sb.AppendLine("0 0");             // End mode list
            sb.AppendLine("0");               // Max RIT
            sb.AppendLine("0");               // Max XIT
            sb.AppendLine("0");               // Max IF shift
            sb.AppendLine("0");               // Announces
            sb.AppendLine("0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"); // Preamp
            sb.AppendLine("0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"); // Attenuator
            sb.AppendLine("0x1e000000");      // has_get_func
            sb.AppendLine("0x1e000000");      // has_set_func
            sb.AppendLine("0x40000000");      // has_get_level
            sb.AppendLine("0x40000000");      // has_set_level
            sb.AppendLine("0");               // has_get_parm
            sb.AppendLine("0");               // has_set_parm
            sb.AppendLine("vfo_op=0x0");
            sb.AppendLine("done");
            return sb.ToString();
        }

        private void SetRadioFrequency(long freqHz, string vfo)
        {
            // Validate frequency fits in int (max ~2.1 GHz) to prevent integer overflow
            if (freqHz <= 0 || freqHz > int.MaxValue) return;

            int radioId = activeRadioId;
            if (radioId < 0) radioId = GetFirstConnectedRadioId();
            if (radioId < 0) return;

            var info = broker.GetValue<RadioDevInfo>(radioId, "Info", null);
            if (info == null) return;

            int scratchIndex = info.channel_count - 1;
            var scratch = new RadioChannelInfo();
            scratch.channel_id = scratchIndex;
            scratch.rx_freq = (int)freqHz;
            scratch.tx_freq = (int)freqHz;
            scratch.rx_mod = Radio.RadioModulationType.FM;
            scratch.tx_mod = Radio.RadioModulationType.FM;
            scratch.bandwidth = Radio.RadioBandwidthType.WIDE;
            scratch.name_str = "QF";

            broker.Dispatch(radioId, "WriteChannel", scratch, store: false);
            string eventName = (vfo == "B") ? "ChannelChangeVfoB" : "ChannelChangeVfoA";
            broker.Dispatch(radioId, eventName, scratchIndex, store: false);
            Log($"Rigctld set_freq: {freqHz} Hz → scratch channel {scratchIndex} on VFO {vfo}");
        }

        internal void SetPtt(bool on)
        {
            lock (pttLock)
            {
                bool wasActive = pttActive;
                pttActive = on;

                if (on && !wasActive)
                {
                    // Start dispatching silence to keep radio keyed
                    pttSilenceTimer = new Timer(DispatchSilence, null, 0, 80);
                    pttTimeoutTimer = new Timer(PttTimeoutCallback, null, PttTimeoutMs, Timeout.Infinite);
                    Log("Rigctld PTT ON");
                    broker?.Dispatch(1, "ExternalPttState", true, store: false);
                }
                else if (!on && wasActive)
                {
                    pttSilenceTimer?.Dispose();
                    pttSilenceTimer = null;
                    pttTimeoutTimer?.Dispose();
                    pttTimeoutTimer = null;
                    Log("Rigctld PTT OFF");
                    broker?.Dispatch(1, "ExternalPttState", false, store: false);
                }
            }
        }

        private void PttTimeoutCallback(object state)
        {
            Log("Rigctld PTT auto-released after timeout");
            SetPtt(false);
        }

        private void DispatchSilence(object state)
        {
            if (!pttActive) return;
            int radioId = activeRadioId;
            if (radioId < 0) radioId = GetFirstConnectedRadioId();
            if (radioId < 0) return;

            // 100ms of 32kHz 16-bit mono silence = 6400 bytes
            byte[] silence = new byte[6400];
            broker?.Dispatch(radioId, "TransmitVoicePCM", silence, store: false);
        }

        private int GetFirstConnectedRadioId()
        {
            var radios = broker.GetValue<object>(1, "ConnectedRadios", null);
            if (radios is System.Collections.IEnumerable enumerable)
            {
                foreach (var item in enumerable)
                {
                    if (item == null) continue;
                    var prop = item.GetType().GetProperty("DeviceId");
                    if (prop != null)
                    {
                        object val = prop.GetValue(item);
                        if (val is int id && id > 0) return id;
                    }
                }
            }
            return -1;
        }

        internal void RemoveClient(Guid clientId)
        {
            if (clients.TryRemove(clientId, out _))
            {
                Log($"Rigctld client disconnected: {clientId}");
                // Release PTT if no clients remain (prevents stuck transmit on disconnect)
                if (pttActive && clients.IsEmpty)
                {
                    Log("Rigctld: releasing PTT (last client disconnected)");
                    SetPtt(false);
                }
            }
        }

        private void Log(string message)
        {
            broker?.LogInfo(message);
        }

        public void Dispose()
        {
            Stop();
            broker?.Dispose();
        }
    }

    internal class RigctldClientHandler : IDisposable
    {
        private readonly TcpClient client;
        private readonly NetworkStream stream;
        private readonly RigctldServer server;
        private readonly CancellationTokenSource cts = new CancellationTokenSource();

        public Guid Id { get; }
        public IPEndPoint EndPoint => (IPEndPoint)client.Client.RemoteEndPoint;

        public RigctldClientHandler(TcpClient client, RigctldServer server)
        {
            Id = Guid.NewGuid();
            this.client = client;
            this.stream = client.GetStream();
            this.server = server;

            Task.Run(ReceiveLoopAsync, cts.Token);
        }

        private async Task ReceiveLoopAsync()
        {
            var writer = new StreamWriter(stream, Encoding.ASCII) { AutoFlush = true };

            try
            {
                // Use a length-limited line reader to prevent unbounded memory allocation
                // from oversized lines (ReadLineAsync buffers the entire line first)
                while (!cts.Token.IsCancellationRequested)
                {
                    string line = await ReadLineLimitedAsync(stream, 1024, cts.Token);
                    if (line == null) break; // Disconnected or oversized

                    string response = server.ProcessCommand(line);
                    if (response == null) break; // quit command

                    if (response.Length > 0)
                    {
                        await writer.WriteAsync(response);
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (Exception) { }

            Disconnect();
        }

        /// <summary>
        /// Reads a line from the stream with a maximum byte limit to prevent unbounded memory allocation.
        /// Returns null on disconnect or if the line exceeds maxLength.
        /// </summary>
        private static async Task<string> ReadLineLimitedAsync(System.Net.Sockets.NetworkStream stream, int maxLength, CancellationToken ct)
        {
            var sb = new System.Text.StringBuilder(128);
            byte[] buf = new byte[1];
            // Idle timeout: disconnect clients that stall without sending data
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(30000); // 30 second idle timeout
            while (!timeoutCts.Token.IsCancellationRequested)
            {
                int read = await stream.ReadAsync(buf, 0, 1, timeoutCts.Token);
                if (read == 0) return sb.Length > 0 ? sb.ToString() : null;
                char c = (char)buf[0];
                if (c == '\n') return sb.ToString().TrimEnd('\r');
                sb.Append(c);
                if (sb.Length > maxLength) return null; // Oversized — disconnect
            }
            return null;
        }

        private void Disconnect()
        {
            if (!cts.IsCancellationRequested) cts.Cancel();
            server.RemoveClient(Id);
        }

        public void Dispose()
        {
            Disconnect();
            stream?.Dispose();
            client?.Dispose();
            cts?.Dispose();
        }
    }
}
