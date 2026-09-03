import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

// ─── Wind premium panel ──────────────────────────────────────────────────
// One "instrument cluster" screen reached by vertical swipe on VNT: a wind
// compass (AWA/TWA + AWS/TWS) on the left, a heading/TWD compass in the
// middle, a speed dial (SOG/STW) on the right — styled to match the Motor
// premium panel's realistic-gauge look (see widgets/motor_premium_panel.dart):
// dark glass dial, tapered needle with shadow+highlight, pale e-ink
// readouts for plain numbers. Kept as its own small file rather than
// reusing Motor's private painter classes directly (those are file-private
// and not exported); the shared look is achieved by mirroring the same
// drawing routines here, not by importing them.
//
// The wind compass face specifically follows a real wind instrument's
// layout (e.g. a Raymarine i60 Wind) rather than a generic speedometer: a
// ~300° sweep with a gap at the bottom, port/starboard color bands only
// across the typical close-hauled range (25°-60°, not the full side), and
// bow marks at the top instead of a solid arrowhead.

const _kEInkBg = Color(0xffd8d6cd);
const _kEInkText = Color(0xff33322c);

// Flat, matching cBg exactly (not a gradient) — three cards side by side
// each running their own diagonal gradient made the background look
// seamed at each card boundary; a flat fill (continued by the dial face's
// own flat fill, see _paintDialFace) reads as one continuous background
// with only the bezel rings marking where each instrument is.
Widget _panelShell({required Widget child}) => Card(
  color: Colors.transparent,
  elevation: 0,
  margin: EdgeInsets.zero,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  clipBehavior: Clip.antiAlias,
  child: Container(color: cBg, child: child),
);

// Same recessed/inset treatment as Motor's e-ink boxes: matte pale ground,
// a dark gradient hugging the top edge, a faint highlight along the
// bottom, so it reads as a screen sunk into the panel. [unlit] swaps the
// pale "powered" fill for a dim, un-backlit grey — matching the Motor
// panel's own dead-LCD look for "no contact"/"sin dato" instead of a
// legible "--" (see motor_premium_panel.dart's _AnalogGaugePainter).
Widget _eInkBox({
  required Widget child,
  BorderRadius? radius,
  bool unlit = false,
}) {
  final br = radius ?? BorderRadius.circular(4);
  return ClipRRect(
    borderRadius: br,
    child: Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: unlit ? const Color(0xff23241f) : _kEInkBg,
            borderRadius: br,
          ),
          child: child,
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: const Alignment(0, -0.1),
                colors: [
                  Colors.black.withValues(alpha: 0.32),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: const Alignment(0, 0.4),
                colors: [
                  Colors.white.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: br,
              border: Border.all(color: Colors.black.withValues(alpha: 0.25)),
            ),
          ),
        ),
      ],
    ),
  );
}

// The label lives on the dark panel, not inside the glass — like the
// printed name beside a real instrument's digital window — so it's plain
// white rather than colored per-metric, and the LCD itself only ever
// shows the number (+ a smaller unit suffix), never a title.
Widget _readoutLabel(String label, {double fontSize = 10}) => Text(
  label,
  style: TextStyle(
    color: cText,
    fontSize: fontSize,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.6,
  ),
);

