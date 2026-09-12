import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'attitude_sensor.dart';
import 'data_api.dart';
import 'theme.dart';

/// Whether recent measured engine telemetry proves that the ECU/contact is
/// currently present. Values and source timestamps stay paired so a retained
/// Signal K replay cannot masquerade as fresh contact activity.
bool engineContactTelemetryIsFresh({
  required DateTime now,
  required double? rpm,
  required DateTime? rpmUpdatedAt,
  required Iterable<(double?, DateTime?)> slowTelemetry,
  required Duration fastStaleAfter,
  required Duration slowStaleAfter,
}) {
  bool fresh(double? value, DateTime? updatedAt, Duration limit) =>
      value != null && updatedAt != null && now.difference(updatedAt) < limit;

  if (fresh(rpm, rpmUpdatedAt, fastStaleAfter)) return true;
  return slowTelemetry.any(
    (sample) => fresh(sample.$1, sample.$2, slowStaleAfter),
  );
}

// How far ahead/behind the connected Signal K server's own clock this
// device's clock is (server − device) — refreshed opportunistically from
// the `Date` response header on ordinary REST calls (see main.dart's
// _fetchVesselName, the call site of skRecordServerDate). The anchor
// watch's cross-device "last write wins" arbitration
// (AnchorConfig.armedOrMovedAt, set from both main.dart and
// anchor_native_view.dart) stamps edits with skNow() instead of a raw
// DateTime.now(), so two devices whose own clocks disagree still order
// their edits consistently against the ONE server clock they both
// actually talk to, rather than against each other's potentially-skewed
// local time. Lives here (not main.dart) so anchor_native_view.dart — a
// separate library that only imports models.dart/theme.dart, not a `part
// of` file — can reach it too. Verified real via external audit, fixed
// 2026-09-04.
Duration skClockOffset = Duration.zero;
DateTime skNow() => DateTime.now().toUtc().add(skClockOffset);

bool shouldAutoRaiseAnchor({
  required bool armed,
  required double? trustedDistanceM,
  double limitM = 300,
}) => armed && trustedDistanceM != null && trustedDistanceM > limitM;

// RFC 7231 preferred HTTP-date format only (what every HTTP server this
// app talks to actually sends, including Signal K's), e.g.
// "Sun, 06 Nov 1994 08:49:37 GMT" — not a general RFC 7231 parser (the
// obsolete asctime()/RFC 850 alternate forms are never seen in practice
// here), and deliberately not using dart:io's HttpDate.parse, which isn't
// available on web.
final _httpDateRe = RegExp(
  r'^\w+, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);
const _httpDateMonths = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};
DateTime? _parseHttpDate(String s) {
  final m = _httpDateRe.firstMatch(s.trim());
  if (m == null) return null;
  final month = _httpDateMonths[m.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}

// Updates skClockOffset from an HTTP response's `Date` header, when
// present and parseable — call sites are ordinary REST calls this app
// already makes (see _fetchVesselName), not a dedicated round trip of its
// own. Second-precision only (HTTP dates carry no finer resolution) and
// ignores request/response latency entirely — nowhere near NTP-grade, but
// easily good enough to correct the many-minutes-to-hours clock drift that
// actually causes cross-device anchor conflicts, at zero extra network
// cost.
void skRecordServerDate(http.BaseResponse response) {
  final raw = response.headers['date'];
  if (raw == null) return;
  final serverNow = _parseHttpDate(raw);
  if (serverNow == null) return;
  skClockOffset = serverNow.difference(DateTime.now().toUtc());
}

// Moved here from utils/format_helpers.dart (a `part of main.dart` file
// that can't be reached from models.dart's own standalone library) so
// computeYawAnalysis below can use it too — main.dart and its part files
// already see this via main.dart's own `import 'models.dart';`.
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

/// Great-circle bearing/distance between two points — shared by the AIS
/// radar (ais_view.dart, in nautical miles) and the native anchor watch
/// (main.dart, in meters), so both use the same Haversine math instead of
/// two divergent copies.
({double bearingDeg, double distanceM}) bearingDistanceMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const r = 6371000.0; // meters
  final dLat = (lat2 - lat1) * math.pi / 180,
      dLon = (lon2 - lon1) * math.pi / 180;
  final lat1r = lat1 * math.pi / 180, lat2r = lat2 * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1r) *
          math.cos(lat2r) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  final y = math.sin(dLon) * math.cos(lat2r);
  final x =
      math.cos(lat1r) * math.sin(lat2r) -
      math.sin(lat1r) * math.cos(lat2r) * math.cos(dLon);
  final brg = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  return (bearingDeg: brg, distanceM: r * c);
}

/// Inverse of bearingDistanceMeters: the point distanceM away from
/// (lat, lon) along bearingDeg (true). Plain-doubles twin of
/// NativeAnchorView's own private _destinationPoint (which uses the
/// latlong2 package's LatLng, not imported here) — shared with main.dart
/// so navigation.anchor.distanceFromBow/bearingTrue can apply the same
/// GPS-antenna-to-bow correction _dropAnchor's drop point already does,
/// instead of quietly measuring from the antenna while claiming to
/// measure "from bow".
({double lat, double lon}) destinationPoint(
  double lat,
  double lon,
  double distanceM,
  double bearingDeg,
) {
  const earthR = 6371000.0;
  final brgRad = bearingDeg * math.pi / 180;
  final lat1 = lat * math.pi / 180;
  final lon1 = lon * math.pi / 180;
  final lat2 = math.asin(
    math.sin(lat1) * math.cos(distanceM / earthR) +
        math.cos(lat1) * math.sin(distanceM / earthR) * math.cos(brgRad),
  );
  final lon2 =
      lon1 +
      math.atan2(
        math.sin(brgRad) * math.sin(distanceM / earthR) * math.cos(lat1),
        math.cos(distanceM / earthR) - math.sin(lat1) * math.sin(lat2),
      );
  return (lat: lat2 * 180 / math.pi, lon: lon2 * 180 / math.pi);
}

/// Whether a point [distanceM] from the drop position, at true bearing
/// [bearingFromDropDeg] from it, counts as outside the anchor watch zone —
/// circle: past the radius; sector: ALSO past the radius, or past the
/// arc's span even while still inside it. Shared by the drag-alarm engine
/// (main.dart's _isOutsideAnchorZone) and the ANC screen's own live
/// "outside" status (anchor_native_view.dart) so the two can never
/// disagree about the same zone — the screen used to only ever compare
/// distance to radius, so a sector watch could show a calm "FONDEADO"
/// while the real alarm correctly fired for being outside the arc.
bool isOutsideWatchZone({
  required double distanceM,
  required double radiusM,
  required String shape,
  double? bearingFromDropDeg,
  double? sectorStartDeg,
  double? sectorEndDeg,
}) {
  if (distanceM > radiusM) return true;
  if (shape != 'sector') return false;
  if (bearingFromDropDeg == null ||
      sectorStartDeg == null ||
      sectorEndDeg == null) {
    return false;
  }
  final span = (sectorEndDeg - sectorStartDeg + 360) % 360;
  final rel = (bearingFromDropDeg - sectorStartDeg + 360) % 360;
  return rel > span;
}

class GraphPoint {
  const GraphPoint({required this.time, required this.value});
  final DateTime time;
  final double value;
}

/// Coerces a barometric reading to millibars/hPa whatever unit it arrived
/// in, so the card can't end up showing "10.1 mbar".
///
/// Signal K specifies environment.*.pressure in PASCALS, and the app
/// divides by 100 accordingly. But sources exist that publish hPa while
/// still declaring "units": "Pa" — REWIND's own signalk-node-red flow
/// does exactly that (verified live 2026-09-08: value 1010.7 with Pa
/// metadata), so the spec-correct division produced 10.1. The same
/// mismatch also shows up from the other end, when a history query
/// applies the metric's 0.01 scale to a series that was already stored
/// in hPa.
///
/// A range test is safe here precisely because the two scales cannot
/// overlap for real weather: sea-level pressure has never been recorded
/// outside roughly 870–1085 hPa (87,000–108,500 Pa). Anything under ~500
/// can only be an over-divided value; anything over ~10,000 can only be
/// Pascals. Neither branch can misfire on a plausible reading.
/// Plausible sea-level pressure. The extremes ever recorded on Earth are
/// ~870 hPa (typhoon Tip) and ~1084 hPa (Siberia); this window is wider
/// than either, so nothing real is ever rejected.
const _minPlausibleHpa = 800.0;
const _maxPlausibleHpa = 1100.0;

double? normalizePressureHpa(double? raw) {
  if (raw == null || !raw.isFinite) return null;
  // Try each interpretation and keep the one that lands in the plausible
  // window. Ordered most- to least-likely; they can't both match, since
  // the windows are two orders of magnitude apart.
  for (final candidate in [raw, raw / 100, raw * 100]) {
    if (candidate >= _minPlausibleHpa && candidate <= _maxPlausibleHpa) {
      return candidate;
    }
  }
  // Nothing plausible: DROP the sample rather than show it. A reading of
  // 510 mbar isn't weather, it's a glitch (a partial/corrupt frame from
  // the BLE sensor, or a stray value during the Node-RED unit change),
  // and plotting it drags the whole trend graph's scale down and fakes a
  // dramatic "crash". Reported live 2026-09-08 ("la presión muestra una
  // caída a 510, filtra para que no pasen esas cosas").
  return null;
}

/// Wrapper referenceable from a const [MetricDef]. Deliberately keeps the
/// null: an implausible sample must be DROPPED by the history path, not
/// plotted, or it drags the graph's scale into a fake crash.
double? normalizePressureHpaValue(double raw) => normalizePressureHpa(raw);

/// A noisy series reduced to what's actually readable: the rolling mean
/// ("sostenido") plus the min/max envelope of the same window.
typedef SmoothedBand = ({
  List<GraphPoint> mean,
  List<GraphPoint> low,
  List<GraphPoint> high,
});

/// Rolling mean + min/max envelope over a TIME window (not a fixed sample
/// count — history sources return very different cadences per range, so a
/// count-based window would mean wildly different real durations).
///
/// This is the standard meteorological way to read wind: a sustained line
/// with the gust/lull envelope around it, rather than the raw trace, whose
/// point-to-point oscillation hides the trend that actually matters when
/// deciding sail area. Reported live 2026-09-07 ("la grafica de viento...
/// es poco util con tanta oscilacion").
///
/// [circular] switches to circular statistics for ANGLES (AWA/TWA/TWD): a
/// plain arithmetic mean is wrong the moment the series crosses its wrap
/// seam (±180 for the relative angles, 0/360 for TWD) — e.g. -179 and +179
/// are 2° apart but average to 0, dead ahead, which is the opposite of the
/// truth. The mean goes through atan2(Σsin, Σcos) instead, and the
/// envelope is built from each sample's wrapped deviation from that mean,
/// so it stays correct across the seam too.
///
/// Note on the envelope's meaning: when the history source already
/// aggregated with `mean` over its own step (InfluxDB's aggregateWindow
/// does), the max here is a max OF MEANS, so it understates true gusts —
/// it shows how much the averaged signal swings, not the 3-second peak a
/// meteorological gust is defined as. Honest framing matters here, hence
/// the UI labels this "variación", not "racha".
SmoothedBand smoothSeriesWithBand(
  List<GraphPoint> points,
  Duration window, {
  bool circular = false,
}) {
  if (points.length < 3 || window <= Duration.zero) {
    return (mean: points, low: const [], high: const []);
  }
  final halfMs = window.inMilliseconds ~/ 2;
  final mean = <GraphPoint>[];
  final low = <GraphPoint>[];
  final high = <GraphPoint>[];
  // Two pointers over a time-sorted series — O(n) rather than O(n²).
  var lo = 0, hi = 0;
  for (var i = 0; i < points.length; i++) {
    final tMs = points[i].time.millisecondsSinceEpoch;
    while (lo < i && points[lo].time.millisecondsSinceEpoch < tMs - halfMs) {
      lo++;
    }
    while (hi + 1 < points.length &&
        points[hi + 1].time.millisecondsSinceEpoch <= tMs + halfMs) {
      hi++;
    }
    final t = points[i].time;
    if (circular) {
      var sumSin = 0.0, sumCos = 0.0;
      for (var j = lo; j <= hi; j++) {
        final rad = points[j].value * math.pi / 180;
        sumSin += math.sin(rad);
        sumCos += math.cos(rad);
      }
      final circMean = math.atan2(sumSin, sumCos) * 180 / math.pi;
      // Re-express near the raw sample so the plotted line stays
      // numerically continuous instead of snapping to atan2's own branch.
      final shift =
          ((circMean - points[i].value + 180) % 360 + 360) % 360 - 180;
      final m = points[i].value + shift;
      var devMin = 0.0, devMax = 0.0;
      for (var j = lo; j <= hi; j++) {
        final dev = ((points[j].value - m + 180) % 360 + 360) % 360 - 180;
        if (dev < devMin) devMin = dev;
        if (dev > devMax) devMax = dev;
      }
      mean.add(GraphPoint(time: t, value: m));
      low.add(GraphPoint(time: t, value: m + devMin));
      high.add(GraphPoint(time: t, value: m + devMax));
    } else {
      var sum = 0.0;
      var mn = points[lo].value, mx = points[lo].value;
      for (var j = lo; j <= hi; j++) {
        final v = points[j].value;
        sum += v;
        if (v < mn) mn = v;
        if (v > mx) mx = v;
      }
      mean.add(GraphPoint(time: t, value: sum / (hi - lo + 1)));
      low.add(GraphPoint(time: t, value: mn));
      high.add(GraphPoint(time: t, value: mx));
    }
  }
  return (mean: mean, low: low, high: high);
}

/// Smoothing window for a given view: proportional to the visible range so
/// the line keeps roughly the same visual "resolution" at every zoom, but
/// never below a few raw samples (pointless) nor above 10 minutes for
/// short views (the meteorological sustained-wind period).
Duration smoothingWindowFor(Duration range, Duration sampleStep) {
  final proportional = Duration(milliseconds: range.inMilliseconds ~/ 60);
  final floor = sampleStep * 3;
  const ceiling = Duration(minutes: 10);
  var w = proportional < ceiling ? proportional : ceiling;
  if (w < floor) w = floor;
  return w;
}

/// One meteorological wind barb: [directionDeg] is the true direction the
/// wind comes from and [speedKnots] controls the 5/10/50 kt feathers.
class WindBarbSample {
  const WindBarbSample({
    required this.time,
    required this.speedKnots,
    required this.directionDeg,
  });

  final DateTime time;
  final double speedKnots;
  final double directionDeg;
}

const _windBarbNiceIntervals = <Duration>[
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 3),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(days: 1),
  Duration(days: 2),
];

Duration windBarbInterval(Duration range, {required int targetCount}) {
  final wantedMs = range.inMilliseconds / math.max(1, targetCount);
  for (final interval in _windBarbNiceIntervals) {
    if (interval.inMilliseconds >= wantedMs) return interval;
  }
  return _windBarbNiceIntervals.last;
}

String formatWindBarbInterval(Duration interval) {
  if (interval.inDays > 0) return '${interval.inDays} d';
  if (interval.inHours > 0) return '${interval.inHours} h';
  return '${interval.inMinutes} min';
}

double? _centeredWindMean(List<GraphPoint> points, DateTime slot) {
  const halfWindow = Duration(minutes: 3);
  final from = slot.subtract(halfWindow);
  final to = slot.add(halfWindow);
  var sum = 0.0;
  var count = 0;
  var hasBefore = false;
  var hasAfter = false;
  for (final point in points) {
    if (point.time.isBefore(from) || point.time.isAfter(to)) continue;
    if (!point.value.isFinite || point.value < 0) continue;
    sum += point.value;
    count++;
    if (point.time.isBefore(slot)) hasBefore = true;
    if (point.time.isAfter(slot)) hasAfter = true;
  }
  return count > 0 && hasBefore && hasAfter ? sum / count : null;
}

double? _centeredWindDirection(List<GraphPoint> points, DateTime slot) {
  const halfWindow = Duration(minutes: 3);
  final from = slot.subtract(halfWindow);
  final to = slot.add(halfWindow);
  var sinSum = 0.0;
  var cosSum = 0.0;
  var count = 0;
  var hasBefore = false;
  var hasAfter = false;
  for (final point in points) {
    if (point.time.isBefore(from) || point.time.isAfter(to)) continue;
    if (!point.value.isFinite) continue;
    final radians = point.value * math.pi / 180;
    sinSum += math.sin(radians);
    cosSum += math.cos(radians);
    count++;
    if (point.time.isBefore(slot)) hasBefore = true;
    if (point.time.isAfter(slot)) hasAfter = true;
  }
  if (count == 0 || !hasBefore || !hasAfter) return null;
  // An almost-zero resultant means the directions cancel out and there is no
  // honest representative direction for this six-minute window.
  if (math.sqrt(sinSum * sinSum + cosSum * cosSum) / count < 0.05) return null;
  return (math.atan2(sinSum, cosSum) * 180 / math.pi + 360) % 360;
}

