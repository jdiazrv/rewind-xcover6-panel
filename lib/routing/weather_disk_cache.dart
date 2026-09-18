// Guarda la última rejilla de cada modelo en SharedPreferences, para que
// cerrar la app del todo (no solo la pantalla RUTA) no obligue a volver a
// pedirla a Open-Meteo. La caché en memoria de CachedWeatherProvider ya
// evita las peticiones repetidas DENTRO de una sesión; esto cubre entre
// sesiones, que es lo que de verdad puede agotar la cuota gratuita si se
// abre y cierra la app muchas veces seguidas. Reportado en vivo 2026-09-18.
//
// Aparte de weather.dart (que no depende de Flutter) porque leer/escribir
// SharedPreferences sí lo necesita.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'weather.dart';

class WeatherDiskCache {
  const WeatherDiskCache();

  static const _prefix = 'routing.weatherGrid.';

  Future<WeatherGrid?> load(WeatherModel model) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('$_prefix${model.name}');
      if (raw == null) return null;
      return WeatherGrid.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(WeatherGrid grid) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_prefix${grid.model.name}', jsonEncode(grid.toJson()));
    } catch (_) {
      /* sin sitio en disco, se sigue igual solo sin persistir */
    }
  }
}
