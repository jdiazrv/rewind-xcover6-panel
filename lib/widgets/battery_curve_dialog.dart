part of '../main.dart';

// "en todas las baterias ademas de la grafica historica e gustaria ver la
// curva de carga y descarga... para house da igual [ya tiene SOC real].
// pero quiero ver la curva graficamente para las que no tengan shunt"
// (reported live 2026-09-04) — start and bow-thruster batteries only ever
// publish voltage, so this is the closest thing to a SOC reading available
// for them: a resting-voltage lookup curve (leadAcidSocFromVoltage, in
// models.dart), with the live voltage marked on it. trendDirection (from
// the matching _VoltageTrendTracker, fed every real delta) is what keeps
// this honest — the curve is only meaningful at rest, so charging/
// discharging is called out explicitly instead of presenting a number that
// would otherwise just be wrong under load.
class BatteryCurveDialog extends StatelessWidget {
  const BatteryCurveDialog({
    super.key,
    required this.title,
    required this.voltage,
    required this.trendDirection,
    required this.color,
  });

  final String title;
  final double? voltage;
  final int trendDirection; // -1 descargando, 0 en reposo, 1 cargando
  final Color color;

  @override
  Widget build(BuildContext context) {
    final v = voltage;
    final soc = v == null ? null : leadAcidSocFromVoltage(v);
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
            const Text(
              'Curva de carga/descarga — plomo-ácido, en reposo (aproximado)',
              style: TextStyle(color: cMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              width: double.infinity,
              child: v == null
                  ? const Center(
                      child: Text(
                        'Sin lectura de voltaje',
                        style: TextStyle(color: cMuted),
                      ),
                    )
                  : CustomPaint(
                      size: Size.infinite,
                      painter: _LeadAcidCurvePainter(
                        voltage: v,
                        soc: soc!,
                        color: color,
                      ),
                    ),
            ),
            if (v != null) ...[const SizedBox(height: 14), _trendBanner(soc!)],
          ],
        ),
      ),
    );
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
        '~${soc.round()}% — estimación razonable (±15%, plomo-ácido).',
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

class _LeadAcidCurvePainter extends CustomPainter {
  _LeadAcidCurvePainter({
    required this.voltage,
    required this.soc,
    required this.color,
  });
  final double voltage;
  final double soc;
  final Color color;

  static const _minV = 11.0, _maxV = 12.9;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 38.0, padB = 22.0, padT = 14.0, padR = 12.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 0 || plotH <= 0) return;

    double xFor(double socPct) => padL + plotW * (socPct / 100);
    double yFor(double v) =>
        padT + plotH * (1 - (v.clamp(_minV, _maxV) - _minV) / (_maxV - _minV));

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
    for (var i = 0; i < leadAcidSocCurve12V.length; i++) {
      final (s, v) = leadAcidSocCurve12V[i];
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
    _text(canvas, '${_maxV.toStringAsFixed(1)}V', Offset(0, padT - 4), cMuted, size: 10);
    _text(
      canvas,
      '${_minV.toStringAsFixed(1)}V',
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
  bool shouldRepaint(covariant _LeadAcidCurvePainter old) =>
      old.voltage != voltage || old.color != color;
}
