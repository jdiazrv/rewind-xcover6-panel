import 'dart:math' as math;

/// Punto digitalizado de la curva de consumo con carga de hélice.
///
/// No es la curva de plena carga del banco. Los fabricantes publican esta
/// curva como "propeller load", normalmente con exponente 3, para representar
/// la potencia que absorbe una hélice correctamente dimensionada al avanzar.
class EngineFuelPoint {
  const EngineFuelPoint(this.rpm, this.litersPerHour);

  final double rpm;
  final double litersPerHour;
}

class EngineFuelProfile {
  const EngineFuelProfile({
    required this.id,
    required this.label,
    required this.curve,
    required this.sourceLabel,
    required this.sourceUrl,
  });

  final String id;
  final String label;
  final List<EngineFuelPoint> curve;
  final String sourceLabel;
  final String sourceUrl;

  double get maxRpm => curve.last.rpm;

  /// Interpolación lineal entre puntos de la curva de hélice del fabricante.
  /// El ajuste es deliberadamente explícito: no se aplican coeficientes
  /// ocultos por saildrive, eje o tipo de hélice, que sin diámetro/paso/casco
  /// serían inventados.
  double estimateLitersPerHour(double rpm, {double calibrationPercent = 100}) {
    if (!rpm.isFinite || rpm <= 200) return 0;
    final calibration = calibrationPercent.clamp(70, 130) / 100;
    final x = rpm.clamp(curve.first.rpm, curve.last.rpm).toDouble();
    for (var i = 1; i < curve.length; i++) {
      final b = curve[i];
      if (x > b.rpm) continue;
      final a = curve[i - 1];
      final span = b.rpm - a.rpm;
      final fraction = span <= 0 ? 0.0 : (x - a.rpm) / span;
      return math.max(
        0,
        (a.litersPerHour + (b.litersPerHour - a.litersPerHour) * fraction) *
            calibration,
      );
    }
    return curve.last.litersPerHour * calibration;
  }
}

