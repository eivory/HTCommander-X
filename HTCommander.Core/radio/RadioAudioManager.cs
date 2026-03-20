/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;

namespace HTCommander
{
    /// <summary>
    /// Cross-platform RadioAudio implementation. Replaces the Windows-only RadioAudio class.
    /// Uses IRadioAudioTransport for Bluetooth audio socket and IAudioService for local playback.
    /// Handles SBC encode/decode, TransmitVoicePCM, and audio receive loop.
    /// </summary>
    public class RadioAudioManager : IRadioAudio
    {
        private readonly DataBrokerClient broker;
        private readonly int DeviceId;
        private readonly string MacAddress;
        private readonly IPlatformServices _platformServices;

        // Bluetooth audio transport
        private IRadioAudioTransport transport;
        private CancellationTokenSource audioLoopCts;
        private Task audioLoopTask;
        private bool running = false;
        private bool isConnecting = false;
        private readonly object connectionLock = new object();

        // SBC codec
        private SbcDecoder sbcDecoder;
        private SbcEncoder sbcEncoder;
        private SbcFrame sbcDecoderFrame;
        private SbcFrame sbcEncoderFrame;
        private int pcmInputSizePerFrame;
        private byte[] pcmFrame = new byte[16000];

        // Audio output
        private IAudioOutput audioOutput;
        private float _outputVolume = 1.0f;
        private bool _isMuted = false;

        // State
        private bool _isAudioEnabled = false;
        private bool _disposed = false;
        private DateTime audioRunStartTime;
        private bool inAudioRun = false;
        private bool inAudioRunIsTransmit = false;

        // Recording
        private WavFileWriter _recorder;
        private bool _recording;

        // Voice transmission
        private ConcurrentQueue<byte[]> pcmQueue = new ConcurrentQueue<byte[]>();
        private bool isTransmitting = false;
        private CancellationTokenSource transmissionTokenSource = null;
        private TaskCompletionSource<bool> newDataAvailable = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool PlayInputBack = false;
        private byte[] ReminderTransmitPcmAudio = null;
        private bool VoiceTransmitCancel = false;

        public bool Recording => _recording;
        public bool IsAudioEnabled => _isAudioEnabled;
        public float Volume { get => _outputVolume; set { _outputVolume = value; if (audioOutput != null) audioOutput.Volume = value; } }
        public int currentChannelId { get; set; }
        public string currentChannelName { get; set; } = "";

        public RadioAudioManager(int deviceId, string mac, IPlatformServices platformServices)
        {
            DeviceId = deviceId;
            MacAddress = mac;
            _platformServices = platformServices;
            broker = new DataBrokerClient();

            // Subscribe to DataBroker commands
            broker.Subscribe(DeviceId, "TransmitVoicePCM", OnTransmitVoicePCM);
            broker.Subscribe(DeviceId, "SetOutputVolume", OnSetOutputVolume);
            broker.Subscribe(DeviceId, "SetMute", OnSetMute);
            broker.Subscribe(DeviceId, "CancelVoiceTransmit", OnCancelVoiceTransmit);
            broker.Subscribe(DeviceId, "RecordingEnable", OnRecordingEnable);
            broker.Subscribe(DeviceId, "RecordingDisable", OnRecordingDisable);

            // Initialize output volume from stored value
            int storedVol = broker.GetValue<int>(DeviceId, "OutputAudioVolume", 100);
            _outputVolume = storedVol / 100f;
            _isMuted = broker.GetValue<bool>(DeviceId, "Mute", false);
        }

        #region DataBroker Event Handlers

        private void OnTransmitVoicePCM(int deviceId, string name, object data)
        {
            if (data == null) return;

            byte[] pcmData = null;
            bool playLocally = false;

            if (data is byte[] directPcmData)
            {
                pcmData = directPcmData;
            }
            else
            {
                try
                {
                    var type = data.GetType();
                    var dataProp = type.GetProperty("Data");
                    var playLocallyProp = type.GetProperty("PlayLocally");

                    if (dataProp != null)
                        pcmData = dataProp.GetValue(data) as byte[];
                    if (playLocallyProp != null)
                    {
                        object playValue = playLocallyProp.GetValue(data);
                        if (playValue is bool b) playLocally = b;
                    }
                }
                catch (Exception) { return; }
            }

            if (pcmData != null && pcmData.Length > 0)
            {
                TransmitVoice(pcmData, 0, pcmData.Length, playLocally);
            }
        }

