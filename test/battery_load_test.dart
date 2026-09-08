import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Arranque y propulsor de proa viven en flotación, así que su voltaje lo
/// impone el cargador y no dice nada del estado de carga. Lo que sí mide
/// su salud es la caída bajo carga fuerte.
void main() {
  group('batteryOnFloat', () {
    test('distingue flotación de reposo sin ambigüedad', () {
      // Flotación de plomo: 13,2-13,8 V.
      expect(batteryOnFloat(13.5), isTrue);
      expect(batteryOnFloat(13.2), isTrue);
      // Reposo: una batería llena da ~12,7 V. Los rangos no se solapan.
      expect(batteryOnFloat(12.7), isFalse);
      expect(batteryOnFloat(12.1), isFalse);
      expect(batteryOnFloat(null), isFalse);
    });
  });

  group('BatteryLoadWatcher', () {
    DateTime t(int s) => DateTime.utc(2026, 9, 8, 12, 0, s);

    test('detecta un arranque y mide caída y recuperación', () {
      final w = BatteryLoadWatcher();
      // Reposo en flotación.
      for (var i = 0; i < 5; i++) {
        expect(w.add(13.5, t(i)), isNull);
      }
      // El motor gira: el voltaje se hunde.
      expect(w.add(10.2, t(5)), isNull);
      expect(w.add(9.8, t(6)), isNull); // valle
      expect(w.add(11.5, t(7)), isNull);
      // Recuperado.
      final e = w.add(13.4, t(8));
      expect(e, isNotNull);
      expect(e!.minV, closeTo(9.8, 1e-9), reason: 'guarda el valle real');
      expect(e.restingV, closeTo(13.5, 1e-9));
      expect(e.dropV, closeTo(3.7, 1e-9));
      expect(e.recoverySeconds, 3);
      expect(w.events, hasLength(1));
    });

    test('el ruido normal no cuenta como esfuerzo', () {
      final w = BatteryLoadWatcher();
      for (var i = 0; i < 20; i++) {
        // +-0,1 V de ruido típico de un sensor BLE.
        final v = 13.5 + (i.isEven ? 0.1 : -0.1);
        expect(w.add(v, t(i)), isNull);
      }
      expect(w.events, isEmpty);
    });

    test('una descarga lenta tampoco dispara un evento', () {
      final w = BatteryLoadWatcher();
      var v = 12.8;
      for (var i = 0; i < 40; i++) {
        v -= 0.02; // consumo normal, muy por debajo del umbral por muestra
        w.add(v, t(i));
      }
      expect(w.events, isEmpty);
    });

    test('un uso del propulsor más largo mide su recuperación', () {
      final w = BatteryLoadWatcher();
      w.add(13.4, t(0));
      w.add(11.0, t(1)); // empuja
      for (var i = 2; i < 8; i++) {
        w.add(10.8, t(i)); // sigue empujando
      }
      final e = w.add(13.3, t(12));
      expect(e, isNotNull);
      expect(e!.minV, closeTo(10.8, 1e-9));
      expect(e.recoverySeconds, 11);
    });

    test('conserva un histórico acotado y en orden', () {
      final w = BatteryLoadWatcher(maxEvents: 3);
      // Cinco arranques, cada uno con un valle algo distinto pero todos muy
      // por encima del umbral de esfuerzo.
      for (var n = 0; n < 5; n++) {
        final base = n * 20;
        w.add(13.5, t(base));
        w.add(10.0 - n * 0.1, t(base + 1));
        w.add(13.5, t(base + 2));
      }
      expect(w.events, hasLength(3), reason: 'se queda con los últimos');
      expect(w.last!.minV, closeTo(9.6, 1e-9), reason: 'el más reciente');
      expect(
        w.events.first.minV,
        closeTo(9.8, 1e-9),
        reason: 'los dos más viejos se descartan, en orden',
      );
    });

    test('el histórico sobrevive a guardar y releer', () {
      final w = BatteryLoadWatcher();
      w.add(13.5, t(0));
      w.add(9.9, t(1));
      w.add(13.5, t(2));
      final restored = BatteryLoadWatcher()..loadJson(w.toJson());
      expect(restored.events, hasLength(1));
      expect(restored.last!.minV, closeTo(9.9, 1e-9));
      expect(restored.last!.at, w.last!.at);
    });
  });
}
