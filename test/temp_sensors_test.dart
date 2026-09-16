import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Las rutas de temperatura no son estándar en Signal K: REWIND publica 17 y
/// QUINTO REAL solo una. La pantalla TMP se construye desde esta lista, así
/// que lo que no puede fallar es la migración: quien ya tenía sus neveras
/// configuradas debe seguir viendo exactamente lo mismo tras actualizar.
void main() {
  group('TempSensorSlot', () {
    test('adivina el tipo por el nombre de la ruta', () {
      expect(
        TempSensorSlot.roleFromPath('environment.fridge_1.temperature'),
        'nevera',
      );
      expect(
        TempSensorSlot.roleFromPath('environment.freezer.temperature'),
        'congelador',
      );
      expect(
        TempSensorSlot.roleFromPath('environment.water.temperature'),
        'mar',
      );
      expect(
        TempSensorSlot.roleFromPath('environment.outside.temperature'),
        'ambiente',
      );
      // Lo que no se reconoce es "equipo": nunca se inventa una nevera.
      expect(
        TempSensorSlot.roleFromPath('environment.venus.43.temperature'),
        'equipo',
      );
    });

    test('propone un nombre legible', () {
      expect(
        TempSensorSlot.labelFromPath('environment.solar_fuses.temperature'),
        'Solar fuses',
      );
    });

    test('solo ofrece las temperaturas que no tienen ya su pantalla', () {
      expect(isConfigurableTempPath('environment.sonoff.temperature'), isTrue);
      expect(
        isConfigurableTempPath('electrical.batteries.279.temperature'),
        isFalse,
        reason: 'las baterías se ven en PWR',
      );
      expect(
        isConfigurableTempPath('propulsion.main.coolantTemperature'),
        isFalse,
        reason: 'el motor tiene su propio panel',
      );
      expect(
        isConfigurableTempPath('environment.rpi.cpu.temperature'),
        isFalse,
        reason: 'la Raspberry va en Diagnóstico',
      );
      expect(isConfigurableTempPath('environment.outside.humidity'), isFalse);
    });

    test('un tipo desconocido no rompe la configuración', () {
      final s = TempSensorSlot.fromJson({
        'path': 'environment.x.temperature',
        'label': 'X',
        'role': 'inventado',
      });
      expect(s.role, 'equipo');
      expect(s.enabled, isTrue);
    });
  });

  group('migración de SensorConfig', () {
    test('una configuración antigua conserva sus cinco tarjetas', () {
      final legacy = SensorConfig().toJson()..remove('tempSensors');
      legacy['fridge1Label'] = 'Nevera cocina';
      legacy['fridge1Location'] = 'tapa';
      legacy['fridge2Label'] = 'Nevera salón';
      legacy['fridge2Location'] = 'puerta';

      final c = SensorConfig.fromJson(legacy);

      expect(c.tempSensors.map((s) => s.path), [
        'environment.sonoff.temperature',
        'environment.solar_fuses.temperature',
        'environment.water.temperature',
        'environment.fridge_1.temperature',
        'environment.fridge_2.temperature',
      ]);
      final fridge = c.tempSensors[3];
      expect(fridge.label, 'T. Nevera cocina', reason: 'el nombre se muda');
      expect(fridge.note, 'tapa', reason: 'y la ubicación también');
      expect(fridge.role, 'nevera');
      expect(c.tempSensors.every((s) => s.enabled), isTrue);
    });

    test('el umbral de equipo se hereda del que había para el cuadro', () {
      final legacy = SensorConfig().toJson()
        ..remove('tempSensors')
        ..remove('equipmentWarnC')
        ..remove('equipmentAlarmC');
      legacy['sonoffWarnC'] = 50.0;
      legacy['sonoffAlarmC'] = 65.0;

      final c = SensorConfig.fromJson(legacy);

      expect(c.equipmentWarnC, 50);
      expect(c.equipmentAlarmC, 65);
    });

    test('un servidor sin configurar no hereda los sensores de REWIND', () {
      final c = SensorConfig.empty();
      expect(c.tempSensors, isEmpty);
      // Y al guardarlo y releerlo sigue vacío: la lista vacía es una
      // decisión, no una configuración que falte por migrar.
      expect(SensorConfig.fromJson(c.toJson()).tempSensors, isEmpty);
    });

    test('la lista sobrevive a guardar y releer', () {
      final c = SensorConfig.empty()
        ..tempSensors = [
          TempSensorSlot(
            path: 'environment.camarote.temperature',
            label: 'Camarote',
            note: 'proa',
            role: 'ambiente',
            enabled: false,
          ),
        ];
      final back = SensorConfig.fromJson(c.toJson()).tempSensors.single;
      expect(back.path, 'environment.camarote.temperature');
      expect(back.label, 'Camarote');
      expect(back.note, 'proa');
      expect(back.role, 'ambiente');
      expect(back.enabled, isFalse);
    });
  });
}
