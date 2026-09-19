// Máscara de costa para el routing: polígonos de tierra reales (Natural
// Earth, dominio público, 1:50 M), recortados al Mediterráneo y el mar
// Negro y simplificados (assets/land/land_med.json, ~50 KB, 74 polígonos).
// No sustituye a una carta náutica: sirve para que el motor no trace
// rutas que crucen tierra, no para navegar pegado a la costa.
//
// Dart puro, sin Flutter: se lee una vez y se pasa al isolate del motor
// como datos planos (List<LandPolygon>), igual que la rejilla de tiempo.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Un polígono de tierra con sus huecos (mares interiores, lagos grandes
/// que Natural Earth ya recorta como agujero del propio polígono).
class LandPolygon {
  const LandPolygon(this.ring, this.holes, this.bbox);

  /// Vértices (lon, lat) del anillo exterior, sin cerrar explícitamente
  /// (el primer y último punto pueden repetirse o no, el test no lo
  /// necesita).
  final List<(double, double)> ring;
  final List<List<(double, double)>> holes;

  /// (minLon, minLat, maxLon, maxLat), para descartar el polígono a la
  /// primera sin recorrer sus puntos.
  final (double, double, double, double) bbox;

  bool bboxContains(double lon, double lat, double marginDeg) =>
      lon >= bbox.$1 - marginDeg &&
      lon <= bbox.$3 + marginDeg &&
      lat >= bbox.$2 - marginDeg &&
      lat <= bbox.$4 + marginDeg;
}

