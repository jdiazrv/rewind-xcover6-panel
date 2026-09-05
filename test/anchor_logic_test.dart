import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

void main() {
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