        private void OnSetOutputVolume(int deviceId, string name, object data)
        {
            if (data is int vol)
            {
                _outputVolume = vol / 100f;
                if (audioOutput != null) audioOutput.Volume = _outputVolume;
                broker.Dispatch(DeviceId, "OutputAudioVolume", vol, store: true);
            }
        }

        private void OnSetMute(int deviceId, string name, object data)
        {
            if (data is bool muted)
            {
                _isMuted = muted;
                if (audioOutput != null) audioOutput.Volume = muted ? 0 : _outputVolume;
                broker.Dispatch(DeviceId, "Mute", muted, store: true);
            }
        }

        private void OnCancelVoiceTransmit(int deviceId, string name, object data)
        {
            VoiceTransmitCancel = true;
            while (pcmQueue.TryDequeue(out _)) { }
        }

        private void OnRecordingEnable(int deviceId, string name, object data)
        {
            string recordingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "HTCommander", "Recordings");
            Directory.CreateDirectory(recordingsDir);
            string filename = $"Recording_{DateTime.Now:yyyyMMdd_HHmmss}.wav";
            string path = Path.Combine(recordingsDir, filename);
            StartRecording(path);
        }

        private void OnRecordingDisable(int deviceId, string name, object data)
        {
            StopRecording();
        }

        #endregion

        #region Recording

        public void StartRecording(string path)
        {
            if (_recording) return;
            try
            {
                _recorder = new WavFileWriter(path, 32000, 16, 1);
                _recording = true;
                Debug($"Recording started: {path}");
            }
            catch (Exception ex)
            {
                Debug($"Failed to start recording: {ex.Message}");
            }
        }

        public void StopRecording()
        {
            if (!_recording) return;
            _recording = false;
            try
            {
                _recorder?.Dispose();
                _recorder = null;
                Debug("Recording stopped.");
            }
            catch (Exception ex)
            {
                Debug($"Error stopping recording: {ex.Message}");
            }
        }

        #endregion

        #region Audio Lifecycle

        public void Start()
        {
            lock (connectionLock)
            {
                if (running || isConnecting) return;
                isConnecting = true;
            }
            audioLoopTask = Task.Run(() => StartAsync());
        }

        public void Stop()
        {
            lock (connectionLock)
            {
                if (!running && audioLoopTask == null) return;
                running = false;
                try { audioLoopCts?.Cancel(); } catch (Exception ex) { Debug($"Stop.Cancel: {ex.Message}"); }
            }

            if (audioLoopTask != null)
            {
                try { audioLoopTask.Wait(TimeSpan.FromSeconds(3)); } catch (Exception ex) { Debug($"Stop.Wait: {ex.Message}"); }
            }

            lock (connectionLock)
            {
                transport?.Disconnect();
                transport?.Dispose();
                transport = null;

                try { audioLoopCts?.Dispose(); } catch (Exception ex) { Debug($"Stop.DisposeCts: {ex.Message}"); }
                audioLoopCts = null;
                audioLoopTask = null;
            }

            try { audioOutput?.Stop(); audioOutput?.Dispose(); } catch (Exception ex) { Debug($"Stop.DisposeAudioOutput: {ex.Message}"); }
            audioOutput = null;

            StopRecording();
            _isAudioEnabled = false;
            DispatchAudioStateChanged(false);
            Thread.Sleep(100);
        }

