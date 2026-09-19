// Proveedor de tiempo para el routing: Open-Meteo, en rejilla.
//
// Una petición de Open-Meteo admite muchas posiciones separadas por comas,
// así que la rejilla entera de la zona baja en 1–2 peticiones de ~1 s
// (medido: 400 puntos × 72 h, viento de 3 modelos 1,5 s; oleaje 1,0 s).
// Viento de api.open-meteo.com (GFS, ECMWF IFS 0,25°, ICON-EU), oleaje de
// marine-api.open-meteo.com (que da null en tierra: se guarda como "sin
// dato", no como mar en calma).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'weather.dart';

/// Tope de puntos de una rejilla. Open-Meteo es gratuito con un uso
/// razonable y cada posición cuenta; con 200 M de ruta como máximo, 600
/// puntos dan un paso de ~0,15°, del orden de la resolución de ECMWF
/// (0,25°) y GFS (0,25°). Por debajo de ese tamaño el paso es 0,1°.
const kMaxGridPoints = 600;
const kMinGridStep = 0.1;

/// Posiciones por petición: mantiene la URL en ~3 KB.
const _kPointsPerRequest = 300;

/// Paso de rejilla para cubrir [box] sin pasar de [maxPoints].
double gridStepFor(GeoBox box, {int maxPoints = kMaxGridPoints}) {
  var step = kMinGridStep;
  while (true) {
    final nLat = ((box.north - box.south) / step).ceil() + 1;
    final nLon = ((box.east - box.west) / step).ceil() + 1;
    if (nLat * nLon <= maxPoints || step >= 1.0) return step;
    step = ((step + 0.05) * 100).round() / 100;
  }
}

/// Geometría de la rejilla: esquina SW ajustada al paso, para que dos
/// descargas de la misma zona den los mismos puntos.
({double lat0, double lon0, int nLat, int nLon}) gridLayout(
  GeoBox box,
  double step,
) {
  final lat0 = (box.south / step).floorToDouble() * step;
  final lon0 = (box.west / step).floorToDouble() * step;
  final nLat = math.max(2, ((box.north - lat0) / step).ceil() + 1);
  final nLon = math.max(2, ((box.east - lon0) / step).ceil() + 1);
  return (lat0: lat0, lon0: lon0, nLat: nLat, nLon: nLon);
}

String _hourParam(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:00';
}

DateTime _floorHour(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day, u.hour);
}

DateTime _ceilHour(DateTime t) {
  final f = _floorHour(t);
  return f.isBefore(t.toUtc()) ? f.add(const Duration(hours: 1)) : f;
}

class OpenMeteoWeatherProvider implements WeatherProvider {
  OpenMeteoWeatherProvider({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now;

  final http.Client _client;
  final DateTime Function() _now;

  @override
  String get name => 'Open-Meteo';

  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) async {
    final step = gridStepFor(box);
    final g = gridLayout(box, step);
    final lats = <double>[];
    final lons = <double>[];
    for (var i = 0; i < g.nLat; i++) {
      for (var j = 0; j < g.nLon; j++) {
        lats.add(g.lat0 + i * step);
        lons.add(g.lon0 + j * step);
      }
    }
    final start = _floorHour(from);
    final end = _ceilHour(to);
    final models = model == WeatherModel.mean ? WeatherModel.singles : [model];

    final wind = <Map<String, dynamic>>[];
    final marine = <Map<String, dynamic>>[];
    for (var off = 0; off < lats.length; off += _kPointsPerRequest) {
      final end0 = math.min(off + _kPointsPerRequest, lats.length);
      final la = lats.sublist(off, end0);
      final lo = lons.sublist(off, end0);
      final results = await Future.wait([
        _get(
          Uri.https('api.open-meteo.com', '/v1/forecast', {
            ..._positionParams(la, lo),
            'hourly': 'wind_speed_10m,wind_direction_10m,wind_gusts_10m',
            'wind_speed_unit': 'kn',
            'models': models.map((m) => m.apiName).join(','),
            'timezone': 'GMT',
            'start_hour': _hourParam(start),
            'end_hour': _hourParam(end),
          }),
        ),
        _get(
          Uri.https('marine-api.open-meteo.com', '/v1/marine', {
            ..._positionParams(la, lo),
            'hourly': 'wave_height,wave_direction,wave_period',
            'timezone': 'GMT',
            'start_hour': _hourParam(start),
            'end_hour': _hourParam(end),
          }),
          optional: true,
        ),
      ]);
      wind.addAll(results[0]!);
      final m = results[1];
      if (m == null) {
        // Sin oleaje en este trozo: se rellena de "sin dato" posición a
        // posición, para no descuadrar la rejilla.
        marine.addAll(List.filled(la.length, const <String, dynamic>{}));
      } else {
        marine.addAll(m);
      }
    }

    return buildOpenMeteoGrid(
      lat0: g.lat0,
      lon0: g.lon0,
      step: step,
      nLat: g.nLat,
      nLon: g.nLon,
      windPoints: wind,
      marinePoints: marine,
      model: model,
      fetchedAt: _now(),
    );
  }

  Map<String, String> _positionParams(List<double> la, List<double> lo) => {
    'latitude': la.map((x) => x.toStringAsFixed(3)).join(','),
    'longitude': lo.map((x) => x.toStringAsFixed(3)).join(','),
  };

  /// Descarga y devuelve la lista de posiciones (Open-Meteo devuelve un
  /// objeto suelto si solo hay una). Con [optional], un fallo da null en
  /// vez de excepción: sin oleaje se puede seguir; sin viento no.
  Future<List<Map<String, dynamic>>?> _get(
    Uri uri, {
    bool optional = false,
  }) async {
    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        var reason = 'HTTP ${res.statusCode}';
        try {
          final body = jsonDecode(res.body);
          if (body is Map && body['reason'] != null) {
            reason = '${body['reason']}';
          }
        } catch (_) {}
        throw WeatherFetchException('${uri.host}: $reason');
      }
      final body = jsonDecode(res.body);
      if (body is List) return body.cast<Map<String, dynamic>>();
      if (body is Map<String, dynamic>) return [body];
      throw WeatherFetchException('${uri.host}: respuesta inesperada');
    } catch (e) {
      if (optional) return null;
      if (e is WeatherFetchException) rethrow;
      throw WeatherFetchException('${uri.host}: $e');
    }
  }
}

