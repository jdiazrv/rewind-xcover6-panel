import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart' as ll;

import 'fullscreen/fullscreen_stub.dart'
    if (dart.library.html) 'fullscreen/fullscreen_web.dart'
    as app_fullscreen;
import 'lan_scan/lan_scan_stub.dart'
    if (dart.library.io) 'lan_scan/lan_scan_io.dart'
    if (dart.library.html) 'lan_scan/lan_scan_web.dart';
import 'webview_embed/webview_embed_stub.dart'
    if (dart.library.io) 'webview_embed/webview_embed_io.dart'
    if (dart.library.html) 'webview_embed/webview_embed_web.dart';
import 'ws_connect/ws_connect_stub.dart'
    if (dart.library.io) 'ws_connect/ws_connect_io.dart'
    if (dart.library.html) 'ws_connect/ws_connect_web.dart';

import 'ais_view.dart';
import 'attitude_sensor.dart';
import 'data_api.dart';
import 'geocode.dart';
import 'model_comparison.dart';
import 'models.dart';
import 'performance_report.dart';
import 'theme.dart';

part 'utils/format_helpers.dart';
part 'widgets/anchor_webview.dart';
part 'widgets/config_dialogs.dart';
part 'widgets/header.dart';
part 'widgets/attitude_dialogs.dart';
part 'widgets/painters.dart';
part 'widgets/metric_card.dart';
part 'widgets/graph_dialog.dart';
part 'widgets/misc_cards.dart';
part 'widgets/alarm_and_shell.dart';
part 'utils/trackers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const RewindApp());
}

/// True when this web build is being served from Signal K's own webapp
/// mount point (see package.json's "name") rather than deployed standalone
/// (e.g. the Netlify build) — in that case Signal K's host/port is always
/// this same origin, never user-configurable.
bool get _isSignalKWebapp =>
    kIsWeb && Uri.base.path.startsWith('/rewind-xcover6-panel');

// ─── App ──────────────────────────────────────────────────────────────────────
class RewindApp extends StatelessWidget {
  const RewindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'REWIND Panel',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: cBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: cCyan,
          brightness: Brightness.dark,
          surface: cPanel,
        ),
      ),
      home: const Dashboard(),
    );
  }
}

