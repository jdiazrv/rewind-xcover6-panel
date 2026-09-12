import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/data_api.dart';
import 'package:rewind_xcover6_panel/models.dart';

void main() {
  test('deduce el último uso de un cuentahoras publicado a saltos', () {
    final base = DateTime.utc(2026, 9, 12, 11, 30);
    final points = <GraphPoint>[
      GraphPoint(time: base, value: 1635.0),
      GraphPoint(time: base.add(const Duration(minutes: 2)), value: 1635.05),
      GraphPoint(time: base.add(const Duration(minutes: 8)), value: 1635.10),
      GraphPoint(time: base.add(const Duration(minutes: 14)), value: 1635.20),
      GraphPoint(time: base.add(const Duration(minutes: 20)), value: 1635.30),
      GraphPoint(time: base.add(const Duration(minutes: 25)), value: 1635.30),
    ];

    final run = latestEngineRunFromHistory(points);

    expect(run, isNotNull);
    expect(run!.startedAt, base);
    expect(run.endedAt, base.add(const Duration(minutes: 20)));
    expect(run.durationHours, closeTo(0.30, 0.0001));
  });

  test('separa dos usos y devuelve el más reciente', () {
    final base = DateTime.utc(2026, 9, 11, 8);
    final points = <GraphPoint>[
      GraphPoint(time: base, value: 100),
      GraphPoint(time: base.add(const Duration(minutes: 5)), value: 100.08),
      GraphPoint(time: base.add(const Duration(hours: 3)), value: 100.08),
      GraphPoint(
        time: base.add(const Duration(hours: 3, minutes: 5)),
        value: 100.16,
      ),
      GraphPoint(
        time: base.add(const Duration(hours: 3, minutes: 10)),
        value: 100.24,
      ),
    ];

    final run = latestEngineRunFromHistory(points);

    expect(run, isNotNull);
    expect(run!.startedAt, base.add(const Duration(hours: 3)));
    expect(run.durationHours, closeTo(0.16, 0.0001));
  });

  test('ignora un salto imposible producido por fuentes mezcladas', () {
    final base = DateTime.utc(2026, 9, 12, 8);
    final points = <GraphPoint>[
      GraphPoint(time: base, value: 1234),
      GraphPoint(time: base.add(const Duration(minutes: 1)), value: 1626),
      GraphPoint(time: base.add(const Duration(minutes: 2)), value: 1626.05),
    ];

    final run = latestEngineRunFromHistory(points);

    expect(run, isNotNull);
    expect(run!.durationHours, closeTo(0.05, 0.0001));
  });

  test('las RPM delimitan con precisión inicio, parada y duración', () {
    final base = DateTime.utc(2026, 9, 12, 11, 30);
    final points = <GraphPoint>[
      GraphPoint(time: base, value: 0),
      for (var minute = 1; minute <= 40; minute++)
        GraphPoint(time: base.add(Duration(minutes: minute)), value: 760),
      GraphPoint(time: base.add(const Duration(minutes: 41)), value: 0),
    ];

    final run = latestEngineRunFromRpmHistory(points);

    expect(run, isNotNull);
    expect(run!.startedAt, base.add(const Duration(minutes: 1)));
    expect(run.endedAt, base.add(const Duration(minutes: 41)));
    expect(run.durationHours * 60, closeTo(40, 0.001));
  });
}
