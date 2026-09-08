part of '../main.dart';

// ─── Graph dialog ─────────────────────────────────────────────────────────────
class GraphDialog extends StatefulWidget {
  const GraphDialog({
    super.key,
    required this.metrics,
    required this.historySource,
    required this.influxHost,
    required this.influxOrg,
    required this.influxToken,
    required this.skHost,
    required this.skPort,
    required this.skAuthBase64,
    this.bucket = influxBucketDefault,
    this.archiveBucket = influxBucketDefault,
    this.demo = false,
  });
  final List<MetricDef> metrics;
  final String historySource; // 'auto' | 'influx' | 'sk'
  final String influxHost;
  final String influxOrg;
  final String influxToken;
  final String skHost;
  final int skPort;
  final String skAuthBase64;
  final String bucket;
  final String archiveBucket;
  final bool demo;

  @override
  State<GraphDialog> createState() => _GraphDialogState();
}

typedef AppRange = ({String label, String flux, String agg, bool longRange});
const appRanges = <AppRange>[
  (label: '1h', flux: '-1h', agg: '10s', longRange: false),
  (label: '6h', flux: '-6h', agg: '30s', longRange: false),
  (label: '12h', flux: '-12h', agg: '1m', longRange: false),
  (label: '24h', flux: '-24h', agg: '2m', longRange: false),
  (label: '48h', flux: '-48h', agg: '5m', longRange: false),
  (label: '7d', flux: '-7d', agg: '15m', longRange: true),
  (label: '1 mes', flux: '-30d', agg: '1h', longRange: true),
];

// Signal K sources (KIP/SQLite) sample far more densely than InfluxDB's
// aggregated buckets and only retain a short window, so there's no reason
// to downsample as conservatively as the Influx `agg` steps above — use a
// finer resolution per range instead of reusing the Influx one.
const _skAgg = <String, String>{
  '1h': '2s',
  '6h': '10s',
  '12h': '20s',
  '24h': '30s',
  '48h': '1m',
  '7d': '5m',
  '1 mes': '15m',
};

class _GraphDialogState extends State<GraphDialog> {
  int _mIdx = 0;
  // Default range stays 24h (now index 3, after the new 1h/6h/12h buttons).
  int _rIdx = 3;
  bool _histogramMode = false;
  // Defaults ON for the wind series it applies to: the raw trace is the
  // state the user called useless, so it shouldn't be what they land on.
  bool _smoothMode = true;
  List<GraphPoint> _points = [];
  List<GraphPoint> _windCompanion = [];
  bool _loading = false;
  String? _error;
  bool _usedSk = false;
  // Per-range data availability when the Signal K History API (KIP/SQLite)
  // is in play — null = not checked yet, true/false once known. A short
  // per-series retention (KIP defaults to 24h) means 48h/7d/1mes routinely
  // come back empty, so those range buttons get disabled instead of looking
  // clickable and then silently showing nothing.
  List<bool?> _skRangeAvailable = List.filled(appRanges.length, null);

  MetricDef get _def => widget.metrics[_mIdx];
  bool get _isTrueWindMetric =>
      _def.skPath == mTws.skPath || _def.skPath == mTwd.skPath;

