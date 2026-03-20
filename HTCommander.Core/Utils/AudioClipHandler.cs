/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Collections.Generic;
using System.Threading;
using HamLib;

namespace HTCommander
{
    /// <summary>
    /// Represents an audio clip entry with metadata for display in the UI.
    /// </summary>
    public class AudioClipEntry
    {
        public string Name { get; set; }
        public string Duration { get; set; }
        public string Size { get; set; }
    }

    /// <summary>
    /// Data handler that manages audio clip files (WAV) for radio transmission.
    /// Stores clips in a local directory and supports play, delete, rename, and save operations.
    /// </summary>
    public class AudioClipHandler : IDisposable
    {
        private readonly DataBrokerClient broker;
        private readonly string clipsDir;
        private readonly object _lock = new object();
        private bool _disposed = false;
        private volatile bool _isPlaying = false;

        public AudioClipHandler()
        {
            broker = new DataBrokerClient();

            clipsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "HTCommander", "Clips");
            Directory.CreateDirectory(clipsDir);

            broker.Subscribe(DataBroker.AllDevices, "PlayAudioClip", OnPlayAudioClip);
            broker.Subscribe(DataBroker.AllDevices, "StopAudioClip", OnStopAudioClip);
            broker.Subscribe(DataBroker.AllDevices, "DeleteAudioClip", OnDeleteAudioClip);
            broker.Subscribe(DataBroker.AllDevices, "RenameAudioClip", OnRenameAudioClip);
            broker.Subscribe(DataBroker.AllDevices, "SaveAudioClip", OnSaveAudioClip);
            broker.Subscribe(DataBroker.AllDevices, "RequestAudioClips", OnRequestAudioClips);

            // Publish initial clip list
            PublishClipList();
        }

        /// <summary>
        /// Scans the clips directory for WAV files and dispatches the clip list to all devices.
        /// </summary>
        private void PublishClipList()
        {
            List<AudioClipEntry> entries = new List<AudioClipEntry>();

            try
            {
                if (Directory.Exists(clipsDir))
                {
                    string[] files = Directory.GetFiles(clipsDir, "*.wav");
                    Array.Sort(files, StringComparer.OrdinalIgnoreCase);

                    foreach (string file in files)
                    {
                        try
                        {
                            FileInfo fi = new FileInfo(file);
                            string name = Path.GetFileNameWithoutExtension(file);
                            string duration = GetWavDuration(file);
                            string size = FormatFileSize(fi.Length);
                            entries.Add(new AudioClipEntry { Name = name, Duration = duration, Size = size });
                        }
                        catch { /* skip unreadable files */ }
                    }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"AudioClipHandler.PublishClipList: {ex.Message}");
            }

            broker.Dispatch(DataBroker.AllDevices, "AudioClips", entries.ToArray(), store: true);
        }

