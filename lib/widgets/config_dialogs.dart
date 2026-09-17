part of '../main.dart';

// Etiquetas del selector "Mostrar como" de cada tanque. 'unknown' aparece
// tal cual porque es lo que publica Signal K cuando el plugin de Venus no
// sabe traducir el tipo de fluido — ver TankSlot.displayType.
const _tankKindLabels = <String, String>{
  'fuel': 'Diésel',
  'lpg': 'LPG',
  'freshWater': 'Agua',
  'blackWater': 'Negras',
  'wasteWater': 'Grises',
  'unknown': 'Sin tipo',
};

String friendlyApiError(Object e) {
  final s = e.toString();
  // Fuente "Grabador REWIND" contra un servidor donde el grabador no está
  // activado (REWIND sigue con InfluxDB): Signal K responde un 400 críptico.
  if (s.contains('Requested provider not found') &&
      s.contains(rewindHistoryProviderId)) {
    return 'Este servidor Signal K no tiene activado el grabador de histórico '
        'REWIND. Actívalo en Signal K > Plugins > REWIND Panel > Grabador de '
        'histórico REWIND, o elige otra fuente (InfluxDB o Signal K).';
  }
  final match = RegExp(r'Exception: (.+)').firstMatch(s);
  return match != null ? match.group(1)! : s;
}

// ─── Weather location picker (PRON > icono junto al lugar) ───────────────────
class _LocationPickerDialog extends StatefulWidget {
  const _LocationPickerDialog({
    required this.initial,
    required this.isOverridden,
  });
  final ll.LatLng? initial;
  final bool isOverridden;