// [value] of '--' means "no data" — rendered as a dead/unlit LCD (see
// _eInkBox) with no glyphs at all, instead of legible dashes, matching
// the Motor panel's own treatment for the same case.
Widget _eInkValue({
  required String value,
  String? unit,
  double valueFontSize = 20,
  double? unitFontSize,
}) {
  final unlit = value == '--';
  return _eInkBox(
    unlit: unlit,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Center(
        // Unlit still lays out the same glyphs (just invisible) rather than
        // an empty SizedBox, so the box keeps the exact height/width it
        // would have with real data instead of collapsing to the padding
        // alone ("las pantallas colapsan cuando no hay instrumentos").
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    color: unlit ? Colors.transparent : _kEInkText,
                    fontSize: valueFontSize,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (unit != null)
                  TextSpan(
                    text: unit,
                    style: TextStyle(
                      color: unlit ? Colors.transparent : _kEInkText,
                      fontSize: unitFontSize ?? valueFontSize * 0.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

const double _kReadoutWidth = 58.0;

Widget _readout({
  required String label,
  required String value,
  String? unit,
  double valueFontSize = 20,
  // Peak gust (same statisticalGustWithAge() formula as the VNT classic
  // grid's "r. NN" caption) — shown as a small muted line under the box
  // instead of inside the LCD glass, so it reads as a secondary figure
  // the way a real instrument prints peak gust under the main number.
  String? gust,
}) => SizedBox(
  width: _kReadoutWidth,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _readoutLabel(label),
      const SizedBox(height: 2),
      _eInkValue(value: value, unit: unit, valueFontSize: valueFontSize),
      if (gust != null) ...[
        const SizedBox(height: 1),
        Text(
          'r. $gust',
          style: const TextStyle(
            color: cMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ],
  ),
);

/// Wind compass (AWA/TWA) + heading/TWD compass + speed dial (SOG/STW), all
/// on one screen — every plain number lives in its own e-ink readout above
/// its dial ("fuera del círculo, mejor arriba que abajo"), not floating
/// separately or overlapping the dial face.
class PremiumWindPanel extends StatelessWidget {
  const PremiumWindPanel({
    super.key,
    this.awaDeg,
    this.twaDeg,
    this.awsKn,
    this.twsKn,
    this.awsGustKn,
    this.twsGustKn,
    this.twdDeg,
    this.twdShiftTrail = const [],
    this.headingDeg,
    this.sogKn,
    this.stwKn,
    this.shipIcon,
    this.maxSpeed = 12,
  });

  final double? awaDeg;
  final double? twaDeg;
  final double? awsKn;
  final double? twsKn;
  final double? awsGustKn;
  final double? twsGustKn;
  final double? twdDeg;
  // Recent TWD swing (see _WindShiftTracker.trail in trackers.dart) —
  // painted as a faint fading trail on the heading/TWD dial, empty if
  // there isn't enough history yet.
  final List<(double bearingDeg, double ageFrac)> twdShiftTrail;
  final double? headingDeg;
  final double? sogKn;
  final double? stwKn;
  final ui.Image? shipIcon;
  final double maxSpeed;

  static const _apparentColor = cCyan;
  static const _trueColor = cPurple;
  static const _sogColor = cGreen;
  static const _stwColor = cCyan;
  static const _twdColor = cOrange;

  String _deg(double? v) => v == null ? '--' : v.round().toString();
  String _kt(double? v) => v == null ? '--' : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          // Pushes the whole row (LCDs + dials + legends together, as one
          // group) down from the very top of the screen.
          SizedBox(height: constraints.maxHeight * 0.10),
          Expanded(child: _dialsRow()),
        ],
      ),
    ),
  );

  Widget _dialsRow() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 5,
        child: _DialColumn(
          legend: [
            _legendDot(_apparentColor, 'AWA'),
            _legendDot(_trueColor, 'TWA'),
          ],
          readouts: [
            _readout(label: 'AWA', value: _deg(awaDeg), unit: '°'),
            _readout(
              label: 'AWS',
              value: _kt(awsKn),
              unit: ' kt',
              gust: awsGustKn == null ? null : _kt(awsGustKn),
            ),
            const SizedBox(width: 20),
            _readout(
              label: 'TWS',
              value: _kt(twsKn),
              unit: ' kt',
              gust: twsGustKn == null ? null : _kt(twsGustKn),
            ),
            _readout(label: 'TWA', value: _deg(twaDeg), unit: '°'),
          ],
          painter: _WindCompassPainter(
            angle1: awaDeg,
            color1: _apparentColor,
            angle2: twaDeg,
            color2: _trueColor,
            shipIcon: shipIcon,
            faceLabel: 'VIENTO',
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        flex: 5,
        child: _DialColumn(
          legend: [_legendDot(_twdColor, 'TWD')],
          readouts: [
            _readout(label: 'RUMBO', value: _deg(headingDeg), unit: '°'),
          ],
          painter: _HeadingTwdPainter(
            headingDeg: headingDeg,
            twdDeg: twdDeg,
            twdColor: _twdColor,
            shiftTrail: twdShiftTrail,
            shipIcon: shipIcon,
            faceLabel: 'TWD',
          ),
          // TWD's own readout lives inside the dial, between the boat
          // icon and the south tick — there's real empty space there on
          // a compass face, and this is what real wind instruments do.
          // Sized/positioned to stay clear of both the rotated boat icon
          // and the TWD arrow even when heading and TWD are both 180°
          // (boat pointing south, arrow also pointing south) — kept
          // narrow and close to center, well inside where the arrow's
          // own tip sits.
          insideOverlay: (d) => Positioned(
            left: d * 0.40,
            right: d * 0.40,
            top: d * 0.66,
            height: d * 0.117,
            child: _eInkValue(
              value: _deg(twdDeg),
              unit: '°',
              valueFontSize: d * 0.075,
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        // Smaller than the other two — "el reloj de velocidad más
        // pequeño si hace falta", to make room for the new heading dial.
        flex: 3,
        child: _DialColumn(
          legend: [_legendDot(_sogColor, 'SOG'), _legendDot(_stwColor, 'STW')],
          readouts: [
            _readout(label: 'SOG', value: _kt(sogKn), unit: ' kt'),
            _readout(label: 'STW', value: _kt(stwKn), unit: ' kt'),
          ],
          painter: _DualSpeedNeedlePainter(
            value1: sogKn,
            color1: _sogColor,
            value2: stwKn,
            color2: _stwColor,
            max: maxSpeed,
            faceLabel: 'VELOCIDAD',
          ),
        ),
      ),
    ],
  );
}

Widget _legendDot(Color color, String label) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
    const SizedBox(width: 4),
    Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.4,
      ),
    ),
  ],
);

