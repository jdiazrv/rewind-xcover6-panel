import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rewind_xcover6_panel/routing/boat_waves.dart';
import 'package:rewind_xcover6_panel/routing/open_meteo_weather.dart';
import 'package:rewind_xcover6_panel/routing/weather.dart';

/// Respuesta de Open-Meteo de una posición, con series por modelo.
Map<String, dynamic> windPoint(
  List<String> times,
  Map<String, (List<num?>, List<num?>)> byModel,
) => {
  'hourly': {
    'time': times,
    for (final e in byModel.entries) ...{
      'wind_speed_10m_${e.key}': e.value.$1,
      'wind_direction_10m_${e.key}': e.value.$2,
    },
  },
};

Map<String, dynamic> marinePoint(
  List<String> times,
  List<num?> h,
  List<num?> dir,
  List<num?> per,
) => {
  'hourly': {
    'time': times,
    'wave_height': h,
    'wave_direction': dir,
    'wave_period': per,
  },
};

const t2 = ['2026-09-19T04:00', '2026-09-19T05:00'];

/// Rejilla 2×2 × 2 horas con el mismo viento en todas partes salvo lo que
/// se sobrescriba.
WeatherGrid grid2x2({
  WeatherModel model = WeatherModel.ecmwf,
  List<Map<String, dynamic>>? wind,
  List<Map<String, dynamic>>? marine,
}) => buildOpenMeteoGrid(
  lat0: 37.0,
  lon0: 24.0,
  step: 0.1,
  nLat: 2,
  nLon: 2,
  windPoints:
      wind ??
      List.generate(
        4,
        (_) => windPoint(t2, {
          'ecmwf_ifs025': ([10, 20], [0, 0]),
        }),
      ),
  marinePoints:
      marine ??
      List.generate(4, (_) => marinePoint(t2, [0.5, 1.0], [90, 90], [4, 6])),
  model: model,
  fetchedAt: DateTime.utc(2026, 9, 18),
);

