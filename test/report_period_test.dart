import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:rewind_xcover6_panel/models.dart';
import 'package:rewind_xcover6_panel/performance_report.dart';

void main() {
  test('al ampliar por el inicio arrastra la ventana completa de 48 horas', () {
    final result = normalizeReportRange(
      const RangeValues(1440, 4320),
      const RangeValues(1000, 4320),
    );

    expect(result, const RangeValues(1005, 3885));
  });

  test('al ampliar por el final arrastra la ventana completa de 48 horas', () {
    final result = normalizeReportRange(
      const RangeValues(0, 2880),
      const RangeValues(0, 4000),
    );

    expect(result, const RangeValues(1125, 4005));
  });

  test('los dos marcadores ajustan en pasos de 15 minutos', () {
    final startMoved = normalizeReportRange(
      const RangeValues(3000, 3600),
      const RangeValues(3011, 3600),
    );
    final endMoved = normalizeReportRange(
      startMoved,
      RangeValues(startMoved.start, 3592),
    );

    expect(startMoved, const RangeValues(3015, 3600));
    expect(endMoved, const RangeValues(3015, 3585));
  });

  test('filtra una coordenada GPS aislada e imposible', () {
    final base = DateTime.utc(2026, 9, 12, 10);
    final samples = <ReportGpsSample>[
      (time: base, lat: 37, lon: -4, sogKn: 5, moving: true),
      (
        time: base.add(const Duration(minutes: 1)),
        lat: 20,
        lon: 20,
        sogKn: 5,
        moving: true,
      ),
      (
        time: base.add(const Duration(minutes: 2)),
        lat: 37,
        lon: -3.999,
        sogKn: 5,
        moving: true,
      ),
    ];

    final filtered = filterImplausibleReportGps(samples);

    expect(filtered, hasLength(2));
    expect(filtered.map((p) => p.lon), [-4, -3.999]);
  });

  test('un primer fix imposible no contamina el contexto del resto', () {
    final base = DateTime.utc(2026, 9, 12, 10);
    final samples = <ReportGpsSample>[
      (time: base, lat: 0, lon: 0, sogKn: 0, moving: false),
      (
        time: base.add(const Duration(minutes: 1)),
        lat: 37,
        lon: -4,
        sogKn: 0,
        moving: false,
      ),
      (
        time: base.add(const Duration(minutes: 2)),
        lat: 37,
        lon: -3.9999,
        sogKn: 0,
        moving: false,
      ),
    ];

    final filtered = filterImplausibleReportGps(samples);

    expect(filtered, hasLength(2));
    expect(filtered.first.lat, 37);
  });

  test('distancia y tiempo navegando usan los timestamps reales', () {
    final base = DateTime.utc(2026, 9, 12, 10);
    final points = [
      GraphPoint(time: base, value: 6),
      GraphPoint(time: base.add(const Duration(minutes: 2)), value: 6),
      // El hueco de 30 minutos no se integra como distancia navegada.
      GraphPoint(time: base.add(const Duration(minutes: 32)), value: 8),
    ];

    final stats = calculateReportNavigationStats(
      points,
      const Duration(minutes: 2),
    );

    expect(stats.distanceNm, closeTo(0.2, 0.0001));
    expect(stats.underway, const Duration(minutes: 2));
    expect(stats.avgSogUnderway, closeTo(6, 0.0001));
    expect(stats.maxSog, 8);
  });

  test('la media STW excluye los tramos sin arrancada', () {
    final base = DateTime.utc(2026, 9, 12, 10);
    final stw = [
      GraphPoint(time: base, value: 1),
      GraphPoint(time: base.add(const Duration(minutes: 2)), value: 1),
      GraphPoint(time: base.add(const Duration(minutes: 4)), value: 7),
      GraphPoint(time: base.add(const Duration(minutes: 6)), value: 7),
    ];
    final sog = [
      GraphPoint(time: base.add(const Duration(minutes: 1)), value: 0),
      GraphPoint(time: base.add(const Duration(minutes: 3)), value: 6),
      GraphPoint(time: base.add(const Duration(minutes: 5)), value: 6),
    ];

    final average = reportAverageStwUnderway(
      stw,
      sog,
      const Duration(minutes: 2),
    );

    expect(average, closeTo(5.5, 0.0001));
  });

  test('una serie vacía no inventa ceros en las estadísticas', () {
    final stats = calculateReportNavigationStats(
      const [],
      const Duration(minutes: 2),
    );

    expect(stats.distanceNm, isNull);
    expect(stats.avgSogUnderway, isNull);
    expect(stats.maxSog, isNull);
    expect(stats.underway, Duration.zero);
  });

  test('la polar observada se puede renderizar en PDF', () async {
    final bands = [
      for (var angle = 0; angle < 180; angle += 10)
        (loDeg: angle, hiDeg: angle + 10),
    ];
    final polar = (
      twsEdges: <int>[6, 8, 10],
      twaBands: bands,
      avgStw: [
        for (var b = 0; b < bands.length; b++)
          <double?>[b < 3 ? null : 4 + b / 12, b < 4 ? null : 5 + b / 12],
      ],
      counts: [
        for (var b = 0; b < bands.length; b++)
          <int>[b < 3 ? 0 : 5, b < 4 ? 0 : 6],
      ],
      minSamples: 3,
      engineFilterAvailable: true,
    );
    final document = pw.Document();
    final font = PdfFont.helvetica(document.document);
    document.addPage(
      pw.Page(
        build: (_) =>
            pdfObservedPolarChart(polar: polar, font: font, width: 500),
      ),
    );

    final bytes = await document.save();
    expect(bytes, isNotEmpty);
  });
}
