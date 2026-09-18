// Motor de weather routing: isócronas cada 15 min, rumbos cada 5°, con
// vela/motor decidido en el propio cálculo — no pintado encima después.
//
// Dart puro, sin Flutter: se llama desde la pantalla con `compute()`
// (aísla el trabajo en su propio isolate) y se prueba sin red ni widgets.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import '../models.dart' show normalizeRelativeAngle;
import '../polars.dart';
import 'geo.dart';
import 'land_mask.dart';
import 'sailing_calc.dart';
import 'weather.dart';

/// Cada 15 min, como pide el encargo: con más margen las isócronas se
/// desdibujan, con menos el cálculo se dispara sin mejorar la ruta.
const kIsochroneStepMinutes = 15;

/// Rumbos candidatos cada 5°.
const kHeadingStepDeg = 5.0;

/// Isócronas partidas en sectores de este ancho para la poda.
const kPruneSectorDeg = 5.0;

enum PropulsionMode { sailing, motor }

enum RoutingObjective {
  fast('Rápido'),
  comfort('Confort'),
  custom('Personalizado');

  const RoutingObjective(this.label);
  final String label;
}

/// Restricciones del encargo. `minimumSailingSTW` decide vela/motor: por
/// debajo, y si el motor está permitido, se motora. `preferredMaxWaveM`/
/// `absoluteMaxWaveM` son un aviso y un tope duro, no el mismo límite.
class RoutingConstraints {
  const RoutingConstraints({
    this.minimumSailingSTW = 4.0,
    this.allowMotor = true,
    this.motorSpeedKn = 5.5,
    this.maxAwsKn = 25,
    this.preferredMaxWaveM = 0.60,
    this.absoluteMaxWaveM = 1.00,
    this.maxTimeAbovePreferred = const Duration(minutes: 60),
    this.minimumCoastDistanceNm = 0.5,
    this.minimumAwaDeg = 30,
  });

  final double minimumSailingSTW;
  final bool allowMotor;
  final double motorSpeedKn;
  final double maxAwsKn;
  final double preferredMaxWaveM;
  final double absoluteMaxWaveM;
  final Duration maxTimeAbovePreferred;

  /// El aparente que la polar diría que "vale" a un TWA puede salir, a
  /// velocidad real, más cerrado de lo que las velas trimarían de
  /// verdad. Por debajo de este AWA, ese rumbo no es una opción a vela
  /// aunque la polar tenga dato ahí. 30° por defecto.
  final double minimumAwaDeg;

  /// Reservado para la máscara de costa (fase futura): hoy no hay
  /// polígonos de tierra en el motor, así que este margen no se aplica
  /// todavía. Se deja en la clase para no cambiar la firma cuando llegue.
  final double minimumCoastDistanceNm;

  RoutingConstraints copyWith({
    double? minimumSailingSTW,
    bool? allowMotor,
    double? motorSpeedKn,
    double? maxAwsKn,
    double? preferredMaxWaveM,
    double? absoluteMaxWaveM,
  }) => RoutingConstraints(
    minimumSailingSTW: minimumSailingSTW ?? this.minimumSailingSTW,
    allowMotor: allowMotor ?? this.allowMotor,
    motorSpeedKn: motorSpeedKn ?? this.motorSpeedKn,
    maxAwsKn: maxAwsKn ?? this.maxAwsKn,
    preferredMaxWaveM: preferredMaxWaveM ?? this.preferredMaxWaveM,
    absoluteMaxWaveM: absoluteMaxWaveM ?? this.absoluteMaxWaveM,
    maxTimeAbovePreferred: maxTimeAbovePreferred,
  );
}

/// Un tramo de 15 min de la ruta ya resuelta, con todo lo que el panel de
/// instrumentos necesita enseñar en ese instante.
class RouteSegment {
  const RouteSegment({
    required this.waypointIndex,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
    required this.startTime,
    required this.endTime,
    required this.headingDeg,
    required this.distanceNm,
    required this.mode,
    required this.stwKn,
    required this.twsKn,
    required this.twdDeg,
    required this.twaDeg,
    required this.awsKn,
    required this.awaDeg,
    this.waveHeightM,
    this.waveDirDeg,
    this.wavePeriodS,
    this.waveEncounterAngleDeg,
    this.waveEncounterPeriodS,
  });

