/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License").
See http://www.apache.org/licenses/LICENSE-2.0
*/

// Protocol: AGW Packet Engine (AGWPE) TCP API
// Reference: https://www.on7lds.net/42/sites/default/files/AGWPEAPI.HTM

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    /// <summary>
    /// Cross-platform AGWPE server that integrates with DataBroker.
    /// Ported from src/AgwpeServerClass.cs — replaces MainForm references with DataBroker dispatch.
    /// </summary>
    /// <summary>
    /// Represents the 36-byte AGW PE API frame header.
    /// </summary>
    public class AgwpeFrame
    {
        public byte Port { get; set; }
        public byte[] Reserved1 { get; set; } = new byte[3];
        public byte DataKind { get; set; }
        public byte Reserved2 { get; set; }
        public byte PID { get; set; }
        public byte Reserved3 { get; set; }
        public string CallFrom { get; set; }
        public string CallTo { get; set; }
        public uint DataLen { get; set; }
        public uint User { get; set; }
        public byte[] Data { get; set; } = Array.Empty<byte>();

        public static async Task<AgwpeFrame> ReadAsync(NetworkStream stream, CancellationToken ct)
        {
            byte[] header = new byte[36];
            int read = 0;
            while (read < header.Length)
            {
                int n = await stream.ReadAsync(header, read, header.Length - read, ct);
                if (n == 0) throw new IOException("Disconnected");
                read += n;
            }

            var frame = new AgwpeFrame
            {
                Port = header[0],
                Reserved1 = header.Skip(1).Take(3).ToArray(),
                DataKind = header[4],
                Reserved2 = header[5],
                PID = header[6],
                Reserved3 = header[7],
                CallFrom = Encoding.ASCII.GetString(header, 8, 10).TrimEnd('\0', ' '),
                CallTo = Encoding.ASCII.GetString(header, 18, 10).TrimEnd('\0', ' '),
                DataLen = BitConverter.ToUInt32(header, 28),
                User = BitConverter.ToUInt32(header, 32)
            };

            if (frame.DataLen > 65536)
                throw new IOException("AGWPE frame DataLen exceeds maximum (65536 bytes)");

            if (frame.DataLen > 0)
            {
                frame.Data = new byte[frame.DataLen];
                int offset = 0;
                while (offset < frame.Data.Length)
                {
                    int n = await stream.ReadAsync(frame.Data, offset, (int)frame.DataLen - offset, ct);
                    if (n == 0) throw new IOException("Disconnected before payload complete");
                    offset += n;
                }
            }

            return frame;
        }

        public byte[] ToBytes()
        {
            byte[] buffer = new byte[36 + (Data?.Length ?? 0)];
            buffer[0] = Port;
            Array.Copy(Reserved1, 0, buffer, 1, 3);
            buffer[4] = DataKind;
            buffer[5] = Reserved2;
            buffer[6] = PID;
            buffer[7] = Reserved3;

            Encoding.ASCII.GetBytes((CallFrom ?? "").PadRight(10, '\0'), 0, 10, buffer, 8);
            Encoding.ASCII.GetBytes((CallTo ?? "").PadRight(10, '\0'), 0, 10, buffer, 18);

            BitConverter.GetBytes(Data?.Length ?? 0).CopyTo(buffer, 28);
            BitConverter.GetBytes(User).CopyTo(buffer, 32);

            if (Data != null && Data.Length > 0)
                Array.Copy(Data, 0, buffer, 36, Data.Length);

            return buffer;
        }
    }

    public class AgwpeServer : IDisposable
    {
        private DataBrokerClient broker;
        private TcpListener listener;
        private readonly ConcurrentDictionary<Guid, AgwpeTcpClientHandler> clients = new ConcurrentDictionary<Guid, AgwpeTcpClientHandler>();
        private readonly ConcurrentDictionary<Guid, HashSet<string>> registeredCallsigns = new ConcurrentDictionary<Guid, HashSet<string>>();
        private CancellationTokenSource cts;
        private Task serverTask;
        private int port;
        private bool running = false;
        private bool bindAll = false;
        private string sessionTo = null;
        private string sessionFrom = null;

        public AgwpeServer()
        {
            broker = new DataBrokerClient();
            broker.Subscribe(0, "AgwpeServerEnabled", OnSettingChanged);
            broker.Subscribe(0, "AgwpeServerPort", OnSettingChanged);
            broker.Subscribe(0, "ServerBindAll", OnSettingChanged);
            broker.Subscribe(DataBroker.AllDevices, "UniqueDataFrame", OnUniqueDataFrame);

            // Auto-start if enabled
            int enabled = broker.GetValue<int>(0, "AgwpeServerEnabled", 0);
            if (enabled == 1)
            {
                port = broker.GetValue<int>(0, "AgwpeServerPort", 8000);
                bindAll = broker.GetValue<int>(0, "ServerBindAll", 0) == 1;
                Start();
            }
        }

        private void OnSettingChanged(int deviceId, string name, object data)
        {
            int enabled = broker.GetValue<int>(0, "AgwpeServerEnabled", 0);
            int newPort = broker.GetValue<int>(0, "AgwpeServerPort", 8000);
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
                Log($"AGWPE server started on port {port}" + (bindAll ? " (all interfaces - WARNING: no authentication, any LAN client can send packets)" : " (loopback only)"));
            }
            catch (Exception ex)
            {
                Log($"AGWPE server start failed: {ex.Message}");
                running = false;
            }
        }

        private void Stop()
        {
            if (!running) return;
            Log("AGWPE server stopping...");
            running = false;
            cts?.Cancel();

            try { listener?.Stop(); } catch { }

            try { serverTask?.Wait(TimeSpan.FromSeconds(3)); }
            catch (AggregateException) { }
            catch (OperationCanceledException) { }

            foreach (var client in clients.Values.ToList())
            {
                try { client.Dispose(); } catch { }
            }
            clients.Clear();
            registeredCallsigns.Clear();

            cts?.Dispose();
            cts = null;
            serverTask = null;
            Log("AGWPE server stopped");
        }

        private const int MaxClients = 20;

        private async Task AcceptClientsAsync(CancellationToken ct)
        {
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    TcpClient tcpClient = await listener.AcceptTcpClientAsync();
                    if (clients.Count >= MaxClients)
                    {
                        Log("AGWPE connection rejected: max clients reached");
                        tcpClient.Close();
                        continue;
                    }
                    var handler = new AgwpeTcpClientHandler(tcpClient, this);
                    if (clients.TryAdd(handler.Id, handler))
                    {
                        Log($"AGWPE client connected: {handler.EndPoint}");
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
                Log($"AGWPE accept loop error: {ex.Message}");
            }
        }

        private void OnUniqueDataFrame(int deviceId, string name, object data)
        {
            if (data is not TncDataFragment fragment) return;
            if (!fragment.incoming) return;

            // Convert to AGWPE monitoring frame and broadcast
            try
            {
                AX25Packet p = AX25Packet.DecodeAX25Packet(fragment);
                if (p == null || p.addresses.Count < 2 || p.type != AX25Packet.FrameType.U_FRAME_UI) return;

                DateTime now = DateTime.Now;
                string str = "1:Fm " + p.addresses[1].CallSignWithId + " To " + p.addresses[0].CallSignWithId +
                    " <UI pid=" + p.pid + " Len=" + p.data.Length + " >[" +
                    now.Hour.ToString("D2") + ":" + now.Minute.ToString("D2") + ":" + now.Second.ToString("D2") + "]\r" + p.dataStr;
                if (!str.EndsWith("\r") && !str.EndsWith("\n")) str += "\r";

                byte[] strBytes = Encoding.ASCII.GetBytes(str);
                var frame = new AgwpeFrame
                {
                    Port = 0,
                    DataKind = 0x55, // 'U'
                    CallFrom = p.addresses[1].CallSignWithId,
                    CallTo = p.addresses[0].CallSignWithId,
                    DataLen = (uint)strBytes.Length,
                    Data = strBytes
                };

                BroadcastMonitoringFrame(frame);
            }
            catch (Exception ex) { Log($"AGWPE OnUniqueDataFrame error: {ex.Message}"); }
        }

        private void BroadcastMonitoringFrame(AgwpeFrame frame)
        {
            var data = frame.ToBytes();
            foreach (var client in clients.Values)
            {
                if (client.SendMonitoringFrames) client.EnqueueSend(data);
            }
        }

        internal void OnFrameReceived(Guid clientId, AgwpeFrame frame)
        {
            Log($"AGWPE received: Kind={(char)frame.DataKind} From={frame.CallFrom} To={frame.CallTo} Len={frame.DataLen}");
            ProcessAgwCommand(clientId, frame);
        }

        private void ProcessAgwCommand(Guid clientId, AgwpeFrame frame)
        {
            switch ((char)frame.DataKind)
            {
                case 'G': // Get channel info
                {
                    var channelInfo = Encoding.UTF8.GetBytes("1;Port1 HTCommander;");
                    SendFrame(clientId, new AgwpeFrame
                    {
                        DataKind = (byte)'G',
                        Data = channelInfo
                    });
                    break;
                }
                case 'R': // Version
                {
                    var versionData = new byte[8];
                    BitConverter.GetBytes(2000).CopyTo(versionData, 0); // Major
                    BitConverter.GetBytes(0).CopyTo(versionData, 4);    // Minor (was "Release")
                    SendFrame(clientId, new AgwpeFrame
                    {
                        DataKind = (byte)'R',
                        Data = versionData
                    });
                    break;
                }
                case 'X': // Register callsign
                {
                    bool success = false;
                    if (!string.IsNullOrWhiteSpace(frame.CallFrom))
                    {
                        Guid? existing = GetClientIdByCallsign(frame.CallFrom);
                        if (existing == null || existing == Guid.Empty)
                        {
                            var set = registeredCallsigns.GetOrAdd(clientId, _ => new HashSet<string>());
                            lock (set) { set.Add(frame.CallFrom); }
                            Log($"AGWPE registered callsign '{frame.CallFrom}'");
                            success = true;
                        }
                    }
                    SendFrame(clientId, new AgwpeFrame
                    {
                        Port = frame.Port,
                        DataKind = (byte)'X',
                        CallFrom = frame.CallFrom,
                        DataLen = 1,
                        Data = new byte[] { (byte)(success ? 1 : 0) }
                    });
                    break;
                }
                case 'x': // Unregister callsign
                {
                    if (!string.IsNullOrWhiteSpace(frame.CallFrom))
                    {
                        if (registeredCallsigns.TryGetValue(clientId, out var set))
                        {
                            lock (set) { set.Remove(frame.CallFrom); }
                            Log($"AGWPE unregistered callsign '{frame.CallFrom}'");
                        }
                    }
                    break;
                }
                case 'm': // Toggle monitoring
                {
                    if (clients.TryGetValue(clientId, out var clientHandler))
                    {
                        clientHandler.SendMonitoringFrames = !clientHandler.SendMonitoringFrames;
                        Log($"AGWPE monitoring {(clientHandler.SendMonitoringFrames ? "enabled" : "disabled")}");
                    }
                    break;
                }
                case 'M': // Send UNPROTO (UI frame)
                {
                    Log($"AGWPE UNPROTO from {frame.CallFrom} to {frame.CallTo}, {frame.DataLen} bytes");

                    var addresses = new List<AX25Address>
                    {
                        AX25Address.GetAddress(frame.CallTo),
                        AX25Address.GetAddress(frame.CallFrom)
                    };
                    var packet = new AX25Packet(addresses, frame.Data, DateTime.Now);

                    // Get first connected radio and transmit
                    int radioId = GetFirstConnectedRadioId();
                    if (radioId >= 0)
                    {
                        broker.Dispatch(radioId, "TransmitDataFrame", packet, store: false);

                        // Echo back as 'T' frame
                        DateTime now = DateTime.Now;
                        string str = (frame.Port + 1) + ":Fm " + packet.addresses[1].CallSignWithId + " To " + packet.addresses[0].CallSignWithId +
                            " <UI pid=" + packet.pid + " Len=" + packet.data.Length + " >[" +
                            now.Hour.ToString("D2") + ":" + now.Minute.ToString("D2") + ":" + now.Second.ToString("D2") + "]\r" +
                            Encoding.ASCII.GetString(frame.Data);
                        if (!str.EndsWith("\r") && !str.EndsWith("\n")) str += "\r";

                        SendFrame(clientId, new AgwpeFrame
                        {
                            Port = frame.Port,
                            DataKind = (byte)'T',
                            CallFrom = packet.addresses[0].CallSignWithId,
                            CallTo = packet.addresses[1].CallSignWithId,
                            DataLen = (uint)packet.data.Length,
                            Data = Encoding.ASCII.GetBytes(str)
                        });
                    }
                    break;
                }
                case 'D': // Send data in session
                {
                    int radioId = GetFirstConnectedRadioId();
                    if (radioId >= 0)
                    {
                        Log($"AGWPE data frame from {frame.CallFrom} to {frame.CallTo}, {frame.DataLen} bytes");
                        broker.Dispatch(radioId, "TransmitDataFrame", frame.Data, store: false);
                    }
                    break;
                }
                case 'C': // Connect request
                {
                    sessionFrom = frame.CallFrom;
                    sessionTo = frame.CallTo;
                    Log($"AGWPE connect request: {sessionFrom} -> {sessionTo}");

                    int radioId = GetFirstConnectedRadioId();
                    if (radioId < 0)
                    {
                        SendFrame(clientId, new AgwpeFrame
                        {
                            Port = frame.Port,
                            DataKind = (byte)'d',
                            CallFrom = frame.CallTo,
                            CallTo = frame.CallFrom
                        });
                    }
                    break;
                }
                case 'd': // Disconnect request
                {
                    Log("AGWPE disconnect request");
                    SendFrame(clientId, new AgwpeFrame
                    {
                        Port = frame.Port,
                        DataKind = (byte)'d',
                        CallFrom = frame.CallTo,
                        CallTo = frame.CallFrom
                    });
                    break;
                }
                case 'Y': // Outstanding frames query
                {
                    SendFrame(clientId, new AgwpeFrame
                    {
                        Port = frame.Port,
                        DataKind = (byte)'Y',
                        CallFrom = frame.CallFrom,
                        CallTo = frame.CallTo,
                        DataLen = 4,
                        Data = BitConverter.GetBytes(0)
                    });
                    break;
                }
                case 'K': // Raw AX.25 frame
                case 'k':
                {
                    int radioId = GetFirstConnectedRadioId();
                    if (radioId >= 0 && frame.Data != null && frame.Data.Length > 0)
                    {
                        broker.Dispatch(radioId, "TransmitDataFrame", frame.Data, store: false);
                    }
                    break;
                }
                default:
                    Log($"AGWPE unknown command '{(char)frame.DataKind}' (0x{frame.DataKind:X2})");
                    break;
            }
        }

        private void SendFrame(Guid clientId, AgwpeFrame frame)
        {
            if (clients.TryGetValue(clientId, out var client))
            {
                client.EnqueueSend(frame.ToBytes());
            }
        }

        private Guid? GetClientIdByCallsign(string callsign)
        {
            foreach (var kvp in registeredCallsigns)
            {
                lock (kvp.Value)
                {
                    if (kvp.Value.Contains(callsign)) return kvp.Key;
                }
            }
            return null;
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
            registeredCallsigns.TryRemove(clientId, out _);
            if (clients.TryRemove(clientId, out _))
            {
                Log($"AGWPE client disconnected: {clientId}");
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

    /// <summary>
    /// Per-client handler for the AGWPE server.
    /// </summary>
    internal class AgwpeTcpClientHandler : IDisposable
    {
        private readonly TcpClient client;
        private readonly NetworkStream stream;
        private readonly AgwpeServer server;
        private readonly ConcurrentQueue<byte[]> sendQueue = new ConcurrentQueue<byte[]>();
        private readonly CancellationTokenSource cts = new CancellationTokenSource();

        public Guid Id { get; }
        public IPEndPoint EndPoint => (IPEndPoint)client.Client.RemoteEndPoint;
        public bool SendMonitoringFrames = false;

        public AgwpeTcpClientHandler(TcpClient client, AgwpeServer server)
        {
            Id = Guid.NewGuid();
            this.client = client;
            this.stream = client.GetStream();
            this.server = server;

            try
            {
                Task.Run(ProcessSendQueueAsync, cts.Token);
                Task.Run(ReceiveLoopAsync, cts.Token);
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        private const int MaxSendQueueSize = 1000;

        public void EnqueueSend(byte[] data)
        {
            if (sendQueue.Count >= MaxSendQueueSize) return; // Drop frames when queue is full
            sendQueue.Enqueue(data);
        }

        private async Task ProcessSendQueueAsync()
        {
            while (!cts.Token.IsCancellationRequested)
            {
                try
                {
                    if (sendQueue.TryDequeue(out var data))
                        await stream.WriteAsync(data, 0, data.Length, cts.Token);
                    else
                        await Task.Delay(50, cts.Token);
                }
                catch (OperationCanceledException) { break; }
                catch (IOException) { Disconnect(); break; }
                catch (Exception) { Disconnect(); break; }
            }
        }

        private async Task ReceiveLoopAsync()
        {
            while (!cts.Token.IsCancellationRequested)
            {
                try
                {
                    var frame = await AgwpeFrame.ReadAsync(stream, cts.Token);
                    server.OnFrameReceived(Id, frame);
                }
                catch (OperationCanceledException) { break; }
                catch (IOException) { break; }
                catch (Exception) { break; }
            }
            Disconnect();
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