bool _pointInRing(double lon, double lat, List<(double, double)> ring) {
  // Ray casting de toda la vida: cuenta cuántas veces un rayo horizontal
  // desde el punto cruza el anillo. Impar = dentro.
  var inside = false;
  final n = ring.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final (xi, yi) = ring[i];
    final (xj, yj) = ring[j];
    if ((yi > lat) != (yj > lat) &&
        lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Distancia mínima (en grados, aprox.) de un punto a un segmento.
double _pointToSegmentDeg(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  var t = len2 <= 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx, cy = ay + t * dy;
  return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

class LandMask {
  LandMask(this.polygons);

  final List<LandPolygon> polygons;

  factory LandMask.empty() => LandMask(const []);

  factory LandMask.fromJson(String source) {
    try {
      final doc = jsonDecode(source) as Map<String, dynamic>;
      final polys = <LandPolygon>[];
      for (final p in (doc['polygons'] as List)) {
        final m = p as Map<String, dynamic>;
        final ring = _readRing(m['ring'] as List);
        if (ring.length < 3) continue;
        final holes = [
          for (final h in (m['holes'] as List? ?? const []))
            _readRing(h as List),
        ];
        var minLon = ring.first.$1, maxLon = ring.first.$1;
        var minLat = ring.first.$2, maxLat = ring.first.$2;
        for (final (x, y) in ring) {
          if (x < minLon) minLon = x;
          if (x > maxLon) maxLon = x;
          if (y < minLat) minLat = y;
          if (y > maxLat) maxLat = y;
        }
        polys.add(LandPolygon(ring, holes, (minLon, minLat, maxLon, maxLat)));
      }
      return LandMask(polys);
    } catch (_) {
      // Sin máscara la ruta se sigue calculando, solo sin evitar tierra:
      // mejor eso que tumbar el routing por un asset corrupto.
      return LandMask.empty();
    }
  }

  static List<(double, double)> _readRing(List raw) => [
    for (final pt in raw)
      ((pt[0] as num).toDouble(), (pt[1] as num).toDouble()),
  ];

  bool get isEmpty => polygons.isEmpty;

  /// Solo los polígonos que caen cerca de esta caja — para no escanear
  /// las 74 costas del Mediterráneo en cada uno de los 72 rumbos que
  /// prueba cada nodo cuando la ruta entera está en mar abierta, lejos de
  /// cualquiera de ellas. El motor la llama una vez por pierna, no por
  /// candidato.
  LandMask restrictedTo(
    double south,
    double west,
    double north,
    double east,
    double marginDeg,
  ) {
    final filtered = [
      for (final p in polygons)
        if (p.bbox.$3 >= west - marginDeg &&
            p.bbox.$1 <= east + marginDeg &&
            p.bbox.$4 >= south - marginDeg &&
            p.bbox.$2 <= north + marginDeg)
          p,
    ];
    return LandMask(filtered);
  }

  /// ¿El punto cae en tierra? (dentro del anillo exterior de algún
  /// polígono y no dentro de ninguno de sus huecos).
  bool isLand(double lat, double lon) {
    for (final p in polygons) {
      if (!p.bboxContains(lon, lat, 0)) continue;
      if (!_pointInRing(lon, lat, p.ring)) continue;
      var inHole = false;
      for (final h in p.holes) {
        if (_pointInRing(lon, lat, h)) {
          inHole = true;
          break;
        }
      }
      if (!inHole) return true;
    }
    return false;
  }

  /// ¿El punto está en tierra o a menos de [marginNm] millas de la costa
  /// más cercana? Es el margen de seguridad (`minimumCoastDistanceNm`):
  /// no evita solo pisar tierra, evita rozarla.
  bool nearLand(double lat, double lon, double marginNm) {
    if (polygons.isEmpty) return false;
    final marginDeg = marginNm / 60; // aprox., suficiente para un margen chico
    final cosLat = math.cos(lat * math.pi / 180).abs().clamp(0.15, 1.0);
    for (final p in polygons) {
      if (!p.bboxContains(lon, lat, marginDeg)) continue;
      if (_pointInRing(lon, lat, p.ring)) return true;
      final minDeg = _minDistToRingDeg(lon, lat, p.ring, cosLat);
      if (minDeg * 60 <= marginNm) return true;
      for (final h in p.holes) {
        final minDegH = _minDistToRingDeg(lon, lat, h, cosLat);
        if (minDegH * 60 <= marginNm) return true;
      }
    }
    return false;
  }

  double _minDistToRingDeg(
    double lon,
    double lat,
    List<(double, double)> ring,
    double cosLat,
  ) {
    var best = double.infinity;
    for (var i = 0; i < ring.length; i++) {
      final (ax, ay) = ring[i];
      final (bx, by) = ring[(i + 1) % ring.length];
      // Corrección grosera este-oeste por la latitud, para que el margen
      // en millas no salga distinto en longitud que en latitud.
      final d = _pointToSegmentDeg(
        lon * cosLat,
        lat,
        ax * cosLat,
        ay,
        bx * cosLat,
        by,
      );
      if (d < best) best = d;
    }
    return best;
  }

  /// Si algún punto del segmento (muestreado, no una intersección exacta
  /// de geometría) cae en tierra o dentro del margen: usado como
  /// comprobación barata de que un tramo de 15 min no atraviesa una
  /// costa entre sus dos extremos.
  bool segmentBlocked(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
    double marginNm, {
    int samples = 4,
  }) {
    if (polygons.isEmpty) return false;
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final lat = lat1 + (lat2 - lat1) * t;
      final lon = lon1 + (lon2 - lon1) * t;
      if (nearLand(lat, lon, marginNm)) return true;
    }
    return false;
  }
}

/// Índice espacial de la costa para UNA pierna, con la comprobación de
/// tramo EXACTA: distancia real del tramo a cada borde de costa (y cruce),
/// no unos puntos muestreados. Más precisa que [LandMask.segmentBlocked]
/// (el muestreo podía saltarse una punta de tierra estrecha entre dos
/// muestras si el tramo era largo) y muchísimo más rápida: cada tramo solo
/// mira los bordes de las celdas que toca, y en mar abierta ninguno.
///
/// Misma métrica que [LandMask.nearLand]: grados con la longitud corregida
/// por el coseno de la latitud del punto consultado, × 60 = millas.
class LandSegmentIndex {
  LandSegmentIndex._(
    this._south,
    this._west,
    this._cell,
    this._nLat,
    this._nLon,
    this._cells,
    this._ax,
    this._ay,
    this._bx,
    this._by,
    this.marginNm,
    this._lonPadDeg,
    this._latPadDeg,
  ) : _stamp = Int32List(_ax.length);

  /// Índice de los bordes de [mask] dentro de la caja (con [marginNm] de
  /// margen para no perder bordes justo fuera de ella).
  factory LandSegmentIndex.build(
    LandMask mask, {
    required double south,
    required double west,
    required double north,
    required double east,
    required double marginNm,
  }) {
    // Relleno en grados del margen, con el coseno más pequeño de la caja
    // (el caso más ancho en longitud): así ninguna celda se queda sin un
    // borde que de verdad esté a menos del margen.
    final maxAbsLat = math.max(south.abs(), north.abs()).clamp(0.0, 85.0);
    final minCos = math.cos(maxAbsLat * math.pi / 180).clamp(0.05, 1.0);
    final latPad = marginNm / 60 + 1e-9;
    final lonPad = marginNm / (60 * minCos) + 1e-9;
    final s = south - latPad, w = west - lonPad;
    final n = north + latPad, e = east + lonPad;
    // Celdas de ~0,02° como poco (1,2 M), y como mucho ~40 000 celdas.
    final area = (n - s) * (e - w);
    final cell = math.max(0.02, math.sqrt(area / 40000));
    final nLat = math.max(1, ((n - s) / cell).ceil());
    final nLon = math.max(1, ((e - w) / cell).ceil());

    final ax = <double>[], ay = <double>[], bx = <double>[], by = <double>[];
    final lists = List<List<int>?>.filled(nLat * nLon, null);
    void addRing(List<(double, double)> ring) {
      final len = ring.length;
      for (var i = 0; i < len; i++) {
        final (x1, y1) = ring[i];
        final (x2, y2) = ring[(i + 1) % len];
        final minX = math.min(x1, x2) - lonPad,
            maxX = math.max(x1, x2) + lonPad;
        final minY = math.min(y1, y2) - latPad,
            maxY = math.max(y1, y2) + latPad;
        if (maxX < w || minX > e || maxY < s || minY > n) continue;
        final id = ax.length;
        ax.add(x1);
        ay.add(y1);
        bx.add(x2);
        by.add(y2);
        final i0 = ((minY - s) / cell).floor().clamp(0, nLat - 1);
        final i1 = ((maxY - s) / cell).floor().clamp(0, nLat - 1);
        final j0 = ((minX - w) / cell).floor().clamp(0, nLon - 1);
        final j1 = ((maxX - w) / cell).floor().clamp(0, nLon - 1);
        for (var ci = i0; ci <= i1; ci++) {
          for (var cj = j0; cj <= j1; cj++) {
            (lists[ci * nLon + cj] ??= <int>[]).add(id);
          }
        }
      }
    }

    for (final p in mask.polygons) {
      if (p.bbox.$3 < w || p.bbox.$1 > e || p.bbox.$4 < s || p.bbox.$2 > n) {
        continue;
      }
      addRing(p.ring);
      for (final h in p.holes) {
        addRing(h);
      }
    }
    return LandSegmentIndex._(
      s,
      w,
      cell,
      nLat,
      nLon,
      [for (final l in lists) l == null ? null : Int32List.fromList(l)],
      Float64List.fromList(ax),
      Float64List.fromList(ay),
      Float64List.fromList(bx),
      Float64List.fromList(by),
      marginNm,
      lonPad,
      latPad,
    );
  }

  final double _south, _west, _cell;
  final int _nLat, _nLon;
  final List<Int32List?> _cells;
  final Float64List _ax, _ay, _bx, _by;
  final double marginNm;
  final double _lonPadDeg, _latPadDeg;
  final Int32List _stamp;
  int _query = 0;

  bool get isEmpty => _ax.isEmpty;

  /// ¿El tramo cruza la costa o pasa a menos de [marginNm] de ella? No
  /// comprueba si el tramo entero cae DENTRO de tierra sin tocar su borde:
  /// el motor solo sale de puntos de agua (o de la zona de puerto, que no
  /// se comprueba), y un tramo que empieza en el agua y no toca ningún
  /// borde sigue en el agua.
  bool segmentBlocked(double lat1, double lon1, double lat2, double lon2) {
    if (_ax.isEmpty) return false;
    final minY = math.min(lat1, lat2) - _latPadDeg;
    final maxY = math.max(lat1, lat2) + _latPadDeg;
    final minX = math.min(lon1, lon2) - _lonPadDeg;
    final maxX = math.max(lon1, lon2) + _lonPadDeg;
    final i0 = ((minY - _south) / _cell).floor();
    final i1 = ((maxY - _south) / _cell).floor();
    final j0 = ((minX - _west) / _cell).floor();
    final j1 = ((maxX - _west) / _cell).floor();
    if (i1 < 0 || j1 < 0 || i0 >= _nLat || j0 >= _nLon) return false;
    // Métrica local del tramo: longitud × cos(lat), como nearLand.
    final cosLat = math
        .cos((lat1 + lat2) / 2 * math.pi / 180)
        .abs()
        .clamp(0.15, 1.0);
    final px1 = lon1 * cosLat, px2 = lon2 * cosLat;
    final marginDeg = marginNm / 60;
    final q = ++_query;
    if (q == 0x7fffffff) {
      _stamp.fillRange(0, _stamp.length, 0);
      _query = 1;
    }
    for (var ci = math.max(0, i0); ci <= math.min(_nLat - 1, i1); ci++) {
      for (var cj = math.max(0, j0); cj <= math.min(_nLon - 1, j1); cj++) {
        final ids = _cells[ci * _nLon + cj];
        if (ids == null) continue;
        for (final id in ids) {
          if (_stamp[id] == _query) continue;
          _stamp[id] = _query;
          final d = _segSegDist(
            px1,
            lat1,
            px2,
            lat2,
            _ax[id] * cosLat,
            _ay[id],
            _bx[id] * cosLat,
            _by[id],
          );
          if (d <= marginDeg) return true;
        }
      }
    }
    return false;
  }
}

/// Distancia mínima entre dos segmentos del plano (0 si se cruzan).
double _segSegDist(
  double x1,
  double y1,
  double x2,
  double y2,
  double x3,
  double y3,
  double x4,
  double y4,
) {
  if (_segmentsIntersect(x1, y1, x2, y2, x3, y3, x4, y4)) return 0;
  return math.min(
    math.min(
      _pointToSegmentDeg(x1, y1, x3, y3, x4, y4),
      _pointToSegmentDeg(x2, y2, x3, y3, x4, y4),
    ),
    math.min(
      _pointToSegmentDeg(x3, y3, x1, y1, x2, y2),
      _pointToSegmentDeg(x4, y4, x1, y1, x2, y2),
    ),
  );
}

bool _segmentsIntersect(
  double x1,
  double y1,
  double x2,
  double y2,
  double x3,
  double y3,
  double x4,
  double y4,
) {
  double orient(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
  ) => (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  final d1 = orient(x3, y3, x4, y4, x1, y1);
  final d2 = orient(x3, y3, x4, y4, x2, y2);
  final d3 = orient(x1, y1, x2, y2, x3, y3);
  final d4 = orient(x1, y1, x2, y2, x4, y4);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  // Casos colineales/tocando: los cubre la distancia punto–segmento (0).
  return false;
}
