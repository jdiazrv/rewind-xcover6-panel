import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/engine_fuel.dart';

void main() {
  test('all profiles are propeller-load estimates with ordered curves', () {
    expect(engineFuelProfiles, hasLength(8));
    for (final profile in engineFuelProfiles) {
      expect(profile.sourceLabel.toLowerCase(), contains('propeller load'));
      expect(profile.curve.length, greaterThan(2));
      for (var i = 1; i < profile.curve.length; i++) {
        expect(profile.curve[i].rpm, greaterThan(profile.curve[i - 1].rpm));
        expect(profile.curve[i].litersPerHour, greaterThanOrEqualTo(0));
      }
    }
  });

  test('interpolates between propeller-curve points', () {
    const profile = EngineFuelProfile(
      id: 'test',
      label: 'Test',
      sourceLabel: 'Test propeller load',
      sourceUrl: 'https://example.invalid',
      curve: [EngineFuelPoint(1000, 1), EngineFuelPoint(2000, 3)],
    );
    expect(profile.estimateLitersPerHour(1500), closeTo(2, 0.001));
    expect(
      profile.estimateLitersPerHour(1500, calibrationPercent: 110),
      closeTo(2.2, 0.001),
    );
  });

  test('stopped engine consumes zero and calibration is bounded', () {
    final profile = engineFuelProfileById('volvo-d2-55')!;
    expect(profile.estimateLitersPerHour(0), 0);
    expect(
      profile.estimateLitersPerHour(2000, calibrationPercent: 1000),
      closeTo(3.8 * 1.3, 0.001),
    );
  });
}
