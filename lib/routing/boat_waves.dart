// Ola del servidor del barco: NOAA GFS-Wave recortado a la zona, que baja y
// decodifica el plugin REWIND (server/wave_grib.js). Sin cuota por punto
// como Open-Meteo, y una descarga la comparten todos los aparatos del barco.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'open_meteo_weather.dart';
import 'weather.dart';

/// Pide la ola al plugin del barco y la devuelve como una rejilla propia
/// (sin viento: solo se usa su ola, que se pasa a la rejilla del viento).
Future<WeatherGrid> fetchBoatWaves({
  required String host,
  required int port,
  required String authBase64,
  required GeoBox box,
  required DateTime from,
  required DateTime to,
  http.Client? client,
}) async {
  final uri = Uri.http('$host:$port', '/plugins/rewind-xcover6-panel/waves', {
    'south': box.south.toStringAsFixed(3),
    'west': box.west.toStringAsFixed(3),
    'north': box.north.toStringAsFixed(3),
    'east': box.east.toStringAsFixed(3),
    'from': '${from.toUtc().millisecondsSinceEpoch}',
    'to': '${to.toUtc().millisecondsSinceEpoch}',
  });
  final c = client ?? http.Client();
  // La primera descarga de un ciclo nuevo tarda ~20 s (25 pasos a NOAA).
  final res = await c
      .get(
        uri,
        headers: authBase64.isEmpty
            ? {}
            : {'Authorization': 'Basic $authBase64'},
      )
      .timeout(const Duration(seconds: 90));
  if (res.statusCode == 404) {
    throw const BoatWavesException(
      'el plugin del barco no sirve ola (actualízalo a la 1.4.257 o posterior)',
    );
  }
  if (res.statusCode != 200) {
    var reason = 'HTTP ${res.statusCode}';
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] != null) reason = '${body['error']}';
    } catch (_) {}
    throw BoatWavesException(reason);
  }
  return boatWavesGridFromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

/// La respuesta del plugin como [WeatherGrid] de solo ola.
WeatherGrid boatWavesGridFromJson(Map<String, dynamic> j) {
  final nLat = j['nLat'] as int, nLon = j['nLon'] as int;
  final times = [
    for (final t in j['times'] as List)
      DateTime.fromMillisecondsSinceEpoch((t as num).toInt(), isUtc: true),
  ];
  final n = times.length * nLat * nLon;
  Float32List read(String key) {
    final list = j[key] as List;
    final out = Float32List(n)..fillRange(0, n, double.nan);
    for (var k = 0; k < n && k < list.length; k++) {
      final v = list[k];
      if (v is num) out[k] = v.toDouble();
    }
    return out;
  }

  final h = read('height'), per = read('period'), dir = read('direction');
  final du = Float32List(n)..fillRange(0, n, double.nan);
  final dv = Float32List(n)..fillRange(0, n, double.nan);
  for (var k = 0; k < n; k++) {
    if (dir[k].isNaN) continue;
    final uv = unitVector(dir[k]);
    du[k] = uv.u;
    dv[k] = uv.v;
  }
  final fetched = DateTime.fromMillisecondsSinceEpoch(
    ((j['fetchedAt'] as num?) ?? (j['cycle'] as num)).toInt(),
    isUtc: true,
  );
  return WeatherGrid(
    lat0: (j['lat0'] as num).toDouble(),
    lon0: (j['lon0'] as num).toDouble(),
    step: (j['step'] as num).toDouble(),
    nLat: nLat,
    nLon: nLon,
    times: times,
    // Sin viento: la rejilla solo aporta su ola (sample() necesita un
    // viento con dato, así que va a cero, nunca se usa).
    windU: Float32List(n),
    windV: Float32List(n),
    waveH: h,
    waveDirU: du,
    waveDirV: dv,
    waveT: per,
    model: WeatherModel.ecmwf,
    source: '${j['source'] ?? 'NOAA GFS-Wave'}',
    fetchedAt: fetched,
    waveOrigin: WaveOrigin.noaa,
  );
}