// Curvas de consumo CON CARGA DE HÉLICE, no consumos de plena carga en banco.
// Los puntos intermedios están digitalizados/redondeados de los gráficos del
// fabricante. D1-13/D1-20, cuya tabla completa no está disponible en la ficha
// recuperada, se identifican como estimación exp. 3. La interfaz presenta
// siempre el resultado como aproximación.
const engineFuelProfiles = <EngineFuelProfile>[
  EngineFuelProfile(
    id: 'yanmar-4jh4-te',
    label: 'Yanmar 4JH4-TE',
    sourceLabel: 'Yanmar · propeller load exp. 3',
    sourceUrl: 'https://www.yanmar.com/marine/wp-content/uploads/2021/02/DS_4JH4-TE_A4_052022_HR.pdf',
    curve: [
      EngineFuelPoint(800, 0.6),
      EngineFuelPoint(1200, 1.0),
      EngineFuelPoint(1600, 2.0),
      EngineFuelPoint(2000, 4.0),
      EngineFuelPoint(2400, 7.2),
      EngineFuelPoint(2800, 11.6),
      EngineFuelPoint(3200, 16.0),
      EngineFuelPoint(3300, 16.5),
    ],
  ),
  EngineFuelProfile(
    id: 'yanmar-4jh5e',
    label: 'Yanmar 4JH5E',
    sourceLabel: 'Yanmar · propeller load exp. 3',
    sourceUrl: 'https://www.yanmar.com/marine/product/engines/4jh5e/',
    curve: [
      EngineFuelPoint(800, 0.5),
      EngineFuelPoint(1200, 0.8),
      EngineFuelPoint(1600, 1.7),
      EngineFuelPoint(2000, 3.2),
      EngineFuelPoint(2400, 5.7),
      EngineFuelPoint(2700, 8.0),
      EngineFuelPoint(3000, 10.5),
    ],
  ),
  EngineFuelProfile(
    id: 'volvo-d1-13',
    label: 'Volvo Penta D1-13',
    sourceLabel: 'Volvo Penta · estimated propeller load exp. 3',
    sourceUrl: 'https://www.volvopenta.com/-/media/volvopenta/marine/products/repowering/d1-d2-installation-repower-s-drive.pdf',
    curve: [
      EngineFuelPoint(800, 0.35),
      EngineFuelPoint(1200, 0.45),
      EngineFuelPoint(1600, 0.7),
      EngineFuelPoint(2000, 1.0),
      EngineFuelPoint(2400, 1.5),
      EngineFuelPoint(2800, 2.2),
      EngineFuelPoint(3200, 3.1),
    ],
  ),
  EngineFuelProfile(
    id: 'volvo-d1-20',
    label: 'Volvo Penta D1-20',
    sourceLabel: 'Volvo Penta · estimated propeller load exp. 3',
    sourceUrl: 'https://www.volvopenta.com/-/media/volvopenta/marine/products/repowering/d1-d2-installation-repower-s-drive.pdf',
    curve: [
      EngineFuelPoint(800, 0.4),
      EngineFuelPoint(1200, 0.55),
      EngineFuelPoint(1600, 0.85),
      EngineFuelPoint(2000, 1.3),
      EngineFuelPoint(2400, 2.1),
      EngineFuelPoint(2800, 3.2),
      EngineFuelPoint(3200, 4.7),
    ],
  ),
  EngineFuelProfile(
    id: 'volvo-d1-30',
    label: 'Volvo Penta D1-30',
    sourceLabel: 'Volvo Penta · calculated propeller load exp. 3',
    sourceUrl: 'https://www.volvopenta.com/-/media/volvopenta/marine/products/repowering/d1-d2-installation-repower-s-drive.pdf',
    curve: [
      EngineFuelPoint(800, 0.5),
      EngineFuelPoint(1200, 0.8),
      EngineFuelPoint(1400, 1.0),
      EngineFuelPoint(1600, 0.9),
      EngineFuelPoint(1800, 1.5),
      EngineFuelPoint(2000, 1.9),
      EngineFuelPoint(2200, 2.4),
      EngineFuelPoint(2400, 2.9),
      EngineFuelPoint(2600, 3.6),
      EngineFuelPoint(2800, 4.4),
      EngineFuelPoint(3000, 5.5),
      EngineFuelPoint(3200, 6.7),
    ],
  ),
  EngineFuelProfile(
    id: 'volvo-d2-55',
    label: 'Volvo Penta D2-55',
    sourceLabel: 'Volvo Penta · calculated propeller load exp. 3',
    sourceUrl: 'https://www.coastalmarineengine.com/fckimages/pdf/volvo-penta-inboard-engines/my14_d2-55.pdf',
    curve: [
      EngineFuelPoint(800, 0.55),
      EngineFuelPoint(1200, 0.9),
      EngineFuelPoint(1600, 1.9),
      EngineFuelPoint(2000, 3.8),
      EngineFuelPoint(2400, 6.8),
      EngineFuelPoint(2700, 9.8),
      EngineFuelPoint(3000, 13.5),
    ],
  ),
  EngineFuelProfile(
    id: 'volvo-d2-60',
    label: 'Volvo Penta D2-60',
    sourceLabel: 'Volvo Penta · calculated propeller load exp. 3',
    sourceUrl:
        'https://irp-cdn.multiscreensite.com/6566baff/files/uploaded/D2-60.pdf',
    curve: [
      EngineFuelPoint(800, 0.6),
      EngineFuelPoint(1200, 0.9),
      EngineFuelPoint(1600, 2.1),
      EngineFuelPoint(2000, 4.2),
      EngineFuelPoint(2400, 7.6),
      EngineFuelPoint(2700, 10.9),
      EngineFuelPoint(3000, 15.0),
    ],
  ),
  EngineFuelProfile(
    id: 'volvo-d2-75',
    label: 'Volvo Penta D2-75',
    sourceLabel: 'Volvo Penta · calculated propeller load exp. 3',
    sourceUrl:
        'https://irp-cdn.multiscreensite.com/6566baff/files/uploaded/D2-75.pdf',
    curve: [
      EngineFuelPoint(800, 0.65),
      EngineFuelPoint(1200, 1.2),
      EngineFuelPoint(1600, 2.7),
      EngineFuelPoint(2000, 5.3),
      EngineFuelPoint(2400, 9.5),
      EngineFuelPoint(2700, 13.8),
      EngineFuelPoint(3000, 18.8),
    ],
  ),
];

EngineFuelProfile? engineFuelProfileById(String id) {
  for (final profile in engineFuelProfiles) {
    if (profile.id == id) return profile;
  }
  return null;
}
