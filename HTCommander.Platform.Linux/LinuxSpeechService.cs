/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;

namespace HTCommander.Platform.Linux
{
    /// <summary>
    /// Linux TTS using espeak-ng. Falls back gracefully if not installed.
    /// </summary>
    public class LinuxSpeechService : ISpeechService
    {
        private string _selectedVoice = null;
        private bool _available;

        public LinuxSpeechService()
        {
            _available = CheckEspeakAvailable();
        }

        public bool IsAvailable => _available;

        public string[] GetVoices()
        {
            if (!_available) return Array.Empty<string>();

            try
            {
                var psi = new ProcessStartInfo("espeak-ng", "--voices")
                {
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                var voices = new List<string>();
                string line;
                bool headerSkipped = false;

                while ((line = process.StandardOutput.ReadLine()) != null)
                {
                    if (!headerSkipped) { headerSkipped = true; continue; }
                    // Format: "Pty Language  Age/Gender VoiceName   File ..."
                    var parts = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 4)
                    {
                        voices.Add(parts[3]); // Voice name
                    }
                }

                process.WaitForExit(5000);
                return voices.ToArray();
            }
            catch (Exception)
            {
                return Array.Empty<string>();
            }
        }

        public void SelectVoice(string voiceName)
        {
            _selectedVoice = voiceName;
        }

        public byte[] SynthesizeToWav(string text, int sampleRate)
        {
            if (!_available) return null;

            try
            {
                string tempFile = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".wav");
                try
                {
                    // Sanitize voice name to prevent argument injection
                    string safeVoice = _selectedVoice != null ? System.Text.RegularExpressions.Regex.Replace(_selectedVoice, @"[^a-zA-Z0-9_\-+]", "") : null;
                    // Use ArgumentList for safe argument passing (no shell interpretation)
                    var psi = new ProcessStartInfo("espeak-ng")
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardError = true
                    };
                    if (!string.IsNullOrEmpty(safeVoice))
                    {
                        psi.ArgumentList.Add("-v");
                        psi.ArgumentList.Add(safeVoice);
                    }
                    psi.ArgumentList.Add("-s");
                    psi.ArgumentList.Add("110");
                    psi.ArgumentList.Add("-w");
                    psi.ArgumentList.Add(tempFile);
                    psi.ArgumentList.Add(text);

                    using var process = Process.Start(psi);
                    process.WaitForExit(10000);

                    if (File.Exists(tempFile))
                    {
                        byte[] wavData;
                        try { wavData = File.ReadAllBytes(tempFile); }
                        catch (FileNotFoundException) { return null; }
                        catch (IOException) { return null; }
                        if (wavData.Length < 44) return wavData;

                        // Read source sample rate from WAV header (bytes 24-27, little-endian)
                        int srcRate = wavData[24] | (wavData[25] << 8) | (wavData[26] << 16) | (wavData[27] << 24);

                        if (srcRate != sampleRate && srcRate > 0)
                        {
                            // Resample PCM from srcRate to sampleRate using linear interpolation
                            // WAV header: 44 bytes, 16-bit mono PCM
                            int srcSamples = (wavData.Length - 44) / 2;
                            int dstSamples = (int)((long)srcSamples * sampleRate / srcRate);
                            byte[] resampled = new byte[44 + dstSamples * 2];

                            // Copy and update WAV header
                            Array.Copy(wavData, 0, resampled, 0, 44);
                            int dataSize = dstSamples * 2;
                            int fileSize = dataSize + 36;
                            resampled[4] = (byte)(fileSize & 0xFF);
                            resampled[5] = (byte)((fileSize >> 8) & 0xFF);
                            resampled[6] = (byte)((fileSize >> 16) & 0xFF);
                            resampled[7] = (byte)((fileSize >> 24) & 0xFF);
                            resampled[24] = (byte)(sampleRate & 0xFF);
                            resampled[25] = (byte)((sampleRate >> 8) & 0xFF);
                            resampled[26] = (byte)((sampleRate >> 16) & 0xFF);
                            resampled[27] = (byte)((sampleRate >> 24) & 0xFF);
                            int byteRate = sampleRate * 2; // 16-bit mono
                            resampled[28] = (byte)(byteRate & 0xFF);
                            resampled[29] = (byte)((byteRate >> 8) & 0xFF);
                            resampled[30] = (byte)((byteRate >> 16) & 0xFF);
                            resampled[31] = (byte)((byteRate >> 24) & 0xFF);
                            resampled[40] = (byte)(dataSize & 0xFF);
                            resampled[41] = (byte)((dataSize >> 8) & 0xFF);
                            resampled[42] = (byte)((dataSize >> 16) & 0xFF);
                            resampled[43] = (byte)((dataSize >> 24) & 0xFF);

                            // Linear interpolation resample
                            double ratio = (double)srcRate / sampleRate;
                            for (int i = 0; i < dstSamples; i++)
                            {
                                double srcPos = i * ratio;
                                int srcIdx = (int)srcPos;
                                double frac = srcPos - srcIdx;

                                short s0 = GetSample(wavData, 44, srcIdx, srcSamples);
                                short s1 = GetSample(wavData, 44, srcIdx + 1, srcSamples);
                                short interpolated = (short)(s0 + (s1 - s0) * frac);

                                int dstOffset = 44 + i * 2;
                                resampled[dstOffset] = (byte)(interpolated & 0xFF);
                                resampled[dstOffset + 1] = (byte)((interpolated >> 8) & 0xFF);
                            }

                            return resampled;
                        }

                        return wavData;
                    }
                }
                finally
                {
                    try { File.Delete(tempFile); } catch { }
                }
            }
            catch (Exception) { }

            return null;
        }

        private static short GetSample(byte[] wav, int headerSize, int index, int totalSamples)
        {
            if (index < 0) index = 0;
            if (index >= totalSamples) index = totalSamples - 1;
            int offset = headerSize + index * 2;
            return (short)(wav[offset] | (wav[offset + 1] << 8));
        }

        private static bool CheckEspeakAvailable()
        {
            try
            {
                var psi = new ProcessStartInfo("espeak-ng", "--version")
                {
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var process = Process.Start(psi);
                process.WaitForExit(3000);
                return process.ExitCode == 0;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