  // Wind is the one family where the raw trace is genuinely unreadable —
  // it oscillates point to point far faster than anything you'd act on
  // ("la grafica de viento... es poco util con tanta oscilacion", reported
  // live 2026-09-07). Other series (temperature, tank level, voltage)
  // change slowly enough that the raw line is already the useful one, so
  // they don't get the toggle at all rather than adding a control that
  // does nothing visible.
  static final _smoothablePaths = {
    mAws.skPath,
    mTws.skPath,
    mAwa.skPath,
    mTwa.skPath,
    mTwd.skPath,
  };
  bool get _canSmooth => _smoothablePaths.contains(_def.skPath);
  // Angles need circular statistics — see smoothSeriesWithBand's own doc
  // comment for why an arithmetic mean is wrong across the wrap seam.
  bool get _isAngleMetric =>
      _def.skPath == mAwa.skPath ||
      _def.skPath == mTwa.skPath ||
      _def.skPath == mTwd.skPath;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final metricIndex = _mIdx;
      final rangeIndex = _rIdx;
      final def = widget.metrics[metricIndex];
      final r = appRanges[_rIdx];
      final (pts, usedSk) = widget.demo
          ? (demoGraphSeries(def, r.flux, r.agg), false)
          : await _queryHistory(r, def);
      var companion = <GraphPoint>[];
      if (def.skPath == mTws.skPath || def.skPath == mTwd.skPath) {
        final companionDef = def.skPath == mTws.skPath ? mTwd : mTws;
        try {
          companion = widget.demo
              ? demoGraphSeries(companionDef, r.flux, r.agg)
              : usedSk
              ? await _fetchSk(r, companionDef)
              : await _fetchInflux(r, companionDef);
        } catch (_) {
          // The primary history remains useful even if its wind companion is
          // unavailable; the graph simply omits the barb strip.
        }
      }
      if (!mounted || metricIndex != _mIdx || rangeIndex != _rIdx) return;
      setState(() {
        _points = pts;
        _windCompanion = companion;
        _loading = false;
        _usedSk = usedSk;
        _skRangeAvailable[_rIdx] = usedSk ? pts.isNotEmpty : null;
      });
      if (usedSk) unawaited(_checkOtherSkRanges());
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  // After landing on SK/KIP data for the current range, silently probe the
  // other ranges so their buttons can be greyed out up front instead of
  // the user tapping into a range that's always going to come back empty.
  Future<void> _checkOtherSkRanges() async {
    for (var i = 0; i < appRanges.length; i++) {
      if (i == _rIdx || _skRangeAvailable[i] != null) continue;
      try {
        final pts = await _fetchSk(appRanges[i], _def);
        if (mounted) setState(() => _skRangeAvailable[i] = pts.isNotEmpty);
      } catch (_) {
        if (mounted) setState(() => _skRangeAvailable[i] = false);
      }
    }
  }

  Future<List<GraphPoint>> _fetchInflux(AppRange r, MetricDef def) =>
      influxQuery(
        host: widget.influxHost,
        org: widget.influxOrg,
        token: widget.influxToken,
        def: def,
        fluxRange: r.flux,
        aggEvery: r.agg,
        bucket: r.longRange ? widget.archiveBucket : widget.bucket,
      );

  Future<List<GraphPoint>> _fetchSk(AppRange r, MetricDef def) =>
      skHistoryQuery(
        host: widget.skHost,
        port: widget.skPort,
        authBase64: widget.skAuthBase64,
        def: def,
        range: parseFluxRange(r.flux),
        resolution: parseAggEvery(_skAgg[r.label] ?? r.agg),
      );