  /// Índice de la pierna (0 = del punto 0 al 1, etc.), para saber a qué
  /// tramo de la ruta de hasta 10 puntos pertenece.
  final int waypointIndex;

  final double startLat, startLon, endLat, endLon;
  final DateTime startTime, endTime;
  final double headingDeg;
  final double distanceNm;
  final PropulsionMode mode;

  final double stwKn;
  final double twsKn, twdDeg, twaDeg;
  final double awsKn, awaDeg;

  /// Hs del MODELO en este tramo — nunca se toca por el rumbo.
  final double? waveHeightM, waveDirDeg, wavePeriodS;

  /// La ola tal como la encuentra el barco: mismo Hs, pero con el ángulo
  /// y el periodo de encuentro (ver [waveEncounter] en sailing_calc.dart).
  final double? waveEncounterAngleDeg, waveEncounterPeriodS;

  Duration get duration => endTime.difference(startTime);

  /// Punto interpolado dentro del tramo, para mover el barco con fluidez
  /// entre isócronas de 15 min.
  ({double lat, double lon}) positionAt(double frac) {
    final f = frac.clamp(0.0, 1.0);
    return (
      lat: startLat + (endLat - startLat) * f,
      lon: startLon + (endLon - startLon) * f,
    );
  }
}

/// Ruta resuelta de un punto de salida a uno de llegada, con hasta 8
/// puntos intermedios entre ambos (10 en total).
class RouteResult {
  const RouteResult({
    required this.segments,
    required this.waypoints,
    required this.reachedIndex,
    this.warning,
  });

  final List<RouteSegment> segments;

  /// Los puntos pedidos, tal cual: [0]=salida, [last]=llegada.
  final List<({double lat, double lon})> waypoints;

  /// Hasta qué punto (índice en [waypoints]) se llegó de verdad. Si es
  /// `waypoints.length - 1` la ruta completa cuadra; si es menor, el
  /// motor se quedó sin candidatos viables antes de la llegada y
  /// [warning] lo explica.
  final int reachedIndex;
  final String? warning;

  bool get complete => reachedIndex == waypoints.length - 1;

  double get totalNm => [for (final s in segments) s.distanceNm].fold(
    0.0,
    (a, b) => a + b,
  );

  Duration get totalDuration => segments.isEmpty
      ? Duration.zero
      : segments.last.endTime.difference(segments.first.startTime);

  DateTime? get departure => segments.isEmpty ? null : segments.first.startTime;
  DateTime? get eta => segments.isEmpty ? null : segments.last.endTime;

  /// El tramo activo en [t], o null si [t] cae fuera de la ruta.
  RouteSegment? segmentAt(DateTime t) {
    if (segments.isEmpty) return null;
    if (t.isBefore(segments.first.startTime)) return null;
    if (!t.isBefore(segments.last.endTime)) return segments.last;
    for (final s in segments) {
      if (!t.isBefore(s.startTime) && t.isBefore(s.endTime)) return s;
    }
    return null;
  }

  /// La posición del barco en [t], interpolada dentro de su tramo.
  ({double lat, double lon})? positionAt(DateTime t) {
    final s = segmentAt(t);
    if (s == null) return null;
    final total = s.duration.inSeconds;
    final f = total <= 0
        ? 1.0
        : t.difference(s.startTime).inSeconds / total;
    return s.positionAt(f);
  }
}

class RoutingException implements Exception {
  RoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lo que necesita `compute()` para correr el motor en su propio isolate:
/// todo dato plano, nada con callbacks ni contexto de Flutter.
class RouteRequest {
  const RouteRequest({
    required this.waypoints,
    required this.departure,
    required this.grid,
    required this.polar,
    required this.polarFactorPercent,
    required this.constraints,
    required this.objective,
    this.land,
  });

  final List<({double lat, double lon})> waypoints;
  final DateTime departure;
  final WeatherGrid grid;
  final PolarTable polar;
  final double polarFactorPercent;
  final RoutingConstraints constraints;
  final RoutingObjective objective;

