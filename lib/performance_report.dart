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
    PerformanceReportKind.navigation => 'Rendimiento del barco',
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

const _reportHorizonMinutes = 72 * 60;
const _reportMaxPeriodMinutes = 24 * 60;
const _reportStepMinutes = 15;

String _reportDateTime(DateTime value) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)} ${two(value.hour)}:${two(value.minute)}';
}

String _reportDurationLabel(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 60) return '$minutes min';
  if (minutes % 60 == 0) return '${minutes ~/ 60} h';
  return '${minutes ~/ 60} h ${minutes % 60} min';
}

AppRange _reportRangeFor(Duration duration) {
  final minutes = duration.inMinutes;
  final agg = switch (minutes) {
    <= 60 => '10s',
    <= 6 * 60 => '30s',
    <= 12 * 60 => '1m',
    _ => '2m',
  };
  return (
    label: _reportDurationLabel(duration),
    flux: '-${math.max(_reportStepMinutes, minutes)}m',
    agg: agg,
    longRange: false,
  );
}

/// Applies the report picker's 15-minute grid and 24-hour maximum without
/// moving the opposite handle. Public so the interaction contract can be
/// covered by a small unit test independently of the PDF/network layer.
RangeValues normalizeReportRange(RangeValues current, RangeValues proposed) {
  double snap(double value) =>
      (value / _reportStepMinutes).round() * _reportStepMinutes.toDouble();
  var start = snap(proposed.start).clamp(0, _reportHorizonMinutes.toDouble());
  var end = snap(proposed.end).clamp(0, _reportHorizonMinutes.toDouble());
  final startMoved =
      (proposed.start - current.start).abs() >=
      (proposed.end - current.end).abs();
  if (startMoved) {
    start = start.clamp(
      math.max(0.0, end - _reportMaxPeriodMinutes),
      end - _reportStepMinutes,
    );
  } else {
    end = end.clamp(
      start + _reportStepMinutes,
      math.min(
        _reportHorizonMinutes.toDouble(),
        start + _reportMaxPeriodMinutes,
      ),
    );
  }
  return RangeValues(start.toDouble(), end.toDouble());
}

class _ReportPeriodSelector extends StatelessWidget {
  const _ReportPeriodSelector({
    required this.referenceNow,
    required this.values,
    required this.onChanged,
  });

  final DateTime referenceNow;
  final RangeValues values;
  final ValueChanged<RangeValues> onChanged;

  DateTime _timeFor(double minutes) => referenceNow
      .subtract(const Duration(hours: 72))
      .add(Duration(minutes: minutes.round()));

