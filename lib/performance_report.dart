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

enum PerformanceReportKind { navigation, windAndSailing, complete }

extension PerformanceReportKindLabel on PerformanceReportKind {
  String get label => switch (this) {
    PerformanceReportKind.navigation => 'Navegación',
    PerformanceReportKind.windAndSailing => 'Viento y vela',
    PerformanceReportKind.complete => 'Informe completo',
  };

  String get description => switch (this) {
    PerformanceReportKind.navigation =>
      'Distancia, tiempo navegando, SOG, STW y traza GPS',
    PerformanceReportKind.windAndSailing =>
      'Viento, barbas, escora y polar real',
    PerformanceReportKind.complete =>
      'Navegación, viento y rendimiento a vela en un único PDF',
  };

  IconData get icon => switch (this) {
    PerformanceReportKind.navigation => Icons.route,
    PerformanceReportKind.windAndSailing => Icons.air,
    PerformanceReportKind.complete => Icons.picture_as_pdf_outlined,
  };
}

Future<void> showPerformanceReportPicker(
  BuildContext context, {
  required SettingsModel settings,
}) async {
  var selectedRange = appRanges[3]; // 24 h: useful default, explicit in UI.
  final selection =
      await showDialog<({PerformanceReportKind kind, AppRange range})>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: cPanel,
            title: const Row(
              children: [
                Icon(Icons.assessment_outlined, color: cCyan),
                SizedBox(width: 10),
                Text('INFORMES', style: TextStyle(color: cText)),
              ],
            ),
            content: SizedBox(
              width: 560,
              height: math.min(300, MediaQuery.sizeOf(context).height * 0.58),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'PERIODO',
                      style: TextStyle(
                        color: cMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 7),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<AppRange>(
                        showSelectedIcon: false,
                        segments: [
                          for (final range in appRanges)
                            ButtonSegment(
                              value: range,
                              label: Text(range.label),
                            ),
                        ],
                        selected: {selectedRange},
                        onSelectionChanged: (value) =>
                            setDialogState(() => selectedRange = value.first),
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final kind in PerformanceReportKind.values) ...[
                      Material(
                        color: cPanel2,
                        borderRadius: BorderRadius.circular(10),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          leading: Icon(kind.icon, color: cCyan),
                          title: Text(
                            kind.label,
                            style: const TextStyle(
                              color: cText,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            kind.description,
                            style: const TextStyle(color: cMuted),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            color: cMuted,
                          ),
                          onTap: () =>
                              Navigator.of(dialogContext)
                                  .pop((kind: kind, range: selectedRange)),
                        ),
                      ),
                      if (kind != PerformanceReportKind.values.last)
                        const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      );
  if (selection == null || !context.mounted) return;
  await openPerformanceReport(
    context,
    settings: settings,
    range: selection.range,
    kind: selection.kind,
  );
}

/// Opens one report type for the period selected explicitly in the VNT report
/// chooser. Graph dialogs deliberately no longer expose a generic PDF action:
/// it looked like an export of that one graph while producing unrelated data.
Future<void> openPerformanceReport(
  BuildContext context, {
  required SettingsModel settings,
  required AppRange range,
  PerformanceReportKind kind = PerformanceReportKind.complete,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          PerformanceReportPage(settings: settings, range: range, kind: kind),
    ),
  );
}

class PerformanceReportPage extends StatefulWidget {
  const PerformanceReportPage({
    super.key,
    required this.settings,
    required this.range,
    required this.kind,
  });
  final SettingsModel settings;
  final AppRange range;
  final PerformanceReportKind kind;

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