/// Shared shell for each of the 3 dials: a row of fixed-width e-ink
/// readouts (same width everywhere, regardless of which dial or how many
/// share the row — wraps onto a 2nd line if they don't fit) sitting close
/// above the dial, the dial itself, then the color legend below it. The
/// dial's own name is printed on its face (white, under the top mark —
/// see each painter's faceLabel), not up here. Every readout lives above
/// and outside the circle except where [insideOverlay] deliberately places
/// one inside a dial's own dead space.
class _DialColumn extends StatelessWidget {
  const _DialColumn({
    required this.legend,
    required this.readouts,
    required this.painter,
    this.insideOverlay,
  });

  final List<Widget> legend;
  final List<Widget> readouts;
  final CustomPainter painter;
  // Builds a widget positioned inside the dial's own Stack (e.g. the TWD
  // readout sitting between the boat icon and the south tick) — given the
  // dial's own pixel size so it can be placed proportionally.
  final Widget Function(double d)? insideOverlay;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: readouts,
      ),
      const SizedBox(height: 0),
      Expanded(
        child: _panelShell(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final d = math.min(constraints.maxWidth, constraints.maxHeight);
                return Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: d,
                    height: d,
                    child: Stack(
                      children: [
                        Positioned.fill(child: CustomPaint(painter: painter)),
                        if (insideOverlay != null) insideOverlay!(d),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < legend.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            legend[i],
          ],
        ],
      ),
    ],
  );
}

