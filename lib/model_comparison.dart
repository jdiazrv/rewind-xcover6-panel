import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'main.dart';
import 'models.dart';
import 'pdf/pdf_theme.dart';
import 'pdf_export/pdf_export_stub.dart'
    if (dart.library.io) 'pdf_export/pdf_export_io.dart'
    if (dart.library.html) 'pdf_export/pdf_export_web.dart';
import 'theme.dart';

PdfColor pdfColorOf(Color c) {
  if (c == cCyan) return pdfCyan;
  if (c == cGreen) return pdfGreen;
  if (c == cOrange) return pdfOrange;
  if (c == cRed) return pdfRed;
  if (c == cYellow) return pdfYellow;
  if (c == cPurple) return pdfPurple;
  if (c == cText) return pdfText;
  if (c == const Color(0xff2ea89a)) return pdfTeal;
  if (c == const Color(0xffb33a3a)) return pdfDarkRed;
  return pdfMuted;
}

/// A lighter, opaque version of [c], as if blended over a white background
/// at [strength] alpha — the pdf package's `setFillColor`/`BoxDecoration`
/// paint path ignores `PdfColor.alpha` entirely (only emits the RGB `rg`
/// operator), so a real translucent color there silently renders as the
/// full-saturation opaque color instead, which is what made cell numbers
/// unreadable: the "tinted" cell background and the bold number text ended
/// up being painted in the exact same solid color.
PdfColor pdfTint(PdfColor c, double strength) => PdfColor(
  1 - (1 - c.red) * strength,
  1 - (1 - c.green) * strength,
  1 - (1 - c.blue) * strength,
);

