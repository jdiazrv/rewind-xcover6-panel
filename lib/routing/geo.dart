// Geodesia para el routing: esfera de radio medio, en millas náuticas.
// Para tramos de 15 min y rutas de 200 M como máximo, el error frente al
// elipsoide (<0,5 %) es mucho menor que la incertidumbre del pronóstico.

import 'dart:math' as math;

const kEarthRadiusNm = 3440.065;

double _rad(double d) => d * math.pi / 180;
double _deg(double r) => r * 180 / math.pi;

/// Distancia ortodrómica en millas.
double distanceNm(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1), p2 = _rad(lat2);
  final dp = p2 - p1, dl = _rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * kEarthRadiusNm * math.asin(math.min(1, math.sqrt(a)));
}

/// Rumbo inicial (0–360°) de 1 a 2.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1), p2 = _rad(lat2), dl = _rad(lon2 - lon1);
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

/// El punto a [distNm] millas de (lat, lon) al rumbo [bearing].
({double lat, double lon}) destinationNm(
  double lat,
  double lon,
  double bearing,
  double distNm,
) {
  final d = distNm / kEarthRadiusNm;
  final b = _rad(bearing);
  final p1 = _rad(lat), l1 = _rad(lon);
  final p2 = math.asin(
    math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b),
  );
  final l2 =
      l1 +
      math.atan2(
        math.sin(b) * math.sin(d) * math.cos(p1),
        math.cos(d) - math.sin(p1) * math.sin(p2),
      );
  return (lat: _deg(p2), lon: (_deg(l2) + 540) % 360 - 180);
}

/// Diferencia angular con signo en (−180, 180].
double angleDiff(double a, double b) {
  var d = (a - b) % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/// "37°23,7'N 24°52,7'E"
String formatLatLon(double lat, double lon) {
  String part(double v, String pos, String neg) {
    final h = v >= 0 ? pos : neg;
    final a = v.abs();
    var d = a.floor();
    var m = (a - d) * 60;
    if (m >= 59.95) {
      d += 1;
      m = 0;
    }
    return '$d°${m.toStringAsFixed(1).replaceAll('.', ',')}\'$h';
  }

  return '${part(lat, 'N', 'S')} ${part(lon, 'E', 'W')}';
}
