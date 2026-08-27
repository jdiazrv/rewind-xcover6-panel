import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native (Android/iOS/desktop): dart:io's WebSocket supports custom
/// headers, so Signal K's Basic Auth can ride on the handshake itself.
WebSocketChannel connectSignalKWs(Uri uri, {required String authBase64}) {
  return IOWebSocketChannel.connect(
    uri,
    headers: authBase64.isEmpty ? null : {'Authorization': 'Basic $authBase64'},
    pingInterval: const Duration(seconds: 20),
  );
}
