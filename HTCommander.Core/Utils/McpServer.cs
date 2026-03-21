/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

// MCP (Model Context Protocol) HTTP server for AI-powered radio control and debugging.
// Exposes HTCommander functionality as MCP tools and resources via JSON-RPC 2.0 over HTTP.
// Follows the same DataBroker data handler pattern as RigctldServer and AgwpeServer.

using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HTCommander
{
    /// <summary>
    /// MCP server data handler. Listens for HTTP requests on a configurable port
    /// and handles MCP JSON-RPC 2.0 protocol messages for radio control and debugging.
    /// Auto-starts/stops based on McpServerEnabled and McpServerPort settings.
    /// </summary>
    public class McpServer : IDisposable
    {
        private DataBrokerClient broker;
        private HttpListener listener;
        private CancellationTokenSource cts;
        private Task serverTask;
        private McpProtocolHandler protocolHandler;
        private McpTools tools;
        private McpResources resources;
        private int port;
        private bool running = false;

        public McpServer()
        {
            broker = new DataBrokerClient();
            tools = new McpTools(broker);
            resources = new McpResources(broker);
            protocolHandler = new McpProtocolHandler(tools, resources);

            broker.Subscribe(0, "McpServerEnabled", OnSettingChanged);
            broker.Subscribe(0, "McpServerPort", OnSettingChanged);
            broker.Subscribe(0, "McpDebugToolsEnabled", OnSettingChanged);
            broker.Subscribe(0, "ServerBindAll", OnSettingChanged);

            int enabled = broker.GetValue<int>(0, "McpServerEnabled", 0);
            if (enabled == 1)
            {
                port = broker.GetValue<int>(0, "McpServerPort", 5678);
                Start();
            }
        }

        private void OnSettingChanged(int deviceId, string name, object data)
        {
            int enabled = broker.GetValue<int>(0, "McpServerEnabled", 0);
            int newPort = broker.GetValue<int>(0, "McpServerPort", 5678);

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
                Log("MCP server started on port " + port);
            }
            catch (Exception ex)
            {
                Log("MCP server start failed: " + ex.Message);
                running = false;
            }
        }

        private void Stop()
        {
            if (!running) return;
            Log("MCP server stopping...");
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
            Log("MCP server stopped");
        }

        private async Task AcceptRequestsAsync(CancellationToken ct)
        {
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    HttpListenerContext context = await listener.GetContextAsync();
                    // Handle each request on the thread pool
                    _ = Task.Run(() => HandleRequestAsync(context), ct);
                }
            }
            catch (HttpListenerException) { }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Log("MCP accept loop error: " + ex.Message);
            }
        }

        private async Task HandleRequestAsync(HttpListenerContext context)
        {
            var request = context.Request;
            var response = context.Response;

            try
            {
                // Add CORS headers
                response.Headers.Add("Access-Control-Allow-Origin", "*");
                response.Headers.Add("Access-Control-Allow-Methods", "POST, OPTIONS");
                response.Headers.Add("Access-Control-Allow-Headers", "Content-Type");

                // Handle preflight
                if (request.HttpMethod == "OPTIONS")
                {
                    response.StatusCode = 204;
                    response.Close();
                    return;
                }

                // Only accept POST
                if (request.HttpMethod != "POST")
                {
                    response.StatusCode = 405;
                    byte[] errBytes = Encoding.UTF8.GetBytes("{\"error\":\"Method not allowed. Use POST.\"}");
                    response.ContentType = "application/json";
                    response.ContentLength64 = errBytes.Length;
                    await response.OutputStream.WriteAsync(errBytes, 0, errBytes.Length);
                    response.Close();
                    return;
                }

                // Read request body
                string requestBody;
                using (var reader = new StreamReader(request.InputStream, Encoding.UTF8))
                {
                    requestBody = await reader.ReadToEndAsync();
                }

                // Process JSON-RPC request
                string responseBody = protocolHandler.ProcessRequest(requestBody);

                if (responseBody == null)
                {
                    // Notification — no response needed (but HTTP requires something)
                    response.StatusCode = 204;
                    response.Close();
                    return;
                }

                // Write response
                byte[] responseBytes = Encoding.UTF8.GetBytes(responseBody);
                response.ContentType = "application/json";
                response.ContentLength64 = responseBytes.Length;
                await response.OutputStream.WriteAsync(responseBytes, 0, responseBytes.Length);
                response.Close();
            }
            catch (Exception ex)
            {
                Log("MCP request error: " + ex.Message);
                try
                {
                    response.StatusCode = 500;
                    byte[] errBytes = Encoding.UTF8.GetBytes("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error\"}}");
                    response.ContentType = "application/json";
                    response.ContentLength64 = errBytes.Length;
                    await response.OutputStream.WriteAsync(errBytes, 0, errBytes.Length);
                    response.Close();
                }
                catch { }
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
