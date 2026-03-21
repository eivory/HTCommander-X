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
using System.Security.Cryptography.X509Certificates;
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
        private TlsHttpServer server;
        private McpProtocolHandler protocolHandler;
        private McpTools tools;
        private McpResources resources;
        private int port;
        private bool running = false;
        private bool tlsEnabled = false;

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
            broker.Subscribe(0, "TlsEnabled", OnSettingChanged);

            int enabled = broker.GetValue<int>(0, "McpServerEnabled", 0);
            if (enabled == 1)
            {
                port = broker.GetValue<int>(0, "McpServerPort", 5678);
                tlsEnabled = broker.GetValue<int>(0, "TlsEnabled", 0) == 1;
                Start();
            }
        }

        private void OnSettingChanged(int deviceId, string name, object data)
        {
            int enabled = broker.GetValue<int>(0, "McpServerEnabled", 0);
            int newPort = broker.GetValue<int>(0, "McpServerPort", 5678);
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
                    null, // No WebSocket support
                    null,
                    Log);

                server.Start();
                running = true;
                string protocol = tlsEnabled ? "HTTPS" : "HTTP";
                Log("MCP server started on port " + port + " (" + protocol + ")");
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
            server?.Stop();
            server = null;
            Log("MCP server stopped");
        }

        private TlsHttpServer.HttpResponse HandleRequest(TlsHttpServer.HttpRequest request)
        {
            var response = new TlsHttpServer.HttpResponse();

            // Add CORS headers
            response.Headers["Access-Control-Allow-Origin"] = "*";
            response.Headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
            response.Headers["Access-Control-Allow-Headers"] = "Content-Type";

            // Handle preflight
            if (request.Method == "OPTIONS")
            {
                response.StatusCode = 204;
                response.StatusText = "No Content";
                return response;
            }

            // Only accept POST
            if (request.Method != "POST")
            {
                response.StatusCode = 405;
                response.StatusText = "Method Not Allowed";
                response.ContentType = "application/json";
                response.Body = Encoding.UTF8.GetBytes("{\"error\":\"Method not allowed. Use POST.\"}");
                return response;
            }

            try
            {
                // Read request body
                string requestBody = request.Body != null ? Encoding.UTF8.GetString(request.Body) : "";

                // Process JSON-RPC request
                string responseBody = protocolHandler.ProcessRequest(requestBody);

                if (responseBody == null)
                {
                    // Notification — no response needed
                    response.StatusCode = 204;
                    response.StatusText = "No Content";
                    return response;
                }

                response.StatusCode = 200;
                response.StatusText = "OK";
                response.ContentType = "application/json";
                response.Body = Encoding.UTF8.GetBytes(responseBody);
                return response;
            }
            catch (Exception ex)
            {
                Log("MCP request error: " + ex.Message);
                response.StatusCode = 500;
                response.StatusText = "Internal Server Error";
                response.ContentType = "application/json";
                response.Body = Encoding.UTF8.GetBytes("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error\"}}");
                return response;
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
