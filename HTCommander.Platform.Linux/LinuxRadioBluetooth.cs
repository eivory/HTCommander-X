/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Tmds.DBus;

namespace HTCommander.Platform.Linux
{
    /// <summary>
    /// Linux Bluetooth transport using direct native RFCOMM sockets.
    /// Strategy: Use SDP to discover the SPP command channel, then connect with a native
    /// RFCOMM socket and verify GAIA protocol response. This approach (used by benlink/khusmann)
    /// is more reliable than BlueZ ProfileManager1 which has fd lifecycle issues with Tmds.DBus.
    /// </summary>
    public class LinuxRadioBluetooth : IRadioBluetooth
    {
        private IRadioHost parent;
        private volatile bool running = false;
        private int rfcommFd = -1;
        private CancellationTokenSource connectionCts = null;
        private readonly object connectionLock = new object();
        private Task connectionTask = null;
        private volatile bool isConnecting = false;
        private bool _disposed = false;

        public event Action OnConnected;
        public event Action<Exception, byte[]> ReceivedData;

        private static readonly string[] TargetDeviceNames = { "UV-PRO", "UV-50PRO", "GA-5WB", "VR-N75", "VR-N76", "VR-N7500", "VR-N7600" };

        private const string BlueZBusName = "org.bluez";
        private const string AdapterPath = "/org/bluez/hci0";

        public LinuxRadioBluetooth(IRadioHost parent)
        {
            this.parent = parent;
        }

        private void Debug(string msg) { parent?.Debug("Transport: " + msg); }

        public Task<bool> RequestPermissionsAsync() => Task.FromResult(true);

        public async Task<bool> CheckBluetoothAsync()
        {
            try
            {
                using var connection = new Connection(Address.System);
                await connection.ConnectAsync();
                var adapter = connection.CreateProxy<IAdapter1>(BlueZBusName, AdapterPath);
                var powered = await adapter.GetAsync("Powered");
                return powered is bool b && b;
            }
            catch (Exception) { return false; }
        }

        public async Task<string[]> GetDeviceNames()
        {
            List<string> deviceNames = new List<string>();
            try
            {
                using var connection = new Connection(Address.System);
                await connection.ConnectAsync();
                var manager = connection.CreateProxy<IObjectManager>(BlueZBusName, "/");
                var objects = await manager.GetManagedObjectsAsync();

                foreach (var path in objects.Keys)
                {
                    if (objects[path].ContainsKey("org.bluez.Device1"))
                    {
                        var props = objects[path]["org.bluez.Device1"];
                        if (props.TryGetValue("Name", out object nameObj) && nameObj is string name)
                        {
                            if (!deviceNames.Contains(name))
                                deviceNames.Add(name);
                        }
                    }
                }
            }
            catch (Exception) { }
            deviceNames.Sort();
            return deviceNames.ToArray();
        }

        public async Task<CompatibleDevice[]> FindCompatibleDevices()
        {
            List<CompatibleDevice> compatibleDevices = new List<CompatibleDevice>();
            List<string> macs = new List<string>();

            try
            {
                using var connection = new Connection(Address.System);
                await connection.ConnectAsync();
                var manager = connection.CreateProxy<IObjectManager>(BlueZBusName, "/");
                var objects = await manager.GetManagedObjectsAsync();

                foreach (var path in objects.Keys)
                {
                    if (!objects[path].ContainsKey("org.bluez.Device1")) continue;
                    var props = objects[path]["org.bluez.Device1"];

                    string name = null, address = null;
                    if (props.TryGetValue("Name", out object nameObj)) name = nameObj as string;
                    if (props.TryGetValue("Address", out object addrObj)) address = addrObj as string;

                    if (name == null || address == null) continue;
                    if (!TargetDeviceNames.Contains(name)) continue;

                    string mac = address.Replace(":", "").ToUpper();
                    if (!macs.Contains(mac))
                    {
                        macs.Add(mac);
                        compatibleDevices.Add(new CompatibleDevice(name, mac));
                    }
                }
            }
            catch (Exception) { }
            return compatibleDevices.ToArray();
        }

