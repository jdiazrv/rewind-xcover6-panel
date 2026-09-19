// Viento aparente y mar encontrada: lo que el barco realmente ve en cada
// punto de la ruta, no solo lo que dice el modelo.
//
// Ambos cálculos son vectoriales y deterministas, sin nada aprendido ni
// ajustado a ojo: se documentan aquí exactamente para poder auditarlos.

import 'dart:math' as math;

import '../angles.dart';
import '../polars.dart';

/// Viento aparente a partir del verdadero y del rumbo/velocidad del barco.
///
/// Se suman como vectores en la superficie (este, norte): el aparente es
/// el verdadero menos la velocidad del barco. [awaDeg] sale con signo
/// (+ = por estribor, − = por babor), igual que se lee en la bitácora.
({double awsKn, double awaDeg}) apparentWind({
  required double twsKn,
  required double twdDeg,
  required double headingDeg,
  required double stwKn,
}) {
  // Componentes del viento verdadero hacia donde SOPLA.
  final wr = twdDeg * math.pi / 180;
  final wu = -twsKn * math.sin(wr), wv = -twsKn * math.cos(wr);
  // Velocidad del barco sobre el fondo (se ignora la deriva: sin corriente
  // en el modelo de tiempo, STW y SOG coinciden aquí).
  final hr = headingDeg * math.pi / 180;
  final bu = stwKn * math.sin(hr), bv = stwKn * math.cos(hr);
  // Aparente = verdadero − barco, en el marco del suelo.
  final au = wu - bu, av = wv - bv;
  final aws = math.sqrt(au * au + av * av);
  // De dónde VIENE el aparente.
  final awFromDeg = (math.atan2(-au, -av) * 180 / math.pi + 360) % 360;
  final awa = normalizeRelativeAngle(awFromDeg - headingDeg);
  return (awsKn: aws, awaDeg: awa);
}

/// TWA (ángulo al viento verdadero) sin signo, 0–180°, como lo usa la
/// polar: 0 = viento de proa, 180 = viento de popa.
double trueWindAngle(double headingDeg, double twdDeg) =>
    normalizeRelativeAngle(headingDeg - twdDeg).abs();

/// La ola que encuentra el barco: mismo Hs que da el modelo (no se
/// inventa una altura nueva por cambiar de rumbo — el oleaje no crece ni
/// mengua porque el barco gire), pero el PERIODO con el que se sienten
/// los golpes sí cambia con el rumbo. Es el "periodo de encuentro",
/// clásico de la mar de olas:
///
///   c  = g·T / (2π)                    (celeridad en aguas profundas)
///   Te = T / |1 + (V/c)·cos(μ)|        (periodo de encuentro)
///
/// donde μ es el ángulo entre el rumbo del barco y de dónde VIENEN las
/// olas (0° = mar de proa, 180° = mar de popa — igual que el TWA), V la
/// velocidad del barco y g = 9,81 m/s². A proa el periodo se acorta (más
/// golpes por minuto); a popa se alarga (se "surfea"). Cerca de |1+…| = 0
/// (popa a la misma velocidad que la ola) el periodo de encuentro no está
/// definido — null, no un número inventado.
({double angleDeg, double? periodS}) waveEncounter({
  required double headingDeg,
  required double stwKn,
  required double waveFromDeg,
  required double wavePeriodS,
}) {
  final mu = normalizeRelativeAngle(headingDeg - waveFromDeg).abs();
  if (wavePeriodS <= 0) return (angleDeg: mu, periodS: null);
  const g = 9.81;
  final c = g * wavePeriodS / (2 * math.pi);
  final v = stwKn * 0.514444; // kn → m/s
  final denom = (1 + (v / c) * math.cos(mu * math.pi / 180)).abs();
  if (denom < 0.08) return (angleDeg: mu, periodS: null);
  return (angleDeg: mu, periodS: wavePeriodS / denom);
}

/// El AWA que le corresponde a ESTA polar en su propia ceñida óptima,
/// promediado en todo su rango de viento — no hay un número universal de
/// "hasta dónde cierra una vela": un barco rápido cierra más que uno
/// lento con la misma polar de ángulos. Sirve para proponer un
/// `minimumAwaDeg` de arranque razonable (editable después) en vez de
/// uno inventado igual para todos los barcos.
double? polarTypicalBeatAwaDeg(PolarTable polar) {
  if (!polar.isValid) return null;
  var sum = 0.0;
  var n = 0;
  for (final tws in polar.tws) {
    final beat = polar.beatFor(tws);
    if (beat == null || beat.vmg <= 0) continue;
    final cosA = math.cos(beat.angle * math.pi / 180);
    if (cosA <= 0.05) continue;
    final stw = beat.vmg / cosA; // VMG → velocidad real en ese rumbo
    final aw = apparentWind(
      twsKn: tws,
      twdDeg: 0,
      headingDeg: beat.angle,
      stwKn: stw,
    );
    sum += aw.awaDeg.abs();
    n++;
  }
  if (n == 0) return null;
  return sum / n;
}

/// Nombre corto del sector de mar, para la etiqueta: 0°/360° proa, 180°
/// popa, 90°/270° a través.
String waveSectorLabel(double encounterAngleDeg) {
  final a = encounterAngleDeg.abs();
  if (a <= 30) return 'de proa';
  if (a <= 60) return 'de amura';
  if (a <= 120) return 'de través';
  if (a <= 150) return 'de aleta';
  return 'de popa';
}
