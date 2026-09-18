// Pantalla de weather routing (planificación, no instrumento en vivo).
//
// Hasta 10 puntos (salida + 8 vías + llegada), elegidos en el mapa. La
// polar es la que ya tiene la app para este barco (CFG › Barco): aquí no
// se elige otra. El motor de cálculo vive en routing_engine.dart: decide
// vela/motor y los bordos como parte de la propia ruta, no encima de una
// ruta ya trazada.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart' as ll;
import 'package:shared_preferences/shared_preferences.dart';

import '../geocode.dart';
import '../polars.dart';
import '../theme.dart';
import 'geo.dart';
import 'land_mask.dart';
import 'routing_engine.dart';
import 'sailing_calc.dart';
import 'weather.dart';

const _kOsmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _kSeamarkTileUrl = 'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png';

/// Ruta máxima: más allá, ni el pronóstico ni la máscara de costa dan para
/// fiarse, y el cálculo crece sin necesidad.
const kMaxRouteNm = 200.0;

/// Vías intermedias como mucho: con salida y llegada son 10 puntos.
const kMaxVias = 8;

/// Horas de pronóstico que se bajan a partir de la salida: 200 M a 4 kn de
/// media son 50 h, más margen para los bordos.
const _kForecastHours = 60;

// Umbrales de color de la capa de ola de fondo (independientes de las
// restricciones del routing, que se editan en el diálogo de ajustes).
const _kWavePreferredM = 0.60;
const _kWaveMaxM = 1.00;

const _cSailing = cCyan;
const _cMotor = cOrange;

enum _Slot { origin, destination, via }

class _Target {
  const _Target(this.slot, [this.viaIndex = -1]);
  final _Slot slot;
  final int viaIndex; // solo para _Slot.via; -1 = vía nueva al final

  @override
  bool operator ==(Object other) =>
      other is _Target && other.slot == slot && other.viaIndex == viaIndex;
  @override
  int get hashCode => Object.hash(slot, viaIndex);
}

class RoutingPage extends StatefulWidget {
  const RoutingPage({
    super.key,
    required this.weather,
    required this.boatLat,
    required this.boatLon,
    required this.polar,
    required this.polarFactorPercent,
    this.shipIconAsset,
  });

  /// Proveedor con caché, del estado de la app: vive más que la pantalla,
  /// así que cerrar y abrir no vuelve a descargar.
  final WeatherProvider weather;
  final double? boatLat, boatLon;
  final PolarTable? polar;
  final double polarFactorPercent;

  /// El icono de barco elegido en CFG (mismo que ANC y AIS): el barco que
  /// se mueve con el slider lo usa en vez de una flecha genérica.
  final String? shipIconAsset;

  @override
  State<RoutingPage> createState() => _RoutingPageState();
}

class _RoutingPageState extends State<RoutingPage> {
  final _map = fm.MapController();
  final _mapKey = GlobalKey();
  _Target? _dragging;
  _Target? _etaTarget;

  ll.LatLng? _origin, _destination;
  final List<ll.LatLng> _vias = [];
  String? _originName, _destinationName;
  _Target? _placing;

  WeatherModel _model = WeatherModel.ecmwf;
  late DateTime _departure = _nextQuarter(DateTime.now());

  RoutingConstraints _constraints = const RoutingConstraints();
  RoutingObjective _objective = RoutingObjective.fast;

  WeatherGrid? _grid;
  bool _loadingWeather = false;
  String? _weatherError;
  int _fetchSerial = 0;

  RouteResult? _route;
  bool _routeStale = false;
  bool _routing = false;
  double _routeProgress = 0;
  String? _routeError;
  int _routeSerial = 0;

  DateTime? _viewTime;
  Timer? _debounce;

  bool _showWind = true;
  bool _showWaves = true;

  ll.LatLng? _inspectAt;

  LandMask? _land;

  @override
  void initState() {
    super.initState();
    if (widget.boatLat != null && widget.boatLon != null) {
      _origin = ll.LatLng(widget.boatLat!, widget.boatLon!);
    }
    unawaited(_loadLand());
    unawaited(_restore());
  }

