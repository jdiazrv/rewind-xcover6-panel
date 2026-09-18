// Prueba contra Open-Meteo de verdad. No corre en la batería normal (va a
// la red); se lanza a mano con:
//   LIVE=1 flutter test test/routing_weather_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/routing/open_meteo_weather.dart';
import 'package:rewind_xcover6_panel/routing/weather.dart';

void main() {
  final live = Platform.environment['LIVE'] != null;

  test('rejilla real de Syros a Maratón', () async {
    // Finikas (Syros) y la playa de Maratón, con 15 M de margen.
    final box = GeoBox.around([
      (lat: 37.395, lon: 24.878),
      (lat: 38.139, lon: 24.012),
    ]).expandNm(15);
    final now = DateTime.now().toUtc();
    final p = OpenMeteoWeatherProvider();
    final sw = Stopwatch()..start();
    final g = await p.fetchGrid(
      box: box,
      from: now,
      to: now.add(const Duration(hours: 48)),
      model: WeatherModel.mean,
    );
    // ignore: avoid_print
    print(
      '${g.nLat}×${g.nLon} puntos, paso ${g.step}°, ${g.times.length} h, '
      '${sw.elapsedMilliseconds} ms, ${g.source}',
    );
    final t = now.add(const Duration(hours: 3));
    final sea = g.sample(37.6, 24.5, t); // entre Syros y Kea
    final land = g.sample(38.0, 23.8, t); // Ática, tierra adentro
    // ignore: avoid_print
    print('mar: $sea\ntierra: $land');
    expect(sea, isNotNull);
    expect(sea!.hasWaves, isTrue);
    // OJO: el modelo de oleaje puede dar ola en tierra pegada a la costa
    // (visto: 0,14 m en pleno Ática). Qué es tierra lo decide la máscara de
    // costa, nunca la ausencia de ola.
    expect(land, isNotNull);
  }, skip: live ? false : 'solo con LIVE=1');
}