void main() {
  test('el error 429 de Marine se muestra y no crea olas vacías', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'marine-api.open-meteo.com') {
        return http.Response(
          '{"error":true,"reason":"Daily API request limit exceeded"}',
          429,
        );
      }
      final count = request.url.queryParameters['latitude']!.split(',').length;
      return http.Response(
        jsonEncode(
          List.generate(
            count,
            (_) => windPoint(t2, {
              'ecmwf_ifs025': ([10, 10], [0, 0]),
            }),
          ),
        ),
        200,
      );
    });
    final provider = OpenMeteoWeatherProvider(client: client);
    await expectLater(
      provider.fetchGrid(
        box: const GeoBox(south: 37, west: 24, north: 37.1, east: 24.1),
        from: DateTime.utc(2026, 9, 19, 4),
        to: DateTime.utc(2026, 9, 19, 5),
        model: WeatherModel.ecmwf,
      ),
      throwsA(predicate((e) => '$e'.contains('HTTP 429'))),
    );
  });

  group('WeatherGrid.sample', () {
    test('interpola en el tiempo', () {
      final g = grid2x2();
      final s = g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4, 30))!;
      expect(s.twsKn, closeTo(15, 1e-4));
      expect(s.twdDeg, closeTo(0, 1e-3));
      expect(s.waveHeightM, closeTo(0.75, 1e-4));
      expect(s.waveDirDeg, closeTo(90, 1e-3));
      expect(s.wavePeriodS, closeTo(5, 1e-4));
    });

    test(
      'la dirección se interpola como vector: 350° y 10° dan 0°, no 180°',
      () {
        final wind = [
          windPoint(t2, {
            'ecmwf_ifs025': ([10, 10], [350, 350]),
          }),
          windPoint(t2, {
            'ecmwf_ifs025': ([10, 10], [10, 10]),
          }),
          windPoint(t2, {
            'ecmwf_ifs025': ([10, 10], [350, 350]),
          }),
          windPoint(t2, {
            'ecmwf_ifs025': ([10, 10], [10, 10]),
          }),
        ];
        final g = grid2x2(wind: wind);
        final s = g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4))!;
        final d = s.twdDeg > 180 ? s.twdDeg - 360 : s.twdDeg;
        expect(d, closeTo(0, 1e-3));
        expect(s.twsKn, closeTo(10 * 0.98481, 1e-3)); // cos 10°
      },
    );

    test('fuera de la rejilla o de las horas no hay dato (null), no calma', () {
      final g = grid2x2();
      expect(g.sample(36.9, 24.05, DateTime.utc(2026, 9, 19, 4)), isNull);
      expect(g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 6)), isNull);
      expect(g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 3)), isNull);
    });

    test('olas junto a tierra: se toman de las celdas de mar', () {
      final marine = [
        marinePoint(t2, [1.0, 1.0], [0, 0], [5, 5]),
        marinePoint(t2, [null, null], [null, null], [null, null]), // tierra
        marinePoint(t2, [1.0, 1.0], [0, 0], [5, 5]),
        marinePoint(t2, [null, null], [null, null], [null, null]),
      ];
      final g = grid2x2(marine: marine);
      final s = g.sample(37.05, 24.03, DateTime.utc(2026, 9, 19, 4))!;
      expect(s.waveHeightM, closeTo(1.0, 1e-4));
      // Encima de la celda de tierra: sin dato, no 0 m.
      final land = g.sample(37.05, 24.1, DateTime.utc(2026, 9, 19, 4))!;
      expect(land.waveHeightM, isNull);
      expect(land.twsKn, greaterThan(0));
    });
  });

  group('media de modelos', () {
    test('promedia en componentes y se queda con los que tienen dato', () {
      final wind = List.generate(
        4,
        (_) => windPoint(t2, {
          'gfs_seamless': ([10, 10], [0, 0]),
          'ecmwf_ifs025': ([20, 20], [0, 0]),
          // ICON-EU ya fuera de su horizonte a las 05:00
          'icon_eu': ([30, null], [0, null]),
        }),
      );
      final g = grid2x2(model: WeatherModel.mean, wind: wind);
      expect(
        g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4))!.twsKn,
        closeTo(20, 1e-4),
      );
      expect(
        g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 5))!.twsKn,
        closeTo(15, 1e-4),
      );
    });

    test('un modelo suelto lee las series sin sufijo', () {
      final wind = List.generate(
        4,
        (_) => {
          'hourly': {
            'time': t2,
            'wind_speed_10m': [8, 8],
            'wind_direction_10m': [270, 270],
          },
        },
      );
      final g = grid2x2(model: WeatherModel.gfs, wind: wind);
      final s = g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4))!;
      expect(s.twsKn, closeTo(8, 1e-4));
      expect(s.twdDeg, closeTo(270, 1e-3));
    });
  });

  group('rachas', () {
    test('se leen de Open-Meteo y se promedian entre modelos', () {
      final wind = List.generate(
        4,
        (_) => {
          'hourly': {
            'time': t2,
            'wind_speed_10m_gfs_seamless': [10, 10],
            'wind_direction_10m_gfs_seamless': [0, 0],
            'wind_gusts_10m_gfs_seamless': [16, 18],
            'wind_speed_10m_ecmwf_ifs025': [12, 12],
            'wind_direction_10m_ecmwf_ifs025': [0, 0],
            'wind_gusts_10m_ecmwf_ifs025': [20, 22],
          },
        },
      );
      final g = grid2x2(model: WeatherModel.mean, wind: wind);
      final s = g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4))!;
      expect(s.gustKn, closeTo(18, 1e-4));
    });

    test('sin rachas en la respuesta, la rejilla no las tiene', () {
      final g = grid2x2();
      expect(g.gust, isNull);
      expect(
        g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4))!.gustKn,
        isNull,
      );
    });
  });

  group('rejilla', () {
    test('paso de 0,1° en zonas pequeñas y más grueso hasta 200 M', () {
      const small = GeoBox(south: 37.3, west: 23.9, north: 38.3, east: 25.0);
      expect(gridStepFor(small), 0.1);
      final big = const GeoBox(
        south: 36.0,
        west: 22.5,
        north: 39.3,
        east: 26.7,
      );
      final step = gridStepFor(big);
      final g = gridLayout(big, step);
      expect(g.nLat * g.nLon, lessThanOrEqualTo(kMaxGridPoints));
      expect(g.lat0, lessThanOrEqualTo(big.south));
      expect(g.lat0 + (g.nLat - 1) * step, greaterThanOrEqualTo(big.north));
    });

    test('rechaza respuestas descuadradas', () {
      expect(
        () => grid2x2(
          wind: [
            windPoint(t2, {
              'ecmwf_ifs025': ([1, 1], [0, 0]),
            }),
          ],
        ),
        throwsA(isA<WeatherFetchException>()),
      );
    });
  });

  group('serialización a disco', () {
    test('toJson/fromJson dan la misma rejilla', () {
      final g = grid2x2(model: WeatherModel.mean);
      final round = WeatherGrid.fromJson(g.toJson())!;
      expect(round.lat0, g.lat0);
      expect(round.nLat, g.nLat);
      expect(round.model, g.model);
      final a = g.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4, 30))!;
      final b = round.sample(37.05, 24.05, DateTime.utc(2026, 9, 19, 4, 30))!;
      expect(b.twsKn, closeTo(a.twsKn, 1e-4));
      expect(b.waveHeightM, closeTo(a.waveHeightM!, 1e-4));
    });

    test('un JSON corrupto da null, no una excepción', () {
      expect(WeatherGrid.fromJson({'lat0': 'no es un número'}), isNull);
    });
  });

  group('caché', () {
    test('descarta una rejilla antigua sin ningún dato de ola', () async {
      final bad = grid2x2(
        marine: List.generate(
          4,
          (_) => marinePoint(t2, [null, null], [null, null], [null, null]),
        ),
      );
      expect(bad.hasWaveData, isFalse);
      final inner = _FakeProvider(() => grid2x2());
      final c = CachedWeatherProvider(
        inner,
        now: () => DateTime.utc(2026, 9, 18, 10),
        loadPersisted: (_) async => bad,
      );
      final result = await c.fetchGrid(
        box: const GeoBox(south: 37.02, west: 24.02, north: 37.08, east: 24.08),
        from: DateTime.utc(2026, 9, 19, 4),
        to: DateTime.utc(2026, 9, 19, 5),
        model: WeatherModel.ecmwf,
      );
      expect(inner.calls, 1);
      expect(result.hasWaveData, isTrue);
    });

    test('no vuelve a descargar lo que ya cubre, sí al caducar', () async {
      var now = DateTime.utc(2026, 9, 18, 10);
      final inner = _FakeProvider(() => grid2x2());
      final c = CachedWeatherProvider(inner, now: () => now);
      const box = GeoBox(south: 37.02, west: 24.02, north: 37.08, east: 24.08);
      final from = DateTime.utc(2026, 9, 19, 4);
      final to = DateTime.utc(2026, 9, 19, 5);
      await c.fetchGrid(
        box: box,
        from: from,
        to: to,
        model: WeatherModel.ecmwf,
      );
      await c.fetchGrid(
        box: box,
        from: from,
        to: to,
        model: WeatherModel.ecmwf,
      );
      expect(inner.calls, 1);
      // Otro modelo es otra descarga.
      await c.fetchGrid(box: box, from: from, to: to, model: WeatherModel.gfs);
      expect(inner.calls, 2);
      now = now.add(const Duration(hours: 2));
      await c.fetchGrid(
        box: box,
        from: from,
        to: to,
        model: WeatherModel.ecmwf,
      );
      expect(inner.calls, 3);
    });

    test(
      'con caché en disco, una app recién abierta no vuelve a pedirla',
      () async {
        // Simula el disco con un mapa en memoria — lo que importa es que
        // CachedWeatherProvider lo consulta ANTES de la red, y que guarda
        // ahí lo que sí descarga.
        final disk = <WeatherModel, WeatherGrid>{};
        final inner = _FakeProvider(() => grid2x2());
        final now = DateTime.utc(2026, 9, 18, 10);
        final c1 = CachedWeatherProvider(
          inner,
          now: () => now,
          loadPersisted: (m) async => disk[m],
          savePersisted: (g) => disk[g.model] = g,
        );
        const box = GeoBox(
          south: 37.02,
          west: 24.02,
          north: 37.08,
          east: 24.08,
        );
        final from = DateTime.utc(2026, 9, 19, 4);
        final to = DateTime.utc(2026, 9, 19, 5);
        await c1.fetchGrid(
          box: box,
          from: from,
          to: to,
          model: WeatherModel.ecmwf,
        );
        expect(inner.calls, 1);
        expect(disk[WeatherModel.ecmwf], isNotNull);

        // "Reabrir la app": una caché en memoria nueva, mismo disco.
        final c2 = CachedWeatherProvider(
          inner,
          now: () => now,
          loadPersisted: (m) async => disk[m],
          savePersisted: (g) => disk[g.model] = g,
        );
        await c2.fetchGrid(
          box: box,
          from: from,
          to: to,
          model: WeatherModel.ecmwf,
        );
        expect(inner.calls, 1); // sigue en 1: se sirvió del disco
      },
    );
  });

  group('cuota de Open-Meteo y ola de respaldo', () {
    // Responde con viento/ola planos para tantas posiciones como pida.
    MockClient client({
      int marineFailures = 0,
      String marineReason = 'Minutely API request limit exceeded',
      List<String>? log,
    }) {
      var failed = 0;
      return MockClient((request) async {
        final count = request.url.queryParameters['latitude']!
            .split(',')
            .length;
        log?.add('${request.url.host} $count');
        if (request.url.host == 'marine-api.open-meteo.com') {
          if (failed < marineFailures) {
            failed++;
            return http.Response(
              jsonEncode({'error': true, 'reason': marineReason}),
              429,
            );
          }
          return http.Response(
            jsonEncode(
              List.generate(
                count,
                (_) => marinePoint(t2, [0.7, 0.7], [0, 0], [5, 5]),
              ),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode(
            List.generate(
              count,
              (_) => windPoint(t2, {
                'ecmwf_ifs025': ([12, 12], [0, 0]),
              }),
            ),
          ),
          200,
        );
      });
    }

    const box = GeoBox(south: 37, west: 24, north: 38, east: 25);
    final from = DateTime.utc(2026, 9, 19, 4);
    final to = DateTime.utc(2026, 9, 19, 5);

    test('la rejilla va al paso real del modelo: ECMWF 0,25°', () async {
      final log = <String>[];
      final p = OpenMeteoWeatherProvider(client: client(log: log));
      final g = await p.fetchGrid(
        box: box,
        from: from,
        to: to,
        model: WeatherModel.ecmwf,
      );
      expect(g.step, 0.25);
      expect(g.pointCount, 25); // 5 × 5, antes 11 × 11 = 121 a 0,1°
      // Viento primero, ola después.
      expect(log, ['api.open-meteo.com 25', 'marine-api.open-meteo.com 25']);
      expect(p.quota.usedToday, 50);
    });

    test(
      'cuota: espera si el minuto está lleno y avisa antes del día',
      () async {
        var now = DateTime.utc(2026, 9, 19, 12);
        final waits = <Duration>[];
        final q = OpenMeteoQuota(
          now: () => now,
          sleep: (d) async {
            waits.add(d);
            now = now.add(d);
          },
        );
        await q.reserve(400);
        await q.reserve(300); // 700 > 600 en el minuto: espera
        expect(waits, hasLength(1));
        expect(q.usedToday, 700);
        final big = OpenMeteoQuota(now: () => now)
          ..load('[[${now.millisecondsSinceEpoch}, 9900]]');
        expect(
          () => big.reserve(200),
          throwsA(predicate((e) => '$e'.contains('cuota del día'))),
        );
      },
    );

    test('ola cortada por el límite por minuto: reintenta y la trae', () async {
      final p = OpenMeteoWeatherProvider(
        client: client(marineFailures: 1),
        quota: OpenMeteoQuota(sleep: (_) async {}),
      );
      final g = await p.fetchGrid(
        box: box,
        from: from,
        to: to,
        model: WeatherModel.ecmwf,
      );
      expect(g.hasWaveData, isTrue);
    });

    test(
      'sin ola del momento, usa la última guardada (≤ 12 h) y lo dice',
      () async {
        var now = DateTime.utc(2026, 9, 19, 4, 30);
        var failMarine = false;
        final inner = OpenMeteoWeatherProvider(
          now: () => now,
          quota: OpenMeteoQuota(now: () => now, sleep: (_) async {}),
          client: MockClient((request) async {
            final count = request.url.queryParameters['latitude']!
                .split(',')
                .length;
            if (request.url.host == 'marine-api.open-meteo.com') {
              if (failMarine) {
                return http.Response(
                  '{"error":true,"reason":"Daily API request limit exceeded"}',
                  429,
                );
              }
              return http.Response(
                jsonEncode(
                  List.generate(
                    count,
                    (_) => marinePoint(t2, [0.9, 0.9], [45, 45], [6, 6]),
                  ),
                ),
                200,
              );
            }
            return http.Response(
              jsonEncode(
                List.generate(
                  count,
                  (_) => windPoint(t2, {
                    'ecmwf_ifs025': ([12, 12], [0, 0]),
                    'gfs_seamless': ([12, 12], [0, 0]),
                  }),
                ),
              ),
              200,
            );
          }),
        );
        final cache = CachedWeatherProvider(
          inner,
          maxAge: const Duration(hours: 3),
          now: () => now,
        );
        await cache.fetchGrid(
          box: box,
          from: from,
          to: to,
          model: WeatherModel.ecmwf,
        );

        // Otro modelo, ya sin cuota para la ola: toma la ola de antes.
        failMarine = true;
        now = now.add(const Duration(minutes: 20));
        final g = await cache.fetchGrid(
          box: box,
          from: from,
          to: to,
          model: WeatherModel.gfs,
        );
        expect(g.hasWaveData, isTrue);
        expect(g.source, contains('respaldo'));
        final s = g.sample(37.5, 24.5, DateTime.utc(2026, 9, 19, 4))!;
        expect(s.waveHeightM, closeTo(0.9, 1e-3));
        expect(g.wavesFetchedAt.isBefore(g.fetchedAt), isTrue);

        // Con más de 12 h, ya no: error claro.
        now = now.add(const Duration(hours: 13));
        await expectLater(
          cache.fetchGrid(
            box: box,
            from: from,
            to: to,
            model: WeatherModel.iconEu,
          ),
          throwsA(predicate((e) => '$e'.contains('Sin ola guardada'))),
        );
      },
    );
  });

  group('ola del barco (NOAA)', () {
    Map<String, dynamic> boatJson() => {
      'lat0': 36.5,
      'lon0': 23.5,
      'step': 0.25,
      'nLat': 9,
      'nLon': 12,
      'times': [
        DateTime.utc(2026, 9, 19, 3).millisecondsSinceEpoch,
        DateTime.utc(2026, 9, 19, 6).millisecondsSinceEpoch,
      ],
      'height': List.filled(2 * 9 * 12, 0.6),
      'period': List.filled(2 * 9 * 12, 4.0),
      'direction': List.filled(2 * 9 * 12, 20.0),
      'source': 'NOAA GFS-Wave 0,25° · ciclo 20260919 00z',
      'cycle': DateTime.utc(2026, 9, 19).millisecondsSinceEpoch,
      'fetchedAt': DateTime.utc(2026, 9, 19, 4).millisecondsSinceEpoch,
    };

    test('la respuesta del plugin se lee como rejilla de ola', () {
      final g = boatWavesGridFromJson(boatJson());
      expect(g.waveOrigin, WaveOrigin.noaa);
      final s = g.sample(37.0, 24.0, DateTime.utc(2026, 9, 19, 4))!;
      expect(s.waveHeightM, closeTo(0.6, 1e-6));
      expect(s.waveDirDeg, closeTo(20, 1e-3));
      expect(s.wavePeriodS, closeTo(4, 1e-6));
    });

    test(
      'sin ola de Open-Meteo, la toma del barco antes que la guardada',
      () async {
        final inner = OpenMeteoWeatherProvider(
          quota: OpenMeteoQuota(sleep: (_) async {}),
          client: MockClient((request) async {
            final count = request.url.queryParameters['latitude']!
                .split(',')
                .length;
            if (request.url.host == 'marine-api.open-meteo.com') {
              return http.Response(
                '{"error":true,"reason":"Daily API request limit exceeded"}',
                429,
              );
            }
            return http.Response(
              jsonEncode(
                List.generate(
                  count,
                  (_) => windPoint(t2, {
                    'ecmwf_ifs025': ([12, 12], [0, 0]),
                  }),
                ),
              ),
              200,
            );
          }),
        );
        final cache = CachedWeatherProvider(inner)
          ..boatWaves = (box, from, to) async =>
              boatWavesGridFromJson(boatJson());
        final g = await cache.fetchGrid(
          box: const GeoBox(south: 37, west: 24, north: 38, east: 25),
          from: DateTime.utc(2026, 9, 19, 4),
          to: DateTime.utc(2026, 9, 19, 5),
          model: WeatherModel.ecmwf,
        );
        expect(g.waveOrigin, WaveOrigin.noaa);
        expect(g.source, contains('GFS-Wave'));
        expect(
          g.sample(37.5, 24.5, DateTime.utc(2026, 9, 19, 4))!.waveHeightM,
          closeTo(0.6, 1e-3),
        );
      },
    );

    test('con la ola del barco elegida, Open-Meteo solo pide viento', () async {
      final hosts = <String>[];
      final inner = OpenMeteoWeatherProvider(
        quota: OpenMeteoQuota(sleep: (_) async {}),
        client: MockClient((request) async {
          hosts.add(request.url.host);
          final count = request.url.queryParameters['latitude']!
              .split(',')
              .length;
          return http.Response(
            jsonEncode(
              List.generate(
                count,
                (_) => windPoint(t2, {
                  'ecmwf_ifs025': ([12, 12], [0, 0]),
                }),
              ),
            ),
            200,
          );
        }),
      )..fetchWaves = false;
      final cache = CachedWeatherProvider(inner)
        ..waveSource = WaveSource.boat
        ..boatWaves = (box, from, to) async =>
            boatWavesGridFromJson(boatJson());
      final g = await cache.fetchGrid(
        box: const GeoBox(south: 37, west: 24, north: 38, east: 25),
        from: DateTime.utc(2026, 9, 19, 4),
        to: DateTime.utc(2026, 9, 19, 5),
        model: WeatherModel.ecmwf,
      );
      expect(hosts, ['api.open-meteo.com']);
      expect(g.hasWaveData, isTrue);
      expect(inner.quota.usedToday, 25); // solo el viento
    });
  });

  group('modelo GFS barco (NOAA desde el plugin)', () {
    Map<String, dynamic> windJson() => {
      'lat0': 36.5,
      'lon0': 23.5,
      'step': 0.25,
      'nLat': 9,
      'nLon': 12,
      'times': [
        for (var h = 3; h <= 6; h++)
          DateTime.utc(2026, 9, 19, h).millisecondsSinceEpoch,
      ],
      // Viento del N de 10 m/s: sopla hacia el sur (v negativa).
      'u': List.filled(4 * 9 * 12, 0.0),
      'v': List.filled(4 * 9 * 12, -10.0),
      'gust': List.filled(4 * 9 * 12, 14.0),
      'source': 'NOAA GFS 0,25° · ciclo 20260919 00z',
      'cycle': DateTime.utc(2026, 9, 19).millisecondsSinceEpoch,
      'fetchedAt': DateTime.utc(2026, 9, 19, 4).millisecondsSinceEpoch,
    };
    Map<String, dynamic> wavesJson() => {
      'lat0': 36.5,
      'lon0': 23.5,
      'step': 0.25,
      'nLat': 9,
      'nLon': 12,
      'times': [
        DateTime.utc(2026, 9, 19, 3).millisecondsSinceEpoch,
        DateTime.utc(2026, 9, 19, 6).millisecondsSinceEpoch,
      ],
      'height': List.filled(2 * 9 * 12, 0.8),
      'period': List.filled(2 * 9 * 12, 4.5),
      'direction': List.filled(2 * 9 * 12, 5.0),
      'source': 'NOAA GFS-Wave 0,25° · ciclo 20260919 00z',
      'cycle': DateTime.utc(2026, 9, 19).millisecondsSinceEpoch,
    };

    test('m/s a nudos y dirección de donde viene', () {
      final g = boatWindGridFromJson(windJson());
      final s = g.sample(37.0, 24.0, DateTime.utc(2026, 9, 19, 4))!;
      expect(s.twsKn, closeTo(19.44, 0.01));
      expect(s.twdDeg % 360, closeTo(0, 0.01)); // del N
      expect(s.gustKn, closeTo(27.21, 0.01));
    });

    test('viento y ola del barco, sin tocar Open-Meteo', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add('${request.url.host}${request.url.path}');
        if (request.url.path.endsWith('/wind')) {
          return http.Response(jsonEncode(windJson()), 200);
        }
        if (request.url.path.endsWith('/waves')) {
          return http.Response(jsonEncode(wavesJson()), 200);
        }
        return http.Response('no', 500);
      });
      final om = OpenMeteoWeatherProvider(client: client);
      final router = ModelRouterProvider(
        openMeteo: om,
        boat: BoatWeatherProvider(
          endpoint: () => (host: 'barco.local', port: 3000, authBase64: ''),
          client: client,
        ),
      );
      final cache = CachedWeatherProvider(router);
      final g = await cache.fetchGrid(
        box: const GeoBox(south: 37, west: 24, north: 38, east: 25),
        from: DateTime.utc(2026, 9, 19, 4),
        to: DateTime.utc(2026, 9, 19, 5),
        model: WeatherModel.noaa,
      );
      expect(hosts, [
        'barco.local/plugins/rewind-xcover6-panel/wind',
        'barco.local/plugins/rewind-xcover6-panel/waves',
      ]);
      expect(om.quota.usedToday, 0);
      expect(g.model, WeatherModel.noaa);
      expect(g.source, contains('GFS'));
      final s = g.sample(37.5, 24.5, DateTime.utc(2026, 9, 19, 4, 30))!;
      expect(s.twsKn, closeTo(19.44, 0.01));
      expect(s.waveHeightM, closeTo(0.8, 1e-3));
    });

    test('plugin viejo sin NOAA: error claro', () async {
      final boat = BoatWeatherProvider(
        endpoint: () => (host: 'barco.local', port: 3000, authBase64: ''),
        client: MockClient((_) async => http.Response('Cannot GET', 404)),
      );
      await expectLater(
        boat.fetchGrid(
          box: const GeoBox(south: 37, west: 24, north: 38, east: 25),
          from: DateTime.utc(2026, 9, 19, 4),
          to: DateTime.utc(2026, 9, 19, 5),
          model: WeatherModel.noaa,
        ),
        throwsA(predicate((e) => '$e'.contains('actualízalo'))),
      );
    });
  });
}

class _FakeProvider implements WeatherProvider {
  _FakeProvider(this.make);
  final WeatherGrid Function() make;
  int calls = 0;
  @override
  String get name => 'fake';
  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) async {
    calls++;
    final g = make();
    return WeatherGrid(
      lat0: g.lat0,
      lon0: g.lon0,
      step: g.step,
      nLat: g.nLat,
      nLon: g.nLon,
      times: g.times,
      windU: g.windU,
      windV: g.windV,
      waveH: g.waveH,
      waveDirU: g.waveDirU,
      waveDirV: g.waveDirV,
      waveT: g.waveT,
      model: model,
      source: 'fake',
      fetchedAt: DateTime.utc(2026, 9, 18, 10),
    );
  }
}
