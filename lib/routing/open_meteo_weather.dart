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

/// Paso de rejilla para cubrir [box] sin pasar de [maxPoints], nunca más
/// fino que [minStep] (la resolución real del modelo).
double gridStepFor(
  GeoBox box, {
  int maxPoints = kMaxGridPoints,
  double minStep = kMinGridStep,
}) {
  var step = math.max(kMinGridStep, minStep);
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

/// Límites del plan gratuito de Open-Meteo (open-meteo.com/en/pricing).
/// Cada POSICIÓN de una petición cuenta como una llamada: peso =
/// posiciones × días/14 × variables/10, con 1 como mínimo por posición.
/// Una rejilla de 600 puntos (viento + ola) eran 1200 llamadas: por encima
/// del límite por minuto (la ola, que va después, recibía HTTP 429 y se
/// quedaba sin datos) y 8 descargas agotaban el día.
const kOpenMeteoPerMinute = 600;
const kOpenMeteoPerHour = 5000;
const kOpenMeteoPerDay = 10000;

/// Lo gastado de la cuota de Open-Meteo, por minuto, hora y día (ventanas
/// móviles), para no pasarse: se espera si el minuto está lleno, y se
/// avisa ANTES de gastar si no queda para la hora o el día. Se guarda
/// entre sesiones con [load]/[save] (inyectados: aquí no hay Flutter).
class OpenMeteoQuota {
  OpenMeteoQuota({
    DateTime Function()? now,
    this.save,
    Future<void> Function(Duration)? sleep,
  }) : _now = now ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;
  final void Function(String json)? save;

  /// (ms, peso) de cada petición de las últimas 24 h.
  final List<(int, double)> _log = [];

  void load(String? json) {
    if (json == null) return;
    try {
      final list = jsonDecode(json) as List;
      _log
        ..clear()
        ..addAll([
          for (final e in list)
            ((e[0] as num).toInt(), (e[1] as num).toDouble()),
        ]);
      _trim();
    } catch (_) {}
  }

  void _trim() {
    final cutoff = _now().millisecondsSinceEpoch - 24 * 3600 * 1000;
    _log.removeWhere((e) => e.$1 < cutoff);
  }

  double _usedSince(Duration d) {
    final from = _now().millisecondsSinceEpoch - d.inMilliseconds;
    var sum = 0.0;
    for (final e in _log) {
      if (e.$1 >= from) sum += e.$2;
    }
    return sum;
  }

  double get usedLastMinute => _usedSince(const Duration(minutes: 1));
  double get usedLastHour => _usedSince(const Duration(hours: 1));
  double get usedToday {
    _trim();
    return _usedSince(const Duration(hours: 24));
  }

  /// Aparta [weight] llamadas: espera lo necesario si el minuto está
  /// lleno; lanza [WeatherFetchException] si no queda para la hora o el
  /// día (mejor decirlo antes que gastar y recibir un 429).
  Future<void> reserve(double weight) async {
    _trim();
    if (usedToday + weight > kOpenMeteoPerDay) {
      throw WeatherFetchException(
        'Open-Meteo: esta descarga (${weight.round()} llamadas) pasaría la '
        'cuota del día (${usedToday.round()} de $kOpenMeteoPerDay usadas en '
        '24 h). Acorta la ruta o espera.',
      );
    }
    if (usedLastHour + weight > kOpenMeteoPerHour) {
      throw WeatherFetchException(
        'Open-Meteo: esta descarga pasaría la cuota de la hora '
        '(${usedLastHour.round()} de $kOpenMeteoPerHour). Espera un rato.',
      );
    }
    // Minuto: hasta 3 esperas de lo que falte para liberar sitio.
    for (
      var i = 0;
      i < 3 && usedLastMinute + weight > kOpenMeteoPerMinute;
      i++
    ) {
      final nowMs = _now().millisecondsSinceEpoch;
      final inWindow = _log.where((e) => e.$1 >= nowMs - 60000).toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
      final oldest = inWindow.isEmpty ? nowMs : inWindow.first.$1;
      await _sleep(Duration(milliseconds: oldest + 60000 - nowMs + 500));
    }
    _log.add((_now().millisecondsSinceEpoch, weight));
    save?.call(
      jsonEncode([
        for (final e in _log) [e.$1, e.$2],
      ]),
    );
  }
}

class OpenMeteoWeatherProvider implements WeatherProvider {
  OpenMeteoWeatherProvider({
    http.Client? client,
    DateTime Function()? now,
    OpenMeteoQuota? quota,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now,
       quota = quota ?? OpenMeteoQuota(now: now);

  final http.Client _client;
  final DateTime Function() _now;
  final OpenMeteoQuota quota;

  /// false con la ola del barco elegida: se pide solo el viento (la mitad
  /// de cuota) y la ola la pone [CachedWeatherProvider] desde el barco.
  bool fetchWaves = true;

  @override
  String get name => 'Open-Meteo';

  /// Peso de una petición según la fórmula de Open-Meteo.
  static double requestWeight({
    required int locations,
    required int variables,
    required Duration span,
  }) {
    final days = span.inHours / 24;
    return locations * math.max(1.0, days / 14) * math.max(1.0, variables / 10);
  }

  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) async {
    final step = gridStepFor(box, minStep: model.gridStepDeg);
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
    final span = end.difference(start);
    final models = model == WeatherModel.mean ? WeatherModel.singles : [model];

    // Primero el viento, entero; la ola después. Por separado y en serie
    // (antes iban en paralelo): así la cuota por minuto se puede respetar
    // esperando, y un fallo de la ola no se lleva el viento por delante.
    final wind = <Map<String, dynamic>>[];
    for (var off = 0; off < lats.length; off += _kPointsPerRequest) {
      final end0 = math.min(off + _kPointsPerRequest, lats.length);
      final la = lats.sublist(off, end0), lo = lons.sublist(off, end0);
      await quota.reserve(
        requestWeight(
          locations: la.length,
          variables: 3 * models.length,
          span: span,
        ),
      );
      wind.addAll(
        await _get(
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
      );
    }

    final marine = <Map<String, dynamic>>[];
    WeatherFetchException? waveError;
    if (!fetchWaves) {
      waveError = WeatherFetchException('ola elegida del barco');
    } else {
      try {
        for (var off = 0; off < lats.length; off += _kPointsPerRequest) {
          final end0 = math.min(off + _kPointsPerRequest, lats.length);
          final la = lats.sublist(off, end0), lo = lons.sublist(off, end0);
          final uri = Uri.https('marine-api.open-meteo.com', '/v1/marine', {
            ..._positionParams(la, lo),
            'hourly': 'wave_height,wave_direction,wave_period',
            'timezone': 'GMT',
            'start_hour': _hourParam(start),
            'end_hour': _hourParam(end),
          });
          final weight = requestWeight(
            locations: la.length,
            variables: 3,
            span: span,
          );
          await quota.reserve(weight);
          List<Map<String, dynamic>> m;
          try {
            m = await _get(uri);
          } on WeatherFetchException catch (e) {
            // Límite por MINUTO: basta esperar uno y reintentar una vez.
            if (!e.message.toLowerCase().contains('minut')) rethrow;
            await quota.reserve(weight);
            m = await _get(uri);
          }
          if (m.length != la.length) {
            throw WeatherFetchException(
              'Open-Meteo Marine devolvió ${m.length} posiciones de ${la.length}',
            );
          }
          marine.addAll(m);
        }
      } on WeatherFetchException catch (e) {
        waveError = e;
      }
    }

    final grid = buildOpenMeteoGrid(
      lat0: g.lat0,
      lon0: g.lon0,
      step: step,
      nLat: g.nLat,
      nLon: g.nLon,
      windPoints: wind,
      marinePoints: waveError == null
          ? marine
          : List.filled(lats.length, const <String, dynamic>{}),
      model: model,
      fetchedAt: _now(),
    );
    if (waveError != null) {
      throw WaveUnavailableException(waveError.message, grid);
    }
    if (!grid.hasWaveData) {
      throw WaveUnavailableException(
        'Open-Meteo Marine no devolvió datos de ola en esta zona y periodo',
        grid,
      );
    }
    return grid;
  }

  Map<String, String> _positionParams(List<double> la, List<double> lo) => {
    'latitude': la.map((x) => x.toStringAsFixed(3)).join(','),
    'longitude': lo.map((x) => x.toStringAsFixed(3)).join(','),
  };

  /// Descarga y devuelve la lista de posiciones (Open-Meteo devuelve un
  /// objeto suelto si solo hay una). Un error marino debe llegar a la UI:
  /// ocultarlo genera una rejilla que parece válida pero no tiene olas.
  Future<List<Map<String, dynamic>>> _get(Uri uri) async {
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
        if (res.statusCode == 429) {
          throw WeatherFetchException(
            '${uri.host}: cuota de consultas agotada (HTTP 429: $reason).',
          );
        }
        throw WeatherFetchException('${uri.host}: $reason');
      }
      final body = jsonDecode(res.body);
      if (body is List) return body.cast<Map<String, dynamic>>();
      if (body is Map<String, dynamic>) return [body];
      throw WeatherFetchException('${uri.host}: respuesta inesperada');
    } catch (e) {
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
