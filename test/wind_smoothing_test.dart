import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

List<GraphPoint> _series(List<double> values, {int stepSec = 10}) {
  final t0 = DateTime.utc(2026, 9, 7, 12);
  return [
    for (var i = 0; i < values.length; i++)
      GraphPoint(
        time: t0.add(Duration(seconds: i * stepSec)),
        value: values[i],
      ),
  ];
}

void main() {
  test(
    'rolling mean flattens oscillation while the band keeps the extremes',
    () {
      // Alternating 8/16 kt — mean should sit near 12 everywhere, but the
      // envelope must still reach the real 8 and 16 the boat actually saw.
      final pts = _series([8, 16, 8, 16, 8, 16, 8, 16, 8, 16]);
      final r = smoothSeriesWithBand(pts, const Duration(seconds: 40));

      expect(r.mean, hasLength(pts.length));
      expect(r.low, hasLength(pts.length));
      expect(r.high, hasLength(pts.length));

      // Interior points have a full window either side.
      for (final m in r.mean.sublist(2, r.mean.length - 2)) {
        expect(m.value, closeTo(12, 1.0));
      }
      expect(r.low.map((p) => p.value).reduce((a, b) => a < b ? a : b), 8);
      expect(r.high.map((p) => p.value).reduce((a, b) => a > b ? a : b), 16);
    },
  );

  test('circular mean survives the wrap seam that breaks a linear mean', () {
    // AWA hovering right at dead astern: -179 and +179 are 2 degrees apart,
    // but a plain arithmetic mean would report 0 (dead ahead) — the exact
    // opposite of the truth.
    final pts = _series([-179, 179, -178, 178, -179, 179]);
    final linear = pts.map((p) => p.value).reduce((a, b) => a + b) / pts.length;
    expect(linear.abs(), lessThan(1), reason: 'linear mean lands near 0');

    final r = smoothSeriesWithBand(
      pts,
      const Duration(seconds: 40),
      circular: true,
    );
    for (final m in r.mean) {
      // Every smoothed value must still read as "astern" (|angle| ~180),
      // never as "ahead".
      expect(m.value.abs(), greaterThan(170));
    }
  });

  test(
    'circular band width reflects the real angular spread, not the seam',
    () {
      final pts = _series([-175, 175, -170, 170]);
      final r = smoothSeriesWithBand(
        pts,
        const Duration(seconds: 60),
        circular: true,
      );
      for (var i = 0; i < pts.length; i++) {
        final spread = r.high[i].value - r.low[i].value;
        // True spread here is 20 degrees (170..190), not ~350.
        expect(spread, closeTo(20, 1));
      }
    },
  );

  test('a series shorter than the window is returned untouched', () {
    final pts = _series([5, 6]);
    final r = smoothSeriesWithBand(pts, const Duration(minutes: 1));
    expect(r.mean, same(pts));
    expect(r.low, isEmpty);
    expect(r.high, isEmpty);
  });

  test('smoothing window scales with the view but respects both limits', () {
    // Short view: proportional (1h/60 = 1 min) wins.
    expect(
      smoothingWindowFor(const Duration(hours: 1), const Duration(seconds: 10)),
      const Duration(minutes: 1),
    );
    // Long view: capped at the 10-minute sustained-wind period...
    expect(
      smoothingWindowFor(const Duration(hours: 24), const Duration(minutes: 2)),
      const Duration(minutes: 10),
    );
    // ...unless the source's own step is coarser, where averaging fewer
    // than a few samples would be pointless.
    expect(
      smoothingWindowFor(const Duration(days: 30), const Duration(hours: 1)),
      const Duration(hours: 3),
    );
  });
}