/// Samples independent TWS and TWD histories on stable clock boundaries.
/// Each barb represents a centred six-minute window (three minutes before and
/// after), rather than one potentially noisy instantaneous sample. Direction
/// uses a circular mean so north-crossing values do not average to south.
List<WindBarbSample> sampleWindBarbs({
  required List<GraphPoint> tws,
  required List<GraphPoint> twd,
  required DateTime start,
  required DateTime end,
  required Duration interval,
}) {
  if (tws.isEmpty || twd.isEmpty || !end.isAfter(start)) return const [];
  final stepMs = interval.inMilliseconds;
  var slotMs = ((start.millisecondsSinceEpoch + stepMs - 1) ~/ stepMs) * stepMs;
  final out = <WindBarbSample>[];
  while (slotMs <= end.millisecondsSinceEpoch) {
    final slot = DateTime.fromMillisecondsSinceEpoch(slotMs, isUtc: true);
    final speed = _centeredWindMean(tws, slot);
    final direction = _centeredWindDirection(twd, slot);
    if (speed != null && direction != null) {
      out.add(
        WindBarbSample(time: slot, speedKnots: speed, directionDeg: direction),
      );
    }
    slotMs += stepMs;
  }
  return out;
}

// ─── Metric definitions ───────────────────────────────────────────────────────
class MetricDef {
  const MetricDef(
    this.skPath,
    this.label,
    this.unit, {
    this.offset = 0.0,
    this.scale = 1.0,
    this.color = cCyan,
    this.tankCapacityL,
    this.tankDangerWhenHigh = false,
    this.normalize,
  });
  final String skPath;
  final String label;
  final String unit;
  final double offset;
  final double scale;
  // Applied AFTER scale/offset, for paths where the fixed factor alone
  // can't be trusted because sources disagree about the unit they send
  // (see normalizePressureHpa). Runs in every history path — Influx, the
  // Signal K API and the demo series — so a graph can't disagree with the
  // live card.
  final double? Function(double)? normalize;
  final Color color;
  // Optional tank metadata lets the generic history screen translate a
  // trustworthy level trend into litres/day and estimated time remaining.
  final double? tankCapacityL;
  final bool tankDangerWhenHigh;
}

const mPressure = MetricDef(
  'environment.outside.pressure',
  'Presión',
  'mbar',
  scale: 0.01,
  // Guards the history/graph path against a source that publishes hPa
  // while declaring Pa — without it the graph read ~10 mbar while the
  // live card read ~1010. See normalizePressureHpa.
  normalize: normalizePressureHpaValue,
  color: cPurple,
);
const mOutdoorTemp = MetricDef(
  'environment.outside.temperature',
  'T. exterior',
  'C',
  offset: -273.15,
  color: cCyan,
);
const mIndoorTemp = MetricDef(
  'environment.interior.temperature',
  'T. interior',
  'C',
  offset: -273.15,
  color: cCyan,
);
const mSeaTemp = MetricDef(
  'environment.water.temperature',
  'T. mar',
  'C',
  offset: -273.15,
  color: cCyan,
);
const mSonoffTemp = MetricDef(
  'environment.sonoff.temperature',
  'Cuadro eléctrico',
  'C',
  offset: -273.15,
  color: cOrange,
);
const mSolarFusesTemp = MetricDef(
  'environment.solar_fuses.temperature',
  'T. Fusibles solar',
  'C',
  offset: -273.15,
  color: cOrange,
);
const mDcLoads = MetricDef(
  'electrical.venus.dcPower',
  'Consumos DC',
  'W',
  color: cOrange,
);
const mBowV = MetricDef(
  'electrical.batteries.bowthruster.voltage',
  'Bowthruster',
  'V',
  color: cCyan,
);

/// Descarta lecturas de viento imposibles.
///
/// El informe llegó a enseñar "ráfaga máx 552,4 kt" (2026-09-12): basta un
/// dato corrupto del sensor para envenenar un agregado `max`, que por
/// definición se queda con el peor valor de toda la ventana. El récord
/// mundial de racha en superficie ronda los 220 kt, y cualquier cosa por
/// encima de 100 en un velero es un fallo de lectura, no viento.
///
/// Devolver null hace que el punto se DESCARTE (ver MetricDef.normalize),
/// que es lo correcto aquí: un hueco es honesto, un 552 no.
const kMaxPlausibleWindKn = 100.0;
double? normalizeWindKn(double raw) {
  if (!raw.isFinite || raw < 0 || raw > kMaxPlausibleWindKn) return null;
  return raw;
}

const mTws = MetricDef(
  'environment.wind.speedTrue',
  'TWS',
  'kn',
  scale: 1.94384,
  // Ver normalizeWindKn: un solo dato corrupto arruina el agregado max
  // del informe de ráfagas.
  normalize: normalizeWindKn,
  color: cCyan,
);
const mHeel = MetricDef(
  'navigation.attitude.roll',
  'Escora',
  '°',
  scale: 57.2957795,
  color: cYellow,
);
const mAws = MetricDef(
  'environment.wind.speedApparent',
  'AWS',
  'kn',
  scale: 1.94384,
  // Ver normalizeWindKn: un solo dato corrupto arruina el agregado max
  // del informe de ráfagas.
  normalize: normalizeWindKn,
  color: cGreen,
);
const mAwa = MetricDef(
  'environment.wind.angleApparent',
  'AWA',
  'deg',
  scale: 57.2957795,
  color: cGreen,
);
const mTwa = MetricDef(
  'environment.wind.angleTrueWater',
  'TWA',
  'deg',
  scale: 57.2957795,
  color: cCyan,
);
const mTwd = MetricDef(
  'environment.wind.directionTrue',
  'TWD',
  'deg',
  scale: 57.2957795,
  color: cOrange,
);
const mSog = MetricDef(
  'navigation.speedOverGround',
  'SOG',
  'kn',
  scale: 1.94384,
  color: cGreen,
);
const mStw = MetricDef(
  'navigation.speedThroughWater',
  'STW',
  'kn',
  scale: 1.94384,
  color: cCyan,
);
const mHeading = MetricDef(
  'navigation.headingTrue',
  'Rumbo',
  '°',
  scale: 57.2957795,
  color: cText,
);
const mCog = MetricDef(
  'navigation.courseOverGroundTrue',
  'COG',
  '°',
  scale: 57.2957795,
  color: cPurple,
);

const defaultNavCardIds = ['sog', 'stw', 'heading', 'cog', 'depth', 'heel'];
const allNavCardIds = [
  'sog',
  'stw',
  'heading',
  'cog',
  'depth',
  'heel',
  'position',
  'gps',
  'ais',
  'time',
  'vmgWind',
  'vmgRoute',
  'appWind',
  'engineHours',
];

class NavCardData {
  const NavCardData({
    required this.id,
    required this.title,
    required this.value,
    required this.color,
    this.unit,
    this.subtitle,
    this.graphMetrics,
    this.trend,
    this.bigLines,
    this.aisName,
    this.aisCrossing,
  });

  final String id;
  final String title;
  final String value;
  final Color color;
  final String? unit;
  final String? subtitle;
  final List<MetricDef>? graphMetrics;
  final int? trend; // -1 down, 0 flat, 1 up — confirmed trend, not noise
  // When set, the card shows these as 2+ equal-size stacked lines instead
  // of the usual single giant `value` — for cards like AIS where CPA and
  // TCPA are equally important and neither should dominate the other.
  final List<String>? bigLines;
  // AIS only, used by the Premium card (the classic card ignores these):
  // kept separate from `subtitle` so a long vessel name truncates on its
  // own and never eats into the distance/bearing or crossing side text.
  final String? aisName;
  final String? aisCrossing; // 'POR PROA' | 'POR POPA' | null
}

// ─── Alarms ─────────────────────────────────────────────────────────────────
class SkZoneAlarmSetting {
  SkZoneAlarmSetting({this.enabled = true, this.sound = true});
  bool enabled;
  bool sound;

  Map<String, dynamic> toJson() => {'enabled': enabled, 'sound': sound};
  factory SkZoneAlarmSetting.fromJson(Map<String, dynamic> j) =>
      SkZoneAlarmSetting(
        enabled: j['enabled'] as bool? ?? true,
        sound: j['sound'] as bool? ?? true,
      );
}

// Custom (client-side) alarm types — evaluated against live SignalKModel
// values, independent of any Signal K server-side zone configuration.
const customAlarmTypes = [
  'depthBelow',
  'windAbove',
  'batteryVoltageBelow',
  'socBelow',
  'tempAbove',
  'tankBelow',
  'windForecastAbove',
];

String customAlarmTypeLabel(String type) => switch (type) {
  'depthBelow' => 'Profundidad menor de',
  'windAbove' => 'Viento (aparente) mayor de',
  'batteryVoltageBelow' => 'Batería menor de',
  'socBelow' => 'Batería (SOC) menor de',
  'tempAbove' => 'Temperatura mayor de',
  'tankBelow' => 'Algún tanque menor de',
  'windForecastAbove' => 'Viento previsto (6h) mayor de',
  _ => type,
};

String customAlarmTypeUnit(String type) => switch (type) {
  'depthBelow' => 'm',
  'windAbove' => 'kt',
  'batteryVoltageBelow' => 'V',
  'socBelow' => '%',
  'tempAbove' => '°C',
  'tankBelow' => '%',
  'windForecastAbove' => 'kt',
  _ => '',
};

// Signal K paths that 'tempAbove' deliberately never offers — exterior,
// interior and sea temperature already have their own display and aren't
// the kind of thing you'd want an audible alarm for.
const excludedTempAlarmPaths = {
  'environment.outside.temperature',
  'environment.interior.temperature',
  'environment.water.temperature',
};

