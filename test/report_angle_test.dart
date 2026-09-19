import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';
import 'package:rewind_xcover6_panel/performance_report.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 19, 6);
  GraphPoint p(int s, double v) =>
      GraphPoint(time: t0.add(Duration(seconds: s)), value: v);

  test('viento del N que cruza 0°/360°: sale N, no SW', () {
    // Lo que dio REWIND (proveedor que solo hace medias aritméticas): en
    // cada intervalo fino, o bien todas las muestras a un lado del corte
    // (media válida), o bien a los dos (mín≈0, máx≈360: media basura).
    final mean = <GraphPoint>[], min = <GraphPoint>[], max = <GraphPoint>[];
    for (var i = 0; i < 180; i++) {
      final s = i * 2;
      switch (i % 3) {
        case 0: // todo al oeste del N
          mean.add(p(s, 354));
          min.add(p(s, 351));
          max.add(p(s, 358));
        case 1: // todo al este del N
          mean.add(p(s, 6));
          min.add(p(s, 2));
          max.add(p(s, 9));
        default: // cruzó el N: la media aritmética (≈ 200°) es basura
          mean.add(p(s, 203));
          min.add(p(s, 0.5));
          max.add(p(s, 359.6));
      }
    }
    final out = reportCircularAngleSeries(
      mean: mean,
      min: min,
      max: max,
      from: t0,
      interval: const Duration(minutes: 1),
      signed: false,
    );
    expect(out, hasLength(6));
    for (final q in out) {
      final fromNorth = q.value > 180 ? 360 - q.value : q.value;
      expect(fromNorth, lessThan(5), reason: '${q.value}');
    }
  });

  test('ángulos con signo (AWA) cruzando ±180° en empopada', () {
    final mean = [p(0, 178), p(2, -179), p(4, 2)]; // el último: cruzó
    final min = [p(0, 176), p(2, -179.5), p(4, -179)];
    final max = [p(0, 179), p(2, -178), p(4, 179)];
    final out = reportCircularAngleSeries(
      mean: mean,
      min: min,
      max: max,
      from: t0,
      interval: const Duration(minutes: 1),
      signed: true,
    );
    expect(out, hasLength(1));
    expect(out.single.value.abs(), greaterThan(178));
  });

  test('sin mín/máx de un intervalo, no se usa su media', () {
    final out = reportCircularAngleSeries(
      mean: [p(0, 200)],
      min: const [],
      max: const [],
      from: t0,
      interval: const Duration(minutes: 1),
      signed: false,
    );
    expect(out, isEmpty);
  });
}
