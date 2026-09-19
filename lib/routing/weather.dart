// Tiempo para el routing: una rejilla lat/lon × hora descargada UNA vez
// por zona, sobre la que el router interpola en espacio y tiempo sin volver
// a la red. Dart puro (sin Flutter) para poder correr en un isolate y en
// los tests.
//
// El router no sabe de dónde sale el tiempo: todo proveedor (Open-Meteo
// hoy, POSEIDON u otro mañana) entrega una WeatherGrid.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Caja geográfica en grados. No cruza el antimeridiano (el barco navega
/// en el Mediterráneo; si algún día hace falta, se parte en dos).
class GeoBox {
  const GeoBox({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south, west, north, east;

  /// La caja mínima que contiene todos los puntos.
  factory GeoBox.around(Iterable<({double lat, double lon})> points) {
    var s = 90.0, n = -90.0, w = 180.0, e = -180.0;
    for (final p in points) {
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
    }
    return GeoBox(south: s, west: w, north: n, east: e);
  }

  /// Agranda la caja [nm] millas por cada lado.
  GeoBox expandNm(double nm) {
    final dLat = nm / 60;
    final midLat = (south + north) / 2;
    final cosLat = math.cos(midLat * math.pi / 180).abs().clamp(0.2, 1.0);
    final dLon = nm / (60 * cosLat);
    return GeoBox(
      south: (south - dLat).clamp(-89.0, 89.0),
      west: west - dLon,
      north: (north + dLat).clamp(-89.0, 89.0),
      east: east + dLon,
    );
  }

  bool contains(double lat, double lon) =>
      lat >= south && lat <= north && lon >= west && lon <= east;

  bool containsBox(GeoBox o) =>
      o.south >= south && o.north <= north && o.west >= west && o.east <= east;

  @override
  String toString() =>
      'GeoBox(${south.toStringAsFixed(2)},${west.toStringAsFixed(2)} → '
      '${north.toStringAsFixed(2)},${east.toStringAsFixed(2)})';
}

/// Modelo meteorológico. [mean] es la media de los tres, hora a hora, con
/// los que tengan dato (ICON-EU acaba a los ~5 días; a partir de ahí la
/// media es de GFS y ECMWF).
enum WeatherModel {
  gfs('gfs_seamless', 'GFS'),
  ecmwf('ecmwf_ifs025', 'ECMWF'),
  iconEu('icon_eu', 'ICON-EU'),
  mean(null, 'Media');

  const WeatherModel(this.apiName, this.label);

  /// Nombre del modelo en la API de Open-Meteo; null para la media.
  final String? apiName;
  final String label;

  static const singles = [gfs, ecmwf, iconEu];

  static WeatherModel byName(String? name) => WeatherModel.values.firstWhere(
    (m) => m.name == name,
    orElse: () => WeatherModel.ecmwf,
  );
}

/// El tiempo en un punto y una hora. Viento en nudos y dirección DE DONDE
/// VIENE (convención meteorológica y de Signal K). Las olas pueden faltar:
/// el modelo de oleaje no tiene dato en tierra ni pegado a ella, y eso se
/// dice como null, nunca se rellena con un valor inventado.
class WeatherSample {
  const WeatherSample({
    required this.twsKn,
    required this.twdDeg,
    this.waveHeightM,
    this.waveDirDeg,
    this.wavePeriodS,
    this.gustKn,
  });

  final double twsKn;
  final double twdDeg;

  /// Racha máxima (nudos) de la hora; null si el modelo no la da.
  final double? gustKn;
  final double? waveHeightM;
  final double? waveDirDeg;
  final double? wavePeriodS;

  bool get hasWaves => waveHeightM != null;

  @override
  String toString() =>
      'Wx(${twsKn.toStringAsFixed(1)} kn @ ${twdDeg.round()}°, '
      'ola ${waveHeightM?.toStringAsFixed(2) ?? '--'} m '
      '${waveDirDeg?.round() ?? '--'}° ${wavePeriodS?.toStringAsFixed(1) ?? '--'} s)';
}

/// Rejilla regular lat/lon × horas (UTC) con viento y oleaje.
///
/// El viento se guarda en componentes (u, v) y se interpola así, no por
/// velocidad y ángulo: promediar 350° y 10° da 180° si se hace con los
/// ángulos. Lo mismo con la dirección de la ola, como vector unitario.
/// NaN = sin dato.
class WeatherGrid {
  WeatherGrid({
    required this.lat0,
    required this.lon0,
    required this.step,
    required this.nLat,
    required this.nLon,
    required this.times,
    required this.windU,
    required this.windV,
    required this.waveH,
    required this.waveDirU,
    required this.waveDirV,
    required this.waveT,
    required this.model,
    required this.source,
    required this.fetchedAt,
    this.gust,
  }) : assert(times.isNotEmpty),
       assert(windU.length == times.length * nLat * nLon);

  /// Esquina SW y paso (grados) de la rejilla.
  final double lat0, lon0, step;
  final int nLat, nLon;

  /// Horas de la rejilla, UTC, crecientes y equiespaciadas.
  final List<DateTime> times;

  /// Viento: vector hacia donde SOPLA, en nudos (u = este, v = norte).
  final Float32List windU, windV;

  /// Ola: altura significativa (m), dirección DE DONDE VIENE como vector
  /// unitario, y periodo (s).
  final Float32List waveH, waveDirU, waveDirV, waveT;

  /// Racha (nudos). Opcional: las rejillas guardadas antes de pedirla no
  /// la tienen.
  final Float32List? gust;

  final WeatherModel model;

  /// De dónde salen los datos, para enseñarlo en pantalla.
  final String source;
  final DateTime fetchedAt;

  double get lat1 => lat0 + (nLat - 1) * step;
  double get lon1 => lon0 + (nLon - 1) * step;
  DateTime get start => times.first;
  DateTime get end => times.last;
  GeoBox get box => GeoBox(south: lat0, west: lon0, north: lat1, east: lon1);

  int get pointCount => nLat * nLon;

  int _idx(int t, int i, int j) => (t * nLat + i) * nLon + j;

  /// A disco: se guarda la última rejilla de cada modelo para no tener
  /// que volver a pedirla si se cierra la app y se abre otra vez — es lo
  /// que de verdad gasta la cuota gratuita de Open-Meteo, no navegar
  /// dentro de la misma sesión (eso ya lo cubre [CachedWeatherProvider]
  /// en memoria). Los arrays van en base64, no como listas de JSON: para
  /// una rejilla de 600 puntos × 60 h eso sería varios megas de texto en
  /// vez de unos cientos de KB.
  Map<String, dynamic> toJson() => {
    'lat0': lat0,
    'lon0': lon0,
    'step': step,
    'nLat': nLat,
    'nLon': nLon,
    'times': [for (final t in times) t.toUtc().millisecondsSinceEpoch],
    'windU': base64Encode(windU.buffer.asUint8List()),
    'windV': base64Encode(windV.buffer.asUint8List()),
    'waveH': base64Encode(waveH.buffer.asUint8List()),
    'waveDirU': base64Encode(waveDirU.buffer.asUint8List()),
    'waveDirV': base64Encode(waveDirV.buffer.asUint8List()),
    'waveT': base64Encode(waveT.buffer.asUint8List()),
    if (gust != null) 'gust': base64Encode(gust!.buffer.asUint8List()),
    'model': model.name,
    'source': source,
    'fetchedAt': fetchedAt.toUtc().millisecondsSinceEpoch,
  };

  static WeatherGrid? fromJson(Map<String, dynamic> j) {
    try {
      Float32List f32(String key) =>
          base64Decode(j[key] as String).buffer.asFloat32List();
      return WeatherGrid(
        lat0: (j['lat0'] as num).toDouble(),
        lon0: (j['lon0'] as num).toDouble(),
        step: (j['step'] as num).toDouble(),
        nLat: j['nLat'] as int,
        nLon: j['nLon'] as int,
        times: [
          for (final t in (j['times'] as List))
            DateTime.fromMillisecondsSinceEpoch(
              (t as num).toInt(),
              isUtc: true,
            ),
        ],
        windU: f32('windU'),
        windV: f32('windV'),
        waveH: f32('waveH'),
        waveDirU: f32('waveDirU'),
        waveDirV: f32('waveDirV'),
        waveT: f32('waveT'),
        gust: j['gust'] is String ? f32('gust') : null,
        model: WeatherModel.byName(j['model'] as String?),
        source: j['source'] as String,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['fetchedAt'] as num).toInt(),
          isUtc: true,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  bool covers(GeoBox b, DateTime from, DateTime to) =>
      box.containsBox(b) && !from.isBefore(start) && !to.isAfter(end);

  double latAt(int i) => lat0 + i * step;
  double lonAt(int j) => lon0 + j * step;

  /// El tiempo interpolado en (lat, lon, hora). null fuera de la rejilla o
  /// fuera del intervalo de horas, o si el viento no tiene dato: el router
  /// debe tratarlo como "no se sabe", no como calma.
  WeatherSample? sample(double lat, double lon, DateTime time) {
    // Tolerancia para los bordes: (24.1 − 24.0) / 0.1 no da 1 exacto.
    const eps = 1e-6;
    var fi = (lat - lat0) / step;
    var fj = (lon - lon0) / step;
    if (fi < -eps || fj < -eps || fi > nLat - 1 + eps || fj > nLon - 1 + eps) {
      return null;
    }
    fi = fi.clamp(0.0, nLat - 1.0);
    fj = fj.clamp(0.0, nLon - 1.0);
    final ms = time.toUtc().millisecondsSinceEpoch;
    final t0ms = start.millisecondsSinceEpoch;
    final t1ms = end.millisecondsSinceEpoch;
    if (ms < t0ms || ms > t1ms) return null;
    final ft = times.length == 1
        ? 0.0
        : (ms - t0ms) / (t1ms - t0ms) * (times.length - 1);

    final i0 = math.min(fi.floor(), nLat - 2).clamp(0, nLat - 1);
    final j0 = math.min(fj.floor(), nLon - 2).clamp(0, nLon - 1);
    final k0 = math
        .min(ft.floor(), times.length - 2)
        .clamp(0, times.length - 1);
    final i1 = math.min(i0 + 1, nLat - 1);
    final j1 = math.min(j0 + 1, nLon - 1);
    final k1 = math.min(k0 + 1, times.length - 1);
    final di = fi - i0, dj = fj - j0, dk = ft - k0;

    // Los 8 vecinos (2 en lat × 2 en lon × 2 en tiempo) y su peso.
    final idx = <int>[];
    final w = <double>[];
    for (final (k, wk) in [(k0, 1 - dk), (k1, dk)]) {
      for (final (i, wi) in [(i0, 1 - di), (i1, di)]) {
        for (final (j, wj) in [(j0, 1 - dj), (j1, dj)]) {
          idx.add(_idx(k, i, j));
          w.add(wk * wi * wj);
        }
      }
    }

    final u = _weighted(windU, idx, w);
    final v = _weighted(windV, idx, w);
    if (u == null || v == null) return null;
    final tws = math.sqrt(u * u + v * v);
    // (u, v) apunta hacia donde sopla; el viento VIENE del lado contrario.
    final twd = _bearingOf(-u, -v);
    final g = gust == null ? null : _weighted(gust!, idx, w);

    final h = _weighted(waveH, idx, w);
    double? wDir;
    double? wPer;
    if (h != null) {
      final du = _weighted(waveDirU, idx, w);
      final dv = _weighted(waveDirV, idx, w);
      if (du != null && dv != null && (du != 0 || dv != 0)) {
        wDir = _bearingOf(du, dv);
      }
      wPer = _weighted(waveT, idx, w);
    }
    return WeatherSample(
      twsKn: tws,
      twdDeg: twd,
      waveHeightM: h,
      waveDirDeg: wDir,
      wavePeriodS: wPer,
      // La racha nunca por debajo del viento medio interpolado.
      gustKn: g == null ? null : math.max(g, tws),
    );
  }

  /// Nombre del contrato del encargo: getWeather(lat, lon, timestamp).
  WeatherSample? getWeather(double lat, double lon, DateTime timestamp) =>
      sample(lat, lon, timestamp);

  /// Media ponderada ignorando los NaN y renormalizando el peso de los que
  /// quedan: pegado a la costa, las celdas de tierra del modelo de oleaje no
  /// tienen dato y la ola se toma de las de mar. Si el peso útil es casi
  /// nulo (el punto cae prácticamente en una celda sin dato) → null.
  static double? _weighted(Float32List a, List<int> idx, List<double> w) {
    var sum = 0.0, wsum = 0.0, wAll = 0.0;
    for (var n = 0; n < idx.length; n++) {
      if (w[n] <= 0) continue;
      wAll += w[n];
      final x = a[idx[n]];
      if (x.isNaN) continue;
      sum += x * w[n];
      wsum += w[n];
    }
    if (wsum <= 0) return null;
    if (wAll > 0 && wsum / wAll < 0.25) return null;
    return sum / wsum;
  }
}

/// Rumbo (0 = N, 90 = E) del vector (este, norte).
double _bearingOf(double east, double north) {
  final deg = math.atan2(east, north) * 180 / math.pi;
  return (deg + 360) % 360;
}

/// Componentes (u, v) del viento hacia donde sopla, a partir de velocidad y
/// dirección DE DONDE VIENE.
({double u, double v}) windComponents(double speed, double fromDeg) {
  final r = fromDeg * math.pi / 180;
  return (u: -speed * math.sin(r), v: -speed * math.cos(r));
}

/// Vector unitario de una dirección (0 = N).
({double u, double v}) unitVector(double deg) {
  final r = deg * math.pi / 180;
  return (u: math.sin(r), v: math.cos(r));
}

/// Quien da tiempo al router. Una sola descarga por zona y hora: el router
/// nunca llama a la red por nodo.
abstract class WeatherProvider {
  String get name;

  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  });
}

/// Caché en memoria de rejillas ya descargadas, delante de cualquier
/// proveedor. Sirve una rejilla guardada si cubre la zona y las horas
/// pedidas y no ha caducado (los modelos se refrescan cada pocas horas;
/// una hora de vida no pierde ninguna pasada útil).
class CachedWeatherProvider implements WeatherProvider {
  CachedWeatherProvider(
    this.inner, {
    this.maxAge = const Duration(hours: 1),
    DateTime Function()? now,
    this.loadPersisted,
    this.savePersisted,
  }) : _now = now ?? DateTime.now;

  final WeatherProvider inner;
  final Duration maxAge;
  final DateTime Function() _now;
  final List<WeatherGrid> _grids = [];

  /// Debajo de la caché en memoria (dura lo que dura esta sesión de la
  /// app): un disco que sobrevive a cerrarla del todo. Inyectado desde
  /// fuera porque leer/escribir a disco necesita Flutter (este fichero
  /// no) — ver `WeatherDiskCache`.
  final Future<WeatherGrid?> Function(WeatherModel model)? loadPersisted;
  final void Function(WeatherGrid grid)? savePersisted;

  @override
  String get name => inner.name;

  /// Descargas reales hechas (para DEBUG y tests).
  int downloads = 0;

  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) async {
    final now = _now();
    _grids.removeWhere((g) => now.difference(g.fetchedAt) > maxAge);
    for (final g in _grids) {
      if (g.model == model && g.covers(box, from, to)) return g;
    }
    if (loadPersisted != null) {
      final disk = await loadPersisted!(model);
      if (disk != null &&
          now.difference(disk.fetchedAt) <= maxAge &&
          disk.covers(box, from, to)) {
        _grids.add(disk);
        return disk;
      }
    }
    final g = await inner.fetchGrid(box: box, from: from, to: to, model: model);
    downloads++;
    _grids.add(g);
    // Solo unas pocas: cada una son cientos de KB.
    while (_grids.length > 6) {
      _grids.removeAt(0);
    }
    savePersisted?.call(g);
    return g;
  }

  void clear() => _grids.clear();
}