  @override
  State<_LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<_LocationPickerDialog> {
  ll.LatLng? _picked;
  final _mapController = fm.MapController();
  bool _lookingUp = false;
  String? _placeName;
  String? _nearestTown;
  int _lookupToken = 0;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial;
    if (widget.initial != null) _lookupPlace(widget.initial!);
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _lookupPlace(ll.LatLng point) async {
    final token = ++_lookupToken;
    setState(() {
      _lookingUp = true;
      _placeName = null;
      _nearestTown = null;
    });
    try {
      final results = await Future.wait([
        reverseGeocode(point.latitude, point.longitude),
        nearestPopulatedPlace(point.latitude, point.longitude),
      ]);
      if (!mounted || token != _lookupToken) return;
      setState(() {
        _lookingUp = false;
        _placeName = results[0] as String;
        _nearestTown = results[1];
      });
    } catch (_) {
      if (!mounted || token != _lookupToken) return;
      setState(() => _lookingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = widget.initial ?? const ll.LatLng(37.75, 26.98);
    return Dialog.fullscreen(
      backgroundColor: cBg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Elige un punto para el pronóstico',
                      style: TextStyle(
                        color: cText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: cText),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Toca el mapa para marcar un punto',
                  style: TextStyle(color: cMuted, fontSize: 13),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Stack(
                children: [
                  fm.FlutterMap(
                    mapController: _mapController,
                    options: fm.MapOptions(
                      initialCenter: center,
                      initialZoom: 8,
                      onTap: (_, latlng) {
                        setState(() => _picked = latlng);
                        _lookupPlace(latlng);
                      },
                    ),
                    children: [
                      fm.TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.rewind.xcover6panel',
                      ),
                      if (_picked != null)
                        fm.MarkerLayer(
                          markers: [
                            fm.Marker(
                              point: _picked!,
                              width: 40,
                              height: 40,
                              child: const Icon(
                                Icons.location_pin,
                                color: cOrange,
                                size: 40,
                              ),
                            ),
                          ],
                        ),
                      const fm.RichAttributionWidget(
                        attributions: [
                          fm.TextSourceAttribution(
                            'OpenStreetMap contributors',
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_picked != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: _lookingUp
                    ? const Row(
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cCyan,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Buscando lugar…',
                            style: TextStyle(color: cMuted, fontSize: 12),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_placeName != null)
                            Text(
                              _placeName!,
                              style: const TextStyle(
                                color: cText,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (_nearestTown != null)
                            Text(
                              'Población más cercana: $_nearestTown',
                              style: const TextStyle(
                                color: cMuted,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Row(
                children: [
                  if (widget.isOverridden)
                    TextButton.icon(
                      icon: const Icon(Icons.my_location, color: cMuted),
                      label: const Text(
                        'Usar mi posición',
                        style: TextStyle(color: cMuted),
                      ),
                      onPressed: () =>
                          Navigator.of(context).pop((lat: null, lon: null)),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Usar esta ubicación'),
                    onPressed: _picked == null
                        ? null
                        : () => Navigator.of(context).pop((
                            lat: _picked!.latitude,
                            lon: _picked!.longitude,
                          )),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Sensor configuration dialog (CFG > Configurar sensores) ─────────────────
class _SensorConfigDialog extends StatefulWidget {
  const _SensorConfigDialog({required this.initial, required this.discover});
  final SensorConfig initial;
  final Future<SkDiscovery> Function() discover;

  @override
  State<_SensorConfigDialog> createState() => _SensorConfigDialogState();
}

class _SensorConfigDialogState extends State<_SensorConfigDialog> {
  late SensorConfig _cfg;
  SkDiscovery? _discovery;
  bool _loading = false;
  String? _error;

  Widget _numberField(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) => SizedBox(
    width: 126,
    child: TextFormField(
      initialValue: value.toStringAsFixed(
        value == value.roundToDouble() ? 0 : 1,
      ),
      decoration: InputDecoration(labelText: label, isDense: true),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (raw) {
        final parsed = double.tryParse(raw.replaceAll(',', '.'));
        if (parsed != null) onChanged(parsed);
      },
    ),
  );

  @override
  void initState() {
    super.initState();
    _cfg = SensorConfig.fromJson(widget.initial.toJson());
  }

  Future<void> _discoverNow() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    SkDiscovery d;
    try {
      d = await widget.discover();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo conectar a Signal K: ${friendlyApiError(e)}';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _discovery = d;
      _cfg.hasOutsideTemp = d.hasOutsideTemp;
      _cfg.hasOutsidePressure = d.hasOutsidePressure;
      for (final tc in d.tanks) {
        final idx = _cfg.tanks.indexWhere(
          (t) => t.type == tc.type && t.id == tc.id,
        );
        if (idx < 0) {
          final isLpg = tc.type.toLowerCase() == 'lpg';
          _cfg.tanks.add(
            TankSlot(
              type: tc.type,
              id: tc.id,
              groupLabel: tc.name ?? '${tc.type} ${tc.id}',
              capacityL: tc.capacityL ?? 0,
              // Venus/Cerbo LPG is a first-class tank source. Previous
              // discovery added it disabled, which made it appear to be
              // missing even though Signal K was publishing it correctly.
              enabled: isLpg,
            ),
          );
        } else {
          if (tc.type.toLowerCase() == 'lpg') {
            _cfg.tanks[idx].enabled = true;
          }
          if (tc.capacityL != null && _cfg.tanks[idx].capacityL == 0) {
            _cfg.tanks[idx].capacityL = tc.capacityL!;
          }
          // "el nombre de los tanques tienes que cogerlo de signalk con el
          // sufijo .name" (reported live 2026-09-04) — Signal K's own name
          // is authoritative when published, so every scan refreshes it
          // rather than only filling it in once.
          if (tc.name != null) _cfg.tanks[idx].groupLabel = tc.name!;
        }
      }
      _autoConfigureFromDiscovery(d);
    });
  }

  // "cuando le doy a buscar sensores, trata de autoconfigurar baterias,
  // paneles, etc." (reported live 2026-09-04) — best-effort auto-fill for
  // fields that were still blank before this scan. Never overwrites a
  // value the user already has set (blank/null check on every field), so
  // re-running the scan can't silently undo a manual choice.
  void _autoConfigureFromDiscovery(SkDiscovery d) {
    if (_cfg.batteryHouseId.isEmpty || _cfg.batteryStartId.isEmpty) {
      String? findByHint(Iterable<String> hints) {
        for (final id in d.batteryIds) {
          final name = d.batteryNames[id];
          if (name != null && hints.any(name.contains)) return id;
        }
        return null;
      }

      final houseHints = ['house', 'servicio', 'domestic', 'auxiliar', 'aux'];
      final startHints = ['start', 'arranque', 'motor', 'engine'];
      var house = findByHint(houseHints);
      var start = findByHint(startHints);
      // No name hints at all (or they didn't disambiguate) but exactly two
      // batteries were found — a reasonable starting guess is better than
      // leaving both blank; the dropdowns are right there to correct it.
      if (house == null &&
          start == null &&
          d.batteryIds.length == 2 &&
          _cfg.batteryHouseId.isEmpty &&
          _cfg.batteryStartId.isEmpty) {
        house = d.batteryIds[0];
        start = d.batteryIds[1];
      }
      if (_cfg.batteryHouseId.isEmpty && house != null) {
        _cfg.batteryHouseId = house;
      }
      if (_cfg.batteryStartId.isEmpty && start != null && start != house) {
        _cfg.batteryStartId = start;
      }
    }
    if (_cfg.solarPath == null && d.solarTotalPaths.isNotEmpty) {
      _cfg.solarPath = d.solarTotalPaths[0];
      if (_cfg.solarPath2 == null && d.solarTotalPaths.length > 1) {
        _cfg.solarPath2 = d.solarTotalPaths[1];
      }
    }
    if (_cfg.fridge1Path == null && d.fridgePaths.isNotEmpty) {
      _cfg.fridge1Path = d.fridgePaths[0];
      if (_cfg.fridge2Path == null && d.fridgePaths.length > 1) {
        _cfg.fridge2Path = d.fridgePaths[1];
      }
    }
    // Lo que publica el barco, para poder ocultar la tarjeta de lo que no
    // tiene (ver optionalCardVisible).
    _cfg.detectedPaths = skDetectablePaths(d.allPaths);
    if (_cfg.bowthrusterPath != null &&
        !_cfg.detectedPaths.contains(_cfg.bowthrusterPath)) {
      // Un barco que no publica la hélice de proa no debe heredar la ruta
      // de REWIND como si fuera suya.
      final found = _cfg.detectedPaths.firstWhere(
        (p) =>
            p.toLowerCase().contains('bowthruster') && p.endsWith('.voltage'),
        orElse: () => '',
      );
      _cfg.bowthrusterPath = found.isEmpty ? null : found;
    }
    if (_cfg.dcLoadsPath != null &&
        !_cfg.detectedPaths.contains(_cfg.dcLoadsPath)) {
      _cfg.dcLoadsPath = null;
    }
    // Temperaturas: se añaden todas las que publique el barco y no estén ya
    // en la lista. Las de environment.venus.<id> suelen ser el MISMO sensor
    // publicado otra vez por el Cerbo (en REWIND, venus.41 es fridge_1), así
    // que entran apagadas para no duplicar la tarjeta.
    final knownTempPaths = {for (final s in _cfg.tempSensors) s.path};
    final descubiertas = d.allPaths.where(isConfigurableTempPath).toList();
    // El Cerbo republica como environment.venus.<id> sensores que ya llegan
    // con su nombre propio (en REWIND, venus.41 es fridge_1): si hay rutas
    // con nombre, las de venus no se ofrecen siquiera, porque duplicarían
    // cada tarjeta con un título tan útil como "41" (visto en vivo
    // 2026-09-16). Solo se ofrecen si son lo único que publica el barco.
    final conNombre = descubiertas
        .where((p) => !p.startsWith('environment.venus.'))
        .toList();
    for (final path in conNombre.isEmpty ? descubiertas : conNombre) {
      if (!knownTempPaths.add(path)) continue;
      final esVenus = path.startsWith('environment.venus.');
      _cfg.tempSensors.add(
        TempSensorSlot(
          path: path,
          // labelFromPath ya antepone "Venus" a las entradas del Cerbo.
          label: TempSensorSlot.labelFromPath(path),
          role: TempSensorSlot.roleFromPath(path),
          enabled: !esVenus,
        ),
      );
    }
    // Pilas de los sensores inalámbricos: qué pila va con qué tarjeta solo lo
    // dice el nombre que puso quien los instaló, así que se propone lo que
    // más se parece y queda corregible en la lista de arriba.
    final pilas = _cfg.detectedPaths
        .where((p) => p.startsWith('sensors.') && p.endsWith('.voltage'))
        .toList();
    if (pilas.isNotEmpty) {
      for (final s in _cfg.tempSensors) {
        s.batteryPath ??= guessSensorBatteryPath(s.path, s.label, pilas);
      }
      for (final t in _cfg.tanks) {
        t.batteryPath ??= guessSensorBatteryPath(t.skPath, t.groupLabel, pilas);
      }
    }
    if (_cfg.depthPath == null && d.depthPaths.isNotEmpty) {
      _cfg.depthPath = d.depthPaths[0];
    }
    if (_cfg.enginePath == null && d.enginePaths.isNotEmpty) {
      _cfg.enginePath = d.enginePaths[0];
    }
  }

  // Candidatas para la pila de un sensor inalámbrico: lo que el barco publica
  // bajo `sensors.<nombre>.battery.voltage` (Mopeka, RuuviTag). Se ofrecen
  // todas porque el nombre lo puso quien instaló el sensor y no hay forma
  // fiable de deducir a qué tanque o nevera pertenece cada una.
  List<String> get _batteryPathsFound =>
      _cfg.detectedPaths
          .where((p) => p.startsWith('sensors.') && p.endsWith('.voltage'))
          .toList()
        ..sort();

  /// La ruta ya configurada entra SIEMPRE en la lista aunque no esté entre las
  /// detectadas: puede venir de otro dispositivo por la configuración
  /// compartida, o de un barrido anterior, y un desplegable cuyo valor no está
  /// entre sus opciones no se pinta, revienta.
  List<String?> _batteryPathOptions(String? current) => [
    null,
    ..._batteryPathsFound,
    if (current != null &&
        current.isNotEmpty &&
        !_batteryPathsFound.contains(current))
      current,
  ];

  bool _showsBatteryPicker(String? current) =>
      _batteryPathsFound.isNotEmpty || (current != null && current.isNotEmpty);

  /// `sensors.mopeka_water_tank.battery.voltage` → `mopeka_water_tank`: en un
  /// desplegable estrecho la ruta entera no dice nada, el nombre sí.
  String _pilaCorta(String path) {
    final parts = path.split('.');
    return parts.length >= 2 ? parts[1] : path;
  }

  // Candidatas para la hélice de proa: cualquier voltaje de batería que
  // publique el barco, porque el nombre lo pone cada instalación (en REWIND
  // es "bowthruster", en otro barco puede ser "proa" o un número).
  List<String?> get _bowthrusterOptions {
    final found =
        _cfg.detectedPaths
            .where(
              (p) =>
                  p.startsWith('electrical.') &&
                  (p.endsWith('.voltage') || p.endsWith('.current')),
            )
            .toList()
          ..sort();
    return [
      null,
      ...found,
      if (_cfg.bowthrusterPath != null && !found.contains(_cfg.bowthrusterPath))
        _cfg.bowthrusterPath,
    ];
  }

  // Consumos DC: la salida total del cargador/inversor. En REWIND la publica
  // el Cerbo como electrical.venus.dcPower; en otro barco tendrá otro nombre.
  List<String?> get _dcLoadsOptions {
    final found =
        _cfg.detectedPaths
            .where(
              (p) =>
                  p.startsWith('electrical.') &&
                  p.toLowerCase().contains('power'),
            )
            .toList()
          ..sort();
    return [
      null,
      ...found,
      if (_cfg.dcLoadsPath != null && !found.contains(_cfg.dcLoadsPath))
        _cfg.dcLoadsPath,
    ];
  }

  // Ruta que demuestra que este barco tiene esa tarjeta — ver
  // optionalCardVisible.
  String? _cardPath(String id) => switch (id) {
    'bowthruster' => _cfg.bowthrusterPath,
    'starterBattery' =>
      _cfg.batteryStartId.isEmpty
          ? null
          : 'electrical.batteries.${_cfg.batteryStartId}.voltage',
    'dcLoads' => _cfg.dcLoadsPath,
    'solar' => _cfg.solarPath,
    _ => null,
  };

  bool _cardDetected(String id) {
    final path = _cardPath(id);
    return path != null && path.isNotEmpty && _cfg.detectedPaths.contains(path);
  }

  String _cardStatusText(String id) {
    if (_cfg.detectedPaths.isEmpty) {
      // Sin haber buscado sensores no se oculta nada, así que tampoco se
      // afirma aquí que falte algo.
      return 'sin buscar sensores todavía';
    }
    final path = _cardPath(id);
    if (path == null || path.isEmpty) return 'sin ruta asignada';
    return _cardDetected(id) ? 'detectada en este barco' : 'no detectada';
  }

  // Rutas de temperatura que el barco publica y todavía no están en la
  // lista — ver isConfigurableTempPath: baterías, motor y Raspberry quedan
  // fuera porque ya se ven en su propia pantalla.
  List<String> get _tempPathOptions {
    final used = {for (final s in _cfg.tempSensors) s.path};
    final found =
        (_discovery?.allPaths ?? const <String>[])
            .where(isConfigurableTempPath)
            .where((p) => !used.contains(p))
            .toSet()
            .toList()
          ..sort();
    return found;
  }

  List<String> get _batteryIdOptions {
    final ids = {
      ...?_discovery?.batteryIds,
      _cfg.batteryHouseId,
      _cfg.batteryStartId,
    };
    return ids.toList()..sort();
  }

  // Only the per-controller TOTAL paths are offered here — an individual
  // panel's own reading (see SkDiscovery.solarTotalPaths) would silently
  // report just that one panel's output as if it were the whole
  // controller's contribution.
  List<String?> get _solarOptions => [
    null,
    ...?_discovery?.solarTotalPaths,
    if (_cfg.solarPath != null) _cfg.solarPath,
  ];
  List<String?> get _solarOptions2 => [
    null,
    ...?_discovery?.solarTotalPaths,
    if (_cfg.solarPath2 != null) _cfg.solarPath2,
  ];
  List<String?> get _fridgeOptions => [
    null,
    ...?_discovery?.fridgePaths,
    if (_cfg.fridge1Path != null) _cfg.fridge1Path,
    if (_cfg.fridge2Path != null) _cfg.fridge2Path,
  ];
  List<String?> get _depthOptions => [
    null,
    ...?_discovery?.depthPaths,
    if (_cfg.depthPath != null) _cfg.depthPath,
  ];
  List<String?> get _engineOptions => [
    null,
    ...?_discovery?.enginePaths,
    if (_cfg.enginePath != null) _cfg.enginePath,
  ];

  bool _showAllPaths = false;

  static final RegExp _fridgePathRe = RegExp(
    r'^environment\.(\w*fridge\w*)\.temperature$',
    caseSensitive: false,
  );
  static final RegExp _tankPathRe = RegExp(
    r'^tanks\.[^.]+\.[^.]+\.currentLevel$',
  );
  static final RegExp _enginePathRe = RegExp(r'^propulsion\.[^.]+\.runTime$');
  // Only the specific sub-fields the app actually reads — a battery exposes
  // many more (design specs, alarms, time remaining…) that we never touch,
  // so highlighting the whole electrical.batteries.* subtree would light up
  // paths that are irrelevant noise for mapping AWS/AWA/baterías/solar.
  static const _usefulBatterySuffixes = [
    '.voltage',
    '.current',
    '.capacity.stateOfCharge',
    '.temperature',
  ];
  static const _navPaths = {
    'navigation.position',
    'navigation.speedOverGround',
    'navigation.speedThroughWater',
    'navigation.headingTrue',
    'navigation.courseOverGroundTrue',
    'navigation.attitude',
    'navigation.attitude.roll',
  };
  static const _windPaths = {
    'environment.wind.speedApparent',
    'environment.wind.angleApparent',
    'environment.wind.angleTrueWater',
    'environment.wind.angleTrueGround',
    'environment.wind.directionTrue',
    'environment.wind.speedTrue',
  };
  static const _envPaths = {
    'environment.water.temperature',
    'environment.outside.temperature',
    'environment.outside.humidity',
    'environment.outside.pressure',
    'environment.interior.temperature',
    'environment.interior.humidity',
    'environment.rpi.cpu.temperature',
  };

  /// Category for a discovered path — used only to filter which paths count
  /// as "usable" in "solo los que usa la app" mode. The on-screen highlight
  /// itself is just two colours (en uso / candidato), not one per category —
  /// nine legend colours ate most of the panel's height, leaving almost no
  /// room to actually see the path list.
  String? _pathHint(String path) {
    if (_navPaths.contains(path)) return 'Navegación';
    if (_windPaths.contains(path)) {
      return path.contains('Apparent')
          ? (path.contains('speed') ? 'AWS' : 'AWA')
          : 'Viento';
    }
    if (_envPaths.contains(path)) return 'Ambiente';
    if (path.startsWith('electrical.batteries.') &&
        _usefulBatterySuffixes.any((s) => path.endsWith(s))) {
      return 'Batería';
    }
    if (path.startsWith('electrical.venus.')) return 'Venus';
    if (_fridgePathRe.hasMatch(path)) return 'Nevera';
    if (_tankPathRe.hasMatch(path)) return 'Tanque';
    if (_enginePathRe.hasMatch(path)) return 'Horas motor';
    final lower = path.toLowerCase();
    if (lower.contains('solar') || lower.contains('panel')) return 'Solar';
    if (lower.contains('depth')) return 'Profundidad';
    return null;
  }

  /// True when [path] is exactly what the app is already configured to
  /// read right now (a selected battery id's useful sub-fields, the chosen
  /// solar/nevera/profundidad/tanque paths, or one of the always-on
  /// hardcoded paths) — as opposed to merely *looking* like a good
  /// candidate for one of those roles.
  bool _isInUse(String path) {
    if (_navPaths.contains(path) ||
        _windPaths.contains(path) ||
        _envPaths.contains(path)) {
      return true;
    }
    if (path == 'electrical.venus.dcPower') return true;
    for (final id in [
      _cfg.batteryHouseId,
      _cfg.batteryStartId,
      'bowthruster',
    ]) {
      if (path.startsWith('electrical.batteries.$id.') &&
          _usefulBatterySuffixes.any((s) => path.endsWith(s))) {
        return true;
      }
    }
    if (path == _cfg.solarPath ||
        path == _cfg.solarPath2 ||
        path == _cfg.fridge1Path ||
        path == _cfg.fridge2Path ||
        path == _cfg.depthPath ||
        path == _cfg.enginePath) {
      return true;
    }
    for (final t in _cfg.tanks.where((t) => t.enabled)) {
      if (path == t.skPath) return true;
    }
    return false;
  }

  /// Human-readable labels for every path currently configured that the
  /// last discovery run did NOT see — a stale/broken mapping (e.g. the boat
  /// changed a device id) shows up as "no encontrado" instead of silently
  /// just not updating.
  List<String> get _missingConfiguredPaths {
    final d = _discovery;
    if (d == null) return const [];
    final all = d.allPaths;
    final missing = <String>[];
    void check(String? label, String? path, {bool prefix = false}) {
      if (path == null || path.isEmpty) return;
      final found = prefix
          ? all.any((p) => p.startsWith(path))
          : all.contains(path);
      if (!found) missing.add('$label ($path)');
    }

    check(
      'Batería de servicio',
      'electrical.batteries.${_cfg.batteryHouseId}.',
      prefix: true,
    );
    check(
      'Batería arranque',
      'electrical.batteries.${_cfg.batteryStartId}.',
      prefix: true,
    );
    check('Solar', _cfg.solarPath);
    check('Solar 2', _cfg.solarPath2);
    check('Nevera 1', _cfg.fridge1Path);
    check('Nevera 2', _cfg.fridge2Path);
    check('Profundidad', _cfg.depthPath);
    check('Horas motor', _cfg.enginePath);
    for (final t in _cfg.tanks.where((t) => t.enabled)) {
      check(t.groupLabel, t.skPath);
    }
    return missing;
  }

  List<String> get _duplicateAssignments {
    final duplicates = <String>[];
    if (_cfg.batteryHouseId.isNotEmpty &&
        _cfg.batteryHouseId == _cfg.batteryStartId) {
      duplicates.add('La misma batería está asignada a servicio y arranque.');
    }
    if (_cfg.solarPath != null && _cfg.solarPath == _cfg.solarPath2) {
      duplicates.add('El mismo path está asignado a Solar 1 y Solar 2.');
    }
    if (_cfg.fridge1Path != null && _cfg.fridge1Path == _cfg.fridge2Path) {
      duplicates.add('El mismo path está asignado a Nevera 1 y Nevera 2.');
    }
    if (_cfg.batteryHouseCapacityAh < 0) {
      duplicates.add('La capacidad de servicio no puede ser negativa.');
    }
    final tempPaths = <String>{};
    for (final s in _cfg.tempSensors.where((s) => s.enabled)) {
      if (!tempPaths.add(s.path)) {
        duplicates.add('El sensor ${s.path} está repetido.');
      }
      if (s.label.trim().isEmpty) {
        duplicates.add('Cada sensor de temperatura necesita un nombre.');
      }
    }
    if (_cfg.fridgeWarnC >= _cfg.fridgeAlarmC ||
        _cfg.freezerWarnC >= _cfg.freezerAlarmC ||
        _cfg.equipmentWarnC >= _cfg.equipmentAlarmC) {
      duplicates.add('Cada aviso de temperatura debe ser menor que su alarma.');
    }
    final tankKeys = <String>{};
    for (final tank in _cfg.tanks.where((tank) => tank.enabled)) {
      if (!tankKeys.add(tank.tankKey)) {
        duplicates.add('El tanque ${tank.tankKey} está repetido.');
      }
      if (tank.capacityL < 0) {
        duplicates.add(
          '${tank.groupLabel}: la capacidad no puede ser negativa.',
        );
      }
    }
    return duplicates;
  }

  void _saveIfValid() {
    final errors = <String>[..._duplicateAssignments];
    for (final tank in _cfg.tanks.where((t) => t.enabled)) {
      final warning = tank.warningPct ?? (tank.type == 'blackWater' ? 75 : 30);
      final alarm = tank.alarmPct ?? (tank.type == 'blackWater' ? 90 : 15);
      if (warning < 0 || warning > 100 || alarm < 0 || alarm > 100) {
        errors.add(
          '${tank.groupLabel}: los umbrales deben estar entre 0 y 100%.',
        );
      } else if (tank.type == 'blackWater' && warning >= alarm) {
        errors.add(
          '${tank.groupLabel}: el aviso debe ser menor que la alarma de llenado.',
        );
      } else if (tank.type != 'blackWater' && alarm >= warning) {
        errors.add(
          '${tank.groupLabel}: la alarma de nivel bajo debe ser menor que el aviso.',
        );
      }
      if (tank.capacityL < 0) {
        errors.add('${tank.groupLabel}: la capacidad no puede ser negativa.');
      }
    }
    if (_cfg.batteryHouseCapacityAh < 0) {
      errors.add(
        'La capacidad de la batería de servicio no puede ser negativa.',
      );
    }
    if (_cfg.tempSensors.any((s) => s.enabled && s.label.trim().isEmpty)) {
      errors.add('Cada sensor de temperatura necesita un nombre visible.');
    }
    if (_cfg.fridgeWarnC >= _cfg.fridgeAlarmC ||
        _cfg.freezerWarnC >= _cfg.freezerAlarmC ||
        _cfg.equipmentWarnC >= _cfg.equipmentAlarmC) {
      errors.add('Cada temperatura de aviso debe ser menor que su alarma.');
    }
    if (errors.isEmpty) {
      Navigator.of(context).pop(_cfg);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revisa las asignaciones'),
        content: Text(errors.map((error) => '• $error').join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Corregir'),
          ),
        ],
      ),
    );
  }

  Widget _pathsPanel() {
    if (_discovery == null) {
      final configured = <String>[
        if (_cfg.solarPath != null) 'Solar',
        if (_cfg.solarPath2 != null) 'Solar 2',
        if (_cfg.depthPath != null) 'Profundidad',
        if (_cfg.enginePath != null) 'Horas de motor',
        if (_cfg.fridge1Path != null) 'Nevera 1',
        if (_cfg.fridge2Path != null) 'Nevera 2',
        for (final tank in _cfg.tanks.where((tank) => tank.enabled))
          tank.groupLabel,
      ];
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ESTADO ACTUAL',
              style: TextStyle(
                color: cMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
            const SizedBox(height: 8),
            const SettingsStatusRow(
              label: 'Batería de servicio y arranque',
              value: 'Configuradas',
              color: cGreen,
              icon: Icons.battery_charging_full,
            ),
            SettingsStatusRow(
              label: 'Otras señales asignadas',
              value: '${configured.length}',
              color: configured.isEmpty ? cMuted : cGreen,
              icon: Icons.sensors,
            ),
            if (configured.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                configured.join(' · '),
                style: const TextStyle(color: cMuted, fontSize: 12),
              ),
            ],
            const Spacer(),
            const Text(
              'Busca sensores para comprobar estas asignaciones, detectar señales nuevas y localizar paths que hayan desaparecido.',
              style: TextStyle(color: cMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (_discovery!.allPaths.isEmpty) {
      return const Center(
        child: Text(
          'No se encontró ningún path.',
          style: TextStyle(color: cMuted, fontSize: 13),
        ),
      );
    }
    final missing = _missingConfiguredPaths;
    final shown = _showAllPaths
        ? _discovery!.allPaths
        : [
            for (final p in _discovery!.allPaths)
              if (_pathHint(p) != null) p,
          ];
    // A candidate device (not yet configured) shows up once per field it
    // reports — a battery has .voltage/.current/…, a solar charger has
    // voltage/panelPower/…, tanks have currentLevel, etc. For a candidate
    // that's noise: what the user needs to see is "this device exists",
    // not every field it happens to report. Trim to the device — the last
    // dot-segment for most categories, or the known field suffix for
    // batteries specifically (their useful field is itself compound, e.g.
    // .capacity.stateOfCharge) — and de-duplicate; paths already in use
    // keep showing their exact full path since that IS the field we read.
    final displaySeen = <String>{};
    final displayEntries = <({String text, bool inUse, bool candidate})>[];
    for (final p in shown) {
      final inUse = _isInUse(p);
      final hint = _pathHint(p);
      var text = p;
      if (!inUse && hint == 'Batería') {
        for (final suf in _usefulBatterySuffixes) {
          if (p.endsWith(suf)) {
            text = p.substring(0, p.length - suf.length);
            break;
          }
        }
      } else if (!inUse && hint != null) {
        final idx = p.lastIndexOf('.');
        if (idx > 0) text = p.substring(0, idx);
      }
      if (!displaySeen.add(text)) continue;
      displayEntries.add((text: text, inUse: inUse, candidate: hint != null));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${displayEntries.length} de ${_discovery!.allPaths.length} paths'
                '${_discovery!.silentPaths.isEmpty ? '' : ' · ${_discovery!.silentPaths.length} del histórico, sin emitir ahora'}',
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              icon: Icon(
                _showAllPaths ? Icons.filter_alt_off : Icons.filter_alt,
                size: 16,
              ),
              label: Text(
                _showAllPaths ? 'Mostrando todos' : 'Solo los que usa la app',
                style: const TextStyle(fontSize: 11),
              ),
              onPressed: () => setState(() => _showAllPaths = !_showAllPaths),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 4),
                decoration: const BoxDecoration(
                  color: cGreen,
                  shape: BoxShape.circle,
                ),
              ),
              const Text(
                'En uso',
                style: TextStyle(
                  color: cGreen,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 14),
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 4),
                decoration: const BoxDecoration(
                  color: cOrange,
                  shape: BoxShape.circle,
                ),
              ),
              const Text(
                'Candidato',
                style: TextStyle(
                  color: cOrange,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (missing.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cRed.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: cRed.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Configurados pero no encontrados:',
                  style: TextStyle(
                    color: cRed,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final m in missing)
                  Text(
                    '• $m',
                    style: const TextStyle(color: cRed, fontSize: 11),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    for (final e in displayEntries) ...[
                      TextSpan(
                        text: e.text,
                        style: TextStyle(
                          color: e.inUse
                              ? cGreen
                              : (e.candidate ? cOrange : cText),
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: (e.inUse || e.candidate)
                              ? FontWeight.w700
                              : FontWeight.normal,
                        ),
                      ),
                      const TextSpan(text: '\n'),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const lbl = TextStyle(
      color: cMuted,
      fontSize: 11,
      letterSpacing: 1.1,
      fontWeight: FontWeight.w700,
    );
    return Dialog.fullscreen(
      backgroundColor: cBg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Configurar sensores',
                      style: TextStyle(
                        color: cText,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: cMuted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Left: discovery + paths panel ────────────────────────────
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: cPanel,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OutlinedButton.icon(
                              icon: _loading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.wifi_find, size: 18),
                              label: Text(
                                _loading
                                    ? 'Buscando…'
                                    : 'Buscar sensores en Signal K',
                              ),
                              onPressed: _loading ? null : _discoverNow,
                            ),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    color: cRed,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 10),
                            Expanded(child: _pathsPanel()),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // ── Right: sensor mapping form ───────────────────────────────
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('BATERÍAS', style: lbl),
                            const SizedBox(height: 4),
                            // Stacked, not side-by-side — two dropdowns
                            // sharing a Row in this narrower right-hand
                            // column overlapped/clipped each other.
                            DropdownButtonFormField<String>(
                              initialValue: _cfg.batteryHouseId,
                              decoration: const InputDecoration(
                                labelText: 'Servicio',
                                isDense: true,
                              ),
                              items: [
                                for (final id in _batteryIdOptions)
                                  DropdownMenuItem(
                                    value: id,
                                    child: Text(
                                      id,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(
                                () => _cfg.batteryHouseId =
                                    v ?? _cfg.batteryHouseId,
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: _cfg.batteryStartId,
                              decoration: const InputDecoration(
                                labelText: 'Arranque',
                                isDense: true,
                              ),
                              items: [
                                for (final id in _batteryIdOptions)
                                  DropdownMenuItem(
                                    value: id,
                                    child: Text(
                                      id,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(
                                () => _cfg.batteryStartId =
                                    v ?? _cfg.batteryStartId,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              initialValue: _cfg.batteryHouseCapacityAh == 0
                                  ? ''
                                  : _cfg.batteryHouseCapacityAh.toStringAsFixed(
                                      0,
                                    ),
                              decoration: const InputDecoration(
                                labelText: 'Capacidad servicio (Ah, opcional)',
                                helperText: 'Permite estimar autonomía solo con corriente reciente.',
                                isDense: true,
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              onChanged: (raw) => _cfg.batteryHouseCapacityAh =
                                  double.tryParse(raw.replaceAll(',', '.')) ??
                                  0,
                            ),
                            const SizedBox(height: 12),
                            const Text('SOLAR', style: lbl),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.solarPath,
                              decoration: const InputDecoration(
                                labelText: 'Path de potencia solar',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _solarOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'Ninguno',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.solarPath = v),
                            ),
                            const SizedBox(height: 8),
                            // Optional — only for boats with two independent
                            // solar controllers. With just the first path set,
                            // nothing changes: that reading already is "the
                            // total". With both, PWR shows the sum plus each
                            // panel's own reading.
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.solarPath2,
                              decoration: const InputDecoration(
                                labelText:
                                    'Path del 2º controlador solar (opcional)',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _solarOptions2)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'Ninguno',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.solarPath2 = v),
                            ),
                            const SizedBox(height: 12),
                            const Text('PROFUNDIDAD', style: lbl),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.depthPath,
                              decoration: const InputDecoration(
                                labelText: 'Path de profundidad',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _depthOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'Ninguno',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.depthPath = v),
                            ),
                            const SizedBox(height: 12),
                            const Text('HORAS DE MOTOR', style: lbl),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.enginePath,
                              decoration: const InputDecoration(
                                labelText: 'Path de horas de motor (runTime)',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _engineOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'Ninguno',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.enginePath = v),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'NEVERAS (alarma y tarjeta NAV)',
                              style: lbl,
                            ),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.fridge1Path,
                              decoration: const InputDecoration(
                                labelText: 'Nevera 1',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _fridgeOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'Ninguna',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.fridge1Path = v),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.fridge2Path,
                              decoration: const InputDecoration(
                                labelText: 'Nevera 2',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _fridgeOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'Ninguna',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.fridge2Path = v),
                            ),
                            const SizedBox(height: 12),
                            const Text('SENSORES DE TEMPERATURA', style: lbl),
                            const Text(
                              'Lo que se ve en la pantalla TMP. Aquí se ponen el nombre y la ubicación de cada sensor, neveras incluidas.',
                              style: TextStyle(color: cMuted, fontSize: 12),
                            ),
                            const SizedBox(height: 4),
                            if (_cfg.tempSensors.isEmpty)
                              const Text(
                                'Ninguno todavía — pulsa "Buscar sensores".',
                                style: TextStyle(color: cMuted, fontSize: 12),
                              ),
                            for (final s in _cfg.tempSensors)
                              Padding(
                                key: ValueKey(s.path),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Row(
                                  children: [
                                    Checkbox(
                                      value: s.enabled,
                                      onChanged: (v) => setState(
                                        () => s.enabled = v ?? false,
                                      ),
                                    ),
                                    Expanded(
                                      flex: 3,
                                      child: TextFormField(
                                        initialValue: s.label,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          labelText: 'Nombre',
                                        ),
                                        onChanged: (v) => s.label = v,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      flex: 2,
                                      child: TextFormField(
                                        initialValue: s.note,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          labelText: 'Ubicación',
                                        ),
                                        onChanged: (v) => s.note = v,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      flex: 2,
                                      child: DropdownButtonFormField<String>(
                                        initialValue: s.role,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          labelText: 'Tipo',
                                        ),
                                        items: [
                                          for (final e
                                              in kTempSensorRoles.entries)
                                            DropdownMenuItem(
                                              value: e.key,
                                              child: Text(e.value),
                                            ),
                                        ],
                                        onChanged: (v) => setState(
                                          () => s.role = v ?? s.role,
                                        ),
                                      ),
                                    ),
                                    if (_showsBatteryPicker(s.batteryPath)) ...[
                                      const SizedBox(width: 6),
                                      Expanded(
                                        flex: 2,
                                        child: DropdownButtonFormField<String?>(
                                          initialValue: s.batteryPath,
                                          isExpanded: true,
                                          decoration: const InputDecoration(
                                            isDense: true,
                                            labelText: 'Pila',
                                          ),
                                          items: [
                                            for (final p in _batteryPathOptions(
                                              s.batteryPath,
                                            ))
                                              DropdownMenuItem(
                                                value: p,
                                                child: Text(
                                                  p == null
                                                      ? 'Sin pila'
                                                      : _pilaCorta(p),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged: (v) =>
                                              setState(() => s.batteryPath = v),
                                        ),
                                      ),
                                    ],
                                    IconButton(
                                      tooltip: s.path,
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                      ),
                                      onPressed: () => setState(
                                        () => _cfg.tempSensors.remove(s),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (_tempPathOptions.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              DropdownButtonFormField<String?>(
                                initialValue: null,
                                decoration: const InputDecoration(
                                  labelText: 'Añadir sensor de temperatura',
                                  isDense: true,
                                ),
                                items: [
                                  for (final p in _tempPathOptions)
                                    DropdownMenuItem(
                                      value: p,
                                      child: Text(
                                        p,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(
                                    () => _cfg.tempSensors.add(
                                      TempSensorSlot(
                                        path: v,
                                        label: TempSensorSlot.labelFromPath(v),
                                        role: TempSensorSlot.roleFromPath(v),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                            const SizedBox(height: 12),
                            const Text('UMBRALES POR TIPO (°C)', style: lbl),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _numberField(
                                  'Nevera aviso',
                                  _cfg.fridgeWarnC,
                                  (v) => _cfg.fridgeWarnC = v,
                                ),
                                _numberField(
                                  'Nevera alarma',
                                  _cfg.fridgeAlarmC,
                                  (v) => _cfg.fridgeAlarmC = v,
                                ),
                                _numberField(
                                  'Congelador aviso',
                                  _cfg.freezerWarnC,
                                  (v) => _cfg.freezerWarnC = v,
                                ),
                                _numberField(
                                  'Congelador alarma',
                                  _cfg.freezerAlarmC,
                                  (v) => _cfg.freezerAlarmC = v,
                                ),
                                _numberField(
                                  'Equipo aviso',
                                  _cfg.equipmentWarnC,
                                  (v) => _cfg.equipmentWarnC = v,
                                ),
                                _numberField(
                                  'Equipo alarma',
                                  _cfg.equipmentAlarmC,
                                  (v) => _cfg.equipmentAlarmC = v,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Text('TARJETAS OPCIONALES', style: lbl),
                            const Text(
                              'En automático solo se ven si el barco publica ese dato. Si un sensor está apagado ahora mismo, ponlo en Mostrar.',
                              style: TextStyle(color: cMuted, fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.bowthrusterPath,
                              decoration: const InputDecoration(
                                labelText: 'Hélice de proa (voltaje)',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _bowthrusterOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'No tiene',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.bowthrusterPath = v),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String?>(
                              initialValue: _cfg.dcLoadsPath,
                              decoration: const InputDecoration(
                                labelText: 'Consumos DC (potencia total)',
                                isDense: true,
                              ),
                              items: [
                                for (final p in _dcLoadsOptions)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p ?? 'No tiene',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _cfg.dcLoadsPath = v),
                            ),
                            const SizedBox(height: 8),
                            const SizedBox(height: 4),
                            for (final card in kOptionalCardLabels.entries)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            card.value,
                                            style: const TextStyle(
                                              color: cText,
                                              fontSize: 13,
                                            ),
                                          ),
                                          Text(
                                            _cardStatusText(card.key),
                                            style: TextStyle(
                                              color: _cardDetected(card.key)
                                                  ? cGreen
                                                  : cMuted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    SegmentedButton<String>(
                                      style: const ButtonStyle(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      segments: const [
                                        ButtonSegment(
                                          value: 'auto',
                                          label: Text(
                                            'Auto',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                        ButtonSegment(
                                          value: 'on',
                                          label: Text(
                                            'Mostrar',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                        ButtonSegment(
                                          value: 'off',
                                          label: Text(
                                            'Ocultar',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ),
                                      ],
                                      selected: {
                                        _cfg.cardVisibility[card.key] ?? 'auto',
                                      },
                                      onSelectionChanged: (v) => setState(
                                        () => _cfg.cardVisibility[card.key] =
                                            v.first,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 12),
                            const Text('TANQUES', style: lbl),
                            const SizedBox(height: 4),
                            if (_cfg.tanks.isEmpty)
                              const Text(
                                'Ninguno encontrado todavía — pulsa "Buscar sensores".',
                                style: TextStyle(color: cMuted, fontSize: 12),
                              ),
                            for (final t in _cfg.tanks)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Checkbox(
                                          value: t.enabled,
                                          onChanged: (v) => setState(
                                            () => t.enabled = v ?? false,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 2,
                                          child: TextFormField(
                                            initialValue: t.groupLabel,
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              labelText: 'Nombre',
                                            ),
                                            onChanged: (v) => t.groupLabel = v,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${t.type}.${t.id}',
                                          style: const TextStyle(
                                            color: cMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // Tipo con el que se PINTA, que no
                                        // siempre puede ser el de la ruta:
                                        // signalk-venus-plugin solo traduce
                                        // los fluidos 0-5 de Victron, así
                                        // que una bombona de gas (tipo 8)
                                        // llega como `unknown` aunque en el
                                        // Venus esté puesta como LPG. Aquí
                                        // se marca como tal sin tocar el
                                        // path del que se lee el dato.
                                        SizedBox(
                                          width: 108,
                                          child:
                                              DropdownButtonFormField<String>(
                                                initialValue: t.kind,
                                                isDense: true,
                                                decoration:
                                                    const InputDecoration(
                                                      isDense: true,
                                                      labelText: 'Mostrar como',
                                                    ),
                                                items: [
                                                  for (final k in {
                                                    t.type,
                                                    'fuel',
                                                    'lpg',
                                                    'freshWater',
                                                    'blackWater',
                                                  })
                                                    DropdownMenuItem(
                                                      value: k,
                                                      child: Text(
                                                        _tankKindLabels[k] ?? k,
                                                        style: const TextStyle(
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                                onChanged: (v) => setState(() {
                                                  // Guardamos null cuando
                                                  // coincide con el tipo real,
                                                  // para no fijar una
                                                  // anulación innecesaria.
                                                  t.displayType =
                                                      (v == null || v == t.type)
                                                      ? null
                                                      : v;
                                                }),
                                              ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 80,
                                          child: TextFormField(
                                            initialValue: '${t.capacityL}',
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              labelText: 'Litros',
                                            ),
                                            keyboardType: TextInputType.number,
                                            onChanged: (v) => t.capacityL =
                                                int.tryParse(v) ?? t.capacityL,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 48,
                                        top: 4,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              t.capacityL > 0
                                                  ? 'Capacidad configurada'
                                                  : 'Sin calibrar capacidad',
                                              style: TextStyle(
                                                color: t.capacityL > 0
                                                    ? cGreen
                                                    : cOrange,
                                                fontSize: 10,
                                              ),
                                            ),
                                          ),
                                          if (_showsBatteryPicker(
                                            t.batteryPath,
                                          ))
                                            SizedBox(
                                              width: 150,
                                              child:
                                                  DropdownButtonFormField<
                                                    String?
                                                  >(
                                                    initialValue: t.batteryPath,
                                                    isExpanded: true,
                                                    decoration:
                                                        const InputDecoration(
                                                          isDense: true,
                                                          labelText: 'Pila',
                                                        ),
                                                    items: [
                                                      for (final p
                                                          in _batteryPathOptions(
                                                            t.batteryPath,
                                                          ))
                                                        DropdownMenuItem(
                                                          value: p,
                                                          child: Text(
                                                            p == null
                                                                ? 'Sin pila'
                                                                : _pilaCorta(p),
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 12,
                                                                ),
                                                          ),
                                                        ),
                                                    ],
                                                    onChanged: (v) => setState(
                                                      () => t.batteryPath = v,
                                                    ),
                                                  ),
                                            ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: 94,
                                            child: TextFormField(
                                              initialValue:
                                                  '${t.warningPct ?? (t.type == 'blackWater' ? 75 : 30)}',
                                              decoration: const InputDecoration(
                                                isDense: true,
                                                labelText: 'Aviso %',
                                              ),
                                              keyboardType:
                                                  const TextInputType.numberWithOptions(
                                                    decimal: true,
                                                  ),
                                              onChanged: (raw) => t.warningPct =
                                                  double.tryParse(
                                                    raw.replaceAll(',', '.'),
                                                  ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: 94,
                                            child: TextFormField(
                                              initialValue:
                                                  '${t.alarmPct ?? (t.type == 'blackWater' ? 90 : 15)}',
                                              decoration: const InputDecoration(
                                                isDense: true,
                                                labelText: 'Alarma %',
                                              ),
                                              keyboardType:
                                                  const TextInputType.numberWithOptions(
                                                    decimal: true,
                                                  ),
                                              onChanged: (raw) =>
                                                  t.alarmPct = double.tryParse(
                                                    raw.replaceAll(',', '.'),
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saveIfValid,
                    child: const Text('Guardar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
