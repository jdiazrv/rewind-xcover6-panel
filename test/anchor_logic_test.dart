import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

void main() {
  test('el auto levado exige estar armado y superar estrictamente 300 m', () {
    expect(shouldAutoRaiseAnchor(armed: true, trustedDistanceM: 300), isFalse);
    expect(
      shouldAutoRaiseAnchor(armed: true, trustedDistanceM: 300.01),
      isTrue,
    );
    expect(shouldAutoRaiseAnchor(armed: false, trustedDistanceM: 500), isFalse);
    expect(shouldAutoRaiseAnchor(armed: true, trustedDistanceM: null), isFalse);
  });

  test('live anchor-track points use the same adjusted clock as the drop', () {
    final previousOffset = skClockOffset;
    addTearDown(() => skClockOffset = previousOffset);
    skClockOffset = const Duration(hours: 2);

    final track = OwnTrackHistory()..add(37.0, 23.0);

    expect(track.points, hasLength(1));
    expect(
      track.points.single.t.difference(skNow()).abs(),
      lessThan(const Duration(seconds: 1)),
    );
  });

  test('physical watch radius is used when chain and depth are known', () {
    expect(effectiveWatchRadiusM(70, 50, 10), closeTo(math.sqrt(2400), 1e-9));
    expect(effectiveWatchRadiusM(70, null, 10), 70);
    expect(effectiveWatchRadiusM(70, 5, 10), 70);
  });

  test('roller height above the waterline deepens the vertical leg', () {
    // Same 50m chain/10m depth as above, but the roller sits 2m above the
    // water — the true vertical drop to the seabed is 12m, not 10m, so the
    // horizontal (watch) radius should shrink accordingly.
    final withoutRoller = effectiveWatchRadiusM(70, 50, 10);
    final withRoller = effectiveWatchRadiusM(70, 50, 10, rollerHeightM: 2);
    expect(withRoller, lessThan(withoutRoller));
    expect(withRoller, closeTo(math.sqrt(50 * 50 - 12 * 12), 1e-9));
  });

  test('destinationPoint round-trips with bearingDistanceMeters', () {
    const lat = 37.0, lon = 23.0;
    final dest = destinationPoint(lat, lon, 100, 45);
    final back = bearingDistanceMeters(lat, lon, dest.lat, dest.lon);
    expect(back.distanceM, closeTo(100, 0.5));
    expect(back.bearingDeg, closeTo(45, 0.5));
  });

  test('reused anchor trace includes only accepted and current windows', () {
    final base = DateTime.utc(2026, 9, 6, 8);
    final points = [
      AnchorTrackPoint(base, 37, 23),
      AnchorTrackPoint(base.add(const Duration(minutes: 10)), 37.1, 23.1),
      AnchorTrackPoint(base.add(const Duration(minutes: 20)), 37.2, 23.2),
      AnchorTrackPoint(base.add(const Duration(minutes: 30)), 37.3, 23.3),
    ];
    final selected = anchorTrackForSession(
      points: points,
      currentFrom: base.add(const Duration(minutes: 25)),
      reusedFrom: base.add(const Duration(minutes: 5)),
      reusedUntil: base.add(const Duration(minutes: 15)),
    );

    expect(selected, [points[1], points[3]]);
    expect(
      anchorTrackForSession(
        points: points,
        currentFrom: base.add(const Duration(minutes: 25)),
      ),
      [points[3]],
    );
  });

  test('reused trace window survives anchor configuration persistence', () {
    final from = DateTime.utc(2026, 9, 6, 8);
    final until = from.add(const Duration(hours: 1));
    final original = AnchorConfig()
      ..reusedTrackFrom = from
      ..reusedTrackUntil = until;

    final restored = AnchorConfig.fromJson(original.toJson());
    expect(restored.reusedTrackFrom, from);
    expect(restored.reusedTrackUntil, until);
  });

  test('borneo smoothing remains close to north across 360 degrees', () {
    const anchorLat = 37.0;
    const anchorLon = 23.0;
    const radiusM = 40.0;
    final now = DateTime.utc(2026, 9, 5, 12);
    const bearings = [358.0, 359.0, 1.0, 2.0, 359.0, 1.0];
    final cosLat = math.cos(anchorLat * math.pi / 180);
    final points = <AnchorYawPoint>[
      for (var i = 0; i < bearings.length; i++)
        () {
          final rad = bearings[i] * math.pi / 180;
          return AnchorYawPoint(
            t: now.add(Duration(seconds: i * 10)),
            lat: anchorLat + radiusM * math.cos(rad) / 110540,
            lon: anchorLon + radiusM * math.sin(rad) / (cosLat * 111320),
          );
        }(),
    ];

    final result = computeYawAnalysis(
      points: points,
      anchorLat: anchorLat,
      anchorLon: anchorLon,
      radiusM: radiusM,
    );

    expect(result.borneoSeries, hasLength(points.length));
    for (final sample in result.borneoSeries) {
      final normalized = normalize360(sample.deg);
      expect(normalized < 15 || normalized > 345, isTrue);
    }
  });
}
