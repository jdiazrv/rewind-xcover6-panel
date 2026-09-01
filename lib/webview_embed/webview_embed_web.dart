import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Web: webview_flutter has no browser implementation (it only ships
/// Android/iOS platform code — using it on web silently does nothing,
/// which is why MAP/ANC showed blank in the Signal K webapp build).
/// Embeds the same URL as a plain `<iframe>` instead, the only way a
/// Flutter web app can show external page content.
///
/// Cross-origin iframes can't report fine-grained load/error state to the
/// parent page (a browser security restriction), so [onError] never fires
/// here and [onPageFinished] fires on the iframe's own `load` event
/// (whether that inner page rendered successfully or shows its own error).
class PlatformWebView extends StatefulWidget {
  const PlatformWebView({
    super.key,
    required this.url,
    this.headers,
    this.skLogin,
    this.allowGeolocation = true,
    this.onPageStarted,
    this.onPageFinished,
    this.onError,
  });
  final String url;
  // Unused on web: an <iframe> can't attach custom request headers (a
  // browser security restriction) — accepted only so call sites don't need
  // platform-specific branching.
  final Map<String, String>? headers;
  // Unused on web — when this build IS the Signal K webapp (see
  // _isSignalKWebapp), the iframe already shares the host page's own
  // logged-in session/cookies on the same origin, nothing extra to do.
  final ({String username, String password})? skLogin;
  // Unused on web — an iframe's own geolocation permission is handled by
  // the browser itself, not something this app can answer programmatically.
  final bool allowGeolocation;
  final VoidCallback? onPageStarted;
  final VoidCallback? onPageFinished;
  final VoidCallback? onError;

  @override
  State<PlatformWebView> createState() => _PlatformWebViewState();
}

class _PlatformWebViewState extends State<PlatformWebView> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType =
        'rewind-iframe-${identityHashCode(this)}-${DateTime.now().microsecondsSinceEpoch}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = web.HTMLIFrameElement()
        ..src = widget.url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      iframe.onLoad.listen((_) => widget.onPageFinished?.call());
      return iframe;
    });
    widget.onPageStarted?.call();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