        public bool Connect()
        {
            lock (connectionLock)
            {
                if (running || isConnecting) return false;
                isConnecting = true;
            }
            connectionTask = Task.Run(() => StartAsync());
            return true;
        }

        public void Disconnect()
        {
            lock (connectionLock)
            {
                if (!running && connectionTask == null) return;
                running = false;
                try { connectionCts?.Cancel(); } catch { }
            }

            if (connectionTask != null)
            {
                try { connectionTask.Wait(TimeSpan.FromSeconds(3)); } catch { }
            }

            lock (connectionLock)
            {
                if (rfcommFd >= 0) { try { NativeMethods.close(rfcommFd); } catch { } rfcommFd = -1; }

                try { connectionCts?.Dispose(); } catch { }
                connectionCts = null;
                connectionTask = null;
            }
            Thread.Sleep(100);
        }

        public void EnqueueWrite(int expectedResponse, byte[] cmdData)
        {
            int fd;
            lock (connectionLock)
            {
                if (!running || rfcommFd < 0) return;
                fd = rfcommFd;
            }
            byte[] bytes = GaiaEncode(cmdData);
            int totalWritten = 0;
            while (totalWritten < bytes.Length)
            {
                byte[] slice = (totalWritten == 0) ? bytes : bytes[totalWritten..];
                int written = NativeMethods.write(fd, slice, slice.Length);
                if (written > 0)
                {
                    totalWritten += written;
                }
                else if (written < 0)
                {
                    int errno = Marshal.GetLastWin32Error();
                    if (errno == 11 || errno == 35) // EAGAIN / EWOULDBLOCK
                    {
                        Thread.Sleep(5);
                        continue;
                    }
                    Debug($"write() failed: errno={errno}");
                    return;
                }
                else return; // written == 0, unexpected
            }
        }

        public void OnPause() { }
        public void OnResume() { }

        #region GAIA Protocol

        private static int GaiaDecode(byte[] data, int index, int len, out byte[] cmd)
        {
            cmd = null;
            if (len < 8) return 0;
            if (data[index] != 0xFF || data[index + 1] != 0x01) return -1;
            byte payloadLen = data[index + 3];
            int hasChecksum = data[index + 2] & 1;
            int totalLen = payloadLen + 8 + hasChecksum;
            if (totalLen > len) return 0;
            cmd = new byte[4 + payloadLen];
            Array.Copy(data, index + 4, cmd, 0, cmd.Length);
            return totalLen;
        }

        private static byte[] GaiaEncode(byte[] cmd)
        {
            int payloadLen = cmd.Length - 4;
            if (payloadLen < 0 || payloadLen > 255) return cmd; // GAIA payload length is single byte; reject oversized
            byte[] bytes = new byte[cmd.Length + 4];
            bytes[0] = 0xFF;
            bytes[1] = 0x01;
            bytes[3] = (byte)payloadLen;
            Array.Copy(cmd, 0, bytes, 4, cmd.Length);
            return bytes;
        }

        #endregion

        #region Connection

