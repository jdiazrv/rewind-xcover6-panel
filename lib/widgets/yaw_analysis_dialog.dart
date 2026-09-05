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
    required this.anchorLat,
    required this.anchorLon,
    required this.radiusM,
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

  final double anchorLat;
  final double anchorLon;
  final double radiusM;
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
  List<AnchorYawPoint>? _fetched1h;
  List<AnchorYawPoint>? _fetched24h;

  List<AnchorYawPoint> get _points => (_last24h ? _fetched24h : _fetched1h) ?? const [];

  @override
  void initState() {
    super.initState();
    unawaited(_selectMode(false));
  }

  // "para la ultima hora de guiñada coge los datos del historica de
  // signalk" (reported live 2026-09-05) — "Última hora" used to read only
  // the live YawTrackHistory buffer, which is empty right after arming or
  // reconnecting ("espera unos minutos"); it now fetches from history too
  // (same mechanism as "Últimas 24h", just a tighter range/resolution),
  // so both modes work immediately.
  Future<void> _selectMode(bool last24h) async {
    setState(() => _last24h = last24h);
    final alreadyFetched = last24h ? _fetched24h != null : _fetched1h != null;
    if (alreadyFetched) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pts = widget.demo
          ? (last24h ? _demo24hSeries() : _demo1hSeries())
          : await _fetchHistorySeries(last24h: last24h);
      if (!mounted) return;
      setState(() {
        if (last24h) {
          _fetched24h = pts;
        } else {
          _fetched1h = pts;
        }
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

  // "Última hora" mirrors GraphDialog's own '1h' range/resolution choices
  // (see appRanges/_skAgg there); "Últimas 24h" matches every range past
  // that — a fixed, reasonably light resolution, not user-adjustable here
  // (this dialog only ever asks for one range per mode).
  String _fluxRange(bool last24h) => last24h ? '-24h' : '-1h';
  String _aggEvery(bool last24h) => last24h ? '2m' : '10s';
  Duration _skRange(bool last24h) =>
      last24h ? const Duration(hours: 24) : const Duration(hours: 1);
  Duration _skResolution(bool last24h) =>
      last24h ? const Duration(minutes: 2) : const Duration(seconds: 2);

  Future<List<GraphPoint>> _fetchInfluxMetric(
    MetricDef def,
    bool last24h,
  ) => influxQuery(
    host: widget.influxHost,
    org: widget.influxOrg,
    token: widget.influxToken,
    def: def,
    fluxRange: _fluxRange(last24h),
    aggEvery: _aggEvery(last24h),
    bucket: widget.bucket,
  );

  Future<List<GraphPoint>> _fetchSkMetric(MetricDef def, bool last24h) =>
      skHistoryQuery(
        host: widget.skHost,
        port: widget.skPort,
        authBase64: widget.skAuthBase64,
        def: def,
        range: _skRange(last24h),
        resolution: _skResolution(last24h),
      );

  Future<List<GraphPoint>> _metric(MetricDef def, bool last24h) async {
    switch (widget.historySource) {
      case 'sk':
        return _fetchSkMetric(def, last24h);
      case 'influx':
        return _fetchInfluxMetric(def, last24h);
      default: // 'auto' — same preference order as GraphDialog
        try {
          return await _fetchInfluxMetric(def, last24h);
        } catch (_) {
          return _fetchSkMetric(def, last24h);
        }
    }
  }

  // Signal K's v2 history API answers position as a plain [lon, lat] list
  // (GeoJSON order), not the {latitude, longitude} object shape live
  // deltas use — see _seedOwnTrackFromHistory's own doc comment for the
  // exact bug this convention already caused once.
  Future<({List<GraphPoint> lat, List<GraphPoint> lon})> _fetchSkPosition(
    bool last24h,
  ) async {
    final now = DateTime.now().toUtc();
    final from = now.subtract(_skRange(last24h));
    final uri = Uri.http('${widget.skHost}:${widget.skPort}', '/signalk/v2/api/history/values', {
      'context': 'vessels.self',
      'paths': 'navigation.position',
      'from': from.toIso8601String(),
      'to': now.toIso8601String(),
      'resolution': _skResolution(last24h).inSeconds.toString(),
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

  // SK's dedicated position-track accumulator (@signalk/tracks-plugin) —
  // a separate mechanism from the generic History API used above, worth
  // trying whenever that comes back with no position at all: a boat's
  // telemetry historian (InfluxDB/QuestDB/etc) can easily be configured to
  // never log navigation.position (confirmed live on a real boat this
  // session: a QuestDB path-filter only logging electrical/solar) while
  // this plugin still tracks it independently. "no tienen track instalado
  // como plugin?" (reported live 2026-09-05) — yes, confirmed present and
  // live on that boat once checked.
  //
  // Returns null (never throws) on absolutely anything going wrong — this
  // is a best-effort fallback, not a primary path, so any failure here
  // should just mean "no better than what we already tried."
  //
  // The API answers with NO per-point timestamps (a plain GeoJSON
  // MultiLineString) — reconstructed by counting back from "now" at the
  // plugin's own default 60s sampling interval, since real installs
  // essentially never override it. That's approximate, not exact, but
  // computeYawAnalysis already smooths its inputs and this is strictly
  // better than having no position history at all.
  Future<List<({DateTime t, double lat, double lon})>?> _fetchSkTrack() async {
    try {
      final uri = Uri.http(
        '${widget.skHost}:${widget.skPort}',
        '/signalk/v1/api/tracks/self',
      );
      final response = await http
          .get(
            uri,
            headers: widget.skAuthBase64.isEmpty
                ? {}
                : {'Authorization': 'Basic ${widget.skAuthBase64}'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final doc = jsonDecode(response.body);
      if (doc is! Map || doc.isEmpty) return null;
      final track = doc.values.first;
      final coordinates = track is Map ? track['coordinates'] : null;
      if (coordinates is! List) return null;
      final flat = <({double lat, double lon})>[];
      for (final segment in coordinates) {
        if (segment is! List) continue;
        for (final pt in segment) {
          if (pt is! List || pt.length < 2) continue;
          final lon = _num(pt[0]);
          final lat = _num(pt[1]);
          if (lat == null || lon == null) continue;
          flat.add((lat: lat, lon: lon));
        }
      }
      if (flat.isEmpty) return null;
      const sampleInterval = Duration(seconds: 60);
      final now = DateTime.now();
      final n = flat.length;
      return [
        for (var i = 0; i < n; i++)
          (
            t: now.subtract(sampleInterval * (n - 1 - i)),
            lat: flat[i].lat,
            lon: flat[i].lon,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<({List<GraphPoint> lat, List<GraphPoint> lon})> _fetchPosition(
    bool last24h,
  ) async {
    switch (widget.historySource) {
      case 'sk':
        return _fetchSkPosition(last24h);
      case 'influx':
        return influxPositionQuery(
          host: widget.influxHost,
          org: widget.influxOrg,
          token: widget.influxToken,
          fluxRange: _fluxRange(last24h),
          aggEvery: _aggEvery(last24h),
          bucket: widget.bucket,
        );
      default:
        try {
          return await influxPositionQuery(
            host: widget.influxHost,
            org: widget.influxOrg,
            token: widget.influxToken,
            fluxRange: _fluxRange(last24h),
            aggEvery: _aggEvery(last24h),
            bucket: widget.bucket,
          );
        } catch (_) {
          return _fetchSkPosition(last24h);
        }
    }
  }

  Future<List<AnchorYawPoint>> _fetchHistorySeries({
    required bool last24h,
  }) async {
    final results = await Future.wait([
      _fetchPosition(last24h),
      _metric(mHeading, last24h),
      _metric(mCog, last24h),
    ]);
    var pos = results[0] as ({List<GraphPoint> lat, List<GraphPoint> lon});
    final heading = results[1] as List<GraphPoint>;
    final cog = results[2] as List<GraphPoint>;
    if (pos.lat.isEmpty) {
      // "leer tracks" (reported live 2026-09-05) — the standard history
      // path has nothing for position; try SK's own track accumulator
      // before giving up on position entirely (see _fetchSkTrack's own
      // doc comment). Heading/COG, if this server's historian doesn't log
      // them either, just stay null per point — computeYawAnalysis's
      // headingSamples/guinadaSamples split is what turns that into an
      // honest "Guiñada no disponible aquí" instead of a wrong number.
      final track = await _fetchSkTrack();
      if (track != null) {
        pos = (
          lat: [for (final p in track) GraphPoint(time: p.t, value: p.lat)],
          lon: [for (final p in track) GraphPoint(time: p.t, value: p.lon)],
        );
      }
    }
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
    // Matches widget.radiusM (not a fixed value) — computeYawAnalysis
    // filters guiñada to points near full scope, so a demo radius that
    // drifted from the real configured one would silently empty that
    // section out.
    final radiusM = widget.radiusM;
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
          // Calm heading points back toward the anchor (boat→anchor, the
          // reciprocal of anchor→boat) — see yawMisalignmentDeg's own doc
          // comment for why.
          final calmHeading = normalize360(
            bearingDistanceMeters(
              widget.anchorLat,
              widget.anchorLon,
              lat,
              lon,
            ).bearingDeg +
                180,
          );
          return AnchorYawPoint(
            t: t,
            lat: lat,
            lon: lon,
            headingDeg: normalize360(calmHeading + yaw),
            cogDeg: normalize360(calmHeading + yaw * 1.3),
          );
        }(),
    ];
  }

  // Same idea as _demo24hSeries but for the shorter "Última hora" window —
  // sampled every 10s (matches _aggEvery(false)) with a much faster,
  // livelier oscillation appropriate to an hour-scale view rather than a
  // slow multi-hour borneo drift.
  List<AnchorYawPoint> _demo1hSeries() {
    final rnd = math.Random(11);
    final now = DateTime.now();
    final radiusM = widget.radiusM;
    const periodSec = 90.0;
    const amplitudeDeg = 30.0;
    final cosLat = math.cos(widget.anchorLat * math.pi / 180);
    return [
      for (var s = -3600; s < 0; s += 10)
        () {
          final t = now.add(Duration(seconds: s));
          final yaw =
              amplitudeDeg / 2 * math.sin(2 * math.pi * s / periodSec) +
              (rnd.nextDouble() - 0.5) * 3;
          final bearingFromAnchor = yaw * 0.3;
          final rad = bearingFromAnchor * math.pi / 180;
          final dx = radiusM * math.sin(rad);
          final dy = radiusM * math.cos(rad);
          final lat = widget.anchorLat + dy / 110540;
          final lon = widget.anchorLon + dx / (cosLat * 111320);
          final calmHeading = normalize360(
            bearingDistanceMeters(
              widget.anchorLat,
              widget.anchorLon,
              lat,
              lon,
            ).bearingDeg +
                180,
          );
          return AnchorYawPoint(
            t: t,
            lat: lat,
            lon: lon,
            headingDeg: normalize360(calmHeading + yaw),
            cogDeg: normalize360(calmHeading + yaw * 1.3),
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
      radiusM: widget.radiusM,
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
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: cCyan),
      );
    }
    if (_error != null) {
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
                : 'No hay suficientes datos de rumbo en la última hora.',
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
          Text(
            '${result.samples} muestras',
            style: const TextStyle(color: cMuted, fontSize: 11),
          ),
          const SizedBox(height: 14),
          _SectionHeader(
            title: 'BORNEO',
            subtitle:
                'Giro de la POSICIÓN del barco alrededor del ancla — lento, '
                'de gran escala (viento/marea cambiando de dirección).',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _KpiCard(
                  label: 'Arco de borneo',
                  value: result.borneoArcDeg == null
                      ? '--'
                      : '${result.borneoArcDeg!.round()}°',
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
          const SizedBox(height: 10),
          const Text(
            'Rumbo del ancla al barco (°)',
            style: TextStyle(color: cMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 180,
            child: result.borneoSeries.isEmpty
                ? const SizedBox.shrink()
                : LineGraph(
                    points: [
                      for (final p in result.borneoSeries)
                        GraphPoint(time: p.t, value: p.deg),
                    ],
                    color: cOrange,
                    unit: '°',
                    windowStart: result.borneoSeries.first.t,
                    windowEnd: result.borneoSeries.last.t,
                    expectedStepMs: _last24h ? 120000 : 3000,
                  ),
          ),
          const SizedBox(height: 22),
          _SectionHeader(
            title: 'GUIÑADA',
            subtitle:
                'Oscilación del RUMBO (proa) sobre la línea que une el '
                'barco con el ancla — más rápida, independiente de dónde '
                'esté el barco dentro del círculo de borneo.',
          ),
          const SizedBox(height: 8),
          if (result.headingSamples == 0)
            // "poner salvaguarda que el boton guiñada no aparezca si no
            // hay datos de rumbo almacenados" (reported live 2026-09-05)
            // — a permanent situation for this boat's setup (its history
            // provider never logs heading at all), not a wait-and-see one,
            // so the message says so plainly instead of implying it might
            // resolve itself with more time at anchor.
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Este Signal K no está guardando histórico de rumbo — '
                'Guiñada no está disponible aquí (Borneo sí, arriba).',
                style: TextStyle(color: cMuted, fontSize: 12.5),
              ),
            )
          else if (result.guinadaSamples < 4)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Cadena no ha estado tensa (o casi) lo suficiente en esta '
                'ventana como para medir guiñada — solo cuenta el tramo '
                'largado a tope.',
                style: TextStyle(color: cMuted, fontSize: 12.5),
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: _KpiCard(
                    label: 'Amplitud de guiñada',
                    value: result.guinadaAmplitudeDeg == null
                        ? '--'
                        : '${result.guinadaAmplitudeDeg!.round()}°',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _KpiCard(
                    label: 'Período',
                    value: result.guinadaPeriod == null
                        ? '--'
                        : result.guinadaPeriod!.inSeconds < 120
                        ? '${result.guinadaPeriod!.inSeconds} s'
                        : '${(result.guinadaPeriod!.inSeconds / 60).toStringAsFixed(1)} min',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${result.guinadaSamples} de ${result.samples} muestras con '
              'cadena a tope',
              style: const TextStyle(color: cMuted, fontSize: 11),
            ),
            const SizedBox(height: 10),
            const Text(
              'Δψ — desalineación de la proa respecto a la línea del ancla (°)',
              style: TextStyle(color: cMuted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 180,
              child: result.guinadaSeries.isEmpty
                  ? const SizedBox.shrink()
                  : LineGraph(
                      points: [
                        for (final p in result.guinadaSeries)
                          GraphPoint(time: p.t, value: p.deg),
                      ],
                      color: cCyan,
                      unit: '°',
                      windowStart: result.guinadaSeries.first.t,
                      windowEnd: result.guinadaSeries.last.t,
                      expectedStepMs: _last24h ? 120000 : 3000,
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          color: cText,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        subtitle,
        style: const TextStyle(color: cMuted, fontSize: 11.5),
      ),
    ],
  );
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