  /// Costa del Mediterráneo y el mar Negro (Natural Earth 1:50 M,
  /// recortada y simplificada, ~50 KB). Sin ella la ruta se calcula
  /// igual, solo sin evitar tierra — por eso los fallos aquí no se
  /// enseñan, solo se recalcula en cuanto carga.
  Future<void> _loadLand() async {
    try {
      final raw = await rootBundle.loadString('assets/land/land_med.json');
      if (!mounted) return;
      setState(() => _land = LandMask.fromJson(raw));
      unawaited(_computeRoute());
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // ── Persistencia: puntos, modelo y restricciones, para volver a la
  // misma planificación al reabrir la pantalla.
  static const _kPrefModel = 'routing.model';
  static const _kPrefOrigin = 'routing.origin';
  static const _kPrefDest = 'routing.destination';
  static const _kPrefVias = 'routing.vias';
  static const _kPrefMinStw = 'routing.minStw';
  static const _kPrefAllowMotor = 'routing.allowMotor';
  static const _kPrefMotorKn = 'routing.motorKn';
  static const _kPrefMaxAws = 'routing.maxAws';
  static const _kPrefPrefWave = 'routing.prefWave';
  static const _kPrefAbsWave = 'routing.absWave';
  static const _kPrefObjective = 'routing.objective';
  static const _kPrefMinAwa = 'routing.minAwa';

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      ll.LatLng? read(String k) {
        final v = p.getString(k)?.split(',');
        if (v == null || v.length != 2) return null;
        final lat = double.tryParse(v[0]), lon = double.tryParse(v[1]);
        return lat == null || lon == null ? null : ll.LatLng(lat, lon);
      }

      if (!mounted) return;
      setState(() {
        _model = WeatherModel.byName(p.getString(_kPrefModel));
        // La salida guardada solo manda si no hay posición del barco.
        _origin ??= read(_kPrefOrigin);
        _destination = read(_kPrefDest);
        _vias
          ..clear()
          ..addAll(
            (p.getString(_kPrefVias) ?? '')
                .split(';')
                .where((s) => s.isNotEmpty)
                .map((s) {
                  final v = s.split(',');
                  return ll.LatLng(double.parse(v[0]), double.parse(v[1]));
                }),
          );
        _constraints = RoutingConstraints(
          minimumSailingSTW: p.getDouble(_kPrefMinStw) ?? 4.0,
          allowMotor: p.getBool(_kPrefAllowMotor) ?? true,
          motorSpeedKn: p.getDouble(_kPrefMotorKn) ?? 5.5,
          maxAwsKn: p.getDouble(_kPrefMaxAws) ?? 25,
          preferredMaxWaveM: p.getDouble(_kPrefPrefWave) ?? 0.60,
          absoluteMaxWaveM: p.getDouble(_kPrefAbsWave) ?? 1.00,
          // Sin ajuste guardado todavía, se propone el de la propia
          // polar (cada barco cierra distinto) en vez de un 30° fijo.
          minimumAwaDeg:
              p.getDouble(_kPrefMinAwa) ??
              (widget.polar != null
                  ? polarTypicalBeatAwaDeg(widget.polar!)
                  : null) ??
              30,
        );
        _objective = RoutingObjective.values.firstWhere(
          (o) => o.name == p.getString(_kPrefObjective),
          orElse: () => RoutingObjective.fast,
        );
      });
    } catch (_) {}
    _nameOrigin();
    _nameDestination();
    _fitPoints();
    unawaited(_recompute());
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kPrefModel, _model.name);
      String enc(ll.LatLng x) => '${x.latitude},${x.longitude}';
      if (_origin != null) {
        await p.setString(_kPrefOrigin, enc(_origin!));
      } else {
        await p.remove(_kPrefOrigin);
      }
      if (_destination != null) {
        await p.setString(_kPrefDest, enc(_destination!));
      } else {
        await p.remove(_kPrefDest);
      }
      await p.setString(_kPrefVias, _vias.map(enc).join(';'));
      await p.setDouble(_kPrefMinStw, _constraints.minimumSailingSTW);
      await p.setBool(_kPrefAllowMotor, _constraints.allowMotor);
      await p.setDouble(_kPrefMotorKn, _constraints.motorSpeedKn);
      await p.setDouble(_kPrefMaxAws, _constraints.maxAwsKn);
      await p.setDouble(_kPrefPrefWave, _constraints.preferredMaxWaveM);
      await p.setDouble(_kPrefAbsWave, _constraints.absoluteMaxWaveM);
      await p.setDouble(_kPrefMinAwa, _constraints.minimumAwaDeg);
      await p.setString(_kPrefObjective, _objective.name);
    } catch (_) {}
  }

  void _nameOrigin() {
    final o = _origin;
    if (o == null) return;
    _originName = null;
    reverseGeocode(o.latitude, o.longitude).then((n) {
      if (mounted && _origin == o) setState(() => _originName = n);
    }).catchError((_) {});
  }

  void _nameDestination() {
    final d = _destination;
    if (d == null) return;
    _destinationName = null;
    reverseGeocode(d.latitude, d.longitude).then((n) {
      if (mounted && _destination == d) setState(() => _destinationName = n);
    }).catchError((_) {});
  }

  static DateTime _nextQuarter(DateTime t) {
    final m = (t.minute ~/ 15 + 1) * 15;
    return DateTime(t.year, t.month, t.day, t.hour).add(Duration(minutes: m));
  }

  List<ll.LatLng> get _orderedPoints => [?_origin, ..._vias, ?_destination];

  /// Suma de tramos directos S→vía→…→L. No es la distancia que se acabará
  /// navegando (eso lo decide la ruta calculada), solo el criterio para
  /// avisar de que 200 M es demasiado para fiarse del pronóstico y de la
  /// zona descargada.
  double? get _directRouteNm {
    final pts = _orderedPoints;
    if (pts.length < 2) return null;
    var total = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      total += distanceNm(
        pts[i].latitude,
        pts[i].longitude,
        pts[i + 1].latitude,
        pts[i + 1].longitude,
      );
    }
    return total;
  }

  bool get _tooFar => (_directRouteNm ?? 0) > kMaxRouteNm;

  /// Zona de tiempo a descargar: la que abarca todos los puntos con un
  /// margen para los bordos (un cuarto de la distancia, 20 M como
  /// mínimo). Con un solo punto, un círculo de 40 M alrededor.
  GeoBox? get _weatherBox {
    final pts = _orderedPoints;
    if (pts.isEmpty) return null;
    final around = GeoBox.around([
      for (final p in pts) (lat: p.latitude, lon: p.longitude),
    ]);
    if (pts.length < 2) return around.expandNm(40);
    return around.expandNm(math.max(20, (_directRouteNm ?? 20) * 0.25));
  }

  Future<void> _fetch() async {
    final box = _weatherBox;
    if (box == null || _tooFar) return;
    final serial = ++_fetchSerial;
    setState(() {
      _loadingWeather = true;
      _weatherError = null;
    });
    try {
      final from = _departure.toUtc();
      final g = await widget.weather.fetchGrid(
        box: box,
        from: from,
        to: from.add(const Duration(hours: _kForecastHours)),
        model: _model,
      );
      if (!mounted || serial != _fetchSerial) return;
      setState(() {
        _grid = g;
        if (_route == null) {
          final vt = _viewTime;
          if (vt == null || vt.isBefore(g.start) || vt.isAfter(g.end)) {
            _viewTime = _clampTime(_departure.toUtc(), g);
          }
        }
      });
    } catch (e) {
      if (!mounted || serial != _fetchSerial) return;
      setState(() => _weatherError = 'No se pudo descargar el tiempo: $e');
    } finally {
      if (mounted && serial == _fetchSerial) {
        setState(() => _loadingWeather = false);
      }
    }
  }

  static DateTime _clampTime(DateTime t, WeatherGrid g) =>
      t.isBefore(g.start) ? g.start : (t.isAfter(g.end) ? g.end : t);

  Future<void> _computeRoute() async {
    final o = _origin, d = _destination, grid = _grid, polar = widget.polar;
    if (o == null || d == null || grid == null || polar == null || _tooFar) {
      if (_route != null) setState(() => _route = null);
      return;
    }
    final serial = ++_routeSerial;
    setState(() {
      _routing = true;
      _routeProgress = 0;
      _routeError = null;
      _routeStale = false;
    });
    try {
      final waypoints = [
        (lat: o.latitude, lon: o.longitude),
        for (final v in _vias) (lat: v.latitude, lon: v.longitude),
        (lat: d.latitude, lon: d.longitude),
      ];
      final result = await computeRouteInIsolate(
        RouteRequest(
          waypoints: waypoints,
          departure: _departure.toUtc(),
          grid: grid,
          polar: polar,
          polarFactorPercent: widget.polarFactorPercent,
          constraints: _constraints,
          objective: _objective,
          land: _land,
        ),
        (f) {
          if (mounted && serial == _routeSerial) setState(() => _routeProgress = f);
        },
      );
      if (!mounted || serial != _routeSerial) return;
      setState(() {
        _route = result;
        _routeError = result.warning;
        final dep = result.departure, eta = result.eta;
        if (dep != null && eta != null) {
          final vt = _viewTime;
          if (vt == null || vt.isBefore(dep) || vt.isAfter(eta)) {
            _viewTime = dep;
          }
        }
      });
    } catch (e) {
      if (!mounted || serial != _routeSerial) return;
      setState(() {
        _route = null;
        _routeError = 'No se pudo calcular la ruta: $e';
      });
    } finally {
      if (mounted && serial == _routeSerial) setState(() => _routing = false);
    }
  }

  /// Mueve un punto, cambia la salida, añade una vía… todo eso baja el
  /// tiempo (barato, hace falta para las capas) pero YA NO lanza el motor
  /// de rutas solo: eso quedaba calculando de fondo en cada paso de un
  /// arrastre. Marca la ruta como desactualizada y deja el botón
  /// "Recalcular" a mano. Reportado en vivo 2026-09-18.
  Future<void> _recompute() async {
    unawaited(_persist());
    if (_tooFar) {
      setState(() {
        _grid = null;
        _route = null;
        _routeStale = false;
      });
      return;
    }
    await _fetch();
    if (!mounted) return;
    if (_origin != null && _destination != null && widget.polar != null) {
      setState(() => _routeStale = true);
    }
  }

  Future<void> _recalculate() async {
    setState(() => _routeStale = false);
    await _computeRoute();
  }

  /// Se llama justo después de mover, añadir o quitar cualquier punto:
  /// la ruta ya calculada deja de valer EN EL ACTO (no solo "desfasada"
  /// mientras se sigue viendo la antigua) — en su lugar, la guía
  /// discontinua S→vías→L hasta que se pulse Recalcular. Reportado en
  /// vivo 2026-09-18.
  void _scheduleRecompute() {
    if (_route != null || _routeStale) {
      setState(() {
        _route = null;
        _routeStale = false;
      });
    }
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_recompute()),
    );
  }

  /// El botón de borrar ruta: vuelve a la guía discontinua sin más.
  void _clearRoute() {
    _debounce?.cancel();
    setState(() {
      _route = null;
      _routeStale = false;
      _routeError = null;
    });
  }

  /// Distinto de [_clearRoute]: no borra solo el cálculo, borra los
  /// puntos (salida, llegada y vías) para empezar una ruta nueva desde
  /// cero. Reportado en vivo 2026-09-18 ("hay dos cosas diferentes:
  /// borrar el routing y borrar la ruta").
  void _clearPoints() {
    _debounce?.cancel();
    setState(() {
      _origin = null;
      _destination = null;
      _vias.clear();
      _originName = null;
      _destinationName = null;
      _placing = null;
      _route = null;
      _routeStale = false;
      _routeError = null;
      _etaTarget = null;
    });
    unawaited(_persist());
  }

  void _fitPoints() {
    final pts = _orderedPoints;
    if (pts.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (pts.length == 1) {
          _map.move(pts.first, 9);
        } else {
          _map.fitCamera(
            fm.CameraFit.bounds(
              bounds: fm.LatLngBounds.fromPoints(pts),
              padding: const EdgeInsets.fromLTRB(40, 150, 40, 170),
            ),
          );
        }
      } catch (_) {}
    });
  }

  void _togglePlacing(_Target t) {
    setState(() {
      _placing =
          (_placing?.slot == t.slot && _placing?.viaIndex == t.viaIndex)
          ? null
          : t;
    });
  }

  void _onMapTap(ll.LatLng p) {
    final t = _placing;
    if (t == null) {
      setState(() => _inspectAt = _inspectAt == null ? p : null);
      return;
    }
    setState(() {
      switch (t.slot) {
        case _Slot.origin:
          _origin = p;
        case _Slot.destination:
          _destination = p;
        case _Slot.via:
          if (t.viaIndex < 0) {
            _vias.add(p);
          } else {
            _vias[t.viaIndex] = p;
          }
      }
      _placing = null;
      _inspectAt = null;
    });
    if (t.slot == _Slot.origin) _nameOrigin();
    if (t.slot == _Slot.destination) _nameDestination();
    _scheduleRecompute();
  }

  void _removeVia(int i) {
    setState(() => _vias.removeAt(i));
    _scheduleRecompute();
  }

  void _useBoatPosition() {
    if (widget.boatLat == null || widget.boatLon == null) return;
    setState(() {
      _origin = ll.LatLng(widget.boatLat!, widget.boatLon!);
      _placing = null;
    });
    _nameOrigin();
    _scheduleRecompute();
    _fitPoints();
  }

  void _swapEnds() {
    if (_origin == null || _destination == null) return;
    setState(() {
      final o = _origin;
      _origin = _destination;
      _destination = o;
      final n = _originName;
      _originName = _destinationName;
      _destinationName = n;
      final rv = _vias.reversed.toList();
      _vias
        ..clear()
        ..addAll(rv);
    });
    _scheduleRecompute();
  }

  Future<void> _pickDeparture() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _departure,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 9)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_departure),
      // Forzado a 24 h: el selector en modo texto tiene un botón AM/PM
      // aparte del número, fácil de dejar en el valor por defecto sin
      // querer — así no hay ambigüedad posible entre las 07:15 y las
      // 19:15. Reportado en vivo 2026-09-18.
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null || !mounted) return;
    setState(() {
      _departure = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _viewTime = null;
    });
    _scheduleRecompute();
  }

  Future<void> _openSettings() async {
    final result =
        await showDialog<(RoutingConstraints, RoutingObjective, WeatherModel)>(
      context: context,
      builder: (_) => _RoutingSettingsDialog(
        constraints: _constraints,
        objective: _objective,
        model: _model,
      ),
    );
    if (result == null) return;
    final modelChanged = result.$3 != _model;
    setState(() {
      _constraints = result.$1;
      _objective = result.$2;
      _model = result.$3;
    });
    // No es solo visual: cambia la ruta óptima y la ETA. Si además cambió
    // el modelo, hace falta volver a bajar el tiempo de ese modelo.
    if (modelChanged) {
      unawaited(_recompute());
    } else {
      unawaited(_computeRoute());
    }
    unawaited(_persist());
  }

  // ── Cronología activa: la de la ruta si hay una calculada, si no la de
  // la rejilla de tiempo (para poder seguir viendo viento/olas sin ruta).
  DateTime? get _timelineStart => _route?.departure ?? _grid?.start;
  DateTime? get _timelineEnd => _route?.eta ?? _grid?.end;

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final center =
        _origin ??
        (widget.boatLat != null && widget.boatLon != null
            ? ll.LatLng(widget.boatLat!, widget.boatLon!)
            : const ll.LatLng(37.9, 24.0));
    final vt = _viewTime;
    final boatPos = (_route != null && vt != null) ? _route!.positionAt(vt) : null;
    final boatSeg = (_route != null && vt != null) ? _route!.segmentAt(vt) : null;
    return Scaffold(
      backgroundColor: cBg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: fm.FlutterMap(
                key: _mapKey,
                mapController: _map,
                options: fm.MapOptions(
                  initialCenter: center,
                  initialZoom: 8,
                  minZoom: 4,
                  maxZoom: 15,
                  onTap: (_, p) => _onMapTap(p),
                  interactionOptions: const fm.InteractionOptions(
                    flags: fm.InteractiveFlag.all & ~fm.InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  fm.TileLayer(
                    urlTemplate: _kOsmTileUrl,
                    userAgentPackageName: 'com.rewindpanel.myapp',
                  ),
                  fm.TileLayer(
                    urlTemplate: _kSeamarkTileUrl,
                    userAgentPackageName: 'com.rewindpanel.myapp',
                  ),
                  if (_grid != null && vt != null && _showWaves)
                    _waveLayer(_grid!, vt),
                  if (_grid != null && vt != null && _showWind)
                    _windLayer(_grid!, vt),
                  if (_route != null)
                    fm.PolylineLayer(polylines: _routePolylines(_route!))
                  else if (_orderedPoints.length >= 2)
                    fm.PolylineLayer(
                      polylines: [
                        fm.Polyline(
                          points: _orderedPoints,
                          color: _tooFar ? cRed : Colors.white70,
                          strokeWidth: 2,
                          pattern: fm.StrokePattern.dashed(segments: const [10, 8]),
                        ),
                      ],
                    ),
                  if (_orderedPoints.length >= 2)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPressStart: (d) => _tryGrabLine(d.globalPosition),
                        onLongPressMoveUpdate: (d) {
                          if (_dragging != null) _dragPoint(_dragging!, d.globalPosition);
                        },
                        onLongPressEnd: (_) => _endDrag(),
                        onLongPressCancel: _endDrag,
                      ),
                    ),
                  fm.MarkerLayer(
                    markers: [
                      if (_origin != null)
                        _pointMarker(
                          _origin!,
                          'S',
                          cGreen,
                          target: const _Target(_Slot.origin),
                        ),
                      for (var i = 0; i < _vias.length; i++)
                        _pointMarker(
                          _vias[i],
                          '${i + 1}',
                          cPurple,
                          small: true,
                          target: _Target(_Slot.via, i),
                          onDoubleTap: () => _removeVia(i),
                          eta: _etaForLeg(i),
                        ),
                      if (_destination != null)
                        _pointMarker(
                          _destination!,
                          'L',
                          cOrange,
                          target: const _Target(_Slot.destination),
                          eta: _route?.eta,
                        ),
                      if (_inspectAt != null)
                        fm.Marker(
                          point: _inspectAt!,
                          width: 18,
                          height: 18,
                          child: const Icon(
                            Icons.add_circle_outline,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      if (boatPos != null)
                        fm.Marker(
                          point: ll.LatLng(boatPos.lat, boatPos.lon),
                          width: 40,
                          height: 40,
                          child: _BoatMarker(
                            headingDeg: boatSeg?.headingDeg ?? 0,
                            color: boatSeg?.mode == PropulsionMode.motor
                                ? _cMotor
                                : _cSailing,
                            shipIconAsset: widget.shipIconAsset,
                          ),
                        ),
                    ],
                  ),
                  const fm.RichAttributionWidget(
                    alignment: fm.AttributionAlignment.bottomLeft,
                    attributions: [
                      fm.TextSourceAttribution('OpenStreetMap'),
                      fm.TextSourceAttribution('OpenSeaMap'),
                      fm.TextSourceAttribution('Open-Meteo'),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(left: 6, right: 6, top: 6, child: _topPanel()),
            if (boatSeg != null)
              Positioned(right: 6, top: 92, bottom: 76, child: _instrumentColumn(boatSeg)),
            if (_inspectAt != null && _grid != null && vt != null && boatSeg == null)
              Positioned(right: 6, top: 92, child: _inspectCard()),
            if (_etaTarget != null) Positioned(left: 6, top: 92, child: _etaPopup()),
            Positioned(left: 6, right: 6, bottom: 6, child: _bottomPanel()),
          ],
        ),
      ),
    );
  }

  /// [target] identifica el punto (salida/vía/llegada) para poder
  /// arrastrarlo directamente en el mapa: mantener pulsado y mover, sin
  /// tener que pasar por el chip de arriba. Es la forma real de redibujar
  /// la ruta a mano — para rodear tierra, o cualquier otro motivo —, no
  /// solo la línea recta entre salida y llegada.
  /// La hora a la que la ruta calculada llega a la vía [legIndex] (el
  /// final de esa pierna) o al destino. null sin ruta calculada.
  DateTime? _etaForLeg(int legIndex) {
    final r = _route;
    if (r == null) return null;
    RouteSegment? last;
    for (final s in r.segments) {
      if (s.waypointIndex == legIndex) last = s;
    }
    return last?.endTime;
  }

  fm.Marker _pointMarker(
    ll.LatLng p,
    String letter,
    Color color, {
    bool small = false,
    required _Target target,
    VoidCallback? onDoubleTap,
    DateTime? eta,
  }) {
    final size = small ? 22.0 : 28.0;
    final dragSize = size + 26; // área de agarre más generosa que el dibujo
    final dep = _route?.departure;
    final frac = (eta != null && dep != null && _route!.totalDuration.inSeconds > 0)
        ? (eta.difference(dep).inSeconds / _route!.totalDuration.inSeconds).clamp(0.0, 1.0)
        : null;
    return fm.Marker(
      point: p,
      width: dragSize,
      height: dragSize,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (_) => setState(() => _dragging = target),
        onLongPressMoveUpdate: (d) => _dragPoint(target, d.globalPosition),
        onLongPressEnd: (_) => _endDrag(),
        onLongPressCancel: _endDrag,
        onDoubleTap: onDoubleTap,
        onTap: eta == null ? null : () => _toggleEtaPopup(target),
        child: Center(
          child: SizedBox(
            width: size + 8,
            height: size + 8,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (frac != null)
                  CustomPaint(
                    size: Size(size + 8, size + 8),
                    painter: _EtaRingPainter(frac, color),
                  ),
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _dragging == target ? cYellow : Colors.white,
                      width: _dragging == target ? 3 : 2,
                    ),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 4),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    letter,
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: small ? 11 : 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _dragPoint(_Target target, Offset globalPosition) {
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final p = _map.camera.screenOffsetToLatLng(local);
    setState(() {
      switch (target.slot) {
        case _Slot.origin:
          _origin = p;
        case _Slot.destination:
          _destination = p;
        case _Slot.via:
          _vias[target.viaIndex] = p;
      }
    });
    _scheduleRecompute();
  }

  void _endDrag() {
    if (_dragging == null) return;
    final t = _dragging!;
    setState(() => _dragging = null);
    if (t.slot == _Slot.origin) _nameOrigin();
    if (t.slot == _Slot.destination) _nameDestination();
    _scheduleRecompute();
  }

  void _toggleEtaPopup(_Target t) {
    setState(() => _etaTarget = _etaTarget == t ? null : t);
  }

  /// Los tramos de la línea tal como se ven ahora mismo (la ruta ya
  /// calculada, o la recta de guía S→vías→L si aún no hay ruta), cada uno
  /// con el índice de pierna donde iría una vía nueva si se agarra ahí.
  List<({double lat1, double lon1, double lat2, double lon2, int legIndex})>
  _hitTestSegments() {
    final r = _route;
    if (r != null && r.segments.isNotEmpty) {
      return [
        for (final s in r.segments)
          (
            lat1: s.startLat,
            lon1: s.startLon,
            lat2: s.endLat,
            lon2: s.endLon,
            legIndex: s.waypointIndex,
          ),
      ];
    }
    final pts = _orderedPoints;
    return [
      for (var i = 0; i < pts.length - 1; i++)
        (
          lat1: pts[i].latitude,
          lon1: pts[i].longitude,
          lat2: pts[i + 1].latitude,
          lon2: pts[i + 1].longitude,
          legIndex: i,
        ),
    ];
  }

  /// "Rompe" la ruta como en cualquier planificador de a bordo: mantener
  /// pulsado sobre la línea (no sobre un punto) y arrastrar añade una
  /// vía nueva justo ahí y la sigue moviendo con el dedo — no hace falta
  /// pasar por el chip "+ vía". Es la forma de definir una ruta de más
  /// de dos puntos sin salir del propio trazado.
  void _tryGrabLine(Offset globalPosition) {
    if (_vias.length >= kMaxVias) return;
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);

    // No competir con los propios puntos: si el dedo está cerca de un
    // marcador ya existente, eso lo gestiona su propio arrastre.
    const markerAvoidPx = 24.0;
    for (final p in _orderedPoints) {
      final s = _map.camera.latLngToScreenOffset(p);
      if ((s - local).distance < markerAvoidPx) return;
    }

    const grabPx = 22.0;
    var bestDist = grabPx;
    int? bestLeg;
    ll.LatLng? bestPoint;
    for (final seg in _hitTestSegments()) {
      final a = _map.camera.latLngToScreenOffset(ll.LatLng(seg.lat1, seg.lon1));
      final b = _map.camera.latLngToScreenOffset(ll.LatLng(seg.lat2, seg.lon2));
      final ab = b - a;
      final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = len2 <= 0
          ? 0.0
          : (((local.dx - a.dx) * ab.dx + (local.dy - a.dy) * ab.dy) / len2)
                .clamp(0.0, 1.0);
      final proj = a + ab * t;
      final dist = (proj - local).distance;
      if (dist < bestDist) {
        bestDist = dist;
        bestLeg = seg.legIndex;
        bestPoint = ll.LatLng(
          seg.lat1 + (seg.lat2 - seg.lat1) * t,
          seg.lon1 + (seg.lon2 - seg.lon1) * t,
        );
      }
    }
    if (bestLeg == null || bestPoint == null) return;
    setState(() {
      _vias.insert(bestLeg!, bestPoint!);
      _dragging = _Target(_Slot.via, bestLeg);
      _placing = null;
    });
    _scheduleRecompute();
  }

  /// La ruta pintada por tramos contiguos del mismo modo, para que el
  /// color cambie exactamente donde cambia vela/motor — no es cosmético,
  /// es lo que decidió el propio cálculo.
  List<fm.Polyline> _routePolylines(RouteResult r) {
    final lines = <fm.Polyline>[];
    var current = <ll.LatLng>[];
    PropulsionMode? mode;
    void flush() {
      if (current.length >= 2) {
        lines.add(
          fm.Polyline(
            points: List.of(current),
            color: mode == PropulsionMode.motor ? _cMotor : _cSailing,
            strokeWidth: 4,
          ),
        );
      }
    }

    for (final s in r.segments) {
      if (mode != null && s.mode != mode) {
        current.add(ll.LatLng(s.startLat, s.startLon));
        flush();
        current = [ll.LatLng(s.startLat, s.startLon)];
      } else if (current.isEmpty) {
        current.add(ll.LatLng(s.startLat, s.startLon));
      }
      mode = s.mode;
      current.add(ll.LatLng(s.endLat, s.endLon));
    }
    flush();
    return lines;
  }

  BoxDecoration get _panelDeco => BoxDecoration(
    color: cPanel.withValues(alpha: 0.93),
    borderRadius: BorderRadius.circular(11),
    border: Border.all(color: Colors.white12),
    boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
  );

  // ── Panel superior en dos líneas: arriba el título y el resumen (lo
  // que se lee, no se toca); abajo los puntos y las acciones (lo que se
  // toca). El resto de parámetros (modelo, objetivo, restricciones) vive
  // en un solo botón de Ajustes para no llenar la barra de mandos.
  Widget _topPanel() {
    final dist = _directRouteNm;
    final polar = widget.polar;
    return Container(
      decoration: _panelDeco,
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 30,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Volver',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
                  icon: const Icon(Icons.arrow_back, color: cText, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Text(
                  'RUTA',
                  style: TextStyle(
                    color: cText,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (polar == null
                            ? 'sin polar (CFG › Barco)'
                            : '${polar.name} · ${widget.polarFactorPercent.round()} %') +
                        (dist == null
                            ? ''
                            : ' · ${dist.toStringAsFixed(dist < 10 ? 1 : 0)} M directas') +
                        (_route == null
                            ? ''
                            : ' · ${_route!.totalNm.toStringAsFixed(0)} M navegadas · ${_durationText(_route!.totalDuration)}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: polar == null ? cOrange : cMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_loadingWeather || _routing)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      // Al calcular la ruta, de verdad se llena con el
                      // progreso real de la isócrona; bajando el tiempo no
                      // hay una medida así, sigue girando sin más.
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cCyan,
                        value: _routing ? _routeProgress.clamp(0.02, 1.0) : null,
                      ),
                    ),
                  ),
                if (_origin != null && _destination != null && widget.polar != null)
                  _recalculateButton(),
                _modeAndObjectiveBadge(),
                _smallAction(Icons.tune, 'Ajustes de la ruta', _openSettings),
              ],
            ),
          ),
          SizedBox(
            height: 32,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final w in _waypointChips()) ...[
                    w,
                    const SizedBox(width: 6),
                  ],
                  if (widget.boatLat != null)
                    _smallAction(
                      Icons.my_location,
                      'Salida en el barco',
                      _useBoatPosition,
                    ),
                  if (_origin != null && _destination != null)
                    _smallAction(Icons.swap_horiz, 'Invertir', _swapEnds),
                  _departureChip(),
                  const SizedBox(width: 8),
                  // Dos borrados distintos: el cálculo (la ruta coloreada;
                  // los puntos se quedan) y los puntos (S, L y vías, para
                  // empezar otra ruta).
                  if (_route != null)
                    _labeledAction(Icons.layers_clear, 'Borrar cálculo', _clearRoute),
                  if (_orderedPoints.isNotEmpty)
                    _labeledAction(Icons.delete_outline, 'Borrar puntos', _clearPoints),
                ],
              ),
            ),
          ),
          ..._topNotices(),
        ],
      ),
    );
  }

  /// El motor ya no corre solo en cada arrastre o cambio — hace falta
  /// pulsar aquí. Resaltado en cian mientras la ruta está desactualizada
  /// (algo cambió desde el último cálculo); en gris si ya está al día,
  /// pero sigue sirviendo para forzar un recálculo.
  Widget _recalculateButton() => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: _routing ? null : _recalculate,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: _routeStale ? cCyan : cPanel2,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: _routeStale ? cCyan : Colors.white24),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.refresh,
              size: 13,
              color: _routeStale ? Colors.black : cMuted,
            ),
            const SizedBox(width: 4),
            Text(
              'Recalcular',
              style: TextStyle(
                color: _routeStale ? Colors.black : cMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// Botón pequeño con texto: en táctil un icono suelto no dice nada (el
  /// tooltip solo aparece con pulsación larga).
  Widget _labeledAction(IconData icon, String label, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: cPanel2,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: Colors.white24),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: cMuted),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _modeAndObjectiveBadge() => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Text(
      '${_model.label} · ${_objective.label}',
      style: const TextStyle(color: cMuted, fontSize: 10.5, fontWeight: FontWeight.w600),
    ),
  );

  List<Widget> _topNotices() {
    final items = <String>[];
    Color color = cYellow;
    if (_placing != null) {
      items.add(_placingLabel(_placing!));
    } else if (_tooFar) {
      items.add(
        'Más de ${kMaxRouteNm.round()} M en línea recta: el routing está '
        'limitado a ${kMaxRouteNm.round()} M.',
      );
      color = cRed;
    } else if (_weatherError != null) {
      items.add(_weatherError!);
      color = cRed;
    } else if (_routeError != null) {
      items.add(_routeError!);
      color = cOrange;
    }
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 3),
        child: Text(
          items.first,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    ];
  }

  String _placingLabel(_Target t) {
    switch (t.slot) {
      case _Slot.origin:
        return 'Toca el mapa donde sales';
      case _Slot.destination:
        return 'Toca el mapa donde llegas';
      case _Slot.via:
        return t.viaIndex < 0
            ? 'Toca el mapa para la nueva vía'
            : 'Toca el mapa para mover la vía ${t.viaIndex + 1}';
    }
  }

  List<Widget> _waypointChips() {
    final chips = <Widget>[
      _pointChip(
        letter: 'S',
        label: 'Salida',
        color: cGreen,
        text: _origin == null
            ? null
            : (_originName ?? formatLatLon(_origin!.latitude, _origin!.longitude)),
        placing: _placing?.slot == _Slot.origin,
        onTap: () => _togglePlacing(const _Target(_Slot.origin)),
      ),
    ];
    // Las vías ya no se listan aquí una a una — con más de un par saturaban
    // la barra. Se ven, se mueven y se borran en el propio mapa: mantener
    // pulsado arrastra, doble toque en el circulito la quita. Aquí solo el
    // recuento, para saber cuántas hay sin tener que mirar el mapa.
    if (_vias.isNotEmpty) {
      chips.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            '${_vias.length} vía${_vias.length == 1 ? '' : 's'}',
            style: const TextStyle(
              color: cPurple,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    if (_vias.length < kMaxVias) {
      chips.add(
        _addViaChip(placing: _placing?.slot == _Slot.via && (_placing?.viaIndex ?? -1) < 0),
      );
    }
    chips.add(
      _pointChip(
        letter: 'L',
        label: 'Llegada',
        color: cOrange,
        text: _destination == null
            ? null
            : (_destinationName ??
                  formatLatLon(_destination!.latitude, _destination!.longitude)),
        placing: _placing?.slot == _Slot.destination,
        onTap: () => _togglePlacing(const _Target(_Slot.destination)),
      ),
    );
    return chips;
  }

  Widget _pointChip({
    required String letter,
    required String label,
    required Color color,
    required String? text,
    required bool placing,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 32, maxWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: placing ? color.withValues(alpha: 0.22) : cPanel2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: placing ? color : Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 8,
            backgroundColor: color,
            child: Text(
              letter,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text ?? label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: text == null ? cMuted : cText,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _addViaChip({required bool placing}) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: () => _togglePlacing(const _Target(_Slot.via, -1)),
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: placing ? cPurple.withValues(alpha: 0.22) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: placing ? cPurple : Colors.white24,
          style: BorderStyle.solid,
        ),
      ),
      alignment: Alignment.center,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add, size: 14, color: cMuted),
          SizedBox(width: 2),
          Text(
            'vía',
            style: TextStyle(color: cMuted, fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );

  Widget _smallAction(IconData icon, String tooltip, VoidCallback onTap) =>
      SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          icon: Icon(icon, color: cCyan, size: 18),
          onPressed: onTap,
        ),
      );

  Widget _departureChip() => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: _pickDeparture,
    child: Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cPanel2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, size: 13, color: cMuted),
          const SizedBox(width: 4),
          Text(
            _formatLocal(_departure),
            style: const TextStyle(
              color: cText,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  static const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];

  static String _formatLocal(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_weekdays[l.weekday - 1]} ${l.day} · ${two(l.hour)}:${two(l.minute)}';
  }

  static String _durationText(Duration d) {
    final h = d.inMinutes ~/ 60, m = d.inMinutes % 60;
    return m == 0 ? '$h h' : '$h h ${m.toString().padLeft(2, '0')}';
  }

  // ── Panel inferior: hora + capas, deslizador y, si hay ruta, la tira
  // de instrumentos en vivo del barco en ese instante.
  Widget _bottomPanel() {
    final start = _timelineStart, end = _timelineEnd;
    final vt = _viewTime;
    final seg = (_route != null && vt != null) ? _route!.segmentAt(vt) : null;
    return Container(
      decoration: _panelDeco,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 26,
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: vt == null ? 'Sin datos de tiempo' : _formatLocal(vt),
                      style: const TextStyle(
                        color: cText,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      children: [
                        if (vt != null)
                          TextSpan(
                            text: '  ${_relativeToDeparture(vt)}',
                            style: const TextStyle(
                              color: cMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (seg != null) _modeBadge(seg.mode),
                const SizedBox(width: 6),
                _layerToggle('Viento', _showWind, (v) => _showWind = v),
                const SizedBox(width: 4),
                _layerToggle('Olas', _showWaves, (v) => _showWaves = v),
              ],
            ),
          ),
          if (start != null && end != null && vt != null)
            SizedBox(
              height: 26,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: vt.difference(start).inSeconds.toDouble().clamp(
                    0,
                    math.max(1, end.difference(start).inSeconds.toDouble()),
                  ),
                  min: 0,
                  max: math.max(1, end.difference(start).inSeconds.toDouble()),
                  activeColor: cCyan,
                  onChanged: (s) => setState(
                    () => _viewTime = start.add(Duration(seconds: s.round())),
                  ),
                ),
              ),
            ),
          SizedBox(
            height: 22,
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ..._legend(),
                if (_grid != null)
                  Text(
                    '${_grid!.source} · ${_ageText(_grid!.fetchedAt)}',
                    style: const TextStyle(color: cMuted, fontSize: 9.5),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeBadge(PropulsionMode mode) {
    final motor = mode == PropulsionMode.motor;
    final color = motor ? _cMotor : _cSailing;
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(motor ? Icons.settings : Icons.air, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            motor ? 'A MOTOR' : 'A VELA',
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  /// Instrumentos en vivo del barco en el instante del deslizador, en
  /// columna a la derecha del mapa (punto 2 del encargo): cada fila es un
  /// dato, no se pelean por el ancho como en una tira.
  Widget _instrumentColumn(RouteSegment s) {
    String kn(double v) => '${v.toStringAsFixed(1)} kn';
    String deg(double v) => '${v.round()}°';
    Widget stat(String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: const TextStyle(color: cMuted, fontSize: 10.5, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color ?? cText,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );

    final encAngle = s.waveEncounterAngleDeg;
    final encPeriod = s.waveEncounterPeriodS;
    return Container(
      width: 168,
      decoration: _panelDeco,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _modeBadge(s.mode),
            const SizedBox(height: 2),
            stat('STW', kn(s.stwKn), color: s.mode == PropulsionMode.motor ? _cMotor : _cSailing),
            stat('TWS', kn(s.twsKn)),
            stat('TWD', deg(s.twdDeg)),
            stat('AWS', kn(s.awsKn)),
            stat('AWA', '${s.awaDeg >= 0 ? '+' : ''}${s.awaDeg.round()}°'),
            const Divider(height: 12, color: Colors.white12),
            if (s.waveHeightM != null) ...[
              stat('Hs modelo', '${s.waveHeightM!.toStringAsFixed(2)} m'),
              if (s.waveDirDeg != null) stat('dir. ola', deg(s.waveDirDeg!)),
              if (s.wavePeriodS != null)
                stat('T ola', '${s.wavePeriodS!.toStringAsFixed(1)} s'),
              if (encAngle != null)
                stat(
                  'Ola encontrada',
                  waveSectorLabel(encAngle) +
                      (encPeriod == null
                          ? ''
                          : ' · Te ${encPeriod.toStringAsFixed(1)} s'),
                  color: cYellow,
                ),
            ] else
              stat('Ola', 'sin dato'),
          ],
        ),
      ),
    );
  }

  String _relativeToDeparture(DateTime t) {
    final base = _route?.departure ?? _departure.toUtc();
    final d = t.difference(base);
    if (d.inMinutes.abs() < 1) return 'salida';
    final h = d.inMinutes.abs() ~/ 60, m = d.inMinutes.abs() % 60;
    final s = m == 0 ? '$h h' : (h == 0 ? '$m min' : '$h h ${m.toString().padLeft(2, '0')}');
    return d.isNegative ? '$s antes de salir' : 'salida + $s';
  }

  static String _ageText(DateTime fetched) {
    final m = DateTime.now().difference(fetched).inMinutes;
    return m < 1 ? 'recién bajado' : 'bajado hace $m min';
  }

  Widget _layerToggle(String label, bool on, void Function(bool) set) =>
      InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => set(!on)),
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: on ? cCyan.withValues(alpha: 0.2) : cPanel2,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? cCyan : Colors.white24),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: on ? cText : cMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );

  List<Widget> _legend() {
    Widget dot(Color c, String t) => Padding(
      padding: const EdgeInsets.only(right: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 3),
          Text(t, style: const TextStyle(color: cMuted, fontSize: 9.5)),
        ],
      ),
    );
    return [
      if (_showWind) ...[
        for (final (c, t) in _windScale) dot(c, t),
      ],
      if (_showWaves) ...[
        dot(_kWaveWarn.withValues(alpha: 1), 'ola ≥${_kWavePreferredM.toStringAsFixed(1)} m'),
        dot(_kWaveBad.withValues(alpha: 1), '≥${_kWaveMaxM.toStringAsFixed(1)} m'),
      ],
    ];
  }

  static const _windScale = [
    (Color(0xff5b8def), '<6'),
    (cCyan, '6–10'),
    (cGreen, '11–15'),
    (cYellow, '16–20'),
    (cOrange, '21–25'),
    (cRed, '>25 kn'),
  ];

  static Color windColor(double kn) {
    if (kn < 6) return _windScale[0].$1;
    if (kn < 11) return _windScale[1].$1;
    if (kn < 16) return _windScale[2].$1;
    if (kn < 21) return _windScale[3].$1;
    if (kn <= 25) return _windScale[4].$1;
    return _windScale[5].$1;
  }

  /// Color de la celda de ola; null por debajo de la preferida (no se
  /// pinta: el mapa de fondo tiene que seguir viéndose).
  static Color? _waveColor(double h) {
    if (h < _kWavePreferredM) return null;
    if (h < _kWaveMaxM) return _kWaveWarn;
    return _kWaveBad;
  }

  // Naranja y magenta, no amarillo: sobre el azul del mar, un amarillo
  // translúcido se ve verde.
  static const _kWaveWarn = Color(0x38ff8c1a);
  static const _kWaveBad = Color(0x48e0206e);

  Widget _waveLayer(WeatherGrid g, DateTime t) {
    final polys = <fm.Polygon>[];
    final half = g.step / 2;
    for (var i = 0; i < g.nLat; i++) {
      for (var j = 0; j < g.nLon; j++) {
        final lat = g.latAt(i), lon = g.lonAt(j);
        final h = g.sample(lat, lon, t)?.waveHeightM;
        if (h == null) continue;
        final c = _waveColor(h);
        if (c == null) continue;
        polys.add(
          fm.Polygon(
            points: [
              ll.LatLng(lat - half, lon - half),
              ll.LatLng(lat - half, lon + half),
              ll.LatLng(lat + half, lon + half),
              ll.LatLng(lat + half, lon - half),
            ],
            color: c,
            borderStrokeWidth: 0,
          ),
        );
      }
    }
    return fm.PolygonLayer(polygons: polys);
  }

  Widget _windLayer(WeatherGrid g, DateTime t) {
    // Como mucho ~180 flechas: con más, el mapa se vuelve ilegible.
    final stride = math.max(1, math.sqrt(g.pointCount / 180).ceil());
    final markers = <fm.Marker>[];
    for (var i = 0; i < g.nLat; i += stride) {
      for (var j = 0; j < g.nLon; j += stride) {
        final s = g.sample(g.latAt(i), g.lonAt(j), t);
        if (s == null) continue;
        markers.add(
          fm.Marker(
            point: ll.LatLng(g.latAt(i), g.lonAt(j)),
            width: 34,
            height: 34,
            child: _WindArrow(
              twdDeg: s.twdDeg,
              twsKn: s.twsKn,
              color: windColor(s.twsKn),
            ),
          ),
        );
      }
    }
    return fm.MarkerLayer(markers: markers);
  }

  /// Al tocar una vía o la llegada (con ruta calculada): cuánto queda
  /// para llegar ahí, con una barra en vez de solo un número — lo que
  /// pedías en vez de que el punto fuera "solo un circulito".
  Widget _etaPopup() {
    final t = _etaTarget;
    final r = _route;
    if (t == null || r == null) return const SizedBox.shrink();
    final eta = t.slot == _Slot.destination ? r.eta : _etaForLeg(t.viaIndex);
    final dep = r.departure;
    if (eta == null || dep == null) return const SizedBox.shrink();
    final total = r.totalDuration.inSeconds;
    final frac = total > 0
        ? (eta.difference(dep).inSeconds / total).clamp(0.0, 1.0)
        : 0.0;
    final label = t.slot == _Slot.destination
        ? 'Llegada'
        : 'Vía ${t.viaIndex + 1}';
    return Container(
      width: 190,
      decoration: _panelDeco,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${(frac * 100).round()} %',
                style: const TextStyle(
                  color: cCyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 6,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(cCyan),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_formatLocal(eta)}  ·  salida + ${_durationText(eta.difference(dep))}',
            style: const TextStyle(
              color: cText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _inspectCard() {
    final p = _inspectAt!;
    final s = _grid!.sample(p.latitude, p.longitude, _viewTime!);
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 62,
            child: Text(k, style: const TextStyle(color: cMuted, fontSize: 11)),
          ),
          Text(
            v,
            style: const TextStyle(
              color: cText,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    return Container(
      width: 190,
      decoration: _panelDeco,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatLatLon(p.latitude, p.longitude),
            style: const TextStyle(color: cMuted, fontSize: 10.5),
          ),
          const SizedBox(height: 4),
          if (s == null)
            const Text(
              'Sin datos aquí',
              style: TextStyle(color: cOrange, fontSize: 12),
            )
          else ...[
            row('Viento', '${s.twsKn.toStringAsFixed(1)} kn · ${s.twdDeg.round()}°'),
            row(
              'Ola',
              s.waveHeightM == null
                  ? 'sin dato'
                  : '${s.waveHeightM!.toStringAsFixed(2)} m'
                        '${s.waveDirDeg == null ? '' : ' · ${s.waveDirDeg!.round()}°'}',
            ),
            if (s.wavePeriodS != null)
              row('Periodo', '${s.wavePeriodS!.toStringAsFixed(1)} s'),
          ],
        ],
      ),
    );
  }
}