// 'tempAbove' targets are real Signal K paths (e.g.
// "environment.fridge_1.temperature", "electrical.batteries.house.temperature")
// discovered live per boat, not a fixed list — this turns one into a
// readable label without needing any settings/discovery context, by
// pattern-matching the path text itself.
String tempAlarmTargetLabel(String path) {
  final p = path.toLowerCase();
  if (p == 'environment.rpi.cpu.temperature') return 'CPU (Raspberry Pi)';
  if (p.contains('bowthruster')) return 'Motor de proa';
  final battMatch = RegExp(r'^electrical\.batteries\.([^.]+)\.temperature$')
      .firstMatch(path);
  if (battMatch != null) return 'Batería (${battMatch.group(1)})';
  final fridgeNum = RegExp(r'fridge\D*(\d+)').firstMatch(p);
  if (fridgeNum != null) return 'Nevera ${fridgeNum.group(1)}';
  if (p.contains('fridge') || p.contains('nevera') || p.contains('freezer')) {
    return 'Nevera';
  }
  // Generic fallback: turn "environment.engine.temperature" into "Engine".
  final segs = path.split('.');
  final middle = segs.length > 2 ? segs.sublist(1, segs.length - 1) : segs;
  final words = middle.join(' ').replaceAll('_', ' ').split(' ');
  return words
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

class CustomAlarmRule {
  CustomAlarmRule({
    required this.id,
    required this.type,
    required this.threshold,
    this.target,
    this.enabled = true,
    this.sound = true,
  });
  final String id;
  String type;
  double threshold;
  String? target; // only meaningful for multi-sensor types like 'tempAbove'
  bool enabled;
  bool sound;

  String get label {
    final base =
        '${customAlarmTypeLabel(type)} $threshold ${customAlarmTypeUnit(type)}';
    return (type == 'tempAbove' && target != null)
        ? '${tempAlarmTargetLabel(target!)}: $base'
        : base;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'threshold': threshold,
    'target': target,
    'enabled': enabled,
    'sound': sound,
  };
  factory CustomAlarmRule.fromJson(Map<String, dynamic> j) {
    // Migrate the old fridge-only 'fridgeTempAbove' type (pre-1.4.13) to
    // 'tempAbove' + an explicit target, so an alarm saved before the
    // sensor picker existed doesn't show up as a broken raw type name.
    var type = j['type'] as String;
    var target = j['target'] as String?;
    if (type == 'fridgeTempAbove') {
      type = 'tempAbove';
      target ??= 'fridge1';
    }
    return CustomAlarmRule(
      id: j['id'] as String,
      type: type,
      threshold: (j['threshold'] as num).toDouble(),
      target: target,
      enabled: j['enabled'] as bool? ?? true,
      sound: j['sound'] as bool? ?? true,
    );
  }
}

// ─── Data models ──────────────────────────────────────────────────────────────
class SignalKModel {
  bool connected = false;
  String status = 'Sin conectar';
  DateTime? lastUpdate;
  // The vessel's own name, straight from Signal K (`vessels.self.name`) —
  // used anywhere the boat's name is shown (report headers, etc.) instead
  // of a hardcoded product name.
  String? vesselName;
  // Navigation/wind data must be recent to be trusted (unlike e.g. temperatures,
  // which change slowly and stay useful even a bit stale). Kept separate —
  // the wind instrument can die while GPS/compass keep updating, or vice versa,
  // so a single shared timestamp would mask a stale sensor as still-fresh.
  DateTime? navUpdate;
  DateTime? windUpdate;
  // Only set while a route/waypoint is active in Signal K — the server
  // simply stops emitting this path when there isn't one, so its own
  // staleness (vs. navUpdate) is what tells the VMG-to-waypoint card
  // "sin ruta" instead of showing a frozen old number.
  DateTime? courseUpdate;
  DateTime? positionUpdate;
  // Navigation
  double? latitude;
  double? longitude;
  double? sogKn;
  double? stwKn;
  double? headingTrueDeg;
  double? headingMagneticDeg;
  double? magneticVariationDeg;
  double? cogTrueDeg;
  // Each of these four also gets its own timestamp — navUpdate above is
  // shared by every navigation.* path, so a compass that dies while GPS
  // keeps emitting SOG/position deltas kept navUpdate ticking over and
  // heading read as "fresh" forever (the exact bug reported: heading
  // frozen at a real value since a specific time, never falling back to
  // COG because the shared timestamp masked it). These four feed that
  // fallback logic directly, so they need real per-field staleness.
  DateTime? sogKnUpdate;
  DateTime? stwKnUpdate;
  DateTime? headingTrueDegUpdate;
  DateTime? headingMagneticDegUpdate;
  DateTime? magneticVariationUpdate;
  DateTime? cogTrueDegUpdate;
  double? heelDeg;
  double? pitchDeg;
  // GNSS/GPS quality — separate from the position update timestamp above,
  // since these change far less often than lat/lon and shouldn't be marked
  // stale just because the receiver hasn't emitted a new fix-quality delta.
  int? gnssSatellites;
  double? gnssHdop;
  double? gnssAntennaAltitudeM;
  String? gnssFixType; // Signal K navigation.gnss.type, e.g. "GPS", "GNSS"
  String? gnssMethodQuality; // e.g. "no GPS", "GNSS Fix", "DGNSS Fix", "RTK fixed integer"
  // VMG to the active route/waypoint, straight from Signal K's own course
  // calculation (whatever plugin/core feature is computing the route) —
  // we don't derive this ourselves, unlike VMG-to-wind below.
  double? courseVmgKn;
  // Distancia y demora al waypoint activo, de la misma API de rumbo de
  // Signal K que publica el VMG de arriba. Aparecen cuando el plóter tiene
  // un GOTO y desaparecen al cancelarlo. Son lo que permite calcular el
  // tiempo real de una travesía de ceñida (ver computeLegEstimate).
  double? courseDistanceNm;
  double? courseBearingTrueDeg;
  // Environment
  double? depthM;
  // Dedicated, not the shared navUpdate — depth arrives through a
  // dynamic handler (_buildDynamicHandlers), which _routeValue dispatches
  // to and returns from BEFORE ever reaching the code that used to try to
  // stamp navUpdate for it, so that never actually ran. Without its own
  // timestamp, depth's "fresh" status silently depended on whatever OTHER
  // navigation.* path happened to be updating nearby — reading as fresh
  // forever if GPS/SOG kept flowing even after a real depth-sounder
  // dropout, or as stale even with a perfectly live depth feed if nothing
  // else on navUpdate happened to be moving. Reported live 2026-09-04.
  DateTime? depthMUpdate;
  double? waterTempK;
  double? outsideTempK;
  double? outsideHumidity; // 0-100 %
  double? outsidePressureHpa;
  double? indoorTempK;
  double? indoorHumidity; // 0-100 %
  double? cpuTempK;
  double? gpuTempK;
  double? cpuUtil; // 0-100 %
  double? memUtil; // 0-100 %
  double? sdUtil; // 0-100 %
  double? sonoffTempK;
  double? solarFusesTempK;
  double? fridge1TempK;
  double? fridge2TempK;
  // Wind
  double? awsKn;
  double? awaDeg;
  double? twaDeg;
  double? twaWaterDeg;
  double? twaGroundDeg;
  double? twsKn;
  double? twdDeg;
  DateTime? awsUpdate;
  DateTime? awaUpdate;
  DateTime? twaUpdate;
  DateTime? twaWaterUpdate;
  DateTime? twaGroundUpdate;
  DateTime? twsUpdate;
  DateTime? twdUpdate;
  // Power
  double? houseV;
  double? houseA;
  double? houseW;
  double? houseSoc; // 0-100 %
  double? houseTempK;
  double? solarW;
  double? solarW2;
  double? dcW;
  double? startV;
  double? bowthrusterV;
  double? engineHours; // hours, from propulsion.<id>.runTime (seconds)
  /// Última lectura vista del cuentahoras, con su fecha, guardada en
  /// disco. Un cuentahoras es acumulativo: solo puede subir, así que una
  /// lectura vieja sigue siendo cierta y enseñarla es mejor que un "--".
  /// Sin esto, bastaba con que el motor dejara de publicar (contacto
  /// quitado, bus apagado, reconexión) para que las horas desaparecieran
  /// de la pantalla ("tienes que dejar siempre las últimas que viste
  /// aunque sean antiguas", 2026-09-12).
  double? lastEngineHours;
  DateTime? lastEngineHoursAt;

  /// Cuándo se usó el motor por última vez y cuánto duró ese uso, deducido
  /// del propio cuentahoras: mientras el motor gira runTime sube, así que
  /// el último tramo en que subió ES el último uso. No hace falta ningún
  /// dato nuevo en el servidor, solo leer su histórico.
  DateTime? lastEngineRunAt;
  double? lastEngineRunHours;
  DateTime? engineHoursUpdate;
  // Real engine telemetry — siblings of enginePath under the same
  // propulsion.<id> base (see _buildDynamicHandlers), auto-registered
  // once the user picks the engine's runTime path in CFG > Sensores, no
  // separate configuration needed for each.
  double? engineRpm; // revolutions (Hz) × 60
  // Actual percent torque, same PGN 61444 (EEC1) frame as RPM — SPN 513.
  // informational (no alarm derived from it), shown only in the
  // "Completo" Motor panel.
  double? engineTorquePercent;
  double? engineCoolantTempK;
  double? engineOilPressurePa;
  double? engineAlternatorV;
  double? engineSupplyV;
  // Per-metric "last delta received" timestamps — each gauge goes stale
  // (needle to zero, "--" on its readout) independently 5s after its own
  // last update, same principle as navUpdate/windUpdate above: one sensor
  // dying shouldn't hide behind another still reporting. torquePercent
  // shares engineRpmUpdate — same PGN 61444 frame as RPM.
  DateTime? engineRpmUpdate;
  DateTime? engineCoolantTempUpdate;
  DateTime? engineOilPressureUpdate;
  DateTime? engineAlternatorVUpdate;
  DateTime? engineSupplyVUpdate;
  // Discrete DM1 fault bits (J1939 PGN 65226 — SPN 110/FMI 0, 100/FMI 1,
  // 167/FMI 1), if the bridge firmware ever decodes them; null while
  // unpublished, in which case the threshold comparison is used instead.
  bool? engineOverTempAlarm;
  bool? engineLowOilAlarm;
  bool? engineLowVoltAlarm;
  // "Last delta received" for the 3 flags above — a fault bit has no
  // natural "cleared" value the way a number reverting to normal does, so
  // without its own staleness a bridge that stops publishing (engine off,
  // bus/bridge disconnected) left whatever it last said sitting there
  // forever, including a real fault that's actually gone stale, not gone.
  DateTime? engineOverTempAlarmUpdate;
  DateTime? engineLowOilAlarmUpdate;
  DateTime? engineLowVoltAlarmUpdate;
  // Glow-plug/starter-relay circuit fault (PGN 65226 DM1 — SPN 677 or 724,
  // FMI 5: open circuit/current below normal). No numeric equivalent
  // exists, so unlike the 3 above there's no threshold fallback — stays
  // off until the bridge actually publishes a fault.
  bool? engineGlowPlugFaultAlarm;
  DateTime? engineGlowPlugFaultAlarmUpdate;
  // Preheat-in-progress status (PGN 65264 — SPN 1494, Glow Plug Relay
  // Status). Not an alarm, just the normal "still warming the glow plugs"
  // state — drives the 'precal' lamp in real (non-SIMUL) mode.
  bool? enginePreheatActive;
  DateTime? enginePreheatActiveUpdate;
  // Volvo MDI / J1939 diagnostic state. PGN 65417 is proprietary, so its
  // decoded switches are authoritative only when mappingVerified is true.
  bool? engineMdiDetected;
  bool? engineMdiMappingVerified;
  bool? engineDm1Available;
  bool? engineCheckAlarm;
  bool? engineStarting;
  bool? engineStopping;
  bool? engineSystemFault;
  bool? engineAuxiliaryFault;
  DateTime? engineDiagnosticUpdate;
  double? engineSourceAddress;
  double? engineActiveDtcCount;
  double? engineFirstDtcSpn;
  double? engineFirstDtcFmi;
  double? engineCanBitrateKbps;
  final engineMdiRawBytes = List<double?>.filled(8, null);
  // Bridge diagnostics (propulsion.<id>.volvoMdi.*) — PGN frames seen on
  // the bus but not decoded, shown in the "Completo" Motor panel.
  double? engineUnknownPgn;
  double? engineUnknownFrameCount;
  double? bowthrusterTempK;
  // Tanks (key = "type.id", e.g. "freshWater.24")
  final tanks = <String, double?>{};

  // Anchor watch (hoekens-anchor-alarm plugin) — armed state and live
  // geometry for the native Premium "Fondeado" anchor card, as opposed to
  // embedding the plugin's own webapp.
  String? anchorState; // navigation.anchor.state: "on" | "off"
  // Despite the name, these are the CONFIGURED watch radius (cfg.radiusM)
  // and its initial value — not a live distance. Kept only for the ring's
  // own fraction-of-radius fill; the card's actual "DISTANCIA" number
  // must read anchorDistanceFromBowM below instead. Mixing the two up
  // here — showing the (mostly constant) radius where the live distance
  // belonged — was a real bug, reported live 2026-09-06.
  double? anchorCurrentRadiusM;
  double? anchorMaxRadiusM;
  double? anchorApparentBearingDeg; // relative to the bow, not true north
  // The actual live distance/true bearing to the anchor — navigation.
  // anchor.distanceFromBow/bearingTrue were being PUBLISHED all along but
  // never subscribed to or read back anywhere on the client side.
  double? anchorDistanceFromBowM;
  double? anchorBearingTrueDeg;
  bool get anchorArmed => anchorState == 'on';

  // Wipes every live-data field back to "unknown" — called at the start of
  // each (re)connect (see _DashboardState._connectSignalK) so switching to
  // a different Signal K server, or even just reconnecting to the same
  // one, can never show a value that's actually left over from whatever
  // was connected before. Previously only `tanks` was cleared here, which
  // is how a stale STW/depth reading from a *previous* server could keep
  // showing forever on a new server that doesn't even publish those paths
  // — nothing was left to overwrite it with "--". Deliberately leaves
  // `connected`/`status` alone (the connection state machine owns those).
  void reset() {
    vesselName = null;
    navUpdate = null;
    windUpdate = null;
    courseUpdate = null;
    positionUpdate = null;
    sogKnUpdate = null;
    stwKnUpdate = null;
    headingTrueDegUpdate = null;
    headingMagneticDegUpdate = null;
    magneticVariationUpdate = null;
    cogTrueDegUpdate = null;
    awsUpdate = null;
    awaUpdate = null;
    twaUpdate = null;
    twsUpdate = null;
    twdUpdate = null;
    latitude = null;
    longitude = null;
    sogKn = null;
    stwKn = null;
    headingTrueDeg = null;
    headingMagneticDeg = null;
    magneticVariationDeg = null;
    cogTrueDeg = null;
    heelDeg = null;
    pitchDeg = null;
    gnssSatellites = null;
    gnssHdop = null;
    gnssAntennaAltitudeM = null;
    gnssFixType = null;
    gnssMethodQuality = null;
    courseVmgKn = null;
    courseDistanceNm = null;
    courseBearingTrueDeg = null;
    depthM = null;
    depthMUpdate = null;
    waterTempK = null;
    outsideTempK = null;
    outsideHumidity = null;
    outsidePressureHpa = null;
    indoorTempK = null;
    indoorHumidity = null;
    cpuTempK = null;
    gpuTempK = null;
    cpuUtil = null;
    memUtil = null;
    sdUtil = null;
    sonoffTempK = null;
    solarFusesTempK = null;
    fridge1TempK = null;
    fridge2TempK = null;
    awsKn = null;
    awaDeg = null;
    twaDeg = null;
    twaWaterDeg = null;
    twaGroundDeg = null;
    twsKn = null;
    twdDeg = null;
    houseV = null;
    houseA = null;
    houseW = null;
    houseSoc = null;
    houseTempK = null;
    solarW = null;
    solarW2 = null;
    dcW = null;
    startV = null;
    bowthrusterV = null;
    engineHours = null;
    // lastEngineHours NO se borra aquí: ver su propio comentario.
    engineRpm = null;
    engineTorquePercent = null;
    engineCoolantTempK = null;
    engineOilPressurePa = null;
    engineAlternatorV = null;
    engineSupplyV = null;
    engineRpmUpdate = null;
    engineHoursUpdate = null;
    engineCoolantTempUpdate = null;
    engineOilPressureUpdate = null;
    engineAlternatorVUpdate = null;
    engineSupplyVUpdate = null;
    engineOverTempAlarm = null;
    engineLowOilAlarm = null;
    engineLowVoltAlarm = null;
    engineOverTempAlarmUpdate = null;
    engineLowOilAlarmUpdate = null;
    engineLowVoltAlarmUpdate = null;
    engineGlowPlugFaultAlarm = null;
    engineGlowPlugFaultAlarmUpdate = null;
    enginePreheatActive = null;
    enginePreheatActiveUpdate = null;
    engineMdiDetected = null;
    engineMdiMappingVerified = null;
    engineDm1Available = null;
    engineCheckAlarm = null;
    engineStarting = null;
    engineStopping = null;
    engineSystemFault = null;
    engineAuxiliaryFault = null;
    engineDiagnosticUpdate = null;
    engineSourceAddress = null;
    engineActiveDtcCount = null;
    engineFirstDtcSpn = null;
    engineFirstDtcFmi = null;
    engineCanBitrateKbps = null;
    for (var i = 0; i < engineMdiRawBytes.length; i++) {
      engineMdiRawBytes[i] = null;
    }
    engineUnknownPgn = null;
    engineUnknownFrameCount = null;
    bowthrusterTempK = null;
    tanks.clear();
    anchorState = null;
    anchorCurrentRadiusM = null;
    anchorMaxRadiusM = null;
    anchorApparentBearingDeg = null;
    anchorDistanceFromBowM = null;
    anchorBearingTrueDeg = null;
  }
}

// ─── Per-boat sensor configuration (paths vary boat to boat) ─────────────────
class TankSlot {
  TankSlot({
    required this.type,
    required this.id,
    required this.groupLabel,
    required this.capacityL,
    this.enabled = true,
    this.warningPct,
    this.alarmPct,
    this.calibrated = false,
    this.displayType,
  });
  String type; // 'freshWater' | 'fuel' | 'blackWater' | ...
  // Tipo con el que se PINTA (icono, color, nombre de categoría, orden y
  // agrupación), cuando no coincide con el que trae la ruta de Signal K.
  //
  // Hace falta porque `type` forma parte del path y no se puede cambiar
  // sin dejar de leer el dato. El caso real: signalk-venus-plugin solo
  // traduce los tipos de fluido 0-5 de Victron, así que una bombona de
  // gas (tipo 8) llega como `tanks.unknown.32` por mucho que en el Venus
  // esté puesta como LPG. Con esto se marca como 'lpg' en CFG y se ve
  // como tal, sin tocar el servidor ni perder el histórico de la ruta.
  String? displayType;
  // El tipo a efectos de presentación. Todo lo visual debe usar esto;
  // solo skPath/tankKey siguen usando `type`.
  String get kind => displayType ?? type;
  String id; // Signal K instance id
  String groupLabel; // tanks sharing the same label are averaged into one card
  int capacityL;
  bool enabled;
  double? warningPct;
  double? alarmPct;
  bool calibrated;
  String get skPath => 'tanks.$type.$id.currentLevel';
  String get tankKey => '$type.$id';

  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'groupLabel': groupLabel,
    'capacityL': capacityL,
    'enabled': enabled,
    'warningPct': warningPct,
    'alarmPct': alarmPct,
    'calibrated': calibrated,
    'displayType': displayType,
  };
  factory TankSlot.fromJson(Map<String, dynamic> j) => TankSlot(
    type: j['type'] as String,
    id: j['id'] as String,
    groupLabel: j['groupLabel'] as String,
    capacityL: j['capacityL'] as int,
    enabled: j['enabled'] as bool? ?? true,
    warningPct: (j['warningPct'] as num?)?.toDouble(),
    alarmPct: (j['alarmPct'] as num?)?.toDouble(),
    calibrated: j['calibrated'] as bool? ?? false,
    displayType: j['displayType'] as String?,
  );
}

class SensorConfig {
  // Plain SensorConfig() defaults to THIS boat's actual known-good sensor
  // ids/paths — appropriate the first time the app ever runs, but very
  // wrong to silently reuse when switching to a DIFFERENT, unconfigured
  // Signal K server (CFG → Admin) — that would show REWIND's tank/battery
  // ids as if they were real readings on someone else's boat. This gives a
  // genuinely blank starting point instead, so an unconfigured server just
  // shows "no data" until someone runs "Configurar sensores" for it.
  factory SensorConfig.empty() => SensorConfig()
    ..batteryHouseId = ''
    ..batteryStartId = ''
    ..solarPath = null
    ..solarPath2 = null
    ..fridge1Path = null
    ..fridge2Path = null
    ..depthPath = null
    ..enginePath = null
    ..tanks = [];

  SensorConfig();

  String batteryHouseId = '278';
  String batteryStartId = '278-second';
  double batteryHouseCapacityAh = 0;
  String? solarPath = 'electrical.venus.totalPanelPower';
  // Optional second solar controller — when set, the PWR card shows both
  // panels' individual output plus the sum as "total"; with just the one
  // (solarPath2 null, the common case) that single value already reads as
  // the total, unchanged from before.
  String? solarPath2;
  String? fridge1Path = 'environment.fridge_1.temperature';
  String? fridge2Path = 'environment.fridge_2.temperature';
  String fridge1Label = 'Nevera 1';
  String fridge1Location = 'tapa';
  String fridge2Label = 'Nevera 2';
  String fridge2Location = 'puerta';
  double sonoffWarnC = 45;
  double sonoffAlarmC = 60;
  double solarFusesWarnC = 45;
  double solarFusesAlarmC = 60;
  double fridgeWarnC = 6;
  double fridgeAlarmC = 10;
  String? depthPath = 'environment.depth.belowKeel';
  // Signal K's standard cumulative engine run time, e.g.
  // "propulsion.main.runTime" — seconds since the engine's counter started.
  String? enginePath;
  // Perfil de consumo estimado. Se guarda dentro de SensorConfig para que sea
  // propio de cada barco/servidor, igual que el path de su motor.
  String engineModelId = '';
  String engineDriveType = '';
  String enginePropellerType = '';
  double engineFuelCalibrationPercent = 100;
  bool hasOutsideTemp = true;
  bool hasOutsidePressure = true;
  List<TankSlot> tanks = [
    TankSlot(type: 'fuel', id: '27', groupLabel: 'Diésel 1', capacityL: 180),
    TankSlot(type: 'fuel', id: '26', groupLabel: 'Diésel 2', capacityL: 180),
    TankSlot(
      type: 'freshWater',
      id: '24',
      groupLabel: 'Agua Stbd',
      capacityL: 276,
    ),
    TankSlot(
      type: 'freshWater',
      id: '25',
      groupLabel: 'Agua Port',
      capacityL: 195,
    ),
    TankSlot(
      type: 'blackWater',
      id: '30',
      groupLabel: 'Black water 1',
      capacityL: 80,
    ),
    TankSlot(
      type: 'blackWater',
      id: '31',
      groupLabel: 'Black water 2',
      capacityL: 80,
    ),
  ];

  Map<String, dynamic> toJson() => {
    'batteryHouseId': batteryHouseId,
    'batteryStartId': batteryStartId,
    'batteryHouseCapacityAh': batteryHouseCapacityAh,
    'solarPath': solarPath,
    'solarPath2': solarPath2,
    'fridge1Path': fridge1Path,
    'fridge2Path': fridge2Path,
    'fridge1Label': fridge1Label,
    'fridge1Location': fridge1Location,
    'fridge2Label': fridge2Label,
    'fridge2Location': fridge2Location,
    'sonoffWarnC': sonoffWarnC,
    'sonoffAlarmC': sonoffAlarmC,
    'solarFusesWarnC': solarFusesWarnC,
    'solarFusesAlarmC': solarFusesAlarmC,
    'fridgeWarnC': fridgeWarnC,
    'fridgeAlarmC': fridgeAlarmC,
    'depthPath': depthPath,
    'enginePath': enginePath,
    'engineModelId': engineModelId,
    'engineDriveType': engineDriveType,
    'enginePropellerType': enginePropellerType,
    'engineFuelCalibrationPercent': engineFuelCalibrationPercent,
    'hasOutsideTemp': hasOutsideTemp,
    'hasOutsidePressure': hasOutsidePressure,
    'tanks': [for (final t in tanks) t.toJson()],
  };