class WeatherFetchException implements Exception {
  WeatherFetchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Monta la rejilla a partir de las respuestas de Open-Meteo, en el mismo
/// orden en que se pidieron las posiciones (fila a fila, de S a N y de W
/// a E). Separado de la descarga para poder probarlo sin red.
///
/// Con [WeatherModel.mean] promedia el viento de los modelos que tengan
/// dato en esa hora y posición, en componentes (u, v).
WeatherGrid buildOpenMeteoGrid({
  required double lat0,
  required double lon0,
  required double step,
  required int nLat,
  required int nLon,
  required List<Map<String, dynamic>> windPoints,
  required List<Map<String, dynamic>> marinePoints,
  required WeatherModel model,
  required DateTime fetchedAt,
}) {
  final n = nLat * nLon;
  if (windPoints.length != n) {
    throw WeatherFetchException(
      'Open-Meteo devolvió ${windPoints.length} posiciones de $n',
    );
  }
  final hourly0 = windPoints.first['hourly'] as Map<String, dynamic>?;
  final timeStr = (hourly0?['time'] as List?)?.cast<String>() ?? const [];
  if (timeStr.isEmpty) throw WeatherFetchException('Open-Meteo sin horas');
  final times = [for (final s in timeStr) DateTime.parse('${s}Z')];
  final nt = times.length;

  final models = model == WeatherModel.mean ? WeatherModel.singles : [model];
  Float32List nan() => Float32List(nt * n)..fillRange(0, nt * n, double.nan);
  final u = nan(), v = nan();
  final h = nan(), du = nan(), dv = nan(), per = nan();
  final gu = nan();
  var anyGust = false;

  List? series(Map<String, dynamic>? hourly, String name, WeatherModel m) =>
      hourly == null
      ? null
      : (hourly['${name}_${m.apiName}'] ?? hourly[name]) as List?;

  for (var p = 0; p < n; p++) {
    final hourly = windPoints[p]['hourly'] as Map<String, dynamic>?;
    final perModel = [
      for (final m in models)
        (
          spd: series(hourly, 'wind_speed_10m', m),
          dir: series(hourly, 'wind_direction_10m', m),
          gust: series(hourly, 'wind_gusts_10m', m),
        ),
    ];
    final mh = marinePoints.length > p
        ? marinePoints[p]['hourly'] as Map<String, dynamic>?
        : null;
    final wh = mh?['wave_height'] as List?;
    final wd = mh?['wave_direction'] as List?;
    final wp = mh?['wave_period'] as List?;
    final mTimes = (mh?['time'] as List?)?.cast<String>();

    for (var t = 0; t < nt; t++) {
      final k = t * n + p;
      var su = 0.0, sv = 0.0, cnt = 0;
      var sg = 0.0, gcnt = 0;
      for (final s in perModel) {
        final spd = _num(s.spd, t);
        final dir = _num(s.dir, t);
        if (spd == null || dir == null) continue;
        final gg = _num(s.gust, t);
        if (gg != null) {
          sg += gg;
          gcnt++;
        }
        final c = windComponents(spd, dir);
        su += c.u;
        sv += c.v;
        cnt++;
      }
      if (cnt > 0) {
        u[k] = su / cnt;
        v[k] = sv / cnt;
      }
      if (gcnt > 0) {
        gu[k] = sg / gcnt;
        anyGust = true;
      }
      // Oleaje: su propia lista de horas; normalmente la misma.
      final mt = mTimes == null
          ? t
          : (mTimes.length > t && mTimes[t] == timeStr[t]
                ? t
                : mTimes.indexOf(timeStr[t]));
      if (mt < 0) continue;
      final hh = _num(wh, mt);
      if (hh == null) continue;
      h[k] = hh;
      final dd = _num(wd, mt);
      if (dd != null) {
        final uv = unitVector(dd);
        du[k] = uv.u;
        dv[k] = uv.v;
      }
      final pp = _num(wp, mt);
      if (pp != null) per[k] = pp;
    }
  }

  return WeatherGrid(
    lat0: lat0,
    lon0: lon0,
    step: step,
    nLat: nLat,
    nLon: nLon,
    times: times,
    windU: u,
    windV: v,
    waveH: h,
    waveDirU: du,
    waveDirV: dv,
    waveT: per,
    gust: anyGust ? gu : null,
    model: model,
    source: model == WeatherModel.mean
        ? 'Open-Meteo · media GFS/ECMWF/ICON-EU'
        : 'Open-Meteo · ${model.label}',
    fetchedAt: fetchedAt,
  );
}

double? _num(List? l, int i) {
  if (l == null || i < 0 || i >= l.length) return null;
  final x = l[i];
  return x is num ? x.toDouble() : null;
}
