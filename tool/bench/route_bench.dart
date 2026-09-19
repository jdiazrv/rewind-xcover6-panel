// Mide el motor de routing: `dart run` (VM) y compilado a JS (como en la
// webapp) con `dart compile js` + node.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rewind_xcover6_panel/polars.dart';
import 'package:rewind_xcover6_panel/routing/geo.dart';
import 'package:rewind_xcover6_panel/routing/routing_engine.dart';
import 'package:rewind_xcover6_panel/routing/weather.dart';

final polar = PolarTable(
  id: 'dehler47',
  name: 'Dehler 47',
  tws: const [6, 8, 10, 12, 14, 16, 20],
  twa: const [52, 60, 75, 90, 110, 120, 135, 150],
  speeds: const [
    [5.49, 6.54, 7.4, 7.91, 8.17, 8.28, 8.32],
    [5.82, 6.88, 7.69, 8.12, 8.36, 8.5, 8.61],
    [6.08, 7.16, 7.9, 8.28, 8.53, 8.73, 9.01],
    [6.0, 7.25, 8.07, 8.45, 8.61, 8.81, 9.29],
    [6.06, 7.38, 8.19, 8.61, 8.96, 9.29, 9.7],
    [5.89, 7.19, 8.08, 8.54, 8.91, 9.3, 10.05],
    [5.31, 6.55, 7.58, 8.21, 8.6, 8.98, 9.84],
    [4.44, 5.62, 6.64, 7.57, 8.18, 8.57, 9.3],
  ],
  beatAngle: const [43.6, 41.4, 41.2, 40.5, 39.4, 38.7, 37.6],
  beatVmg: const [3.56, 4.35, 4.97, 5.46, 5.74, 5.87, 6.0],
  runAngle: const [140.6, 148.4, 151.1, 153.8, 160.4, 173.6, 179],
  runVmg: const [3.85, 4.87, 5.76, 6.58, 7.28, 7.88, 8.68],
);

WeatherGrid grid() {
  const nLat = 25, nLon = 25;
  final times = [
    for (var h = 0; h <= 60; h++) DateTime.utc(2026, 9, 19).add(Duration(hours: h)),
  ];
  final n = times.length * nLat * nLon;
  final u = Float32List(n), v = Float32List(n), h = Float32List(n);
  final du = Float32List(n), dv = Float32List(n), per = Float32List(n);
  for (var t = 0; t < times.length; t++) {
    for (var i = 0; i < nLat; i++) {
      for (var j = 0; j < nLon; j++) {
        final k = (t * nLat + i) * nLon + j;
        final dir = 10.0 + 30 * math.sin(t / 8 + j / 6);
        final c = windComponents(9 + 5 * math.sin(i / 5 + t / 10), dir);
        u[k] = c.u;
        v[k] = c.v;
        h[k] = 0.5 + 0.4 * math.sin(j / 4);
        final w = unitVector(dir);
        du[k] = w.u;
        dv[k] = w.v;
        per[k] = 5;
      }
    }
  }
  return WeatherGrid(
    lat0: 36.0, lon0: 23.0, step: 0.15, nLat: nLat, nLon: nLon, times: times,
    windU: u, windV: v, waveH: h, waveDirU: du, waveDirV: dv, waveT: per,
    model: WeatherModel.ecmwf, source: 'bench', fetchedAt: DateTime.utc(2026, 9, 19),
  );
}

// ignore_for_file: avoid_print

void main() {
  final g = grid();
  final dest = destinationNm(36.5, 23.4, 20, 100); // 100 M ciñendo
  final req = RouteRequest(
    waypoints: [(lat: 36.5, lon: 23.4), (lat: dest.lat, lon: dest.lon)],
    departure: DateTime.utc(2026, 9, 19, 2),
    grid: g,
    polar: polar,
    polarFactorPercent: 100,
    constraints: const RoutingConstraints(allowMotor: false),
    objective: RoutingObjective.fast,
  );
  computeRoute(req); // calentamiento
  final sw = Stopwatch()..start();
  var isos = 0;
  final r = computeRoute(req, onIsochrone: (_) => isos++);
  print('ruta ${r.totalNm.toStringAsFixed(1)} M, ${r.complete ? 'completa' : 'incompleta'}, '
      '$isos isócronas, ${sw.elapsedMilliseconds} ms');
}
