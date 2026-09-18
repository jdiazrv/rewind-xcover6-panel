import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// El cuentahoras guardado es de cada barco. Se guardaba una sola vez para
/// todos y, como al conectar se toma el máximo entre lo guardado y el
/// histórico, lysmarine enseñaba las horas del último barco al que te habías
/// conectado (AREA SECADA). Visto en vivo el 18/09/2026.
void main() {
  test('cada barco guarda y recupera las suyas', () {
    final map = <String, EngineHoursCache>{
      'lysmarine.local:3000': EngineHoursCache(
        hours: 1234.5,
        hoursAt: DateTime.utc(2026, 9, 18, 8),
      ),
      'AREA SECADA': EngineHoursCache(hours: 4321.0),
    };

    final back = EngineHoursCache.mapFromJson(EngineHoursCache.mapToJson(map));

    expect(back['lysmarine.local:3000']!.hours, 1234.5);
    expect(
      back['lysmarine.local:3000']!.hoursAt,
      DateTime.utc(2026, 9, 18, 8).toLocal(),
    );
    expect(back['AREA SECADA']!.hours, 4321.0);
  });

  test('un barco sin nada guardado no hereda las de otro', () {
    final back = EngineHoursCache.mapFromJson(
      EngineHoursCache.mapToJson({'AREA SECADA': EngineHoursCache(hours: 99)}),
    );
    expect(back['lysmarine.local:3000'], isNull);
  });

  test('los vacíos no se guardan y lo corrupto no rompe', () {
    expect(EngineHoursCache.mapToJson({'x': EngineHoursCache()}), '{}');
    expect(EngineHoursCache.mapFromJson('esto no es json'), isEmpty);
    expect(EngineHoursCache.mapFromJson(null), isEmpty);
  });
}
