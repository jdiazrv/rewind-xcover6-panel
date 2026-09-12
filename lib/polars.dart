import 'dart:convert';
import 'dart:math' as math;

import 'models.dart' show normalizeRelativeAngle;

/// Polar de un barco: qué velocidad da a cada combinación de viento real
/// (TWS) y ángulo al viento (TWA).
///
/// Las tablas salen de los certificados ORC, que dan una rejilla gruesa
/// (8 ángulos × 7-9 velocidades) más los ángulos y VMG óptimos de ceñida y
/// empopada ya resueltos por su VPP. Eso último es importante: la rejilla
/// empieza en 52°, así que TODO lo que pasa ciñendo — que es justo donde
/// la polar se usa para decidir algo — vive por debajo de la tabla y
/// saldría de una extrapolación inventada si no fuera por esos valores.
class PolarTable {
  const PolarTable({
    required this.id,
    required this.name,
    required this.tws,
    required this.twa,
    required this.speeds,
    this.year,
    this.loa,
    this.ref,
    this.beatAngle = const [],
    this.beatVmg = const [],
    this.runAngle = const [],
    this.runVmg = const [],
  });

  final String id;
  final String name;
  final int? year;
  final double? loa;

  /// De dónde sale la tabla, p. ej. "NED/NED7928". Se enseña en CFG para
  /// que se sepa que es un certificado concreto de un barco concreto y no
  /// una verdad universal del modelo.
  final String? ref;

  /// Velocidades de viento real de la tabla, en nudos, ascendentes.
  final List<double> tws;

  /// Ángulos al viento de la tabla, en grados, ascendentes.
  final List<double> twa;

  /// Velocidad del barco en nudos: `speeds[índice de twa][índice de tws]`.
  final List<List<double>> speeds;

  /// Óptimos por cada TWS. Pueden venir vacíos (una tabla `.pol` importada
  /// no los trae) y entonces se calculan barriendo la curva.
  final List<double> beatAngle;
  final List<double> beatVmg;
  final List<double> runAngle;
  final List<double> runVmg;

  bool get isValid =>
      tws.length >= 2 &&
      twa.length >= 2 &&
      speeds.length == twa.length &&
      speeds.every((r) => r.length == tws.length);

  double get minTws => tws.first;
  double get maxTws => tws.last;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// Interpola una lista indexada por TWS. Fuera de la tabla se pega al
  /// extremo en vez de extrapolar: una polar no dice nada de lo que pasa
  /// con 35 nudos, y fingir que sí sería peor que quedarse corto.
  static double? _atTws(List<double> values, List<double> tws, double v) {
    if (values.length != tws.length || values.isEmpty) return null;
    if (v <= tws.first) return values.first;
    if (v >= tws.last) return values.last;
    for (var i = 0; i < tws.length - 1; i++) {
      if (v <= tws[i + 1]) {
        final t = (v - tws[i]) / (tws[i + 1] - tws[i]);
        return _lerp(values[i], values[i + 1], t);
      }
    }
    return values.last;
  }

  /// ¿Está [twsKn] fuera del rango medido? El dato sigue sirviendo, pero
  /// la pantalla debe decirlo.
  bool twsOutOfRange(double twsKn) => twsKn < minTws || twsKn > maxTws;

  /// La curva de velocidad para un viento dado, como pares (ángulo,
  /// velocidad) ordenados por ángulo, con los extremos de ceñida y
  /// empopada incluidos.
  List<(double, double)> curveFor(double twsKn) {
    final points = <(double, double)>[];
    final beat = beatFor(twsKn);
    if (beat != null) {
      final c = math.cos(beat.angle * math.pi / 180);
      if (c > 0.01) points.add((beat.angle, beat.vmg / c));
    }
    for (var i = 0; i < twa.length; i++) {
      final v = _atTws(speeds[i], tws, twsKn);
      if (v != null) points.add((twa[i], v));
    }
    final run = runFor(twsKn);
    if (run != null) {
      final c = math.cos(run.angle * math.pi / 180).abs();
      if (c > 0.01) points.add((run.angle, run.vmg / c));
    }
    points.sort((a, b) => a.$1.compareTo(b.$1));
    return points;
  }

  /// Velocidad objetivo a este viento y este ángulo, en nudos.
  ///
  /// Devuelve null fuera del abanico navegable: por debajo del ángulo de
  /// ceñida el barco no avanza, y por encima del de empopada tampoco —
  /// decirlo es más honesto que interpolar hacia cero.
  double? speedAt(double twsKn, double twaDeg) {
    if (!isValid) return null;
    final a = normalizeRelativeAngle(twaDeg).abs();
    final curve = curveFor(twsKn);
    if (curve.length < 2) return null;
    if (a < curve.first.$1 || a > curve.last.$1) return null;
    for (var i = 0; i < curve.length - 1; i++) {
      if (a <= curve[i + 1].$1) {
        final (a0, v0) = curve[i];
        final (a1, v1) = curve[i + 1];
        if (a1 == a0) return v0;
        return _lerp(v0, v1, (a - a0) / (a1 - a0));
      }
    }
    return curve.last.$2;
  }

