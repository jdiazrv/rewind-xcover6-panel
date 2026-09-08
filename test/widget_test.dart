import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rewind_xcover6_panel/main.dart';

void main() {
  testWidgets('REWIND panel boots', (WidgetTester tester) async {
    await tester.pumpWidget(const RewindApp());

    expect(find.text('NAV'), findsOneWidget);
    expect(find.text('Signal K'), findsNothing);
  });

  testWidgets('PRON layout fits landscape phone size', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('PRON'));
    await tester.pumpAndSettle();

    // No network in the test environment, so this lands on the "still
    // downloading" placeholder rather than real forecast data — still
    // enough to confirm the page actually switched and laid out cleanly.
    expect(find.textContaining('Descargando'), findsOneWidget);
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

  testWidgets('MET overview fits the XCover landscape viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('MET'));
    await tester.pumpAndSettle();

    expect(find.text('PRESIÓN ATMOSFÉRICA'), findsOneWidget);
    expect(find.text('T. exterior'), findsOneWidget);
    expect(find.text('T. interior'), findsOneWidget);
    expect(find.text('Viento previsto'), findsOneWidget);
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
    await tester.tap(find.text('INFORMES'));
    await tester.pumpAndSettle();

    expect(find.text('Rendimiento del barco'), findsOneWidget);
    expect(find.text('Viento y vela'), findsOneWidget);
    expect(find.text('Informe completo'), findsOneWidget);
    expect(find.text('24h'), findsOneWidget);
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
