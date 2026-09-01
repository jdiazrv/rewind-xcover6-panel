import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'data_api.dart';
import 'dns_resolve_stub.dart' if (dart.library.io) 'dns_resolve_io.dart';
import 'main.dart';
import 'model_comparison.dart' show pdfInfoCard;
import 'models.dart';
import 'pdf/pdf_theme.dart';
import 'theme.dart';

typedef PolarData = ({
  List<int> twsEdges,
  List<({int loDeg, int hiDeg})> twaBands,
  List<List<double?>> avgStw,
  List<List<int>> counts,
});

/// Opens the performance report for [range] — the same range the caller
/// already has selected (e.g. a GraphDialog's own 1h/6h/12h/... buttons),
/// so the report never asks the user to pick a period a second time.
Future<void> openPerformanceReport(
  BuildContext context, {
  required SettingsModel settings,
  required AppRange range,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PerformanceReportPage(settings: settings, range: range),
    ),
  );
}

class PerformanceReportPage extends StatefulWidget {
  const PerformanceReportPage({
    super.key,
    required this.settings,
    required this.range,
  });
  final SettingsModel settings;
  final AppRange range;

  @override
  State<PerformanceReportPage> createState() => _PerformanceReportPageState();
}

class _PerformanceReportPageState extends State<PerformanceReportPage> {
  bool _loading = true;
  String? _error;
  Map<String, List<GraphPoint>> _series = {};

  // Resolved once per report generation and reused for every Signal K
  // History API call, so all of a report's queries hit the exact same
  // server even if the configured host is an mDNS ".local" name whose
  // resolution can otherwise flip between individual HTTP requests.
  String? _resolvedSkHost;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<List<GraphPoint>> _query(MetricDef def) async {
    final s = widget.settings;
    final r = widget.range;
    Future<List<GraphPoint>> fromInflux() => influxQuery(
      host: s.effectiveInfluxHost,
      org: s.influxOrg,
      token: s.influxToken,
      def: def,
      fluxRange: r.flux,
      aggEvery: r.agg,
      bucket: r.longRange ? s.influxArchiveBucket : s.influxBucket,
    );
    Future<List<GraphPoint>> fromSk() async => skHistoryQuery(
      host: _resolvedSkHost ?? s.host,
      port: s.port,
      authBase64: s.authBase64,
      def: def,
      range: parseFluxRange(r.flux),
      resolution: parseAggEvery(r.agg),
    );
    switch (s.historySource) {
      case 'influx':
        return fromInflux();
      case 'sk':
        return fromSk();
      default:
        try {
          return await fromInflux();
        } catch (_) {
          return fromSk();
        }
    }
  }

