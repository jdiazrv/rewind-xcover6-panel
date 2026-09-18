import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rewind_xcover6_panel/main.dart';
import 'package:rewind_xcover6_panel/models.dart';
import 'package:rewind_xcover6_panel/performance_report.dart';
import 'package:rewind_xcover6_panel/engine_fuel.dart';
import 'package:rewind_xcover6_panel/theme.dart';
import 'package:rewind_xcover6_panel/widgets/motor_premium_panel.dart';

void main() {
  // Sin red en los tests: el selector de informes no debe lanzar la descarga
  // real del histórico, que dejaría vivo el temporizador de su timeout.
  setUp(() => reportHorizonSogLoader = (_, _) async => const <GraphPoint>[]);
  tearDown(() => reportHorizonSogLoader = loadReportHorizonSog);

  testWidgets('REWIND panel boots', (WidgetTester tester) async {
    await tester.pumpWidget(const RewindApp());

    expect(find.text('NAV'), findsOneWidget);
    expect(find.text('Signal K'), findsNothing);
  });

  testWidgets('motor hour meter fits the landscape tachometer', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PremiumMotorEnginePanel(
            engineHours: NavCardData(
              id: 'engineHours',
              title: 'Horas motor',
              value: '1626.2',
              color: cText,
            ),
            engineRunning: true,
            engineContactOn: true,
            engineRpm: 761.4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.text('HORAS MOTOR'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('estimated fuel opens the propeller-load curve', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiumMotorEnginePanel(
            engineHours: const NavCardData(
              id: 'engineHours',
              title: 'Horas motor',
              value: '1626.2',
              color: cText,
            ),
            engineRunning: true,
            engineContactOn: true,
            engineRpm: 2000,
            fuelProfile: engineFuelProfileById('volvo-d2-55'),
            fuelDriveType: 'shaft',
            fuelPropellerType: 'folding',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2.7 L/h'), findsOneWidget);
    await tester.tap(find.text('2.7 L/h'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Estimación práctica 70 %'), findsOneWidget);
    expect(find.textContaining('no plena carga de banco'), findsOneWidget);
    expect(find.text('Fabricante (referencia)'), findsOneWidget);
    expect(find.byKey(const ValueKey('engine-fuel-curve')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TIEMPO abre en PREVISIÓN y cabe en el móvil apaisado', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('TIEMPO'));
    await tester.pumpAndSettle();

    // No network in the test environment, so this lands on the "still
    // downloading" placeholder rather than real forecast data — still
    // enough to confirm the page actually switched and laid out cleanly.
    expect(find.textContaining('Descargando'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Las siete pestañas visibles de CFG se reordenaron y se partieron en
  // métodos propios (antes eran una sola función de 4.000 líneas). Esto
  // comprueba que todas siguen dibujándose sin excepciones y que cada ajuste
  // movido está en su pestaña nueva, no en la vieja.
  testWidgets('CFG dibuja las siete pestañas y cada ajuste está en su sitio', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.drag(find.text('VNT'), const Offset(-900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CFG'));
    await tester.pumpAndSettle();

    for (final tab in const [
      'CONEXIÓN',
      'SENSORES',
      'HISTÓRICO',
      'PANTALLA',
      'ALARMAS',
      'FONDEO',
      'DIAGNÓSTICO',
    ]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }

    // La ficha del barco dejó Pantalla y Fondeo y vive en Sensores.
    await tester.tap(find.text('SENSORES'));
    await tester.pumpAndSettle();
    expect(find.text('MOTOR Y TRANSMISIÓN'), findsOneWidget);
    expect(find.text('EL BARCO'), findsOneWidget);

    // Mostrar y avisar del AIS, en un solo sitio y ya no en Pantalla.
    await tester.tap(find.text('ALARMAS'));
    await tester.pumpAndSettle();
    expect(find.text('AIS: AVISO Y VISTA EN NAV'), findsOneWidget);

    // Diagnóstico son dos vistas, no un scroll de 800 líneas.
    // La barra de pestañas hace scroll: a 915 px DIAGNÓSTICO queda fuera.
    await tester.ensureVisible(find.text('DIAGNÓSTICO'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DIAGNÓSTICO'));
    await tester.pumpAndSettle();
    expect(find.text('ESTADO DEL SISTEMA'), findsOneWidget);
    expect(find.text('Datos en vivo'), findsOneWidget);
    await tester.tap(find.text('Datos en vivo'));
    await tester.pumpAndSettle();
    expect(find.text('ESTADO DEL SISTEMA'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Cada grupo dice si lo que toca viaja al barco o se queda en el aparato.
  testWidgets('CFG marca qué se comparte con el barco', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.drag(find.text('VNT'), const Offset(-900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CFG'));
    await tester.pumpAndSettle();

    // La leyenda de la cabecera, siempre visible.
    expect(find.text('SE GUARDA EN'), findsOneWidget);
    expect(find.text('TODO EL BARCO'), findsWidgets);
    expect(find.text('SOLO AQUÍ'), findsWidgets);

    await tester.tap(find.text('FONDEO'));
    await tester.pumpAndSettle();
    // Grupos del barco y filas del aparato conviviendo, cada una marcada.
    expect(find.text('TODO EL BARCO'), findsWidgets);
    expect(find.text('SOLO AQUÍ'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CFG search finds concrete DEMO and motor settings', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.drag(find.text('VNT'), const Offset(-900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CFG'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Buscar ajuste'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'DEMO');
    await tester.pump();
    expect(find.text('Modo DEMO y escenarios simulados'), findsOneWidget);
    await tester.tap(find.text('Modo DEMO y escenarios simulados'));
    await tester.pumpAndSettle();
    expect(find.text('Modo DEMO'), findsOneWidget);

    // Con DEMO encendido aparece la lista de escenarios: antes eran
    // RadioListTile dentro de una tarjeta con fondo propio, que Flutter avisa
    // que pierden color y efecto al pulsar.
    final demoSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('Modo DEMO'),
        matching: find.byType(SettingsSwitchRow),
      ),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(demoSwitch);
    await tester.pumpAndSettle();
    await tester.tap(demoSwitch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.radio_button_checked), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Buscar ajuste'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'motor completo');
    await tester.pump();
    expect(find.text('Pantalla del motor'), findsOneWidget);
    await tester.tap(find.text('Pantalla del motor'));
    await tester.pumpAndSettle();
    expect(find.text('ESTILO MOTOR'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // RESUMEN es la pantalla de los barcos con pocos sensores, y ahora lleva
  // también el estado del motor. Cuatro paneles en 915x412 se desbordan a la
  // mínima, así que esto comprueba que caben y que la fecha está en la
  // cabecera de POSICIÓN Y HORA, no gastando un chip abajo.
  testWidgets('RESUMEN cabe con el panel de motor', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.drag(find.text('VNT'), const Offset(-900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CFG'));
    await tester.pumpAndSettle();

    // DEMO da datos de motor; sin ellos el panel se oculta a propósito. Se
    // llega por el buscador: a 915 px la barra de pestañas no enseña
    // DIAGNÓSTICO sin hacer scroll.
    await tester.tap(find.byTooltip('Buscar ajuste'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'DEMO');
    await tester.pump();
    await tester.tap(find.text('Modo DEMO y escenarios simulados'));
    await tester.pumpAndSettle();
    final demoSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('Modo DEMO'),
        matching: find.byType(SettingsSwitchRow),
      ),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(demoSwitch);
    await tester.pumpAndSettle();
    await tester.tap(demoSwitch);
    await tester.pump();

    await tester.tap(find.byTooltip('Buscar ajuste'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'RESUMEN');
    await tester.pump();
    await tester.tap(find.text('Pantalla RESUMEN').last);
    await tester.pumpAndSettle();
    final resSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('Pantalla RESUMEN'),
        matching: find.byType(SettingsSwitchRow),
      ),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(resSwitch);
    await tester.pumpAndSettle();
    await tester.tap(resSwitch);
    await tester.pumpAndSettle();

    await tester.drag(find.text('CFG'), const Offset(900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RES'));
    await tester.pumpAndSettle();

    expect(find.text('ENERGÍA'), findsOneWidget);
    expect(find.text('TANQUES'), findsOneWidget);
    expect(find.text('POSICIÓN Y HORA'), findsOneWidget);
    expect(find.text('MOTOR'), findsOneWidget);
    // 'AIS' también es una pestaña de la barra de navegación.
    expect(find.text('AIS'), findsWidgets);

    // Fecha y hora en la cabecera, y ya no como chip.
    expect(
      find.textContaining(RegExp(r'\d{2}/\d{2}/\d{4}  \d{2}:\d{2}')),
      findsOneWidget,
    );
    expect(find.text('FECHA'), findsNothing);

    // El motor dice en qué estado está y con qué cifras.
    expect(find.text('TEMP'), findsOneWidget);
    expect(find.text('ALTERN.'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  // El cuadro de testigos: no enseña lo que está sonando (eso es la campana)
  // sino TODAS las alarmas configuradas y en qué estado está cada una. Lo que
  // no puede fallar es que un piloto verde no mienta: una alarma que ahora
  // mismo no se puede evaluar —ancla sin armar, motor parado— va en naranja.
  testWidgets('ALM enseña las alarmas configuradas con su testigo', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('ALM'));
    await tester.pumpAndSettle();

    // Las placas y sus leyendas grabadas.
    expect(find.text('FONDEO'), findsOneWidget);
    expect(find.text('NAVEGACIÓN'), findsOneWidget);
    expect(find.text('Garreo'), findsOneWidget);
    expect(find.text('Colisión AIS'), findsOneWidget);
    expect(find.byType(ChromeLed), findsWidgets);

    // Sin ancla armada el garreo no se está vigilando: naranja, no verde.
    final garreo = tester.widget<AlarmLampRow>(
      find
          .ancestor(
            of: find.text('Garreo'),
            matching: find.byType(AlarmLampRow),
          )
          .first,
    );
    expect(garreo.lamp.state, LampState.warn);
    expect(find.text('ancla sin armar'), findsWidgets);

    // Una alarma sin configurar sale apagada, no en verde.
    final ais = tester.widget<AlarmLampRow>(
      find
          .ancestor(
            of: find.text('Colisión AIS'),
            matching: find.byType(AlarmLampRow),
          )
          .first,
    );
    expect(ais.lamp.state, LampState.off);

    // Scroll vertical, y sin desbordes en el alto del XCover.
    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('metric cards open zoom', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('SOG'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('TNK overview and aggregate detail fit', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('TNK'));
    await tester.pumpAndSettle();
    expect(find.text('Diésel'), findsOneWidget);
    expect(find.text('Agua'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final overviewCards = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('tank-card-'),
    );
    expect(overviewCards, findsWidgets);
    for (final element in overviewCards.evaluate()) {
      final rect = tester.getRect(find.byElementPredicate((e) => e == element));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(tester.view.physicalSize.width));
    }

    await tester.tap(find.text('Diésel'));
    await tester.pumpAndSettle();
    // The summary card remains mounted behind the fullscreen dialog, so the
    // individual names can legitimately exist in both layers.
    expect(find.text('Diésel 1'), findsWidgets);
    expect(find.text('Diésel 2'), findsWidgets);
    expect(find.text('HISTÓRICO'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PWR puts bow left and service current right', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('PWR'));
    await tester.pumpAndSettle();

    final bowX = tester.getCenter(find.text('Bow thruster')).dx;
    final startX = tester.getCenter(find.text('Arranque')).dx;
    final serviceX = tester.getCenter(find.text('Corriente servicio')).dx;
    expect(bowX, lessThan(startX));
    expect(startX, lessThan(serviceX));
    expect(tester.takeException(), isNull);
  });

  // MET, PRON y MAR son ahora una sola pestaña TIEMPO con carrusel
  // vertical. A BORDO enseña solo lo que mide el barco: la previsión que
  // tenía MET mezclada ("Viento previsto") se fue a PREVISIÓN.
  testWidgets('TIEMPO pasa de PREVISIÓN a MAR y a A BORDO deslizando', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    // Ni MET, ni PRON, ni MAR en el menú: una sola entrada.
    expect(find.text('MET'), findsNothing);
    expect(find.text('PRON'), findsNothing);
    await tester.tap(find.text('TIEMPO'));
    await tester.pumpAndSettle();

    Future<void> siguiente() async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -300));
      await tester.pumpAndSettle();
    }

    // Arranca en PREVISIÓN; deslizando se llega a A BORDO (el arranque sin
    // conexión es modo DEMO, que tiene barómetro y temperaturas).
    for (
      var i = 0;
      i < 3 && find.text('PRESIÓN ATMOSFÉRICA').evaluate().isEmpty;
      i++
    ) {
      await siguiente();
    }
    expect(find.text('PRESIÓN ATMOSFÉRICA'), findsOneWidget);
    expect(find.text('T. exterior'), findsOneWidget);
    expect(find.text('T. interior'), findsOneWidget);
    // Nada de previsión en A BORDO.
    expect(find.text('Viento previsto'), findsNothing);
    expect(
      find.text('Medido a bordo por los sensores del barco'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('VNT page shows all wind cards', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('VNT'));
    await tester.pumpAndSettle();

    expect(find.text('AWA'), findsWidgets);
    expect(find.text('AWS'), findsWidgets);
    expect(find.text('TWA'), findsWidgets);
    expect(find.text('TWS'), findsWidgets);
    expect(find.text('TWD'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la línea de tiempo marca en verde cuándo navegó el barco', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    reportHorizonSogLoader = (_, referenceNow) async => [
      for (var m = 0; m <= 120; m += 10)
        GraphPoint(
          time: referenceNow.subtract(Duration(hours: 30, minutes: -m)),
          value: m < 40 || m > 90 ? 0 : 6,
        ),
    ];

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('VNT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INFORME VIENTO'));
    await tester.pumpAndSettle();

    expect(
      find.text('en verde, barco navegando (SOG > 0.5 kt)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('VNT exposes the three report types directly', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('VNT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INFORME VIENTO'));
    await tester.pumpAndSettle();

    expect(find.text('Barco: navegación y motor'), findsOneWidget);
    expect(find.text('Viento y navegación a vela'), findsOneWidget);
    expect(find.text('Completo: barco y viento'), findsOneWidget);
    expect(find.text('−72 h'), findsOneWidget);
    expect(find.text('ahora'), findsOneWidget);
    expect(find.text('24 h'), findsOneWidget);
    // Sin datos no se afirma que el barco estuviera parado.
    expect(find.text('sin datos de velocidad para estas 72 h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [
    Size(640, 360),
    Size(800, 360),
    Size(915, 412),
    Size(1280, 720),
  ]) {
    testWidgets('main navigation fits ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const RewindApp());
      await tester.tap(find.text('VNT'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.drag(find.text('VNT'), const Offset(-900, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CFG'));
      await tester.pumpAndSettle();
      expect(find.text('CONEXIÓN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('main tabs expose labels and tap semantics', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const RewindApp());
    final nav = tester.getSemantics(find.text('NAV'));
    expect(nav.label, contains('NAV'));
    expect(nav.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
  });
}
