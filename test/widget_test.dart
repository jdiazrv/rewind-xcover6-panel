import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rewind_xcover6_panel/main.dart';

void main() {
  testWidgets('REWIND panel boots', (WidgetTester tester) async {
    await tester.pumpWidget(const RewindApp());

    expect(find.text('NAV'), findsOneWidget);
    expect(find.text('Signal K'), findsNothing);
  });

  testWidgets('PRON layout fits landscape phone size', (WidgetTester tester) async {
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

  testWidgets('TNK overview and aggregate detail fit', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('TNK'));
    await tester.pumpAndSettle();
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.text('Fresh water'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Fuel'));
    await tester.pumpAndSettle();
    expect(find.text('fuel 27'), findsOneWidget);
    expect(find.text('fuel 26'), findsOneWidget);
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

    expect(find.text('AWA'), findsOneWidget);
    expect(find.text('AWS'), findsOneWidget);
    expect(find.text('TWA'), findsOneWidget);
    expect(find.text('TWS'), findsOneWidget);
    expect(find.text('TWD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