  List<({double lat, double lon, DateTime time})> _track = [];

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = widget.range;
      if (!widget.settings.demoMode) {
        _resolvedSkHost = await resolveHostOnce(widget.settings.host);
      }
      if (widget.settings.demoMode) {
        _series = {
          'sog': demoGraphSeries(mSog, r.flux, r.agg),
          'stw': demoGraphSeries(mStw, r.flux, r.agg),
          'aws': demoGraphSeries(mAws, r.flux, r.agg),
          'tws': demoGraphSeries(mTws, r.flux, r.agg),
          'heel': demoGraphSeries(mHeel, r.flux, r.agg),
          'twa': demoGraphSeries(mTwa, r.flux, r.agg),
        };
        _track = []; // No plausible synthetic track worth drawing.
      } else {
        final results = await Future.wait([
          _query(mSog),
          _query(mStw),
          _query(mAws),
          _query(mTws),
          _query(mHeel),
          _query(mTwa),
        ]);
        _series = {
          'sog': results[0],
          'stw': results[1],
          'aws': results[2],
          'tws': results[3],
          'heel': results[4],
          'twa': results[5],
        };
        _track = await _fetchTrackPoints(results[0]);
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  // Position history tends to outlive what the Signal K History API
  // (KIP/SQLite) retains — that backend is geared for recent/live data, not
  // an archive — so unlike the other metrics (which respect the user's
  // chosen history source), the track always tries InfluxDB first when a
  // token is configured, using the same archive-vs-regular bucket the rest
  // of the report already picks by range, and only falls back to Signal K
  // if Influx has nothing for this range. Unlike every other metric here,
  // position isn't stored as its own measurement — signalk-to-influxdb2
  // writes it as a single "navigation.position" measurement with "lat"/"lon"
  // fields, which is why this needs its own query instead of `influxQuery`.
  Future<({List<GraphPoint> lat, List<GraphPoint> lon})>
  _fetchPositionSeries() async {
    final s = widget.settings;
    final r = widget.range;
    if (s.influxToken.isNotEmpty) {
      try {
        final res = await influxPositionQuery(
          host: s.effectiveInfluxHost,
          org: s.influxOrg,
          token: s.influxToken,
          fluxRange: r.flux,
          aggEvery: r.agg,
          bucket: r.longRange ? s.influxArchiveBucket : s.influxBucket,
        );
        if (res.lat.isNotEmpty && res.lon.isNotEmpty) return res;
      } catch (_) {
        // Fall through to the Signal K History API below.
      }
    }
    final results = await Future.wait([
      skHistoryQuery(
        host: _resolvedSkHost ?? s.host,
        port: s.port,
        authBase64: s.authBase64,
        def: const MetricDef('navigation.position.latitude', 'Lat', 'deg'),
        range: parseFluxRange(r.flux),
        resolution: parseAggEvery(r.agg),
      ),
      skHistoryQuery(
        host: _resolvedSkHost ?? s.host,
        port: s.port,
        authBase64: s.authBase64,
        def: const MetricDef('navigation.position.longitude', 'Lon', 'deg'),
        range: parseFluxRange(r.flux),
        resolution: parseAggEvery(r.agg),
      ),
    ]);
    return (lat: results[0], lon: results[1]);
  }

  // GPS position is a compound value (lat+lon), so its two series need
  // joining by nearest timestamp (same technique as _realPolar) to
  // reconstruct (lat, lon) pairs. [sog] filters out anchored/stationary
  // samples (same SOG<=0.5kt threshold as the polar table) — without it,
  // hundreds of GPS-jitter fixes recorded while sitting at anchor get
  // connected point-to-point into a tangled scribble instead of the actual
  // transit line, which is what made the map look like "muchas lineas".
  Future<List<({double lat, double lon, DateTime time})>> _fetchTrackPoints(
    List<GraphPoint> sog,
  ) async {
    try {
      final res = await _fetchPositionSeries();
      final lats = res.lat;
      final lons = res.lon;
      if (lats.isEmpty || lons.isEmpty) return [];
      final tol = Duration(
        seconds: math.max(
          30,
          lats.length > 1
              ? lats[1].time.difference(lats[0].time).inSeconds ~/ 2
              : 60,
        ),
      );
      GraphPoint? nearest(List<GraphPoint> series, DateTime t) {
        GraphPoint? best;
        Duration? bestDiff;
        for (final p in series) {
          final diff = p.time.difference(t).abs();
          if (diff > tol) continue;
          if (bestDiff == null || diff < bestDiff) {
            best = p;
            bestDiff = diff;
          }
        }
        return best;
      }

      final out = <({double lat, double lon, DateTime time})>[];
      for (final lp in lats) {
        final lonP = nearest(lons, lp.time);
        if (lonP == null || lp.value.abs() > 90 || lonP.value.abs() > 180) {
          continue;
        }
        if (sog.isNotEmpty) {
          final sogP = nearest(sog, lp.time);
          if (sogP == null || sogP.value <= 0.5) continue;
        }
        out.add((lat: lp.value, lon: lonP.value, time: lp.time));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: cBg,
      appBar: AppBar(
        backgroundColor: cBg,
        foregroundColor: cText,
        title: Text('Informe de rendimiento - ${widget.range.label}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Error obteniendo histórico: ${friendlyApiError(_error!)}',
                  style: const TextStyle(color: cRed, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : PdfPreview(
              canChangePageFormat: false,
              canChangeOrientation: false,
              canDebug: false,
              allowPrinting: true,
              allowSharing: true,
              pdfFileName: 'rewind_rendimiento.pdf',
              build: (_) => _buildReportPdf(),
            ),
    );
  }

  // ─── Stats ──────────────────────────────────────────────────────────────
  double _avg(List<GraphPoint> pts) => pts.isEmpty
      ? 0
      : pts.map((p) => p.value).reduce((a, b) => a + b) / pts.length;
  double _max(List<GraphPoint> pts) =>
      pts.isEmpty ? 0 : pts.map((p) => p.value).reduce(math.max);
  double _maxAbs(List<GraphPoint> pts) =>
      pts.isEmpty ? 0 : pts.map((p) => p.value.abs()).reduce(math.max);

  // Points are roughly evenly spaced at the range's aggregation interval, so
  // distance ≈ Σ(speed · Δt) using that fixed interval as a stand-in for the
  // real gap between samples — good enough for a summary report, not a
  // navigation-grade log.
  double _distanceNm(List<GraphPoint> sog, Duration interval) {
    final hoursPerSample = interval.inSeconds / 3600.0;
    return sog.fold(0.0, (a, p) => a + p.value * hoursPerSample);
  }

  double _underwayFraction(List<GraphPoint> sog) {
    if (sog.isEmpty) return 0;
    return sog.where((p) => p.value > 0.5).length / sog.length;
  }

  // "Polar de datos reales": average STW by TWA (30° bands, port/starboard
  // combined since a boat's polar is symmetric) × TWS band — the same
  // whole-number TWS margins used by the wind distribution above, so
  // "el margen que haya pedido" (the histogram's bin width) drives this
  // table too. STW/TWA/TWS come back as 3 independent series from the same
  // query window, so they're joined by nearest timestamp rather than by
  // index, tolerant of small gaps between them.
  PolarData _realPolar(
    List<GraphPoint> stw,
    List<GraphPoint> twa,
    List<GraphPoint> tws,
    List<GraphPoint> sog,
  ) {
    const twaBandDeg = 10;
    final twaBands = [
      for (var d = 0; d < 180; d += twaBandDeg)
        (loDeg: d, hiDeg: d + twaBandDeg),
    ];
    if (stw.isEmpty || twa.isEmpty || tws.isEmpty) {
      return (
        twsEdges: const [0],
        twaBands: twaBands,
        avgStw: [for (final _ in twaBands) <double?>[]],
        counts: [for (final _ in twaBands) <int>[]],
      );
    }
    final twsValues = tws.map((p) => p.value).toList();
    final twsMin = twsValues.reduce(math.min);
    final twsMax = twsValues.reduce(math.max);
    final twsSpan = twsMax - twsMin;
    // TWS bands stay narrow (max 2kt) since wind strength changes the
    // predicted speed a lot — a 5kt-wide band used to blur together
    // conditions that sail very differently.
    int niceStep(double s) {
      if (s <= 6) return 1;
      return 2;
    }

    final step = niceStep(twsSpan);
    final twsLow = (twsMin / step).floor() * step;
    final twsBinCount = twsSpan > 0
        ? ((twsMax - twsLow) / step).ceil().clamp(1, 16)
        : 1;
    final twsEdges = [for (var i = 0; i <= twsBinCount; i++) twsLow + step * i];

    GraphPoint? nearest(List<GraphPoint> series, DateTime t, Duration tol) {
      GraphPoint? best;
      Duration? bestDiff;
      for (final p in series) {
        final diff = p.time.difference(t).abs();
        if (diff > tol) continue;
        if (bestDiff == null || diff < bestDiff) {
          best = p;
          bestDiff = diff;
        }
      }
      return best;
    }

    final tol = Duration(
      seconds: math.max(
        30,
        stw.length > 1
            ? stw[1].time.difference(stw[0].time).inSeconds ~/ 2
            : 60,
      ),
    );

    final sums = [
      for (final _ in twaBands) List<double>.filled(twsBinCount, 0),
    ];
    final counts = [for (final _ in twaBands) List<int>.filled(twsBinCount, 0)];

    for (final sp in stw) {
      final twaP = nearest(twa, sp.time, tol);
      final twsP = nearest(tws, sp.time, tol);
      if (twaP == null || twsP == null) continue;
      // Anchored/stationary moments (same SOG>0.5kt threshold used for the
      // "tiempo navegando" stat) would otherwise drag every band's average
      // toward zero with samples that aren't actually sailing.
      final sogP = nearest(sog, sp.time, tol);
      if (sogP == null || sogP.value <= 0.5) continue;
      final angle = twaP.value.abs().clamp(0, 180);
      final bandIdx = math.min(
        twaBands.length - 1,
        (angle / twaBandDeg).floor(),
      );
      final twsIdx = twsSpan > 0
          ? math.min(twsBinCount - 1, ((twsP.value - twsLow) / step).floor())
          : 0;
      if (twsIdx < 0) continue;
      sums[bandIdx][twsIdx] += sp.value;
      counts[bandIdx][twsIdx]++;
    }

    final avgStw = [
      for (var b = 0; b < twaBands.length; b++)
        [
          for (var w = 0; w < twsBinCount; w++)
            counts[b][w] == 0 ? null : sums[b][w] / counts[b][w],
        ],
    ];

    return (
      twsEdges: twsEdges,
      twaBands: twaBands,
      avgStw: avgStw,
      counts: counts,
    );
  }

  Future<Uint8List> _buildReportPdf() async {
    final r = widget.range;
    final sog = _series['sog'] ?? [];
    final stw = _series['stw'] ?? [];
    final aws = _series['aws'] ?? [];
    final tws = _series['tws'] ?? [];
    final heel = _series['heel'] ?? [];
    final twa = _series['twa'] ?? [];
    final interval = parseAggEvery(r.agg);
    final now = DateTime.now();
    final polar = _realPolar(stw, twa, tws, sog);

    final rangeDur = parseFluxRange(r.flux);
    final distanceNm = _distanceNm(sog, interval);
    final underwayFrac = _underwayFraction(sog);
    final underwayDur = Duration(
      seconds: (rangeDur.inSeconds * underwayFrac).round(),
    );

    const margin = 24.0;
    const pageFormat = PdfPageFormat.a4;
    final contentWidth = pageFormat.width - margin * 2;

    final doc = pw.Document();
    final trackMap = await _fetchTrackMapTiles(_track);

    String fmtDateTime(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final periodStart = now.subtract(rangeDur);

    pw.Widget header() => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Informe de rendimiento - REWIND',
          style: const pw.TextStyle(
            color: pdfText,
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.Text(
          'Periodo: ${r.label} - del ${fmtDateTime(periodStart)} al ${fmtDateTime(now)}',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
        ),
        pw.Text(
          'Generado ${fmtDateTime(now)}',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
        ),
        pw.SizedBox(height: 6),
        pw.Divider(color: pdfGrid, height: 1, thickness: 0.6),
        pw.SizedBox(height: 10),
      ],
    );

    final pageTheme = pw.PageTheme(
      pageFormat: pageFormat,
      margin: const pw.EdgeInsets.all(margin),
      theme: pw.ThemeData.base().copyWith(
        defaultTextStyle: const pw.TextStyle(color: pdfText, fontSize: 9),
      ),
      buildBackground: (ctx) =>
          pw.FullPage(ignoreMargins: true, child: pw.Container(color: pdfBg)),
    );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Página ${ctx.pageNumber} / ${ctx.pagesCount}',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 7),
          ),
        ),
        build: (ctx) => [
          header(),
          pw.Row(
            children: [
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'Distancia',
                    '${distanceNm.toStringAsFixed(1)} NM',
                    'periodo completo',
                    pdfCyan,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'Tiempo navegando',
                    '${underwayDur.inHours}h ${underwayDur.inMinutes % 60}m',
                    '${(underwayFrac * 100).round()}% del periodo (SOG>0.5kt)',
                    pdfGreen,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'SOG',
                    '${_avg(sog).toStringAsFixed(1)} kt media',
                    'máx ${_max(sog).toStringAsFixed(1)} kt',
                    pdfGreen,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'STW',
                    '${_avg(stw).toStringAsFixed(1)} kt media',
                    'máx ${_max(stw).toStringAsFixed(1)} kt',
                    pdfTeal,
                  ),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            children: [
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'AWS',
                    '${_avg(aws).toStringAsFixed(1)} kt media',
                    'ráfaga máx ${_max(aws).toStringAsFixed(1)} kt',
                    pdfOrange,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'TWS',
                    '${_avg(tws).toStringAsFixed(1)} kt media',
                    'ráfaga máx ${_max(tws).toStringAsFixed(1)} kt',
                    pdfCyan,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'Escora',
                    '${_maxAbs(heel).toStringAsFixed(0)}° máx',
                    'media ${_avg(heel).toStringAsFixed(0)}°',
                    pdfYellow,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(child: pw.SizedBox()),
            ],
          ),
          pw.SizedBox(height: 22),
          pw.Text(
            'Distribución de SOG',
            style: const pw.TextStyle(
              color: pdfText,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            '% de muestras del periodo en cada franja de velocidad',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
          ),
          pw.SizedBox(height: 6),
          ...pdfHistogramRows(sog, 'kt', pdfGreen, contentWidth),
          pw.SizedBox(height: 18),
          pw.Text(
            'Distribución de viento (TWS)',
            style: const pw.TextStyle(
              color: pdfText,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            '% de muestras del periodo en cada franja de viento real',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
          ),
          pw.SizedBox(height: 6),
          ...pdfHistogramRows(tws, 'kt', pdfCyan, contentWidth),
        ],
      ),
    );

    // Own page — the chart plus its legend plus the table together are
    // taller than the space usually left after the histograms, so sharing
    // a page with them meant the polar routinely got cut/overlapped at the
    // page break.
    doc.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Página ${ctx.pageNumber} / ${ctx.pagesCount}',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 7),
          ),
        ),
        build: (ctx) => [
          header(),
          pw.Text(
            'Traza GPS del periodo',
            style: const pw.TextStyle(
              color: pdfText,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 8),
          pdfTrackMap(map: trackMap, points: _track, width: contentWidth),
          pw.SizedBox(height: 16),
          pw.Text(
            'Polar de datos reales - STW media (kt)',
            style: const pw.TextStyle(
              color: pdfText,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            'Por ángulo de viento (TWA, 0 = proa) y franja de viento real (TWS) - mismos márgenes que la distribución de TWS. Excluye momentos parado (SOG<0.5kt). Sin curva objetivo con la que comparar, solo lo navegado en este periodo.',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
          ),
          pw.SizedBox(height: 8),
          pdfPolarTable(polar, pdfGreen),
        ],
      ),
    );

    return doc.save();
  }
}

/// PDF-widget equivalent of the on-screen `_HistogramChart` (GraphDialog) —
/// same auto-binning logic, rendered as `pw.Container` bars since PDF
/// widgets have no `LayoutBuilder` to size against at paint time.
List<pw.Widget> pdfHistogramRows(
  List<GraphPoint> points,
  String unit,
  PdfColor color,
  double width, {
  int maxStep = 20,
}) {
  if (points.isEmpty) {
    return [
      pw.Text(
        'Sin datos suficientes en este periodo.',
        style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
      ),
    ];
  }
  final values = points.map((p) => p.value).toList();
  final minV = values.reduce(math.min);
  final maxV = values.reduce(math.max);
  final span = maxV - minV;
  // Whole-number bin edges (e.g. "6–8kt", not "6.3–8.7kt") — step chosen
  // from the span so there are roughly 6-10 bins regardless of scale.
  int niceStep(double s) {
    if (s <= 8) return math.min(1, maxStep);
    if (s <= 16) return math.min(2, maxStep);
    if (s <= 40) return math.min(5, maxStep);
    if (s <= 80) return math.min(10, maxStep);
    return maxStep;
  }

  final step = niceStep(span);
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
  const labelWidth = 70.0;
  const pctWidth = 40.0;
  final barMaxWidth = width - labelWidth - pctWidth - 12;

  return [
    for (var i = 0; i < binCount; i++)
      if (counts[i] > 0 || span > 0)
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Row(
            children: [
              pw.SizedBox(
                width: labelWidth,
                child: pw.Text(
                  '${(lowStart + step * i).round()}'
                  '${span > 0 ? '-${(lowStart + step * (i + 1)).round()}' : ''}$unit',
                  style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
                ),
              ),
              pw.Container(
                width: barMaxWidth,
                height: 12,
                color: pdfGrid,
                child: pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Container(
                    width: maxCount == 0
                        ? 0
                        : barMaxWidth * counts[i] / maxCount,
                    height: 12,
                    color: color,
                  ),
                ),
              ),
              pw.SizedBox(
                width: pctWidth,
                child: pw.Text(
                  '${(counts[i] * 100 / total).toStringAsFixed(0)}%',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
  ];
}

/// Real-data polar as a table — TWA bands (rows) × TWS bands (columns),
/// each cell the average STW logged in that combination during the report
/// period, excluding stationary samples (SOG<=0.5kt). Answers "how fast
/// does the boat actually go at each angle/wind strength" from real logged
/// data, without any assumed/target polar to compare against.

/// A fetched grid of OSM tiles covering a track's bounding box, plus enough
/// to re-project any (lat, lon) back onto that grid for overlay drawing.
class TrackMapResult {
  final List<Uint8List> tiles; // row-major, length == cols * rows
  final int cols, rows, z, startX, startY;
  TrackMapResult({
    required this.tiles,
    required this.cols,
    required this.rows,
    required this.z,
    required this.startX,
    required this.startY,
  });

  /// Top-down fractions (0,0 = top-left of the grid image) for a point.
  (double, double) project(double lat, double lon) {
    final n = math.pow(2, z).toDouble();
    final latRad = lat * math.pi / 180;
    final x = (lon + 180) / 360 * n;
    final y =
        (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
        2 *
        n;
    return (
      ((x - startX) / cols).clamp(0.0, 1.0),
      ((y - startY) / rows).clamp(0.0, 1.0),
    );
  }
}

/// Fetches the smallest-area / highest-zoom grid of free OSM tiles (no API
/// key) whose combined area fully covers the track's padded bounding box,
/// capped at [maxCols] x [maxRows] tiles so the request stays bounded.
Future<TrackMapResult?> _fetchTrackMapTiles(
  List<({double lat, double lon, DateTime time})> points, {
  int maxCols = 6,
  int maxRows = 5,
}) async {
  if (points.length < 2) return null;
  try {
    var minLat = points.first.lat, maxLat = points.first.lat;
    var minLon = points.first.lon, maxLon = points.first.lon;
    for (final p in points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    // Pad so the track doesn't touch the tile grid's edges.
    final latPad = math.max((maxLat - minLat) * 0.12, 0.002);
    final lonPad = math.max((maxLon - minLon) * 0.12, 0.002);
    minLat -= latPad;
    maxLat += latPad;
    minLon -= lonPad;
    maxLon += lonPad;

    (double, double) proj(int z, double lat, double lon) {
      final n = math.pow(2, z).toDouble();
      final latRad = lat * math.pi / 180;
      final x = (lon + 180) / 360 * n;
      final y =
          (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
          2 *
          n;
      return (x, y);
    }

    for (var z = 16; z >= 2; z--) {
      final tl = proj(z, maxLat, minLon);
      final br = proj(z, minLat, maxLon);
      final startX = tl.$1.floor();
      final startY = tl.$2.floor();
      final cols = br.$1.ceil() - startX;
      final rows = br.$2.ceil() - startY;
      if (cols < 1 || rows < 1) continue;
      if (cols > maxCols || rows > maxRows) continue;

      final maxTile = math.pow(2, z).toInt();
      if (startY < 0 || startY + rows > maxTile) return null;
      final tiles = <Uint8List>[];
      for (var ty = startY; ty < startY + rows; ty++) {
        for (var tx = startX; tx < startX + cols; tx++) {
          final wrappedX = ((tx % maxTile) + maxTile) % maxTile;
          final uri = Uri.parse(
            'https://tile.openstreetmap.org/$z/$wrappedX/$ty.png',
          );
          final response = await http
              .get(uri, headers: {'User-Agent': 'REWIND-XCover6-panel/1.0'})
              .timeout(const Duration(seconds: 8));
          final type = response.headers['content-type'] ?? '';
          if (response.statusCode != 200 || !type.startsWith('image/')) {
            return null;
          }
          tiles.add(response.bodyBytes);
        }
      }
      return TrackMapResult(
        tiles: tiles,
        cols: cols,
        rows: rows,
        z: z,
        startX: startX,
        startY: startY,
      );
    }
    return null;
  } catch (_) {
    // A real map is useful, but not mandatory for the report.
  }
  return null;
}

/// Full-width GPS track over an OSM tile background, with start (green) and
/// end (red) markers. Falls back to a plain muted note — never an "API key"
/// message, since the OSM tiles behind it need none — when there isn't
/// enough position data to draw a track.
pw.Widget pdfTrackMap({
  required TrackMapResult? map,
  required List<({double lat, double lon, DateTime time})> points,
  required double width,
  double height = 220,
}) {
  if (map == null || points.length < 2) {
    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xffe8f5f8),
        borderRadius: pw.BorderRadius.circular(5),
      ),
      child: pw.Text(
        'Sin datos de posición suficientes para trazar el mapa.',
        style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
      ),
    );
  }

  final projected = points.map((p) => map.project(p.lat, p.lon)).toList();

  // Long gaps between consecutive samples (anchored for days between two
  // separate trips, a signal dropout, etc.) shouldn't be drawn as a straight
  // "teleport" line connecting them — break the stroke there instead. The
  // break threshold scales with the report's own typical sample spacing
  // rather than a fixed duration, since ranges query at very different
  // resolutions (a few seconds for 1h up to an hour for 1 mes).
  final gaps = [
    for (var i = 1; i < points.length; i++)
      points[i].time.difference(points[i - 1].time),
  ]..sort((a, b) => a.compareTo(b));
  final medianGap = gaps.isEmpty
      ? const Duration(minutes: 15)
      : gaps[gaps.length ~/ 2];
  final breakThreshold = medianGap * 4 < const Duration(minutes: 20)
      ? const Duration(minutes: 20)
      : medianGap * 4;

  return pw.Container(
    width: width,
    height: height,
    padding: const pw.EdgeInsets.all(4),
    decoration: pw.BoxDecoration(
      color: const PdfColor.fromInt(0xffe8f5f8),
      borderRadius: pw.BorderRadius.circular(5),
    ),
    child: pw.Stack(
      children: [
        pw.Positioned.fill(
          child: pw.ClipRRect(
            horizontalRadius: 4,
            verticalRadius: 4,
            child: pw.Column(
              children: List.generate(
                map.rows,
                (row) => pw.Expanded(
                  child: pw.Row(
                    children: List.generate(
                      map.cols,
                      (col) => pw.Expanded(
                        child: pw.Image(
                          pw.MemoryImage(map.tiles[row * map.cols + col]),
                          fit: pw.BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        pw.Positioned.fill(
          child: pw.CustomPaint(
            painter: (canvas, size) {
              // Tile fractions above are top-down, but `package:pdf`
              // canvases are y-up (origin bottom-left) — same flip as the
              // polar chart: canvasY = size.y * (1 - yFracTopDown).
              canvas.setStrokeColor(pdfCyan);
              canvas.setLineWidth(1.6);
              for (var i = 0; i < projected.length; i++) {
                final (xf, yf) = projected[i];
                final x = size.x * xf;
                final y = size.y * (1 - yf);
                final gapBefore = i == 0
                    ? Duration.zero
                    : points[i].time.difference(points[i - 1].time);
                if (i == 0 || gapBefore > breakThreshold) {
                  canvas.moveTo(x, y);
                } else {
                  canvas.lineTo(x, y);
                }
              }
              canvas.strokePath();

              void marker((double, double) frac, PdfColor color) {
                final x = size.x * frac.$1;
                final y = size.y * (1 - frac.$2);
                canvas
                  ..setFillColor(color)
                  ..drawEllipse(x - 3, y - 3, 6, 6)
                  ..fillPath()
                  ..setStrokeColor(PdfColors.white)
                  ..setLineWidth(1)
                  ..drawEllipse(x - 4.5, y - 4.5, 9, 9)
                  ..strokePath();
              }

              marker(projected.first, pdfGreen);
              marker(projected.last, pdfRed);
            },
          ),
        ),
      ],
    ),
  );
}

pw.Widget pdfPolarTable(PolarData polar, PdfColor color) {
  final twsBinCount = polar.twsEdges.length - 1;
  if (twsBinCount < 1) {
    return pw.Text(
      'Sin datos suficientes (TWA/TWS/STW) en este periodo.',
      style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
    );
  }
  pw.Widget cell(String text, {bool header = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
    child: pw.Text(
      text,
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
        color: header ? pdfText : pdfMuted,
        fontSize: 8,
        fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );

  return pw.Table(
    border: pw.TableBorder.all(color: pdfGrid, width: 0.5),
    columnWidths: {
      0: const pw.FlexColumnWidth(1.3),
      for (var w = 0; w < twsBinCount; w++) w + 1: const pw.FlexColumnWidth(1),
    },
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: pdfPanel),
        children: [
          cell('TWA \\ TWS', header: true),
          for (var w = 0; w < twsBinCount; w++)
            cell(
              '${polar.twsEdges[w]}-${polar.twsEdges[w + 1]}kt',
              header: true,
            ),
        ],
      ),
      for (var b = 0; b < polar.twaBands.length; b++)
        pw.TableRow(
          children: [
            cell(
              '${polar.twaBands[b].loDeg}-${polar.twaBands[b].hiDeg}°',
              header: true,
            ),
            for (var w = 0; w < twsBinCount; w++)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 5,
                ),
                child: pw.Text(
                  polar.avgStw[b][w] == null
                      ? '--'
                      : polar.avgStw[b][w]!.toStringAsFixed(1),
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    color: polar.avgStw[b][w] == null ? pdfMuted : color,
                    fontSize: 9,
                    fontWeight: polar.avgStw[b][w] == null
                        ? pw.FontWeight.normal
                        : pw.FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
    ],
  );
}