  Future<(List<GraphPoint>, bool)> _queryHistory(
    AppRange r,
    MetricDef def,
  ) async {
    switch (widget.historySource) {
      case 'influx':
        return (await _fetchInflux(r, def), false);
      case 'sk':
        return (await _fetchSk(r, def), true);
      default: // 'auto' — prefer InfluxDB (richer/longer history), fall back
        // to the Signal K History API (e.g. KIP/SQLite) if it fails.
        try {
          return (await _fetchInflux(r, def), false);
        } catch (_) {
          return (await _fetchSk(r, def), true);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: cBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            if (widget.metrics.length > 1) _buildMetricTabs(),
            Expanded(child: _buildBody()),
            if (_points.isNotEmpty) _buildStats(),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: cMuted),
            onPressed: () => Navigator.pop(context),
          ),
          Container(
            width: 44,
            height: 6,
            decoration: BoxDecoration(
              color: _def.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _def.label,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cText,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Toggle between the line chart and a distribution histogram
          // ("% of time spent in each value range") over the same time
          // window/range buttons.
          IconButton(
            icon: Icon(
              _histogramMode ? Icons.show_chart : Icons.bar_chart,
              color: _def.color,
            ),
            tooltip: _histogramMode
                ? 'Ver gráfica de línea'
                : 'Ver distribución',
            onPressed: () => setState(() => _histogramMode = !_histogramMode),
          ),
          if (_canSmooth && !_histogramMode)
            IconButton(
              icon: Icon(
                _smoothMode ? Icons.waves : Icons.blur_on,
                color: _smoothMode ? _def.color : cMuted,
              ),
              tooltip: _smoothMode
                  ? 'Ver serie cruda'
                  : 'Ver media móvil y variación',
              onPressed: () => setState(() => _smoothMode = !_smoothMode),
            ),
          // Range buttons — greyed out and untappable once we know (from a
          // Signal K/KIP probe) that range has no data at all for this
          // series. Horizontally scrollable so adding more ranges never
          // overflows the bar on a narrow screen.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < appRanges.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: GestureDetector(
                      onTap: _skRangeAvailable[i] == false
                          ? null
                          : () {
                              if (_rIdx != i) {
                                setState(() => _rIdx = i);
                                _fetch();
                              }
                            },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _rIdx == i ? _def.color : cPanel2,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          appRanges[i].label,
                          style: TextStyle(
                            color: _skRangeAvailable[i] == false
                                ? const Color(0xff445560)
                                : (_rIdx == i ? cBg : cMuted),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          for (var i = 0; i < widget.metrics.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () {
                  if (_mIdx != i) {
                    setState(() {
                      _mIdx = i;
                      _skRangeAvailable = List.filled(appRanges.length, null);
                    });
                    _fetch();
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _mIdx == i ? widget.metrics[i].color : cPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _mIdx == i
                          ? widget.metrics[i].color
                          : const Color(0xff2a3a44),
                    ),
                  ),
                  child: Text(
                    widget.metrics[i].label,
                    style: TextStyle(
                      color: _mIdx == i ? cBg : cText,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _def.color),
            const SizedBox(height: 12),
            Text(
              'Cargando datos…',
              style: TextStyle(color: _def.color.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, color: cOrange, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Error obteniendo histórico',
                style: TextStyle(color: cOrange, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                widget.historySource == 'sk'
                    ? widget.skHost
                    : widget.influxHost,
                style: const TextStyle(color: cMuted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: cRed, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                onPressed: _fetch,
              ),
            ],
          ),
        ),
      );
    }
    // A KIP series with genuinely no data even at 24h isn't a temporary gap —
    // it means this path was never added to a widget in a KIP screen, so
    // KIP never started sampling it at all. Say so instead of "sin datos".
    if (_points.isEmpty && _usedSk && _skRangeAvailable[0] == false) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, color: cMuted, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Sin histórico en KIP para esta serie',
                style: TextStyle(color: cMuted, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Añade "${_def.skPath}" a un widget en alguna pantalla de KIP para que empiece a registrarla.',
                style: const TextStyle(color: cMuted, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_points.isEmpty) {
      return const Center(
        child: Text('Sin datos', style: TextStyle(color: cMuted, fontSize: 24)),
      );
    }
    if (_histogramMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: _HistogramChart(
          values: _points.map((p) => p.value).toList(),
          unit: _def.unit,
          color: _def.color,
        ),
      );
    }
    final range = parseFluxRange(appRanges[_rIdx].flux);
    final step = parseAggEvery(
      _usedSk
          ? (_skAgg[appRanges[_rIdx].label] ?? appRanges[_rIdx].agg)
          : appRanges[_rIdx].agg,
    );
    final smoothed = (_canSmooth && _smoothMode)
        ? smoothSeriesWithBand(
            _points,
            smoothingWindowFor(range, step),
            circular: _isAngleMetric,
          )
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: LineGraph(
        points: smoothed?.mean ?? _points,
        bandLow: smoothed?.low ?? const [],
        bandHigh: smoothed?.high ?? const [],
        // The barb strip stays on the RAW companion series — barbs are
        // discrete samples of what the wind actually did at that instant,
        // so smoothing them would misrepresent them.
        windSpeeds: _isTrueWindMetric
            ? (_def.skPath == mTws.skPath ? _points : _windCompanion)
            : const [],
        windDirections: _isTrueWindMetric
            ? (_def.skPath == mTwd.skPath ? _points : _windCompanion)
            : const [],
        color: _def.color,
        unit: _def.unit,
        windowStart: DateTime.now().subtract(range),
        windowEnd: DateTime.now(),
        expectedStepMs: step.inMilliseconds.toDouble(),
      ),
    );
  }

  static final RegExp _engineRunTimeRe = RegExp(r'^propulsion\.[^.]+\.runTime');
  static final RegExp _tankLevelRe = RegExp(
    r'^tanks\.[^.]+\.[^.]+\.currentLevel$',
  );

  Widget _buildStats() {
    final values = _points.map((p) => p.value).toList();
    final current = values.last;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    // Engine hours is a lifetime odometer-style counter, not a value that
    // fluctuates — "min/max/trend" is meaningless for it. What's actually
    // useful is how much it grew during the selected period.
    if (_engineRunTimeRe.hasMatch(_def.skPath)) {
      final usedH = values.last - values.first;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Text(
              'Uso en el periodo: ${usedH.toStringAsFixed(1)} h',
              style: const TextStyle(
                color: cText,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Text(
              '${current.toStringAsFixed(1)} h totales',
              style: TextStyle(
                color: _def.color,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }
    if (_tankLevelRe.hasMatch(_def.skPath)) {
      final elapsedHours =
          _points.last.time.difference(_points.first.time).inSeconds.abs() /
          3600.0;
      final q = math.max(1, values.length ~/ 4);
      final early = values.take(q).fold(0.0, (a, b) => a + b) / q;
      final late =
          values.skip(values.length - q).fold(0.0, (a, b) => a + b) / q;
      final usefulChange = _def.tankDangerWhenHigh
          ? late - early
          : early - late;
      final reliable = elapsedHours >= 3 && usefulChange >= 2;
      final ratePctDay = reliable ? usefulChange / elapsedHours * 24 : null;
      final remainingPct = _def.tankDangerWhenHigh
          ? (100 - current).clamp(0, 100)
          : current.clamp(0, 100);
      final daysRemaining = ratePctDay == null || ratePctDay <= 0
          ? null
          : remainingPct / ratePctDay;
      final litersPerDay = ratePctDay == null || _def.tankCapacityL == null
          ? null
          : _def.tankCapacityL! * ratePctDay / 100;
      final estimateLabel = _def.tankDangerWhenHigh
          ? 'LLENADO ESTIMADO'
          : 'CONSUMO ESTIMADO';
      final timeLabel = _def.tankDangerWhenHigh ? 'lleno en' : 'autonomía';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  reliable ? estimateLabel : 'TENDENCIA NO FIABLE',
                  style: TextStyle(
                    color: reliable ? _def.color : cMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${current.toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: _def.color,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              !reliable || daysRemaining == null
                  ? 'Se necesitan ≥3 h y un cambio sostenido ≥2% para estimar.'
                  : '${litersPerDay == null ? '${ratePctDay!.toStringAsFixed(1)}%/día' : '${litersPerDay.toStringAsFixed(1)} L/día'} · $timeLabel ${daysRemaining.toStringAsFixed(1)} días',
              style: const TextStyle(color: cMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final q = math.max(1, values.length ~/ 4);
    final earlySum = values.take(q).fold(0.0, (a, b) => a + b);
    final lateSum = values.skip(values.length - q).fold(0.0, (a, b) => a + b);
    final diff = lateSum / q - earlySum / q;
    final thr = (maxV - minV) * 0.1;
    final trendStr = diff > thr
        ? '↑ Subiendo'
        : diff < -thr
        ? '↓ Bajando'
        : '→ Estable';
    final trendColor = diff > thr
        ? cRed
        : diff < -thr
        ? cGreen
        : cMuted;
    final u = _def.unit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Text(
            trendStr,
            style: TextStyle(
              color: trendColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            '${current.toStringAsFixed(1)} $u',
            style: TextStyle(
              color: _def.color,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Text(
            'Min ${minV.toStringAsFixed(1)}  Max ${maxV.toStringAsFixed(1)} $u',
            style: const TextStyle(color: cMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ─── Distribution histogram (% of time spent in each value range) ─────────────
class _HistogramChart extends StatelessWidget {
  const _HistogramChart({
    required this.values,
    required this.unit,
    required this.color,
  });
  final List<double> values;
  final String unit;
  final Color color;

  // A step that divides the observed range into whole-number bins (e.g.
  // wind in 2kt steps, not "6.3–8.7kt") — chosen from the span so there are
  // roughly 6-10 bins regardless of whether the metric spans 5 units or 50.
  static int _niceStep(double span) {
    if (span <= 8) return 1;
    if (span <= 16) return 2;
    if (span <= 40) return 5;
    if (span <= 80) return 10;
    return 20;
  }

  @override
  Widget build(BuildContext context) {
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final span = maxV - minV;
    final step = _niceStep(span);
    final lowStart = (minV / step).floor() * step;
    final binCount = span > 0
        ? ((maxV - lowStart) / step).ceil().clamp(1, 20)
        : 1;
    final counts = List<int>.filled(binCount, 0);
    for (final v in values) {
      final idx = span > 0
          ? math.min(binCount - 1, ((v - lowStart) / step).floor())
          : 0;
      counts[idx]++;
    }
    final total = values.length;
    final maxCount = counts.reduce(math.max);

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < binCount; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          counts[i] == 0
                              ? ''
                              : '${(counts[i] * 100 / total).round()}%',
                          style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Expanded(
                          child: FractionallySizedBox(
                            alignment: Alignment.bottomCenter,
                            heightFactor: maxCount == 0
                                ? 0.0
                                : math.max(0.02, counts[i] / maxCount),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              decoration: BoxDecoration(
                                color: counts[i] == 0 ? cPanel2 : color,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var i = 0; i < binCount; i++)
              Expanded(
                child: Text(
                  '${(lowStart + step * i).round()}'
                  '${span > 0 ? '–${(lowStart + step * (i + 1)).round()}' : ''}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: cMuted, fontSize: 10),
                ),
              ),
          ],
        ),
        Text(unit, style: const TextStyle(color: cMuted, fontSize: 10)),
      ],
    );
  }
}

// ─── Line graph ───────────────────────────────────────────────────────────────
class LineGraph extends StatefulWidget {
  const LineGraph({
    super.key,
    required this.points,
    required this.color,
    this.unit = '',
    required this.windowStart,
    required this.windowEnd,
    required this.expectedStepMs,
    this.windSpeeds = const [],
    this.windDirections = const [],
    this.bandLow = const [],
    this.bandHigh = const [],
  });
  final List<GraphPoint> points;
  // Min/max envelope drawn as a translucent area behind [points] — empty
  // when the graph is showing the raw trace. Both lists are parallel to
  // [points] (same times, same length); see smoothSeriesWithBand.
  final List<GraphPoint> bandLow;
  final List<GraphPoint> bandHigh;
  final Color color;
  final String unit;
  // The x-axis always spans the *requested* range (24h/48h/7d/1 mes), not
  // just however much data actually came back — a sparse history source
  // (e.g. KIP's short retention) used to make the axis silently shrink to
  // fit only the available span, stretching one real day across the full
  // width and making it look like "1 mes" had a month of data.
  final DateTime windowStart;
  final DateTime windowEnd;
  // Gaps between consecutive points bigger than ~1.8x this get drawn as a
  // break in the line instead of a straight connector, so missing data
  // reads as missing rather than a plausible-looking flat/sloped segment.
  final double expectedStepMs;
  final List<GraphPoint> windSpeeds;
  final List<GraphPoint> windDirections;
  @override
  State<LineGraph> createState() => _LineGraphState();
}

class _LineGraphState extends State<LineGraph> {
  GraphPoint? _sel;

  static const _lPad = 52.0, _rPad = 10.0, _tPad = 10.0;

  void _pick(Offset local, Size size) {
    final pL = _lPad, pR = size.width - _rPad;
    if (local.dx < pL || local.dx > pR) return;
    final pts = widget.points;
    if (pts.isEmpty) return;
    final tFirst = widget.windowStart.millisecondsSinceEpoch.toDouble();
    final tLast = widget.windowEnd.millisecondsSinceEpoch.toDouble();
    final t = tFirst + (local.dx - pL) / (pR - pL) * (tLast - tFirst);
    GraphPoint? best;
    var bestD = double.infinity;
    for (final p in pts) {
      final d = (p.time.millisecondsSinceEpoch - t).abs().toDouble();
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    setState(() => _sel = best);
  }

  Widget _tooltip(GraphPoint sel, Size size) {
    final dt = sel.time.toLocal();
    final dateStr =
        '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    final valStr = '${sel.value.toStringAsFixed(1)} ${widget.unit}';
    final tFirst = widget.windowStart.millisecondsSinceEpoch.toDouble();
    final tLast = widget.windowEnd.millisecondsSinceEpoch.toDouble();
    final pL = _lPad, pR = size.width - _rPad;
    final cx =
        pL +
        (sel.time.millisecondsSinceEpoch - tFirst) /
            (tLast - tFirst).clamp(1, double.infinity) *
            (pR - pL);
    const w = 140.0;
    var left = cx - w / 2;
    left = left.clamp(pL, pR - w);
    return Positioned(
      left: left,
      top: _tPad + 4,
      child: IgnorePointer(
        child: Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xff0d1e2c).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.color.withValues(alpha: 0.7),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                dateStr,
                style: const TextStyle(color: cMuted, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                valStr,
                style: TextStyle(
                  color: widget.color,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (ctx, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      return GestureDetector(
        onTapDown: (e) => _pick(e.localPosition, size),
        onPanUpdate: (e) => _pick(e.localPosition, size),
        onTapUp: (_) => setState(() => _sel = null),
        onPanEnd: (_) => setState(() => _sel = null),
        child: Stack(
          children: [
            CustomPaint(
              painter: _LineGraphPainter(
                points: widget.points,
                color: widget.color,
                selected: _sel,
                windowStart: widget.windowStart,
                windowEnd: widget.windowEnd,
                expectedStepMs: widget.expectedStepMs,
                windSpeeds: widget.windSpeeds,
                windDirections: widget.windDirections,
                bandLow: widget.bandLow,
                bandHigh: widget.bandHigh,
              ),
              child: const SizedBox.expand(),
            ),
            if (_sel != null) _tooltip(_sel!, size),
          ],
        ),
      );
    },
  );
}

class _LineGraphPainter extends CustomPainter {
  const _LineGraphPainter({
    required this.points,
    required this.color,
    this.selected,
    required this.windowStart,
    required this.windowEnd,
    required this.expectedStepMs,
    required this.windSpeeds,
    required this.windDirections,
    this.bandLow = const [],
    this.bandHigh = const [],
  });
  final List<GraphPoint> points;
  final Color color;
  final GraphPoint? selected;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double expectedStepMs;
  final List<GraphPoint> windSpeeds;
  final List<GraphPoint> windDirections;
  final List<GraphPoint> bandLow;
  final List<GraphPoint> bandHigh;

  static const _lPad = 52.0, _rPad = 10.0, _tPad = 10.0, _bPad = 30.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final pL = _lPad, pR = size.width - _rPad;
    final hasWindBarbs = windSpeeds.isNotEmpty && windDirections.isNotEmpty;
    final pT = hasWindBarbs ? 58.0 : _tPad;
    final pB = size.height - _bPad;
    final pW = pR - pL, pH = pB - pT;

    // Y scale — must cover the envelope too, or the band gets clipped at
    // the plot edges and reads as if the wind never went above the line.
    final hasBand =
        bandLow.length == points.length && bandHigh.length == points.length;
    final vals = <double>[
      for (final p in points) p.value,
      if (hasBand) ...[
        for (final p in bandLow) p.value,
        for (final p in bandHigh) p.value,
      ],
    ];
    final sortedVals = List<double>.of(vals)..sort();
    // A single corrupt/spurious sample must not flatten the remaining 99%
    // of a 48 h trace. For sufficiently populated series, scale to the
    // 2nd–98th percentile and clip only the exceptional points at the edge.
    final robust = sortedVals.length >= 20;
    double percentile(double p) =>
        sortedVals[((sortedVals.length - 1) * p).round()];
    var yMin = robust ? percentile(0.02) : sortedVals.first;
    var yMax = robust ? percentile(0.98) : sortedVals.last;
    final ySpan0 = yMax - yMin;
    final pad = ySpan0 < 0.5 ? 0.5 : ySpan0 * 0.08;
    yMin -= pad;
    yMax += pad;
    final ySpan = yMax - yMin;

    // X scale — always the full requested window, not just the span the
    // returned points happen to cover (see the doc comment on LineGraph).
    final tFirst = windowStart.millisecondsSinceEpoch.toDouble();
    final tLast = windowEnd.millisecondsSinceEpoch.toDouble();
    final tSpan = (tLast - tFirst).clamp(1.0, double.infinity);
    final gapThresholdMs = expectedStepMs * 1.8;

    double toX(double t) => pL + (t - tFirst) / tSpan * pW;
    double toY(double v) => pB - (v.clamp(yMin, yMax) - yMin) / ySpan * pH;

    if (hasWindBarbs) {
      final range = windowEnd.difference(windowStart);
      final interval = windBarbInterval(
        range,
        targetCount: math.max(1, (pW / 36).floor()),
      );
      final barbs = sampleWindBarbs(
        tws: windSpeeds,
        twd: windDirections,
        start: windowStart,
        end: windowEnd,
        interval: interval,
      );
      canvas.drawLine(
        const Offset(_lPad, 52),
        Offset(pR, 52),
        Paint()
          ..color = const Color(0xff243b49)
          ..strokeWidth = 1,
      );
      final intervalPainter = TextPainter(
        text: TextSpan(
          text: 'TWD/TWS · cada ${formatWindBarbInterval(interval)}',
          style: const TextStyle(color: cMuted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      intervalPainter.paint(canvas, Offset(pL, 1));
      for (final barb in barbs) {
        final x = toX(barb.time.millisecondsSinceEpoch.toDouble());
        _paintWindBarb(
          canvas,
          Offset(x, 31),
          speedKnots: barb.speedKnots,
          directionDeg: barb.directionDeg,
          color: cOrange,
        );
      }
    }

    // Nice grid step
    double step;
    final yRange = ySpan;
    if (yRange < 5) {
      step = 1;
    } else if (yRange < 15) {
      step = 2;
    } else if (yRange < 40) {
      step = 5;
    } else if (yRange < 100) {
      step = 10;
    } else if (yRange < 250) {
      step = 25;
    } else if (yRange < 500) {
      step = 50;
    } else {
      step = 100;
    }

    final gridPaint = Paint()
      ..color = const Color(0xff1a2c38)
      ..strokeWidth = 1;
    final labelStyle = TextStyle(
      color: const Color(0xff5e7e90),
      fontSize: 10.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // Zero line — thick and bright if in range
    if (yMin < 0 && yMax > 0) {
      final zy = toY(0);
      canvas.drawLine(
        Offset(pL, zy),
        Offset(pR, zy),
        Paint()
          ..color = const Color(0xff4a6070)
          ..strokeWidth = 2.5,
      );
    }

    final gStart = (yMin / step).ceil() * step;
    for (var g = gStart; g <= yMax + 0.001; g += step) {
      final gy = toY(g);
      if (gy < pT - 2 || gy > pB + 2) continue;
      if (g.abs() < step * 0.01 && yMin < 0 && yMax > 0) {
        // skip the regular grid line at 0 — already drawn as zero line above
      } else {
        canvas.drawLine(Offset(pL, gy), Offset(pR, gy), gridPaint);
      }
      final tp = TextPainter(
        text: TextSpan(text: g.round().toString(), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pL - tp.width - 4, gy - tp.height / 2));
    }

    // X labels
    final totalSecs = tSpan / 1000;
    int tickMs;
    String Function(DateTime) tfmt;
    if (totalSecs <= 26 * 3600) {
      tickMs = 3 * 3600 * 1000;
      tfmt = (dt) => '${dt.toLocal().hour.toString().padLeft(2, '0')}h';
    } else if (totalSecs <= 50 * 3600) {
      tickMs = 6 * 3600 * 1000;
      tfmt = (dt) => '${dt.toLocal().hour.toString().padLeft(2, '0')}h';
    } else if (totalSecs <= 8 * 86400) {
      tickMs = 86400 * 1000;
      const days = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
      tfmt = (dt) => days[dt.toLocal().weekday - 1];
    } else {
      tickMs = 7 * 86400 * 1000;
      tfmt = (dt) {
        final l = dt.toLocal();
        return '${l.day}/${l.month}';
      };
    }

    var tick = (((tFirst / tickMs).floor() + 1) * tickMs).toDouble();
    while (tick <= tLast) {
      final tx = toX(tick);
      canvas.drawLine(Offset(tx, pT), Offset(tx, pB), gridPaint);
      final dt = DateTime.fromMillisecondsSinceEpoch(tick.round());
      final tp = TextPainter(
        text: TextSpan(text: tfmt(dt), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(tx - tp.width / 2, pB + 4));
      tick += tickMs;
    }

    // Split into contiguous segments wherever the gap to the next point is
    // bigger than expected — those gaps are missing data (e.g. a source
    // with patchy coverage), not a real flat/sloped transition, so they
    // must not be bridged by a connecting line or fill.
    final segments = <List<GraphPoint>>[];
    for (final p in points) {
      if (segments.isEmpty ||
          p.time.millisecondsSinceEpoch -
                  segments.last.last.time.millisecondsSinceEpoch >
              gapThresholdMs) {
        segments.add([p]);
      } else {
        segments.last.add(p);
      }
    }

    // Min/max envelope, drawn first so the mean line sits on top of it.
    // Uses the SAME segmentation as the line, so a data gap breaks the
    // band too instead of spanning it with a misleading filled block.
    if (hasBand) {
      final bandPaint = Paint()..color = color.withValues(alpha: 0.16);
      var idx = 0;
      for (final seg in segments) {
        if (seg.length < 2) {
          idx += seg.length;
          continue;
        }
        final path = Path();
        for (var k = 0; k < seg.length; k++) {
          final x = toX(seg[k].time.millisecondsSinceEpoch.toDouble());
          final y = toY(bandHigh[idx + k].value);
          k == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
        for (var k = seg.length - 1; k >= 0; k--) {
          path.lineTo(
            toX(seg[k].time.millisecondsSinceEpoch.toDouble()),
            toY(bandLow[idx + k].value),
          );
        }
        path.close();
        canvas.drawPath(path, bandPaint);
        idx += seg.length;
      }
    }

    final fillPath = Path();
    for (final seg in segments) {
      fillPath.moveTo(
        toX(seg.first.time.millisecondsSinceEpoch.toDouble()),
        pB,
      );
      for (final p in seg) {
        fillPath.lineTo(
          toX(p.time.millisecondsSinceEpoch.toDouble()),
          toY(p.value),
        );
      }
      fillPath.lineTo(toX(seg.last.time.millisecondsSinceEpoch.toDouble()), pB);
      fillPath.close();
    }
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0.03)],
        ).createShader(Rect.fromLTWH(pL, pT, pW, pH))
        ..style = PaintingStyle.fill,
    );

    final linePath = Path();
    for (final seg in segments) {
      var started = false;
      for (final p in seg) {
        final px = toX(p.time.millisecondsSinceEpoch.toDouble());
        final py = toY(p.value);
        if (!started) {
          linePath.moveTo(px, py);
          started = true;
        } else {
          linePath.lineTo(px, py);
        }
      }
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // End dot — at the last real sample's own position, not the window
    // edge, so a source with a stale/short tail doesn't show a dot
    // floating at the right margin with an old value.
    final lastPt = points.last;
    final lastX = toX(lastPt.time.millisecondsSinceEpoch.toDouble());
    final lastY = toY(lastPt.value);
    canvas.drawCircle(Offset(lastX, lastY), 5, Paint()..color = color);
    canvas.drawCircle(Offset(lastX, lastY), 3, Paint()..color = cBg);

    // Selected crosshair
    if (selected != null) {
      final sx = toX(selected!.time.millisecondsSinceEpoch.toDouble());
      final sy = toY(selected!.value);
      canvas.drawLine(
        Offset(sx, pT),
        Offset(sx, pB),
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(Offset(sx, sy), 7, Paint()..color = color);
      canvas.drawCircle(Offset(sx, sy), 4.5, Paint()..color = cBg);
    }

    // Border
    canvas.drawRect(
      Rect.fromLTRB(pL, pT, pR, pB),
      Paint()
        ..color = const Color(0xff243040)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_LineGraphPainter old) =>
      old.points != points ||
      old.color != color ||
      old.selected != selected ||
      old.windSpeeds != windSpeeds ||
      old.windDirections != windDirections ||
      old.bandLow != bandLow ||
      old.bandHigh != bandHigh;
}

void _paintWindBarb(
  Canvas canvas,
  Offset origin, {
  required double speedKnots,
  required double directionDeg,
  required Color color,
}) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  if (speedKnots < 2.5) {
    canvas.drawCircle(origin, 3, paint);
    return;
  }

  final radians = directionDeg * math.pi / 180;
  final along = Offset(math.sin(radians), -math.cos(radians));
  final side = Offset(math.cos(radians), math.sin(radians));
  const shaftLength = 18.0;
  final tip = origin + along * shaftLength;
  canvas.drawLine(origin, tip, paint);

  var units = (speedKnots / 5).round() * 5;
  var cursor = tip;
  const featherStep = 3.2;
  while (units >= 50) {
    final back = cursor - along * 5.5;
    final outer = cursor + side * 6.5;
    final flag = Path()
      ..moveTo(cursor.dx, cursor.dy)
      ..lineTo(outer.dx, outer.dy)
      ..lineTo(back.dx, back.dy)
      ..close();
    canvas.drawPath(
      flag,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    cursor = back - along * 1.5;
    units -= 50;
  }
  while (units >= 10) {
    canvas.drawLine(cursor, cursor + side * 6.5, paint);
    cursor -= along * featherStep;
    units -= 10;
  }
  if (units >= 5) canvas.drawLine(cursor, cursor + side * 3.8, paint);
}
