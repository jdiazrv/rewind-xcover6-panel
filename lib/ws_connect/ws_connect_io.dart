import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native (Android/iOS/desktop): dart:io's WebSocket supports custom
/// headers, so Signal K's Basic Auth can ride on the handshake itself.
///
/// [bearerToken], when given, takes priority over [authBase64] — needed
/// because this server's WS delta *writes* (not just subscribing/reading)
/// are only accepted over a connection authenticated with a real session
/// token from /signalk/v1/auth/login; Basic Auth reads fine but publishes
/// silently vanish (confirmed live 2026-09-01: no WS echo, no REST
/// readback, vs. both working immediately with a Bearer token instead).
WebSocketChannel connectSignalKWs(
  Uri uri, {
  required String authBase64,
  String? bearerToken,
}) {
  return IOWebSocketChannel.connect(
    uri,
    headers: bearerToken != null
        ? {'Authorization': 'Bearer $bearerToken'}
        : (authBase64.isEmpty ? null : {'Authorization': 'Basic $authBase64'}),
    pingInterval: const Duration(seconds: 20),
  );
}
