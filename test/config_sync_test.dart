import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/config_sync.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// La configuración del barco se comparte entre dispositivos a través del
/// servidor. Lo que no puede fallar: que no viaje ninguna contraseña, que no
/// se pise un ajuste propio del aparato, y que una versión distinta de la app
/// no estropee la configuración de las demás.
void main() {
  group('qué se comparte', () {
    test('lleva lo que describe al barco', () {
      final s = SettingsModel()
        ..shipIconId = 'lagoon-42-catamaran'
        ..ntfyTopic = 'SV_REWIND'
        ..anchorTotalChainLengthM = 80
        ..batteryChemistryStart = 'lithium';
      final doc = sharedConfigFromSettings(s);

      expect(doc['schemaVersion'], kSharedConfigSchemaVersion);
      expect(doc['sensors'], isA<Map<String, dynamic>>());
      expect((doc['ship'] as Map)['iconId'], 'lagoon-42-catamaran');
      expect((doc['alarms'] as Map)['ntfyTopic'], 'SV_REWIND');
      expect((doc['anchor'] as Map)['totalChainLengthM'], 80);
      expect((doc['battery'] as Map)['chemistryStart'], 'lithium');
    });

    test('NUNCA lleva credenciales ni ajustes del dispositivo', () {
      final s = SettingsModel()
        ..skUsername = 'user'
        ..skPassword = 'secreta'
        ..authBase64 = 'dXNlcjpzZWNyZXRh'
        ..influxToken = 'token-influx'
        ..brightnessMode = 'noche'
        ..keepAwake = false
        ..anchorDeviceId = 'tablet-1';
      final texto = jsonEncode(sharedConfigFromSettings(s));

      expect(texto, isNot(contains('secreta')));
      expect(texto, isNot(contains('token-influx')));
      expect(texto, isNot(contains('dXNlcjpzZWNyZXRh')));
      expect(texto, isNot(contains('tablet-1')));
      for (final clave in kNeverSharedKeys) {
        expect(texto, isNot(contains('"$clave"')), reason: clave);
      }
    });
  });

  group('lo que vigila el barco viaja entero', () {
    // Antes la corredera y el "sin posición" eran las dos únicas alarmas que
    // se quedaban en el aparato, con sus vecinas de la misma tarjeta
    // viajando: apagabas una en la tablet y seguía activa en el móvil.
    test('corredera, sin posición y falsas alarmas se comparten', () {
      final origen = SettingsModel()
        ..alarmCorrederaEnabled = true
        ..alarmAnchorNoPositionEnabled = false
        ..alarmAnchorFilterGlitches = false
        ..alarmAnchorGlitchJumpM = 75;
      final destino = SettingsModel();

      applySharedConfig(destino, sharedConfigFromSettings(origen));

      expect(destino.alarmCorrederaEnabled, isTrue);
      expect(destino.alarmAnchorNoPositionEnabled, isFalse);
      expect(destino.alarmAnchorFilterGlitches, isFalse);
      expect(destino.alarmAnchorGlitchJumpM, 75);
    });

    test('a qué alarmas avisa el push también', () {
      final origen = SettingsModel()..ntfyAlarmKeys.addAll({'drag', 'wind'});
      final destino = SettingsModel()..ntfyAlarmKeys.add('depth');

      applySharedConfig(destino, sharedConfigFromSettings(origen));

      expect(destino.ntfyAlarmKeys, {'drag', 'wind'});
    });

    test('una lista de push vacía no borra la que ya hay', () {
      final destino = SettingsModel()..ntfyAlarmKeys.addAll({'drag'});

      applySharedConfig(destino, sharedConfigFromSettings(SettingsModel()));

      expect(destino.ntfyAlarmKeys, {'drag'});
    });

    test('cómo avisa cada aparato se queda en el aparato', () {
      final origen = SettingsModel()
        ..alarmAisSound = false
        ..alarmAnchorWindSound = false
        ..anchorShowElectrical = true
        ..anchorDetectPhoneLeftByWifi = true;
      final destino = SettingsModel()
        ..alarmAisSound = true
        ..alarmAnchorWindSound = true
        ..anchorShowElectrical = false
        ..anchorDetectPhoneLeftByWifi = false;

      applySharedConfig(destino, sharedConfigFromSettings(origen));

      expect(destino.alarmAisSound, isTrue);
      expect(destino.alarmAnchorWindSound, isTrue);
      expect(destino.anchorShowElectrical, isFalse);
      expect(destino.anchorDetectPhoneLeftByWifi, isFalse);
    });
  });

  group('aplicar lo del servidor', () {
    test('ida y vuelta conserva la configuración del barco', () {
      final origen = SettingsModel()
        ..shipIconId = 'x-yachts-x56'
        ..ntfyTopic = 'SV_DRAGUEUR'
        ..alarmAnchorWindKn = 30
        ..anchorGpsToBowM = 4.5
        ..sensorConfig = (SensorConfig.empty()
          ..batteryHouseId = 'house'
          ..tempSensors = [
            TempSensorSlot(
              path: 'environment.water.temperature',
              label: 'T. mar',
              role: 'mar',
            ),
          ]);
      final destino = SettingsModel();

      applySharedConfig(destino, sharedConfigFromSettings(origen));

      expect(destino.shipIconId, 'x-yachts-x56');
      expect(destino.ntfyTopic, 'SV_DRAGUEUR');
      expect(destino.alarmAnchorWindKn, 30);
      expect(destino.anchorGpsToBowM, 4.5);
      expect(destino.sensorConfig.batteryHouseId, 'house');
      expect(destino.sensorConfig.tempSensors.single.label, 'T. mar');
    });

    test('no toca los ajustes del dispositivo', () {
      final destino = SettingsModel()
        ..brightnessMode = 'noche'
        ..keepAwake = false
        ..skPassword = 'la mía'
        ..anchorDeviceId = 'tablet-2';

      applySharedConfig(destino, sharedConfigFromSettings(SettingsModel()));

      expect(destino.brightnessMode, 'noche');
      expect(destino.keepAwake, isFalse);
      expect(destino.skPassword, 'la mía');
      expect(destino.anchorDeviceId, 'tablet-2');
    });

    test('lo que no venga se queda como está', () {
      final destino = SettingsModel()..shipIconId = 'moody-425-centre-cockpit';
      applySharedConfig(destino, {'schemaVersion': 1});
      expect(destino.shipIconId, 'moody-425-centre-cockpit');
    });

    test('un documento de otra versión no rompe nada', () {
      final destino = SettingsModel();
      applySharedConfig(destino, {
        'schemaVersion': 99,
        'ship': {'iconId': 'semirrigida-9m'},
        'inventado': {'algo': true},
        'alarms': 'esto no es un objeto',
      });
      expect(destino.shipIconId, 'semirrigida-9m');
      expect(destino.ntfyTopic, '', reason: 'el bloque inválido se ignora');
    });

    test('un valor de tipo raro no sustituye a uno bueno', () {
      final destino = SettingsModel()..alarmAnchorWindKn = 22;
      applySharedConfig(destino, {
        'alarms': {'anchorWindKn': 'mucho', 'ntfyTopic': 42},
      });
      expect(destino.alarmAnchorWindKn, 22);
      expect(destino.ntfyTopic, '');
    });
  });

  group('mezcla de sensores: un vacío no borra lo que ya hay', () {
    test('el perfil del motor sobrevive a un servidor sin configurar', () {
      // El fallo real de 2026-09-17: el barco tenía engineModelId vacío y al
      // sincronizar desaparecía el consumo estimado del panel de motor.
      final local = SettingsModel()
        ..sensorConfig = (SensorConfig()
          ..engineModelId = 'yanmar-4jh45'
          ..engineDriveType = 'saildrive'
          ..enginePropellerType = 'folding'
          ..enginePath = 'propulsion.main.runTime');
      final remoto = sharedConfigFromSettings(
        SettingsModel()..sensorConfig = SensorConfig.empty(),
      );

      applySharedConfig(local, remoto);

      expect(local.sensorConfig.engineModelId, 'yanmar-4jh45');
      expect(local.sensorConfig.engineDriveType, 'saildrive');
      expect(local.sensorConfig.enginePropellerType, 'folding');
      expect(local.sensorConfig.enginePath, 'propulsion.main.runTime');
    });

    test('un valor real del servidor sí manda', () {
      final local = SettingsModel()
        ..sensorConfig = (SensorConfig()..batteryHouseId = '278');
      final remoto = sharedConfigFromSettings(
        SettingsModel()
          ..sensorConfig = (SensorConfig()..batteryHouseId = 'house'),
      );

      applySharedConfig(local, remoto);

      expect(local.sensorConfig.batteryHouseId, 'house');
    });

    test('mergeSensorJson: vacíos fuera, valores dentro', () {
      final merged = mergeSensorJson(
        local: {
          'engineModelId': 'yanmar',
          'dcLoadsPath': 'electrical.venus.dcPower',
          'tanks': [
            {'type': 'fuel'},
          ],
          'fridgeWarnC': 6,
        },
        remote: {
          'engineModelId': '',
          'dcLoadsPath': null,
          'tanks': [],
          'fridgeWarnC': 4,
          'bowthrusterPath': 'electrical.batteries.proa.voltage',
        },
      );
      expect(merged['engineModelId'], 'yanmar');
      expect(merged['dcLoadsPath'], 'electrical.venus.dcPower');
      expect(merged['tanks'], hasLength(1));
      expect(merged['fridgeWarnC'], 4, reason: 'un número sí es un valor');
      expect(merged['bowthrusterPath'], 'electrical.batteries.proa.voltage');
    });

    test('un false del servidor no se confunde con "sin valor"', () {
      final merged = mergeSensorJson(
        local: {'hasOutsideTemp': true},
        remote: {'hasOutsideTemp': false},
      );
      expect(merged['hasOutsideTemp'], isFalse);
    });
  });

  group('cuándo se adopta lo del servidor', () {
    test('solo si la revisión es distinta de la última vista', () {
      expect(
        shouldAdoptRemote(remoteRevision: 4, localKnownRevision: 3),
        isTrue,
      );
      expect(
        shouldAdoptRemote(remoteRevision: 3, localKnownRevision: 3),
        isFalse,
        reason: 'ya la tenemos: no se reescribe nada',
      );
    });

    test('un servidor sin configuración no se adopta', () {
      expect(
        shouldAdoptRemote(remoteRevision: 0, localKnownRevision: 0),
        isFalse,
        reason: 'no puede vaciar la configuración de este dispositivo',
      );
    });

    test('una revisión anterior también se adopta: manda el servidor', () {
      // Pasa al restaurar una versión antigua desde otro dispositivo.
      expect(
        shouldAdoptRemote(remoteRevision: 2, localKnownRevision: 7),
        isTrue,
      );
    });
  });

  test('sharedConfigEquals detecta cambios reales', () {
    final a = sharedConfigFromSettings(SettingsModel());
    final b = sharedConfigFromSettings(SettingsModel()..ntfyTopic = 'otro');
    expect(sharedConfigEquals(a, Map<String, dynamic>.from(a)), isTrue);
    expect(sharedConfigEquals(a, b), isFalse);
  });
}
