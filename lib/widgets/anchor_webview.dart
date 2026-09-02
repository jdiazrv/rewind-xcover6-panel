part of '../main.dart';

// ─── Anchor page: embedded Freeboard-SK view ──────────────────────────────────
// Used only for Freeboard-SK now (_mapPage) — the old hoekens-anchor-alarm
// embed this was originally written for (with its device-GPS-consent flow,
// since arming the plugin's own anchor needed a position source) is gone,
// fully replaced by the native ANC screen (NativeAnchorView). Freeboard
// never needs any of that: it just shows a chart from Signal K's own
// position, no GPS fallback, no "missing plugin" case to explain.
class _AnchorWebView extends StatefulWidget {
  const _AnchorWebView({
    required this.host,
    required this.port,
    this.path = '/@signalk/freeboard-sk/',
    this.label = 'Freeboard-SK',
    this.demo = false,
    this.demoExplainer,
    this.authBase64 = '',
    this.skUsername = '',
    this.skPassword = '',
  });
  final String host;
  final int port;
  final String path;
  final String label;
  final bool demo;
  final String? demoExplainer;
  // Same Signal K Basic Auth the app's own REST/WS calls use (see
  // settings.authBase64) — without it, this WebView starts as an
  // anonymous/readonly session on a server that requires login for write
  // actions, which is why arming the anchor could silently fail here
  // while working fine in a browser that had separately logged in before.
  final String authBase64;
  // Signal K username/password (CFG > Conexión > "Sesión web") — when
  // set, logs this WebView into a real Signal K session once per page
  // load (see PlatformWebView.skLogin), so features that check the
  // browser's own logged-in state (not just Basic Auth on the transport)
  // work without asking again — persists in the WebView's own storage
  // across app restarts and updates.
  final String skUsername;
  final String skPassword;
  @override
  State<_AnchorWebView> createState() => _AnchorWebViewState();
}

class _AnchorWebViewState extends State<_AnchorWebView>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _error = false;
  int _reloadNonce = 0;

  @override
  bool get wantKeepAlive => true;

  String get _url => 'http://${widget.host}:${widget.port}${widget.path}';

  void _reload() {
    setState(() {
      _loading = true;
      _error = false;
      _reloadNonce++;
    });
  }

  @override
  void didUpdateWidget(_AnchorWebView old) {
    super.didUpdateWidget(old);
    if (!widget.demo &&
        (old.host != widget.host ||
            old.port != widget.port ||
            old.path != widget.path)) {
      _loading = true;
      _error = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.demo) {
      return Container(
        color: cBg,
        padding: const EdgeInsets.all(32),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off, color: cMuted, size: 48),
            const SizedBox(height: 16),
            Text(
              widget.label,
              style: const TextStyle(
                color: cText,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.demoExplainer ??
                  'Aquí se mostraría ${widget.label}, embebido desde el servidor Signal K.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: cMuted, fontSize: 15),
            ),
            const SizedBox(height: 14),
            const Text(
              'No disponible en modo DEMO.',
              style: TextStyle(
                color: cOrange,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        PlatformWebView(
          key: ValueKey(_reloadNonce),
          url: _url,
          headers: widget.authBase64.isEmpty
              ? null
              : {'Authorization': 'Basic ${widget.authBase64}'},
          skLogin: widget.skUsername.isEmpty || widget.skPassword.isEmpty
              ? null
              : (username: widget.skUsername, password: widget.skPassword),
          // Freeboard-SK uses Signal K's own position, never the browser's
          // JS Geolocation — this only ever mattered for the old hoekens
          // GPS-fallback flow, gone along with the rest of that class.
          allowGeolocation: false,
          onPageStarted: () {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: () {
            if (mounted) setState(() => _loading = false);
          },
          onError: () {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = true;
              });
            }
          },
        ),
        if (_loading)
          const Center(child: CircularProgressIndicator(color: cCyan)),
        if (_error)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.web_asset_off, color: cMuted, size: 48),
                const SizedBox(height: 12),
                Text(
                  'No se puede cargar ${widget.label}',
                  style: const TextStyle(color: cMuted, fontSize: 18),
                ),
                const SizedBox(height: 6),
                Text(
                  _url,
                  style: const TextStyle(color: cOrange, fontSize: 12),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                  onPressed: _reload,
                ),
              ],
            ),
          ),
        Positioned(
          top: 28,
          left: 8,
          child: GestureDetector(
            onTap: _reload,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.refresh, color: cMuted, size: 20),
            ),
          ),
        ),
      ],
    );
  }
}
