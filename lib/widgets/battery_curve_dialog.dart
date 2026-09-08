part of '../main.dart';

// "en todas las baterias ademas de la grafica historica e gustaria ver la
// curva de carga y descarga... para house da igual [ya tiene SOC real].
// pero quiero ver la curva graficamente para las que no tengan shunt" then
// "en CFG debe poderse elegir plomo, agm, gel o litio y poner la curva de
// carga aprox" (reported live 2026-09-04) — start and bow-thruster
// batteries only ever publish voltage, so this is the closest thing to a
// SOC reading available for them: a resting-voltage lookup curve
// (socFromVoltage, in models.dart, keyed by settings.batteryChemistry),
// with the live voltage marked on it. trendDirection (from the matching
// _VoltageTrendTracker, fed every real delta) is what keeps this honest —
// the curve is only meaningful at rest, so charging/discharging is called
// out explicitly instead of presenting a number that would otherwise just
// be wrong under load.
// Añadido después (2026-09-08): "bow y arranque damos por hecho que estan
// en flotacion asi que a lo mejor es mejor quitar esa funcion". Cierto — en
// flotación el voltaje lo fija el cargador, no la batería, así que la curva
// marcaría 100% tanto con una batería sana como con una muerta. Cuando está
// en flotación se dice eso y punto, y en su lugar se enseña lo único que sí
// mide su salud sin shunt: cuánto se hunde bajo carga fuerte (arrancar el
// motor, usar el propulsor). Ver BatteryLoadWatcher en models.dart.
class BatteryCurveDialog extends StatelessWidget {
  const BatteryCurveDialog({
    super.key,
    required this.title,
    required this.voltage,
    required this.trendDirection,
    required this.color,
    required this.chemistry,
    this.loadEvents = const [],
  });

  final String title;
  final double? voltage;
  final int trendDirection; // -1 descargando, 0 en reposo, 1 cargando
  final Color color;
  final String chemistry; // 'lead' | 'agm' | 'gel' | 'lithium'
  final List<BatteryLoadEvent> loadEvents;

