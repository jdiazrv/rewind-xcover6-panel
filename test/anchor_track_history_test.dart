import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// La traza de ANC se rellena al entrar con 24 h del histórico del servidor.
/// Cada proveedor contesta la posición de una forma distinta y la app solo
/// entendía una: entrando remoto a QUINTO REAL (servido por el grabador del
/// propio plugin) la traza salía vacía aunque el servidor devolviera 200 con
/// 660 filas buenas. Visto en vivo el 17/09/2026.
void main() {
  test('lista [lon, lat] — signalk-to-influxdb2', () {
    final pts = anchorTrackFromHistoryRows([
      [
        '2026-09-16T14:54:00.000Z',
        [24.9406306, 37.4302065],
      ],
      [
        '2026-09-16T14:55:00.000Z',
        [24.9406400, 37.4302100],
      ],
    ]);

    expect(pts, hasLength(2));
    expect(pts.first.lat, closeTo(37.4302065, 1e-9));
    expect(pts.first.lon, closeTo(24.9406306, 1e-9));
    expect(pts.first.t.isUtc, isTrue);
  });

  test('objeto {latitude, longitude} — grabador REWIND', () {
    final pts = anchorTrackFromHistoryRows([
      [
        '2026-09-16T14:54:08.135Z',
        {'longitude': 25.1521987, 'latitude': 37.0900438},
      ],
    ]);

    expect(pts, hasLength(1));
    expect(pts.single.lat, closeTo(37.0900438, 1e-9));
    expect(pts.single.lon, closeTo(25.1521987, 1e-9));
  });

  test('tira las filas sin posición, corruptas o en 0,0', () {
    final pts = anchorTrackFromHistoryRows([
      ['2026-09-16T14:54:00.000Z', null],
      [
        'no es una fecha',
        [1.0, 2.0],
      ],
      [
        '2026-09-16T14:56:00.000Z',
        [0, 0],
      ],
      [
        '2026-09-16T14:57:00.000Z',
        [999, 999],
      ],
      [
        '2026-09-16T14:58:00.000Z',
        {'latitude': 37.1},
      ],
      [
        '2026-09-16T14:59:00.000Z',
        [24.94, 37.43],
      ],
    ]);

    expect(pts, hasLength(1));
    expect(pts.single.lat, closeTo(37.43, 1e-9));
  });

  test('con varios paths se queda con la columna que es una posición', () {
    final pts = anchorTrackFromHistoryRows([
      [
        '2026-09-16T14:54:00.000Z',
        3.4,
        {'latitude': 37.09, 'longitude': 25.15},
      ],
    ]);

    expect(pts, hasLength(1));
    expect(pts.single.lon, closeTo(25.15, 1e-9));
  });
}
