/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    public class WebServer : IDisposable
    {
        private DataBrokerClient broker;
        private HttpListener listener;
        private CancellationTokenSource cts;
        private Task serverTask;
        private int port;
        private bool running = false;
        private string webRoot;

        public WebServer()
        {
            broker = new DataBrokerClient();

            broker.Subscribe(0, "WebServerEnabled", OnSettingChanged);
            broker.Subscribe(0, "WebServerPort", OnSettingChanged);
            broker.Subscribe(0, "ServerBindAll", OnSettingChanged);

            webRoot = Path.Combine(AppContext.BaseDirectory, "web");

            int enabled = broker.GetValue<int>(0, "WebServerEnabled", 0);
            if (enabled == 1)
            {
                port = broker.GetValue<int>(0, "WebServerPort", 8080);
                Start();
            }
        }

        private void OnSettingChanged(int deviceId, string name, object data)
        {
            int enabled = broker.GetValue<int>(0, "WebServerEnabled", 0);
            int newPort = broker.GetValue<int>(0, "WebServerPort", 8080);

            if (enabled == 1)
            {
                if (running && newPort != port)
                {
                    Stop();
                    port = newPort;
                    Start();
                }
                else if (!running)
                {
                    port = newPort;
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
                listener = new HttpListener();
                int bindAll = broker.GetValue<int>(0, "ServerBindAll", 0);
                string host = (bindAll == 1) ? "*" : "localhost";
                listener.Prefixes.Add("http://" + host + ":" + port + "/");
                listener.Start();
                running = true;
                serverTask = Task.Run(() => AcceptRequestsAsync(cts.Token), cts.Token);
                Log("Web server started on port " + port);
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
            cts?.Cancel();

            try { listener?.Stop(); } catch { }
            try { listener?.Close(); } catch { }

            try { serverTask?.Wait(TimeSpan.FromSeconds(3)); }
            catch (AggregateException) { }
            catch (OperationCanceledException) { }

            cts?.Dispose();
            cts = null;
            serverTask = null;
            listener = null;
            Log("Web server stopped");
        }

        private async Task AcceptRequestsAsync(CancellationToken ct)
        {
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    HttpListenerContext context = await listener.GetContextAsync();
                    _ = Task.Run(() => HandleRequest(context), ct);
                }
            }
            catch (HttpListenerException) { }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Log("Web server accept loop error: " + ex.Message);
            }
        }

        private void HandleRequest(HttpListenerContext context)
        {
            try
            {
                string urlPath = context.Request.Url.AbsolutePath;

                // API endpoint: return config for mobile web UI
                if (urlPath == "/api/config")
                {
                    int mcpPort = broker.GetValue<int>(0, "McpServerPort", 5678);
                    int mcpEnabled = broker.GetValue<int>(0, "McpServerEnabled", 0);
                    string json = "{\"mcpPort\":" + mcpPort + ",\"mcpEnabled\":" + (mcpEnabled == 1 ? "true" : "false") + "}";
                    context.Response.Headers.Add("Access-Control-Allow-Origin", "*");
                    context.Response.ContentType = "application/json";
                    byte[] buffer = Encoding.UTF8.GetBytes(json);
                    context.Response.ContentLength64 = buffer.Length;
                    context.Response.StatusCode = 200;
                    context.Response.OutputStream.Write(buffer, 0, buffer.Length);
                    return;
                }

                if (urlPath == "/") urlPath = "/index.html";

                string relativePath = Uri.UnescapeDataString(urlPath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar));

                // Security: prevent path traversal
                if (relativePath.Contains(".."))
                {
                    SendResponse(context, 400, "400 - Bad Request");
                    return;
                }

                string filePath = Path.Combine(webRoot, relativePath);

                // Ensure path stays within web root
                string fullPath = Path.GetFullPath(filePath);
                string fullWebRoot = Path.GetFullPath(webRoot);
                if (!fullPath.StartsWith(fullWebRoot, StringComparison.OrdinalIgnoreCase))
                {
                    SendResponse(context, 403, "403 - Forbidden");
                    return;
                }

                if (File.Exists(filePath))
                {
                    byte[] fileBytes = File.ReadAllBytes(filePath);
                    string mimeType = GetMimeType(filePath);

                    context.Response.ContentType = mimeType;
                    context.Response.ContentLength64 = fileBytes.Length;
                    context.Response.StatusCode = 200;
                    context.Response.OutputStream.Write(fileBytes, 0, fileBytes.Length);
                }
                else
                {
                    SendResponse(context, 404, "404 - File Not Found");
                }
            }
            catch (Exception)
            {
                try { SendResponse(context, 500, "500 - Internal Server Error"); } catch { }
            }
            finally
            {
                try { context.Response.OutputStream.Close(); } catch { }
            }
        }

        private void SendResponse(HttpListenerContext context, int statusCode, string body)
        {
            context.Response.StatusCode = statusCode;
            context.Response.ContentType = "text/plain";
            byte[] buffer = Encoding.UTF8.GetBytes(body);
            context.Response.ContentLength64 = buffer.Length;
            context.Response.OutputStream.Write(buffer, 0, buffer.Length);
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
            broker?.Dispose();
        }
    }
}
