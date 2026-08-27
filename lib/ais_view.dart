import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart' as ll;

import 'main.dart';
import 'models.dart';
import 'theme.dart';

// ─── AIS relative-motion view (MAP > swipe down) ──────────────────────────────
const cMagenta = Color(
  0xffff00ff,
); // matches Freeboard-SK's default AIS target color

({double bearingDeg, double distNm}) _bearingDistance(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const r = 3440.065; // nm
  final dLat = (lat2 - lat1) * math.pi / 180,
      dLon = (lon2 - lon1) * math.pi / 180;
  final lat1r = lat1 * math.pi / 180, lat2r = lat2 * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1r) *
          math.cos(lat2r) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  final y = math.sin(dLon) * math.cos(lat2r);
  final x =
      math.cos(lat1r) * math.sin(lat2r) -
      math.sin(lat1r) * math.cos(lat2r) * math.cos(dLon);
  final brg = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  return (bearingDeg: brg, distNm: r * c);
}

({double cpaNm, double tcpaMin})? _cpa(
  double rN,
  double rE,
  double vN,
  double vE,
) {
  final vv = vN * vN + vE * vE;
  if (vv < 1e-6) return null;
  final t = -(rN * vN + rE * vE) / vv; // hours
  // Negative t means the closest approach was in the past — the target is
  // moving away, so there's no meaningful future TCPA to show (not "0 min").
  if (t < 0) return null;
  final cN = rN + vN * t, cE = rE + vE * t;
  return (cpaNm: math.sqrt(cN * cN + cE * cE), tcpaMin: t * 60);
}

/// Where the relative track crosses our own heading line (dead ahead/astern),
/// so we can say "pasará por proa" / "pasará por popa" like B&G/Raymarine do.
/// Returns null when the crossing isn't well-defined (near-parallel track, or
/// already happened, or too far out to be a meaningful call).
String? _crossingLabel(
  double relN,
  double relE,
  double vN,
  double vE,
  double headingRad,
) {
  final cosH = math.cos(headingRad), sinH = math.sin(headingRad);
  final fwd0 = relN * cosH + relE * sinH;
  final right0 = -relN * sinH + relE * cosH;
  final vFwd = vN * cosH + vE * sinH;
  final vRight = -vN * sinH + vE * cosH;
  if (vRight.abs() < 0.05) return null;
  final tStar = -right0 / vRight;
  // No independent time cap here — whether to actually display this is
  // decided downstream by _aisShowsCrossing (CPA < 3 nm and moving).
  if (tStar < 0) return null;
  return (fwd0 + vFwd * tStar) >= 0 ? 'POR PROA' : 'POR POPA';
}

typedef _AisPlot = ({
  AisTarget target,
  Offset pos,
  Offset vecEnd,
  double distNm,
  double bearingDeg, // true bearing FROM own ship TO target (list "BRG" column)
  double screenCourseDeg, // target's own COG, rotated into screen frame (hull icon orientation)
  bool stale,
  double? cpaNm,
  double? tcpaMin,
  String? crossing,
  List<Offset> trail,
});

/// A sensible starting range (nm) so targets are visible on first open —
/// the user can then pinch to change scale explicitly.
double autoAisRangeNm(List<AisTarget> targets, double? ownLat, double? ownLon) {
  if (ownLat == null || ownLon == null) return 3.0;
  final dists = [
    for (final t in targets)
      if (t.lat != null && t.lon != null)
        _bearingDistance(ownLat, ownLon, t.lat!, t.lon!).distNm,
  ];
  if (dists.isEmpty) return 3.0;
  return (dists.reduce(math.max) * 1.25).clamp(0.5, 24.0);
}

