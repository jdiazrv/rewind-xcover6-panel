part of '../main.dart';

/// One row in CFG > Admin's saved-server list — same name/host/port +
/// connect/edit/delete controls as before, plus a live reachability dot:
/// grey while checking, green if the server actually answered, orange
/// "requiere VPN" if Android reports no VPN transport active right now
/// (skips the probe entirely in that case — there's no point waiting out
/// a timeout against an address that can't possibly be routed). EVERY
/// entry here is remote/Tailscale by construction — the local (LAN)
/// connection lives on a separate screen — so this always gates on VPN
/// state, no per-host range heuristic needed. Reported live 2026-09-04
/// ("al entrar en admin que compruebe si hay tailscale... una por una
/// mirar quién de los servidores está conectado").
class SavedServerRow extends StatefulWidget {
  const SavedServerRow({
    super.key,
    required this.server,
    required this.isCurrent,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
  });

  final SavedServer server;
  final bool isCurrent;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<SavedServerRow> createState() => _SavedServerRowState();
}

enum _ProbeState { checking, reachable, unreachable, needsVpn }

class _SavedServerRowState extends State<SavedServerRow> {
  _ProbeState _state = _ProbeState.checking;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void didUpdateWidget(covariant SavedServerRow old) {
    super.didUpdateWidget(old);
    if (old.server.host != widget.server.host ||
        old.server.port != widget.server.port) {
      setState(() => _state = _ProbeState.checking);
      unawaited(_probe());
    }
  }

  Future<void> _probe() async {
    if (!await isVpnActive()) {
      if (mounted) setState(() => _state = _ProbeState.needsVpn);
      return;
    }
    try {
      final resp = await http
          .get(
            Uri.parse(
              'http://${widget.server.host}:${widget.server.port}'
              '/signalk/v1/api/vessels/self/name',
            ),
          )
          .timeout(const Duration(seconds: 3));
      // Any real HTTP response — even 401/403 — means the host answered;
      // only a timeout/connection failure means it's actually unreachable.
      if (!mounted) return;
      setState(
        () => _state = resp.statusCode > 0
            ? _ProbeState.reachable
            : _ProbeState.unreachable,
      );
    } catch (_) {
      if (mounted) setState(() => _state = _ProbeState.unreachable);
    }
  }

  Widget _statusDot() {
    switch (_state) {
      case _ProbeState.checking:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: cMuted),
        );
      case _ProbeState.reachable:
        return const Icon(Icons.circle, color: cGreen, size: 10);
      case _ProbeState.unreachable:
        return const Icon(Icons.circle, color: cRed, size: 10);
      case _ProbeState.needsVpn:
        return const Icon(Icons.vpn_key_off, color: cOrange, size: 14);
    }
  }

  String? _statusLabel() {
    switch (_state) {
      case _ProbeState.checking:
        return null;
      case _ProbeState.reachable:
        return null;
      case _ProbeState.unreachable:
        return 'sin respuesta';
      case _ProbeState.needsVpn:
        return 'requiere VPN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _statusLabel();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _statusDot(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.server.name,
                  style: const TextStyle(
                    color: cText,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                Text(
                  label == null
                      ? '${widget.server.host}:${widget.server.port}'
                      : '${widget.server.host}:${widget.server.port} · $label',
                  style: TextStyle(
                    color: _state == _ProbeState.needsVpn ? cOrange : cMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (widget.isCurrent)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.check_circle, color: cGreen, size: 20),
            )
          else
            OutlinedButton(
              // Not hard-blocked while needsVpn — Tailscale coming up a
              // moment after this check ran shouldn't leave the button
              // stuck disabled with no way to retry short of leaving and
              // re-entering Admin.
              onPressed: widget.onConnect,
              child: const Text('Conectar'),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: cMuted, size: 18),
            onPressed: widget.onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: cMuted, size: 18),
            onPressed: widget.onDelete,
          ),
        ],
      ),
    );
  }
}
