import 'package:flutter/material.dart';

/// Fallback for platforms with neither webview_flutter nor a browser DOM
/// (shouldn't be reachable — this app only targets Android and web).
class PlatformWebView extends StatelessWidget {
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
  final Map<String, String>? headers;
  final ({String username, String password})? skLogin;
  final bool allowGeolocation;
  final VoidCallback? onPageStarted;
  final VoidCallback? onPageFinished;
  final VoidCallback? onError;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
