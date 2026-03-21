/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    /// <summary>
    /// Lightweight HTTP server with optional TLS support.
    /// Replaces HttpListener (which doesn't support HTTPS on Linux) with TcpListener + SslStream.
    /// Supports static file serving, REST endpoints, and WebSocket upgrade.
    /// </summary>
    public class TlsHttpServer : IDisposable
    {
        public class HttpRequest
        {
            public string Method;
            public string Path;
            public string Query;
            public Dictionary<string, string> Headers;
            public byte[] Body;
        }

        public class HttpResponse
        {
            public int StatusCode = 200;
            public string StatusText = "OK";
            public string ContentType = "text/plain";
            public Dictionary<string, string> Headers;
            public byte[] Body;

            public HttpResponse()
            {
                Headers = new Dictionary<string, string>();
            }

            public HttpResponse(int statusCode, string body) : this()
            {
                StatusCode = statusCode;
                StatusText = GetStatusText(statusCode);
                Body = Encoding.UTF8.GetBytes(body);
            }

            private static string GetStatusText(int code)
            {
                switch (code)
                {
                    case 200: return "OK";
                    case 400: return "Bad Request";
                    case 403: return "Forbidden";
                    case 404: return "Not Found";
                    case 405: return "Method Not Allowed";
                    case 500: return "Internal Server Error";
                    default: return "Unknown";
                }
            }
        }

        private readonly int port;
        private readonly bool bindAll;
        private readonly bool useTls;
        private readonly X509Certificate2 certificate;
        private readonly Func<HttpRequest, HttpResponse> requestHandler;
        private readonly string webSocketPath;
        private readonly Func<WebSocket, CancellationToken, Task> webSocketHandler;
        private readonly Action<string> logAction;

        private TcpListener tcpListener;
        private CancellationTokenSource cts;
        private Task acceptTask;
        private volatile bool disposed;

        private const int MaxRequestSize = 1024 * 1024; // 1MB max request
        private const int HeaderReadTimeout = 30000; // 30s to read headers
        private const int TlsHandshakeTimeout = 15000; // 15s for TLS handshake

        public TlsHttpServer(
            int port,
            bool bindAll,
            bool useTls,
            X509Certificate2 certificate,
            Func<HttpRequest, HttpResponse> requestHandler,
            string webSocketPath,
            Func<WebSocket, CancellationToken, Task> webSocketHandler,
            Action<string> logAction)
        {
            this.port = port;
            this.bindAll = bindAll;
            this.useTls = useTls;
            this.certificate = certificate;
            this.requestHandler = requestHandler;
            this.webSocketPath = webSocketPath;
            this.webSocketHandler = webSocketHandler;
            this.logAction = logAction;
        }

        public void Start()
        {
            cts = new CancellationTokenSource();
            var endpoint = bindAll ? new IPEndPoint(IPAddress.Any, port) : new IPEndPoint(IPAddress.Loopback, port);
            tcpListener = new TcpListener(endpoint);
            tcpListener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            tcpListener.Start();
            acceptTask = Task.Run(() => AcceptLoopAsync(cts.Token));
        }

        private readonly object stopLock = new object();

        public void Stop()
        {
            lock (stopLock)
            {
                var localCts = cts;
                var localTask = acceptTask;
                var localListener = tcpListener;

                localCts?.Cancel();
                try { localListener?.Stop(); } catch { }

                try { localTask?.Wait(TimeSpan.FromSeconds(3)); }
                catch (AggregateException) { }
                catch (OperationCanceledException) { }

                localCts?.Dispose();
                cts = null;
                acceptTask = null;
                tcpListener = null;
            }
        }

        private async Task AcceptLoopAsync(CancellationToken ct)
        {
            int activeConnections = 0;
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    TcpClient client = await tcpListener.AcceptTcpClientAsync();
                    // Increment first, then check — prevents race where multiple threads pass the check
                    if (Interlocked.Increment(ref activeConnections) > 100)
                    {
                        Interlocked.Decrement(ref activeConnections);
                        try { client.Close(); } catch { }
                        continue;
                    }
                    _ = Task.Run(async () =>
                    {
                        try { await HandleClientAsync(client, ct); }
                        finally { Interlocked.Decrement(ref activeConnections); }
                    });
                }
            }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                logAction?.Invoke("Accept loop error: " + ex.Message);
            }
        }

        private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
        {
            Stream stream = null;
            try
            {
                client.ReceiveTimeout = HeaderReadTimeout;
                client.SendTimeout = HeaderReadTimeout;
                stream = client.GetStream();

                if (useTls)
                {
                    var sslStream = new SslStream(stream, false);
                    using (var tlsCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                    {
                        tlsCts.CancelAfter(TlsHandshakeTimeout);
                        await sslStream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                        {
                            ServerCertificate = certificate,
                            EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                            ClientCertificateRequired = false
                        }, tlsCts.Token);
                    }
                    stream = sslStream;
                }

                // Parse HTTP request
                var request = await ReadHttpRequestAsync(stream, ct);
                if (request == null)
                {
                    await WriteErrorResponseAsync(stream, 400, "Bad Request");
                    return;
                }

                // Check for WebSocket upgrade
                if (webSocketPath != null && webSocketHandler != null &&
                    request.Path == webSocketPath &&
                    IsWebSocketUpgrade(request))
                {
                    await HandleWebSocketUpgradeAsync(stream, request, ct);
                    return; // Stream ownership transferred to WebSocket handler
                }

                // Normal HTTP request
                HttpResponse response;
                try
                {
                    response = requestHandler(request);
                }
                catch (Exception ex)
                {
                    logAction?.Invoke("Request handler error: " + ex.Message);
                    response = new HttpResponse(500, "Internal Server Error");
                }

                await WriteResponseAsync(stream, response);
            }
            catch (AuthenticationException) { }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (Exception ex)
            {
                logAction?.Invoke("Client handler error: " + ex.Message);
            }
            finally
            {
                try { stream?.Dispose(); } catch { }
                try { client?.Dispose(); } catch { }
            }
        }

        private const int MaxHeaderLineSize = 8192; // 8KB max per header line

        private async Task<HttpRequest> ReadHttpRequestAsync(Stream stream, CancellationToken ct)
        {
            // Read headers (line by line until empty line)
            var headerBytes = new List<byte>(4096);
            byte prev = 0;
            int consecutive = 0;
            int totalRead = 0;
            int lineLength = 0;

            // Read byte-by-byte until we find \r\n\r\n
            byte[] singleByte = new byte[1];
            while (totalRead < MaxRequestSize)
            {
                int read = await stream.ReadAsync(singleByte, 0, 1, ct);
                if (read == 0) return null; // Connection closed

                headerBytes.Add(singleByte[0]);
                totalRead++;
                lineLength++;

                // Detect \r\n\r\n
                if (singleByte[0] == '\n' && prev == '\r')
                {
                    consecutive++;
                    lineLength = 0; // Reset line length on newline
                    if (consecutive >= 2) break;
                }
                else if (singleByte[0] != '\r')
                {
                    consecutive = 0;
                }

                // Reject excessively long header lines
                if (lineLength > MaxHeaderLineSize) return null;

                prev = singleByte[0];
            }

            string headerText = Encoding.ASCII.GetString(headerBytes.ToArray());
            string[] lines = headerText.Split(new[] { "\r\n" }, StringSplitOptions.None);

            if (lines.Length < 1) return null;

            // Parse request line
            string[] requestParts = lines[0].Split(' ');
            if (requestParts.Length < 3) return null;

            var request = new HttpRequest
            {
                Method = requestParts[0].ToUpperInvariant(),
                Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            };

            // Parse path and query string
            string rawPath = requestParts[1];
            int queryIndex = rawPath.IndexOf('?');
            if (queryIndex >= 0)
            {
                request.Path = rawPath.Substring(0, queryIndex);
                request.Query = rawPath.Substring(queryIndex + 1);
            }
            else
            {
                request.Path = rawPath;
                request.Query = "";
            }

            // Parse headers
            for (int i = 1; i < lines.Length; i++)
            {
                if (string.IsNullOrEmpty(lines[i])) continue;
                int colonIndex = lines[i].IndexOf(':');
                if (colonIndex > 0)
                {
                    string key = lines[i].Substring(0, colonIndex).Trim();
                    string value = lines[i].Substring(colonIndex + 1).Trim();
                    request.Headers[key] = value;
                }
            }

            // Read body if Content-Length present
            if (request.Headers.TryGetValue("Content-Length", out string contentLengthStr) &&
                int.TryParse(contentLengthStr, out int contentLength) &&
                contentLength > 0)
            {
                if (contentLength > MaxRequestSize) return null;

                request.Body = new byte[contentLength];
                int offset = 0;
                while (offset < contentLength)
                {
                    int read = await stream.ReadAsync(request.Body, offset, contentLength - offset, ct);
                    if (read == 0) return null;
                    offset += read;
                }
            }

            return request;
        }

        private bool IsWebSocketUpgrade(HttpRequest request)
        {
            return request.Headers.TryGetValue("Upgrade", out string upgrade) &&
                   upgrade.Equals("websocket", StringComparison.OrdinalIgnoreCase) &&
                   request.Headers.TryGetValue("Connection", out string connection) &&
                   connection.IndexOf("Upgrade", StringComparison.OrdinalIgnoreCase) >= 0 &&
                   request.Headers.ContainsKey("Sec-WebSocket-Key");
        }

        private async Task HandleWebSocketUpgradeAsync(Stream stream, HttpRequest request, CancellationToken ct)
        {
            string key = request.Headers["Sec-WebSocket-Key"];
            string acceptKey = ComputeWebSocketAcceptKey(key);

            // Send 101 Switching Protocols
            string response = "HTTP/1.1 101 Switching Protocols\r\n" +
                              "Upgrade: websocket\r\n" +
                              "Connection: Upgrade\r\n" +
                              "Sec-WebSocket-Accept: " + acceptKey + "\r\n" +
                              "\r\n";

            byte[] responseBytes = Encoding.ASCII.GetBytes(response);
            await stream.WriteAsync(responseBytes, 0, responseBytes.Length, ct);
            await stream.FlushAsync(ct);

            // Create managed WebSocket from the stream
            var wsOptions = new WebSocketCreationOptions
            {
                IsServer = true,
                KeepAliveInterval = TimeSpan.FromSeconds(30)
            };

            using (var ws = WebSocket.CreateFromStream(stream, wsOptions))
            {
                try
                {
                    await webSocketHandler(ws, ct);
                }
                catch (WebSocketException) { }
                catch (OperationCanceledException) { }
                catch (Exception ex)
                {
                    logAction?.Invoke("WebSocket handler error: " + ex.Message);
                }
            }
        }

        private static string ComputeWebSocketAcceptKey(string key)
        {
            string combined = key + "258EAFA5-E914-47DA-95CA-5AB5FE80E65D";
            byte[] hash = SHA1.HashData(Encoding.ASCII.GetBytes(combined));
            return Convert.ToBase64String(hash);
        }

        private async Task WriteResponseAsync(Stream stream, HttpResponse response)
        {
            var sb = new StringBuilder();
            sb.Append("HTTP/1.1 ");
            sb.Append(response.StatusCode);
            sb.Append(' ');
            sb.Append(response.StatusText);
            sb.Append("\r\n");

            if (response.ContentType != null)
            {
                sb.Append("Content-Type: ");
                sb.Append(response.ContentType);
                sb.Append("\r\n");
            }

            int bodyLength = response.Body != null ? response.Body.Length : 0;
            sb.Append("Content-Length: ");
            sb.Append(bodyLength);
            sb.Append("\r\n");

            sb.Append("Connection: close\r\n");

            if (response.Headers != null)
            {
                foreach (var kvp in response.Headers)
                {
                    // Sanitize header values to prevent header injection via CRLF and null bytes
                    string safeKey = kvp.Key.Replace("\r", "").Replace("\n", "").Replace("\0", "").Replace("\u2028", "").Replace("\u2029", "");
                    string safeValue = kvp.Value.Replace("\r", "").Replace("\n", "").Replace("\0", "").Replace("\u2028", "").Replace("\u2029", "");
                    sb.Append(safeKey);
                    sb.Append(": ");
                    sb.Append(safeValue);
                    sb.Append("\r\n");
                }
            }

            sb.Append("\r\n");

            byte[] headerBytes = Encoding.ASCII.GetBytes(sb.ToString());
            await stream.WriteAsync(headerBytes, 0, headerBytes.Length);

            if (response.Body != null && response.Body.Length > 0)
            {
                await stream.WriteAsync(response.Body, 0, response.Body.Length);
            }

            await stream.FlushAsync();
        }

        private async Task WriteErrorResponseAsync(Stream stream, int statusCode, string message)
        {
            var response = new HttpResponse(statusCode, message);
            try { await WriteResponseAsync(stream, response); } catch { }
        }

        public void Dispose()
        {
            if (!disposed)
            {
                disposed = true;
                Stop();
            }
        }
    }
}
