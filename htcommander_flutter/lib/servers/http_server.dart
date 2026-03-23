/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:io';

/// Lightweight HTTP server using dart:io HttpServer.
///
/// Provides request routing, static file serving, and CORS header helpers.
/// Base framework that MCP and Web servers build on.
class SimpleHttpServer {
  final int port;
  final bool bindAll;
  final Future<void> Function(HttpRequest request) handler;
  final void Function(String message)? logger;

  HttpServer? _server;
  bool _running = false;

  bool get isRunning => _running;

  SimpleHttpServer({
    required this.port,
    this.bindAll = false,
    required this.handler,
    this.logger,
  });

  /// Start the HTTP server.
  Future<void> start() async {
    if (_running) return;
    try {
      final address =
          bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      _server = await HttpServer.bind(address, port, shared: true);
      _running = true;
      _log('HTTP server started on port $port'
          '${bindAll ? " (all interfaces)" : " (loopback only)"}');

      _server!.listen(
        (request) async {
          try {
            await handler(request);
          } catch (e) {
            try {
              request.response.statusCode = HttpStatus.internalServerError;
              request.response.write('Internal Server Error');
              await request.response.close();
            } catch (_) {}
          }
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (e) {
      _running = false;
      _log('HTTP server start failed: $e');
      rethrow;
    }
  }

  /// Stop the HTTP server.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _server?.close(force: true);
    _server = null;
    _log('HTTP server stopped');
  }

  /// Dispose the server.
  Future<void> dispose() async {
    await stop();
  }

  void _log(String message) {
    logger?.call(message);
  }

  // --- Static helpers ---

  /// Get MIME type for a file extension.
  static String getMimeType(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'html':
      case 'htm':
        return 'text/html';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
      case 'json':
        return 'application/json';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'ico':
        return 'image/x-icon';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      default:
        return 'application/octet-stream';
    }
  }

  /// Validates a CORS origin against allowed patterns (localhost/loopback/LAN).
  /// Returns the origin if valid, null otherwise.
  static String? validateCorsOrigin(String? origin) {
    if (origin == null || origin.isEmpty) return null;
    final uri = Uri.tryParse(origin);
    if (uri == null) return null;
    final host = uri.host;
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return origin;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip != null) {
      final bytes = ip.rawAddress;
      // IPv4 private ranges
      if (bytes.length == 4 &&
          (bytes[0] == 10 ||
              bytes[0] == 127 ||
              (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168))) {
        return origin;
      }
      // IPv6 loopback, link-local (fe80::/10), unique local (fc00::/7)
      if (bytes.length == 16 &&
          (ip.isLoopback ||
              ip.isLinkLocal ||
              (bytes[0] & 0xFE) == 0xFC)) {
        return origin;
      }
    }
    return null;
  }

  /// Add CORS headers to a response if origin is valid.
  static void addCorsHeaders(HttpResponse response, String? origin,
      {String methods = 'POST, OPTIONS',
      String headers = 'Content-Type, Authorization'}) {
    final allowed = validateCorsOrigin(origin);
    if (allowed != null) {
      response.headers.set('Access-Control-Allow-Origin', allowed);
      response.headers.set('Access-Control-Allow-Methods', methods);
      response.headers.set('Access-Control-Allow-Headers', headers);
    }
    response.headers.set('Vary', 'Origin');
  }

  /// Serve a static file from disk.
  static Future<void> serveStaticFile(
      HttpRequest request, String fullPath) async {
    final file = File(fullPath);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      final mimeType = getMimeType(fullPath);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.parse(mimeType);
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      request.response.headers.set('X-Frame-Options', 'DENY');
      request.response.headers
          .set('Referrer-Policy', 'strict-origin-when-cross-origin');
      request.response.add(bytes);
      await request.response.close();
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('404 - File Not Found');
      await request.response.close();
    }
  }
}