List<_AisPlot> _computeAisPlots(
  List<AisTarget> targets,
  double? ownLat,
  double? ownLon,
  double ownHeadingDeg,
  double? ownCogDeg,
  double? ownSogKn,
  Size size,
  double rangeNm, {
  required bool headingUp,
  bool showTrail = false,
  bool relativeMotion = true,
  int vectorMinutes = 10,
}) {
  if (ownLat == null || ownLon == null || size.shortestSide <= 0) {
    return const [];
  }
  final valid = targets.where((t) => t.lat != null && t.lon != null).toList();
  if (valid.isEmpty) return const [];
  // headingRad drives the proa/popa geometry (always the boat's real heading);
  // viewRotRad drives what's "up" on screen — the two only coincide in heading-up mode.
  final headingRad = ownHeadingDeg * math.pi / 180;
  final viewRotRad = headingUp ? headingRad : 0.0;
  final ownCogRad = (ownCogDeg ?? ownHeadingDeg) * math.pi / 180;
  final ownSog = ownSogKn ?? 0;
  final ownVN = ownSog * math.cos(ownCogRad),
      ownVE = ownSog * math.sin(ownCogRad);
  final now = DateTime.now();

  final raw =
      <
        ({
          AisTarget t,
          double relN,
          double relE,
          double distNm,
          double bearingDeg,
          bool stale,
          double? cpaNm,
          double? tcpaMin,
          String? crossing,
          double vecEndN,
          double vecEndE,
        })
      >[];
  for (final t in valid) {
    final bd = _bearingDistance(ownLat, ownLon, t.lat!, t.lon!);
    final brgRad = bd.bearingDeg * math.pi / 180;
    final relN = bd.distNm * math.cos(brgRad),
        relE = bd.distNm * math.sin(brgRad);
    double vN = 0,
        vE = 0; // relative velocity — always used for CPA/crossing math
    double dispVN = 0,
        dispVE = 0; // vector actually drawn — relative or true motion
    final hasVelocity = t.sogKn != null && t.cogDeg != null;
    if (hasVelocity) {
      final tRad = t.cogDeg! * math.pi / 180;
      final tVN = t.sogKn! * math.cos(tRad), tVE = t.sogKn! * math.sin(tRad);
      vN = tVN - ownVN;
      vE = tVE - ownVE;
      dispVN = relativeMotion ? vN : tVN;
      dispVE = relativeMotion ? vE : tVE;
    }
    // Prefer a Signal K collision-alert plugin's own CPA/TCPA when it's publishing
    // navigation.closestApproach.* for this target; fall back to our own geometry.
    final ownCpa = _cpa(relN, relE, vN, vE);
    final cpaNm = t.pluginCpaNm ?? ownCpa?.cpaNm;
    final tcpaMin = t.pluginTcpaMin ?? ownCpa?.tcpaMin;
    final crossing = hasVelocity
        ? _crossingLabel(relN, relE, vN, vE, headingRad)
        : null;
    final lookaheadH = vectorMinutes / 60.0;
    final stale =
        t.lastUpdate == null || now.difference(t.lastUpdate!).inMinutes >= 6;
    raw.add((
      t: t,
      relN: relN,
      relE: relE,
      distNm: bd.distNm,
      bearingDeg: bd.bearingDeg,
      stale: stale,
      cpaNm: cpaNm,
      tcpaMin: tcpaMin,
      crossing: crossing,
      vecEndN: relN + dispVN * lookaheadH,
      vecEndE: relE + dispVE * lookaheadH,
    ));
  }

  final radiusPx = size.shortestSide / 2 - 24;
  final center = Offset(size.width / 2, size.height / 2);
  final pxPerNm = radiusPx / rangeNm;
  final cosH = math.cos(-viewRotRad), sinH = math.sin(-viewRotRad);

  Offset project(double relN, double relE) {
    final rotN = relN * cosH - relE * sinH;
    final rotE = relN * sinH + relE * cosH;
    return center + Offset(rotE * pxPerNm, -rotN * pxPerNm);
  }

  final viewRotDeg = viewRotRad * 180 / math.pi;
  List<Offset> trailFor(AisTarget t) {
    if (!showTrail || t.track.length < 2) return const [];
    final points = <Offset>[];
    for (final p in t.track) {
      final bd = _bearingDistance(ownLat, ownLon, p.lat, p.lon);
      final rad = bd.bearingDeg * math.pi / 180;
      points.add(project(bd.distNm * math.cos(rad), bd.distNm * math.sin(rad)));
    }
    return points;
  }

  // Always-visible vector: if the true on-screen length would be too small to
  // read (near-parallel courses, or zoomed way out), stretch it to a minimum
  // pixel length in the same direction rather than letting it disappear.
  const minVectorPx = 16.0;
  Offset stretchedVecEnd(Offset pos, Offset vecEnd) {
    final delta = vecEnd - pos;
    final len = delta.distance;
    if (len < 0.01 || len >= minVectorPx) return vecEnd;
    return pos + delta / len * minVectorPx;
  }

  return [
    for (final r in raw)
      (
        target: r.t,
        pos: project(r.relN, r.relE),
        vecEnd: stretchedVecEnd(
          project(r.relN, r.relE),
          project(r.vecEndN, r.vecEndE),
        ),
        distNm: r.distNm,
        bearingDeg: r.bearingDeg,
        screenCourseDeg: normalize360(
          (r.t.cogDeg ?? r.bearingDeg) - viewRotDeg,
        ),
        stale: r.stale,
        cpaNm: r.cpaNm,
        tcpaMin: r.tcpaMin,
        crossing: r.crossing,
        trail: trailFor(r.t),
      ),
  ];
}