  /// null o vacía = sin máscara de costa (la ruta se calcula igual, solo
  /// sin evitar tierra).
  final LandMask? land;
}

/// Punto de entrada para `compute()`. Debe ser una función de nivel
/// superior (no un método) para poder cruzar a otro isolate.
RouteResult computeRoute(RouteRequest req, {void Function(double)? onProgress}) {
  if (req.waypoints.length < 2) {
    throw RoutingException('Hacen falta salida y llegada');
  }
  if (req.waypoints.length > 10) {
    throw RoutingException('Máximo 10 puntos');
  }
  if (!req.polar.isValid) {
    throw RoutingException('Sin polar: se elige en CFG › Barco');
  }

  final segments = <RouteSegment>[];
  var pos = req.waypoints.first;
  var time = req.departure;
  var reachedIndex = 0;
  String? warning;
  final totalLegs = req.waypoints.length - 1;

  for (var leg = 0; leg < totalLegs; leg++) {
    final target = req.waypoints[leg + 1];
    final result = _routeLeg(
      legIndex: leg,
      start: pos,
      startTime: time,
      target: target,
      req: req,
      onProgress: onProgress == null
          ? null
          : (legFrac) => onProgress((leg + legFrac) / totalLegs),
    );
    segments.addAll(result.segments);
    if (result.segments.isNotEmpty) {
      pos = (lat: result.segments.last.endLat, lon: result.segments.last.endLon);
      time = result.segments.last.endTime;
    }
    if (!result.reached) {
      warning =
          'No se pudo completar el tramo ${leg + 1} de '
          '${req.waypoints.length - 1}${result.reason == null ? '' : ': ${result.reason}'}.';
      break;
    }
    reachedIndex = leg + 1;
  }

  return RouteResult(
    segments: segments,
    waypoints: req.waypoints,
    reachedIndex: reachedIndex,
    warning: warning,
  );
}

/// Igual que [computeRoute], pero en su propio isolate y avisando del
/// progreso real del cálculo (no una espera indefinida): [onProgress]
/// recibe 0–1 según avanzan los pasos de la isócrona, sumando las
/// piernas si la ruta tiene vías. Para 200 M puede tardar unos segundos;
/// esto es lo que deja al deslizador de carga llenarse de verdad en vez
/// de girar sin decir nada.
Future<RouteResult> computeRouteInIsolate(
  RouteRequest req,
  void Function(double) onProgress,
) async {
  final port = ReceivePort();
  final errorPort = ReceivePort();
  late final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _routeIsolateEntry,
      _RouteIsolateArgs(req, port.sendPort),
      onError: errorPort.sendPort,
      errorsAreFatal: true,
    );
  } catch (e) {
    port.close();
    errorPort.close();
    throw RoutingException('No se pudo lanzar el cálculo: $e');
  }
  final completer = Completer<RouteResult>();
  late final StreamSubscription portSub;
  late final StreamSubscription errSub;
  void finish() {
    portSub.cancel();
    errSub.cancel();
    port.close();
    errorPort.close();
    isolate.kill(priority: Isolate.immediate);
  }

  errSub = errorPort.listen((e) {
    if (!completer.isCompleted) {
      completer.completeError(RoutingException('$e'));
    }
    finish();
  });
  portSub = port.listen((message) {
    if (message is double) {
      onProgress(message);
    } else if (message is RouteResult) {
      if (!completer.isCompleted) completer.complete(message);
      finish();
    } else if (message is String) {
      if (!completer.isCompleted) completer.completeError(RoutingException(message));
      finish();
    }
  });
  return completer.future;
}

class _RouteIsolateArgs {
  const _RouteIsolateArgs(this.request, this.sendPort);
  final RouteRequest request;
  final SendPort sendPort;
}

void _routeIsolateEntry(_RouteIsolateArgs args) {
  try {
    final result = computeRoute(
      args.request,
      onProgress: (f) => args.sendPort.send(f),
    );
    args.sendPort.send(result);
  } catch (e) {
    args.sendPort.send(e.toString());
  }
}

class _LegResult {
  _LegResult(this.segments, this.reached, this.reason);
  final List<RouteSegment> segments;
  final bool reached;
  final String? reason;
}

/// Nodo de la búsqueda: una posición y hora alcanzables, con el tramo que
/// llevó hasta él (para reconstruir la ruta) y cuánto tiempo lleva el
/// camino por encima de la ola preferida (para el tope de confort).
class _Node {
  _Node(
    this.lat,
    this.lon,
    this.time,
    this.parent,
    this.arrivingSegment,
    this.minutesAbovePreferred,
    this.remainingNm, {
    this.minutesSinceManeuver = 0,
    this.justManeuvered = false,
  });
  final double lat, lon;
  final DateTime time;
  final _Node? parent;
  final RouteSegment? arrivingSegment;
  final int minutesAbovePreferred;
  final double remainingNm;

