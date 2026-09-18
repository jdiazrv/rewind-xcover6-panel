import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/main.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Lo que devuelve /plugins/rewind-xcover6-panel/diagnostics, con la forma de
/// server/diagnostics.js. Lo que falte no puede romper la pantalla.
void main() {
  test('lee un diagnóstico completo', () {
    final d = SkDiagnostics.fromJson({
      'server': {
        'version': '2.31.1',
        'nodeVersion': 'v22.1.0',
        'startedAt': '2026-09-18T06:00:00.000Z',
        'uptimeSec': 7200,
      },
      'host': {
        'hostname': 'lysmarine',
        'bootedAt': '2026-09-17T08:00:00.000Z',
        'cpuCount': 4,
        'loadPct': 50,
        'memUsedPct': 75,
        'cpuTempC': 61.2,
        'disk': {'usedPct': 75, 'freeGb': 8, 'totalGb': 32},
      },
      'traffic': {
        'deltaRate': 42.4,
        'paths': 812,
        'wsClients': 3,
        'providers': [
          {'id': 'N2k', 'deltaRate': 30.2},
        ],
      },
      'plugins': {
        'total': 30,
        'enabled': 25,
        'withErrors': 1,
        'list': [
          {
            'id': 'broken',
            'name': 'Roto',
            'enabled': true,
            'statusType': 'error',
            'message': 'se cayó',
          },
        ],
      },
      'connections': [
        {'id': 'N2k', 'statusType': 'status', 'message': 'Conectado'},
      ],
      'log': {
        'errors': 1,
        'lines': [
          {'ts': 'Sep 18 08:44:02', 'error': true, 'text': 'Error: token=***'},
        ],
      },
    });

    expect(d.version, '2.31.1');
    expect(d.serverStartedAt, DateTime.utc(2026, 9, 18, 6));
    expect(d.cpuTempC, 61.2);
    expect(d.diskUsedPct, 75);
    expect(d.providers.single.id, 'N2k');
    expect(d.pluginsWithErrors, 1);
    expect(d.plugins.single.statusType, 'error');
    expect(d.connections.single.message, 'Conectado');
    expect(d.logLines.single.error, isTrue);
  });

  test('una respuesta vacía o rara no rompe nada', () {
    final d = SkDiagnostics.fromJson({'host': 'no es un mapa', 'log': null});
    expect(d.version, isNull);
    expect(d.plugins, isEmpty);
    expect(d.logLines, isEmpty);
  });

  test('duración legible del último reinicio', () {
    expect(humanDuration(const Duration(minutes: 8)), '8 min');
    expect(humanDuration(const Duration(hours: 5, minutes: 12)), '5 h 12 min');
    expect(humanDuration(const Duration(days: 3, hours: 4)), '3 d 4 h');
    expect(humanDuration(const Duration(days: 2)), '2 d');
  });

  testWidgets('la vista cabe en el XCover con un servidor lleno', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final diag = SkDiagnostics.fromJson({
      'server': {
        'version': '2.31.1',
        'nodeVersion': 'v22.1.0',
        'startedAt': '2026-09-18T06:00:00.000Z',
        'rssMb': 250,
      },
      'host': {
        'hostname': 'lysmarine',
        'kernel': '6.6.51-v8+',
        'cpuCount': 4,
        'bootedAt': '2026-09-10T08:00:00.000Z',
        'loadPct': 95,
        'load1': 3.8,
        'load5': 2.1,
        'load15': 1.9,
        'memUsedPct': 81,
        'memTotalMb': 4000,
        'cpuTempC': 77.3,
        'disk': {'usedPct': 64, 'freeGb': 10.2, 'totalGb': 29.1},
      },
      'traffic': {
        'deltaRate': 42.4,
        'paths': 812,
        'wsClients': 3,
        'providers': [
          {'id': 'N2k', 'deltaRate': 30.2},
          {'id': 'GPS', 'deltaRate': 5.1},
        ],
      },
      'plugins': {
        'total': 30,
        'enabled': 3,
        'withErrors': 1,
        'list': [
          {
            'id': 'b',
            'name': 'signalk-un-plugin-con-un-nombre-muy-largo-que-no-cabe',
            'enabled': true,
            'statusType': 'error',
            'message': 'Error: connect ECONNREFUSED 127.0.0.1:8086 ' * 4,
          },
          {'id': 'g', 'name': 'Bueno', 'enabled': true, 'message': 'OK'},
          {'id': 'o', 'name': 'Apagado', 'enabled': false},
        ],
      },
      'connections': [
        {'id': 'N2k', 'statusType': 'status', 'message': 'Connected'},
      ],
      'log': {
        'errors': 1,
        'lines': [
          for (var i = 0; i < 100; i++)
            {
              'ts': 'Sep 18 08:44:0$i',
              'error': i % 10 == 0,
              'text': 'línea $i ' * 12,
            },
        ],
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SkDiagnosticsPanel(
              diag: diag,
              error: null,
              updatedAt: DateTime.now(),
              loading: false,
              onlyErrors: false,
              onRefresh: () {},
              onToggleOnlyErrors: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Versión de Signal K'), findsOneWidget);
    expect(find.text('2.31.1'), findsOneWidget);
    expect(find.text('1 con error'), findsOneWidget);
    expect(find.textContaining('Desactivados: Apagado'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