_AisPlot? _hitTestAis(List<_AisPlot> plots, Offset p) {
  for (final plot in plots) {
    if ((plot.pos - p).distance <= 22) return plot;
  }
  return null;
}

/// Fill/stroke colors matching Freeboard-SK's own AIS_MOORED_STYLE_IDS table,
/// bucketed by AIS ship-type code (tens digit): 10-30 Class A/B, 40 high-speed,
/// 50 special craft, 60 passenger, 70 cargo, 80 tanker, 90 other.
({Color stroke, Color fill}) _aisTypeStyle(int? shipTypeId) {
  final bucket = shipTypeId == null ? -1 : (shipTypeId ~/ 10) * 10;
  switch (bucket) {
    case 10:
    case 20:
    case 30:
      return (stroke: Colors.white, fill: cMagenta);
    case 40:
      return (stroke: const Color(0xff7f6a00), fill: const Color(0xffffe97f));
    case 50:
      return (stroke: Colors.black, fill: const Color(0xff00ffff));
    case 60:
      return (stroke: const Color(0xff0026ff), fill: const Color(0xff5570ff));
    case 70:
      return (stroke: Colors.black, fill: const Color(0xff009931));
    case 80:
      return (stroke: const Color(0xff7f0000), fill: const Color(0xffff0000));
    case 90:
      return (stroke: Colors.black, fill: const Color(0xff808080));
    default:
      return (stroke: Colors.white, fill: cMagenta);
  }
}

Color _aisColor(_AisPlot p) =>
    p.stale ? const Color(0xffff00dc) : _aisTypeStyle(p.target.shipTypeId).fill;

/// Only worth telling the sailor about when the target is actually closing
/// (TCPA within 30 min) and the proa/popa crossing is geometrically well-defined.
bool _aisHasMeaningfulCpa(_AisPlot p) =>
    p.tcpaMin != null && p.tcpaMin! <= 30 && p.crossing != null;

/// List view rule: only call proa/popa when the target will actually pass
/// close (CPA < 3 nm) and is moving — a stopped/anchored target has no
/// meaningful "crossing" even if the geometry technically resolves one.
bool _aisShowsCrossing(_AisPlot p) =>
    p.cpaNm != null &&
    p.cpaNm! < 5 &&
    p.crossing != null &&
    (p.target.sogKn ?? 0) > 0.2;

String _aisTypeName(int? id) {
  if (id == 36 || id == 37) return 'Vela';
  final bucket = id == null ? -1 : (id ~/ 10) * 10;
  switch (bucket) {
    case 10:
    case 20:
    case 30:
      return 'Clase A/B';
    case 40:
      return 'Alta veloc.';
    case 50:
      return 'Especial';
    case 60:
      return 'Pasaje';
    case 70:
      return 'Carga';
    case 80:
      return 'Petrolero';
    case 90:
      return 'Otro';
    default:
      return '--';
  }
}

/// Rotated hull outline helper — all the hand-drawn vessel silhouettes below
/// build their points in local (bow = -y) space and rotate/translate here.
Path _rotatedHull(Offset pos, double bearingDeg, List<Offset> localPoints) {
  final rad = bearingDeg * math.pi / 180;
  final cosR = math.cos(rad), sinR = math.sin(rad);
  Offset rot(Offset p) =>
      pos + Offset(p.dx * cosR - p.dy * sinR, p.dx * sinR + p.dy * cosR);
  final pts = [for (final p in localPoints) rot(p)];
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    path.lineTo(pts[i].dx, pts[i].dy);
  }
  return path..close();
}

/// Sleek sailboat from above: pointed bow, narrow waist, flat transom stern.
Path _sailboatHull(Offset pos, double bearingDeg, double scale) =>
    _rotatedHull(pos, bearingDeg, [
      for (final p in const [
        Offset(0, -12),
        Offset(2.6, -7),
        Offset(3.2, 2),
        Offset(2.2, 7),
        Offset(-2.2, 7),
        Offset(-3.2, 2),
        Offset(-2.6, -7),
      ])
        Offset(p.dx * scale, p.dy * scale),
    ]);