// ─── Dashboard ────────────────────────────────────────────────────────────────
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final signalK = SignalKModel();
  final weather = WeatherModel();
  final settings = SettingsModel();
  final _pageController = PageController();

  WebSocketChannel? channel;
  Timer? reconnectTimer;
  Timer? weatherTimer;
  Timer? _demoTimer;
  final _demoClockStart = DateTime.now();
  PhoneHeelTracker? _phoneHeelTracker;

  int page = 0;
  double _marineHorizonHours = 1;
  // See the enginePath dynamic handler — set to "now + 20s" every time
  // engine hours is observed to increase, so a short gap after the engine
  // stops still reads as running rather than flickering off between deltas.
  DateTime? _engineRunningUntil;
  bool get _engineRunning =>
      _engineRunningUntil != null &&
      DateTime.now().isBefore(_engineRunningUntil!);
  bool loadingWeather = false;
  // Manual pick from the PRON map picker overrides the boat's own GPS position
  // for weather queries only — null means "use signalK's position" (default).
  double? _manualWeatherLat;
  double? _manualWeatherLon;
  double? get _weatherLat => _manualWeatherLat ?? signalK.latitude;
  double? get _weatherLon => _manualWeatherLon ?? signalK.longitude;
  bool _headerHidden = false;
  Timer? _navHideTimer;

  // CFG > Conexión text field controllers. Kept as State fields (created
  // once, lazily) rather than local vars inside _settingsPage(), which runs
  // on every Dashboard rebuild — with live Signal K data arriving every
  // second or so, a fresh TextEditingController(text: settings.host) on
  // each rebuild wiped out whatever the user had mid-typed into the field
  // before they hit "Guardar", snapping it back to the old saved host.
  TextEditingController? _hostController;
  TextEditingController? _portController;
  TextEditingController? _authController;
  TextEditingController? _skUsernameController;
  TextEditingController? _skPasswordController;
  TextEditingController? _bucketController;
  TextEditingController? _influxHostController;
  TextEditingController? _influxOrgController;
  TextEditingController? _influxTokenController;

  // AIS (MAP > swipe down) — subscribed on demand, see _subscribeAis/_unsubscribeAis
  String? _selfContext;
  bool _aisSubscribed = false;
  final _aisTargets = <String, AisTarget>{};

  // Live Signal K zone alarms — keyed by the path under "notifications."
  // (e.g. "environment.wind.speedApparent"), only entries currently in an
  // alert/warn/alarm/emergency state. See AlarmEngine below for how this
  // combines with custom alarms into what's actually shown/sounded.
  final _notifications = <String, ({String state, String? message})>{};
  static const _activeAlertStates = {'alert', 'warn', 'alarm', 'emergency'};
  AudioPlayer? _alarmPlayer;
  bool _alarmSoundPlaying = false;
  final _mutedAlarms =
      <String>{}; // acknowledged-until-it-clears, no auto-unmute
  // Generic "last value by Signal K path" cache for any *.temperature path
  // we're subscribed to — lets a 'tempAbove' custom alarm target *any*
  // discovered temperature sensor, not just a hardcoded handful, without
  // needing a dedicated SignalKModel field for each one.
  final _customTempValues = <String, double?>{};

  // Corredera stall alarm — needs a sustained (3s) condition, not just an
  // instant snapshot, so this is tracked across ticks of _staleWatchdog
  // rather than computed fresh inside the _activeAlarms getter.
  DateTime? _correderaSince;
  bool _correderaActive = false;
  void _checkCorredera() {
    if (!settings.alarmCorrederaEnabled) {
      _correderaSince = null;
      _correderaActive = false;
      return;
    }
    final sog = signalK.sogKn;
    final stw = signalK.stwKn;
    final condition = sog != null && sog > 2 && stw != null && stw == 0;
    if (!condition) {
      _correderaSince = null;
      _correderaActive = false;
      return;
    }
    _correderaSince ??= DateTime.now();
    _correderaActive =
        DateTime.now().difference(_correderaSince!) >=
        const Duration(seconds: 3);
  }

  void _routeNotification(String path, dynamic value) {
    if (value is! Map) {
      _notifications.remove(path);
      return;
    }
    final state = value['state'] as String?;
    final message = value['message'] as String?;
    if (state == null || !_activeAlertStates.contains(state)) {
      _notifications.remove(path);
      _mutedAlarms.remove(path);
      return;
    }
    _notifications[path] = (state: state, message: message);
  }

  // ─── Alarm engine ──────────────────────────────────────────────────────────
  // Combines Signal K zone notifications (if enabled) with client-side
  // custom rules into one list the UI (card highlight, header bell, sound)
  // reads from — neither source knows about the other beyond this point.
  List<({String key, String label, bool sound, bool muted})> get _activeAlarms {
    final out = <({String key, String label, bool sound, bool muted})>[];
    if (settings.alarmsUseSkZones) {
      for (final entry in _notifications.entries) {
        final cfg = settings.skZoneAlarms[entry.key];
        if (cfg != null && !cfg.enabled) continue;
        final key = 'sk:${entry.key}';
        out.add((
          key: key,
          label: entry.value.message ?? entry.key,
          sound: cfg?.sound ?? true,
          muted: _mutedAlarms.contains(key),
        ));
      }
    }
    for (final rule in settings.customAlarms) {
      if (!rule.enabled || !_customAlarmTriggered(rule)) continue;
      final key = 'custom:${rule.id}';
      out.add((
        key: key,
        label: rule.label,
        sound: rule.sound,
        muted: _mutedAlarms.contains(key),
      ));
    }
    if (settings.alarmCorrederaEnabled && _correderaActive) {
      const key = 'corredera';
      out.add((
        key: key,
        label: 'Corredera (SOG sin STW)',
        sound: settings.alarmCorrederaSound,
        muted: _mutedAlarms.contains(key),
      ));
    }
    if (settings.alarmAisEnabled) {
      final closest = _closestApproachTarget();
      final cpa = closest?.cpaNm;
      final tcpa = closest?.tcpaMin;
      // tcpa > 0 — a negative TCPA means the target's already at its
      // closest point and opening again, not actually converging.
      if (cpa != null &&
          tcpa != null &&
          tcpa > 0 &&
          cpa <= settings.alarmAisCpaNm &&
          tcpa <= settings.alarmAisTcpaMin) {
        const key = 'ais';
        out.add((
          key: key,
          label:
              'AIS: ${_aisTargetName(closest!.target)} — CPA ${cpa.toStringAsFixed(1)} NM / TCPA ${tcpa.round()} min',
          sound: settings.alarmAisSound,
          muted: _mutedAlarms.contains(key),
        ));
      }
    }
    return out;
  }

  bool _customAlarmTriggered(CustomAlarmRule rule) {
    switch (rule.type) {
      case 'depthBelow':
        final d = signalK.depthM;
        return d != null && d < rule.threshold;
      case 'windAbove':
        final w = signalK.awsKn;
        return w != null && w > rule.threshold;
      case 'batteryVoltageBelow':
        final v = signalK.houseV;
        return v != null && v < rule.threshold;
      case 'socBelow':
        final s = signalK.houseSoc;
        return s != null && s < rule.threshold;
      case 'tempAbove':
        // rule.target is a real Signal K path (e.g.
        // "environment.fridge_2.temperature") — _customTempValues caches
        // the latest reading for *every* subscribed *.temperature path,
        // so this works for any discovered sensor, not just a fixed set.
        final kelvin = rule.target == null
            ? null
            : _customTempValues[rule.target];
        return kelvin != null && (kelvin - 273.15) > rule.threshold;
      case 'tankBelow':
        return signalK.tanks.values.any((v) => v != null && v < rule.threshold);
      case 'windForecastAbove':
        final now = DateTime.now();
        final cutoff = now.add(const Duration(hours: 6));
        for (final p in weather.hourly) {
          if (p.time.isBefore(now) || p.time.isAfter(cutoff)) continue;
          if ((p.windKn ?? 0) > rule.threshold) return true;
        }
        return false;
      default:
        return false;
    }
  }

  bool get _alarmSoundShouldPlay =>
      _activeAlarms.any((a) => a.sound && !a.muted);

  Future<void> _syncAlarmSound() async {
    final shouldPlay = _alarmSoundShouldPlay;
    if (shouldPlay && !_alarmSoundPlaying) {
      _alarmSoundPlaying = true;
      _alarmPlayer ??= AudioPlayer();
      await _alarmPlayer!.setReleaseMode(ReleaseMode.loop);
      await _alarmPlayer!.play(AssetSource('sound/alarm.wav'));
    } else if (!shouldPlay && _alarmSoundPlaying) {
      _alarmSoundPlaying = false;
      await _alarmPlayer?.stop();
    }
  }

  void _muteAlarm(String key) {
    setState(() => _mutedAlarms.add(key));
    unawaited(_syncAlarmSound());
  }

  // Crude keyword mapping from an alarm's underlying path (or custom-rule
  // type) to the header tab it belongs to — good enough to point the user
  // at the right screen without a hardcoded table for every possible SK path.
  String? _pageForAlarmKey(String key) {
    if (key == 'corredera') return 'NAV';
    if (key.startsWith('custom:')) {
      final id = key.substring('custom:'.length);
      for (final rule in settings.customAlarms) {
        if (rule.id != id) continue;
        return switch (rule.type) {
          'depthBelow' => 'NAV',
          'windAbove' => 'VNT',
          _ => null,
        };
      }
      return null;
    }
    final p = key.substring('sk:'.length).toLowerCase();
    if (p.contains('anchor')) return 'ANC';
    if (p.contains('wind')) return 'VNT';
    if (p.contains('depth')) return 'NAV';
    if (p.contains('electrical') || p.contains('batter')) return 'PWR';
    if (p.contains('tank')) return 'TNK';
    if (p.contains('outside') ||
        p.contains('interior') ||
        p.contains('pressure') ||
        p.contains('humidity')) {
      return 'MET';
    }
    return null;
  }

  // Per-card highlight — only wired up for depth so far (the concrete
  // example asked for); extend this switch for other cards as needed.
  bool _isCardAlarming(String cardId) {
    for (final a in _activeAlarms) {
      if (a.key == 'corredera' && (cardId == 'sog' || cardId == 'stw')) {
        return true;
      }
      if (a.key.startsWith('custom:')) {
        final id = a.key.substring('custom:'.length);
        for (final rule in settings.customAlarms) {
          if (rule.id == id && rule.type == 'depthBelow' && cardId == 'depth') {
            return true;
          }
        }
      } else if (cardId == 'depth' &&
          a.key.substring('sk:'.length).toLowerCase().contains('depth')) {
        return true;
      }
    }
    return false;
  }

  Set<String> get _alarmPageIds => {
    for (final a in _activeAlarms) ?_pageForAlarmKey(a.key),
  };

  Future<CustomAlarmRule?> _showAddCustomAlarmDialog(BuildContext context) {
    final sortedTypes = [...customAlarmTypes]
      ..sort(
        (a, b) => customAlarmTypeLabel(a).compareTo(customAlarmTypeLabel(b)),
      );
    var type = sortedTypes.first;
    // Seeded with the sensors this app already knows the paths for; "Buscar
    // más sensores" below adds any other *.temperature path Signal K is
    // currently reporting, so this covers whatever's actually on the boat
    // rather than a fixed list.
    final c = settings.sensorConfig;
    final tempTargets = <String>{
      if (c.fridge1Path != null && c.fridge1Path!.isNotEmpty) c.fridge1Path!,
      if (c.fridge2Path != null && c.fridge2Path!.isNotEmpty) c.fridge2Path!,
      'electrical.batteries.${c.batteryHouseId}.temperature',
      'environment.rpi.cpu.temperature',
      'electrical.batteries.bowthruster.temperature',
    };
    var target = tempTargets.first;
    var discoveringTemps = false;
    final thresholdController = TextEditingController(text: '5');
    return showDialog<CustomAlarmRule>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Dialog(
          backgroundColor: cBg,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nueva alarma personalizada',
                    style: TextStyle(
                      color: cText,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButton<String>(
                    value: type,
                    isExpanded: true,
                    dropdownColor: cPanel,
                    style: const TextStyle(color: cText),
                    items: [
                      for (final t in sortedTypes)
                        DropdownMenuItem(
                          value: t,
                          child: Text(customAlarmTypeLabel(t)),
                        ),
                    ],
                    onChanged: (v) => setSt(() => type = v ?? type),
                  ),
                  if (type == 'tempAbove') ...[
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      value: target,
                      isExpanded: true,
                      dropdownColor: cPanel,
                      style: const TextStyle(color: cText),
                      items: [
                        for (final t in tempTargets)
                          DropdownMenuItem(
                            value: t,
                            child: Text(tempAlarmTargetLabel(t)),
                          ),
                      ],
                      onChanged: (v) => setSt(() => target = v ?? target),
                    ),
                    TextButton.icon(
                      icon: discoveringTemps
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search, size: 16),
                      label: const Text('Buscar más sensores de temperatura'),
                      onPressed: discoveringTemps
                          ? null
                          : () async {
                              setSt(() => discoveringTemps = true);
                              final d = await discoverSkPaths();
                              if (d != null) {
                                for (final p in d.allPaths) {
                                  if (p.toLowerCase().endsWith(
                                        '.temperature',
                                      ) &&
                                      !excludedTempAlarmPaths.contains(p)) {
                                    tempTargets.add(p);
                                  }
                                }
                              }
                              setSt(() => discoveringTemps = false);
                            },
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: thresholdController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Umbral (${customAlarmTypeUnit(type)})',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancelar'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          final threshold = double.tryParse(
                            thresholdController.text.trim().replaceAll(
                              ',',
                              '.',
                            ),
                          );
                          if (threshold == null) return;
                          Navigator.of(ctx).pop(
                            CustomAlarmRule(
                              id: DateTime.now().millisecondsSinceEpoch
                                  .toString(),
                              type: type,
                              threshold: threshold,
                              target: type == 'tempAbove' ? target : null,
                            ),
                          );
                        },
                        child: const Text('Añadir'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAlarmsList(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final alarms = _activeAlarms;
          return Dialog(
            backgroundColor: cBg,
            insetPadding: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Alarmas activas',
                            style: TextStyle(
                              color: cText,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: cMuted),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    if (alarms.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Sin alarmas activas.',
                          style: TextStyle(color: cMuted),
                        ),
                      ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final a in alarms)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    color: cRed,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      a.label,
                                      style: const TextStyle(
                                        color: cText,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  if (a.sound && !a.muted)
                                    TextButton(
                                      onPressed: () {
                                        _muteAlarm(a.key);
                                        setSt(() {});
                                      },
                                      child: const Text('Silenciar'),
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
          );
        },
      ),
    );
  }

  // B&G-style circular dampers for wind instruments
  final _twsDamp = _WindCircularDamper(tau: 5.0);
  final _twaDamp = _WindCircularDamper(tau: 5.0);
  final _twdDamp = _WindCircularDamper(tau: 5.0);
  final _awsDamp = _WindCircularDamper(tau: 3.0);
  final _awaDamp = _WindCircularDamper(tau: 3.0);
  double? _dTws, _dTwa, _dTwd, _dAws, _dAwa;

  // 30-min rolling history for wind trend + gusts (raw, undamped values)
  final _twsHistory = _WindHistory();
  final _awsHistory = _WindHistory();
  final _pressureHistory = _PressureHistory();
  bool _pressureTrendFromInflux = false;
  bool _loadingPressureTrend = false;
  final _depthTrend = _DepthTrendTracker();
  // Same top-down artwork/loader as the AIS radar (ais_view.dart), reused
  // here so the Fondeado anchor ring shows the real hull instead of a
  // generic triangle.
  ui.Image? _shipIcon;

  @override
  void initState() {
    super.initState();
    loadShipIcon().then((img) {
      if (mounted) setState(() => _shipIcon = img);
    });
    unawaited(_boot());
    // Re-render periodically so nav/wind cards flip to "--" once stale, even
    // without a new Signal K message arriving to trigger a rebuild.
    _staleWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkCorredera();
      unawaited(_syncAlarmSound());
      if (mounted) setState(() {});
    });
  }

  Timer? _staleWatchdog;

  Future<void> _boot() async {
    await _loadSettings();
    // The first build() can run (and lazily create the CFG field
    // controllers, see _settingsPage) before this async load finishes —
    // refresh them now so they don't get stuck showing pre-load defaults.
    _hostController?.text = settings.host;
    _portController?.text = '${settings.port}';
    _authController?.text = settings.authBase64;
    _skUsernameController?.text = settings.skUsername;
    _skPasswordController?.text = settings.skPassword;
    _bucketController?.text = settings.influxBucket;
    _influxHostController?.text = settings.influxHost;
    _influxOrgController?.text = settings.influxOrg;
    _influxTokenController?.text = settings.influxToken;
    if (!kIsWeb) await _loadWeatherCache();
    if (settings.demoMode) {
      _startDemoMode();
    } else {
      _connectSignalK();
      Timer(const Duration(seconds: 12), _maybePromptDemoMode);
      if (_isSignalKWebapp) unawaited(_loginToSignalK());
      unawaited(_fetchVesselName());
    }
    weatherTimer = Timer.periodic(
      const Duration(minutes: 20),
      (_) => _loadWeather(),
    );
    await _loadWeather(force: kIsWeb);
  }

  void _maybePromptDemoMode() {
    if (!mounted || settings.demoMode || signalK.connected) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: const Text(
          'Sin conexión a Signal K',
          style: TextStyle(color: cText),
        ),
        content: const Text(
          'No se ha podido conectar con el servidor Signal K (revisa host/puerto en CFG). ¿Quieres activar el modo DEMO mientras tanto, con datos simulados?',
          style: TextStyle(color: cMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Seguir intentando'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setDemoMode(true);
            },
            child: const Text('Activar DEMO'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isSignalKWebapp) {
      // Served from Signal K's own webapp mount — always this same origin.
      // Never trust a cached host/port here: a device that previously
      // visited a *different* Signal K server's webapp (different boat,
      // different IP/hostname) would otherwise keep reconnecting to that
      // stale host instead of the one it's actually being served from.
      settings.host = Uri.base.host;
      if (Uri.base.hasPort) settings.port = Uri.base.port;
    } else {
      // Android app / standalone (Netlify) web build: host/port are
      // user-configurable in CFG. On web, default to the page's own origin
      // on first run (nothing saved yet) as a convenience guess only —
      // unlike the webapp case above, a saved value always wins here.
      settings.host =
          prefs.getString('host') ??
          (kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : settings.host);
      settings.port =
          prefs.getInt('port') ??
          (kIsWeb && Uri.base.hasPort ? Uri.base.port : settings.port);
    }
    settings.authBase64 = prefs.getString('auth') ?? settings.authBase64;
    settings.skUsername = prefs.getString('skUsername') ?? settings.skUsername;
    settings.skPassword = prefs.getString('skPassword') ?? settings.skPassword;
    settings.keepAwake = prefs.getBool('keepAwake') ?? settings.keepAwake;
    settings.brightnessMode =
        prefs.getString('brightnessMode') ??
        (kIsWeb ? 'dia' : settings.brightnessMode);
    settings.historySource =
        prefs.getString('historySource') ?? settings.historySource;
    settings.influxHost = prefs.getString('influxHost') ?? settings.influxHost;
    settings.influxOrg = prefs.getString('influxOrg') ?? settings.influxOrg;
    settings.influxToken =
        prefs.getString('influxToken') ?? settings.influxToken;
    settings.influxBucket =
        prefs.getString('influxBucket') ?? settings.influxBucket;
    settings.influxArchiveBucket =
        prefs.getString('influxArchiveBucket') ?? settings.influxArchiveBucket;
    settings.demoMode = prefs.getBool('demoMode') ?? settings.demoMode;
    settings.usePhoneHeel =
        prefs.getBool('usePhoneHeel') ?? settings.usePhoneHeel;
    settings.phoneAttitudeCalibrated =
        prefs.getBool('phoneAttitudeCalibrated') ??
        settings.phoneAttitudeCalibrated;
    settings.phoneDownX = prefs.getDouble('phoneDownX') ?? settings.phoneDownX;
    settings.phoneDownY = prefs.getDouble('phoneDownY') ?? settings.phoneDownY;
    settings.phoneDownZ = prefs.getDouble('phoneDownZ') ?? settings.phoneDownZ;
    settings.phoneRightX =
        prefs.getDouble('phoneRightX') ?? settings.phoneRightX;
    settings.phoneRightY =
        prefs.getDouble('phoneRightY') ?? settings.phoneRightY;
    settings.phoneRightZ =
        prefs.getDouble('phoneRightZ') ?? settings.phoneRightZ;
    settings.phoneAttitudeInvertRoll =
        prefs.getBool('phoneAttitudeInvertRoll') ??
        settings.phoneAttitudeInvertRoll;
    settings.navLayoutMode =
        prefs.getString('navLayoutMode') ?? settings.navLayoutMode;
    if (settings.navLayoutMode != 'classic' &&
        settings.navLayoutMode != 'premium' &&
        settings.navLayoutMode != 'both') {
      settings.navLayoutMode = 'classic';
    }
    settings.navGridColumns =
        prefs.getInt('navGridColumns') ?? settings.navGridColumns;
    settings.aisCpaMaxNm =
        prefs.getDouble('aisCpaMaxNm') ?? settings.aisCpaMaxNm;
    settings.aisTcpaMaxMin =
        prefs.getDouble('aisTcpaMaxMin') ?? settings.aisTcpaMaxMin;
    settings.alarmCorrederaEnabled =
        prefs.getBool('alarmCorrederaEnabled') ??
        settings.alarmCorrederaEnabled;
    settings.alarmCorrederaSound =
        prefs.getBool('alarmCorrederaSound') ?? settings.alarmCorrederaSound;
    settings.alarmAisEnabled =
        prefs.getBool('alarmAisEnabled') ?? settings.alarmAisEnabled;
    settings.alarmAisSound =
        prefs.getBool('alarmAisSound') ?? settings.alarmAisSound;
    settings.alarmAisCpaNm =
        prefs.getDouble('alarmAisCpaNm') ?? settings.alarmAisCpaNm;
    settings.alarmAisTcpaMin =
        prefs.getDouble('alarmAisTcpaMin') ?? settings.alarmAisTcpaMin;
    settings.alarmsUseSkZones =
        prefs.getBool('alarmsUseSkZones') ?? settings.alarmsUseSkZones;
    final skZoneJson = prefs.getString('skZoneAlarmsJson');
    if (skZoneJson != null) {
      try {
        final map = jsonDecode(skZoneJson) as Map<String, dynamic>;
        settings.skZoneAlarms = map.map(
          (k, v) => MapEntry(
            k,
            SkZoneAlarmSetting.fromJson(v as Map<String, dynamic>),
          ),
        );
      } catch (_) {
        /* keep defaults if corrupted */
      }
    }
    final customAlarmsJson = prefs.getString('customAlarmsJson');
    if (customAlarmsJson != null) {
      try {
        final list = jsonDecode(customAlarmsJson) as List;
        settings.customAlarms = list
            .map((e) => CustomAlarmRule.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        /* keep defaults if corrupted */
      }
    }
    final navJson = prefs.getString('navCardIdsJson');
    if (navJson != null) {
      try {
        final ids = (jsonDecode(navJson) as List).whereType<String>().toList();
        settings.navCardIds = _validNavSelection(ids);
      } catch (_) {
        /* keep defaults if corrupted */
      }
    }
    final sensorJson = prefs.getString('sensorConfigJson');
    if (sensorJson != null) {
      try {
        settings.sensorConfig = SensorConfig.fromJson(
          jsonDecode(sensorJson) as Map<String, dynamic>,
        );
      } catch (_) {
        /* keep defaults if corrupted */
      }
    }
    _migrateLegacyTempAlarmTargets();
    _applyWakelock();
    _applyPhoneHeelSetting();
    unawaited(_refreshPressureTrendFromInflux());
  }

  // Pre-1.4.15 'tempAbove' alarms stored a fixed key ('fridge1', 'battery'...)
  // instead of a real Signal K path — resolve those against the current
  // sensor config now that it's loaded, so the alarm keeps working under
  // the new (any-discovered-sensor) targeting scheme.
  void _migrateLegacyTempAlarmTargets() {
    final c = settings.sensorConfig;
    for (final rule in settings.customAlarms) {
      if (rule.type != 'tempAbove' || rule.target == null) continue;
      final resolved = switch (rule.target) {
        'fridge1' => c.fridge1Path ?? 'environment.fridge_1.temperature',
        'fridge2' => c.fridge2Path ?? 'environment.fridge_2.temperature',
        'battery' => 'electrical.batteries.${c.batteryHouseId}.temperature',
        'cpu' => 'environment.rpi.cpu.temperature',
        'bowthruster' => 'electrical.batteries.bowthruster.temperature',
        _ => rule.target!, // already a real path
      };
      rule.target = resolved;
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('host', settings.host);
    await prefs.setInt('port', settings.port);
    await prefs.setString('auth', settings.authBase64);
    await prefs.setString('skUsername', settings.skUsername);
    await prefs.setString('skPassword', settings.skPassword);
    await prefs.setBool('keepAwake', settings.keepAwake);
    await prefs.setString('brightnessMode', settings.brightnessMode);
    await prefs.setString('historySource', settings.historySource);
    await prefs.setString('influxHost', settings.influxHost);
    await prefs.setString('influxOrg', settings.influxOrg);
    await prefs.setString('influxToken', settings.influxToken);
    await prefs.setString('influxBucket', settings.influxBucket);
    await prefs.setString('influxArchiveBucket', settings.influxArchiveBucket);
    await prefs.setString(
      'sensorConfigJson',
      jsonEncode(settings.sensorConfig.toJson()),
    );
    await prefs.setString('navCardIdsJson', jsonEncode(settings.navCardIds));
    await prefs.setString('navLayoutMode', settings.navLayoutMode);
    await prefs.setInt('navGridColumns', settings.navGridColumns);
    await prefs.setDouble('aisCpaMaxNm', settings.aisCpaMaxNm);
    await prefs.setDouble('aisTcpaMaxMin', settings.aisTcpaMaxMin);
    await prefs.setBool(
      'alarmCorrederaEnabled',
      settings.alarmCorrederaEnabled,
    );
    await prefs.setBool('alarmCorrederaSound', settings.alarmCorrederaSound);
    await prefs.setBool('alarmAisEnabled', settings.alarmAisEnabled);
    await prefs.setBool('alarmAisSound', settings.alarmAisSound);
    await prefs.setDouble('alarmAisCpaNm', settings.alarmAisCpaNm);
    await prefs.setDouble('alarmAisTcpaMin', settings.alarmAisTcpaMin);
    await prefs.setBool('alarmsUseSkZones', settings.alarmsUseSkZones);
    await prefs.setString(
      'skZoneAlarmsJson',
      jsonEncode(settings.skZoneAlarms.map((k, v) => MapEntry(k, v.toJson()))),
    );
    await prefs.setString(
      'customAlarmsJson',
      jsonEncode(settings.customAlarms.map((r) => r.toJson()).toList()),
    );
    await prefs.setBool('demoMode', settings.demoMode);
    await prefs.setBool('usePhoneHeel', settings.usePhoneHeel);
    await prefs.setBool(
      'phoneAttitudeCalibrated',
      settings.phoneAttitudeCalibrated,
    );
    await prefs.setDouble('phoneDownX', settings.phoneDownX);
    await prefs.setDouble('phoneDownY', settings.phoneDownY);
    await prefs.setDouble('phoneDownZ', settings.phoneDownZ);
    await prefs.setDouble('phoneRightX', settings.phoneRightX);
    await prefs.setDouble('phoneRightY', settings.phoneRightY);
    await prefs.setDouble('phoneRightZ', settings.phoneRightZ);
    await prefs.setBool(
      'phoneAttitudeInvertRoll',
      settings.phoneAttitudeInvertRoll,
    );
    _applyWakelock();
    _applyPhoneHeelSetting();
  }

  void _applyWakelock() {
    if (settings.keepAwake) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  // ─── Phone accelerometer as an alternative heel source ────────────────────
  void _applyPhoneHeelSetting() {
    if (kIsWeb) return; // no reliable accelerometer stream on web
    if (!settings.usePhoneHeel) {
      _phoneHeelTracker?.stop();
      return;
    }
    final tracker = _phoneHeelTracker ??= PhoneHeelTracker(
      onUpdate: (deg) {
        if (mounted) {
          setState(
            () =>
                signalK.heelDeg = settings.phoneAttitudeInvertRoll ? -deg : deg,
          );
        }
      },
      onPitchUpdate: (deg) {
        if (mounted) setState(() => signalK.pitchDeg = deg);
      },
    );
    tracker
      ..calibration = settings.phoneCalibration
      ..start();
  }

  void _startAttitudeCalibration(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AttitudeCalibrationWizard(
        getBoatHeadingDeg: () => _fresh(signalK.headingTrueDeg),
        onDone: (calibration, _) {
          settings.savePhoneCalibration(calibration);
          unawaited(_saveSettings());
          _applyPhoneHeelSetting();
          if (mounted) setState(() {});
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Calibración guardada')));
        },
      ),
    );
  }

  Map<String, void Function(dynamic)> _dynamicHandlers = {};

  void _buildDynamicHandlers() {
    final c = settings.sensorConfig;
    final h = <String, void Function(dynamic)>{};
    h['electrical.batteries.${c.batteryHouseId}.voltage'] = (v) =>
        signalK.houseV = _num(v);
    h['electrical.batteries.${c.batteryHouseId}.current'] = (v) =>
        signalK.houseA = _num(v);
    h['electrical.batteries.${c.batteryHouseId}.capacity.stateOfCharge'] = (v) {
      final n = _num(v);
      signalK.houseSoc = n == null ? null : n * 100;
    };
    h['electrical.batteries.${c.batteryHouseId}.temperature'] = (v) =>
        signalK.houseTempK = _num(v);
    h['electrical.batteries.${c.batteryStartId}.voltage'] = (v) =>
        signalK.startV = _num(v);
    if (c.solarPath != null && c.solarPath!.isNotEmpty) {
      h[c.solarPath!] = (v) => signalK.solarW = _num(v);
    }
    if (c.fridge1Path != null && c.fridge1Path!.isNotEmpty) {
      h[c.fridge1Path!] = (v) => signalK.fridge1TempK = _num(v);
    }
    if (c.fridge2Path != null && c.fridge2Path!.isNotEmpty) {
      h[c.fridge2Path!] = (v) => signalK.fridge2TempK = _num(v);
    }
    if (c.depthPath != null && c.depthPath!.isNotEmpty) {
      h[c.depthPath!] = (v) {
        final n = _num(v);
        signalK.depthM = n;
        _depthTrend.add(n);
      };
    }
    if (c.enginePath != null && c.enginePath!.isNotEmpty) {
      h[c.enginePath!] = (v) {
        final n = _num(v);
        final hours = n == null ? null : n / 3600.0;
        // propulsion.*.runTime is a lifetime counter, not an "is it on"
        // flag — the engine reads as running for a short grace window
        // after each observed increase, and as stopped once those
        // increases stop arriving (see _engineRunning).
        final prev = signalK.engineHours;
        if (prev != null && hours != null && hours > prev) {
          _engineRunningUntil = DateTime.now().add(const Duration(seconds: 20));
        }
        signalK.engineHours = hours;
      };
    }
    for (final t in c.tanks.where((t) => t.enabled)) {
      h[t.skPath] = (v) => signalK.tanks[t.tankKey] = _pct(v);
    }
    _dynamicHandlers = h;
  }

  // The vessel's own name isn't published as a delta over the websocket
  // stream — it's static metadata, fetched once over REST instead.
  Future<void> _fetchVesselName() async {
    try {
      final uri = Uri.parse(
        'http://${settings.host}:${settings.port}/signalk/v1/api/vessels/self/name',
      );
      final response = await http
          .get(
            uri,
            headers: settings.authBase64.isEmpty
                ? {}
                : {'Authorization': 'Basic ${settings.authBase64}'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;
      final name = jsonDecode(response.body);
      if (name is String && name.isNotEmpty && mounted) {
        setState(() => signalK.vesselName = name);
      }
    } catch (_) {
      // Not critical — callers fall back to a generic label.
    }
  }

  void _connectSignalK() {
    // Several call sites (reconnect button, sensor config save, boot)
    // used to call this unconditionally — if DEMO mode was on, that opened
    // a real websocket alongside the demo timer, so both real and
    // simulated data landed on the same model at once and flickered.
    // Guarding here once covers all of them instead of patching each.
    if (settings.demoMode) return;
    channel?.sink.close();
    signalK.tanks.clear();
    _buildDynamicHandlers();
    final uri = Uri.parse(
      'ws://${settings.host}:${settings.port}/signalk/v1/stream?subscribe=none',
    );
    setState(() => signalK.status = 'Conectando…');
    try {
      channel = connectSignalKWs(uri, authBase64: settings.authBase64);
      channel!.stream.listen(
        _onSignalKMessage,
        onError: _onSignalKError,
        onDone: _onSignalKDone,
      );
      _sendSignalKSubscription();
      // A fresh connection always starts unsubscribed from AIS — re-derive
      // whether it should be (AIS page open, or a CPA/TCPA NAV card is
      // selected) rather than trusting the pre-reconnect _aisSubscribed flag.
      _aisSubscribed = false;
      _syncAisSubscription();
      setState(() {
        signalK.connected = true;
        signalK.status = 'Signal K';
      });
    } catch (error) {
      _onSignalKError(error);
    }
  }

  void _sendSignalKSubscription() {
    final paths = [
      'navigation.position',
      'navigation.speedOverGround',
      'navigation.speedThroughWater',
      'navigation.headingTrue',
      'navigation.courseOverGroundTrue',
      'navigation.attitude',
      'navigation.attitude.roll',
      'navigation.gnss.satellites',
      'navigation.gnss.horizontalDilution',
      'navigation.gnss.antennaAltitude',
      'navigation.gnss.type',
      'navigation.gnss.methodQuality',
      'navigation.course.calcValues.velocityMadeGood',
      'environment.wind.speedApparent',
      'environment.wind.angleApparent',
      'environment.wind.angleTrueWater',
      'environment.wind.angleTrueGround',
      'environment.wind.directionTrue',
      'environment.wind.speedTrue',
      'environment.water.temperature',
      'environment.outside.temperature',
      'environment.outside.humidity',
      'environment.outside.pressure',
      'environment.interior.temperature',
      'environment.interior.humidity',
      'environment.rpi.cpu.temperature',
      'electrical.batteries.bowthruster.voltage',
      'electrical.batteries.bowthruster.temperature',
      'electrical.venus.dcPower',
      'navigation.anchor.state',
      'navigation.anchor.currentRadius',
      'navigation.anchor.maxRadius',
      'navigation.anchor.apparentBearing',
      'notifications.*',
      ..._dynamicHandlers.keys,
      for (final rule in settings.customAlarms)
        if (rule.type == 'tempAbove' && rule.target != null) rule.target!,
    ];
    channel?.sink.add(
      jsonEncode({
        'context': 'vessels.self',
        'subscribe': [
          for (final path in paths) {'path': path, 'policy': 'instant'},
        ],
      }),
    );
  }

  void _onSignalKMessage(dynamic raw) {
    final doc = jsonDecode(raw as String) as Map<String, dynamic>;
    final selfHello = doc['self'];
    if (selfHello is String && selfHello.isNotEmpty) {
      _selfContext = selfHello.startsWith('vessels.')
          ? selfHello
          : 'vessels.$selfHello';
    }
    final updates = doc['updates'];
    if (updates is! List) return;
    final context = doc['context'] as String?;
    final isSelf =
        context == null || context == 'vessels.self' || context == _selfContext;
    var changed = false;
    var aisChanged = false;
    for (final update in updates) {
      final values = update is Map ? update['values'] : null;
      if (values is! List) continue;
      // Use the delta's own timestamp (when the source actually produced
      // this value), not receive time — a Signal K server commonly replays
      // its last *retained* value on every (re)subscribe, and treating that
      // replay as "now" made staleness detection cycle: "--" would flip
      // back to a frozen old number each time the WebSocket reconnected.
      final rawTs = update is Map ? update['timestamp'] : null;
      final dataTime = rawTs is String ? DateTime.tryParse(rawTs) : null;
      for (final item in values) {
        if (item is! Map) continue;
        final path = item['path'] as String? ?? '';
        if (isSelf) {
          changed = _routeValue(path, item['value'], dataTime) || changed;
        } else if (_aisSubscribed) {
          _routeAisValue(context, path, item['value']);
          aisChanged = true;
        }
      }
    }
    if ((changed || aisChanged) && mounted) {
      setState(() {
        if (changed) {
          signalK.connected = true;
          signalK.status = 'Signal K';
          signalK.lastUpdate = DateTime.now();
        }
      });
    }
    if (changed) unawaited(_syncAlarmSound());
  }

  void _routeAisValue(String context, String path, dynamic value) {
    final t = _aisTargets.putIfAbsent(context, () => AisTarget(context));
    t.lastUpdate = DateTime.now();
    final n = _num(value);
    switch (path) {
      case 'navigation.position':
        if (value is Map) {
          t.lat = _num(value['latitude']);
          t.lon = _num(value['longitude']);
          t.recordTrackPoint();
        }
      case 'navigation.courseOverGroundTrue':
        t.cogDeg = n == null ? null : n * 57.2957795;
      case 'navigation.speedOverGround':
        t.sogKn = n == null ? null : n * 1.94384;
      case 'mmsi':
        t.mmsi = value?.toString();
      case 'name':
        t.name = value?.toString();
      case 'design.aisShipType':
        if (value is Map) t.shipTypeId = (value['id'] as num?)?.toInt();
      // Published by a Signal K collision-alert plugin (SI units: meters, seconds, radians)
      // when installed — see [[project_rewind_android]] for the on-boat plugin discovery notes.
      case 'navigation.closestApproach.distance':
        t.pluginCpaNm = n == null ? null : n / 1852.0;
      case 'navigation.closestApproach.timeTo':
        t.pluginTcpaMin = n == null ? null : n / 60.0;
      case 'navigation.closestApproach.bearing':
        t.pluginCpaBearingDeg = n == null ? null : n * 57.2957795;
    }
  }

  void _sendAisSubscription() {
    channel?.sink.add(
      jsonEncode({
        'context': 'vessels.*',
        'subscribe': [
          for (final p in const [
            'navigation.position',
            'navigation.courseOverGroundTrue',
            'navigation.speedOverGround',
            'mmsi',
            'name',
            'design.aisShipType',
            'navigation.closestApproach.distance',
            'navigation.closestApproach.timeTo',
            'navigation.closestApproach.bearing',
          ])
            {'path': p, 'policy': 'instant'},
        ],
      }),
    );
  }

  // Whether the AIS page is open, or the merged AIS NAV card needs live AIS
  // targets to compute "closest approach" — either one keeps the (otherwise
  // on-demand, to save bandwidth) vessels.* subscription alive.
  // Premium's Vela screen always shows the AIS card too, regardless of
  // what's in the classic grid's own selection — without this, Premium
  // users (who often have no reason to also select AIS in the classic
  // picker) never got live AIS data, so the card always read "Sin AIS"
  // even with real traffic and a closest-approach target.
  bool get _navWantsAis =>
      settings.navCardIds.contains('ais') ||
      settings.navLayoutMode == 'premium' ||
      settings.navLayoutMode == 'both';

  void _syncAisSubscription() {
    final ids = _pageIds;
    final onAisPage = page < ids.length && ids[page] == 'AIS';
    if (onAisPage || _navWantsAis) {
      _subscribeAis();
    } else {
      _unsubscribeAis();
    }
  }

  void _subscribeAis() {
    if (_aisSubscribed) return;
    _aisSubscribed = true;
    _sendAisSubscription();
  }

  void _unsubscribeAis() {
    if (!_aisSubscribed) return;
    _aisSubscribed = false;
    channel?.sink.add(
      jsonEncode({
        'context': 'vessels.*',
        'unsubscribe': [
          {'path': '*'},
        ],
      }),
    );
    // Keep _aisTargets (and their 1h tracks) in memory so re-entering AIS
    // doesn't lose the trails — stale targets just show orange until fresh data returns.
  }

  bool _routeValue(String path, dynamic value, DateTime? dataTime) {
    if (path.endsWith('.temperature')) {
      _customTempValues[path] = _num(value);
    }
    final dynamicHandler = _dynamicHandlers[path];
    if (dynamicHandler != null) {
      dynamicHandler(value);
      return true;
    }
    if (path.startsWith('notifications.')) {
      _routeNotification(path.substring('notifications.'.length), value);
      return true;
    }
    final n = _num(value);
    final ts = dataTime ?? DateTime.now();
    if (path.startsWith('environment.wind.')) {
      signalK.windUpdate = ts;
    } else if (path.startsWith('navigation.') ||
        path == settings.sensorConfig.depthPath) {
      signalK.navUpdate = ts;
    }
    switch (path) {
      case 'navigation.position':
        if (value is Map) {
          final hadNoPos =
              signalK.latitude == null || signalK.longitude == null;
          final newLat = _num(value['latitude']);
          final newLon = _num(value['longitude']);
          signalK.latitude = newLat;
          signalK.longitude = newLon;
          if (hadNoPos &&
              newLat != null &&
              newLon != null &&
              weather.updated == null) {
            unawaited(_loadWeather(force: true));
          }
          return true;
        }
      case 'navigation.speedOverGround':
        signalK.sogKn = n == null ? null : n * 1.94384;
      case 'navigation.speedThroughWater':
        signalK.stwKn = n == null ? null : n * 1.94384;
      case 'navigation.headingTrue':
        signalK.headingTrueDeg = n == null ? null : n * 57.2957795;
      case 'navigation.courseOverGroundTrue':
        signalK.cogTrueDeg = n == null ? null : n * 57.2957795;
      case 'navigation.gnss.satellites':
        signalK.gnssSatellites = n?.round();
      case 'navigation.gnss.horizontalDilution':
        signalK.gnssHdop = n;
      case 'navigation.gnss.antennaAltitude':
        signalK.gnssAntennaAltitudeM = n;
      case 'navigation.gnss.type':
        signalK.gnssFixType = value?.toString();
      case 'navigation.gnss.methodQuality':
        signalK.gnssMethodQuality = value?.toString();
      case 'navigation.course.calcValues.velocityMadeGood':
        signalK.courseVmgKn = n == null ? null : n * 1.94384;
        signalK.courseUpdate = ts;
        return true;
      case 'navigation.attitude':
        if (settings.usePhoneHeel) return true;
        if (value is Map) {
          final roll = _num(value['roll']);
          if (roll != null) signalK.heelDeg = roll * 57.2957795;
          final pitch = _num(value['pitch']);
          if (pitch != null) signalK.pitchDeg = pitch * 57.2957795;
          return true;
        }
      case 'navigation.attitude.roll':
        if (settings.usePhoneHeel) return true;
        signalK.heelDeg = n == null ? null : n * 57.2957795;
      case 'navigation.attitude.pitch':
        if (settings.usePhoneHeel) return true;
        signalK.pitchDeg = n == null ? null : n * 57.2957795;
      case 'navigation.anchor.state':
        signalK.anchorState = value?.toString();
      case 'navigation.anchor.currentRadius':
        signalK.anchorCurrentRadiusM = n;
      case 'navigation.anchor.maxRadius':
        signalK.anchorMaxRadiusM = n;
      case 'navigation.anchor.apparentBearing':
        signalK.anchorApparentBearingDeg = n == null ? null : n * 57.2957795;
      case 'environment.wind.speedApparent':
        signalK.awsKn = n == null ? null : n * 1.94384;
        _dAws = _awsDamp.linear(signalK.awsKn);
        _awsHistory.add(signalK.awsKn);
      case 'environment.wind.angleApparent':
        signalK.awaDeg = n == null ? null : n * 57.2957795;
        _dAwa = _awaDamp.angle(signalK.awaDeg);
      case 'environment.wind.angleTrueWater':
      case 'environment.wind.angleTrueGround':
        signalK.twaDeg = n == null ? null : n * 57.2957795;
        _dTwa = _twaDamp.angle(signalK.twaDeg);
      case 'environment.wind.directionTrue':
        signalK.twdDeg = n == null ? null : n * 57.2957795;
        _dTwd = _twdDamp.angle(signalK.twdDeg);
      case 'environment.wind.speedTrue':
        signalK.twsKn = n == null ? null : n * 1.94384;
        _dTws = _twsDamp.linear(signalK.twsKn);
        _twsHistory.add(signalK.twsKn);
      case 'environment.water.temperature':
        signalK.waterTempK = n;
      case 'environment.outside.temperature':
        signalK.outsideTempK = n;
      case 'environment.outside.humidity':
        signalK.outsideHumidity = n == null ? null : n * 100;
      case 'environment.outside.pressure':
        signalK.outsidePressureHpa = n;
        _pressureHistory.add(signalK.outsidePressureHpa);
      case 'environment.interior.temperature':
        signalK.indoorTempK = n;
      case 'environment.interior.humidity':
        signalK.indoorHumidity = n == null ? null : n * 100;
      case 'environment.rpi.cpu.temperature':
        signalK.cpuTempK = n;
      case 'electrical.batteries.bowthruster.voltage':
        signalK.bowthrusterV = n;
      case 'electrical.batteries.bowthruster.temperature':
        signalK.bowthrusterTempK = n;
      case 'electrical.venus.dcPower':
        signalK.dcW = n;
      default:
        return false;
    }
    return true;
  }

  void _onSignalKError(Object error) {
    if (!mounted) return;
    setState(() {
      signalK.connected = false;
      signalK.status = 'SK espera';
    });
    _scheduleReconnect();
  }

  void _onSignalKDone() {
    if (!mounted) return;
    setState(() {
      signalK.connected = false;
      signalK.status = 'SK desconectado';
    });
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    reconnectTimer?.cancel();
    reconnectTimer = Timer(const Duration(seconds: 5), _connectSignalK);
  }

  // ─── DEMO mode: synthetic data with plausible oscillation, no server needed ──
  void setDemoMode(bool enabled) {
    settings.demoMode = enabled;
    unawaited(_saveSettings());
    if (enabled) {
      _startDemoMode();
    } else {
      _stopDemoMode();
      _connectSignalK();
    }
  }

  void _startDemoMode() {
    reconnectTimer?.cancel();
    channel?.sink.close();
    setState(() {
      signalK.connected = true;
      signalK.status = 'DEMO';
    });
    _demoTimer?.cancel();
    _tickDemo();
    _demoTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickDemo());
  }

  void _stopDemoMode() {
    _demoTimer?.cancel();
    _demoTimer = null;
    _aisTargets.clear();
  }

  void _tickDemo() {
    if (!mounted) return;
    final t =
        DateTime.now().difference(_demoClockStart).inMilliseconds / 1000.0;
    final rnd = math.Random();
    double osc(double periodS, double amp, double phase) =>
        amp * math.sin(2 * math.pi * t / periodS + phase);
    double jitter(double amp) => (rnd.nextDouble() - 0.5) * amp;

    setState(() {
      signalK.connected = true;
      signalK.status = 'DEMO';
      signalK.lastUpdate = DateTime.now();
      signalK.navUpdate = DateTime.now();
      signalK.windUpdate = DateTime.now();

      // Position: slow loop around the Aegean (demo cruising ground)
      final hadNoPos = signalK.latitude == null;
      signalK.latitude = 37.75 + 0.012 * math.sin(t / 900) + jitter(0.0002);
      signalK.longitude = 26.98 + 0.012 * math.cos(t / 900) + jitter(0.0002);
      if (hadNoPos) unawaited(_loadWeather(force: true));

      // Navigation
      signalK.headingTrueDeg = normalize360(120 + osc(600, 25, 0));
      signalK.cogTrueDeg = signalK.headingTrueDeg;
      signalK.sogKn = (6.2 + osc(180, 1.4, 0.5) + jitter(0.2)).clamp(0, 11);
      signalK.stwKn = signalK.sogKn == null
          ? null
          : (signalK.sogKn! - 0.2 + jitter(0.1)).clamp(0, 11);
      signalK.heelDeg = osc(31, 9, 1.1) + jitter(0.4);
      signalK.depthM = (14 + osc(70, 6, 2) + jitter(0.3)).clamp(2, 60);
      _depthTrend.add(signalK.depthM);

      // Wind
      signalK.awsKn = (13 + osc(40, 3.5, 0) + jitter(0.4)).clamp(0, 30);
      signalK.awaDeg = normalize360(40 + osc(53, 18, 1));
      signalK.twsKn = (11 + osc(65, 3, 0.8) + jitter(0.3)).clamp(0, 28);
      signalK.twaDeg = normalize360(55 + osc(70, 20, 0.3));
      signalK.twdDeg = normalize360(signalK.headingTrueDeg! + signalK.twaDeg!);
      _dAws = signalK.awsKn;
      _dAwa = normalizeRelativeAngle(signalK.awaDeg!);
      _dTws = signalK.twsKn;
      _dTwa = normalizeRelativeAngle(signalK.twaDeg!);
      _dTwd = signalK.twdDeg;

      // Environment
      signalK.waterTempK = 296.5 + osc(4000, 0.8, 0);
      signalK.outsideTempK = 298 + osc(3600, 3, 1);
      signalK.outsideHumidity = (55 + osc(1800, 12, 0)).clamp(20, 95);
      signalK.outsidePressureHpa = 1015 + osc(2400, 4, 0.5);
      _pressureHistory.add(signalK.outsidePressureHpa);
      signalK.indoorTempK = 300 + osc(3600, 1.2, 0.6);
      signalK.indoorHumidity = (50 + osc(1800, 8, 1)).clamp(20, 90);
      signalK.cpuTempK = 318 + osc(300, 3, 0) + jitter(0.3);
      signalK.fridge1TempK = 277 + osc(600, 1.2, 0);
      signalK.fridge2TempK = 279 + osc(600, 1, 1.4);

      // Power
      signalK.houseSoc = (76 + osc(2600, 16, 0)).clamp(20, 100);
      signalK.houseV = 12.5 + osc(300, 0.35, 0) + jitter(0.02);
      signalK.houseA = osc(90, 9, 0) + jitter(0.5);
      signalK.houseTempK = 300 + osc(1000, 2, 0);
      signalK.solarW = (350 + osc(600, 320, 0)).clamp(0, 900);
      signalK.dcW = 55 + osc(150, 18, 0.7);
      signalK.startV = 12.8 + osc(500, 0.15, 0);
      signalK.bowthrusterV = 12.7 + jitter(0.05);
      signalK.bowthrusterTempK = 297 + jitter(0.2);

      // Tanks: slowly draining, wraps back up (simulating a re-fill) for a believable demo
      for (final slot in settings.sensorConfig.tanks.where((s) => s.enabled)) {
        final drainSpeed =
            0.6 +
            (slot.skPath.hashCode % 5) * 0.15; // %/min-ish, varies per tank
        final pct = 95 - ((t * drainSpeed / 20) % 90);
        signalK.tanks[slot.tankKey] = pct.clamp(5, 100);
      }

      _tickDemoAis(t);
    });
    unawaited(_syncAlarmSound());
  }

  void _tickDemoAis(double t) {
    const demoBoats = [
      (
        mmsi: '211000001',
        name: 'DEMO CARGO 1',
        type: 70,
        bearing0: 30.0,
        speed: 9.0,
        distNm0: 3.0,
      ),
      (
        mmsi: '211000002',
        name: 'DEMO SAIL 2',
        type: 36,
        bearing0: 200.0,
        speed: 5.5,
        distNm0: 1.6,
      ),
      (
        mmsi: '211000003',
        name: 'DEMO TANKER 3',
        type: 80,
        bearing0: 100.0,
        speed: 11.0,
        distNm0: 4.5,
      ),
    ];
    final ownLat = signalK.latitude, ownLon = signalK.longitude;
    if (ownLat == null || ownLon == null) return;
    for (final b in demoBoats) {
      final target = _aisTargets.putIfAbsent(
        'vessels.demo.${b.mmsi}',
        () => AisTarget('vessels.demo.${b.mmsi}'),
      );
      target.mmsi = b.mmsi;
      target.name = b.name;
      target.shipTypeId = b.type;
      target.lastUpdate = DateTime.now();
      final cogDeg = normalize360(b.bearing0 + 180 + 15 * math.sin(t / 400));
      target.cogDeg = cogDeg;
      target.sogKn = b.speed;
      final travelledNm = b.speed * (t / 3600);
      final brgRad = b.bearing0 * math.pi / 180;
      final cogRad = cogDeg * math.pi / 180;
      final startLat = ownLat + (b.distNm0 / 60) * math.cos(brgRad);
      final startLon =
          ownLon +
          (b.distNm0 / 60) *
              math.sin(brgRad) /
              math.cos(ownLat * math.pi / 180);
      target.lat = startLat + (travelledNm / 60) * math.cos(cogRad);
      target.lon =
          startLon +
          (travelledNm / 60) *
              math.sin(cogRad) /
              math.cos(ownLat * math.pi / 180);
      target.recordTrackPoint();
    }
  }

  Future<SkDiscovery?> discoverSkPaths() async {
    try {
      final uri = Uri.parse(
        'http://${settings.host}:${settings.port}/signalk/v1/api/vessels/self',
      );
      final response = await http
          .get(
            uri,
            headers: settings.authBase64.isEmpty
                ? {}
                : {'Authorization': 'Basic ${settings.authBase64}'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final root = jsonDecode(response.body);
      final leaves = <String, dynamic>{};
      void walk(dynamic node, String prefix) {
        if (node is! Map) return;
        if (node.containsKey('value')) {
          leaves[prefix] = node;
          return;
        }
        for (final entry in node.entries) {
          if (entry.key is! String) continue;
          final key = entry.key as String;
          if (key.startsWith(r'$') ||
              key == 'meta' ||
              key == 'timestamp' ||
              key == 'source' ||
              key == 'sentence' ||
              key == 'pgn' ||
              // Alarms/messages, never a data source we'd map a sensor to —
              // pure noise in the discovery list.
              (prefix.isEmpty && key == 'notifications')) {
            continue;
          }
          walk(entry.value, prefix.isEmpty ? key : '$prefix.$key');
        }
      }

      walk(root, '');

      final result = SkDiscovery();
      final batteryIds = <String>{};
      final tankMap = <String, TankCandidate>{};
      for (final path in leaves.keys) {
        final battMatch = RegExp(r'^electrical\.batteries\.([^.]+)\.')
            .firstMatch(path);
        if (battMatch != null) batteryIds.add(battMatch.group(1)!);
        final lowerPath = path.toLowerCase();
        if (lowerPath.contains('solar') || lowerPath.contains('panel')) {
          result.solarPaths.add(path);
        }
        if (lowerPath.contains('depth')) {
          final node = leaves[path];
          final depthVal = node is Map ? _num(node['value']) : null;
          // Discovered depth-shaped paths are only offered as choices when
          // they carry a real positive reading — a stale/disconnected
          // transducer often reports exactly 0 (or is absent), which would
          // otherwise show up as a plausible-looking but useless option.
          if (depthVal != null && depthVal > 0) result.depthPaths.add(path);
        }
        final fridgeMatch = RegExp(
          r'^environment\.(\w*fridge\w*)\.temperature$',
          caseSensitive: false,
        ).firstMatch(path);
        if (fridgeMatch != null) result.fridgePaths.add(path);
        // Standard Signal K engine hours: propulsion.<id>.runTime, seconds.
        if (RegExp(r'^propulsion\.[^.]+\.runTime$').hasMatch(path)) {
          result.enginePaths.add(path);
        }
        final tankMatch = RegExp(r'^tanks\.([^.]+)\.([^.]+)\.currentLevel$')
            .firstMatch(path);
        if (tankMatch != null) {
          final type = tankMatch.group(1)!;
          final id = tankMatch.group(2)!;
          final capNode = leaves['tanks.$type.$id.capacity'];
          final capM3 = capNode is Map ? _num(capNode['value']) : null;
          tankMap['$type.$id'] = TankCandidate(
            type: type,
            id: id,
            capacityL: capM3 == null ? null : (capM3 * 1000).round(),
          );
        }
        if (path == 'environment.outside.temperature') {
          result.hasOutsideTemp = true;
        }
        if (path == 'environment.outside.pressure') {
          result.hasOutsidePressure = true;
        }
      }
      result.batteryIds.addAll(batteryIds);
      result.tanks.addAll(tankMap.values);
      result.allPaths.addAll(leaves.keys.toList()..sort());
      return result;
    } catch (_) {
      return null;
    }
  }

  // Fetches and shows every leaf value Signal K publishes under a given dot
  // path (e.g. "tanks.freshWater.0") — for a tank, that's whatever the
  // server actually has (name, capacity, voltage, currentLevel...) beyond
  // the single value Diagnóstico normally shows, so a raw-vs-app-shown
  // mismatch (like an odd currentLevel) can be checked directly.
  Future<void> _showRawSkNode(BuildContext context, String path) async {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(path, style: const TextStyle(color: cText, fontSize: 15)),
        content: SizedBox(
          width: 340,
          child: FutureBuilder<Map<String, dynamic>>(
            future: _fetchRawSkNode(path),
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 80,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final leaves = snap.data;
              if (snap.hasError || leaves == null || leaves.isEmpty) {
                return const Text(
                  'Sin datos (o el servidor no responde) para este path.',
                  style: TextStyle(color: cMuted, fontSize: 13),
                );
              }
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in leaves.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 110,
                              child: Text(
                                entry.key,
                                style: const TextStyle(
                                  color: cMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${entry.value}',
                                style: const TextStyle(
                                  color: cText,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  // Only meaningful running as the Signal K webapp (kIsWeb + same origin):
  // a plain HTTP Basic Auth header (authBase64 above) authenticates OUR
  // OWN REST/WS calls, but Freeboard-SK/the anchor alarm plugin load as
  // independent same-origin page loads inside their <iframe>, so they only
  // see whatever session cookie the browser already holds for this origin
  // — which is exactly what a real Signal K login sets. This POST is a
  // normal fetch from the page itself, so the browser stores that cookie
  // automatically; nothing else needs to be done for the iframes to pick
  // it up on their own next load.
  Future<void> _loginToSignalK() async {
    if (settings.skUsername.isEmpty || settings.skPassword.isEmpty) return;
    try {
      final uri = Uri.parse(
        'http://${settings.host}:${settings.port}/signalk/v1/auth/login',
      );
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': settings.skUsername,
              'password': settings.skPassword,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (mounted) {
        setState(() => _skLoginOk = response.statusCode == 200);
      }
    } catch (_) {
      if (mounted) setState(() => _skLoginOk = false);
    }
  }

  bool? _skLoginOk; // null = not attempted, true/false = last attempt result

  Future<Map<String, dynamic>> _fetchRawSkNode(String path) async {
    final uri = Uri.parse(
      'http://${settings.host}:${settings.port}/signalk/v1/api/vessels/self/${path.replaceAll('.', '/')}',
    );
    final response = await http
        .get(
          uri,
          headers: settings.authBase64.isEmpty
              ? {}
              : {'Authorization': 'Basic ${settings.authBase64}'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final root = jsonDecode(response.body);
    final leaves = <String, dynamic>{};
    void walk(dynamic node, String prefix) {
      if (node is Map && node.containsKey('value')) {
        leaves[prefix.isEmpty ? 'value' : prefix] = node['value'];
        return;
      }
      if (node is! Map) {
        if (prefix.isNotEmpty) leaves[prefix] = node;
        return;
      }
      for (final entry in node.entries) {
        if (entry.key is! String) continue;
        final key = entry.key as String;
        if (key.startsWith(r'$') ||
            key == 'meta' ||
            key == 'timestamp' ||
            key == 'source' ||
            key == 'sentence' ||
            key == 'pgn') {
          continue;
        }
        walk(entry.value, prefix.isEmpty ? key : '$prefix.$key');
      }
    }

    walk(root, '');
    return leaves;
  }

  Future<void> _loadWeatherCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('weatherCacheJson');
    if (raw == null) return;
    try {
      weather.loadFromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      /* ignore corrupted cache */
    }
  }

  Future<void> _saveWeatherCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('weatherCacheJson', jsonEncode(weather.toJson()));
  }

  Future<void> _refreshPressureTrendFromInflux() async {
    if (_loadingPressureTrend || settings.demoMode) {
      return;
    }
    _loadingPressureTrend = true;
    try {
      final points = await influxQuery(
        host: settings.effectiveInfluxHost,
        org: settings.influxOrg,
        token: settings.influxToken,
        def: mPressure,
        fluxRange: '-6h',
        aggEvery: '10m',
        bucket: settings.influxBucket,
      );
      if (!mounted) return;
      if (points.length >= 2) {
        setState(() {
          _pressureHistory.replaceWithGraphPoints(points);
          _pressureTrendFromInflux = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _pressureTrendFromInflux = false);
    } finally {
      _loadingPressureTrend = false;
    }
  }

  Future<void> _loadWeather({bool force = false}) async {
    if (loadingWeather) return;
    // Reuse the last successful fetch (possibly restored from disk on a fresh
    // app launch) if it's under 30 min old — avoids re-hitting Open-Meteo's
    // rate limit every time the app restarts.
    if (!force && weather.updated != null && weather.error == null) {
      final cacheFresh =
          DateTime.now().difference(weather.updated!).inMinutes < 30;
      final marineRangeOk = weather.marine.length >= _marineMaxHour.round();
      if (cacheFresh && marineRangeOk) return;
    }
    final lat = _weatherLat ?? (kIsWeb ? kDefaultWeatherLat : null);
    final lon = _weatherLon ?? (kIsWeb ? kDefaultWeatherLon : null);
    if (lat == null || lon == null) {
      if (mounted) setState(() => weather.error = 'Sin posición GPS');
      return;
    }
    loadingWeather = true;
    try {
      final forecastUri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': lat.toStringAsFixed(5),
        'longitude': lon.toStringAsFixed(5),
        'current': 'temperature_2m,apparent_temperature,precipitation_probability,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,relative_humidity_2m',
        'hourly': 'temperature_2m,precipitation_probability,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m',
        'timezone': 'GMT',
        'timeformat': 'unixtime',
        'wind_speed_unit': 'kn',
        'forecast_days': '8',
      });
      final marineUri = Uri.https('marine-api.open-meteo.com', '/v1/marine', {
        'latitude': lat.toStringAsFixed(5),
        'longitude': lon.toStringAsFixed(5),
        'current': 'wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_direction,swell_wave_period,sea_surface_temperature,ocean_current_velocity,ocean_current_direction',
        'hourly': 'wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_direction,swell_wave_period,sea_surface_temperature,ocean_current_velocity,ocean_current_direction',
        'timezone': 'GMT',
        'timeformat': 'unixtime',
        'forecast_hours': '72',
      });
      final forecastResponse = await http
          .get(forecastUri)
          .timeout(const Duration(seconds: 10));
      final marineResponse = await http
          .get(marineUri)
          .timeout(const Duration(seconds: 10));
      final place = await _reverseGeocode(lat, lon);
      final forecastDoc =
          jsonDecode(forecastResponse.body) as Map<String, dynamic>;
      final marineDoc = jsonDecode(marineResponse.body) as Map<String, dynamic>;
      // Check for API-level errors (e.g. daily limit, bad coords)
      final apiErr =
          (forecastDoc['error'] == true ? forecastDoc['reason'] : null) ??
          (marineDoc['error'] == true ? marineDoc['reason'] : null);
      if (apiErr != null) throw Exception(apiErr as String);
      if (!mounted) return;
      setState(() {
        weather.error = null;
        weather.place = place;
        weather.summary
          ..clear()
          ..addAll(_forecastSummary(forecastDoc));
        weather.hourly
          ..clear()
          ..addAll(_hourlyForecast(forecastDoc));
        weather.marine
          ..clear()
          ..addAll(_marine(marineDoc));
        weather.updated = DateTime.now();
      });
      unawaited(_saveWeatherCache());
    } catch (e) {
      if (mounted) {
        setState(() {
          weather.error = _weatherError(e);
          weather.updated ??= DateTime.now();
        });
      }
    } finally {
      loadingWeather = false;
    }
  }

  Future<
    ({
      Map<String, List<ModelForecastPoint>> models,
      List<GraphPoint> waveHeight,
    })
  >
  fetchModelComparison() async {
    final lat = _weatherLat ?? (kIsWeb ? kDefaultWeatherLat : null);
    final lon = _weatherLon ?? (kIsWeb ? kDefaultWeatherLon : null);
    if (lat == null || lon == null) throw Exception('Sin posición GPS');
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': lat.toStringAsFixed(5),
      'longitude': lon.toStringAsFixed(5),
      'hourly': 'wind_speed_10m,wind_gusts_10m,wind_direction_10m,pressure_msl,precipitation_probability,precipitation',
      'models': weatherModels.map((m) => m.id).join(','),
      'timezone': 'GMT',
      'timeformat': 'unixtime',
      'wind_speed_unit': 'kn',
      'forecast_days': '4',
    });
    final marineUri = Uri.https('marine-api.open-meteo.com', '/v1/marine', {
      'latitude': lat.toStringAsFixed(5),
      'longitude': lon.toStringAsFixed(5),
      'hourly': 'wave_height',
      'timezone': 'GMT',
      'timeformat': 'unixtime',
      'forecast_days': '4',
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    final marineResponse = await http
        .get(marineUri)
        .timeout(const Duration(seconds: 12));
    final doc = jsonDecode(response.body) as Map<String, dynamic>;
    if (doc['error'] == true) {
      throw Exception(doc['reason'] as String? ?? 'Error de la API');
    }
    final hourly = doc['hourly'] as Map<String, dynamic>?;
    if (hourly == null) throw Exception('Sin datos horarios');
    final times = (hourly['time'] as List).cast<num>();
    final out = <String, List<ModelForecastPoint>>{};
    for (final m in weatherModels) {
      final winds = hourly['wind_speed_10m_${m.id}'] as List?;
      final gusts = hourly['wind_gusts_10m_${m.id}'] as List?;
      final dirs = hourly['wind_direction_10m_${m.id}'] as List?;
      final pressures = hourly['pressure_msl_${m.id}'] as List?;
      final rain = hourly['precipitation_probability_${m.id}'] as List?;
      final rainMm = hourly['precipitation_${m.id}'] as List?;
      if (winds == null) continue; // model has no coverage for this location
      final pts = <ModelForecastPoint>[
        for (var i = 0; i < times.length; i++)
          ModelForecastPoint(
            time: DateTime.fromMillisecondsSinceEpoch(
              times[i].toInt() * 1000,
              isUtc: true,
            ),
            windKn: i < winds.length ? _num(winds[i]) : null,
            gustKn: gusts != null && i < gusts.length ? _num(gusts[i]) : null,
            windDirDeg: dirs != null && i < dirs.length ? _num(dirs[i]) : null,
            pressureHpa: pressures != null && i < pressures.length
                ? _num(pressures[i])
                : null,
            rainPct: rain != null && i < rain.length ? _num(rain[i]) : null,
            rainMm: rainMm != null && i < rainMm.length
                ? _num(rainMm[i])
                : null,
          ),
      ];
      out[m.id] = pts;
    }
    if (out.isEmpty) throw Exception('Ningún modelo disponible para esta zona');

    final waveHeight = <GraphPoint>[];
    try {
      final marineDoc = jsonDecode(marineResponse.body) as Map<String, dynamic>;
      final marineHourly = marineDoc['hourly'] as Map<String, dynamic>?;
      final waveTimes = (marineHourly?['time'] as List?)?.cast<num>();
      final waves = marineHourly?['wave_height'] as List?;
      if (waveTimes != null && waves != null) {
        for (var i = 0; i < waveTimes.length && i < waves.length; i++) {
          final v = _num(waves[i]);
          if (v != null) {
            waveHeight.add(
              GraphPoint(
                time: DateTime.fromMillisecondsSinceEpoch(
                  waveTimes[i].toInt() * 1000,
                  isUtc: true,
                ),
                value: v,
              ),
            );
          }
        }
      }
    } catch (_) {
      /* wave height is a nice-to-have; skip silently if unavailable */
    }

    return (models: out, waveHeight: waveHeight);
  }

  static String _weatherError(Object e) {
    final s = e.toString();
    if (s.contains('Daily API request limit') ||
        s.contains('limit exceeded') ||
        s.contains('429')) {
      return 'Límite diario superado';
    }
    if (s.contains('Hourly') || s.contains('hourly')) {
      return 'Límite horario superado';
    }
    if (s.contains('TimeoutException') || s.toLowerCase().contains('timeout')) {
      return 'Tiempo de espera agotado';
    }
    if (s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Network')) {
      return 'Sin conexión a internet';
    }
    // Extract "reason" message from Exception('…')
    final match = RegExp(r'Exception: (.+)').firstMatch(s);
    if (match != null) return match.group(1)!;
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  Future<String> _reverseGeocode(double lat, double lon) =>
      reverseGeocode(lat, lon);

  List<ForecastPoint> _forecastSummary(Map<String, dynamic> doc) {
    final current = doc['current'] as Map<String, dynamic>?;
    final hourly = doc['hourly'] as Map<String, dynamic>?;
    final times = (hourly?['time'] as List?)?.cast<num>() ?? const [];
    final list = <ForecastPoint>[];
    if (current != null) list.add(_forecastFromMap(current));
    final base = list.isEmpty ? DateTime.now().toUtc() : list.first.time;
    for (final hours in [24, 48]) {
      final idx = _closestIndex(times, base.add(Duration(hours: hours)));
      if (idx >= 0 && hourly != null) {
        list.add(_forecastFromHourly(hourly, idx));
      }
    }
    return list;
  }

  List<ForecastPoint> _hourlyForecast(Map<String, dynamic> doc) {
    final hourly = doc['hourly'] as Map<String, dynamic>?;
    final times = (hourly?['time'] as List?)?.cast<num>() ?? const [];
    if (hourly == null || times.isEmpty) return const [];
    final now = DateTime.now().toUtc();
    final end = now.add(const Duration(days: 3));
    final out = <ForecastPoint>[];
    for (var t = now; t.isBefore(end); t = t.add(const Duration(hours: 3))) {
      final idx = _closestIndex(times, t);
      if (idx >= 0) out.add(_forecastFromHourly(hourly, idx));
    }
    return out;
  }

  ForecastPoint _forecastFromMap(Map<String, dynamic> map) => ForecastPoint(
    time: _epoch(map['time']),
    tempC: _num(map['temperature_2m']),
    rainPct: _num(map['precipitation_probability']),
    windKn: _num(map['wind_speed_10m']),
    gustKn: _num(map['wind_gusts_10m']),
    windDirDeg: _num(map['wind_direction_10m']),
    weatherCode: _num(map['weather_code'])?.round(),
  );

  ForecastPoint _forecastFromHourly(Map<String, dynamic> hourly, int idx) =>
      ForecastPoint(
        time: _epoch((hourly['time'] as List)[idx]),
        tempC: _at(hourly, 'temperature_2m', idx),
        rainPct: _at(hourly, 'precipitation_probability', idx),
        windKn: _at(hourly, 'wind_speed_10m', idx),
        gustKn: _at(hourly, 'wind_gusts_10m', idx),
        windDirDeg: _at(hourly, 'wind_direction_10m', idx),
        weatherCode: _at(hourly, 'weather_code', idx)?.round(),
      );

  List<MarinePoint> _marine(Map<String, dynamic> doc) {
    final current = doc['current'] as Map<String, dynamic>?;
    final hourly = doc['hourly'] as Map<String, dynamic>?;
    final times = (hourly?['time'] as List?)?.cast<num>() ?? const [];
    final out = <MarinePoint>[];
    final base = current == null
        ? DateTime.now().toUtc()
        : _marineFromMap(current).time;
    for (var hours = _marineMinHour.round(); hours <= _marineMaxHour; hours++) {
      final idx = _closestIndex(times, base.add(Duration(hours: hours)));
      if (idx >= 0 && hourly != null) {
        out.add(_marineFromHourly(hourly, idx));
      }
    }
    if (out.isEmpty && current != null) out.add(_marineFromMap(current));
    return out;
  }

  MarinePoint _marineFromMap(Map<String, dynamic> map) => MarinePoint(
    time: _epoch(map['time']),
    waveM: _num(map['wave_height']),
    waveDir: _num(map['wave_direction']),
    wavePeriod: _num(map['wave_period']),
    swellM: _num(map['swell_wave_height']),
    swellDir: _num(map['swell_wave_direction']),
    swellPeriod: _num(map['swell_wave_period']),
    seaTempC: _num(map['sea_surface_temperature']),
    currentKmh: _num(map['ocean_current_velocity']),
    currentDir: _num(map['ocean_current_direction']),
  );

  MarinePoint _marineFromHourly(Map<String, dynamic> hourly, int idx) =>
      MarinePoint(
        time: _epoch((hourly['time'] as List)[idx]),
        waveM: _at(hourly, 'wave_height', idx),
        waveDir: _at(hourly, 'wave_direction', idx),
        wavePeriod: _at(hourly, 'wave_period', idx),
        swellM: _at(hourly, 'swell_wave_height', idx),
        swellDir: _at(hourly, 'swell_wave_direction', idx),
        swellPeriod: _at(hourly, 'swell_wave_period', idx),
        seaTempC: _at(hourly, 'sea_surface_temperature', idx),
        currentKmh: _at(hourly, 'ocean_current_velocity', idx),
        currentDir: _at(hourly, 'ocean_current_direction', idx),
      );

  @override
  void dispose() {
    reconnectTimer?.cancel();
    weatherTimer?.cancel();
    _navHideTimer?.cancel();
    _navToastTimer?.cancel();
    _demoTimer?.cancel();
    _staleWatchdog?.cancel();
    _phoneHeelTracker?.stop();
    channel?.sink.close();
    _pageController.dispose();
    _navScrollController.dispose();
    _hostController?.dispose();
    _portController?.dispose();
    _authController?.dispose();
    _skUsernameController?.dispose();
    _skPasswordController?.dispose();
    _bucketController?.dispose();
    _influxHostController?.dispose();
    _influxOrgController?.dispose();
    _influxTokenController?.dispose();
    _alarmPlayer?.dispose();
    super.dispose();
  }

  List<String> get _pageIds => [
    'NAV',
    'VNT',
    'PWR',
    'TMP',
    if (settings.sensorConfig.tanks.any((t) => t.enabled)) 'TNK',
    if (settings.sensorConfig.hasOutsideTemp ||
        settings.sensorConfig.hasOutsidePressure)
      'MET',
    'PRON',
    'MAR',
    'ANC',
    'MAP',
    'AIS',
    'CFG',
  ];
  bool get _autoHidesHeader {
    final ids = _pageIds;
    return page < ids.length && (ids[page] == 'ANC' || ids[page] == 'MAP');
  }

  // Navigation/wind values must be recent to be trusted — unlike e.g. temperatures,
  // which stay useful even a bit stale. Nav and wind are tracked separately
  // (see navUpdate/windUpdate on SignalKModel) so one dying instrument doesn't
  // hide behind the other still updating.
  static const _navWindStaleAfter = Duration(seconds: 8);
  // Below this CPA, the NAV cards switch to a stronger alert color — this is
  // "about to matter" territory, not just "closer than most".
  static const _cpaCriticalNm = 0.5;
  bool get _navFresh {
    final u = signalK.navUpdate;
    return u != null && DateTime.now().difference(u) < _navWindStaleAfter;
  }

  bool get _windFresh {
    final u = signalK.windUpdate;
    return u != null && DateTime.now().difference(u) < _navWindStaleAfter;
  }

  // Signal K simply stops emitting navigation.course.calcValues.velocityMadeGood
  // when there's no active route — staleness here means "no waypoint", not
  // "sensor died", but the same freshness check works for both.
  bool get _courseFresh {
    final u = signalK.courseUpdate;
    return u != null && DateTime.now().difference(u) < _navWindStaleAfter;
  }

  double? _fresh(double? v) => _navFresh ? v : null;
  double? _freshWind(double? v) => _windFresh ? v : null;

  // Used by the Premium anchor card to jump to the full ANC tab on tap.
  void _goToTab(String id) {
    final i = _pageIds.indexOf(id);
    if (i < 0) return;
    _onPageChange(i);
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _onPageChange(int i) {
    setState(() => page = i);
    _syncAisSubscription();
    _navHideTimer?.cancel();
    if (_autoHidesHeader) {
      _navHideTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _headerHidden = true);
      });
    } else if (_headerHidden) {
      setState(() => _headerHidden = false);
    }
  }

  void _revealHeader() {
    setState(() => _headerHidden = false);
    _navHideTimer?.cancel();
    _navHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _autoHidesHeader) setState(() => _headerHidden = true);
    });
  }

  // ─── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pages = [
      ('NAV', Icons.explore, _navPage()),
      ('VNT', Icons.air, _windPage()),
      ('PWR', Icons.bolt, _powerPage()),
      ('TMP', Icons.thermostat, _tempPage()),
      if (settings.sensorConfig.tanks.any((t) => t.enabled))
        ('TNK', Icons.water_drop, _tankPage()),
      if (settings.sensorConfig.hasOutsideTemp ||
          settings.sensorConfig.hasOutsidePressure)
        ('MET', Icons.cloud, _metPage()),
      ('PRON', Icons.wb_sunny, _forecastPage()),
      ('MAR', Icons.waves, _marinePage()),
      ('ANC', Icons.anchor, _anchorPage()),
      ('MAP', Icons.map_outlined, _mapPage()),
      ('AIS', Icons.radar, _aisPage()),
      ('CFG', Icons.tune, _settingsPage()),
    ];

    final sysDark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final useNight =
        settings.brightnessMode == 'noche' ||
        (settings.brightnessMode == 'auto' && sysDark);

    final scaffold = Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                ClipRect(
                  child: (_headerHidden && kIsWeb)
                      ? _CollapsedHeaderBar(onTap: _revealHeader)
                      : AnimatedAlign(
                          duration: const Duration(milliseconds: 300),
                          alignment: Alignment.topCenter,
                          heightFactor: _headerHidden ? 0.0 : 1.0,
                          child: _Header(
                            pages: pages,
                            selected: page,
                            status: signalK.status,
                            ok: signalK.connected,
                            alarmPageIds: _alarmPageIds,
                            alarmCount: _activeAlarms.length,
                            onBellTap: () => _showAlarmsList(context),
                            onSelect: (i) {
                              _onPageChange(i);
                              _pageController.animateToPage(
                                i,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            },
                          ),
                        ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: _onPageChange,
                    children: [for (final p in pages) p.$3],
                  ),
                ),
              ],
            ),
            if (_headerHidden && !kIsWeb)
              // Web: the floating overlay handle sits over the WebView's
              // <iframe>, which is a separate browser document and can
              // swallow the tap at the OS/DOM level regardless of Flutter's
              // own widget stacking — so on web we use _CollapsedHeaderBar
              // instead, which reserves real (non-overlapping) layout space.
              Positioned.fill(
                child: Align(
                  alignment: const Alignment(
                    0.7,
                    -1,
                  ), // 15% left of the right edge
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _revealHeader,
                    onVerticalDragUpdate: (d) {
                      if (d.delta.dy > 0) _revealHeader();
                    },
                    child: Container(
                      width: 80,
                      height: 24,
                      alignment: Alignment.topCenter,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(12),
                        ),
                      ),
                      child: Container(
                        width: 48,
                        height: 4,
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!useNight) return scaffold;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        //  R  G  B  A  +
        1, 0, 0, 0, 0, // R → keep
        0, 0, 0, 0, 0, // G → zero
        0, 0, 0, 0, 0, // B → zero
        0, 0, 0, 1, 0, // A → keep
      ]),
      child: scaffold,
    );
  }

  // ─── NAV page ───────────────────────────────────────────────────────────────
  int _navPageIndex = 0;
  double _navDragOverscroll = 0;
  // Briefly names the screen you just swiped to (e.g. "Fondeado"), then
  // fades — otherwise which of several near-identical-looking Premium
  // screens you landed on isn't obvious at a glance.
  String? _navToast;
  Timer? _navToastTimer;

  void _flashNavToast(String label) {
    _navToastTimer?.cancel();
    setState(() => _navToast = label);
    _navToastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _navToast = null);
    });
  }

  final _navScrollController = ScrollController();

  Widget _navPage() {
    final selectedIds = _validNavSelection(settings.navCardIds);
    if (!listEquals(selectedIds, settings.navCardIds)) {
      settings.navCardIds = selectedIds;
    }
    final selected = selectedIds.map(_navCardData).toList();
    final remaining = allNavCardIds
        .where((id) => !selectedIds.contains(id))
        .map(_navCardData)
        .toList();

    // Library pages hold exactly as many cards as fit on the main grid
    // (same columns×2 capacity) so _grid3x2's Expanded rows always divide
    // the available height evenly — no page ever needs to crop a card.
    final capacity = settings.navGridColumns * 2;
    final libraryPages = <List<NavCardData>>[];
    for (var i = 0; i < remaining.length; i += capacity) {
      libraryPages.add(
        remaining.sublist(i, math.min(i + capacity, remaining.length)),
      );
    }

    final screenSize = MediaQuery.sizeOf(context);
    // Threshold lowered to fit the XCover6 tablet's actual landscape
    // logical size (960×600) — it was gated at 1000×560, just above what
    // this boat's hardware reports, so Premium silently never appeared.
    final wantsPremium =
        settings.navLayoutMode == 'premium' || settings.navLayoutMode == 'both';
    final premiumEligible =
        wantsPremium && screenSize.width >= 900 && screenSize.height >= 500;
    // Classic pages show for 'classic'/'both', and also as a fallback for
    // 'premium' when the screen doesn't qualify — never leave the cycle
    // empty just because the tablet's too small for Premium right now.
    final showClassicPages =
        settings.navLayoutMode != 'premium' || !premiumEligible;

    // Vela is always available (the default/fallback); Motor and Fondeado
    // only join the swipeable set while they're actually relevant, so a
    // screen for a context you're not in never shows up empty.
    final premiumScreens = <Widget>[
      _navPremiumSailPage(),
      if (_engineRunning) _navPremiumMotorPage(),
      if (signalK.anchorArmed) _navPremiumAnchorPage(),
    ];
    final premiumLabels = <String>[
      'Vela',
      if (_engineRunning) 'Motor',
      if (signalK.anchorArmed) 'Fondeado',
    ];

    // Exactly two classic pages, fixed: "Clásica 1" is your selected grid,
    // "Clásica 2" is the first page of everything else. Cards beyond that
    // first overflow page simply don't appear in the swipe cycle — pick
    // them into Clásica 1 if you want them on screen.
    final classica2 = libraryPages.isEmpty ? null : libraryPages.first;
    final pages = <Widget>[
      if (premiumEligible) ...premiumScreens,
      if (showClassicPages)
        _grid3x2(
          columns: settings.navGridColumns,
          children: [
            for (var i = 0; i < selected.length; i++)
              _navMetricCard(selected[i], i),
          ],
        ),
      if (showClassicPages && classica2 != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: _grid3x2(
            columns: settings.navGridColumns,
            children: [
              for (var i = 0; i < classica2.length; i++)
                _navMetricCard(
                  classica2[i],
                  selectedIds.length + i,
                  selectable: false,
                ),
            ],
          ),
        ),
    ];
    final pageLabels = <String>[
      if (premiumEligible) ...premiumLabels,
      if (showClassicPages) 'Clásica 1',
      if (showClassicPages && classica2 != null) 'Clásica 2',
    ];

    final totalPages = pages.length;
    if (_navPageIndex >= totalPages) _navPageIndex = 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = math.max(320.0, constraints.maxHeight);
        final page = SizedBox(
          key: ValueKey(_navPageIndex),
          height: pageHeight,
          child: pages[_navPageIndex],
        );

        if (totalPages == 1) {
          return ListView(
            key: const PageStorageKey<String>('nav-scroll'),
            controller: _navScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [page],
          );
        }

        // Manual vertical swipe instead of a nested PageView — a PageView
        // nested inside this screen's outer horizontal PageView was
        // observed to silently swallow taps on the cards it contains (a
        // gesture-arena issue specific to that nesting), so paging is
        // driven by this screen's own ListView instead of a second PageView.
        //
        // That ListView is a real Scrollable (needed so taps reach the
        // cards inside it — a bare SizedBox or NeverScrollableScrollPhysics
        // was observed to swallow those taps under this nesting). But a
        // real Scrollable also *wins* the vertical-drag gesture arena over
        // any ancestor GestureDetector, even though there's nothing to
        // actually scroll (content height == viewport height) — so a plain
        // GestureDetector.onVerticalDragEnd wrapped around it never fired.
        // Detecting the drag via the ListView's own overscroll instead
        // sidesteps that arena conflict entirely. Accumulated *distance*
        // rather than fling velocity, since a deliberate slower drag should
        // page just as reliably as a fast flick — and unlike velocity
        // (which needs several closely-timed samples to compute), distance
        // is correct even from a single coarse touch sample.
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification) {
              _navDragOverscroll = 0;
            } else if (notification is OverscrollNotification) {
              _navDragOverscroll += notification.overscroll;
              if (_navDragOverscroll.abs() >= 60) {
                final forward = _navDragOverscroll > 0;
                _navDragOverscroll = 0;
                setState(() {
                  _navPageIndex = forward
                      ? (_navPageIndex + 1) %
                            totalPages // swipe up (scroll forward) → next
                      : (_navPageIndex - 1 + totalPages) %
                            totalPages; // swipe down → previous
                });
                if (_navPageIndex < pageLabels.length) {
                  _flashNavToast(pageLabels[_navPageIndex]);
                }
              }
            }
            return false;
          },
          child: Stack(
            children: [
              Scrollbar(
                controller: _navScrollController,
                thumbVisibility: true,
                child: ListView(
                  key: const PageStorageKey<String>('nav-scroll'),
                  controller: _navScrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: page,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 6,
                right: 10,
                child: IgnorePointer(
                  child: _NavPageIndicator(
                    total: totalPages,
                    current: _navPageIndex,
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _navToast == null ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: AnimatedScale(
                        scale: _navToast == null ? 0.9 : 1,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 36,
                            vertical: 18,
                          ),
                          decoration: BoxDecoration(
                            color: cBg.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: cCyan.withValues(alpha: 0.35),
                              width: 1.4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 24,
                              ),
                            ],
                          ),
                          child: Text(
                            _navToast ?? '',
                            style: const TextStyle(
                              color: cText,
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _navMetricCard(NavCardData data, int slot, {bool selectable = true}) =>
      MetricCard(
        title: data.title,
        value: data.value,
        unit: data.unit,
        subtitle: data.subtitle,
        color: data.color,
        zoom: _showZoom,
        graphMetrics: data.graphMetrics,
        trend: data.trend,
        bigLines: data.bigLines,
        onTap: data.id == 'heel'
            ? () => _showAttitudeGauges(context)
            : data.id == 'gps'
            ? () => _showGpsDetail(context)
            : data.id == 'ais'
            ? () => _showCpaDetail(context)
            : null,
        onLongPress: selectable ? () => _showNavCardPicker(slot) : null,
        onDoubleTap: selectable ? () => _showNavCardPicker(slot) : null,
        onSecondaryTap: selectable ? () => _showNavCardPicker(slot) : null,
      );

  // The exact same card PWR shows for the house battery (not a Premium
  // gauge card) — battery SOC/V/A read better as plain numbers than as a
  // 0-100 speedometer, and reusing MetricCard directly means this and the
  // PWR page can never drift out of sync with each other.
  Widget _premiumBatteryCard() => MetricCard(
    title: 'Batería',
    value: fmt(signalK.houseSoc, 0, ''),
    unit: '%',
    subtitle:
        '${fmt(signalK.houseV, 1, 'V')} ${signalK.houseA != null ? (signalK.houseA! >= 0 ? '+' : '') : ''}${fmt(signalK.houseA, 1, 'A')}',
    // Smaller than MetricCard's 28px default — the Premium card is
    // narrower than PWR's, and at 28px "13.8V +0.3A" wrapped to 2 lines.
    subtitleFontSize: 16,
    color: socColor(signalK.houseSoc),
    zoom: _showZoom,
    graphMetrics: [_mHouseSoc, _mHouseCurrent, _mHouseVoltage],
  );

  // Fills the space next to Profundidad on the Fondeado screen — Depth on
  // its own as a full-width card was mostly empty air; pairing it with
  // date/time uses that width for something useful instead.
  Widget _premiumDateTimeCard() {
    final now = DateTime.now();
    return MetricCard(
      title: 'Hora',
      value: hhmm(now),
      subtitle: ddmmyyyy(now),
      color: cText,
    );
  }

  NavCardData _navCardData(String id) {
    final sog = _fresh(signalK.sogKn);
    final stw = _fresh(signalK.stwKn);
    final heading = _fresh(signalK.headingTrueDeg);
    final cog = _fresh(signalK.cogTrueDeg);
    final depth = _fresh(signalK.depthM);
    final heel = _fresh(signalK.heelDeg);
    final positionFresh =
        _navFresh && signalK.latitude != null && signalK.longitude != null;
    final closest = _closestApproachTarget();

    switch (id) {
      case 'sog':
        return NavCardData(
          id: id,
          title: 'SOG',
          value: fmt(sog, 1, ''),
          unit: 'kt',
          color: _isCardAlarming('sog') ? cRed : cGreen,
          graphMetrics: const [mSog],
        );
      case 'stw':
        return NavCardData(
          id: id,
          title: 'STW',
          value: fmt(stw, 1, ''),
          unit: 'kt',
          color: _isCardAlarming('stw') ? cRed : cGreen,
        );
      case 'heading':
        return NavCardData(
          id: id,
          title: 'Rumbo',
          value: directionDeg(heading),
          unit: '°',
          color: cText,
          graphMetrics: const [mHeading],
        );
      case 'cog':
        return NavCardData(
          id: id,
          title: 'COG',
          value: directionDeg(cog),
          unit: '°',
          color: cCyan,
        );
      case 'depth':
        return NavCardData(
          id: id,
          title: 'Profundidad',
          value: fmt(depth, 1, ''),
          unit: 'm',
          color: _isCardAlarming('depth') ? cRed : depthColor(depth),
          trend: depth == null ? null : _depthTrend.direction,
        );
      case 'heel':
        return NavCardData(
          id: id,
          title: 'Escora',
          value: heel != null ? '${heel.abs().round()}' : '--',
          unit: heel != null ? '° ${heel >= 0 ? 'E' : 'B'}' : '°',
          color: heelColor(heel),
          graphMetrics: const [mHeel],
        );
      case 'position':
        return NavCardData(
          id: id,
          title: 'Posición',
          value: positionFresh
              ? posLines(signalK.latitude, signalK.longitude)
              : '--',
          subtitle: positionFresh ? 'Lat / Lon' : null,
          color: positionFresh ? cCyan : cMuted,
        );
      case 'gps':
        return NavCardData(
          id: id,
          title: 'GPS',
          value:
              signalK.gnssSatellites?.toString() ??
              (positionFresh ? 'OK' : '--'),
          unit: signalK.gnssSatellites != null ? 'sat' : null,
          subtitle:
              signalK.gnssMethodQuality ??
              _lastUpdateText(signalK.navUpdate ?? signalK.lastUpdate),
          color: positionFresh ? cGreen : cMuted,
        );
      case 'ais':
        // CPA and TCPA are the two numbers that actually matter for
        // "should I worry" at a glance, so they're the two big equal-size
        // lines; name/distancia/demora are secondary context and go below
        // in the smaller muted subtitle.
        final cpaCritical =
            (closest?.cpaNm ?? double.infinity) < _cpaCriticalNm;
        final cpaStr = closest?.cpaNm != null
            ? '${closest!.cpaNm!.toStringAsFixed(1)} NM'
            : '--';
        final tcpaStr = closest?.tcpaMin != null
            ? '${closest!.tcpaMin!.round()} min'
            : '--';
        // "Sin AIS" should mean exactly that — no targets at all — not "no
        // target happens to have a crossing predicted right now", which is
        // the far more common case out at sea and reads as broken/no-data.
        //
        // Name kept separate from dist/bearing (aisName vs subtitle) so the
        // Premium card can let a long name truncate on its own line without
        // it eating into (or being fought over with) the distance/bearing
        // text — a single combined+ellipsized string used to hide whichever
        // came last depending on how long the name happened to be.
        final subtitle = closest != null
            ? [
                if (closest.distNm != null)
                  '${closest.distNm!.toStringAsFixed(1)}NM',
                if (closest.bearingDeg != null)
                  '${closest.bearingDeg!.round()}°',
              ].join(' · ')
            : (_aisTargets.isEmpty ? 'Sin AIS' : 'Sin cruce previsto');
        return NavCardData(
          id: id,
          title: 'AIS',
          value: cpaStr,
          bigLines: ['TCPA $tcpaStr', 'CPA $cpaStr'],
          subtitle: subtitle,
          aisName: closest != null ? _aisTargetName(closest.target) : null,
          aisCrossing: closest?.crossing,
          color: closest == null ? cMuted : (cpaCritical ? cRed : cOrange),
        );
      case 'time':
        final now = DateTime.now();
        return NavCardData(
          id: id,
          title: 'Hora',
          value: hhmm(now),
          subtitle: ddmmyyyy(now),
          color: cText,
        );
      case 'vmgWind':
        final twaForVmg = _freshWind(_dTwa);
        final speedForVmg = stw ?? sog;
        final vmgWind = (twaForVmg != null && speedForVmg != null)
            ? speedForVmg * math.cos(twaForVmg * math.pi / 180)
            : null;
        return NavCardData(
          id: id,
          title: 'VMG viento',
          value: fmt(vmgWind, 1, ''),
          unit: 'kt',
          subtitle: vmgWind == null
              ? 'Sin viento'
              : (vmgWind >= 0 ? 'Ciñendo' : 'Empopada'),
          color: vmgWind == null ? cMuted : cGreen,
        );
      case 'vmgRoute':
        final vmgRoute = _courseFresh ? signalK.courseVmgKn : null;
        return NavCardData(
          id: id,
          title: 'VMG ruta',
          value: fmt(vmgRoute, 1, ''),
          unit: 'kt',
          subtitle: vmgRoute == null ? 'Sin ruta' : null,
          color: vmgRoute == null ? cMuted : cGreen,
        );
      case 'appWind':
        final aws = _freshWind(_dAws);
        final awa = _freshWind(_dAwa);
        return NavCardData(
          id: id,
          title: 'Viento aparente',
          value: fmt(aws, 1, ''),
          bigLines: [
            'AWS ${fmt(aws, 1, '')} kt',
            'AWA ${awa != null ? '${awa.round()}°' : '--'}',
          ],
          color: aws == null ? cMuted : cGreen,
        );
      case 'engineHours':
        final h = signalK.engineHours;
        final enginePath = settings.sensorConfig.enginePath;
        return NavCardData(
          id: id,
          title: 'Horas motor',
          value: h != null ? h.toStringAsFixed(1) : '--',
          unit: h != null ? 'h' : null,
          color: h == null ? cMuted : cText,
          graphMetrics: enginePath == null
              ? null
              : [
                  MetricDef(
                    enginePath,
                    'Horas motor',
                    'h',
                    scale: 1 / 3600.0,
                    color: cText,
                  ),
                ],
        );
      default:
        return _navCardData(defaultNavCardIds.first);
    }
  }

  List<String> _validNavSelection(List<String> ids) {
    final max = settings.navGridColumns * 2;
    final out = <String>[];
    for (final id in ids) {
      if (allNavCardIds.contains(id) && !out.contains(id)) out.add(id);
      if (out.length == max) break;
    }
    for (final id in defaultNavCardIds) {
      if (out.length == max) break;
      if (!out.contains(id)) out.add(id);
    }
    // 4x2 needs 2 more cards than defaultNavCardIds provides — fill any
    // remaining slots from the rest of the catalog.
    for (final id in allNavCardIds) {
      if (out.length == max) break;
      if (!out.contains(id)) out.add(id);
    }
    return out.take(max).toList();
  }

  void _showNavCardPicker(int slot) {
    final selectedIds = _validNavSelection(settings.navCardIds);
    final choices = allNavCardIds
        .where((id) => !selectedIds.contains(id))
        .map(_navCardData)
        .toList();
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: cBg,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Cambiar carta NAV',
                        style: TextStyle(
                          color: cText,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: cMuted),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    itemCount: choices.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: 1.45,
                        ),
                    itemBuilder: (context, i) {
                      final data = choices[i];
                      return MetricCard(
                        title: data.title,
                        value: data.value,
                        unit: data.unit,
                        subtitle: data.subtitle,
                        color: data.color,
                        onTap: () async {
                          final next = List<String>.of(selectedIds);
                          next[slot] = data.id;
                          setState(() => settings.navCardIds = next);
                          await _saveSettings();
                          _syncAisSubscription();
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showGpsDetail(BuildContext context) {
    final sat = signalK.gnssSatellites;
    final hdop = signalK.gnssHdop;
    final alt = signalK.gnssAntennaAltitudeM;
    final fixType = signalK.gnssFixType;
    final quality = signalK.gnssMethodQuality;
    final positionFresh =
        _navFresh && signalK.latitude != null && signalK.longitude != null;
    final rows = <(String, String)>[
      ('Satélites', sat?.toString() ?? '--'),
      ('HDOP', hdop != null ? hdop.toStringAsFixed(1) : '--'),
      ('Tipo', fixType ?? '--'),
      ('Calidad de fix', quality ?? '--'),
      ('Altitud antena', alt != null ? '${alt.toStringAsFixed(0)} m' : '--'),
      (
        'Posición',
        positionFresh ? posLines(signalK.latitude, signalK.longitude) : '--',
      ),
      (
        'Última actualización',
        _lastUpdateText(signalK.navUpdate ?? signalK.lastUpdate),
      ),
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: cBg,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'GPS',
                        style: TextStyle(
                          color: cText,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: cMuted),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 150,
                          child: Text(
                            row.$1,
                            style: const TextStyle(color: cMuted, fontSize: 13),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row.$2,
                            style: const TextStyle(
                              color: cText,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Same "ficha" the AIS tab itself shows on tap — full data, not just the
  // CPA/TCPA summary this dialog used to have on its own.
  void _showCpaDetail(BuildContext context) {
    final closest = _closestApproachTarget();
    if (closest == null) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cPanel,
          title: const Text('AIS', style: TextStyle(color: cText)),
          content: const Text(
            'Sin objetivos AIS con rumbo de colisión',
            style: TextStyle(color: cMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      return;
    }
    showAisTargetDetail(
      context,
      target: closest.target,
      distNm: closest.distNm ?? 0,
      bearingDeg: closest.bearingDeg ?? 0,
      cpaNm: closest.cpaNm,
      tcpaMin: closest.tcpaMin,
      crossing: closest.crossing,
    );
  }

  ({
    AisTarget target,
    double? cpaNm,
    double? tcpaMin,
    double? bearingDeg,
    double? distNm,
    String? crossing,
  })?
  _closestApproachTarget() {
    final ownLat = signalK.latitude;
    final ownLon = signalK.longitude;
    final ownHeading = _fresh(signalK.headingTrueDeg);
    final ownCog = _fresh(signalK.cogTrueDeg) ?? ownHeading;
    final ownSog = _fresh(signalK.sogKn) ?? 0;
    ({
      AisTarget target,
      double? cpaNm,
      double? tcpaMin,
      double? bearingDeg,
      double? distNm,
      String? crossing,
    })?
    best;

    for (final target in _aisTargets.values) {
      final last = target.lastUpdate;
      if (last != null && DateTime.now().difference(last).inMinutes > 10) {
        continue;
      }
      double? cpaNm = target.pluginCpaNm;
      double? tcpaMin = target.pluginTcpaMin;
      double? bearingDeg;
      double? distNm;
      String? crossing;

      if (ownLat != null &&
          ownLon != null &&
          target.lat != null &&
          target.lon != null) {
        final rel = _bearingDistanceNm(
          ownLat,
          ownLon,
          target.lat!,
          target.lon!,
        );
        bearingDeg = rel.bearingDeg;
        distNm = rel.distNm;

        if ((cpaNm == null || tcpaMin == null) &&
            ownCog != null &&
            target.cogDeg != null &&
            target.sogKn != null) {
          final brg = rel.bearingDeg * math.pi / 180;
          final rN = rel.distNm * math.cos(brg);
          final rE = rel.distNm * math.sin(brg);
          final ownCogRad = ownCog * math.pi / 180;
          final tgtCogRad = target.cogDeg! * math.pi / 180;
          final vN =
              target.sogKn! * math.cos(tgtCogRad) -
              ownSog * math.cos(ownCogRad);
          final vE =
              target.sogKn! * math.sin(tgtCogRad) -
              ownSog * math.sin(ownCogRad);
          final cpa = _cpa(rN, rE, vN, vE);
          cpaNm ??= cpa?.cpaNm;
          tcpaMin ??= cpa?.tcpaMin;
          // Same "worth calling proa/popa" gate as the AIS tab's own list
          // view (_aisShowsCrossing): only when the target is actually
          // moving and will pass close, so a stopped/anchored contact or a
          // wide-berth crossing doesn't get a misleading label.
          if (ownHeading != null &&
              (cpaNm ?? double.infinity) < 5 &&
              target.sogKn! > 0.2) {
            crossing = _crossingLabel(
              rN,
              rE,
              vN,
              vE,
              ownHeading * math.pi / 180,
            );
          }
        }
      }

      // Both CPA and TCPA must be known and within range at once — a
      // target with only one of the two computed (e.g. distance known but
      // no CPA yet) used to slip through on the other check alone, which
      // is how a contact 30 NM out with a stray CPA reading could show up
      // as "closest approach". Both thresholds are user-configurable
      // (CFG → Pantalla → AIS).
      if (cpaNm == null || tcpaMin == null) continue;
      // A target 40 minutes out at its current CPA isn't a collision risk
      // yet — don't let it steal the "closest approach" slot from something
      // that's actually about to happen.
      if (tcpaMin > settings.aisTcpaMaxMin) continue;
      // A target that will pass 6 NM off isn't "the" closest approach either.
      if (cpaNm > settings.aisCpaMaxNm) continue;
      final candidate = (
        target: target,
        cpaNm: cpaNm,
        tcpaMin: tcpaMin,
        bearingDeg: bearingDeg,
        distNm: distNm,
        crossing: crossing,
      );
      if (best == null) {
        best = candidate;
        continue;
      }
      final cpaCmp = (candidate.cpaNm ?? double.infinity).compareTo(
        best.cpaNm ?? double.infinity,
      );
      if (cpaCmp < 0 ||
          (cpaCmp == 0 &&
              (candidate.tcpaMin ?? double.infinity) <
                  (best.tcpaMin ?? double.infinity))) {
        best = candidate;
      }
    }
    return best;
  }

  /// Where the relative track crosses our own heading line (dead ahead vs.
  /// astern) — same geometry as the AIS tab's own crossing label, so "por
  /// proa"/"por popa" means the same thing in both places.
  String? _crossingLabel(
    double relN,
    double relE,
    double vN,
    double vE,
    double headingRad,
  ) {
    final cosH = math.cos(headingRad), sinH = math.sin(headingRad);
    final fwd0 = relN * cosH + relE * sinH;
    final right0 = -relN * sinH + relE * cosH;
    final vFwd = vN * cosH + vE * sinH;
    final vRight = -vN * sinH + vE * cosH;
    if (vRight.abs() < 0.05) return null;
    final tStar = -right0 / vRight;
    if (tStar < 0) return null;
    return (fwd0 + vFwd * tStar) >= 0 ? 'POR PROA' : 'POR POPA';
  }

  ({double bearingDeg, double distNm}) _bearingDistanceNm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 3440.065; // nautical miles
    final lat1r = lat1 * math.pi / 180;
    final lat2r = lat2 * math.pi / 180;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1r) *
            math.cos(lat2r) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    final y = math.sin(dLon) * math.cos(lat2r);
    final x =
        math.cos(lat1r) * math.sin(lat2r) -
        math.sin(lat1r) * math.cos(lat2r) * math.cos(dLon);
    final brg = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    return (bearingDeg: brg, distNm: r * c);
  }

  ({double cpaNm, double tcpaMin})? _cpa(
    double rN,
    double rE,
    double vN,
    double vE,
  ) {
    final vv = vN * vN + vE * vE;
    if (vv < 1e-6) return null;
    final t = -(rN * vN + rE * vE) / vv;
    if (t < 0) return null;
    final cN = rN + vN * t;
    final cE = rE + vE * t;
    return (cpaNm: math.sqrt(cN * cN + cE * cE), tcpaMin: t * 60);
  }

  String _aisTargetName(AisTarget target) =>
      target.name ?? target.mmsi ?? target.context.split('.').last;

  void _showAttitudeGauges(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _AttitudeGaugesDialog(
        signalK: signalK,
        settings: settings,
        onSettingsChanged: () {
          unawaited(_saveSettings());
          _applyPhoneHeelSetting();
          if (mounted) setState(() {});
        },
        onCalibrate: (ctx) => _startAttitudeCalibration(ctx),
      ),
    );
  }

  Widget _grid3x2({required List<Widget> children, int columns = 3}) {
    const gap = 8.0;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final slice = children.sublist(i, math.min(i + columns, children.length));
      rows.add(
        Expanded(
          child: Row(
            children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) const SizedBox(width: gap),
                Expanded(
                  child: j < slice.length ? slice[j] : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
      if (i + columns < children.length) rows.add(const SizedBox(height: gap));
    }
    return Padding(
      padding: const EdgeInsets.all(gap),
      child: Column(children: rows),
    );
  }

  Widget _navPremiumSailPage() {
    final sog = _navCardData('sog');
    final stw = _navCardData('stw');
    final vmg = _navCardData('vmgWind');
    final ais = _navCardData('ais');
    final depth = _navCardData('depth');
    final wind = _navCardData('appWind');
    const primaryFlex = 1;
    const secondaryFlex = 1;
    const tacticalFlex = 1;

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: primaryFlex,
                  child: _premiumSpeedCard(sog, maxValue: 12),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: secondaryFlex,
                  child: _premiumSpeedCard(stw, maxValue: 12),
                ),
                const SizedBox(width: 8),
                Expanded(flex: tacticalFlex, child: _premiumVmgCard(vmg)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: primaryFlex, child: _premiumAisCard(ais)),
                const SizedBox(width: 8),
                Expanded(flex: secondaryFlex, child: _premiumDepthCard(depth)),
                const SizedBox(width: 8),
                Expanded(flex: tacticalFlex, child: _premiumWindCard(wind)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Swaps wind/VMG for engine health — the sailing screen's headline
  // instruments stop mattering the moment the engine's turning.
  Widget _navPremiumMotorPage() {
    final sog = _navCardData('sog');
    final cog = _navCardData('cog');
    final engineHours = _navCardData('engineHours');
    final depth = _navCardData('depth');

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 10, child: _premiumSpeedCard(sog, maxValue: 12)),
                const SizedBox(width: 8),
                Expanded(flex: 6, child: _premiumVmgCard(cog)),
                const SizedBox(width: 8),
                Expanded(flex: 10, child: _premiumSpeedCard(engineHours)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 9, child: _premiumDepthCard(depth)),
                const SizedBox(width: 8),
                Expanded(flex: 9, child: _premiumBatteryCard()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The one Premium screen without a matching NavCardData source — anchor
  // watch geometry lives only in SignalKModel, drawn as a boat-centered
  // "radar" (ring = maxRadius, marker = anchor at its live distance/bearing)
  // instead of the numbers-only classic anchor alarm webview.
  Widget _navPremiumAnchorPage() {
    final wind = _navCardData('appWind');
    final depth = _navCardData('depth');
    // Heading, not COG — at anchor the boat isn't tracking a course over
    // ground, it's swinging on the chain, so COG is just noise; heading
    // (which way the bow is lying) is the useful number here.
    final heading = _navCardData('heading');

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          // Anchor card is intentionally small — the ANC tab already has a
          // full map with anchor tracking, this is just a glance.
          Expanded(flex: 7, child: _premiumAnchorCard()),
          const SizedBox(width: 8),
          Expanded(
            flex: 13,
            child: Column(
              children: [
                Expanded(child: _premiumWindCard(wind, showGauge: false)),
                const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _premiumBatteryCard()),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _premiumVmgCard(heading, unitNextToValue: true),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: _premiumDepthCard(
                          depth,
                          alignWithSpeedGauge: false,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: _premiumDateTimeCard()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _premiumPanel({required Widget child, VoidCallback? onTap}) =>
      CardShell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff0d1a21), Color(0xff071015)],
            ),
            boxShadow: [
              BoxShadow(
                color: cCyan.withValues(alpha: 0.04),
                blurRadius: 26,
                spreadRadius: 0,
              ),
            ],
          ),
          child: child,
        ),
      );

  Widget _premiumTitle(String title, Color color, {String? unit}) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(
          color: cMuted,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
      const Spacer(),
      if (unit != null)
        Text(
          unit,
          style: TextStyle(
            color: color,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
    ],
  );

  Widget _premiumSpeedCard(NavCardData data, {double maxValue = 30}) {
    final value = double.tryParse(data.value);
    return _premiumPanel(
      onTap: () => _showZoom(
        data.title,
        data.value,
        data.color,
        subtitle: data.subtitle,
        graphMetrics: data.graphMetrics,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _premiumTitle(data.title, data.color, unit: data.unit),
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Text(
                    data.value,
                    style: TextStyle(
                      color: data.color,
                      fontSize: 210,
                      fontWeight: FontWeight.w900,
                      height: 0.95,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 92,
              child: CustomPaint(
                painter: _PremiumSpeedScalePainter(
                  value: value,
                  color: data.color,
                  maxValue: maxValue,
                  unit: data.unit ?? 'kt',
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // unitNextToValue: Rumbo on the Fondeado screen sits beside the same
  // wind card that can't use a title-level unit (see _premiumWindCard) —
  // so for visual consistency on that screen it gets the same treatment,
  // the unit riding next to the number instead of top-right of the card.
  Widget _premiumVmgCard(NavCardData data, {bool unitNextToValue = false}) {
    final value = double.tryParse(data.value);
    return _premiumPanel(
      onTap: () => _showZoom(
        data.title,
        data.value,
        data.color,
        subtitle: data.subtitle,
        graphMetrics: data.graphMetrics,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _premiumTitle(
              data.title,
              data.color,
              unit: unitNextToValue ? null : data.unit,
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        painter: _PremiumCompassPainter(
                          value: value,
                          color: data.color,
                        ),
                        child: const SizedBox.expand(),
                      ),
                      FractionallySizedBox(
                        widthFactor: 0.72,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: unitNextToValue && data.unit != null
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      data.value,
                                      style: TextStyle(
                                        color: data.color,
                                        fontSize: 120,
                                        fontWeight: FontWeight.w900,
                                        height: 0.95,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 14),
                                      child: Text(
                                        data.unit!,
                                        style: const TextStyle(
                                          color: cMuted,
                                          fontSize: 32,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  data.value,
                                  style: TextStyle(
                                    color: data.color,
                                    fontSize: 120,
                                    fontWeight: FontWeight.w900,
                                    height: 0.95,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (data.subtitle != null)
              Center(
                child: Text(
                  data.subtitle!,
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _premiumAisCard(NavCardData data) {
    final lines = data.bigLines ?? const <String>[];
    final tcpa = lines.isNotEmpty ? lines[0].replaceFirst('TCPA ', '') : '--';
    final cpa = lines.length > 1
        ? lines[1].replaceFirst('CPA ', '')
        : data.value;
    return _premiumPanel(
      onTap: () => _showCpaDetail(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _premiumTitle('AIS', data.color),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _premiumAisNumber('TCPA', tcpa, data.color)),
                  Container(width: 1, color: cMuted.withValues(alpha: 0.22)),
                  Expanded(child: _premiumAisNumber('CPA', cpa, data.color)),
                ],
              ),
            ),
            if (data.aisName != null || data.subtitle != null)
              Row(
                children: [
                  // The name gets its own flexible, independently-truncating
                  // slot — previously it shared one line+ellipsis with the
                  // distance/bearing text, so a long name could hide
                  // whichever of those happened to be typed after it.
                  if (data.aisName != null)
                    Expanded(
                      child: Text(
                        data.aisName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: cMuted,
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  if (data.subtitle != null) ...[
                    if (data.aisName != null) const SizedBox(width: 8),
                    Text(
                      data.subtitle!,
                      style: const TextStyle(
                        color: cMuted,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            // Whether the target's track crosses ahead of or behind us —
            // its own row so it never competes for space with the name.
            if (data.aisCrossing != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: data.color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    data.aisCrossing!,
                    style: TextStyle(
                      color: data.color,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _premiumAisNumber(String label, String value, Color color) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 74,
              fontWeight: FontWeight.w900,
              height: 0.98,
            ),
          ),
        ),
      ],
    ),
  );

  // Same hysteresis device as the AWA dial's zone switching — tiers
  // (10/20/50/100/200 m) instead of a fixed 0-10m scale, so anchoring in
  // deeper water doesn't just pin the marker uselessly at the bottom.
  double _depthScaleMax = 10;
  double _depthScaleWithHysteresis(double? value) {
    if (value == null) return _depthScaleMax;
    const tiers = [10.0, 20.0, 50.0, 100.0, 200.0];
    if (value > _depthScaleMax * 0.9) {
      _depthScaleMax = tiers.firstWhere(
        (t) => t > _depthScaleMax && value <= t * 0.9,
        orElse: () => tiers.last,
      );
    } else {
      final lower = tiers.lastWhere(
        (t) => t < _depthScaleMax,
        orElse: () => tiers.first,
      );
      if (value < lower * 0.5) _depthScaleMax = lower;
    }
    return _depthScaleMax;
  }

  // alignWithSpeedGauge: reserves the same bottom strip _premiumSpeedCard
  // does, so a Depth card stacked directly under a speed card (Vela,
  // Motor — the default) lines up with it. Must be turned off wherever
  // Depth isn't stacked under one (Fondeado, sharing a much shorter row
  // with Hora instead) — that reservation would just shrink the number
  // pointlessly there.
  Widget _premiumDepthCard(
    NavCardData data, {
    bool alignWithSpeedGauge = true,
  }) {
    final value = double.tryParse(data.value);
    final depthMax = _depthScaleWithHysteresis(value);
    return _premiumPanel(
      onTap: () => _showZoom(
        data.title,
        data.value,
        data.color,
        subtitle: data.subtitle,
        graphMetrics: data.graphMetrics,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _premiumTitle(data.title, data.color, unit: data.unit),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    // A light lift keeps Depth visually related to the
                    // speed cards above it, but the number should remain
                    // mostly centered because its scale is vertical, not a
                    // bottom dial like SOG/STW.
                    child: Padding(
                      padding: alignWithSpeedGauge
                          ? const EdgeInsets.only(bottom: 42)
                          : EdgeInsets.zero,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: Text(
                            data.value,
                            style: TextStyle(
                              color: data.color,
                              fontSize: 210,
                              fontWeight: FontWeight.w900,
                              height: 0.95,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    child: CustomPaint(
                      painter: _PremiumDepthScalePainter(
                        value: value,
                        color: data.color,
                        maxValue: depthMax,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Which of the 2 dial zones is active — near the bow (±45°, drawn
  // opening upward) or near the stern (135°..225°, the same shape just
  // relabeled around 180° instead of 0°). The old middle 60°..120° window
  // was dropped entirely (see _PremiumAwaPainter) so there's no longer a
  // third shape to fight screen-aspect edge cases on. Kept as state (not
  // recomputed fresh each paint) so the ~90° boundary has hysteresis —
  // without it, AWA sitting right at that boundary would flicker back and
  // forth on every small oscillation.
  bool _awaFarZone = false;

  bool _awaFarWithHysteresis(double? awa) {
    if (awa == null) return _awaFarZone;
    final absAwa = normalizeRelativeAngle(awa).abs();
    const hysteresis = 5.0;
    if (_awaFarZone) {
      if (absAwa < 90 - hysteresis) _awaFarZone = false;
    } else {
      if (absAwa > 90 + hysteresis) _awaFarZone = true;
    }
    return _awaFarZone;
  }

  // showGauge: false on the Fondeado screen — at anchor there's no
  // meaningful apparent-wind angle relative to travel, so the dial is
  // dead space; only the AWS/AWA numbers are useful there.
  Widget _premiumWindCard(NavCardData data, {bool showGauge = true}) {
    final aws = _freshWind(_dAws);
    final awa = _freshWind(_dAwa);
    // Absolute value + side arrow (see _premiumWindNumber) instead of a
    // signed angle — matches the VNT screen's AWA card. "°" goes through
    // the same unit slot as AWS's "kt" now (was embedded in the value
    // string before), so both get identical superscript styling.
    final awaText = awa == null ? '--' : angleAbs(awa);
    final awaSide = awa != null
        ? (normalizeRelativeAngle(awa) < 0 ? -1 : 1)
        : 0;
    final farZone = _awaFarWithHysteresis(awa);
    final numbersRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: _premiumWindNumber('AWS', fmt(aws, 0, ''), 'kt')),
        Container(width: 1, color: cMuted.withValues(alpha: 0.22)),
        Expanded(
          child: _premiumWindNumber(
            'AWA',
            awaText,
            '°',
            side: awaSide,
            hasSideArrow: true,
          ),
        ),
      ],
    );
    return _premiumPanel(
      onTap: () => _showZoom(
        data.title,
        data.value,
        data.color,
        subtitle: data.subtitle,
        graphMetrics: data.graphMetrics,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // No title-level unit — this card holds two metrics (AWS/AWA),
            // so a single top-right unit slot doesn't make sense here the
            // way it does on single-metric cards. "kt" instead sits next to
            // the AWS number itself, same spot/scale as the ° next to AWA.
            _premiumTitle(data.title, data.color),
            // Numbers get a compact, fixed-height row (not Expanded) so
            // they always land at the same height regardless of content —
            // previously AWA's column carried extra height (its own number
            // + the gauge below it) that AWS's column didn't, so the two
            // numbers ended up misaligned with each other. Without a gauge
            // below (Fondeado screen), let them fill the card instead so
            // there's no dead space.
            if (showGauge)
              SizedBox(height: 108, child: numbersRow)
            else
              Expanded(child: Center(child: numbersRow)),
            // The dial fills the whole remaining rectangle (not a centered
            // square) so it can pick its own radius/vertical anchor per
            // zone (see _PremiumAwaPainter) — a fixed square left it
            // needlessly small whenever the card was wider than it was
            // tall in this last strip.
            if (showGauge)
              Expanded(
                // Small top gap pushes the whole dial down, away from the
                // numbers row above it.
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: CustomPaint(
                    painter: _PremiumAwaPainter(awa: awa, far: farZone),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // side: -1 port (red arrow, left), 0 none, 1 starboard (green arrow,
  // right) — same device as the VNT screen's _WindTapCard: the number
  // itself stays neutral white and only the side arrow carries color, so a
  // green number never gets misread as "good"/starboard by itself.
  // hasSideArrow: reserves both arrow slots (invisible on the inactive
  // side) so the number sits on the true center regardless of which side
  // is active — only needed for AWA (AWS never has a side). Skipping it
  // for AWS frees up real width: with both slots always reserved, a
  // 3-digit AWA ("133°") plus its arrow genuinely didn't fit the column
  // and bled sideways over AWS's own number.
  Widget _premiumWindNumber(
    String label,
    String value,
    String? unit, {
    int side = 0,
    bool hasSideArrow = false,
  }) {
    const arrowSlot = 26.0;
    Widget arrow(Color color, bool flip) => SizedBox(
      width: arrowSlot,
      child: Center(
        child: Transform.flip(
          flipX: flip,
          child: Icon(Icons.play_arrow, color: color, size: 24),
        ),
      ),
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: cMuted,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (hasSideArrow)
              side < 0
                  ? arrow(cRed, false)
                  : const SizedBox(width: arrowSlot),
            // Unit sits high next to the digits — a true superscript,
            // riding above the number's cap-height — same spot/scale on
            // both AWS's "kt" and AWA's "°" (a single card with two
            // metrics has nowhere sensible for one card-level unit).
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: cText,
                    fontSize: 52,
                    fontWeight: FontWeight.w900,
                    height: 0.95,
                  ),
                ),
                if (unit != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      unit,
                      style: const TextStyle(
                        color: cMuted,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            if (hasSideArrow)
              side > 0
                  ? arrow(cGreen, true)
                  : const SizedBox(width: arrowSlot),
          ],
        ),
      ],
    );
  }

  // Boat-centered "radar" for the anchor watch: the outer ring is the
  // configured swing limit (maxRadius), and the marker shows the anchor's
  // live distance/bearing from the bow within it — reads at a glance
  // whether it's centered or nearing the edge, instead of two bare numbers.
  Widget _premiumAnchorCard() {
    final current = signalK.anchorCurrentRadiusM;
    final maxR = signalK.anchorMaxRadiusM;
    final bearing = signalK.anchorApparentBearingDeg;
    final frac = (current != null && maxR != null && maxR > 0)
        ? (current / maxR).clamp(0.0, 1.3)
        : null;
    final color = frac == null
        ? cMuted
        : frac < 0.6
        ? cGreen
        : frac < 0.9
        ? cOrange
        : cRed;
    return _premiumPanel(
      onTap: () => _goToTab('ANC'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _premiumTitle('Ancla', color),
            // Distance sits above the ring, not beside it — the card is
            // taller than it is wide, so a side-by-side split squeezed the
            // ring into a narrow column; stacking uses the full width.
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Column(
                children: [
                  const Text(
                    'DISTANCIA',
                    style: TextStyle(
                      color: cMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          current != null ? current.toStringAsFixed(0) : '--',
                          style: TextStyle(
                            color: color,
                            fontSize: 64,
                            fontWeight: FontWeight.w900,
                            height: 0.95,
                          ),
                        ),
                        if (current != null) ...[
                          const SizedBox(width: 4),
                          Text(
                            'm',
                            style: TextStyle(
                              color: color,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: CustomPaint(
                    painter: _PremiumAnchorPainter(
                      radiusFraction: frac,
                      bearingDeg: bearing,
                      color: color,
                      shipIcon: _shipIcon,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            Center(
              child: Text(
                maxR != null
                    ? 'Radio máx. ${maxR.toStringAsFixed(0)} m'
                    : 'Sin radio configurado',
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── VNT page ───────────────────────────────────────────────────────────────
  Widget _windPage() {
    final computedTwa = _freshWind(
      _dTwa ??
          relativeWindAngle(
            _dTwd,
            signalK.headingTrueDeg ?? signalK.cogTrueDeg,
          ),
    );
    final aws = _freshWind(_dAws),
        awa = _freshWind(_dAwa),
        sog = _fresh(signalK.sogKn),
        tws = _freshWind(_dTws),
        twd = _freshWind(_dTwd);
    final h = settings.effectiveInfluxHost;
    final b = settings.influxBucket;
    final ab = settings.influxArchiveBucket;
    final hs = settings.historySource;
    final iOrg = settings.influxOrg;
    final iTok = settings.influxToken;
    final skH = settings.host;
    final skP = settings.port;
    final skA = settings.authBase64;
    final awsGust = _awsHistory.gust();
    final twsGust = _twsHistory.gust();
    return _grid3x2(
      children: [
        _WindTapCard(
          label: 'AWS',
          value: fmt(aws, 0, ''),
          color: cText,
          accentColor: windColor(aws),
          unit: 'kt',
          trend: _awsHistory.trend(),
          gust: awsGust != null ? fmt(awsGust, 0, '') : null,
          beaufort: beaufort(aws),
          graphMetrics: const [mAws],
          host: h,
          bucket: b,
          archiveBucket: ab,
          historySource: hs,
          influxOrg: iOrg,
          influxToken: iTok,
          skHost: skH,
          skPort: skP,
          skAuthBase64: skA,
          demo: settings.demoMode,
          settings: settings,
        ),
        _WindTapCard(
          label: 'AWA',
          value: angleAbs(awa),
          color: cText,
          accentColor: sideColor(awa),
          unit: '°',
          side: awa != null ? (normalizeRelativeAngle(awa) < 0 ? -1 : 1) : 0,
          graphMetrics: const [mAwa],
          host: h,
          bucket: b,
          archiveBucket: ab,
          historySource: hs,
          influxOrg: iOrg,
          influxToken: iTok,
          skHost: skH,
          skPort: skP,
          skAuthBase64: skA,
          demo: settings.demoMode,
          settings: settings,
        ),
        _WindTapCard(
          label: 'SOG',
          value: fmt(sog, 1, ''),
          color: cText,
          accentColor: cGreen,
          unit: 'kt',
          graphMetrics: const [mSog],
          host: h,
          bucket: b,
          archiveBucket: ab,
          historySource: hs,
          influxOrg: iOrg,
          influxToken: iTok,
          skHost: skH,
          skPort: skP,
          skAuthBase64: skA,
          demo: settings.demoMode,
          settings: settings,
        ),
        _WindTapCard(
          label: 'TWS',
          value: fmt(tws, 0, ''),
          color: cText,
          accentColor: windColor(tws),
          unit: 'kt',
          trend: _twsHistory.trend(),
          gust: twsGust != null ? fmt(twsGust, 0, '') : null,
          beaufort: beaufort(tws),
          graphMetrics: const [mTws],
          host: h,
          bucket: b,
          archiveBucket: ab,
          historySource: hs,
          influxOrg: iOrg,
          influxToken: iTok,
          skHost: skH,
          skPort: skP,
          skAuthBase64: skA,
          demo: settings.demoMode,
          settings: settings,
        ),
        _WindTapCard(
          label: 'TWA',
          value: angleAbs(computedTwa),
          color: cText,
          accentColor: sideColor(computedTwa),
          unit: '°',
          side: computedTwa != null
              ? (normalizeRelativeAngle(computedTwa) < 0 ? -1 : 1)
              : 0,
          graphMetrics: const [mTwa],
          host: h,
          bucket: b,
          archiveBucket: ab,
          historySource: hs,
          influxOrg: iOrg,
          influxToken: iTok,
          skHost: skH,
          skPort: skP,
          skAuthBase64: skA,
          demo: settings.demoMode,
          settings: settings,
        ),
        _WindTapCard(
          label: 'TWD',
          value: directionDeg(twd),
          color: cText,
          accentColor: cOrange,
          unit: '° ${dir(twd)}',
          graphMetrics: const [mTwd],
          host: h,
          bucket: b,
          archiveBucket: ab,
          historySource: hs,
          influxOrg: iOrg,
          influxToken: iTok,
          skHost: skH,
          skPort: skP,
          skAuthBase64: skA,
          demo: settings.demoMode,
          settings: settings,
        ),
      ],
    );
  }

  // ─── PWR page ───────────────────────────────────────────────────────────────
  MetricDef get _mHouseSoc => MetricDef(
    'electrical.batteries.${settings.sensorConfig.batteryHouseId}.capacity.stateOfCharge',
    'Batería',
    '%',
    scale: 100.0,
    color: cGreen,
  );
  MetricDef get _mHouseCurrent => MetricDef(
    'electrical.batteries.${settings.sensorConfig.batteryHouseId}.current',
    'Corriente',
    'A',
    color: cCyan,
  );
  MetricDef get _mHouseVoltage => MetricDef(
    'electrical.batteries.${settings.sensorConfig.batteryHouseId}.voltage',
    'Voltaje',
    'V',
    color: cCyan,
  );
  MetricDef get _mHouseTemp => MetricDef(
    'electrical.batteries.${settings.sensorConfig.batteryHouseId}.temperature',
    'T. batería',
    'C',
    offset: -273.15,
    color: cOrange,
  );
  MetricDef get _mStartV => MetricDef(
    'electrical.batteries.${settings.sensorConfig.batteryStartId}.voltage',
    'Start',
    'V',
    color: cGreen,
  );
  MetricDef? get _mSolar {
    final p = settings.sensorConfig.solarPath;
    return (p == null || p.isEmpty)
        ? null
        : MetricDef(p, 'Solar', 'W', color: cYellow);
  }

  MetricDef _metricColor(MetricDef metric, Color color) => MetricDef(
    metric.skPath,
    metric.label,
    metric.unit,
    offset: metric.offset,
    scale: metric.scale,
    color: color,
  );

  MetricDef? get _mFridge1 {
    final p = settings.sensorConfig.fridge1Path;
    return (p == null || p.isEmpty)
        ? null
        : MetricDef(p, 'T. Nevera 1', 'C', offset: -273.15, color: cGreen);
  }

  MetricDef? get _mFridge2 {
    final p = settings.sensorConfig.fridge2Path;
    return (p == null || p.isEmpty)
        ? null
        : MetricDef(p, 'T. Nevera 2', 'C', offset: -273.15, color: cGreen);
  }

  Widget _powerPage() {
    final houseColor = socColor(signalK.houseSoc);
    final currentColorValue = currentColor(signalK.houseA);
    final startColor = voltageColor12V(signalK.startV);
    final bowColor = voltageColor12V(signalK.bowthrusterV);
    final currentPrefix = signalK.houseA != null && signalK.houseA! >= 0
        ? '+'
        : '';
    final batterySubtitle =
        '${fmt(signalK.houseV, 2, ' V')}  $currentPrefix${fmt(signalK.houseA, 1, ' A')}';
    final dcReferenceWatts = ((signalK.houseV ?? 12.5) * 40).clamp(
      420.0,
      620.0,
    );
    final houseMetrics = [
      _metricColor(_mHouseSoc, houseColor),
      _metricColor(_mHouseCurrent, houseColor),
      _metricColor(_mHouseVoltage, houseColor),
    ];
    final solarMetric = _mSolar;
    final hasSolar =
        settings.demoMode || (solarMetric != null && signalK.solarW != null);
    final hasDcLoads = settings.demoMode || signalK.dcW != null;
    final flowWidgets = <Widget>[];
    if (hasSolar) {
      flowWidgets.add(
        Expanded(
          flex: 10,
          child: PowerFlowTile(
            title: 'Solar',
            value: fmt(signalK.solarW, 0, ''),
            unit: 'W',
            subtitle: 'solar',
            color: cYellow,
            icon: Icons.wb_sunny,
            zoom: _showZoom,
            graphMetrics: solarMetric == null ? null : [solarMetric],
          ),
        ),
      );
      flowWidgets.add(
        PowerFlowConnector(
          color: cYellow,
          watts: signalK.solarW,
          label: 'carga',
          referenceWatts: 600,
        ),
      );
    }
    flowWidgets.add(
      Expanded(
        flex: hasSolar || hasDcLoads ? 12 : 16,
        child: PowerFlowTile(
          title: 'Batería servicio',
          value: fmt(signalK.houseSoc, 0, ''),
          unit: '%',
          subtitle: batterySubtitle,
          color: houseColor,
          icon: Icons.battery_charging_full,
          stateOfCharge: signalK.houseSoc,
          zoom: _showZoom,
          graphMetrics: houseMetrics,
        ),
      ),
    );
    if (hasDcLoads) {
      flowWidgets.add(
        PowerFlowConnector(
          color: cOrange,
          watts: signalK.dcW,
          label: 'consumo',
          referenceWatts: dcReferenceWatts,
        ),
      );
      flowWidgets.add(
        Expanded(
          flex: 10,
          child: PowerFlowTile(
            title: 'DC Loads',
            value: fmt(signalK.dcW, 0, ''),
            unit: 'W',
            subtitle: 'Consumos DC',
            color: cOrange,
            icon: Icons.power,
            zoom: _showZoom,
            graphMetrics: [_metricColor(mDcLoads, cOrange)],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Expanded(flex: 7, child: Row(children: flowWidgets)),
          const SizedBox(height: 8),
          Expanded(
            flex: 4,
            child: Row(
              children: [
                Expanded(
                  child: PowerAuxTile(
                    title: 'Corriente servicio',
                    value: fmt(signalK.houseA, 1, ''),
                    unit: 'A',
                    subtitle: signalK.houseA == null
                        ? 'sin datos'
                        : signalK.houseA! >= 0
                        ? 'cargando batería'
                        : 'descargando batería',
                    color: currentColorValue,
                    icon: Icons.swap_vert,
                    zoom: _showZoom,
                    graphMetrics: [
                      _metricColor(_mHouseCurrent, currentColorValue),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PowerAuxTile(
                    title: 'Arranque',
                    value: fmt(signalK.startV, 2, ''),
                    unit: 'V',
                    subtitle: settings.sensorConfig.batteryStartId,
                    color: startColor,
                    customIcon: StarterMotorGlyph(color: startColor),
                    zoom: _showZoom,
                    graphMetrics: [_metricColor(_mStartV, startColor)],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PowerAuxTile(
                    title: 'Bow thruster',
                    value: fmt(signalK.bowthrusterV, 2, ''),
                    unit: 'V',
                    subtitle: 'batería proa',
                    color: bowColor,
                    customIcon: BowThrusterGlyph(color: bowColor),
                    zoom: _showZoom,
                    graphMetrics: [_metricColor(mBowV, bowColor)],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── TEMP page ──────────────────────────────────────────────────────────────
  Widget _tempPage() {
    final cards = <Widget>[
      MetricCard(
        title: 'T. Batería',
        value: tempValue(signalK.houseTempK),
        unit: tempUnit(signalK.houseTempK),
        color: equipTempColor(signalK.houseTempK, warnC: 35, alarmC: 50),
        zoom: _showZoom,
        graphMetrics: [_mHouseTemp],
      ),
      MetricCard(
        title: 'T. Bowthruster',
        value: tempValue(signalK.bowthrusterTempK),
        unit: tempUnit(signalK.bowthrusterTempK),
        color: equipTempColor(signalK.bowthrusterTempK, warnC: 40, alarmC: 60),
        zoom: _showZoom,
        graphMetrics: const [mBowTemp],
      ),
      MetricCard(
        title: 'T. Mar',
        value: tempValue(signalK.waterTempK),
        unit: tempUnit(signalK.waterTempK),
        color: seaTempColor(signalK.waterTempK),
        zoom: _showZoom,
        graphMetrics: const [mSeaTemp],
      ),
      MetricCard(
        title: 'T. Raspberry',
        value: tempValue(signalK.cpuTempK),
        unit: tempUnit(signalK.cpuTempK),
        color: equipTempColor(signalK.cpuTempK, warnC: 60, alarmC: 75),
        zoom: _showZoom,
        graphMetrics: const [mCpuTemp],
      ),
      if (_mFridge1 != null)
        MetricCard(
          title: 'T. Nevera 1',
          value: tempValue(signalK.fridge1TempK),
          unit: tempUnit(signalK.fridge1TempK),
          color: fridgeTempColor(signalK.fridge1TempK),
          zoom: _showZoom,
          graphMetrics: [_mFridge1!],
        ),
      if (_mFridge2 != null)
        MetricCard(
          title: 'T. Nevera 2',
          value: tempValue(signalK.fridge2TempK),
          unit: tempUnit(signalK.fridge2TempK),
          color: fridgeTempColor(signalK.fridge2TempK),
          zoom: _showZoom,
          graphMetrics: [_mFridge2!],
        ),
    ];
    return _grid3x2(children: cards);
  }

  // ─── Tank page ──────────────────────────────────────────────────────────────
  static const _tankIcons = {
    'fuel': Icons.local_gas_station,
    'freshWater': Icons.water_drop_outlined,
    'blackWater': Icons.opacity,
  };
  static const _tankColors = {
    'fuel': Color(0xffb7d122),
    'freshWater': Color(0xff81c6ef),
    'blackWater': Color(0xff7f42ee),
  };

  List<TankViewData> get tankOverview {
    final groups = <String, List<TankSlot>>{};
    for (final t in settings.sensorConfig.tanks.where((t) => t.enabled)) {
      groups.putIfAbsent(t.groupLabel, () => []).add(t);
    }
    return [
      for (final entry in groups.entries)
        TankViewData(
          name: entry.key,
          slots: entry.value,
          color: _tankColors[entry.value.first.type] ?? cCyan,
          icon: _tankIcons[entry.value.first.type] ?? Icons.water_drop,
        ),
    ];
  }

  Widget _tankPage() {
    final tanks = tankOverview;
    return LayoutBuilder(
      builder: (ctx, c) {
        final cardW = c.maxWidth * 0.20;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final t in tanks)
                SizedBox(
                  width: cardW,
                  child: TankCard(
                    name: t.name,
                    value: t.percent(signalK.tanks),
                    capacityL: t.capacityL,
                    color: t.color,
                    icon: t.icon,
                    flexible: true,
                    onTap: () => _showTankGroup(t),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ─── MET page ───────────────────────────────────────────────────────────────
  Widget _metPage() {
    final forecast = elementAtOrNull(weather.summary, 0);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            flex: 11,
            child: PressureTrendCard(
              value: signalK.outsidePressureHpa,
              history: _pressureHistory,
              fromInflux: _pressureTrendFromInflux,
              zoom: _showZoom,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 18,
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: MetricCard(
                          title: 'T. exterior',
                          value: tempNum(signalK.outsideTempK),
                          unit: '°C',
                          subtitle: signalK.outsideHumidity != null
                              ? 'HR ${fmt(signalK.outsideHumidity, 0, '%')}'
                              : null,
                          color: cCyan,
                          zoom: _showZoom,
                          graphMetrics: const [mOutdoorTemp],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: MetricCard(
                          title: 'T. interior',
                          value: tempNum(signalK.indoorTempK),
                          unit: '°C',
                          subtitle: signalK.indoorHumidity != null
                              ? 'HR ${fmt(signalK.indoorHumidity, 0, '%')}'
                              : null,
                          color: cCyan,
                          zoom: _showZoom,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: ModelWindCompassCard(
                          forecast: forecast,
                          tws: _freshWind(_dTws),
                          zoom: _showZoom,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: MetricCard(
                          title: 'Lugar',
                          value: forecast != null
                              ? fmt(forecast.tempC, 0, '')
                              : '--',
                          unit: '°C',
                          subtitle: weather.error ?? weather.place,
                          color: weather.error != null ? cOrange : cYellow,
                          zoom: _showZoom,
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
    );
  }

  // ─── Forecast page (unchanged) ──────────────────────────────────────────────
  Widget _weatherEmptyState(String page) {
    final err = weather.error;
    if (err != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 42, color: cMuted),
            const SizedBox(height: 12),
            Text(
              err,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: cOrange,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reintentar'),
              onPressed: () => unawaited(_loadWeather(force: true)),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Text(
        'Descargando $page…',
        style: const TextStyle(fontSize: 22, color: cMuted),
      ),
    );
  }

  (double?, double?) _dayMinMax(int dayOffset) {
    final start = DateTime.now().toUtc().add(Duration(days: dayOffset));
    final end = start.add(const Duration(hours: 24));
    final temps = [
      for (final p in weather.hourly)
        if (!p.time.isBefore(start) && p.time.isBefore(end)) p.tempC,
    ].whereType<double>().toList();
    if (temps.isEmpty) return (null, null);
    return (temps.reduce(math.min), temps.reduce(math.max));
  }

  static const _forecastHeaderHeight = 34.0;

  Widget _forecastPage() {
    if (weather.hourly.isEmpty) return _weatherEmptyState('predicción');
    return LayoutBuilder(
      builder: (ctx, c) {
        final summaryHeight = ((c.maxHeight - _forecastHeaderHeight) * 0.42)
            .clamp(110.0, 168.0);
        return Column(
          children: [
            SizedBox(
              height: _forecastHeaderHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        weather.place,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: cMuted, fontSize: 18),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _pickWeatherLocation(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.edit_location_alt_outlined,
                              size: 15,
                              color: _manualWeatherLat != null
                                  ? cOrange
                                  : cMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Cambiar ubicación',
                              style: TextStyle(
                                color: _manualWeatherLat != null
                                    ? cOrange
                                    : cMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _showModelComparison(context),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.stacked_line_chart,
                              size: 15,
                              color: cCyan,
                            ),
                            SizedBox(width: 5),
                            Text(
                              'Comparar modelos',
                              style: TextStyle(
                                color: cCyan,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: summaryHeight,
              child: Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: ForecastCard(
                        title: i == 0 ? 'Ahora' : '+${i * 24} h',
                        point: elementAtOrNull(weather.summary, i),
                        minMax: _dayMinMax(i),
                        zoom: _showZoom,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(child: ForecastStrip(points: weather.hourly)),
          ],
        );
      },
    );
  }

  // ─── Marine page ────────────────────────────────────────────────────────────
  static const _marineMinHour = 1.0;
  static const _marineMaxHour = 24.0;

  static String _marineDate(DateTime t) {
    const days = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
    const months = [
      'ene',
      'feb',
      'mar',
      'abr',
      'may',
      'jun',
      'jul',
      'ago',
      'sep',
      'oct',
      'nov',
      'dic',
    ];
    final l = t.toLocal();
    return '${days[l.weekday - 1]} ${l.day} ${months[l.month - 1]}';
  }

  String _marineHorizonLabel(double hours) => '${hours.round()}h';

  double? _lerpNullable(double? a, double? b, double t) {
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return a + (b - a) * t;
  }

  double? _lerpDirection(double? a, double? b, double t) {
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return normalize360(a + normalizeRelativeAngle(b - a) * t);
  }

  MarinePoint _marinePointAt(double hours) {
    if (weather.marine.length < 2) return weather.marine.first;
    final requested = hours.clamp(_marineMinHour, _marineMaxHour);
    final clamped = requested.clamp(
      _marineMinHour,
      weather.marine.length.toDouble(),
    );
    final lowerHour = clamped.floor().clamp(1, weather.marine.length);
    final upperHour = clamped.ceil().clamp(1, weather.marine.length);
    final lower = weather.marine[lowerHour - 1];
    final upper = weather.marine[upperHour - 1];
    final t = upperHour == lowerHour
        ? 0.0
        : (clamped - lowerHour) / (upperHour - lowerHour);
    final millis =
        lower.time.millisecondsSinceEpoch +
        ((upper.time.millisecondsSinceEpoch -
                    lower.time.millisecondsSinceEpoch) *
                t)
            .round();
    return MarinePoint(
      time: DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      waveM: _lerpNullable(lower.waveM, upper.waveM, t),
      waveDir: _lerpDirection(lower.waveDir, upper.waveDir, t),
      wavePeriod: _lerpNullable(lower.wavePeriod, upper.wavePeriod, t),
      swellM: _lerpNullable(lower.swellM, upper.swellM, t),
      swellDir: _lerpDirection(lower.swellDir, upper.swellDir, t),
      swellPeriod: _lerpNullable(lower.swellPeriod, upper.swellPeriod, t),
      seaTempC: _lerpNullable(lower.seaTempC, upper.seaTempC, t),
      currentKmh: _lerpNullable(lower.currentKmh, upper.currentKmh, t),
      currentDir: _lerpDirection(lower.currentDir, upper.currentDir, t),
    );
  }

  (String, Color) _marineComfort(MarinePoint point) {
    final wave = point.waveM;
    if (wave == null) return ('--', cMuted);
    if (wave < 1.0) return ('Cómodo', cGreen);
    if (wave < 2.0) return ('Atención', cOrange);
    return ('Duro', cRed);
  }

  Widget _marinePage() => weather.marine.isEmpty
      ? _weatherEmptyState('MAR')
      : Builder(
          builder: (context) {
            if (weather.marine.length < _marineMaxHour.round() &&
                !loadingWeather) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !loadingWeather) {
                  unawaited(_loadWeather(force: true));
                }
              });
            }
            const maxHour = _marineMaxHour;
            final currentHours = _marineHorizonHours.clamp(
              _marineMinHour,
              maxHour,
            );
            final point = _marinePointAt(currentHours);
            final (comfort, comfortColor) = _marineComfort(point);
            final currentKn = point.currentKmh == null
                ? null
                : point.currentKmh! / 1.852;
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  SizedBox(
                    height: 58,
                    child: Row(
                      children: [
                        Text(
                          '${_marineHorizonLabel(currentHours)} · ${_marineDate(point.time)}',
                          style: const TextStyle(
                            color: cMuted,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: cCyan,
                              inactiveTrackColor: cMuted.withValues(
                                alpha: 0.25,
                              ),
                              thumbColor: cCyan,
                              overlayColor: cCyan.withValues(alpha: 0.14),
                              valueIndicatorColor: cPanel,
                              valueIndicatorTextStyle: const TextStyle(
                                color: cText,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            child: Slider(
                              value: currentHours,
                              min: _marineMinHour,
                              max: maxHour,
                              label: _marineHorizonLabel(currentHours),
                              onChanged: maxHour <= _marineMinHour
                                  ? null
                                  : (v) =>
                                        setState(() => _marineHorizonHours = v),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        for (final marker in const [1.0, 6.0, 12.0, 24.0])
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              _marineHorizonLabel(marker),
                              style: TextStyle(
                                color: (currentHours - marker).abs() < 0.5
                                    ? cCyan
                                    : cMuted,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 11,
                          child: MarineGraphicCard(
                            title: 'Ola significativa',
                            value: point.waveM,
                            unit: 'm',
                            subtitle:
                                'Periodo ${fmt(point.wavePeriod, 1, ' s')} · ${dir(point.waveDir)}',
                            color: cCyan,
                            directionDeg: point.waveDir,
                            valueWidthFactor: 0.82,
                            arrowSize: 68,
                            arrowGap: 18,
                            arrowLift: 22,
                            zoom: _showZoom,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 18,
                          child: Column(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: MarineGraphicCard(
                                        title: 'Swell',
                                        value: point.swellM,
                                        unit: 'm',
                                        subtitle:
                                            '${dir(point.swellDir)} · ${fmt(point.swellPeriod, 1, ' s')}',
                                        color: const Color(0xff69bdf7),
                                        directionDeg: point.swellDir,
                                        valueFontSize: 154,
                                        valueWidthFactor: 0.72,
                                        arrowSize: 56,
                                        arrowGap: 18,
                                        arrowLift: 20,
                                        zoom: _showZoom,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: MetricCard(
                                        title: 'Corriente',
                                        value: fmt(currentKn, 1, ''),
                                        unit: 'kt',
                                        subtitle: dir(point.currentDir),
                                        color: cGreen,
                                        zoom: _showZoom,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: MetricCard(
                                        title: 'T. mar',
                                        value: fmt(point.seaTempC, 0, ''),
                                        unit: '°C',
                                        subtitle: 'superficie',
                                        color: cCyan,
                                        zoom: _showZoom,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: MetricCard(
                                        title: 'Resumen',
                                        value: comfort,
                                        subtitle:
                                            'Ola ${fmt(point.waveM, 1, ' m')} · swell ${fmt(point.swellM, 1, ' m')}',
                                        color: comfortColor,
                                        zoom: _showZoom,
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
                ],
              ),
            );
          },
        );

  // ─── Anchor page (WebView) ──────────────────────────────────────────────────
  Widget _anchorPage() => _AnchorWebView(
    host: settings.host,
    port: settings.port,
    missingPluginHint: 'No se encontró el plugin de fondeo (Anchor Alarm) en Signal K.\nInstálalo desde el App Store de Signal K.',
    demo: settings.demoMode,
    demoExplainer: 'Aquí verías la alarma de fondeo (Anchor Alarm), embebida desde el servidor Signal K: la posición del ancla, el radio de garreo y el estado de la alarma.',
  );

  Widget _mapPage() => _AnchorWebView(
    host: settings.host,
    port: settings.port,
    path: '/@signalk/freeboard-sk/',
    label: 'Freeboard-SK',
    demo: settings.demoMode,
    demoExplainer: 'Aquí verías la carta náutica Freeboard-SK, embebida desde el servidor Signal K: tu posición, rumbo y las cartas configuradas.',
  );

  Widget _aisPage() => AisRelativeView(
    targets: _aisTargets,
    ownHeadingDeg: signalK.headingTrueDeg,
    ownCogDeg: signalK.cogTrueDeg,
    ownSogKn: signalK.sogKn,
    ownLat: signalK.latitude,
    ownLon: signalK.longitude,
  );

  // ─── Settings page ──────────────────────────────────────────────────────────

  Widget _settingsPage() {
    // ??= : created once and reused across rebuilds (see the field
    // declarations for why a fresh controller per rebuild was the bug).
    final hostController = _hostController ??= TextEditingController(
      text: settings.host,
    );
    final portController = _portController ??= TextEditingController(
      text: '${settings.port}',
    );
    final authController = _authController ??= TextEditingController(
      text: settings.authBase64,
    );
    final skUsernameController = _skUsernameController ??=
        TextEditingController(text: settings.skUsername);
    final skPasswordController = _skPasswordController ??=
        TextEditingController(text: settings.skPassword);
    final bucketController = _bucketController ??= TextEditingController(
      text: settings.influxBucket,
    );
    final influxHostController = _influxHostController ??=
        TextEditingController(text: settings.influxHost);
    final influxOrgController = _influxOrgController ??= TextEditingController(
      text: settings.influxOrg,
    );
    final influxTokenController = _influxTokenController ??=
        TextEditingController(text: settings.influxToken);
    var scanning = false;
    var scanChecked = 0, scanTotal = 0;
    List<String> scanResults = [];

    const lbl = TextStyle(
      color: cMuted,
      fontSize: 10,
      letterSpacing: 1.1,
      fontWeight: FontWeight.w700,
    );
    const gap = SizedBox(height: 6);

    Future<void> doSave() async {
      settings.host = hostController.text.trim();
      settings.port = int.tryParse(portController.text.trim()) ?? 3000;
      settings.authBase64 = authController.text.trim();
      settings.influxHost = influxHostController.text.trim();
      settings.influxOrg = influxOrgController.text.trim().isEmpty
          ? influxOrgDefault
          : influxOrgController.text.trim();
      settings.influxToken = influxTokenController.text.trim().isEmpty
          ? influxTokenDefault
          : influxTokenController.text.trim();
      settings.influxBucket = bucketController.text.trim().isEmpty
          ? influxBucketDefault
          : bucketController.text.trim();
      await _saveSettings();
      _connectSignalK();
      Timer(const Duration(seconds: 12), _maybePromptDemoMode);
    }

    return DefaultTabController(
      length: 6,
      child: Column(
        children: [
          const Material(
            color: cBg,
            child: TabBar(
              isScrollable: true,
              labelColor: cCyan,
              unselectedLabelColor: cMuted,
              indicatorColor: cCyan,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'CONEXIÓN'),
                Tab(text: 'SENSORES'),
                Tab(text: 'HISTÓRICO'),
                Tab(text: 'PANTALLA'),
                Tab(text: 'ALARMAS'),
                Tab(text: 'DIAGNÓSTICO'),
              ],
            ),
          ),
          Expanded(
            child: StatefulBuilder(
              builder: (ctx, setSt) => TabBarView(
                children: [
                  // ── Tab: Conexión (Signal K) ─────────────────────────────────────
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_isSignalKWebapp) ...[
                          const Text('SIGNAL K', style: lbl),
                          gap,
                          Row(
                            children: [
                              const Icon(
                                Icons.check_circle,
                                color: cGreen,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Conectado automáticamente a ${settings.host}:${settings.port} — esta app se sirve desde tu propio servidor Signal K, así que no hace falta configurar host/puerto.',
                                  style: const TextStyle(
                                    color: cMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ] else ...[
                          const Text('SIGNAL K', style: lbl),
                          gap,
                          Row(
                            children: [
                              _HostPresetChip(
                                label: 'lysmarine.local',
                                selected: settings.host == 'lysmarine.local',
                                onTap: () {
                                  setSt(() {
                                    settings.host = 'lysmarine.local';
                                    hostController.text = settings.host;
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              _HostPresetChip(
                                label: '100.85.109.61',
                                selected: settings.host == '100.85.109.61',
                                onTap: () {
                                  setSt(() {
                                    settings.host = '100.85.109.61';
                                    hostController.text = settings.host;
                                  });
                                },
                              ),
                            ],
                          ),
                          gap,
                          // Manual IP/hostname entry — the third option alongside the two
                          // presets above: "lysmarine.local" only resolves on the network
                          // it was set up on (mDNS is network-scoped), so a different boat
                          // needs to type its own Signal K IP here, or use the scan below.
                          TextField(
                            controller: hostController,
                            decoration: const InputDecoration(
                              labelText: 'Host (o escribe una IP manualmente)',
                              isDense: true,
                            ),
                            onChanged: (v) =>
                                setSt(() => settings.host = v.trim()),
                          ),
                          gap,
                          OutlinedButton.icon(
                            icon: scanning
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.wifi_find, size: 18),
                            label: Text(
                              scanning
                                  ? 'Buscando… ($scanChecked/$scanTotal)'
                                  : 'Buscar Signal K en la red (puerto 3000)',
                            ),
                            onPressed: scanning
                                ? null
                                : () async {
                                    setSt(() {
                                      scanning = true;
                                      scanResults = [];
                                      scanChecked = 0;
                                      scanTotal = 0;
                                    });
                                    try {
                                      final results = await scanLanForSignalK(
                                        3000,
                                        onProgress: (c, t) => setSt(() {
                                          scanChecked = c;
                                          scanTotal = t;
                                        }),
                                      );
                                      setSt(() {
                                        scanResults = results;
                                        scanning = false;
                                      });
                                    } catch (e) {
                                      setSt(() => scanning = false);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'No se pudo escanear la red: ${friendlyApiError(e)}',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                          ),
                          if (!scanning &&
                              scanResults.isEmpty &&
                              scanChecked > 0)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'No se encontró ningún Signal K en la red.',
                                style: TextStyle(color: cMuted, fontSize: 12),
                              ),
                            ),
                          if (scanResults.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final ip in scanResults)
                                    _HostPresetChip(
                                      label: ip,
                                      selected: settings.host == ip,
                                      onTap: () {
                                        setSt(() {
                                          settings.host = ip;
                                          hostController.text = ip;
                                        });
                                      },
                                    ),
                                ],
                              ),
                            ),
                          gap,
                          TextField(
                            controller: portController,
                            decoration: const InputDecoration(
                              labelText: 'Puerto',
                              isDense: true,
                            ),
                            keyboardType: TextInputType.number,
                          ),
                          TextField(
                            controller: authController,
                            decoration: const InputDecoration(
                              labelText:
                                  'Autenticación Signal K (Basic, base64)',
                              helperText: 'Solo para la conexión a Signal K — no para InfluxDB',
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            icon: const Icon(Icons.save, size: 18),
                            label: const Text('Guardar y reconectar'),
                            onPressed: () => doSave(),
                          ),
                          if (_isSignalKWebapp) ...[
                            const SizedBox(height: 16),
                            const Text(
                              'SESIÓN WEB (Freeboard / Anclaje)',
                              style: lbl,
                            ),
                            gap,
                            const Text(
                              'Distinto del campo de arriba: hace login real en Signal K para que el navegador quede con sesión — así Freeboard-SK y la alarma de fondeo (embebidos) también funcionan (p.ej. arrastrar para fijar el ancla), sin volver a pedir login.',
                              style: TextStyle(color: cMuted, fontSize: 11),
                            ),
                            gap,
                            TextField(
                              controller: skUsernameController,
                              decoration: const InputDecoration(
                                labelText: 'Usuario Signal K',
                                isDense: true,
                              ),
                            ),
                            gap,
                            TextField(
                              controller: skPasswordController,
                              decoration: const InputDecoration(
                                labelText: 'Contraseña Signal K',
                                isDense: true,
                              ),
                              obscureText: true,
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.login, size: 16),
                                  label: const Text('Iniciar sesión'),
                                  onPressed: () async {
                                    settings.skUsername = skUsernameController
                                        .text
                                        .trim();
                                    settings.skPassword =
                                        skPasswordController.text;
                                    await _saveSettings();
                                    await _loginToSignalK();
                                    if (mounted) setState(() {});
                                  },
                                ),
                                const SizedBox(width: 10),
                                if (_skLoginOk == true)
                                  const Text(
                                    'Sesión iniciada ✓',
                                    style: TextStyle(
                                      color: cGreen,
                                      fontSize: 12,
                                    ),
                                  )
                                else if (_skLoginOk == false)
                                  const Text(
                                    'No se pudo iniciar sesión',
                                    style: TextStyle(color: cRed, fontSize: 12),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                  // ── Tab: Sensores ──────────────────────────────────────────────────
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SENSORES', style: lbl),
                        gap,
                        const Text(
                          'Descubre y asigna los paths de Signal K para baterías, solar, neveras, tanques y profundidad de este barco.',
                          style: TextStyle(color: cMuted, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.sensors, size: 18),
                          label: const Text('Configurar sensores'),
                          onPressed: () async {
                            final newCfg = await showDialog<SensorConfig>(
                              context: context,
                              builder: (_) => _SensorConfigDialog(
                                initial: settings.sensorConfig,
                                discover: discoverSkPaths,
                              ),
                            );
                            if (newCfg != null) {
                              setState(() => settings.sensorConfig = newCfg);
                              await _saveSettings();
                              _connectSignalK();
                            }
                          },
                        ),
                        if (!kIsWeb) ...[
                          const SizedBox(height: 20),
                          const Text('ESCORA (BALANCEO)', style: lbl),
                          gap,
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                              'Usar acelerómetro del dispositivo',
                              style: TextStyle(color: cText, fontSize: 13),
                            ),
                            subtitle: const Text(
                              'Fuente alternativa de escora/cabeceo si el barco no tiene sensor de actitud propio (navigation.attitude)',
                              style: TextStyle(color: cMuted, fontSize: 11),
                            ),
                            value: settings.usePhoneHeel,
                            onChanged: (v) {
                              setSt(() => settings.usePhoneHeel = v);
                              setState(() {});
                              unawaited(_saveSettings());
                            },
                          ),
                          if (settings.usePhoneHeel)
                            const Text(
                              'Elegir el eje y calibrar se hace desde la propia pantalla: toca la tarjeta "Escora" en NAV.',
                              style: TextStyle(color: cMuted, fontSize: 12),
                            ),
                        ],
                      ],
                    ),
                  ),
                  // ── Tab: Histórico de gráficas ────────────────────────────────────
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Fuente de datos',
                          style: TextStyle(color: cMuted, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'auto',
                              label: Text(
                                'Automático',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            ButtonSegment(
                              value: 'influx',
                              label: Text(
                                'InfluxDB',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            ButtonSegment(
                              value: 'sk',
                              label: Text(
                                'Signal K (KIP…)',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                          selected: {settings.historySource},
                          onSelectionChanged: (v) =>
                              setSt(() => settings.historySource = v.first),
                        ),
                        const SizedBox(height: 4),
                        Text(switch (settings.historySource) {
                          'influx' => 'Siempre usa InfluxDB.',
                          'sk' => 'Siempre usa el History API de Signal K (funciona con KIP/SQLite u otro proveedor registrado).',
                          _ => 'Prueba InfluxDB primero; si falla, usa el History API de Signal K (KIP/SQLite) automáticamente.',
                        }, style: const TextStyle(color: cMuted, fontSize: 11)),
                        if (settings.historySource != 'sk') ...[
                          const SizedBox(height: 14),
                          const Text('INFLUXDB', style: lbl),
                          gap,
                          TextField(
                            controller: influxHostController,
                            decoration: const InputDecoration(
                              labelText: 'Host (vacío = el mismo que Signal K)',
                              isDense: true,
                            ),
                            onChanged: (v) =>
                                setSt(() => settings.influxHost = v.trim()),
                          ),
                          gap,
                          TextField(
                            controller: influxOrgController,
                            decoration: const InputDecoration(
                              labelText: 'Org',
                              isDense: true,
                            ),
                            onChanged: (v) =>
                                setSt(() => settings.influxOrg = v.trim()),
                          ),
                          gap,
                          TextField(
                            controller: influxTokenController,
                            decoration: const InputDecoration(
                              labelText: 'Token',
                              isDense: true,
                            ),
                            obscureText: true,
                            onChanged: (v) =>
                                setSt(() => settings.influxToken = v.trim()),
                          ),
                          gap,
                          TextField(
                            controller: bucketController,
                            decoration: const InputDecoration(
                              labelText: 'Bucket',
                              hintText: 'enjoy_raw',
                              isDense: true,
                            ),
                            onChanged: (v) =>
                                setSt(() => settings.influxBucket = v.trim()),
                          ),
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.save, size: 18),
                          label: const Text('Guardar y reconectar'),
                          onPressed: () => doSave(),
                        ),
                      ],
                    ),
                  ),
                  // ── Tab: Pantalla ──────────────────────────────────────────────────
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: settings.keepAwake,
                          onChanged: (v) {
                            setState(() => settings.keepAwake = v);
                            _applyWakelock();
                          },
                          title: const Text(
                            'Pantalla siempre activa',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: settings.demoMode,
                          onChanged: (v) => setState(() => setDemoMode(v)),
                          title: const Text(
                            'Modo DEMO (datos simulados)',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'MODO',
                          style: TextStyle(
                            color: cMuted,
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'dia',
                              label: Text('Día'),
                              icon: Icon(Icons.wb_sunny_outlined, size: 14),
                            ),
                            ButtonSegment(
                              value: 'auto',
                              label: Text('Auto (dispositivo)'),
                              icon: Icon(Icons.brightness_auto, size: 14),
                            ),
                            ButtonSegment(
                              value: 'noche',
                              label: Text('Noche'),
                              icon: Icon(Icons.nightlight_outlined, size: 14),
                            ),
                          ],
                          selected: {settings.brightnessMode},
                          onSelectionChanged: (v) {
                            setState(() => settings.brightnessMode = v.first);
                            unawaited(_saveSettings());
                          },
                          style: const ButtonStyle(
                            visualDensity: VisualDensity(
                              horizontal: -2,
                              vertical: -2,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'ESTILO NAV',
                          style: TextStyle(
                            color: cMuted,
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'classic',
                              label: Text('Clásica'),
                            ),
                            ButtonSegment(
                              value: 'premium',
                              label: Text('Premium'),
                            ),
                            ButtonSegment(value: 'both', label: Text('Ambas')),
                          ],
                          selected: {settings.navLayoutMode},
                          onSelectionChanged: (v) {
                            setState(() {
                              settings.navLayoutMode = v.first;
                              _navPageIndex = 0;
                            });
                            unawaited(_saveSettings());
                          },
                          style: const ButtonStyle(
                            visualDensity: VisualDensity(
                              horizontal: -2,
                              vertical: -2,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'REJILLA NAV CLÁSICA',
                          style: TextStyle(
                            color: cMuted,
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                              value: 3,
                              label: Text('3×2 (6 cartas)'),
                            ),
                            ButtonSegment(
                              value: 4,
                              label: Text('4×2 (8 cartas)'),
                            ),
                          ],
                          selected: {settings.navGridColumns},
                          onSelectionChanged: (v) {
                            setState(() => settings.navGridColumns = v.first);
                            unawaited(_saveSettings());
                          },
                          style: const ButtonStyle(
                            visualDensity: VisualDensity(
                              horizontal: -2,
                              vertical: -2,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Just what shows on the NAV AIS card — not an
                        // alarm (see CFG → Alarmas for the real collision
                        // alarm, which has its own, much tighter
                        // thresholds and actually alerts).
                        const Text('AIS — MOSTRADO EN NAV', style: lbl),
                        gap,
                        _ThresholdRow(
                          label: 'CPA máximo mostrado',
                          unit: 'NM',
                          value: settings.aisCpaMaxNm,
                          onChanged: (v) {
                            setSt(() => settings.aisCpaMaxNm = v);
                            setState(() {});
                            unawaited(_saveSettings());
                          },
                        ),
                        _ThresholdRow(
                          label: 'TCPA máximo mostrado',
                          unit: 'min',
                          value: settings.aisTcpaMaxMin,
                          onChanged: (v) {
                            setSt(() => settings.aisTcpaMaxMin = v);
                            setState(() {});
                            unawaited(_saveSettings());
                          },
                        ),
                      ],
                    ),
                  ),
                  // ── Tab: Alarmas ────────────────────────────────────────────────────
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('FUENTE', style: lbl),
                        gap,
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: settings.alarmsUseSkZones,
                          onChanged: (v) {
                            setSt(() => settings.alarmsUseSkZones = v);
                            setState(() {});
                            unawaited(_saveSettings());
                            unawaited(_syncAlarmSound());
                          },
                          title: const Text(
                            'Usar zonas de Signal K',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            'Zonas configuradas en el propio servidor (notifications.*)',
                            style: TextStyle(fontSize: 11, color: cMuted),
                          ),
                        ),
                        if (settings.alarmsUseSkZones) ...[
                          const SizedBox(height: 10),
                          const Text('ALARMAS DETECTADAS EN ZONA', style: lbl),
                          gap,
                          if (_notifications.isEmpty)
                            const Text(
                              'Ninguna alarma detectada todavía.',
                              style: TextStyle(color: cMuted, fontSize: 12),
                            )
                          else
                            for (final path in _notifications.keys)
                              _SkZoneAlarmRow(
                                path: path,
                                state: _notifications[path]!.state,
                                setting: settings.skZoneAlarms[path],
                                onChanged: (next) {
                                  setSt(
                                    () => settings.skZoneAlarms[path] = next,
                                  );
                                  setState(() {});
                                  unawaited(_saveSettings());
                                  unawaited(_syncAlarmSound());
                                },
                              ),
                        ],
                        const SizedBox(height: 16),
                        const Text('ALARMA DE CORREDERA', style: lbl),
                        gap,
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: settings.alarmCorrederaEnabled,
                          onChanged: (v) {
                            setSt(() => settings.alarmCorrederaEnabled = v);
                            setState(() {});
                            unawaited(_saveSettings());
                            unawaited(_syncAlarmSound());
                          },
                          title: const Text(
                            'Corredera (SOG sin STW)',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            'Salta si SOG > 2 kt y STW = 0 durante al menos 3s — corredera fouled/parada',
                            style: TextStyle(fontSize: 11, color: cMuted),
                          ),
                        ),
                        if (settings.alarmCorrederaEnabled)
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: settings.alarmCorrederaSound,
                            onChanged: (v) {
                              setSt(() => settings.alarmCorrederaSound = v);
                              setState(() {});
                              unawaited(_saveSettings());
                              unawaited(_syncAlarmSound());
                            },
                            title: const Text(
                              'Aviso sonoro',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        const SizedBox(height: 16),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: settings.alarmAisEnabled,
                          onChanged: (v) {
                            setSt(() => settings.alarmAisEnabled = v);
                            setState(() {});
                            unawaited(_saveSettings());
                            unawaited(_syncAlarmSound());
                          },
                          title: const Text(
                            'Alarma de colisión AIS',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            'Salta cuando CPA y TCPA del blanco más cercano bajan de estos umbrales a la vez',
                            style: TextStyle(fontSize: 11, color: cMuted),
                          ),
                        ),
                        if (settings.alarmAisEnabled) ...[
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: settings.alarmAisSound,
                            onChanged: (v) {
                              setSt(() => settings.alarmAisSound = v);
                              setState(() {});
                              unawaited(_saveSettings());
                              unawaited(_syncAlarmSound());
                            },
                            title: const Text(
                              'Aviso sonoro',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                          _ThresholdRow(
                            label: 'Alarma CPA',
                            unit: 'NM',
                            value: settings.alarmAisCpaNm,
                            onChanged: (v) {
                              setSt(() => settings.alarmAisCpaNm = v);
                              setState(() {});
                              unawaited(_saveSettings());
                            },
                          ),
                          _ThresholdRow(
                            label: 'Alarma TCPA',
                            unit: 'min',
                            value: settings.alarmAisTcpaMin,
                            onChanged: (v) {
                              setSt(() => settings.alarmAisTcpaMin = v);
                              setState(() {});
                              unawaited(_saveSettings());
                            },
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Text('ALARMAS PERSONALIZADAS', style: lbl),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                color: cCyan,
                              ),
                              onPressed: () async {
                                final rule = await _showAddCustomAlarmDialog(
                                  context,
                                );
                                if (rule == null) return;
                                setSt(() => settings.customAlarms.add(rule));
                                setState(() {});
                                unawaited(_saveSettings());
                              },
                            ),
                          ],
                        ),
                        if (settings.customAlarms.isEmpty)
                          const Text(
                            'Ninguna. Toca + para añadir una.',
                            style: TextStyle(color: cMuted, fontSize: 12),
                          )
                        else
                          for (final rule in settings.customAlarms)
                            _CustomAlarmRow(
                              rule: rule,
                              onChanged: () {
                                setSt(() {});
                                setState(() {});
                                unawaited(_saveSettings());
                                unawaited(_syncAlarmSound());
                              },
                              onDelete: () {
                                setSt(
                                  () => settings.customAlarms.removeWhere(
                                    (r) => r.id == rule.id,
                                  ),
                                );
                                setState(() {});
                                unawaited(_saveSettings());
                                unawaited(_syncAlarmSound());
                              },
                            ),
                      ],
                    ),
                  ),
                  // ── Tab: Diagnóstico ───────────────────────────────────────────────
                  Builder(
                    builder: (_) {
                      final sc = settings.sensorConfig;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('NAVEGACIÓN / VIENTO', style: lbl),
                            const SizedBox(height: 4),
                            _diagRow(
                              'Escora',
                              signalK.heelDeg != null
                                  ? '${signalK.heelDeg!.abs().round()}° ${signalK.heelDeg! >= 0 ? 'E' : 'B'}'
                                  : '--',
                              signalK.heelDeg != null ? cGreen : cRed,
                              path: 'navigation.attitude.roll',
                            ),
                            _diagRow(
                              'TWS',
                              _dTws != null
                                  ? '${_dTws!.toStringAsFixed(1)} kt'
                                  : '--',
                              _dTws != null ? cCyan : cMuted,
                              path: 'environment.wind.speedTrue',
                            ),
                            _diagRow(
                              'TWA',
                              _dTwa != null
                                  ? '${_dTwa!.toStringAsFixed(1)}°'
                                  : '--',
                              _dTwa != null ? cCyan : cMuted,
                              path: 'environment.wind.angleTrueWater',
                            ),
                            _diagRow(
                              'AWS',
                              _dAws != null
                                  ? '${_dAws!.toStringAsFixed(1)} kt'
                                  : '--',
                              _dAws != null ? cGreen : cMuted,
                              path: 'environment.wind.speedApparent',
                            ),
                            _diagRow(
                              'AWA',
                              _dAwa != null
                                  ? '${_dAwa!.toStringAsFixed(1)}°'
                                  : '--',
                              _dAwa != null ? cGreen : cMuted,
                              path: 'environment.wind.angleApparent',
                            ),
                            _diagRow(
                              'SOG',
                              signalK.sogKn != null
                                  ? '${signalK.sogKn!.toStringAsFixed(1)} kt'
                                  : '--',
                              signalK.sogKn != null ? cGreen : cMuted,
                              path: 'navigation.speedOverGround',
                            ),
                            _diagRow(
                              'STW',
                              signalK.stwKn != null
                                  ? '${signalK.stwKn!.toStringAsFixed(1)} kt'
                                  : '--',
                              signalK.stwKn != null ? cGreen : cMuted,
                              path: 'navigation.speedThroughWater',
                            ),
                            _diagRow(
                              'Rumbo',
                              signalK.headingTrueDeg != null
                                  ? '${signalK.headingTrueDeg!.round()}°'
                                  : '--',
                              signalK.headingTrueDeg != null ? cText : cMuted,
                              path: 'navigation.headingTrue',
                            ),
                            _diagRow(
                              'Profundidad',
                              signalK.depthM != null
                                  ? '${signalK.depthM!.toStringAsFixed(1)} m'
                                  : '--',
                              signalK.depthM != null ? cOrange : cMuted,
                              path: sc.depthPath ?? '(sin configurar)',
                            ),
                            _diagRow(
                              'Horas motor',
                              signalK.engineHours != null
                                  ? '${signalK.engineHours!.toStringAsFixed(1)} h'
                                  : '--',
                              signalK.engineHours != null ? cText : cMuted,
                              path: sc.enginePath ?? '(sin configurar)',
                            ),
                            _diagRow(
                              'COG',
                              signalK.cogTrueDeg != null
                                  ? '${signalK.cogTrueDeg!.round()}°'
                                  : '--',
                              signalK.cogTrueDeg != null ? cText : cMuted,
                              path: 'navigation.courseOverGroundTrue',
                            ),
                            _diagRow(
                              'Ancla',
                              signalK.anchorArmed ? 'Armada' : 'Sin armar',
                              signalK.anchorArmed ? cGreen : cMuted,
                              path: 'navigation.anchor.state',
                            ),
                            _diagRow(
                              'TWD',
                              _dTwd != null
                                  ? '${_dTwd!.toStringAsFixed(0)}°'
                                  : '--',
                              _dTwd != null ? cCyan : cMuted,
                              path: 'environment.wind.directionTrue',
                            ),
                            _diagRow(
                              'VMG viento',
                              () {
                                final twaForVmg = _freshWind(_dTwa);
                                final speedForVmg =
                                    _fresh(signalK.stwKn) ??
                                    _fresh(signalK.sogKn);
                                final v =
                                    (twaForVmg != null && speedForVmg != null)
                                    ? speedForVmg *
                                          math.cos(twaForVmg * math.pi / 180)
                                    : null;
                                return v != null
                                    ? '${v.toStringAsFixed(1)} kt'
                                    : '--';
                              }(),
                              cGreen,
                              path: '(calculado)',
                            ),
                            _diagRow(
                              'VMG ruta',
                              signalK.courseVmgKn != null
                                  ? '${signalK.courseVmgKn!.toStringAsFixed(1)} kt'
                                  : '--',
                              signalK.courseVmgKn != null ? cGreen : cMuted,
                              path: 'navigation.course.calcValues.velocityMadeGood',
                            ),
                            _diagRow(
                              'GNSS sats',
                              signalK.gnssSatellites?.toString() ?? '--',
                              signalK.gnssSatellites != null ? cGreen : cMuted,
                              path: 'navigation.gnss.satellites',
                            ),
                            _diagRow(
                              'GNSS HDOP',
                              signalK.gnssHdop != null
                                  ? signalK.gnssHdop!.toStringAsFixed(1)
                                  : '--',
                              signalK.gnssHdop != null ? cGreen : cMuted,
                              path: 'navigation.gnss.horizontalDilution',
                            ),
                            _diagRow(
                              'GNSS fix',
                              signalK.gnssMethodQuality ??
                                  signalK.gnssFixType ??
                                  '--',
                              (signalK.gnssMethodQuality ??
                                          signalK.gnssFixType) !=
                                      null
                                  ? cGreen
                                  : cMuted,
                              path: 'navigation.gnss.methodQuality',
                            ),
                            _diagRow(
                              'Altitud antena',
                              signalK.gnssAntennaAltitudeM != null
                                  ? '${signalK.gnssAntennaAltitudeM!.toStringAsFixed(1)} m'
                                  : '--',
                              signalK.gnssAntennaAltitudeM != null
                                  ? cGreen
                                  : cMuted,
                              path: 'navigation.gnss.antennaAltitude',
                            ),
                            const SizedBox(height: 12),
                            const Text('ENERGÍA', style: lbl),
                            const SizedBox(height: 4),
                            _diagRow(
                              'Batería de servicio V',
                              signalK.houseV != null
                                  ? '${signalK.houseV!.toStringAsFixed(2)} V'
                                  : '--',
                              signalK.houseV != null ? cCyan : cMuted,
                              path:
                                  'electrical.batteries.${sc.batteryHouseId}.voltage',
                            ),
                            _diagRow(
                              'Batería de servicio A',
                              signalK.houseA != null
                                  ? '${signalK.houseA!.toStringAsFixed(1)} A'
                                  : '--',
                              signalK.houseA != null ? cCyan : cMuted,
                              path:
                                  'electrical.batteries.${sc.batteryHouseId}.current',
                            ),
                            _diagRow(
                              'Batería de servicio SoC',
                              signalK.houseSoc != null
                                  ? '${signalK.houseSoc!.round()}%'
                                  : '--',
                              signalK.houseSoc != null ? cCyan : cMuted,
                              path:
                                  'electrical.batteries.${sc.batteryHouseId}.capacity.stateOfCharge',
                            ),
                            _diagRow(
                              'Batería arranque V',
                              signalK.startV != null
                                  ? '${signalK.startV!.toStringAsFixed(2)} V'
                                  : '--',
                              signalK.startV != null ? cCyan : cMuted,
                              path:
                                  'electrical.batteries.${sc.batteryStartId}.voltage',
                            ),
                            _diagRow(
                              'Solar',
                              signalK.solarW != null
                                  ? '${signalK.solarW!.round()} W'
                                  : '--',
                              signalK.solarW != null ? cOrange : cMuted,
                              path: sc.solarPath ?? '(sin configurar)',
                            ),
                            _diagRow(
                              'Bowthruster V',
                              signalK.bowthrusterV != null
                                  ? '${signalK.bowthrusterV!.toStringAsFixed(2)} V'
                                  : '--',
                              signalK.bowthrusterV != null ? cCyan : cMuted,
                              path: 'electrical.batteries.bowthruster.voltage',
                            ),
                            const SizedBox(height: 12),
                            const Text('TEMPERATURAS', style: lbl),
                            const SizedBox(height: 4),
                            _diagRow(
                              'Nevera 1',
                              signalK.fridge1TempK != null
                                  ? '${(signalK.fridge1TempK! - 273.15).toStringAsFixed(1)} °C'
                                  : '--',
                              signalK.fridge1TempK != null ? cCyan : cMuted,
                              path: sc.fridge1Path ?? '(sin configurar)',
                            ),
                            _diagRow(
                              'Nevera 2',
                              signalK.fridge2TempK != null
                                  ? '${(signalK.fridge2TempK! - 273.15).toStringAsFixed(1)} °C'
                                  : '--',
                              signalK.fridge2TempK != null ? cCyan : cMuted,
                              path: sc.fridge2Path ?? '(sin configurar)',
                            ),
                            _diagRow(
                              'Bowthruster',
                              signalK.bowthrusterTempK != null
                                  ? '${(signalK.bowthrusterTempK! - 273.15).toStringAsFixed(1)} °C'
                                  : '--',
                              signalK.bowthrusterTempK != null ? cCyan : cMuted,
                              path: 'electrical.batteries.bowthruster.temperature',
                            ),
                            const SizedBox(height: 12),
                            const Text('TANQUES', style: lbl),
                            const SizedBox(height: 4),
                            for (final t in sc.tanks.where((t) => t.enabled))
                              InkWell(
                                onTap: () => _showRawSkNode(
                                  context,
                                  'tanks.${t.type}.${t.id}',
                                ),
                                child: _diagRow(
                                  t.groupLabel,
                                  signalK.tanks[t.tankKey] != null
                                      ? '${signalK.tanks[t.tankKey]!.round()}%'
                                      : '--',
                                  signalK.tanks[t.tankKey] != null
                                      ? cCyan
                                      : cMuted,
                                  path: '${t.skPath}  (toca para ver todo)',
                                ),
                              ),
                            const SizedBox(height: 10),
                            const Divider(color: Color(0xff1e3040), height: 1),
                            const SizedBox(height: 6),
                            Text(
                              kAppVersion,
                              style: const TextStyle(
                                color: cMuted,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Dampening: TWS/AWS 5s · TWA/AWA 3s',
                              style: TextStyle(
                                color: Color(0xff4a6070),
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _diagRow(
    String label,
    String value,
    Color color, {
    String? path,
  }) {
    // A row whose path is a real, in-use one (not the "(sin configurar)"
    // placeholder some rows fall back to) but whose value still reads "--"
    // means something the app actually depends on isn't coming through —
    // that's worth flagging red rather than just muted-gray like an
    // optional/unconfigured sensor that's expected to be empty.
    final missingButUsed =
        value == '--' && path != null && !path.contains('sin configurar');
    final effectiveColor = missingButUsed ? cRed : color;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(color: cMuted, fontSize: 11),
            ),
          ),
          SizedBox(
            width: 76,
            child: Text(
              value,
              style: TextStyle(
                color: effectiveColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (path != null)
            Expanded(
              child: Text(
                path,
                style: const TextStyle(color: cMuted, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  // ─── Zoom dialog (first tap → zoom, tap value → graph) ─────────────────────
  void _showZoom(
    String title,
    String value,
    Color color, {
    String? subtitle,
    List<MetricDef>? graphMetrics,
  }) {
    final hasGraph = graphMetrics != null && graphMetrics.isNotEmpty;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: cBg,
        child: SafeArea(
          child: Stack(
            children: [
              InkWell(
                onTap: hasGraph
                    ? () {
                        Navigator.of(ctx).pop();
                        _showGraph(graphMetrics);
                      }
                    : () => Navigator.of(ctx).pop(),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(width: 72, height: 7, color: color),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: cMuted,
                                fontSize: 30,
                              ),
                            ),
                          ),
                          const SizedBox(width: 48), // room for X button
                        ],
                      ),
                      const Spacer(),
                      Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            value,
                            style: TextStyle(
                              color: color,
                              fontSize: 132,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                      if (subtitle != null)
                        Center(
                          child: Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: cMuted, fontSize: 32),
                          ),
                        ),
                      const Spacer(),
                      if (hasGraph)
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.show_chart,
                                color: color.withValues(alpha: 0.7),
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Toca para ver gráfica',
                                style: TextStyle(
                                  color: cMuted.withValues(alpha: 0.8),
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: cMuted),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Graph (second tap) ─────────────────────────────────────────────────────
  void _showGraph(List<MetricDef> metrics) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => GraphDialog(
          metrics: metrics,
          historySource: settings.historySource,
          influxHost: settings.effectiveInfluxHost,
          influxOrg: settings.influxOrg,
          influxToken: settings.influxToken,
          skHost: settings.host,
          skPort: settings.port,
          skAuthBase64: settings.authBase64,
          bucket: settings.influxBucket,
          archiveBucket: settings.influxArchiveBucket,
          demo: settings.demoMode,
          // "Informe de rendimiento" is wind-performance specific — only
          // _WindTapCard (the VNT screen's cards) offers it.
          settings: null,
        ),
      ),
    );
  }

  // ─── Tank group detail ──────────────────────────────────────────────────────
  void _showTankGroup(TankViewData group) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: InkWell(
            onTap: () => Navigator.of(ctx).pop(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          group.name,
                          style: const TextStyle(
                            color: cText,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, color: cText),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: ListView(
                        shrinkWrap: true,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(top: 24),
                        children: [
                          for (final slot in group.slots)
                            TankCard(
                              name: '${slot.type} ${slot.id}',
                              value: signalK.tanks[slot.tankKey],
                              capacityL: slot.capacityL,
                              color: group.color,
                              icon: group.icon,
                              large: true,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showModelComparison(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => ModelComparisonDialog(
        place: weather.place,
        lat: _weatherLat,
        lon: _weatherLon,
        fetch: fetchModelComparison,
      ),
    );
  }

  Future<void> _pickWeatherLocation(BuildContext context) async {
    final initial = _weatherLat != null && _weatherLon != null
        ? ll.LatLng(_weatherLat!, _weatherLon!)
        : null;
    final result = await showDialog<({double? lat, double? lon})>(
      context: context,
      builder: (_) => _LocationPickerDialog(
        initial: initial,
        isOverridden: _manualWeatherLat != null,
      ),
    );
    if (result == null) return; // cancelled
    setState(() {
      _manualWeatherLat = result.lat;
      _manualWeatherLon = result.lon;
    });
    unawaited(_loadWeather(force: true));
  }

  // ─── Wind panel ─────────────────────────────────────────────────────────────
}

T? elementAtOrNull<T>(List<T> list, int index) =>
    index < 0 || index >= list.length ? null : list[index];
double? _num(dynamic value) => value is num ? value.toDouble() : null;
double? _pct(dynamic value) => _num(value) == null ? null : _num(value)! * 100;
double? _at(Map<String, dynamic> map, String key, int index) {
  final list = map[key];
  if (list is! List || index < 0 || index >= list.length) return null;
  return _num(list[index]);
}

DateTime _epoch(dynamic value) => DateTime.fromMillisecondsSinceEpoch(
  (_num(value) ?? 0).round() * 1000,
  isUtc: true,
);