  /// Ceñida óptima: el ángulo que más te acerca al viento por unidad de
  /// tiempo, y ese avance (VMG).
  ({double angle, double vmg})? beatFor(double twsKn) {
    if (beatAngle.length == tws.length && beatVmg.length == tws.length) {
      final a = _atTws(beatAngle, tws, twsKn);
      final v = _atTws(beatVmg, tws, twsKn);
      if (a != null && v != null && v > 0) return (angle: a, vmg: v);
    }
    return _sweep(twsKn, upwind: true);
  }

  /// Empopada óptima, el simétrico de [beatFor].
  ({double angle, double vmg})? runFor(double twsKn) {
    if (runAngle.length == tws.length && runVmg.length == tws.length) {
      final a = _atTws(runAngle, tws, twsKn);
      final v = _atTws(runVmg, tws, twsKn);
      if (a != null && v != null && v > 0) return (angle: a, vmg: v);
    }
    return _sweep(twsKn, upwind: false);
  }

  /// Busca el máximo VMG barriendo la tabla grado a grado. Solo hace falta
  /// para polares importadas que no traen los óptimos; con las de ORC se
  /// usan los suyos, que salen de su propio VPP y son mejores que esto.
  ({double angle, double vmg})? _sweep(double twsKn, {required bool upwind}) {
    if (!isValid) return null;
    // Sin los extremos: se están calculando justamente ellos.
    final base = <(double, double)>[];
    for (var i = 0; i < twa.length; i++) {
      final v = _atTws(speeds[i], tws, twsKn);
      if (v != null) base.add((twa[i], v));
    }
    if (base.length < 2) return null;
    double? bestAngle;
    var bestVmg = 0.0;
    final from = upwind ? base.first.$1 : 90.0;
    final to = upwind ? 90.0 : base.last.$1;
    for (var a = from; a <= to; a += 0.5) {
      double? v;
      for (var i = 0; i < base.length - 1; i++) {
        if (a >= base[i].$1 && a <= base[i + 1].$1) {
          final (a0, v0) = base[i];
          final (a1, v1) = base[i + 1];
          v = a1 == a0 ? v0 : _lerp(v0, v1, (a - a0) / (a1 - a0));
          break;
        }
      }
      if (v == null) continue;
      final made = v * math.cos(a * math.pi / 180);
      final score = upwind ? made : -made;
      if (score > bestVmg) {
        bestVmg = score;
        bestAngle = a;
      }
    }
    if (bestAngle == null || bestVmg <= 0) return null;
    return (angle: bestAngle, vmg: bestVmg);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (year != null) 'year': year,
    if (loa != null) 'loa': loa,
    if (ref != null) 'ref': ref,
    'tws': tws,
    'twa': twa,
    'speeds': speeds,
    if (beatAngle.isNotEmpty) 'beatAngle': beatAngle,
    if (beatVmg.isNotEmpty) 'beatVmg': beatVmg,
    if (runAngle.isNotEmpty) 'runAngle': runAngle,
    if (runVmg.isNotEmpty) 'runVmg': runVmg,
  };

  static List<double> _nums(dynamic v) => [
    for (final x in (v as List? ?? const [])) (x as num).toDouble(),
  ];

  static PolarTable? fromJson(Map<String, dynamic> j) {
    try {
      final t = PolarTable(
        id: j['id'] as String,
        name: j['name'] as String,
        year: (j['year'] as num?)?.toInt(),
        loa: (j['loa'] as num?)?.toDouble(),
        ref: j['ref'] as String?,
        tws: _nums(j['tws']),
        twa: _nums(j['twa']),
        speeds: [for (final r in (j['speeds'] as List)) _nums(r)],
        beatAngle: _nums(j['beatAngle']),
        beatVmg: _nums(j['beatVmg']),
        runAngle: _nums(j['runAngle']),
        runVmg: _nums(j['runVmg']),
      );
      return t.isValid ? t : null;
    } catch (_) {
      return null;
    }
  }

