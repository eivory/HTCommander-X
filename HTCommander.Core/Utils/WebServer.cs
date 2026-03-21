/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Collections.Generic;
using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    public class WebServer : IDisposable
    {
        private DataBrokerClient broker;
        private TlsHttpServer server;
        private int port;
        private bool running = false;
        private bool tlsEnabled = false;
        private string webRoot;
        private WebAudioBridge audioBridge;

        public WebServer()
        {
            broker = new DataBrokerClient();
            audioBridge = new WebAudioBridge();

            broker.Subscribe(0, "WebServerEnabled", OnSettingChanged);
            broker.Subscribe(0, "WebServerPort", OnSettingChanged);
            broker.Subscribe(0, "ServerBindAll", OnSettingChanged);
            broker.Subscribe(0, "TlsEnabled", OnSettingChanged);

            webRoot = Path.Combine(AppContext.BaseDirectory, "web");

            int enabled = broker.GetValue<int>(0, "WebServerEnabled", 0);
            if (enabled == 1)
            {
                port = broker.GetValue<int>(0, "WebServerPort", 8080);
                tlsEnabled = broker.GetValue<int>(0, "TlsEnabled", 0) == 1;
                Start();
            }
        }

        private void OnSettingChanged(int deviceId, string name, object data)
        {
            int enabled = broker.GetValue<int>(0, "WebServerEnabled", 0);
            int newPort = broker.GetValue<int>(0, "WebServerPort", 8080);
            bool newTls = broker.GetValue<int>(0, "TlsEnabled", 0) == 1;

            if (enabled == 1)
            {
                if (running && (newPort != port || newTls != tlsEnabled))
                {
                    Stop();
                    port = newPort;
                    tlsEnabled = newTls;
                    Start();
                }
                else if (!running)
                {
                    port = newPort;
                    tlsEnabled = newTls;
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
                int bindAll = broker.GetValue<int>(0, "ServerBindAll", 0);
                X509Certificate2 cert = null;

                if (tlsEnabled)
                {
                    string configDir = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                        "HTCommander");
                    cert = TlsCertificateManager.GetOrCreateCertificate(configDir);
                }

                server = new TlsHttpServer(
                    port,
                    bindAll == 1,
                    tlsEnabled,
                    cert,
                    HandleRequest,
                    "/ws/audio",
                    HandleWebSocketAsync,
                    Log);

                server.Start();
                running = true;
                string protocol = tlsEnabled ? "HTTPS" : "HTTP";
                Log("Web server started on port " + port + " (" + protocol + ")");
            }
            catch (Exception ex)
            {
                Log("Web server start failed: " + ex.Message);
                running = false;
            }
        }

        private void Stop()
        {
            if (!running) return;
            Log("Web server stopping...");
            running = false;
            audioBridge?.DisconnectAll();
            server?.Stop();
            server = null;
            Log("Web server stopped");
        }

        private async Task HandleWebSocketAsync(WebSocket ws, CancellationToken ct)
        {
            await audioBridge.HandleWebSocketAsync(ws, ct);
        }

        private TlsHttpServer.HttpResponse HandleRequest(TlsHttpServer.HttpRequest request)
        {
            string urlPath = request.Path;

            // API endpoint: return config for mobile web UI
            if (urlPath == "/api/config")
            {
                int mcpPort = broker.GetValue<int>(0, "McpServerPort", 5678);
                int mcpEnabled = broker.GetValue<int>(0, "McpServerEnabled", 0);
                int bindAllSetting = broker.GetValue<int>(0, "ServerBindAll", 0);

                // When ServerBindAll is enabled, require Bearer token to access config (which includes mcpToken)
                string mcpToken = broker.GetValue<string>(0, "McpApiToken", "") ?? "";
                if (bindAllSetting == 1 && !string.IsNullOrEmpty(mcpToken))
                {
                    string authHeader = request.Headers != null && request.Headers.ContainsKey("Authorization") ? request.Headers["Authorization"] : null;
                    // Constant-time comparison of full "Bearer <token>" string to prevent timing leaks
                    string expectedAuth = "Bearer " + mcpToken;
                    bool authValid = authHeader != null &&
                        authHeader.Length == expectedAuth.Length &&
                        System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(
                            Encoding.UTF8.GetBytes(authHeader),
                            Encoding.UTF8.GetBytes(expectedAuth));
                    if (!authValid)
                    {
                        return new TlsHttpServer.HttpResponse(401, "401 - Unauthorized");
                    }
                }

                var configObj = new Dictionary<string, object>
                {
                    ["mcpPort"] = mcpPort,
                    ["mcpEnabled"] = mcpEnabled == 1,
                    ["tlsEnabled"] = tlsEnabled
                };
                if (!string.IsNullOrEmpty(mcpToken)) configObj["mcpToken"] = mcpToken;
                string json = System.Text.Json.JsonSerializer.Serialize(configObj);
                var resp = new TlsHttpServer.HttpResponse
                {
                    StatusCode = 200,
                    StatusText = "OK",
                    ContentType = "application/json",
                    Body = Encoding.UTF8.GetBytes(json)
                };
                resp.Headers["Cache-Control"] = "no-store, no-cache";
                // CORS restricted to localhost/LAN origins
                string origin = request.Headers != null && request.Headers.ContainsKey("Origin") ? request.Headers["Origin"] : null;
                string allowedOrigin = ValidateCorsOrigin(origin);
                if (allowedOrigin != null)
                    resp.Headers["Access-Control-Allow-Origin"] = allowedOrigin;
                resp.Headers["Vary"] = "Origin";
                return resp;
            }

            if (urlPath == "/") urlPath = "/index.html";

            string relativePath = Uri.UnescapeDataString(urlPath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar));

            // Security: prevent path traversal
            if (relativePath.Contains(".."))
            {
                return new TlsHttpServer.HttpResponse(400, "400 - Bad Request");
            }

            string filePath = Path.Combine(webRoot, relativePath);

            // Ensure path stays within web root
            string fullPath = Path.GetFullPath(filePath);
            string fullWebRoot = Path.GetFullPath(webRoot);
            if (!fullPath.StartsWith(fullWebRoot, StringComparison.Ordinal))
            {
                return new TlsHttpServer.HttpResponse(403, "403 - Forbidden");
            }

            if (File.Exists(fullPath))
            {
                byte[] fileBytes = File.ReadAllBytes(fullPath);
                string mimeType = GetMimeType(fullPath);

                var fileResp = new TlsHttpServer.HttpResponse
                {
                    StatusCode = 200,
                    StatusText = "OK",
                    ContentType = mimeType,
                    Body = fileBytes
                };
                fileResp.Headers["X-Content-Type-Options"] = "nosniff";
                fileResp.Headers["X-Frame-Options"] = "DENY";
                fileResp.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
                return fileResp;
            }
            else
            {
                return new TlsHttpServer.HttpResponse(404, "404 - File Not Found");
            }
        }

        private string GetMimeType(string filePath)
        {
            string extension = Path.GetExtension(filePath).ToLowerInvariant();
            switch (extension)
            {
                case ".html":
                case ".htm": return "text/html";
                case ".css": return "text/css";
                case ".js": return "application/javascript";
                case ".json": return "application/json";
                case ".png": return "image/png";
                case ".jpg":
                case ".jpeg": return "image/jpeg";
                case ".gif": return "image/gif";
                case ".svg": return "image/svg+xml";
                case ".ico": return "image/x-icon";
                case ".woff": return "font/woff";
                case ".woff2": return "font/woff2";
                default: return "application/octet-stream";
            }
        }

        /// <summary>
        /// Validates a CORS origin against allowed patterns (localhost/loopback/LAN origins).
        /// </summary>
        private static string ValidateCorsOrigin(string origin)
        {
            if (string.IsNullOrEmpty(origin)) return null;
            if (!Uri.TryCreate(origin, UriKind.Absolute, out Uri uri)) return null;
            string host = uri.Host;
            if (host == "localhost" || host == "127.0.0.1" || host == "::1") return origin;
            if (System.Net.IPAddress.TryParse(host, out var ip))
            {
                if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
                byte[] bytes = ip.GetAddressBytes();
                if (bytes.Length == 4 &&
                    (bytes[0] == 10 || bytes[0] == 127 ||
                     (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                     (bytes[0] == 192 && bytes[1] == 168)))
                    return origin;
                if (bytes.Length == 16 &&
                    (System.Net.IPAddress.IsLoopback(ip) ||
                     ip.IsIPv6LinkLocal ||
                     (bytes[0] & 0xFE) == 0xFC))
                    return origin;
            }
            return null;
        }

        private void Log(string message)
        {
            broker?.LogInfo(message);
        }

        public void Dispose()
        {
            Stop();
            audioBridge?.Dispose();
            broker?.Dispose();
        }
    }
}
