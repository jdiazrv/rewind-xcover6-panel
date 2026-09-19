import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

void main() {
  group('profundidad plausible', () {
    test('valores reales sí', () {
      for (final d in [0.0, 2.4, 35.0, 250.0, -0.5]) {
        expect(plausibleDepthM(d), isTrue, reason: '$d');
      }
    });
    test('centinelas de sonda sin fondo, no', () {
      for (final d in [999.9, 1000.0, 6553.5, 42949672.0, double.nan, -50.0]) {
        expect(plausibleDepthM(d), isFalse, reason: '$d');
      }
    });
  });

  group('demora respecto a la proa', () {
    test('estribor y babor', () {
      expect(relativeBearingText(125, 90), '35° Er');
      expect(relativeBearingText(10, 90), '80° Br');
      expect(relativeBearingText(350, 20), '30° Br');
      expect(relativeBearingText(200, 350), '150° Br');
    });
    test('siempre 0–180 por banda, sin "por la proa/popa"', () {
      expect(relativeBearingText(91, 90), '1° Er');
      expect(relativeBearingText(89, 90), '1° Br');
      expect(relativeBearingText(265, 90), '175° Er');
      expect(relativeBearingText(220, 90), '130° Er');
      expect(relativeBearingText(90, 90), '0°');
      expect(relativeBearingText(270, 90), '180°');
    });
    test('sin rumbo propio, demora verdadera', () {
      expect(relativeBearingText(212.4, null), '212°V');
    });
  });
}