  /// Lee el recurso con las polares empotradas.
  static List<PolarTable> listFromAsset(String source) {
    try {
      final doc = jsonDecode(source) as Map<String, dynamic>;
      return [
        for (final b in (doc['boats'] as List))
          ?fromJson(b as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// Lee el formato de tabla de toda la vida: primera fila con las
/// velocidades de viento, y una fila por ángulo.
///
/// Acepta tabulador, punto y coma o coma como separador. Con punto y coma
/// se admite además la coma decimal, que es como los escriben media
/// Europa y los exporta qtVlm.
PolarTable? parsePolarTable(String text, {required String id, String? name}) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
  if (lines.length < 2) return null;

  final semicolon = lines.first.contains(';');
  List<String> cells(String line) => line
      .split(semicolon ? ';' : RegExp(r'[\t,]|\s{1,}'))
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();
  double? num_(String s) {
    final cleaned = semicolon ? s.replaceAll(',', '.') : s;
    return double.tryParse(cleaned);
  }

  final header = cells(lines.first);
  if (header.length < 3) return null;
  // La primera celda suele ser un rótulo ("twa/tws", "TWA") pero algunos
  // ficheros abren directamente con la primera velocidad.
  final headerNums = [for (final h in header) num_(h)];
  final skipFirst = headerNums.first == null;
  final tws = [
    for (final v in headerNums.skip(skipFirst ? 1 : 0)) ?v,
  ];
  if (tws.length < 2) return null;

  final twa = <double>[];
  final speeds = <List<double>>[];
  for (final line in lines.skip(1)) {
    final c = cells(line);
    if (c.length < tws.length + 1) continue;
    final a = num_(c.first);
    if (a == null) continue;
    final row = [
      for (final s in c.skip(1).take(tws.length)) num_(s) ?? 0.0,
    ];
    if (row.length != tws.length) continue;
    twa.add(a);
    speeds.add(row);
  }
  if (twa.length < 2) return null;

  final table = PolarTable(
    id: id,
    name: name ?? id,
    tws: tws,
    twa: twa,
    speeds: speeds,
  );
  return table.isValid ? table : null;
}

/// Cómo se llega al destino: apuntando, ciñendo en bordos o trasluchando.
enum LegMode { lay, beat, run }

/// Lo que cuesta el tramo hasta el destino con esta polar y este viento.
class LegEstimate {
  const LegEstimate({
    required this.mode,
    required this.sailedNm,
    required this.hours,
    required this.sailAngle,
    required this.madeGoodKn,
    required this.directNm,
    required this.twsOutOfRange,
  });

  final LegMode mode;

  /// Millas que se navegan de verdad. Ciñendo son más que las directas.
  final double sailedNm;
  final double hours;

  /// TWA al que hay que navegar: la demora misma si se puede apuntar, o
  /// el ángulo óptimo si hay que dar bordos.
  final double sailAngle;

  /// Avance hacia el destino, en nudos.
  final double madeGoodKn;
  final double directNm;

  /// El viento está fuera del rango de la tabla y el resultado se ha
  /// calculado con su extremo.
  final bool twsOutOfRange;

  bool get isZigzag => mode != LegMode.lay;

  /// Cuánto se alarga el camino respecto a la línea recta.
  double get detourFactor => directNm <= 0 ? 1 : sailedNm / directNm;
}

/// Tiempo y distancia reales hasta un destino, contando los bordos.
///
/// La clave es que, ciñendo, el resultado NO depende de cuántos bordos se
/// den ni de cómo se repartan: descomponiendo el trayecto en el eje del
/// viento, el tiempo total sale `distancia · cos(α) / VMG`, donde α es el
/// ángulo entre la demora al destino y el viento. Dos bordos largos o diez
/// cortos tardan lo mismo. Por eso basta una fórmula y no hace falta
/// simular ninguna ruta.
///
/// [factorPercent] escala solo la VELOCIDAD, nunca los ángulos: un casco
/// sucio o unas velas cansadas quitan nudos, pero el ángulo óptimo de
/// ceñida apenas se mueve.
LegEstimate? computeLegEstimate({
  required PolarTable polar,
  required double distanceNm,
  required double bearingDeg,
  required double twdDeg,
  required double twsKn,
  double factorPercent = 100,
}) {
  if (!polar.isValid || distanceNm <= 0 || twsKn <= 0) return null;
  final factor = (factorPercent / 100).clamp(0.1, 1.5);
  final outOfRange = polar.twsOutOfRange(twsKn);

  // El TWA que habría que navegar para apuntar al destino.
  final alpha = normalizeRelativeAngle(bearingDeg - twdDeg).abs();
  final rad = alpha * math.pi / 180;

  final beat = polar.beatFor(twsKn);
  final run = polar.runFor(twsKn);

  if (beat != null && alpha < beat.angle) {
    final along = distanceNm * math.cos(rad);
    final vmg = beat.vmg * factor;
    if (vmg <= 0) return null;
    final cosBeat = math.cos(beat.angle * math.pi / 180);
    return LegEstimate(
      mode: LegMode.beat,
      sailedNm: cosBeat <= 0.01 ? along : along / cosBeat,
      hours: along / vmg,
      sailAngle: beat.angle,
      madeGoodKn: vmg,
      directNm: distanceNm,
      twsOutOfRange: outOfRange,
    );
  }

  if (run != null && alpha > run.angle) {
    final along = distanceNm * -math.cos(rad);
    final vmg = run.vmg * factor;
    if (vmg <= 0) return null;
    final cosRun = math.cos(run.angle * math.pi / 180).abs();
    return LegEstimate(
      mode: LegMode.run,
      sailedNm: cosRun <= 0.01 ? along : along / cosRun,
      hours: along / vmg,
      sailAngle: run.angle,
      madeGoodKn: vmg,
      directNm: distanceNm,
      twsOutOfRange: outOfRange,
    );
  }

  final v = polar.speedAt(twsKn, alpha);
  if (v == null || v <= 0) return null;
  final speed = v * factor;
  return LegEstimate(
    mode: LegMode.lay,
    sailedNm: distanceNm,
    hours: distanceNm / speed,
    sailAngle: alpha,
    madeGoodKn: speed,
    directNm: distanceNm,
    twsOutOfRange: outOfRange,
  );
}
