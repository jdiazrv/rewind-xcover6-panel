import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Los sensores inalámbricos (Mopeka de tanque, sondas de nevera) llevan pila,
/// y cuando se agota dejan de emitir sin avisar: en AREA SECADA el sensor de
/// agua va a 2,56 V y pasa cuartos de hora sin hablar. Por eso el voltaje se
/// enseña junto al dato al que pertenece.
void main() {
  group('sensorBatteryPercent', () {
    test('una CR2032 llena y una agotada', () {
      expect(sensorBatteryPercent(3.0), 100);
      expect(sensorBatteryPercent(2.2), 0);
    });

    test('el caso real de AREA SECADA queda a media carga', () {
      expect(sensorBatteryPercent(2.5625), closeTo(45.3, 0.2));
    });

    test('no se sale de la escala', () {
      expect(sensorBatteryPercent(3.4), 100);
      expect(sensorBatteryPercent(1.5), 0);
    });

    test('sin voltaje no hay porcentaje', () {
      expect(sensorBatteryPercent(null), isNull);
      expect(sensorBatteryPercent(double.nan), isNull);
    });

    test('se puede ajustar el rango para otra química', () {
      expect(sensorBatteryPercent(3.6, emptyV: 3.0, fullV: 4.2), closeTo(50, 0.1));
    });
  });

  group('guessSensorBatteryPath', () {
    const candidatas = [
      'sensors.mopeka_water_tank.battery.voltage',
      'sensors.ruuvi_nevera.battery.voltage',
    ];

    test('asocia el tanque de agua con su Mopeka', () {
      expect(
        guessSensorBatteryPath('tanks.freshWater.0', 'Agua dulce', candidatas),
        'sensors.mopeka_water_tank.battery.voltage',
      );
    });

    test('asocia la nevera con su sonda', () {
      expect(
        guessSensorBatteryPath(
          'environment.fridge_1.temperature',
          'Nevera',
          candidatas,
        ),
        'sensors.ruuvi_nevera.battery.voltage',
      );
    });

    test('sin parecido no inventa una asociación', () {
      expect(
        guessSensorBatteryPath(
          'environment.sonoff.temperature',
          'Cuadro eléctrico',
          candidatas,
        ),
        isNull,
      );
    });

    test('sin candidatas devuelve null', () {
      expect(guessSensorBatteryPath('tanks.freshWater.0', 'Agua', const []), isNull);
    });
  });

  group('persistencia', () {
    test('la ruta de pila sobrevive a guardar y releer', () {
      final slot = TempSensorSlot(
        path: 'environment.fridge_1.temperature',
        label: 'Nevera',
        batteryPath: 'sensors.ruuvi_nevera.battery.voltage',
      );
      expect(
        TempSensorSlot.fromJson(slot.toJson()).batteryPath,
        'sensors.ruuvi_nevera.battery.voltage',
      );
      final tank = TankSlot(
        type: 'freshWater',
        id: '0',
        groupLabel: 'Agua',
        capacityL: 200,
        batteryPath: 'sensors.mopeka_water_tank.battery.voltage',
      );
      expect(
        TankSlot.fromJson(tank.toJson()).batteryPath,
        'sensors.mopeka_water_tank.battery.voltage',
      );
    });
  });
}
