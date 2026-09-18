import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// Si el receptor AIS está funcionando se sabe por la última POSICIÓN de otro
/// emisor, nada más. Con el AIS de REWIND apagado, la app lo seguía dando por
/// encendido porque dos plugins del servidor escriben sobre los blancos cada
/// segundo (visto en vivo el 18/09/2026).
void main() {
  test('sin estación base: encendido hasta 3 min de silencio', () {
    expect(aisReceiverAlive(const Duration(seconds: 5)), isTrue);
    expect(aisReceiverAlive(const Duration(minutes: 2, seconds: 59)), isTrue);
    expect(aisReceiverAlive(const Duration(minutes: 3)), isFalse);
    expect(aisReceiverAlive(null), isFalse);
  });

  test('con estación base al alcance se detecta en 30 s', () {
    expect(
      aisReceiverAlive(const Duration(seconds: 20), baseStationHeard: true),
      isTrue,
    );
    expect(
      aisReceiverAlive(const Duration(seconds: 31), baseStationHeard: true),
      isFalse,
    );
  });

  test('el "hace X" solo aparece pasado el minuto', () {
    expect(aisSilenceText(const Duration(seconds: 40)), isNull);
    // Con segundos por debajo de 5 min: 1:59 no puede decir "1 min".
    expect(
      aisSilenceText(const Duration(minutes: 1, seconds: 59)),
      'último mensaje hace 1 min 59 s',
    );
    expect(
      aisSilenceText(const Duration(minutes: 2)),
      'último mensaje hace 2 min',
    );
    expect(
      aisSilenceText(const Duration(minutes: 5, seconds: 30)),
      'último mensaje hace 5 min',
    );
    expect(aisSilenceText(const Duration(hours: 2)), 'último mensaje hace 2 h');
    expect(
      aisSilenceText(const Duration(hours: 1, minutes: 5)),
      'último mensaje hace 1 h 5 min',
    );
    expect(aisSilenceText(null), 'ningún mensaje AIS recibido');
  });
}