  static SensorConfig fromJson(Map<String, dynamic> j) {
    final c = SensorConfig();
    c.batteryHouseId = j['batteryHouseId'] as String? ?? c.batteryHouseId;
    c.batteryStartId = j['batteryStartId'] as String? ?? c.batteryStartId;
    c.batteryHouseCapacityAh =
        (j['batteryHouseCapacityAh'] as num?)?.toDouble() ??
        c.batteryHouseCapacityAh;
    c.solarPath = j['solarPath'] as String?;
    c.solarPath2 = j['solarPath2'] as String?;
    c.fridge1Path = j['fridge1Path'] as String?;
    c.fridge2Path = j['fridge2Path'] as String?;
    c.fridge1Label = j['fridge1Label'] as String? ?? c.fridge1Label;
    c.fridge1Location = j['fridge1Location'] as String? ?? c.fridge1Location;
    c.fridge2Label = j['fridge2Label'] as String? ?? c.fridge2Label;
    c.fridge2Location = j['fridge2Location'] as String? ?? c.fridge2Location;
    c.sonoffWarnC = (j['sonoffWarnC'] as num?)?.toDouble() ?? c.sonoffWarnC;
    c.sonoffAlarmC = (j['sonoffAlarmC'] as num?)?.toDouble() ?? c.sonoffAlarmC;
    c.solarFusesWarnC =
        (j['solarFusesWarnC'] as num?)?.toDouble() ?? c.solarFusesWarnC;
    c.solarFusesAlarmC =
        (j['solarFusesAlarmC'] as num?)?.toDouble() ?? c.solarFusesAlarmC;
    c.fridgeWarnC = (j['fridgeWarnC'] as num?)?.toDouble() ?? c.fridgeWarnC;
    c.fridgeAlarmC = (j['fridgeAlarmC'] as num?)?.toDouble() ?? c.fridgeAlarmC;
    c.depthPath = j['depthPath'] as String?;
    c.enginePath = j['enginePath'] as String?;
    c.engineModelId = j['engineModelId'] as String? ?? '';
    c.engineDriveType = j['engineDriveType'] as String? ?? '';
    c.enginePropellerType = j['enginePropellerType'] as String? ?? '';
    c.engineFuelCalibrationPercent =
        ((j['engineFuelCalibrationPercent'] as num?)?.toDouble() ?? 100)
            .clamp(70, 130)
            .toDouble();
    c.hasOutsideTemp = j['hasOutsideTemp'] as bool? ?? true;
    c.hasOutsidePressure = j['hasOutsidePressure'] as bool? ?? true;
    final rawTanks = j['tanks'];
    if (rawTanks is List) {
      c.tanks = [
        for (final t in rawTanks) TankSlot.fromJson(t as Map<String, dynamic>),
      ];
    }
    return c;
  }
}

// ─── Native anchor watch (ANC) — replaces the embedded hoekens-anchor-alarm
// webview entirely. State lives here instead of on the Signal K server (the
// plugin's `zone`/`on` config), so the watch works even if that plugin is
// gone or misconfigured — no PUT to Signal K, no dependency on it at all.
class AnchorConfig {
  bool armed = false;
  double? dropLat;
  double? dropLon;
  DateTime? droppedAt;
  // Optional window from a recently completed anchorage that the user
  // explicitly chose to reuse after lifting and dropping again in the same
  // place. The new droppedAt remains untouched so alarm grace periods and
  // elapsed-time checks still describe the current anchorage honestly.
  DateTime? reusedTrackFrom;
  DateTime? reusedTrackUntil;
  // Depth at the moment of dropping — the reference point for the depth
  // "swing" alarm (settings.alarmAnchorDepthEnabled), not an absolute
  // threshold.
  double? dropDepthM;
  double radiusM = 30;
  // Chain actually paid out for THIS anchoring — distinct from the boat's
  // fixed total chain length (settings.anchorTotalChainLengthM, published
  // as design.* and unrelated to any specific drop). Asked directly when
  // using "Recolocar" (reported live 2026-09-04: using the boat's total
  // chain length gave a wildly-too-large radius when only a fraction of
  // it was actually let out) since it can change mid-anchorage as more or
  // less chain is paid out or recovered.
  double? chainOutM;
  // The radius set on drop (or last manually confirmed via the "Radio"
  // handle) — radiusM itself may grow past this automatically to keep the
  // watch circle around the boat, and shrinks back to this baseline once
  // the boat is close enough to the anchor again to fit inside it.
  double? initialRadiusM;
  // Set on arm and on every confirmed anchor-position change — the drag
  // alarm ignores "outside the zone" for a short grace window afterward,
  // so repositioning the anchor (or the sector) outside where the boat
  // currently sits doesn't immediately alarm on the edit itself.
  DateTime? armedOrMovedAt;
  String shape = 'circle'; // 'circle' or 'sector'
  double? sectorStartDeg; // only meaningful when shape == 'sector'
  double? sectorEndDeg;
  // Layer toggles — mirrors the show/hide checkboxes the hoekens plugin
  // offered, so switching to the native screen isn't a step down.
  bool showWind = true;
  bool showDepth = true;
  // Off by default — a minority-interest panel, not something everyone
  // wants cluttering the screen on every anchor drop.
  bool showScope = false;
  bool showAisNearby = true;
  bool showOwnTrack = true;
  // Independent checkboxes, not exclusive — satellite + OpenSeaMap
  // together is a legitimate hybrid (imagery with nautical marks on top),
  // and both off just means a plain background, not an invalid state.
  bool showSatelliteLayer = true;
  bool showSeamarkLayer = false;
  List<int> scopeRatios = [7, 5, 4, 3];
  // Past anchorages (drop → raise), most recent last — mirrors the
  // hoekens plugin's own history view. Capped in _raiseAnchor's append so
  // this doesn't grow unbounded across a season.
  List<AnchorHistoryEntry> history = [];

  Map<String, dynamic> toJson() => {
    'armed': armed,
    'dropLat': dropLat,
    'dropLon': dropLon,
    'dropDepthM': dropDepthM,
    'droppedAt': droppedAt?.toIso8601String(),
    'reusedTrackFrom': reusedTrackFrom?.toIso8601String(),
    'reusedTrackUntil': reusedTrackUntil?.toIso8601String(),
    'radiusM': radiusM,
    'chainOutM': chainOutM,
    'initialRadiusM': initialRadiusM,
    'armedOrMovedAt': armedOrMovedAt?.toIso8601String(),
    'shape': shape,
    'sectorStartDeg': sectorStartDeg,
    'sectorEndDeg': sectorEndDeg,
    'showWind': showWind,
    'showDepth': showDepth,
    'showScope': showScope,
    'showAisNearby': showAisNearby,
    'showOwnTrack': showOwnTrack,
    'showSatelliteLayer': showSatelliteLayer,
    'showSeamarkLayer': showSeamarkLayer,
    'scopeRatios': scopeRatios,
    'history': history.map((e) => e.toJson()).toList(),
  };

  static AnchorConfig fromJson(Map<String, dynamic> j) {
    final c = AnchorConfig();
    c.armed = j['armed'] as bool? ?? false;
    c.dropLat = (j['dropLat'] as num?)?.toDouble();
    c.dropLon = (j['dropLon'] as num?)?.toDouble();
    c.dropDepthM = (j['dropDepthM'] as num?)?.toDouble();
    final droppedAtStr = j['droppedAt'] as String?;
    c.droppedAt = droppedAtStr == null ? null : DateTime.tryParse(droppedAtStr);
    final reusedTrackFromStr = j['reusedTrackFrom'] as String?;
    final reusedTrackUntilStr = j['reusedTrackUntil'] as String?;
    c.reusedTrackFrom = reusedTrackFromStr == null
        ? null
        : DateTime.tryParse(reusedTrackFromStr);
    c.reusedTrackUntil = reusedTrackUntilStr == null
        ? null
        : DateTime.tryParse(reusedTrackUntilStr);
    c.radiusM = (j['radiusM'] as num?)?.toDouble() ?? c.radiusM;
    c.chainOutM = (j['chainOutM'] as num?)?.toDouble();
    c.initialRadiusM = (j['initialRadiusM'] as num?)?.toDouble();
    final armedOrMovedAtStr = j['armedOrMovedAt'] as String?;
    c.armedOrMovedAt = armedOrMovedAtStr == null
        ? null
        : DateTime.tryParse(armedOrMovedAtStr);
    c.shape = j['shape'] as String? ?? c.shape;
    c.sectorStartDeg = (j['sectorStartDeg'] as num?)?.toDouble();
    c.sectorEndDeg = (j['sectorEndDeg'] as num?)?.toDouble();
    c.showWind = j['showWind'] as bool? ?? true;
    c.showDepth = j['showDepth'] as bool? ?? true;
    c.showScope = j['showScope'] as bool? ?? false;
    c.showAisNearby = j['showAisNearby'] as bool? ?? true;
    c.showOwnTrack = j['showOwnTrack'] as bool? ?? true;
    // Migrates the old exclusive 'baseLayer' string (satellite/seamark/
    // none) if present, otherwise reads the new independent checkboxes.
    final legacyBaseLayer = j['baseLayer'] as String?;
    if (legacyBaseLayer != null) {
      c.showSatelliteLayer = legacyBaseLayer == 'satellite';
      c.showSeamarkLayer = legacyBaseLayer == 'seamark';
    } else {
      c.showSatelliteLayer = j['showSatelliteLayer'] as bool? ?? true;
      c.showSeamarkLayer = j['showSeamarkLayer'] as bool? ?? false;
    }
    final rawRatios = j['scopeRatios'];
    if (rawRatios is List) {
      c.scopeRatios = rawRatios.map((e) => (e as num).toInt()).toList();
    }
    final rawHistory = j['history'];
    if (rawHistory is List) {
      c.history = rawHistory
          .whereType<Map>()
          .map((e) => AnchorHistoryEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return c;
  }
}

// One completed anchorage: drop → raise.
class AnchorHistoryEntry {
  AnchorHistoryEntry({
    required this.droppedAt,
    required this.raisedAt,
    required this.lat,
    required this.lon,
    required this.radiusM,
    this.depthM,
  });
  final DateTime droppedAt;
  final DateTime raisedAt;
  final double lat;
  final double lon;
  final double radiusM;
  final double? depthM;

  Map<String, dynamic> toJson() => {
    'droppedAt': droppedAt.toIso8601String(),
    'raisedAt': raisedAt.toIso8601String(),
    'lat': lat,
    'lon': lon,
    'radiusM': radiusM,
    'depthM': depthM,
  };

  static AnchorHistoryEntry fromJson(Map<String, dynamic> j) =>
      AnchorHistoryEntry(
        droppedAt:
            DateTime.tryParse(j['droppedAt'] as String? ?? '') ??
            DateTime.now(),
        raisedAt:
            DateTime.tryParse(j['raisedAt'] as String? ?? '') ?? DateTime.now(),
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        radiusM: (j['radiusM'] as num).toDouble(),
        depthM: (j['depthM'] as num?)?.toDouble(),
      );
}

// ─── Signal K path discovery (used by CFG > Sensores) ────────────────────────
class TankCandidate {
  TankCandidate({
    required this.type,
    required this.id,
    this.capacityL,
    this.name,
  });
  final String type;
  final String id;
  final int? capacityL;
  // Signal K's own tanks.<type>.<id>.name, when published — "el nombre de
  // los tanques tienes que cogerlo de signalk con el sufijo .name"
  // (reported live 2026-09-04). Null when the device never publishes one.
  final String? name;
}

class SkDiscovery {
  final List<String> batteryIds = [];
  // id -> Signal K's own electrical.batteries.<id>.name, when the device
  // publishes one (lowercased) — used to guess house vs. start battery on
  // "Buscar sensores" instead of leaving both blank. See
  // _SensorConfigDialog._discoverNow's _guessBatteryRole.
  final Map<String, String> batteryNames = {};
  final List<String> solarPaths = [];
  // Subset of solarPaths that are an actual per-controller TOTAL (e.g.
  // electrical.solar.0.panelPower, electrical.venus.totalPanelPower) as
  // opposed to one individual panel's own reading (e.g.
  // electrical.solar.0.1.panelPower, one extra segment) — only these are
  // valid solarPath/solarPath2 candidates, since picking an individual
  // panel's path would silently report just that one panel's output
  // instead of the controller's real total. "analiza primero el numero de
  // paneles... electrical.solar.?.?.panelpower para los individuales y
  // electrical.solar.?.panelpower para el total" (reported live
  // 2026-09-04).
  final List<String> solarTotalPaths = [];
  // Nombre publicado por cada ruta de solarTotalPaths (minúsculas), cuando
  // el dispositivo publica uno. Sirve para distinguir un controlador real
  // de un AGREGADO que llega por la misma forma de ruta: en REWIND,
  // electrical.solar.100 se llama "BLE Solar PORT+STBD" y suma los dos
  // controladores, así que elegirlo junto a otro total contaría los mismos
  // paneles dos veces. Ver solarControllerPathsPreferred.
  final Map<String, String> solarPathNames = {};

  /// solarTotalPaths ordenado poniendo delante los CONTROLADORES reales y
  /// dejando al final los agregados.
  ///
  /// Con dos controladores hay que coger los dos panelPower individuales,
  /// no un total ("si hay dos controladores tiene que coger los dos
  /// panelpower no el total", 2026-09-08): un total ya incluye a ambos, y
  /// combinarlo con otra ruta suma los mismos paneles dos veces. Un
  /// agregado se reconoce por dos vías, porque ninguna basta sola:
  /// - la propia ruta lo dice (`totalPanelPower`, o cuelga de `venus`,
  ///   que es el sumario del Cerbo, no un cargador);
  /// - o lo dice su nombre (el "PORT+STBD" del ejemplo), única pista
  ///   cuando la ruta es idéntica en forma a la de un controlador.
  List<String> get solarControllerPathsPreferred {
    bool isAggregate(String path) {
      final p = path.toLowerCase();
      if (p.contains('totalpanelpower') || p.startsWith('electrical.venus.')) {
        return true;
      }
      final name = solarPathNames[path] ?? '';
      return name.contains('+') ||
          name.contains('total') ||
          name.contains('todos') ||
          name.contains('both');
    }

    final controllers = solarTotalPaths.where((p) => !isAggregate(p)).toList();
    final aggregates = solarTotalPaths.where(isAggregate).toList();
    return [...controllers, ...aggregates];
  }

  final List<String> fridgePaths = [];
  final List<String> depthPaths = [];
  final List<String> enginePaths = [];
  final List<TankCandidate> tanks = [];
  final List<String> allPaths = [];
  bool hasOutsideTemp = false;
  bool hasOutsidePressure = false;
}

class ForecastPoint {
  ForecastPoint({
    required this.time,
    this.tempC,
    this.rainPct,
    this.rainMm,
    this.windKn,
    this.gustKn,
    this.windDirDeg,
    this.weatherCode,
  });
  final DateTime time;
  final double? tempC, rainPct, rainMm, windKn, gustKn, windDirDeg;
  final int? weatherCode;

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    'temp': tempC,
    'rain': rainPct,
    'rainMm': rainMm,
    'wind': windKn,
    'gust': gustKn,
    'dir': windDirDeg,
    'code': weatherCode,
  };
  static ForecastPoint fromJson(Map<String, dynamic> j) => ForecastPoint(
    time: DateTime.parse(j['t'] as String),
    tempC: (j['temp'] as num?)?.toDouble(),
    rainPct: (j['rain'] as num?)?.toDouble(),
    rainMm: (j['rainMm'] as num?)?.toDouble(),
    windKn: (j['wind'] as num?)?.toDouble(),
    gustKn: (j['gust'] as num?)?.toDouble(),
    windDirDeg: (j['dir'] as num?)?.toDouble(),
    weatherCode: (j['code'] as num?)?.toInt(),
  );
}

class MarinePoint {
  MarinePoint({
    required this.time,
    this.waveM,
    this.waveDir,
    this.wavePeriod,
    this.swellM,
    this.swellDir,
    this.swellPeriod,
    this.windWaveM,
    this.windWaveDir,
    this.windWavePeriod,
    this.seaTempC,
    this.currentKmh,
    this.currentDir,
  });
  final DateTime time;
  final double? waveM,
      waveDir,
      wavePeriod,
      swellM,
      swellDir,
      swellPeriod,
      windWaveM,
      windWaveDir,
      windWavePeriod,
      seaTempC,
      currentKmh,
      currentDir;

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    'wave': waveM,
    'waveDir': waveDir,
    'wavePeriod': wavePeriod,
    'swell': swellM,
    'swellDir': swellDir,
    'swellPeriod': swellPeriod,
    'windWave': windWaveM,
    'windWaveDir': windWaveDir,
    'windWavePeriod': windWavePeriod,
    'seaTemp': seaTempC,
    'current': currentKmh,
    'currentDir': currentDir,
  };
  static MarinePoint fromJson(Map<String, dynamic> j) => MarinePoint(
    time: DateTime.parse(j['t'] as String),
    waveM: (j['wave'] as num?)?.toDouble(),
    waveDir: (j['waveDir'] as num?)?.toDouble(),
    wavePeriod: (j['wavePeriod'] as num?)?.toDouble(),
    swellM: (j['swell'] as num?)?.toDouble(),
    swellDir: (j['swellDir'] as num?)?.toDouble(),
    swellPeriod: (j['swellPeriod'] as num?)?.toDouble(),
    windWaveM: (j['windWave'] as num?)?.toDouble(),
    windWaveDir: (j['windWaveDir'] as num?)?.toDouble(),
    windWavePeriod: (j['windWavePeriod'] as num?)?.toDouble(),
    seaTempC: (j['seaTemp'] as num?)?.toDouble(),
    currentKmh: (j['current'] as num?)?.toDouble(),
    currentDir: (j['currentDir'] as num?)?.toDouble(),
  );
}

