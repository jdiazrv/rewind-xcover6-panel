part of '../main.dart';

class _ThresholdRow extends StatefulWidget {
  const _ThresholdRow({
    required this.label,
    required this.unit,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final String unit;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_ThresholdRow> createState() => _ThresholdRowState();
}

class _ThresholdRowState extends State<_ThresholdRow> {
  late final _controller = TextEditingController(
    text: widget.value == widget.value.roundToDouble()
        ? widget.value.toStringAsFixed(0)
        : widget.value.toString(),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
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

