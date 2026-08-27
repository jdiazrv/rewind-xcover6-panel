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
    await tester.pump();

    expect(find.text('PRON'), findsOneWidget);
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
    await tester.pump();
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.text('Fresh water'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Fuel'));
    await tester.pumpAndSettle();
    expect(find.text('Fuel Tank 1'), findsOneWidget);
    expect(find.text('Fuel Tank 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wind cards open wind detail panel', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RewindApp());
    await tester.tap(find.text('Viento real'));
    await tester.pumpAndSettle();

    expect(find.text('AWA'), findsOneWidget);
    expect(find.text('AWS'), findsOneWidget);
    expect(find.text('TWA'), findsOneWidget);
    expect(find.text('TWS'), findsOneWidget);
    expect(find.text('TWD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