  /// Cuánto lleva el camino en el mismo rumbo y modo (vela/motor) sin
  /// virar/trasluchar ni arrancar/parar el motor. Sirve para penalizar
  /// las maniobras seguidas: "virar cada poco cansa", el mismo criterio
  /// que usan los routers de regata reales (SailTimer y similares).
  final double minutesSinceManeuver;

  /// Si el tramo que llega a este nodo ES la maniobra (viró, trasluchó o
  /// cambió de vela a motor o viceversa justo aquí).
  final bool justManeuvered;
}

/// Penalización de búsqueda por maniobrar, no un tiempo físico simulado
/// (el barco no se para de verdad en el cálculo): sesga la isócrona para
/// que no compense virar o cambiar de vela a motor cada 15 min si el
/// tramo anterior en ese rumbo era corto. Inversamente proporcional al
/// tiempo mantenido en el rumbo previo, como describe la literatura de
/// routing de regata.
const kManeuverBasePenaltyNm = 0.5;
const kManeuverReferenceMinutes = 60.0;

/// ¿Es la misma bordada? No es "¿ha girado poco el rumbo?" — un rumbo
/// óptimo hacia un destino cambia unos grados en cada paso sin más
/// motivo que corregir la puntería, y eso no cansa a nadie. La maniobra
/// real es cruzar el eje del viento: pasar de recibirlo por babor a
/// recibirlo por estribor (virada) o al revés en popa (trasluchada), o
/// cambiar de vela a motor. Mientras se navegue en el mismo lado del
/// viento, ajustar el rumbo no cuenta como maniobra por mucho que se
/// mueva el número de grados.
bool _sameTack(
  RouteSegment? prev,
  double headingDeg,
  double twdDeg,
  PropulsionMode mode,
) {
  if (prev == null) return true; // primer paso: no hay maniobra que contar
  if (prev.mode != mode) return false;
  final prevSide = normalizeRelativeAngle(prev.headingDeg - prev.twdDeg);
  final newSide = normalizeRelativeAngle(headingDeg - twdDeg);
  // Cerca del eje del viento (proa o popa directas) el signo es ruido de
  // redondeo, no una virada real.
  if (prevSide.abs() < 5 || newSide.abs() < 5) return true;
  return prevSide.sign == newSide.sign;
}

