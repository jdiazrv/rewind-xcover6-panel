import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// En REWIND la pantalla TMP salía con tarjetas repetidas y tituladas "43":
/// el Cerbo republica cada sonda como `environment.venus.<id>.temperature` y
/// una versión anterior las guardó activas en la configuración del barco.
void main() {
  TempSensorSlot venus(String id, {String? label, bool enabled = true}) =>
      TempSensorSlot(
        path: 'environment.venus.$id.temperature',
        label: label ?? id,
        enabled: enabled,
      );

  group('silenceDuplicateVenusTemps', () {
    test('apaga las del Cerbo cuando hay sondas con nombre', () {
      final slots = [
        TempSensorSlot(
          path: 'environment.fridge_1.temperature',
          label: 'T. Nevera 1',
        ),
        venus('41'),
        venus('45'),
      ];
      silenceDuplicateVenusTemps(slots);
      expect(slots.first.enabled, isTrue);
      expect(slots.where((s) => s.enabled), hasLength(1));
    });

    test('las respeta si son lo único que publica el barco', () {
      final slots = [venus('41'), venus('42')];
      silenceDuplicateVenusTemps(slots);
      expect(
        slots.every((s) => s.enabled),
        isTrue,
        reason: 'sin ellas ese barco no tendría ninguna temperatura',
      );
    });

    test('una sonda con nombre apagada no cuenta como sonda con nombre', () {
      final slots = [
        TempSensorSlot(
          path: 'environment.water.temperature',
          label: 'T. mar',
          enabled: false,
        ),
        venus('45'),
      ];
      silenceDuplicateVenusTemps(slots);
      expect(slots.last.enabled, isTrue);
    });

    test('un título que es solo un número se rehace', () {
      final slots = [venus('43')];
      silenceDuplicateVenusTemps(slots);
      expect(slots.single.label, 'Venus 43');
    });

    test('un nombre puesto a mano no se toca', () {
      final slots = [
        TempSensorSlot(
          path: 'environment.fridge_1.temperature',
          label: 'T. Nevera 1',
        ),
        venus('43', label: 'Cuadro (Cerbo)'),
      ];
      silenceDuplicateVenusTemps(slots);
      expect(slots.last.label, 'Cuadro (Cerbo)');
      expect(slots.last.enabled, isFalse);
    });

    test('la limpieza llega a la configuración ya guardada', () {
      final c = SensorConfig.empty()
        ..tempSensors = [
          TempSensorSlot(
            path: 'environment.sonoff.temperature',
            label: 'Cuadro eléctrico',
          ),
          venus('43'),
        ];
      final back = SensorConfig.fromJson(c.toJson());
      final cerbo = back.tempSensors.firstWhere(
        (s) => s.path.startsWith('environment.venus.'),
      );
      expect(cerbo.enabled, isFalse);
      expect(cerbo.label, 'Venus 43');
    });
  });

  group('labelFromPath', () {
    test('las entradas del Cerbo llevan su prefijo', () {
      expect(
        TempSensorSlot.labelFromPath('environment.venus.43.temperature'),
        'Venus 43',
      );
    });

    test('el resto sigue igual', () {
      expect(
        TempSensorSlot.labelFromPath('environment.solar_fuses.temperature'),
        'Solar fuses',
      );
    });
  });

  group('skDetectablePaths', () {
    test('incluye las pilas de los sensores inalámbricos', () {
      // Sin esto no se puede ofrecer en CFG qué pila va con qué tanque: la
      // del Mopeka de AREA SECADA es sensors.mopeka_water_tank.battery.voltage.
      expect(
        skDetectablePaths([
          'sensors.mopeka_water_tank.battery.voltage',
          'navigation.position',
        ]),
        ['sensors.mopeka_water_tank.battery.voltage'],
      );
    });
  });
}
