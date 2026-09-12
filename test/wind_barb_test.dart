import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

void main() {
  test(
    'cada barba promedia velocidad y dirección en una ventana de ±3 min',
    () {
      final slot = DateTime.utc(2026, 9, 12, 12);
      final times = [
        slot.subtract(const Duration(minutes: 2)),
        slot,
        slot.add(const Duration(minutes: 2)),
      ];
      final barbs = sampleWindBarbs(
        tws: [
          GraphPoint(time: times[0], value: 10),
          GraphPoint(time: times[1], value: 10),
          GraphPoint(time: times[2], value: 40),
        ],
        twd: [
          GraphPoint(time: times[0], value: 350),
          GraphPoint(time: times[1], value: 350),
          GraphPoint(time: times[2], value: 20),
        ],
        start: slot.subtract(const Duration(minutes: 5)),
        end: slot.add(const Duration(minutes: 5)),
        interval: const Duration(minutes: 5),
      );

      expect(barbs, hasLength(1));
      expect(barbs.single.time, slot);
      expect(barbs.single.speedKnots, closeTo(20, 1e-9));
      expect(barbs.single.directionDeg, anyOf(lessThan(1), greaterThan(359)));
    },
  );
}