_LegResult _routeLeg({
  required int legIndex,
  required ({double lat, double lon}) start,
  required DateTime startTime,
  required ({double lat, double lon}) target,
  required RouteRequest req,
  void Function(double)? onProgress,
}) {
  final directNm = distanceNm(start.lat, start.lon, target.lat, target.lon);
  if (directNm < 0.05) return _LegResult(const [], true, null);

  // Techo de pasos: el doble del tiempo que tardaría en línea recta a la
  // velocidad mínima navegable, más un margen generoso para los bordos.
  final minSpeed = math.max(2.0, req.constraints.minimumSailingSTW * 0.6);
  final maxSteps = math.min(
    400,
    ((directNm / minSpeed) * 60 / kIsochroneStepMinutes * 2.2).ceil() + 8,
  );
  final stepH = kIsochroneStepMinutes / 60.0;
  final targetBearing = bearingDeg(start.lat, start.lon, target.lat, target.lon);
  const arrivalNm = 0.35;

  // Solo la costa que de verdad puede tocar esta pierna: en mar abierta,
  // lejos de cualquiera de los polígonos, esto deja la lista vacía y cada
  // rumbo se ahorra un escaneo de 74 costas que nunca iban a estar cerca.
  final land = req.land;
  final legLand = (land == null || land.isEmpty)
      ? null
      : land.restrictedTo(
          math.min(start.lat, target.lat),
          math.min(start.lon, target.lon),
          math.max(start.lat, target.lat),
          math.max(start.lon, target.lon),
          math.max(0.35, directNm / 60 * 0.3),
        );
  final comfortPenaltyNmPerMeterMin = req.objective == RoutingObjective.comfort
      ? 3.0
      : 0.0;

  var frontier = <_Node>[
    _Node(start.lat, start.lon, startTime, null, null, 0, directNm),
  ];
  _Node? best = frontier.first;

  for (var step = 0; step < maxSteps; step++) {
    onProgress?.call(step / maxSteps);
    final next = <String, _Node>{}; // clave = sector de poda
    for (final node in frontier) {
      if (node.remainingNm <= arrivalNm) {
        best = node;
        return _LegResult(_backtrack(node, legIndex), true, null);
      }
      final grid = req.grid;
      final sample = grid.sample(node.lat, node.lon, node.time);
      if (sample == null) {
        // Sin dato de viento aquí: si se puede motorar hacia el destino,
        // ese es el único candidato razonable; si no, el nodo muere.
        if (req.constraints.allowMotor) {
          final bearing = bearingDeg(node.lat, node.lon, target.lat, target.lon);
          if (!_blockedByLand(
            legLand,
            node.lat,
            node.lon,
            bearing,
            req.constraints.motorSpeedKn * stepH,
            req.constraints.minimumCoastDistanceNm,
          )) {
            final child = _stepNode(
              node,
              bearing,
              req.constraints.motorSpeedKn,
              PropulsionMode.motor,
              stepH,
              legIndex,
              twsKn: 0,
              twdDeg: bearing,
              waveSample: null,
              req: req,
            );
            _offerCandidate(next, child, target, targetBearing);
          }
        }
        continue;
      }
      if (sample.twsKn > req.constraints.maxAwsKn + 40) continue; // absurdo
      // La curva de la polar solo depende del TWS de este nodo, no del
      // rumbo: se construye UNA vez y se reutiliza en los 72 candidatos,
      // en vez de rehacerla en cada uno (era el grueso del tiempo de
      // cálculo). Reportado en vivo 2026-09-18 ("es lentísimo").
      final curve = req.polar.curveFor(sample.twsKn);
      for (var h = 0.0; h < 360; h += kHeadingStepDeg) {
        final child = _headingCandidate(
          node: node,
          headingDeg: h,
          sample: sample,
          curve: curve,
          legLand: legLand,
          req: req,
          legIndex: legIndex,
          stepH: stepH,
        );
        if (child == null) continue;
        _offerCandidate(
          next,
          child,
          target,
          targetBearing,
          comfortPenalty: comfortPenaltyNmPerMeterMin,
        );
      }
    }
    if (next.isEmpty) {
      // Nada navegable (calma total sin motor, o todo por encima del
      // tope absoluto de ola): la pierna no se puede completar.
      final closest = frontier.reduce(
        (a, b) => a.remainingNm <= b.remainingNm ? a : b,
      );
      final stuckOnCoast =
          legLand != null && legLand.nearLand(closest.lat, closest.lon, req.constraints.minimumCoastDistanceNm);
      return _LegResult(
        _backtrack(closest, legIndex),
        false,
        stuckOnCoast
            ? 'rodeado de costa, sin paso navegable'
            : 'sin rumbo navegable (calma o mar por encima del máximo)',
      );
    }
    frontier = next.values.toList();
    for (final n in frontier) {
      final b = best;
      if (b == null || n.remainingNm < b.remainingNm) best = n;
    }
  }

  final b = best;
  if (b == null) return _LegResult(const [], false, 'sin candidatos');
  return _LegResult(
    _backtrack(b, legIndex),
    false,
    'se agotó el tiempo de cálculo antes de llegar',
  );
}

/// ¿El tramo de [startLat]/[startLon] al punto que resulta de navegar
/// [distNm] millas al rumbo [headingDeg] pisa tierra o se queda a menos
/// del margen de seguridad? Sin máscara (null o vacía) nunca bloquea:
/// la ruta se calcula igual, solo sin evitar la costa.
bool _blockedByLand(
  LandMask? land,
  double startLat,
  double startLon,
  double headingDeg,
  double distNm,
  double marginNm,
) {
  if (land == null || land.isEmpty) return false;
  final dest = destinationNm(startLat, startLon, headingDeg, distNm);
  return land.segmentBlocked(startLat, startLon, dest.lat, dest.lon, marginNm);
}