// ─── Weather model comparison (PRON > Comparar modelos) ──────────────────────
class ModelSeries {
  const ModelSeries({
    required this.id,
    required this.label,
    required this.color,
  });
  final String id;
  final String label;
  final Color color;
}

// Free Open-Meteo models, no API key. Unknown/unsupported ids for a given
// location just come back empty and are skipped, so it's safe to list several.
const weatherModels = [
  ModelSeries(id: 'gfs_seamless', label: 'GFS', color: cCyan),
  ModelSeries(id: 'ecmwf_ifs025', label: 'ECMWF', color: cOrange),
  ModelSeries(id: 'icon_eu', label: 'ICON-EU', color: cGreen),
  ModelSeries(id: 'arpege_europe', label: 'ARPEGE', color: cPurple),
  ModelSeries(id: 'gem_seamless', label: 'GEM', color: cYellow),
];

// ─── AIS targets (MAP > swipe down) ───────────────────────────────────────────
class AisTarget {
  AisTarget(this.context);
  final String context; // e.g. 'vessels.urn:mrn:imo:mmsi:123456789'
  String? mmsi;
  String? name;
  double? lat, lon;
  double? cogDeg;
  double? sogKn;
  int? shipTypeId; // AIS ship type code, e.g. 70 = cargo, 80 = tanker
  DateTime? lastUpdate;
  DateTime? positionUpdate;
  DateTime? cogUpdate;
  DateTime? sogUpdate;
  // Provided by a Signal K collision-alert plugin (navigation.closestApproach.*),
  // if installed — preferred over our own client-side CPA geometry when
  // present AND recent (see pluginCpaUpdate). NOT gated by the target's
  // own shared `lastUpdate` above — that refreshes on ANY field (name,
  // position, mmsi, ...), so if the collision plugin itself stopped
  // publishing while ordinary AIS reception for this target kept going,
  // lastUpdate stayed fresh while these three quietly froze at a stale
  // prediction that would otherwise keep winning over a fresh local
  // calculation forever. Reported live 2026-09-04.
  double? pluginCpaNm;
  double? pluginTcpaMin;
  double? pluginCpaBearingDeg;
  DateTime? pluginCpaUpdate;
  DateTime? pluginCpaDistanceUpdate;
  DateTime? pluginTcpaUpdate;
  DateTime? pluginCpaBearingUpdate;
  // Rolling 1h position history for the optional on-screen track.
  final List<({DateTime t, double lat, double lon})> track = [];
  void recordTrackPoint() {
    final la = lat, lo = lon;
    if (la == null || lo == null) return;
    final now = DateTime.now();
    if (track.isNotEmpty &&
        now.difference(track.last.t) < const Duration(seconds: 15)) {
      return;
    }
    track.add((t: now, lat: la, lon: lo));
    track.removeWhere((p) => now.difference(p.t) > const Duration(hours: 1));
  }
}

// Own-boat position trail for the native anchor watch — same shape/rules as
// AisTarget.track above (min spacing, rolling window), just not tied to a
// specific AIS target since it's our own position.
class AnchorTrackPoint {
  const AnchorTrackPoint(this.t, this.lat, this.lon);
  final DateTime t;
  final double lat;
  final double lon;
}

// ─── Estado de baterías sin shunt (arranque / propulsor de proa) ─────────
//
// Estas dos viven permanentemente en FLOTACIÓN: el cargador impone el
// voltaje (~13,2-13,8 V en plomo), así que no dice nada del estado de
// carga — 13,5 V solo significa "el cargador está haciendo su trabajo".
// Traducir eso a un porcentaje con la curva de reposo es inventar un dato
// ("bow y arranque damos por hecho que están en flotación", 2026-09-08).
//
// Lo que sí se puede medir sin shunt es la CAÍDA BAJO CARGA: al arrancar
// el motor, o al usar el propulsor, la batería entrega cientos de amperios
// unos segundos y el voltaje se hunde. Cuánto se hunde, y cuánto tarda en
// recuperarse, es la prueba de estado clásica y vale mucho más que el SOC.

/// Un episodio de carga fuerte: arranque del motor o uso del propulsor.
class BatteryLoadEvent {
  const BatteryLoadEvent({
    required this.at,
    required this.restingV,
    required this.minV,
    required this.recoverySeconds,
  });

  final DateTime at;

  /// Voltaje justo antes del esfuerzo (referencia de la que cayó).
  final double restingV;

  /// Mínimo alcanzado. Es el indicador principal de salud.
  final double minV;

  /// Segundos hasta recuperar casi todo el voltaje de partida. Una batería
  /// sana vuelve casi al instante; una cansada se queda baja. Distingue
  /// "pico normal" de "batería gastada".
  final int recoverySeconds;

  double get dropV => restingV - minV;

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'restingV': restingV,
    'minV': minV,
    'recoverySeconds': recoverySeconds,
  };

  factory BatteryLoadEvent.fromJson(Map<String, dynamic> j) => BatteryLoadEvent(
    at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
    restingV: (j['restingV'] as num?)?.toDouble() ?? 0,
    minV: (j['minV'] as num?)?.toDouble() ?? 0,
    recoverySeconds: (j['recoverySeconds'] as num?)?.toInt() ?? 0,
  );
}

/// ¿Está el cargador imponiendo el voltaje ahora mismo?
///
/// Se puede distinguir con fiabilidad porque los rangos NO se solapan: una
/// batería de plomo llena en reposo da ~12,7 V, y flotación son ~13,2-13,8
/// V. Por encima del umbral el porcentaje no debe mostrarse; por debajo y
/// estable, la curva de reposo sí es válida.
bool batteryOnFloat(double? volts) => volts != null && volts >= 13.0;

/// Detecta episodios de carga fuerte a partir del voltaje.
///
/// No necesita saber cuándo arrancas ni cuándo usas el propulsor: el
/// hundimiento del voltaje lo delata solo. La app se suscribe con política
/// `instant` (sin promediar), así que recibe cada cambio que publique el
/// servidor; con qué resolución se capta el valle depende del ritmo al que
/// lo publique el Cerbo.
class BatteryLoadWatcher {
  BatteryLoadWatcher({this.dropThresholdV = 0.6, this.maxEvents = 20});

  /// Caída mínima respecto al nivel previo para considerarlo un esfuerzo y
  /// no ruido de medida. Un arranque hunde varios voltios; el ruido normal
  /// de un BLE está muy por debajo de esto.
  final double dropThresholdV;
  final int maxEvents;

  final List<BatteryLoadEvent> events = [];

  double? _baseline; // nivel estable antes del esfuerzo
  double? _minV; // mínimo del episodio en curso
  DateTime? _startedAt;

  /// Alimenta una lectura. Devuelve el evento si acaba de cerrarse uno.
  BatteryLoadEvent? add(double? volts, DateTime at) {
    if (volts == null || !volts.isFinite || volts <= 0) return null;
    final base = _baseline;
    if (base == null) {
      _baseline = volts;
      return null;
    }
    if (_startedAt == null) {
      if (base - volts >= dropThresholdV) {
        // Empieza el esfuerzo.
        _startedAt = at;
        _minV = volts;
      } else {
        // En reposo: la referencia sigue al voltaje, pero solo hacia
        // ARRIBA de golpe y hacia abajo despacio, para que una bajada
        // lenta (consumo normal) no se coma el umbral y acabe ocultando
        // un esfuerzo real.
        _baseline = volts > base ? volts : base - (base - volts) * 0.05;
      }
      return null;
    }
    if (volts < (_minV ?? volts)) _minV = volts;
    // Recuperado: vuelve a menos de un tercio de la caída que lo disparó.
    if (volts >= base - dropThresholdV / 3) {
      final event = BatteryLoadEvent(
        at: _startedAt!,
        restingV: base,
        minV: _minV ?? volts,
        recoverySeconds: at.difference(_startedAt!).inSeconds,
      );
      _startedAt = null;
      _minV = null;
      _baseline = volts;
      events.add(event);
      if (events.length > maxEvents) events.removeAt(0);
      return event;
    }
    return null;
  }

  BatteryLoadEvent? get last => events.isEmpty ? null : events.last;

  List<Map<String, dynamic>> toJson() => [for (final e in events) e.toJson()];

  void loadJson(List<dynamic> raw) {
    events
      ..clear()
      ..addAll(
        raw.whereType<Map<String, dynamic>>().map(BatteryLoadEvent.fromJson),
      );
  }
}

/// Viento aparente a partir del real y la velocidad del barco.
///
/// El DEMO fabricaba AWS/AWA y TWS/TWA como oscilaciones independientes, y
/// salían combinaciones que no existen en el mar (aparente menor que el
/// real navegando de ceñida, por ejemplo). Con esto el escenario define
/// solo el viento real y el aparente sale de la geometría, como en el
/// barco: el vector del viento real más el vector de la marcha.
///
/// [twaDeg] y el AWA devuelto son relativos a proa, con el signo de
/// [normalizeRelativeAngle]: negativo por babor, positivo por estribor.
/// Escenarios del modo DEMO.
///
/// El DEMO enseñaba siempre lo mismo: una vuelta genérica por el Egeo. Para
/// enseñar la app hacen falta las dos situaciones reales, porque cada una
/// usa pantallas distintas — fondeado se mira ANC, navegando se mira NAV y
/// VNT ("en DEMOS se debe poder elegir fondeado o navegando", 2026-09-08).
class DemoScenario {
  const DemoScenario({
    required this.id,
    required this.label,
    required this.description,
    required this.lat,
    required this.lon,
    required this.depthM,
    required this.twdDeg,
    required this.twsKn,
    required this.headingDeg,
    required this.sogKn,
    required this.seaFromDeg,
    required this.seaToDeg,
  });

  final String id;
  final String label;
  final String description;

  /// Punto de partida: el fondeo, o el inicio de la singladura.
  final double lat;
  final double lon;
  final double depthM;

  /// Viento real: de dónde viene y cuánto sopla.
  final double twdDeg;
  final double twsKn;

  /// Rumbo y velocidad de crucero (ignorados si está fondeado).
  final double headingDeg;
  final double sogKn;

  /// Sector de mar abierto visto desde el barco, en grados verdaderos y
  /// recorrido en sentido horario de [seaFromDeg] a [seaToDeg]. Los barcos
  /// AIS del DEMO se quedan dentro: fuera de ahí hay costa, y un mercante
  /// pintado tierra adentro delata el simulacro al instante ("en AIS
  /// intenta que los barcos no salgan en tierra", 2026-09-08).
  final double seaFromDeg;
  final double seaToDeg;

  /// Ancho del sector de mar, siempre positivo.
  double get seaSpanDeg {
    final span = normalize360(seaToDeg - seaFromDeg);
    return span == 0 ? 360 : span;
  }

  /// Rumbo dentro del sector de mar, con [fraction] entre 0 y 1.
  double seaBearing(double fraction) =>
      normalize360(seaFromDeg + seaSpanDeg * fraction);

  /// ¿Cae [bearingDeg] en mar abierto?
  bool isSeaward(double bearingDeg) =>
      normalize360(bearingDeg - seaFromDeg) <= seaSpanDeg;
}

const kDemoScenarios = <DemoScenario>[
  // Ormos Kolona, Kythnos: una cala clásica del Egeo, abierta al oeste y
  // cerrada por tierra por el resto.
  DemoScenario(
    id: 'anchored',
    label: 'Fondeado',
    description: 'Cala de Kythnos (Grecia), 10 m de sonda, meltemi flojo',
    lat: 37.3925,
    lon: 24.3855,
    depthM: 10,
    twdDeg: 340,
    twsKn: 12,
    headingDeg: 160,
    sogKn: 0,
    seaFromDeg: 200,
    seaToDeg: 340,
  ),
  // A 5 millas al sur de Málaga, rumbo SE con levante entablado. La costa
  // queda al norte, así que el mar abierto es todo el semicírculo sur.
  DemoScenario(
    id: 'sailing',
    label: 'Navegando',
    description: '5 M al sur de Málaga, rumbo SE a 7 kn con levante',
    lat: 36.6297,
    lon: -4.4150,
    depthM: 45,
    twdDeg: 90,
    twsKn: 15,
    headingDeg: 135,
    sogKn: 7,
    seaFromDeg: 80,
    seaToDeg: 280,
  ),
];

DemoScenario demoScenarioById(String id) => kDemoScenarios.firstWhere(
  (s) => s.id == id,
  orElse: () => kDemoScenarios.last,
);

(double aws, double awa) apparentFromTrue(
  double twsKn,
  double twaDeg,
  double boatSpeedKn,
) {
  final twaRad = twaDeg * math.pi / 180;
  // Componentes en ejes del barco: x a proa, y a estribor.
  final x = twsKn * math.cos(twaRad) + boatSpeedKn;
  final y = twsKn * math.sin(twaRad);
  final aws = math.sqrt(x * x + y * y);
  final awa = math.atan2(y, x) * 180 / math.pi;
  return (aws, normalizeRelativeAngle(awa));
}

/// Por qué falló (o no) un intento de login contra Signal K.
///
/// Antes esto era un simple bool y ANC enseñaba "revisa usuario/contraseña"
/// para TODO: contraseña mala, servidor apagado, timeout de 8 s, DNS que no
/// resuelve o un Signal K sin seguridad activada. Los cinco casos parecían
/// el mismo, así que el aviso no servía de diagnóstico y mandaba a corregir
/// unas credenciales que podían estar perfectas (2026-09-10: el Pi estaba
/// caído y el mensaje culpaba a la contraseña).
enum SkLoginOutcome {
  ok,

  /// El servidor contestó y rechazó las credenciales.
  badCredentials,

  /// No se pudo hablar con el servidor: apagado, fuera de la red, timeout.
  unreachable,

  /// Contestó, pero con algo que no es ni 200 ni un rechazo de credenciales.
  serverError,
}

class SkLoginResult {
  const SkLoginResult(this.outcome, {this.statusCode, this.serverMessage});
  final SkLoginOutcome outcome;
  final int? statusCode;
  final String? serverMessage;

  bool get ok => outcome == SkLoginOutcome.ok;

  /// Solo las credenciales malas se arreglan reescribiéndolas; el resto se
  /// arregla en el servidor o en la red, así que ofrecer "reintentar con
  /// otra contraseña" en esos casos sería mandar por el camino equivocado.
  bool get isCredentialProblem => outcome == SkLoginOutcome.badCredentials;

  static SkLoginResult fromStatus(int status, {String? body}) {
    if (status == 200) return const SkLoginResult(SkLoginOutcome.ok);
    if (status == 401 || status == 403) {
      return SkLoginResult(
        SkLoginOutcome.badCredentials,
        statusCode: status,
        serverMessage: body,
      );
    }
    return SkLoginResult(
      SkLoginOutcome.serverError,
      statusCode: status,
      serverMessage: body,
    );
  }
}

/// Texto que ve el usuario. Nombra el host y el puerto cuando el problema
/// es de alcance, porque saber A QUIÉN no se ha podido llamar es la mitad
/// del diagnóstico.
String skLoginErrorText(SkLoginResult result, String target) =>
    switch (result.outcome) {
      SkLoginOutcome.ok => '',
      SkLoginOutcome.badCredentials =>
        'Signal K ha rechazado el usuario o la contraseña.',
      SkLoginOutcome.unreachable =>
        'No se pudo contactar con $target. El servidor puede estar apagado '
            'o fuera de esta red — no es necesariamente la contraseña.',
      SkLoginOutcome.serverError =>
        'El servidor respondió con un error ${result.statusCode ?? ''}. '
            'Revisa Signal K en $target.',
    };

class OwnTrackHistory {
  final List<AnchorTrackPoint> points = [];
  void add(double? lat, double? lon) {
    if (lat == null || lon == null) return;
    // skNow(), NOT DateTime.now() — droppedAt/armedOrMovedAt (what
    // _trackSinceDrop compares every point here against) are stamped with
    // skNow() precisely to survive a device clock that disagrees with the
    // Signal K server's, sometimes by "many minutes to hours" (see skNow's
    // own doc comment). Every point recorded here used to carry the RAW,
    // uncorrected device clock instead — on any device whose clock runs
    // behind the server's, droppedAt ended up stamped LATER than any point
    // this function could ever produce, so _trackSinceDrop's `!p.t.isBefore
    // (since)` filter silently excluded every single point forever, not
    // just until enough time passed. Reported live 2026-09-05 (Recolocar
    // stuck at "0/8 puntos" no matter how long the boat had genuinely been
    // swinging at anchor).
    final now = skNow();
    if (points.isNotEmpty &&
        now.difference(points.last.t) < const Duration(seconds: 15)) {
      return;
    }
    points.add(AnchorTrackPoint(now, lat, lon));
    points.removeWhere((p) => now.difference(p.t) > const Duration(hours: 24));
  }

