part of '../main.dart';

// ─── ANC > Guiñada ──────────────────────────────────────────────────────────
// "analizar analíticamente cómo 'navega' el barco sobre el ancla... en lugar
// de limitarse a mostrar solo el círculo de borneo estático" (reported live
// 2026-09-04). Two modes:
// - "Última hora": the live YawTrackHistory buffer (3s sampling) — works
//   identically whether or not the boat has InfluxDB configured.
// - "Últimas 24h": fetched from whichever history backend CFG > Histórico
//   already points at (mirrors GraphDialog's own dispatch), since a live
//   buffer can't reach back before this app session started.
//
// Deliberately single-boat: comparing against another boat's own app
// happens by talking over the radio, not by this screen reaching into a
// different Signal K server; and the effect of paying out more/less chain
// is judged by eye, re-opening this dialog before/after, not by an
// automatic before/after annotation. Both explicitly requested this way.
class YawAnalysisDialog extends StatefulWidget {
  const YawAnalysisDialog({
    super.key,
    required this.liveTrack,
    required this.anchorLat,
    required this.anchorLon,
    required this.demo,
    required this.historySource,
    required this.skHost,
    required this.skPort,
    required this.skAuthBase64,
    required this.influxHost,
    required this.influxOrg,
    required this.influxToken,
    this.bucket = influxBucketDefault,
    this.archiveBucket = influxBucketDefault,
  });

  final List<AnchorYawPoint> liveTrack;
  final double anchorLat;
  final double anchorLon;
  final bool demo;
  final String historySource; // 'auto' | 'influx' | 'sk'
  final String skHost;
  final int skPort;
  final String skAuthBase64;
  final String influxHost;
  final String influxOrg;
  final String influxToken;
  final String bucket;
  final String archiveBucket;

  @override
  State<YawAnalysisDialog> createState() => _YawAnalysisDialogState();
}

class _YawAnalysisDialogState extends State<YawAnalysisDialog> {
  bool _last24h = false;
  bool _loading = false;
  String? _error;
  List<AnchorYawPoint>? _fetched24h;

  List<AnchorYawPoint> get _points {
    if (!_last24h) {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      return widget.liveTrack.where((p) => !p.t.isBefore(cutoff)).toList();
    }
    return _fetched24h ?? const [];
  }

  Future<void> _selectMode(bool last24h) async {
    setState(() => _last24h = last24h);
    if (!last24h || _fetched24h != null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pts = widget.demo ? _demo24hSeries() : await _fetch24hSeries();
      if (!mounted) return;
      setState(() {
        _fetched24h = pts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyApiError(e);
        _loading = false;
      });
    }
  }

  // Matches every other range GraphDialog offers past "24h" — a fixed,
  // reasonably light resolution, not user-adjustable here (this dialog
  // only ever asks for one range).
  static const _range24h = '-24h';
  static const _agg24h = '2m';

  Future<List<GraphPoint>> _fetchInfluxMetric(MetricDef def) => influxQuery(
    host: widget.influxHost,
    org: widget.influxOrg,
    token: widget.influxToken,
    def: def,
    fluxRange: _range24h,
    aggEvery: _agg24h,
    bucket: widget.bucket,
  );

  Future<List<GraphPoint>> _fetchSkMetric(MetricDef def) => skHistoryQuery(
    host: widget.skHost,
    port: widget.skPort,
    authBase64: widget.skAuthBase64,
    def: def,
    range: const Duration(hours: 24),
    resolution: const Duration(minutes: 2),
  );

  Future<List<GraphPoint>> _metric(MetricDef def) async {
    switch (widget.historySource) {
      case 'sk':
        return _fetchSkMetric(def);
      case 'influx':
        return _fetchInfluxMetric(def);
      default: // 'auto' — same preference order as GraphDialog
        try {
          return await _fetchInfluxMetric(def);
        } catch (_) {
          return _fetchSkMetric(def);
        }
    }
  }

