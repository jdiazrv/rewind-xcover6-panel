part of '../main.dart';

class _DualArcPainter extends CustomPainter {
  _DualArcPainter({
    required this.valueDeg,
    required this.fineRange,
    required this.coarseRange,
  });
  final double? valueDeg;
  final double fineRange;
  final double coarseRange;

  Offset _pointAt(Size size, double top, double curveDepth, double t) {
    final halfW = size.width / 2 - 22;
    final x = size.width / 2 + t * halfW;
    final y = top + curveDepth * (1 - t * t);
    return Offset(x, y);
  }

  void _drawArc(
    Canvas canvas,
    Size size,
    double top,
    double curveDepth,
    double range,
    double majorStep,
    double minorStep,
  ) {
    Offset point(double t) => _pointAt(size, top, curveDepth, t);

    // The channel itself, as a stroked path following the curve — shaded to
    // read as a concave groove (dark at the rim, lit in the middle) rather
    // than a raised bar, so the bead can look like it's resting inside it.
    final tubePath = Path();
    const steps = 60;
    for (var i = 0; i <= steps; i++) {
      final t = -1.0 + 2.0 * i / steps;
      final p = point(t);
      if (i == 0) {
        tubePath.moveTo(p.dx, p.dy);
      } else {
        tubePath.lineTo(p.dx, p.dy);
      }
    }
    final tubeBounds = tubePath.getBounds();
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xff1c262b),
    );
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(tubeBounds.center.dx, tubeBounds.top),
          Offset(tubeBounds.center.dx, tubeBounds.bottom + 8),
          [
            const Color(0xff35464e),
            const Color(0xff5c7079),
            const Color(0xff2c3b42),
          ],
          [0.0, 0.55, 1.0],
        ),
    );

    // Ticks + labels, minor step first so major ticks/labels paint on top.
    for (var deg = -range; deg <= range + 0.001; deg += minorStep) {
      final isMajor =
          (deg / majorStep - (deg / majorStep).round()).abs() < 1e-6;
      final t = (deg / range).clamp(-1.0, 1.0);
      final p = point(t);
      final p1 = point((t - 0.01).clamp(-1.0, 1.0));
      final p2 = point((t + 0.01).clamp(-1.0, 1.0));
      final tangent = p2 - p1;
      final tangentLen = tangent.distance;
      final normal = tangentLen == 0
          ? const Offset(0, 1)
          : Offset(-tangent.dy, tangent.dx) / tangentLen;
      final tickLen = isMajor ? 9.0 : 5.0;
      final tickEnd = p + normal * tickLen;
      canvas.drawLine(
        p,
        tickEnd,
        Paint()
          ..color = (isMajor ? cText : cMuted).withValues(
            alpha: isMajor ? 0.85 : 0.5,
          )
          ..strokeWidth = isMajor ? 1.6 : 1.0,
      );
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(
            text: deg.abs().round().toString(),
            style: const TextStyle(
              color: cMuted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final labelPos = p + normal * (tickLen + 3);
        tp.paint(canvas, Offset(labelPos.dx - tp.width / 2, labelPos.dy));
      }
    }

    // Bead marking the current reading, clamped to the ends of the scale —
    // drawn to sit *inside* the channel (small contact shadow rather than a
    // floating drop shadow, glossy radial fill) with the channel's near rim
    // re-stroked on top so it visually overlaps the bead's upper edge.
    if (valueDeg != null) {
      final t = (valueDeg! / range).clamp(-1.0, 1.0);
      final p = point(t);
      const ballRadius = 5.0;
      canvas.drawOval(
        Rect.fromCenter(
          center: p + const Offset(0, 1.5),
          width: ballRadius * 1.8,
          height: ballRadius * 0.9,
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.4),
      );
      canvas.drawCircle(
        p,
        ballRadius,
        Paint()
          ..shader = ui.Gradient.radial(p + const Offset(-1.6, -1.8), 7, [
            const Color(0xff3a3a3a),
            const Color(0xff0c0c0c),
          ]),
      );
      canvas.drawCircle(
        p + const Offset(-1.4, -1.6),
        1.3,
        Paint()..color = Colors.white.withValues(alpha: 0.55),
      );
      // Re-stroke a thin highlight along the channel's top edge over the
      // bead, so the rim reads as being in front of it (i.e. the bead sits
      // recessed in the groove instead of floating above the surface).
      canvas.drawPath(
        tubePath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.22),
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fineDepth = size.height * 0.22;
    final coarseDepth = size.height * 0.30;
    _drawArc(canvas, size, 6, fineDepth, fineRange, fineRange, 1);
    _drawArc(
      canvas,
      size,
      size.height * 0.56,
      coarseDepth,
      coarseRange,
      coarseRange / 3,
      coarseRange / 9,
    );
  }

  @override
  bool shouldRepaint(covariant _DualArcPainter oldDelegate) =>
      oldDelegate.valueDeg != valueDeg ||
      oldDelegate.fineRange != fineRange ||
      oldDelegate.coarseRange != coarseRange;
}

