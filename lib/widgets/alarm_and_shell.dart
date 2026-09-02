part of '../main.dart';

// ─── Shared CFG building blocks ─────────────────────────────────────────────
// One visual language for every settings tab: a bordered card per logical
// group, a header with real weight (not a barely-there 10px caption) so the
// eye can tell "this is a section title" from "this is a row" at a glance,
// and switches sitting directly against their own label instead of pinned
// to the far trailing edge of whatever width the tab happens to be — the
// three things CFG → Alarmas/Fondeo got called out for.

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.icon,
  });
  final String title;
  final IconData? icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    decoration: BoxDecoration(
      color: cPanel.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white12)),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: cCyan),
                const SizedBox(width: 6),
              ],
              Text(
                title,
                style: const TextStyle(
                  color: cText,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    ),
  );
}

// Switch leading, tight against its own label — not a ListTile spanning the
// full row width with the switch stranded at the trailing edge.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Transform.scale(
            scale: 0.85,
            child: Switch(value: value, onChanged: onChanged),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13, color: cText)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: const TextStyle(fontSize: 11, color: cMuted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ThresholdRow extends StatefulWidget {
  const _ThresholdRow({
    required this.label,
    required this.unit,
    required this.value,
    required this.onChanged,
    this.min,
    this.max,
    this.divisions,
  });
  final String label;
  final String unit;
  final double value;
  final ValueChanged<double> onChanged;
  // Slider shown under the row only when both are set — existing callers
  // that don't pass these keep the original text-only layout unchanged.
  final double? min;
  final double? max;
  final int? divisions;

  @override
  State<_ThresholdRow> createState() => _ThresholdRowState();
}

class _ThresholdRowState extends State<_ThresholdRow> {
  late final _controller = TextEditingController(text: _fmt(widget.value));

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void _setValue(double v) {
    widget.onChanged(v);
    _controller.text = _fmt(v);
  }

  @override
  Widget build(BuildContext context) {
    final showSlider = widget.min != null && widget.max != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: const TextStyle(color: cText, fontSize: 13),
                ),
              ),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _controller,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: cText, fontSize: 13),
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (v) {
                    final n = double.tryParse(v.replaceAll(',', '.'));
                    if (n != null) widget.onChanged(n);
                  },
                ),
              ),
              const SizedBox(width: 6),
              Text(
                widget.unit,
                style: const TextStyle(color: cMuted, fontSize: 12),
              ),
            ],
          ),
          if (showSlider)
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
              width: 220,
              height: 28,
              child: Slider(
                value: widget.value.clamp(widget.min!, widget.max!),
                min: widget.min!,
                max: widget.max!,
                divisions: widget.divisions,
                activeColor: cCyan,
                onChanged: _setValue,
              ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SkZoneAlarmRow extends StatelessWidget {
  const _SkZoneAlarmRow({
    required this.path,
    required this.state,
    required this.setting,
    required this.onChanged,
  });
  final String path;
  final String state;
  final SkZoneAlarmSetting? setting;
  final ValueChanged<SkZoneAlarmSetting> onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = setting?.enabled ?? true;
    final sound = setting?.sound ?? true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(path, style: const TextStyle(color: cText, fontSize: 12)),
                Text(state, style: const TextStyle(color: cRed, fontSize: 10)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              sound ? Icons.volume_up : Icons.volume_off,
              color: enabled ? cCyan : cMuted,
              size: 18,
            ),
            onPressed: !enabled
                ? null
                : () => onChanged(
                    SkZoneAlarmSetting(enabled: enabled, sound: !sound),
                  ),
          ),
          Switch(
            value: enabled,
            onChanged: (v) =>
                onChanged(SkZoneAlarmSetting(enabled: v, sound: sound)),
          ),
        ],
      ),
    );
  }
}

class _CustomAlarmRow extends StatelessWidget {
  const _CustomAlarmRow({
    required this.rule,
    required this.onChanged,
    required this.onDelete,
  });
  final CustomAlarmRule rule;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            rule.label,
            style: const TextStyle(color: cText, fontSize: 12),
          ),
        ),
        IconButton(
          icon: Icon(
            rule.sound ? Icons.volume_up : Icons.volume_off,
            color: rule.enabled ? cCyan : cMuted,
            size: 18,
          ),
          onPressed: !rule.enabled
              ? null
              : () {
                  rule.sound = !rule.sound;
                  onChanged();
                },
        ),
        Switch(
          value: rule.enabled,
          onChanged: (v) {
            rule.enabled = v;
            onChanged();
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: cMuted, size: 18),
          onPressed: onDelete,
        ),
      ],
    ),
  );
}

class CardShell extends StatelessWidget {
  const CardShell({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.onSecondaryTap,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) => Card(
    color: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: cMuted.withValues(alpha: 0.35), width: 1.4),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onDoubleTap: onDoubleTap,
      onSecondaryTap: onSecondaryTap,
      child: child,
    ),
  );
}

// CFG → Admin: add or edit a saved Signal K server (see
// Dashboard._switchToSavedServer). Plain text fields, no validation beyond
// "name and host aren't empty" — this is an owner-only screen, not
// user-facing input that needs guarding.
class ServerEditDialog extends StatefulWidget {
  const ServerEditDialog({super.key, this.initial});
  final SavedServer? initial;

  @override
  State<ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<ServerEditDialog> {
  late final _nameCtrl = TextEditingController(text: widget.initial?.name ?? '');
  late final _hostCtrl = TextEditingController(text: widget.initial?.host ?? '');
  late final _portCtrl = TextEditingController(
    text: '${widget.initial?.port ?? 3000}',
  );
  late final _userCtrl = TextEditingController(
    text: widget.initial?.skUsername ?? '',
  );
  late final _passCtrl = TextEditingController(
    text: widget.initial?.skPassword ?? '',
  );

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: cPanel,
    title: Text(widget.initial == null ? 'Añadir servidor' : 'Editar servidor'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Nombre (ej. DRAGUEUR)'),
          ),
          TextField(
            controller: _hostCtrl,
            decoration: const InputDecoration(labelText: 'Host / IP'),
          ),
          TextField(
            controller: _portCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Puerto'),
          ),
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(labelText: 'Usuario Signal K (opcional)'),
          ),
          TextField(
            controller: _passCtrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Contraseña (opcional)'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          final name = _nameCtrl.text.trim();
          final host = _hostCtrl.text.trim();
          if (name.isEmpty || host.isEmpty) return;
          Navigator.of(context).pop(
            SavedServer(
              name: name,
              host: host,
              port: int.tryParse(_portCtrl.text.trim()) ?? 3000,
              skUsername: _userCtrl.text.trim(),
              skPassword: _passCtrl.text,
            ),
          );
        },
        child: const Text('Guardar'),
      ),
    ],
  );
}

class WindArrow extends StatelessWidget {
  const WindArrow({super.key, required this.deg, required this.speed});
  final double? deg;
  final double? speed;

  @override
  Widget build(BuildContext context) {
    if (deg == null) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Center(child: Text('--')),
      );
    }
    return Transform.rotate(
      angle: ((deg! + 180) % 360) * math.pi / 180,
      child: Icon(Icons.navigation, color: windColor(speed), size: 28),
    );
  }
}
