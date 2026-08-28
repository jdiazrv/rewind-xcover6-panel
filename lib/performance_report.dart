import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'data_api.dart';
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
    Future<List<GraphPoint>> fromSk() => skHistoryQuery(
      host: s.host,
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

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = widget.range;
      if (widget.settings.demoMode) {
        _series = {
          'sog': demoGraphSeries(mSog, r.flux, r.agg),
          'stw': demoGraphSeries(mStw, r.flux, r.agg),
          'aws': demoGraphSeries(mAws, r.flux, r.agg),
          'tws': demoGraphSeries(mTws, r.flux, r.agg),
          'heel': demoGraphSeries(mHeel, r.flux, r.agg),
          'twa': demoGraphSeries(mTwa, r.flux, r.agg),
        };
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
  double _avg(List<GraphPoint> pts) =>
      pts.isEmpty ? 0 : pts.map((p) => p.value).reduce((a, b) => a + b) / pts.length;
  double _max(List<GraphPoint> pts) =>
      pts.isEmpty ? 0 : pts.map((p) => p.value).reduce(math.max);
  double _maxAbs(List<GraphPoint> pts) => pts.isEmpty
      ? 0
      : pts.map((p) => p.value.abs()).reduce(math.max);

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
  ) {
    const twaBands = [
      (loDeg: 0, hiDeg: 30),
      (loDeg: 30, hiDeg: 60),
      (loDeg: 60, hiDeg: 90),
      (loDeg: 90, hiDeg: 120),
      (loDeg: 120, hiDeg: 150),
      (loDeg: 150, hiDeg: 180),
    ];
    if (stw.isEmpty || twa.isEmpty || tws.isEmpty) {
      return (
        twsEdges: const [0],
        twaBands: twaBands,
        avgStw: [
          for (final _ in twaBands) <double?>[],
        ],
        counts: [
          for (final _ in twaBands) <int>[],
        ],
      );
    }
    final twsValues = tws.map((p) => p.value).toList();
    final twsMin = twsValues.reduce(math.min);
    final twsMax = twsValues.reduce(math.max);
    final twsSpan = twsMax - twsMin;
    int niceStep(double s) {
      if (s <= 8) return 1;
      if (s <= 16) return 2;
      if (s <= 40) return 5;
      return 10;
    }

    final step = niceStep(twsSpan);
    final twsLow = (twsMin / step).floor() * step;
    final twsBinCount = twsSpan > 0
        ? ((twsMax - twsLow) / step).ceil().clamp(1, 12)
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
    final counts = [
      for (final _ in twaBands) List<int>.filled(twsBinCount, 0),
    ];

    for (final sp in stw) {
      final twaP = nearest(twa, sp.time, tol);
      final twsP = nearest(tws, sp.time, tol);
      if (twaP == null || twsP == null) continue;
      final angle = twaP.value.abs().clamp(0, 180);
      final bandIdx = math.min(
        twaBands.length - 1,
        (angle / 30).floor(),
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
    final polar = _realPolar(stw, twa, tws);

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
    final canvasFont = PdfFont.helvetica(doc.document);

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
          'Periodo: ${r.label} - generado ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
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
          pw.SizedBox(height: 22),
          pw.Text(
            'Polar de datos reales - STW media (kt)',
            style: const pw.TextStyle(
              color: pdfText,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            'Por ángulo de viento (TWA, 0 = proa) y franja de viento real (TWS) - mismos márgenes que la distribución de TWS. Sin curva objetivo con la que comparar, solo lo navegado en este periodo.',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
          ),
          pw.SizedBox(height: 8),
          pw.Center(
            child: pdfPolarChart(
              font: canvasFont,
              polar: polar,
              width: math.min(contentWidth, 340),
            ),
          ),
          pw.SizedBox(height: 12),
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
  double width,
) {
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
    if (s <= 8) return 1;
    if (s <= 16) return 2;
    if (s <= 40) return 5;
    if (s <= 80) return 10;
    return 20;
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
/// period. A proper radial polar plot is future work; this already answers
/// "how fast does the boat actually go at each angle/wind strength" from
/// real logged data, without any assumed/target polar to compare against.
/// Small fixed palette cycled by TWS-band index, so each band gets a
/// stable, distinguishable color across the chart and its legend.
const _polarPalette = [
  pdfCyan,
  pdfGreen,
  pdfOrange,
  pdfPurple,
  pdfTeal,
  pdfYellow,
  pdfRed,
  pdfDarkRed,
];

/// Radial "how fast does the boat actually go" chart — one line per TWS
/// band, plotted STW (radius) against TWA (angle from bow, mirrored
/// port/starboard since the underlying data doesn't distinguish tack).
pw.Widget pdfPolarChart({
  required PdfFont font,
  required PolarData polar,
  required double width,
  double height = 260,
}) {
  return pw.Column(
    children: [
      pw.CustomPaint(
        size: PdfPoint(width, height),
        painter: (canvas, size) {
          var maxStw = 0.0;
          for (final row in polar.avgStw) {
            for (final v in row) {
              if (v != null && v > maxStw) maxStw = v;
            }
          }
          final cx = size.x / 2;
          final cy = size.y - 20;
          final maxR = math.min(size.x / 2 - 16, size.y - 34);
          if (maxStw <= 0 || maxR <= 0) {
            canvas
              ..setFillColor(pdfMuted)
              ..drawString(
                font,
                9,
                'Sin datos suficientes de STW/TWA/TWS en este periodo.',
                8,
                size.y / 2,
              );
            return;
          }
          final ringStep = maxStw <= 4
              ? 1.0
              : maxStw <= 10
              ? 2.0
              : maxStw <= 20
              ? 5.0
              : 10.0;
          final ringCount = (maxStw / ringStep).ceil().clamp(1, 12);
          final rMax = ringCount * ringStep;
          double rPx(double v) => (v / rMax) * maxR;

          // Concentric STW rings.
          for (var i = 1; i <= ringCount; i++) {
            final r = rPx(ringStep * i);
            canvas
              ..setStrokeColor(pdfGrid)
              ..setLineWidth(0.5)
              ..drawEllipse(cx - r, cy - r, r * 2, r * 2)
              ..strokePath()
              ..setFillColor(pdfMuted)
              ..drawString(
                font,
                6,
                (ringStep * i).round().toString(),
                cx + 2,
                cy - r + 1,
              );
          }

          // Radial spokes at every TWA band edge, mirrored L/R — angle 0 is
          // straight up (dead ahead), 90 is abeam, 180 is dead astern.
          final edges = <int>{
            0,
            for (final b in polar.twaBands) b.hiDeg,
          };
          for (final deg in edges) {
            final rad = deg * math.pi / 180;
            final dx = math.sin(rad) * maxR, dy = math.cos(rad) * maxR;
            canvas
              ..setStrokeColor(pdfGrid)
              ..setLineWidth(0.5)
              ..moveTo(cx, cy)
              ..lineTo(cx + dx, cy + dy)
              ..strokePath();
            if (deg != 0) {
              canvas
                ..moveTo(cx, cy)
                ..lineTo(cx - dx, cy + dy)
                ..strokePath();
            }
            if (deg > 0) {
              canvas
                ..setFillColor(pdfMuted)
                ..drawString(
                  font,
                  6,
                  '$deg',
                  cx + dx * 1.04 - 6,
                  cy + dy * 1.04 - 3,
                );
            }
          }

          // One polyline per TWS band, mirrored on both sides; gaps (no
          // samples for a TWA band) simply break the line rather than
          // interpolating across missing data.
          final twsBinCount = polar.twsEdges.length - 1;
          for (var w = 0; w < twsBinCount; w++) {
            final color = _polarPalette[w % _polarPalette.length];
            for (final side in [1, -1]) {
              canvas
                ..setStrokeColor(color)
                ..setLineWidth(1.4);
              var started = false;
              for (var b = 0; b < polar.twaBands.length; b++) {
                final v = polar.avgStw[b][w];
                if (v == null) {
                  started = false;
                  continue;
                }
                final mid =
                    (polar.twaBands[b].loDeg + polar.twaBands[b].hiDeg) / 2;
                final rad = mid * math.pi / 180;
                final r = rPx(v);
                final x = cx + side * math.sin(rad) * r;
                final y = cy + math.cos(rad) * r;
                if (!started) {
                  canvas.moveTo(x, y);
                  started = true;
                } else {
                  canvas.lineTo(x, y);
                }
              }
              canvas.strokePath();
            }
          }
        },
      ),
      pw.SizedBox(height: 6),
      pw.Wrap(
        spacing: 10,
        runSpacing: 4,
        children: [
          for (var w = 0; w < polar.twsEdges.length - 1; w++)
            pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Container(
                  width: 9,
                  height: 9,
                  margin: const pw.EdgeInsets.only(right: 3),
                  color: _polarPalette[w % _polarPalette.length],
                ),
                pw.Text(
                  '${polar.twsEdges[w]}-${polar.twsEdges[w + 1]}kt',
                  style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
                ),
              ],
            ),
        ],
      ),
    ],
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
            cell('${polar.twsEdges[w]}-${polar.twsEdges[w + 1]}kt', header: true),
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
