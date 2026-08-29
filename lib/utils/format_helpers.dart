part of '../main.dart';

int _closestIndex(List<num> times, DateTime target) {
  if (times.isEmpty) return -1;
  var best = 0;
  var bestDelta = ((times[0] * 1000).round() - target.millisecondsSinceEpoch)
      .abs();
  for (var i = 1; i < times.length; i++) {
    final delta = ((times[i] * 1000).round() - target.millisecondsSinceEpoch)
        .abs();
    if (delta < bestDelta) {
      best = i;
      bestDelta = delta;
    }
  }
  return best;
}

String fmt(double? value, int decimals, String suffix) =>
    value == null ? '--$suffix' : '${value.toStringAsFixed(decimals)}$suffix';
String tempK(double? value) =>
    value == null ? '-- C' : '${(value - 273.15).toStringAsFixed(1)} C';
String tempNum(double? kelvin) =>
    kelvin == null ? '--' : (kelvin - 273.15).toStringAsFixed(1);
String tempValue(double? kelvin) =>
    kelvin == null ? 'No data' : (kelvin - 273.15).toStringAsFixed(1);
String? tempUnit(double? kelvin) => kelvin == null ? null : '°C';
// Degrees + minutes.tenths (e.g. 36°43.3'N) — the format sailors actually
// plot with, rather than raw decimal degrees.
String _dmm(double value, bool isLat) {
  final hemi = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
  final abs = value.abs();
  var deg = abs.floor();
  var min = (abs - deg) * 60;
  var minStr = min.toStringAsFixed(1);
  if (double.parse(minStr) >= 60) {
    deg += 1;
    minStr = '0.0';
  }
  final degStr = deg.toString().padLeft(isLat ? 2 : 3, '0');
  return "$degStr°$minStr'$hemi";
}

String pos(double? lat, double? lon) => lat == null || lon == null
    ? '--'
    : '${_dmm(lat, true)} ${_dmm(lon, false)}';
String posLines(double? lat, double? lon) => lat == null || lon == null
    ? '--'
    : '${_dmm(lat, true)}\n${_dmm(lon, false)}';
String angle(double? value) => value == null ? '--' : value.round().toString();
String angleAbs(double? value) => value == null
    ? '--'
    : normalizeRelativeAngle(value).abs().round().toString();
String directionDeg(double? value) =>
    value == null ? '--' : normalize360(value).round().toString();
String hhmm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String ddmmyyyy(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
String _lastUpdateText(DateTime? value) {
  if (value == null) return 'Sin datos';
  final seconds = DateTime.now().difference(value).inSeconds;
  if (seconds < 60) return 'Hace ${math.max(0, seconds)} s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return 'Hace $minutes min';
  return hhmm(value);
}

String dir(double? value) {
  if (value == null) return '--';
  const dirs = [
    'N',
    'NNE',
    'NE',
    'ENE',
    'E',
    'ESE',
    'SE',
    'SSE',
    'S',
    'SSW',
    'SW',
    'WSW',
    'W',
    'WNW',
    'NW',
    'NNW',
  ];
  return dirs[((value + 11.25) ~/ 22.5) & 15];
}

String fmtDeg(double? deg) =>
    deg == null ? '--°' : '${normalize360(deg).round()}°';

String fmtHeel(double? deg) {
  if (deg == null) return '--°';
  final side = deg < 0 ? 'B' : 'E';
  return '${deg.abs().round()}° $side';
}

Color heelColor(double? deg) {
  if (deg == null) return cMuted;
  return deg >= 0 ? cGreen : cRed;
}

Color meteogramColor(double? kn) {
  if (kn == null) return cMuted;
  if (kn < 3) return cMuted;
  if (kn < 7) return const Color(0xff2ea89a);
  if (kn < 10) return cOrange;
  if (kn < 15) return cRed;
  if (kn < 20) return const Color(0xffb33a3a);
  return cPurple;
}

Color windColor(double? speed) {
  if (speed == null) return cRed;
  if (speed <= 5) return cCyan;
  if (speed <= 15) return cGreen;
  if (speed <= 25) return cOrange;
  return cRed;
}

int? beaufort(double? kn) {
  if (kn == null) return null;
  const upper = [1, 4, 7, 11, 17, 22, 28, 34, 41, 48, 56, 64];
  for (var i = 0; i < upper.length; i++) {
    if (kn < upper[i]) return i;
  }
  return 12;
}

Color socColor(double? pct) {
  if (pct == null) return cMuted;
  if (pct >= 80) return cGreen;
  if (pct >= 50) return cYellow;
  if (pct >= 20) return cOrange;
  return cRed;
}

Color currentColor(double? amps) {
  if (amps == null) return cMuted;
  return amps >= 0 ? cGreen : cOrange;
}

Color sideColor(double? angle) {
  if (angle == null) return cMuted;
  return normalizeRelativeAngle(angle) < 0 ? cRed : cGreen;
}

Color voltageColor12V(double? v) {
  if (v == null) return cMuted;
  if (v >= 12.7) return cGreen;
  if (v >= 12.4) return cYellow;
  if (v >= 12.0) return cOrange;
  return cRed;
}

Color seaTempColor(double? kelvin) {
  if (kelvin == null) return cMuted;
  final c = kelvin - 273.15;
  if (c < 15) return cCyan;
  if (c < 22) return cGreen;
  if (c < 28) return cYellow;
  return cOrange;
}

// Equipment temp: green=normal, orange=warm, red=too hot
Color equipTempColor(double? kelvin, {double warnC = 40, double alarmC = 55}) {
  if (kelvin == null) return cMuted;
  final c = kelvin - 273.15;
  if (c >= alarmC) return cRed;
  if (c >= warnC) return cOrange;
  return cGreen;
}

// Fridge temp: cyan=perfect, green=ok, orange=too warm, red=alarm
Color fridgeTempColor(double? kelvin) {
  if (kelvin == null) return cMuted;
  final c = kelvin - 273.15;
  if (c > 10) return cRed;
  if (c > 6) return cOrange;
  if (c > 2) return cGreen;
  return cCyan;
}

// Depth: cyan=deep, green=ok, orange=caution, red=shallow
Color depthColor(double? meters) {
  if (meters == null) return cMuted;
  if (meters < 2.0) return cRed;
  if (meters < 5.0) return cOrange;
  if (meters < 15.0) return cYellow;
  return cCyan;
}

double normalize360(double value) {
  var out = value % 360.0;
  if (out < 0) out += 360.0;
  return out;
}

double normalizeRelativeAngle(double value) {
  var out = normalize360(value);
  if (out > 180.0) out -= 360.0;
  return out;
}

double? relativeWindAngle(double? directionDeg, double? referenceDeg) {
  if (directionDeg == null || referenceDeg == null) return null;
  return normalizeRelativeAngle(directionDeg - referenceDeg);
}