// ─── NAV premium painters ────────────────────────────────────────────────────
class _PremiumSpeedScalePainter extends CustomPainter {
  const _PremiumSpeedScalePainter({
    required this.value,
    required this.color,
    this.maxValue = 30,
    this.unit = 'kt',
  });
  final double? value;
  final Color color;
  final double maxValue;
  final String unit;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 1.62);
    final radius = size.width * 0.46;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = math.pi * 1.06;
    const sweep = math.pi * 0.88;
    final track = Paint()
      ..color = cMuted.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, track);
    if (value != null) {
      final t = (value! / maxValue).clamp(0.0, 1.0);
      canvas.drawArc(
        rect,
        start,
        sweep * t,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 13
          ..strokeCap = StrokeCap.round,
      );
    }
    // Tick step scales with the range so it always lands cleanly on
    // maxValue instead of assuming the old fixed 0-30 scale.
    final step = maxValue <= 6
        ? 1
        : maxValue <= 15
        ? 2
        : (maxValue / 6).round();
    final majorStep = step * 2;
    for (var v = 0; v <= maxValue; v += step) {
      final t = v / maxValue;
      final a = start + sweep * t;
      final major = v % majorStep == 0 || v == 0 || v >= maxValue;
      final p1 = center + Offset(math.cos(a), math.sin(a)) * (radius - 13);
      final p2 = center + Offset(math.cos(a), math.sin(a)) * (radius + 1);
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = cText.withValues(alpha: major ? 0.72 : 0.38)
          ..strokeWidth = major ? 1.8 : 1.0,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '$v',
          style: TextStyle(
            color: cMuted.withValues(alpha: 0.92),
            fontSize: major ? 12 : 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = center + Offset(math.cos(a), math.sin(a)) * (radius - 36);
      tp.paint(canvas, Offset(lp.dx - tp.width / 2, lp.dy - tp.height / 2));
    }
    final unitLabel = TextPainter(
      text: TextSpan(
        text: unit,
        style: const TextStyle(
          color: cMuted,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    unitLabel.paint(
      canvas,
      Offset(size.width / 2 - unitLabel.width / 2, size.height - 20),
    );
  }

  @override
  bool shouldRepaint(covariant _PremiumSpeedScalePainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.color != color ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.unit != unit;
}

class _PremiumCompassPainter extends CustomPainter {
  const _PremiumCompassPainter({required this.value, required this.color});
  final double? value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.43;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = cMuted.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );
    canvas.drawCircle(
      center,
      radius * 0.88,
      Paint()
        ..color = cMuted.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    for (var i = 0; i < 16; i++) {
      final a = -math.pi / 2 + i * math.pi * 2 / 16;
      final major = i % 4 == 0;
      final p1 = center + Offset(math.cos(a), math.sin(a)) * radius;
      final p2 =
          center +
          Offset(math.cos(a), math.sin(a)) * (radius - (major ? 14 : 8));
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = cMuted.withValues(alpha: major ? 0.72 : 0.42)
          ..strokeWidth = major ? 1.6 : 1.0,
      );
    }
    final markerPath = Path()
      ..moveTo(center.dx, center.dy - radius - 11)
      ..lineTo(center.dx - 11, center.dy - radius + 11)
      ..lineTo(center.dx + 11, center.dy - radius + 11)
      ..close();
    canvas.drawPath(markerPath, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PremiumCompassPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}

// Anchor-centered radar: outer ring = the swing limit (maxRadius), the
// anchor glyph sits fixed at the center, and the boat is the marker that
// moves around it — the anchor's dropped and stays put, the boat is what
// actually swings on the chain. [radiusFraction] is currentRadius/maxRadius
// (clamped a bit past 1.0 so a dragged anchor still shows just outside the
// ring instead of vanishing at its edge).
class _PremiumAnchorPainter extends CustomPainter {
  const _PremiumAnchorPainter({
    required this.radiusFraction,
    required this.bearingDeg,
    required this.color,
    this.shipIcon,
  });
  final double? radiusFraction;
  // Relative to the bow, not true north — the ring is drawn bow-up, so the
  // boat's screen angle is this bearing (reversed, see paint()) with no
  // extra heading rotation applied.
  final double? bearingDeg;
  final Color color;
  final ui.Image? shipIcon;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.43;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = cMuted.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = cMuted.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    // The anchor is dropped and stays put — it's the fixed reference, not
    // the boat. Drawn as the Material "anchor" glyph (same icon as the ANC
    // tab) via TextPainter, since it's just a font glyph under the hood.
    const anchorIcon = Icons.anchor;
    final anchorTp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(anchorIcon.codePoint),
        style: TextStyle(
          fontSize: 20,
          fontFamily: anchorIcon.fontFamily,
          package: anchorIcon.fontPackage,
          color: cMuted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    anchorTp.paint(
      canvas,
      center - Offset(anchorTp.width / 2, anchorTp.height / 2),
    );

    final frac = radiusFraction;
    final bearing = bearingDeg;
    if (frac == null || bearing == null) return;
    // bearingDeg is the anchor's direction as seen from the boat — to plot
    // the boat's position around the now-fixed anchor we need the reverse
    // vector, i.e. the boat sits opposite that bearing.
    final a = -math.pi / 2 + (bearing + 180) * math.pi / 180;
    final r = frac.clamp(0.0, 1.15) * radius;
    final boatPos = center + Offset(math.cos(a), math.sin(a)) * r;
    canvas.drawLine(
      center,
      boatPos,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..strokeWidth = 1.4,
    );
    // Same top-down artwork as the AIS radar; the ring is bow-up, so the
    // icon just sits pointing straight up (that already *is* "facing our
    // heading" in this frame) rather than being rotated a second time.
    final icon = shipIcon;
    if (icon != null) {
      const targetH = 22.0;
      final targetW = targetH * icon.width / icon.height;
      canvas.drawImageRect(
        icon,
        Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
        Rect.fromCenter(center: boatPos, width: targetW, height: targetH),
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      final boatPath = Path()
        ..moveTo(boatPos.dx, boatPos.dy - 9)
        ..lineTo(boatPos.dx - 7, boatPos.dy + 8)
        ..lineTo(boatPos.dx + 7, boatPos.dy + 8)
        ..close();
      canvas.drawPath(boatPath, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _PremiumAnchorPainter oldDelegate) =>
      oldDelegate.radiusFraction != radiusFraction ||
      oldDelegate.bearingDeg != bearingDeg ||
      oldDelegate.color != color ||
      oldDelegate.shipIcon != shipIcon;
}

class _PremiumDepthScalePainter extends CustomPainter {
  const _PremiumDepthScalePainter({
    required this.value,
    required this.color,
    this.maxValue = 10,
  });
  final double? value;
  final Color color;
  final double maxValue;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * 0.55;
    final top = 22.0;
    final bottom = size.height - 18;
    canvas.drawLine(
      Offset(x, top),
      Offset(x, bottom),
      Paint()
        ..color = cMuted.withValues(alpha: 0.35)
        ..strokeWidth = 1.2,
    );
    final step = maxValue <= 10
        ? 2
        : maxValue <= 20
        ? 5
        : maxValue <= 50
        ? 10
        : maxValue <= 100
        ? 20
        : 50;
    for (var d = 0; d <= maxValue; d += step) {
      final y = top + (bottom - top) * (d / maxValue);
      canvas.drawLine(
        Offset(x - 10, y),
        Offset(x, y),
        Paint()
          ..color = cMuted.withValues(alpha: 0.55)
          ..strokeWidth = 1.2,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '$d',
          style: const TextStyle(
            color: cMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 6, y - tp.height / 2));
    }
    if (value != null) {
      final y = top + (bottom - top) * (value!.clamp(0.0, maxValue) / maxValue);
      final marker = Path()
        ..moveTo(x - 18, y)
        ..lineTo(x - 2, y - 9)
        ..lineTo(x - 2, y + 9)
        ..close();
      canvas.drawPath(marker, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _PremiumDepthScalePainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.color != color ||
      oldDelegate.maxValue != maxValue;
}

// Wind-angle dial, two zones sharing one identical shape (design settled
// in conversation, after dropping the earlier 3-zone version — the middle
// 60°..120° tangent-arc case was cut entirely to avoid chasing screen-
// aspect edge cases): near the bow (|AWA|<~90°, drawn ±45° around dead
// ahead) or near the stern (|AWA|>~90°, the exact same shape just
// relabeled ±45° around dead astern/180° instead of 0°). Because both
// zones use the same geometry and margins, the dial never changes how
// much vertical space it occupies when it switches — only the labels and
// which real AWA range maps onto the shape differ.
// Radius is solved so the arc's *near* edge (its two ±45° endpoints), not
// just its far tip, touches the card's margin — the circle's true center
// commonly ends up off-canvas below (near zone) or above (far zone), which
// is fine, only the visible slice is ever drawn.
class _PremiumAwaPainter extends CustomPainter {
  const _PremiumAwaPainter({required this.awa, required this.far});
  final double? awa;
  // Which zone — see _DashboardState._awaFarWithHysteresis, which owns
  // the ~90° switch point and its hysteresis.
  final bool far;

  static const _bandWidth = 10.0;
  static const _neutral = Color(0xff3a4952);

  @override
  void paint(Canvas canvas, Size size) {
    final rel = awa == null ? 0.0 : normalizeRelativeAngle(awa!);
    // Local angle relative to this zone's reference direction (0°=dead
    // ahead near, 180°=dead astern far), signed so negative is always
    // port/left and positive starboard/right — same convention the near
    // zone already had natively, just re-derived for the far zone.
    final local = far ? (rel >= 0 ? 180 - rel : -180 - rel) : rel;
    final angleFor = far ? _angleForDegFar : _angleForDegNear;

    // Radius that makes BOTH the far tip (0°/180°, at offset=1·radius from
    // center) and the ±45° endpoints (at offset=cos(45°)·radius) land
    // exactly on their margins at once — solved from
    // far_offset - near_offset = (1-cos45°)·radius = available span.
    const margin = 12.0, marginH = 26.0;
    final available = size.height - 2 * margin;
    final radius = math.min(
      available / (1 - math.cos(45 * math.pi / 180)),
      (size.width / 2 - marginH) / math.sin(45 * math.pi / 180),
    );
    // Always anchor to the bottom margin, not the top — for near that's
    // the ±45° endpoints (the colored band's own tips); for far it's the
    // 0°/180° tip instead (see _angleForDegFar). Anchoring the *other*
    // end instead only gives the right answer when radius is the
    // height-bound rMax; the moment width is the tighter constraint
    // (rHoriz smaller — the usual case, this card is wide) it pushes the
    // whole shape *up*, away from the bottom, which is backwards.
    final center = Offset(
      size.width / 2,
      far
          ? size.height - margin - radius
          : size.height - margin + math.cos(45 * math.pi / 180) * radius,
    );

    _band(canvas, center, radius, angleFor);
    for (final deg in [-45.0, 45.0]) {
      // Shorter/thinner than the center tick — see 0° below — the
      // endpoint tick only needs to mark the edge, not compete with it.
      _tick(canvas, center, angleFor(deg), radius, tier: 0);
      _label(canvas, center, angleFor(deg), radius, _realLabel(deg));
    }
    _tick(canvas, center, angleFor(0), radius, tier: 2);
    _label(canvas, center, angleFor(0), radius, _realLabel(0));
    for (final deg in [-30.0, 30.0]) {
      _tick(canvas, center, angleFor(deg), radius, tier: 1);
    }
    // No marker at all once the real value is outside this zone's ±45°
    // range — clamping it to the edge used to leave a needle sitting at
    // 45° that looked like a real reading when the actual AWA was well
    // past it (still short of the ~90° switch to the other zone).
    if (awa != null && local.abs() <= 45) {
      _marker(canvas, center, angleFor(local), radius);
    }
  }

  // Converts a local dial degree (always -45..45) back to the real AWA
  // value it represents, for that tick's label — identity for the near
  // zone, mirrored around ±180° for the far one (see `local` above).
  String _realLabel(double localDeg) {
    if (!far) return localDeg.round().toString();
    final real = localDeg >= 0 ? 180 - localDeg : -180 - localDeg;
    return real.round().toString();
  }

  // near: 0° points straight up (away from center, toward the top
  // margin), ±45° down toward the bottom margin — same formula as always.
  static double _angleForDegNear(double deg) => (deg - 90) * math.pi / 180;
  // far: the exact vertical mirror of the above (negate the angle, which
  // flips the y-component and keeps the port/starboard x-sign correct) —
  // 0° now points down (toward the bottom margin), ±45° up.
  static double _angleForDegFar(double deg) => (90 - deg) * math.pi / 180;

  // tier: 0=minor (short/thin — the ±45° endpoints, which only need to
  // mark the edge), 1=emphasized (the ±30°s, a bit more visible than a
  // plain minor without competing with the center), 2=major (dead ahead/
  // astern, the one real reference point).
  void _tick(
    Canvas canvas,
    Offset center,
    double angle,
    double radius, {
    required int tier,
  }) {
    const lengthFrac = [0.90, 0.85, 0.78];
    const strokeWidth = [1.2, 1.7, 2.2];
    final color = tier == 2
        ? cText
        : cMuted.withValues(alpha: tier == 1 ? 0.8 : 0.5);
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      center + dir * radius * lengthFrac[tier],
      center + dir * radius,
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth[tier],
    );
  }

  void _label(
    Canvas canvas,
    Offset center,
    double angle,
    double radius,
    String text,
  ) {
    final dir = Offset(math.cos(angle), math.sin(angle));
    final pos = center + dir * (radius + 16);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: cMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  void _marker(Canvas canvas, Offset center, double angle, double radius) {
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      center + dir * (radius - 14),
      center + dir * (radius + 8),
      Paint()
        ..color = cCyan
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  // Red(port)→neutral→green(starboard) band, drawn as 3 solid arcs rather
  // than a shader gradient — a shader here was throwing mid-paint and
  // silently killing the rest of the frame (ticks/labels/marker never
  // drew), so plain solid segments trade a little smoothness for
  // reliability. `local`'s sign convention (see paint()) already puts
  // port on the left and starboard on the right for both zones, so this
  // never needs a reversed variant.
  void _band(
    Canvas canvas,
    Offset center,
    double radius,
    double Function(double) angleFor,
  ) {
    final aStart = angleFor(-45), aEnd = angleFor(45);
    final third = (aEnd - aStart) / 3;
    const colors = [cRed, _neutral, cGreen];
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        aStart + third * i,
        third,
        false,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = _bandWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PremiumAwaPainter oldDelegate) =>
      oldDelegate.awa != awa || oldDelegate.far != far;
}

class _PressureSparklinePainter extends CustomPainter {
  const _PressureSparklinePainter({required this.samples, required this.color});
  final List<(DateTime, double)> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) {
      final y = size.height * 0.55;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = cMuted.withValues(alpha: 0.24)
          ..strokeWidth = 2,
      );
      return;
    }

    final values = [for (final s in samples) s.$2];
    var minV = values.reduce(math.min);
    var maxV = values.reduce(math.max);
    if ((maxV - minV).abs() < 0.2) {
      minV -= 0.1;
      maxV += 0.1;
    }

    final firstMs = samples.first.$1.millisecondsSinceEpoch;
    final lastMs = samples.last.$1.millisecondsSinceEpoch;
    final spanMs = math.max(1, lastMs - firstMs);
    Offset point((DateTime, double) sample) {
      final x =
          (sample.$1.millisecondsSinceEpoch - firstMs) / spanMs * size.width;
      final y =
          size.height -
          ((sample.$2 - minV) / (maxV - minV)).clamp(0.0, 1.0) * size.height;
      return Offset(x, y);
    }

    final path = Path()
      ..moveTo(point(samples.first).dx, point(samples.first).dy);
    for (var i = 1; i < samples.length; i++) {
      final p = point(samples[i]);
      final prev = point(samples[i - 1]);
      path.cubicTo(
        prev.dx + (p.dx - prev.dx) * 0.42,
        prev.dy,
        prev.dx + (p.dx - prev.dx) * 0.58,
        p.dy,
        p.dx,
        p.dy,
      );
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _PressureSparklinePainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.color != color;
}

class _MarineWavePainter extends CustomPainter {
  const _MarineWavePainter({required this.directionDeg, required this.color});
  final double? directionDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height * 0.58;
    for (var row = 0; row < 2; row++) {
      final path = Path();
      final y0 = midY + row * size.height * 0.16;
      for (var i = 0; i <= 80; i++) {
        final x = size.width * 0.08 + size.width * 0.84 * i / 80;
        final y =
            y0 +
            math.sin(i / 80 * math.pi * 2.15 + row * 0.8) * size.height * 0.08;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: row == 0 ? 0.34 : 0.58)
          ..strokeWidth = row == 0 ? 9 : 18
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MarineWavePainter oldDelegate) =>
      oldDelegate.directionDeg != directionDeg || oldDelegate.color != color;
}
