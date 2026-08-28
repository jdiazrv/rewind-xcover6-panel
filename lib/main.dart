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
import 'theme.dart';

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
  final _mutedAlarms = <String>{}; // acknowledged-until-it-clears, no auto-unmute
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
        return signalK.tanks.values.any(
          (v) => v != null && v < rule.threshold,
        );
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
      ..sort((a, b) => customAlarmTypeLabel(a).compareTo(customAlarmTypeLabel(b)));
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
                                  if (p.toLowerCase().endsWith('.temperature') &&
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
                            thresholdController.text.trim().replaceAll(',', '.'),
                          );
                          if (threshold == null) return;
                          Navigator.of(ctx).pop(
                            CustomAlarmRule(
                              id: DateTime.now().millisecondsSinceEpoch.toString(),
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
  final _depthTrend = _DepthTrendTracker();

  @override
  void initState() {
    super.initState();
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
    settings.navGridColumns = prefs.getInt('navGridColumns') ?? settings.navGridColumns;
    settings.aisCpaMaxNm = prefs.getDouble('aisCpaMaxNm') ?? settings.aisCpaMaxNm;
    settings.aisTcpaMaxMin =
        prefs.getDouble('aisTcpaMaxMin') ?? settings.aisTcpaMaxMin;
    settings.alarmCorrederaEnabled =
        prefs.getBool('alarmCorrederaEnabled') ?? settings.alarmCorrederaEnabled;
    settings.alarmCorrederaSound =
        prefs.getBool('alarmCorrederaSound') ?? settings.alarmCorrederaSound;
    settings.alarmsUseSkZones =
        prefs.getBool('alarmsUseSkZones') ?? settings.alarmsUseSkZones;
    final skZoneJson = prefs.getString('skZoneAlarmsJson');
    if (skZoneJson != null) {
      try {
        final map = jsonDecode(skZoneJson) as Map<String, dynamic>;
        settings.skZoneAlarms = map.map(
          (k, v) => MapEntry(k, SkZoneAlarmSetting.fromJson(v as Map<String, dynamic>)),
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
    await prefs.setInt('navGridColumns', settings.navGridColumns);
    await prefs.setDouble('aisCpaMaxNm', settings.aisCpaMaxNm);
    await prefs.setDouble('aisTcpaMaxMin', settings.aisTcpaMaxMin);
    await prefs.setBool('alarmCorrederaEnabled', settings.alarmCorrederaEnabled);
    await prefs.setBool('alarmCorrederaSound', settings.alarmCorrederaSound);
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
    for (final t in c.tanks.where((t) => t.enabled)) {
      h[t.skPath] = (v) => signalK.tanks[t.tankKey] = _pct(v);
    }
    _dynamicHandlers = h;
  }

  void _connectSignalK() {
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
  bool get _navWantsAis => settings.navCardIds.contains('ais');

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

  Future<void> _loadWeather({bool force = false}) async {
    if (loadingWeather) return;
    // Reuse the last successful fetch (possibly restored from disk on a fresh
    // app launch) if it's under 30 min old — avoids re-hitting Open-Meteo's
    // rate limit every time the app restarts.
    if (!force && weather.updated != null && weather.error == null) {
      if (DateTime.now().difference(weather.updated!).inMinutes < 30) return;
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
    if (current != null) out.add(_marineFromMap(current));
    final base = out.isEmpty ? DateTime.now().toUtc() : out.first.time;
    for (final hours in [24, 48]) {
      final idx = _closestIndex(times, base.add(Duration(hours: hours)));
      if (idx >= 0 && hourly != null) out.add(_marineFromHourly(hourly, idx));
    }
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
    _demoTimer?.cancel();
    _staleWatchdog?.cancel();
    _phoneHeelTracker?.stop();
    channel?.sink.close();
    _pageController.dispose();
    _hostController?.dispose();
    _portController?.dispose();
    _authController?.dispose();
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = math.max(320.0, constraints.maxHeight);
        return Scrollbar(
          thumbVisibility: true,
          child: ListView(
            key: const PageStorageKey<String>('nav-scroll'),
            primary: false,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              SizedBox(
                height: pageHeight,
                child: _grid3x2(
                  columns: settings.navGridColumns,
                  children: [
                    for (var i = 0; i < selected.length; i++)
                      _navMetricCard(selected[i], i),
                  ],
                ),
              ),
              if (remaining.isNotEmpty)
                SizedBox(
                  height: pageHeight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: remaining.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.45,
                          ),
                      itemBuilder: (context, i) => _navMetricCard(
                        remaining[i],
                        selectedIds.length + i,
                        selectable: false,
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
          value: signalK.gnssSatellites?.toString() ?? (positionFresh ? 'OK' : '--'),
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
        final cpaCritical = (closest?.cpaNm ?? double.infinity) < _cpaCriticalNm;
        final cpaStr = closest?.cpaNm != null
            ? '${closest!.cpaNm!.toStringAsFixed(1)} NM'
            : '--';
        final tcpaStr = closest?.tcpaMin != null
            ? '${closest!.tcpaMin!.round()} min'
            : '--';
        // "Sin AIS" should mean exactly that — no targets at all — not "no
        // target happens to have a crossing predicted right now", which is
        // the far more common case out at sea and reads as broken/no-data.
        final subtitle = closest != null
            ? [
                _aisTargetName(closest.target),
                if (closest.distNm != null) '${closest.distNm!.toStringAsFixed(1)}NM',
                if (closest.bearingDeg != null) '${closest.bearingDeg!.round()}°',
              ].join(' · ')
            : (_aisTargets.isEmpty ? 'Sin AIS' : 'Sin cruce previsto');
        return NavCardData(
          id: id,
          title: 'AIS',
          value: cpaStr,
          bigLines: ['TCPA $tcpaStr', 'CPA $cpaStr'],
          subtitle: subtitle,
          color: closest == null
              ? cMuted
              : (cpaCritical ? cRed : cOrange),
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
        positionFresh
            ? posLines(signalK.latitude, signalK.longitude)
            : '--',
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

      if (ownLat != null && ownLon != null && target.lat != null && target.lon != null) {
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

      if (cpaNm == null && tcpaMin == null) continue;
      // A target 40 minutes out at its current CPA isn't a collision risk
      // yet — don't let it steal the "closest approach" slot from something
      // that's actually about to happen. Both thresholds are user-configurable
      // (CFG → Pantalla → AIS).
      if (tcpaMin != null && tcpaMin > settings.aisTcpaMaxMin) continue;
      // A target that will pass 6 NM off isn't "the" closest approach either,
      // even if it happens to be the only one with a computed CPA right now.
      if (cpaNm != null && cpaNm > settings.aisCpaMaxNm) continue;
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

  Widget _powerPage() => _grid3x2(
    children: [
      MetricCard(
        title: 'Batería',
        value: fmt(signalK.houseSoc, 0, ''),
        unit: '%',
        subtitle:
            '${fmt(signalK.houseV, 2, ' V')}  ${signalK.houseA != null ? (signalK.houseA! >= 0 ? '+' : '') : ''}${fmt(signalK.houseA, 1, ' A')}',
        color: socColor(signalK.houseSoc),
        zoom: _showZoom,
        graphMetrics: [_mHouseSoc, _mHouseCurrent, _mHouseVoltage],
      ),
      MetricCard(
        title: 'Solar',
        value: fmt(signalK.solarW, 0, ''),
        unit: 'W',
        color: cYellow,
        zoom: _showZoom,
        graphMetrics: _mSolar == null ? null : [_mSolar!],
      ),
      MetricCard(
        title: 'DC Loads',
        value: fmt(signalK.dcW, 0, ''),
        unit: 'W',
        color: cOrange,
        zoom: _showZoom,
        graphMetrics: const [mDcLoads],
      ),
      MetricCard(
        title: 'Corriente',
        value: fmt(signalK.houseA, 1, ''),
        unit: 'A',
        color: currentColor(signalK.houseA),
        zoom: _showZoom,
        graphMetrics: [_mHouseCurrent],
      ),
      MetricCard(
        title: 'Start',
        value: fmt(signalK.startV, 2, ''),
        unit: 'V',
        color: voltageColor12V(signalK.startV),
        zoom: _showZoom,
        graphMetrics: [_mStartV],
      ),
      MetricCard(
        title: 'Bowthruster',
        value: fmt(signalK.bowthrusterV, 2, ''),
        unit: 'V',
        color: voltageColor12V(signalK.bowthrusterV),
        zoom: _showZoom,
        graphMetrics: const [mBowV],
      ),
    ],
  );

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
                    onTap: t.slots.length > 1 ? () => _showTankGroup(t) : null,
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
    return _grid3x2(
      children: [
        MetricCard(
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
        MetricCard(
          title: 'Presión',
          value: fmt(signalK.outsidePressureHpa, 0, ''),
          unit: 'hPa',
          color: cPurple,
          zoom: _showZoom,
          graphMetrics: const [mPressure],
        ),
        MetricCard(
          title: 'TWS',
          value: fmt(_freshWind(_dTws), 0, ''),
          unit: 'kt',
          subtitle: dir(_freshWind(_dTwd)),
          color: windColor(_freshWind(_dTws)),
          zoom: _showZoom,
          graphMetrics: const [mTws],
        ),
        MetricCard(
          title: 'T. interior',
          value: tempNum(signalK.indoorTempK),
          unit: '°C',
          subtitle: signalK.indoorHumidity != null
              ? 'HR ${fmt(signalK.indoorHumidity, 0, '%')}'
              : null,
          color: cCyan,
          zoom: _showZoom,
        ),
        MetricCard(
          title: 'Lugar',
          value: forecast != null ? fmt(forecast.tempC, 0, '') : '--',
          unit: '°C',
          subtitle: weather.error ?? weather.place,
          color: weather.error != null ? cOrange : cYellow,
          zoom: _showZoom,
        ),
        MetricCard(
          title: 'Viento modelo',
          value: fmt(forecast?.windKn, 0, ''),
          unit: 'kt',
          subtitle: forecast != null ? dir(forecast.windDirDeg) : null,
          color: windColor(forecast?.windKn),
          zoom: _showZoom,
        ),
      ],
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

  // ─── Marine page (unchanged) ────────────────────────────────────────────────
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

  // Fixed height instead of _grid3x2's full-page Expanded stretch — these
  // cards don't need (or look good at) the whole screen's height just
  // because there are only 3 of them in one row. PageView gives each page
  // *tight* (exact-size) constraints, so a plain SizedBox alone can't
  // shrink below that — Align (loose constraints for its child) is what
  // actually lets the fixed height take effect instead of being
  // overridden back up to the full page height.
  Widget _marinePage() => weather.marine.isEmpty
      ? _weatherEmptyState('MAR')
      : Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              height: 260,
              width: double.infinity,
              child: Row(
                children: [
                  for (var i = 0; i < weather.marine.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: MarineCard(
                        title: _marineDate(weather.marine[i].time),
                        point: weather.marine[i],
                        zoom: _showZoom,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
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
    final bucketController = _bucketController ??= TextEditingController(
      text: settings.influxBucket,
    );
    final influxHostController = _influxHostController ??= TextEditingController(
      text: settings.influxHost,
    );
    final influxOrgController = _influxOrgController ??= TextEditingController(
      text: settings.influxOrg,
    );
    final influxTokenController = _influxTokenController ??= TextEditingController(
      text: settings.influxToken,
    );
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
                              label: Text('Tema claro'),
                              icon: Icon(Icons.wb_sunny_outlined, size: 14),
                            ),
                            ButtonSegment(
                              value: 'auto',
                              label: Text('Auto (dispositivo)'),
                              icon: Icon(Icons.brightness_auto, size: 14),
                            ),
                            ButtonSegment(
                              value: 'noche',
                              label: Text('Tema oscuro'),
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
                          'PANTALLA NAV',
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
                            ButtonSegment(value: 3, label: Text('3×2 (6 cartas)')),
                            ButtonSegment(value: 4, label: Text('4×2 (8 cartas)')),
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
                                  setSt(() => settings.skZoneAlarms[path] = next);
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
                        const Text('AIS — UMBRALES', style: lbl),
                        gap,
                        _ThresholdRow(
                          label: 'CPA máximo relevante',
                          unit: 'NM',
                          value: settings.aisCpaMaxNm,
                          onChanged: (v) {
                            setSt(() => settings.aisCpaMaxNm = v);
                            setState(() {});
                            unawaited(_saveSettings());
                          },
                        ),
                        _ThresholdRow(
                          label: 'TCPA máximo relevante',
                          unit: 'min',
                          value: settings.aisTcpaMaxMin,
                          onChanged: (v) {
                            setSt(() => settings.aisTcpaMaxMin = v);
                            setState(() {});
                            unawaited(_saveSettings());
                          },
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Text('ALARMAS PERSONALIZADAS', style: lbl),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline, color: cCyan),
                              onPressed: () async {
                                final rule = await _showAddCustomAlarmDialog(context);
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
                              'COG',
                              signalK.cogTrueDeg != null
                                  ? '${signalK.cogTrueDeg!.round()}°'
                                  : '--',
                              signalK.cogTrueDeg != null ? cText : cMuted,
                              path: 'navigation.courseOverGroundTrue',
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
                                final v = (twaForVmg != null &&
                                        speedForVmg != null)
                                    ? speedForVmg *
                                          math.cos(
                                            twaForVmg * math.pi / 180,
                                          )
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
                              path:
                                  'navigation.course.calcValues.velocityMadeGood',
                            ),
                            _diagRow(
                              'GNSS sats',
                              signalK.gnssSatellites?.toString() ?? '--',
                              signalK.gnssSatellites != null
                                  ? cGreen
                                  : cMuted,
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
                              signalK.bowthrusterTempK != null
                                  ? cCyan
                                  : cMuted,
                              path:
                                  'electrical.batteries.bowthruster.temperature',
                            ),
                            const SizedBox(height: 12),
                            const Text('TANQUES', style: lbl),
                            const SizedBox(height: 4),
                            for (final t in sc.tanks.where((t) => t.enabled))
                              _diagRow(
                                t.groupLabel,
                                signalK.tanks[t.tankKey] != null
                                    ? '${signalK.tanks[t.tankKey]!.round()}%'
                                    : '--',
                                signalK.tanks[t.tankKey] != null
                                    ? cCyan
                                    : cMuted,
                                path: t.skPath,
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
  }) => Padding(
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
              color: color,
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

  bool _showAllPaths = false;

  static final RegExp _fridgePathRe = RegExp(
    r'^environment\.(\w*fridge\w*)\.temperature$',
    caseSensitive: false,
  );
  static final RegExp _tankPathRe = RegExp(
    r'^tanks\.[^.]+\.[^.]+\.currentLevel$',
  );
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
        path == _cfg.depthPath) {
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

// ─── Host preset chip ─────────────────────────────────────────────────────────
class _HostPresetChip extends StatelessWidget {
  const _HostPresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? cCyan : cPanel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? cCyan : const Color(0xff303030),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? cBg : cMuted,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? cBg : cText,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Collapsed header bar (web only) ──────────────────────────────────────────
// Replaces the floating reveal-handle overlay on web: that overlay sits on
// top of the WebView's <iframe> (MAP/ANC), and taps landing on an iframe's
// rectangle are delivered straight to the iframe's own document by the
// browser, never reaching Flutter's canvas — so the handle never registers
// a tap there. This bar takes real space in the Column layout instead,
// pushing the WebView down so the tap target never overlaps the iframe.
class _CollapsedHeaderBar extends StatelessWidget {
  const _CollapsedHeaderBar({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    width: double.infinity,
    color: cBg,
    alignment: Alignment.topCenter,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 0) onTap();
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
  );
}

// ─── Header ───────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({
    required this.pages,
    required this.selected,
    required this.status,
    required this.ok,
    required this.onSelect,
    this.alarmPageIds = const {},
    this.alarmCount = 0,
    this.onBellTap,
  });
  final List<(String, IconData, Widget)> pages;
  final int selected;
  final String status;
  final bool ok;
  final ValueChanged<int> onSelect;
  final Set<String> alarmPageIds;
  final int alarmCount;
  final VoidCallback? onBellTap;

  Widget _tab(int i) {
    final active = selected == i;
    final alarming = alarmPageIds.contains(pages[i].$1);
    final color = alarming ? cRed : (active ? cCyan : cMuted);
    return GestureDetector(
      onTap: () => onSelect(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: active
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: alarming ? cRed : cCyan, width: 3),
                ),
              )
            : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(pages[i].$2, size: 18, color: color),
            const SizedBox(height: 2),
            Text(
              pages[i].$1,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: active || alarming
                    ? FontWeight.w800
                    : FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      color: const Color(0xff0e1a21),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [for (var i = 0; i < pages.length; i++) _tab(i)],
            ),
          ),
          if (kIsWeb) const _FullscreenButton(),
          if (kIsWeb) const SizedBox(width: 8),
          if (alarmCount > 0) ...[
            GestureDetector(
              onTap: onBellTap,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_active, color: cRed),
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: const BoxDecoration(
                        color: cRed,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 16,
                        minHeight: 16,
                      ),
                      child: Text(
                        '$alarmCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
          Icon(ok ? Icons.link : Icons.link_off, color: ok ? cGreen : cOrange),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(
              color: ok ? cGreen : cOrange,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }
}

class _FullscreenButton extends StatefulWidget {
  const _FullscreenButton();

  @override
  State<_FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<_FullscreenButton> {
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _active = app_fullscreen.fullscreenActive;
  }

  Future<void> _toggle() async {
    await app_fullscreen.toggleFullscreen();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (mounted) setState(() => _active = app_fullscreen.fullscreenActive);
  }

  @override
  Widget build(BuildContext context) {
    if (!app_fullscreen.fullscreenSupported) return const SizedBox.shrink();
    return Tooltip(
      message: _active ? 'Salir de pantalla completa' : 'Pantalla completa',
      child: IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        onPressed: _toggle,
        icon: Icon(
          _active ? Icons.fullscreen_exit : Icons.fullscreen,
          color: cMuted,
        ),
      ),
    );
  }
}

// ─── Attitude gauge (escora/cabeceo) — mimics a boat's plastic dual-scale
// clinometer: a fine arc on top, a coarse arc below, each with a bead that
// slides along it to the current reading ──────────────────────────────────
// Live-updating dialog (ticks every 300ms) so the gauges track the boat's
// motion in real time while open — this gets checked constantly underway,
// so the "Calibrar" button lives here rather than buried in CFG.
class _AttitudeGaugesDialog extends StatefulWidget {
  const _AttitudeGaugesDialog({
    required this.signalK,
    required this.settings,
    required this.onSettingsChanged,
    required this.onCalibrate,
  });
  final SignalKModel signalK;
  final SettingsModel settings;
  final VoidCallback onSettingsChanged;
  final void Function(BuildContext) onCalibrate;

  @override
  State<_AttitudeGaugesDialog> createState() => _AttitudeGaugesDialogState();
}

class _AttitudeGaugesDialogState extends State<_AttitudeGaugesDialog> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final showCalibration = !kIsWeb && s.usePhoneHeel;
    // Wide, side-by-side layout (gauges left, calibration right) instead of
    // stacking everything in one column — that used to overflow a compact
    // screen's dialog height and need a scroll with no visible hint that
    // there was more below "Cerrar".
    final maxW = MediaQuery.of(context).size.width - 48;
    return AlertDialog(
      backgroundColor: cPanel,
      title: const Text('Escora y cabeceo', style: TextStyle(color: cText)),
      content: SizedBox(
        width: math.min(showCalibration ? 640 : 340, maxW),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AttitudeGauge(
                    label: 'ESCORA',
                    valueDeg: widget.signalK.heelDeg,
                    fineRange: 5,
                    coarseRange: 45,
                    positiveLabel: 'E',
                    negativeLabel: 'B',
                  ),
                  const SizedBox(height: 18),
                  AttitudeGauge(
                    label: 'CABECEO',
                    valueDeg: widget.signalK.pitchDeg,
                    fineRange: 5,
                    coarseRange: 30,
                    positiveLabel: 'PROA ARRIBA',
                    negativeLabel: 'PROA ABAJO',
                  ),
                ],
              ),
            ),
            if (showCalibration) ...[
              const SizedBox(width: 16),
              const VerticalDivider(color: cPanel2, width: 1),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          s.phoneAttitudeCalibrated
                              ? Icons.check_circle
                              : Icons.error_outline,
                          color: s.phoneAttitudeCalibrated ? cGreen : cOrange,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.phoneAttitudeCalibrated
                                ? 'Calibrado para esta posición del dispositivo'
                                : 'Sin calibrar — el dispositivo puede estar montado en cualquier posición; calibra antes de fiarte de la lectura',
                            style: TextStyle(
                              color: s.phoneAttitudeCalibrated
                                  ? cMuted
                                  : cOrange,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(
                        s.phoneAttitudeCalibrated
                            ? 'Recalibrar (2 pasos)'
                            : 'Calibrar (2 pasos)',
                      ),
                      onPressed: () => widget.onCalibrate(context),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Necesario si el dispositivo cambia de sitio o de orientación en el barco.',
                      style: TextStyle(color: cMuted, fontSize: 11),
                    ),
                    if (s.phoneAttitudeCalibrated) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Checkbox(
                            value: s.phoneAttitudeInvertRoll,
                            onChanged: (v) {
                              setState(
                                () => s.phoneAttitudeInvertRoll = v ?? false,
                              );
                              widget.onSettingsChanged();
                            },
                          ),
                          const Expanded(
                            child: Text(
                              'Invertir E/B (si la escora sale al revés)',
                              style: TextStyle(color: cMuted, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

// ─── 2-point attitude calibration wizard ──────────────────────────────────
// Gravity alone, from a single level reading, only fixes 2 of the 3 degrees
// of freedom of the device's mounting orientation — rotation about the
// down axis (i.e. which way the device is "facing") is left undetermined,
// which is exactly the ambiguity a fixed "pick X or Y axis" UI could never
// resolve for an arbitrarily-mounted tablet. Step 2 fixes it one of two
// ways, chosen on screen: comparing the device's own tilt-compensated
// compass heading against Signal K's boat heading (needs a fresh heading,
// no maneuvering — but a phone's magnetometer can be biased), or comparing
// the lateral acceleration felt during a real turn against how much Signal
// K says the boat's heading actually changed (no magnetometer, but needs
// an actual turn under way — can't be faked by hand at a dock).
class _AttitudeCalibrationWizard extends StatefulWidget {
  const _AttitudeCalibrationWizard({
    required this.getBoatHeadingDeg,
    required this.onDone,
  });
  final double? Function() getBoatHeadingDeg;
  final void Function(AttitudeCalibration calibration, double detailDeg) onDone;

  @override
  State<_AttitudeCalibrationWizard> createState() =>
      _AttitudeCalibrationWizardState();
}

class _AttitudeCalibrationWizardState
    extends State<_AttitudeCalibrationWizard> {
  String? _method; // null = not chosen yet, 'heading' or 'turn'
  int _step = 0; // 0 = level; then method-specific (see _capture)
  bool _capturing = false;
  String? _error;
  String? _warning;
  Vec3? _downVec;
  Vec3 _magBias = const Vec3(0, 0, 0);

  String get _noHeadingError =>
      'No hay rumbo de Signal K reciente (menos de 8s) — comprueba que el barco/piloto automático estén conectados y enviando rumbo antes de este paso.';

  bool get _needsHeadingNow =>
      (_method == 'turn' && _step == 1) || (_method == 'heading' && _step == 2);

  Future<void> _capture() async {
    if (_needsHeadingNow && widget.getBoatHeadingDeg() == null) {
      setState(() => _error = _noHeadingError);
      return;
    }
    setState(() {
      _capturing = true;
      _error = null;
      _warning = null;
    });
    if (_step == 0) {
      final v = await captureAveragedGravity(
        duration: const Duration(seconds: 3),
      );
      if (!mounted) return;
      _downVec = v;
      setState(() {
        _capturing = false;
        _step = 1;
      });
      return;
    }
    if (_method == 'turn') {
      await _captureTurn();
      return;
    }
    if (_step == 1) {
      final bias = await captureMagBias(duration: const Duration(seconds: 12));
      if (!mounted) return;
      _magBias = bias;
      setState(() {
        _capturing = false;
        _step = 2;
      });
      return;
    }
    await _captureHeading();
  }

  Future<void> _captureHeading() async {
    final sample = await captureAccelAndMag(
      duration: const Duration(seconds: 10),
    );
    final boatHeading = widget.getBoatHeadingDeg();
    if (!mounted) return;
    if (boatHeading == null) {
      setState(() {
        _capturing = false;
        _error = 'Se perdió el rumbo de Signal K durante la captura — vuelve a intentarlo.';
      });
      return;
    }
    final correctedMag = sample.mag - _magBias;
    // Earth's field is roughly 25-65 µT; well outside that range usually
    // means magnetic interference (engine, speakers, metal mount) skewing
    // the reading — not blocked, since real thresholds are hard to know
    // without in-the-field data, but flagged so a bad calibration doesn't
    // look silently trustworthy.
    final magMagnitude = correctedMag.length;
    if (magMagnitude < 15 || magMagnitude > 120) {
      _warning =
          'El magnetómetro dio una lectura ${magMagnitude.toStringAsFixed(0)} µT tras corregir el sesgo, fuera de lo normal — puede haber interferencia magnética cerca (motor, altavoces, metal). Si la escora sale rara, aleja el dispositivo de esas fuentes y recalibra.';
    }
    final down = _downVec!;
    final right = down.cross(
      forwardFromHeading(down, correctedMag, boatHeading),
    );
    Navigator.of(context).pop();
    widget.onDone(AttitudeCalibration(down: down, right: right), boatHeading);
  }

  Future<void> _captureTurn() async {
    final startHeading = widget.getBoatHeadingDeg()!;
    final avgAccel = await captureAveragedAccel(
      duration: const Duration(seconds: 6),
    );
    final endHeading = widget.getBoatHeadingDeg();
    if (!mounted) return;
    if (endHeading == null) {
      setState(() {
        _capturing = false;
        _error = 'Se perdió el rumbo de Signal K durante la captura — vuelve a intentarlo.';
      });
      return;
    }
    var turnDeg = endHeading - startHeading;
    while (turnDeg > 180) {
      turnDeg -= 360;
    }
    while (turnDeg < -180) {
      turnDeg += 360;
    }
    if (turnDeg.abs() < 20) {
      setState(() {
        _capturing = false;
        _error =
            'El barco solo giró ${turnDeg.abs().toStringAsFixed(0)}° — vira al menos 20-30° sin parar, siempre hacia el mismo lado, y vuelve a intentarlo.';
      });
      return;
    }
    final down = _downVec!;
    final lateral = avgAccel - down * avgAccel.dot(down);
    if (lateral.length < 0.15) {
      setState(() {
        _capturing = false;
        _error = 'No se detectó suficiente aceleración lateral del viraje — prueba un giro más cerrado o más rápido.';
      });
      return;
    }
    // The accelerometer measures specific force, which points *outward*
    // from the turn's center — opposite to the turn direction (the same
    // reason you feel pushed toward the outside of a turn). Turning to
    // starboard (heading increasing) means the reading points to port, so
    // starboard is the opposite direction.
    final outward = lateral.normalized;
    final right = turnDeg > 0 ? outward * -1 : outward;
    Navigator.of(context).pop();
    widget.onDone(AttitudeCalibration(down: down, right: right), turnDeg);
  }

  @override
  Widget build(BuildContext context) {
    if (_method == null) return _buildMethodChooser();
    final totalSteps = _method == 'turn' ? 2 : 3;
    String title;
    String instructions;
    if (_step == 0) {
      title = 'Paso 1 de $totalSteps — Nivelado';
      instructions = 'Con el barco lo más nivelado posible (amarrado o en calma), pulsa Capturar y no muevas el dispositivo durante 3 segundos.';
    } else if (_method == 'turn') {
      title = 'Paso 2 de $totalSteps — Viraje';
      instructions = 'Navegando, pulsa Capturar y luego haz un viraje sostenido de al menos 20-30° (siempre hacia el mismo lado, sin parar) durante los 6 segundos siguientes. No hace falta escorar el barco a propósito.';
    } else if (_step == 1) {
      title = 'Paso 2 de $totalSteps — Calibrar brújula';
      instructions = 'El magnetómetro del dispositivo necesita esto antes de fiarse de él (como al calibrar la brújula del móvil). Pulsa Capturar y mueve el dispositivo libremente en el aire, dibujando un 8, durante 12 segundos. No hace falta estar en el barco para este paso.';
    } else {
      title = 'Paso 3 de $totalSteps — Rumbo estable';
      instructions = 'Navegando en línea recta con rumbo estable (sin virar), pulsa Capturar y no muevas el dispositivo durante 10 segundos. No hace falta escorar el barco.';
    }
    return AlertDialog(
      backgroundColor: cPanel,
      title: Text(title, style: const TextStyle(color: cText, fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              instructions,
              style: const TextStyle(color: cMuted, fontSize: 13),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: cRed, fontSize: 12)),
            ],
            if (_warning != null) ...[
              const SizedBox(height: 10),
              Text(
                _warning!,
                style: const TextStyle(color: cOrange, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Center(
              child: _capturing
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: CircularProgressIndicator(color: cCyan),
                    )
                  : FilledButton(
                      onPressed: _capture,
                      child: Text(
                        _step == 0
                            ? 'Capturar (3 s)'
                            : _method == 'turn'
                            ? 'Capturar (6 s)'
                            : _step == 1
                            ? 'Capturar (12 s)'
                            : 'Capturar (10 s)',
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _capturing
              ? null
              : () {
                  if (_step >= 1) {
                    setState(() {
                      _step = 0;
                      _method = null;
                      _error = null;
                      _warning = null;
                    });
                  } else {
                    Navigator.of(context).pop();
                  }
                },
          child: Text(_step >= 1 ? 'Cambiar método' : 'Cancelar'),
        ),
      ],
    );
  }

  Widget _buildMethodChooser() {
    Widget methodCard({
      required String method,
      required String title,
      required String description,
    }) => InkWell(
      onTap: () => setState(() => _method = method),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: cPanel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cPanel2, width: 1.4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: cCyan,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: const TextStyle(color: cMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
    return AlertDialog(
      backgroundColor: cPanel,
      title: const Text(
        'Elige cómo calibrar',
        style: TextStyle(color: cText, fontSize: 16),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            methodCard(
              method: 'heading',
              title: 'Rumbo estable (recomendado)',
              description: 'Calibra la brújula del dispositivo (muévelo en el aire 12 s) y luego navega en línea recta 10 s. Puede fallar igualmente si hay mucha interferencia magnética cerca (motor, altavoces).',
            ),
            methodCard(
              method: 'turn',
              title: 'Viraje real',
              description: 'Haz un viraje de 20-30° mientras navegas. No usa la brújula del dispositivo, pero solo funciona con el barco moviéndose de verdad — no se puede simular en el muelle.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

class AttitudeGauge extends StatelessWidget {
  const AttitudeGauge({
    super.key,
    required this.label,
    required this.valueDeg,
    required this.fineRange,
    required this.coarseRange,
    required this.positiveLabel,
    required this.negativeLabel,
  });
  final String label;
  final double? valueDeg;
  final double fineRange;
  final double coarseRange;
  final String positiveLabel;
  final String negativeLabel;

  @override
  Widget build(BuildContext context) {
    final v = valueDeg;
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: cMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          v != null ? '${v.abs().toStringAsFixed(1)}°' : '--°',
          style: TextStyle(
            color: v == null ? cMuted : (v >= 0 ? cGreen : cRed),
            fontSize: 44,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        Text(
          v != null ? (v >= 0 ? positiveLabel : negativeLabel) : '',
          style: const TextStyle(
            color: cMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 128,
          width: double.infinity,
          child: CustomPaint(
            painter: _DualArcPainter(
              valueDeg: v,
              fineRange: fineRange,
              coarseRange: coarseRange,
            ),
          ),
        ),
      ],
    );
  }
}

class _DualArcPainter extends CustomPainter {
  _DualArcPainter({
    required this.valueDeg,
    required this.fineRange,
    required this.coarseRange,
  });
  final double? valueDeg;
  final double fineRange;
  final double coarseRange;

  Offset _pointAt(Size size, double top, double curveDepth, double t) {
    final halfW = size.width / 2 - 22;
    final x = size.width / 2 + t * halfW;
    final y = top + curveDepth * (1 - t * t);
    return Offset(x, y);
  }

  void _drawArc(
    Canvas canvas,
    Size size,
    double top,
    double curveDepth,
    double range,
    double majorStep,
    double minorStep,
  ) {
    Offset point(double t) => _pointAt(size, top, curveDepth, t);

    // The channel itself, as a stroked path following the curve — shaded to
    // read as a concave groove (dark at the rim, lit in the middle) rather
    // than a raised bar, so the bead can look like it's resting inside it.
    final tubePath = Path();
    const steps = 60;
    for (var i = 0; i <= steps; i++) {
      final t = -1.0 + 2.0 * i / steps;
      final p = point(t);
      if (i == 0) {
        tubePath.moveTo(p.dx, p.dy);
      } else {
        tubePath.lineTo(p.dx, p.dy);
      }
    }
    final tubeBounds = tubePath.getBounds();
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xff1c262b),
    );
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(tubeBounds.center.dx, tubeBounds.top),
          Offset(tubeBounds.center.dx, tubeBounds.bottom + 8),
          [
            const Color(0xff35464e),
            const Color(0xff5c7079),
            const Color(0xff2c3b42),
          ],
          [0.0, 0.55, 1.0],
        ),
    );

    // Ticks + labels, minor step first so major ticks/labels paint on top.
    for (var deg = -range; deg <= range + 0.001; deg += minorStep) {
      final isMajor =
          (deg / majorStep - (deg / majorStep).round()).abs() < 1e-6;
      final t = (deg / range).clamp(-1.0, 1.0);
      final p = point(t);
      final p1 = point((t - 0.01).clamp(-1.0, 1.0));
      final p2 = point((t + 0.01).clamp(-1.0, 1.0));
      final tangent = p2 - p1;
      final tangentLen = tangent.distance;
      final normal = tangentLen == 0
          ? const Offset(0, 1)
          : Offset(-tangent.dy, tangent.dx) / tangentLen;
      final tickLen = isMajor ? 9.0 : 5.0;
      final tickEnd = p + normal * tickLen;
      canvas.drawLine(
        p,
        tickEnd,
        Paint()
          ..color = (isMajor ? cText : cMuted).withValues(
            alpha: isMajor ? 0.85 : 0.5,
          )
          ..strokeWidth = isMajor ? 1.6 : 1.0,
      );
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(
            text: deg.abs().round().toString(),
            style: const TextStyle(
              color: cMuted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final labelPos = p + normal * (tickLen + 3);
        tp.paint(canvas, Offset(labelPos.dx - tp.width / 2, labelPos.dy));
      }
    }

    // Bead marking the current reading, clamped to the ends of the scale —
    // drawn to sit *inside* the channel (small contact shadow rather than a
    // floating drop shadow, glossy radial fill) with the channel's near rim
    // re-stroked on top so it visually overlaps the bead's upper edge.
    if (valueDeg != null) {
      final t = (valueDeg! / range).clamp(-1.0, 1.0);
      final p = point(t);
      const ballRadius = 5.0;
      canvas.drawOval(
        Rect.fromCenter(
          center: p + const Offset(0, 1.5),
          width: ballRadius * 1.8,
          height: ballRadius * 0.9,
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.4),
      );
      canvas.drawCircle(
        p,
        ballRadius,
        Paint()
          ..shader = ui.Gradient.radial(p + const Offset(-1.6, -1.8), 7, [
            const Color(0xff3a3a3a),
            const Color(0xff0c0c0c),
          ]),
      );
      canvas.drawCircle(
        p + const Offset(-1.4, -1.6),
        1.3,
        Paint()..color = Colors.white.withValues(alpha: 0.55),
      );
      // Re-stroke a thin highlight along the channel's top edge over the
      // bead, so the rim reads as being in front of it (i.e. the bead sits
      // recessed in the groove instead of floating above the surface).
      canvas.drawPath(
        tubePath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.22),
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fineDepth = size.height * 0.22;
    final coarseDepth = size.height * 0.30;
    _drawArc(canvas, size, 6, fineDepth, fineRange, fineRange, 1);
    _drawArc(
      canvas,
      size,
      size.height * 0.56,
      coarseDepth,
      coarseRange,
      coarseRange / 3,
      coarseRange / 9,
    );
  }

  @override
  bool shouldRepaint(covariant _DualArcPainter oldDelegate) =>
      oldDelegate.valueDeg != valueDeg ||
      oldDelegate.fineRange != fineRange ||
      oldDelegate.coarseRange != coarseRange;
}

// ─── MetricCard ───────────────────────────────────────────────────────────────
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.color,
    this.unit,
    this.subtitle,
    this.zoom,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.onSecondaryTap,
    this.graphMetrics,
    this.trend,
    this.bigLines,
  });

  final String title;
  final String value;
  final String? unit;
  final String? subtitle;
  final Color color;
  final int? trend; // -1 down, 0 flat, 1 up
  final List<String>? bigLines;
  final void Function(
    String title,
    String value,
    Color color, {
    String? subtitle,
    List<MetricDef>? graphMetrics,
  })?
  zoom;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSecondaryTap;
  final List<MetricDef>? graphMetrics;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      onTap:
          onTap ??
          () => zoom?.call(
            title,
            value,
            color,
            subtitle: subtitle,
            graphMetrics: graphMetrics,
          ),
      onLongPress: onLongPress,
      onDoubleTap: onDoubleTap,
      onSecondaryTap: onSecondaryTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                if (unit != null)
                  Text(
                    unit!,
                    style: TextStyle(
                      color: color,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (graphMetrics != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.show_chart,
                    size: 13,
                    color: color.withValues(alpha: 0.5),
                  ),
                ],
                if (trend != null && trend != 0) ...[
                  const SizedBox(width: 4),
                  Icon(
                    trend! > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 15,
                    color: color,
                  ),
                ],
              ],
            ),
            Expanded(
              child: Center(
                child: bigLines != null
                    ? FittedBox(
                        fit: BoxFit.contain,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (final line in bigLines!)
                              Text(
                                line,
                                style: TextStyle(
                                  fontSize: 90,
                                  fontWeight: FontWeight.w900,
                                  color: color,
                                  height: 1.15,
                                ),
                              ),
                          ],
                        ),
                      )
                    : FittedBox(
                        fit: BoxFit.contain,
                        child: Text(
                          value,
                          style: TextStyle(
                            fontSize: 300,
                            fontWeight: FontWeight.w900,
                            color: color,
                            height: 1.0,
                          ),
                        ),
                      ),
              ),
            ),
            if (subtitle != null)
              Center(
                child: Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Graph dialog ─────────────────────────────────────────────────────────────
class GraphDialog extends StatefulWidget {
  const GraphDialog({
    super.key,
    required this.metrics,
    required this.historySource,
    required this.influxHost,
    required this.influxOrg,
    required this.influxToken,
    required this.skHost,
    required this.skPort,
    required this.skAuthBase64,
    this.bucket = influxBucketDefault,
    this.archiveBucket = influxBucketDefault,
    this.demo = false,
  });
  final List<MetricDef> metrics;
  final String historySource; // 'auto' | 'influx' | 'sk'
  final String influxHost;
  final String influxOrg;
  final String influxToken;
  final String skHost;
  final int skPort;
  final String skAuthBase64;
  final String bucket;
  final String archiveBucket;
  final bool demo;

  @override
  State<GraphDialog> createState() => _GraphDialogState();
}

typedef _Range = ({String label, String flux, String agg, bool longRange});
const _ranges = <_Range>[
  (label: '24h', flux: '-24h', agg: '2m', longRange: false),
  (label: '48h', flux: '-48h', agg: '5m', longRange: false),
  (label: '7d', flux: '-7d', agg: '15m', longRange: true),
  (label: '1 mes', flux: '-30d', agg: '1h', longRange: true),
];

// Signal K sources (KIP/SQLite) sample far more densely than InfluxDB's
// aggregated buckets and only retain a short window, so there's no reason
// to downsample as conservatively as the Influx `agg` steps above — use a
// finer resolution per range instead of reusing the Influx one.
const _skAgg = <String, String>{
  '24h': '30s',
  '48h': '1m',
  '7d': '5m',
  '1 mes': '15m',
};

class _GraphDialogState extends State<GraphDialog> {
  int _mIdx = 0;
  int _rIdx = 0;
  List<GraphPoint> _points = [];
  bool _loading = false;
  String? _error;
  bool _usedSk = false;
  // Per-range data availability when the Signal K History API (KIP/SQLite)
  // is in play — null = not checked yet, true/false once known. A short
  // per-series retention (KIP defaults to 24h) means 48h/7d/1mes routinely
  // come back empty, so those range buttons get disabled instead of looking
  // clickable and then silently showing nothing.
  List<bool?> _skRangeAvailable = List.filled(_ranges.length, null);

  MetricDef get _def => widget.metrics[_mIdx];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = _ranges[_rIdx];
      final (pts, usedSk) = widget.demo
          ? (demoGraphSeries(_def, r.flux, r.agg), false)
          : await _queryHistory(r);
      if (!mounted) return;
      setState(() {
        _points = pts;
        _loading = false;
        _usedSk = usedSk;
        _skRangeAvailable[_rIdx] = usedSk ? pts.isNotEmpty : null;
      });
      if (usedSk) unawaited(_checkOtherSkRanges());
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  // After landing on SK/KIP data for the current range, silently probe the
  // other ranges so their buttons can be greyed out up front instead of
  // the user tapping into a range that's always going to come back empty.
  Future<void> _checkOtherSkRanges() async {
    for (var i = 0; i < _ranges.length; i++) {
      if (i == _rIdx || _skRangeAvailable[i] != null) continue;
      try {
        final pts = await _fetchSk(_ranges[i]);
        if (mounted) setState(() => _skRangeAvailable[i] = pts.isNotEmpty);
      } catch (_) {
        if (mounted) setState(() => _skRangeAvailable[i] = false);
      }
    }
  }

  Future<List<GraphPoint>> _fetchInflux(_Range r) => influxQuery(
    host: widget.influxHost,
    org: widget.influxOrg,
    token: widget.influxToken,
    def: _def,
    fluxRange: r.flux,
    aggEvery: r.agg,
    bucket: r.longRange ? widget.archiveBucket : widget.bucket,
  );

  Future<List<GraphPoint>> _fetchSk(_Range r) => skHistoryQuery(
    host: widget.skHost,
    port: widget.skPort,
    authBase64: widget.skAuthBase64,
    def: _def,
    range: parseFluxRange(r.flux),
    resolution: parseAggEvery(_skAgg[r.label] ?? r.agg),
  );

  Future<(List<GraphPoint>, bool)> _queryHistory(_Range r) async {
    switch (widget.historySource) {
      case 'influx':
        return (await _fetchInflux(r), false);
      case 'sk':
        return (await _fetchSk(r), true);
      default: // 'auto' — prefer InfluxDB (richer/longer history), fall back
        // to the Signal K History API (e.g. KIP/SQLite) if it fails.
        try {
          return (await _fetchInflux(r), false);
        } catch (_) {
          return (await _fetchSk(r), true);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: cBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            if (widget.metrics.length > 1) _buildMetricTabs(),
            Expanded(child: _buildBody()),
            if (_points.isNotEmpty) _buildStats(),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: cMuted),
            onPressed: () => Navigator.pop(context),
          ),
          Container(
            width: 44,
            height: 6,
            decoration: BoxDecoration(
              color: _def.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _def.label,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cText,
              ),
            ),
          ),
          // Range buttons — greyed out and untappable once we know (from a
          // Signal K/KIP probe) that range has no data at all for this series.
          for (var i = 0; i < _ranges.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 5),
              child: GestureDetector(
                onTap: _skRangeAvailable[i] == false
                    ? null
                    : () {
                        if (_rIdx != i) {
                          setState(() => _rIdx = i);
                          _fetch();
                        }
                      },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _rIdx == i ? _def.color : cPanel2,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _ranges[i].label,
                    style: TextStyle(
                      color: _skRangeAvailable[i] == false
                          ? const Color(0xff445560)
                          : (_rIdx == i ? cBg : cMuted),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMetricTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          for (var i = 0; i < widget.metrics.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () {
                  if (_mIdx != i) {
                    setState(() {
                      _mIdx = i;
                      _skRangeAvailable = List.filled(_ranges.length, null);
                    });
                    _fetch();
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _mIdx == i ? widget.metrics[i].color : cPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _mIdx == i
                          ? widget.metrics[i].color
                          : const Color(0xff2a3a44),
                    ),
                  ),
                  child: Text(
                    widget.metrics[i].label,
                    style: TextStyle(
                      color: _mIdx == i ? cBg : cText,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _def.color),
            const SizedBox(height: 12),
            Text(
              'Cargando datos…',
              style: TextStyle(color: _def.color.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, color: cOrange, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Error obteniendo histórico',
                style: TextStyle(color: cOrange, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                widget.historySource == 'sk'
                    ? widget.skHost
                    : widget.influxHost,
                style: const TextStyle(color: cMuted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: cRed, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                onPressed: _fetch,
              ),
            ],
          ),
        ),
      );
    }
    // A KIP series with genuinely no data even at 24h isn't a temporary gap —
    // it means this path was never added to a widget in a KIP screen, so
    // KIP never started sampling it at all. Say so instead of "sin datos".
    if (_points.isEmpty && _usedSk && _skRangeAvailable[0] == false) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, color: cMuted, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Sin histórico en KIP para esta serie',
                style: TextStyle(color: cMuted, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Añade "${_def.skPath}" a un widget en alguna pantalla de KIP para que empiece a registrarla.',
                style: const TextStyle(color: cMuted, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_points.isEmpty) {
      return const Center(
        child: Text('Sin datos', style: TextStyle(color: cMuted, fontSize: 24)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: LineGraph(
        points: _points,
        color: _def.color,
        unit: _def.unit,
        windowStart: DateTime.now().subtract(
          parseFluxRange(_ranges[_rIdx].flux),
        ),
        windowEnd: DateTime.now(),
        expectedStepMs: parseAggEvery(
          _usedSk
              ? (_skAgg[_ranges[_rIdx].label] ?? _ranges[_rIdx].agg)
              : _ranges[_rIdx].agg,
        ).inMilliseconds.toDouble(),
      ),
    );
  }

  Widget _buildStats() {
    final values = _points.map((p) => p.value).toList();
    final current = values.last;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final q = math.max(1, values.length ~/ 4);
    final earlySum = values.take(q).fold(0.0, (a, b) => a + b);
    final lateSum = values.skip(values.length - q).fold(0.0, (a, b) => a + b);
    final diff = lateSum / q - earlySum / q;
    final thr = (maxV - minV) * 0.1;
    final trendStr = diff > thr
        ? '↑ Subiendo'
        : diff < -thr
        ? '↓ Bajando'
        : '→ Estable';
    final trendColor = diff > thr
        ? cRed
        : diff < -thr
        ? cGreen
        : cMuted;
    final u = _def.unit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Text(
            trendStr,
            style: TextStyle(
              color: trendColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            '${current.toStringAsFixed(1)} $u',
            style: TextStyle(
              color: _def.color,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Text(
            'Min ${minV.toStringAsFixed(1)}  Max ${maxV.toStringAsFixed(1)} $u',
            style: const TextStyle(color: cMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ─── Line graph ───────────────────────────────────────────────────────────────
class LineGraph extends StatefulWidget {
  const LineGraph({
    super.key,
    required this.points,
    required this.color,
    this.unit = '',
    required this.windowStart,
    required this.windowEnd,
    required this.expectedStepMs,
  });
  final List<GraphPoint> points;
  final Color color;
  final String unit;
  // The x-axis always spans the *requested* range (24h/48h/7d/1 mes), not
  // just however much data actually came back — a sparse history source
  // (e.g. KIP's short retention) used to make the axis silently shrink to
  // fit only the available span, stretching one real day across the full
  // width and making it look like "1 mes" had a month of data.
  final DateTime windowStart;
  final DateTime windowEnd;
  // Gaps between consecutive points bigger than ~1.8x this get drawn as a
  // break in the line instead of a straight connector, so missing data
  // reads as missing rather than a plausible-looking flat/sloped segment.
  final double expectedStepMs;
  @override
  State<LineGraph> createState() => _LineGraphState();
}

class _LineGraphState extends State<LineGraph> {
  GraphPoint? _sel;

  static const _lPad = 52.0, _rPad = 10.0, _tPad = 10.0;

  void _pick(Offset local, Size size) {
    final pL = _lPad, pR = size.width - _rPad;
    if (local.dx < pL || local.dx > pR) return;
    final pts = widget.points;
    if (pts.isEmpty) return;
    final tFirst = widget.windowStart.millisecondsSinceEpoch.toDouble();
    final tLast = widget.windowEnd.millisecondsSinceEpoch.toDouble();
    final t = tFirst + (local.dx - pL) / (pR - pL) * (tLast - tFirst);
    GraphPoint? best;
    var bestD = double.infinity;
    for (final p in pts) {
      final d = (p.time.millisecondsSinceEpoch - t).abs().toDouble();
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    setState(() => _sel = best);
  }

  Widget _tooltip(GraphPoint sel, Size size) {
    final dt = sel.time.toLocal();
    final dateStr =
        '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    final valStr = '${sel.value.toStringAsFixed(1)} ${widget.unit}';
    final tFirst = widget.windowStart.millisecondsSinceEpoch.toDouble();
    final tLast = widget.windowEnd.millisecondsSinceEpoch.toDouble();
    final pL = _lPad, pR = size.width - _rPad;
    final cx =
        pL +
        (sel.time.millisecondsSinceEpoch - tFirst) /
            (tLast - tFirst).clamp(1, double.infinity) *
            (pR - pL);
    const w = 140.0;
    var left = cx - w / 2;
    left = left.clamp(pL, pR - w);
    return Positioned(
      left: left,
      top: _tPad + 4,
      child: IgnorePointer(
        child: Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xff0d1e2c).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.color.withValues(alpha: 0.7),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                dateStr,
                style: const TextStyle(color: cMuted, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                valStr,
                style: TextStyle(
                  color: widget.color,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (ctx, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      return GestureDetector(
        onTapDown: (e) => _pick(e.localPosition, size),
        onPanUpdate: (e) => _pick(e.localPosition, size),
        onTapUp: (_) => setState(() => _sel = null),
        onPanEnd: (_) => setState(() => _sel = null),
        child: Stack(
          children: [
            CustomPaint(
              painter: _LineGraphPainter(
                points: widget.points,
                color: widget.color,
                selected: _sel,
                windowStart: widget.windowStart,
                windowEnd: widget.windowEnd,
                expectedStepMs: widget.expectedStepMs,
              ),
              child: const SizedBox.expand(),
            ),
            if (_sel != null) _tooltip(_sel!, size),
          ],
        ),
      );
    },
  );
}

class _LineGraphPainter extends CustomPainter {
  const _LineGraphPainter({
    required this.points,
    required this.color,
    this.selected,
    required this.windowStart,
    required this.windowEnd,
    required this.expectedStepMs,
  });
  final List<GraphPoint> points;
  final Color color;
  final GraphPoint? selected;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double expectedStepMs;

  static const _lPad = 52.0, _rPad = 10.0, _tPad = 10.0, _bPad = 30.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final pL = _lPad, pR = size.width - _rPad;
    final pT = _tPad, pB = size.height - _bPad;
    final pW = pR - pL, pH = pB - pT;

    // Y scale
    final vals = points.map((p) => p.value).toList();
    var yMin = vals.reduce(math.min), yMax = vals.reduce(math.max);
    final ySpan0 = yMax - yMin;
    final pad = ySpan0 < 0.5 ? 0.5 : ySpan0 * 0.08;
    yMin -= pad;
    yMax += pad;
    final ySpan = yMax - yMin;

    // X scale — always the full requested window, not just the span the
    // returned points happen to cover (see the doc comment on LineGraph).
    final tFirst = windowStart.millisecondsSinceEpoch.toDouble();
    final tLast = windowEnd.millisecondsSinceEpoch.toDouble();
    final tSpan = (tLast - tFirst).clamp(1.0, double.infinity);
    final gapThresholdMs = expectedStepMs * 1.8;

    double toX(double t) => pL + (t - tFirst) / tSpan * pW;
    double toY(double v) => pB - (v - yMin) / ySpan * pH;

    // Nice grid step
    double step;
    final yRange = ySpan;
    if (yRange < 5) {
      step = 1;
    } else if (yRange < 15) {
      step = 2;
    } else if (yRange < 40) {
      step = 5;
    } else if (yRange < 100) {
      step = 10;
    } else if (yRange < 250) {
      step = 25;
    } else if (yRange < 500) {
      step = 50;
    } else {
      step = 100;
    }

    final gridPaint = Paint()
      ..color = const Color(0xff1a2c38)
      ..strokeWidth = 1;
    final labelStyle = TextStyle(
      color: const Color(0xff5e7e90),
      fontSize: 10.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // Zero line — thick and bright if in range
    if (yMin < 0 && yMax > 0) {
      final zy = toY(0);
      canvas.drawLine(
        Offset(pL, zy),
        Offset(pR, zy),
        Paint()
          ..color = const Color(0xff4a6070)
          ..strokeWidth = 2.5,
      );
    }

    final gStart = (yMin / step).ceil() * step;
    for (var g = gStart; g <= yMax + 0.001; g += step) {
      final gy = toY(g);
      if (gy < pT - 2 || gy > pB + 2) continue;
      if (g.abs() < step * 0.01 && yMin < 0 && yMax > 0) {
        // skip the regular grid line at 0 — already drawn as zero line above
      } else {
        canvas.drawLine(Offset(pL, gy), Offset(pR, gy), gridPaint);
      }
      final tp = TextPainter(
        text: TextSpan(text: g.round().toString(), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pL - tp.width - 4, gy - tp.height / 2));
    }

    // X labels
    final totalSecs = tSpan / 1000;
    int tickMs;
    String Function(DateTime) tfmt;
    if (totalSecs <= 26 * 3600) {
      tickMs = 3 * 3600 * 1000;
      tfmt = (dt) => '${dt.toLocal().hour.toString().padLeft(2, '0')}h';
    } else if (totalSecs <= 50 * 3600) {
      tickMs = 6 * 3600 * 1000;
      tfmt = (dt) => '${dt.toLocal().hour.toString().padLeft(2, '0')}h';
    } else if (totalSecs <= 8 * 86400) {
      tickMs = 86400 * 1000;
      const days = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
      tfmt = (dt) => days[dt.toLocal().weekday - 1];
    } else {
      tickMs = 7 * 86400 * 1000;
      tfmt = (dt) {
        final l = dt.toLocal();
        return '${l.day}/${l.month}';
      };
    }

    var tick = (((tFirst / tickMs).floor() + 1) * tickMs).toDouble();
    while (tick <= tLast) {
      final tx = toX(tick);
      canvas.drawLine(Offset(tx, pT), Offset(tx, pB), gridPaint);
      final dt = DateTime.fromMillisecondsSinceEpoch(tick.round());
      final tp = TextPainter(
        text: TextSpan(text: tfmt(dt), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(tx - tp.width / 2, pB + 4));
      tick += tickMs;
    }

    // Split into contiguous segments wherever the gap to the next point is
    // bigger than expected — those gaps are missing data (e.g. a source
    // with patchy coverage), not a real flat/sloped transition, so they
    // must not be bridged by a connecting line or fill.
    final segments = <List<GraphPoint>>[];
    for (final p in points) {
      if (segments.isEmpty ||
          p.time.millisecondsSinceEpoch -
                  segments.last.last.time.millisecondsSinceEpoch >
              gapThresholdMs) {
        segments.add([p]);
      } else {
        segments.last.add(p);
      }
    }

    final fillPath = Path();
    for (final seg in segments) {
      fillPath.moveTo(
        toX(seg.first.time.millisecondsSinceEpoch.toDouble()),
        pB,
      );
      for (final p in seg) {
        fillPath.lineTo(
          toX(p.time.millisecondsSinceEpoch.toDouble()),
          toY(p.value),
        );
      }
      fillPath.lineTo(toX(seg.last.time.millisecondsSinceEpoch.toDouble()), pB);
      fillPath.close();
    }
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0.03)],
        ).createShader(Rect.fromLTWH(pL, pT, pW, pH))
        ..style = PaintingStyle.fill,
    );

    final linePath = Path();
    for (final seg in segments) {
      var started = false;
      for (final p in seg) {
        final px = toX(p.time.millisecondsSinceEpoch.toDouble());
        final py = toY(p.value);
        if (!started) {
          linePath.moveTo(px, py);
          started = true;
        } else {
          linePath.lineTo(px, py);
        }
      }
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // End dot — at the last real sample's own position, not the window
    // edge, so a source with a stale/short tail doesn't show a dot
    // floating at the right margin with an old value.
    final lastPt = points.last;
    final lastX = toX(lastPt.time.millisecondsSinceEpoch.toDouble());
    final lastY = toY(lastPt.value);
    canvas.drawCircle(Offset(lastX, lastY), 5, Paint()..color = color);
    canvas.drawCircle(Offset(lastX, lastY), 3, Paint()..color = cBg);

    // Selected crosshair
    if (selected != null) {
      final sx = toX(selected!.time.millisecondsSinceEpoch.toDouble());
      final sy = toY(selected!.value);
      canvas.drawLine(
        Offset(sx, pT),
        Offset(sx, pB),
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(Offset(sx, sy), 7, Paint()..color = color);
      canvas.drawCircle(Offset(sx, sy), 4.5, Paint()..color = cBg);
    }

    // Border
    canvas.drawRect(
      Rect.fromLTRB(pL, pT, pR, pB),
      Paint()
        ..color = const Color(0xff243040)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_LineGraphPainter old) =>
      old.points != points || old.color != color || old.selected != selected;
}

// ─── Wind tap card (wind panel → graph) ──────────────────────────────────────
class _WindTapCard extends StatelessWidget {
  const _WindTapCard({
    required this.label,
    required this.value,
    required this.color,
    required this.accentColor,
    required this.graphMetrics,
    required this.host,
    required this.bucket,
    this.archiveBucket = influxBucketDefault,
    this.historySource = 'auto',
    this.influxOrg = influxOrgDefault,
    this.influxToken = influxTokenDefault,
    this.skHost = '',
    this.skPort = 3000,
    this.skAuthBase64 = '',
    this.unit = '',
    this.side = 0, // -1=port(red), 0=none, 1=starboard(green)
    this.trend = 0, // -1 falling, 0 steady, 1 rising
    this.gust,
    this.beaufort,
    this.demo = false,
  });
  final String label;
  final String value;
  final Color color;
  final Color accentColor;
  final String unit;
  final int side; // -1 port, 0 none, 1 starboard
  final int trend;
  final String? gust;
  final int? beaufort;
  final List<MetricDef> graphMetrics;
  final String host;
  final String bucket;
  final String archiveBucket;
  final String historySource;
  final String influxOrg;
  final String influxToken;
  final String skHost;
  final int skPort;
  final String skAuthBase64;
  final bool demo;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (ctx) => GraphDialog(
              metrics: graphMetrics,
              historySource: historySource,
              influxHost: host,
              influxOrg: influxOrg,
              influxToken: influxToken,
              skHost: skHost.isEmpty ? host : skHost,
              skPort: skPort,
              skAuthBase64: skAuthBase64,
              bucket: bucket,
              archiveBucket: archiveBucket,
              demo: demo,
            ),
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: accentColor.withAlpha(80), width: 2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top bar: label left, unit right
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 3, 8, 0),
                child: Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                    if (trend != 0) ...[
                      const SizedBox(width: 4),
                      Icon(
                        trend > 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                        size: 16,
                        color: cMuted,
                      ),
                    ],
                    const Spacer(),
                    if (unit.isNotEmpty)
                      Text(
                        unit,
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              // Number fills the middle
              Expanded(
                child: Row(
                  children: [
                    const SizedBox(width: 6),
                    if (side < 0) ...[
                      LayoutBuilder(
                        builder: (ctx, c) => Icon(
                          Icons.play_arrow,
                          color: cRed,
                          size: (c.maxHeight * 0.60).clamp(20.0, 72.0),
                        ),
                      ),
                      const SizedBox(width: 2),
                    ],
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: Text(
                          value,
                          style: const TextStyle(
                            color: cText,
                            fontSize: 300,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                    if (side > 0) ...[
                      const SizedBox(width: 2),
                      LayoutBuilder(
                        builder: (ctx, c) => Transform.flip(
                          flipX: true,
                          child: Icon(
                            Icons.play_arrow,
                            color: cGreen,
                            size: (c.maxHeight * 0.60).clamp(20.0, 72.0),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                  ],
                ),
              ),
              // Bottom bar: graph icon left, gust bottom-right
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
                child: Row(
                  children: [
                    Icon(
                      Icons.show_chart,
                      size: 13,
                      color: accentColor.withAlpha(100),
                    ),
                    if (beaufort != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        'f. $beaufort Bft.',
                        style: const TextStyle(
                          color: cMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (gust != null)
                      Text(
                        'r. $gust',
                        style: const TextStyle(
                          color: cMuted,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
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
  }
}

// ─── Existing widgets (unchanged) ─────────────────────────────────────────────
class ForecastCard extends StatelessWidget {
  const ForecastCard({
    super.key,
    required this.title,
    required this.point,
    this.minMax,
    this.zoom,
  });
  final String title;
  final ForecastPoint? point;
  final (double?, double?)? minMax;
  final void Function(
    String title,
    String value,
    Color color, {
    String? subtitle,
    List<MetricDef>? graphMetrics,
  })?
  zoom;

  @override
  Widget build(BuildContext context) {
    final p = point;
    final mn = minMax?.$1, mx = minMax?.$2;
    return CardShell(
      onTap: p == null
          ? null
          : () => zoom?.call(
              title,
              fmt(p.tempC, 0, ' C'),
              cYellow,
              subtitle:
                  'Lluvia ${fmt(p.rainPct, 0, '%')} · Viento ${fmt(p.windKn, 0, ' kt')} · Racha ${fmt(p.gustKn, 0, ' kt')}',
            ),
      child: p == null
          ? const Center(child: Text('--', style: TextStyle(fontSize: 40)))
          : FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: 230,
                height: 150,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      WeatherIcon(
                        code: p.weatherCode,
                        time: p.time,
                        small: true,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: cMuted,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              fmt(p.tempC, 0, ' C'),
                              style: const TextStyle(
                                fontSize: 52,
                                fontWeight: FontWeight.w800,
                                height: 1.0,
                              ),
                            ),
                            if (mn != null && mx != null)
                              Text(
                                '${mx.round()}° / ${mn.round()}°',
                                style: const TextStyle(
                                  color: cMuted,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Text(
                              'Lluvia ${fmt(p.rainPct, 0, '%')}',
                              style: const TextStyle(
                                color: cCyan,
                                fontSize: 13,
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    fmt(p.windKn, 0, ' kt'),
                                    style: TextStyle(
                                      color: windColor(p.windKn),
                                      fontSize: 20,
                                    ),
                                  ),
                                ),
                                WindArrow(deg: p.windDirDeg, speed: p.windKn),
                              ],
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
}

class ForecastStrip extends StatelessWidget {
  const ForecastStrip({super.key, required this.points});
  final List<ForecastPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const Center(
        child: Text(
          'Sin prevision',
          style: TextStyle(color: cMuted, fontSize: 24),
        ),
      );
    }
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      children: [for (final p in points) HourForecast(point: p)],
    );
  }
}

class HourForecast extends StatelessWidget {
  const HourForecast({super.key, required this.point});
  final ForecastPoint point;

  static const _days = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  static Widget _hourLabel(DateTime t) {
    final l = t.toLocal();
    return Text(
      '${_days[l.weekday - 1]} ${l.hour.toString().padLeft(2, '0')}h',
      style: const TextStyle(
        color: cMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 98,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cPanel2,
        borderRadius: BorderRadius.circular(8),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: 82,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _hourLabel(point.time),
              const SizedBox(height: 4),
              WeatherIcon(
                code: point.weatherCode,
                time: point.time,
                small: true,
              ),
              const SizedBox(height: 4),
              Text(
                fmt(point.tempC, 0, ' °C'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                fmt(point.rainPct, 0, '%'),
                style: const TextStyle(color: cCyan, fontSize: 13),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    fmt(point.windKn, 0, ''),
                    style: TextStyle(
                      color: windColor(point.windKn),
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text(
                    '/',
                    style: TextStyle(color: cMuted, fontSize: 13),
                  ),
                  Text(
                    fmt(point.gustKn, 0, ' kt'),
                    style: TextStyle(
                      color: windColor(point.gustKn),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 30,
                width: 30,
                child: WindArrow(deg: point.windDirDeg, speed: point.windKn),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MarineCard extends StatelessWidget {
  const MarineCard({
    super.key,
    required this.title,
    required this.point,
    this.zoom,
  });
  final String title;
  final MarinePoint point;
  final void Function(
    String title,
    String value,
    Color color, {
    String? subtitle,
    List<MetricDef>? graphMetrics,
  })?
  zoom;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      onTap: () => zoom?.call(
        title,
        fmt(point.waveM, 1, ' m'),
        cCyan,
        subtitle:
            'Periodo ${fmt(point.wavePeriod, 1, ' s')} · Fondo ${fmt(point.swellM, 1, ' m')} · T. mar ${fmt(point.seaTempC, 0, ' C')}',
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: cMuted)),
            const Spacer(),
            Text(
              fmt(point.waveM, 1, ' m'),
              style: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w800,
                color: cCyan,
              ),
            ),
            Text(
              'Periodo ${fmt(point.wavePeriod, 1, ' s')}  ${dir(point.waveDir)}',
            ),
            Text(
              'Fondo ${fmt(point.swellM, 1, ' m')}  ${fmt(point.swellPeriod, 1, ' s')}',
            ),
            Text(
              'T. mar ${fmt(point.seaTempC, 0, ' C')}  Corr ${fmt(point.currentKmh == null ? null : point.currentKmh! / 1.852, 1, ' kt')}',
            ),
          ],
        ),
      ),
    );
  }
}

class WindValueCard extends StatelessWidget {
  const WindValueCard({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.subtitle,
    this.angle,
    this.isAngle = false,
  });
  final String label, value;
  final Color color;
  final String? subtitle;
  final double? angle;
  final bool isAngle;

  @override
  Widget build(BuildContext context) {
    final leftSide = angle != null && normalizeRelativeAngle(angle!) < 0;
    return Card(
      color: Colors.black,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xff303030), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 34, height: 5, color: color),
                const Spacer(),
                Text(
                  label,
                  style: const TextStyle(color: cMuted, fontSize: 17),
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isAngle && leftSide)
                      SideTriangle(color: color, left: true),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          value,
                          style: const TextStyle(
                            color: cText,
                            fontSize: 54,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    if (isAngle && !leftSide)
                      SideTriangle(color: color, left: false),
                  ],
                ),
              ),
            ),
            if (subtitle != null)
              Center(
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: cMuted, fontSize: 17),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SideTriangle extends StatelessWidget {
  const SideTriangle({super.key, required this.color, required this.left});
  final Color color;
  final bool left;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: left ? 0 : 8, right: left ? 8 : 0),
    child: Transform.rotate(
      angle: left ? 0 : math.pi,
      child: Icon(Icons.play_arrow, color: color, size: 26),
    ),
  );
}

class TankCard extends StatelessWidget {
  const TankCard({
    super.key,
    required this.name,
    required this.value,
    required this.capacityL,
    required this.color,
    required this.icon,
    this.large = false,
    this.flexible = false,
    this.onTap,
  });
  final String name;
  final double? value;
  final int capacityL;
  final Color color;
  final IconData icon;
  final bool large;
  final bool flexible;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final percent = (value ?? 0).clamp(0, 100).toDouble();
    final liters = capacityL <= 0 ? null : (capacityL * percent / 100).round();
    final cardWidth = flexible ? null : (large ? 190.0 : 152.0);
    return Container(
      width: cardWidth,
      margin: flexible ? null : EdgeInsets.only(right: large ? 18 : 10),
      child: Material(
        color: const Color(0xff151515),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xff303030), width: 1.3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                // Title bar
                Container(
                  height: large ? 46 : 38,
                  color: color,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: large ? 20 : 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Body: left = icon + % + liters, right = gauge bar
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      children: [
                        // Left: icon, percentage, liters
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(icon, color: cText, size: large ? 28 : 22),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: RichText(
                                  text: TextSpan(
                                    children: [
                                      TextSpan(
                                        text: percent.round().toString(),
                                        style: TextStyle(
                                          color: cText,
                                          fontSize: large ? 52 : 42,
                                          fontWeight: FontWeight.w300,
                                        ),
                                      ),
                                      TextSpan(
                                        text: '%',
                                        style: TextStyle(
                                          color: cMuted,
                                          fontSize: large ? 36 : 28,
                                          fontWeight: FontWeight.w300,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                liters == null
                                    ? '-- l'
                                    : '$liters/$capacityL l',
                                style: TextStyle(
                                  color: cMuted,
                                  fontSize: large ? 14 : 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Right: vertical gauge bar
                        SizedBox(
                          width: large ? 32 : 24,
                          child: SegmentedTankGauge(percent: percent),
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
    );
  }
}

class SegmentedTankGauge extends StatelessWidget {
  const SegmentedTankGauge({super.key, required this.percent});
  final double percent;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fillHeight =
            constraints.maxHeight * (percent / 100).clamp(0.0, 1.0);
        return ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            children: [
              Container(color: const Color(0xff10283d)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: fillHeight,
                child: Container(color: const Color(0xff3f86cc)),
              ),
              for (final mark in [0.25, 0.5, 0.75])
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: constraints.maxHeight * mark,
                  child: Container(height: 3, color: Colors.black),
                ),
            ],
          ),
        );
      },
    );
  }
}

class WeatherIcon extends StatelessWidget {
  const WeatherIcon({
    super.key,
    required this.code,
    required this.time,
    this.small = false,
  });
  final int? code;
  final DateTime time;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final hour = time.toLocal().hour;
    final night = hour < 7 || hour >= 20;
    final icon = night
        ? Icons.nightlight_round
        : (code == 0 ? Icons.wb_sunny : Icons.cloud);
    return Icon(
      icon,
      color: night || code == 0 ? cYellow : cMuted,
      size: small ? 24 : 52,
    );
  }
}

// ─── Alarms (CFG tab) ──────────────────────────────────────────────────────
class _ThresholdRow extends StatefulWidget {
  const _ThresholdRow({
    required this.label,
    required this.unit,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final String unit;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_ThresholdRow> createState() => _ThresholdRowState();
}

class _ThresholdRowState extends State<_ThresholdRow> {
  late final _controller = TextEditingController(
    text: widget.value == widget.value.roundToDouble()
        ? widget.value.toStringAsFixed(0)
        : widget.value.toString(),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.label,
              style: const TextStyle(color: cText, fontSize: 13),
            ),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              controller: _controller,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(color: cText, fontSize: 13),
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (v) {
                final n = double.tryParse(v.replaceAll(',', '.'));
                if (n != null) widget.onChanged(n);
              },
            ),
          ),
          const SizedBox(width: 6),
          Text(widget.unit, style: const TextStyle(color: cMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _SkZoneAlarmRow extends StatelessWidget {
  const _SkZoneAlarmRow({
    required this.path,
    required this.state,
    required this.setting,
    required this.onChanged,
  });
  final String path;
  final String state;
  final SkZoneAlarmSetting? setting;
  final ValueChanged<SkZoneAlarmSetting> onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = setting?.enabled ?? true;
    final sound = setting?.sound ?? true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  path,
                  style: const TextStyle(color: cText, fontSize: 12),
                ),
                Text(
                  state,
                  style: const TextStyle(color: cRed, fontSize: 10),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              sound ? Icons.volume_up : Icons.volume_off,
              color: enabled ? cCyan : cMuted,
              size: 18,
            ),
            onPressed: !enabled
                ? null
                : () => onChanged(
                    SkZoneAlarmSetting(enabled: enabled, sound: !sound),
                  ),
          ),
          Switch(
            value: enabled,
            onChanged: (v) =>
                onChanged(SkZoneAlarmSetting(enabled: v, sound: sound)),
          ),
        ],
      ),
    );
  }
}

class _CustomAlarmRow extends StatelessWidget {
  const _CustomAlarmRow({
    required this.rule,
    required this.onChanged,
    required this.onDelete,
  });
  final CustomAlarmRule rule;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            rule.label,
            style: const TextStyle(color: cText, fontSize: 12),
          ),
        ),
        IconButton(
          icon: Icon(
            rule.sound ? Icons.volume_up : Icons.volume_off,
            color: rule.enabled ? cCyan : cMuted,
            size: 18,
          ),
          onPressed: !rule.enabled
              ? null
              : () {
                  rule.sound = !rule.sound;
                  onChanged();
                },
        ),
        Switch(
          value: rule.enabled,
          onChanged: (v) {
            rule.enabled = v;
            onChanged();
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: cMuted, size: 18),
          onPressed: onDelete,
        ),
      ],
    ),
  );
}

class CardShell extends StatelessWidget {
  const CardShell({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.onSecondaryTap,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) => Card(
    color: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: cMuted.withValues(alpha: 0.35), width: 1.4),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onDoubleTap: onDoubleTap,
      onSecondaryTap: onSecondaryTap,
      child: child,
    ),
  );
}

class WindArrow extends StatelessWidget {
  const WindArrow({super.key, required this.deg, required this.speed});
  final double? deg;
  final double? speed;

  @override
  Widget build(BuildContext context) {
    if (deg == null) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Center(child: Text('--')),
      );
    }
    return Transform.rotate(
      angle: ((deg! + 180) % 360) * math.pi / 180,
      child: Icon(Icons.navigation, color: windColor(speed), size: 28),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
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
int _closestIndex(List<num> times, DateTime target) {
  if (times.isEmpty) return -1;
  var best = 0;
  var bestDelta = ((times[0] * 1000).round() - target.millisecondsSinceEpoch)
      .abs();
  for (var i = 1; i < times.length; i++) {
    final delta = ((times[i] * 1000).round() - target.millisecondsSinceEpoch)
        .abs();
    if (delta < bestDelta) {
      best = i;
      bestDelta = delta;
    }
  }
  return best;
}

String fmt(double? value, int decimals, String suffix) =>
    value == null ? '--$suffix' : '${value.toStringAsFixed(decimals)}$suffix';
String tempK(double? value) =>
    value == null ? '-- C' : '${(value - 273.15).toStringAsFixed(1)} C';
String tempNum(double? kelvin) =>
    kelvin == null ? '--' : (kelvin - 273.15).toStringAsFixed(1);
String tempValue(double? kelvin) =>
    kelvin == null ? 'No data' : (kelvin - 273.15).toStringAsFixed(1);
String? tempUnit(double? kelvin) => kelvin == null ? null : '°C';
// Degrees + minutes.tenths (e.g. 36°43.3'N) — the format sailors actually
// plot with, rather than raw decimal degrees.
String _dmm(double value, bool isLat) {
  final hemi = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
  final abs = value.abs();
  var deg = abs.floor();
  var min = (abs - deg) * 60;
  var minStr = min.toStringAsFixed(1);
  if (double.parse(minStr) >= 60) {
    deg += 1;
    minStr = '0.0';
  }
  final degStr = deg.toString().padLeft(isLat ? 2 : 3, '0');
  return "$degStr°$minStr'$hemi";
}

String pos(double? lat, double? lon) => lat == null || lon == null
    ? '--'
    : '${_dmm(lat, true)} ${_dmm(lon, false)}';
String posLines(double? lat, double? lon) => lat == null || lon == null
    ? '--'
    : '${_dmm(lat, true)}\n${_dmm(lon, false)}';
String angle(double? value) => value == null ? '--' : value.round().toString();
String angleAbs(double? value) => value == null
    ? '--'
    : normalizeRelativeAngle(value).abs().round().toString();
String directionDeg(double? value) =>
    value == null ? '--' : normalize360(value).round().toString();
String hhmm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String ddmmyyyy(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
String _lastUpdateText(DateTime? value) {
  if (value == null) return 'Sin datos';
  final seconds = DateTime.now().difference(value).inSeconds;
  if (seconds < 60) return 'Hace ${math.max(0, seconds)} s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return 'Hace $minutes min';
  return hhmm(value);
}

String dir(double? value) {
  if (value == null) return '--';
  const dirs = [
    'N',
    'NNE',
    'NE',
    'ENE',
    'E',
    'ESE',
    'SE',
    'SSE',
    'S',
    'SSO',
    'SO',
    'OSO',
    'O',
    'ONO',
    'NO',
    'NNO',
  ];
  return dirs[((value + 11.25) ~/ 22.5) & 15];
}

String fmtDeg(double? deg) =>
    deg == null ? '--°' : '${normalize360(deg).round()}°';

String fmtHeel(double? deg) {
  if (deg == null) return '--°';
  final side = deg < 0 ? 'B' : 'E';
  return '${deg.abs().round()}° $side';
}

Color heelColor(double? deg) {
  if (deg == null) return cMuted;
  return deg >= 0 ? cGreen : cRed;
}

Color meteogramColor(double? kn) {
  if (kn == null) return cMuted;
  if (kn < 3) return cMuted;
  if (kn < 7) return const Color(0xff2ea89a);
  if (kn < 10) return cOrange;
  if (kn < 15) return cRed;
  if (kn < 20) return const Color(0xffb33a3a);
  return cPurple;
}

Color windColor(double? speed) {
  if (speed == null) return cRed;
  if (speed <= 5) return cCyan;
  if (speed <= 15) return cGreen;
  if (speed <= 25) return cOrange;
  return cRed;
}

int? beaufort(double? kn) {
  if (kn == null) return null;
  const upper = [1, 4, 7, 11, 17, 22, 28, 34, 41, 48, 56, 64];
  for (var i = 0; i < upper.length; i++) {
    if (kn < upper[i]) return i;
  }
  return 12;
}

Color socColor(double? pct) {
  if (pct == null) return cMuted;
  if (pct >= 80) return cGreen;
  if (pct >= 50) return cYellow;
  if (pct >= 20) return cOrange;
  return cRed;
}

Color currentColor(double? amps) {
  if (amps == null) return cMuted;
  return amps >= 0 ? cGreen : cOrange;
}

Color sideColor(double? angle) {
  if (angle == null) return cMuted;
  return normalizeRelativeAngle(angle) < 0 ? cRed : cGreen;
}

Color voltageColor12V(double? v) {
  if (v == null) return cMuted;
  if (v >= 12.7) return cGreen;
  if (v >= 12.4) return cYellow;
  if (v >= 12.0) return cOrange;
  return cRed;
}

Color seaTempColor(double? kelvin) {
  if (kelvin == null) return cMuted;
  final c = kelvin - 273.15;
  if (c < 15) return cCyan;
  if (c < 22) return cGreen;
  if (c < 28) return cYellow;
  return cOrange;
}

// Equipment temp: green=normal, orange=warm, red=too hot
Color equipTempColor(double? kelvin, {double warnC = 40, double alarmC = 55}) {
  if (kelvin == null) return cMuted;
  final c = kelvin - 273.15;
  if (c >= alarmC) return cRed;
  if (c >= warnC) return cOrange;
  return cGreen;
}

// Fridge temp: cyan=perfect, green=ok, orange=too warm, red=alarm
Color fridgeTempColor(double? kelvin) {
  if (kelvin == null) return cMuted;
  final c = kelvin - 273.15;
  if (c > 10) return cRed;
  if (c > 6) return cOrange;
  if (c > 2) return cGreen;
  return cCyan;
}

// Depth: cyan=deep, green=ok, orange=caution, red=shallow
Color depthColor(double? meters) {
  if (meters == null) return cMuted;
  if (meters < 2.0) return cRed;
  if (meters < 5.0) return cOrange;
  if (meters < 15.0) return cYellow;
  return cCyan;
}

double normalize360(double value) {
  var out = value % 360.0;
  if (out < 0) out += 360.0;
  return out;
}

double normalizeRelativeAngle(double value) {
  var out = normalize360(value);
  if (out > 180.0) out -= 360.0;
  return out;
}

double? relativeWindAngle(double? directionDeg, double? referenceDeg) {
  if (directionDeg == null || referenceDeg == null) return null;
  return normalizeRelativeAngle(directionDeg - referenceDeg);
}

// ─── Anchor page: embedded Hoeken/Freeboard-SK view ───────────────────────────
class _AnchorWebView extends StatefulWidget {
  const _AnchorWebView({
    required this.host,
    required this.port,
    this.path = '/hoekens-anchor-alarm/',
    this.label = 'Ancla',
    this.missingPluginHint,
    this.demo = false,
    this.demoExplainer,
  });
  final String host;
  final int port;
  final String path;
  final String label;
  final String? missingPluginHint;
  final bool demo;
  final String? demoExplainer;
  @override
  State<_AnchorWebView> createState() => _AnchorWebViewState();
}

class _AnchorWebViewState extends State<_AnchorWebView>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _error = false;
  int _reloadNonce = 0;

  @override
  bool get wantKeepAlive => true;

  String get _url => 'http://${widget.host}:${widget.port}${widget.path}';

  void _reload() {
    setState(() {
      _loading = true;
      _error = false;
      _reloadNonce++;
    });
  }

  @override
  void didUpdateWidget(_AnchorWebView old) {
    super.didUpdateWidget(old);
    if (!widget.demo &&
        (old.host != widget.host ||
            old.port != widget.port ||
            old.path != widget.path)) {
      _loading = true;
      _error = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.demo) {
      return Container(
        color: cBg,
        padding: const EdgeInsets.all(32),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off, color: cMuted, size: 48),
            const SizedBox(height: 16),
            Text(
              widget.label,
              style: const TextStyle(
                color: cText,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.demoExplainer ??
                  'Aquí se mostraría ${widget.label}, embebido desde el servidor Signal K.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: cMuted, fontSize: 15),
            ),
            const SizedBox(height: 14),
            const Text(
              'No disponible en modo DEMO.',
              style: TextStyle(
                color: cOrange,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        PlatformWebView(
          key: ValueKey(_reloadNonce),
          url: _url,
          onPageStarted: () {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: () {
            if (mounted) setState(() => _loading = false);
          },
          onError: () {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = true;
              });
            }
          },
        ),
        if (_loading)
          const Center(child: CircularProgressIndicator(color: cCyan)),
        if (_error)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.web_asset_off, color: cMuted, size: 48),
                const SizedBox(height: 12),
                Text(
                  'No se puede cargar ${widget.label}',
                  style: const TextStyle(color: cMuted, fontSize: 18),
                ),
                const SizedBox(height: 6),
                Text(
                  _url,
                  style: const TextStyle(color: cOrange, fontSize: 12),
                ),
                if (widget.missingPluginHint != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.missingPluginHint!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: cYellow, fontSize: 14),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                  onPressed: _reload,
                ),
              ],
            ),
          ),
        Positioned(
          top: 28,
          left: 8,
          child: GestureDetector(
            onTap: _reload,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.refresh, color: cMuted, size: 20),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Circular exponential damper (B&G-style smoothing) ───────────────────────
// ─── Wind history buffer (trend + gusts over a rolling window) ───────────────
/// Confirmed-trend detector for depth (and similar slow-moving values):
/// a Schmitt-trigger-style hysteresis on top of a light exponential
/// moving average, so seabed/wave noise doesn't flip the arrow back and
/// forth — the direction only updates once the smoothed value has moved
/// by [_thresholdM] from the last confirmed point, and re-anchors there.
class _DepthTrendTracker {
  double? _smoothed;
  double? _confirmedAt;
  int direction = 0; // -1 bajando, 0 sin tendencia clara, 1 subiendo
  static const _thresholdM = 0.3;
  static const _alpha = 0.15;

  void add(double? depth) {
    if (depth == null) return;
    _smoothed = _smoothed == null
        ? depth
        : _smoothed! + (depth - _smoothed!) * _alpha;
    _confirmedAt ??= _smoothed;
    final delta = _smoothed! - _confirmedAt!;
    if (delta.abs() >= _thresholdM) {
      direction = delta > 0 ? 1 : -1;
      _confirmedAt = _smoothed;
    }
  }
}

class _WindHistory {
  final List<(DateTime, double)> _samples = [];
  static const _window = Duration(minutes: 30);

  void add(double? value) {
    if (value == null) return;
    final now = DateTime.now();
    _samples.add((now, value));
    final cutoff = now.subtract(_window);
    while (_samples.isNotEmpty && _samples.first.$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  double? _avg(Duration from, Duration to) {
    final now = DateTime.now();
    final start = now.subtract(to);
    final end = now.subtract(from);
    final vals = [
      for (final s in _samples)
        if (!s.$1.isBefore(start) && s.$1.isBefore(end)) s.$2,
    ];
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  // -1 falling, 0 steady, 1 rising (2min avg vs 2-30min avg, 1.5kt hysteresis)
  int trend({double threshold = 1.5}) {
    final recent = _avg(Duration.zero, const Duration(minutes: 2));
    final past = _avg(const Duration(minutes: 2), const Duration(minutes: 30));
    if (recent == null || past == null) return 0;
    final diff = recent - past;
    if (diff > threshold) return 1;
    if (diff < -threshold) return -1;
    return 0;
  }

  // Max raw value in the last [window] (default 2min) = gust.
  double? gust({Duration window = const Duration(minutes: 2)}) {
    final now = DateTime.now();
    final start = now.subtract(window);
    final vals = [
      for (final s in _samples)
        if (!s.$1.isBefore(start)) s.$2,
    ];
    if (vals.isEmpty) return null;
    return vals.reduce(math.max);
  }
}

class _WindCircularDamper {
  final double tau; // time constant in seconds (higher = more smoothing)
  double? _s, _c; // sin / cos accumulators (for circular angles)
  double? _v; // linear accumulator (for speeds)

  _WindCircularDamper({this.tau = 5.0});

  double get _alpha => 1.0 - math.exp(-1.0 / tau);

  // Feed a circular angle (degrees, any range). Returns smoothed degrees.
  double? angle(double? deg) {
    if (deg == null) return _toDeg();
    final a = _alpha;
    final rad = deg * math.pi / 180;
    _s = _s == null ? math.sin(rad) : _s! + a * (math.sin(rad) - _s!);
    _c = _c == null ? math.cos(rad) : _c! + a * (math.cos(rad) - _c!);
    return _toDeg();
  }

  double? _toDeg() {
    if (_s == null || _c == null) return null;
    return math.atan2(_s!, _c!) * 180 / math.pi;
  }

  // Feed a linear value (speed, temperature, etc.).
  double? linear(double? val) {
    if (val == null) return _v;
    _v = _v == null ? val : _v! + _alpha * (val - _v!);
    return _v;
  }

  void reset() {
    _s = null;
    _c = null;
    _v = null;
  }
}
