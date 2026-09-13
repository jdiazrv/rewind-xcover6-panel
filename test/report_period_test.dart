import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';
import 'package:rewind_xcover6_panel/performance_report.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:rewind_xcover6_panel/model_comparison.dart';
import 'package:rewind_xcover6_panel/pdf/pdf_theme.dart';

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
    // La navegación empieza y acaba donde hubo arrancada, no en los bordes
    // del periodo pedido.
    expect(stats.startedAt, base);
    expect(stats.endedAt, base.add(const Duration(minutes: 2)));
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

  test('el máximo solo cuenta mientras se navega', () {
    final base = DateTime.utc(2026, 9, 12, 10);
    final sog = [
      GraphPoint(time: base, value: 0),
      GraphPoint(time: base.add(const Duration(minutes: 2)), value: 6),
      GraphPoint(time: base.add(const Duration(minutes: 4)), value: 7),
    ];
    final stw = [
      // Un pico con el barco parado (corredera sucia, oleaje en el
      // molinete) no puede ser el máximo de la navegación.
      GraphPoint(time: base, value: 12),
      GraphPoint(time: base.add(const Duration(minutes: 2)), value: 6.5),
      GraphPoint(time: base.add(const Duration(minutes: 4)), value: 7.2),
    ];
    expect(
      reportMaxSpeedUnderway(stw, sog, const Duration(minutes: 2)),
      closeTo(7.2, 0.0001),
    );
    expect(reportMaxSpeedUnderway(sog, sog, const Duration(minutes: 2)), 7);
    expect(reportMaxSpeedUnderway(const [], sog, const Duration(minutes: 2)),
        isNull);
  });

  test('la etiqueta de navegación dice cuándo empezó y acabó', () {
    final start = DateTime(2026, 9, 12, 9, 12);
    expect(
      reportNavigationSpanLabel(start, DateTime(2026, 9, 12, 16, 40)),
      'de 09:12 a 16:40',
    );
    expect(
      reportNavigationSpanLabel(start, DateTime(2026, 9, 13, 1, 5)),
      'de 12/09 09:12 a 13/09 01:05',
    );
    expect(reportNavigationSpanLabel(null, null), 'sin navegación registrada');
  });

  test('una tarjeta con texto largo no se queda en blanco en el PDF', () async {
    // Antes, un valor que no cabía en una línea desbordaba la tarjeta y el
    // PDF perdía el valor y el subtítulo: solo quedaba el título.
    final doc = pw.Document(compress: false);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.base(),
        build: (_) => pw.Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              pw.Expanded(
                child: pw.SizedBox(
                  height: 62,
                  child: pdfInfoCard(
                    'SOG',
                    '47.8 kt media (una etiqueta larga)',
                    'máx 93.1 kt con un subtítulo también bastante largo',
                    pdfGreen,
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
    final text = String.fromCharCodes(await doc.save());
    expect(text, contains('47.8'));
    expect(text, contains('93.1'));
  });

  group('tramos de movimiento en la línea de tiempo', () {
    final start = DateTime.utc(2026, 9, 10, 0);
    GraphPoint at(int minutes, double kn) =>
        GraphPoint(time: start.add(Duration(minutes: minutes)), value: kn);

    test('parado, navegando y otra vez parado da un solo tramo', () {
      final spans = reportMovementSpans([
        at(0, 0),
        at(60, 0.2),
        at(70, 6),
        at(80, 6.5),
        at(90, 0.1),
        at(200, 0),
      ], start);
      expect(spans, hasLength(1));
      expect(spans.single.start, 70);
      expect(spans.single.end, 90);
    });

    test('un hueco largo de datos corta el tramo en dos', () {
      final spans = reportMovementSpans([
        at(0, 6),
        at(10, 6),
        // 3 horas sin datos: no se da por navegado.
        at(190, 6),
        at(200, 6),
      ], start);
      expect(spans, hasLength(2));
      expect(spans[0].end, 10);
      expect(spans[1].start, 190);
    });

    test('si sigue navegando al final, el tramo acaba en su último dato', () {
      final spans = reportMovementSpans([at(100, 0), at(110, 5), at(120, 5)], start);
      expect(spans.single.start, 110);
      expect(spans.single.end, 120);
    });

    test('sin datos o siempre parado no hay tramos', () {
      expect(reportMovementSpans(const [], start), isEmpty);
      expect(reportMovementSpans([at(0, 0), at(10, 0.3)], start), isEmpty);
    });
  });

  group('paradas en la traza', () {
    final t0 = DateTime.utc(2026, 9, 12, 8);
    GraphPoint sog(int minute, double kn) =>
        GraphPoint(time: t0.add(Duration(minutes: minute)), value: kn);
    final track = [
      (lat: 37.39, lon: 24.38, time: t0.add(const Duration(minutes: 60))),
    ];

    test('parada con el ancla armada es fondeado aunque sea corta', () {
      final stops = detectReportStops(
        sog: [sog(0, 6), sog(50, 6), sog(60, 0.1), sog(75, 0.2), sog(90, 0.1), sog(100, 6)],
        anchorStates: [(time: t0.add(const Duration(minutes: 70)), anchored: true)],
        track: track,
      );
      expect(stops, hasLength(1));
      expect(stops.single.kind, ReportStopKind.anchored);
      expect(stops.single.start, t0.add(const Duration(minutes: 60)));
      expect(stops.single.end, t0.add(const Duration(minutes: 90)));
      expect(stops.single.lat, 37.39);
      expect(reportStopKindLabel(stops.single.kind), 'Fondeado');
    });

    test('más de una hora parado sin fondeo es fondeado/marina', () {
      final stops = detectReportStops(
        sog: [sog(0, 6), sog(60, 0), sog(100, 0), sog(150, 0.1), sog(160, 5)],
        anchorStates: const [],
        track: track,
      );
      expect(stops.single.kind, ReportStopKind.anchoredOrMarina);
      expect(reportStopKindLabel(stops.single.kind), 'Fondeado/marina');
    });

    test('una parada corta sin fondeo no se marca', () {
      final stops = detectReportStops(
        sog: [sog(0, 6), sog(60, 0), sog(90, 0.2), sog(100, 6)],
        anchorStates: const [],
        track: track,
      );
      expect(stops, isEmpty);
    });

    test('con los instrumentos apagados en marina, el hueco cuenta', () {
      // Parado a las 60 y 62, sin datos 4 horas, parado a las 300 y sale.
      final stops = detectReportStops(
        sog: [sog(0, 6), sog(60, 0), sog(62, 0), sog(300, 0), sog(305, 6)],
        anchorStates: const [],
        track: track,
      );
      expect(stops.single.kind, ReportStopKind.anchoredOrMarina);
      expect(stops.single.end, t0.add(const Duration(minutes: 300)));
    });

    test('un ancla armada lejos de la parada no la hace fondeo', () {
      final stops = detectReportStops(
        sog: [sog(0, 6), sog(60, 0), sog(150, 0), sog(160, 6)],
        anchorStates: [(time: t0.add(const Duration(minutes: 600)), anchored: true)],
        track: track,
      );
      expect(stops.single.kind, ReportStopKind.anchoredOrMarina);
    });

    test('dos navegaciones con parada intermedia dan una parada', () {
      final stops = detectReportStops(
        sog: [sog(0, 6), sog(30, 6), sog(40, 0), sog(200, 0), sog(210, 6), sog(260, 6)],
        anchorStates: const [],
        track: track,
      );
      expect(stops, hasLength(1));
      expect(stops.single.start, t0.add(const Duration(minutes: 40)));
    });
  });

  group('muestras a motor en la tabla de rendimiento', () {
    final t0 = DateTime.utc(2026, 9, 12, 10);
    GraphPoint rpm(int minute, double value) =>
        GraphPoint(time: t0.add(Duration(minutes: minute)), value: value);

    test('sin telemetría de motor en el periodo no se descarta nada', () {
      expect(reportSampleUnderEngine(const [], t0), isFalse);
    });

    test('con el motor girando cerca, la muestra es a motor', () {
      expect(reportSampleUnderEngine([rpm(2, 1800)], t0), isTrue);
    });

    test('RPM por debajo del umbral no es motor', () {
      expect(reportSampleUnderEngine([rpm(1, 150)], t0), isFalse);
    });

    test('sin RPM cerca es motor apagado, o sea vela', () {
      // Hubo motor, pero hace más de 10 minutos: al apagarlo deja de
      // publicar, y esa ausencia no es "sin datos" sino vela.
      expect(reportSampleUnderEngine([rpm(-40, 1800)], t0), isFalse);
    });

    test('manda la lectura más cercana', () {
      expect(
        reportSampleUnderEngine([rpm(-9, 1800), rpm(1, 0)], t0),
        isFalse,
        reason: 'el motor se apagó justo antes',
      );
    });
  });

  test('la duración de una parada va en horas, o en días si pasa de 3', () {
    expect(reportStopDurationLabel(const Duration(minutes: 5)), '0.1 h');
    expect(
      reportStopDurationLabel(const Duration(hours: 18, minutes: 25)),
      '18.4 h',
    );
    expect(reportStopDurationLabel(const Duration(hours: 72)), '72.0 h');
    expect(reportStopDurationLabel(const Duration(hours: 80)), '3.3 días');
  });
}