  Future<List<GraphPoint>> _optionalQuery(MetricDef def) async {
    try {
      return await _query(def);
    } catch (_) {
      return const [];
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
          'twd': demoGraphSeries(mTwd, r.flux, r.agg),
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
          _optionalQuery(mTwd),
          _query(mHeel),
          _query(mTwa),
        ]);
        _series = {
          'sog': results[0],
          'stw': results[1],
          'aws': results[2],
          'tws': results[3],
          'twd': results[4],
          'heel': results[5],
          'twa': results[6],
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
  // reconstruct (lat, lon) pairs. [sog] flags anchored/stationary samples
  // (same SOG<=0.5kt threshold as the polar table): hundreds of GPS-jitter
  // fixes recorded while sitting at anchor used to get connected
  // point-to-point into a tangled scribble instead of the actual transit
  // line ("muchas lineas"). The FIX for that used to just drop every
  // stationary sample outright — which solved the scribble but erased
  // real dwell time from the map entirely, so a report covering a period
  // with real anchoring drew a route that skipped straight from wherever
  // the boat was before dropping anchor to wherever it was after raising
  // it, matching nothing in the boat's actual Signal K track ("no se
  // parece nada", reported live 2026-09-07). Collapsing each contiguous
  // stationary run into ONE averaged point instead keeps both fixes: no
  // jitter scribble, and the stop still shows up as a real point on the
  // route — the same way a chartplotter or MarineTraffic-style track
  // shows a dwell as one knot, not a gap and not a blob.
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

      final raw = <({double lat, double lon, DateTime time, bool moving})>[];
      for (final lp in lats) {
        final lonP = nearest(lons, lp.time);
        if (lonP == null || lp.value.abs() > 90 || lonP.value.abs() > 180) {
          continue;
        }
        var moving = true;
        if (sog.isNotEmpty) {
          final sogP = nearest(sog, lp.time);
          moving = sogP != null && sogP.value > 0.5;
        }
        raw.add((lat: lp.value, lon: lonP.value, time: lp.time, moving: moving));
      }

      final out = <({double lat, double lon, DateTime time})>[];
      var i = 0;
      while (i < raw.length) {
        if (raw[i].moving) {
          out.add((lat: raw[i].lat, lon: raw[i].lon, time: raw[i].time));
          i++;
          continue;
        }
        var j = i;
        var sumLat = 0.0, sumLon = 0.0, n = 0;
        while (j < raw.length && !raw[j].moving) {
          sumLat += raw[j].lat;
          sumLon += raw[j].lon;
          n++;
          j++;
        }
        out.add((lat: sumLat / n, lon: sumLon / n, time: raw[i].time));
        i = j;
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
        title: Text('${widget.kind.label} - ${widget.range.label}'),
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
              pdfFileName: switch (widget.kind) {
                PerformanceReportKind.navigation => 'rewind_navegacion.pdf',
                PerformanceReportKind.windAndSailing =>
                  'rewind_viento_y_vela.pdf',
                PerformanceReportKind.complete => 'rewind_informe_completo.pdf',
              },
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
    final showNavigation = widget.kind != PerformanceReportKind.windAndSailing;
    final showWind = widget.kind != PerformanceReportKind.navigation;
    final r = widget.range;
    final sog = _series['sog'] ?? [];
    final stw = _series['stw'] ?? [];
    final aws = _series['aws'] ?? [];
    final tws = _series['tws'] ?? [];
    final twd = _series['twd'] ?? [];
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
    final canvasFont = PdfFont.helvetica(doc.document);
    final trackMap = showNavigation ? await _fetchTrackMapTiles(_track) : null;

    String fmtDateTime(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final periodStart = now.subtract(rangeDur);

    pw.Widget header() => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '${widget.kind.label} - REWIND',
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
          if (showNavigation)
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
          if (showWind) pw.SizedBox(height: 8),
          if (showWind)
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
          if (showNavigation) ...[
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
          ],
          if (showWind) ...[
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
        ],
      ),
    );

    if (showWind) {
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
              'Evolución del viento verdadero',
              style: const pw.TextStyle(
                color: pdfText,
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 4),
            pdfWindTimeline(
              font: canvasFont,
              tws: tws,
              twd: twd,
              start: periodStart,
              end: now,
              width: contentWidth,
            ),
          ],
        ),
      );
    }

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
          if (showNavigation) ...[
            pw.Text(
              'Traza GPS del periodo',
              style: const pw.TextStyle(
                color: pdfText,
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pdfTrackMap(
              map: trackMap,
              points: _track,
              width: contentWidth,
              tws: tws,
              twd: twd,
            ),
          ],
          if (showWind) ...[
            if (showNavigation) pw.SizedBox(height: 16),
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

/// Draws one meteorological wind barb glyph centered at (originX, originY)
/// — a full shaft pointing the direction the wind blows FROM, with 50/10/5
/// kt pennants/feathers. Shared by the wind timeline chart (origin = a
/// position along the time axis) and the track map (origin = the boat's
/// own charted position at that sample's time), so the same glyph reads
/// consistently in both places instead of two near-duplicate copies
/// drifting apart.
void _drawWindBarbGlyph(
  PdfGraphics canvas,
  double originX,
  double originY,
  WindBarbSample barb, {
  PdfColor color = pdfOrange,
}) {
  canvas
    ..setStrokeColor(color)
    ..setLineWidth(1.15);
  if (barb.speedKnots < 2.5) {
    canvas
      ..drawEllipse(originX - 2, originY - 2, 4, 4)
      ..strokePath();
    return;
  }
  final angle = barb.directionDeg * math.pi / 180;
  final ax = math.sin(angle), ay = math.cos(angle);
  final sx = math.cos(angle), sy = -math.sin(angle);
  const shaft = 14.0;
  final tipX = originX + ax * shaft;
  final tipY = originY + ay * shaft;
  canvas
    ..moveTo(originX, originY)
    ..lineTo(tipX, tipY)
    ..strokePath();
  var units = (barb.speedKnots / 5).round() * 5;
  var cursorX = tipX, cursorY = tipY;
  while (units >= 50) {
    final backX = cursorX - ax * 4.5;
    final backY = cursorY - ay * 4.5;
    canvas
      ..setFillColor(color)
      ..moveTo(cursorX, cursorY)
      ..lineTo(cursorX + sx * 5.5, cursorY + sy * 5.5)
      ..lineTo(backX, backY)
      ..closePath()
      ..fillPath();
    cursorX = backX - ax;
    cursorY = backY - ay;
    units -= 50;
  }
  while (units >= 10) {
    canvas
      ..moveTo(cursorX, cursorY)
      ..lineTo(cursorX + sx * 5.5, cursorY + sy * 5.5)
      ..strokePath();
    cursorX -= ax * 2.7;
    cursorY -= ay * 2.7;
    units -= 10;
  }
  if (units >= 5) {
    canvas
      ..moveTo(cursorX, cursorY)
      ..lineTo(cursorX + sx * 3.2, cursorY + sy * 3.2)
      ..strokePath();
  }
}

pw.Widget pdfWindTimeline({
  required PdfFont font,
  required List<GraphPoint> tws,
  required List<GraphPoint> twd,
  required DateTime start,
  required DateTime end,
  required double width,
  double height = 190,
}) {
  if (tws.isEmpty || twd.isEmpty) {
    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xffe8f5f8),
        borderRadius: pw.BorderRadius.circular(5),
      ),
      child: pw.Text(
        'Sin datos simultáneos de TWS y TWD para dibujar las barbas.',
        style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
      ),
    );
  }

  final interval = windBarbInterval(
    end.difference(start),
    targetCount: math.max(1, (width / 30).floor()),
  );
  final barbs = sampleWindBarbs(
    tws: tws,
    twd: twd,
    start: start,
    end: end,
    interval: interval,
  );
  final visibleTws = tws
      .where((p) => !p.time.isBefore(start) && !p.time.isAfter(end))
      .toList();
  final maxSpeed = visibleTws.isEmpty
      ? 5.0
      : visibleTws.map((p) => p.value).reduce(math.max);
  final yMax = math.max(5.0, (maxSpeed / 5).ceil() * 5.0);
  final rangeMs = math.max(1, end.difference(start).inMilliseconds);

  String axisTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}h';
  }

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        'Curva: TWS en nudos. Barbas: TWD/TWS cada ${formatWindBarbInterval(interval)}. '
        'Media barba = 5 kt; barba completa = 10 kt; triángulo = 50 kt.',
        style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
      ),
      pw.SizedBox(height: 7),
      pw.Container(
        width: width,
        height: height,
        padding: const pw.EdgeInsets.all(4),
        decoration: pw.BoxDecoration(
          color: const PdfColor.fromInt(0xfff5fafb),
          border: pw.Border.all(color: pdfGrid, width: 0.6),
          borderRadius: pw.BorderRadius.circular(5),
        ),
        child: pw.CustomPaint(
          size: PdfPoint(width - 8, height - 8),
          painter: (canvas, size) {
            const pL = 30.0, pB = 18.0;
            final pR = size.x - 6;
            final curveTop = size.y - 43;
            final pW = pR - pL;
            final pH = curveTop - pB;
            double xAt(DateTime time) =>
                pL +
                (time.millisecondsSinceEpoch - start.millisecondsSinceEpoch) /
                    rangeMs *
                    pW;
            double yAt(double speed) =>
                pB + speed.clamp(0.0, yMax).toDouble() / yMax * pH;

            for (var i = 0; i <= 4; i++) {
              final speed = yMax * i / 4;
              final y = yAt(speed);
              canvas
                ..setStrokeColor(pdfGrid)
                ..setLineWidth(0.45)
                ..moveTo(pL, y)
                ..lineTo(pR, y)
                ..strokePath()
                ..setFillColor(pdfMuted)
                ..drawString(font, 6.5, speed.round().toString(), 2, y - 2.5);
            }

            final axisDates = [
              start,
              start.add(Duration(milliseconds: rangeMs ~/ 2)),
              end,
            ];
            for (var i = 0; i < axisDates.length; i++) {
              final label = axisTime(axisDates[i]);
              final x = xAt(axisDates[i]);
              canvas
                ..setFillColor(pdfMuted)
                ..drawString(
                  font,
                  6.5,
                  label,
                  i == 0
                      ? x
                      : i == axisDates.length - 1
                      ? x - 35
                      : x - 17,
                  4,
                );
            }

            final gaps = <int>[];
            for (var i = 1; i < visibleTws.length; i++) {
              final gap = visibleTws[i].time
                  .difference(visibleTws[i - 1].time)
                  .inMilliseconds;
              if (gap > 0) gaps.add(gap);
            }
            gaps.sort();
            final medianGap = gaps.isEmpty
                ? const Duration(minutes: 5).inMilliseconds
                : gaps[gaps.length ~/ 2];
            final breakMs = math.max(
              const Duration(minutes: 20).inMilliseconds,
              medianGap * 4,
            );
            canvas
              ..setStrokeColor(pdfCyan)
              ..setLineWidth(1.5);
            var started = false;
            GraphPoint? previous;
            for (final point in visibleTws) {
              final x = xAt(point.time), y = yAt(point.value);
              if (!started ||
                  (previous != null &&
                      point.time.difference(previous.time).inMilliseconds >
                          breakMs)) {
                canvas.moveTo(x, y);
                started = true;
              } else {
                canvas.lineTo(x, y);
              }
              previous = point;
            }
            canvas.strokePath();

            for (final barb in barbs) {
              _drawWindBarbGlyph(canvas, xAt(barb.time), size.y - 20, barb);
            }
          },
        ),
      ),
    ],
  );
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
  // Wind barbs placed ALONG the route itself, like MarineTraffic's own
  // track view — not on a separate time axis. Optional: a caller with no
  // wind history just gets the plain route/markers, same as before.
  List<GraphPoint> tws = const [],
  List<GraphPoint> twd = const [],
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

  // OSM tiles are 256px each, and the fetched grid's own aspect ratio
  // (cols:rows) almost never matches this report's fixed width:height box
  // — laying the grid out with `Expanded` cells used to force EVERY tile
  // into a cell shaped by the OUTER box instead of the tile's own square
  // shape, and BoxFit.cover cropped each one independently. Neighbouring
  // tiles no longer lined up at their shared edge (each was stretched/
  // cropped by a different amount), so the mosaic looked shredded — "el
  // mapa... se come trozos" (reported live 2026-09-07). Rendering the
  // mosaic at its true natural size first, THEN scaling the whole thing as
  // one unit (same cover math FittedBox itself uses) keeps every tile
  // boundary aligned; only the composed image's own outer edges get
  // cropped, same as a normal cover-fit photo.
  final naturalW = map.cols * 256.0;
  final naturalH = map.rows * 256.0;
  final coverScale = math.max(width / naturalW, height / naturalH);
  final drawnW = naturalW * coverScale;
  final drawnH = naturalH * coverScale;
  final offsetX = (width - drawnW) / 2;
  final offsetY = (height - drawnH) / 2;

  // The route/marker overlay must use this SAME cover transform — not a
  // plain 0..1-over-the-box mapping — or it drifts away from the map
  // underneath it whenever the mosaic's aspect ratio forces a crop.
  (double, double) toCanvas((double, double) frac) {
    final topDownX = offsetX + frac.$1 * drawnW;
    final topDownY = offsetY + frac.$2 * drawnH;
    return (topDownX, height - topDownY); // package:pdf canvases are y-up
  }

  // Barbs ON the route, not on a separate time axis — "los barbs son en
  // la ruta como hace marine traffic" (reported live 2026-09-07). Each
  // sampled TWD/TWS pair is placed at whatever track point is closest in
  // TIME to it, the same nearest-timestamp join used everywhere else in
  // this report.
  final windBarbs = (tws.isEmpty || twd.isEmpty)
      ? const <WindBarbSample>[]
      : sampleWindBarbs(
          tws: tws,
          twd: twd,
          start: points.first.time,
          end: points.last.time,
          interval: windBarbInterval(
            points.last.time.difference(points.first.time),
            targetCount: math.max(1, (width / 90).floor()),
          ),
        );
  (double, double)? nearestTrackCanvasPos(DateTime t) {
    var bestIdx = -1;
    Duration? bestDiff;
    for (var i = 0; i < points.length; i++) {
      final diff = points[i].time.difference(t).abs();
      if (bestDiff == null || diff < bestDiff) {
        bestDiff = diff;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) return null;
    return toCanvas(projected[bestIdx]);
  }

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
            child: pw.FittedBox(
              fit: pw.BoxFit.cover,
              child: pw.SizedBox(
                width: naturalW,
                height: naturalH,
                child: pw.Column(
                  children: List.generate(
                    map.rows,
                    (row) => pw.Row(
                      children: List.generate(
                        map.cols,
                        (col) => pw.Image(
                          pw.MemoryImage(map.tiles[row * map.cols + col]),
                          width: 256,
                          height: 256,
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
              canvas.setStrokeColor(pdfCyan);
              canvas.setLineWidth(1.6);
              for (var i = 0; i < projected.length; i++) {
                final (x, y) = toCanvas(projected[i]);
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
                final (x, y) = toCanvas(frac);
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

              for (final barb in windBarbs) {
                final pos = nearestTrackCanvasPos(barb.time);
                if (pos == null) continue;
                _drawWindBarbGlyph(canvas, pos.$1, pos.$2, barb);
              }
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