  void clear() => points.clear();

  // Backfills from Signal K's own history API on app start, so a fresh
  // launch doesn't show an empty trail until enough live points accumulate
  // — unlike add(), timestamps here are the recorded ones, not "now", so
  // the same 15s-spacing/24h-window rules are re-applied explicitly rather
  // than relying on add()'s live-clock-relative checks.
  //
  // The history fetch is a several-second round trip, so by the time it
  // resolves live points have almost always already started arriving via
  // add() — bailing out whenever points was non-empty (the original
  // approach) meant this never actually ran in practice. Instead, only
  // backfill points OLDER than whatever's already there, prepending them —
  // live data always wins for anything it already covers.
  void seedFromHistory(List<AnchorTrackPoint> historical) {
    // skNow(), matching add() above — historical's own timestamps come
    // from Signal K's server-side history, already on the server's clock,
    // so comparing them against the device's raw (possibly skewed) clock
    // here would reintroduce the exact same mismatch add() just got fixed
    // for, just for the backfilled points instead of the live ones.
    final now = skNow();
    final cutoff = points.isEmpty ? now : points.first.t;
    final sorted = [...historical]..sort((a, b) => a.t.compareTo(b.t));
    final backfill = <AnchorTrackPoint>[];
    AnchorTrackPoint? last;
    for (final p in sorted) {
      if (now.difference(p.t) > const Duration(hours: 24)) continue;
      if (!p.t.isBefore(cutoff)) continue;
      if (last != null &&
          p.t.difference(last.t) < const Duration(seconds: 15)) {
        continue;
      }
      backfill.add(p);
      last = p;
    }
    points.insertAll(0, backfill);
  }
}

/// Selects the current anchorage's points plus, when explicitly accepted,
/// the bounded trace of one previous anchorage. The gap while the anchor was
/// raised is deliberately excluded.
List<AnchorTrackPoint> anchorTrackForSession({
  required Iterable<AnchorTrackPoint> points,
  required DateTime currentFrom,
  DateTime? reusedFrom,
  DateTime? reusedUntil,
}) => [
  for (final p in points)
    if (!p.t.isBefore(currentFrom) ||
        (reusedFrom != null &&
            reusedUntil != null &&
            !p.t.isBefore(reusedFrom) &&
            !p.t.isAfter(reusedUntil)))
      p,
];

// configRadiusM is the watch's own ALARM radius, usually set with a safety
// margin above the true taut-chain swing (see _dropAnchor's 7:1 scope rule)
// — using it as if it were the true physical swing radius understates how
// taut the chain actually is. When the chain paid out for THIS anchoring is
// known (chainOutM) and a depth reading exists, the true horizontal swing
// radius is ground truth, not a guess: a straight line from bow roller to
// anchor is the hypotenuse (chain length); the vertical leg is depth PLUS
// rollerHeightM (settings.anchorBowRollerHeightM — the roller sits above
// the waterline, so the true drop to the seabed is deeper than the
// depthsounder alone reports), so the horizontal leg is
// sqrt(chain² − (depth+rollerHeight)²) (still ignores catenary sag — an
// accepted simplification). rollerHeightM defaults to 0 for callers that
// don't have it (and to stay source-compatible with existing callers/
// tests) — the boat's own configured height should be passed wherever
// it's known. Falls back to configRadiusM whenever there's no usable
// chain/depth pair. Shared by NativeAnchorView's own reposition gate and
// computeYawAnalysis's guiñada taut-chain filter (audit finding, verified
// 2026-09-05: guiñada used to filter on configRadiusM alone, the same
// alarm-safety-margin bias this function exists to correct for).
double effectiveWatchRadiusM(
  double configRadiusM,
  double? chainOutM,
  double? depthM, {
  double rollerHeightM = 0,
}) {
  if (chainOutM != null && chainOutM > 0 && depthM != null && depthM > 0) {
    final verticalM = depthM + rollerHeightM;
    if (chainOutM > verticalM) {
      final horizontal = math.sqrt(
        chainOutM * chainOutM - verticalM * verticalM,
      );
      if (horizontal >= 3) return horizontal;
    }
  }
  return configRadiusM;
}

// Minimum points (since the current drop — see ANC's "Recolocar" use)
// before a fit is even attempted.
const kAnchorRefitMinPoints = 8;

// Finds the anchor's true position from the boat's own swing track, given
// a KNOWN (not fitted) chain-taut radius — config.radiusM, the anchor
// watch's own configured radius, which the user already set (often from
// the 7:1 scope rule _dropAnchor itself uses). The boat, tethered to the
// anchor, traces an arc centered on the anchor's TRUE position when the
// chain is taut; that center can be a more accurate estimate than the
// originally recorded drop fix (GPS settling at the moment of dropping, a
// position taken at the bow rather than the anchor itself, etc). Used by
// ANC's "Recolocar ancla" button. Reported live 2026-09-04 ("cuando ha
// pasado tiempo y hay trazas se forma un sector de circulo que
// permitiria... recolocar automaticamente el ancla").
//
// An EARLIER version of this fit solved for center AND radius together
// (3 unknowns) via Kasa's least-squares method — that needed a wide
// (60°+) swing to be well-conditioned; a narrower arc could produce a
// "confident"-looking fit 15m+ off from the truth. Fixing the radius
// (an external follow-up suggestion, evaluated and agreed with 2026-09-04)
// reduces this to 2 unknowns (just the center), dramatically better
// conditioned in principle — but the FIRST fixed-radius version (still
// evaluated and agreed with 2026-09-04) only penalized points EXCEEDING
// R, leaving a real bug: whenever every point already happened to lie
// within R of the current drop position (i.e. ref itself already
// satisfied "nothing exceeds R" — not a rare case at all, since ref is
// usually already a decent estimate), the whole loss was flat/zero right
// there and gradient descent never moved — the fit just silently returned
// ref back unchanged. Reported live 2026-09-04 ("recolocar falla, no
// mueve bien el centro").
//
// Method now: gradient descent on Σ (distance_i − R)² over ALL points
// (two-sided, not just violators) — well-defined everywhere, verified
// empirically accurate (<1m error) across every realistic combination of
// radius (15-150m) and starting-offset (up to the radius itself) tried.
// Two extra passes guard what that two-sided loss trades away on its own:
// gross outliers are trimmed BEFORE fitting (median absolute distance
// from the raw centroid — a single bad GPS fix no longer needs to be
// "explained" by the fit at all), and the result is rejected unless a
// real fraction of points end up near the fitted radius afterward (catches
// an all-calm anchorage where the chain never actually went taut this
// session, and a raw-spread pre-check catches it even more directly).
//
// refLat/refLon should be the CURRENTLY recorded anchor position (config.
// dropLat/dropLon) — the local-projection origin, not otherwise part of
// the math.
({double lat, double lon})? fitAnchorCenterKnownRadius(
  List<AnchorTrackPoint> points, {
  required double radiusM,
  required double refLat,
  required double refLon,
}) {
  if (points.length < kAnchorRefitMinPoints || radiusM <= 0) return null;
  final cosRef = math.cos(refLat * math.pi / 180);
  var xs = [for (final p in points) (p.lon - refLon) * cosRef * 111320];
  var ys = [for (final p in points) (p.lat - refLat) * 110540];

  // Trim gross outliers before fitting — median absolute distance from
  // the raw centroid (robust to exactly the single-bad-fix case this is
  // meant to catch; a real arc's own points cluster together by
  // construction and are unaffected).
  {
    final cxRaw = xs.reduce((a, b) => a + b) / xs.length;
    final cyRaw = ys.reduce((a, b) => a + b) / ys.length;
    final dists = [
      for (var i = 0; i < xs.length; i++)
        math.sqrt(
          (xs[i] - cxRaw) * (xs[i] - cxRaw) + (ys[i] - cyRaw) * (ys[i] - cyRaw),
        ),
    ];
    final sorted = [...dists]..sort();
    final median = sorted[sorted.length ~/ 2];
    final keep = <int>[
      for (var i = 0; i < dists.length; i++)
        if (dists[i] <= median * 2.5 + 5) i,
    ];
    if (keep.length >= kAnchorRefitMinPoints && keep.length < xs.length) {
      xs = [for (final i in keep) xs[i]];
      ys = [for (final i in keep) ys[i]];
    }
  }
  final n = xs.length;
  if (n < kAnchorRefitMinPoints) return null;

  // "Ready" doesn't require a wide swinging ARC — a boat held by a
  // steadily taut chain with barely any angular swing (e.g. a steady
  // current pinning it in one direction, no wind oscillation) is just as
  // valid a case, and produces a TIGHT cluster of points that's still far
  // from ref. The previous check measured spread around the cluster's OWN
  // centroid, which is near-zero for a tight cluster regardless of how far
  // offset it sits from ref — so it kept reporting "hasn't gone taut" even
  // after a full day of steady tension. Reported live 2026-09-04 ("lleva
  // todo el día con la cadena tensa"). What actually matters is how far
  // the boat's TYPICAL position is from the recorded drop point (ref),
  // checked against the RAW data before any fitting could pull points
  // toward R.
  final distFromRef = [
    for (var i = 0; i < n; i++) math.sqrt(xs[i] * xs[i] + ys[i] * ys[i]),
  ]..sort();
  final medianDistFromRef = distFromRef[distFromRef.length ~/ 2];
  if (medianDistFromRef < radiusM * 0.3) return null;

  var cx = 0.0, cy = 0.0;
  const learningRate = 0.3;
  const iterations = 400;
  for (var iter = 0; iter < iterations; iter++) {
    var gx = 0.0, gy = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = cx - xs[i], dy = cy - ys[i];
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < 1e-9) continue;
      final coeff = 2 * (d - radiusM) / d;
      gx += coeff * dx;
      gy += coeff * dy;
    }
    cx -= learningRate * gx / n;
    cy -= learningRate * gy / n;
    if (!cx.isFinite || !cy.isFinite) return null;
  }
  // Require a real ABSOLUTE count of points actually near the fitted
  // radius afterward — guards against the two-sided loss "explaining" a
  // tight, spurious cluster from far enough away. This used to also
  // require a FRACTION of the whole track (25%), but that's wrong for a
  // real anchor watch: a boat rides calm and well inside scope most of a
  // 24h day, only reaching taut chain in wind/tide gusts, so genuinely
  // good swing data can easily be well under 25% of a day's worth of
  // samples. Reported live 2026-09-04 ("lleva todo el día tensa" and
  // still getting rejected). The absolute floor alone still requires a
  // real, non-trivial cluster of near-radius points to trust the fit.
  final nearRadiusCount = [
    for (var i = 0; i < n; i++)
      math.sqrt((cx - xs[i]) * (cx - xs[i]) + (cy - ys[i]) * (cy - ys[i])),
  ].where((d) => d >= radiusM * 0.7 && d <= radiusM * 1.3).length;
  if (nearRadiusCount < 15) return null;
  return (lat: refLat + cy / 110540, lon: refLon + cx / (cosRef * 111320));
}

// ─── Voltage → SOC curves, by chemistry (batteries without a shunt) ───────────
// "en todas las baterias ademas de la grafica historica e gustaria ver la
// curva de carga y descarga" then "en CFG debe poderse elegir plomo, agm,
// gel o litio y poner la curva de carga aprox" (reported live 2026-09-04) —
// for the house battery there's already a real current sensor and Signal K
// publishes a proper stateOfCharge, so none of this applies there. For
// start/bow-thruster batteries there's only ever a voltage reading, so this
// is the standard fallback: a resting-voltage lookup table per chemistry
// (settings.batteryChemistryStart / batteryChemistryBow — separate per
// battery, see their own doc comment), ONLY meaningful when the battery
// isn't currently being charged or drained (see _VoltageTrendTracker in
// trackers.dart, which is what qualifies whether to trust it). Values are
// widely-used approximate references at rest around room temperature —
// real cells vary by brand and temperature, so this is always presented as
// an approximation, never an exact reading.
//
// Lithium (LiFePO4) is a special case worth calling out: its curve is
// famously almost FLAT across the whole 20-90% range (~13.0-13.3V) before
// dropping sharply at each end — a few tens of millivolts of measurement
// noise there swing the estimate by a huge SOC range, far more than for any
// lead-based chemistry. BatteryCurveDialog surfaces that as an extra
// caption rather than silently presenting a falsely precise number.
const batterySocCurves = <String, List<(int soc, double voltage)>>{
  'lead': [
    (0, 11.00),
    (10, 11.51),
    (20, 11.66),
    (30, 11.81),
    (40, 11.96),
    (50, 12.10),
    (60, 12.24),
    (70, 12.37),
    (80, 12.50),
    (90, 12.62),
    (100, 12.70),
  ],
  'agm': [
    (0, 11.30),
    (10, 11.60),
    (20, 11.80),
    (30, 11.96),
    (40, 12.10),
    (50, 12.24),
    (60, 12.37),
    (70, 12.50),
    (80, 12.60),
    (90, 12.70),
    (100, 12.80),
  ],
  'gel': [
    (0, 11.50),
    (10, 11.70),
    (20, 11.90),
    (30, 12.05),
    (40, 12.20),
    (50, 12.35),
    (60, 12.45),
    (70, 12.55),
    (80, 12.65),
    (90, 12.75),
    (100, 12.85),
  ],
  'lithium': [
    (0, 10.00),
    (10, 12.50),
    (20, 12.90),
    (30, 13.00),
    (40, 13.05),
    (50, 13.10),
    (60, 13.15),
    (70, 13.20),
    (80, 13.25),
    (90, 13.30),
    (100, 13.60),
  ],
};

const batteryChemistryLabels = <String, String>{
  'lead': 'Plomo-ácido',
  'agm': 'AGM',
  'gel': 'Gel',
  'lithium': 'Litio (LiFePO4)',
};

// Linear interpolation through batterySocCurves[chemistry] — voltage in,
// approximate SOC% out (clamped to the table's own range at both ends).
double socFromVoltage(double voltageAt12VNominal, String chemistry) {
  final v = voltageAt12VNominal;
  final table = batterySocCurves[chemistry] ?? batterySocCurves['lead']!;
  if (v <= table.first.$2) return table.first.$1.toDouble();
  if (v >= table.last.$2) return table.last.$1.toDouble();
  for (var i = 0; i < table.length - 1; i++) {
    final (soc0, v0) = table[i];
    final (soc1, v1) = table[i + 1];
    if (v >= v0 && v <= v1) {
      final frac = (v - v0) / (v1 - v0);
      return soc0 + frac * (soc1 - soc0);
    }
  }
  return 50; // unreachable given the clamps above
}

// ─── Guiñada (yaw-at-anchor analysis) ─────────────────────────────────────────
// "analizar analíticamente cómo 'navega' el barco sobre el ancla... en lugar
// de limitarse a mostrar solo el círculo de borneo estático" (reported live
// 2026-09-04) — a new ANC sub-screen. Purely single-boat, no cross-vessel
// data sharing and no chain-scope event log (both explicitly descoped by the
// user: comparing boats happens by talking over the radio, not in-app; the
// effect of paying out more/less chain is judged by eye, re-opening this
// screen before/after, not by an automatic before/after annotation).

// One sample for yaw analysis — like AnchorTrackPoint but also carries
// heading/COG/SOG at that instant, needed for the yaw/leeway math below.
class AnchorYawPoint {
  const AnchorYawPoint({
    required this.t,
    required this.lat,
    required this.lon,
    this.headingDeg,
    this.cogDeg,
    this.sogKn,
  });
  final DateTime t;
  final double lat;
  final double lon;
  final double? headingDeg;
  final double? cogDeg;
  final double? sogKn;
}

// Δψ: how far the bow is pointing away from the rode's own direction (bow
// → anchor) — 0° means lying calmly head-to-rode (bow pointing back along
// the chain, into the wind/current pulling the boat taut), ±90° means
// lying broadside to it. Signed, -180..180.
//
// "es mas logico rumbo del ancla al barco o del varco al ancla?" (reported
// live 2026-09-05) — this must be bearing BOAT→anchor, not anchor→boat:
// lying calmly at anchor, the bow weathervanes into whatever is pulling
// the chain taut, i.e. it points back toward the anchor, not away from
// it. Using anchor→boat here (the reciprocal) was a real bug — it made
// "calm" read as Δψ≈180° instead of ≈0°, sitting right on
// normalizeRelativeAngle's own -180/180 wrap seam, which corrupts the
// smoothed series and amplitude/period readings with spurious jumps
// exactly the way a real, non-synthetic anchorage would eventually
// expose (the demo generator's own synthetic data used the same
// convention on both sides, so it never caught this when self-tested).
//
// NOTE for readers of computeYawAnalysis below: only GUIÑADA needs
// headingDeg. BORNEO is pure position and works from any AnchorYawPoint,
// heading or not — a real boat can have its own position tracked (e.g.
// via SK's tracks-plugin, see YawAnalysisDialog's own comment) on a
// server whose telemetry historian never happened to log heading at all
// ("no tienen track instalado como plugin?", confirmed true on at least
// one boat this session).
double? yawMisalignmentDeg({
  required double anchorLat,
  required double anchorLon,
  required double boatLat,
  required double boatLon,
  required double headingDeg,
}) {
  final expected = bearingDistanceMeters(
    boatLat,
    boatLon,
    anchorLat,
    anchorLon,
  ).bearingDeg;
  return normalizeRelativeAngle(headingDeg - expected);
}

