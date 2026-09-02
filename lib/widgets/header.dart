part of '../main.dart';

// ─── Host preset chip ─────────────────────────────────────────────────────────
class _HostPresetChip extends StatelessWidget {
  const _HostPresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? cCyan : cPanel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? cCyan : const Color(0xff303030),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? cBg : cMuted,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? cBg : cText,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Collapsed header bar (web only) ──────────────────────────────────────────
// Replaces the floating reveal-handle overlay on web: that overlay sits on
// top of the WebView's <iframe> (MAP/ANC), and taps landing on an iframe's
// rectangle are delivered straight to the iframe's own document by the
// browser, never reaching Flutter's canvas — so the handle never registers
// a tap there. This bar takes real space in the Column layout instead,
// pushing the WebView down so the tap target never overlaps the iframe.
class _CollapsedHeaderBar extends StatelessWidget {
  const _CollapsedHeaderBar({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    // 44 tall, not 24 — the old size was a real tap target of just 80x24,
    // under the ~44pt minimum touch target and hard to hit on a phone.
    // Reported live 2026-09-02 ("muy corto el boton para telefono").
    height: 44,
    width: double.infinity,
    color: cBg,
    alignment: Alignment.topCenter,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 0) onTap();
      },
      child: Container(
        width: 88,
        height: 44,
        alignment: Alignment.topCenter,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(12),
          ),
        ),
        child: Container(
          width: 48,
          height: 4,
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    ),
  );
}

// ─── Header ───────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({
    required this.pages,
    required this.selected,
    required this.status,
    required this.ok,
    required this.onSelect,
    this.alarmPageIds = const {},
    this.alarmCount = 0,
    this.onBellTap,
  });
  final List<(String, IconData, Widget)> pages;
  final int selected;
  final String status;
  final bool ok;
  final ValueChanged<int> onSelect;
  final Set<String> alarmPageIds;
  final int alarmCount;
  final VoidCallback? onBellTap;

  Widget _tab(int i) {
    final active = selected == i;
    final alarming = alarmPageIds.contains(pages[i].$1);
    final color = alarming ? cRed : (active ? cCyan : cMuted);
    return GestureDetector(
      onTap: () => onSelect(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: active
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: alarming ? cRed : cCyan, width: 3),
                ),
              )
            : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(pages[i].$2, size: 18, color: color),
            const SizedBox(height: 2),
            Text(
              pages[i].$1,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: active || alarming
                    ? FontWeight.w800
                    : FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      color: const Color(0xff0e1a21),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [for (var i = 0; i < pages.length; i++) _tab(i)],
            ),
          ),
          if (kIsWeb) const _FullscreenButton(),
          if (kIsWeb) const SizedBox(width: 8),
          // Always present, not just while something's actively alarming —
          // otherwise there's no way to get to the alarm list (to check
          // what's muted, silence something in advance, etc.) except by
          // waiting for an alarm to fire first.
          GestureDetector(
            onTap: onBellTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    alarmCount > 0
                        ? Icons.notifications_active
                        : Icons.notifications_none,
                    color: alarmCount > 0 ? cRed : cMuted,
                  ),
                  if (alarmCount > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: const BoxDecoration(
                          color: cRed,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          '$alarmCount',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            ok ? Icons.link : Icons.link_off,
            color: status == 'DEMO' ? cOrange : (ok ? cGreen : cOrange),
          ),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(
              color: status == 'DEMO' ? cOrange : (ok ? cGreen : cOrange),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }
}

class _FullscreenButton extends StatefulWidget {
  const _FullscreenButton();

  @override
  State<_FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<_FullscreenButton> {
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _active = app_fullscreen.fullscreenActive;
  }

  Future<void> _toggle() async {
    await app_fullscreen.toggleFullscreen();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (mounted) setState(() => _active = app_fullscreen.fullscreenActive);
  }

  @override
  Widget build(BuildContext context) {
    if (!app_fullscreen.fullscreenSupported) return const SizedBox.shrink();
    return Tooltip(
      message: _active ? 'Salir de pantalla completa' : 'Pantalla completa',
      child: IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        onPressed: _toggle,
        icon: Icon(
          _active ? Icons.fullscreen_exit : Icons.fullscreen,
          color: cMuted,
        ),
      ),
    );
  }
}
