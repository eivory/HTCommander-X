/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HTCommander.Platform.Linux
{
    /// <summary>
    /// Linux audio service using PortAudio via P/Invoke.
    /// Supports PipeWire, PulseAudio, and ALSA backends.
    /// </summary>
    public class LinuxAudioService : IAudioService
    {
        private bool _initialized = false;

        public LinuxAudioService()
        {
            try
            {
                PortAudioNative.Pa_Initialize();
                _initialized = true;
            }
            catch (Exception) { }
        }

        public Task<bool> RequestPermissionsAsync() => Task.FromResult(true);

        public IAudioOutput CreateOutput(int sampleRate, int bitsPerSample, int channels)
        {
            return new LinuxAudioOutput(sampleRate, bitsPerSample, channels);
        }

        public IAudioInput CreateInput(int sampleRate, int bitsPerSample, int channels)
        {
            return new LinuxAudioInput(sampleRate, bitsPerSample, channels);
        }

        public string[] GetOutputDevices()
        {
            if (!_initialized) return Array.Empty<string>();
            var devices = new List<string>();
            int count = PortAudioNative.Pa_GetDeviceCount();
            for (int i = 0; i < count; i++)
            {
                IntPtr infoPtr = PortAudioNative.Pa_GetDeviceInfo(i);
                if (infoPtr == IntPtr.Zero) continue;
                var info = Marshal.PtrToStructure<PortAudioNative.PaDeviceInfo>(infoPtr);
                if (info.maxOutputChannels > 0)
                {
                    string name = Marshal.PtrToStringUTF8(info.name);
                    devices.Add(name);
                }
            }
            return devices.ToArray();
        }

        public string[] GetInputDevices()
        {
            if (!_initialized) return Array.Empty<string>();
            var devices = new List<string>();
            int count = PortAudioNative.Pa_GetDeviceCount();
            for (int i = 0; i < count; i++)
            {
                IntPtr infoPtr = PortAudioNative.Pa_GetDeviceInfo(i);
                if (infoPtr == IntPtr.Zero) continue;
                var info = Marshal.PtrToStructure<PortAudioNative.PaDeviceInfo>(infoPtr);
                if (info.maxInputChannels > 0)
                {
                    string name = Marshal.PtrToStringUTF8(info.name);
                    devices.Add(name);
                }
            }
            return devices.ToArray();
        }

        public void OnPause() { }
        public void OnResume() { }

        public void Dispose()
        {
            if (_initialized)
            {
                PortAudioNative.Pa_Terminate();
                _initialized = false;
            }
        }
    }

    public class LinuxAudioOutput : IAudioOutput
    {
        private IntPtr stream = IntPtr.Zero;
        private float _volume = 1.0f;
        private string _deviceId;
        private int _sampleRate;
        private int _bitsPerSample;
        private int _channels;
        private int _outputChannels;
        private readonly object _bufferLock = new object();
        private byte[] _buffer = new byte[65536];

        public LinuxAudioOutput(int sampleRate, int bitsPerSample, int channels)
        {
            _sampleRate = sampleRate;
            _bitsPerSample = bitsPerSample;
            _channels = channels;
        }

        public void Init(int sampleRate, int bitsPerSample, int channels)
        {
            _sampleRate = sampleRate;
            _bitsPerSample = bitsPerSample;
            _channels = channels;
        }

        public void Play()
        {
            if (stream != IntPtr.Zero) return;

            uint sampleFormat = (uint)(_bitsPerSample == 16 ? 0x00000008 : 0x00000001); // paInt16 or paFloat32
            int device = PortAudioNative.Pa_GetDefaultOutputDevice();

            // Always open as stereo — mono PortAudio output on Linux only plays through left speaker
            _outputChannels = 2;
            var outputParams = new PortAudioNative.PaStreamParameters
            {
                device = device,
                channelCount = _outputChannels,
                sampleFormat = sampleFormat,
                suggestedLatency = 0.1,
                hostApiSpecificStreamInfo = IntPtr.Zero
            };

            PortAudioNative.Pa_OpenStream(
                out stream, IntPtr.Zero, ref outputParams,
                _sampleRate, 256, 0, null, IntPtr.Zero);

            if (stream != IntPtr.Zero)
            {
                PortAudioNative.Pa_StartStream(stream);
            }
            else
            {
                // Stereo failed, try original channel count
                _outputChannels = _channels;
                outputParams.channelCount = _channels;
                PortAudioNative.Pa_OpenStream(
                    out stream, IntPtr.Zero, ref outputParams,
                    _sampleRate, 256, 0, null, IntPtr.Zero);
                if (stream != IntPtr.Zero)
                    PortAudioNative.Pa_StartStream(stream);
            }
        }

        public void Stop()
        {
            if (stream != IntPtr.Zero)
            {
                PortAudioNative.Pa_StopStream(stream);
                PortAudioNative.Pa_CloseStream(stream);
                stream = IntPtr.Zero;
            }
        }

        public void AddSamples(byte[] buffer, int offset, int count)
        {
            if (stream == IntPtr.Zero) return;

            // Apply volume
            if (Math.Abs(_volume - 1.0f) > 0.01f && _bitsPerSample == 16)
            {
                byte[] adjusted = new byte[count];
                Array.Copy(buffer, offset, adjusted, 0, count);
                for (int i = 0; i < count - 1; i += 2)
                {
                    short sample = (short)(adjusted[i] | (adjusted[i + 1] << 8));
                    sample = (short)(sample * _volume);
                    adjusted[i] = (byte)(sample & 0xFF);
                    adjusted[i + 1] = (byte)((sample >> 8) & 0xFF);
                }
                buffer = adjusted;
                offset = 0;
            }

            // Duplicate mono to stereo if input is mono but output is stereo
            int bytesPerSample = _bitsPerSample / 8;
            int frames = count / (_channels * bytesPerSample);

            if (_channels == 1 && _outputChannels == 2 && _bitsPerSample == 16)
            {
                int stereoSize = frames * 2 * bytesPerSample;
                IntPtr dataPtr = Marshal.AllocHGlobal(stereoSize);
                try
                {
                    unsafe
                    {
                        byte* dst = (byte*)dataPtr;
                        for (int i = 0; i < frames; i++)
                        {
                            int srcIdx = offset + i * bytesPerSample;
                            byte lo = buffer[srcIdx];
                            byte hi = buffer[srcIdx + 1];
                            int dstIdx = i * 2 * bytesPerSample;
                            dst[dstIdx] = lo;     dst[dstIdx + 1] = hi;  // Left
                            dst[dstIdx + 2] = lo; dst[dstIdx + 3] = hi;  // Right
                        }
                    }
                    PortAudioNative.Pa_WriteStream(stream, dataPtr, (uint)frames);
                }
                finally
                {
                    Marshal.FreeHGlobal(dataPtr);
                }
            }
            else
            {
                IntPtr dataPtr = Marshal.AllocHGlobal(count);
                try
                {
                    Marshal.Copy(buffer, offset, dataPtr, count);
                    PortAudioNative.Pa_WriteStream(stream, dataPtr, (uint)frames);
                }
                finally
                {
                    Marshal.FreeHGlobal(dataPtr);
                }
            }
        }

        public float Volume
        {
            get => _volume;
            set => _volume = Math.Max(0, Math.Min(2.0f, value));
        }

        public string DeviceId
        {
            get => _deviceId;
            set => _deviceId = value;
        }

        public void Dispose()
        {
            Stop();
        }
    }

    public class LinuxAudioInput : IAudioInput
    {
        private int _sampleRate;
        private int _bitsPerSample;
        private int _channels;
        private string _deviceId;
        private System.Diagnostics.Process captureProcess;
        private System.Threading.Thread captureThread;
        private volatile bool capturing = false;

        public event Action<byte[], int> DataAvailable;

        public LinuxAudioInput(int sampleRate, int bitsPerSample, int channels)
        {
            _sampleRate = sampleRate;
            _bitsPerSample = bitsPerSample;
            _channels = channels;
        }

        public void Start()
        {
            if (capturing) return;

            // Use parecord (PulseAudio/PipeWire CLI) for reliable audio capture
            // This works on PipeWire, PulseAudio, and ALSA via compatibility layers
            try
            {
                string format = _bitsPerSample == 16 ? "s16le" : "float32le";
                var psi = new System.Diagnostics.ProcessStartInfo("parecord",
                    $"--format={format} --rate={_sampleRate} --channels={_channels} --raw --latency-msec=20")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                captureProcess = System.Diagnostics.Process.Start(psi);
                if (captureProcess == null) return;

                capturing = true;
                captureThread = new System.Threading.Thread(CaptureLoop) { IsBackground = true };
                captureThread.Start();
            }
            catch (Exception)
            {
                // parecord not available
            }
        }

        private void CaptureLoop()
        {
            int bytesPerFrame = _channels * (_bitsPerSample / 8);
            int framesPerBuffer = 1024; // ~21ms at 48kHz
            int bufferSize = framesPerBuffer * bytesPerFrame;
            byte[] buffer = new byte[bufferSize];

            var stdout = captureProcess?.StandardOutput?.BaseStream;
            if (stdout == null) return;

            while (capturing)
            {
                try
                {
                    int totalRead = 0;
                    while (totalRead < bufferSize && capturing)
                    {
                        int bytesRead = stdout.Read(buffer, totalRead, bufferSize - totalRead);
                        if (bytesRead <= 0) { capturing = false; break; }
                        totalRead += bytesRead;
                    }

                    if (totalRead > 0)
                        DataAvailable?.Invoke(buffer, totalRead);
                }
                catch (Exception)
                {
                    break;
                }
            }
        }

        public void Stop()
        {
            capturing = false;
            try
            {
                if (captureProcess != null && !captureProcess.HasExited)
                {
                    captureProcess.Kill();
                    captureProcess.WaitForExit(1000);
                }
                captureProcess?.Dispose();
                captureProcess = null;
            }
            catch (Exception) { }
            captureThread?.Join(1000);
            captureThread = null;
        }

        public string DeviceId
        {
            get => _deviceId;
            set => _deviceId = value;
        }

        public void Dispose()
        {
            Stop();
        }
    }

    /// <summary>
    /// PortAudio native P/Invoke bindings.
    /// </summary>
    internal static class PortAudioNative
    {
        private const string LibName = "libportaudio.so.2";

        [StructLayout(LayoutKind.Sequential)]
        public struct PaDeviceInfo
        {
            public int structVersion;
            public IntPtr name;
            public int hostApi;
            public int maxInputChannels;
            public int maxOutputChannels;
            public double defaultLowInputLatency;
            public double defaultLowOutputLatency;
            public double defaultHighInputLatency;
            public double defaultHighOutputLatency;
            public double defaultSampleRate;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PaStreamParameters
        {
            public int device;
            public int channelCount;
            public uint sampleFormat; // paFloat32=1, paInt16=8
            public double suggestedLatency;
            public IntPtr hostApiSpecificStreamInfo;
        }

        public delegate int PaStreamCallback(IntPtr input, IntPtr output, uint frameCount,
            IntPtr timeInfo, uint statusFlags, IntPtr userData);

        [DllImport(LibName)] public static extern int Pa_Initialize();
        [DllImport(LibName)] public static extern int Pa_Terminate();
        [DllImport(LibName)] public static extern int Pa_GetDeviceCount();
        [DllImport(LibName)] public static extern IntPtr Pa_GetDeviceInfo(int device);
        [DllImport(LibName)] public static extern int Pa_GetDefaultOutputDevice();
        [DllImport(LibName)] public static extern int Pa_GetDefaultInputDevice();

        [DllImport(LibName)]
        public static extern int Pa_OpenStream(out IntPtr stream,
            ref PaStreamParameters inputParameters, ref PaStreamParameters outputParameters,
            double sampleRate, uint framesPerBuffer, uint streamFlags,
            PaStreamCallback streamCallback, IntPtr userData);

        [DllImport(LibName)]
        public static extern int Pa_OpenStream(out IntPtr stream,
            IntPtr inputParameters, ref PaStreamParameters outputParameters,
            double sampleRate, uint framesPerBuffer, uint streamFlags,
            PaStreamCallback streamCallback, IntPtr userData);

        [DllImport(LibName)]
        public static extern int Pa_OpenStream(out IntPtr stream,
            ref PaStreamParameters inputParameters, IntPtr outputParameters,
            double sampleRate, uint framesPerBuffer, uint streamFlags,
            PaStreamCallback streamCallback, IntPtr userData);

        [DllImport(LibName)] public static extern int Pa_StartStream(IntPtr stream);
        [DllImport(LibName)] public static extern int Pa_StopStream(IntPtr stream);
        [DllImport(LibName)] public static extern int Pa_CloseStream(IntPtr stream);
        [DllImport(LibName)] public static extern int Pa_WriteStream(IntPtr stream, IntPtr buffer, uint frames);
        [DllImport(LibName)] public static extern int Pa_ReadStream(IntPtr stream, IntPtr buffer, uint frames);
    }
}
