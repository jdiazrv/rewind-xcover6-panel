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
    for (final pt in raw) ((pt[0] as num).toDouble(), (pt[1] as num).toDouble()),
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