// Shared "realistic gauge" chrome — face, bezel, hub, glass reflection —
// factored out so every dial in this file paints it identically.
void _paintDialFace(Canvas canvas, Offset center, double r, double s) {
  // Flat, matching the card's own flat fill (_panelShell) — a continuous
  // background from the card edge into the dial, only the bezel ring
  // below marking the boundary.
  canvas.drawCircle(center, r, Paint()..color = cBg);
  canvas.drawCircle(
    center,
    r - s * 0.015,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.025
      ..shader = const SweepGradient(
        colors: [
          Color(0xff3a4a54),
          Color(0xff0c1418),
          Color(0xff3a4a54),
          Color(0xff0c1418),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: r)),
  );
}

// The dial's own name, printed on its face in white just under the top
// mark (bow marks / N / the 0 tick) — "como siempre se rotulan los
// relojes": a real instrument prints its own name on the dial, not in a
// caption floating above the whole card.
void _paintFaceLabel(
  Canvas canvas,
  Offset center,
  double r,
  double s,
  String label, {
  double verticalFactor = -0.42,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: Colors.white,
        fontSize: s * 0.055,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final pos = center + Offset(-tp.width / 2, r * verticalFactor);
  tp.paint(canvas, pos);
}

void _paintHub(
  Canvas canvas,
  Offset center,
  double s, {
  double hubFactor = 0.05,
}) {
  final hubR = s * hubFactor;
  canvas.drawCircle(
    center,
    hubR,
    Paint()
      ..shader = RadialGradient(
        colors: const [cMuted, cPanel2, Colors.black],
        stops: const [0, 0.6, 1],
      ).createShader(Rect.fromCircle(center: center, radius: hubR)),
  );
  canvas.drawCircle(
    center,
    hubR,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black.withValues(alpha: 0.6),
  );
}

// Glass-cover reflection — always painted *last*, on top of the needles
// too, the way a real instrument's glass sits above everything under it.
void _paintGlassReflection(Canvas canvas, Offset center, double r) {
  canvas.save();
  canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
  final reflectRect = Rect.fromCenter(
    center: center + Offset(-r * 0.32, -r * 0.42),
    width: r * 1.15,
    height: r * 0.62,
  );
  canvas.drawOval(
    reflectRect,
    Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.12),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(reflectRect),
  );
  canvas.restore();
}

void _paintHubAndGlass(
  Canvas canvas,
  Offset center,
  double r,
  double s, {
  double hubFactor = 0.05,
}) {
  _paintHub(canvas, center, s, hubFactor: hubFactor);
  _paintGlassReflection(canvas, center, r);
}

// Tapered needle from the hub — shadow, gradient fill, lengthwise
// highlight — the same shape used across every gauge in this app.
void _paintNeedle(
  Canvas canvas,
  Offset center,
  double r,
  double s,
  double angleRad,
  double needleLen,
  Color color, {
  double baseWFactor = 0.045,
}) {
  final dir = Offset(math.cos(angleRad), math.sin(angleRad));
  final perp = Offset(-math.sin(angleRad), math.cos(angleRad));
  final tailLen = r * 0.16;
  final baseW = s * baseWFactor;
  final tip = center + dir * needleLen;
  final baseL = center + perp * (baseW / 2) - dir * (tailLen * 0.1);
  final baseR = center - perp * (baseW / 2) - dir * (tailLen * 0.1);
  final tail = center - dir * tailLen;
  final path = Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo(baseL.dx, baseL.dy)
    ..lineTo(tail.dx, tail.dy)
    ..lineTo(baseR.dx, baseR.dy)
    ..close();

  canvas.save();
  canvas.translate(s * 0.01, s * 0.015);
  canvas.drawPath(
    path,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.01),
  );
  canvas.restore();

  canvas.drawPath(
    path,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color, color.withValues(alpha: 0.7)],
      ).createShader(path.getBounds()),
  );
  canvas.drawLine(
    center - dir * (tailLen * 0.5),
    center + dir * (needleLen * 0.9),
    Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = s * 0.005
      ..strokeCap = StrokeCap.round,
  );
}