        private async void StartAsync()
        {
            CancellationToken cancellationToken;

            lock (connectionLock)
            {
                running = true;
                audioLoopCts = new CancellationTokenSource();
                cancellationToken = audioLoopCts.Token;
            }

            Debug("Connecting audio transport...");
            try
            {
                transport = _platformServices.CreateRadioAudioTransport();
                bool connected = await transport.ConnectAsync(MacAddress, cancellationToken);
                if (!connected)
                {
                    Debug("Failed to connect audio transport.");
                    lock (connectionLock) { running = false; isConnecting = false; }
                    return;
                }

                lock (connectionLock) { isConnecting = false; }
                Debug("Audio transport connected.");
            }
            catch (Exception ex)
            {
                Debug($"Audio transport connection error: {ex.Message}");
                lock (connectionLock)
                {
                    transport?.Dispose();
                    transport = null;
                    running = false;
                    isConnecting = false;
                }
                return;
            }

            // Initialize SBC codec
            sbcDecoder = new SbcDecoder();
            sbcEncoder = new SbcEncoder();

            sbcDecoderFrame = new SbcFrame
            {
                Frequency = SbcFrequency.Freq32K,
                Blocks = 16,
                Mode = SbcMode.Mono,
                AllocationMethod = SbcBitAllocationMethod.Loudness,
                Subbands = 8,
                Bitpool = 18
            };

            sbcEncoderFrame = new SbcFrame
            {
                Frequency = SbcFrequency.Freq32K,
                Blocks = 16,
                Mode = SbcMode.Mono,
                AllocationMethod = SbcBitAllocationMethod.Loudness,
                Subbands = 8,
                Bitpool = 18
            };

            pcmInputSizePerFrame = sbcEncoderFrame.Blocks * sbcEncoderFrame.Subbands * 2;

            // Initialize audio output
            try
            {
                audioOutput = _platformServices.Audio?.CreateOutput(32000, 16, 1);
                if (audioOutput != null)
                {
                    audioOutput.Volume = _isMuted ? 0 : _outputVolume;
                    audioOutput.Play();
                }
            }
            catch (Exception ex)
            {
                Debug($"Audio output init error: {ex.Message}");
            }

            _isAudioEnabled = true;
            DispatchAudioStateChanged(true);
            Debug("Audio ready, starting receive loop.");

            // Audio receive loop
            MemoryStream accumulator = new MemoryStream();
            const int MaxAccumulatorSize = 64 * 1024;
            byte[] receiveBuffer = new byte[1024];

            try
            {
                while (running && !cancellationToken.IsCancellationRequested)
                {
                    int bytesRead;
                    try
                    {
                        bytesRead = await transport.ReadAsync(receiveBuffer, 0, receiveBuffer.Length, cancellationToken);
                    }
                    catch (OperationCanceledException) { break; }
                    catch (Exception ex)
                    {
                        Debug($"Audio read error: {ex.Message}");
                        break;
                    }

                    if (bytesRead <= 0)
                    {
                        if (transport == null || !transport.IsConnected)
                        {
                            Debug("Audio transport disconnected.");
                            break;
                        }
                        await Task.Delay(10, cancellationToken);
                        continue;
                    }

                    accumulator.Write(receiveBuffer, 0, bytesRead);

                    if (accumulator.Length > MaxAccumulatorSize)
                    {
                        Debug("Audio accumulator overflow, clearing.");
                        accumulator.SetLength(0);
                        accumulator.Position = 0;
                        continue;
                    }

                    // Extract and process framed audio data
                    byte[] frame;
                    while ((frame = ExtractData(ref accumulator)) != null)
                    {
                        if (frame.Length < 2) continue;

                        int uframeLength = UnescapeBytesInPlace(frame);
                        if (uframeLength < 2) continue;

                        byte cmd = frame[0];
                        if (cmd == 0x00) // Audio data (receive)
                        {
                            if (!inAudioRun)
                            {
                                inAudioRun = true;
                                inAudioRunIsTransmit = false;
                                DispatchAudioDataStart(false);
                            }
                            DecodeSbcFrame(frame, 1, uframeLength - 1, false);
                        }
                        else if (cmd == 0x01) // End of audio / control
                        {
                            if (inAudioRun)
                            {
                                inAudioRun = false;
                                DispatchAudioDataEnd();
                            }
                        }
                        else if (cmd == 0x02) // Audio data (transmit loopback)
                        {
                            if (!inAudioRun)
                            {
                                inAudioRun = true;
                                inAudioRunIsTransmit = true;
                                DispatchAudioDataStart(true);
                            }
                            DecodeSbcFrame(frame, 1, uframeLength - 1, true);
                        }
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Debug($"Audio loop error: {ex.Message}");
            }
            finally
            {
                accumulator.Dispose();
            }

            _isAudioEnabled = false;
            DispatchAudioStateChanged(false);

            if (inAudioRun)
            {
                inAudioRun = false;
                DispatchAudioDataEnd();
            }

            Debug("Audio loop ended.");
        }

        #endregion

        #region Voice Transmission

        public bool TransmitVoice(byte[] pcmInputData, int pcmOffset, int pcmLength, bool play)
        {
            if (transport == null || !transport.IsConnected) return false;

            PlayInputBack = play;
            VoiceTransmitCancel = false;
            byte[] pcmSlice = new byte[pcmLength];
            Buffer.BlockCopy(pcmInputData, pcmOffset, pcmSlice, 0, pcmLength);
            pcmQueue.Enqueue(pcmSlice);

            if (isTransmitting) { newDataAvailable.TrySetResult(true); }
            StartTransmissionIfNeeded();
            return true;
        }

        private void StartTransmissionIfNeeded()
        {
            if (isTransmitting) return;

            Debug("Starting voice transmission...");
            isTransmitting = true;
            transmissionTokenSource = new CancellationTokenSource();
            CancellationToken token = transmissionTokenSource.Token;

            Task.Run(async () =>
            {
                DispatchVoiceTransmitStateChanged(true);
                try
                {
                    while (!token.IsCancellationRequested && !VoiceTransmitCancel)
                    {
                        if (pcmQueue.TryDequeue(out var pcmData))
                        {
                            await ProcessPcmDataAsync(pcmData, token);
                        }
                        else
                        {
                            Task delayTask = Task.Delay(100, token);
                            Task signalTask = newDataAvailable.Task;
                            Task completedTask = await Task.WhenAny(delayTask, signalTask);
                            if (completedTask == signalTask)
                            {
                                newDataAvailable = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                            }
                            else { break; }
                        }
                    }

                    if (inAudioRun)
                    {
                        inAudioRun = false;
                        DispatchAudioDataEnd();
                    }

                    // Send end audio frame
                    ReminderTransmitPcmAudio = null;
                    byte[] endAudio = { 0x7e, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e };
                    if (transport != null && transport.IsConnected)
                    {
                        try
                        {
                            await transport.WriteAsync(endAudio, 0, endAudio.Length, CancellationToken.None);
                            await transport.FlushAsync(CancellationToken.None);
                        }
                        catch (Exception) { }
                    }
                }
                finally
                {
                    DispatchVoiceTransmitStateChanged(false);
                    Debug("Voice transmission stopped.");
                    isTransmitting = false;
                }
            }, token);
        }

        private async Task ProcessPcmDataAsync(byte[] pcmData, CancellationToken token)
        {
            if (!inAudioRun)
            {
                inAudioRun = true;
                inAudioRunIsTransmit = true;
                DispatchAudioDataStart(true);
            }

            int pcmOffset = 0;
            int pcmLength = pcmData.Length;

            if (ReminderTransmitPcmAudio != null)
            {
                byte[] pcmData2 = new byte[ReminderTransmitPcmAudio.Length + pcmLength];
                Buffer.BlockCopy(ReminderTransmitPcmAudio, 0, pcmData2, 0, ReminderTransmitPcmAudio.Length);
                Buffer.BlockCopy(pcmData, 0, pcmData2, ReminderTransmitPcmAudio.Length, pcmLength);
                pcmData = pcmData2;
                pcmLength = pcmData2.Length;
                ReminderTransmitPcmAudio = null;
            }

            const int bytesPerSecond = 32000 * 2;
            var stopwatch = System.Diagnostics.Stopwatch.StartNew();
            int totalBytesSent = 0;

            while (pcmLength >= pcmInputSizePerFrame && !token.IsCancellationRequested && !VoiceTransmitCancel)
            {
                byte[] encodedSbcFrame;
                int bytesConsumed;
                if (!EncodeSbcFrame(pcmData, pcmOffset, pcmLength, out encodedSbcFrame, out bytesConsumed)) break;

                // Send the audio frame to the radio
                byte[] escaped = EscapeBytes(0, encodedSbcFrame, encodedSbcFrame.Length);
                if (transport != null && transport.IsConnected)
                {
                    await transport.WriteAsync(escaped, 0, escaped.Length, token);
                    await transport.FlushAsync(token);
                }

                // Play locally if requested
                if (PlayInputBack && audioOutput != null)
                {
                    audioOutput.AddSamples(pcmData, pcmOffset, bytesConsumed);
                }

                // Dispatch audio data for VoiceHandler
                byte[] pcmDataForEvent = new byte[bytesConsumed];
                Buffer.BlockCopy(pcmData, pcmOffset, pcmDataForEvent, 0, bytesConsumed);
                broker.Dispatch(DeviceId, "AudioDataAvailable", new
                {
                    Data = pcmDataForEvent,
                    Offset = 0,
                    Length = bytesConsumed,
                    ChannelName = currentChannelName,
                    Transmit = true
                }, store: false);

                pcmOffset += bytesConsumed;
                pcmLength -= bytesConsumed;
                totalBytesSent += bytesConsumed;

                // Real-time pacing
                double expectedMs = (totalBytesSent * 1000.0) / bytesPerSecond;
                double actualMs = stopwatch.Elapsed.TotalMilliseconds;
                if (expectedMs > actualMs + 10)
                {
                    int sleepMs = (int)(expectedMs - actualMs);
                    if (sleepMs > 0 && sleepMs < 200)
                        await Task.Delay(sleepMs, token);
                }
            }

            if (pcmLength > 0 && pcmLength < pcmInputSizePerFrame)
            {
                ReminderTransmitPcmAudio = new byte[pcmLength];
                Buffer.BlockCopy(pcmData, pcmOffset, ReminderTransmitPcmAudio, 0, pcmLength);
            }
        }

        #endregion

        #region SBC Encode/Decode

        private int DecodeSbcFrame(byte[] sbcFrame, int start, int length, bool isTransmit)
        {
            if (sbcFrame == null || sbcFrame.Length == 0) return 1;

            try
            {
                int offset = start;
                int remaining = length;
                int totalWritten = 0;

                while (remaining > 0)
                {
                    byte syncByte = sbcFrame[offset];
                    if (syncByte != 0x9C && syncByte != 0xAD) break;

                    if (remaining < SbcFrame.HeaderSize) break;
                    byte[] headerProbe = new byte[SbcFrame.HeaderSize];
                    Buffer.BlockCopy(sbcFrame, offset, headerProbe, 0, SbcFrame.HeaderSize);
                    SbcFrame probed = sbcDecoder.Probe(headerProbe);
                    if (probed == null) break;
                    int frameSize = probed.GetFrameSize();
                    if (frameSize <= 0 || frameSize > remaining) break;

                    byte[] sbcData = new byte[frameSize];
                    Buffer.BlockCopy(sbcFrame, offset, sbcData, 0, frameSize);

                    if (!sbcDecoder.Decode(sbcData, out short[] pcmLeft, out short[] pcmRight, out SbcFrame frame))
                        break;

                    if (frame.GetFrameSize() != frameSize) break;

                    int pcmBytes = pcmLeft.Length * 2;
                    if (totalWritten + pcmBytes > pcmFrame.Length)
                        Array.Resize(ref pcmFrame, totalWritten + pcmBytes);

                    Buffer.BlockCopy(pcmLeft, 0, pcmFrame, totalWritten, pcmBytes);
                    totalWritten += pcmBytes;

                    offset += frameSize;
                    remaining -= frameSize;
                }

                if (totalWritten > 0)
                {
                    // Play through local audio output
                    if (audioOutput != null && !_isMuted)
                    {
                        audioOutput.AddSamples(pcmFrame, 0, totalWritten);
                    }

                    // Write to recording file if recording
                    if (_recording && _recorder != null)
                    {
                        try { _recorder.Write(pcmFrame, 0, totalWritten); }
                        catch (Exception ex) { Debug($"DecodeSbcFrame.RecorderWrite: {ex.Message}"); }
                    }

                    // Dispatch decoded audio data for VoiceHandler
                    byte[] pcmCopy = new byte[totalWritten];
                    Buffer.BlockCopy(pcmFrame, 0, pcmCopy, 0, totalWritten);
                    broker.Dispatch(DeviceId, "AudioDataAvailable", new
                    {
                        Data = pcmCopy,
                        Offset = 0,
                        Length = totalWritten,
                        ChannelName = currentChannelName,
                        Transmit = isTransmit
                    }, store: false);

                    // Dispatch amplitude for UI
                    float maxAmplitude = 0;
                    for (int i = 0; i < totalWritten - 1; i += 2)
                    {
                        short sample = (short)(pcmFrame[i] | (pcmFrame[i + 1] << 8));
                        float abs = Math.Abs((int)sample) / 32768f;
                        if (abs > maxAmplitude) maxAmplitude = abs;
                    }
                    broker.Dispatch(DeviceId, "OutputAmplitude", maxAmplitude, store: false);
                }

                return totalWritten > 0 ? 0 : 1;
            }
            catch (Exception ex)
            {
                Debug($"SBC decode error: {ex.Message}");
                return 1;
            }
        }

        private bool EncodeSbcFrame(byte[] pcmInputData, int pcmOffset, int pcmLength, out byte[] encodedSbcFrame, out int bytesConsumed)
        {
            encodedSbcFrame = null;
            bytesConsumed = 0;
            if (pcmInputData == null || pcmLength < pcmInputSizePerFrame) return false;
            if (pcmOffset < 0 || pcmOffset >= pcmInputData.Length || pcmOffset + pcmInputSizePerFrame > pcmInputData.Length) return false;

            try
            {
                int totalToConsume = pcmLength;
                int totalGenerated = 0;
                int totalBytesConsumed = 0;
                byte[] outputBuffer = new byte[1024];
                int outputOffset = 0;

                while (totalToConsume >= pcmInputSizePerFrame && totalGenerated < 300)
                {
                    int samplesPerChannel = sbcEncoderFrame.Blocks * sbcEncoderFrame.Subbands;
                    short[] pcmSamples = new short[samplesPerChannel];
                    Buffer.BlockCopy(pcmInputData, pcmOffset + totalBytesConsumed, pcmSamples, 0, samplesPerChannel * 2);

                    byte[] sbcFrameData = sbcEncoder.Encode(pcmSamples, null, sbcEncoderFrame);
                    if (sbcFrameData == null || sbcFrameData.Length == 0) break;

                    if (outputOffset + sbcFrameData.Length > outputBuffer.Length) break;
                    Buffer.BlockCopy(sbcFrameData, 0, outputBuffer, outputOffset, sbcFrameData.Length);
                    outputOffset += sbcFrameData.Length;

                    int bytesConsumedThisRound = samplesPerChannel * 2;
                    totalToConsume -= bytesConsumedThisRound;
                    totalGenerated += sbcFrameData.Length;
                    totalBytesConsumed += bytesConsumedThisRound;
                }

                if (totalGenerated > 0)
                {
                    encodedSbcFrame = new byte[totalGenerated];
                    Buffer.BlockCopy(outputBuffer, 0, encodedSbcFrame, 0, totalGenerated);
                    bytesConsumed = totalBytesConsumed;
                    return true;
                }

                return false;
            }
            catch (Exception ex)
            {
                Debug($"SBC encode error: {ex.Message}");
                return false;
            }
        }

        #endregion

        #region Framing (0x7E escape protocol)

        private static unsafe int UnescapeBytesInPlace(byte[] buffer)
        {
            if (buffer == null || buffer.Length == 0) return 0;
            fixed (byte* pBuffer = buffer)
            {
                byte* src = pBuffer;
                byte* dst = pBuffer;
                byte* end = pBuffer + buffer.Length;
                while (src < end)
                {
                    if (*src == 0x7d)
                    {
                        src++;
                        if (src < end) { *dst = (byte)(*src ^ 0x20); dst++; } else { break; }
                    }
                    else { *dst = *src; dst++; }
                    src++;
                }
                return (int)(dst - pBuffer);
            }
        }

        private static unsafe byte[] EscapeBytes(byte cmd, byte[] b, int len)
        {
            int maxLen = 2 + len * 2;
            byte[] result = new byte[maxLen];
            fixed (byte* bPtr = b)
            fixed (byte* rPtr = result)
            {
                byte* src = bPtr;
                byte* dest = rPtr;
                *dest++ = 0x7e;
                *dest++ = cmd;
                for (int i = 0; i < len; i++)
                {
                    byte currentByte = *src++;
                    if (currentByte == 0x7d || currentByte == 0x7e)
                    {
                        *dest++ = 0x7d;
                        *dest++ = (byte)(currentByte ^ 0x20);
                    }
                    else { *dest++ = currentByte; }
                }
                *dest++ = 0x7e;
                int finalLen = (int)(dest - rPtr);
                Array.Resize(ref result, finalLen);
            }
            return result;
        }

        private byte[] ExtractData(ref MemoryStream inputStream)
        {
            while (true)
            {
                if (inputStream.Length < 2) return null;

                if (!inputStream.TryGetBuffer(out ArraySegment<byte> bufferSegment))
                    bufferSegment = new ArraySegment<byte>(inputStream.GetBuffer(), 0, (int)inputStream.Length);

                byte[] buffer = bufferSegment.Array;
                int bufferLength = bufferSegment.Count;
                int start = -1, end = -1;

                int scanFrom = 0;
                if (bufferLength >= 2 && buffer[0] == 0x7e && buffer[1] == 0x7e)
                    scanFrom = 1;

                for (int i = scanFrom; i < bufferLength; i++)
                {
                    if (buffer[i] == 0x7e)
                    {
                        if (start == -1) { start = i; }
                        else { end = i; break; }
                    }
                }

                if (start != -1 && end != -1 && end > start + 1)
                {
                    int dataLength = end - start - 1;
                    byte[] extractedData = new byte[dataLength];
                    Buffer.BlockCopy(buffer, start + 1, extractedData, 0, dataLength);

                    int remaining = bufferLength - (end + 1);
                    if (remaining > 0)
                    {
                        Buffer.BlockCopy(buffer, end + 1, buffer, 0, remaining);
                        inputStream.SetLength(remaining);
                        inputStream.Position = remaining;
                    }
                    else
                    {
                        inputStream.SetLength(0);
                        inputStream.Position = 0;
                    }
                    return extractedData;
                }
                else if (start != -1 && end != -1 && end == start + 1)
                {
                    int remaining = bufferLength - end;
                    Buffer.BlockCopy(buffer, end, buffer, 0, remaining);
                    inputStream.SetLength(remaining);
                    inputStream.Position = remaining;
                    continue;
                }
                else if (start > 0)
                {
                    int remaining = bufferLength - start;
                    Buffer.BlockCopy(buffer, start, buffer, 0, remaining);
                    inputStream.SetLength(remaining);
                    inputStream.Position = remaining;
                    continue;
                }
                else if (start == -1)
                {
                    inputStream.SetLength(0);
                    inputStream.Position = 0;
                    return null;
                }
                else
                {
                    inputStream.Position = inputStream.Length;
                    return null;
                }
            }
        }

        #endregion

        #region Dispatch Helpers

        private void Debug(string msg) { broker.Dispatch(1, "LogInfo", $"[RadioAudio/{DeviceId}]: {msg}", store: false); }
        private void DispatchAudioStateChanged(bool enabled) { broker.Dispatch(DeviceId, "AudioState", enabled, store: true); }
        private void DispatchVoiceTransmitStateChanged(bool transmitting) { broker.Dispatch(DeviceId, "VoiceTransmitStateChanged", transmitting, store: false); }
        private void DispatchAudioDataStart(bool transmit)
        {
            audioRunStartTime = DateTime.Now;
            broker.Dispatch(DeviceId, "AudioDataStart", new { StartTime = audioRunStartTime, ChannelName = currentChannelName, Transmit = transmit }, store: false);
        }
        private void DispatchAudioDataEnd()
        {
            broker.Dispatch(DeviceId, "AudioDataEnd", new { StartTime = audioRunStartTime, Transmit = inAudioRunIsTransmit }, store: false);
            broker.Dispatch(DeviceId, "OutputAmplitude", 0f, store: false);
        }

        #endregion

        #region IDisposable

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;

            StopRecording();
            Stop();
            broker?.Dispose();
        }

        #endregion
    }
}