        /// <summary>
        /// Reads a WAV file header to determine its duration.
        /// </summary>
        private static string GetWavDuration(string filePath)
        {
            try
            {
                using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read))
                using (BinaryReader br = new BinaryReader(fs))
                {
                    if (fs.Length < 44) return "0:00";

                    // RIFF header
                    br.ReadBytes(4); // "RIFF"
                    br.ReadInt32();   // file size
                    br.ReadBytes(4); // "WAVE"

                    // Find fmt chunk
                    int channels = 1;
                    int sampleRate = 32000;
                    int bitsPerSample = 16;

                    while (fs.Position < fs.Length - 8)
                    {
                        string chunkId = new string(br.ReadChars(4));
                        int chunkSize = br.ReadInt32();

                        if (chunkId == "fmt ")
                        {
                            br.ReadInt16(); // audio format
                            channels = br.ReadInt16();
                            sampleRate = br.ReadInt32();
                            br.ReadInt32(); // byte rate
                            br.ReadInt16(); // block align
                            bitsPerSample = br.ReadInt16();
                            int remaining = chunkSize - 16;
                            if (remaining > 0) br.ReadBytes(remaining);
                        }
                        else if (chunkId == "data")
                        {
                            int dataSize = chunkSize;
                            int bytesPerSample = bitsPerSample / 8;
                            if (bytesPerSample <= 0 || channels <= 0 || sampleRate <= 0) return "0:00";
                            double totalSeconds = (double)dataSize / (sampleRate * channels * bytesPerSample);
                            int minutes = (int)(totalSeconds / 60);
                            int seconds = (int)(totalSeconds % 60);
                            return $"{minutes}:{seconds:D2}";
                        }
                        else
                        {
                            if (chunkSize > 0 && fs.Position + chunkSize <= fs.Length)
                                br.ReadBytes(chunkSize);
                            else
                                break;
                        }
                    }
                }
            }
            catch { }
            return "0:00";
        }

        /// <summary>
        /// Formats a file size in bytes to a human-readable string.
        /// </summary>
        private static string FormatFileSize(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            return $"{bytes / (1024.0 * 1024.0):F1} MB";
        }

        /// <summary>
        /// Plays an audio clip by reading the WAV file, resampling to 32kHz mono, and dispatching TransmitVoicePCM chunks.
        /// </summary>
        private void OnPlayAudioClip(int deviceId, string name, object data)
        {
            if (_disposed) return;
            if (!(data is string clipName) || string.IsNullOrEmpty(clipName)) return;

            string filePath = Path.Combine(clipsDir, clipName + ".wav");
            if (!File.Exists(filePath))
            {
                broker.LogError($"Audio clip not found: {clipName}");
                return;
            }

            if (_isPlaying)
            {
                broker.LogInfo("Already playing an audio clip");
                return;
            }

            int devId = deviceId;
            _isPlaying = true;

            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    var (samples, wavParams) = WavFile.Read(filePath);

                    // Convert stereo to mono if needed
                    if (wavParams.NumChannels > 1)
                    {
                        int monoLen = samples.Length / wavParams.NumChannels;
                        short[] mono = new short[monoLen];
                        for (int i = 0; i < monoLen; i++)
                        {
                            int sum = 0;
                            for (int ch = 0; ch < wavParams.NumChannels; ch++)
                                sum += samples[i * wavParams.NumChannels + ch];
                            mono[i] = (short)(sum / wavParams.NumChannels);
                        }
                        samples = mono;
                    }

                    // Convert to byte array
                    byte[] pcmBytes = new byte[samples.Length * 2];
                    for (int i = 0; i < samples.Length; i++)
                    {
                        pcmBytes[i * 2] = (byte)(samples[i] & 0xFF);
                        pcmBytes[i * 2 + 1] = (byte)((samples[i] >> 8) & 0xFF);
                    }

                    // Resample to 32kHz if needed
                    if (wavParams.SampleRate != 32000)
                        pcmBytes = ResampleTo32kHz(pcmBytes, pcmBytes.Length, wavParams.SampleRate);

                    if (pcmBytes == null || pcmBytes.Length == 0)
                    {
                        broker.LogError($"Audio clip resample failed: {clipName}");
                        return;
                    }

                    // Apply mic gain
                    float gain = broker.GetValue<int>(devId, "MicGain", 100) / 100f;
                    ApplyGain(pcmBytes, gain);

                    // Chunk and transmit at 100ms pacing
                    int chunkSize = 6400; // 100ms at 32kHz 16-bit mono
                    int totalChunks = (pcmBytes.Length + chunkSize - 1) / chunkSize;

                    for (int c = 0; c < totalChunks; c++)
                    {
                        if (!_isPlaying || _disposed) break;

                        int offset = c * chunkSize;
                        int len = Math.Min(chunkSize, pcmBytes.Length - offset);
                        byte[] chunk = new byte[len];
                        Array.Copy(pcmBytes, offset, chunk, 0, len);

                        DataBroker.Dispatch(devId, "TransmitVoicePCM", new { Data = chunk, PlayLocally = false }, store: false);

                        Thread.Sleep(100);
                    }
                }
                catch (Exception ex)
                {
                    broker.LogError($"Error playing audio clip: {ex.Message}");
                }
                finally
                {
                    _isPlaying = false;
                }
            });
        }

        /// <summary>
        /// Stops the currently playing audio clip.
        /// </summary>
        private void OnStopAudioClip(int deviceId, string name, object data)
        {
            _isPlaying = false;
        }

        /// <summary>
        /// Deletes an audio clip file and republishes the clip list.
        /// </summary>
        private void OnDeleteAudioClip(int deviceId, string name, object data)
        {
            if (_disposed) return;
            if (!(data is string clipName) || string.IsNullOrEmpty(clipName)) return;

            try
            {
                string filePath = Path.Combine(clipsDir, clipName + ".wav");
                if (File.Exists(filePath))
                {
                    File.Delete(filePath);
                    broker.LogInfo($"Deleted audio clip: {clipName}");
                }
            }
            catch (Exception ex)
            {
                broker.LogError($"Error deleting audio clip: {ex.Message}");
            }

            PublishClipList();
        }

        /// <summary>
        /// Renames an audio clip file and republishes the clip list.
        /// </summary>
        private void OnRenameAudioClip(int deviceId, string name, object data)
        {
            if (_disposed) return;
            if (!(data is string[] names) || names.Length != 2) return;

            string oldName = names[0];
            string newName = names[1];
            if (string.IsNullOrEmpty(oldName) || string.IsNullOrEmpty(newName)) return;

            try
            {
                string oldPath = Path.Combine(clipsDir, oldName + ".wav");
                string newPath = Path.Combine(clipsDir, newName + ".wav");

                if (File.Exists(oldPath) && !File.Exists(newPath))
                {
                    File.Move(oldPath, newPath);
                    broker.LogInfo($"Renamed audio clip: {oldName} -> {newName}");
                }
                else if (File.Exists(newPath))
                {
                    broker.LogError($"Cannot rename: clip '{newName}' already exists");
                }
                else
                {
                    broker.LogError($"Cannot rename: clip '{oldName}' not found");
                }
            }
            catch (Exception ex)
            {
                broker.LogError($"Error renaming audio clip: {ex.Message}");
            }

            PublishClipList();
        }

        /// <summary>
        /// Saves audio data as a WAV file clip. Expects data to be a SaveAudioClipData object
        /// with Name (string) and PcmData (byte[]) properties, or a dynamic with those fields.
        /// </summary>
        private void OnSaveAudioClip(int deviceId, string name, object data)
        {
            if (_disposed || data == null) return;

            try
            {
                // Use reflection to get Name and PcmData from the anonymous/dynamic object
                var dataType = data.GetType();
                var nameProp = dataType.GetProperty("Name");
                var pcmProp = dataType.GetProperty("PcmData");
                var rateProp = dataType.GetProperty("SampleRate");

                if (nameProp == null || pcmProp == null) return;

                string clipName = nameProp.GetValue(data) as string;
                byte[] pcmData = pcmProp.GetValue(data) as byte[];
                int sampleRate = rateProp != null ? (int)rateProp.GetValue(data) : 32000;

                if (string.IsNullOrEmpty(clipName) || pcmData == null || pcmData.Length == 0) return;

                string filePath = Path.Combine(clipsDir, clipName + ".wav");
                WriteWavFile(filePath, pcmData, sampleRate, 1, 16);
                broker.LogInfo($"Saved audio clip: {clipName}");
            }
            catch (Exception ex)
            {
                broker.LogError($"Error saving audio clip: {ex.Message}");
            }

            PublishClipList();
        }

        /// <summary>
        /// Handles requests to republish the clip list.
        /// </summary>
        private void OnRequestAudioClips(int deviceId, string name, object data)
        {
            if (_disposed) return;
            PublishClipList();
        }

        /// <summary>
        /// Writes raw PCM data to a WAV file.
        /// </summary>
        private static void WriteWavFile(string filePath, byte[] pcmData, int sampleRate, int channels, int bitsPerSample)
        {
            int byteRate = sampleRate * channels * (bitsPerSample / 8);
            short blockAlign = (short)(channels * (bitsPerSample / 8));

            using (FileStream fs = new FileStream(filePath, FileMode.Create, FileAccess.Write))
            using (BinaryWriter bw = new BinaryWriter(fs))
            {
                // RIFF header
                bw.Write(new char[] { 'R', 'I', 'F', 'F' });
                bw.Write(36 + pcmData.Length); // file size - 8
                bw.Write(new char[] { 'W', 'A', 'V', 'E' });

                // fmt subchunk
                bw.Write(new char[] { 'f', 'm', 't', ' ' });
                bw.Write(16); // subchunk size
                bw.Write((short)1); // PCM format
                bw.Write((short)channels);
                bw.Write(sampleRate);
                bw.Write(byteRate);
                bw.Write(blockAlign);
                bw.Write((short)bitsPerSample);

                // data subchunk
                bw.Write(new char[] { 'd', 'a', 't', 'a' });
                bw.Write(pcmData.Length);
                bw.Write(pcmData);
            }
        }

        /// <summary>
        /// Resamples 16-bit PCM audio to 32kHz using linear interpolation.
        /// </summary>
        private static byte[] ResampleTo32kHz(byte[] input, int bytesRecorded, int srcRate)
        {
            if (srcRate == 32000)
            {
                byte[] copy = new byte[bytesRecorded];
                Array.Copy(input, 0, copy, 0, bytesRecorded);
                return copy;
            }
            int srcSamples = bytesRecorded / 2;
            int dstSamples = (int)((long)srcSamples * 32000 / srcRate);
            if (dstSamples <= 0) return null;
            byte[] output = new byte[dstSamples * 2];
            double ratio = (double)srcRate / 32000;
            for (int i = 0; i < dstSamples; i++)
            {
                double srcPos = i * ratio;
                int idx = (int)srcPos;
                double frac = srcPos - idx;
                int i0 = Math.Clamp(idx, 0, srcSamples - 1);
                int i1 = Math.Clamp(idx + 1, 0, srcSamples - 1);
                short s0 = (short)(input[i0 * 2] | (input[i0 * 2 + 1] << 8));
                short s1 = (short)(input[i1 * 2] | (input[i1 * 2 + 1] << 8));
                short val = (short)(s0 + (s1 - s0) * frac);
                output[i * 2] = (byte)(val & 0xFF);
                output[i * 2 + 1] = (byte)((val >> 8) & 0xFF);
            }
            return output;
        }

        /// <summary>
        /// Applies gain to 16-bit PCM audio data in place.
        /// </summary>
        private static void ApplyGain(byte[] pcm16, float gain)
        {
            if (gain == 1.0f) return;
            int samples = pcm16.Length / 2;
            for (int i = 0; i < samples; i++)
            {
                int offset = i * 2;
                short s = (short)(pcm16[offset] | (pcm16[offset + 1] << 8));
                int amplified = (int)(s * gain);
                if (amplified > 32767) amplified = 32767;
                else if (amplified < -32768) amplified = -32768;
                pcm16[offset] = (byte)(amplified & 0xFF);
                pcm16[offset + 1] = (byte)((amplified >> 8) & 0xFF);
            }
        }

        public void Dispose()
        {
            if (!_disposed)
            {
                _disposed = true;
                _isPlaying = false;
                broker?.Dispose();
            }
        }
    }
}