/// Evalúa un rumbo candidato: decide vela/motor, aplica los límites de
/// AWS y ola, y devuelve el nodo resultante (o null si el rumbo no es
/// utilizable).
_Node? _headingCandidate({
  required _Node node,
  required double headingDeg,
  required WeatherSample sample,
  required List<(double, double)> curve,
  required LandMask? legLand,
  required RouteRequest req,
  required int legIndex,
  required double stepH,
}) {
  final twa = trueWindAngle(headingDeg, sample.twdDeg);
  final factor = (req.polarFactorPercent / 100).clamp(0.1, 1.5);
  final sailStw = PolarTable.speedAtCurve(curve, twa);
  final sailSpeed = sailStw == null ? null : sailStw * factor;

  // El ángulo de ceñida de la polar (beatAngle) es el óptimo del VPP en
  // banco de pruebas; a velocidad real, el aparente que le corresponde
  // puede salir más cerrado de lo que las velas aguantan trimadas de
  // verdad (a más velocidad del barco respecto al viento, más se
  // adelanta el aparente). minimumAwaDeg es el tope de eso: por debajo,
  // el barco tendría que abrir el rumbo aunque la polar diga que ese TWA
  // "vale". Reportado en vivo 2026-09-18.
  ({double awsKn, double awaDeg})? sailAw;
  var sailPhysicallyValid = false;
  if (sailSpeed != null) {
    sailAw = apparentWind(
      twsKn: sample.twsKn,
      twdDeg: sample.twdDeg,
      headingDeg: headingDeg,
      stwKn: sailSpeed,
    );
    sailPhysicallyValid = sailAw.awaDeg.abs() >= req.constraints.minimumAwaDeg;
  }

  double stw;
  PropulsionMode mode;
  ({double awsKn, double awaDeg}) aw;
  if (sailPhysicallyValid && sailSpeed! >= req.constraints.minimumSailingSTW) {
    stw = sailSpeed;
    mode = PropulsionMode.sailing;
    aw = sailAw!;
  } else if (req.constraints.allowMotor) {
    stw = req.constraints.motorSpeedKn;
    mode = PropulsionMode.motor;
    aw = apparentWind(
      twsKn: sample.twsKn,
      twdDeg: sample.twdDeg,
      headingDeg: headingDeg,
      stwKn: stw,
    );
  } else if (sailPhysicallyValid && sailSpeed! > 0) {
    stw = sailSpeed;
    mode = PropulsionMode.sailing;
    aw = sailAw!;
  } else {
    // Ángulo muerto, o el aparente saldría demasiado cerrado para
    // trimar, y sin motor: rumbo inútil.
    return null;
  }
  if (aw.awsKn > req.constraints.maxAwsKn) return null;

  if (sample.waveHeightM != null &&
      sample.waveHeightM! > req.constraints.absoluteMaxWaveM) {
    return null; // tope duro: nunca se cruza
  }

  if (_blockedByLand(
    legLand,
    node.lat,
    node.lon,
    headingDeg,
    stw * stepH,
    req.constraints.minimumCoastDistanceNm,
  )) {
    return null;
  }

  return _stepNode(
    node,
    headingDeg,
    stw,
    mode,
    stepH,
    legIndex,
    twsKn: sample.twsKn,
    twdDeg: sample.twdDeg,
    waveSample: sample,
    req: req,
    precomputedAws: aw,
    precomputedTwa: twa,
  );
}

