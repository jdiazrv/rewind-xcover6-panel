// Motor de weather routing: isócronas cada 15 min, rumbos cada 5°, con
// vela/motor decidido en el propio cálculo — no pintado encima después.
//
// Dart puro, sin Flutter: se llama desde la pantalla con `compute()`
// (aísla el trabajo en su propio isolate) y se prueba sin red ni widgets.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import '../angles.dart';
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

/// Tipo de maniobra al empezar un tramo. Cuesta tiempo de verdad (el barco
/// pierde velocidad al virar, o mientras arría/iza para arrancar el motor)
/// y entra en la ETA, no solo en la puntuación de la búsqueda.
enum ManeuverKind {
  tack('virada'),
  gybe('trasluchada'),
  modeChange('cambio vela/motor');

  const ManeuverKind(this.label);
  final String label;

  /// Tiempo perdido, en segundos: lo que tarda un crucero en recuperar
  /// velocidad tras virar (~1 min), algo menos al trasluchar, y lo que
  /// cuesta arriar/izar y arrancar/parar el motor.
  int get lossSeconds => switch (this) {
    ManeuverKind.tack => 60,
    ManeuverKind.gybe => 45,
    ManeuverKind.modeChange => 120,
  };
}

/// Peso del confort en modo Confort: millas de penalización por cada metro
/// de ola por encima de la cómoda y hora navegada en ella.
const kComfortWeightDefault = 4.0;

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
    this.comfortWeight = kComfortWeightDefault,
  });

  final double minimumSailingSTW;
  final bool allowMotor;
  final double motorSpeedKn;
  final double maxAwsKn;
  final double preferredMaxWaveM;
  final double absoluteMaxWaveM;

  /// En Confort y Personalizado, lo más que la ruta puede pasar con ola
  /// por encima de [preferredMaxWaveM]. En Rápido no cuenta: solo manda
  /// el máximo absoluto.
  final Duration maxTimeAbovePreferred;

  /// El aparente que la polar diría que "vale" a un TWA puede salir, a
  /// velocidad real, más cerrado de lo que las velas trimarían de
  /// verdad. Por debajo de este AWA, ese rumbo no es una opción a vela
  /// aunque la polar tenga dato ahí. 30° por defecto.
  final double minimumAwaDeg;

  /// Margen a la costa (máscara de tierra de Natural Earth 1:50 M): ningún
  /// tramo pasa a menos de esto de tierra. La máscara es de escala media,
  /// no una carta: no sustituye a mirar la carta en la aproximación.
  final double minimumCoastDistanceNm;

  /// Solo en Personalizado: cuánto pesa la ola por encima de la cómoda
  /// frente a llegar antes (0 = como Rápido). Confort usa
  /// [kComfortWeightDefault].
  final double comfortWeight;

  RoutingConstraints copyWith({
    double? minimumSailingSTW,
    bool? allowMotor,
    double? motorSpeedKn,
    double? maxAwsKn,
    double? preferredMaxWaveM,
    double? absoluteMaxWaveM,
    Duration? maxTimeAbovePreferred,
    double? minimumCoastDistanceNm,
    double? minimumAwaDeg,
    double? comfortWeight,
  }) => RoutingConstraints(
    minimumSailingSTW: minimumSailingSTW ?? this.minimumSailingSTW,
    allowMotor: allowMotor ?? this.allowMotor,
    motorSpeedKn: motorSpeedKn ?? this.motorSpeedKn,
    maxAwsKn: maxAwsKn ?? this.maxAwsKn,
    preferredMaxWaveM: preferredMaxWaveM ?? this.preferredMaxWaveM,
    absoluteMaxWaveM: absoluteMaxWaveM ?? this.absoluteMaxWaveM,
    maxTimeAbovePreferred: maxTimeAbovePreferred ?? this.maxTimeAbovePreferred,
    minimumCoastDistanceNm:
        minimumCoastDistanceNm ?? this.minimumCoastDistanceNm,
    minimumAwaDeg: minimumAwaDeg ?? this.minimumAwaDeg,
    comfortWeight: comfortWeight ?? this.comfortWeight,
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
    this.gustKn,
    this.maneuver,
    this.noForecast = false,
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

  /// Racha del modelo en este tramo (null si el modelo no la da).
  final double? gustKn;

  /// La maniobra con la que EMPIEZA este tramo, si la hay. Su tiempo
  /// perdido ya está descontado de [distanceNm].
  final ManeuverKind? maneuver;

  /// Tramo fuera de la zona o de las horas del tiempo descargado: se ha
  /// supuesto motor en línea recta, sin viento ni ola conocidos.
  final bool noForecast;

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

  double get totalNm =>
      [for (final s in segments) s.distanceNm].fold(0.0, (a, b) => a + b);

  Duration get totalDuration => segments.isEmpty
      ? Duration.zero
      : segments.last.endTime.difference(segments.first.startTime);

  DateTime? get departure => segments.isEmpty ? null : segments.first.startTime;

  /// Desde cuándo la ruta va sin previsión (null si toda la tiene).
  DateTime? get noForecastFrom {
    for (final s in segments) {
      if (s.noForecast) return s.startTime;
    }
    return null;
  }

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
    final f = total <= 0 ? 1.0 : t.difference(s.startTime).inSeconds / total;
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

/// Una isócrona: los puntos alcanzables a una misma hora, ordenados por
/// su ángulo visto desde el destino de la pierna (para pintarla como una
/// línea). [latLon] va plano: lat0, lon0, lat1, lon1…
class RouteIsochrone {
  const RouteIsochrone({
    required this.legIndex,
    required this.step,
    required this.time,
    required this.latLon,
  });
  final int legIndex;

  /// Paso de 15 min dentro de la pierna (0 = el primero tras salir).
  final int step;
  final DateTime time;
  final List<double> latLon;
}

/// Cálculo síncrono completo. Función de nivel superior para poder
/// cruzar a otro isolate.
RouteResult computeRoute(
  RouteRequest req, {
  void Function(double)? onProgress,
  void Function(RouteIsochrone)? onIsochrone,
}) {
  Object? last;
  for (final e in _routeSteps(req, onProgress, onIsochrone)) {
    last = e;
  }
  return last! as RouteResult;
}

/// ¿Compilado para navegador? Ahí no hay isolates (`Isolate.spawn` da
/// "Unsupported operation"). Mismo criterio que `kIsWeb` de Flutter, sin
/// depender de Flutter.
const bool kRoutingOnWeb =
    bool.fromEnvironment('dart.library.js_util') ||
    bool.fromEnvironment('dart.library.js_interop');

/// Calcula sin congelar la pantalla: en su propio isolate en Android y
/// escritorio; en la webapp, a trozos en el hilo principal, cediendo
/// al navegador cada pocos milisegundos para que pinte el progreso y
/// las isócronas.
Future<RouteResult> computeRouteInBackground(
  RouteRequest req,
  void Function(double) onProgress, {
  void Function(RouteIsochrone)? onIsochrone,
}) => kRoutingOnWeb
    // Trozos de 40 ms: ceder al navegador cuesta unos ms cada vez; con
    // trozos más cortos se va más tiempo en ceder que en calcular.
    ? computeRouteChunked(
        req,
        onProgress,
        onIsochrone: onIsochrone,
        sliceMs: 40,
      )
    : computeRouteInIsolate(req, onProgress, onIsochrone: onIsochrone);

/// El mismo cálculo por trozos, en el hilo que llama: cada ~[sliceMs]
/// cede el control al bucle de eventos.
Future<RouteResult> computeRouteChunked(
  RouteRequest req,
  void Function(double) onProgress, {
  void Function(RouteIsochrone)? onIsochrone,
  int sliceMs = 16,
}) async {
  final sw = Stopwatch()..start();
  for (final e in _routeSteps(req, onProgress, onIsochrone)) {
    if (e is RouteResult) return e;
    if (sw.elapsedMilliseconds >= sliceMs) {
      await Future<void>.delayed(Duration.zero);
      sw.reset();
    }
  }
  throw RoutingException('El cálculo terminó sin resultado');
}

/// El algoritmo, como generador: da `null` tras cada paso de isócrona
/// (punto donde se puede ceder el control) y, al final, el RouteResult.
Iterable<Object?> _routeSteps(
  RouteRequest req,
  void Function(double)? onProgress,
  void Function(RouteIsochrone)? onIsochrone,
) sync* {
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
  RouteSegment? carry; // último tramo de la pierna anterior (maniobras)

  // El progreso se reparte entre piernas por su distancia directa (una vía
  // a 5 M y otra a 60 M no pesan lo mismo), y nunca retrocede.
  final legNm = [
    for (var i = 0; i < totalLegs; i++)
      distanceNm(
        req.waypoints[i].lat,
        req.waypoints[i].lon,
        req.waypoints[i + 1].lat,
        req.waypoints[i + 1].lon,
      ),
  ];
  final totalNm = legNm.fold(0.0, (a, b) => a + b);
  var doneNm = 0.0;
  var shown = 0.0;
  void report(int leg, double legFrac) {
    if (onProgress == null) return;
    final f = totalNm <= 0
        ? (leg + legFrac) / totalLegs
        : (doneNm + legFrac * legNm[leg]) / totalNm;
    if (f > shown) {
      shown = f.clamp(0.0, 1.0);
      onProgress(shown);
    }
  }

  for (var leg = 0; leg < totalLegs; leg++) {
    final target = req.waypoints[leg + 1];
    _LegResult? legResult;
    for (final e in _routeLegSteps(
      legIndex: leg,
      start: pos,
      startTime: time,
      target: target,
      req: req,
      previous: carry,
      onProgress: onProgress == null ? null : (f) => report(leg, f),
      onIsochrone: onIsochrone,
    )) {
      if (e == null) {
        yield null;
      } else {
        legResult = e;
      }
    }
    final result = legResult!;
    doneNm += legNm[leg];
    segments.addAll(result.segments);
    if (result.segments.isNotEmpty) {
      pos = (
        lat: result.segments.last.endLat,
        lon: result.segments.last.endLon,
      );
      time = result.segments.last.endTime;
      carry = result.segments.last;
    }
    if (!result.reached) {
      warning =
          'No se pudo completar el tramo ${leg + 1} de '
          '${req.waypoints.length - 1}${result.reason == null ? '' : ': ${result.reason}'}.';
      break;
    }
    reachedIndex = leg + 1;
  }

  if (onProgress != null && shown < 1) onProgress(1.0);
  yield RouteResult(
    segments: segments,
    waypoints: req.waypoints,
    reachedIndex: reachedIndex,
    warning: warning,
  );
}

/// Igual que [computeRoute], pero en su propio isolate y avisando del
/// progreso real del cálculo (no una espera indefinida): [onProgress]
/// recibe 0–1 según avanzan los pasos de la isócrona, sumando las
/// piernas si la ruta tiene vías. Con [onIsochrone], además, cada
/// isócrona según se calcula, para pintarlas en vivo.
Future<RouteResult> computeRouteInIsolate(
  RouteRequest req,
  void Function(double) onProgress, {
  void Function(RouteIsochrone)? onIsochrone,
}) async {
  final port = ReceivePort();
  final errorPort = ReceivePort();
  late final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _routeIsolateEntry,
      _RouteIsolateArgs(req, port.sendPort, onIsochrone != null),
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
    } else if (message is RouteIsochrone) {
      onIsochrone?.call(message);
    } else if (message is RouteResult) {
      if (!completer.isCompleted) completer.complete(message);
      finish();
    } else if (message is String) {
      if (!completer.isCompleted) {
        completer.completeError(RoutingException(message));
      }
      finish();
    }
  });
  return completer.future;
}