        private async void StartAsync()
        {
            CancellationToken ct;
            lock (connectionLock)
            {
                connectionCts = new CancellationTokenSource();
                ct = connectionCts.Token;
            }

            string mac = parent.MacAddress.Replace(":", "").Replace("-", "").ToUpper();
            string macColon = string.Join(":", Enumerable.Range(0, 6).Select(i => mac.Substring(i * 2, 2)));
            string formattedMac = string.Join("_", Enumerable.Range(0, 6).Select(i => mac.Substring(i * 2, 2)));
            string devicePath = $"{AdapterPath}/dev_{formattedMac}";
            byte[] bdaddr = ParseMacAddress(mac);

            int retry = 3;
            while (retry > 0 && !ct.IsCancellationRequested)
            {
                try
                {
                    Debug($"Connecting to {macColon} (attempt {4 - retry}/3)...");

                    // Step 1: Ensure ACL-level connection via BlueZ D-Bus
                    await EnsureAclConnection(devicePath, ct);

                    // Step 2: Try SDP-based channel discovery, then direct RFCOMM socket
                    // This approach (used by benlink/khusmann) is more reliable than ProfileManager1
                    int[] sppChannels = await DiscoverSppChannels(macColon);

                    if (sppChannels != null && sppChannels.Length > 0)
                    {
                        Debug($"SDP discovered {sppChannels.Length} SPP channel(s): {string.Join(", ", sppChannels)}");
                        rfcommFd = ConnectToGaiaChannel(bdaddr, sppChannels);
                    }

                    // Step 3: If SDP failed or no channel responded, probe channels 1-10
                    if (rfcommFd < 0)
                    {
                        Debug("Probing RFCOMM channels for GAIA response...");
                        rfcommFd = ProbeChannels(bdaddr);
                    }

                    if (rfcommFd >= 0)
                    {
                        retry = -2; // success
                    }
                    else
                    {
                        retry--;
                        Debug("No GAIA-responsive RFCOMM channel found");
                        if (retry > 0) await Task.Delay(2000, ct);
                    }
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    retry--;
                    Debug("Connect failed: " + ex.Message);
                    if (rfcommFd >= 0) { try { NativeMethods.close(rfcommFd); } catch { } rfcommFd = -1; }
                    if (retry > 0) await Task.Delay(2000, ct);
                }
            }

            if (retry != -2)
            {
                lock (connectionLock) { isConnecting = false; }
                parent.Disconnect("Unable to connect", RadioState.UnableToConnect);
                return;
            }

            Debug("Connected — GAIA communication verified.");
            RunReadLoop(ct);
        }

        /// <summary>
        /// Ensure ACL-level Bluetooth connection via BlueZ D-Bus.
        /// </summary>
        private async Task EnsureAclConnection(string devicePath, CancellationToken ct)
        {
            try
            {
                using var dbusConn = new Connection(Address.System);
                await dbusConn.ConnectAsync();
                var device = dbusConn.CreateProxy<IDevice1>(BlueZBusName, devicePath);

                var connected = await device.GetAsync("Connected");
                if (connected is bool b && b)
                {
                    Debug("Device already connected at ACL level");
                    return;
                }

                Debug("Connecting at ACL level...");
                await device.ConnectAsync();
                await Task.Delay(2000, ct);
            }
            catch (Exception ex)
            {
                Debug($"ACL connect: {ex.Message} (will try direct RFCOMM anyway)");
            }
        }