/// Blocky elongated hull — cargo ship / tanker look.
Path _cargoHull(Offset pos, double bearingDeg) =>
    _rotatedHull(pos, bearingDeg, const [
      Offset(0, -11),
      Offset(4.5, -5),
      Offset(4.5, 9),
      Offset(-4.5, 9),
      Offset(-4.5, -5),
    ]);

/// Small rounded hull — generic/passenger/other craft.
Path _genericHull(Offset pos, double bearingDeg) =>
    _rotatedHull(pos, bearingDeg, const [
      Offset(0, -9),
      Offset(4, -2),
      Offset(4, 6),
      Offset(-4, 6),
      Offset(-4, -2),
    ]);

Path _hullForPlot(_AisPlot plot) {
  final type = plot.target.shipTypeId;
  if (type == 36 || type == 37) {
    return _sailboatHull(
      plot.pos,
      plot.screenCourseDeg,
      0.9,
    ); // sailing / pleasure craft
  }
  final bucket = type == null ? -1 : (type ~/ 10) * 10;
  if (bucket == 70 || bucket == 80) {
    return _cargoHull(plot.pos, plot.screenCourseDeg); // cargo / tanker
  }
  return _genericHull(plot.pos, plot.screenCourseDeg);
}

// Own-ship icon (user-supplied top-down sailboat artwork) — loaded once and cached.
ui.Image? _cachedShipIcon;
Future<ui.Image>? _shipIconLoading;
Future<ui.Image> loadShipIcon() {
  final cached = _cachedShipIcon;
  if (cached != null) return Future.value(cached);
  return _shipIconLoading ??= () async {
    final data = await rootBundle.load('assets/img/own_ship.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    _cachedShipIcon = frame.image;
    return frame.image;
  }();
}

class _AisRadarPainter extends CustomPainter {
  const _AisRadarPainter({
    required this.plots,
    required this.rangeNm,
    required this.ownScreenHeadingDeg,
    required this.northScreenAngleDeg,
    this.shipIcon,
  });
  final List<_AisPlot> plots;
  final double rangeNm;
  final double
  ownScreenHeadingDeg; // own ship icon rotation relative to screen-up
  final double northScreenAngleDeg; // where true north points on screen
  final ui.Image? shipIcon;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.shortestSide / 2 - 24;
    final ringPaint = Paint()
      ..color = const Color(0xff1a2c38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const ringLabelStyle = TextStyle(
      color: Color(0xff6f8fa3),
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );
    for (var i = 1; i <= 3; i++) {
      final r = maxR * i / 3;
      canvas.drawCircle(center, r, ringPaint);
      final labelNm = rangeNm * i / 3;
      final labelText = '${labelNm.toStringAsFixed(labelNm < 10 ? 1 : 0)} nm';
      final tp = TextPainter(
        text: TextSpan(text: labelText, style: ringLabelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelPos =
          center +
          Offset(r * math.sin(math.pi / 4), -r * math.cos(math.pi / 4));
      canvas.drawRect(
        Rect.fromCenter(
          center: labelPos,
          width: tp.width + 6,
          height: tp.height + 2,
        ),
        Paint()..color = const Color(0xcc0a161e),
      );
      tp.paint(canvas, labelPos - Offset(tp.width / 2, tp.height / 2));
    }
    // Heading indicator + "N" marker rotate with the view: in heading-up mode
    // north swings around us; in north-up mode our heading line swings instead.
    final headingRad2 = ownScreenHeadingDeg * math.pi / 180;
    final headingLineEnd =
        center +
        Offset(math.sin(headingRad2), -math.cos(headingRad2)) * (maxR + 16);
    canvas.drawLine(
      center,
      headingLineEnd,
      Paint()
        ..color = cCyan.withValues(alpha: 0.5)
        ..strokeWidth = 1.5,
    );
    final northRad = northScreenAngleDeg * math.pi / 180;
    final northPos =
        center + Offset(math.sin(northRad), -math.cos(northRad)) * (maxR + 12);
    final ntp = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(
          color: cCyan,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    ntp.paint(canvas, northPos - Offset(ntp.width / 2, ntp.height / 2));

    // Own ship: user-supplied top-down artwork if loaded, rotated to show our
    // actual heading relative to the screen — falls back to a drawn hull while it loads.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(headingRad2);
    canvas.translate(-center.dx, -center.dy);
    final icon = shipIcon;
    if (icon != null) {
      const targetH = 46.0;
      final targetW = targetH * icon.width / icon.height;
      final dst = Rect.fromCenter(
        center: center,
        width: targetW,
        height: targetH,
      );
      canvas.drawImageRect(
        icon,
        Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      final ownHull = _sailboatHull(center, 0, 1.5);
      canvas.drawPath(ownHull, Paint()..color = cGreen);
      canvas.drawPath(
        ownHull,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      canvas.drawLine(
        center + const Offset(0, -9),
        center + const Offset(0, 7),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 1,
      );
    }
    canvas.restore();

    for (final plot in plots) {
      final style = plot.stale
          ? (stroke: Colors.white, fill: const Color(0xffff00dc))
          : _aisTypeStyle(plot.target.shipTypeId);
      if (plot.trail.length >= 2) {
        final trailPath = Path()
          ..moveTo(plot.trail.first.dx, plot.trail.first.dy);
        for (final p in plot.trail.skip(1)) {
          trailPath.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
          trailPath,
          Paint()
            ..color = style.fill.withValues(alpha: 0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      final hull = _hullForPlot(plot);
      canvas.drawPath(hull, Paint()..color = style.fill);
      canvas.drawPath(
        hull,
        Paint()
          ..color = style.stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      canvas.drawLine(
        plot.pos,
        plot.vecEnd,
        Paint()
          ..color = style.fill
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      final label = plot.target.name ?? plot.target.mmsi ?? '?';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: style.fill,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, plot.pos + const Offset(10, -6));
    }
  }

  @override
  bool shouldRepaint(covariant _AisRadarPainter oldDelegate) => true;
}

void _showAisDetail(BuildContext context, _AisPlot p) {
  final t = p.target;
  Widget row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 150,
          child: Text(k, style: const TextStyle(color: cMuted, fontSize: 13)),
        ),
        Expanded(
          child: Text(
            v,
            style: const TextStyle(
              color: cText,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
  showDialog<void>(
    context: context,
    // `t` is the same mutable AisTarget kept in the target map — its fields
    // (position, COG, SOG...) keep updating live as new AIS data arrives,
    // even while this dialog is open. Without a refresh, a target tapped
    // right after it first appeared (before all its fields had arrived)
    // stayed frozen showing "--" until the dialog was closed and reopened.
    // Refreshing here every 2s means it fills in / corrects on its own.
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) {
        Timer(const Duration(seconds: 2), () {
          if (ctx.mounted) setSt(() {});
        });
        return AlertDialog(
          backgroundColor: cPanel,
          title: Text(
            t.name ?? 'Sin nombre',
            style: const TextStyle(color: cText),
          ),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (t.mmsi != null) _AisTargetPhoto(mmsi: t.mmsi!),
                row('MMSI', t.mmsi ?? '--'),
                row(
                  'Posición',
                  t.lat != null && t.lon != null
                      ? '${t.lat!.toStringAsFixed(4)}, ${t.lon!.toStringAsFixed(4)}'
                      : '--',
                ),
                row(
                  'Rumbo (COG)',
                  t.cogDeg != null ? '${t.cogDeg!.round()}°' : '--',
                ),
                row(
                  'Velocidad (SOG)',
                  t.sogKn != null ? '${t.sogKn!.toStringAsFixed(1)} kt' : '--',
                ),
                row(
                  'Distancia',
                  '${p.distNm.toStringAsFixed(2)} nm · ${p.bearingDeg.round()}°',
                ),
                row(
                  'CPA',
                  p.cpaNm != null ? '${p.cpaNm!.toStringAsFixed(2)} nm' : '--',
                ),
                row(
                  'TCPA',
                  p.tcpaMin != null
                      ? '${p.tcpaMin!.toStringAsFixed(0)} min'
                      : '--',
                ),
                if (_aisHasMeaningfulCpa(p)) row('Cruce', p.crossing!),
                row(
                  'Actualizado',
                  t.lastUpdate != null
                      ? 'hace ${DateTime.now().difference(t.lastUpdate!).inSeconds}s'
                      : '--',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    ),
  );
}

/// Vessel photo by MMSI via MarineTraffic's public (unauthenticated) photo
/// lookup — the same URL pattern several open-source AIS plotters (e.g.
/// OpenCPN's AIS plugin) use for a "show target photo" button. Not every
/// MMSI has a submitted photo, so failures are just hidden rather than
/// shown as an error.
class _AisTargetPhoto extends StatelessWidget {
  const _AisTargetPhoto({required this.mmsi});
  final String mmsi;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          'https://photos.marinetraffic.com/ais/showphoto.aspx?mmsi=$mmsi',
          height: 140,
          width: double.infinity,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const SizedBox(
              height: 140,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class AisRelativeView extends StatefulWidget {
  const AisRelativeView({super.key, 
    required this.targets,
    required this.ownHeadingDeg,
    required this.ownCogDeg,
    required this.ownSogKn,
    required this.ownLat,
    required this.ownLon,
  });
  final Map<String, AisTarget> targets;
  final double? ownHeadingDeg;
  final double? ownCogDeg;
  final double? ownSogKn;
  final double? ownLat;
  final double? ownLon;

  @override
  State<AisRelativeView> createState() => _AisRelativeViewState();
}

class _AisRelativeViewState extends State<AisRelativeView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _showList = false;
  bool _headingUp = true;
  bool _showTrail = false;
  bool _relativeMotion = true;
  static const _vectorPresetsMin = [6, 10, 15, 24, 30];
  int _vectorMinutes = 10;
  double? _rangeNm; // null = not yet auto-initialized
  double? _rangeAtGestureStart;
  ui.Image? _shipIcon;
  bool _showMapLayer = false;
  double _mapOpacity = 0.6;
  final _mapController = fm.MapController();

  void _cycleVectorMinutes() {
    final idx = _vectorPresetsMin.indexOf(_vectorMinutes);
    setState(
      () => _vectorMinutes =
          _vectorPresetsMin[(idx + 1) % _vectorPresetsMin.length],
    );
  }

  // Exact nm-range → flutter_map zoom mapping, calibrated against the radar's
  // own scale (outer ring = rangeNm at maxRPx pixels) via the standard Web
  // Mercator meters-per-pixel formula — a fixed heuristic here previously
  // caused the map layer to be zoomed to a different real-world scale than
  // the AIS targets it was drawn under, so boats could appear over land.
  double _zoomForRangeNm(double rangeNm, double maxRPx, double latDeg) {
    const earthCircumferenceM =
        156543.03392804097; // meters/px at zoom 0, equator
    final metersPerPx = (rangeNm * 1852) / maxRPx;
    final latRad = latDeg * math.pi / 180;
    final zoom =
        math.log(earthCircumferenceM * math.cos(latRad) / metersPerPx) /
        math.ln2;
    return zoom.clamp(2.0, 17.0);
  }

  @override
  void initState() {
    super.initState();
    loadShipIcon().then((img) {
      if (mounted) setState(() => _shipIcon = img);
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  double _effectiveRange() =>
      _rangeNm ??
      autoAisRangeNm(
        widget.targets.values.toList(),
        widget.ownLat,
        widget.ownLon,
      );

  void _zoomStep(double factor) {
    setState(() => _rangeNm = (_effectiveRange() * factor).clamp(0.25, 48.0));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      color: cBg,
      child: LayoutBuilder(
        builder: (ctx, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          final rangeNm = _effectiveRange();
          final ownHeading = widget.ownHeadingDeg ?? 0;
          final plots = _computeAisPlots(
            widget.targets.values.toList(),
            widget.ownLat,
            widget.ownLon,
            ownHeading,
            widget.ownCogDeg,
            widget.ownSogKn,
            size,
            rangeNm,
            headingUp: _headingUp,
            showTrail: _showTrail,
            relativeMotion: _relativeMotion,
            vectorMinutes: _vectorMinutes,
          );
          final viewRotDeg = _headingUp ? ownHeading : 0.0;
          final ownScreenHeadingDeg = normalize360(ownHeading - viewRotDeg);
          final northScreenAngleDeg = normalize360(0 - viewRotDeg);
          final maxR = size.shortestSide / 2 - 24;
          if (_showMapLayer &&
              !_showList &&
              widget.ownLat != null &&
              widget.ownLon != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              try {
                _mapController.moveAndRotate(
                  ll.LatLng(widget.ownLat!, widget.ownLon!),
                  _zoomForRangeNm(rangeNm, maxR, widget.ownLat!),
                  viewRotDeg,
                );
              } catch (_) {}
            });
          }
          return Stack(
            children: [
              if (_showMapLayer &&
                  !_showList &&
                  widget.ownLat != null &&
                  widget.ownLon != null)
                Positioned.fill(
                  child: Opacity(
                    opacity: _mapOpacity,
                    child: IgnorePointer(
                      child: _mapBackdrop(
                        widget.ownLat!,
                        widget.ownLon!,
                        rangeNm,
                        maxR,
                      ),
                    ),
                  ),
                ),
              if (_showList)
                _aisList(plots)
              else
                _aisRadar(
                  context,
                  plots,
                  size,
                  rangeNm,
                  ownScreenHeadingDeg,
                  northScreenAngleDeg,
                ),
              Positioned(
                top: 8,
                left: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IgnorePointer(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          const Text(
                            'HDG',
                            style: TextStyle(
                              color: cText,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.ownHeadingDeg != null
                                ? '${widget.ownHeadingDeg!.round()}°'
                                : '--',
                            style: const TextStyle(
                              color: cText,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!_showList) ...[
                      const SizedBox(height: 10),
                      _pillChip(
                        _headingUp ? 'RUMBO ARRIBA' : 'NORTE ARRIBA',
                        () => setState(() => _headingUp = !_headingUp),
                      ),
                      const SizedBox(height: 8),
                      _pillChip(
                        _relativeMotion ? 'VECTOR RELATIVO' : 'VECTOR REAL',
                        () =>
                            setState(() => _relativeMotion = !_relativeMotion),
                      ),
                      const SizedBox(height: 8),
                      _pillChip(
                        'VECTOR $_vectorMinutes MIN',
                        _cycleVectorMinutes,
                      ),
                      const SizedBox(height: 8),
                      _switchChip(
                        'TRACK 1H',
                        _showTrail,
                        (v) => setState(() => _showTrail = v),
                      ),
                      const SizedBox(height: 8),
                      _switchChip(
                        'MAPA',
                        _showMapLayer,
                        (v) => setState(() => _showMapLayer = v),
                      ),
                      if (_showMapLayer)
                        SizedBox(
                          width: 160,
                          height: 26,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                            ),
                            child: Slider(
                              value: _mapOpacity,
                              activeColor: cCyan,
                              onChanged: (v) => setState(() => _mapOpacity = v),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showList = !_showList),
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _showList ? Icons.radar : Icons.list,
                      color: cCyan,
                      size: 32,
                    ),
                  ),
                ),
              ),
              if (widget.ownLat == null || widget.ownLon == null)
                const Center(
                  child: Text(
                    'Sin posición GPS',
                    style: TextStyle(color: cMuted, fontSize: 16),
                  ),
                )
              else if (plots.isEmpty)
                const Center(
                  child: Text(
                    'Sin objetivos AIS',
                    style: TextStyle(color: cMuted, fontSize: 16),
                  ),
                ),
              if (!_showList)
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: Column(
                    children: [
                      _zoomButton(Icons.add, () => _zoomStep(0.7)),
                      const SizedBox(height: 8),
                      _zoomButton(Icons.remove, () => _zoomStep(1.4)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _mapBackdrop(double lat, double lon, double rangeNm, double maxRPx) =>
      fm.FlutterMap(
        mapController: _mapController,
        options: fm.MapOptions(
          initialCenter: ll.LatLng(lat, lon),
          initialZoom: _zoomForRangeNm(rangeNm, maxRPx, lat),
          interactionOptions: const fm.InteractionOptions(
            flags: fm.InteractiveFlag.none,
          ),
        ),
        children: [
          fm.TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.rewind.xcover6panel',
          ),
          fm.TileLayer(
            urlTemplate: 'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.rewind.xcover6panel',
          ),
          const fm.RichAttributionWidget(
            attributions: [
              fm.TextSourceAttribution('OpenStreetMap contributors'),
              fm.TextSourceAttribution('OpenSeaMap contributors'),
            ],
          ),
        ],
      );

  Widget _pillChip(String label, VoidCallback onTap) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(15),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: cCyan,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Widget _switchChip(String label, bool value, void Function(bool) onChanged) =>
      Container(
        height: 30,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: cMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            Transform.scale(
              scale: 0.65,
              child: Switch(
                value: value,
                activeThumbColor: cOrange,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      );

  Widget _zoomButton(IconData icon, VoidCallback onTap) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: cCyan, size: 22),
    ),
  );

  Widget _aisRadar(
    BuildContext context,
    List<_AisPlot> plots,
    Size size,
    double rangeNm,
    double ownScreenHeadingDeg,
    double northScreenAngleDeg,
  ) {
    // Pinch changes the nm-per-ring scale (like a real chartplotter), not a
    // canvas transform — icon/text sizes stay constant, only the range does.
    return GestureDetector(
      onScaleStart: (_) => _rangeAtGestureStart = rangeNm,
      onScaleUpdate: (d) {
        if (d.pointerCount < 2 || _rangeAtGestureStart == null) return;
        final next = (_rangeAtGestureStart! / d.scale).clamp(0.25, 48.0);
        setState(() => _rangeNm = next);
      },
      onTapUp: (d) {
        final hit = _hitTestAis(plots, d.localPosition);
        if (hit != null) _showAisDetail(context, hit);
      },
      child: CustomPaint(
        painter: _AisRadarPainter(
          plots: plots,
          rangeNm: rangeNm,
          ownScreenHeadingDeg: ownScreenHeadingDeg,
          northScreenAngleDeg: northScreenAngleDeg,
          shipIcon: _shipIcon,
        ),
        size: size,
      ),
    );
  }

  Widget _aisList(List<_AisPlot> plots) {
    // Bucket TCPA to the nearest 0.5 min and break ties by a stable key (the
    // target's own context id) — otherwise tiny tick-to-tick float jitter
    // between near-equal TCPAs makes rows swap places continuously.
    final sorted = [...plots]
      ..sort((a, b) {
        final ta = a.tcpaMin, tb = b.tcpaMin;
        if (ta == null && tb == null) {
          return a.target.context.compareTo(b.target.context);
        }
        if (ta == null) return 1;
        if (tb == null) return -1;
        final cmp = (ta * 2).round().compareTo((tb * 2).round());
        return cmp != 0 ? cmp : a.target.context.compareTo(b.target.context);
      });
    const headStyle = TextStyle(
      color: cMuted,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 40, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 150,
                  child: Text('BARCO', style: headStyle),
                ),
                SizedBox(
                  width: 78,
                  child: Text(
                    'TIPO',
                    style: headStyle,
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    'SOG',
                    style: headStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    'BRG',
                    style: headStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 54,
                  child: Text(
                    'DIST',
                    style: headStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    'CPA',
                    style: headStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    'TCPA',
                    style: headStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(
                  width: 92,
                  child: Text(
                    'CRUCE',
                    style: headStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Color(0xff1e3040), height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: sorted.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: Color(0xff1e3040), height: 1),
              itemBuilder: (ctx, i) {
                final p = sorted[i];
                final color = _aisColor(p);
                final crosses = _aisShowsCrossing(p);
                return InkWell(
                  onTap: () => _showAisDetail(ctx, p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 150,
                          child: Row(
                            children: [
                              Icon(
                                Icons.change_history,
                                color: color,
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  p.target.name ?? p.target.mmsi ?? '?',
                                  style: const TextStyle(
                                    color: cText,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 78,
                          child: Text(
                            _aisTypeName(p.target.shipTypeId),
                            style: const TextStyle(color: cMuted, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        SizedBox(
                          width: 46,
                          child: Text(
                            p.target.sogKn != null
                                ? p.target.sogKn!.toStringAsFixed(1)
                                : '--',
                            style: const TextStyle(color: cText, fontSize: 13),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 46,
                          child: Text(
                            '${p.bearingDeg.round()}°',
                            style: const TextStyle(color: cText, fontSize: 13),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 54,
                          child: Text(
                            '${p.distNm.toStringAsFixed(1)} nm',
                            style: const TextStyle(color: cText, fontSize: 13),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 52,
                          child: Text(
                            p.cpaNm != null
                                ? '${p.cpaNm!.toStringAsFixed(1)} nm'
                                : '--',
                            style: const TextStyle(color: cText, fontSize: 13),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 52,
                          child: Text(
                            p.tcpaMin != null
                                ? '${p.tcpaMin!.round()} min'
                                : '--',
                            style: const TextStyle(color: cText, fontSize: 13),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 92,
                          child: Text(
                            crosses ? p.crossing! : '--',
                            style: TextStyle(
                              color: crosses ? cOrange : cMuted,
                              fontSize: 12,
                              fontWeight: crosses
                                  ? FontWeight.w800
                                  : FontWeight.w400,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
