part of '../main.dart';

// ─── Anchor page: embedded Hoeken/Freeboard-SK view ───────────────────────────
class _AnchorWebView extends StatefulWidget {
  const _AnchorWebView({
    required this.host,
    required this.port,
    this.path = '/hoekens-anchor-alarm/',
    this.label = 'Ancla',
    this.missingPluginHint,
    this.demo = false,
    this.demoExplainer,
    this.authBase64 = '',
    this.hasVesselPosition = false,
    this.skUsername = '',
    this.skPassword = '',
    this.offerGpsFallback = false,
    this.gpsFallbackConsent,
    this.onGpsFallbackConsentChanged,
  });
  final String host;
  final int port;
  final String path;
  final String label;
  final String? missingPluginHint;
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
  // Whether Signal K currently has a vessel position (navigation.position)
  // — when true, the device's own GPS is NOT offered to the plugin's JS
  // Geolocation calls, only the boat's own Signal K position should be
  // used for anchoring. The tablet's own GPS is a fallback for when the
  // boat has no position source at all, not a competing source: it can
  // read a different (sometimes worse/stale) fix than the boat's own GPS,
  // which is what made the anchor point appear to "jump" once real Signal
  // K data caught up.
  final bool hasVesselPosition;
  // Only true for the ANC screen's own instance (see _anchorPage) — the
  // GPS-fallback offer is an anchor-specific feature, MAP/Freeboard never
  // asks for location at all regardless of vessel position.
  final bool offerGpsFallback;
  // null = user has never been asked; true/false = their remembered
  // choice (settings.gpsFallbackConsent, see models.dart). A privacy
  // decision, so it's asked explicitly on first need rather than assumed
  // — see the dialog in initState below.
  final bool? gpsFallbackConsent;
  final ValueChanged<bool>? onGpsFallbackConsentChanged;
  @override
  State<_AnchorWebView> createState() => _AnchorWebViewState();
}

class _AnchorWebViewState extends State<_AnchorWebView>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _error = false;
  int _reloadNonce = 0;
  // Guards the consent dialog to at most once per time this widget
  // becomes eligible to ask (not once ever — if the user says no and
  // later Signal K genuinely loses its position on a fresh visit, asking
  // again is reasonable; what must never happen is asking repeatedly on
  // every rebuild while waiting for an answer, or asking at all when a
  // vessel position is already available).
  bool _askedThisSession = false;

  bool get _wantsGpsFallback =>
      widget.offerGpsFallback &&
      !widget.hasVesselPosition &&
      widget.gpsFallbackConsent == true;

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
  void initState() {
    super.initState();
    _maybeAskGpsConsent();
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
    if (old.hasVesselPosition && !widget.hasVesselPosition) {
      // Position was just lost — worth asking again even if declined on
      // a previous visit to this screen.
      _askedThisSession = false;
    }
    _maybeAskGpsConsent();
  }

  // Explains *why* before Android's own permission dialog ever appears —
  // shown only on the ANC screen (offerGpsFallback), only when Signal K
  // genuinely has no vessel position, and only once until that changes.
  // Never fires just from opening the app or visiting MAP.
  void _maybeAskGpsConsent() {
    if (widget.demo ||
        !widget.offerGpsFallback ||
        widget.hasVesselPosition ||
        widget.gpsFallbackConsent != null ||
        _askedThisSession) {
      return;
    }
    _askedThisSession = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cPanel,
          title: const Text(
            'Usar GPS del dispositivo',
            style: TextStyle(color: cText),
          ),
          content: const Text(
            'Signal K no está publicando la posición del barco ahora mismo, '
            'así que el fondeo no tiene desde dónde partir. Puedes autorizar '
            'que se use el GPS de esta tablet/móvil como alternativa solo '
            'para este caso — no se usará mientras el barco sí tenga '
            'posición propia.',
            style: TextStyle(color: cMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No, gracias'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Permitir'),
            ),
          ],
        ),
      );
      if (mounted && allow != null) {
        widget.onGpsFallbackConsentChanged?.call(allow);
      }
    });
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
          allowGeolocation: _wantsGpsFallback,
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
                if (widget.missingPluginHint != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.missingPluginHint!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: cYellow, fontSize: 14),
                  ),
                ],
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