/// Flecha de viento: apunta hacia donde SOPLA, con la velocidad al lado.
class _WindArrow extends StatelessWidget {
  const _WindArrow({
    required this.twdDeg,
    required this.twsKn,
    required this.color,
  });

  final double twdDeg, twsKn;
  final Color color;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Transform.rotate(
        angle: (twdDeg + 180) * math.pi / 180,
        child: CustomPaint(size: const Size(26, 26), painter: _ArrowPainter(color)),
      ),
      Positioned(
        right: 0,
        bottom: 0,
        child: Text(
          twsKn.round().toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            shadows: [
              Shadow(color: Colors.black, blurRadius: 3),
              Shadow(color: Colors.black, blurRadius: 1),
            ],
          ),
        ),
      ),
    ],
  );
}

/// El anillo alrededor de una vía o la llegada: cuánto queda de ruta para
/// llegar ahí, a simple vista, sin tener que tocarlo.
class _EtaRingPainter extends CustomPainter {
  _EtaRingPainter(this.fraction, this.color);
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2 - 1.5;
    final track = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(center, radius, track);
    if (fraction <= 0) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_EtaRingPainter old) =>
      old.fraction != fraction || old.color != color;
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = Colors.black87
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final head = Path()
      ..moveTo(w / 2, 0)
      ..lineTo(w / 2 - 6.5, 10)
      ..lineTo(w / 2 + 6.5, 10)
      ..close();
    canvas.drawLine(Offset(w / 2, h - 2), Offset(w / 2, 6), stroke);
    canvas.drawLine(Offset(w / 2, h - 2), Offset(w / 2, 6), line);
    canvas.drawPath(
      head,
      Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      head,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

/// El barco en el mapa: el mismo casco elegido en CFG (como en ANC y
/// AIS), girado al rumbo del tramo activo, con una marca de color en la
/// esquina de si va a vela o a motor. Si no hay icono elegido (barco sin
/// posición todavía, asset sin cargar), un triángulo simple de reserva —
/// pero nunca una flecha genérica cuando SÍ hay un icono.
class _BoatMarker extends StatelessWidget {
  const _BoatMarker({
    required this.headingDeg,
    required this.color,
    required this.shipIconAsset,
  });
  final double headingDeg;
  final Color color;
  final String? shipIconAsset;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Transform.rotate(
        angle: headingDeg * math.pi / 180,
        child: shipIconAsset == null
            ? CustomPaint(size: const Size(26, 26), painter: _BoatPainter(color))
            : Image.asset(shipIconAsset!, width: 34, height: 34, fit: BoxFit.contain),
      ),
      Positioned(
        right: shipIconAsset == null ? 2 : -2,
        top: shipIconAsset == null ? 2 : -2,
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black87, width: 1),
          ),
        ),
      ),
    ],
  );
}

