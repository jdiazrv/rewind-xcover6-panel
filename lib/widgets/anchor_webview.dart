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
  });
  final String host;
  final int port;
  final String path;
  final String label;
  final String? missingPluginHint;
  final bool demo;
  final String? demoExplainer;
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
