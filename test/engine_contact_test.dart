import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

void main() {
  const fast = Duration(milliseconds: 1500);
  const slow = Duration(milliseconds: 2800);
  final now = DateTime.utc(2026, 9, 9, 12);

  bool contact({
    double? rpm,
    DateTime? rpmAt,
    double? hours,
    DateTime? hoursAt,
  }) => engineContactTelemetryIsFresh(
    now: now,
    rpm: rpm,
    rpmUpdatedAt: rpmAt,
    slowTelemetry: [(hours, hoursAt)],
    fastStaleAfter: fast,
    slowStaleAfter: slow,
  );

  test('la primera muestra fresca activa contacto inmediatamente', () {
    expect(contact(hours: 5854321, hoursAt: now), isTrue);
    expect(contact(rpm: 0, rpmAt: now), isTrue);
  });

  test('RPM deja de indicar contacto tras 1,5 segundos sin tramas', () {
    expect(
      contact(rpm: 0, rpmAt: now.subtract(const Duration(milliseconds: 1499))),
      isTrue,
    );
    expect(
      contact(rpm: 0, rpmAt: now.subtract(const Duration(milliseconds: 1500))),
      isFalse,
    );
  });

  test('telemetría lenta cubre su cadencia y expira a los 2,8 segundos', () {
    expect(
      contact(
        hours: 5854321,
        hoursAt: now.subtract(const Duration(milliseconds: 2799)),
      ),
      isTrue,
    );
    expect(
      contact(
        hours: 5854321,
        hoursAt: now.subtract(const Duration(milliseconds: 2800)),
      ),
      isFalse,
    );
  });

  test('un valor retenido con timestamp antiguo no reactiva contacto', () {
    expect(
      contact(hours: 5854321, hoursAt: now.subtract(const Duration(hours: 1))),
      isFalse,
    );
  });
}