/// Real-wind-instrument-style compass — a ~300° sweep (gap at the bottom)
/// instead of a full circle, port/starboard bands only across the typical
/// close-hauled range (25°-60°, matching the reference photo), and bow
/// marks (two short white lines forming a peak) instead of a solid
/// arrowhead. AWA is a normal needle from the hub; TWA is a small
/// arrowhead riding the tick ring, not touching the hub — two full
/// needles pivoting from the same center read as a clock, not a wind
/// instrument.
class _WindCompassPainter extends CustomPainter {
  const _WindCompassPainter({
    required this.angle1,
    required this.color1,
    required this.angle2,
    required this.color2,
    this.shipIcon,
    required this.faceLabel,
  });

  final double? angle1;
  final Color color1;
  final double? angle2;
  final Color color2;
  // Bow-up, unrotated — this dial is already bow-referenced (0° = dead
  // ahead), so unlike the heading dial the icon never rotates.
  final ui.Image? shipIcon;
  final String faceLabel;

  // 0° = straight up (bow), positive = clockwise (starboard) — matches
  // normalizeRelativeAngle's convention directly, no remapping needed.
  double _screenRad(double compassDeg) => (compassDeg - 90) * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final r = s / 2;

    _paintDialFace(canvas, center, r, s);
    // Pushed higher than the default — the bigger ship icon at center
    // (see targetH below) needs more clearance than the other dials.
    _paintFaceLabel(canvas, center, r, s, faceLabel, verticalFactor: -0.60);

    final tickOuter = r * 0.86;
    final tickInner = r * 0.76;
    final minorInner = r * 0.81;
    final bandOuter = tickOuter + s * 0.015;

    // Port (red) / starboard (green) bands only across 25°-60° each side —
    // the typical close-hauled/no-go zone highlight on a real wind
    // instrument, not a full-side band.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: bandOuter),
      _screenRad(-60),
      35 * math.pi / 180,
      false,
      Paint()
        ..color = cRed.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.02,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: bandOuter),
      _screenRad(25),
      35 * math.pi / 180,
      false,
      Paint()
        ..color = cGreen.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.02,
    );

    // Bow marks — two short white lines meeting in a peak at dead ahead,
    // like a stylized bow/sail outline, instead of a solid arrowhead.
    final peak = center + Offset(0, -bandOuter - s * 0.03);
    final baseL = center + Offset(-s * 0.045, -bandOuter + s * 0.01);
    final baseR = center + Offset(s * 0.045, -bandOuter + s * 0.01);
    final bowPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.012
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(baseL, peak, bowPaint);
    canvas.drawLine(peak, baseR, bowPaint);

    for (var deg = -150; deg <= 150; deg += 30) {
      final a = _screenRad(deg.toDouble());
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * tickInner,
        center + dir * tickOuter,
        Paint()
          ..color = cText.withValues(alpha: 0.85)
          ..strokeWidth = s * 0.01,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '${deg.abs()}',
          style: TextStyle(
            color: cMuted,
            fontSize: s * 0.045,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = center + dir * (tickInner - s * 0.07);
      tp.paint(canvas, Offset(lp.dx - tp.width / 2, lp.dy - tp.height / 2));

      if (deg < 150) {
        for (var m = 1; m < 3; m++) {
          final ma = _screenRad(deg + 10.0 * m);
          final mdir = Offset(math.cos(ma), math.sin(ma));
          canvas.drawLine(
            center + mdir * minorInner,
            center + mdir * tickOuter,
            Paint()
              ..color = cMuted.withValues(alpha: 0.5)
              ..strokeWidth = s * 0.005,
          );
        }
      }
    }

    // Own ship, bow-up (this dial is already bow-referenced, so unlike
    // the heading dial the icon never rotates) — replaces the plain metal
    // hub the other dials use. Drawn *before* the needles, so the needles
    // sweep over the boat rather than the boat sitting on top of them.
    final icon = shipIcon;
    if (icon != null) {
      final targetH = s * 0.34;
      final targetW = targetH * icon.width / icon.height;
      canvas.drawImageRect(
        icon,
        Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
        Rect.fromCenter(center: center, width: targetW, height: targetH),
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      _paintHub(canvas, center, s);
    }

    // AWA: full needle from the hub.
    if (angle1 != null) {
      final a = _screenRad(angle1!.clamp(-150.0, 150.0));
      _paintNeedle(canvas, center, r, s, a, tickInner * 0.92, color1);
    }

    // TWA: a small arrowhead riding the tick ring, tip pointing outward
    // (toward the ring) — deliberately not connected to the hub, so it
    // reads as a distinct marker rather than a second clock hand sharing
    // the same pivot.
    if (angle2 != null) {
      final a = _screenRad(angle2!.clamp(-150.0, 150.0));
      final dir = Offset(math.cos(a), math.sin(a));
      final perp = Offset(-math.sin(a), math.cos(a));
      final outR = tickInner * 0.95;
      final inR = tickInner * 0.72;
      final tip = center + dir * outR;
      final baseL = center + dir * inR + perp * (s * 0.028);
      final baseR = center + dir * inR - perp * (s * 0.028);
      final arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(baseL.dx, baseL.dy)
        ..lineTo(baseR.dx, baseR.dy)
        ..close();
      canvas.drawPath(
        arrow,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.008),
      );
      canvas.drawPath(arrow, Paint()..color = color2);
      canvas.drawPath(
        arrow,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.004
          ..color = Colors.white.withValues(alpha: 0.4),
      );
    }

    _paintGlassReflection(canvas, center, r);
  }

  @override
  bool shouldRepaint(covariant _WindCompassPainter old) =>
      old.angle1 != angle1 ||
      old.angle2 != angle2 ||
      old.color1 != color1 ||
      old.color2 != color2 ||
      old.shipIcon != shipIcon;
}