_Node _stepNode(
  _Node node,
  double headingDeg,
  double stwKn,
  PropulsionMode mode,
  double stepH,
  int legIndex, {
  required double twsKn,
  required double twdDeg,
  required WeatherSample? waveSample,
  required RouteRequest req,
  ({double awsKn, double awaDeg})? precomputedAws,
  double? precomputedTwa,
}) {
  final distNm = stwKn * stepH;
  final dest = destinationNm(node.lat, node.lon, headingDeg, distNm);
  final endTime = node.time.add(
    Duration(seconds: (stepH * 3600).round()),
  );
  final aw =
      precomputedAws ??
      apparentWind(
        twsKn: twsKn,
        twdDeg: twdDeg,
        headingDeg: headingDeg,
        stwKn: stwKn,
      );
  final twa = precomputedTwa ?? trueWindAngle(headingDeg, twdDeg);

  double? encAngle, encPeriod;
  if (waveSample?.waveDirDeg != null && waveSample?.wavePeriodS != null) {
    final enc = waveEncounter(
      headingDeg: headingDeg,
      stwKn: stwKn,
      waveFromDeg: waveSample!.waveDirDeg!,
      wavePeriodS: waveSample.wavePeriodS!,
    );
    encAngle = enc.angleDeg;
    encPeriod = enc.periodS;
  }

  final seg = RouteSegment(
    waypointIndex: legIndex,
    startLat: node.lat,
    startLon: node.lon,
    endLat: dest.lat,
    endLon: dest.lon,
    startTime: node.time,
    endTime: endTime,
    headingDeg: headingDeg,
    distanceNm: distNm,
    mode: mode,
    stwKn: stwKn,
    twsKn: twsKn,
    twdDeg: twdDeg,
    twaDeg: twa,
    awsKn: aw.awsKn,
    awaDeg: aw.awaDeg,
    waveHeightM: waveSample?.waveHeightM,
    waveDirDeg: waveSample?.waveDirDeg,
    wavePeriodS: waveSample?.wavePeriodS,
    waveEncounterAngleDeg: encAngle,
    waveEncounterPeriodS: encPeriod,
  );

  final abovePreferred =
      waveSample?.waveHeightM != null &&
      waveSample!.waveHeightM! > req.constraints.preferredMaxWaveM;
  final minutesAbove =
      node.minutesAbovePreferred + (abovePreferred ? kIsochroneStepMinutes : 0);

  final sameTack = _sameTack(node.arrivingSegment, headingDeg, twdDeg, mode);
  final minutesSinceManeuver = sameTack
      ? node.minutesSinceManeuver + kIsochroneStepMinutes
      : kIsochroneStepMinutes.toDouble();

  return _Node(
    dest.lat,
    dest.lon,
    endTime,
    node,
    seg,
    minutesAbove,
    0, // se recalcula en _offerCandidate
    minutesSinceManeuver: minutesSinceManeuver,
    justManeuvered: !sameTack,
  );
}

/// Poda por isócronas: para cada sector angular (visto desde la salida de
/// la pierna, hacia el rumbo directo al destino) se queda solo el nodo
/// que más ha progresado, penalizando la ola incómoda en modo Confort y
/// descartando el que ya agotó su presupuesto de tiempo en mar dura.
void _offerCandidate(
  Map<String, _Node> next,
  _Node candidate,
  ({double lat, double lon}) target,
  double targetBearing, {
  double comfortPenalty = 0,
}) {
  final maxMinutes = 24 * 60; // se corta antes por maxSteps; esto es solo cordura
  if (candidate.minutesAbovePreferred > maxMinutes) return;

  final remaining = distanceNm(
    candidate.lat,
    candidate.lon,
    target.lat,
    target.lon,
  );
  final seg = candidate.arrivingSegment;
  final wavePenalty =
      (comfortPenalty > 0 && seg?.waveHeightM != null && seg!.waveHeightM! > 0.0)
      ? comfortPenalty *
            math.max(0, seg.waveHeightM! - 0.0) *
            (seg.duration.inMinutes / 60.0)
      : 0.0;
  // El tramo previo a ESTA maniobra es el que se mantuvo antes de virar
  // (minutesSinceManeuver del padre), no el de este nodo (que ya cuenta
  // el paso recién dado).
  final heldBeforeThis = candidate.parent?.minutesSinceManeuver ?? kManeuverReferenceMinutes;
  final maneuverPenalty = candidate.justManeuvered
      ? kManeuverBasePenaltyNm *
            (kManeuverReferenceMinutes / math.max(kIsochroneStepMinutes.toDouble(), heldBeforeThis))
      : 0.0;
  final scored = _Node(
    candidate.lat,
    candidate.lon,
    candidate.time,
    candidate.parent,
    candidate.arrivingSegment,
    candidate.minutesAbovePreferred,
    remaining + wavePenalty + maneuverPenalty,
    minutesSinceManeuver: candidate.minutesSinceManeuver,
    justManeuvered: candidate.justManeuvered,
  );

  final bearingFromTarget = bearingDeg(
    target.lat,
    target.lon,
    candidate.lat,
    candidate.lon,
  );
  final sector =
      (normalizeRelativeAngle(bearingFromTarget - targetBearing) /
              kPruneSectorDeg)
          .round();
  final key = '$sector';
  final existing = next[key];
  if (existing == null || scored.remainingNm < existing.remainingNm) {
    next[key] = scored;
  }
}

List<RouteSegment> _backtrack(_Node node, int legIndex) {
  final segs = <RouteSegment>[];
  var n = node;
  while (n.arrivingSegment != null) {
    segs.add(n.arrivingSegment!);
    n = n.parent!;
  }
  return segs.reversed.toList();
}
