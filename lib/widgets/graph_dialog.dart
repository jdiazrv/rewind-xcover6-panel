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
    this.settings,
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
  // Only needed for the "Informe de rendimiento" button — null hides it
  // (e.g. call sites that don't have the full SettingsModel handy).
  final SettingsModel? settings;

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
  List<GraphPoint> _points = [];
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
      final r = appRanges[_rIdx];
      final (pts, usedSk) = widget.demo
          ? (demoGraphSeries(_def, r.flux, r.agg), false)
          : await _queryHistory(r);
      if (!mounted) return;
      setState(() {
        _points = pts;
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
        final pts = await _fetchSk(appRanges[i]);
        if (mounted) setState(() => _skRangeAvailable[i] = pts.isNotEmpty);
      } catch (_) {
        if (mounted) setState(() => _skRangeAvailable[i] = false);
      }
    }
  }

  Future<List<GraphPoint>> _fetchInflux(AppRange r) => influxQuery(
    host: widget.influxHost,
    org: widget.influxOrg,
    token: widget.influxToken,
    def: _def,
    fluxRange: r.flux,
    aggEvery: r.agg,
    bucket: r.longRange ? widget.archiveBucket : widget.bucket,
  );

  Future<List<GraphPoint>> _fetchSk(AppRange r) => skHistoryQuery(
    host: widget.skHost,
    port: widget.skPort,
    authBase64: widget.skAuthBase64,
    def: _def,
    range: parseFluxRange(r.flux),
    resolution: parseAggEvery(_skAgg[r.label] ?? r.agg),
  );

  Future<(List<GraphPoint>, bool)> _queryHistory(AppRange r) async {
    switch (widget.historySource) {
      case 'influx':
        return (await _fetchInflux(r), false);
      case 'sk':
        return (await _fetchSk(r), true);
      default: // 'auto' — prefer InfluxDB (richer/longer history), fall back
        // to the Signal K History API (e.g. KIP/SQLite) if it fails.
        try {
          return (await _fetchInflux(r), false);
        } catch (_) {
          return (await _fetchSk(r), true);
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
          if (widget.settings != null)
            IconButton(
              icon: Icon(Icons.picture_as_pdf, color: _def.color),
              tooltip: 'Informe de rendimiento (${appRanges[_rIdx].label})',
              onPressed: () => openPerformanceReport(
                context,
                settings: widget.settings!,
                range: appRanges[_rIdx],
              ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: LineGraph(
        points: _points,
        color: _def.color,
        unit: _def.unit,
        windowStart: DateTime.now().subtract(
          parseFluxRange(appRanges[_rIdx].flux),
        ),
        windowEnd: DateTime.now(),
        expectedStepMs: parseAggEvery(
          _usedSk
              ? (_skAgg[appRanges[_rIdx].label] ?? appRanges[_rIdx].agg)
              : appRanges[_rIdx].agg,
        ).inMilliseconds.toDouble(),
      ),
    );
  }

  static final RegExp _engineRunTimeRe = RegExp(r'^propulsion\.[^.]+\.runTime');

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
  });
  final List<GraphPoint> points;
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
  });
  final List<GraphPoint> points;
  final Color color;
  final GraphPoint? selected;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double expectedStepMs;

  static const _lPad = 52.0, _rPad = 10.0, _tPad = 10.0, _bPad = 30.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final pL = _lPad, pR = size.width - _rPad;
    final pT = _tPad, pB = size.height - _bPad;
    final pW = pR - pL, pH = pB - pT;

    // Y scale
    final vals = points.map((p) => p.value).toList();
    var yMin = vals.reduce(math.min), yMax = vals.reduce(math.max);
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
    double toY(double v) => pB - (v - yMin) / ySpan * pH;

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
      old.points != points || old.color != color || old.selected != selected;
}