class _RouteIsolateArgs {
  const _RouteIsolateArgs(this.request, this.sendPort, this.isochrones);
  final RouteRequest request;
  final SendPort sendPort;
  final bool isochrones;
}

void _routeIsolateEntry(_RouteIsolateArgs args) {
  try {
    final result = computeRoute(
      args.request,
      onProgress: (f) => args.sendPort.send(f),
      onIsochrone: args.isochrones ? args.sendPort.send : null,
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
/// llevó hasta él (para reconstruir la ruta), cuánto tiempo lleva el
/// camino por encima de la ola cómoda (para el tope de Confort) y la
/// penalización de confort ACUMULADA por el camino.
class _Node {
  _Node(
    this.lat,
    this.lon,
    this.time,
    this.parent,
    this.arrivingSegment,
    this.minutesAbovePreferred, {
    this.comfortPenaltyNm = 0,
    this.minutesSinceManeuver = 0,
  });
  final double lat, lon;
  final DateTime time;
  final _Node? parent;
  final RouteSegment? arrivingSegment;
  final int minutesAbovePreferred;
  final double comfortPenaltyNm;

  /// Distancia real que falta al destino de la pierna.
  double remainingNm = 0;

  /// Lo que se compara en la poda: [remainingNm] más las penalizaciones.
  double score = 0;

  /// Cuánto lleva el camino en el mismo bordo y modo (vela/motor) sin
  /// virar/trasluchar ni arrancar/parar el motor.
  final double minutesSinceManeuver;

  bool get justManeuvered => arrivingSegment?.maneuver != null;
}

/// Sesgo de búsqueda contra maniobrar seguido (no un tiempo físico: ese
/// ya lo pone [ManeuverKind.lossSeconds] en la ETA). Inversamente
/// proporcional al tiempo mantenido en el bordo anterior: sin él, la
/// isócrona elige bordos de 15 min que sobre el papel ganan unos metros.
const kManeuverBasePenaltyNm = 0.5;
const kManeuverReferenceMinutes = 60.0;

/// ¿Qué maniobra hay entre el tramo anterior y este? No es "¿ha girado
/// poco el rumbo?" — un rumbo óptimo hacia un destino cambia unos grados
/// en cada paso sin más motivo que corregir la puntería, y eso no cansa a
/// nadie. La maniobra real es cruzar el eje del viento a vela (virada o
/// trasluchada) o cambiar de vela a motor. A motor cruzar el eje del
/// viento no es ninguna maniobra.
ManeuverKind? _maneuverBetween(
  RouteSegment? prev,
  double headingDeg,
  double twdDeg,
  PropulsionMode mode,
) {
  if (prev == null) return null; // primer paso: no hay maniobra que contar
  if (prev.noForecast) return null;
  if (prev.mode != mode) return ManeuverKind.modeChange;
  if (mode == PropulsionMode.motor) return null;
  final prevSide = normalizeRelativeAngle(prev.headingDeg - prev.twdDeg);
  final newSide = normalizeRelativeAngle(headingDeg - twdDeg);
  // Cerca del eje del viento (proa o popa directas) el signo es ruido de
  // redondeo, no una virada real.
  if (prevSide.abs() < 5 || newSide.abs() < 5) return null;
  if (prevSide.sign == newSide.sign) return null;
  return newSide.abs() < 90 ? ManeuverKind.tack : ManeuverKind.gybe;
}

/// Peso del confort según el objetivo: 0 en Rápido (solo el máximo
/// absoluto manda), fijo en Confort, el del usuario en Personalizado.
double _comfortWeightFor(RouteRequest req) => switch (req.objective) {
  RoutingObjective.fast => 0.0,
  RoutingObjective.comfort => kComfortWeightDefault,
  RoutingObjective.custom => req.constraints.comfortWeight,
};

/// ¿Cuenta el tope de tiempo con ola por encima de la cómoda?
bool _limitTimeAbovePreferred(RouteRequest req) =>
    req.objective != RoutingObjective.fast;

/// Una pierna, como generador: `null` tras cada paso y el _LegResult al
/// final.
Iterable<_LegResult?> _routeLegSteps({
  required int legIndex,
  required ({double lat, double lon}) start,
  required DateTime startTime,
  required ({double lat, double lon}) target,
  required RouteRequest req,
  RouteSegment? previous,
  void Function(double)? onProgress,
  void Function(RouteIsochrone)? onIsochrone,
}) sync* {
  final directNm = distanceNm(start.lat, start.lon, target.lat, target.lon);
  if (directNm < 0.05) {
    yield _LegResult(const [], true, null);
    return;
  }

  // Techo de pasos: el doble del tiempo que tardaría en línea recta a la
  // velocidad mínima navegable, más un margen generoso para los bordos.
  final minSpeed = math.max(2.0, req.constraints.minimumSailingSTW * 0.6);
  final maxSteps = math.min(
    400,
    ((directNm / minSpeed) * 60 / kIsochroneStepMinutes * 2.2).ceil() + 8,
  );
  final stepH = kIsochroneStepMinutes / 60.0;
  final targetBearing = bearingDeg(
    start.lat,
    start.lon,
    target.lat,
    target.lon,
  );
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
  final ctx = _LegContext(
    req: req,
    legIndex: legIndex,
    legLand: legLand,
    stepH: stepH,
    target: target,
    targetBearing: targetBearing,
    comfortWeight: _comfortWeightFor(req),
    maxMinutesAbovePreferred: _limitTimeAbovePreferred(req)
        ? req.constraints.maxTimeAbovePreferred.inMinutes
        : null,
  );

  // El nodo de salida "lleva" el último tramo de la pierna anterior (para
  // contar como maniobra el virar justo en la vía) y un bordo neutro.
  final root =
      _Node(
          start.lat,
          start.lon,
          startTime,
          null,
          previous,
          0,
          minutesSinceManeuver: kManeuverReferenceMinutes,
        )
        ..remainingNm = directNm
        ..score = directNm;
  var frontier = <_Node>[root];
  _Node best = root;

  for (var step = 0; step < maxSteps; step++) {
    // Progreso = cuánto se ha acercado ya la mejor isócrona al destino.
    // Antes era paso / techo de pasos, y ese techo es 2,2 veces el peor
    // caso: la barra se arrastraba y luego saltaba al 100 %.
    onProgress?.call((1 - best.remainingNm / directNm).clamp(0.0, 0.99));
    if (step > 0) yield null;
    final next = <int, _Node>{}; // clave = sector de poda
    // Llegada exacta: si desde algún nodo el destino se alcanza DENTRO de
    // este paso a un rumbo navegable, se llega justo ahí con un paso
    // parcial. Antes solo contaba como llegada caer a menos de 0,35 M, y
    // con pasos de ~1,5 M y rumbos cada 5° una ceñida podía no caer nunca
    // dentro (la pierna "no se completaba") y la ETA iba de 15 en 15 min.
    _Node? finish;
    for (final node in frontier) {
      if (node.remainingNm <= arrivalNm) {
        yield _LegResult(_backtrack(node), true, null);
        return;
      }
      final sample = req.grid.sample(node.lat, node.lon, node.time);
      if (sample == null) {
        // Fuera de la zona o de las horas del tiempo descargado. Antes se
        // motoraba en silencio; ahora se marca el tramo como "sin
        // previsión" (la pantalla lo avisa) y, sin motor, el nodo muere.
        ctx.sawNoForecast = true;
        if (req.constraints.allowMotor) {
          final toTarget = node.remainingNm;
          final bearing = bearingDeg(
            node.lat,
            node.lon,
            target.lat,
            target.lon,
          );
          final reach = req.constraints.motorSpeedKn * stepH;
          final h = toTarget <= reach
              ? toTarget / req.constraints.motorSpeedKn
              : stepH;
          if (!_blockedByLand(
            legLand,
            node.lat,
            node.lon,
            bearing,
            req.constraints.motorSpeedKn * h,
            req.constraints.minimumCoastDistanceNm,
          )) {
            final child = _stepNode(
              ctx,
              node,
              bearing,
              req.constraints.motorSpeedKn,
              PropulsionMode.motor,
              h,
              sample: null,
              maneuver: null,
            );
            if (toTarget <= reach) {
              if (finish == null || child.time.isBefore(finish.time)) {
                finish = child;
              }
            } else {
              _offerCandidate(ctx, next, child);
            }
          }
        }
        continue;
      }
      if (sample.twsKn > req.constraints.maxAwsKn + 40) continue; // absurdo
      // La curva de la polar solo depende del TWS de este nodo, no del
      // rumbo: se construye UNA vez y se reutiliza en los 72 candidatos.
      final curve = req.polar.curveFor(sample.twsKn);
      final fin = _headingCandidate(
        ctx,
        node: node,
        headingDeg: bearingDeg(node.lat, node.lon, target.lat, target.lon),
        sample: sample,
        curve: curve,
        finishDistNm: node.remainingNm,
      );
      if (fin != null && (finish == null || fin.time.isBefore(finish.time))) {
        finish = fin;
      }
      for (var h = 0.0; h < 360; h += kHeadingStepDeg) {
        final child = _headingCandidate(
          ctx,
          node: node,
          headingDeg: h,
          sample: sample,
          curve: curve,
        );
        if (child == null) continue;
        _offerCandidate(ctx, next, child);
      }
    }
    if (finish != null) {
      yield _LegResult(_backtrack(finish), true, null);
      return;
    }
    if (next.isEmpty) {
      // Nada navegable (calma total sin motor, todo por encima del tope
      // absoluto de ola, o sin previsión): la pierna no se puede completar.
      final closest = frontier.reduce(
        (a, b) => a.remainingNm <= b.remainingNm ? a : b,
      );
      final stuckOnCoast =
          legLand != null &&
          legLand.nearLand(
            closest.lat,
            closest.lon,
            req.constraints.minimumCoastDistanceNm,
          );
      final String reason;
      if (ctx.sawNoForecast) {
        reason =
            'sin previsión más allá (fuera de la zona o de las horas '
            'descargadas) y sin motor permitido';
      } else if (ctx.droppedForTimeAbovePreferred) {
        reason =
            'haría falta más de ${_minutesText(ctx.maxMinutesAbovePreferred!)} '
            'con ola por encima de la cómoda (ajústalo o usa Rápido)';
      } else if (stuckOnCoast) {
        reason = 'rodeado de costa, sin paso navegable';
      } else {
        reason = 'sin rumbo navegable (calma o mar por encima del máximo)';
      }
      yield _LegResult(_backtrack(closest), false, reason);
      return;
    }
    frontier = next.values.toList();
    for (final n in frontier) {
      if (n.remainingNm < best.remainingNm) best = n;
    }
    if (onIsochrone != null) {
      final keys = next.keys.toList()..sort();
      onIsochrone(
        RouteIsochrone(
          legIndex: legIndex,
          step: step,
          time: frontier.first.time,
          latLon: [
            for (final k in keys) ...[next[k]!.lat, next[k]!.lon],
          ],
        ),
      );
    }
  }

  yield _LegResult(
    _backtrack(best),
    false,
    'se agotó el tiempo de cálculo antes de llegar',
  );
  return;
}

String _minutesText(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// Lo que comparten todos los candidatos de una pierna.
class _LegContext {
  _LegContext({
    required this.req,
    required this.legIndex,
    required this.legLand,
    required this.stepH,
    required this.target,
    required this.targetBearing,
    required this.comfortWeight,
    required this.maxMinutesAbovePreferred,
  });
  final RouteRequest req;
  final int legIndex;
  final LandMask? legLand;
  final double stepH;
  final ({double lat, double lon}) target;
  final double targetBearing;
  final double comfortWeight;
  final int? maxMinutesAbovePreferred;

  /// Para explicar por qué una pierna no se completa.
  bool sawNoForecast = false;
  bool droppedForTimeAbovePreferred = false;
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
/// AWS y ola, descuenta el tiempo de la maniobra si la hay, y devuelve el
/// nodo resultante (o null si el rumbo no es utilizable). Con
/// [finishDistNm], solo vale si llega a esa distancia dentro del paso.
_Node? _headingCandidate(
  _LegContext ctx, {
  required _Node node,
  required double headingDeg,
  required WeatherSample sample,
  required List<(double, double)> curve,
  double? finishDistNm,
}) {
  final req = ctx.req;
  final c = req.constraints;
  final twa = trueWindAngle(headingDeg, sample.twdDeg);
  final factor = (req.polarFactorPercent / 100).clamp(0.1, 1.5);
  final sailStw = PolarTable.speedAtCurve(curve, twa);
  final sailSpeed = sailStw == null ? null : sailStw * factor;

  // El ángulo de ceñida de la polar (beatAngle) es el óptimo del VPP en
  // banco de pruebas; a velocidad real, el aparente que le corresponde
  // puede salir más cerrado de lo que las velas aguantan trimadas de
  // verdad. minimumAwaDeg es el tope de eso: por debajo, sin motor, el
  // barco tiene que abrir el rumbo; con motor, ese rumbo va a motor.
  ({double awsKn, double awaDeg})? sailAw;
  var sailPhysicallyValid = false;
  if (sailSpeed != null) {
    sailAw = apparentWind(
      twsKn: sample.twsKn,
      twdDeg: sample.twdDeg,
      headingDeg: headingDeg,
      stwKn: sailSpeed,
    );
    sailPhysicallyValid = sailAw.awaDeg.abs() >= c.minimumAwaDeg;
  }

  double stw;
  PropulsionMode mode;
  ({double awsKn, double awaDeg}) aw;
  if (sailPhysicallyValid && sailSpeed! >= c.minimumSailingSTW) {
    stw = sailSpeed;
    mode = PropulsionMode.sailing;
    aw = sailAw!;
  } else if (c.allowMotor) {
    stw = c.motorSpeedKn;
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
  if (aw.awsKn > c.maxAwsKn) return null;

  if (sample.waveHeightM != null && sample.waveHeightM! > c.absoluteMaxWaveM) {
    return null; // tope duro: nunca se cruza
  }

  final maneuver = _maneuverBetween(
    node.arrivingSegment,
    headingDeg,
    sample.twdDeg,
    mode,
  );
  final lossH = (maneuver?.lossSeconds ?? 0) / 3600.0;

  // Tramo final: llegar justo al destino con un paso parcial, si da tiempo
  // dentro de este paso a este rumbo (maniobra incluida).
  var thisStepH = ctx.stepH;
  if (finishDistNm != null) {
    if (stw <= 0) return null;
    final need = finishDistNm / stw + lossH;
    if (need > ctx.stepH) return null;
    thisStepH = need;
  }

  if (_blockedByLand(
    ctx.legLand,
    node.lat,
    node.lon,
    headingDeg,
    stw * math.max(0, thisStepH - lossH),
    c.minimumCoastDistanceNm,
  )) {
    return null;
  }

  return _stepNode(
    ctx,
    node,
    headingDeg,
    stw,
    mode,
    thisStepH,
    sample: sample,
    maneuver: maneuver,
    precomputedAws: aw,
    precomputedTwa: twa,
  );
}

_Node _stepNode(
  _LegContext ctx,
  _Node node,
  double headingDeg,
  double stwKn,
  PropulsionMode mode,
  double stepH, {
  required WeatherSample? sample,
  required ManeuverKind? maneuver,
  ({double awsKn, double awaDeg})? precomputedAws,
  double? precomputedTwa,
}) {
  final twsKn = sample?.twsKn ?? 0;
  final twdDeg = sample?.twdDeg ?? headingDeg;
  // El tiempo de la maniobra se pierde parado (a efectos de avance): el
  // tramo dura lo mismo pero recorre menos.
  final lossH = (maneuver?.lossSeconds ?? 0) / 3600.0;
  final distNm = stwKn * math.max(0, stepH - lossH);
  final dest = destinationNm(node.lat, node.lon, headingDeg, distNm);
  final endTime = node.time.add(Duration(seconds: (stepH * 3600).round()));
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
  if (sample?.waveDirDeg != null && sample?.wavePeriodS != null) {
    final enc = waveEncounter(
      headingDeg: headingDeg,
      stwKn: stwKn,
      waveFromDeg: sample!.waveDirDeg!,
      wavePeriodS: sample.wavePeriodS!,
    );
    encAngle = enc.angleDeg;
    encPeriod = enc.periodS;
  }

  final seg = RouteSegment(
    waypointIndex: ctx.legIndex,
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
    waveHeightM: sample?.waveHeightM,
    waveDirDeg: sample?.waveDirDeg,
    wavePeriodS: sample?.wavePeriodS,
    waveEncounterAngleDeg: encAngle,
    waveEncounterPeriodS: encPeriod,
    gustKn: sample?.gustKn,
    maneuver: maneuver,
    noForecast: sample == null,
  );

  final minutes = (stepH * 60).round();
  final c = ctx.req.constraints;
  final excessM = sample?.waveHeightM == null
      ? 0.0
      : math.max(0.0, sample!.waveHeightM! - c.preferredMaxWaveM);
  final minutesAbove = node.minutesAbovePreferred + (excessM > 0 ? minutes : 0);

  // Confort: se penaliza solo lo que PASA de la ola cómoda (antes se
  // penalizaba toda ola, hasta 0,2 m), y más de proa que de popa: la
  // misma Hs recibida de proa es mucho más dura.
  var comfortPenalty = node.comfortPenaltyNm;
  if (ctx.comfortWeight > 0 && excessM > 0) {
    final enc = encAngle?.abs();
    final headFactor = enc == null
        ? 1.0
        : (enc < 60 ? 1.5 : (enc > 120 ? 0.6 : 1.0));
    comfortPenalty += ctx.comfortWeight * excessM * headFactor * stepH;
  }

  return _Node(
    dest.lat,
    dest.lon,
    endTime,
    node,
    seg,
    minutesAbove,
    comfortPenaltyNm: comfortPenalty,
    minutesSinceManeuver: maneuver == null
        ? node.minutesSinceManeuver + minutes
        : minutes.toDouble(),
  );
}

/// Poda por isócronas: para cada sector angular (visto desde el destino,
/// respecto al rumbo directo) se queda solo el nodo mejor puntuado: el que
/// más cerca queda, más la penalización de confort acumulada y un sesgo
/// contra virar seguido. En Confort/Personalizado se descarta el que ya
/// agotó su presupuesto de tiempo con ola por encima de la cómoda.
void _offerCandidate(_LegContext ctx, Map<int, _Node> next, _Node candidate) {
  final maxAbove = ctx.maxMinutesAbovePreferred;
  if (maxAbove != null && candidate.minutesAbovePreferred > maxAbove) {
    ctx.droppedForTimeAbovePreferred = true;
    return;
  }

  final target = ctx.target;
  final remaining = distanceNm(
    candidate.lat,
    candidate.lon,
    target.lat,
    target.lon,
  );
  // El bordo previo a ESTA maniobra es el que se mantuvo antes de virar
  // (minutesSinceManeuver del padre), no el de este nodo.
  final heldBeforeThis =
      candidate.parent?.minutesSinceManeuver ?? kManeuverReferenceMinutes;
  final maneuverBias = candidate.justManeuvered
      ? kManeuverBasePenaltyNm *
            (kManeuverReferenceMinutes /
                math.max(kIsochroneStepMinutes.toDouble(), heldBeforeThis))
      : 0.0;
  candidate
    ..remainingNm = remaining
    ..score = remaining + candidate.comfortPenaltyNm + maneuverBias;

  final bearingFromTarget = bearingDeg(
    target.lat,
    target.lon,
    candidate.lat,
    candidate.lon,
  );
  final sector =
      (normalizeRelativeAngle(bearingFromTarget - ctx.targetBearing) /
              kPruneSectorDeg)
          .round();
  final existing = next[sector];
  if (existing == null || candidate.score < existing.score) {
    next[sector] = candidate;
  }
}

List<RouteSegment> _backtrack(_Node node) {
  final segs = <RouteSegment>[];
  var n = node;
  while (n.parent != null) {
    segs.add(n.arrivingSegment!);
    n = n.parent!;
  }
  return segs.reversed.toList();
}

/// Resumen de una ruta calculada: lo que se enseña al recalcular.
class RouteSummary {
  RouteSummary._({
    required this.totalNm,
    required this.duration,
    required this.departure,
    required this.eta,
    required this.sailDuration,
    required this.motorDuration,
    required this.sailNm,
    required this.motorNm,
    required this.upwindDuration,
    required this.reachDuration,
    required this.downwindDuration,
    required this.maxTwsKn,
    required this.maxGustKn,
    required this.maxAwsKn,
    required this.maxWaveM,
    required this.aboveComfortDuration,
    required this.tacks,
    required this.gybes,
    required this.modeChanges,
    required this.noForecastFrom,
    required this.complete,
    required this.warning,
  });

  final double totalNm;
  final Duration duration;
  final DateTime? departure, eta;
  final Duration sailDuration, motorDuration;
  final double sailNm, motorNm;

  /// Tiempo a vela por ángulo al viento real: ceñida (<70°), través
  /// (70–120°) y popa (>120°).
  final Duration upwindDuration, reachDuration, downwindDuration;
  final double maxTwsKn, maxAwsKn;
  final double? maxGustKn, maxWaveM;
  final Duration aboveComfortDuration;
  final int tacks, gybes, modeChanges;
  final DateTime? noForecastFrom;
  final bool complete;
  final String? warning;

  double get avgSpeedKn =>
      duration.inSeconds <= 0 ? 0 : totalNm / (duration.inSeconds / 3600);

  double get motorFraction {
    final t = sailDuration + motorDuration;
    return t.inSeconds <= 0 ? 0 : motorDuration.inSeconds / t.inSeconds;
  }

  double get upwindFraction => sailDuration.inSeconds <= 0
      ? 0
      : upwindDuration.inSeconds / sailDuration.inSeconds;

  factory RouteSummary.of(RouteResult r, RoutingConstraints c) {
    var sail = Duration.zero, motor = Duration.zero;
    var up = Duration.zero, reach = Duration.zero, down = Duration.zero;
    var above = Duration.zero;
    var sailNm = 0.0, motorNm = 0.0;
    var maxTws = 0.0, maxAws = 0.0;
    double? maxGust, maxWave;
    var tacks = 0, gybes = 0, modeChanges = 0;
    for (final s in r.segments) {
      final d = s.duration;
      if (s.mode == PropulsionMode.motor) {
        motor += d;
        motorNm += s.distanceNm;
      } else {
        sail += d;
        sailNm += s.distanceNm;
        final twa = s.twaDeg.abs();
        if (twa < 70) {
          up += d;
        } else if (twa <= 120) {
          reach += d;
        } else {
          down += d;
        }
      }
      if (s.noForecast) continue;
      maxTws = math.max(maxTws, s.twsKn);
      maxAws = math.max(maxAws, s.awsKn);
      if (s.gustKn != null) maxGust = math.max(maxGust ?? 0, s.gustKn!);
      if (s.waveHeightM != null) {
        maxWave = math.max(maxWave ?? 0, s.waveHeightM!);
        if (s.waveHeightM! > c.preferredMaxWaveM) above += d;
      }
      switch (s.maneuver) {
        case ManeuverKind.tack:
          tacks++;
        case ManeuverKind.gybe:
          gybes++;
        case ManeuverKind.modeChange:
          modeChanges++;
        case null:
      }
    }
    return RouteSummary._(
      totalNm: r.totalNm,
      duration: r.totalDuration,
      departure: r.departure,
      eta: r.eta,
      sailDuration: sail,
      motorDuration: motor,
      sailNm: sailNm,
      motorNm: motorNm,
      upwindDuration: up,
      reachDuration: reach,
      downwindDuration: down,
      maxTwsKn: maxTws,
      maxGustKn: maxGust,
      maxAwsKn: maxAws,
      maxWaveM: maxWave,
      aboveComfortDuration: above,
      tacks: tacks,
      gybes: gybes,
      modeChanges: modeChanges,
      noForecastFrom: r.noForecastFrom,
      complete: r.complete,
      warning: r.warning,
    );
  }
}