class _BoatPainter extends CustomPainter {
  _BoatPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w / 2, 1)
      ..lineTo(w * 0.78, h - 4)
      ..lineTo(w / 2, h * 0.72)
      ..lineTo(w * 0.22, h - 4)
      ..close();
    canvas.drawShadow(path, Colors.black, 2, false);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_BoatPainter old) =>
      old.color != color;
}

/// Ajustes que de verdad cambian el cálculo: cambiarlos vuelve a correr
/// el motor, no es un filtro visual.
class _RoutingSettingsDialog extends StatefulWidget {
  const _RoutingSettingsDialog({
    required this.constraints,
    required this.objective,
    required this.model,
  });
  final RoutingConstraints constraints;
  final RoutingObjective objective;
  final WeatherModel model;

  @override
  State<_RoutingSettingsDialog> createState() => _RoutingSettingsDialogState();
}

class _RoutingSettingsDialogState extends State<_RoutingSettingsDialog> {
  late double minStw = widget.constraints.minimumSailingSTW;
  late bool allowMotor = widget.constraints.allowMotor;
  late double motorKn = widget.constraints.motorSpeedKn;
  late double maxAws = widget.constraints.maxAwsKn;
  late double prefWave = widget.constraints.preferredMaxWaveM;
  late double absWave = widget.constraints.absoluteMaxWaveM;
  late double minAwa = widget.constraints.minimumAwaDeg;
  late RoutingObjective objective = widget.objective;
  late WeatherModel model = widget.model;

