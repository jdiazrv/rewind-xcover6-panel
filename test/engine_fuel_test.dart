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
    expect(profile.manufacturerLitersPerHour(1500), closeTo(2, 0.001));
    expect(profile.estimateLitersPerHour(1500), closeTo(1.4, 0.001));
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
      closeTo(3.8 * 1.2, 0.001),
    );
    expect(
      profile.estimateLitersPerHour(2000, calibrationPercent: 1),
      closeTo(3.8 * 0.5, 0.001),
    );
  });

  test('the same practical reduction is applied to every engine', () {
    for (final profile in engineFuelProfiles) {
      final rpm = profile.curve[profile.curve.length ~/ 2].rpm;
      expect(
        profile.estimateLitersPerHour(rpm),
        closeTo(
          profile.manufacturerLitersPerHour(rpm) *
              kDefaultPracticalFuelPercent /
              100,
          0.0001,
        ),
      );
    }
  });

  test('D2-75 uses the technical propeller-load table before reduction', () {
    final profile = engineFuelProfileById('volvo-d2-75')!;
    expect(profile.manufacturerLitersPerHour(1800), closeTo(3.737, 0.0001));
    expect(profile.manufacturerLitersPerHour(2000), closeTo(4.795, 0.0001));
    expect(profile.manufacturerLitersPerHour(2200), closeTo(6.492, 0.0001));
    expect(profile.manufacturerLitersPerHour(2400), closeTo(8.077, 0.0001));
    expect(profile.estimateLitersPerHour(1800), closeTo(2.616, 0.001));
    expect(profile.estimateLitersPerHour(2000), closeTo(3.357, 0.001));
    expect(profile.estimateLitersPerHour(2200), closeTo(4.544, 0.001));
    expect(profile.estimateLitersPerHour(2400), closeTo(5.654, 0.001));
  });
}