pw.Widget pdfLegendRow(List<({PdfColor color, String label})> items) => pw.Wrap(
  spacing: 12,
  runSpacing: 4,
  children: [
    for (final it in items)
      pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Container(
            width: 7,
            height: 7,
            margin: const pw.EdgeInsets.only(right: 4),
            decoration: pw.BoxDecoration(
              color: it.color,
              shape: pw.BoxShape.circle,
            ),
          ),
          pw.Text(
            it.label,
            style: pw.TextStyle(
              color: pdfMuted,
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
  ],
);

pw.Widget pdfInfoCard(
  String title,
  String value,
  String subtitle,
  PdfColor color,
) => pw.Container(
  padding: const pw.EdgeInsets.all(8),
  decoration: pw.BoxDecoration(
    color: color,
    borderRadius: pw.BorderRadius.circular(5),
  ),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        title,
        style: const pw.TextStyle(
          color: PdfColors.white,
          fontSize: 7,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        value,
        style: const pw.TextStyle(
          color: PdfColors.white,
          fontSize: 15,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
      pw.Spacer(),
      pw.Text(
        subtitle,
        style: const pw.TextStyle(
          color: PdfColor.fromInt(0xffeef6f8),
          fontSize: 6.5,
        ),
      ),
    ],
  ),
);

pw.Widget pdfLocationMap(
  String place,
  double? lat,
  double? lon, {
  ({List<Uint8List> tiles, double xFrac, double yFrac})? map,
}) => pw.Container(
  height: 140,
  padding: const pw.EdgeInsets.all(8),
  decoration: pw.BoxDecoration(
    color: const PdfColor.fromInt(0xffe8f5f8),
    borderRadius: pw.BorderRadius.circular(5),
  ),
  child: pw.Stack(
    children: [
      if (map != null && map.tiles.length == 4)
        pw.Positioned.fill(
          child: pw.ClipRRect(
            horizontalRadius: 4,
            verticalRadius: 4,
            child: pw.Column(
              children: [
                pw.Expanded(
                  child: pw.Row(
                    children: [
                      pw.Expanded(
                        child: pw.Image(
                          pw.MemoryImage(map.tiles[0]),
                          fit: pw.BoxFit.cover,
                        ),
                      ),
                      pw.Expanded(
                        child: pw.Image(
                          pw.MemoryImage(map.tiles[1]),
                          fit: pw.BoxFit.cover,
                        ),
                      ),
                    ],
                  ),
                ),
                pw.Expanded(
                  child: pw.Row(
                    children: [
                      pw.Expanded(
                        child: pw.Image(
                          pw.MemoryImage(map.tiles[2]),
                          fit: pw.BoxFit.cover,
                        ),
                      ),
                      pw.Expanded(
                        child: pw.Image(
                          pw.MemoryImage(map.tiles[3]),
                          fit: pw.BoxFit.cover,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        )
      else
        pw.Positioned.fill(
          child: pw.CustomPaint(
            painter: (canvas, size) {
              canvas.setFillColor(const PdfColor.fromInt(0xffe8f5f8));
              canvas.drawRect(0, 0, size.x, size.y);
              canvas.setFillColor(const PdfColor.fromInt(0xffd6ead4));
              canvas.moveTo(size.x * 0.47, size.y * 0.84);
              canvas.lineTo(size.x * 0.59, size.y * 0.68);
              canvas.lineTo(size.x * 0.53, size.y * 0.50);
              canvas.lineTo(size.x * 0.65, size.y * 0.32);
              canvas.lineTo(size.x * 0.49, size.y * 0.12);
              canvas.lineTo(size.x * 0.37, size.y * 0.34);
              canvas.lineTo(size.x * 0.43, size.y * 0.58);
              canvas.closePath();
              canvas.fillPath();
              canvas.setFillColor(const PdfColor.fromInt(0xfff0e5c9));
              canvas.moveTo(size.x * 0.84, 0);
              canvas.curveTo(
                size.x * 0.76,
                size.y * 0.28,
                size.x * 0.92,
                size.y * 0.62,
                size.x * 0.82,
                size.y,
              );
              canvas.lineTo(size.x, size.y);
              canvas.lineTo(size.x, 0);
              canvas.closePath();
              canvas.fillPath();
              final mx = size.x * 0.55, my = size.y * 0.58;
              canvas
                ..setFillColor(pdfRed)
                ..drawEllipse(mx - 3, my - 3, 6, 6)
                ..fillPath()
                ..setStrokeColor(pdfRed)
                ..setLineWidth(1)
                ..drawEllipse(mx - 7, my - 7, 14, 14)
                ..strokePath();
            },
          ),
        ),
      if (map != null && map.tiles.length == 4)
        pw.Positioned.fill(
          child: pw.CustomPaint(
            painter: (canvas, size) {
              final x = size.x * map.xFrac;
              final y = size.y * (1 - map.yFrac);
              canvas
                ..setFillColor(pdfRed)
                ..drawEllipse(x - 2, y - 2, 4, 4)
                ..fillPath()
                ..setStrokeColor(PdfColors.white)
                ..setLineWidth(1.2)
                ..drawEllipse(x - 3.5, y - 3.5, 7, 7)
                ..strokePath();
            },
          ),
        ),
      pw.Positioned(
        left: 0,
        top: 0,
        child: pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          decoration: pw.BoxDecoration(
            color: map == null
                ? PdfColors.white
                : const PdfColor.fromInt(0xeeffffff),
            borderRadius: pw.BorderRadius.circular(3),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Zona del pronóstico',
                style: const pw.TextStyle(
                  color: pdfText,
                  fontSize: 7.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                lat != null && lon != null
                    ? '$place  ·  ${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}'
                    : place,
                style: const pw.TextStyle(color: pdfMuted, fontSize: 6.8),
              ),
            ],
          ),
        ),
      ),
      pw.Positioned(
        right: 0,
        bottom: 0,
        child: pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: pw.BoxDecoration(
            color: map == null
                ? PdfColors.white
                : const PdfColor.fromInt(0xeeffffff),
            borderRadius: pw.BorderRadius.circular(3),
          ),
          child: pw.Text(
            '© OpenStreetMap contributors',
            style: const pw.TextStyle(color: pdfMuted, fontSize: 5.8),
          ),
        ),
      ),
    ],
  ),
);

/// Line chart mirroring `_SimpleLineChartPainter`'s exact drawing logic
/// (gridlines, hour labels, optional filled area on its own right-hand
/// scale) but against a PDF canvas, whose Y axis points up instead of down.
pw.Widget pdfLineChart({
  required PdfFont font,
  required List<({PdfColor color, List<double?> values})> series,
  required List<DateTime> hourLabels,
  List<double?>? areaValues,
  PdfColor? areaColor,
  String? areaAxisLabel,
  required double width,
  double height = 150,
}) {
  return pw.CustomPaint(
    size: PdfPoint(width, height),
    painter: (canvas, size) {
      const lPad = 26.0, tPad = 8.0, bPad = 16.0;
      final rPad = areaValues != null ? 32.0 : 6.0;
      final pL = lPad, pR = size.x - rPad, pT = size.y - tPad, pB = bPad;
      final pW = pR - pL, pH = pT - pB;
      if (pW <= 0 || pH <= 0 || hourLabels.isEmpty) return;
      final n = hourLabels.length;
      double xAt(int i) => n <= 1 ? pL : pL + pW * i / (n - 1);

      final allVals = <double>[
        for (final s in series) ...s.values.whereType<double>(),
      ];
      if (allVals.isEmpty) return;
      var yMin = allVals.reduce(math.min), yMax = allVals.reduce(math.max);
      final pad = (yMax - yMin) < 1 ? 1.0 : (yMax - yMin) * 0.15;
      yMin -= pad;
      yMax += pad;
      final ySpan = (yMax - yMin).clamp(0.001, double.infinity);
      double yAt(double v) => pB + (v - yMin) / ySpan * pH;

      for (var i = 0; i <= 3; i++) {
        final v = yMin + ySpan * i / 3;
        final y = yAt(v);
        canvas
          ..setStrokeColor(pdfGrid)
          ..setLineWidth(0.5)
          ..moveTo(pL, y)
          ..lineTo(pR, y)
          ..strokePath();
        canvas
          ..setFillColor(pdfMuted)
          ..drawString(font, 6.5, v.round().toString(), 1, y - 2.5);
      }
      final step = (n / 6).ceil().clamp(1, n);
      for (var i = 0; i < n; i += step) {
        canvas
          ..setFillColor(pdfMuted)
          ..drawString(
            font,
            6.5,
            '${hourLabels[i].hour.toString().padLeft(2, '0')}h',
            xAt(i) - 5,
            pB - 10,
          );
      }

      final area = areaValues;
      if (area != null && area.any((v) => v != null)) {
        final vals = area.whereType<double>().toList();
        final aMin = vals.reduce(math.min), aMax = vals.reduce(math.max);
        final aSpan = (aMax - aMin).clamp(0.001, double.infinity);
        double areaY(double v) => pB + (v - aMin) / aSpan * pH * 0.9;
        canvas.setFillColor(pdfTint(areaColor ?? pdfMuted, 0.28));
        canvas.moveTo(pL, pB);
        for (var i = 0; i < n; i++) {
          final v = area[i];
          if (v == null) continue;
          canvas.lineTo(xAt(i), areaY(v));
        }
        canvas
          ..lineTo(xAt(n - 1), pB)
          ..fillPath();
        for (var i = 0; i <= 3; i++) {
          final v = aMin + aSpan * i / 3;
          final y = pB + (v - aMin) / aSpan * pH * 0.9;
          canvas
            ..setFillColor(areaColor ?? pdfMuted)
            ..drawString(
              font,
              6.5,
              '${v.toStringAsFixed(1)}${areaAxisLabel ?? ''}',
              pR + 3,
              y - 2.5,
            );
        }
      }

      for (final s in series) {
        canvas
          ..setStrokeColor(s.color)
          ..setLineWidth(1.3);
        var started = false;
        for (var i = 0; i < n; i++) {
          final v = s.values[i];
          if (v == null) {
            started = false;
            continue;
          }
          final x = xAt(i), y = yAt(v);
          if (!started) {
            canvas.moveTo(x, y);
            started = true;
          } else {
            canvas.lineTo(x, y);
          }
        }
        canvas.strokePath();
      }
    },
  );
}

pw.Widget pdfConsensusChart({
  required PdfFont font,
  required List<double?> meanValues,
  required List<double?> minValues,
  required List<double?> maxValues,
  required List<DateTime> hourLabels,
  required double width,
  double height = 150,
}) {
  return pw.CustomPaint(
    size: PdfPoint(width, height),
    painter: (canvas, size) {
      const lPad = 26.0, tPad = 8.0, bPad = 16.0, rPad = 6.0;
      final pL = lPad, pR = size.x - rPad, pT = size.y - tPad, pB = bPad;
      final pW = pR - pL, pH = pT - pB;
      if (pW <= 0 || pH <= 0 || hourLabels.isEmpty) return;
      final n = hourLabels.length;
      double xAt(int i) => n <= 1 ? pL : pL + pW * i / (n - 1);
      final vals = <double>[
        ...meanValues.whereType<double>(),
        ...minValues.whereType<double>(),
        ...maxValues.whereType<double>(),
      ];
      if (vals.isEmpty) return;
      var yMin = math.max(0, vals.reduce(math.min) - 2);
      var yMax = vals.reduce(math.max) + 2;
      if (yMax - yMin < 4) yMax = yMin + 4;
      final ySpan = yMax - yMin;
      double yAt(double v) => pB + (v - yMin) / ySpan * pH;
      for (var i = 0; i <= 3; i++) {
        final v = yMin + ySpan * i / 3;
        final y = yAt(v);
        canvas
          ..setStrokeColor(pdfGrid)
          ..setLineWidth(0.5)
          ..moveTo(pL, y)
          ..lineTo(pR, y)
          ..strokePath()
          ..setFillColor(pdfMuted)
          ..drawString(font, 6.5, v.round().toString(), 1, y - 2.5);
      }
      final step = (n / 6).ceil().clamp(1, n);
      for (var i = 0; i < n; i += step) {
        canvas
          ..setFillColor(pdfMuted)
          ..drawString(
            font,
            6.5,
            '${hourLabels[i].hour.toString().padLeft(2, '0')}h',
            xAt(i) - 5,
            pB - 10,
          );
      }
      canvas.setFillColor(pdfTint(pdfCyan, 0.20));
      var bandStarted = false;
      for (var i = 0; i < n; i++) {
        final v = minValues[i];
        if (v == null) continue;
        final x = xAt(i), y = yAt(v);
        if (!bandStarted) {
          canvas.moveTo(x, y);
          bandStarted = true;
        } else {
          canvas.lineTo(x, y);
        }
      }
      for (var i = n - 1; i >= 0; i--) {
        final v = maxValues[i];
        if (v == null) continue;
        canvas.lineTo(xAt(i), yAt(v));
      }
      if (bandStarted) {
        canvas
          ..closePath()
          ..fillPath();
      }
      canvas
        ..setStrokeColor(pdfCyan)
        ..setLineWidth(1.7);
      var started = false;
      for (var i = 0; i < n; i++) {
        final v = meanValues[i];
        if (v == null) {
          started = false;
          continue;
        }
        final x = xAt(i), y = yAt(v);
        if (!started) {
          canvas.moveTo(x, y);
          started = true;
        } else {
          canvas.lineTo(x, y);
        }
      }
      canvas.strokePath();
    },
  );
}

/// A single triangle pointing in the wind direction, colour-coded by speed —
/// the PDF equivalent of the on-screen `Icons.navigation` arrows. Drawn as a
/// vector path rather than a Unicode glyph (e.g. "▲"): the base-14 PDF fonts
/// don't include that glyph and render it as a garbled fallback box.
/// PDF widget space is Y-up (unlike Flutter's Y-down canvas), so the
/// rotation angle is negated to still point the same real-world way.
pw.Widget pdfWindArrow(double? degTo, double? speedKn, {double size = 9}) {
  // A null speed (e.g. a model with no gust data for this hour) must not
  // silently draw as a "calm" muted arrow — show the same dash as a missing
  // direction instead, or gust mode would visually look like less wind.
  if (degTo == null || speedKn == null)
    return pw.Text(
      '-',
      style: pw.TextStyle(color: pdfMuted, fontSize: size * 0.8),
    );
  final color = pdfColorOf(meteogramColor(speedKn));
  return pw.CustomPaint(
    size: PdfPoint(size, size),
    painter: (canvas, sz) {
      final cx = sz.x / 2, cy = sz.y / 2, r = sz.x * 0.46;
      final theta = -((degTo + 180) * math.pi / 180);
      final cosT = math.cos(theta), sinT = math.sin(theta);
      Offset rot(double x, double y) =>
          Offset(x * cosT - y * sinT + cx, x * sinT + y * cosT + cy);
      final tip = rot(0, r),
          left = rot(-r * 0.62, -r * 0.62),
          right = rot(r * 0.62, -r * 0.62);
      canvas
        ..setFillColor(color)
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy)
        ..closePath()
        ..fillPath();
    },
  );
}

// ─── Weather model comparison (PRON > Comparar modelos) ───────────────────────
// Table layout follows the Windguru convention every sailor already knows:
// hours across the top, one colour-coded wind row per model (speed + gust +
// direction arrow), so several models can be scanned and compared at a glance.
class ModelComparisonDialog extends StatefulWidget {
  const ModelComparisonDialog({
    required this.place,
    required this.lat,
    required this.lon,
    required this.fetch,
  });
  final String place;
  final double? lat;
  final double? lon;
  final Future<
    ({
      Map<String, List<ModelForecastPoint>> models,
      List<GraphPoint> waveHeight,
    })
  >
  Function()
  fetch;

  @override
  State<ModelComparisonDialog> createState() => _ModelComparisonDialogState();
}

class _ModelComparisonDialogState extends State<ModelComparisonDialog> {
  Map<String, List<ModelForecastPoint>>? _data;
  List<GraphPoint> _waveHeight = const [];
  bool _loading = true;
  String? _error;
  bool _mastCorrection = false;
  double _mastHeightM = 15;
  String? _meteogramModelId;
  bool _meteogramShowGust = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.fetch();
      if (mounted)
        setState(() {
          _data = d.models;
          _waveHeight = d.waveHeight;
          _loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = friendlyApiError(e);
          _loading = false;
        });
    }
  }

  pw.Widget _pdfWindCell(ModelForecastPoint? p) {
    if (p == null || p.windKn == null) {
      return pw.Center(
        child: pw.Text(
          '--',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 7),
        ),
      );
    }
    final speed = _corrected(p.windKn!);
    final gust = p.gustKn != null ? _corrected(p.gustKn!) : null;
    final color = pdfColorOf(windColor(speed));
    return pw.Container(
      margin: const pw.EdgeInsets.all(1),
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      decoration: pw.BoxDecoration(
        color: pdfTint(color, 0.16),
        borderRadius: pw.BorderRadius.circular(3),
        border: pw.Border.all(color: pdfTint(color, 0.7), width: 0.5),
      ),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text(
                '${speed.round()}',
                style: pw.TextStyle(
                  color: color,
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(width: 2),
              pdfWindArrow(p.windDirDeg, speed, size: 6.5),
            ],
          ),
          if (gust != null)
            pw.Text(
              'r.${gust.round()}',
              style: const pw.TextStyle(color: pdfMuted, fontSize: 5.5),
            ),
        ],
      ),
    );
  }

  pw.Widget _pdfDayTable(
    DateTime day,
    List<DateTime> dayHours,
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    bool hasWave,
  ) {
    const labelW = 42.0;
    return pw.Table(
      border: pw.TableBorder.symmetric(
        inside: const pw.BorderSide(color: pdfGrid, width: 0.4),
      ),
      columnWidths: {
        0: const pw.FixedColumnWidth(labelW),
        for (var i = 1; i <= dayHours.length; i++)
          i: const pw.FlexColumnWidth(),
      },
      children: [
        // Marked `repeat: true` so the day/hour header reappears if this
        // table's rows get split across a page boundary — otherwise (the
        // pdf package's default) only the first page shows which day or
        // hour each column is, and the continuation page looks unlabeled.
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: pdfPanel),
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(
                vertical: 3,
                horizontal: 2,
              ),
              child: pw.Text(
                '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}',
                style: const pw.TextStyle(
                  color: pdfText,
                  fontSize: 7,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            for (final h in dayHours)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 3),
                child: pw.Center(
                  child: pw.Text(
                    '${h.hour.toString().padLeft(2, '0')}h',
                    style: const pw.TextStyle(
                      color: pdfText,
                      fontSize: 6.5,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
        for (final m in activeModels)
          pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  vertical: 2,
                  horizontal: 2,
                ),
                child: pw.Text(
                  m.label,
                  style: pw.TextStyle(
                    color: pdfColorOf(m.color),
                    fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              for (final h in dayHours)
                _pdfWindCell(_nearestPoint(data[m.id]!, h)),
            ],
          ),
        if (hasWave)
          pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  vertical: 2,
                  horizontal: 2,
                ),
                child: pw.Text(
                  'OLA',
                  style: const pw.TextStyle(
                    color: pdfPurple,
                    fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              for (final h in dayHours)
                pw.Center(
                  child: pw.Text(
                    _nearestWave(h) != null
                        ? '${_nearestWave(h)!.value.toStringAsFixed(1)}m'
                        : '--',
                    style: const pw.TextStyle(color: pdfPurple, fontSize: 6.5),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  bool _hasRain(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    for (final m in activeModels) {
      for (final h in hours) {
        final rain = _nearestPoint(data[m.id]!, h)?.rainPct;
        if (rain != null && rain > 0) return true;
      }
    }
    return false;
  }

  ({DateTime? start, DateTime? end, double? maxKn}) _worstWindWindow(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    DateTime? worst;
    double? maxKn;
    for (final h in hours) {
      for (final m in activeModels) {
        final p = _nearestPoint(data[m.id]!, h);
        final raw = p?.gustKn ?? p?.windKn;
        if (raw == null) continue;
        final kn = _corrected(raw);
        if (maxKn == null || kn > maxKn) {
          maxKn = kn;
          worst = h;
        }
      }
    }
    return (
      start: worst,
      end: worst?.add(const Duration(hours: 2)),
      maxKn: maxKn,
    );
  }

  double _averageSpread(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final spreads = <double>[];
    for (final h in hours) {
      final values = <double>[];
      for (final m in activeModels) {
        final v = _nearestPoint(data[m.id]!, h)?.windKn;
        if (v != null) values.add(_corrected(v));
      }
      if (values.length > 1)
        spreads.add(values.reduce(math.max) - values.reduce(math.min));
    }
    if (spreads.isEmpty) return 0;
    return spreads.reduce((a, b) => a + b) / spreads.length;
  }

  double? _averageSpreadUntil(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
    Duration horizon,
  ) {
    final now = DateTime.now();
    var windowHours = hours
        .where((h) => !h.isBefore(now) && h.isBefore(now.add(horizon)))
        .toList();
    if (windowHours.isEmpty && hours.isNotEmpty) {
      final first = hours.first;
      windowHours = hours
          .where((h) => !h.isBefore(first) && h.isBefore(first.add(horizon)))
          .toList();
    }
    if (windowHours.isEmpty) return null;
    return _averageSpread(activeModels, data, windowHours);
  }

  String _confidenceBrief(double? spread) =>
      spread == null ? '--' : _confidenceLabel(spread);

  String _confidenceWithSpread(double? spread) => spread == null
      ? '--'
      : '${_confidenceLabel(spread)} (${spread.toStringAsFixed(1)} kt)';

  double? _maxWaveFor(List<DateTime> hours) {
    double? maxWave;
    for (final h in hours) {
      final wave = _nearestWave(h)?.value;
      if (wave == null) continue;
      maxWave = maxWave == null ? wave : math.max(maxWave, wave);
    }
    return maxWave;
  }

  String _shortHour(DateTime? t) => t == null
      ? '--'
      : '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}h';

  String _confidenceLabel(double spread) {
    if (spread < 3) return 'Alta';
    if (spread < 7) return 'Media';
    return 'Baja';
  }

  String _modelResolutionLabel(List<ModelForecastPoint> points) {
    final times = points.map((p) => p.time).toList()..sort();
    final steps = <int>[];
    for (var i = 1; i < times.length; i++) {
      final minutes = times[i].difference(times[i - 1]).inMinutes.abs();
      if (minutes > 0) steps.add(minutes);
    }
    if (steps.isEmpty) return 'sin resolución calculable';
    steps.sort();
    final median = steps[steps.length ~/ 2];
    if (median % 60 == 0) {
      final hours = median ~/ 60;
      return hours == 1 ? '1 h' : '$hours h';
    }
    return '$median min';
  }

  String _modelSpatialResolutionLabel(ModelSeries model) {
    switch (model.id) {
      case 'gfs_seamless':
        return '0.11° (~13 km)';
      case 'ecmwf_ifs025':
        return '0.25° (~25 km)';
      case 'icon_eu':
        return '0.0625° (~7 km)';
      case 'arpege_europe':
        return '0.1° (~11 km)';
      case 'gem_seamless':
        return '0.15° (~15 km)';
      default:
        return 'no documentada';
    }
  }

  Future<({List<Uint8List> tiles, double xFrac, double yFrac})?>
  _fetchReportMapTiles() async {
    final lat = widget.lat, lon = widget.lon;
    if (lat == null || lon == null) return null;
    try {
      const z = 10;
      final n = math.pow(2, z).toDouble();
      final latRad = lat * math.pi / 180;
      final xFloat = (lon + 180) / 360 * n;
      final yFloat =
          (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
          2 *
          n;
      final startX = (xFloat - 1).round().clamp(0, math.pow(2, z).toInt() - 2);
      final startY = (yFloat - 1).round().clamp(0, math.pow(2, z).toInt() - 2);
      final tiles = <Uint8List>[];
      for (final y in [startY, startY + 1]) {
        for (final x in [startX, startX + 1]) {
          final uri = Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png');
          final response = await http
              .get(uri, headers: {'User-Agent': 'REWIND-XCover6-panel/1.0'})
              .timeout(const Duration(seconds: 8));
          final type = response.headers['content-type'] ?? '';
          if (response.statusCode != 200 || !type.startsWith('image/'))
            return null;
          tiles.add(response.bodyBytes);
        }
      }
      if (tiles.length != 4) return null;
      return (
        tiles: tiles,
        xFrac: ((xFloat - startX) / 2).clamp(0.0, 1.0),
        yFrac: ((yFloat - startY) / 2).clamp(0.0, 1.0),
      );
    } catch (_) {
      // Keep PDF generation robust: a real map is useful, but not mandatory.
    }
    return null;
  }

  ({List<double?> mean, List<double?> min, List<double?> max}) _consensusValues(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final means = <double?>[];
    final lows = <double?>[];
    final highs = <double?>[];
    for (final h in hours) {
      final values = <double>[];
      for (final m in activeModels) {
        final v = _nearestPoint(data[m.id]!, h)?.windKn;
        if (v != null) values.add(_corrected(v));
      }
      if (values.isEmpty) {
        means.add(null);
        lows.add(null);
        highs.add(null);
      } else {
        means.add(values.reduce((a, b) => a + b) / values.length);
        lows.add(values.reduce(math.min));
        highs.add(values.reduce(math.max));
      }
    }
    return (mean: means, min: lows, max: highs);
  }

  List<String> _reportAlerts(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours, {
    required bool hasRain,
    required double? maxWave,
    required double spread,
    required double? spread6h,
    required double? spread24h,
    required double? spread48h,
  }) {
    final alerts = <String>[];
    final worst = _worstWindWindow(activeModels, data, hours);
    if (worst.maxKn != null) {
      alerts.add(
        'Racha máxima prevista: ${worst.maxKn!.round()} kt en torno a ${_shortHour(worst.start)}.',
      );
      if (worst.maxKn! >= 25) {
        alerts.add('Tramo duro: hay modelos por encima de 25 kt de racha.');
      } else if (worst.maxKn! >= 20) {
        alerts.add('Atención: rachas por encima de 20 kt.');
      }
    }
    if (spread >= 7) {
      alerts.add(
        'Confianza baja: dispersión media entre modelos de ${spread.toStringAsFixed(1)} kt.',
      );
    } else if (spread >= 3) {
      alerts.add(
        'Confianza media: los modelos se separan ${spread.toStringAsFixed(1)} kt de media.',
      );
    } else {
      alerts.add('Confianza alta: los modelos mantienen una dispersión baja.');
    }
    alerts.add(
      'Confianza por horizonte: próximas 6 h ${_confidenceWithSpread(spread6h)}, 24 h ${_confidenceWithSpread(spread24h)}, 48 h ${_confidenceWithSpread(spread48h)}.',
    );
    if (hasRain)
      alerts.add('Hay probabilidad de lluvia en al menos un modelo.');
    if (maxWave != null)
      alerts.add('Ola máxima prevista: ${maxWave.toStringAsFixed(1)} m.');
    return alerts;
  }

  List<
    ({
      DateTime time,
      double spread,
      String lowModel,
      double low,
      String highModel,
      double high,
    })
  >
  _topDivergences(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final rows =
        <
          ({
            DateTime time,
            double spread,
            String lowModel,
            double low,
            String highModel,
            double high,
          })
        >[];
    for (final h in hours) {
      final values = <({String model, double value})>[];
      for (final m in activeModels) {
        final v = _nearestPoint(data[m.id]!, h)?.windKn;
        if (v != null) values.add((model: m.label, value: _corrected(v)));
      }
      if (values.length < 2) continue;
      values.sort((a, b) => a.value.compareTo(b.value));
      final low = values.first;
      final high = values.last;
      rows.add((
        time: h,
        spread: high.value - low.value,
        lowModel: low.model,
        low: low.value,
        highModel: high.model,
        high: high.value,
      ));
    }
    rows.sort((a, b) => b.spread.compareTo(a.spread));
    return rows.take(6).toList();
  }

  pw.Widget _pdfGeneratedBlock(
    String title,
    List<String> lines, {
    PdfColor accent = pdfCyan,
  }) => pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(
      color: pdfPanel,
      borderRadius: pw.BorderRadius.circular(5),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            color: accent,
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 5),
        for (final line in lines)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.Text(
              '• $line',
              style: const pw.TextStyle(color: pdfText, fontSize: 8.2),
            ),
          ),
      ],
    ),
  );

  Future<Uint8List> _buildReportPdf() async {
    final data = _data!;
    final activeModels = [
      for (final m in weatherModels)
        if (data.containsKey(m.id)) m,
    ];
    final hours = _hourColumns();
    final now = DateTime.now();
    final hasWave = _waveHeight.isNotEmpty;
    final hasRain = _hasRain(activeModels, data, hours);
    final worst = _worstWindWindow(activeModels, data, hours);
    final spread = _averageSpread(activeModels, data, hours);
    final spread6h = _averageSpreadUntil(
      activeModels,
      data,
      hours,
      const Duration(hours: 6),
    );
    final spread24h = _averageSpreadUntil(
      activeModels,
      data,
      hours,
      const Duration(hours: 24),
    );
    final spread48h = _averageSpreadUntil(
      activeModels,
      data,
      hours,
      const Duration(hours: 48),
    );
    final maxWave = _maxWaveFor(hours);
    final consensus = _consensusValues(activeModels, data, hours);
    final mapTiles = await _fetchReportMapTiles();
    final meteoModel = activeModels.firstWhere(
      (m) => m.id == _meteogramModelId,
      orElse: () => activeModels.first,
    );

    const margin = 24.0;
    const pageFormat = PdfPageFormat.a4;
    final contentWidth = pageFormat.landscape.width - margin * 2;

    final doc = pw.Document();
    final canvasFont = PdfFont.helvetica(doc.document);

    pw.Widget header(pw.Context ctx) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Comparativa de modelos meteorológicos',
          style: const pw.TextStyle(
            color: pdfText,
            fontSize: 15,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.Text(
          widget.place,
          style: const pw.TextStyle(color: pdfMuted, fontSize: 10),
        ),
        pw.Text(
          'Generado ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}'
          '${_mastCorrection ? ' · viento corregido a ${_mastHeightM.round()} m de altura de palo' : ''}',
          style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
        ),
        pw.SizedBox(height: 6),
        pw.Divider(color: pdfGrid, height: 1, thickness: 0.6),
        pw.SizedBox(height: 8),
      ],
    );
    pw.Widget footer(pw.Context ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        'Página ${ctx.pageNumber} / ${ctx.pagesCount}',
        style: const pw.TextStyle(color: pdfMuted, fontSize: 7),
      ),
    );
    final pageTheme = pw.PageTheme(
      pageFormat: pageFormat.landscape,
      margin: const pw.EdgeInsets.all(margin),
      theme: pw.ThemeData.base().copyWith(
        defaultTextStyle: const pw.TextStyle(color: pdfText, fontSize: 9),
      ),
      buildBackground: (ctx) =>
          pw.FullPage(ignoreMargins: true, child: pw.Container(color: pdfBg)),
    );

    // Group hours by calendar day so each day's comparative table (models
    // as rows, hours as columns — same layout as the on-screen sticky
    // table) fits comfortably instead of squeezing 30 hours into one page.
    final byDay = <DateTime, List<DateTime>>{};
    for (final h in hours) {
      byDay.putIfAbsent(DateTime(h.year, h.month, h.day), () => []).add(h);
    }

    doc.addPage(
      pw.Page(
        pageTheme: pageTheme,
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            header(ctx),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 165,
                  child: pdfLocationMap(
                    widget.place,
                    widget.lat,
                    widget.lon,
                    map: mapTiles,
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: pw.Column(
                    children: [
                      pw.Row(
                        children: [
                          pw.Expanded(
                            child: pw.SizedBox(
                              height: 64,
                              child: pdfInfoCard(
                                'Peor tramo',
                                _shortHour(worst.start),
                                worst.maxKn == null
                                    ? 'sin rachas'
                                    : 'máx ${worst.maxKn!.round()} kt',
                                pdfRed,
                              ),
                            ),
                          ),
                          pw.SizedBox(width: 8),
                          pw.Expanded(
                            child: pw.SizedBox(
                              height: 64,
                              child: pdfInfoCard(
                                'Confianza',
                                '6h ${_confidenceBrief(spread6h)}',
                                '24h ${_confidenceBrief(spread24h)} · 48h ${_confidenceBrief(spread48h)}',
                                pdfYellow,
                              ),
                            ),
                          ),
                          pw.SizedBox(width: 8),
                          pw.Expanded(
                            child: pw.SizedBox(
                              height: 64,
                              child: pdfInfoCard(
                                'Mar',
                                maxWave == null
                                    ? '--'
                                    : '${maxWave.toStringAsFixed(1)} m',
                                hasWave
                                    ? 'altura de ola máx'
                                    : 'sin datos de ola',
                                pdfPurple,
                              ),
                            ),
                          ),
                          pw.SizedBox(width: 8),
                          pw.Expanded(
                            child: pw.SizedBox(
                              height: 64,
                              child: pdfInfoCard(
                                'Lluvia',
                                hasRain ? 'Sí' : 'No',
                                hasRain
                                    ? 'ver gráfica dedicada'
                                    : 'sin precipitación modelo',
                                pdfCyan,
                              ),
                            ),
                          ),
                        ],
                      ),
                      pw.SizedBox(height: 10),
                      pw.Container(
                        width: double.infinity,
                        padding: const pw.EdgeInsets.all(10),
                        decoration: pw.BoxDecoration(
                          color: pdfPanel,
                          borderRadius: pw.BorderRadius.circular(5),
                        ),
                        child: pw.Text(
                          'Lectura náutica: se mantiene la tabla horaria comparativa original y la gráfica de todos los modelos. '
                          'Esta cabecera añade contexto de posición, peor tramo y confianza para decidir más rápido antes de entrar en el detalle.',
                          style: const pw.TextStyle(
                            color: pdfText,
                            fontSize: 8.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 22),
            pw.Text(
              'Consenso TWS - rango entre modelos',
              style: const pw.TextStyle(
                color: pdfText,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              'La banda muestra min-max; la línea, la media de modelos.',
              style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
            ),
            pw.SizedBox(height: 8),
            pdfConsensusChart(
              font: canvasFont,
              meanValues: consensus.mean,
              minValues: consensus.min,
              maxValues: consensus.max,
              hourLabels: hours,
              width: contentWidth,
              height: 170,
            ),
            pw.Spacer(),
            footer(ctx),
          ],
        ),
      ),
    );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: header,
        footer: footer,
        build: (ctx) => [
          for (final entry in byDay.entries) ...[
            pw.Text(
              '${entry.key.day.toString().padLeft(2, '0')}/${entry.key.month.toString().padLeft(2, '0')}/${entry.key.year}',
              style: const pw.TextStyle(
                color: pdfText,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 4),
            _pdfDayTable(entry.key, entry.value, activeModels, data, hasWave),
            pw.SizedBox(height: 14),
          ],
        ],
      ),
    );

    // Charts page — same three graphs as on screen (TWS divergence,
    // direction meteogram, pressure + wave), redrawn on the PDF canvas so
    // it matches the in-app look rather than a generic table dump.
    if (activeModels.isNotEmpty) {
      final twsSeries = [
        for (final m in activeModels)
          (
            color: pdfColorOf(m.color),
            values: [
              for (final h in hours) _nearestPoint(data[m.id]!, h)?.windKn,
            ].map((v) => v == null ? null : _corrected(v)).toList(),
          ),
      ];
      final meteoPts = data[meteoModel.id]!;
      final pressureSeries = [
        for (final m in activeModels)
          (
            color: pdfColorOf(m.color),
            values: [
              for (final h in hours) _nearestPoint(data[m.id]!, h)?.pressureHpa,
            ],
          ),
      ];
      final rainSeries = [
        for (final m in activeModels)
          (
            color: pdfColorOf(m.color),
            values: [
              for (final h in hours) _nearestPoint(data[m.id]!, h)?.rainPct,
            ],
          ),
      ];
      final waveValues = [for (final h in hours) _nearestWave(h)?.value];
      // Rain probability is naturally per-model (each model's own hourly
      // %), but the amount in mm is drawn as a single filled area like the
      // wave height chart — averaged across active models per hour, since
      // one line per model here would just clutter the same chart that
      // already carries five probability lines.
      final rainMmValues = [
        for (final h in hours)
          () {
            final vals = [
              for (final m in activeModels)
                _nearestPoint(data[m.id]!, h)?.rainMm,
            ].whereType<double>().toList();
            return vals.isEmpty
                ? null
                : vals.reduce((a, b) => a + b) / vals.length;
          }(),
      ];

      doc.addPage(
        pw.MultiPage(
          pageTheme: pageTheme,
          header: header,
          footer: footer,
          // Each chart section (title + subtitle + chart + legend) is
          // wrapped in its own pw.Column instead of spliced flat into this
          // list — a flat list lets MultiPage break the page between any
          // two items, so a title landing at the bottom of a page had its
          // chart pushed to the next one. A Column isn't a spanning widget,
          // so the whole group now moves together.
          build: (ctx) => [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'TWS por hora - divergencia entre modelos',
                  style: const pw.TextStyle(
                    color: pdfText,
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  'Velocidad del viento (nudos)',
                  style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
                ),
                pw.SizedBox(height: 6),
                pdfLineChart(
                  font: canvasFont,
                  series: twsSeries,
                  hourLabels: hours,
                  width: contentWidth,
                ),
                pw.SizedBox(height: 4),
                pdfLegendRow([
                  for (final m in activeModels)
                    (color: pdfColorOf(m.color), label: m.label),
                ]),
              ],
            ),
            pw.SizedBox(height: 18),

            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'TWD - meteograma de dirección (${meteoModel.label}, ${_meteogramShowGust ? 'rachas' : 'viento'})',
                  style: const pw.TextStyle(
                    color: pdfText,
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  'Flecha = hacia dónde sopla · color = intensidad',
                  style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
                ),
                pw.SizedBox(height: 6),
                pw.Row(
                  children: [
                    for (final h in hours)
                      pw.Expanded(
                        child: pw.Center(
                          child: () {
                            final p = _nearestPoint(meteoPts, h);
                            final rawKn = _meteogramShowGust
                                ? p?.gustKn
                                : p?.windKn;
                            final kn = rawKn == null ? null : _corrected(rawKn);
                            return pdfWindArrow(p?.windDirDeg, kn, size: 10);
                          }(),
                        ),
                      ),
                  ],
                ),
                pw.Row(
                  children: [
                    for (var i = 0; i < hours.length; i++)
                      pw.Expanded(
                        child: pw.Center(
                          child: pw.Text(
                            i % 6 == 0
                                ? (hours[i].hour == 0
                                      ? '${hours[i].day}/${hours[i].month}'
                                      : '${hours[i].hour.toString().padLeft(2, '0')}h')
                                : '',
                            style: pw.TextStyle(
                              color: hours[i].hour == 0 ? pdfCyan : pdfMuted,
                              fontSize: 6,
                              fontWeight: hours[i].hour == 0
                                  ? pw.FontWeight.bold
                                  : pw.FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                pw.SizedBox(height: 4),
                pdfLegendRow(const [
                  (color: pdfMuted, label: '< 3 kt'),
                  (color: pdfTeal, label: '3-7 kt'),
                  (color: pdfOrange, label: '7-10 kt'),
                  (color: pdfRed, label: '10-15 kt'),
                  (color: pdfDarkRed, label: '15-20 kt'),
                  (color: pdfPurple, label: '> 20 kt'),
                ]),
              ],
            ),
            pw.SizedBox(height: 18),

            if (hasRain)
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Lluvia - probabilidad y cantidad por modelo',
                    style: const pw.TextStyle(
                      color: pdfText,
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Probabilidad de precipitación (%, líneas) y cantidad (mm, área)',
                    style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
                  ),
                  pw.SizedBox(height: 6),
                  pdfLineChart(
                    font: canvasFont,
                    series: rainSeries,
                    hourLabels: hours,
                    areaValues: rainMmValues,
                    areaColor: pdfCyan,
                    areaAxisLabel: 'mm',
                    width: contentWidth,
                    height: 120,
                  ),
                  pw.SizedBox(height: 4),
                  pdfLegendRow([
                    for (final m in activeModels)
                      (color: pdfColorOf(m.color), label: 'Lluvia ${m.label}'),
                    if (rainMmValues.any((v) => v != null))
                      (color: pdfCyan, label: 'Cantidad (mm)'),
                  ]),
                ],
              ),
            if (hasRain) pw.SizedBox(height: 18),

            if (hasWave)
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Presión y oleaje combinados',
                    style: const pw.TextStyle(
                      color: pdfText,
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Presión media (hPa, líneas, izq.) y altura de ola (m, área, dcha.)',
                    style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
                  ),
                  pw.SizedBox(height: 6),
                  pdfLineChart(
                    font: canvasFont,
                    series: pressureSeries,
                    hourLabels: hours,
                    areaValues: waveValues,
                    areaColor: pdfPurple,
                    areaAxisLabel: 'm',
                    width: contentWidth,
                  ),
                  pw.SizedBox(height: 4),
                  pdfLegendRow([
                    for (final m in activeModels)
                      (color: pdfColorOf(m.color), label: 'Presión ${m.label}'),
                    (color: pdfPurple, label: 'Altura de ola'),
                  ]),
                ],
              ),
          ],
        ),
      );
    }

    doc.addPage(
      pw.Page(
        pageTheme: pageTheme,
        build: (ctx) {
          final alerts = _reportAlerts(
            activeModels,
            data,
            hours,
            hasRain: hasRain,
            maxWave: maxWave,
            spread: spread,
            spread6h: spread6h,
            spread24h: spread24h,
            spread48h: spread48h,
          );
          final divergences = _topDivergences(activeModels, data, hours);
          final divergenceLines = divergences
              .map(
                (d) =>
                    '${_shortHour(d.time)}: ${d.spread.toStringAsFixed(1)} kt de diferencia (${d.lowModel} ${d.low.round()} kt / ${d.highModel} ${d.high.round()} kt).',
              )
              .toList();
          final modelLines = [
            for (final m in activeModels)
              '${m.label}: resolución ${_modelResolutionLabel(data[m.id]!)} · espacial ${_modelSpatialResolutionLabel(m)}; ${data[m.id]!.length} horas disponibles; máximo viento medio ${[for (final p in data[m.id]!)
                if (p.windKn != null) _corrected(p.windKn!)].fold<double>(0, math.max).round()} kt.',
          ];
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              header(ctx),
              pw.Text(
                'Diagnóstico generado',
                style: const pw.TextStyle(
                  color: pdfText,
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                'Resumen automático derivado de los modelos cargados para la zona seleccionada.',
                style: const pw.TextStyle(color: pdfMuted, fontSize: 8),
              ),
              pw.SizedBox(height: 14),
              if (_mastCorrection) ...[
                _pdfGeneratedBlock('Corrección aplicada', [
                  'Los valores de viento del informe están corregidos a ${_mastHeightM.round()} m de altura de palo.',
                  'La corrección afecta a viento medio, rachas, consenso, divergencias y gráficas de viento.',
                ], accent: pdfCyan),
                pw.SizedBox(height: 10),
              ],
              _pdfGeneratedBlock(
                'Alertas de navegación',
                alerts,
                accent: pdfRed,
              ),
              pw.SizedBox(height: 10),
              _pdfGeneratedBlock(
                'Horas con mayor incertidumbre',
                divergenceLines.isEmpty
                    ? [
                        'No hay suficiente solape de modelos para calcular divergencia.',
                      ]
                    : divergenceLines,
                accent: pdfYellow,
              ),
              pw.SizedBox(height: 10),
              _pdfGeneratedBlock('Lluvia y mar', [
                hasRain
                    ? 'La gráfica de lluvia muestra los modelos con precipitación prevista.'
                    : 'No aparece lluvia relevante en el horizonte comparado.',
                maxWave == null
                    ? 'Sin datos de oleaje para esta ubicación.'
                    : 'Oleaje máximo comparado: ${maxWave.toStringAsFixed(1)} m.',
              ], accent: pdfPurple),
              pw.SizedBox(height: 10),
              _pdfGeneratedBlock(
                'Ficha de modelos disponibles',
                modelLines,
                accent: pdfCyan,
              ),
              pw.Spacer(),
              footer(ctx),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  Future<void> _shareReport(BuildContext context) async {
    if (_data == null || _sharing) return;
    setState(() => _sharing = true);
    try {
      final now = DateTime.now();
      final bytes = await _buildReportPdf();
      if (!context.mounted) return;
      await exportPdfReport(
        bytes: bytes,
        filename: 'rewind_comparativa_${now.millisecondsSinceEpoch}.pdf',
        subject: 'Comparativa de modelos — ${widget.place}',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generando PDF: ${friendlyApiError(e)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _openReportPreview(BuildContext context) {
    if (_data == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: cBg,
          appBar: AppBar(
            backgroundColor: cBg,
            foregroundColor: cText,
            title: const Text('Informe comparativo'),
          ),
          body: PdfPreview(
            canChangePageFormat: false,
            canChangeOrientation: false,
            canDebug: false,
            allowPrinting: true,
            allowSharing: true,
            pdfFileName: 'rewind_comparativa.pdf',
            build: (_) => _buildReportPdf(),
          ),
        ),
      ),
    );
  }

  double _corrected(double kn) =>
      _mastCorrection ? kn * math.pow(_mastHeightM / 10.0, 0.11) : kn;

  List<DateTime> _hourColumns() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour);
    return [for (var i = 0; i < 72; i++) start.add(Duration(hours: i))];
  }

  ModelForecastPoint? _nearestPoint(
    List<ModelForecastPoint> pts,
    DateTime target,
  ) {
    if (pts.isEmpty) return null;
    var best = pts.first;
    var bestDiff = pts.first.time.toLocal().difference(target).abs();
    for (final p in pts) {
      final diff = p.time.toLocal().difference(target).abs();
      if (diff < bestDiff) {
        best = p;
        bestDiff = diff;
      }
    }
    return bestDiff.inMinutes <= 90 ? best : null;
  }

  GraphPoint? _nearestWave(DateTime target) {
    if (_waveHeight.isEmpty) return null;
    var best = _waveHeight.first;
    var bestDiff = _waveHeight.first.time.toLocal().difference(target).abs();
    for (final p in _waveHeight) {
      final diff = p.time.toLocal().difference(target).abs();
      if (diff < bestDiff) {
        best = p;
        bestDiff = diff;
      }
    }
    return bestDiff.inMinutes <= 90 ? best : null;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: cBg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Comparativa de modelos',
                          style: TextStyle(
                            color: cText,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          widget.place,
                          style: const TextStyle(color: cMuted, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  if (_data != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilledButton.icon(
                        onPressed: _sharing
                            ? null
                            : () => _openReportPreview(context),
                        icon: const Icon(Icons.picture_as_pdf, size: 18),
                        label: const Text('Generar informe'),
                      ),
                    ),
                  if (_data != null)
                    IconButton(
                      onPressed: _sharing ? null : () => _shareReport(context),
                      icon: _sharing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: cCyan,
                              ),
                            )
                          : const Icon(Icons.share, color: cText),
                      tooltip: 'Compartir PDF',
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: cText),
                  ),
                ],
              ),
              Row(
                children: [
                  Switch(
                    value: _mastCorrection,
                    onChanged: (v) => setState(() => _mastCorrection = v),
                  ),
                  const Text(
                    'Corregir por altura de palo',
                    style: TextStyle(color: cMuted, fontSize: 13),
                  ),
                  if (_mastCorrection) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 160,
                      child: Slider(
                        value: _mastHeightM,
                        min: 5,
                        max: 50,
                        divisions: 45,
                        label: '${_mastHeightM.round()} m',
                        onChanged: (v) => setState(() => _mastHeightM = v),
                      ),
                    ),
                    Text(
                      '${_mastHeightM.round()} m',
                      style: const TextStyle(
                        color: cText,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading)
      return const Center(child: CircularProgressIndicator(color: cCyan));
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: cMuted, size: 40),
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: cMuted, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    final data = _data!;
    final activeModels = [
      for (final m in weatherModels)
        if (data.containsKey(m.id)) m,
    ];
    final hours = _hourColumns();
    const colW = 58.0;
    const headerH = 30.0;
    const dividerH = 9.0;
    const modelRowH = 48.0;
    const waveRowH = 34.0;
    final hasWave = _waveHeight.isNotEmpty;
    final hasRain = _hasRain(activeModels, data, hours);

    // Sticky label column (doesn't scroll horizontally) + a synced, identically
    // heighted value grid that does — so "which row is this" never gets lost
    // while scanning far into the hours.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _comparisonOverview(
            activeModels,
            data,
            hours,
            hasRain: hasRain,
            hasWave: hasWave,
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: headerH),
                  const SizedBox(height: dividerH),
                  for (final m in activeModels)
                    SizedBox(
                      height: modelRowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          m.label,
                          style: TextStyle(
                            color: m.color,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  if (hasWave) ...[
                    const SizedBox(height: dividerH),
                    const SizedBox(
                      height: waveRowH,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'OLA',
                          style: TextStyle(
                            color: cPurple,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: colW * hours.length,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: headerH,
                          child: Row(
                            children: [
                              for (final h in hours)
                                SizedBox(
                                  width: colW,
                                  child: Column(
                                    children: [
                                      if (h.hour == 0)
                                        Text(
                                          '${h.day}/${h.month}',
                                          style: const TextStyle(
                                            color: cCyan,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      Text(
                                        '${h.hour.toString().padLeft(2, '0')}h',
                                        style: const TextStyle(
                                          color: cMuted,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(
                          height: dividerH,
                          child: Divider(color: Color(0xff1e3040), height: 8),
                        ),
                        for (final m in activeModels)
                          SizedBox(
                            height: modelRowH,
                            child: Row(
                              children: [
                                for (final h in hours)
                                  SizedBox(
                                    width: colW,
                                    child: _windCell(
                                      _nearestPoint(data[m.id]!, h),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (hasWave) ...[
                          const SizedBox(
                            height: dividerH,
                            child: Divider(color: Color(0xff1e3040), height: 8),
                          ),
                          SizedBox(
                            height: waveRowH,
                            child: Row(
                              children: [
                                for (final h in hours)
                                  SizedBox(
                                    width: colW,
                                    child: _waveCell(_nearestWave(h)),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (activeModels.isNotEmpty) ...[
            _twsChart(activeModels, data, hours),
            const SizedBox(height: 16),
            _windDirMeteogram(
              activeModels.firstWhere(
                (m) => m.id == _meteogramModelId,
                orElse: () => activeModels.first,
              ),
              activeModels,
              data,
              hours,
            ),
            const SizedBox(height: 16),
            if (hasRain) ...[
              _rainChart(activeModels, data, hours),
              const SizedBox(height: 16),
            ],
          ],
          if (hasWave) _pressureWaveChart(activeModels, data, hours),
        ],
      ),
    );
  }

  Widget _comparisonOverview(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours, {
    required bool hasRain,
    required bool hasWave,
  }) {
    final worst = _worstWindWindow(activeModels, data, hours);
    final spread6h = _averageSpreadUntil(
      activeModels,
      data,
      hours,
      const Duration(hours: 6),
    );
    final spread24h = _averageSpreadUntil(
      activeModels,
      data,
      hours,
      const Duration(hours: 24),
    );
    final spread48h = _averageSpreadUntil(
      activeModels,
      data,
      hours,
      const Duration(hours: 48),
    );
    final maxWave = _maxWaveFor(hours);
    final consensus = _consensusValues(activeModels, data, hours);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: cPanel,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _overviewTile(
                'Peor tramo',
                _shortHour(worst.start),
                worst.maxKn == null
                    ? 'sin rachas'
                    : 'máx ${worst.maxKn!.round()} kt',
                cRed,
              ),
              const SizedBox(width: 8),
              _overviewTile(
                'Confianza',
                '6h ${_confidenceBrief(spread6h)}',
                '24h ${_confidenceBrief(spread24h)} · 48h ${_confidenceBrief(spread48h)}',
                cYellow,
              ),
              const SizedBox(width: 8),
              _overviewTile(
                'Mar',
                maxWave == null ? '--' : '${maxWave.toStringAsFixed(1)} m',
                hasWave ? 'altura máxima' : 'sin ola',
                cPurple,
              ),
              const SizedBox(width: 8),
              _overviewTile(
                'Lluvia',
                hasRain ? 'Sí' : 'No',
                hasRain ? 'ver gráfica' : 'sin precipitación',
                cCyan,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 138,
            child: CustomPaint(
              painter: _ConsensusBandChartPainter(
                meanValues: consensus.mean,
                minValues: consensus.min,
                maxValues: consensus.max,
                hourLabels: hours,
              ),
              size: Size.infinite,
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 30, top: 2),
            child: Text(
              'Consenso TWS: línea = media · banda = min/max entre modelos',
              style: TextStyle(
                color: cMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overviewTile(
    String title,
    String value,
    String subtitle,
    Color color,
  ) => Expanded(
    child: Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: cText,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: cMuted, fontSize: 10),
          ),
        ],
      ),
    ),
  );

  Widget _windCell(ModelForecastPoint? p) {
    if (p == null || p.windKn == null) {
      return const SizedBox(
        height: 44,
        child: Center(
          child: Text('--', style: TextStyle(color: cMuted, fontSize: 12)),
        ),
      );
    }
    final speed = _corrected(p.windKn!);
    final gust = p.gustKn != null ? _corrected(p.gustKn!) : null;
    final color = windColor(speed);
    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.22),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5), width: 0.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${speed.round()}',
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (p.windDirDeg != null)
                Transform.rotate(
                  angle: (p.windDirDeg! + 180) * math.pi / 180,
                  child: Icon(Icons.navigation, color: color, size: 12),
                ),
            ],
          ),
          if (gust != null)
            Text(
              'r.${gust.round()}',
              style: const TextStyle(color: cMuted, fontSize: 9),
            ),
        ],
      ),
    );
  }

  Widget _waveCell(GraphPoint? p) {
    if (p == null)
      return const SizedBox(
        height: 30,
        child: Center(
          child: Text('--', style: TextStyle(color: cMuted, fontSize: 12)),
        ),
      );
    return SizedBox(
      height: 30,
      child: Center(
        child: Text(
          '${p.value.toStringAsFixed(1)} m',
          style: const TextStyle(
            color: cPurple,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _chartCard(String title, String subtitle, Widget child) => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
    decoration: BoxDecoration(
      color: cPanel,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: cText,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(subtitle, style: const TextStyle(color: cMuted, fontSize: 11)),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  Widget _legendRow(List<({Color color, String label})> items) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final it in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: it.color,
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                it.label,
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
      ],
    ),
  );

  Widget _twsChart(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final series = [
      for (final m in activeModels)
        (
          color: m.color,
          values: [for (final h in hours) _nearestPoint(data[m.id]!, h)?.windKn]
              .map((v) => v == null ? null : _corrected(v))
              .toList(),
        ),
    ];
    return _chartCard(
      'TWS por hora — divergencia entre modelos',
      'Velocidad del viento (nudos)',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 170,
            child: CustomPaint(
              painter: _SimpleLineChartPainter(
                series: series,
                hourLabels: hours,
              ),
              size: Size.infinite,
            ),
          ),
          _legendRow([
            for (final m in activeModels) (color: m.color, label: m.label),
          ]),
        ],
      ),
    );
  }

  Widget _rainChart(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final series = [
      for (final m in activeModels)
        (
          color: m.color,
          values: [
            for (final h in hours) _nearestPoint(data[m.id]!, h)?.rainPct,
          ],
        ),
    ];
    return _chartCard(
      'Lluvia por modelo',
      'Probabilidad de precipitación (%)',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 150,
            child: CustomPaint(
              painter: _SimpleLineChartPainter(
                series: series,
                hourLabels: hours,
              ),
              size: Size.infinite,
            ),
          ),
          _legendRow([
            for (final m in activeModels) (color: m.color, label: m.label),
          ]),
        ],
      ),
    );
  }

  Widget _windDirMeteogram(
    ModelSeries model,
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final pts = data[model.id]!;
    return _chartCard(
      'TWD — meteograma de dirección',
      'Flecha = hacia dónde sopla · color = intensidad',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (activeModels.length > 1)
                for (final m in activeModels)
                  ChoiceChip(
                    label: Text(
                      m.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: m.id == model.id ? cBg : m.color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    selected: m.id == model.id,
                    selectedColor: m.color,
                    backgroundColor: m.color.withOpacity(0.12),
                    side: BorderSide(color: m.color.withOpacity(0.5)),
                    onSelected: (_) => setState(() => _meteogramModelId = m.id),
                  ),
              const SizedBox(width: 4),
              ChoiceChip(
                label: const Text(
                  'Viento',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                selected: !_meteogramShowGust,
                onSelected: (_) => setState(() => _meteogramShowGust = false),
              ),
              ChoiceChip(
                label: const Text(
                  'Rachas',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                selected: _meteogramShowGust,
                onSelected: (_) => setState(() => _meteogramShowGust = true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 60,
            child: Row(
              children: [
                for (final h in hours)
                  Expanded(
                    child: Builder(
                      builder: (_) {
                        final p = _nearestPoint(pts, h);
                        final rawKn = _meteogramShowGust
                            ? p?.gustKn
                            : p?.windKn;
                        final kn = rawKn == null ? null : _corrected(rawKn);
                        final deg = p?.windDirDeg;
                        final color = meteogramColor(kn);
                        // A missing gust value (some models don't report it) must not
                        // silently color as "calm" — that made gust mode look like
                        // *less* wind than plain wind mode. Show the same "no data"
                        // dash as a missing direction instead.
                        return Center(
                          child: deg == null || kn == null
                              ? const Text(
                                  '–',
                                  style: TextStyle(color: cMuted, fontSize: 12),
                                )
                              : Transform.rotate(
                                  angle: (deg + 180) * math.pi / 180,
                                  child: Icon(
                                    Icons.navigation,
                                    color: color,
                                    size: 16,
                                  ),
                                ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 14,
            // One Expanded per *labeled* group of 6 hours (not one per hour with
            // the rest hidden) — hiding 5 out of every 6 still left each visible
            // label squeezed into 1/72 of the row's width, so it clipped down to
            // a single character (which read as just "0" or "1").
            child: Row(
              children: [
                for (var i = 0; i < hours.length; i += 6)
                  Expanded(
                    child: Text(
                      hours[i].hour == 0
                          ? '${hours[i].day}/${hours[i].month}'
                          : '${hours[i].hour.toString().padLeft(2, '0')}h',
                      style: TextStyle(
                        color: hours[i].hour == 0 ? cCyan : cMuted,
                        fontSize: 9,
                        fontWeight: hours[i].hour == 0
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _legendRow(const [
            (color: cMuted, label: '< 3 kt'),
            (color: Color(0xff2ea89a), label: '3-7 kt'),
            (color: cOrange, label: '7-10 kt'),
            (color: cRed, label: '10-15 kt'),
            (color: Color(0xffb33a3a), label: '15-20 kt'),
            (color: cPurple, label: '> 20 kt'),
          ]),
        ],
      ),
    );
  }

  Widget _pressureWaveChart(
    List<ModelSeries> activeModels,
    Map<String, List<ModelForecastPoint>> data,
    List<DateTime> hours,
  ) {
    final series = [
      for (final m in activeModels)
        (
          color: m.color,
          values: [
            for (final h in hours) _nearestPoint(data[m.id]!, h)?.pressureHpa,
          ],
        ),
    ];
    final waveValues = [for (final h in hours) _nearestWave(h)?.value];
    return _chartCard(
      'Presión y oleaje combinados',
      'Presión media (hPa, líneas, izq.) y altura de ola (m, área, dcha.)',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 170,
            child: CustomPaint(
              painter: _SimpleLineChartPainter(
                series: series,
                hourLabels: hours,
                areaValues: waveValues,
                areaColor: cPurple,
                areaAxisLabel: 'm',
              ),
              size: Size.infinite,
            ),
          ),
          _legendRow([
            for (final m in activeModels)
              (color: m.color, label: 'Presión ${m.label}'),
            (color: cPurple, label: 'Altura de ola'),
          ]),
        ],
      ),
    );
  }
}

/// Compact multi-line chart with an optional filled area series on its own
/// (independent) vertical scale — used for the TWS/pressure+wave graphs below
/// the hourly comparison table.
class _SimpleLineChartPainter extends CustomPainter {
  const _SimpleLineChartPainter({
    required this.series,
    required this.hourLabels,
    this.areaValues,
    this.areaColor,
    this.areaAxisLabel,
  });
  final List<({Color color, List<double?> values})> series;
  final List<DateTime> hourLabels;
  final List<double?>? areaValues;
  final Color? areaColor;
  final String? areaAxisLabel;

  static const _lPad = 30.0, _tPad = 6.0, _bPad = 16.0;
  double get _rPad => areaValues != null ? 30.0 : 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final pL = _lPad,
        pR = size.width - _rPad,
        pT = _tPad,
        pB = size.height - _bPad;
    final pW = pR - pL, pH = pB - pT;
    if (pW <= 0 || pH <= 0 || hourLabels.isEmpty) return;
    final n = hourLabels.length;
    double xAt(int i) => n <= 1 ? pL : pL + pW * i / (n - 1);

    final allVals = <double>[
      for (final s in series) ...s.values.whereType<double>(),
    ];
    if (allVals.isEmpty) return;
    var yMin = allVals.reduce(math.min), yMax = allVals.reduce(math.max);
    final pad = (yMax - yMin) < 1 ? 1.0 : (yMax - yMin) * 0.15;
    yMin -= pad;
    yMax += pad;
    final ySpan = (yMax - yMin).clamp(0.001, double.infinity);
    double yAt(double v) => pB - (v - yMin) / ySpan * pH;

    const labelStyle = TextStyle(color: Color(0xff5e7e90), fontSize: 9);
    final gridPaint = Paint()
      ..color = const Color(0xff1a2c38)
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final v = yMin + ySpan * i / 3;
      final y = yAt(v);
      canvas.drawLine(Offset(pL, y), Offset(pR, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: v.round().toString(), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pL - tp.width - 4, y - tp.height / 2));
    }
    for (var i = 0; i < n; i += (n / 6).ceil().clamp(1, n)) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${hourLabels[i].hour.toString().padLeft(2, '0')}h',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(xAt(i) - tp.width / 2, pB + 3));
    }

    final area = areaValues;
    if (area != null && area.any((v) => v != null)) {
      final vals = area.whereType<double>().toList();
      final aMin = vals.reduce(math.min), aMax = vals.reduce(math.max);
      final aSpan = (aMax - aMin).clamp(0.001, double.infinity);
      double areaY(double v) => pB - (v - aMin) / aSpan * pH * 0.9;
      final path = Path()..moveTo(pL, pB);
      var started = false;
      for (var i = 0; i < n; i++) {
        final v = area[i];
        if (v == null) continue;
        final pt = Offset(xAt(i), areaY(v));
        if (!started) {
          path.lineTo(pt.dx, pt.dy);
          started = true;
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      path.lineTo(xAt(n - 1), pB);
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = (areaColor ?? cMuted).withOpacity(0.18),
      );

      final axisColor = (areaColor ?? cMuted);
      final axisLabelStyle = TextStyle(
        color: axisColor.withOpacity(0.85),
        fontSize: 9,
        fontWeight: FontWeight.w600,
      );
      for (var i = 0; i <= 3; i++) {
        final v = aMin + aSpan * i / 3;
        final y = pB - (v - aMin) / aSpan * pH * 0.9;
        final text = '${v.toStringAsFixed(1)}${areaAxisLabel ?? ''}';
        final tp = TextPainter(
          text: TextSpan(text: text, style: axisLabelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(pR + 4, y - tp.height / 2));
      }
    }

    for (final s in series) {
      final path = Path();
      var started = false;
      for (var i = 0; i < n; i++) {
        final v = s.values[i];
        if (v == null) {
          started = false;
          continue;
        }
        final pt = Offset(xAt(i), yAt(v));
        if (!started) {
          path.moveTo(pt.dx, pt.dy);
          started = true;
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SimpleLineChartPainter oldDelegate) => true;
}

class _ConsensusBandChartPainter extends CustomPainter {
  const _ConsensusBandChartPainter({
    required this.meanValues,
    required this.minValues,
    required this.maxValues,
    required this.hourLabels,
  });
  final List<double?> meanValues;
  final List<double?> minValues;
  final List<double?> maxValues;
  final List<DateTime> hourLabels;

  static const _lPad = 30.0, _tPad = 6.0, _rPad = 8.0, _bPad = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final pL = _lPad,
        pR = size.width - _rPad,
        pT = _tPad,
        pB = size.height - _bPad;
    final pW = pR - pL, pH = pB - pT;
    if (pW <= 0 || pH <= 0 || hourLabels.isEmpty) return;
    final n = hourLabels.length;
    double xAt(int i) => n <= 1 ? pL : pL + pW * i / (n - 1);
    final values = <double>[
      ...meanValues.whereType<double>(),
      ...minValues.whereType<double>(),
      ...maxValues.whereType<double>(),
    ];
    if (values.isEmpty) return;
    var yMin = math.max(0.0, values.reduce(math.min) - 2);
    var yMax = values.reduce(math.max) + 2;
    if (yMax - yMin < 4) yMax = yMin + 4;
    final ySpan = yMax - yMin;
    double yAt(double v) => pB - (v - yMin) / ySpan * pH;

    final gridPaint = Paint()
      ..color = const Color(0xff1a2c38)
      ..strokeWidth = 1;
    const labelStyle = TextStyle(color: Color(0xff5e7e90), fontSize: 9);
    for (var i = 0; i <= 3; i++) {
      final v = yMin + ySpan * i / 3;
      final y = yAt(v);
      canvas.drawLine(Offset(pL, y), Offset(pR, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: v.round().toString(), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pL - tp.width - 4, y - tp.height / 2));
    }
    for (var i = 0; i < n; i += (n / 6).ceil().clamp(1, n)) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${hourLabels[i].hour.toString().padLeft(2, '0')}h',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(xAt(i) - tp.width / 2, pB + 3));
    }

    final band = Path();
    var started = false;
    for (var i = 0; i < n; i++) {
      final v = minValues[i];
      if (v == null) continue;
      final pt = Offset(xAt(i), yAt(v));
      if (!started) {
        band.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        band.lineTo(pt.dx, pt.dy);
      }
    }
    for (var i = n - 1; i >= 0; i--) {
      final v = maxValues[i];
      if (v == null) continue;
      band.lineTo(xAt(i), yAt(v));
    }
    if (started) {
      band.close();
      canvas.drawPath(band, Paint()..color = cCyan.withOpacity(0.16));
    }

    final line = Path();
    started = false;
    for (var i = 0; i < n; i++) {
      final v = meanValues[i];
      if (v == null) {
        started = false;
        continue;
      }
      final pt = Offset(xAt(i), yAt(v));
      if (!started) {
        line.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        line.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = cCyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ConsensusBandChartPainter oldDelegate) => true;
}
