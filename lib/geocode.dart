import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

Future<String> reverseGeocode(double lat, double lon) async {
  final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
    'format': 'jsonv2',
    'addressdetails': '1',
    'namedetails': '1',
    'accept-language': 'en,es',
    'zoom': '12',
    'lat': lat.toStringAsFixed(6),
    'lon': lon.toStringAsFixed(6),
  });
  final response = await http
      .get(uri, headers: {'User-Agent': 'REWIND-XCover6-panel/1.0'})
      .timeout(const Duration(seconds: 8));
  final doc = jsonDecode(response.body) as Map<String, dynamic>;
  final fields = [
    'city',
    'town',
    'village',
    'island',
    'islet',
    'name:en',
    'name:es',
    'name',
    'county',
  ];
  for (final source in [doc['namedetails'], doc['address'], doc]) {
    if (source is! Map) continue;
    for (final field in fields) {
      final value = source[field];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim().replaceAll(
          RegExp(r'\s+Regional Unit$', caseSensitive: false),
          '',
        );
      }
    }
  }
  return '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
}

/// Nearest inhabited place to [lat]/[lon] via Nominatim's "places near"
/// search, used only for the map picker's "población más cercana" hint —
/// distinct from [reverseGeocode], which just names whatever polygon
/// contains the point (which can be a large county/region at sea).
Future<String?> nearestPopulatedPlace(double lat, double lon) async {
  final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
    'format': 'jsonv2',
    'addressdetails': '1',
    'accept-language': 'en,es',
    'featureType': 'settlement',
    'lat': lat.toStringAsFixed(6),
    'lon': lon.toStringAsFixed(6),
    'viewbox': '${lon - 1.5},${lat + 1.5},${lon + 1.5},${lat - 1.5}',
    'bounded': '0',
    'limit': '5',
  });
  final response = await http
      .get(uri, headers: {'User-Agent': 'REWIND-XCover6-panel/1.0'})
      .timeout(const Duration(seconds: 8));
  final list = jsonDecode(response.body) as List;
  if (list.isEmpty) return null;
  ({String name, double dist})? best;
  for (final item in list) {
    final m = item as Map<String, dynamic>;
    final itemLat = double.tryParse(m['lat'] as String? ?? '');
    final itemLon = double.tryParse(m['lon'] as String? ?? '');
    final name = (m['name'] as String?)?.trim();
    if (itemLat == null || itemLon == null || name == null || name.isEmpty) {
      continue;
    }
    final dist = _haversineKm(lat, lon, itemLat, itemLon);
    if (best == null || dist < best.dist) best = (name: name, dist: dist);
  }
  if (best == null) return null;
  final km = best.dist;
  final distLabel = km < 1
      ? '${(km * 1000).round()} m'
      : '${km.toStringAsFixed(km < 10 ? 1 : 0)} km';
  return '${best.name} ($distLabel)';
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
