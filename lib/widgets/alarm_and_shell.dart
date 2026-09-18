part of '../main.dart';

// ─── Shared CFG building blocks ─────────────────────────────────────────────
// One visual language for every settings tab: a bordered card per logical
// group, a header with real weight (not a barely-there 10px caption) so the
// eye can tell "this is a section title" from "this is a row" at a glance,
// and switches sitting directly against their own label instead of pinned
// to the far trailing edge of whatever width the tab happens to be — the
// three things CFG → Alarmas/Fondeo got called out for.

/// Whether a setting travels with the BOAT (stored by the REWIND plugin on
/// the server and pulled by every tablet, phone and browser — see
/// config_sync.dart) or stays on THIS device only.
///
/// CFG used to leave this invisible, and it was not even consistent: the AIS
/// alarm thresholds were shared while the "aviso sonoro" right next to them
/// was not, and "Usar acelerómetro del dispositivo" sat inside the tab that
/// announces "se guarda en el servidor". You changed a value on the tablet
/// and could not tell whether the phone would follow. Now every group says
/// which it is, and a row that differs from its group says so too.
enum CfgScope {
  // "BARCO" y "ESTE APARATO" no decían nada por sí solos: hay que leer lo que
  // PASA, no dónde se guarda. Con "TODO EL BARCO" y "SOLO AQUÍ" se entiende
  // sin tooltip, y con dos colores distintos se distinguen de un vistazo en
  // vez de tener que leerlos (2026-09-17).
  boat('TODO EL BARCO', Icons.sailing, cCyan),
  device('SOLO AQUÍ', Icons.phone_android, cPurple);

  const CfgScope(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;

  String get explanation => this == CfgScope.boat
      ? 'Se guarda en el barco: el cambio llega a todas las tablets, móviles '
            'y navegadores que se conecten.'
      : 'Se queda en este aparato: los demás no se enteran.';
}

/// Marca de alcance para una cabecera de grupo o una fila suelta.
class CfgScopeTag extends StatelessWidget {
  const CfgScopeTag(this.scope, {super.key, this.dense = false});
  final CfgScope scope;

  /// Para una fila dentro de un grupo, donde compite con su etiqueta.
  final bool dense;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: scope.explanation,
    child: Container(
      padding: EdgeInsets.fromLTRB(dense ? 6 : 8, 3, dense ? 8 : 10, 3),
      decoration: BoxDecoration(
        color: scope.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scope.color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(scope.icon, size: dense ? 12 : 14, color: scope.color),
          const SizedBox(width: 5),
          Text(
            scope.label,
            style: TextStyle(
              color: scope.color,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    ),
  );
}

/// La leyenda de la cabecera de CFG: las dos marcas con su significado.
class CfgScopeLegend extends StatelessWidget {
  const CfgScopeLegend({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text(
        'SE GUARDA EN',
        style: TextStyle(
          color: cMuted,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
      const SizedBox(width: 6),
      const CfgScopeTag(CfgScope.boat, dense: true),
      const SizedBox(width: 5),
      const CfgScopeTag(CfgScope.device, dense: true),
    ],
  );
}

/// A sub-heading inside a group, with the gap that always followed it.
class SettingsSubLabel extends StatelessWidget {
  const SettingsSubLabel(this.text, {super.key, this.scope, this.top = 0});
  final String text;
  final CfgScope? scope;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 6),
    child: Row(
      children: [
        Flexible(child: Text(text, style: cfgSubLabel)),
        if (scope != null) ...[
          const SizedBox(width: 8),
          CfgScopeTag(scope!, dense: true),
        ],
      ],
    ),
  );
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.icon,
    this.scope,
  });
  final String title;
  final IconData? icon;
  final List<Widget> children;

  /// Shown as a badge in the header. Omitted only for groups that are pure
  /// actions or read-outs (Diagnóstico), where "where is this stored" has no
  /// meaning.
  final CfgScope? scope;

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
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: cText,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              if (scope != null) ...[
                const SizedBox(width: 8),
                CfgScopeTag(scope!),
              ],
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

/// Consistent page frame for the non-card CFG tabs. On the XCover the app is
/// always landscape: use the available width, but keep long forms readable
/// instead of letting fields stretch edge-to-edge.
class SettingsPageBody extends StatelessWidget {
  const SettingsPageBody({
    super.key,
    required this.child,
    this.maxWidth = 760,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: padding,
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    ),
  );
}

/// Uses the XCover's landscape width without introducing another navigation
/// level. Groups keep their normal single-column order on narrow windows and
/// split into two balanced reading columns on the device layout.
class SettingsResponsiveGroups extends StatelessWidget {
  const SettingsResponsiveGroups({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 700 || children.length < 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      }
      final split = (children.length + 1) ~/ 2;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children.take(split).toList(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children.skip(split).toList(),
            ),
          ),
        ],
      );
    },
  );
}