  @override
  Widget build(BuildContext context) {
    final duration = Duration(minutes: (values.end - values.start).round());
    return Column(
      children: [
        Text(
          'Inicio ${_reportDateTime(_timeFor(values.start))}  ·  '
          'Fin ${_reportDateTime(_timeFor(values.end))}  ·  '
          '${_reportDurationLabel(duration)}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: cText,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(
          height: 102,
          child: LayoutBuilder(
            builder: (context, constraints) {
              const markerWidth = 116.0;
              const markerHeight = 34.0;
              final width = constraints.maxWidth;
              final startCenter = width * values.start / _reportHorizonMinutes;
              final endCenter = width * values.end / _reportHorizonMinutes;

              Widget marker(double center, String text, bool above) {
                final left = (center - markerWidth / 2)
                    .clamp(0.0, math.max(0.0, width - markerWidth))
                    .toDouble();
                return Positioned(
                  left: left,
                  top: above ? 0 : 68,
                  width: markerWidth,
                  height: markerHeight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (details) {
                      final deltaMinutes =
                          details.delta.dx / width * _reportHorizonMinutes;
                      onChanged(
                        above
                            ? RangeValues(
                                values.start + deltaMinutes,
                                values.end,
                              )
                            : RangeValues(
                                values.start,
                                values.end + deltaMinutes,
                              ),
                      );
                    },
                    child: CustomPaint(
                      painter: _ReportMarkerPainter(
                        pointerDown: above,
                        pointerX: (center - left)
                            .clamp(8.0, markerWidth - 8)
                            .toDouble(),
                      ),
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: above ? 0 : 5,
                            bottom: above ? 5 : 0,
                          ),
                          child: Text(
                            text,
                            style: const TextStyle(
                              color: cText,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 27,
                    height: 48,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: cCyan,
                        inactiveTrackColor: Colors.white24,
                        rangeThumbShape: const _InvisibleRangeThumbShape(),
                        rangeValueIndicatorShape:
                            const PaddleRangeSliderValueIndicatorShape(),
                        showValueIndicator: ShowValueIndicator.never,
                        overlayColor: cCyan.withValues(alpha: 0.14),
                      ),
                      child: RangeSlider(
                        min: 0,
                        max: _reportHorizonMinutes.toDouble(),
                        divisions: _reportHorizonMinutes ~/ _reportStepMinutes,
                        values: values,
                        onChanged: onChanged,
                      ),
                    ),
                  ),
                  marker(
                    startCenter,
                    _reportDateTime(_timeFor(values.start)),
                    true,
                  ),
                  marker(
                    endCenter,
                    _reportDateTime(_timeFor(values.end)),
                    false,
                  ),
                ],
              );
            },
          ),
        ),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('−72 h', style: TextStyle(color: cMuted, fontSize: 10)),
            Text('ahora', style: TextStyle(color: cMuted, fontSize: 10)),
          ],
        ),
      ],
    );
  }
}

class _InvisibleRangeThumbShape extends RangeSliderThumbShape {
  const _InvisibleRangeThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(2, 2);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool isOnTop = false,
    bool isPressed = false,
    required SliderThemeData sliderTheme,
    TextDirection textDirection = TextDirection.ltr,
    Thumb thumb = Thumb.start,
  }) {}
}

class _ReportMarkerPainter extends CustomPainter {
  const _ReportMarkerPainter({
    required this.pointerDown,
    required this.pointerX,
  });

  final bool pointerDown;
  final double pointerX;

  @override
  void paint(Canvas canvas, Size size) {
    const pointerHeight = 6.0;
    final rect = pointerDown
        ? Rect.fromLTRB(0, 0, size.width, size.height - pointerHeight)
        : Rect.fromLTRB(0, pointerHeight, size.width, size.height);
    final fill = Paint()..color = cPanel2;
    final border = Paint()
      ..color = cCyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    final box = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(box, fill);
    canvas.drawRRect(box, border);
    final tipY = pointerDown ? size.height : 0.0;
    final baseY = pointerDown ? size.height - pointerHeight : pointerHeight;
    final pointer = Path()
      ..moveTo(pointerX - 6, baseY)
      ..lineTo(pointerX, tipY)
      ..lineTo(pointerX + 6, baseY)
      ..close();
    canvas.drawPath(pointer, fill);
    canvas.drawPath(pointer, border);
  }

  @override
  bool shouldRepaint(covariant _ReportMarkerPainter oldDelegate) =>
      oldDelegate.pointerDown != pointerDown ||
      oldDelegate.pointerX != pointerX;
}

