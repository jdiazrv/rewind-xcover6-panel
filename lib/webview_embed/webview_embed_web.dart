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
