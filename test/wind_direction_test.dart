import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/main.dart';

void main() {
  group('trueWindDirection', () {
    test('rebuilds TWD as the bearing the wind comes FROM', () {
      // Bow pointing north, wind 30 deg off the starboard bow -> it is
      // coming from 030.
      expect(trueWindDirection(30, 0), 30);
      // Same relative angle on a boat heading east -> from 120.
      expect(trueWindDirection(30, 90), 120);
      // Port side is negative.
      expect(trueWindDirection(-30, 90), 60);
    });

    test('wraps past north instead of going negative or over 360', () {
      expect(trueWindDirection(-30, 10), 340);
      expect(trueWindDirection(30, 350), 20);
      expect(trueWindDirection(180, 200), 20);
    });

    test('is the exact inverse of relativeWindAngle', () {
      for (final heading in [0.0, 45.0, 137.0, 275.0, 359.0]) {
        for (final twa in [-179.0, -90.0, -1.0, 0.0, 1.0, 90.0, 179.0]) {
          final twd = trueWindDirection(twa, heading)!;
          expect(
            relativeWindAngle(twd, heading),
            closeTo(twa, 1e-9),
            reason: 'heading=$heading twa=$twa twd=$twd',
          );
        }
      }
    });

    test('returns null when either input is missing', () {
      expect(trueWindDirection(null, 90), isNull);
      expect(trueWindDirection(30, null), isNull);
    });
  });
}