class BoatWavesException implements Exception {
  const BoatWavesException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// El viento del plugin (NOAA GFS 0,25°, u/v a 10 m y racha en m/s) como
/// rejilla, con la ola vacía.
WeatherGrid boatWindGridFromJson(Map<String, dynamic> j) {
  const msToKn = 1.9438444924;
  final nLat = j['nLat'] as int, nLon = j['nLon'] as int;
  final times = [
    for (final t in j['times'] as List)
      DateTime.fromMillisecondsSinceEpoch((t as num).toInt(), isUtc: true),
  ];
  final n = times.length * nLat * nLon;
  Float32List read(String key, {double scale = 1}) {
    final list = (j[key] as List?) ?? const [];
    final out = Float32List(n)..fillRange(0, n, double.nan);
    for (var k = 0; k < n && k < list.length; k++) {
      final v = list[k];
      if (v is num) out[k] = v.toDouble() * scale;
    }
    return out;
  }

  Float32List nan() => Float32List(n)..fillRange(0, n, double.nan);
  final fetched = DateTime.fromMillisecondsSinceEpoch(
    ((j['fetchedAt'] as num?) ?? (j['cycle'] as num)).toInt(),
    isUtc: true,
  );
  return WeatherGrid(
    lat0: (j['lat0'] as num).toDouble(),
    lon0: (j['lon0'] as num).toDouble(),
    step: (j['step'] as num).toDouble(),
    nLat: nLat,
    nLon: nLon,
    times: times,
    // UGRD/VGRD: hacia donde sopla (este, norte), como en la rejilla.
    windU: read('u', scale: msToKn),
    windV: read('v', scale: msToKn),
    gust: read('gust', scale: msToKn),
    waveH: nan(),
    waveDirU: nan(),
    waveDirV: nan(),
    waveT: nan(),
    model: WeatherModel.noaa,
    source: '${j['source'] ?? 'NOAA GFS'}',
    fetchedAt: fetched,
    waveOrigin: WaveOrigin.noaa,
  );
}

/// Viento, racha y ola del plugin del barco (NOAA). No gasta cuota de
/// Open-Meteo: la descarga la hace el servidor del barco, una vez para
/// todos sus aparatos.
class BoatWeatherProvider implements WeatherProvider {
  BoatWeatherProvider({required this.endpoint, http.Client? client})
    : _client = client ?? http.Client();

  /// host, puerto y credencial del servidor conectado, leídos al pedir.
  final ({String host, int port, String authBase64}) Function() endpoint;
  final http.Client _client;

  @override
  String get name => 'Servidor del barco (NOAA)';

  Future<Map<String, dynamic>> _get(
    String path,
    GeoBox box,
    DateTime from,
    DateTime to,
  ) async {
    final e = endpoint();
    final uri = Uri.http(
      '${e.host}:${e.port}',
      '/plugins/rewind-xcover6-panel/$path',
      {
        'south': box.south.toStringAsFixed(3),
        'west': box.west.toStringAsFixed(3),
        'north': box.north.toStringAsFixed(3),
        'east': box.east.toStringAsFixed(3),
        'from': '${from.toUtc().millisecondsSinceEpoch}',
        'to': '${to.toUtc().millisecondsSinceEpoch}',
      },
    );
    final res = await _client
        .get(
          uri,
          headers: e.authBase64.isEmpty
              ? {}
              : {'Authorization': 'Basic ${e.authBase64}'},
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 404) {
      throw const BoatWavesException(
        'el plugin del barco no sirve el tiempo de NOAA (actualízalo a la '
        '1.4.257 o posterior)',
      );
    }
    if (res.statusCode != 200) {
      var reason = 'HTTP ${res.statusCode}';
      try {
        final body = jsonDecode(res.body);
        if (body is Map && body['error'] != null) reason = '${body['error']}';
      } catch (_) {}
      throw BoatWavesException('servidor del barco: $reason');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) async {
    // Viento y ola a la vez; el error de la ola se recoge aparte, para que
    // no quede suelto si el viento falla antes.
    final windF = _get('wind', box, from, to);
    final wavesF = _get(
      'waves',
      box,
      from,
      to,
    ).then<Object>((v) => v, onError: (Object e) => e);
    final wind = boatWindGridFromJson(await windF);
    final wavesOrError = await wavesF;
    WeatherGrid waves;
    try {
      if (wavesOrError is! Map<String, dynamic>) throw wavesOrError;
      waves = boatWavesGridFromJson(wavesOrError);
    } catch (e) {
      throw WaveUnavailableException('ola de NOAA: $e', wind);
    }
    final merged = mergeWaves(
      wind,
      waves,
      origin: WaveOrigin.noaa,
      wavesFetchedAt: waves.wavesFetchedAt,
      source: '${wind.source} · ola ${waves.source.replaceFirst('NOAA ', '')}',
    );
    if (!merged.hasWaveData) {
      throw WaveUnavailableException('NOAA no dio ola en esta zona', wind);
    }
    return merged;
  }
}

/// Reparte cada modelo a su proveedor: "GFS barco" al plugin del barco, el
/// resto a Open-Meteo.
class ModelRouterProvider implements WeatherProvider {
  ModelRouterProvider({required this.openMeteo, required this.boat});
  final OpenMeteoWeatherProvider openMeteo;
  final BoatWeatherProvider boat;

  @override
  String get name => 'Open-Meteo / barco';

  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) => (model == WeatherModel.noaa ? boat : openMeteo).fetchGrid(
    box: box,
    from: from,
    to: to,
    model: model,
  );
}
