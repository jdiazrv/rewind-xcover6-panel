import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    final times = [for (var h = 0; h <= 6; h++) start.add(Duration(hours: h))];
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

  Future<void> pump(WidgetTester t, _FlatProvider p, Size size) async {
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
          polar: null,
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
    await t.tap(find.text('Aplicar y recalcular'));
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
}
