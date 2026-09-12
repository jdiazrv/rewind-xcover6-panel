import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/polars.dart';
import 'package:rewind_xcover6_panel/widgets/polar_panel.dart';

/// La página POLAR cabe en pantallas apaisadas estrechas y, sobre todo,
/// no da órdenes: enseña el intercambio y deja decidir.
void main() {
  late PolarTable dehler47;

  setUpAll(() {
    final raw = File('assets/polars/orc_polars.json').readAsStringSync();
    dehler47 = PolarTable.listFromAsset(raw).firstWhere((b) => b.id == 'dehler47');
  });

  Future<void> pump(
    WidgetTester t,
    Widget panel, {
    Size size = const Size(915, 412),
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(home: Scaffold(body: panel)),
    );
    await t.pumpAndSettle();
  }

  PolarPanel panel({
    double? tws = 12,
    double? twa = 90,
    double? speed = 7.5,
    bool engine = false,
    bool usingSog = false,
    double? destNm,
    double? destBrg,
    double twd = 0,
    double factor = 100,
  }) => PolarPanel(
    polar: dehler47,
    factorPercent: factor,
    twsKn: tws,
    twaDeg: twa,
    boatSpeedKn: speed,
    usingSog: usingSog,
    engineRunning: engine,
    twdDeg: twd,
    destinationDistanceNm: destNm,
    destinationBearingDeg: destBrg,
    now: DateTime.utc(2026, 9, 12, 10, 0),
  );

  testWidgets('a motor no calcula ni finge un porcentaje', (t) async {
    await pump(t, panel(engine: true));
    expect(find.text('A motor'), findsOneWidget);
    expect(find.text('RENDIMIENTO'), findsNothing);
  });

  testWidgets('sin datos de viento lo dice en vez de poner cero', (t) async {
    await pump(t, panel(tws: null));
    expect(find.text('Faltan datos'), findsOneWidget);
  });

  testWidgets('sin destino enseña objetivo, real y rendimiento', (t) async {
    await pump(t, panel());
    expect(find.text('OBJETIVO'), findsOneWidget);
    expect(find.text('REAL'), findsOneWidget);
    expect(find.text('RENDIMIENTO'), findsOneWidget);
    // 7,5 reales sobre los 8,45 de la polar = 89 %.
    expect(find.text('89'), findsOneWidget);
    expect(find.text('SIN DESTINO ACTIVO'), findsOneWidget);
  });

  testWidgets('avisa cuando mide con GPS y no con corredera', (t) async {
    await pump(t, panel(usingSog: true));
    expect(find.text('REAL (GPS)'), findsOneWidget);
    expect(
      find.textContaining('la corriente entra en el dato'),
      findsOneWidget,
    );
  });

  testWidgets('el porcentaje mueve el objetivo, no el dato real', (t) async {
    await pump(t, panel(factor: 85));
    expect(find.text('al 85 %'), findsOneWidget);
    // 8,45 x 0,85 = 7,2 de objetivo, y 7,5 reales pasan a superarlo.
    expect(find.text('7.2'), findsOneWidget);
    expect(find.text('104'), findsOneWidget);
  });

  group('con destino', () {
    testWidgets('a barlovento da millas y tiempo reales', (t) async {
      await pump(t, panel(destNm: 12, destBrg: 0, twa: 45));
      expect(find.textContaining('no se puede apuntar'), findsOneWidget);
      expect(find.textContaining('15.8 M reales'), findsOneWidget);
      expect(find.textContaining('en línea recta son 12.0 M'), findsOneWidget);
      expect(find.textContaining('2 h 12 min'), findsOneWidget);
    });

    testWidgets('alcanzable: no alarga el camino', (t) async {
      await pump(t, panel(destNm: 12, destBrg: 90, twa: 90));
      expect(find.textContaining('Se puede apuntar'), findsOneWidget);
      expect(find.textContaining('12.0 M'), findsOneWidget);
    });

    testWidgets('nunca dice "vira" ni "orza"', (t) async {
      // Es la regla de estilo de toda la página: hechos y alternativas, no
      // instrucciones. Virar depende de la costa, del tráfico y de la
      // tripulación, que la app no conoce.
      for (final args in [
        (dest: 12.0, brg: 0.0, twa: 55.0),
        (dest: 12.0, brg: 180.0, twa: 150.0),
        (dest: 12.0, brg: 90.0, twa: 90.0),
      ]) {
        await pump(
          t,
          panel(destNm: args.dest, destBrg: args.brg, twa: args.twa),
        );
        // Como PALABRA suelta: "cada virada" es una advertencia legítima,
        // "vira" a secas sería la orden que no queremos.
        final textos = t
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data ?? '')
            .join(' | ');
        final orden = RegExp(
          r'\b(vira|virad|orza|orzad|arriba|cae)\b',
          caseSensitive: false,
        );
        expect(
          orden.hasMatch(textos),
          isFalse,
          reason: 'sale una orden con demora ${args.brg}: $textos',
        );
      }
    });

    testWidgets('se calla cuando la diferencia es ruido', (t) async {
      // Navegando casi al ángulo óptimo, la mejora cabe en el margen del
      // propio cálculo: decirla sería fingir precisión.
      await pump(t, panel(destNm: 12, destBrg: 0, twa: 41));
      expect(find.textContaining('prácticamente igual'), findsOneWidget);
    });

    testWidgets('cuando sí hay diferencia, la da en minutos', (t) async {
      await pump(t, panel(destNm: 12, destBrg: 0, twa: 70));
      expect(find.textContaining('min más que a'), findsOneWidget);
    });

    testWidgets('dice en qué no se puede confiar', (t) async {
      await pump(t, panel(destNm: 12, destBrg: 0, twa: 45));
      expect(find.textContaining('viento constante'), findsOneWidget);
      expect(find.textContaining('si hay costa por medio'), findsOneWidget);
    });
  });

  // Un desbordamiento de layout lanza un FlutterError que el propio banco
  // de pruebas convierte en fallo, así que basta con pintarla en las dos
  // pantallas apaisadas más estrechas que soporta la app.
  for (final size in [const Size(800, 360), const Size(640, 360)]) {
    testWidgets('cabe en ${size.width.round()}x${size.height.round()}', (
      t,
    ) async {
      await pump(t, panel(destNm: 12, destBrg: 0, twa: 45), size: size);
      expect(find.byType(PolarPanel), findsOneWidget);
    });
  }
}