        /// <summary>
        /// Discover SPP RFCOMM channels via sdptool or bluetoothctl.
        /// Returns channel numbers for "SPP Dev" / Serial Port services, or null if discovery fails.
        /// </summary>
        private async Task<int[]> DiscoverSppChannels(string macColon)
        {
            // Try sdptool first (most reliable for RFCOMM channel discovery)
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo("sdptool")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                psi.ArgumentList.Add("browse");
                psi.ArgumentList.Add(macColon);
                using var proc = System.Diagnostics.Process.Start(psi);
                if (proc != null)
                {
                    string output = await ReadProcessOutputLimited(proc.StandardOutput, 512 * 1024);
                    proc.WaitForExit(10000);

                    if (proc.ExitCode == 0 && !string.IsNullOrEmpty(output))
                    {
                        var channels = ParseSdptoolOutput(output);
                        if (channels.Count > 0)
                        {
                            Debug($"sdptool found SPP channels: {string.Join(", ", channels)}");
                            return channels.ToArray();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug($"sdptool not available: {ex.Message}");
            }

            // Fallback: try bluetoothctl info to at least confirm SPP UUID is advertised
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo("bluetoothctl")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                psi.ArgumentList.Add("info");
                psi.ArgumentList.Add(macColon);
                using var proc = System.Diagnostics.Process.Start(psi);
                if (proc != null)
                {
                    string output = await ReadProcessOutputLimited(proc.StandardOutput, 512 * 1024);
                    proc.WaitForExit(5000);

                    if (output.Contains("00001101-0000-1000-8000-00805f9b34fb"))
                    {
                        Debug("bluetoothctl confirms SPP UUID is advertised");
                        // Can't get channel number from bluetoothctl, will probe
                    }
                    else
                    {
                        Debug("bluetoothctl: SPP UUID not found in device services");
                    }
                }
            }
            catch (Exception) { }

            return null;
        }

        /// <summary>
        /// Reads subprocess output with a size limit to prevent unbounded memory allocation.
        /// </summary>
        private static async System.Threading.Tasks.Task<string> ReadProcessOutputLimited(System.IO.StreamReader reader, int maxBytes)
        {
            var sb = new System.Text.StringBuilder();
            char[] buf = new char[4096];
            int totalRead = 0;
            int read;
            while ((read = await reader.ReadAsync(buf, 0, buf.Length)) > 0)
            {
                totalRead += read;
                if (totalRead > maxBytes) { sb.Append(buf, 0, read - (totalRead - maxBytes)); break; }
                sb.Append(buf, 0, read);
            }
            return sb.ToString();
        }

        /// <summary>
        /// Parse sdptool browse output to find RFCOMM channel numbers for SPP/"SPP Dev" services.
        /// </summary>
        private List<int> ParseSdptoolOutput(string output)
        {
            var sppChannels = new List<int>();
            var allChannels = new List<int>();
            string[] records = output.Split(new[] { "Service Name:" }, StringSplitOptions.None);

            foreach (string record in records)
            {
                // Look for RFCOMM channel number
                var channelMatch = Regex.Match(record, @"Channel:\s*(\d+)");
                if (!channelMatch.Success) continue;
                if (!int.TryParse(channelMatch.Groups[1].Value, out int channel)) continue;
                if (channel < 1 || channel > 30) continue; // Valid RFCOMM channels are 1-30

                // Check if this is an SPP service (command channel)
                bool isSpp = record.Contains("SPP Dev") ||
                             record.Contains("Serial Port") ||
                             record.Contains("00001101-0000-1000-8000-00805f9b34fb");

                if (isSpp)
                {
                    Debug($"SDP: SPP service on channel {channel}");
                    sppChannels.Add(channel);
                }
                else
                {
                    // Track other channels too (audio "BS AOC", HFP, etc.)
                    string nameMatch = record.TrimStart();
                    string name = nameMatch.Length > 40 ? nameMatch.Substring(0, 40) : nameMatch;
                    Debug($"SDP: other service on channel {channel}: {name.Trim()}");
                    allChannels.Add(channel);
                }
            }

            // If we found specific SPP channels, return those first
            // Otherwise return all discovered channels for probing
            if (sppChannels.Count > 0) return sppChannels;
            return allChannels;
        }

        /// <summary>
        /// Try connecting to specific RFCOMM channels and verify GAIA response.
        /// Only accepts a channel if the radio actually responds to GET_DEV_ID.
        /// </summary>
        private int ConnectToGaiaChannel(byte[] bdaddr, int[] channels)
        {
            foreach (int ch in channels)
            {
                int fd = CreateRfcommFd(bdaddr, ch);
                if (fd < 0)
                {
                    Debug($"Channel {ch}: connect failed");
                    continue;
                }

                try
                {
                    if (VerifyGaiaResponse(fd, ch))
                        return fd;
                }
                catch (Exception ex)
                {
                    Debug($"Channel {ch}: verification exception: {ex.Message}");
                }

                NativeMethods.close(fd);
            }
            return -1;
        }

        /// <summary>
        /// Send GAIA GET_DEV_ID command and verify the radio responds with valid GAIA data.
        /// This is the critical test — benlink and HTCommander Windows both work because
        /// they connect to the correct SPP channel that actually carries GAIA traffic.
        /// </summary>
        private bool VerifyGaiaResponse(int fd, int channel)
        {
            // Send GET_DEV_ID: group=BASIC(2), cmd=1
            byte[] gaiaCmd = GaiaEncode(new byte[] { 0x00, 0x02, 0x00, 0x01 });
            int sent = NativeMethods.write(fd, gaiaCmd, gaiaCmd.Length);
            if (sent < 0)
            {
                Debug($"Channel {channel}: write failed (errno={Marshal.GetLastWin32Error()})");
                return false;
            }
            Debug($"Channel {channel}: sent GET_DEV_ID ({sent} bytes)");

            // Wait for GAIA response — the radio should respond within 2 seconds
            var pfd = new NativeMethods.pollfd { fd = fd, events = 1 /* POLLIN */ };
            int pollResult = NativeMethods.poll(ref pfd, 1, 3000);

            if (pollResult <= 0)
            {
                Debug($"Channel {channel}: no response (poll={pollResult})");
                return false;
            }

            if ((pfd.revents & (4 | 8 | 16)) != 0) // POLLERR | POLLHUP | POLLNVAL
            {
                Debug($"Channel {channel}: socket error (revents=0x{pfd.revents:X})");
                return false;
            }

            if ((pfd.revents & 1) != 0) // POLLIN
            {
                byte[] buf = new byte[1024];
                int bytesRead = NativeMethods.read(fd, buf, buf.Length);
                if (bytesRead > 0)
                {
                    string hex = BitConverter.ToString(buf, 0, Math.Min(bytesRead, 32));
                    Debug($"Channel {channel}: received {bytesRead} bytes: {hex}");

                    // Verify it looks like a GAIA response (starts with FF 01)
                    if (bytesRead >= 2 && buf[0] == 0xFF && buf[1] == 0x01)
                    {
                        Debug($"Channel {channel}: valid GAIA response — this is the command channel!");
                        return true;
                    }
                    else
                    {
                        Debug($"Channel {channel}: not a GAIA response");
                        return false;
                    }
                }
            }

            Debug($"Channel {channel}: no data received");
            return false;
        }

        /// <summary>
        /// Fallback: probe RFCOMM channels 1-30 with native sockets.
        /// Only accepts a channel if it responds with valid GAIA data (FF 01 header).
        /// Based on approach used by benlink (khusmann) — direct RFCOMM socket per channel.
        /// </summary>
        private int ProbeChannels(byte[] bdaddr)
        {
            Debug("Probing RFCOMM channels 1-30 for GAIA response...");
            for (int ch = 1; ch <= 30; ch++)
            {
                int fd = CreateRfcommFd(bdaddr, ch);
                if (fd < 0) continue;

                Debug($"Channel {ch}: connected, testing GAIA...");
                try
                {
                    if (VerifyGaiaResponse(fd, ch))
                        return fd;
                }
                catch
                {
                    // VerifyGaiaResponse failed with exception
                }

                NativeMethods.close(fd);
            }
            Debug("No GAIA-responsive channel found");
            return -1;
        }

        private void RunReadLoop(CancellationToken ct)
        {
            try
            {
                byte[] accumulator = new byte[4096];
                int accumulatorPtr = 0, accumulatorLen = 0;

                lock (connectionLock)
                {
                    isConnecting = false;
                    if (ct.IsCancellationRequested)
                    {
                        running = false;
                        if (rfcommFd >= 0) { NativeMethods.close(rfcommFd); rfcommFd = -1; }
                        return;
                    }
                }

                // Verify the fd is valid and check socket type
                int fcntlResult = NativeMethods.fcntl(rfcommFd, 1 /* F_GETFD */);
                Debug($"fd {rfcommFd} fcntl F_GETFD = {fcntlResult} (errno={Marshal.GetLastWin32Error()})");
                if (fcntlResult < 0)
                {
                    Debug("ERROR: fd is not valid!");
                    lock (connectionLock) { isConnecting = false; }
                    parent.Disconnect("Invalid file descriptor", RadioState.UnableToConnect);
                    return;
                }

                // Check socket type and domain
                int sockType = 0, sockTypeLen = 4;
                NativeMethods.getsockopt(rfcommFd, 1 /* SOL_SOCKET */, 3 /* SO_TYPE */, ref sockType, ref sockTypeLen);
                int sockDomain = 0, sockDomainLen = 4;
                NativeMethods.getsockopt(rfcommFd, 1 /* SOL_SOCKET */, 39 /* SO_DOMAIN */, ref sockDomain, ref sockDomainLen);
                int sockProto = 0, sockProtoLen = 4;
                NativeMethods.getsockopt(rfcommFd, 1 /* SOL_SOCKET */, 38 /* SO_PROTOCOL */, ref sockProto, ref sockProtoLen);
                Debug($"Socket info: type={sockType} (1=STREAM), domain={sockDomain} (31=AF_BLUETOOTH), protocol={sockProto} (3=BTPROTO_RFCOMM)");

                int flags = NativeMethods.fcntl(rfcommFd, 3 /* F_GETFL */);
                if (flags < 0)
                {
                    Debug($"fcntl F_GETFL failed (errno={Marshal.GetLastWin32Error()})");
                    lock (connectionLock) { isConnecting = false; }
                    parent.Disconnect("Failed to get socket flags", RadioState.UnableToConnect);
                    return;
                }
                Debug($"Socket flags=0x{flags:X}");

                running = true;

                // Set socket to non-blocking mode.
                // Neither poll() nor SO_RCVTIMEO work reliably on RFCOMM sockets,
                // so we use non-blocking read() with a manual sleep loop.
                int curFlags = NativeMethods.fcntl(rfcommFd, 3 /* F_GETFL */);
                if (curFlags < 0)
                {
                    Debug($"fcntl F_GETFL failed before read loop (errno={Marshal.GetLastWin32Error()})");
                    lock (connectionLock) { isConnecting = false; }
                    parent.Disconnect("Failed to get socket flags", RadioState.UnableToConnect);
                    return;
                }
                NativeMethods.fcntl3(rfcommFd, 4 /* F_SETFL */, curFlags | 0x800 /* O_NONBLOCK */);
                Debug("Read loop starting (non-blocking read with sleep loop)");

                // Fire OnConnected on a background thread so the read loop starts immediately.
                ThreadPool.QueueUserWorkItem(_ => OnConnected?.Invoke());

                int idleCycles = 0;
                while (running && !ct.IsCancellationRequested)
                {
                    // Read into a temp buffer, then copy to accumulator
                    int space = accumulator.Length - (accumulatorPtr + accumulatorLen);
                    if (space <= 0) { accumulatorPtr = 0; accumulatorLen = 0; space = accumulator.Length; }

                    byte[] readBuf = new byte[Math.Min(space, 1024)];
                    int bytesRead = NativeMethods.read(rfcommFd, readBuf, readBuf.Length);

                    if (bytesRead < 0)
                    {
                        int errno = Marshal.GetLastWin32Error();
                        // EAGAIN/EWOULDBLOCK (11) = no data available, EINTR (4) = signal
                        if (errno == 11 || errno == 4)
                        {
                            idleCycles++;
                            if (idleCycles % 600 == 0) Debug($"Waiting for data... ({idleCycles / 20}s)");
                            Thread.Sleep(50); // 50ms between read attempts
                            continue;
                        }
                        Debug($"read() error: errno={errno}");
                        break;
                    }

                    if (!running) break;
                    if (bytesRead == 0)
                    {
                        Debug("read() returned 0 — remote closed connection");
                        break;
                    }

                    idleCycles = 0;

                    Array.Copy(readBuf, 0, accumulator, accumulatorPtr + accumulatorLen, bytesRead);
                    accumulatorLen += bytesRead;

                    if (accumulatorLen < 8) continue;

                    int cmdSize;
                    byte[] cmd;
                    while ((cmdSize = GaiaDecode(accumulator, accumulatorPtr, accumulatorLen, out cmd)) != 0)
                    {
                        if (cmdSize < 0) cmdSize = accumulatorLen;
                        accumulatorPtr += cmdSize;
                        accumulatorLen -= cmdSize;
                        if (cmd != null) ReceivedData?.Invoke(null, cmd);
                    }

                    if (accumulatorLen == 0) accumulatorPtr = 0;
                    if (accumulatorPtr > 2048)
                    {
                        Array.Copy(accumulator, accumulatorPtr, accumulator, 0, accumulatorLen);
                        accumulatorPtr = 0;
                    }
                }
            }
            catch (Exception ex)
            {
                if (running) Debug($"Connection error: {ex.Message}");
            }
            finally
            {
                lock (connectionLock) { running = false; isConnecting = false; }
                lock (connectionLock)
                {
                    if (rfcommFd >= 0) { try { NativeMethods.close(rfcommFd); } catch { } rfcommFd = -1; }
                }
                Debug("Connection closed.");
                parent.Disconnect("Connection closed.", RadioState.Disconnected);
            }
        }

        #endregion

        #region Native RFCOMM

        private static byte[] ParseMacAddress(string mac)
        {
            mac = mac.Replace(":", "").Replace("-", "");
            byte[] bytes = new byte[6];
            for (int i = 0; i < 6; i++)
                bytes[i] = Convert.ToByte(mac.Substring(i * 2, 2), 16);
            return bytes;
        }

        private int CreateRfcommFd(byte[] bdaddr, int channel)
        {
            if (bdaddr == null || bdaddr.Length < 6) return -1;

            int fd = NativeMethods.socket(31, 1, 3); // AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM
            if (fd < 0) return -1;

            byte[] addr = new byte[10];
            addr[0] = 31; addr[1] = 0; // AF_BLUETOOTH
            for (int i = 0; i < 6; i++) addr[2 + i] = bdaddr[5 - i]; // reversed
            addr[8] = (byte)channel;

            IntPtr addrPtr = Marshal.AllocHGlobal(addr.Length);
            try
            {
                Marshal.Copy(addr, 0, addrPtr, addr.Length);
                int result = NativeMethods.connect(fd, addrPtr, addr.Length);
                if (result < 0) { NativeMethods.close(fd); return -1; }
            }
            finally { Marshal.FreeHGlobal(addrPtr); }

            return fd;
        }

        #endregion

        public void Dispose()
        {
            if (!_disposed) { Disconnect(); _disposed = true; }
        }

        private static class NativeMethods
        {
            [DllImport("libc", SetLastError = true)]
            public static extern int socket(int domain, int type, int protocol);
            [DllImport("libc", SetLastError = true)]
            public static extern int connect(int sockfd, IntPtr addr, int addrlen);
            [DllImport("libc", SetLastError = true)]
            public static extern int close(int fd);
            [DllImport("libc", SetLastError = true)]
            public static extern int write(int fd, byte[] buf, int count);
            [DllImport("libc", SetLastError = true)]
            public static extern int read(int fd, byte[] buf, int count);
            [DllImport("libc", SetLastError = true)]
            public static extern int getsockopt(int sockfd, int level, int optname, ref int optval, ref int optlen);

            [DllImport("libc", SetLastError = true)]
            public static extern int setsockopt(int sockfd, int level, int optname, byte[] optval, int optlen);

            // Alias for clarity
            public static int setsockopt_bytes(int sockfd, int level, int optname, byte[] optval, int optlen)
                => setsockopt(sockfd, level, optname, optval, optlen);

            [StructLayout(LayoutKind.Sequential)]
            public struct pollfd { public int fd; public short events; public short revents; }

            [DllImport("libc", SetLastError = true)]
            public static extern int poll(ref pollfd fds, int nfds, int timeout);

            [DllImport("libc", SetLastError = true)]
            public static extern int fcntl(int fd, int cmd);

            [DllImport("libc", SetLastError = true, EntryPoint = "fcntl")]
            public static extern int fcntl3(int fd, int cmd, int arg);
        }
    }

    #region BlueZ D-Bus Interfaces

    [DBusInterface("org.bluez.Adapter1")]
    public interface IAdapter1 : IDBusObject
    {
        Task<object> GetAsync(string prop);
    }

    [DBusInterface("org.freedesktop.DBus.ObjectManager")]
    public interface IObjectManager : IDBusObject
    {
        Task<IDictionary<ObjectPath, IDictionary<string, IDictionary<string, object>>>> GetManagedObjectsAsync();
    }

    [DBusInterface("org.bluez.Device1")]
    public interface IDevice1 : IDBusObject
    {
        Task ConnectAsync();
        Task ConnectProfileAsync(string uuid);
        Task DisconnectAsync();
        Task<object> GetAsync(string prop);
    }

    #endregion
}
