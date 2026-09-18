part of '../main.dart';

/// Ancho del canal de la derecha donde van los puntos de posición de los
/// carruseles verticales (NAV, VNT y TIEMPO). La página se estrecha esto y
/// los puntos van ahí, para que nunca tapen una tarjeta (2026-09-18).
const kPagerGutter = 20.0;

/// Carrusel vertical: varias pantallas dentro de una sola pestaña, pasando de
/// una a otra deslizando arriba y abajo, con el aviso del nombre al cambiar y
/// los puntos de posición en la esquina.
///
/// Es el mismo gesto que NAV y VNT (ver el comentario largo del ListView de
/// _navPage: por qué es un ListView con overscroll y no un PageView anidado),
/// pero en un componente: la tercera copia pegada a mano no era opción. Lo
/// estrena TIEMPO, que junta PREVISIÓN, MAR y A BORDO para que el menú no
/// tenga tres pestañas que son "el tiempo" (petición 2026-09-18).
class _VerticalPager extends StatefulWidget {
  const _VerticalPager({
    super.key,
    required this.pages,
    required this.initialLabel,
    required this.onChanged,
  });

  final List<({String label, Widget child})> pages;

  /// Por nombre y no por índice: la lista cambia de longitud según el barco
  /// (A BORDO solo existe si hay sensores), y un índice guardado apuntaría a
  /// otra página.
  final String initialLabel;
  final ValueChanged<String> onChanged;

  @override
  State<_VerticalPager> createState() => _VerticalPagerState();
}

class _VerticalPagerState extends State<_VerticalPager> {
  static const _physics = AlwaysScrollableScrollPhysics(
    parent: ClampingScrollPhysics(),
  );
  final _controller = ScrollController();
  late int _index = _indexOf(widget.initialLabel);
  double _overscroll = 0;
  bool _flipLock = false;
  String? _toast;
  Timer? _toastTimer;

  int _indexOf(String label) {
    final i = widget.pages.indexWhere((p) => p.label == label);
    return i < 0 ? 0 : i;
  }

  @override
  void didUpdateWidget(covariant _VerticalPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.pages.length) _index = 0;
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    final label = widget.pages[i].label;
    widget.onChanged(label);
    _toastTimer?.cancel();
    setState(() => _toast = label);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.pages.length;
    if (total == 0) return const SizedBox.shrink();
    if (_index >= total) _index = 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final page = SizedBox(
          key: ValueKey(widget.pages[_index].label),
          height: math.max(320.0, constraints.maxHeight),
          child: widget.pages[_index].child,
        );
        if (total == 1) {
          return ListView(
            controller: _controller,
            physics: _physics,
            padding: EdgeInsets.zero,
            children: [page],
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification) {
              _overscroll = 0;
              _flipLock = false;
            } else if (n is ScrollEndNotification) {
              _flipLock = false;
            } else if (n is OverscrollNotification) {
              if (_flipLock) return false;
              _overscroll += n.overscroll;
              // Distancia y no velocidad, igual que NAV: un arrastre lento y
              // deliberado tiene que pasar de página igual que un golpe.
              if (_overscroll.abs() >= 60) {
                final forward = _overscroll > 0;
                _overscroll = 0;
                _flipLock = true;
                _goTo(
                  forward ? (_index + 1) % total : (_index - 1 + total) % total,
                );
              }
            }
            return false;
          },
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: kPagerGutter),
                child: ListView(
                  controller: _controller,
                  physics: _physics,
                  padding: EdgeInsets.zero,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: page,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: kPagerGutter,
                child: Center(
                  child: _NavPageIndicator(
                    total: total,
                    current: _index,
                    onDotTap: _goTo,
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _toast == null ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: AnimatedScale(
                        scale: _toast == null ? 0.9 : 1,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 36,
                            vertical: 18,
                          ),
                          decoration: BoxDecoration(
                            color: cBg.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: cCyan.withValues(alpha: 0.35),
                              width: 1.4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 24,
                              ),
                            ],
                          ),
                          child: Text(
                            _toast ?? '',
                            style: const TextStyle(
                              color: cText,
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