  // Signal K's v2 history API answers position as a plain [lon, lat] list
  // (GeoJSON order), not the {latitude, longitude} object shape live
  // deltas use — see _seedOwnTrackFromHistory's own doc comment for the
  // exact bug this convention already caused once.
  Future<({List<GraphPoint> lat, List<GraphPoint> lon})>
  _fetchSkPosition() async {
    final now = DateTime.now().toUtc();
    final from = now.subtract(const Duration(hours: 24));
    final uri = Uri.http('${widget.skHost}:${widget.skPort}', '/signalk/v2/api/history/values', {
      'context': 'vessels.self',
      'paths': 'navigation.position',
      'from': from.toIso8601String(),
      'to': now.toIso8601String(),
      'resolution': '120',
    });
    final response = await http
        .get(
          uri,
          headers: widget.skAuthBase64.isEmpty
              ? {}
              : {'Authorization': 'Basic ${widget.skAuthBase64}'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final doc = jsonDecode(response.body) as Map<String, dynamic>;
    final data = doc['data'];
    final lat = <GraphPoint>[], lon = <GraphPoint>[];
    if (data is List) {
      for (final row in data) {
        if (row is! List || row.length < 2) continue;
        final dt = DateTime.tryParse(row[0]?.toString() ?? '');
        final pos = row[1];
        if (dt == null || pos is! List || pos.length < 2) continue;
        final lonV = _num(pos[0]);
        final latV = _num(pos[1]);
        if (latV == null || lonV == null) continue;
        lat.add(GraphPoint(time: dt, value: latV));
        lon.add(GraphPoint(time: dt, value: lonV));
      }
    }
    return (lat: lat, lon: lon);
  }

  Future<({List<GraphPoint> lat, List<GraphPoint> lon})>
  _fetchPosition() async {
    switch (widget.historySource) {
      case 'sk':
        return _fetchSkPosition();
      case 'influx':
        return influxPositionQuery(
          host: widget.influxHost,
          org: widget.influxOrg,
          token: widget.influxToken,
          fluxRange: _range24h,
          aggEvery: _agg24h,
          bucket: widget.bucket,
        );
      default:
        try {
          return await influxPositionQuery(
            host: widget.influxHost,
            org: widget.influxOrg,
            token: widget.influxToken,
            fluxRange: _range24h,
            aggEvery: _agg24h,
            bucket: widget.bucket,
          );
        } catch (_) {
          return _fetchSkPosition();
        }
    }
  }

  Future<List<AnchorYawPoint>> _fetch24hSeries() async {
    final results = await Future.wait([
      _fetchPosition(),
      _metric(mHeading),
      _metric(mCog),
    ]);
    final pos = results[0] as ({List<GraphPoint> lat, List<GraphPoint> lon});
    final heading = results[1] as List<GraphPoint>;
    final cog = results[2] as List<GraphPoint>;
    if (pos.lat.isEmpty) return const [];
    // Position is the timeline every other series gets matched onto — a
    // gap in heading/COG at a given instant just means that point's fields
    // stay null (computeYawAnalysis already skips points with no heading).
    GraphPoint? nearest(List<GraphPoint> series, DateTime t) {
      if (series.isEmpty) return null;
      var best = series.first;
      var bestDiff = (best.time.difference(t)).abs();
      for (final p in series) {
        final diff = (p.time.difference(t)).abs();
        if (diff < bestDiff) {
          best = p;
          bestDiff = diff;
        }
      }
      return bestDiff <= const Duration(minutes: 3) ? best : null;
    }

    return [
      for (var i = 0; i < pos.lat.length && i < pos.lon.length; i++)
        AnchorYawPoint(
          t: pos.lat[i].time,
          lat: pos.lat[i].value,
          lon: pos.lon[i].value,
          headingDeg: nearest(heading, pos.lat[i].time)?.value,
          cogDeg: nearest(cog, pos.lat[i].time)?.value,
        ),
    ];
  }

  // A plausible-looking oscillation for DEMO mode — NOT influxQuery's own
  // demoGraphSeries, which random-walks each field independently and would
  // produce heading/position combinations that don't correspond to any
  // real yaw pattern.
  List<AnchorYawPoint> _demo24hSeries() {
    final rnd = math.Random(7);
    final now = DateTime.now();
    const radiusM = 22.0;
    // Sampled every 120s below — a period much shorter than a few times
    // that (e.g. the "última hora" scale of ~100s) would alias into a
    // false, much-longer-looking period once downsampled, exactly the
    // way a real InfluxDB aggregateWindow over 24h would too. 1h is a
    // plausible "wind/tide slowly working the boat around" scale for a
    // 24h demo view, safely above the sampling interval's Nyquist limit.
    const periodSec = 3600.0;
    const amplitudeDeg = 35.0;
    final cosLat = math.cos(widget.anchorLat * math.pi / 180);
    return [
      for (var s = -24 * 3600; s < 0; s += 120)
        () {
          final t = now.add(Duration(seconds: s));
          final yaw =
              amplitudeDeg /
                  2 *
                  math.sin(2 * math.pi * s / periodSec) +
              (rnd.nextDouble() - 0.5) * 4;
          final bearingFromAnchor = yaw * 0.5;
          final rad = bearingFromAnchor * math.pi / 180;
          final dx = radiusM * math.sin(rad);
          final dy = radiusM * math.cos(rad);
          final lat = widget.anchorLat + dy / 110540;
          final lon = widget.anchorLon + dx / (cosLat * 111320);
          final expected = bearingDistanceMeters(
            widget.anchorLat,
            widget.anchorLon,
            lat,
            lon,
          ).bearingDeg;
          return AnchorYawPoint(
            t: t,
            lat: lat,
            lon: lon,
            headingDeg: normalize360(expected + yaw),
            cogDeg: normalize360(expected + yaw * 1.3),
          );
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final result = computeYawAnalysis(
      points: _points,
      anchorLat: widget.anchorLat,
      anchorLon: widget.anchorLon,
    );
    return Dialog.fullscreen(
      backgroundColor: cBg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Guiñada',
                      style: TextStyle(
                        color: cText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: cText),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _ModeButton(
                      label: 'Última hora',
                      selected: !_last24h,
                      onTap: () => _selectMode(false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModeButton(
                      label: 'Últimas 24 h',
                      selected: _last24h,
                      onTap: () => _selectMode(true),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(child: _buildBody(result)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(YawAnalysisResult result) {
    if (_last24h && _loading) {
      return const Center(
        child: CircularProgressIndicator(color: cCyan),
      );
    }
    if (_last24h && _error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No se pudo cargar el histórico: $_error',
            style: const TextStyle(color: cMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (result.samples == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _last24h
                ? 'No hay suficientes datos de rumbo en las últimas 24h.'
                : 'Aún no hay suficiente traza de la última hora — espera '
                      'unos minutos con el ancla fondeada.',
            style: const TextStyle(color: cMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _KpiCard(
                  label: 'Amplitud de guiñada',
                  value: result.yawAmplitudeDeg == null
                      ? '--'
                      : '${result.yawAmplitudeDeg!.round()}°',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _KpiCard(
                  label: 'Período',
                  value: result.oscillationPeriod == null
                      ? '--'
                      : result.oscillationPeriod!.inSeconds < 120
                      ? '${result.oscillationPeriod!.inSeconds} s'
                      : '${(result.oscillationPeriod!.inSeconds / 60).toStringAsFixed(1)} min',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _KpiCard(
                  label: 'Área barrida',
                  value: result.sweptAreaM2 == null
                      ? '--'
                      : '${result.sweptAreaM2!.round()} m²',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${result.samples} muestras',
            style: const TextStyle(color: cMuted, fontSize: 11),
          ),
          const SizedBox(height: 16),
          const Text(
            'Δψ — desalineación respecto a la línea del ancla (°)',
            style: TextStyle(color: cMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 220,
            child: result.yawSeries.isEmpty
                ? const SizedBox.shrink()
                : LineGraph(
                    points: [
                      for (final p in result.yawSeries)
                        GraphPoint(time: p.t, value: p.yawDeg),
                    ],
                    color: cCyan,
                    unit: '°',
                    windowStart: result.yawSeries.first.t,
                    windowEnd: result.yawSeries.last.t,
                    expectedStepMs: _last24h ? 120000 : 3000,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? cCyan : cPanel,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.black : cText,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    ),
  );
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    decoration: BoxDecoration(
      color: cPanel,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: cMuted, fontSize: 10.5),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: cText,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}
