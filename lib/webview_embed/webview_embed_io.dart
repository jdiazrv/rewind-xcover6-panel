import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Native (Android/iOS): embeds via the real webview_flutter plugin.
class PlatformWebView extends StatefulWidget {
  const PlatformWebView({
    super.key,
    required this.url,
    this.onPageStarted,
    this.onPageFinished,
    this.onError,
  });
  final String url;
  final VoidCallback? onPageStarted;
  final VoidCallback? onPageFinished;
  final VoidCallback? onError;

  @override
  State<PlatformWebView> createState() => _PlatformWebViewState();
}

class _PlatformWebViewState extends State<PlatformWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => widget.onPageStarted?.call(),
          onPageFinished: (_) => widget.onPageFinished?.call(),
          onWebResourceError: (_) => widget.onError?.call(),
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  void didUpdateWidget(PlatformWebView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _controller.loadRequest(Uri.parse(widget.url));
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(
    controller: _controller,
    // Without this, taps on our own overlay controls (e.g. the menu
    // reappear button) could lose the gesture arena to the WebView and
    // never register — same fix as before this file existed.
    gestureRecognizers: {
      Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
    },
  );
}
