import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';
import 'package:rewind_xcover6_panel/performance_report.dart';

void main() {
  test('el tiempo por régimen suma lo mismo que el tiempo a motor', () {
    // 6 h con el motor a varios regímenes, mucho rato a ralentí/pocas
    // vueltas (puerto) y apagado entre medias; una muestra por minuto.
    final t0 = DateTime.utc(2026, 9, 19, 6);
    final rpm = <GraphPoint>[];
    double rpmAt(int m) {
      if (m < 20) return 850; // salir de puerto
      if (m < 28) return 2100; // un rato a crucero
      if (m < 200) return 0; // a vela, motor parado
      if (m < 204) return 1300; // entrar en puerto
      return 0;
    }

    for (var m = 0; m <= 360; m++) {
      rpm.add(
        GraphPoint(
          time: t0.add(Duration(minutes: m)),
          value: rpmAt(m),
        ),
      );
    }
    const step = Duration(minutes: 1);
    final total = reportEngineRunningDuration(rpm, step);
    final bands = reportEngineRpmBands(rpm, step);
    final sum = bands.values.fold(Duration.zero, (a, b) => a + b);
    expect(total.inMinutes, closeTo(32, 2));
    expect(sum, total);
    // Ralentí de este barco: 850 (donde más rato pasa por debajo de 1100).
    expect(reportEstimateIdleRpm(rpm, step), closeTo(850, 30));
    final keys = bands.keys.toList();
    expect(keys.first, startsWith('ralenti ~'));
    expect(bands[keys[0]]!.inMinutes, closeTo(20, 2)); // ralentí
    expect(bands[keys[1]]!.inMinutes, closeTo(4, 1)); // pocas vueltas
  });

  test('cada barco tiene su ralentí; sin datos, 850', () {
    final t0 = DateTime.utc(2026, 9, 19);
    final rpm = [
      for (var m = 0; m <= 30; m++)
        GraphPoint(time: t0.add(Duration(minutes: m)), value: 720),
    ];
    const step = Duration(minutes: 1);
    expect(reportEstimateIdleRpm(rpm, step), closeTo(720, 30));
    expect(reportEstimateIdleRpm(const [], step), 850);
  });
}
