import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/data_api.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Con el motor en marcha, la pantalla enseña cuánto lleva ESTE arranque, y al
/// tocarla, los últimos usos. Ambas cosas salen de aquí.
void main() {
  final t0 = DateTime.utc(2026, 9, 17, 8);
  GraphPoint p(int minute, double rpm) =>
      GraphPoint(time: t0.add(Duration(minutes: minute)), value: rpm);

  group('engineCurrentRunLabel', () {
    test('minutos mientras es corto', () {
      final inicio = DateTime.utc(2026, 9, 17, 8, 30);
      final texto = engineCurrentRunLabel(
        inicio,
        inicio.add(const Duration(minutes: 12)),
      );
      expect(texto, contains('12 min'));
      expect(texto, contains('En marcha desde'));
    });

    test('horas y minutos cuando pasa de una hora', () {
      final inicio = DateTime.utc(2026, 9, 17, 8);
      expect(
        engineCurrentRunLabel(
          inicio,
          inicio.add(const Duration(hours: 2, minutes: 5)),
        ),
        contains('2 h 05 min'),
      );
    });

    test('recién arrancado no dice 0 min', () {
      final inicio = DateTime.utc(2026, 9, 17, 8);
      expect(
        engineCurrentRunLabel(inicio, inicio.add(const Duration(seconds: 20))),
        contains('<1 min'),
      );
    });
  });

  group('engineRunsFromRpmHistory', () {
    // El "ahora" se fija: la función recorta los usos al momento actual, así
    // que un test con fechas del futuro no probaría nada.
    final ahora = t0.add(const Duration(hours: 2));

    test('separa dos usos y los da del más reciente al más antiguo', () {
      final runs = engineRunsFromRpmHistory(now: ahora, [
        p(0, 0),
        p(1, 800),
        p(2, 900),
        p(3, 850),
        p(4, 0),
        p(30, 0),
        p(31, 1200),
        p(32, 1300),
        p(33, 1250),
        p(34, 1100),
        p(35, 0),
      ]);
      expect(runs, hasLength(2));
      expect(runs.first.startedAt, t0.add(const Duration(minutes: 31)));
      expect(runs.last.startedAt, t0.add(const Duration(minutes: 1)));
      expect(runs.first.durationHours * 60, closeTo(4, 0.01));
    });

    test('un pico suelto al dar contacto no cuenta como uso', () {
      final runs = engineRunsFromRpmHistory(now: ahora, [
        p(0, 0),
        p(1, 900),
        p(2, 0),
      ]);
      expect(runs, isEmpty, reason: 'menos de un minuto girando');
    });

    test('ralentí por debajo del umbral no es marcha', () {
      final runs = engineRunsFromRpmHistory(now: ahora, [
        p(0, 120),
        p(1, 150),
        p(2, 100),
      ]);
      expect(runs, isEmpty);
    });

    test('un hueco largo en los datos cierra el uso', () {
      final runs = engineRunsFromRpmHistory(now: ahora, [
        p(0, 900),
        p(1, 900),
        p(2, 900),
        // 20 minutos sin datos: no se puede afirmar que siguiera girando.
        p(22, 900),
        p(23, 900),
        p(24, 900),
      ]);
      expect(runs, hasLength(2));
    });

    test('sin datos no inventa arranques', () {
      expect(engineRunsFromRpmHistory(const []), isEmpty);
    });
  });

  group('engineRunsFromHistory (cuentahoras)', () {
    GraphPoint h(int minute, double hours) =>
        GraphPoint(time: t0.add(Duration(minutes: minute)), value: hours);

    test('cada tramo de incrementos es un uso', () {
      final runs = engineRunsFromHistory([
        h(0, 100.0),
        h(5, 100.08),
        h(10, 100.16),
        // parón de más de 15 minutos
        h(60, 100.16),
        h(65, 100.08 + 100.16 - 100.08),
        h(70, 100.30),
        h(75, 100.38),
      ]);
      expect(runs.length, greaterThanOrEqualTo(1));
      expect(runs.first.startedAt.isAfter(runs.last.startedAt), isTrue);
    });

    test('un contador que retrocede no genera un uso', () {
      final runs = engineRunsFromHistory([h(0, 500.0), h(5, 10.0)]);
      expect(runs, isEmpty);
    });
  });
}
