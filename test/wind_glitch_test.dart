import 'package:flutter_test/flutter_test.dart';
import 'package:rewind_xcover6_panel/models.dart';

/// La racha que enseña la app es el máximo de las últimas horas, así que una
/// sola lectura corrupta de la veleta manda en la pantalla durante horas.
/// Caso real (QUINTO REAL, 2026-09-16): máximos de 44,5 y 55,8 kt en minutos
/// cuya media fue 12 y 13 kt. Una racha de verdad sube también la media.
void main() {
  group('windReadingIsImplausible', () {
    test('el pico suelto de la veleta se detecta', () {
      expect(
        windReadingIsImplausible(44.5, recentMeanKn: 12.1),
        isTrue,
        reason: 'medido en QUINTO REAL',
      );
      expect(windReadingIsImplausible(55.8, recentMeanKn: 13.3), isTrue);
    });

    test('una racha real no se descarta', () {
      // Racha fuerte pero proporcionada: 25 kt con 15 de media es viento.
      expect(windReadingIsImplausible(25, recentMeanKn: 15), isFalse);
      // Un temporal de verdad: la media ya es alta.
      expect(windReadingIsImplausible(58, recentMeanKn: 35), isFalse);
    });

    test('con viento flojo no basta con multiplicar', () {
      // De 2 a 6 kt es el triple, pero son 4 kt: una ráfaga normal en calma.
      expect(windReadingIsImplausible(6, recentMeanKn: 2), isFalse);
      // 20 kt con 2 de media sí es un salto imposible.
      expect(windReadingIsImplausible(20, recentMeanKn: 2), isTrue);
    });

    test('sin media conocida no se descarta nada', () {
      expect(windReadingIsImplausible(80, recentMeanKn: 0), isFalse);
    });

    test('los umbrales se pueden ajustar', () {
      expect(
        windReadingIsImplausible(30, recentMeanKn: 12, factor: 2, marginKn: 5),
        isTrue,
      );
      expect(
        windReadingIsImplausible(30, recentMeanKn: 12, factor: 4),
        isFalse,
      );
    });
  });

  group('plausibleGustPeak', () {
    final t0 = DateTime.utc(2026, 9, 16, 13);
    GraphPoint p(int minute, double kn) =>
        GraphPoint(time: t0.add(Duration(minutes: minute)), value: kn);

    test('descarta el pico del sensor y se queda con la racha real', () {
      // Minuto 8: 44,5 de máximo con 12,1 de media — el caso de QUINTO REAL.
      // Minuto 20: 24 de máximo con 18 de media — racha de verdad.
      final peak = plausibleGustPeak(
        maxima: [p(0, 14), p(8, 44.5), p(20, 24)],
        averages: [p(0, 12), p(8, 12.1), p(20, 18)],
      );
      expect(peak!.value, 24);
      expect(peak.time, t0.add(const Duration(minutes: 20)));
    });

    test('una racha real de 40 kt con 15 de media NO se pierde', () {
      // El caso que preocupa: la racha se dispara sobre la media de su
      // minuto, pero los minutos de al lado vienen altos porque el viento
      // está arreciando de verdad.
      final peak = plausibleGustPeak(
        maxima: [p(0, 22), p(1, 28), p(2, 40), p(3, 26), p(4, 24)],
        averages: [p(0, 14), p(1, 15), p(2, 15), p(3, 15), p(4, 14)],
      );
      expect(peak!.value, 40);
    });

    test('el mismo 40 kt aislado sí se descarta', () {
      // Idéntico valor y media, pero sin nada alrededor: eso es la veleta.
      final peak = plausibleGustPeak(
        maxima: [p(0, 15), p(1, 16), p(2, 40), p(3, 15), p(4, 16)],
        averages: [p(0, 14), p(1, 15), p(2, 15), p(3, 15), p(4, 14)],
      );
      expect(peak!.value, 16);
    });

    test('datos reales de QUINTO REAL: pico fuera, racha dentro', () {
      // Minutos 13:23-13:27 medidos: el pico de 55,8 con vecinos ~17.
      final peak = plausibleGustPeak(
        maxima: [p(0, 16.6), p(1, 17.3), p(2, 55.8), p(3, 16.2), p(4, 16.6)],
        averages: [p(0, 13), p(1, 13), p(2, 12.9), p(3, 13), p(4, 13)],
      );
      expect(peak!.value, 17.3);
    });

    test('un temporal de verdad en un día flojo NO se pierde', () {
      // Lo que fallaba al comparar contra la media de toda la ventana: la
      // borrasca dura poco, pero en su minuto la media también es alta.
      final peak = plausibleGustPeak(
        maxima: [p(0, 10), p(1, 11), p(2, 40), p(3, 12)],
        averages: [p(0, 8), p(1, 9), p(2, 33), p(3, 9)],
      );
      expect(peak!.value, 40);
    });

    test('sin medias no se descarta nada', () {
      final peak = plausibleGustPeak(
        maxima: [p(0, 14), p(8, 44.5)],
        averages: const [],
      );
      expect(peak!.value, 44.5, reason: 'mejor de más que perder una real');
    });

    test('sin datos no hay racha', () {
      expect(
        plausibleGustPeak(maxima: const [], averages: const []),
        isNull,
      );
    });
  });

  group('normalizeWindKn', () {
    test('sigue descartando lo imposible en términos absolutos', () {
      expect(normalizeWindKn(45), 45);
      expect(normalizeWindKn(kMaxPlausibleWindKn + 1), isNull);
      expect(normalizeWindKn(-1), isNull);
      expect(normalizeWindKn(double.nan), isNull);
    });

    test('por sí solo no habría evitado el caso real', () {
      // Justo el problema: 55,8 kt es "plausible" en absoluto, y aun así era
      // un pico del sensor. Por eso hace falta la regla relativa.
      expect(normalizeWindKn(55.8), 55.8);
      expect(windReadingIsImplausible(55.8, recentMeanKn: 13.3), isTrue);
    });
  });
}