/// North-up heading compass — the boat's own top-down icon (same artwork
/// as the AIS view, see loadShipIcon in ais_view.dart) rotated to true
/// heading, with an arrow on the ring showing where the true wind is
/// coming from (TWD, a true bearing, plotted directly since this dial is
/// already north-referenced — no heading correction needed for the arrow
/// itself).
class _HeadingTwdPainter extends CustomPainter {
  const _HeadingTwdPainter({
    required this.headingDeg,
    required this.twdDeg,
    required this.twdColor,
    this.shiftTrail = const [],
    required this.shipIcon,
    required this.faceLabel,
  });

  final double? headingDeg;
  final double? twdDeg;
  final Color twdColor;
  // Recent TWD swing — see PremiumWindPanel.twdShiftTrail.
  final List<(double bearingDeg, double ageFrac)> shiftTrail;
  final ui.Image? shipIcon;
  final String faceLabel;

  double _screenRad(double bearingDeg) => (bearingDeg - 90) * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final r = s / 2;

    _paintDialFace(canvas, center, r, s);
    _paintFaceLabel(canvas, center, r, s, faceLabel);

    final tickOuter = r * 0.86;
    final tickInner = r * 0.78;
    final minorInner = r * 0.82;
    const labels = {0: 'N', 90: 'E', 180: 'S', 270: 'W'};

    // Wind-shift trail — the swept TWD path over the last window (see
    // _WindShiftTracker in trackers.dart), sitting just outside the tick
    // ring so it never competes with the degree labels underneath. Drawn
    // as one thin wedge per sample (oldest first, so a freshly-revisited
    // bearing's more-opaque wedge lands on top of any older one there) —
    // a real trail, not a static envelope: it visibly expands wherever
    // the needle has actually swept, and its oldest end simply fades out
    // as those samples age past the window rather than staying fixed.
    // Drawn before the ticks/arrow so both stay legible on top of it.
    if (shiftTrail.isNotEmpty) {
      final bandInner = tickOuter + s * 0.01;
      final bandOuter = tickOuter + s * 0.075;
      const halfWidthDeg = 2.5;
      final sweepRad = halfWidthDeg * 2 * math.pi / 180;
      for (final (bearingDeg, ageFrac) in shiftTrail) {
        if (ageFrac <= 0) continue;
        final startRad = _screenRad(bearingDeg - halfWidthDeg);
        final wedge = Path()
          ..addArc(Rect.fromCircle(center: center, radius: bandOuter), startRad, sweepRad)
          ..arcTo(
            Rect.fromCircle(center: center, radius: bandInner),
            startRad + sweepRad,
            -sweepRad,
            false,
          )
          ..close();
        canvas.drawPath(
          wedge,
          Paint()..color = twdColor.withValues(alpha: 0.32 * ageFrac),
        );
      }
    }

