import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// signalk-venus-plugin solo traduce los fluidos 0-5 de Victron, así que
/// una bombona de gas (tipo 8) llega como `tanks.unknown.32` aunque en el
/// Venus esté configurada como LPG. displayType permite pintarla como LPG
/// sin dejar de leerla de su ruta real.
void main() {
  test('sin displayType, kind es el tipo de la ruta', () {
    final t = TankSlot(
      type: 'fuel',
      id: '27',
      groupLabel: 'Fuel 1',
      capacityL: 180,
    );
    expect(t.kind, 'fuel');
    expect(t.skPath, 'tanks.fuel.27.currentLevel');
  });

  test('displayType cambia la presentación pero NUNCA la ruta', () {
    final t = TankSlot(
      type: 'unknown',
      id: '32',
      groupLabel: 'Gas',
      capacityL: 10,
      displayType: 'lpg',
    );
    expect(t.kind, 'lpg', reason: 'se pinta como LPG');
    // Lo esencial: el dato se sigue leyendo de donde el Venus lo publica.
    expect(t.skPath, 'tanks.unknown.32.currentLevel');
    expect(t.tankKey, 'unknown.32');
  });

  test('displayType sobrevive a guardar y releer la configuración', () {
    final t = TankSlot(
      type: 'unknown',
      id: '32',
      groupLabel: 'Gas',
      capacityL: 10,
      displayType: 'lpg',
    );
    final back = TankSlot.fromJson(t.toJson());
    expect(back.displayType, 'lpg');
    expect(back.kind, 'lpg');
    expect(back.skPath, 'tanks.unknown.32.currentLevel');
  });

  test('una configuración antigua (sin el campo) sigue cargando', () {
    final back = TankSlot.fromJson({
      'type': 'freshWater',
      'id': '24',
      'groupLabel': 'Agua Stbd',
      'capacityL': 275,
    });
    expect(back.displayType, isNull);
    expect(back.kind, 'freshWater');
  });
}
