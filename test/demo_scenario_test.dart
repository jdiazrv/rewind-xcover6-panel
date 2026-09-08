import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// El DEMO fabrica datos, así que nada avisa cuando son imposibles: un
/// aparente menor que el real en ceñida, o un mercante pintado tierra
/// adentro, pasan desapercibidos hasta que alguien los mira en pantalla.
void main() {
  group('apparentFromTrue', () {
    test('parado, el aparente es el real', () {
      final (aws, awa) = apparentFromTrue(15, 45, 0);
      expect(aws, closeTo(15, 1e-9));
      expect(awa, closeTo(45, 1e-9));
    });

    test('de ceñida el aparente arrecia y se cierra sobre la proa', () {
      const tws = 15.0, twa = 45.0, boat = 7.0;
      final (aws, awa) = apparentFromTrue(tws, twa, boat);
      expect(aws, greaterThan(tws), reason: 'la marcha suma');
      expect(awa.abs(), lessThan(twa), reason: 'se cierra hacia proa');
    });

    test('en popa el aparente afloja', () {
      final (aws, awa) = apparentFromTrue(15, 180, 7);
      expect(aws, closeTo(8, 1e-9));
      // Popa cerrada: 180 y -180 son el mismo ángulo.
      expect(awa.abs(), closeTo(180, 1e-9));
    });

    test('el viento aparente conserva el costado del real', () {
      final (_, port) = apparentFromTrue(15, -60, 6);
      final (_, stbd) = apparentFromTrue(15, 60, 6);
      expect(port, lessThan(0), reason: 'babor sigue siendo babor');
      expect(stbd, greaterThan(0));
      expect(port, closeTo(-stbd, 1e-9), reason: 'simétrico');
    });

    test('viento en calma: el aparente es solo la marcha, por la proa', () {
      final (aws, awa) = apparentFromTrue(0, 90, 6);
      expect(aws, closeTo(6, 1e-9));
      expect(awa, closeTo(0, 1e-9));
    });
  });

  group('DemoScenario', () {
    test('los dos escenarios existen y son distintos', () {
      final ids = kDemoScenarios.map((s) => s.id).toList();
      expect(ids, containsAll(['anchored', 'sailing']));
      expect(ids.toSet(), hasLength(kDemoScenarios.length));
    });

    test('un id desconocido no revienta', () {
      expect(demoScenarioById('vete-a-saber'), isNotNull);
      expect(demoScenarioById('anchored').id, 'anchored');
      expect(demoScenarioById('sailing').id, 'sailing');
    });

    test('el sector de mar cruza el norte sin romperse', () {
      // La cala mira al oeste: 200° → 340° pasando por el 270.
      final cala = demoScenarioById('anchored');
      expect(cala.seaSpanDeg, closeTo(140, 1e-9));
      expect(cala.isSeaward(270), isTrue, reason: 'de frente a la bocana');
      expect(cala.isSeaward(90), isFalse, reason: 'ahí está la cala');
      expect(cala.isSeaward(0), isFalse, reason: 'tierra al norte');
    });

    test('en Málaga el mar es el sur y la costa el norte', () {
      final mar = demoScenarioById('sailing');
      expect(mar.isSeaward(180), isTrue);
      expect(mar.isSeaward(90), isTrue);
      expect(mar.isSeaward(0), isFalse, reason: 'la costa queda al norte');
      expect(mar.isSeaward(340), isFalse);
    });

    test('seaBearing recorre el sector de punta a punta', () {
      for (final sc in kDemoScenarios) {
        expect(sc.seaBearing(0), closeTo(sc.seaFromDeg, 1e-9));
        expect(normalize360(sc.seaBearing(1)), closeTo(sc.seaToDeg, 1e-9));
        // Y todo lo de en medio sigue siendo mar.
        for (var f = 0.0; f <= 1.0; f += 0.05) {
          expect(
            sc.isSeaward(sc.seaBearing(f)),
            isTrue,
            reason: '${sc.id} en la fracción $f',
          );
        }
      }
    });

    test('las marcaciones que usa el AIS del DEMO caen todas en el mar', () {
      // Mismo reparto que _tickDemoAis: fracción base más el vaivén.
      const fractions = [0.20, 0.50, 0.80];
      for (final sc in kDemoScenarios) {
        for (final base in fractions) {
          for (var step = 0; step < 60; step++) {
            final phase = 2 * math.pi * (step / 60) + base * math.pi * 2;
            final swing = 0.5 + 0.42 * math.sin(phase);
            final b = sc.seaBearing(
              (base + (swing - 0.5) * 0.5).clamp(0.03, 0.97),
            );
            expect(
              sc.isSeaward(b),
              isTrue,
              reason: '${sc.id}: marcación $b se sale del sector de mar',
            );
          }
        }
      }
    });
  });
}