Future<void> showPerformanceReportPicker(
  BuildContext context, {
  required SettingsModel settings,
}) async {
  // Freeze "now" while this dialog is open: otherwise both labels would
  // drift under the user's fingers even though neither marker had moved.
  final referenceNow = DateTime.now();
  var selectedPeriod = RangeValues(
    (_reportHorizonMinutes - _reportMaxPeriodMinutes).toDouble(),
    _reportHorizonMinutes.toDouble(),
  );
  Duration? selectedBarbInterval;
  final selection =
      await showDialog<
        ({
          PerformanceReportKind kind,
          DateTime start,
          DateTime end,
          Duration? barbInterval,
        })
      >(
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
              height: math.min(410, MediaQuery.sizeOf(context).height * 0.7),
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
                    const SizedBox(height: 4),
                    _ReportPeriodSelector(
                      referenceNow: referenceNow,
                      values: selectedPeriod,
                      onChanged: (value) => setDialogState(
                        () => selectedPeriod = normalizeReportRange(
                          selectedPeriod,
                          value,
                        ),
                      ),
                    ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final hours in const [1, 3, 6, 12, 24])
                          ChoiceChip(
                            visualDensity: VisualDensity.compact,
                            label: Text('$hours h'),
                            selected:
                                selectedPeriod.end == _reportHorizonMinutes &&
                                selectedPeriod.end - selectedPeriod.start ==
                                    hours * 60,
                            onSelected: (_) => setDialogState(
                              () => selectedPeriod = RangeValues(
                                (_reportHorizonMinutes - hours * 60).toDouble(),
                                _reportHorizonMinutes.toDouble(),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'BARBAS DE VIENTO',
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
                      child: SegmentedButton<Duration?>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: null, label: Text('Auto')),
                          ButtonSegment(
                            value: Duration(minutes: 30),
                            label: Text('30 min'),
                          ),
                          ButtonSegment(
                            value: Duration(hours: 1),
                            label: Text('1 h'),
                          ),
                          ButtonSegment(
                            value: Duration(hours: 3),
                            label: Text('3 h'),
                          ),
                        ],
                        selected: {selectedBarbInterval},
                        onSelectionChanged: (value) => setDialogState(
                          () => selectedBarbInterval = value.first,
                        ),
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
                          onTap: () {
                            final horizonStart = referenceNow.subtract(
                              const Duration(hours: 72),
                            );
                            Navigator.of(dialogContext).pop((
                              kind: kind,
                              start: horizonStart.add(
                                Duration(minutes: selectedPeriod.start.round()),
                              ),
                              end: horizonStart.add(
                                Duration(minutes: selectedPeriod.end.round()),
                              ),
                              barbInterval: selectedBarbInterval,
                            ));
                          },
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
    start: selection.start,
    end: selection.end,
    kind: selection.kind,
    barbInterval: selection.barbInterval,
  );
}

/// Opens one report type for the period selected explicitly in the VNT report
/// chooser. Graph dialogs deliberately no longer expose a generic PDF action:
/// it looked like an export of that one graph while producing unrelated data.
Future<void> openPerformanceReport(
  BuildContext context, {
  required SettingsModel settings,
  required DateTime start,
  required DateTime end,
  PerformanceReportKind kind = PerformanceReportKind.complete,
  Duration? barbInterval,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PerformanceReportPage(
        settings: settings,
        start: start,
        end: end,
        kind: kind,
        barbInterval: barbInterval,
      ),
    ),
  );
}

class PerformanceReportPage extends StatefulWidget {
  const PerformanceReportPage({
    super.key,
    required this.settings,
    required this.start,
    required this.end,
    required this.kind,
    this.barbInterval,
  });
  final SettingsModel settings;
  final DateTime start;
  final DateTime end;
  final PerformanceReportKind kind;
  final Duration? barbInterval;

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