// Leeway/abatimiento: how far the boat's actual movement (COG) diverges
// from where the bow points (heading) — near 0 lying still or moving
// straight ahead, larger when sliding sideways (typical mid-swing, chain
// still slack). Signed, -180..180.
double? leewayDeg({required double cogDeg, required double headingDeg}) =>
    normalizeRelativeAngle(cogDeg - headingDeg);

// "en el menu de guiñada tienes que diferenciar entre borneo y guiñada.
// borneo es el movimiento con centro del radio de giro en el ancla.
// guiñada es la oscilacion sobre la linea que une la proa con el ancla"
// (reported live 2026-09-04) — two genuinely different phenomena, both
// worth showing but never conflated into one number:
//  - Borneo: the boat's POSITION swinging in an arc centered on the
//    anchor — slow, large-scale, driven by wind/tide direction changes.
//    Tracked here as the bearing FROM the anchor TO the boat over time.
//  - Guiñada: the boat's HEADING oscillating around the anchor-rode
//    line — faster, smaller-scale snaking, independent of where in the
//    swing circle the boat currently sits. Already what yawMisalignmentDeg
//    (Δψ) measures.
class YawAnalysisResult {
  const YawAnalysisResult({
    required this.samples,
    required this.borneoSeries,
    required this.borneoArcDeg,
    required this.sweptAreaM2,
    required this.headingSamples,
    required this.guinadaSamples,
    required this.guinadaSeries,
    required this.guinadaAmplitudeDeg,
    required this.guinadaPeriod,
  });
  final int samples;
  // Borneo — (time, ° relative to the first bearing observed this window).
  final List<({DateTime t, double deg})> borneoSeries;
  final double? borneoArcDeg;
  final double? sweptAreaM2;
  // How many of `samples` have ANY heading at all (taut or not) — 0 means
  // this server's history never logs heading, a different, permanent
  // situation from merely "chain not taut yet in this window" (see
  // computeYawAnalysis's own comment).
  final int headingSamples;
  // Guiñada — (time, Δψ). A SUBSET of samples: only points with the chain
  // at (near) full scope — see computeYawAnalysis's own comment for why.
  final int guinadaSamples;
  final List<({DateTime t, double deg})> guinadaSeries;
  final double? guinadaAmplitudeDeg;
  final Duration? guinadaPeriod;
}

// Odd-length centered CIRCULAR moving average (values are degrees) — enough
// to take the worst of raw GPS/compass jitter off the yaw series before
// amplitude/period/area are measured from it, without a full signal-
// processing library.
//
// Was a plain arithmetic mean until 2026-09-05 (audit finding): borneo feeds
// this the boat's raw 0-360° bearing to the anchor, which crosses the
// 0°/360° seam every time the boat lies roughly north of it — completely
// ordinary, not an edge case. A window straddling that seam (e.g.
// 359°,1°,358°,2°) averaged to ~180°, a wildly wrong "smoothed" point
// plotted right in the middle of the graph. Averaging via atan2(mean sin,
// mean cos) is seam-safe; the extra step below then picks whichever
// multiple-of-360° representation of that circular mean sits closest to
// the window's own center sample, so the output stays numerically
// continuous with its neighbors instead of snapping to atan2's native
// (-180, 180] branch — needed because callers plot this directly (borneo
// as 0-360°, guiñada as a signed relative angle) and neither wants an
// artificial jump introduced by the smoothing step itself.
List<double> _movingAverage(List<double> values, int window) {
  if (window < 3 || values.length < window) return values;
  final w = window.isOdd ? window : window + 1;
  final half = w ~/ 2;
  return [
    for (var i = 0; i < values.length; i++)
      () {
        final lo = (i - half).clamp(0, values.length - 1);
        final hi = (i + half).clamp(0, values.length - 1);
        var sumSin = 0.0, sumCos = 0.0;
        for (var j = lo; j <= hi; j++) {
          final rad = values[j] * math.pi / 180;
          sumSin += math.sin(rad);
          sumCos += math.cos(rad);
        }
        final n = hi - lo + 1;
        final circularMean = math.atan2(sumSin / n, sumCos / n) * 180 / math.pi;
        final diff = ((circularMean - values[i] + 180) % 360 + 360) % 360 - 180;
        return values[i] + diff;
      }(),
  ];
}

// Turns a raw track (own position + heading, since the current drop) into
// the KPIs Guiñada shows. anchorLat/anchorLon is the CURRENT drop position
// (config.dropLat/dropLon) — same "known, not fitted" spirit as
// fitAnchorCenterKnownRadius, just used here as a fixed reference instead
// of something to solve for.
// Average time between consecutive UPWARD zero-crossings of a smoothed,
// zero-centered series (one full cycle = one side to the other and back).
// A simple, honest approximation, not a spectral analysis — deliberately
// ignores crossings closer together than 20s (GPS/compass jitter, not a
// real half-cycle) and requires the series to have actually swung at least
// a few degrees either side of zero. Shared by both borneo and guiñada.
Duration? _oscillationPeriod(
  List<double> smoothed,
  List<DateTime> times,
  double amplitude,
) {
  if (amplitude <= 4) return null;
  final crossings = <DateTime>[];
  for (var i = 1; i < smoothed.length; i++) {
    if (smoothed[i - 1] <= 0 && smoothed[i] > 0) {
      if (crossings.isEmpty ||
          times[i].difference(crossings.last) > const Duration(seconds: 20)) {
        crossings.add(times[i]);
      }
    }
  }
  if (crossings.length < 2) return null;
  final totalMs = crossings.last.difference(crossings.first).inMilliseconds;
  return Duration(milliseconds: (totalMs / (crossings.length - 1)).round());
}

// Largest-angular-gap method: the true angular span a set of bearings
// covers, robust to wrapping across 0°/360° (a naive max−min on raw
// bearings breaks the moment the swing straddles that seam). Same
// algorithm as NativeAnchorView's own _swingArcDeg, extended here to also
// return the arc's own CENTER — "no entiendo la grafica... con todo
// valores negativo entre 5 y -25" (reported live 2026-09-05): plotting
// borneo relative to whichever bearing happened to be FIRST in the window
// only reads as a symmetric wobble around zero if the window happens to
// start mid-swing; if it starts near one edge (the common case), the whole
// graph reads one-sided even though the boat is genuinely swinging back
// and forth. Centering on the arc's own midpoint instead makes the graph
// symmetric regardless of where in the swing the window happened to start.
({double arcDeg, double centerDeg}) _angularArc(List<double> bearingsDeg) {
  if (bearingsDeg.length < 2) {
    return (arcDeg: 0, centerDeg: bearingsDeg.isEmpty ? 0 : bearingsDeg.first);
  }
  final angles = [...bearingsDeg]..sort();
  final n = angles.length;
  // Gap after the LAST element wraps around to the first (+360) — the
  // default/starting candidate before checking the internal gaps below.
  var largestGap = 360.0 - (angles.last - angles.first);
  var gapStartIdx = n - 1;
  for (var i = 1; i < n; i++) {
    final gap = angles[i] - angles[i - 1];
    if (gap > largestGap) {
      largestGap = gap;
      gapStartIdx = i - 1;
    }
  }
  final arcDeg = 360.0 - largestGap;
  final arcStart = angles[(gapStartIdx + 1) % n];
  return (arcDeg: arcDeg, centerDeg: normalize360(arcStart + arcDeg / 2));
}

YawAnalysisResult computeYawAnalysis({
  required List<AnchorYawPoint> points,
  required double anchorLat,
  required double anchorLon,
  required double radiusM,
}) {
  if (points.length < 4) {
    return const YawAnalysisResult(
      samples: 0,
      borneoSeries: [],
      borneoArcDeg: null,
      sweptAreaM2: null,
      headingSamples: 0,
      guinadaSamples: 0,
      guinadaSeries: [],
      guinadaAmplitudeDeg: null,
      guinadaPeriod: null,
    );
  }

  // ── Borneo — the boat's POSITION swinging around the anchor ──────────────
  // Uses every point, heading or not: it's pure position, and a real boat
  // can have its track recorded (e.g. via SK's own tracks-plugin) on a
  // server whose telemetry historian never logged heading at all — see
  // yawMisalignmentDeg's own doc comment.
  final fixes = [
    for (final p in points)
      bearingDistanceMeters(anchorLat, anchorLon, p.lat, p.lon),
  ];
  final bearingToBoat = [for (final f in fixes) f.bearingDeg];
  // Plotted as the plain absolute rumbo ancla→barco (0-360°), not centered
  // or made relative to anything — "no hace falta que la centres en cero"
  // (reported live 2026-09-05). Only the KPI (arc degrees) needs the
  // wrap-safe largest-gap treatment; the graph itself is just the raw
  // bearing over time.
  final borneoArcDeg = _angularArc(bearingToBoat).arcDeg;
  final smoothedBorneo = _movingAverage(
    bearingToBoat,
    (points.length ~/ 20).clamp(3, 9),
  );
  final borneoSeries = [
    for (var i = 0; i < points.length; i++)
      (t: points[i].t, deg: smoothedBorneo[i]),
  ];

  // Swept area: the footprint the boat has actually occupied, in a local
  // flat projection centered on the anchor (same convention used
  // throughout this file). NOT a shoelace over the raw TIME-ordered
  // points — a boat swinging/yawing oscillates back and forth over
  // roughly the SAME arc, not tracing one clean loop, so a time-ordered
  // shoelace mostly cancels itself out to near zero (verified
  // empirically: a realistic 40° yaw over 40 cycles came out as 0.0 m²).
  // The convex hull of the visited points, then shoelace on THAT
  // (properly boundary-ordered) polygon, gives the actual occupied area
  // instead.
  final cosLat = math.cos(anchorLat * math.pi / 180);
  final xy = [
    for (final p in points)
      (
        x: (p.lon - anchorLon) * cosLat * 111320,
        y: (p.lat - anchorLat) * 110540,
      ),
  ];
  final sweptAreaM2 = _convexHullArea(xy);

  // ── Guiñada — the boat's HEADING oscillating around the rode line ────────
  // "guiñada [es] la diferencia entre el heading y el rumbo al ancla...
  // cuando la cadena está estirada en su totalidad o próximo a ella"
  // (reported live 2026-09-04) — only meaningful riding at (near) the end
  // of a taut rode: with slack chain the boat isn't constrained to yaw
  // around any particular line at all, so a Δψ computed from those points
  // would just be noise, not a real oscillation. radiusM is the same
  // known, not-fitted chain-taut radius used throughout (config.radiusM).
  // Threshold started at 0.85 but that missed genuinely taut real data —
  // "considera la cadena tensa cuando esta a un 75%, ahora esta super
  // tensa y no lo detectas" (reported live 2026-09-05); GPS noise and
  // radiusM itself (the watch's alarm radius, usually set with a safety
  // margin above the true chain-taut distance) both push real readings
  // below a stricter cutoff even at full scope.
  //
  // headingSamples (ANY point with a heading, taut or not) is tracked
  // separately from guinadaSamples (heading AND taut) so the dialog can
  // tell "cadena floja todavía" apart from "este servidor nunca guarda
  // rumbo histórico" — "poner salvaguarda que el boton guiñada no
  // aparezca si no hay datos de rumbo almacenados" (reported live
  // 2026-09-05): the first is a wait-and-see state, the second means
  // Guiñada is simply not available on this boat's setup, borneo or not.
  final headingSamples = points.where((p) => p.headingDeg != null).length;
  final tautIdx = [
    for (var i = 0; i < points.length; i++)
      if (points[i].headingDeg != null && fixes[i].distanceM >= radiusM * 0.75)
        i,
  ];
  if (tautIdx.length < 4) {
    return YawAnalysisResult(
      samples: points.length,
      borneoSeries: borneoSeries,
      borneoArcDeg: borneoArcDeg,
      sweptAreaM2: sweptAreaM2,
      headingSamples: headingSamples,
      guinadaSamples: tautIdx.length,
      guinadaSeries: const [],
      guinadaAmplitudeDeg: null,
      guinadaPeriod: null,
    );
  }
  final tautPoints = [for (final i in tautIdx) points[i]];
  final rawGuinada = [
    for (final i in tautIdx)
      yawMisalignmentDeg(
        anchorLat: anchorLat,
        anchorLon: anchorLon,
        boatLat: points[i].lat,
        boatLon: points[i].lon,
        headingDeg: points[i].headingDeg!,
      )!,
  ];
  // Smoothing window scales a little with sample count so a handful of
  // points (start of the "última hora" window) isn't over-smoothed into a
  // flat line, but a long dense series still gets real noise reduction.
  final smoothedGuinada = _movingAverage(
    rawGuinada,
    (tautPoints.length ~/ 20).clamp(3, 9),
  );
  final guinadaSeries = [
    for (var i = 0; i < tautPoints.length; i++)
      (t: tautPoints[i].t, deg: smoothedGuinada[i]),
  ];
  final guinadaAmplitudeDeg =
      smoothedGuinada.reduce(math.max) - smoothedGuinada.reduce(math.min);

  return YawAnalysisResult(
    samples: points.length,
    borneoSeries: borneoSeries,
    borneoArcDeg: borneoArcDeg,
    sweptAreaM2: sweptAreaM2,
    headingSamples: headingSamples,
    guinadaSamples: tautPoints.length,
    guinadaSeries: guinadaSeries,
    guinadaAmplitudeDeg: guinadaAmplitudeDeg,
    guinadaPeriod: _oscillationPeriod(smoothedGuinada, [
      for (final p in tautPoints) p.t,
    ], guinadaAmplitudeDeg),
  );
}

// Andrew's monotone chain: convex hull in O(n log n), then shoelace on the
// hull's own (properly boundary-ordered) vertices. See computeYawAnalysis's
// doc comment above for why the hull is used instead of a direct
// time-ordered shoelace.
double _convexHullArea(List<({double x, double y})> pts) {
  if (pts.length < 3) return 0;
  final sorted = [...pts]
    ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  double cross(
    ({double x, double y}) o,
    ({double x, double y}) a,
    ({double x, double y}) b,
  ) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <({double x, double y})>[];
  for (final p in sorted) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <({double x, double y})>[];
  for (final p in sorted.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  final hull = [...lower, ...upper];
  if (hull.length < 3) return 0;
  double shoelace = 0;
  for (var i = 0; i < hull.length; i++) {
    final j = (i + 1) % hull.length;
    shoelace += hull[i].x * hull[j].y - hull[j].x * hull[i].y;
  }
  return shoelace.abs() / 2;
}

class ModelForecastPoint {
  const ModelForecastPoint({
    required this.time,
    this.tempC,
    this.windKn,
    this.gustKn,
    this.rainPct,
    this.rainMm,
    this.windDirDeg,
    this.pressureHpa,
  });
  final DateTime time;
  final double? tempC, windKn, gustKn, rainPct, rainMm, windDirDeg, pressureHpa;
}

class WeatherModel {
  String place = 'Sin posicion';
  DateTime? updated;
  String? error;
  double? latitude;
  double? longitude;
  final summary = <ForecastPoint>[];
  final hourly = <ForecastPoint>[];
  final marine = <MarinePoint>[];

  Map<String, dynamic> toJson() => {
    'place': place,
    'updated': updated?.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'summary': [for (final p in summary) p.toJson()],
    'hourly': [for (final p in hourly) p.toJson()],
    'marine': [for (final p in marine) p.toJson()],
  };

  void loadFromJson(Map<String, dynamic> j) {
    place = j['place'] as String? ?? place;
    final updatedStr = j['updated'] as String?;
    updated = updatedStr == null ? null : DateTime.tryParse(updatedStr);
    latitude = (j['latitude'] as num?)?.toDouble();
    longitude = (j['longitude'] as num?)?.toDouble();
    summary
      ..clear()
      ..addAll([
        for (final e in (j['summary'] as List? ?? []))
          ForecastPoint.fromJson(e as Map<String, dynamic>),
      ]);
    hourly
      ..clear()
      ..addAll([
        for (final e in (j['hourly'] as List? ?? []))
          ForecastPoint.fromJson(e as Map<String, dynamic>),
      ]);
    marine
      ..clear()
      ..addAll([
        for (final e in (j['marine'] as List? ?? []))
          MarinePoint.fromJson(e as Map<String, dynamic>),
      ]);
  }
}

// A remembered Signal K server (CFG → Admin, owner-only) — lets the app
// jump between several boats' servers without retyping host/port/login
// each time. Each server keeps its OWN sensor mapping (see
// SettingsModel.sensorConfigJsonForHost) so switching boats never
// overwrites another boat's tank/battery/solar setup.
class SavedServer {
  SavedServer({
    required this.name,
    required this.host,
    this.port = 3000,
    this.skUsername = '',
    this.skPassword = '',
  });
  String name;
  String host;
  int port;
  String skUsername;
  String skPassword;

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'skUsername': skUsername,
    'skPassword': skPassword,
  };

  static SavedServer fromJson(Map<String, dynamic> j) => SavedServer(
    name: j['name'] as String? ?? '',
    host: j['host'] as String? ?? '',
    port: (j['port'] as num?)?.toInt() ?? 3000,
    skUsername: j['skUsername'] as String? ?? '',
    skPassword: j['skPassword'] as String? ?? '',
  );
}

