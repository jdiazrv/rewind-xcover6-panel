import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'models.dart';

// Response row order isn't guaranteed to match `_time` order, and
// `aggregateWindow` has been observed to emit two overlapping buckets for
// the same nominal timestamp — either one left as-is turns a chart/track
// into a line that zigzags backwards and forwards instead of progressing
// chronologically. Sorts, then keeps only the first point per timestamp.
List<GraphPoint> _sortAndDedupe(List<GraphPoint> points) {
  points.sort((a, b) => a.time.compareTo(b.time));
  final out = <GraphPoint>[];
  for (final p in points) {
    if (out.isNotEmpty && out.last.time == p.time) continue;
    out.add(p);
  }
  return out;
}

// ─── InfluxDB ─────────────────────────────────────────────────────────────────
// Deliberately blank — a real org/token used to ship here as the built-in
// default, which meant every install (including ones shared with Play
// Store testers, easily decompiled from the APK) carried live InfluxDB
// credentials. Each install now has to enter its own via CFG → Histórico;
// this device's saved settings (SharedPreferences) already hold the real
// values from before, so this change doesn't affect it — only future
// installs that have never saved a value.
const influxOrgDefault = '';
const influxTokenDefault = '';
const influxBucketDefault = 'enjoy_raw';

// ─── Top-level InfluxDB query ─────────────────────────────────────────────────
Future<List<GraphPoint>> influxQuery({
  required String host,
  required MetricDef def,
  required String fluxRange,
  required String aggEvery,
  String bucket = influxBucketDefault,
  String org = influxOrgDefault,
  String token = influxTokenDefault,
}) async {
  final url = Uri.parse('http://$host:8086/api/v2/query?org=$org');
  final query =
      'from(bucket:"$bucket")'
      '|>range(start:$fluxRange,stop:now())'
      '|>filter(fn:(r)=>r._measurement=="${def.skPath}")'
      '|>aggregateWindow(every:$aggEvery,fn:mean,createEmpty:true)'
      '|>keep(columns:["_time","_value"])';
  final response = await http
      .post(
        url,
        headers: {
          'Authorization': 'Token $token',
          'Content-Type': 'application/vnd.flux',
          'Accept': 'application/csv',
        },
        body: query,
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception(
      'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
    );
  }

  final points = <GraphPoint>[];
  int timeCol = -1, valueCol = -1;
  for (final line in const LineSplitter().convert(response.body)) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final cells = line.split(',');
    if (timeCol < 0) {
      final t = cells.indexOf('_time');
      if (t >= 0) {
        timeCol = t;
        valueCol = cells.indexOf('_value');
      }
      continue;
    }
    if (valueCol < 0 || cells.length <= math.max(timeCol, valueCol)) continue;
    final ts = cells[timeCol];
    final vs = cells[valueCol];
    if (ts.isEmpty || vs.isEmpty || vs == 'null') continue;
    final dt = DateTime.tryParse(ts);
    final v = double.tryParse(vs);
    if (dt == null || v == null || !v.isFinite) continue;
    points.add(GraphPoint(time: dt, value: v * def.scale + def.offset));
  }
  return _sortAndDedupe(points);
}

// GPS position is stored differently from every other metric this app
// queries: signalk-to-influxdb2 writes it as a single "navigation.position"
// measurement with two fields ("lat"/"lon"), not as its own measurement per
// scalar value — so it needs its own query (selecting both fields) and its
// own CSV parse (splitting rows by the `_field` column) instead of reusing
// `influxQuery`, which assumes one value per measurement.
Future<({List<GraphPoint> lat, List<GraphPoint> lon})> influxPositionQuery({
  required String host,
  required String fluxRange,
  required String aggEvery,
  String bucket = influxBucketDefault,
  String org = influxOrgDefault,
  String token = influxTokenDefault,
}) async {
  final url = Uri.parse('http://$host:8086/api/v2/query?org=$org');
  final query =
      'from(bucket:"$bucket")'
      '|>range(start:$fluxRange,stop:now())'
      '|>filter(fn:(r)=>r._measurement=="navigation.position" and (r._field=="lat" or r._field=="lon"))'
      '|>aggregateWindow(every:$aggEvery,fn:mean,createEmpty:false)'
      '|>keep(columns:["_time","_value","_field"])';
  final response = await http
      .post(
        url,
        headers: {
          'Authorization': 'Token $token',
          'Content-Type': 'application/vnd.flux',
          'Accept': 'application/csv',
        },
        body: query,
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception(
      'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
    );
  }

  final lat = <GraphPoint>[];
  final lon = <GraphPoint>[];
  int timeCol = -1, valueCol = -1, fieldCol = -1;
  for (final line in const LineSplitter().convert(response.body)) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final cells = line.split(',');
    if (timeCol < 0) {
      final t = cells.indexOf('_time');
      if (t >= 0) {
        timeCol = t;
        valueCol = cells.indexOf('_value');
        fieldCol = cells.indexOf('_field');
      }
      continue;
    }
    if (valueCol < 0 ||
        fieldCol < 0 ||
        cells.length <= math.max(timeCol, math.max(valueCol, fieldCol))) {
      continue;
    }
    final ts = cells[timeCol];
    final vs = cells[valueCol];
    if (ts.isEmpty || vs.isEmpty || vs == 'null') continue;
    final dt = DateTime.tryParse(ts);
    final v = double.tryParse(vs);
    if (dt == null || v == null || !v.isFinite) continue;
    final point = GraphPoint(time: dt, value: v);
    switch (cells[fieldCol]) {
      case 'lat':
        lat.add(point);
      case 'lon':
        lon.add(point);
    }
  }
  // Same non-guaranteed row order as `influxQuery` — a track line drawn
  // straight from response order braids back and forth instead of tracing
  // the boat's actual path.
  return (lat: _sortAndDedupe(lat), lon: _sortAndDedupe(lon));
}

