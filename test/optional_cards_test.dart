import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// La app nació configurada para REWIND: hélice de proa, dos neveras, dos
/// controladores solares, consumos DC del Cerbo… Un barco que no tiene algo
/// de eso no debe ver su tarjeta vacía, pero tampoco puede perder una tarjeta
/// real solo porque el sensor estuviera apagado el día que se configuró.
void main() {
  group('optionalCardVisible', () {
    test('en automático manda lo que publica el barco', () {
      expect(optionalCardVisible('auto', detected: true), isTrue);
      expect(optionalCardVisible('auto', detected: false), isFalse);
    });

    test('la decisión manual siempre gana', () {
      expect(
        optionalCardVisible('on', detected: false),
        isTrue,
        reason: 'un sensor apagado hoy puede volver mañana',
      );
      expect(
        optionalCardVisible('off', detected: true),
        isFalse,
        reason: 'aunque exista, se puede no querer ver',
      );
    });

    test('un valor desconocido se comporta como automático', () {
      expect(optionalCardVisible('', detected: true), isTrue);
      expect(optionalCardVisible('loquesea', detected: false), isFalse);
    });

    test('cada tarjeta opcional tiene nombre visible', () {
      expect(kOptionalCardLabels.keys, contains('bowthruster'));
      expect(kOptionalCardLabels['bowthruster'], isNotEmpty);
      expect(kOptionalCardLabels.length, 4);
    });
  });

  group('skDetectablePaths', () {
    test('se queda con lo que decide tarjetas y descarta el resto', () {
      final paths = skDetectablePaths([
        'electrical.batteries.bowthruster.voltage',
        'tanks.fuel.27.currentLevel',
        'propulsion.main.revolutions',
        'environment.wind.speedApparent',
        'navigation.position',
        'design.influxHost',
        'notifications.navigation.anchor',
      ]);
      expect(paths, [
        'electrical.batteries.bowthruster.voltage',
        'environment.wind.speedApparent',
        'propulsion.main.revolutions',
        'tanks.fuel.27.currentLevel',
      ]);
    });

    test('sin duplicados y en orden estable', () {
      final paths = skDetectablePaths([
        'tanks.fuel.27.currentLevel',
        'electrical.venus.dcPower',
        'tanks.fuel.27.currentLevel',
      ]);
      expect(paths, ['electrical.venus.dcPower', 'tanks.fuel.27.currentLevel']);
    });
  });

  group('SensorConfig', () {
    test('guarda y relee las rutas detectadas y las tarjetas ocultas', () {
      final c = SensorConfig.empty()
        ..detectedPaths = ['electrical.venus.dcPower']
        ..cardVisibility = {'bowthruster': 'off', 'solar': 'on'};
      final back = SensorConfig.fromJson(c.toJson());
      expect(back.detectedPaths, ['electrical.venus.dcPower']);
      expect(back.cardVisibility['bowthruster'], 'off');
      expect(back.cardVisibility['solar'], 'on');
    });

    test('un servidor sin configurar no hereda las rutas de REWIND', () {
      final c = SensorConfig.empty();
      expect(c.bowthrusterPath, isNull);
      expect(c.dcLoadsPath, isNull);
      expect(c.detectedPaths, isEmpty);
    });

    test('una configuración antigua conserva sus rutas', () {
      // Sin estas claves no se puede saber si el barco no tiene hélice de
      // proa o si es que se guardó antes de que existiera el campo: se
      // conserva lo que había para no esconder una tarjeta que hoy se ve.
      final legacy = SensorConfig().toJson()
        ..remove('bowthrusterPath')
        ..remove('dcLoadsPath');
      final c = SensorConfig.fromJson(legacy);
      expect(c.bowthrusterPath, 'electrical.batteries.bowthruster.voltage');
      expect(c.dcLoadsPath, 'electrical.venus.dcPower');
    });

    test('una ruta puesta a null se respeta al releer', () {
      final c = SensorConfig()..bowthrusterPath = null;
      expect(SensorConfig.fromJson(c.toJson()).bowthrusterPath, isNull);
    });
  });
}