  @override
  Widget build(BuildContext context) {
    final dialogWidth = MediaQuery.sizeOf(context).width.clamp(460, 760).toDouble();
    Widget header(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        t,
        style: const TextStyle(color: cMuted, fontSize: 11, fontWeight: FontWeight.w800),
      ),
    );
    return AlertDialog(
      backgroundColor: cPanel,
      title: const Text('Ajustes de la ruta', style: TextStyle(color: cText)),
      content: SizedBox(
        width: dialogWidth,
        // Todo cabe sin scroll: tres columnas en vez de una lista larga.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header('MODELO METEOROLÓGICO'),
                      SegmentedButton<WeatherModel>(
                        segments: [
                          for (final m in WeatherModel.values)
                            ButtonSegment(value: m, label: Text(m.label)),
                        ],
                        selected: {model},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) => setState(() => model = s.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header('MODO'),
                      SegmentedButton<RoutingObjective>(
                        segments: [
                          for (final o in RoutingObjective.values)
                            ButtonSegment(value: o, label: Text(o.label)),
                        ],
                        selected: {objective},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) => setState(() => objective = s.first),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // VELA
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header('VELA'),
                      _slider(
                        'Velocidad mínima',
                        minStw,
                        2,
                        8,
                        (v) => setState(() => minStw = v),
                        '${minStw.toStringAsFixed(1)} kn',
                      ),
                      _slider(
                        'AWA mínimo al ceñir',
                        minAwa,
                        15,
                        45,
                        (v) => setState(() => minAwa = v),
                        '${minAwa.round()}°',
                      ),
                      const Text(
                        'Por debajo, ese rumbo no se ofrece a vela aunque la '
                        'polar tenga dato: las velas no trimarían tan '
                        'cerradas. Propuesto de tu propia polar.',
                        style: TextStyle(color: cMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // MOTOR
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header('MOTOR'),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          'Permitido',
                          style: TextStyle(color: cText, fontSize: 13),
                        ),
                        value: allowMotor,
                        activeThumbColor: cCyan,
                        onChanged: (v) => setState(() => allowMotor = v),
                      ),
                      if (allowMotor)
                        _slider(
                          'Velocidad de motor',
                          motorKn,
                          3,
                          10,
                          (v) => setState(() => motorKn = v),
                          '${motorKn.toStringAsFixed(1)} kn',
                        ),
                      _slider(
                        'AWS máximo',
                        maxAws,
                        15,
                        40,
                        (v) => setState(() => maxAws = v),
                        '${maxAws.round()} kn',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // OLA
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header('OLA'),
                      _slider(
                        'Preferida (aviso)',
                        prefWave,
                        0.2,
                        2.0,
                        (v) => setState(() => prefWave = math.min(v, absWave)),
                        '${prefWave.toStringAsFixed(2)} m',
                      ),
                      _slider(
                        'Máxima absoluta',
                        absWave,
                        0.2,
                        3.0,
                        (v) => setState(() {
                          absWave = v;
                          if (prefWave > absWave) prefWave = absWave;
                        }),
                        '${absWave.toStringAsFixed(2)} m',
                      ),
                      const Text(
                        'La máxima nunca se cruza; la preferida solo avisa.',
                        style: TextStyle(color: cMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            RoutingConstraints(
              minimumSailingSTW: minStw,
              allowMotor: allowMotor,
              motorSpeedKn: motorKn,
              maxAwsKn: maxAws,
              preferredMaxWaveM: prefWave,
              absoluteMaxWaveM: absWave,
              minimumAwaDeg: minAwa,
            ),
            objective,
            model,
          )),
          child: const Text('Aplicar y recalcular'),
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChanged,
    String valueText,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(color: cMuted, fontSize: 12)),
            ),
            Text(
              valueText,
              style: const TextStyle(color: cText, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 3),
          child: Slider(
            value: value,
            min: min,
            max: max,
            activeColor: cCyan,
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}
