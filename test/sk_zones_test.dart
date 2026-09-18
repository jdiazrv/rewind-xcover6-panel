import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/main.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// El panel de testigos tiene que enseñar TODAS las zonas de Signal K y su
/// estado, no solo las disparadas. Antes, con todo en orden, la placa salía
/// vacía aunque REWIND define cinco zonas y publica once notificaciones. La
/// forma de los datos es la de REWIND (lysmarine) del 18/09/2026.
void main() {
  final self = <String, dynamic>{
    'environment': {
      'depth': {
        'belowTransducer': {
          'value': 12.4,
          'meta': {
            'zones': [
              {'state': 'emergency', 'lower': 0, 'upper': 2.2},
              {'state': 'alarm', 'lower': 2.2, 'upper': 2.4},
              {'state': 'warn', 'lower': 2.4, 'upper': 2.9},
            ],
          },
        },
      },
    },
    'electrical': {
      'batteries': {
        '278': {
          'voltage': {
            'value': 13.1,
            'meta': {
              'zones': [
                {'state': 'alarm', 'lower': 0, 'upper': 12.3},
                {'state': 'warn', 'lower': 12.3, 'upper': 12.45},
                {'state': 'nominal', 'lower': 12.45, 'upper': 15},
                {'state': 'warn', 'lower': 15, 'upper': 15.5},
                {'state': 'alarm', 'lower': 15.5, 'upper': 100},
              ],
            },
          },
        },
      },
    },
    'notifications': {
      'environment': {
        'depth': {
          'belowTransducer': {
            'value': {'state': 'nominal', 'message': 'ok'},
          },
        },
        'fridge_1': {
          'temperature': {
            'value': {'state': 'normal', 'message': ''},
          },
        },
      },
      // Un plugin publica con el prefijo repetido.
      'notifications': {
        'propulsion': {
          'main': {
            'oilTemperature': {
              'value': {'state': 'alarm', 'message': 'Aceite caliente'},
            },
          },
        },
      },
    },
  };

  test('lee todas las zonas y todas las notificaciones, también normales', () {
    final snap = parseSkZonesSnapshot(self);

    expect(
      snap.zones.keys,
      unorderedEquals([
        'environment.depth.belowTransducer',
        'electrical.batteries.278.voltage',
      ]),
    );
    expect(
      snap.notifications['environment.depth.belowTransducer']?.state,
      'nominal',
    );
    expect(
      snap.notifications['environment.fridge_1.temperature']?.state,
      'normal',
    );
    expect(
      snap.notifications['notifications.propulsion.main.oilTemperature']?.state,
      'alarm',
    );
    // Las notificaciones no se cuelan como zonas.
    expect(
      snap.zones.keys.where((k) => k.startsWith('notifications')),
      isEmpty,
    );
  });

  test('nombres legibles, sin el prefijo repetido', () {
    expect(skPathLabel('environment.depth.belowTransducer'), 'Profundidad');
    expect(
      skPathLabel('electrical.batteries.278.voltage'),
      'Batería 278 · tensión',
    );
    expect(
      skPathLabel('notifications.propulsion.main.oilTemperature'),
      'Motor main · temperatura del aceite',
    );
    expect(
      skPathLabel('environment.fridge_1.temperature'),
      'Temperatura fridge 1',
    );
  });

  test('resumen de franjas: el tope ficticio de arriba es "sin límite"', () {
    final snap = parseSkZonesSnapshot(self);
    expect(
      skZoneSummary(snap.zones['environment.depth.belowTransducer']!),
      'emergencia < 2,2 · alarma 2,2–2,4 · aviso 2,4–2,9',
    );
    expect(
      skZoneSummary(snap.zones['electrical.batteries.278.voltage']!),
      'alarma < 12,3 · aviso 12,3–12,45 · aviso 15–15,5 · alarma > 15,5',
    );
  });

  test('estado del servidor → piloto', () {
    expect(lampForSkState('nominal'), LampState.ok);
    expect(lampForSkState('normal'), LampState.ok);
    expect(lampForSkState('warn'), LampState.warn);
    expect(lampForSkState('alert'), LampState.warn);
    expect(lampForSkState('alarm'), LampState.alarm);
    expect(lampForSkState('emergency'), LampState.alarm);
    // Un estado raro no es "en orden".
    expect(lampForSkState('lo-que-sea'), LampState.warn);
  });
}