Future<bool> confirmSettingsAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirmar',
  bool destructive = false,
}) async =>
    (await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: cRed)
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    )) ??
    false;

// Switch leading, tight against its own label — not a ListTile spanning the
// full row width with the switch stranded at the trailing edge.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.scope,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;

  /// Only when this row does NOT follow its group's scope — e.g. an "aviso
  /// sonoro" inside a group of boat-wide alarm thresholds.
  final CfgScope? scope;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Switch(value: value, onChanged: onChanged),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(fontSize: 13, color: cText),
                        ),
                      ),
                      if (scope != null) ...[
                        const SizedBox(width: 6),
                        CfgScopeTag(scope!, dense: true),
                      ],
                    ],
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: const TextStyle(fontSize: 12, color: cMuted),
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

// Casilla de verificación con la misma disciplina que SettingsSwitchRow: un
// CheckboxListTile dentro de estos recuadros con fondo propio pierde su color
// y su efecto al pulsar, y Flutter lo avisa ("ListTile background color or ink
// splashes may be invisible") — el test de CFG lo caza.
class SettingsCheckRow extends StatelessWidget {
  const SettingsCheckRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, color: cText),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Igual que SettingsCheckRow pero para elegir uno de varios.
///
/// Sustituye a RadioListTile, que además de perder el fondo dentro de estas
/// tarjetas arrastraba dos `groupValue`/`onChanged` marcados como obsoletos.
class SettingsRadioRow extends StatelessWidget {
  const SettingsRadioRow({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.title,
    this.subtitle,
  });
  final bool selected;
  final VoidCallback onSelected;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onSelected,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? cCyan : cMuted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: selected ? cText : cMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(color: cMuted, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SettingsStatusRow extends StatelessWidget {
  const SettingsStatusRow({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon ?? Icons.circle, size: icon == null ? 10 : 17, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: cText, fontSize: 13),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
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
  String? _error;

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void _setValue(double v) {
    widget.onChanged(v);
    _controller.text = _fmt(v);
    setState(() => _error = null);
  }

  void _submit(String raw) {
    final parsed = double.tryParse(raw.replaceAll(',', '.'));
    if (parsed == null) {
      setState(() => _error = 'Número no válido');
      return;
    }
    if (widget.min != null && parsed < widget.min! ||
        widget.max != null && parsed > widget.max!) {
      final range = widget.min != null && widget.max != null
          ? '${_fmt(widget.min!)}–${_fmt(widget.max!)} ${widget.unit}'
          : widget.min != null
          ? 'mínimo ${_fmt(widget.min!)} ${widget.unit}'
          : 'máximo ${_fmt(widget.max!)} ${widget.unit}';
      setState(() => _error = 'Rango permitido: $range');
      return;
    }
    _setValue(parsed);
  }

  @override
  void didUpdateWidget(covariant _ThresholdRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        double.tryParse(_controller.text.replaceAll(',', '.')) !=
            widget.value) {
      _controller.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
                  decoration: InputDecoration(
                    isDense: true,
                    errorText: _error,
                    errorMaxLines: 2,
                  ),
                  onSubmitted: _submit,
                  onEditingComplete: () => _submit(_controller.text),
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
  late final _nameCtrl = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final _hostCtrl = TextEditingController(
    text: widget.initial?.host ?? '',
  );
  late final _portCtrl = TextEditingController(
    text: '${widget.initial?.port ?? 3000}',
  );
  late final _userCtrl = TextEditingController(
    text: widget.initial?.skUsername ?? '',
  );
  late final _passCtrl = TextEditingController(
    text: widget.initial?.skPassword ?? '',
  );
  bool _showPassword = false;
  String? _validationError;

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
            decoration: const InputDecoration(
              labelText: 'Nombre (ej. DRAGUEUR)',
            ),
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
            decoration: const InputDecoration(
              labelText: 'Usuario Signal K (opcional)',
            ),
          ),
          TextField(
            controller: _passCtrl,
            obscureText: !_showPassword,
            decoration: InputDecoration(
              labelText: 'Contraseña (opcional)',
              suffixIcon: IconButton(
                tooltip: _showPassword
                    ? 'Ocultar contraseña'
                    : 'Mostrar contraseña',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          if (_validationError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _validationError!,
                style: const TextStyle(color: cRed, fontSize: 12),
              ),
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
          final port = int.tryParse(_portCtrl.text.trim());
          if (name.isEmpty || host.isEmpty) {
            setState(
              () => _validationError = 'El nombre y el host son obligatorios.',
            );
            return;
          }
          if (port == null || port < 1 || port > 65535) {
            setState(
              () => _validationError = 'El puerto debe estar entre 1 y 65535.',
            );
            return;
          }
          Navigator.of(context).pop(
            SavedServer(
              name: name,
              host: host,
              port: port,
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
