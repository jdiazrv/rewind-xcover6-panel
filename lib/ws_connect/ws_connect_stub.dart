import 'package:web_socket_channel/web_socket_channel.dart';

/// Browsers don't allow custom headers on a WebSocket handshake (a browser
/// security restriction, not something this package can work around), so
/// Signal K's Basic Auth can't be applied here — only servers that allow
/// anonymous/local-network read access over WS will work from a web build.
/// [authBase64] is accepted for API symmetry with the native version, but
/// unused.
WebSocketChannel connectSignalKWs(Uri uri, {required String authBase64}) {
  return WebSocketChannel.connect(uri);
}
