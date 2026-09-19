import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart' show normalizeRelativeAngle;
import 'package:rewind_xcover6_panel/polars.dart';
import 'package:rewind_xcover6_panel/routing/geo.dart';
import 'package:rewind_xcover6_panel/routing/land_mask.dart';
import 'package:rewind_xcover6_panel/routing/routing_engine.dart';
import 'package:rewind_xcover6_panel/routing/sailing_calc.dart';
import 'package:rewind_xcover6_panel/routing/weather.dart';

/// El Dehler 47 real del catálogo (assets/polars/orc_polars.json), para
/// probar el motor con una polar de verdad y no una inventada.
final dehler47 = PolarTable(
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

/// Rejilla amplia (2°, cubre de sobra 20 M) con viento y ola constantes,
/// para aislar el algoritmo del router de la interpolación de la rejilla.
WeatherGrid flatGrid({
  required double twsKn,
  required double twdDeg,
  double? waveHeightM,
  double waveDirDeg = 0,
  double wavePeriodS = 5,
  double lat0 = 36.5,
  double lon0 = 23.5,
  int hours = 30,
  double? gustKn,
}) {
  const n = 6;
  final times = [
    for (var h = 0; h <= hours; h++)
      DateTime.utc(2026, 9, 19).add(Duration(hours: h)),
  ];
  final size = times.length * n * n;
  Float32List filled(double v) => Float32List(size)..fillRange(0, size, v);
  final wc = windComponents(twsKn, twdDeg);
  final u = filled(wc.u), v = filled(wc.v);
  final h = waveHeightM == null ? filled(double.nan) : filled(waveHeightM);
  final wv = unitVector(waveDirDeg);
  final du = waveHeightM == null ? filled(double.nan) : filled(wv.u);
  final dv = waveHeightM == null ? filled(double.nan) : filled(wv.v);
  final per = waveHeightM == null ? filled(double.nan) : filled(wavePeriodS);
  return WeatherGrid(
    lat0: lat0,
    lon0: lon0,
    step: 2.0,
    nLat: n,
    nLon: n,
    times: times,
    windU: u,
    windV: v,
    waveH: h,
    waveDirU: du,
    waveDirV: dv,
    waveT: per,
    gust: gustKn == null ? null : filled(gustKn),
    model: WeatherModel.ecmwf,
    source: 'test',
    fetchedAt: DateTime.utc(2026, 9, 18),
  );
}

RouteRequest request(
  WeatherGrid grid,
  ({double lat, double lon}) dest, {
  RoutingConstraints constraints = const RoutingConstraints(),
  RoutingObjective objective = RoutingObjective.fast,
  DateTime? departure,
}) => RouteRequest(
  waypoints: [(lat: 37.4, lon: 24.0), dest],
  departure: departure ?? DateTime.utc(2026, 9, 19, 6),
  grid: grid,
  polar: dehler47,
  polarFactorPercent: 100,
  constraints: constraints,
  objective: objective,
);

void main() {
  final departure = DateTime.utc(2026, 9, 19, 6);

  group('rumbo directo posible', () {
    test('viento de través: ruta recta, a vela', () {
      // Salida a 37.4N/24.0E, llegada 10 M al Este; viento del N (a
      // través): TWA=90°, sobradamente navegable, sin necesidad de bordo.
      final grid = flatGrid(twsKn: 14, twdDeg: 0);
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue);
      expect(result.segments, isNotEmpty);
      expect(
        result.segments.every((s) => s.mode == PropulsionMode.sailing),
        isTrue,
      );
      // 10 M a ~8 kn son poco más de una hora.
      expect(result.totalDuration.inMinutes, lessThan(110));
      // El rumbo medio debe apuntar hacia el Este, sin desvíos disparatados.
      final avgHeading =
          result.segments.map((s) => s.headingDeg).reduce((a, b) => a + b) /
          result.segments.length;
      expect(avgHeading, closeTo(90, 25));
    });
  });

  group('ángulo muerto: ceñida real', () {
    test('llegada justo a barlovento fuerza bordos, no línea recta', () {
      // El viento sopla del mismo rumbo que la llegada: ir en línea recta
      // exigiría TWA=0°, muy por debajo del ángulo de ceñida (~41° a 10
      // kn). El router tiene que virar.
      final grid = flatGrid(twsKn: 10, twdDeg: 0);
      final dest = destinationNm(37.4, 24.0, 0, 8); // 8 M al N, viento del N
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(allowMotor: false),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.segments, isNotEmpty);
      // Ningún tramo puede ir dentro del ángulo muerto: TWA real >= la
      // ceñida óptima de la polar a ese viento (con algo de margen porque
      // el TWS efectivo varía poco).
      for (final s in result.segments) {
        expect(s.twaDeg, greaterThanOrEqualTo(38));
      }
      // Con el viento fijo del N, un rumbo directo sería 0°/360°: la ruta
      // real debe alternar bordos a un lado y otro de ese eje.
      final headings = result.segments.map((s) => s.headingDeg).toSet();
      final hasPort = headings.any((h) => h > 180 && h < 360);
      final hasStarboard = headings.any((h) => h > 0 && h < 180);
      expect(
        hasPort && hasStarboard,
        isTrue,
        reason: 'debe haber bordos a los dos lados: $headings',
      );
    });
  });

  group('vela / motor', () {
    test('barco cansado (factor bajo) por debajo del mínimo, motora', () {
      // La polar clampa por debajo de su TWS mínima (no extrapola a
      // cero), así que "poco viento" no basta para forzar el motor: se
      // simula un barco lento (fondo sucio, velas viejas) con el factor.
      final grid = flatGrid(twsKn: 10, twdDeg: 180);
      final dest = destinationNm(37.4, 24.0, 90, 6);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 30,
          constraints: const RoutingConstraints(
            minimumSailingSTW: 4,
            motorSpeedKn: 6,
          ),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue);
      expect(
        result.segments.every((s) => s.mode == PropulsionMode.motor),
        isTrue,
      );
      expect(result.segments.every((s) => s.stwKn == 6), isTrue);
    });

    test('sin motor permitido, navega despacio a vela en vez de pararse', () {
      final grid = flatGrid(twsKn: 6, twdDeg: 180);
      final dest = destinationNm(37.4, 24.0, 90, 4);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(
            minimumSailingSTW: 8, // por encima de lo que da la polar aquí
            allowMotor: false,
          ),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.segments, isNotEmpty);
      expect(
        result.segments.every((s) => s.mode == PropulsionMode.sailing),
        isTrue,
      );
    });
  });

  group('ola', () {
    test('por encima del máximo absoluto, la pierna no se completa', () {
      final grid = flatGrid(
        twsKn: 14,
        twdDeg: 0,
        waveHeightM: 1.5, // por encima del absoluteMaxWaveM por defecto (1.0)
      );
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(allowMotor: false),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isFalse);
      expect(result.warning, isNotNull);
    });

    test('modo confort evita la ola incómoda cuando hay alternativa', () {
      // Rejilla con una franja de mala mar cruzando la ruta directa: el
      // modo Confort debe rodearla más que el Rápido.
      final n = 8;
      final lat0 = 37.0, lon0 = 23.6, step = 0.2;
      final hours = 20;
      final times = [
        for (var h = 0; h <= hours; h++)
          DateTime.utc(2026, 9, 19).add(Duration(hours: h)),
      ];
      final size = times.length * n * n;
      Float32List filled(double v) => Float32List(size)..fillRange(0, size, v);
      final wc = windComponents(12, 0);
      final u = filled(wc.u), v = filled(wc.v);
      final h = filled(0.3);
      // Franja de 1.4 m de ola justo en el centro (columna 3-4) — dentro
      // del máximo absoluto (para no bloquear) pero por encima del
      // preferido.
      for (var t = 0; t < times.length; t++) {
        for (var i = 0; i < n; i++) {
          for (var j = 3; j <= 4; j++) {
            h[(t * n + i) * n + j] = 0.95;
          }
        }
      }
      final wv = unitVector(0);
      final du = filled(wv.u), dv = filled(wv.v), per = filled(5);
      final grid = WeatherGrid(
        lat0: lat0,
        lon0: lon0,
        step: step,
        nLat: n,
        nLon: n,
        times: times,
        windU: u,
        windV: v,
        waveH: h,
        waveDirU: du,
        waveDirV: dv,
        waveT: per,
        model: WeatherModel.ecmwf,
        source: 'test',
        fetchedAt: DateTime.utc(2026, 9, 18),
      );
      final start = (lat: lat0 + 0.7, lon: lon0 + 0.1);
      final dest = (lat: lat0 + 0.7, lon: lon0 + 1.3);
      const constraints = RoutingConstraints(
        absoluteMaxWaveM: 2.0,
        preferredMaxWaveM: 0.6,
        maxTimeAbovePreferred: Duration(hours: 12),
      );
      final fast = computeRoute(
        RouteRequest(
          waypoints: [start, dest],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: constraints,
          objective: RoutingObjective.fast,
        ),
      );
      final comfort = computeRoute(
        RouteRequest(
          waypoints: [start, dest],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: constraints,
          objective: RoutingObjective.comfort,
        ),
      );
      double minutesInBadSea(RouteResult r) => r.segments
          .where((s) => (s.waveHeightM ?? 0) > 0.6)
          .fold(0.0, (a, s) => a + s.duration.inMinutes);
      expect(minutesInBadSea(comfort), lessThanOrEqualTo(minutesInBadSea(fast)));
    });
  });

  group('varios puntos', () {
    test('hasta 10 puntos encadenan sus piernas', () {
      final grid = flatGrid(twsKn: 12, twdDeg: 45, hours: 40);
      final points = [
        for (var i = 0; i < 5; i++) destinationNm(37.4, 24.0, 90, i * 4.0),
      ];
      final result = computeRoute(
        RouteRequest(
          waypoints: [for (final p in points) (lat: p.lat, lon: p.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue);
      expect(
        result.segments.map((s) => s.waypointIndex).toSet(),
        {0, 1, 2, 3},
      );
    });

    test('rechaza más de 10 puntos', () {
      expect(
        () => computeRoute(
          RouteRequest(
            waypoints: [for (var i = 0; i < 11; i++) (lat: 37.0 + i * 0.01, lon: 24.0)],
            departure: departure,
            grid: flatGrid(twsKn: 10, twdDeg: 0),
            polar: dehler47,
            polarFactorPercent: 100,
            constraints: const RoutingConstraints(),
            objective: RoutingObjective.fast,
          ),
        ),
        throwsA(isA<RoutingException>()),
      );
    });
  });

  group('AWA mínimo', () {
    test('sin motor, abre el bordo: ningún tramo a vela más cerrado que el mínimo', () {
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      final dest = destinationNm(37.4, 24.0, 0, 12); // a barlovento
      const minAwa = 32.0;
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(
            allowMotor: false,
            minimumAwaDeg: minAwa,
          ),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue); // no se queda parado: abre el bordo
      for (final s in result.segments) {
        expect(s.mode, PropulsionMode.sailing);
        expect(s.awaDeg.abs(), greaterThanOrEqualTo(minAwa - 0.01));
      }
    });

    test('con motor, un rumbo más cerrado que el mínimo nunca va a vela', () {
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      final dest = destinationNm(37.4, 24.0, 0, 12);
      const minAwa = 32.0;
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(minimumAwaDeg: minAwa),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue);
      for (final s in result.segments.where((s) => s.mode == PropulsionMode.sailing)) {
        expect(s.awaDeg.abs(), greaterThanOrEqualTo(minAwa - 0.01));
      }
    });
  });

  group('cálculo en isolate', () {
    test('avisa del progreso real y da el mismo resultado que el síncrono', () async {
      final grid = flatGrid(twsKn: 14, twdDeg: 0);
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final req = RouteRequest(
        waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
        departure: departure,
        grid: grid,
        polar: dehler47,
        polarFactorPercent: 100,
        constraints: const RoutingConstraints(),
        objective: RoutingObjective.fast,
      );
      final progress = <double>[];
      final result = await computeRouteInIsolate(req, progress.add);
      expect(result.complete, isTrue);
      expect(progress, isNotEmpty);
      // Sube (no baja) y no se sale de 0–1.
      expect(progress.every((p) => p >= 0 && p <= 1), isTrue);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      final sync = computeRoute(req);
      expect(result.segments.length, sync.segments.length);
      expect(result.totalNm, closeTo(sync.totalNm, 0.01));
    });
  });

  group('maniobras', () {
    test('corregir el rumbo hacia el destino no cuenta como virada', () {
      // Ruta corta y de través: el óptimo real reajusta el rumbo un poco
      // en cada paso para no pasarse de largo, sin cruzar nunca al otro
      // lado del viento. Antes de distinguir "corregir" de "virar" esto
      // fallaba: la penalización empujaba la búsqueda lejos del destino
      // y la pierna nunca llegaba a los 0,35 M de llegada.
      final grid = flatGrid(twsKn: 14, twdDeg: 0, hours: 10);
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue);
    });

    test('virar de verdad (cruzar el eje del viento) sí tiene coste', () {
      // Con el destino justo a barlovento, la búsqueda TIENE que cruzar
      // de un bordo a otro más de una vez; cada cruce debe costar algo,
      // así que una ruta que necesita muchos bordos cortos sale peor
      // puntuada que una que ciñe limpio con pocos. Se comprueba
      // indirectamente: la ruta completa igualmente (la penalización no
      // bloquea virar cuando hace falta, solo lo desalienta si sale
      // gratis virar cada paso).
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      final dest = destinationNm(37.4, 24.0, 0, 18);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(allowMotor: false),
          objective: RoutingObjective.fast,
        ),
      );
      // Con la penalización activa no debe virar en cada uno de los
      // pasos: alguna racha se mantiene el mismo bordo más de un paso.
      var maxHeld = 0;
      var held = 1;
      for (var i = 1; i < result.segments.length; i++) {
        final a = result.segments[i - 1], b = result.segments[i];
        final sameSide =
            normalizeRelativeAngle(a.headingDeg - a.twdDeg).sign ==
            normalizeRelativeAngle(b.headingDeg - b.twdDeg).sign;
        held = sameSide ? held + 1 : 1;
        if (held > maxHeld) maxHeld = held;
      }
      expect(maxHeld, greaterThan(1));
    });
  });

  group('arreglos de la auditoría', () {
    test('F1: Confort no penaliza la ola por debajo de la cómoda', () {
      // Ola de 0,5 m en toda la zona, por debajo de la cómoda (0,6): Confort
      // tiene que dar la misma ruta que Rápido.
      final grid = flatGrid(twsKn: 14, twdDeg: 0, waveHeightM: 0.5);
      final dest = destinationNm(37.4, 24.0, 60, 15);
      final d = (lat: dest.lat, lon: dest.lon);
      final fast = computeRoute(request(grid, d));
      final comfort = computeRoute(
        request(grid, d, objective: RoutingObjective.comfort),
      );
      expect(comfort.complete, isTrue);
      expect(comfort.totalDuration, fast.totalDuration);
      expect(comfort.totalNm, closeTo(fast.totalNm, 0.01));
    });

    test('F2: Confort respeta el tope de tiempo con ola incómoda', () {
      // 0,8 m en toda la zona (por encima de la cómoda, por debajo de la
      // máxima): 15 M son ~2 h, más que la hora que admite por defecto.
      final grid = flatGrid(twsKn: 14, twdDeg: 0, waveHeightM: 0.8);
      final dest = destinationNm(37.4, 24.0, 90, 15);
      final d = (lat: dest.lat, lon: dest.lon);
      final comfort = computeRoute(
        request(grid, d, objective: RoutingObjective.comfort),
      );
      expect(comfort.complete, isFalse);
      expect(comfort.warning, contains('ola por encima de la cómoda'));
      // Rápido no tiene ese tope; con un tope mayor, Confort sí llega.
      expect(computeRoute(request(grid, d)).complete, isTrue);
      final relaxed = computeRoute(
        request(
          grid,
          d,
          objective: RoutingObjective.comfort,
          constraints: const RoutingConstraints(
            maxTimeAbovePreferred: Duration(hours: 4),
          ),
        ),
      );
      expect(relaxed.complete, isTrue);
    });

    test('F3: Personalizado con peso 0 y sin tope práctico es como Rápido', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0, waveHeightM: 0.8);
      final dest = destinationNm(37.4, 24.0, 60, 15);
      final d = (lat: dest.lat, lon: dest.lon);
      const c = RoutingConstraints(
        comfortWeight: 0,
        maxTimeAbovePreferred: Duration(hours: 24),
      );
      final fast = computeRoute(request(grid, d, constraints: c));
      final custom = computeRoute(
        request(grid, d, constraints: c, objective: RoutingObjective.custom),
      );
      expect(custom.totalDuration, fast.totalDuration);
    });

    test('F4: fuera del tiempo descargado lo marca, no motora en silencio', () {
      // Rejilla de solo 1 h: el resto de la ruta queda sin previsión.
      final grid = flatGrid(twsKn: 14, twdDeg: 0, hours: 1);
      final dest = destinationNm(37.4, 24.0, 90, 20);
      final d = (lat: dest.lat, lon: dest.lon);
      final r = computeRoute(
        request(grid, d, departure: DateTime.utc(2026, 9, 19)),
      );
      expect(r.complete, isTrue);
      expect(r.noForecastFrom, isNotNull);
      final blind = r.segments.where((s) => s.noForecast).toList();
      expect(blind, isNotEmpty);
      expect(blind.every((s) => s.mode == PropulsionMode.motor), isTrue);

      final noMotor = computeRoute(
        request(
          grid,
          d,
          departure: DateTime.utc(2026, 9, 19),
          constraints: const RoutingConstraints(allowMotor: false),
        ),
      );
      expect(noMotor.complete, isFalse);
      expect(noMotor.warning, contains('sin previsión'));
    });

    test('F6: las viradas cuestan tiempo real y se cuentan', () {
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      final dest = destinationNm(37.4, 24.0, 0, 18); // a barlovento
      final r = computeRoute(
        request(
          grid,
          (lat: dest.lat, lon: dest.lon),
          constraints: const RoutingConstraints(allowMotor: false),
        ),
      );
      expect(r.complete, isTrue);
      final tacks = r.segments.where((s) => s.maneuver == ManeuverKind.tack);
      expect(tacks, isNotEmpty);
      for (final s in tacks) {
        // Recorre menos de lo que daría la velocidad en todo el tramo.
        final full = s.stwKn * s.duration.inSeconds / 3600;
        expect(s.distanceNm, lessThan(full - 0.05));
      }
      final sum = RouteSummary.of(r, const RoutingConstraints());
      expect(sum.tacks, tacks.length);
      expect(sum.upwindFraction, greaterThan(0.9));
      expect(sum.motorFraction, 0);
    });

    test('a motor, cruzar el eje del viento no es una virada', () {
      final grid = flatGrid(twsKn: 3, twdDeg: 0, hours: 10); // calma: motor
      final dest = destinationNm(37.4, 24.0, 0, 10);
      final r = computeRoute(request(grid, (lat: dest.lat, lon: dest.lon)));
      expect(r.complete, isTrue);
      expect(r.segments.every((s) => s.mode == PropulsionMode.motor), isTrue);
      expect(r.segments.where((s) => s.maneuver != null), isEmpty);
    });
  });

  group('rachas', () {
    test('la racha del modelo llega a cada tramo y al resumen', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0, gustKn: 21);
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final r = computeRoute(request(grid, (lat: dest.lat, lon: dest.lon)));
      expect(r.segments.every((s) => s.gustKn != null), isTrue);
      expect(r.segments.first.gustKn, closeTo(21, 0.01));
      final sum = RouteSummary.of(r, const RoutingConstraints());
      expect(sum.maxGustKn, closeTo(21, 0.01));
      expect(sum.maxTwsKn, closeTo(14, 0.01));
    });

    test('sin rachas en la rejilla, null (no se inventa)', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0);
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final r = computeRoute(request(grid, (lat: dest.lat, lon: dest.lon)));
      expect(r.segments.every((s) => s.gustKn == null), isTrue);
      expect(RouteSummary.of(r, const RoutingConstraints()).maxGustKn, isNull);
    });

    test('la racha nunca sale por debajo del viento medio', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0, gustKn: 10);
      expect(grid.sample(37.4, 24.0, departure)!.gustKn, closeTo(14, 0.01));
    });

    test('la racha sobrevive a guardar y leer de disco', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0, gustKn: 19);
      final back = WeatherGrid.fromJson(grid.toJson())!;
      expect(back.sample(37.4, 24.0, departure)!.gustKn, closeTo(19, 0.01));
      final old = flatGrid(twsKn: 14, twdDeg: 0);
      expect(WeatherGrid.fromJson(old.toJson())!.gust, isNull);
    });
  });

  group('isócronas', () {
    test('se emiten en orden, con puntos, y también desde el isolate', () async {
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      final dest = destinationNm(37.4, 24.0, 0, 12);
      final req = request(
        grid,
        (lat: dest.lat, lon: dest.lon),
        constraints: const RoutingConstraints(allowMotor: false),
      );
      final sync = <RouteIsochrone>[];
      computeRoute(req, onIsochrone: sync.add);
      expect(sync.length, greaterThan(4));
      for (var i = 1; i < sync.length; i++) {
        expect(sync[i].time.isAfter(sync[i - 1].time), isTrue);
      }
      expect(sync.every((iso) => iso.latLon.length >= 2), isTrue);
      expect(sync.every((iso) => iso.latLon.length.isEven), isTrue);

      final live = <RouteIsochrone>[];
      final r = await computeRouteInIsolate(req, (_) {}, onIsochrone: live.add);
      expect(r.complete, isTrue);
      expect(live.length, sync.length);
    });
  });

  group('progreso', () {
    test('avanza de forma pareja hasta el 100 %, sin saltos al final', () {
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      for (final (brg, nm) in [(90.0, 30.0), (0.0, 18.0)]) {
        final dest = destinationNm(37.4, 24.0, brg, nm);
        final progress = <double>[];
        computeRoute(
          request(
            grid,
            (lat: dest.lat, lon: dest.lon),
            constraints: const RoutingConstraints(allowMotor: false),
          ),
          onProgress: progress.add,
        );
        expect(progress.last, 1.0);
        var maxJump = 0.0;
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
          maxJump = math.max(maxJump, progress[i] - progress[i - 1]);
        }
        // Antes (paso / techo de pasos) el último salto era de más del 50 %.
        expect(maxJump, lessThan(0.2), reason: 'rumbo $brg');
      }
    });

    test('con vías, cada tramo pesa según su distancia', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0, hours: 30);
      final a = destinationNm(37.4, 24.0, 90, 2); // tramo corto
      final b = destinationNm(a.lat, a.lon, 90, 18); // tramo largo
      final progress = <double>[];
      computeRoute(
        RouteRequest(
          waypoints: [
            (lat: 37.4, lon: 24.0),
            (lat: a.lat, lon: a.lon),
            (lat: b.lat, lon: b.lon),
          ],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(),
          objective: RoutingObjective.fast,
        ),
        onProgress: progress.add,
      );
      // Al acabar el tramo corto se lleva ~10 %, no el 50 %.
      expect(progress.where((p) => p > 0.15 && p < 0.45), isNotEmpty);
      expect(progress.last, 1.0);
    });
  });

  group('webapp (sin isolates)', () {
    test('por trozos da lo mismo que el síncrono, con progreso e isócronas', () async {
      final grid = flatGrid(twsKn: 10, twdDeg: 0, hours: 30);
      final dest = destinationNm(37.4, 24.0, 0, 12);
      final req = request(
        grid,
        (lat: dest.lat, lon: dest.lon),
        constraints: const RoutingConstraints(allowMotor: false),
      );
      final progress = <double>[];
      final isos = <RouteIsochrone>[];
      // sliceMs 0: cede en cada paso, como haría un móvil lento.
      final r = await computeRouteChunked(
        req,
        progress.add,
        onIsochrone: isos.add,
        sliceMs: 0,
      );
      final sync = computeRoute(req);
      expect(r.complete, isTrue);
      expect(r.segments.length, sync.segments.length);
      expect(r.totalDuration, sync.totalDuration);
      expect(progress, isNotEmpty);
      expect(isos, isNotEmpty);
    });

    test('los errores de validación llegan igual', () async {
      final grid = flatGrid(twsKn: 10, twdDeg: 0);
      await expectLater(
        computeRouteChunked(
          RouteRequest(
            waypoints: [(lat: 37.4, lon: 24.0)],
            departure: departure,
            grid: grid,
            polar: dehler47,
            polarFactorPercent: 100,
            constraints: const RoutingConstraints(),
            objective: RoutingObjective.fast,
          ),
          (_) {},
        ),
        throwsA(isA<RoutingException>()),
      );
    });
  });

  group('máscara de costa', () {
    test('un istmo entre salida y llegada obliga a rodearlo', () {
      // Franja de tierra Norte-Sur cruzando la ruta directa Oeste-Este.
      final land = LandMask([
        const LandPolygon(
          [(24.05, 37.0), (24.15, 37.0), (24.15, 38.0), (24.05, 38.0)],
          [],
          (24.05, 37.0, 24.15, 38.0),
        ),
      ]);
      final grid = flatGrid(twsKn: 14, twdDeg: 0, hours: 20);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 23.9), (lat: 37.4, lon: 24.3)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(minimumCoastDistanceNm: 0.3),
          objective: RoutingObjective.fast,
          land: land,
        ),
      );
      expect(result.segments, isNotEmpty);
      for (final s in result.segments) {
        expect(land.isLand(s.endLat, s.endLon), isFalse);
      }
      // No es la línea recta: se ha desviado en latitud para rodear.
      final maxLatDrift = result.segments
          .map((s) => (s.endLat - 37.4).abs())
          .fold(0.0, math.max);
      expect(maxLatDrift, greaterThan(0.05));
    });

    test('sin máscara, no cambia el comportamiento de antes', () {
      final grid = flatGrid(twsKn: 14, twdDeg: 0);
      final dest = destinationNm(37.4, 24.0, 90, 10);
      final result = computeRoute(
        RouteRequest(
          waypoints: [(lat: 37.4, lon: 24.0), (lat: dest.lat, lon: dest.lon)],
          departure: departure,
          grid: grid,
          polar: dehler47,
          polarFactorPercent: 100,
          constraints: const RoutingConstraints(),
          objective: RoutingObjective.fast,
        ),
      );
      expect(result.complete, isTrue);
    });
  });

  group('LandMask', () {
    test('punto dentro del anillo es tierra; con hueco, el hueco es mar', () {
      final land = LandMask([
        const LandPolygon(
          [(0, 0), (10, 0), (10, 10), (0, 10)],
          [
            [(4, 4), (6, 4), (6, 6), (4, 6)],
          ],
          (0, 0, 10, 10),
        ),
      ]);
      expect(land.isLand(5, 5), isFalse); // en el hueco: mar
      expect(land.isLand(2, 2), isTrue);
      expect(land.isLand(20, 20), isFalse);
    });

    test('nearLand respeta el margen', () {
      final land = LandMask([
        const LandPolygon(
          [(0, 0), (1, 0), (1, 1), (0, 1)],
          [],
          (0, 0, 1, 1),
        ),
      ]);
      // A 1 minuto (1/60°) de la costa: dentro de un margen de 2 M, fuera de uno de 0.1 M.
      expect(land.nearLand(0.5, 1.0 + 1 / 60, 2.0), isTrue);
      expect(land.nearLand(0.5, 1.0 + 1 / 60, 0.1), isFalse);
    });
  });

  group('sailing_calc', () {
    test('viento aparente: proa al viento, mismo AWA que TWA', () {
      final aw = apparentWind(
        twsKn: 15,
        twdDeg: 0,
        headingDeg: 0,
        stwKn: 6,
      );
      // Yendo directos al viento, el aparente sigue viniendo de proa y es
      // más fuerte que el verdadero (verdadero + velocidad propia).
      expect(aw.awaDeg.abs(), lessThan(1));
      expect(aw.awsKn, closeTo(21, 0.1));
    });

    test('viento aparente: en popa, más flojo que el verdadero', () {
      final aw = apparentWind(
        twsKn: 15,
        twdDeg: 0,
        headingDeg: 180,
        stwKn: 6,
      );
      expect(aw.awsKn, closeTo(9, 0.1));
    });

    test('periodo de encuentro: mar de proa se acorta, de popa se alarga', () {
      final headSea = waveEncounter(
        headingDeg: 0,
        stwKn: 7,
        waveFromDeg: 0,
        wavePeriodS: 6,
      );
      final followingSea = waveEncounter(
        headingDeg: 0,
        stwKn: 7,
        waveFromDeg: 180,
        wavePeriodS: 6,
      );
      expect(headSea.periodS, isNotNull);
      expect(followingSea.periodS, isNotNull);
      expect(headSea.periodS!, lessThan(6));
      expect(followingSea.periodS!, greaterThan(6));
    });

    test('no inventa una altura: la Hs no forma parte del cálculo', () {
      // waveEncounter ni siquiera recibe la altura — verificación de
      // contrato por firma, no solo de comportamiento.
      final enc = waveEncounter(
        headingDeg: 90,
        stwKn: 5,
        waveFromDeg: 45,
        wavePeriodS: 7,
      );
      expect(enc.angleDeg, closeTo(45, 0.01));
    });
  });
}
