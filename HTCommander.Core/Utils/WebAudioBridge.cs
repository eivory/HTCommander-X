/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    /// <summary>
    /// WebSocket audio bridge for mobile PTT and bidirectional audio streaming.
    /// RX: Radio PCM (32kHz) → resample 48kHz → WebSocket binary → browser Web Audio API
    /// TX: Browser mic (48kHz) → WebSocket binary → resample 32kHz → TransmitVoicePCM
    /// Protocol: 0x01+PCM=audio, 0x02=PTT start, 0x03=PTT stop, 0x04=PTT rejected, 0x05=PTT acquired
    /// </summary>
    public class WebAudioBridge : IDisposable
    {
        private DataBrokerClient broker;
        private readonly ConcurrentDictionary<Guid, WebSocket> clients = new ConcurrentDictionary<Guid, WebSocket>();
        private readonly ConcurrentDictionary<Guid, long> clientLastAudioTime = new ConcurrentDictionary<Guid, long>();
        private const int MaxAudioFramesPerSecond = 200; // Rate limit per client
        private const int MaxClients = 20; // Maximum concurrent WebSocket audio clients
        private volatile int activeRadioId = -1;
        private Guid? pttOwner = null;
        private Timer pttSilenceTimer;
        private Timer pttTimeoutTimer;
        private long lastAudioFromPttOwner;
        private const int PttTimeoutMs = 30000; // Auto-release PTT after 30s of no audio
        private readonly object pttLock = new object();

        public WebAudioBridge()
        {
            broker = new DataBrokerClient();
            broker.Subscribe(1, "ConnectedRadios", OnConnectedRadiosChanged);
            broker.Subscribe(DataBroker.AllDevices, "AudioDataAvailable", OnAudioDataAvailable);
        }

        private void OnConnectedRadiosChanged(int deviceId, string name, object data)
        {
            activeRadioId = GetFirstConnectedRadioId();
        }

        private void OnAudioDataAvailable(int deviceId, string name, object data)
        {
            if (clients.IsEmpty) return;
            if (deviceId < 100) return;

            try
            {
                // Only forward RX audio (Transmit == false)
                var transmitProp = data?.GetType().GetProperty("Transmit");
                if (transmitProp != null)
                {
                    object transmitVal = transmitProp.GetValue(data);
                    if (transmitVal is bool isTransmit && isTransmit) return;
                }

                var dataProp = data?.GetType().GetProperty("Data");
                var lengthProp = data?.GetType().GetProperty("Length");
                if (dataProp == null || lengthProp == null) return;

                byte[] pcm = dataProp.GetValue(data) as byte[];
                int length = 0;
                object lengthVal = lengthProp.GetValue(data);
                if (lengthVal is int l) length = l;

                if (pcm == null || length <= 0) return;

                // Trim to actual length if needed
                byte[] input = pcm;
                if (length < pcm.Length)
                {
                    input = new byte[length];
                    Array.Copy(pcm, 0, input, 0, length);
                }

                // Resample 32kHz → 48kHz for browser
                byte[] resampled = AudioResampler.Resample16BitMono(input, 32000, 48000);

                // Prepend 0x01 command byte
                byte[] frame = new byte[1 + resampled.Length];
                frame[0] = 0x01;
                Array.Copy(resampled, 0, frame, 1, resampled.Length);

                // Broadcast to all connected clients
                var segment = new ArraySegment<byte>(frame);
                foreach (var kvp in clients)
                {
                    var ws = kvp.Value;
                    if (ws.State == WebSocketState.Open)
                    {
                        try
                        {
                            _ = ws.SendAsync(segment, WebSocketMessageType.Binary, true, CancellationToken.None);
                        }
                        catch { }
                    }
                }
            }
            catch { }
        }

        public async Task HandleWebSocketAsync(WebSocket ws, CancellationToken ct)
        {
            var clientId = Guid.NewGuid();

            // Authenticate if ServerBindAll is enabled
            int bindAll = DataBroker.GetValue<int>(0, "ServerBindAll", 0);
            if (bindAll == 1)
            {
                string expectedToken = DataBroker.GetValue<string>(0, "McpApiToken", "") ?? "";
                if (!string.IsNullOrEmpty(expectedToken))
                {
                    bool authenticated = false;
                    try
                    {
                        // First message must be text: "AUTH:<token>"
                        var authBuffer = new byte[1024];
                        var authResult = await ws.ReceiveAsync(new ArraySegment<byte>(authBuffer), ct);
                        if (authResult.MessageType == WebSocketMessageType.Text && authResult.Count > 5 && authResult.Count <= authBuffer.Length)
                        {
                            string authMsg = Encoding.UTF8.GetString(authBuffer, 0, authResult.Count);
                            if (authMsg.StartsWith("AUTH:"))
                            {
                                string providedToken = authMsg.Substring(5);
                                byte[] providedBytes = Encoding.UTF8.GetBytes(providedToken);
                                byte[] expectedBytes = Encoding.UTF8.GetBytes(expectedToken);
                                authenticated = CryptographicOperations.FixedTimeEquals(providedBytes, expectedBytes);
                            }
                        }
                    }
                    catch { }

                    if (!authenticated)
                    {
                        Log("WebSocket client rejected: authentication failed");
                        try { await ws.CloseAsync(WebSocketCloseStatus.PolicyViolation, "Authentication required", CancellationToken.None); } catch { }
                        try { ws.Dispose(); } catch { }
                        return;
                    }
                }
            }

            if (!clients.TryAdd(clientId, ws) || clients.Count > MaxClients)
            {
                clients.TryRemove(clientId, out _);
                Log("WebSocket client rejected: max clients reached (" + MaxClients + ")");
                try { await ws.CloseAsync(WebSocketCloseStatus.PolicyViolation, "Too many connections", CancellationToken.None); } catch { }
                try { ws.Dispose(); } catch { }
                return;
            }
            Log("WebSocket audio client connected: " + clientId.ToString().Substring(0, 8));

            try
            {
                var buffer = new byte[65536];
                while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
                {
                    WebSocketReceiveResult result;
                    try
                    {
                        result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
                    }
                    catch (WebSocketException) { break; }
                    catch (OperationCanceledException) { break; }

                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        try { await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); } catch { }
                        break;
                    }

                    if (result.MessageType != WebSocketMessageType.Binary || result.Count < 1)
                        continue;

                    byte cmd = buffer[0];

                    switch (cmd)
                    {
                        case 0x02: // PTT start
                            HandlePttStart(clientId, ws);
                            break;

                        case 0x03: // PTT stop
                            HandlePttStop(clientId);
                            break;

                        case 0x01: // Audio data
                            HandleAudioData(clientId, buffer, result.Count);
                            break;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("WebSocket client error: " + ex.Message);
            }
            finally
            {
                // Release PTT if this client held it
                HandlePttStop(clientId);
                clients.TryRemove(clientId, out _);
                Log("WebSocket audio client disconnected: " + clientId.ToString().Substring(0, 8));

                if (ws.State != WebSocketState.Closed && ws.State != WebSocketState.Aborted)
                {
                    try { ws.Abort(); } catch { }
                }
                try { ws.Dispose(); } catch { }
            }
        }

        private void HandlePttStart(Guid clientId, WebSocket ws)
        {
            lock (pttLock)
            {
                if (pttOwner != null && pttOwner != clientId)
                {
                    // PTT rejected — another client has it
                    try
                    {
                        _ = ws.SendAsync(new ArraySegment<byte>(new byte[] { 0x04 }),
                            WebSocketMessageType.Binary, true, CancellationToken.None);
                    }
                    catch { }
                    return;
                }

                pttOwner = clientId;
                lastAudioFromPttOwner = Environment.TickCount64;
                pttSilenceTimer = new Timer(DispatchSilence, null, 0, 80);
                pttTimeoutTimer = new Timer(CheckPttTimeout, clientId, PttTimeoutMs, PttTimeoutMs);
                Log("WebSocket PTT ON (client " + clientId.ToString().Substring(0, 8) + ")");
                broker?.Dispatch(1, "ExternalPttState", true, store: false);
            }

            // PTT acquired confirmation
            try
            {
                _ = ws.SendAsync(new ArraySegment<byte>(new byte[] { 0x05 }),
                    WebSocketMessageType.Binary, true, CancellationToken.None);
            }
            catch { }
        }

        private void HandlePttStop(Guid clientId)
        {
            lock (pttLock)
            {
                if (pttOwner != clientId) return;

                pttSilenceTimer?.Dispose();
                pttSilenceTimer = null;
                pttTimeoutTimer?.Dispose();
                pttTimeoutTimer = null;
                pttOwner = null;
                Log("WebSocket PTT OFF (client " + clientId.ToString().Substring(0, 8) + ")");
                broker?.Dispatch(1, "ExternalPttState", false, store: false);
            }
        }

        private void CheckPttTimeout(object state)
        {
            Guid clientId = (Guid)state;
            lock (pttLock)
            {
                if (pttOwner != clientId) return;
                if (Environment.TickCount64 - lastAudioFromPttOwner > PttTimeoutMs)
                {
                    Log("WebSocket PTT auto-released (timeout, no audio from client " + clientId.ToString().Substring(0, 8) + ")");
                    pttSilenceTimer?.Dispose();
                    pttSilenceTimer = null;
                    pttTimeoutTimer?.Dispose();
                    pttTimeoutTimer = null;
                    pttOwner = null;
                    broker?.Dispatch(1, "ExternalPttState", false, store: false);
                }
            }
        }

        private void HandleAudioData(Guid clientId, byte[] buffer, int count)
        {
            lock (pttLock)
            {
                if (pttOwner != clientId) return;
                lastAudioFromPttOwner = Environment.TickCount64;
            }

            // Rate limit: max audio frames per second per client (minimum 5ms between frames)
            // Use atomic update to prevent concurrent frames bypassing the rate limit
            long nowTicks = Environment.TickCount64;
            long minInterval = 1000 / MaxAudioFramesPerSecond;
            if (minInterval < 1) minInterval = 1;
            long lastTicks = clientLastAudioTime.GetOrAdd(clientId, 0);
            if (nowTicks - lastTicks < minInterval) return;
            if (!clientLastAudioTime.TryUpdate(clientId, nowTicks, lastTicks)) return; // Lost race, skip frame

            int radioId = activeRadioId;
            if (radioId < 0) radioId = GetFirstConnectedRadioId();
            if (radioId < 0) return;

            try
            {
                // Extract PCM data (skip command byte)
                int pcmLength = count - 1;
                if (pcmLength <= 0 || pcmLength > 19200) return; // Cap at 100ms of 48kHz stereo 16-bit

                byte[] pcm48 = new byte[pcmLength];
                Array.Copy(buffer, 1, pcm48, 0, pcmLength);

                // Resample 48kHz → 32kHz for radio
                byte[] pcm32 = AudioResampler.Resample16BitMono(pcm48, 48000, 32000);
                broker?.Dispatch(radioId, "TransmitVoicePCM", pcm32, store: false);
            }
            catch { }
        }

        private void DispatchSilence(object state)
        {
            Guid? owner;
            lock (pttLock) { owner = pttOwner; }
            if (owner == null) return;

            int radioId = activeRadioId;
            if (radioId < 0) radioId = GetFirstConnectedRadioId();
            if (radioId < 0) return;

            // 100ms of 32kHz 16-bit mono silence = 6400 bytes
            byte[] silence = new byte[6400];
            broker?.Dispatch(radioId, "TransmitVoicePCM", silence, store: false);
        }

        public void DisconnectAll()
        {
            foreach (var kvp in clients)
            {
                try
                {
                    if (kvp.Value.State == WebSocketState.Open)
                    {
                        kvp.Value.CloseAsync(WebSocketCloseStatus.NormalClosure, "Server stopping", CancellationToken.None)
                            .Wait(TimeSpan.FromSeconds(2));
                    }
                }
                catch { }
            }
            clients.Clear();

            lock (pttLock)
            {
                if (pttOwner != null)
                {
                    pttSilenceTimer?.Dispose();
                    pttSilenceTimer = null;
                    pttTimeoutTimer?.Dispose();
                    pttTimeoutTimer = null;
                    pttOwner = null;
                    broker?.Dispatch(1, "ExternalPttState", false, store: false);
                }
            }
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

        private void Log(string message)
        {
            broker?.LogInfo(message);
        }

        public void Dispose()
        {
            DisconnectAll();
            broker?.Dispose();
        }
    }
}
