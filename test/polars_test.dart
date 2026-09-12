import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/polars.dart';

/// La polar decide tiempos y distancias de travesía, así que un error aquí
/// no se ve: sale un número plausible y equivocado.
void main() {
  late List<PolarTable> boats;
  late PolarTable dehler47;

  setUpAll(() {
    final raw = File('assets/polars/orc_polars.json').readAsStringSync();
    boats = PolarTable.listFromAsset(raw);
    dehler47 = boats.firstWhere((b) => b.id == 'dehler47');
  });

  group('el recurso empotrado', () {
    test('carga y todas las tablas son coherentes', () {
      expect(boats.length, greaterThanOrEqualTo(18));
      for (final b in boats) {
        expect(b.isValid, isTrue, reason: '${b.name} tiene la rejilla rota');
        expect(b.tws, orderedEquals([...b.tws]..sort()), reason: b.name);
        expect(b.twa, orderedEquals([...b.twa]..sort()), reason: b.name);
      }
    });

    test('ninguna tiene ángulos de ceñida absurdos', () {
      // El filtro de calidad descartó certificados con ceñidas de 55°, que
      // es lo que delataba una medición mala.
      for (final b in boats) {
        for (final a in b.beatAngle) {
          expect(
            a,
            inInclusiveRange(33, 50),
            reason: '${b.name}: ceñida a $a°',
          );
        }
      }
    });

    test('el Dehler 47 es el barco de REWIND', () {
      expect(dehler47.loa, closeTo(14.27, 0.05));
      expect(dehler47.ref, 'NED/NED7928');
    });
  });

  group('velocidad objetivo', () {
    test('coincide con la tabla en un punto medido', () {
      // Dehler 47, TWA 90°, 12 nudos: la tabla dice 8.45.
      expect(dehler47.speedAt(12, 90), closeTo(8.45, 0.01));
    });

    test('interpola entre dos vientos medidos', () {
      // A 11 nudos, entre los 8.07 de 10 y los 8.45 de 12.
      final v = dehler47.speedAt(11, 90)!;
      expect(v, greaterThan(8.07));
      expect(v, lessThan(8.45));
      expect(v, closeTo(8.26, 0.01));
    });

    test('es simétrica: babor y estribor dan lo mismo', () {
      expect(dehler47.speedAt(12, -110), dehler47.speedAt(12, 110));
    });

    test('por debajo de la ceñida óptima no hay velocidad', () {
      // Nadie navega a 20° del viento; decirlo es mejor que inventar.
      expect(dehler47.speedAt(12, 20), isNull);
    });

    test('cubre la zona de ceñida, por debajo de la rejilla', () {
      // La rejilla empieza en 52°, pero entre la ceñida óptima (40,5°) y
      // ese 52° hay que dar un número — es donde se navega de bolina.
      final v = dehler47.speedAt(12, 45);
      expect(v, isNotNull, reason: '45° cae entre la ceñida óptima y la tabla');
      expect(v!, greaterThan(6));
      expect(v, lessThan(dehler47.speedAt(12, 52)!));
    });

    test('fuera del rango de viento se pega al extremo y avisa', () {
      expect(dehler47.twsOutOfRange(30), isTrue);
      expect(dehler47.twsOutOfRange(12), isFalse);
      expect(dehler47.speedAt(30, 90), dehler47.speedAt(20, 90));
    });
  });

  group('ángulos óptimos', () {
    test('el Dehler 47 ciñe a unos 40° con 12 nudos', () {
      final b = dehler47.beatFor(12)!;
      expect(b.angle, closeTo(40.5, 0.1));
      expect(b.vmg, closeTo(5.46, 0.01));
    });

    test('empopa muy abierto, no a 180°', () {
      final r = dehler47.runFor(12)!;
      expect(r.angle, lessThan(175));
      expect(r.angle, greaterThan(140));
    });

    test('una tabla sin óptimos los deduce sola', () {
      // Las .pol importadas no traen ceñida/empopada: hay que barrerlas.
      final sinOptimos = PolarTable(
        id: 'x',
        name: 'x',
        tws: dehler47.tws,
        twa: dehler47.twa,
        speeds: dehler47.speeds,
      );
      final b = sinOptimos.beatFor(12)!;
      // Sin los extremos de ORC el barrido se queda en la rejilla (52° es
      // lo más cerrado que conoce), así que da un ángulo más abierto.
      expect(b.angle, inInclusiveRange(45.0, 60.0));
      expect(b.vmg, greaterThan(4));
    });
  });

  group('travesía hasta un destino', () {
    // Viento del norte para que las cuentas se lean solas.
    const twd = 0.0;

    test('ciñendo: el caso de las 12 millas contra el viento', () {
      final e = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 0, // destino justo a barlovento
        twdDeg: twd,
        twsKn: 12,
      )!;
      expect(e.mode, LegMode.beat);
      expect(e.sailAngle, closeTo(40.5, 0.1));
      // 12 / cos(40,5°) = 15,78 M reales.
      expect(e.sailedNm, closeTo(15.78, 0.05));
      // 12 / 5,46 = 2,20 h = 2 h 12 min.
      expect(e.hours, closeTo(2.198, 0.01));
      expect(e.detourFactor, closeTo(1.315, 0.01));
    });

    test('el resultado no depende de cómo se repartan los bordos', () {
      // Es la propiedad que permite resolverlo con una fórmula en vez de
      // simular una ruta: cualquier reparto válido tarda lo mismo.
      final e = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 0,
        twdDeg: twd,
        twsKn: 12,
      )!;
      final beat = dehler47.beatFor(12)!;
      expect(e.hours, closeTo(12 / beat.vmg, 1e-9));
    });

    test('apuntando: si se puede, no se alarga nada', () {
      final e = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 90, // través
        twdDeg: twd,
        twsKn: 12,
      )!;
      expect(e.mode, LegMode.lay);
      expect(e.sailedNm, closeTo(12, 1e-9));
      expect(e.detourFactor, closeTo(1, 1e-9));
      expect(e.sailAngle, closeTo(90, 1e-9));
      expect(e.madeGoodKn, closeTo(8.45, 0.01));
    });

    test('popa cerrada: también hay que zigzaguear', () {
      final e = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 180, // destino justo a sotavento
        twdDeg: twd,
        twsKn: 12,
      )!;
      expect(e.mode, LegMode.run);
      expect(e.sailedNm, greaterThan(12));
      expect(e.sailAngle, greaterThan(140));
    });

    test('el destino a un lado del viento sigue siendo ceñida', () {
      // 30° del viento está dentro del cono muerto: no se puede apuntar.
      final e = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 30,
        twdDeg: twd,
        twsKn: 12,
      )!;
      expect(e.mode, LegMode.beat);
      // Se alarga menos que yendo justo contra el viento.
      expect(e.sailedNm, lessThan(15.78));
      expect(e.sailedNm, greaterThan(12));
    });

    test('el porcentaje alarga el tiempo pero no el camino', () {
      // Un casco sucio quita nudos; no cambia la geometría del zigzag.
      final pleno = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 0,
        twdDeg: twd,
        twsKn: 12,
      )!;
      final real = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 0,
        twdDeg: twd,
        twsKn: 12,
        factorPercent: 85,
      )!;
      expect(real.sailedNm, closeTo(pleno.sailedNm, 1e-9));
      expect(real.sailAngle, closeTo(pleno.sailAngle, 1e-9));
      expect(real.hours, closeTo(pleno.hours / 0.85, 1e-6));
    });

    test('avisa cuando el viento se sale de la tabla', () {
      final e = computeLegEstimate(
        polar: dehler47,
        distanceNm: 12,
        bearingDeg: 0,
        twdDeg: twd,
        twsKn: 32,
      )!;
      expect(e.twsOutOfRange, isTrue);
    });

    test('sin viento no inventa una travesía', () {
      expect(
        computeLegEstimate(
          polar: dehler47,
          distanceNm: 12,
          bearingDeg: 0,
          twdDeg: twd,
          twsKn: 0,
        ),
        isNull,
      );
    });
  });

  group('importar una tabla .pol', () {
    test('lee el formato separado por tabuladores', () {
      const text =
          'TWA\t6\t10\t15\n'
          '52\t5.5\t7.4\t8.1\n'
          '90\t6.0\t8.1\t8.6\n'
          '150\t4.4\t6.6\t8.2\n';
      final t = parsePolarTable(text, id: 'mia', name: 'La mía')!;
      expect(t.tws, [6, 10, 15]);
      expect(t.twa, [52, 90, 150]);
      expect(t.speedAt(10, 90), closeTo(8.1, 1e-9));
    });

    test('acepta punto y coma con coma decimal', () {
      const text = 'twa;6;10\n52;5,5;7,4\n90;6,0;8,1\n';
      final t = parsePolarTable(text, id: 'eu')!;
      expect(t.speedAt(10, 90), closeTo(8.1, 1e-9));
    });

    test('un fichero que no es una polar no cuela', () {
      expect(parsePolarTable('hola mundo', id: 'x'), isNull);
      expect(parsePolarTable('', id: 'x'), isNull);
    });

    test('sobrevive a guardar y releer', () {
      final json = jsonDecode(jsonEncode(dehler47.toJson()));
      final back = PolarTable.fromJson(json as Map<String, dynamic>)!;
      expect(back.speedAt(12, 90), dehler47.speedAt(12, 90));
      expect(back.beatFor(12)!.angle, dehler47.beatFor(12)!.angle);
    });
  });
}