  @override
  Widget build(BuildContext context) {
    final v = voltage;
    final onFloat = batteryOnFloat(v);
    final soc = (v == null || onFloat) ? null : socFromVoltage(v, chemistry);
    final chemLabel = batteryChemistryLabels[chemistry] ?? 'Plomo-ácido';
    return Dialog(
      backgroundColor: cPanel,
      insetPadding: const EdgeInsets.all(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: cText,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: cMuted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Text(
              onFloat
                  ? '$chemLabel — cargador conectado'
                  : 'Curva de carga/descarga — $chemLabel, en reposo (aproximado)',
              style: const TextStyle(color: cMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (v == null)
              const SizedBox(
                height: 220,
                width: double.infinity,
                child: Center(
                  child: Text(
                    'Sin lectura de voltaje',
                    style: TextStyle(color: cMuted),
                  ),
                ),
              )
            else if (onFloat) ...[
              _floatBanner(v),
              const SizedBox(height: 14),
              _loadSection(),
            ] else ...[
              SizedBox(
                height: 220,
                width: double.infinity,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _BatteryCurvePainter(
                    voltage: v,
                    soc: soc!,
                    color: color,
                    chemistry: chemistry,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _trendBanner(soc),
              if (loadEvents.isNotEmpty) ...[
                const SizedBox(height: 14),
                _loadSection(),
              ],
            ],
            if (v != null && !onFloat && chemistry == 'lithium') ...[
              const SizedBox(height: 10),
              const Text(
                'El litio (LiFePO4) mantiene el voltaje casi plano entre el '
                '20% y el 90% — pequeñas variaciones de lectura cambian '
                'mucho la estimación. Fíate más de un BMS/shunt real si '
                'tienes uno.',
                style: TextStyle(color: cMuted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // En flotación no hay nada que estimar: se dice el estado y se explica
  // por qué no aparece un porcentaje, en vez de enseñar un 100% falso.
  Widget _floatBanner(double v) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: cPanel2,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Row(
      children: [
        Icon(Icons.battery_charging_full, color: color, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'En flotación · ${v.toStringAsFixed(2)} V',
                style: const TextStyle(
                  color: cText,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                'Con el cargador puesto, el voltaje lo fija él y no dice '
                'nada del estado de carga. Lo que sí mide su salud es '
                'cuánto se hunde al pedirle corriente.',
                style: TextStyle(color: cMuted, fontSize: 12, height: 1.35),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  // Histórico de esfuerzos: lo útil no es un valor suelto sino su
  // evolución — si el mismo arranque hunde cada vez más, la batería se
  // está acabando.
  Widget _loadSection() {
    if (loadEvents.isEmpty) {
      return const Text(
        'Aún no se ha registrado ningún esfuerzo. Al arrancar el motor o '
        'usar el propulsor se anotará aquí cuánto cae el voltaje, para '
        'poder comparar con el tiempo.',
        style: TextStyle(color: cMuted, fontSize: 12, height: 1.35),
      );
    }
    final recent = loadEvents.reversed.take(5).toList();
    final worst = recent.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Esfuerzos recientes',
          style: TextStyle(
            color: cText,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Último: bajó a ${worst.minV.toStringAsFixed(2)} V '
          '(−${worst.dropV.toStringAsFixed(2)} V) y tardó '
          '${worst.recoverySeconds} s en recuperarse.',
          style: const TextStyle(color: cMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (final e in recent)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(
                    _stamp(e.at),
                    style: const TextStyle(color: cMuted, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${e.minV.toStringAsFixed(2)} V',
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Text(
                  '−${e.dropV.toStringAsFixed(2)} V · ${e.recoverySeconds} s',
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _stamp(DateTime at) {
    final d = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _trendBanner(double soc) {
    final (icon, label, sub) = switch (trendDirection) {
      1 => (
        Icons.trending_up,
        'Cargando',
        'El SOC real es probablemente MAYOR que el ~${soc.round()}% de la curva.',
      ),
      -1 => (
        Icons.trending_down,
        'Descargando',
        'El SOC real es probablemente MENOR que el ~${soc.round()}% de la curva.',
      ),
      _ => (
        Icons.trending_flat,
        'En reposo',
        '~${soc.round()}% — estimación aproximada.',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cPanel2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: cText,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  sub,
                  style: const TextStyle(color: cMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BatteryCurvePainter extends CustomPainter {
  _BatteryCurvePainter({
    required this.voltage,
    required this.soc,
    required this.color,
    required this.chemistry,
  });
  final double voltage;
  final double soc;
  final Color color;
  final String chemistry;

  @override
  void paint(Canvas canvas, Size size) {
    final table = batterySocCurves[chemistry] ?? batterySocCurves['lead']!;
    // A little headroom above/below the table's own extremes so the top
    // and bottom points aren't drawn flush against the axes.
    final minV = table.first.$2 - 0.15;
    final maxV = table.last.$2 + 0.15;

    const padL = 42.0, padB = 22.0, padT = 14.0, padR = 12.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 0 || plotH <= 0) return;

    double xFor(double socPct) => padL + plotW * (socPct / 100);
    double yFor(double v) =>
        padT + plotH * (1 - (v.clamp(minV, maxV) - minV) / (maxV - minV));

    final axisPaint = Paint()
      ..color = cMuted.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(padL, padT),
      Offset(padL, padT + plotH),
      axisPaint,
    );
    canvas.drawLine(
      Offset(padL, padT + plotH),
      Offset(padL + plotW, padT + plotH),
      axisPaint,
    );

    final path = Path();
    for (var i = 0; i < table.length; i++) {
      final (s, v) = table[i];
      final p = Offset(xFor(s.toDouble()), yFor(v));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    final markerY = yFor(voltage);
    final markerX = xFor(soc);
    _drawDashedLine(
      canvas,
      Offset(padL, markerY),
      Offset(padL + plotW, markerY),
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(Offset(markerX, markerY), 6, Paint()..color = color);
    canvas.drawCircle(
      Offset(markerX, markerY),
      6,
      Paint()
        ..color = cBg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    _text(
      canvas,
      '${voltage.toStringAsFixed(2)}V',
      Offset(padL + 6, (markerY - 20).clamp(padT, padT + plotH - 14)),
      color,
    );
    for (final pct in [0, 25, 50, 75, 100]) {
      _text(
        canvas,
        '$pct%',
        Offset(xFor(pct.toDouble()) - 10, padT + plotH + 4),
        cMuted,
        size: 10,
      );
    }
    _text(canvas, '${maxV.toStringAsFixed(1)}V', Offset(0, padT - 4), cMuted, size: 10);
    _text(
      canvas,
      '${minV.toStringAsFixed(1)}V',
      Offset(0, padT + plotH - 8),
      cMuted,
      size: 10,
    );
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashW = 5.0, gapW = 4.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var dist = 0.0;
    while (dist < total) {
      final start = a + dir * dist;
      final end = a + dir * math.min(dist + dashW, total);
      canvas.drawLine(start, end, paint);
      dist += dashW + gapW;
    }
  }

  void _text(Canvas canvas, String text, Offset pos, Color color, {double size = 11}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _BatteryCurvePainter old) =>
      old.voltage != voltage || old.color != color || old.chemistry != chemistry;
}
