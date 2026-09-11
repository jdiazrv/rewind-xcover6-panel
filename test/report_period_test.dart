import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/performance_report.dart';

void main() {
  test('el marcador inicial se detiene al alcanzar 24 horas', () {
    final result = normalizeReportRange(
      const RangeValues(2880, 4320),
      const RangeValues(1000, 4320),
    );

    expect(result, const RangeValues(2880, 4320));
  });

  test('el marcador final se detiene al alcanzar 24 horas', () {
    final result = normalizeReportRange(
      const RangeValues(0, 1440),
      const RangeValues(0, 4000),
    );

    expect(result, const RangeValues(0, 1440));
  });

  test('los dos marcadores ajustan en pasos de 15 minutos', () {
    final startMoved = normalizeReportRange(
      const RangeValues(3000, 3600),
      const RangeValues(3011, 3600),
    );
    final endMoved = normalizeReportRange(
      startMoved,
      RangeValues(startMoved.start, 3592),
    );

    expect(startMoved, const RangeValues(3015, 3600));
    expect(endMoved, const RangeValues(3015, 3585));
  });
}
