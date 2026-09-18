import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/polars.dart';
import 'package:rewind_xcover6_panel/routing/routing_page.dart';
import 'package:rewind_xcover6_panel/routing/weather.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Proveedor sin red: viento del N de 12 kn y ola de 0,8 m en toda la zona.
class _FlatProvider implements WeatherProvider {
  int calls = 0;
  WeatherModel? lastModel;

  @override
  String get name => 'plano';

  @override
  Future<WeatherGrid> fetchGrid({
    required GeoBox box,
    required DateTime from,
    required DateTime to,
    required WeatherModel model,
  }) async {
    calls++;
    lastModel = model;
    const nLat = 6, nLon = 6;
    final start = DateTime.utc(from.year, from.month, from.day, from.hour);
    final hours = to.difference(from).inHours + 1;
    final times = [for (var h = 0; h <= hours; h++) start.add(Duration(hours: h))];
    final n = times.length * nLat * nLon;
    Float32List filled(double v) => Float32List(n)..fillRange(0, n, v);
    return WeatherGrid(
      lat0: box.south,
      lon0: box.west,
      step: math(box),
      nLat: nLat,
      nLon: nLon,
      times: times,
      windU: filled(0),
      windV: filled(-12),
      waveH: filled(0.8),
      waveDirU: filled(0),
      waveDirV: filled(1),
      waveT: filled(4),
      gust: filled(17),
      model: model,
      source: 'prueba · ${model.label}',
      fetchedAt: DateTime.now(),
    );
  }