class SettingsModel {
  // Random, generated once on first run and persisted — lets the app tell
  // "my own anchor.* publish echoing back" apart from "a DIFFERENT install
  // of this same app (another phone/tablet, or the web version) changed
  // the shared anchor watch", since both currently publish under the same
  // 'rewind-panel-anchor' label prefix. Without this, every install was
  // forced to ignore ALL rewind-panel-anchor-labeled data including from
  // other installs — meaning anchoring from the webapp never showed as
  // anchored on Android and vice versa.
  String anchorDeviceId = '';
  // CFG → Admin (owner-only, revealed by a long-press — see _settingsPage):
  // other boats' Signal K servers, for quickly switching which one this
  // install talks to. Each entry's sensor mapping is kept separately (see
  // sensorConfigJsonByHost) so switching servers never overwrites another
  // boat's tank/battery/solar setup.
  List<SavedServer> savedServers = [];
  Map<String, Map<String, dynamic>> sensorConfigJsonByHost = {};
  // Anchor watch state (armed, drop position, radius) is boat-specific —
  // without this, switching servers while armed on one boat carried that
  // "anchored" state (and kept publishing it) onto whichever server you
  // switched to next. Confirmed live 2026-09-02.
  Map<String, Map<String, dynamic>> anchorConfigJsonByHost = {};
  String host = 'lysmarine.local';
  int port = 3000;
  String authBase64 = ''; // Basic auth for the Signal K connection (WebSocket + REST) — not InfluxDB.
  // Separate from authBase64 above: a real Signal K session login (POST
  // /signalk/v1/auth/login). Only meaningful running as the Signal K
  // webapp — the browser then holds the session cookie itself, so
  // same-origin embedded pages (Freeboard-SK, the anchor alarm plugin)
  // that need write access (e.g. dragging to set the anchor) are
  // authenticated too, without the app having to touch their iframes.
  String skUsername = '';
  String skPassword = '';
  // Whether the user has consented to the anchor screen falling back to
  // the device's own GPS when Signal K has no vessel position — null
  // means "never asked yet" (see _AnchorWebView's explanatory dialog,
  // shown only on the ANC screen and only when actually needed, never at
  // app launch or on MAP). A privacy-sensitive choice, so it's asked
  // explicitly rather than assumed, and remembered once answered.
  bool? gpsFallbackConsent;
  bool keepAwake = true;
  String brightnessMode = 'dia'; // 'dia', 'noche', 'auto'
  // Historical-chart data source: 'auto' tries InfluxDB first and falls back
  // to the Signal K History API (e.g. KIP/SQLite) if that fails — 'influx'
  // and 'sk' force one or the other regardless of availability.
  String historySource = 'auto';
  String influxHost = ''; // empty = same as `host` above
  String influxOrg = influxOrgDefault;
  String influxToken = influxTokenDefault;
  String influxBucket = influxBucketDefault;
  String influxArchiveBucket = influxBucketDefault; // bucket for 7d / 1mes
  SensorConfig sensorConfig = SensorConfig();
  AnchorConfig anchorConfig = AnchorConfig();
  // Selected id from kBoatIconOptions (lib/boat_icons.dart) — null/unknown
  // falls back to the 'default' entry (the original own_ship.png).
  String shipIconId = 'default';
  String navLayoutMode = 'premium'; // 'classic', 'premium', or 'both'
  List<String> navCardIds = List<String>.of(defaultNavCardIds);
  int navGridColumns = 3; // 3 -> 3x2 (6 cards), 4 -> 4x2 (8 cards)
  // Alarms — see AlarmEngine in main.dart for how these drive live state.
  bool alarmsUseSkZones = false;
  // Keyed by the Signal K notification path (e.g.
  // "notifications.environment.wind.speedApparent") — only paths this app
  // has actually seen a notification for get an entry; unseen ones default
  // to enabled+sound so a brand new zone alarm is on by default.
  Map<String, SkZoneAlarmSetting> skZoneAlarms = {};
  List<CustomAlarmRule> customAlarms = [];
  // AIS "closest approach" DISPLAY filter — not an alarm. A target further
  // than this at CPA, or further out in time than this at TCPA, just isn't
  // shown as the closest-approach target on the NAV AIS card (see
  // _closestApproachTarget in main.dart). See alarmAis* below for the
  // actual collision alarm, which uses much tighter thresholds.
  double aisCpaMaxNm = 5.0;
  double aisTcpaMaxMin = 20.0;
  // AIS collision alarm — genuinely alerts (card highlight + header bell +
  // optional sound) when the closest AIS target's CPA/TCPA both come in
  // under these, tighter than the aisCpaMaxNm/aisTcpaMaxMin display filter
  // above on purpose: "worth showing on NAV" and "worth alerting for" are
  // different bars. Same on/off + sound shape as alarmCorrederaEnabled.
  bool alarmAisEnabled = false;
  bool alarmAisSound = true;
  double alarmAisCpaNm = 1.0;
  double alarmAisTcpaMin = 10.0;
  // Engine alarms — prefer the engine's own DM1 fault bit (J1939 PGN
  // 65226 — SPN 100/FMI 1 oil, SPN 110/FMI 0 coolant, SPN 167/FMI 1
  // alternator) when the NMEA2000 bridge (a Volvo Penta MDI-specific
  // gateway) publishes one; the threshold below is only the fallback for
  // as long as that signal stays unpublished (see engineOverTempAlarm et
  // al. in SignalKModel and the precedence in _activeAlarms/
  // _isLampOnReal). Evaluated only while the engine is running (see
  // _engineRunning in main.dart) so a stopped engine's naturally-zero oil
  // pressure and ambient coolant temp don't fire false alarms. Not
  // user-toggleable off — unlike AIS/Corredera these are safety alarms,
  // only the sound and the threshold are configurable.
  bool alarmEngineOilSound = true;
  double alarmEngineOilMinBar = 1.0;
  bool alarmEngineTempSound = true;
  double alarmEngineTempMaxC = 100.0;
  bool alarmEngineVoltSound = true;
  double alarmEngineVoltMinV = 13.0;
  // Glow-plug/starter-relay circuit fault (SPN 677 or 724, FMI 5) — a
  // discrete DM1 fault with no numeric equivalent, so no threshold to
  // configure, just the sound. Also not user-toggleable off.
  bool alarmEngineGlowPlugSound = true;
  // "Simple" (RPM + status + lamps) vs "Completo" (adds numeric gauges for
  // refrigerante and voltage with their honest source; oil remains a
  // discrete lamp because this MDI has no pressure sensor) — see CFG >
  // Sensores and PremiumMotorEnginePanel's `detailed` param. Ignored
  // (Motor screen never even joins the NAV swipe cycle) when
  // motorPanelEnabled is false.
  bool motorPanelDetailed = false;
  // "Ninguno" in CFG > Pantalla > ESTILO MOTOR — a boat with no engine
  // telemetry wired up at all can drop the Motor screen from the NAV
  // swipe cycle entirely instead of it always sitting there as an empty
  // simulation preview (see _kMotorPanelAlwaysVisible in main.dart).
  bool motorPanelEnabled = true;
  // Whether NAV's header auto-hides after a few seconds like ANC/MAP
  // always do (those two are non-negotiable — a WebView needs the full
  // screen). NAV doesn't have that constraint, so it's the user's call;
  // true matches the original behavior.
  bool autoHideHeaderOnNav = true;
  // Corredera (log/speedo) stall alarm: SOG moving but STW reads zero for a
  // sustained period usually means the paddle wheel is fouled/stuck rather
  // than the boat actually being stopped in the water — a standalone alarm
  // outside the customAlarms list since it isn't threshold-configurable by
  // the user, just on/off + sound.
  bool alarmCorrederaEnabled = false;
  bool alarmCorrederaSound = true;
  // Anchor watch alarms — only evaluated while settings.anchorConfig.armed
  // (see _activeAlarms in main.dart). Depth-swing is a margin around the
  // depth recorded at the moment of dropping, not the absolute value — a
  // tide change or the boat settling over different bottom both show up as
  // a swing, which is a useful drag proxy even before the boat leaves the
  // watch circle. Explicitly NOT a scope-ratio alarm (chain:depth) — asked
  // for and declined; depth swing is what's wanted instead.
  bool alarmAnchorDepthEnabled = false;
  // Sound off by default (reported live 2026-09-04) — the anchor-drag
  // alarm itself (garreo) always sounds regardless, un-configurable; these
  // three secondary anchor alarms (depth swing, wind, no-position) stay
  // silent until the user opts in per-alarm in CFG > Fondeo, same as the
  // AIS/corredera/engine alarms already default to sound-on but these
  // specifically default to off.
  bool alarmAnchorDepthSound = false;
  double alarmAnchorDepthMarginM = 1.5;
  bool alarmAnchorWindEnabled = false;
  bool alarmAnchorWindSound = false;
  double alarmAnchorWindKn = 25.0;
  // "Fails loud, not silent" — losing position entirely while armed (both
  // Signal K and any device-GPS fallback) is itself worth alerting on, not
  // just silently showing "--" the way it would for an unarmed watch. On
  // by default, unlike the other two — this one has no false-positive risk
  // (it only fires when there's truly nothing to watch with). Sound still
  // defaults off though, same as the other two anchor alarms above.
  bool alarmAnchorNoPositionEnabled = true;
  bool alarmAnchorNoPositionSound = false;
  // A single implausible GPS fix (a big instantaneous jump, then back) can
  // read as "outside the watch circle" even though the boat never actually
  // moved — this ignores any one reading that jumps further than this from
  // the last trusted fix, rather than trusting it as real drift.
  bool alarmAnchorFilterGlitches = true;
  double alarmAnchorGlitchJumpM = 50;
  // Vessel-design facts, not per-anchorage state — published to Signal K
  // as design.bowAnchorRollerHeight / design.totalAnchorChainLength
  // alongside the anchor watch data, same paths hoekens used.
  double anchorBowRollerHeightM = 0;
  double anchorTotalChainLengthM = 100;
  // Distance from the GPS antenna to the bow roller, measured along the
  // boat's centerline (positive = antenna is AFT of the roller, the
  // common case — mast-mounted or cockpit-mounted GPS on most boats).
  // navigation.position is the antenna's position, not the anchor's drop
  // point — on a boat where the antenna sits several meters aft of the
  // bow, using it directly as the drop origin (or as "distance from bow")
  // introduces exactly that many meters of avoidable error. 0 is a
  // reasonable default for a boat where they're genuinely close (small
  // boat, bow-mounted GPS) and keeps this fully opt-in. Reported live
  // 2026-09-06 ("para que el fondeo sea más exacto hay que poder
  // configurar... ubicación del GPS").
  double anchorGpsToBowM = 0;
  // Applies to start/bow-thruster's voltage→SOC curve (BatteryCurveDialog)
  // — the house battery has a real current sensor and doesn't need this.
  // Separate per battery, NOT one shared setting — they're not always the
  // same chemistry, and plenty of boats don't even have a bow thruster
  // battery at all (reported live 2026-09-04). 'lead' | 'agm' | 'gel' |
  // 'lithium' — see batterySocCurves in models.dart for the reference
  // tables.
  String batteryChemistryStart = 'lead';
  String batteryChemistryBow = 'lead';
  // ntfy.sh push, per-alarm opt-in — client-side, no Signal K plugin
  // involved. Empty topic gets a "SV_<nombre del barco>" default the first
  // time CFG is opened (see _settingsPage). Which alarms actually push is
  // just the set of alarm keys (same keys _activeAlarms uses) present here
  // — no separate master enable switch, no path to type.
  String ntfyTopic = '';
  final Set<String> ntfyAlarmKeys = {};
  // Minimum minutes between repeat pushes for the same alarm key — applies
  // uniformly to every alarm that pushes, not configured per-alarm.
  int ntfyMinIntervalSec = 60;
  // "Te has llevado el móvil" detectors — only meaningful while armed AND
  // actually relying on the device's own GPS as the anchor position (see
  // NativeAnchorView._preferDeviceGps/_hasSkPosition): if Signal K has its
  // own position, the boat's watch is accurate regardless of where the
  // phone wanders, so these three stay dormant until device GPS is the
  // one actually being trusted.
  bool anchorDetectPhoneLeftByMotion = false;
  bool anchorDetectPhoneLeftBySteps = false;
  bool anchorDetectPhoneLeftByWifi = false;
  String anchorBoatWifiSsid = '';
  // ANC's own HUD (voltage/SOC/corriente of the house/service battery) —
  // off by default since not everyone fondeando wants a battery readout
  // competing for space with viento/profundidad. Reported live 2026-09-06.
  bool anchorShowElectrical = false;

  /// Polar activa: id del catálogo empotrado, 'custom' para una tabla
  /// importada, o vacío para no usar ninguna. Ver lib/polars.dart.
  String polarBoatId = '';

  /// Qué porcentaje de la polar se toma como objetivo realista. El 100 %
  /// es el barco del certificado — fondo limpio, velas nuevas, tripulación
  /// completa — que no es el de nadie. Escala la VELOCIDAD, nunca los
  /// ángulos.
  double polarFactorPercent = 100;

  /// Tabla importada por el usuario, serializada. Manda sobre el catálogo
  /// cuando polarBoatId vale 'custom'.
  String? polarCustomJson;

  /// Lo anterior, guardado por servidor: el mismo APK sirve a varios
  /// barcos y cada uno tiene su polar. Mismo patrón que sensorConfig.
  Map<String, dynamic> polarConfigJsonByHost = {};

  Map<String, dynamic> polarConfigToJson() => {
    'boatId': polarBoatId,
    'factor': polarFactorPercent,
    if (polarCustomJson != null) 'custom': polarCustomJson,
  };

  void polarConfigFromJson(Map<String, dynamic> j) {
    polarBoatId = j['boatId'] as String? ?? '';
    polarFactorPercent = (j['factor'] as num?)?.toDouble() ?? 100;
    polarCustomJson = j['custom'] as String?;
  }

  bool demoMode = false;

  /// Escenario del DEMO: 'anchored' (fondeado en una cala) o 'sailing'
  /// (navegando). Ver kDemoScenarios.
  String demoScenario = 'sailing';
  // Use the device's own accelerometer as the heel/pitch source instead of
  // Signal K, for a boat with no attitude sensor. The device can be mounted
  // at any orientation, so a 2-point calibration (down from a level
  // reading, "right"/starboard from comparing the device's own
  // magnetometer heading against Signal K's boat heading — see
  // AttitudeCalibration / forwardFromHeading) is stored rather than a
  // guessed axis — set via the inclinometer screen's calibration wizard.
  bool usePhoneHeel = false;
  bool phoneAttitudeCalibrated = false;
  double phoneDownX = 0, phoneDownY = 0, phoneDownZ = 1;
  double phoneRightX = 0, phoneRightY = 1, phoneRightZ = 0;
  // Safety net: the heading-based sign convention for roll hasn't been
  // verified against a real boat (no way to test that here) — flip this if
  // a live calibrated reading turns out E/B-reversed, without recalibrating.
  bool phoneAttitudeInvertRoll = false;

  AttitudeCalibration get phoneCalibration => phoneAttitudeCalibrated
      ? AttitudeCalibration(
          down: Vec3(phoneDownX, phoneDownY, phoneDownZ),
          right: Vec3(phoneRightX, phoneRightY, phoneRightZ),
        )
      : AttitudeCalibration.fallback;

  void savePhoneCalibration(AttitudeCalibration c) {
    phoneAttitudeCalibrated = true;
    phoneDownX = c.down.x;
    phoneDownY = c.down.y;
    phoneDownZ = c.down.z;
    phoneRightX = c.right.x;
    phoneRightY = c.right.y;
    phoneRightZ = c.right.z;
  }

  String get effectiveInfluxHost => influxHost.isEmpty ? host : influxHost;
}

class TankViewData {
  const TankViewData({
    required this.name,
    required this.slots,
    required this.color,
    required this.icon,
  });
  final String name;
  final List<TankSlot> slots;
  final Color color;
  final IconData icon;
  int get capacityL => slots.fold(0, (sum, s) => sum + s.capacityL);
  double? percent(Map<String, double?> values) {
    var liters = 0.0;
    var capacity = 0;
    var unweightedSum = 0.0;
    var unweightedCount = 0;
    for (final s in slots) {
      final pct = values[s.tankKey];
      if (pct == null) continue;
      final cap = s.capacityL;
      if (cap > 0) {
        liters += cap * pct / 100.0;
        capacity += cap;
      } else {
        // Discovered tanks whose Signal K server only publishes
        // currentLevel (no capacity node) default to capacityL 0 until
        // someone fills it in — without this fallback, a perfectly valid
        // live reading got silently dropped here (liters-weighted average
        // saw zero total capacity) and the card showed a misleading "0%"
        // instead of the real level.
        unweightedSum += pct;
        unweightedCount++;
      }
    }
    if (capacity > 0) return liters * 100.0 / capacity;
    if (unweightedCount > 0) return unweightedSum / unweightedCount;
    return null;
  }
}
