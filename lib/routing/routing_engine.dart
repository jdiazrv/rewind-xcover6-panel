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

/// Freno de cordura: pasadas [kSanityAfterHours] de navegación simulada,
/// si la media hacia el destino (lo que se ha acercado / tiempo) no llega
/// a [kMinUsefulVmgKn], el cálculo se para y lo explica.
const kSanityAfterHours = 2.0;
const kMinUsefulVmgKn = 1.0;

/// Zona de puerto: se relaja el margen de costa, pero nunca se permite
/// cruzar el borde de tierra ni terminar dentro de un polígono.
const kPortApproachNm = 1.5;

/// Poda clásica de isócronas: sectores de este ancho vistos DESDE LA
/// SALIDA de la pierna, quedándose en cada uno con el punto más lejano.
const kPruneSectorDeg = 2.0;

/// Abanico explorado a cada lado del rumbo directo (visto desde la
/// salida): suficiente para rodear islas, cabos y zonas de mal tiempo sin
/// gastar cálculo en ir hacia atrás.
const kFanHalfDeg = 120.0;

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
    this.minimumTwaDeg = 0,
    this.comfortWeight = kComfortWeightDefault,
    this.maxGustKn = 30,
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

  /// Ángulo mínimo al viento verdadero para cualquier modo, incluido motor.
  /// Cero deja el comportamiento anterior; 90 evita navegar contra viento.
  final double minimumTwaDeg;

  /// Margen a la costa (máscara de tierra de Natural Earth 1:50 M): ningún
  /// tramo pasa a menos de esto de tierra. La máscara es de escala media,
  /// no una carta: no sustituye a mirar la carta en la aproximación.
  final double minimumCoastDistanceNm;

  /// Solo en Personalizado: cuánto pesa la ola por encima de la cómoda
  /// frente a llegar antes (0 = como Rápido). Confort usa
  /// [kComfortWeightDefault].
  final double comfortWeight;

  /// Racha máxima admitida (verdadera, del modelo): la ruta no pasa por
  /// donde la supere. Si el modelo no da rachas, no limita.
  final double maxGustKn;

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
    double? minimumTwaDeg,
    double? comfortWeight,
    double? maxGustKn,
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
    minimumTwaDeg: minimumTwaDeg ?? this.minimumTwaDeg,
    comfortWeight: comfortWeight ?? this.comfortWeight,
    maxGustKn: maxGustKn ?? this.maxGustKn,
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
    this.requireCompleteWeather = false,
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

  /// La pantalla de producción exige viento, rachas y ola para todos los
  /// tramos. El valor por defecto conserva los usos históricos del motor.
  final bool requireCompleteWeather;
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
    this.breakAfter = const [],
  });
  final int legIndex;

  /// Paso de 15 min dentro de la pierna (0 = el primero tras salir).
  final int step;
  final DateTime time;
  final List<double> latLon;

  /// Índices tras los que no hay conexión navegable con el siguiente punto.
  final List<int> breakAfter;
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

  // Segunda comprobación solo de la ruta elegida: evita aceptar un tramo
  // que entre en otra celda/hora con peor tiempo sin multiplicar el coste
  // por todos los rumbos explorados.
  if (req.requireCompleteWeather) {
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      String? issue;
      for (final fraction in const [0.5, 1.0]) {
        final p = s.positionAt(fraction);
        final t = s.startTime.add(
          Duration(
            milliseconds: (s.duration.inMilliseconds * fraction).round(),
          ),
        );
        final wx = req.grid.sample(p.lat, p.lon, t);
        if (wx == null) {
          issue = 'falta previsión dentro del tramo';
        } else if (wx.waveHeightM == null || wx.gustKn == null) {
          issue = 'faltan datos de ola o rachas dentro del tramo';
        } else if (wx.waveHeightM! > req.constraints.absoluteMaxWaveM) {
          issue = 'la ola supera el máximo dentro del tramo';
        } else if (wx.gustKn! > req.constraints.maxGustKn) {
          issue = 'las rachas superan el máximo dentro del tramo';
        } else if (trueWindAngle(s.headingDeg, wx.twdDeg) <
            req.constraints.minimumTwaDeg) {
          issue = 'el viento queda demasiado de proa dentro del tramo';
        } else if (apparentWind(
              twsKn: wx.twsKn,
              twdDeg: wx.twdDeg,
              headingDeg: s.headingDeg,
              stwKn: s.stwKn,
            ).awsKn >
            req.constraints.maxAwsKn) {
          issue = 'el viento aparente supera el máximo dentro del tramo';
        }
        if (issue != null) break;
      }
      if (issue != null) {
        reachedIndex = math.min(reachedIndex, s.waypointIndex);
        segments.removeRange(i, segments.length);
        warning = 'Ruta detenida antes del tramo ${i + 1}: $issue.';
        break;
      }
    }
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
  /// Nodo de salida de una pierna. Hereda del último tramo de la pierna
  /// anterior lo necesario para contar como maniobra virar justo en la vía.
  _Node.root(this.lat, this.lon, this.timeMs, RouteSegment? previous)
    : parent = null,
      minutesAbovePreferred = 0,
      comfortPenaltyNm = 0,
      minutesSinceManeuver = kManeuverReferenceMinutes,
      legIndex = previous?.waypointIndex ?? 0,
      headingDeg = previous?.headingDeg ?? 0,
      twdDeg = previous?.twdDeg ?? 0,
      mode = previous?.mode,
      noForecast = previous?.noForecast ?? false,
      maneuver = null,
      stwKn = 0,
      stepH = 0,
      distNm = 0,
      sample = null,
      awsKn = 0,
      awaDeg = 0,
      twaDeg = 0;

  _Node.step({
    required this.lat,
    required this.lon,
    required this.timeMs,
    required _Node this.parent,
    required this.minutesAbovePreferred,
    required this.comfortPenaltyNm,
    required this.minutesSinceManeuver,
    required this.legIndex,
    required this.headingDeg,
    required this.twdDeg,
    required PropulsionMode this.mode,
    required this.noForecast,
    required this.maneuver,
    required this.stwKn,
    required this.stepH,
    required this.distNm,
    required this.sample,
    required this.awsKn,
    required this.awaDeg,
    required this.twaDeg,
  });

  final double lat, lon;

  /// Hora del nodo, en ms desde epoch (UTC): sin crear un DateTime por
  /// cada uno de los miles de candidatos que la poda va a descartar.
  final int timeMs;
  final _Node? parent;
  final int minutesAbovePreferred;
  final double comfortPenaltyNm;

  /// Cuánto lleva el camino en el mismo bordo y modo (vela/motor) sin
  /// virar/trasluchar ni arrancar/parar el motor.
  final double minutesSinceManeuver;

  // ── El tramo que llega a este nodo, en bruto. El RouteSegment completo
  // (con la ola encontrada) solo se construye para los nodos que acaban
  // en la ruta, no para cada candidato.
  final int legIndex;
  final double headingDeg, twdDeg, stwKn, stepH, distNm;
  final PropulsionMode? mode;
  final bool noForecast;
  final ManeuverKind? maneuver;
  final WeatherSample? sample;
  final double awsKn, awaDeg, twaDeg;

  /// Distancia real que falta al destino de la pierna.
  double remainingNm = 0;

  /// Puntuaciones de la poda (menor es mejor): en el abanico visto desde
  /// la salida, y en los sectores vistos desde la llegada.
  double fanScore = 0, approachScore = 0;

  bool get justManeuvered => maneuver != null;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(timeMs, isUtc: true);

  RouteSegment? _segment;

  /// El tramo que llega aquí, completo (solo para nodos que no son la
  /// salida de la pierna).
  RouteSegment get arrivingSegment => _segment ??= _buildSegment();

  RouteSegment _buildSegment() {
    final p = parent!;
    final wx = sample;
    double? encAngle, encPeriod;
    if (wx?.waveDirDeg != null && wx?.wavePeriodS != null) {
      final enc = waveEncounter(
        headingDeg: headingDeg,
        stwKn: stwKn,
        waveFromDeg: wx!.waveDirDeg!,
        wavePeriodS: wx.wavePeriodS!,
      );
      encAngle = enc.angleDeg;
      encPeriod = enc.periodS;
    }
    return RouteSegment(
      waypointIndex: legIndex,
      startLat: p.lat,
      startLon: p.lon,
      endLat: lat,
      endLon: lon,
      startTime: p.time,
      endTime: time,
      headingDeg: headingDeg,
      distanceNm: distNm,
      mode: mode!,
      stwKn: stwKn,
      twsKn: wx?.twsKn ?? 0,
      twdDeg: twdDeg,
      twaDeg: twaDeg,
      awsKn: awsKn,
      awaDeg: awaDeg,
      waveHeightM: wx?.waveHeightM,
      waveDirDeg: wx?.waveDirDeg,
      wavePeriodS: wx?.wavePeriodS,
      waveEncounterAngleDeg: encAngle,
      waveEncounterPeriodS: encPeriod,
      gustKn: wx?.gustKn,
      maneuver: maneuver,
      noForecast: noForecast,
    );
  }
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
  _Node prev,
  double headingDeg,
  double twdDeg,
  PropulsionMode mode,
) {
  final prevMode = prev.mode;
  if (prevMode == null) return null; // primer paso: no hay maniobra que contar
  if (prev.noForecast) return null;
  if (prevMode != mode) return ManeuverKind.modeChange;
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
  // Solo puntos realmente coincidentes: 0,05 M eran casi 100 m sin navegar.
  if (directNm < 1e-5) {
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

  // Solo la costa que de verdad puede tocar esta pierna: en mar abierta,
  // lejos de cualquiera de los polígonos, esto deja la lista vacía y cada
  // rumbo se ahorra un escaneo de 74 costas que nunca iban a estar cerca.
  // Zona que puede explorar esta pierna: la caja salida–llegada con un
  // margen para desvíos (la mitad de la distancia, 0,5° como poco). La
  // costa se mira solo dentro, y por eso ningún punto puede salir de ella
  // (con el abanico, la ruta ya no se pega a la línea recta).
  final marginDeg = math.max(0.5, directNm / 60 * 0.5);
  final legBox = GeoBox(
    south: math.min(start.lat, target.lat) - marginDeg,
    west: math.min(start.lon, target.lon) - marginDeg,
    north: math.max(start.lat, target.lat) + marginDeg,
    east: math.max(start.lon, target.lon) + marginDeg,
  );
  final land = req.land;
  final legLand = (land == null || land.isEmpty)
      ? null
      : land.restrictedTo(
          legBox.south,
          legBox.west,
          legBox.north,
          legBox.east,
          0.05,
        );
  final ctx0 = _LegContext(
    req: req,
    legIndex: legIndex,
    legLand: legLand,
    stepH: stepH,
    start: start,
    legBox: legBox,
    target: target,
    targetBearing: targetBearing,
    comfortWeight: _comfortWeightFor(req),
    maxMinutesAbovePreferred: _limitTimeAbovePreferred(req)
        ? req.constraints.maxTimeAbovePreferred.inMinutes
        : null,
  );
  final ctx = ctx0;
  final factor = (req.polarFactorPercent / 100).clamp(0.1, 1.5);
  if (legLand != null && !legLand.isEmpty) {
    ctx.landIndex = LandSegmentIndex.build(
      legLand,
      south: legBox.south,
      west: legBox.west,
      north: legBox.north,
      east: legBox.east,
      marginNm: req.constraints.minimumCoastDistanceNm,
    );
  }
  if (land != null && !land.isEmpty) {
    final m = req.constraints.minimumCoastDistanceNm;
    ctx.startNearLand =
        land.isLand(start.lat, start.lon) ||
        land.nearLand(start.lat, start.lon, m);
    ctx.targetNearLand =
        land.isLand(target.lat, target.lon) ||
        land.nearLand(target.lat, target.lon, m);
  }

  // El nodo de salida "lleva" el último tramo de la pierna anterior (para
  // contar como maniobra el virar justo en la vía) y un bordo neutro.
  final root = _Node.root(
    start.lat,
    start.lon,
    startTime.toUtc().millisecondsSinceEpoch,
    previous,
  )..remainingNm = directNm;
  var frontier = <_Node>[root];
  _Node best = root;
  // Para detectar una búsqueda atascada: cuándo mejoró por última vez la
  // distancia al destino.
  var bestSeenNm = directNm;
  var lastImproveStep = 0;
  // Y cuándo creció por última vez el abanico (lo más lejos llegado desde
  // la salida): en un rodeo largo la ruta se aleja antes de acercarse,
  // pero el abanico sigue creciendo; atascada, no.
  var bestReachNm = 0.0;
  var lastReachStep = 0;

  for (var step = 0; step < maxSteps; step++) {
    // Progreso = cuánto se ha acercado ya la mejor isócrona al destino.
    // Antes era paso / techo de pasos, y ese techo es 2,2 veces el peor
    // caso: la barra se arrastraba y luego saltaba al 100 %.
    onProgress?.call((1 - best.remainingNm / directNm).clamp(0.0, 0.99));
    if (step > 0) yield null;
    final next = _Pruner();
    // Llegada exacta: si desde algún nodo el destino se alcanza DENTRO de
    // este paso a un rumbo navegable, se llega justo ahí con un paso
    // parcial. Antes solo contaba como llegada caer a menos de 0,35 M, y
    // con pasos de ~1,5 M y rumbos cada 5° una ceñida podía no caer nunca
    // dentro (la pierna "no se completaba") y la ETA iba de 15 en 15 min.
    _Node? finish;
    for (final node in frontier) {
      final sample = req.grid.sampleMs(node.lat, node.lon, node.timeMs);
      if (sample == null) {
        // Fuera de la zona o de las horas del tiempo descargado. Antes se
        // motoraba en silencio; ahora se marca el tramo como "sin
        // previsión" (la pantalla lo avisa) y, sin motor, el nodo muere.
        ctx.sawNoForecast = true;
        if (req.constraints.allowMotor && !req.requireCompleteWeather) {
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
          final runNm = req.constraints.motorSpeedKn * h;
          final end = destinationNm(node.lat, node.lon, bearing, runNm);
          if (!_landBlocked(ctx, node.lat, node.lon, end)) {
            final motorKn = req.constraints.motorSpeedKn;
            final child = _stepNode(
              ctx,
              node,
              headingDeg: bearing,
              stwKn: motorKn,
              mode: PropulsionMode.motor,
              stepH: h,
              distNm: runNm,
              end: end,
              sample: null,
              maneuver: null,
              // Sin viento conocido: el aparente es el de la marcha.
              awsKn: motorKn,
              awaDeg: 0,
              twaDeg: 0,
            );
            if (toTarget <= reach) {
              if (finish == null || child.timeMs < finish.timeMs) {
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
      // Límites que no dependen del rumbo: se miran una vez por nodo.
      final gust = sample.gustKn;
      if (req.requireCompleteWeather && gust == null) {
        ctx.sawMissingGust = true;
        continue;
      }
      if (gust != null && gust > req.constraints.maxGustKn) {
        ctx.rejectedGust++;
        if (gust > ctx.maxGustSeen) ctx.maxGustSeen = gust;
        continue;
      }
      final hs = sample.waveHeightM;
      if (req.requireCompleteWeather && hs == null) {
        ctx.sawMissingWave = true;
        continue;
      }
      if (hs != null && hs > req.constraints.absoluteMaxWaveM) {
        ctx.rejectedWave++;
        if (hs > ctx.maxWaveSeen) ctx.maxWaveSeen = hs;
        continue;
      }
      // La curva de la polar solo depende del TWS de este nodo, no del
      // rumbo: se construye UNA vez y se reutiliza en los 72 candidatos.
      final wx = _NodeWx(
        node,
        sample,
        req.polar.curveFor(sample.twsKn),
        factor,
      );
      final toTargetDeg = bearingDeg(
        node.lat,
        node.lon,
        target.lat,
        target.lon,
      );
      final fin = _headingCandidate(
        ctx,
        wx,
        headingDeg: toTargetDeg,
        sinH: math.sin(toTargetDeg * math.pi / 180),
        cosH: math.cos(toTargetDeg * math.pi / 180),
        finishDistNm: node.remainingNm,
      );
      if (fin != null && (finish == null || fin.timeMs < finish.timeMs)) {
        finish = fin;
      }
      for (var k = 0; k < _candidateHeadings.length; k++) {
        final child = _headingCandidate(
          ctx,
          wx,
          headingDeg: _candidateHeadings[k],
          sinH: _headingSin[k],
          cosH: _headingCos[k],
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
            'descargadas)';
      } else if (ctx.sawMissingWave || ctx.sawMissingGust) {
        reason = ctx.sawMissingWave
            ? 'faltan datos de oleaje para comprobar el límite de ola'
            : 'faltan datos de rachas para comprobar el límite de viento';
      } else if (ctx.droppedForTimeAbovePreferred) {
        reason =
            'haría falta más de ${_minutesText(ctx.maxMinutesAbovePreferred!)} '
            'con ola por encima de la cómoda (ajústalo o usa Rápido)';
      } else if (stuckOnCoast) {
        reason = 'rodeado de costa, sin paso navegable';
      } else {
        reason = _limitReason(ctx);
      }
      yield _LegResult(_backtrack(closest), false, reason);
      return;
    }
    frontier = next.frontier();
    for (final n in frontier) {
      if (n.remainingNm < best.remainingNm) best = n;
    }
    // Cordura: si tras un rato la isócrona apenas AVANZA (lo más lejos que
    // ha llegado desde la salida), el resultado sería absurdo — días para
    // unas millas —: se para y se explica, en vez de seguir hasta el techo
    // de pasos. Se mide lo avanzado y no lo acercado al destino: un rodeo
    // (un istmo, una zona de rachas) pasa horas sin acercarse y es
    // correcto. Reportado en vivo 2026-09-19.
    if (best.remainingNm < bestSeenNm - 0.2) {
      bestSeenNm = best.remainingNm;
      lastImproveStep = step;
    }
    var reachNm = directNm - best.remainingNm;
    for (final n in frontier) {
      final d = distanceNm(start.lat, start.lon, n.lat, n.lon);
      if (d > reachNm) reachNm = d;
    }
    if (reachNm > bestReachNm + 0.5) {
      bestReachNm = reachNm;
      lastReachStep = step;
    }
    final stalled = step - lastImproveStep;
    final fanStalled = step - lastReachStep;
    // Atascado cerca del final (1 h sin acercarse estando a menos de 3 M)
    // o, lejos, 12 h sin acercarse y sin que crezca el abanico (un rodeo
    // largo pasa horas sin acercarse; lo absurdo lejos ya lo para el freno
    // de media < 1 kn):
    // se para y se dice, en vez de seguir hasta el techo de pasos (llegó a
    // verse "salida + 12 h" rondando la llegada sin poder terminar).
    if ((best.remainingNm < 3 && stalled >= 4) ||
        (stalled >= 48 && fanStalled >= 8)) {
      final near = best.remainingNm < 3;
      yield _LegResult(
        _backtrack(best),
        false,
        near
            ? 'atascado a ${best.remainingNm.toStringAsFixed(1)} M de la llegada: '
                  'no encuentra cómo terminar. Si está dentro de un puerto o '
                  'pegada a la costa, ponla en agua libre, fuera de la bocana '
                  '(la costa del cálculo es aproximada)'
            : 'sin acercarse al destino en ${_minutesText(stalled * kIsochroneStepMinutes)}: '
                  'no encuentra paso (costa, límites o calma)',
      );
      return;
    }
    final elapsedH = (step + 1) * stepH;
    if (elapsedH >= kSanityAfterHours) {
      final avg = reachNm / elapsedH;
      if (avg < kMinUsefulVmgKn) {
        yield _LegResult(
          _backtrack(best),
          false,
          'cálculo detenido: resultado absurdo. En ${_minutesText((elapsedH * 60).round())} '
          'solo avanza ${reachNm.toStringAsFixed(1)} M (media '
          '${avg.toStringAsFixed(1)} kn). Revisa el viento, la polar o los '
          'límites (motor, viento máx., ola, AWA)',
        );
        return;
      }
    }
    if (onIsochrone != null) {
      final keys = next.fan.keys.toList()..sort();
      final fan = [for (final k in keys) next.fan[k]!];
      final breaks = <int>[];
      final cosLat = math.cos(ctx.start.lat * math.pi / 180);
      const maxGapDeg2 = 0.05 * 0.05; // 3 M, sin trigonometría por par.
      for (var i = 0; i + 1 < fan.length; i++) {
        final a = fan[i], b = fan[i + 1];
        final dLat = a.lat - b.lat;
        final dLon = (a.lon - b.lon) * cosLat;
        if (dLat * dLat + dLon * dLon > maxGapDeg2 ||
            (ctx.landIndex?.segmentBlocked(
                  a.lat,
                  a.lon,
                  b.lat,
                  b.lon,
                  clearanceNm: 0,
                ) ??
                false)) {
          breaks.add(i);
        }
      }
      onIsochrone(
        RouteIsochrone(
          legIndex: legIndex,
          step: step,
          time: frontier.first.time,
          latLon: [
            for (final node in fan) ...[node.lat, node.lon],
          ],
          breakAfter: breaks,
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

/// La causa que más ha bloqueado, dicha con sus números.
String _limitReason(_LegContext ctx) {
  final c = ctx.req.constraints;
  final causes = <(int, String)>[
    (
      ctx.rejectedGust,
      'rachas de hasta ${ctx.maxGustSeen.round()} kn, por encima de tu máximo '
          '(${c.maxGustKn.round()} kn): no hay paso posible. Sube "Racha máx." '
          'en Ajustes o prueba otra hora de salida',
    ),
    (
      ctx.rejectedWave,
      'ola de hasta ${ctx.maxWaveSeen.toStringAsFixed(1)} m, por encima de tu '
          'máximo (${c.absoluteMaxWaveM.toStringAsFixed(1)} m): no hay paso '
          'posible. Sube "Ola máxima" o prueba otra hora de salida',
    ),
    (
      ctx.rejectedAws,
      'viento aparente por encima de tu máximo (${c.maxAwsKn.round()} kn) en '
          'todos los rumbos posibles',
    ),
  ]..sort((a, b) => b.$1.compareTo(a.$1));
  if (causes.first.$1 > 0) return causes.first.$2;
  return c.allowMotor
      ? 'sin rumbo navegable'
      : 'sin rumbo navegable a vela (calma o ángulo muerto) y sin motor permitido';
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
    required this.start,
    required this.legBox,
    required this.target,
    required this.targetBearing,
    required this.comfortWeight,
    required this.maxMinutesAbovePreferred,
  });
  final RouteRequest req;
  final int legIndex;
  final LandMask? legLand;
  final double stepH;
  final ({double lat, double lon}) start;
  late final GeoAnchor startAnchor = GeoAnchor(start.lat, start.lon);
  late final GeoAnchor targetAnchor = GeoAnchor(target.lat, target.lon);
  final GeoBox legBox;
  bool startNearLand = false, targetNearLand = false;

  /// Costa de la pierna indexada para la comprobación exacta de tramos.
  LandSegmentIndex? landIndex;
  final ({double lat, double lon}) target;
  final double targetBearing;
  final double comfortWeight;
  final int? maxMinutesAbovePreferred;

  /// Para explicar por qué una pierna no se completa.
  bool sawNoForecast = false;
  bool sawMissingWave = false, sawMissingGust = false;
  bool droppedForTimeAbovePreferred = false;

  /// Por qué se descartan nodos y rumbos, para explicar una pierna que no
  /// se completa con la causa real (no un "sin rumbo navegable" genérico).
  int rejectedGust = 0, rejectedWave = 0, rejectedAws = 0;
  double maxGustSeen = 0, maxWaveSeen = 0;
}

/// ¿El tramo de [startLat]/[startLon] al punto que resulta de navegar
/// [distNm] millas al rumbo [headingDeg] pisa tierra o se queda a menos
/// del margen de seguridad?
bool _inPortZone(_LegContext ctx, double lat, double lon) =>
    (ctx.startNearLand &&
        distanceNm(lat, lon, ctx.start.lat, ctx.start.lon) <=
            kPortApproachNm) ||
    (ctx.targetNearLand &&
        distanceNm(lat, lon, ctx.target.lat, ctx.target.lon) <=
            kPortApproachNm);

/// ¿El tramo de ([lat], [lon]) a [end] cruza la costa o pasa a menos del
/// margen? En la zona de puerto se relaja el margen, nunca el cruce real.
bool _landBlocked(
  _LegContext ctx,
  double lat,
  double lon,
  ({double lat, double lon}) end,
) {
  final idx = ctx.landIndex;
  if (idx == null) return false;
  final startInZone = _inPortZone(ctx, lat, lon);
  if (startInZone && _inPortZone(ctx, end.lat, end.lon)) {
    return ctx.legLand!.isLand(end.lat, end.lon) ||
        idx.segmentBlocked(lat, lon, end.lat, end.lon, clearanceNm: 0);
  }
  if (idx.segmentBlocked(lat, lon, end.lat, end.lon)) return true;
  if (startInZone && ctx.legLand!.isLand(end.lat, end.lon)) return true;
  return false;
}

/// Evalúa un rumbo candidato: decide vela/motor, aplica los límites de
/// AWS y ola, descuenta el tiempo de la maniobra si la hay, y devuelve el
/// nodo resultante (o null si el rumbo no es utilizable). Con
/// [finishDistNm], solo vale si llega a esa distancia dentro del paso.
_Node? _headingCandidate(
  _LegContext ctx,
  _NodeWx wx, {
  required double headingDeg,
  required double sinH,
  required double cosH,
  double? finishDistNm,
}) {
  final node = wx.node;
  final sample = wx.sample;
  final c = ctx.req.constraints;
  final twa = trueWindAngle(headingDeg, sample.twdDeg);
  if (twa < c.minimumTwaDeg) return null;
  final sailStw = PolarTable.speedAtCurve(wx.curve, twa);
  final sailSpeed = sailStw == null ? null : sailStw * wx.factor;

  // El ángulo de ceñida de la polar (beatAngle) es el óptimo del VPP en
  // banco de pruebas; a velocidad real, el aparente que le corresponde
  // puede salir más cerrado de lo que las velas aguantan trimadas de
  // verdad. minimumAwaDeg es el tope de eso: por debajo, sin motor, el
  // barco tiene que abrir el rumbo; con motor, ese rumbo va a motor.
  ({double awsKn, double awaDeg})? sailAw;
  var sailPhysicallyValid = false;
  if (sailSpeed != null) {
    sailAw = _apparent(wx.wu, wx.wv, sinH, cosH, headingDeg, sailSpeed);
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
    aw = _apparent(wx.wu, wx.wv, sinH, cosH, headingDeg, stw);
  } else if (sailPhysicallyValid && sailSpeed! > 0) {
    stw = sailSpeed;
    mode = PropulsionMode.sailing;
    aw = sailAw!;
  } else {
    // Ángulo muerto, o el aparente saldría demasiado cerrado para
    // trimar, y sin motor: rumbo inútil.
    return null;
  }
  if (aw.awsKn > c.maxAwsKn) {
    ctx.rejectedAws++;
    return null;
  }

  final maneuver = _maneuverBetween(node, headingDeg, sample.twdDeg, mode);
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

  final runNm = stw * math.max(0, thisStepH - lossH);
  final end = _destination(wx.sinLat, wx.cosLat, wx.lonRad, sinH, cosH, runNm);
  if (_landBlocked(ctx, node.lat, node.lon, end)) return null;

  return _stepNode(
    ctx,
    node,
    headingDeg: headingDeg,
    stwKn: stw,
    mode: mode,
    stepH: thisStepH,
    distNm: runNm,
    end: end,
    sample: sample,
    maneuver: maneuver,
    awsKn: aw.awsKn,
    awaDeg: aw.awaDeg,
    twaDeg: twa,
  );
}

/// Lo que de un nodo no depende del rumbo, calculado una vez para sus 72
/// candidatos: el tiempo en su punto y hora, la curva de la polar a ese
/// viento, el viento en componentes y los términos trigonométricos de su
/// posición. Mismas fórmulas que [apparentWind] y [destinationNm], con los
/// términos repetidos guardados: el resultado es idéntico.
class _NodeWx {
  _NodeWx(this.node, this.sample, this.curve, this.factor)
    : sinLat = math.sin(node.lat * math.pi / 180),
      cosLat = math.cos(node.lat * math.pi / 180),
      lonRad = node.lon * math.pi / 180,
      wu = -sample.twsKn * math.sin(sample.twdDeg * math.pi / 180),
      wv = -sample.twsKn * math.cos(sample.twdDeg * math.pi / 180);
  final _Node node;
  final WeatherSample sample;
  final List<(double, double)> curve;
  final double factor;
  final double sinLat, cosLat, lonRad;

  /// Viento verdadero hacia donde sopla (este, norte).
  final double wu, wv;
}

/// Senos y cosenos de los rumbos candidatos (0, 5, … 355°), una sola vez.
final _candidateHeadings = [for (var h = 0.0; h < 360; h += kHeadingStepDeg) h];
final _headingSin = [
  for (final h in _candidateHeadings) math.sin(h * math.pi / 180),
];
final _headingCos = [
  for (final h in _candidateHeadings) math.cos(h * math.pi / 180),
];

/// [apparentWind] con el viento ya en componentes y el rumbo ya en
/// seno/coseno.
({double awsKn, double awaDeg}) _apparent(
  double wu,
  double wv,
  double sinH,
  double cosH,
  double headingDeg,
  double stwKn,
) {
  final au = wu - stwKn * sinH, av = wv - stwKn * cosH;
  final aws = math.sqrt(au * au + av * av);
  final awFromDeg = (math.atan2(-au, -av) * 180 / math.pi + 360) % 360;
  return (awsKn: aws, awaDeg: normalizeRelativeAngle(awFromDeg - headingDeg));
}

/// [destinationNm] con la latitud de salida y el rumbo ya en seno/coseno.
({double lat, double lon}) _destination(
  double sinP1,
  double cosP1,
  double lonRad,
  double sinB,
  double cosB,
  double distNm,
) {
  final d = distNm / kEarthRadiusNm;
  final sinD = math.sin(d), cosD = math.cos(d);
  final p2 = math.asin(sinP1 * cosD + cosP1 * sinD * cosB);
  final l2 =
      lonRad + math.atan2(sinB * sinD * cosP1, cosD - sinP1 * math.sin(p2));
  return (lat: p2 * 180 / math.pi, lon: (l2 * 180 / math.pi + 540) % 360 - 180);
}

_Node _stepNode(
  _LegContext ctx,
  _Node node, {
  required double headingDeg,
  required double stwKn,
  required PropulsionMode mode,
  required double stepH,
  required double distNm,
  required ({double lat, double lon}) end,
  required WeatherSample? sample,
  required ManeuverKind? maneuver,
  required double awsKn,
  required double awaDeg,
  required double twaDeg,
}) {
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
    final waveFrom = sample?.waveDirDeg;
    final enc = waveFrom == null
        ? null
        : normalizeRelativeAngle(headingDeg - waveFrom).abs();
    final headFactor = enc == null
        ? 1.0
        : (enc < 60 ? 1.5 : (enc > 120 ? 0.6 : 1.0));
    comfortPenalty += ctx.comfortWeight * excessM * headFactor * stepH;
  }

  return _Node.step(
    lat: end.lat,
    lon: end.lon,
    timeMs: node.timeMs + (stepH * 3600).round() * 1000,
    parent: node,
    minutesAbovePreferred: minutesAbove,
    comfortPenaltyNm: comfortPenalty,
    minutesSinceManeuver: maneuver == null
        ? node.minutesSinceManeuver + minutes
        : minutes.toDouble(),
    legIndex: ctx.legIndex,
    headingDeg: headingDeg,
    twdDeg: sample?.twdDeg ?? headingDeg,
    mode: mode,
    noForecast: sample == null,
    maneuver: maneuver,
    stwKn: stwKn,
    stepH: stepH,
    distNm: distNm,
    sample: sample,
    awsKn: awsKn,
    awaDeg: awaDeg,
    twaDeg: twaDeg,
  );
}

/// Sectores vistos desde la llegada, para la poda de aproximación.
const kApproachSectorDeg = 5.0;

/// Poda de la isócrona: la unión de dos, cada una con sus sectores.
/// - Abanico (visto desde la SALIDA, [kPruneSectorDeg]): en cada sector el
///   punto que más lejos ha llegado. Es el método clásico: la isócrona se
///   abre y puede rodear lo que haya en medio.
/// - Aproximación (vista desde la LLEGADA, [kApproachSectorDeg]): en cada
///   sector el punto más cercano a la llegada. El abanico solo no ve lo
///   que queda a la sombra de un obstáculo visto desde la salida (una
///   llegada justo detrás de un istmo: los puntos que remontan hacia ella
///   pierden frente a los que siguen corriendo más lejos).
/// La unión nunca pierde un camino que encontrara cualquiera de las dos.
class _Pruner {
  final fan = <int, _Node>{};
  final approach = <int, _Node>{};

  bool get isEmpty => fan.isEmpty && approach.isEmpty;

  List<_Node> frontier() {
    final out = <_Node>[...fan.values];
    final seen = Set<_Node>.identity()..addAll(out);
    for (final n in approach.values) {
      if (seen.add(n)) out.add(n);
    }
    return out;
  }
}

/// Ofrece un candidato a la poda (ver [_Pruner]). Las penalizaciones de
/// confort (acumulada) y el sesgo contra virar seguido cuentan en las dos.
/// En Confort/Personalizado se descarta además el que ya agotó su tiempo
/// con ola incómoda.
void _offerCandidate(_LegContext ctx, _Pruner next, _Node candidate) {
  final maxAbove = ctx.maxMinutesAbovePreferred;
  if (maxAbove != null && candidate.minutesAbovePreferred > maxAbove) {
    ctx.droppedForTimeAbovePreferred = true;
    return;
  }
  // Fuera de la zona de la pierna (costa sin mirar) o del tiempo
  // descargado: no se explora.
  if (!ctx.legBox.contains(candidate.lat, candidate.lon)) return;
  if (!ctx.req.grid.box.contains(candidate.lat, candidate.lon)) return;

  // Seno y coseno de la latitud del candidato, una vez para las cuatro
  // medidas (distancia y rumbo a la llegada y a la salida).
  final p = candidate.lat * math.pi / 180;
  final sinP = math.sin(p), cosP = math.cos(p);
  final toTarget = anchorDistanceBearing(
    ctx.targetAnchor,
    p,
    sinP,
    cosP,
    candidate.lon,
  );
  final remaining = toTarget.distNm;
  // El bordo previo a ESTA maniobra es el que se mantuvo antes de virar
  // (minutesSinceManeuver del padre), no el de este nodo.
  final heldBeforeThis =
      candidate.parent?.minutesSinceManeuver ?? kManeuverReferenceMinutes;
  final maneuverBias = candidate.justManeuvered
      ? kManeuverBasePenaltyNm *
            (kManeuverReferenceMinutes /
                math.max(kIsochroneStepMinutes.toDouble(), heldBeforeThis))
      : 0.0;
  final penalty = candidate.comfortPenaltyNm + maneuverBias;
  candidate.remainingNm = remaining;

  // Aproximación: sectores vistos desde la llegada, el más cercano.
  candidate.approachScore = remaining + penalty;
  final aSector = remaining < 1e-6
      ? 0
      : (normalizeRelativeAngle(toTarget.bearingFrom - ctx.targetBearing) /
                kApproachSectorDeg)
            .round();
  final a = next.approach[aSector];
  if (a == null || candidate.approachScore < a.approachScore) {
    next.approach[aSector] = candidate;
  }

  // Abanico: sectores vistos desde la salida, el más lejano.
  final fromStart = anchorDistanceBearing(
    ctx.startAnchor,
    p,
    sinP,
    cosP,
    candidate.lon,
  );
  final fromStartNm = fromStart.distNm;
  final rel = fromStartNm < 1e-6
      ? 0.0
      : normalizeRelativeAngle(fromStart.bearingFrom - ctx.targetBearing);
  if (rel.abs() > kFanHalfDeg) return;
  candidate.fanScore = -fromStartNm + penalty;
  final sector = (rel / kPruneSectorDeg).round();
  final f = next.fan[sector];
  if (f == null || candidate.fanScore < f.fanScore) {
    next.fan[sector] = candidate;
  }
}

List<RouteSegment> _backtrack(_Node node) {
  final segs = <RouteSegment>[];
  var n = node;
  while (n.parent != null) {
    segs.add(n.arrivingSegment);
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