  double math(GeoBox b) =>
      ((b.north - b.south) > (b.east - b.west)
          ? (b.north - b.south)
          : (b.east - b.west)) /
      5;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester t,
    _FlatProvider p,
    Size size, {
    PolarTable? polar,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: RoutingPage(
          weather: p,
          boatLat: 37.395,
          boatLon: 24.878,
          polar: polar,
          polarFactorPercent: 100,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 50));
  }

  for (final (name, size) in [
    ('tablet apaisada', const Size(1280, 800)),
    ('teléfono vertical', const Size(400, 860)),
  ]) {
    testWidgets('abre sin desbordes y baja el tiempo · $name', (t) async {
      final p = _FlatProvider();
      await pump(t, p, size);
      expect(t.takeException(), isNull);
      expect(p.calls, greaterThanOrEqualTo(1));
      expect(find.text('RUTA'), findsOneWidget);
      // Sin polar lo dice y remite a CFG, no ofrece elegir otra.
      expect(find.textContaining('CFG › Barco'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });
  }

  testWidgets('elegir llegada tocando el chip y el mapa', (t) async {
    final p = _FlatProvider();
    await pump(t, p, const Size(1280, 800));
    await t.tap(find.text('Llegada'));
    await t.pump();
    expect(find.text('Toca el mapa donde llegas'), findsOneWidget);
    await t.tapAt(const Offset(900, 450));
    // flutter_map espera el margen de doble toque antes de dar el toque.
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Toca el mapa donde llegas'), findsNothing);
    // El punto se colocó y arranca (con debounce) la descarga del tiempo.
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('M directas'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('cambiar de modelo vuelve a pedir el tiempo de ese modelo', (
    t,
  ) async {
    final p = _FlatProvider();
    await pump(t, p, const Size(1280, 800));
    await t.tap(find.byIcon(Icons.tune));
    await t.pumpAndSettle();
    await t.tap(find.text('Media'));
    await t.pump();
    await t.tap(find.text('Aplicar'));
    await t.pump(const Duration(milliseconds: 400));
    expect(p.lastModel, WeatherModel.mean);
    expect(find.textContaining('prueba · Media'), findsOneWidget);
  });

  testWidgets('añadir una vía y quitarla con doble toque en el mapa', (
    t,
  ) async {
    final p = _FlatProvider();
    await pump(t, p, const Size(1280, 800));
    expect(find.text('vía'), findsOneWidget);
    expect(find.textContaining('vías'), findsNothing);
    await t.tap(find.text('vía'));
    await t.pump();
    await t.tapAt(const Offset(850, 400));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('1 vía'), findsOneWidget);

    await t.tapAt(const Offset(850, 400));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(const Offset(850, 400));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('1 vía'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('agarrar la línea entre salida y llegada añade una vía ahí', (
    t,
  ) async {
    final p = _FlatProvider();
    await pump(t, p, const Size(1280, 800));
    // Llegada, como en el test de arriba.
    await t.tap(find.text('Llegada'));
    await t.pump();
    await t.tapAt(const Offset(900, 450));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('vía'), findsOneWidget); // el botón "+ vía"

    // "S"/"L" aparecen dos veces: en el chip de arriba y en el marcador
    // del mapa (fontSize 13). Se necesita el del mapa para calcular el
    // punto medio de la línea en pantalla.
    Finder markerLetter(String letter) => find.byWidgetPredicate(
      (w) => w is Text && w.data == letter && w.style?.fontSize == 13,
    );
    final sCenter = t.getCenter(markerLetter('S'));
    final lCenter = t.getCenter(markerLetter('L'));
    final mid = Offset(
      (sCenter.dx + lCenter.dx) / 2,
      (sCenter.dy + lCenter.dy) / 2,
    );
    final gesture = await t.startGesture(mid);
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(6, 0));
    await t.pump();
    await gesture.up();
    await t.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('1 vía'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  for (final (name, size) in [
    ('XCover apaisado', const Size(915, 412)),
    ('teléfono vertical', const Size(400, 860)),
    ('tablet', const Size(1280, 800)),
  ]) {
    testWidgets('el diálogo de ajustes cabe sin desbordar · $name', (t) async {
      final p = _FlatProvider();
      await pump(t, p, size);
      await t.tap(find.byIcon(Icons.tune));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Ajustes de la ruta'), findsOneWidget);
      expect(find.text('Aplicar'), findsOneWidget);
      expect(find.text('Personalizado'), findsOneWidget);
    });
  }

  group('con polar', () {
    final polar = PolarTable(
      id: 'dehler47',
      name: 'Dehler 47',
      tws: const [6, 8, 10, 12, 14, 16, 20],
      twa: const [52, 60, 75, 90, 110, 120, 135, 150],
      speeds: const [
        [5.49, 6.54, 7.4, 7.91, 8.17, 8.28, 8.32],
        [5.82, 6.88, 7.69, 8.12, 8.36, 8.5, 8.61],
        [6.08, 7.16, 7.9, 8.28, 8.53, 8.73, 9.01],
        [6.0, 7.25, 8.07, 8.45, 8.61, 8.81, 9.29],
        [6.06, 7.38, 8.19, 8.61, 8.96, 9.29, 9.7],
        [5.89, 7.19, 8.08, 8.54, 8.91, 9.3, 10.05],
        [5.31, 6.55, 7.58, 8.21, 8.6, 8.98, 9.84],
        [4.44, 5.62, 6.64, 7.57, 8.18, 8.57, 9.3],
      ],
      beatAngle: const [43.6, 41.4, 41.2, 40.5, 39.4, 38.7, 37.6],
      beatVmg: const [3.56, 4.35, 4.97, 5.46, 5.74, 5.87, 6.0],
      runAngle: const [140.6, 148.4, 151.1, 153.8, 160.4, 173.6, 179],
      runVmg: const [3.85, 4.87, 5.76, 6.58, 7.28, 7.88, 8.68],
    );

    Future<void> placeDestination(WidgetTester t, [Size? size]) async {
      await t.tap(find.text('Llegada'));
      await t.pump();
      final s = size ?? const Size(1280, 800);
      await t.tapAt(Offset(s.width * 0.7, s.height * 0.56));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
    }

    /// El cálculo corre en un isolate de verdad: hay que dejar pasar
    /// tiempo real, no solo el reloj falso de los tests.
    Future<void> waitRoute(WidgetTester t) async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.pump();
        if (find.textContaining('RESUMEN').evaluate().isNotEmpty) return;
      }
    }

    for (final (name, size) in [
      ('tablet', const Size(1280, 800)),
      ('XCover apaisado', const Size(915, 412)),
      ('iPhone vertical', const Size(390, 844)),
    ]) {
      testWidgets('recalcular enseña el resumen con rachas · $name', (t) async {
        final p = _FlatProvider();
        await pump(t, p, size, polar: polar);
        await placeDestination(t, size);
        expect(find.byTooltip('Recalcular'), findsOneWidget);
        await t.tap(find.byTooltip('Recalcular'));
        await t.pump();
        await waitRoute(t);
        expect(find.textContaining('RESUMEN'), findsOneWidget);
        expect(find.textContaining('racha 17 kn'), findsOneWidget);
        expect(t.takeException(), isNull);

        // Se cierra y se vuelve a abrir desde la barra.
        await t.tap(find.byTooltip('Cerrar resumen'));
        await t.pump();
        expect(find.textContaining('RESUMEN'), findsNothing);
        await t.tap(find.byTooltip('Resumen'));
        await t.pump();
        expect(find.textContaining('RESUMEN'), findsOneWidget);
      });
    }

    testWidgets('isócronas: el interruptor las pinta tras calcular', (t) async {
      final p = _FlatProvider();
      await pump(t, p, const Size(1280, 800), polar: polar);
      await placeDestination(t);
      await t.tap(find.text('Recalcular'));
      await t.pump();
      await waitRoute(t);
      int polylines() => t
          .widgetList<fm.PolylineLayer>(find.byType(fm.PolylineLayer))
          .fold(0, (a, l) => a + l.polylines.length);
      final before = polylines();
      await t.tap(find.text('Isócronas'));
      await t.pump();
      expect(polylines(), greaterThan(before));
      expect(t.takeException(), isNull);
    });

    testWidgets('planificador: compara salidas y usa la elegida', (t) async {
      final p = _FlatProvider();
      await pump(t, p, const Size(1280, 800), polar: polar);
      await placeDestination(t);
      await t.tap(find.text('Planificar salida'));
      await t.pumpAndSettle();
      await t.tap(find.text('6 h'));
      await t.tap(find.text('12 h'));
      await t.pump();
      await t.tap(find.text('Calcular'));
      for (var i = 0; i < 60; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.pump();
        if (find.textContaining('→').evaluate().length >= 3) break;
      }
      // 0, +6 y +12 h.
      expect(find.textContaining('→'), findsNWidgets(3));
      expect(find.text('MÁS RÁPIDA'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.textContaining('→').last);
      await t.pump();
      await waitRoute(t);
      expect(find.textContaining('RESUMEN'), findsOneWidget);
    });
  });
}
