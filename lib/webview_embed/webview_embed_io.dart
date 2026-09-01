import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Native (Android/iOS): embeds via the real webview_flutter plugin.
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
  // Sent on the initial navigation request only (e.g. HTTP Basic Auth) —
  // see anchor_webview.dart for why this matters: without it, an embedded
  // Signal K webapp that requires auth for write actions (like arming the
  // anchor) never gets a chance to authenticate, since this WebView starts
  // with no session/credentials of its own.
  final Map<String, String>? headers;
  // Signal K username/password (settings.skUsername/skPassword) — when
  // set, logged into *from inside the WebView's own page* once it
  // finishes loading (see onPageFinished below), so the resulting session
  // cookie lands in the WebView's own cookie jar exactly like a real
  // browser login would. That jar is part of the Android System WebView's
  // persistent storage, not this app's own version/build, so once logged
  // in this survives app updates and future launches without asking
  // again — the whole point of exposing this as a saved credential
  // instead of a one-off action.
  final ({String username, String password})? skLogin;
  // Whether the JS Geolocation prompt (see initState below) should be
  // answered with the device's own GPS. Default true so other WebView
  // uses (Freeboard, etc.) keep working as before; anchor_webview.dart
  // passes false whenever Signal K already has a vessel position — the
  // device's GPS is a fallback for "no boat position at all", not a
  // second source to blend with/override the boat's own fix.
  final bool allowGeolocation;
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
          onPageFinished: (_) {
            _loginIfConfigured();
            widget.onPageFinished?.call();
          },
          onWebResourceError: (_) => widget.onError?.call(),
        ),
      );
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      // Auto-approve the JS Geolocation API prompt so a "set anchor at my
      // current position" style feature can get a real GPS fix the same
      // way a normal mobile browser would — the manifest permission alone
      // (see AndroidManifest.xml) isn't enough, WebView still needs this
      // callback answered or getCurrentPosition just hangs/fails silently.
      // The OS runtime permission itself (Android 6+) still has to be
      // granted separately — WebView doesn't trigger that system prompt on
      // its own, the hosting app has to ask, hence the explicit request
      // below. Fire-and-forget: if the user denies it, geolocation simply
      // keeps failing exactly as it did before this change, nothing new
      // to handle.
      unawaited(platform.setGeolocationEnabled(true));
      unawaited(
        platform.setGeolocationPermissionsPromptCallbacks(
          // Re-evaluated on every prompt (not just once at setup) via
          // `widget.allowGeolocation`, which the State's `widget` getter
          // always resolves to the latest widget instance — so this stays
          // in sync as the caller's vessel-position state changes across
          // rebuilds, without needing to re-register the callback.
          onShowPrompt: (request) async => GeolocationPermissionsResponse(
            allow: widget.allowGeolocation,
            retain: false,
          ),
        ),
      );
      if (widget.allowGeolocation) {
        unawaited(Permission.locationWhenInUse.request());
      }
    }
    _controller.loadRequest(
      Uri.parse(widget.url),
      headers: widget.headers ?? const {},
    );
  }

  // Fires a normal Signal K JWT login request via `fetch` *from inside the
  // page*, so the resulting Set-Cookie is captured by the WebView's own
  // cookie jar the same way it would be for a real login form submit —
  // our own Dart-side `http.post` calls elsewhere in the app can't do
  // this, they have a completely separate cookie/network stack from the
  // WebView. Errors are swallowed: this is a convenience best-effort
  // (skip it and the page just stays whatever it already was —
  // read-only if never logged in, still logged in if a previous session
  // cookie is still valid).
  void _loginIfConfigured() {
    final login = widget.skLogin;
    if (login == null || login.username.isEmpty || login.password.isEmpty) {
      return;
    }
    final body = jsonEncode({
      'username': login.username,
      'password': login.password,
    });
    unawaited(
      _controller.runJavaScript('''
        fetch('/signalk/v1/auth/login', {
          method: 'POST',
          credentials: 'include',
          headers: { 'Content-Type': 'application/json' },
          body: ${jsonEncode(body)}
        }).catch(function(){});
      '''),
    );
  }

  @override
  void didUpdateWidget(PlatformWebView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _controller.loadRequest(
        Uri.parse(widget.url),
        headers: widget.headers ?? const {},
      );
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
