import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Signal K specifies environment.*.pressure in Pascals, but REWIND's own
/// signalk-node-red flow publishes hPa while still declaring "units":"Pa"
/// (verified live 2026-09-08: value 1010.7). The spec-correct /100 then
/// produced "10.1 mbar" on the card.
void main() {
  group('normalizePressureHpa', () {
    test('passes through a value already in hPa/mbar', () {
      expect(normalizePressureHpa(1010.7), closeTo(1010.7, 1e-9));
      expect(normalizePressureHpa(1013.25), closeTo(1013.25, 1e-9));
    });

    test('converts a genuine Pascal reading', () {
      expect(normalizePressureHpa(101070), closeTo(1010.7, 1e-9));
      expect(normalizePressureHpa(101325), closeTo(1013.25, 1e-9));
    });

    test('rescues a value that was divided once too often', () {
      // What the boat actually showed: 1010.7 hPa treated as Pa.
      expect(normalizePressureHpa(10.107), closeTo(1010.7, 1e-6));
    });

    test('covers the full range of real sea-level pressure', () {
      // Records: ~870 hPa (typhoon Tip) to ~1084 hPa (Siberia). The two
      // scales cannot overlap, which is what makes the range test safe.
      for (final hpa in [870.0, 950.0, 1013.25, 1050.0, 1084.0]) {
        expect(normalizePressureHpa(hpa), closeTo(hpa, 1e-9));
        expect(normalizePressureHpa(hpa * 100), closeTo(hpa, 1e-9));
        expect(normalizePressureHpa(hpa / 100), closeTo(hpa, 1e-6));
      }
    });

    test('leaves null alone', () {
      expect(normalizePressureHpa(null), isNull);
    });

    test('drops implausible samples instead of plotting them', () {
      // The reported glitch: a "caída a 510" that isn't weather at all.
      // 510 is not valid in any interpretation — as hPa it's far below
      // the record low, /100 and *100 are nowhere near either.
      expect(normalizePressureHpa(510), isNull);
      expect(normalizePressureHpa(0), isNull);
      expect(normalizePressureHpa(-3), isNull);
      expect(normalizePressureHpa(double.nan), isNull);
      expect(normalizePressureHpa(double.infinity), isNull);
      // ...and the graph path must drop them too, not fall back to raw.
      expect(mPressure.normalize!(510), isNull);
    });
  });

  test('mPressure carries the normalizer so graphs match the live card', () {
    expect(mPressure.normalize, isNotNull);
    // The history path scales raw Pa by 0.01 first; on a boat storing hPa
    // that lands at ~10 and the normalizer has to rescue it.
    expect(mPressure.normalize!(10.107), closeTo(1010.7, 1e-6));
    expect(mPressure.normalize!(1010.7), closeTo(1010.7, 1e-9));
  });
}