  AppRange get _range {
    final base = _reportRangeFor(widget.end.difference(widget.start));
    return (
      label: base.label,
      flux: base.flux,
      agg: base.agg,
      // A short interval can still sit near the old end of the 72-hour
      // selector, outside the raw bucket's normal retention window.
      longRange: widget.start.isBefore(
        DateTime.now().subtract(const Duration(hours: 48)),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<List<GraphPoint>> _query(MetricDef def) async {
    final s = widget.settings;
    final r = _range;
    Future<List<GraphPoint>> fromInflux() => influxQuery(
      host: s.effectiveInfluxHost,
      org: s.influxOrg,
      token: s.influxToken,
      def: def,
      fluxRange: r.flux,
      aggEvery: r.agg,
      start: widget.start,
      stop: widget.end,
      bucket: r.longRange ? s.influxArchiveBucket : s.influxBucket,
    );
    Future<List<GraphPoint>> fromSk() async => skHistoryQuery(
      host: _resolvedSkHost ?? s.host,
      port: s.port,
      authBase64: s.authBase64,
      def: def,
      range: parseFluxRange(r.flux),
      resolution: parseAggEvery(r.agg),
      start: widget.start,
      stop: widget.end,
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
      final r = _range;
      if (!widget.settings.demoMode) {
        _resolvedSkHost = await resolveHostOnce(widget.settings.host);
      }
      if (widget.settings.demoMode) {
        _series = {
          'sog': demoGraphSeries(
            mSog,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
          'stw': demoGraphSeries(
            mStw,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
          'aws': demoGraphSeries(
            mAws,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
          'tws': demoGraphSeries(
            mTws,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
          'twd': demoGraphSeries(
            mTwd,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
          'heel': demoGraphSeries(
            mHeel,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
          'twa': demoGraphSeries(
            mTwa,
            r.flux,
            r.agg,
            start: widget.start,
            stop: widget.end,
          ),
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
    final r = _range;
    if (s.influxToken.isNotEmpty) {
      try {
        final res = await influxPositionQuery(
          host: s.effectiveInfluxHost,
          org: s.influxOrg,
          token: s.influxToken,
          fluxRange: r.flux,
          aggEvery: r.agg,
          start: widget.start,
          stop: widget.end,
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
        start: widget.start,
        stop: widget.end,
      ),
      skHistoryQuery(
        host: _resolvedSkHost ?? s.host,
        port: s.port,
        authBase64: s.authBase64,
        def: const MetricDef('navigation.position.longitude', 'Lon', 'deg'),
        range: parseFluxRange(r.flux),
        resolution: parseAggEvery(r.agg),
        start: widget.start,
        stop: widget.end,
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
        raw.add((
          lat: lp.value,
          lon: lonP.value,
          time: lp.time,
          moving: moving,
        ));
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
        title: Text('${widget.kind.label} - ${_range.label}'),
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

  int _coveragePct(List<GraphPoint> points, Duration range, Duration step) {
    if (points.isEmpty || step.inSeconds <= 0) return 0;
    final expected = math.max(1, range.inSeconds / step.inSeconds);
    return (points.length / expected * 100).round().clamp(0, 100);
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
    final r = _range;
    final sog = _series['sog'] ?? [];
    final stw = _series['stw'] ?? [];
    final aws = _series['aws'] ?? [];
    final tws = _series['tws'] ?? [];
    final twd = _series['twd'] ?? [];
    final heel = _series['heel'] ?? [];
    final twa = _series['twa'] ?? [];
    final interval = parseAggEvery(r.agg);
    final generatedAt = DateTime.now();
    final polar = _realPolar(stw, twa, tws, sog);

    final rangeDur = widget.end.difference(widget.start);
    final distanceNm = _distanceNm(sog, interval);
    final underwayFrac = _underwayFraction(sog);
    final underwayDur = Duration(
      seconds: (rangeDur.inSeconds * underwayFrac).round(),
    );
    final coverageParts = <String>[
      if (showNavigation) 'SOG ${_coveragePct(sog, rangeDur, interval)}%',
      if (showNavigation) 'STW ${_coveragePct(stw, rangeDur, interval)}%',
      if (showWind) 'TWS ${_coveragePct(tws, rangeDur, interval)}%',
      if (showWind) 'TWD ${_coveragePct(twd, rangeDur, interval)}%',
      if (showWind) 'TWA ${_coveragePct(twa, rangeDur, interval)}%',
      if (showWind) 'escora ${_coveragePct(heel, rangeDur, interval)}%',
    ];

    const margin = 24.0;
    const pageFormat = PdfPageFormat.a4;
    final contentWidth = pageFormat.width - margin * 2;

    final doc = pw.Document();
    final canvasFont = PdfFont.helvetica(doc.document);
    // Must match pdfTrackMap's own inner box (its default 220pt height,
    // both minus the 4pt padding on each side) — the tile grid is
    // stretched to this aspect so the whole route fits without cropping.
    const trackMapHeight = 220.0;
    final trackMap = showNavigation
        ? await _fetchTrackMapTiles(
            _track,
            targetAspect: (contentWidth - 8) / (trackMapHeight - 8),
          )
        : null;

    String fmtDateTime(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final periodStart = widget.start;
    final periodEnd = widget.end;

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
          'Periodo: ${r.label} - del ${fmtDateTime(periodStart)} al ${fmtDateTime(periodEnd)}',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 9),
        ),
        pw.Text(
          'Generado ${fmtDateTime(generatedAt)}',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
        ),
        pw.Text(
          'Cobertura de muestras: ${coverageParts.join(' · ')}',
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
              end: periodEnd,
              width: contentWidth,
              barbInterval: widget.barbInterval,
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
              barbInterval: widget.barbInterval,
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
  Duration? barbInterval,
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

  final interval =
      barbInterval ??
      windBarbInterval(
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
  final speedValues = visibleTws.map((p) => p.value).toList()..sort();
  final maxSpeed = speedValues.isEmpty
      ? 5.0
      : speedValues.length < 20
      ? speedValues.last
      : speedValues[((speedValues.length - 1) * 0.98).round()];
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
  // Aspect ratio (w/h) of the box this mosaic will be drawn into. The
  // padded bounding box is stretched to match it BEFORE tiles are chosen,
  // which is what makes "cover the box" and "show the whole track" the
  // same thing at draw time. Without this the two genuinely conflict
  // whenever the route's shape differs from the box's — filling the box
  // then necessarily crops the ends of the route off the page ("se come
  // coordenadas del inicio y final", reported live 2026-09-07).
  double targetAspect = 1.0,
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

    // Normalized Web-Mercator (0..1 over the whole world) — the aspect
    // stretch has to happen HERE, not in raw degrees: a degree of latitude
    // and a degree of longitude are different distances on the map, and
    // Mercator's own latitude scaling makes that ratio change with
    // latitude, so matching aspect in degrees would be wrong except at
    // the equator.
    double mercX(double lon) => (lon + 180) / 360;
    double mercY(double lat) {
      final r = lat * math.pi / 180;
      return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2;
    }

    double invMercY(double y) {
      final n = math.pi * (1 - 2 * y);
      return math.atan(0.5 * (math.exp(n) - math.exp(-n))) * 180 / math.pi;
    }

    var x0 = mercX(minLon), x1 = mercX(maxLon);
    var y0 = mercY(maxLat), y1 = mercY(minLat); // y grows southward
    final spanX = x1 - x0, spanY = y1 - y0;
    if (spanX <= 0 || spanY <= 0) return null;
    if (spanX / spanY < targetAspect) {
      // Too tall for the box — widen it.
      final want = spanY * targetAspect;
      final cx = (x0 + x1) / 2;
      x0 = cx - want / 2;
      x1 = cx + want / 2;
    } else {
      // Too wide — heighten it.
      final want = spanX / targetAspect;
      final cy = (y0 + y1) / 2;
      y0 = cy - want / 2;
      y1 = cy + want / 2;
    }
    if (y0 < 0 || y1 > 1) return null; // ran off the poles — not plottable
    minLon = x0 * 360 - 180;
    maxLon = x1 * 360 - 180;
    maxLat = invMercY(y0);
    minLat = invMercY(y1);

    (double, double) proj(int z, double lat, double lon) {
      final n = math.pow(2, z).toDouble();
      return (mercX(lon) * n, mercY(lat) * n);
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
  Duration? barbInterval,
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

  // The Stack below sits inside 4pt of padding, so every measurement here
  // must be in that INNER space — the CustomPaint's own `size` is the
  // inner box, and mixing the two would offset the route from the tiles
  // it's drawn over by exactly that padding.
  final innerW = math.max(width - 8, 1.0);
  final innerH = math.max(height - 8, 1.0);

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
  // Scale to fit the TRACK's own bounding box, not the whole tile grid.
  // Cover-fitting the grid meant whichever axis overflowed got its edges
  // cropped — and the track's start/end sit near those edges by
  // definition, so the first and last coordinates were being cut off the
  // map ("se come coordenadas del inicio y final", reported live
  // 2026-09-07). The tile grid is snapped out to whole tiles and so always
  // extends past the track's padded box; letting the crop eat THAT margin
  // instead keeps every real fix on the page.
  var fx0 = 1.0, fx1 = 0.0, fy0 = 1.0, fy1 = 0.0;
  for (final (fx, fy) in projected) {
    if (fx < fx0) fx0 = fx;
    if (fx > fx1) fx1 = fx;
    if (fy < fy0) fy0 = fy;
    if (fy > fy1) fy1 = fy;
  }
  // Room for the start/end markers themselves (~5pt radius) plus a little
  // breathing space, so a fix exactly on the bbox edge isn't half-drawn.
  const edgePad = 12.0;
  final trackW = math.max((fx1 - fx0) * naturalW, 1.0);
  final trackH = math.max((fy1 - fy0) * naturalH, 1.0);
  final fitScale = math.min(
    math.max(innerW - 2 * edgePad, 1.0) / trackW,
    math.max(innerH - 2 * edgePad, 1.0) / trackH,
  );
  // Showing the whole track wins over filling every last pixel with map:
  // losing a real fix off the edge is a data bug, a sliver of background
  // is cosmetic. In practice it never comes to that — the tile request
  // already stretched its bounding box to this box's aspect ratio (see
  // _fetchTrackMapTiles) precisely so that covering and containing
  // coincide. The cap stops a boat that barely moved from blowing one
  // tile up into a blurry wall.
  final coverScale = math.max(innerW / naturalW, innerH / naturalH);
  final scale = math.min(fitScale, coverScale * 4);
  final drawnW = naturalW * scale;
  final drawnH = naturalH * scale;
  // Center on the TRACK's midpoint rather than the grid's, so whatever
  // cropping does happen falls on surplus tile margin around the route.
  final trackCx = (fx0 + fx1) / 2 * drawnW;
  final trackCy = (fy0 + fy1) / 2 * drawnH;
  var offsetX = innerW / 2 - trackCx;
  var offsetY = innerH / 2 - trackCy;
  // Only pull back toward the edges while the mosaic is actually big
  // enough to fill the box; if it isn't, keep it centered instead.
  offsetX = drawnW >= innerW
      ? offsetX.clamp(innerW - drawnW, 0.0)
      : (innerW - drawnW) / 2;
  offsetY = drawnH >= innerH
      ? offsetY.clamp(innerH - drawnH, 0.0)
      : (innerH - drawnH) / 2;

  // The route/marker overlay must use this SAME transform — not a plain
  // 0..1-over-the-box mapping — or it drifts away from the map underneath
  // it whenever the mosaic's aspect ratio forces a crop.
  (double, double) toCanvas((double, double) frac) {
    final topDownX = offsetX + frac.$1 * drawnW;
    final topDownY = offsetY + frac.$2 * drawnH;
    return (topDownX, innerH - topDownY); // package:pdf canvases are y-up
  }

  // Barbs ON the route, like MarineTraffic's own track view — "los barbs
  // son en la ruta" (reported live 2026-09-07).
  //
  // Spaced by CLOCK TIME so the report answers "qué viento había cada X".
  // Repeated positions (for example while fondeado) are suppressed visually
  // so several slots do not paint an unreadable pile of glyphs.
  final windBarbs = <({double x, double y, WindBarbSample barb})>[];
  if (tws.isNotEmpty && twd.isNotEmpty && projected.length > 1) {
    GraphPoint? nearestIn(List<GraphPoint> s, DateTime t, Duration tol) {
      GraphPoint? best;
      Duration? bestDiff;
      for (final p in s) {
        final d = p.time.difference(t).abs();
        if (d > tol) continue;
        if (bestDiff == null || d < bestDiff) {
          best = p;
          bestDiff = d;
        }
      }
      return best;
    }

    Duration tolFor(List<GraphPoint> s) {
      if (s.length < 2) return const Duration(minutes: 30);
      final gaps = <int>[];
      for (var i = 1; i < s.length; i++) {
        final ms = s[i].time.difference(s[i - 1].time).inMilliseconds;
        if (ms > 0) gaps.add(ms);
      }
      if (gaps.isEmpty) return const Duration(minutes: 30);
      gaps.sort();
      final median = gaps[gaps.length ~/ 2];
      final t = Duration(milliseconds: (median * 3).round());
      return t < const Duration(minutes: 10) ? const Duration(minutes: 10) : t;
    }

    final twsTol = tolFor(tws), twdTol = tolFor(twd);
    final canvasPts = [for (final f in projected) toCanvas(f)];
    final interval =
        barbInterval ??
        windBarbInterval(
          points.last.time.difference(points.first.time),
          targetCount: math.max(3, (width / 78).floor()),
        );
    final trackTolerance = tolFor([
      for (final p in points) GraphPoint(time: p.time, value: 0),
    ]);
    var slot = points.first.time;
    (double, double)? previousCanvas;
    while (!slot.isAfter(points.last.time)) {
      var idx = 0;
      Duration? bestTrackDiff;
      for (var i = 0; i < points.length; i++) {
        final diff = points[i].time.difference(slot).abs();
        if (bestTrackDiff == null || diff < bestTrackDiff) {
          idx = i;
          bestTrackDiff = diff;
        }
      }
      if (bestTrackDiff != null && bestTrackDiff <= trackTolerance) {
        final t = points[idx].time;
        final sp = nearestIn(tws, t, twsTol);
        final dir = nearestIn(twd, t, twdTol);
        final here = canvasPts[idx];
        final sufficientlySeparate =
            previousCanvas == null ||
            math.sqrt(
                  math.pow(here.$1 - previousCanvas.$1, 2) +
                      math.pow(here.$2 - previousCanvas.$2, 2),
                ) >=
                18;
        if (sufficientlySeparate &&
            sp != null &&
            dir != null &&
            sp.value >= 0 &&
            dir.value.isFinite) {
          windBarbs.add((
            x: here.$1,
            y: here.$2,
            barb: WindBarbSample(
              time: t,
              speedKnots: sp.value,
              directionDeg: (dir.value % 360 + 360) % 360,
            ),
          ));
          previousCanvas = here;
        }
      }
      slot = slot.add(interval);
    }
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
        // Placed with the SAME scale/offset the route overlay uses, rather
        // than a FittedBox doing its own independent fit — that's what
        // keeps the drawn track sitting exactly where it belongs on the
        // map instead of drifting relative to it.
        pw.Positioned(
          left: offsetX,
          top: offsetY,
          child: pw.SizedBox(
            width: drawnW,
            height: drawnH,
            child: pw.Column(
              children: List.generate(
                map.rows,
                (row) => pw.Row(
                  children: List.generate(
                    map.cols,
                    (col) => pw.Image(
                      pw.MemoryImage(map.tiles[row * map.cols + col]),
                      width: drawnW / map.cols,
                      height: drawnH / map.rows,
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

              for (final b in windBarbs) {
                _drawWindBarbGlyph(canvas, b.x, b.y, b.barb);
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