// ─── Signal K History API (standard SK endpoint — the same API a boat's
// InfluxDB plugin OR a SQLite-backed provider like KIP can serve, so this one
// query works regardless of which the server has registered) ────────────────
Future<List<GraphPoint>> skHistoryQuery({
  required String host,
  required int port,
  required String authBase64,
  required MetricDef def,
  required Duration range,
  required Duration resolution,
}) async {
  final now = DateTime.now().toUtc();
  final from = now.subtract(range);
  final url = Uri.http('$host:$port', '/signalk/v2/api/history/values', {
    'context': 'vessels.self',
    'paths': def.skPath,
    'from': from.toIso8601String(),
    'to': now.toIso8601String(),
    'resolution': resolution.inSeconds.clamp(1, 1 << 30).toString(),
  });
  final response = await http
      .get(
        url,
        headers: authBase64.isEmpty
            ? {}
            : {'Authorization': 'Basic $authBase64'},
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception(
      'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
    );
  }
  final doc = jsonDecode(response.body) as Map<String, dynamic>;
  final data = doc['data'];
  if (data is! List) return [];
  final points = <GraphPoint>[];
  for (final row in data) {
    if (row is! List || row.length < 2) continue;
    final dt = DateTime.tryParse(row[0]?.toString() ?? '');
    final raw = row[1];
    final v = raw is num ? raw.toDouble() : null;
    if (dt == null || v == null || !v.isFinite) continue;
    points.add(GraphPoint(time: dt, value: v * def.scale + def.offset));
  }
  return _sortAndDedupe(points);
}

// ─── DEMO mode: synthetic graph data (no InfluxDB call) ───────────────────────
Duration parseFluxRange(String r) {
  final m = RegExp(r'-(\d+)([mhd])').firstMatch(r);
  if (m == null) return const Duration(hours: 24);
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    'd' => Duration(days: n),
    _ => const Duration(hours: 24),
  };
}

Duration parseAggEvery(String a) {
  final m = RegExp(r'(\d+)([smh])').firstMatch(a);
  if (m == null) return const Duration(minutes: 5);
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    's' => Duration(seconds: n),
    'h' => Duration(hours: n),
    _ => Duration(minutes: n),
  };
}

/// (baseline, volatility, min, max) — plausible per-metric range for a random
/// walk with mean reversion, so demo graphs look like real sensor noise
/// instead of pure noise or a flat line.
(double, double, double, double) _demoGraphBounds(MetricDef def) {
  final label = def.label.toLowerCase();
  if (label.contains('nevera')) return (4, 0.8, 0, 12);
  if (label.contains('raspberry') || label.contains('cpu')) {
    return (55, 3, 35, 80);
  }
  if (label.contains('mar')) return (23, 0.4, 10, 30);
  if (label.contains('exterior')) return (24, 2, 5, 40);
  if (def.offset != 0) return (22, 1.5, 5, 45); // generic Celsius temp fallback
  if (label.contains('bater')) return (75, 3, 20, 100);
  if (label.contains('corriente')) return (0, 4, -25, 25);
  if (label.contains('voltaje') || label.contains('start')) {
    return (12.6, 0.08, 11.5, 14.4);
  }
  if (label.contains('solar')) return (300, 60, 0, 900);
  if (label.contains('dc loads')) return (55, 15, 0, 200);
  if (label.contains('presi')) return (1015, 1.5, 990, 1035);
  if (label == 'tws' || label == 'aws') return (12, 2, 0, 30);
  if (label == 'sog') return (6, 0.8, 0, 11);
  return (10, 2, 0, 100);
}

List<GraphPoint> demoGraphSeries(
  MetricDef def,
  String fluxRange,
  String aggEvery,
) {
  final duration = parseFluxRange(fluxRange);
  final step = parseAggEvery(aggEvery);
  final now = DateTime.now();
  final rng = math.Random(def.skPath.hashCode);
  final (baseline, volatility, minV, maxV) = _demoGraphBounds(def);
  var value = baseline;
  final points = <GraphPoint>[];
  for (var t = now.subtract(duration); t.isBefore(now); t = t.add(step)) {
    value += (rng.nextDouble() - 0.5) * volatility + (baseline - value) * 0.03;
    value = value.clamp(minV, maxV);
    points.add(GraphPoint(time: t, value: value));
  }
  return points;
}