    for (var deg = 0; deg < 360; deg += 30) {
      final a = _screenRad(deg.toDouble());
      final dir = Offset(math.cos(a), math.sin(a));
      final major = labels.containsKey(deg);
      canvas.drawLine(
        center + dir * tickInner,
        center + dir * tickOuter,
        Paint()
          ..color = cText.withValues(alpha: major ? 0.9 : 0.7)
          ..strokeWidth = s * (major ? 0.012 : 0.008),
      );
      final label = labels[deg] ?? '$deg';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: major ? cText : cMuted,
            fontSize: s * (major ? 0.06 : 0.038),
            fontWeight: major ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = center + dir * (tickInner - s * 0.07);
      tp.paint(canvas, Offset(lp.dx - tp.width / 2, lp.dy - tp.height / 2));

      for (var m = 1; m < 3; m++) {
        final ma = _screenRad(deg + 10.0 * m);
        final mdir = Offset(math.cos(ma), math.sin(ma));
        canvas.drawLine(
          center + mdir * minorInner,
          center + mdir * tickOuter,
          Paint()
            ..color = cMuted.withValues(alpha: 0.4)
            ..strokeWidth = s * 0.005,
        );
      }
    }

    // TWD arrow — an arrowhead riding just inside the tick ring, tip
    // pointing outward (toward the ring), showing where the wind is
    // coming from, same visual language as the wind compass's TWA marker.
    if (twdDeg != null) {
      final a = _screenRad(twdDeg!);
      final dir = Offset(math.cos(a), math.sin(a));
      final perp = Offset(-math.sin(a), math.cos(a));
      final outR = tickInner * 0.98;
      final inR = tickInner * 0.62;
      final tip = center + dir * outR;
      final baseL = center + dir * inR + perp * (s * 0.03);
      final baseR = center + dir * inR - perp * (s * 0.03);
      final arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(baseL.dx, baseL.dy)
        ..lineTo(baseR.dx, baseR.dy)
        ..close();
      canvas.drawPath(
        arrow,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.008),
      );
      canvas.drawPath(arrow, Paint()..color = twdColor);
      canvas.drawPath(
        arrow,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.004
          ..color = Colors.white.withValues(alpha: 0.4),
      );
    }

    // Own ship, top-down, rotated to true heading — same rotation pattern
    // as the AIS radar view (see ais_view.dart).
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(headingDeg == null ? 0 : headingDeg! * math.pi / 180);
    canvas.translate(-center.dx, -center.dy);

    // Bow line — extends straight up from the boat to the tick ring,
    // inside the same rotated block so it turns with the icon, making the
    // heading readable directly off the ring's degree marks.
    if (headingDeg != null) {
      canvas.drawLine(
        center,
        center + Offset(0, -tickInner),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..strokeWidth = s * 0.008
          ..strokeCap = StrokeCap.round,
      );
    }

    final icon = shipIcon;
    if (icon != null) {
      final targetH = s * 0.26;
      final targetW = targetH * icon.width / icon.height;
      canvas.drawImageRect(
        icon,
        Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
        Rect.fromCenter(center: center, width: targetW, height: targetH),
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      final boatPath = Path()
        ..moveTo(center.dx, center.dy - s * 0.1)
        ..lineTo(center.dx - s * 0.07, center.dy + s * 0.08)
        ..lineTo(center.dx + s * 0.07, center.dy + s * 0.08)
        ..close();
      canvas.drawPath(boatPath, Paint()..color = cText.withValues(alpha: 0.85));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HeadingTwdPainter old) =>
      old.headingDeg != headingDeg ||
      old.twdDeg != twdDeg ||
      old.twdColor != twdColor ||
      // Always a freshly-built list (see PremiumWindPanel.twdShiftTrail),
      // so reference inequality is deliberate here, not a missed
      // optimization: ageFrac keeps decaying with real time even when the
      // underlying bearings haven't changed, and the fade needs to keep
      // repainting to actually animate.
      old.shiftTrail != shiftTrail ||
      old.shipIcon != shipIcon;
}

