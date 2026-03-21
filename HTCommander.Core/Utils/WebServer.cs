/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
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
                string json = "{\"mcpPort\":" + mcpPort +
                              ",\"mcpEnabled\":" + (mcpEnabled == 1 ? "true" : "false") +
                              ",\"tlsEnabled\":" + (tlsEnabled ? "true" : "false") + "}";
                var resp = new TlsHttpServer.HttpResponse
                {
                    StatusCode = 200,
                    StatusText = "OK",
                    ContentType = "application/json",
                    Body = Encoding.UTF8.GetBytes(json)
                };
                resp.Headers["Access-Control-Allow-Origin"] = "*";
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
            if (!fullPath.StartsWith(fullWebRoot, StringComparison.OrdinalIgnoreCase))
            {
                return new TlsHttpServer.HttpResponse(403, "403 - Forbidden");
            }

            if (File.Exists(filePath))
            {
                byte[] fileBytes = File.ReadAllBytes(filePath);
                string mimeType = GetMimeType(filePath);

                return new TlsHttpServer.HttpResponse
                {
                    StatusCode = 200,
                    StatusText = "OK",
                    ContentType = mimeType,
                    Body = fileBytes
                };
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
