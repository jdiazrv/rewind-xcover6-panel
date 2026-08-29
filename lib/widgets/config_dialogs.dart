part of '../main.dart';

String friendlyApiError(Object e) {
  final s = e.toString();
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
  final Future<SkDiscovery?> Function() discover;

  @override
  State<_SensorConfigDialog> createState() => _SensorConfigDialogState();
}

class _SensorConfigDialogState extends State<_SensorConfigDialog> {
  late SensorConfig _cfg;
  SkDiscovery? _discovery;
  bool _loading = false;
  String? _error;

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
    final d = await widget.discover();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (d == null) {
        _error =
            'No se pudo conectar a Signal K (${'revisa host/puerto en CFG'})';
        return;
      }
      _discovery = d;
      _cfg.hasOutsideTemp = d.hasOutsideTemp;
      _cfg.hasOutsidePressure = d.hasOutsidePressure;
      for (final tc in d.tanks) {
        final idx = _cfg.tanks.indexWhere(
          (t) => t.type == tc.type && t.id == tc.id,
        );
        if (idx < 0) {
          _cfg.tanks.add(
            TankSlot(
              type: tc.type,
              id: tc.id,
              groupLabel: '${tc.type} ${tc.id}',
              capacityL: tc.capacityL ?? 0,
              enabled: false,
            ),
          );
        } else if (tc.capacityL != null && _cfg.tanks[idx].capacityL == 0) {
          _cfg.tanks[idx].capacityL = tc.capacityL!;
        }
      }
    });
  }

  List<String> get _batteryIdOptions {
    final ids = {
      ...?_discovery?.batteryIds,
      _cfg.batteryHouseId,
      _cfg.batteryStartId,
    };
    return ids.toList()..sort();
  }

  List<String?> get _solarOptions => [
    null,
    ...?_discovery?.solarPaths,
    if (_cfg.solarPath != null) _cfg.solarPath,
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
    check('Nevera 1', _cfg.fridge1Path);
    check('Nevera 2', _cfg.fridge2Path);
    check('Profundidad', _cfg.depthPath);
    check('Horas motor', _cfg.enginePath);
    for (final t in _cfg.tanks.where((t) => t.enabled)) {
      check(t.groupLabel, t.skPath);
    }
    return missing;
  }

  Widget _pathsPanel() {
    if (_discovery == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Pulsa "Buscar sensores" para descubrir los paths disponibles en tu Signal K.',
            style: TextStyle(color: cMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
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
                '${displayEntries.length} de ${_discovery!.allPaths.length} paths',
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
      fontSize: 10,
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
                            const Text('NEVERAS', style: lbl),
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
                                child: Row(
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
                    onPressed: () => Navigator.of(context).pop(_cfg),
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