class _DualSpeedNeedlePainter extends CustomPainter {
  const _DualSpeedNeedlePainter({
    required this.value1,
    required this.color1,
    required this.value2,
    required this.color2,
    required this.max,
    required this.faceLabel,
  });

  final double? value1;
  final Color color1;
  final double? value2;
  final Color color2;
  final double max;
  final String faceLabel;

  static const _startRad = math.pi * 0.75;
  static const _sweepRad = math.pi * 1.5;

  double _angleFor(double v) {
    final t = (v / max).clamp(0.0, 1.0);
    return _startRad + _sweepRad * t;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final r = s / 2;

    _paintDialFace(canvas, center, r, s);
    // This dial's 270° sweep puts a real tick (6, mid-scale) right at the
    // top — the default top placement collided with it. The gap this
    // style always leaves at the *bottom* (see _startRad/_sweepRad) is
    // clear space instead, same spot Motor's own gauges use for their
    // digital readout.
    _paintFaceLabel(canvas, center, r, s, faceLabel, verticalFactor: 0.58);

    final tickOuter = r * 0.82;
    final tickInner = r * 0.72;
    final minorInner = r * 0.77;
    final majorStep = max <= 12 ? 2.0 : 5.0;
    final steps = (max / majorStep).round().clamp(1, 20);
    for (var i = 0; i <= steps; i++) {
      final v = majorStep * i;
      final a = _angleFor(v);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * tickInner,
        center + dir * tickOuter,
        Paint()
          ..color = cText.withValues(alpha: 0.85)
          ..strokeWidth = s * 0.012,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: v.round().toString(),
          style: TextStyle(
            color: cMuted,
            fontSize: s * 0.08,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = center + dir * (tickInner - s * 0.075);
      tp.paint(canvas, Offset(lp.dx - tp.width / 2, lp.dy - tp.height / 2));
      if (i < steps) {
        for (var m = 1; m < 4; m++) {
          final ma = _angleFor(v + majorStep * m / 4);
          final mdir = Offset(math.cos(ma), math.sin(ma));
          canvas.drawLine(
            center + mdir * minorInner,
            center + mdir * tickOuter,
            Paint()
              ..color = cMuted.withValues(alpha: 0.45)
              ..strokeWidth = s * 0.006,
          );
        }
      }
    }

    if (value1 != null) {
      _paintNeedle(
        canvas,
        center,
        r,
        s,
        _angleFor(value1!),
        tickInner * 0.92,
        color1,
        baseWFactor: 0.06,
      );
    }
    if (value2 != null) {
      _paintNeedle(
        canvas,
        center,
        r,
        s,
        _angleFor(value2!),
        tickInner * 0.7,
        color2,
        baseWFactor: 0.06,
      );
    }

    _paintHubAndGlass(canvas, center, r, s, hubFactor: 0.055);
  }

  @override
  bool shouldRepaint(covariant _DualSpeedNeedlePainter old) =>
      old.value1 != value1 ||
      old.value2 != value2 ||
      old.color1 != color1 ||
      old.color2 != color2 ||
      old.max != max;
}
