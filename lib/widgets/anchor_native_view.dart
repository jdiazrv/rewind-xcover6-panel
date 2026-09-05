import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:latlong2/latlong.dart' as ll;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models.dart';
import '../theme.dart';

// ─── Native anchor watch (ANC) ─────────────────────────────────────────────
// Full replacement for the embedded hoekens-anchor-alarm webview: real
// lat/lon map (not the old _PremiumAnchorPainter's polar/relative
// abstraction), drop/raise, draggable position + radius, circle/sector
// shape, togglable layers, nearby AIS, own track colored by age. Nothing
// here talks to the plugin or writes anything back to Signal K — the whole
// watch lives in AnchorConfig, persisted locally by the caller.
//
// Free ArcGIS World Imagery tiles — the same satellite source the hoekens
// plugin itself uses (confirmed live), so switching to this screen isn't a
// step down in chart quality.
const _kSatelliteTileUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const _kOsmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _kSeamarkTileUrl = 'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png';

const _kMaxMapZoom = 19.0;

// Own track: green fading with age (like hoekens' own trail), never blue —
// a blue trail disappears against open water on the satellite layer.
// Three stops, not just two shades of the same green — green (just now)
// fading through yellow (a while ago) to brown (oldest still shown) reads
// as an actual age gradient at a glance instead of "some dark green,
// some light green". Explicit per request 2026-09-02, applies to every
// platform since it's the same shared Dart code.
const _kTrackRecent = Color(0xff3ddc61); // green — just now
const _kTrackMid = Color(0xffd4c23a); // yellow — a while ago
const _kTrackOld = Color(0xff6b4a2a); // brown — oldest still shown

// t=0 oldest point shown, t=1 most recent — two Color.lerp hops instead of
// one, since Color.lerp itself only ever blends two colors.
Color _trackAgeColor(double t) => t >= 0.5
    ? (Color.lerp(_kTrackMid, _kTrackRecent, (t - 0.5) * 2) ?? _kTrackRecent)
    : (Color.lerp(_kTrackOld, _kTrackMid, t * 2) ?? _kTrackMid);

class NativeAnchorView extends StatefulWidget {
  const NativeAnchorView({
    super.key,
    required this.config,
    required this.onConfigChanged,
    required this.ownLat,
    required this.ownLon,
    required this.skConnected,
    required this.headingDeg,
    required this.sogKn,
    required this.depthM,
    required this.awaDeg,
    required this.awsKn,
    required this.gustKn,
    required this.gustAgeMin,
    required this.aisTargets,
    required this.ownTrack,
    required this.skUsername,
    required this.skPassword,
    required this.onCredentialsChanged,
    this.onVerifyLogin,
    this.demo = false,
    required this.gpsFallbackConsent,
    required this.onGpsFallbackConsentChanged,
    required this.onEffectivePositionChanged,
    required this.detectPhoneLeftByMotion,
    required this.detectPhoneLeftBySteps,
    required this.detectPhoneLeftByWifi,
    required this.boatWifiSsid,
    this.shipIconAsset = 'assets/img/own_ship.png',
    this.alarmsMuted = false,
    this.onToggleAlarmsMuted,
    this.isGusting = false,
    this.twdDeg,
    this.windMeanKn,
    this.windStddevKn,
    this.windPeak3sKn,
    this.windGustFloorKn,
    this.onDragStatusChanged,
    required this.onOpenYawAnalysis,
  });

  final AnchorConfig config;
  final ValueChanged<AnchorConfig> onConfigChanged;
  final double? ownLat;
  final double? ownLon;
  // Live, not a stored/cached value — without a real Signal K connection
  // the app genuinely doesn't know the boat's current state, so it must
  // never present "FONDEADO" (or any drag/outside reading) as if it were
  // confirmed. Explicit per request 2026-09-02.
  final bool skConnected;
  final double? headingDeg;
  final double? sogKn;
  final double? depthM;
  final double? awaDeg;
  final double? awsKn;
  final double? twdDeg;
  // Long-press-to-inspect diagnostics behind the gust detection — see
  // docs/gust-detection.md.
  final double? windMeanKn;
  final double? windStddevKn;
  final double? windPeak3sKn;
  final double? windGustFloorKn;
  // outside-the-circle, actively-dragging, and drag-speed (m/min) — for
  // main.dart's ntfy push text, so it doesn't have to re-derive this
  // itself (duplicating the "only sample while outside, reset the instant
  // it isn't" logic this screen already gets right).
  final void Function(bool outside, bool isDragging, double? dragSpeedMPerMin)?
  onDragStatusChanged;
  // ANC > Guiñada — opens a main.dart-scope dialog (needs
  // LineGraph/GraphPoint/history-query helpers only visible there), same
  // bridge pattern as onConfigChanged/onCredentialsChanged.
  final VoidCallback onOpenYawAnalysis;
  final double? gustKn;
  final int? gustAgeMin;
  final List<AisTarget> aisTargets;
  final List<AnchorTrackPoint> ownTrack;
  final String skUsername;
  final String skPassword;
  final void Function(String username, String password) onCredentialsChanged;
  // A real POST /signalk/v1/auth/login, not just "are these fields
  // non-empty" — Fondear/Levar used to arm/disarm locally on the strength
  // of a non-empty username/password alone, so a typo'd credential could
  // arm the watch while the actual Signal K publish silently failed from
  // then on. Null means the caller doesn't support verification (treated
  // as "trust the fields", the old behavior) — always provided in
  // practice (see main.dart's _loginToSignalK).
  final Future<bool> Function()? onVerifyLogin;
  // DEMO mode has no real Signal K server to verify against — a real
  // POST would always fail, blocking Fondear/Levar/Recolocar entirely and
  // making it impossible to try the anchor watch out risk-free, exactly
  // what DEMO exists for. Skips _ensureLoggedIn's verification (not the
  // "has credentials" check — DEMO still shouldn't need real credentials
  // typed in at all) while active. Reported live 2026-09-04 (found while
  // testing "Guiñada" in DEMO mode).
  final bool demo;
  final bool? gpsFallbackConsent;
  final ValueChanged<bool> onGpsFallbackConsentChanged;
  // Lets main.dart's "sin posición" alarm know this screen's own
  // device-GPS fallback is quietly covering for a missing Signal K fix,
  // so that alarm doesn't fire on a false positive.
  final void Function(double? lat, double? lon) onEffectivePositionChanged;
  // "Te has llevado el móvil" detectors — configured in CFG > Fondeo, only
  // meaningful (and only actually run) while device GPS is the position
  // source actually in use.
  final bool detectPhoneLeftByMotion;
  final bool detectPhoneLeftBySteps;
  final bool detectPhoneLeftByWifi;
  final String boatWifiSsid;
  final String shipIconAsset;
  final bool alarmsMuted;
  final VoidCallback? onToggleAlarmsMuted;
  final bool isGusting;

  @override
  State<NativeAnchorView> createState() => _NativeAnchorViewState();
}

class _NativeAnchorViewState extends State<NativeAnchorView> {
  final _mapController = fm.MapController();
  final _mapKey = GlobalKey();
  // null = normal map pan/zoom. 'anchor'/'radius' = editing, map gestures
  // disabled, long-press-drag repositions instead — the explicit
  // "realimentación... en vez de mover la carta" the request asked for.
  String? _editMode;
  ll.LatLng? _dragAnchor;
  double? _dragRadiusM;
  // Live drag state for the sector's two limit handles — separate from
  // _dragRadiusM so radius and either limit can each be mid-drag without
  // clobbering the others; all three commit together on confirm.
  double? _dragSectorStartDeg;
  double? _dragSectorEndDeg;
  // Set from tapping a Historial entry — just a plain geo Marker, so it
  // naturally stops rendering the instant a pan/zoom takes it off-screen,
  // with no extra visibility bookkeeping needed here.
  ll.LatLng? _historyMarkerPoint;
  // Editing ends on its own 5s after the last movement — no need to hunt
  // for a Confirm button if you just stop touching the screen.
  Timer? _editTimeoutTimer;
  bool _askedDeviceGps = false;
  StreamSubscription<geo.Position>? _geoSub;
  geo.Position? _devicePosition;
  // True once the user explicitly says "keep using the phone" when asked
  // whether to switch back — Signal K position reappearing shouldn't
  // silently yank the reference out from under an in-progress watch.
  bool _preferDeviceGps = false;
  bool _askingSwitchBack = false;

  // "Te has llevado el móvil" detectors — all three only actually run
  // while device GPS is the position actually in use (see
  // _usingDeviceGpsAsSource), and all three funnel into the same
  // confirmation dialog rather than alarming outright: a false positive
  // here is a dinghy trip ashore, not a real drag, so it asks first.
  final List<geo.Position> _deviceTrack = [];
  StreamSubscription<StepCount>? _stepSub;
  int? _stepsAtFallbackStart;
  int? _latestStepCount;
  Timer? _wifiCheckTimer;
  bool _phoneLeftDialogShowing = false;
  DateTime? _phoneLeftSnoozeUntil;
  bool _ignoreMotionDetector = false;
  bool _ignoreStepsDetector = false;
  bool _ignoreWifiDetector = false;

  // Rolling window of (time, distance-to-anchor) so "outside the circle"
  // can be told apart from "actually garreando": a boat that swung out
  // once and is holding steady out there isn't dragging, one whose
  // distance keeps climbing is. Also drives the m/min readout.
  final List<(DateTime, double)> _distanceSamples = [];

  // Distance-to-anchor only — never SOG, which is the boat's speed through
  // the water/ground generically and says nothing about whether it's
  // actually pulling further from the anchor (could be motoring in a tight
  // circle right at the edge of the zone with real SOG but ~zero drag
  // speed). Only sampled while actually outside the circle, and reset the
  // instant it isn't, so a fresh drag episode is measured on its own —
  // not diluted by however long it sat calmly inside beforehand.
  double? _dragSpeedMPerMin(double? distanceM, bool outside) {
    if (!outside || distanceM == null) {
      _distanceSamples.clear();
      return null;
    }
    final now = DateTime.now();
    _distanceSamples.add((now, distanceM));
    _distanceSamples.removeWhere(
      (s) => now.difference(s.$1) > const Duration(minutes: 2),
    );
    if (_distanceSamples.length < 2) return null;
    final oldest = _distanceSamples.first;
    final elapsedMin = now.difference(oldest.$1).inSeconds / 60.0;
    if (elapsedMin < 0.25) return null; // not enough time span to trust yet
    return (distanceM - oldest.$2) / elapsedMin;
  }

  bool get _usingDeviceGpsAsSource =>
      _devicePosition != null && (!_hasSkPosition || _preferDeviceGps);

  // Red while a real, confirmed gust is under way (see _WindHistory.
  // isGusting — %-above-baseline, sustained a couple seconds, not just
  // "the biggest number recently"), yellow otherwise.
  Color get _windArrowColor => widget.isGusting ? cRed : cYellow;

  @override
  void dispose() {
    _geoSub?.cancel();
    _stepSub?.cancel();
    _wifiCheckTimer?.cancel();
    _editTimeoutTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _resetEditTimeout() {
    _editTimeoutTimer?.cancel();
    _editTimeoutTimer = Timer(const Duration(seconds: 5), () {
      if (_editMode != null) _confirmEdit();
    });
  }

  // All four ways editing ends (5s idle, tap elsewhere, re-tapping the same
  // toolbar button, the banner's own Confirm) apply the drag in progress —
  // only the banner's explicit Cancel discards it.
  void _confirmEdit() {
    final mode = _editMode;
    setState(() {
      if (mode == 'anchor' && _dragAnchor != null) {
        final lat = _effectiveLat, lon = _effectiveLon;
        _updateConfig((c) {
          c.dropLat = _dragAnchor!.latitude;
          c.dropLon = _dragAnchor!.longitude;
          // Moving the anchor is the ONLY thing that auto-resizes the
          // circle — grows it just enough to keep the boat inside (10%
          // margin), once, right now. It never auto-shrinks and never
          // reacts to ordinary swinging — a radius the user set by hand
          // (below) stays exactly as they set it otherwise.
          if (lat != null && lon != null) {
            final required =
                bearingDistanceMeters(
                  _dragAnchor!.latitude,
                  _dragAnchor!.longitude,
                  lat,
                  lon,
                ).distanceM *
                1.10;
            if (required > c.radiusM) c.radiusM = required;
          }
          c.armedOrMovedAt = skNow();
        });
      } else if (mode == 'radius' && _dragRadiusM != null) {
        _updateConfig((c) {
          c.radiusM = _dragRadiusM!;
          c.initialRadiusM = _dragRadiusM!;
          if (c.shape == 'sector') {
            if (_dragSectorStartDeg != null) {
              c.sectorStartDeg = _dragSectorStartDeg! % 360;
            }
            if (_dragSectorEndDeg != null) {
              c.sectorEndDeg = _dragSectorEndDeg! % 360;
            }
          }
          c.armedOrMovedAt = skNow();
        });
      }
      _editMode = null;
      _dragAnchor = null;
      _dragRadiusM = null;
      _dragSectorStartDeg = null;
      _dragSectorEndDeg = null;
    });
    _editTimeoutTimer?.cancel();
  }

  void _cancelEdit() {
    setState(() {
      _editMode = null;
      _dragAnchor = null;
      _dragRadiusM = null;
      _dragSectorStartDeg = null;
      _dragSectorEndDeg = null;
    });
    _editTimeoutTimer?.cancel();
  }

  double? get _effectiveLat => _preferDeviceGps
      ? (_devicePosition?.latitude ?? widget.ownLat)
      : (widget.ownLat ?? _devicePosition?.latitude);
  double? get _effectiveLon => _preferDeviceGps
      ? (_devicePosition?.longitude ?? widget.ownLon)
      : (widget.ownLon ?? _devicePosition?.longitude);
  bool get _hasSkPosition => widget.ownLat != null && widget.ownLon != null;

  ll.LatLng? _globalToLatLng(Offset global) {
    final box = _mapKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return _mapController.camera.screenOffsetToLatLng(
      box.globalToLocal(global),
    );
  }

  Future<void> _maybeOfferDeviceGps() async {
    if (_hasSkPosition || _askedDeviceGps) return;
    if (widget.gpsFallbackConsent == false) return;
    _askedDeviceGps = true;
    if (widget.gpsFallbackConsent == null) {
      if (!mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cPanel,
          title: const Text('¿Usar la posición del dispositivo?'),
          content: const Text(
            'Signal K no está enviando la posición del barco ahora mismo. '
            'Puedo usar el GPS de esta tablet/móvil como referencia mientras '
            'tanto, solo en esta pantalla de fondeo. Es un dato de tu '
            'dispositivo, no del barco — solo se usa si lo permites.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No, gracias'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Permitir'),
            ),
          ],
        ),
      );
      widget.onGpsFallbackConsentChanged(allow ?? false);
      if (allow != true) return;
    }
    unawaited(_startDeviceGps());
  }

  Future<void> _startDeviceGps() async {
    final enabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!enabled) return;
    var perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }
    if (perm == geo.LocationPermission.denied ||
        perm == geo.LocationPermission.deniedForever) {
      return;
    }
    _geoSub?.cancel();
    _deviceTrack.clear();
    _ignoreMotionDetector = false;
    _ignoreStepsDetector = false;
    _ignoreWifiDetector = false;
    _geoSub =
        geo.Geolocator.getPositionStream(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 3,
          ),
        ).listen((p) {
          if (!mounted) return;
          setState(() => _devicePosition = p);
          _deviceTrack.add(p);
          _deviceTrack.removeWhere(
            (s) =>
                p.timestamp.difference(s.timestamp) >
                const Duration(minutes: 5),
          );
          _checkMotionPattern();
        });
    unawaited(_startStepMonitoring());
    _startWifiMonitoring();
  }

  // (b) Motion pattern: a real drag/swing stays within the watch radius
  // and wanders back and forth; someone walking ashore moves steadily
  // further away in roughly one direction. Compares net displacement from
  // the oldest sample in the last 5 min against the total path length
  // covered getting there — a straight walk keeps that ratio close to 1,
  // an oscillating swing keeps it low.
  void _checkMotionPattern() {
    if (!widget.detectPhoneLeftByMotion || _ignoreMotionDetector) return;
    if (!widget.config.armed || !_usingDeviceGpsAsSource) return;
    if (_deviceTrack.length < 6) return;
    final first = _deviceTrack.first;
    final last = _deviceTrack.last;
    final net = bearingDistanceMeters(
      first.latitude,
      first.longitude,
      last.latitude,
      last.longitude,
    ).distanceM;
    if (net < 40) return; // too close to tell yet
    var pathLen = 0.0;
    for (var i = 1; i < _deviceTrack.length; i++) {
      final a = _deviceTrack[i - 1], b = _deviceTrack[i];
      pathLen += bearingDistanceMeters(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      ).distanceM;
    }
    if (pathLen < 1) return;
    if (net / pathLen > 0.75) {
      _maybeShowPhoneLeftDialog(
        'El móvil se ha movido en línea bastante recta unos '
        '${net.round()} m — más propio de alguien caminando que del vaivén '
        'del barco fondeado.',
        () => _ignoreMotionDetector = true,
      );
    }
  }

  // (c) Step count: a real anchor drag doesn't involve anyone walking.
  Future<void> _startStepMonitoring() async {
    if (!widget.detectPhoneLeftBySteps) return;
    final status = await Permission.activityRecognition.request();
    if (!status.isGranted) return;
    _stepsAtFallbackStart = null;
    _stepSub?.cancel();
    _stepSub = Pedometer.stepCountStream.listen((event) {
      _stepsAtFallbackStart ??= event.steps;
      _latestStepCount = event.steps;
      _checkSteps();
    }, onError: (_) {});
  }

  void _checkSteps() {
    if (!widget.detectPhoneLeftBySteps || _ignoreStepsDetector) return;
    if (!widget.config.armed || !_usingDeviceGpsAsSource) return;
    final start = _stepsAtFallbackStart, now = _latestStepCount;
    if (start == null || now == null) return;
    if (now - start >= 25) {
      _maybeShowPhoneLeftDialog(
        'El podómetro del móvil ha contado ${now - start} pasos desde que '
        'empezaste a usar su GPS — parece que alguien está caminando con él.',
        () => _ignoreStepsDetector = true,
      );
    }
  }

  // (d) Boat's own WiFi: losing that network while device GPS is the
  // active source is a simple, strong "left the boat" signal.
  void _startWifiMonitoring() {
    if (!widget.detectPhoneLeftByWifi || widget.boatWifiSsid.trim().isEmpty) {
      return;
    }
    _wifiCheckTimer?.cancel();
    _wifiCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_checkWifi());
    });
  }

  Future<void> _checkWifi() async {
    if (!widget.detectPhoneLeftByWifi || _ignoreWifiDetector) return;
    if (!widget.config.armed || !_usingDeviceGpsAsSource) return;
    try {
      final ssid = await NetworkInfo().getWifiName();
      final clean = ssid?.replaceAll('"', '');
      if (clean != widget.boatWifiSsid) {
        _maybeShowPhoneLeftDialog(
          'El móvil ya no está conectado a la red WiFi del barco '
          '("${widget.boatWifiSsid}") — parece que se ha alejado.',
          () => _ignoreWifiDetector = true,
        );
      }
    } catch (_) {
      /* WiFi state unavailable — skip this check, not worth alarming over */
    }
  }

  Future<void> _maybeShowPhoneLeftDialog(
    String reason,
    VoidCallback onIgnore,
  ) async {
    if (_phoneLeftDialogShowing) return;
    final snooze = _phoneLeftSnoozeUntil;
    if (snooze != null && DateTime.now().isBefore(snooze)) return;
    if (!mounted) return;
    _phoneLeftDialogShowing = true;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: const Text('¿Te has llevado el móvil?'),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('ignore'),
            child: const Text('Ignorar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('raise'),
            style: FilledButton.styleFrom(backgroundColor: cRed),
            child: const Text('Levar ancla'),
          ),
        ],
      ),
    );
    _phoneLeftDialogShowing = false;
    switch (action) {
      case 'raise':
        await _raiseAnchor();
      case 'ignore':
        onIgnore();
      default:
        // 'cancel' (or dismissed) — don't nag again for a few minutes,
        // the underlying condition is almost certainly still true.
        _phoneLeftSnoozeUntil = DateTime.now().add(const Duration(minutes: 10));
    }
  }

  @override
  void didUpdateWidget(NativeAnchorView old) {
    super.didUpdateWidget(old);
    if (!_hasSkPosition) {
      // SK position lost again — any earlier "keep using the phone"
      // decision was about the previous reappearance, not a standing
      // preference, so it's re-askable next time SK comes back too.
      _preferDeviceGps = false;
      unawaited(_maybeOfferDeviceGps());
      return;
    }
    if (_geoSub != null && !_preferDeviceGps && !_askingSwitchBack) {
      unawaited(_offerSwitchBackToSk());
    }
  }

  // Signal K position came back while device GPS was standing in — don't
  // yank the reference out from under an in-progress watch without asking;
  // the user may deliberately still want the phone's own position.
  Future<void> _offerSwitchBackToSk() async {
    _askingSwitchBack = true;
    final switchBack = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: const Text('Signal K ya tiene posición'),
        content: const Text(
          'El barco ya está enviando su propia posición otra vez. '
          '¿Cambio a esa posición, o sigo usando el GPS de este dispositivo?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Seguir con el dispositivo'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cambiar a Signal K'),
          ),
        ],
      ),
    );
    _askingSwitchBack = false;
    if (!mounted) return;
    if (switchBack == true) {
      _geoSub?.cancel();
      _geoSub = null;
      _stepSub?.cancel();
      _stepSub = null;
      _wifiCheckTimer?.cancel();
      _wifiCheckTimer = null;
      setState(() => _devicePosition = null);
    } else {
      setState(() => _preferDeviceGps = true);
    }
  }

  @override
  void initState() {
    super.initState();
    if (!_hasSkPosition) unawaited(_maybeOfferDeviceGps());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lat = _effectiveLat, lon = _effectiveLon;
      if (lat != null && lon != null) {
        _mapController.move(ll.LatLng(lat, lon), 18);
      }
    });
  }

  void _updateConfig(void Function(AnchorConfig c) mutate) {
    final c = widget.config;
    mutate(c);
    widget.onConfigChanged(c);
  }

  bool get _hasCredentials =>
      widget.skUsername.trim().isNotEmpty && widget.skPassword.isNotEmpty;

  Future<bool> _ensureLoggedIn() async {
    if (widget.demo) return true;
    if (!_hasCredentials) {
      final result = await showDialog<(String, String)>(
        context: context,
        builder: (ctx) => _LoginDialog(
          initialUser: widget.skUsername,
          initialPass: widget.skPassword,
        ),
      );
      if (result == null) return false;
      widget.onCredentialsChanged(result.$1, result.$2);
      if (result.$1.trim().isEmpty || result.$2.isEmpty) return false;
    }
    // Actually confirm the credentials work, not just that the fields
    // aren't empty — a typo used to arm/disarm the watch locally while
    // the real Signal K publish (which needs a valid login of its own)
    // silently failed from then on.
    final verify = widget.onVerifyLogin;
    if (verify == null) return true;
    final ok = await verify();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo iniciar sesión en Signal K — revisa usuario/contraseña.',
          ),
        ),
      );
    }
    return ok;
  }

  Future<void> _dropAnchor() async {
    if (!await _ensureLoggedIn()) return;
    final lat = _effectiveLat, lon = _effectiveLon;
    if (lat == null || lon == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sin posición — no se puede fondear.')),
        );
      }
      return;
    }
    HapticFeedback.mediumImpact();
    final depth = widget.depthM;
    final heading = widget.headingDeg;
    // Chain scope (5:1) laid out along the boat's heading gives a more
    // realistic initial drop point than the boat's own position.
    final ll.LatLng dropPoint = (depth != null && heading != null)
        ? _destinationPoint(ll.LatLng(lat, lon), depth * 5, heading)
        : ll.LatLng(lat, lon);
    _updateConfig((c) {
      c.armed = true;
      c.dropLat = dropPoint.latitude;
      c.dropLon = dropPoint.longitude;
      c.dropDepthM = depth;
      c.droppedAt = DateTime.now();
      c.chainOutM = null;
      // 7:1 swing radius is the initial watch-circle size on drop.
      c.radiusM = depth != null ? (depth * 7).clamp(15, 150) : 30;
      c.initialRadiusM = c.radiusM;
      // 10s grace period before the drag alarm can fire — the drop itself
      // (or a GPS fix settling in) shouldn't immediately read as garreo.
      c.armedOrMovedAt = skNow();
    });
  }

  Future<void> _raiseAnchor() async {
    if (!await _ensureLoggedIn()) return;
    HapticFeedback.mediumImpact();
    _updateConfig((c) {
      c.armed = false;
      if (c.dropLat != null && c.dropLon != null) {
        c.history = [
          ...c.history,
          AnchorHistoryEntry(
            droppedAt: c.droppedAt ?? DateTime.now(),
            raisedAt: DateTime.now(),
            lat: c.dropLat!,
            lon: c.dropLon!,
            radiusM: c.radiusM,
            depthM: c.dropDepthM,
          ),
        ];
        // Keep the log from growing unbounded across a season.
        if (c.history.length > 50) {
          c.history = c.history.sublist(c.history.length - 50);
        }
      }
    });
  }

  // Only the swing recorded since the CURRENT drop — widget.ownTrack keeps
  // up to 24h regardless of anchorage, so an earlier stop's track must
  // never leak into this anchorage's fit.
  List<AnchorTrackPoint> get _trackSinceDrop {
    final since = widget.config.droppedAt;
    if (since == null) return const [];
    return widget.ownTrack.where((p) => !p.t.isBefore(since)).toList();
  }

  // config.radiusM is the watch's own ALARM radius, usually set with a
  // safety margin above the true taut-chain swing — using it as the
  // "known radius" for the fit meant a real, meaningful swing could still
  // fail the readiness checks below (reported live 2026-09-04: 30° of
  // genuine taut-chain swing still showing "no ha tensado"). When the
  // chain paid out for THIS anchoring is known (config.chainOutM — asked
  // directly in _repositionAnchor, since it's per-drop and can change
  // mid-anchorage, unlike the boat's fixed total chain length) and a
  // current depth reading exists, the true horizontal swing radius is
  // ground truth, not a guess: a straight line from bow roller to anchor
  // is the hypotenuse (chain length) with depth as one leg, so the
  // horizontal leg is sqrt(chain² − depth²) (ignores catenary sag and
  // roller height above the waterline — an accepted simplification, same
  // one the scope panel already uses). Falls back to the configured watch
  // radius only when there's no usable chain/depth pair (e.g. before the
  // user has been asked yet — this getter also drives the toolbar
  // button's live enabled state, which can't wait on a dialog).
  double get _effectiveRepositionRadiusM =>
      _repositionRadiusFor(widget.config.chainOutM);

  double _repositionRadiusFor(double? chainOutM) {
    final depth = widget.depthM;
    if (chainOutM != null &&
        chainOutM > 0 &&
        depth != null &&
        depth > 0 &&
        chainOutM > depth) {
      final horizontal = math.sqrt(
        chainOutM * chainOutM - depth * depth,
      );
      if (horizontal >= 3) return horizontal;
    }
    return widget.config.radiusM;
  }

  // "recolocar automaticamente el ancla en el origen del radio de ese
  // sector" (reported live 2026-09-04) — re-derives the anchor's true
  // position from the arc the boat has actually swung through, which can
  // be more accurate than the originally recorded drop fix. The known
  // radius (_effectiveRepositionRadiusM — ground truth from chain+depth
  // when available) is what makes this reliable down to a fairly narrow
  // swing — see fitAnchorCenterKnownRadius's own doc comment for the
  // method. Null (rather than just "enough points") is also what gates
  // the toolbar button itself — a coarse point-count check alone could
  // leave the button looking enabled while a tap silently did nothing.
  ({double lat, double lon})? get _repositionFit {
    final dropLat = widget.config.dropLat, dropLon = widget.config.dropLon;
    if (dropLat == null || dropLon == null) return null;
    return fitAnchorCenterKnownRadius(
      _trackSinceDrop,
      radiusM: _effectiveRepositionRadiusM,
      refLat: dropLat,
      refLon: dropLon,
    );
  }

  // Why the button is greyed out right now — surfaced as its tooltip.
  // "por qué sale disabled el botón recolocar si hay trazas de 24h"
  // (reported live 2026-09-04): 24h of own-track HISTORY existing doesn't
  // mean the boat has actually SWUNG through much of an arc in that
  // time — calm, steady wind/tide for the whole anchorage genuinely
  // leaves nothing reliable to fit, which is correct, not a bug, but the
  // button gave no indication of why.
  // Explicit \n line breaks — Tooltip's own text does not reliably
  // soft-wrap a long single-line message, it can just overflow past the
  // screen edge instead. Reported live 2026-09-04.
  //
  // Does NOT also pre-check _repositionFit here (unlike before) — that
  // used to require the CONFIGURED watch radius (or a stale/never-entered
  // chain-out value) to already look right before letting the user even
  // try, which could grey the button out forever if that radius happened
  // to be off. _repositionAnchor now asks for the real chain paid out
  // fresh on every tap and only THEN decides whether a fit is possible,
  // reporting that as a message instead of a permanently disabled button.
  String? get _repositionDisabledReason {
    if (!widget.config.armed) return 'Solo con el\nancla fondeada';
    final n = _trackSinceDrop.length;
    if (n < kAnchorRefitMinPoints) {
      return 'Acumulando traza\n($n/$kAnchorRefitMinPoints puntos)';
    }
    return null;
  }

  // "falta una salvaguarda para que no este habilitado el boton si al
  // menos no llava 15 min fondeado" (reported live 2026-09-05) — both
  // borneo and guiñada need real time at anchor to mean anything; opening
  // this right after dropping (now also querying an hour of HISTORY, not
  // just a live buffer) would just show pre-anchoring data or nothing at
  // all, either way not useful.
  static const _minTimeAtAnchor = Duration(minutes: 15);
  String? get _yawAnalysisDisabledReason {
    if (!widget.config.armed) return 'Solo con el\nancla fondeada';
    final droppedAt = widget.config.droppedAt;
    if (droppedAt == null) return 'Solo con el\nancla fondeada';
    final elapsed = skNow().difference(droppedAt);
    if (elapsed < _minTimeAtAnchor) {
      final minsLeft = (_minTimeAtAnchor - elapsed).inMinutes + 1;
      return 'Espera $minsLeft min\nmás fondeado';
    }
    return null;
  }

  // Display-only — the angular span the track has actually swept around
  // the CURRENT drop point, purely for the confirmation dialog's summary
  // (not a gating condition; fitAnchorCenterKnownRadius has its own,
  // stricter checks for whether to trust the fit at all).
  double _swingArcDeg(double refLat, double refLon) {
    final angles =
        [
          for (final p in _trackSinceDrop)
            bearingDistanceMeters(refLat, refLon, p.lat, p.lon).bearingDeg,
        ]..sort();
    if (angles.length < 2) return 0;
    var largestGap = 360.0 - (angles.last - angles.first);
    for (var i = 1; i < angles.length; i++) {
      final gap = angles[i] - angles[i - 1];
      if (gap > largestGap) largestGap = gap;
    }
    return 360.0 - largestGap;
  }

  // Chain paid out is per-drop and can change mid-anchorage (letting out
  // more or recovering some) — asked fresh every time rather than reused
  // silently, pre-filled with whatever was entered last as a convenience.
  // Cancelling (or leaving it blank) falls back to the configured watch
  // radius, same as before this existed.
  Future<double?> _promptChainOutM() async {
    final controller = TextEditingController(
      text: widget.config.chainOutM?.round().toString() ?? '',
    );
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: const Text(
          '¿Cuánta cadena tienes largada?',
          style: TextStyle(color: cText),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: cText),
          decoration: const InputDecoration(
            suffixText: 'm',
            hintText: 'p. ej. 45',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text.replaceAll(',', '.'));
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    return (result != null && result > 0) ? result : null;
  }

  // "no hace nada" (reported live 2026-09-04) — the fit was actually being
  // applied, but a correction is often only a few meters, invisible at a
  // normal map zoom, with nothing telling the user anything happened at
  // all. Now shows exactly what's about to change and asks first — also
  // what was explicitly requested: "resumen de los datos... angulo de
  // borneo, maximo estiramiento de la cadena, modificacion que va a
  // hacer... pregunta si esta de acuerdo". Also asks for the chain paid
  // out first (reported live 2026-09-04: using the boat's fixed total
  // chain length instead gave a nonsensical radius, e.g. 90 m out of only
  // 45 m of actual chain).
  Future<void> _repositionAnchor() async {
    final chainOutM = await _promptChainOutM();
    if (!mounted) return;
    if (chainOutM != null) {
      _updateConfig((c) => c.chainOutM = chainOutM);
    }
    final fit = _repositionFit;
    if (fit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay giro suficiente registrado para calcular una '
            'posición fiable con ese radio.',
          ),
        ),
      );
      return;
    }
    final dropLat = widget.config.dropLat!, dropLon = widget.config.dropLon!;
    final move = bearingDistanceMeters(dropLat, dropLon, fit.lat, fit.lon);
    final arcDeg = _swingArcDeg(dropLat, dropLon);
    final effectiveRadius = _effectiveRepositionRadiusM;
    final radiusFromChain = effectiveRadius != widget.config.radiusM;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: const Text(
          'Recolocar ancla',
          style: TextStyle(color: cText),
        ),
        content: Text(
          'Se ha calculado una posición más precisa a partir del giro '
          'registrado desde que fondeaste.\n\n'
          'Ángulo de borneo: ${arcDeg.round()}°\n'
          'Radio (cadena tensa): ${effectiveRadius.round()} m'
          '${radiusFromChain ? ' (calculado: cadena + profundidad)' : ' (radio configurado)'}\n'
          'Puntos usados: ${_trackSinceDrop.length}\n\n'
          'Quedará a ${move.distanceM.round()} m de la posición actual, '
          'en rumbo ${move.bearingDeg.round()}°.',
          style: const TextStyle(color: cMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Recolocar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!await _ensureLoggedIn()) return;
    HapticFeedback.mediumImpact();
    _updateConfig((c) {
      c.dropLat = fit.lat;
      c.dropLon = fit.lon;
      c.armedOrMovedAt = skNow();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Ancla recolocada — ${move.distanceM.round()} m, '
            'rumbo ${move.bearingDeg.round()}°',
          ),
        ),
      );
    }
  }

  void _openLayersSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cPanel,
      isScrollControlled: true,
      builder: (ctx) => _LayersSheet(
        config: widget.config,
        onChanged: (mutate) => setState(() => _updateConfig(mutate)),
      ),
    );
  }

  Future<void> _openChainDialog() async {
    if (!await _ensureLoggedIn()) return;
    final lat = _effectiveLat, lon = _effectiveLon;
    if (lat == null || lon == null) return;
    if (!mounted) return;
    final result = await showDialog<(double, double)>(
      context: context,
      builder: (ctx) => _ChainDialog(initialBearing: widget.headingDeg ?? 0),
    );
    if (result == null) return;
    final dest = _destinationPoint(ll.LatLng(lat, lon), result.$1, result.$2);
    _updateConfig((c) {
      c.armed = true;
      c.dropLat = dest.latitude;
      c.dropLon = dest.longitude;
      c.dropDepthM ??= widget.depthM;
      c.droppedAt ??= DateTime.now();
      c.armedOrMovedAt = skNow();
    });
  }

  void _openHistoryDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void deleteAt(int historyIndex) {
            final e = widget.config.history[historyIndex];
            // The marker on the map is just a lat/lon snapshot — if it's
            // the entry being deleted, it has to go with it.
            if (_historyMarkerPoint != null &&
                _historyMarkerPoint!.latitude == e.lat &&
                _historyMarkerPoint!.longitude == e.lon) {
              setState(() => _historyMarkerPoint = null);
            }
            _updateConfig(
              (c) => c.history = [...c.history]..removeAt(historyIndex),
            );
            setDialogState(() {});
          }

          return AlertDialog(
            backgroundColor: cPanel,
            title: const Text(
              'Historial de fondeos',
              style: TextStyle(color: cText),
            ),
            content: SizedBox(
              width: 420,
              child: widget.config.history.isEmpty
                  ? const Text(
                      'Todavía no hay fondeos registrados.',
                      style: TextStyle(color: cMuted),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: widget.config.history.length,
                      separatorBuilder: (_, _) =>
                          const Divider(color: Colors.white12),
                      itemBuilder: (_, i) {
                        // Most recent first.
                        final historyIndex =
                            widget.config.history.length - 1 - i;
                        final e = widget.config.history[historyIndex];
                        final duration = e.raisedAt.difference(e.droppedAt);
                        final h = duration.inHours;
                        final m = duration.inMinutes % 60;
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.anchor,
                            color: cCyan,
                            size: 18,
                          ),
                          title: Text(
                            '${e.droppedAt.day.toString().padLeft(2, '0')}/'
                            '${e.droppedAt.month.toString().padLeft(2, '0')}/'
                            '${e.droppedAt.year} '
                            '${e.droppedAt.hour.toString().padLeft(2, '0')}:'
                            '${e.droppedAt.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(color: cText, fontSize: 13),
                          ),
                          subtitle: Text(
                            '${e.lat.toStringAsFixed(5)}, ${e.lon.toStringAsFixed(5)}'
                            ' · radio ${e.radiusM.round()} m'
                            '${e.depthM != null ? ' · ${e.depthM!.toStringAsFixed(1)} m fondo' : ''}'
                            ' · ${h}h ${m}min',
                            style: const TextStyle(color: cMuted, fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: cMuted,
                              size: 18,
                            ),
                            onPressed: () => deleteAt(historyIndex),
                          ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            setState(() {
                              _historyMarkerPoint = ll.LatLng(e.lat, e.lon);
                            });
                            _mapController.move(
                              _historyMarkerPoint!,
                              _mapController.camera.zoom,
                            );
                          },
                        );
                      },
                    ),
            ),
            actions: [
              if (widget.config.history.isNotEmpty)
                TextButton(
                  onPressed: () {
                    _updateConfig((c) => c.history = []);
                    setState(() => _historyMarkerPoint = null);
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Borrar historial'),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cerrar'),
              ),
            ],
          );
        },
      ),
    );
  }

  // Where to put the map camera when there's no live position at all right
  // now (no connection, or none yet) — falls through anchor drop position
  // (if armed — exactly the point a disconnected watch cares about) then
  // the most recent own-track point, so a lost connection shows roughly
  // where the boat actually is instead of flutter_map's (0,0) default,
  // off the coast of Africa. Only truly falls back to (0,0) if nothing at
  // all is known yet (brand new install, never armed, empty track).
  ll.LatLng? get _bestKnownCenter {
    final lat = _effectiveLat, lon = _effectiveLon;
    if (lat != null && lon != null) return ll.LatLng(lat, lon);
    final dropLat = widget.config.dropLat, dropLon = widget.config.dropLon;
    if (widget.config.armed && dropLat != null && dropLon != null) {
      return ll.LatLng(dropLat, dropLon);
    }
    if (widget.ownTrack.isNotEmpty) {
      final last = widget.ownTrack.last;
      return ll.LatLng(last.lat, last.lon);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final lat = _effectiveLat, lon = _effectiveLon;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onEffectivePositionChanged(lat, lon);
    });
    final dropLat = widget.config.dropLat, dropLon = widget.config.dropLon;
    // Bearing FROM the drop point TO the boat — same direction
    // bearingDistanceMeters(dropLat, dropLon, lat, lon) gives main.dart's
    // own _isOutsideAnchorZone for its sector check, so this screen's
    // "outside" verdict below can use the identical convention.
    final fromDrop =
        (lat != null && lon != null && dropLat != null && dropLon != null)
        ? bearingDistanceMeters(dropLat, dropLon, lat, lon)
        : null;
    final distanceM = fromDrop?.distanceM;
    // True bearing from the bow to the anchor — hoekens' navigation.anchor.
    // bearingTrue equivalent, shown alongside distance/radius so the status
    // card carries the same parameters the plugin used to publish.
    final bearingToAnchorDeg =
        (lat != null && lon != null && dropLat != null && dropLon != null)
        ? bearingDistanceMeters(lat, lon, dropLat, dropLon).bearingDeg
        : null;
    // isOutsideWatchZone (models.dart), NOT a bare distance>radius check —
    // for a sector watch, that alone missed being outside the arc while
    // still inside the radius, so this screen could show a calm
    // "FONDEADO" while the real alarm (main.dart's _isOutsideAnchorZone,
    // same function) correctly fired. Reported live 2026-09-04.
    final outside = distanceM != null
        ? isOutsideWatchZone(
            distanceM: distanceM,
            radiusM: widget.config.radiusM,
            shape: widget.config.shape,
            bearingFromDropDeg: fromDrop?.bearingDeg,
            sectorStartDeg: widget.config.sectorStartDeg,
            sectorEndDeg: widget.config.sectorEndDeg,
          )
        : false;
    // Mirrors main.dart's own 10s grace window on the drag alarm (must
    // match — see _isOutsideAnchorZone) so the countdown shown here is
    // actually counting down to when the alarm can really fire, not some
    // separate guess at it.
    int? graceSecondsLeft;
    final armedOrMovedAt = widget.config.armedOrMovedAt;
    if (outside && armedOrMovedAt != null) {
      final elapsed = DateTime.now().difference(armedOrMovedAt);
      if (elapsed < const Duration(seconds: 10)) {
        graceSecondsLeft = 10 - elapsed.inSeconds;
      }
    }
    // Only sample while actually armed and not mid-edit — a drag preview
    // isn't the boat moving, and dropping/raising shouldn't count either.
    final dragSpeedMPerMin = (widget.config.armed && _editMode == null)
        ? _dragSpeedMPerMin(distanceM, outside)
        : null;
    // "Garreando" (actively dragging) vs. just parked outside the circle
    // (swung out once, holding steady there) — 1 m/min is comfortably
    // above GPS jitter but well below any real drag.
    final isDragging =
        outside && dragSpeedMPerMin != null && dragSpeedMPerMin > 1.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onDragStatusChanged?.call(outside, isDragging, dragSpeedMPerMin);
    });

    return Container(
      // Plain black, not the app's usual navy-tinted cBg, when neither map
      // layer is on — a deliberately blank chart, not just "dark theme".
      color: (!widget.config.showSatelliteLayer && !widget.config.showSeamarkLayer)
          ? Colors.black
          : cBg,
      child: Stack(
        children: [
          fm.FlutterMap(
            key: _mapKey,
            mapController: _mapController,
            options: fm.MapOptions(
              // flutter_map's own default (light grey) shows through
              // whenever there's no tile under it — with both layers off
              // that was the actual bug, not the screen's own Container
              // color below it.
              backgroundColor:
                  (!widget.config.showSatelliteLayer &&
                      !widget.config.showSeamarkLayer)
                  ? Colors.black
                  : cBg,
              initialCenter: _bestKnownCenter ?? const ll.LatLng(0, 0),
              initialZoom: 17,
              // Past the satellite source's real native resolution,
              // flutter_map keeps stretching (overzooming) the last tile
              // it actually has to fill the view — a raster image getting
              // crudely upscaled while the (vector, exactly-positioned)
              // AIS/anchor markers stay pixel-precise, which reads exactly
              // like "the map and the markers came out of sync" even
              // though only the imagery is imprecise. Capping zoom here
              // keeps it inside what World Imagery actually resolves at
              // this kind of location; minZoom is just a sane floor.
              minZoom: 3,
              maxZoom: _kMaxMapZoom,
              interactionOptions: fm.InteractionOptions(
                flags: _editMode == null
                    ? fm.InteractiveFlag.all
                    : fm.InteractiveFlag.none,
              ),
            ),
            children: [
              // Independent checkboxes: satellite and OpenSeaMap can each
              // be on, off, or both together (imagery + nautical marks).
              // Neither checked leaves just the screen's plain background.
              if (widget.config.showSatelliteLayer)
                fm.TileLayer(
                  urlTemplate: _kSatelliteTileUrl,
                  userAgentPackageName: 'com.rewindpanel.myapp',
                ),
              if (widget.config.showSeamarkLayer) ...[
                // OpenSeaMap's own marks-only tiles need a street/outline
                // base under them when satellite imagery isn't already
                // providing one, or they'd float on nothing.
                if (!widget.config.showSatelliteLayer)
                  fm.TileLayer(
                    urlTemplate: _kOsmTileUrl,
                    userAgentPackageName: 'com.rewindpanel.myapp',
                  ),
                fm.TileLayer(
                  urlTemplate: _kSeamarkTileUrl,
                  userAgentPackageName: 'com.rewindpanel.myapp',
                ),
              ],
              // Only while actually fondeado — a leftover dropLat/dropLon
              // from the last anchoring (kept around so re-arming remembers
              // where you were) must not paint a watch circle for a boat
              // that isn't anchored right now.
              if (widget.config.armed && dropLat != null && dropLon != null)
                _watchZoneLayer(dropLat, dropLon, outside),
              if (widget.config.showOwnTrack && widget.ownTrack.length >= 2)
                fm.PolylineLayer(
                  // One short polyline per consecutive point pair, each its
                  // own solid color lerped by age — a single 2-stop
                  // gradientColors polyline banded far more coarsely than
                  // this once there were more than a handful of points, per
                  // "muchas más tonos". Points are already chronological
                  // (oldest first, see OwnTrackHistory).
                  polylines: [
                    for (var i = 0; i < widget.ownTrack.length - 1; i++)
                      fm.Polyline(
                        points: [
                          ll.LatLng(
                            widget.ownTrack[i].lat,
                            widget.ownTrack[i].lon,
                          ),
                          ll.LatLng(
                            widget.ownTrack[i + 1].lat,
                            widget.ownTrack[i + 1].lon,
                          ),
                        ],
                        strokeWidth: 0.9,
                        color: _trackAgeColor(
                          i / (widget.ownTrack.length - 1),
                        ),
                      ),
                  ],
                ),
              // Long-press anywhere inside the watch circle: near the rim
              // starts a radius edit, closer to the center moves the
              // anchor — both without needing the toolbar first. Sits
              // below the MarkerLayer so a marker's own gesture wins
              // whenever the press actually lands on one.
              if (widget.config.armed && dropLat != null && dropLon != null)
                Positioned.fill(child: _insideCircleDetector(dropLat, dropLon)),
              // Rode line from the bow to the anchor, always on while
              // fondeado — not just during an edit — so it's always clear
              // at a glance where the chain runs. Hidden mid-drag, when the
              // dotted preview line below takes over the same job.
              if (widget.config.armed &&
                  dropLat != null &&
                  dropLon != null &&
                  lat != null &&
                  lon != null &&
                  _editMode != 'anchor')
                fm.PolylineLayer(
                  polylines: [
                    fm.Polyline(
                      points: [ll.LatLng(lat, lon), ll.LatLng(dropLat, dropLon)],
                      strokeWidth: 1.5,
                      color: cCyan.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              // Rode line from the bow to wherever the anchor is being
              // dragged right now — live, not just on Confirm, so the
              // distance/bearing readout means something while you're
              // still deciding where to drop it.
              if (_editMode == 'anchor' &&
                  _dragAnchor != null &&
                  lat != null &&
                  lon != null)
                fm.PolylineLayer(
                  polylines: [
                    fm.Polyline(
                      points: [ll.LatLng(lat, lon), _dragAnchor!],
                      strokeWidth: 2,
                      color: cYellow,
                      pattern: const fm.StrokePattern.dotted(),
                    ),
                  ],
                ),
              fm.MarkerLayer(markers: _markers(dropLat, dropLon, lat, lon)),
            ],
          ),
          if (_editMode != null) _editBanner(),
          Positioned(
            top: 10,
            left: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusPanel(
                  distanceM,
                  bearingToAnchorDeg,
                  outside,
                  isDragging,
                  dragSpeedMPerMin,
                  graceSecondsLeft,
                ),
                if (_usingDeviceGpsAsSource) _deviceGpsBanner(),
                if (widget.config.showWind) ...[
                  const SizedBox(height: 8),
                  _windPanel(),
                ],
                if (widget.config.showDepth) ...[
                  const SizedBox(height: 8),
                  _hudPanel(
                    'PROFUNDIDAD',
                    widget.depthM != null
                        ? '${widget.depthM!.toStringAsFixed(1)} m'
                        : '--',
                    cOrange,
                  ),
                ],
                if (widget.config.showScope && widget.depthM != null) ...[
                  const SizedBox(height: 8),
                  _scopePanel(),
                ],
              ],
            ),
          ),
          Positioned(bottom: 14, left: 0, right: 0, child: _bottomToolbar()),
          // Anchored from the top, not the bottom — bottom-anchoring grew
          // this stack of 6 buttons *upward*, and on a phone's shorter
          // viewport that pushed the top ones (layers) up under the app's
          // own header bar. Anchoring from the top instead means it only
          // ever grows down, toward the bottom toolbar, never up into the
          // header — and SingleChildScrollView is a safety net if a
          // screen's still too short to fit all six.
          Positioned(
            right: 10,
            top: 10,
            bottom: 70,
            child: SingleChildScrollView(
              child: _mapControlCluster(dropLat, dropLon, lat, lon),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapControlCluster(
    double? dropLat,
    double? dropLon,
    double? lat,
    double? lon,
  ) => Column(
    children: [
      _miniMapBtn(Icons.layers, _openLayersSheet),
      const SizedBox(height: 14),
      _miniMapBtn(
        Icons.add,
        () => _mapController.move(
          _mapController.camera.center,
          (_mapController.camera.zoom + 1).clamp(3, _kMaxMapZoom),
        ),
      ),
      const SizedBox(height: 6),
      _miniMapBtn(
        Icons.remove,
        () => _mapController.move(
          _mapController.camera.center,
          (_mapController.camera.zoom - 1).clamp(3, _kMaxMapZoom),
        ),
      ),
      const SizedBox(height: 14),
      _miniMapBtn(
        Icons.anchor,
        (dropLat == null || dropLon == null)
            ? null
            // Recentering is also a reasonable moment to snap back to
            // north-up, in case anything ever leaves the map rotated.
            : () {
                _mapController.moveAndRotate(
                  ll.LatLng(dropLat, dropLon),
                  _mapController.camera.zoom,
                  0,
                );
              },
      ),
      const SizedBox(height: 6),
      _miniMapBtn(
        Icons.navigation,
        (lat == null || lon == null)
            ? null
            : () {
                _mapController.moveAndRotate(
                  ll.LatLng(lat, lon),
                  _mapController.camera.zoom,
                  0,
                );
              },
      ),
      if (widget.onToggleAlarmsMuted != null) ...[
        const SizedBox(height: 14),
        _miniMapBtn(
          widget.alarmsMuted ? Icons.volume_off : Icons.volume_up,
          widget.onToggleAlarmsMuted,
          active: widget.alarmsMuted,
        ),
      ],
    ],
  );

  Widget _miniMapBtn(IconData icon, VoidCallback? onTap, {bool active = false}) =>
      Material(
        color: active ? cYellow : cPanel.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              icon,
              size: 18,
              color: onTap == null
                  ? cMuted.withValues(alpha: 0.4)
                  : (active ? Colors.black : cText),
            ),
          ),
        ),
      );

  Widget _insideCircleDetector(double dropLat, double dropLon) =>
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        // A plain short tap anywhere is the fastest way to say "done" —
        // applies whatever's being dragged, same as Confirm.
        onTap: _editMode == null ? null : _confirmEdit,
        onLongPressStart: (d) {
          final latLng = _globalToLatLng(d.globalPosition);
          if (latLng == null) return;
          final anchor = ll.LatLng(dropLat, dropLon);
          var mode = _editMode;
          if (mode == null) {
            final r = bearingDistanceMeters(
              dropLat,
              dropLon,
              latLng.latitude,
              latLng.longitude,
            );
            if (r.distanceM > widget.config.radiusM) return;
            mode = r.distanceM > widget.config.radiusM * 0.7
                ? 'radius'
                : 'anchor';
          }
          HapticFeedback.mediumImpact();
          _resetEditTimeout();
          setState(() {
            _editMode = mode;
            _dragAnchor = anchor;
            if (mode == 'radius') {
              _dragRadiusM = widget.config.radiusM;
              _dragSectorStartDeg = widget.config.sectorStartDeg;
              _dragSectorEndDeg = widget.config.sectorEndDeg;
            }
          });
        },
        onLongPressMoveUpdate: (d) {
          if (_editMode == null) return;
          final latLng = _globalToLatLng(d.globalPosition);
          if (latLng == null) return;
          _resetEditTimeout();
          setState(() {
            if (_editMode == 'anchor') {
              _dragAnchor = latLng;
            } else if (_editMode == 'radius' && _dragAnchor != null) {
              _dragRadiusM = bearingDistanceMeters(
                _dragAnchor!.latitude,
                _dragAnchor!.longitude,
                latLng.latitude,
                latLng.longitude,
              ).distanceM.clamp(5, 300);
            }
          });
        },
      );

  fm.PolygonLayer _watchZoneLayer(
    double dropLat,
    double dropLon,
    bool outside,
  ) {
    final center = _dragAnchor ?? ll.LatLng(dropLat, dropLon);
    final radius = _dragRadiusM ?? widget.config.radiusM;
    final points = widget.config.shape == 'sector'
        ? _sectorPoints(
            center,
            radius,
            _dragSectorStartDeg ?? widget.config.sectorStartDeg ?? 0,
            _dragSectorEndDeg ?? widget.config.sectorEndDeg ?? 90,
          )
        : _circlePoints(center, radius);
    return fm.PolygonLayer(
      polygons: [
        fm.Polygon(
          points: points,
          color: (outside ? cRed : cGreen).withValues(alpha: 0.12),
          borderColor: (outside ? cRed : cGreen).withValues(alpha: 0.8),
          borderStrokeWidth: outside ? 4 : 2,
        ),
      ],
    );
  }

  List<ll.LatLng> _circlePoints(ll.LatLng center, double radiusM) => [
    for (var i = 0; i <= 64; i++)
      _destinationPoint(center, radiusM, i * 360 / 64),
  ];

  List<ll.LatLng> _sectorPoints(
    ll.LatLng center,
    double radiusM,
    double startDeg,
    double endDeg,
  ) {
    final span = (endDeg - startDeg + 360) % 360;
    const steps = 32;
    return [
      center,
      for (var i = 0; i <= steps; i++)
        _destinationPoint(center, radiusM, startDeg + span * i / steps),
      center,
    ];
  }

  ll.LatLng _destinationPoint(
    ll.LatLng from,
    double distanceM,
    double bearingDeg,
  ) {
    const earthR = 6371000.0;
    final brgRad = bearingDeg * math.pi / 180;
    final lat1 = from.latitude * math.pi / 180;
    final lon1 = from.longitude * math.pi / 180;
    final lat2 = math.asin(
      math.sin(lat1) * math.cos(distanceM / earthR) +
          math.cos(lat1) * math.sin(distanceM / earthR) * math.cos(brgRad),
    );
    final lon2 =
        lon1 +
        math.atan2(
          math.sin(brgRad) * math.sin(distanceM / earthR) * math.cos(lat1),
          math.cos(distanceM / earthR) - math.sin(lat1) * math.sin(lat2),
        );
    return ll.LatLng(lat2 * 180 / math.pi, lon2 * 180 / math.pi);
  }

  // One of the sector's two boundary handles — dragging it changes ONLY
  // that limit's bearing (recomputed from the anchor to wherever the
  // finger is), independent of the radius handle and of the other limit.
  fm.Marker _sectorLimitHandle({
    required ll.LatLng anchorPoint,
    required double radius,
    required bool isStart,
  }) {
    final currentDeg =
        (isStart
            ? _dragSectorStartDeg ?? widget.config.sectorStartDeg
            : _dragSectorEndDeg ?? widget.config.sectorEndDeg) ??
        (isStart ? 0.0 : 90.0);
    final handlePoint = _destinationPoint(anchorPoint, radius, currentDeg);
    void updateFromTouch(Offset globalPosition) {
      final latLng = _globalToLatLng(globalPosition);
      if (latLng == null) return;
      _resetEditTimeout();
      final bearing = bearingDistanceMeters(
        anchorPoint.latitude,
        anchorPoint.longitude,
        latLng.latitude,
        latLng.longitude,
      ).bearingDeg;
      setState(() {
        if (isStart) {
          _dragSectorStartDeg = bearing;
        } else {
          _dragSectorEndDeg = bearing;
        }
      });
    }

    return fm.Marker(
      point: handlePoint,
      width: 22,
      height: 22,
      child: GestureDetector(
        onPanUpdate: (d) => updateFromTouch(d.globalPosition),
        onLongPressStart: (d) => updateFromTouch(d.globalPosition),
        onLongPressMoveUpdate: (d) => updateFromTouch(d.globalPosition),
        child: Container(
          decoration: BoxDecoration(
            color: cOrange,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black38, width: 1.5),
          ),
          child: Icon(
            isStart ? Icons.rotate_left : Icons.rotate_right,
            size: 13,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }

  List<fm.Marker> _markers(
    double? dropLat,
    double? dropLon,
    double? lat,
    double? lon,
  ) {
    final markers = <fm.Marker>[];
    final previewAnchor =
        _dragAnchor ??
        (dropLat != null && dropLon != null
            ? ll.LatLng(dropLat, dropLon)
            : null);
    if (lat != null && lon != null) {
      // Bow points at the real heading when we have one; with no heading
      // source at all, point it at the anchor instead — a real heading
      // still overrides that even while the anchor's being dragged, since
      // it's the boat's actual attitude and not a guess.
      final shipAngleDeg =
          widget.headingDeg ??
          (previewAnchor != null
              ? bearingDistanceMeters(
                  lat,
                  lon,
                  previewAnchor.latitude,
                  previewAnchor.longitude,
                ).bearingDeg
              : 0);
      markers.add(
        fm.Marker(
          point: ll.LatLng(lat, lon),
          width: 50,
          height: 50,
          child: Transform.rotate(
            angle: shipAngleDeg * math.pi / 180,
            // fit: contain — the source PNG is a large, non-square image
            // (loaded full-size elsewhere via a ui.Image canvas draw); left
            // unconstrained here it rendered outside the tiny marker box
            // and never showed up on screen at all.
            child: Image.asset(widget.shipIconAsset, fit: BoxFit.contain),
          ),
        ),
      );
      // A small arrow anchored a short distance upwind of the boat,
      // pointing back at it — true wind-source bearing needs a real
      // heading (AWA is bow-relative, not true), so this only appears
      // once one's actually available, never off the anchor-bearing
      // fallback used for the hull's own rotation above.
      if (widget.config.showWind &&
          widget.headingDeg != null &&
          widget.awaDeg != null) {
        // NOT the same +180 the panel dial needed — confirmed live 2026-09-01
        // that this map placement/rotation was already correct with the
        // plain heading+AWA sum; adding +180 here (to match the dial fix)
        // flipped it 180° wrong.
        final windSourceTrueDeg = (widget.headingDeg! + widget.awaDeg!) % 360;
        // Anchored AT the boat's own point, offset in pixel space (Align +
        // an outer rotation, both screen-space) rather than a real geo
        // distance — a fixed number of meters visually crept closer/further
        // from the boat as you zoomed in and out, which a fixed pixel
        // offset doesn't.
        markers.add(
          fm.Marker(
            point: ll.LatLng(lat, lon),
            width: 90,
            height: 90,
            child: IgnorePointer(
              child: Transform.rotate(
                angle: windSourceTrueDeg * math.pi / 180,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Transform.rotate(
                    // Drawn "up" by default (points away from center at
                    // the top of the box) — flipped 180° here so it always
                    // points back in, at the boat, regardless of the
                    // group rotation above.
                    angle: math.pi,
                    child: _WindArrowIcon(
                      color: _windArrowColor,
                      size: 24,
                      shadow: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      // Live distance/bearing from the bow to wherever the anchor is right
      // now — only while actually moving it, updates every drag frame.
      if (_editMode == 'anchor' && previewAnchor != null) {
        final r = bearingDistanceMeters(
          lat,
          lon,
          previewAnchor.latitude,
          previewAnchor.longitude,
        );
        markers.add(
          fm.Marker(
            point: ll.LatLng(lat, lon),
            width: 110,
            height: 24,
            alignment: const Alignment(0, 2.4),
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${r.distanceM.round()} m · ${r.bearingDeg.round()}°',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: cYellow,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    if (widget.config.armed && dropLat != null && dropLon != null) {
      final anchorPoint = _dragAnchor ?? ll.LatLng(dropLat, dropLon);
      markers.add(
        fm.Marker(
          point: anchorPoint,
          width: 40,
          height: 40,
          child: GestureDetector(
            // Long-press still gates the FIRST touch when nothing's armed
            // yet — a safety net against a stray tap on the map. But once
            // the "Mover ancla" toolbar button has already put us in
            // _editMode == 'anchor', a plain drag moves it immediately;
            // no reason to make the user hold down twice.
            onLongPressStart: (_) {
              HapticFeedback.mediumImpact();
              _resetEditTimeout();
              setState(() {
                _editMode = 'anchor';
                _dragAnchor = anchorPoint;
              });
            },
            onLongPressMoveUpdate: (d) {
              final latLng = _globalToLatLng(d.globalPosition);
              if (latLng == null) return;
              _resetEditTimeout();
              setState(() => _dragAnchor = latLng);
            },
            onPanUpdate: (d) {
              if (_editMode != 'anchor') return;
              final latLng = _globalToLatLng(d.globalPosition);
              if (latLng == null) return;
              _resetEditTimeout();
              setState(() => _dragAnchor = latLng);
            },
            child: Icon(
              Icons.anchor,
              color: _editMode == 'anchor' ? cYellow : cText,
              size: 24,
              shadows: const [
                Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(1, 1.5)),
              ],
            ),
          ),
        ),
      );
      // Radius handle — sits on the circle rim, due east of the anchor —
      // shown for ANY active edit, not just radius mode specifically: a
      // long-press inside the circle (or on the anchor) should offer both
      // position and radius as things that might change, not force a
      // choice between them up front.
      if (_editMode != null) {
        final isSector = widget.config.shape == 'sector';
        // On the sector's bisector rather than fixed due-east, so it
        // doesn't sit on top of (or right next to) the two limit handles
        // below when the sector happens to span east.
        final radiusHandleBearing = isSector
            ? ((_dragSectorStartDeg ?? widget.config.sectorStartDeg ?? 0) +
                      (((_dragSectorEndDeg ?? widget.config.sectorEndDeg ?? 90) -
                                  (_dragSectorStartDeg ??
                                      widget.config.sectorStartDeg ??
                                      0) +
                              360) %
                          360) /
                          2) %
                  360
            : 90.0;
        final handlePoint = _destinationPoint(
          anchorPoint,
          _dragRadiusM ?? widget.config.radiusM,
          radiusHandleBearing,
        );
        markers.add(
          fm.Marker(
            point: handlePoint,
            width: 22,
            height: 22,
            child: GestureDetector(
              onLongPressStart: (_) {
                HapticFeedback.mediumImpact();
                _resetEditTimeout();
                setState(() {
                  _editMode = 'radius';
                  _dragAnchor = anchorPoint;
                  _dragRadiusM = widget.config.radiusM;
                  _dragSectorStartDeg = widget.config.sectorStartDeg;
                  _dragSectorEndDeg = widget.config.sectorEndDeg;
                });
              },
              onLongPressMoveUpdate: (d) {
                if (_dragAnchor == null) return;
                final latLng = _globalToLatLng(d.globalPosition);
                if (latLng == null) return;
                _resetEditTimeout();
                setState(() {
                  _dragRadiusM = bearingDistanceMeters(
                    _dragAnchor!.latitude,
                    _dragAnchor!.longitude,
                    latLng.latitude,
                    latLng.longitude,
                  ).distanceM.clamp(5, 300);
                });
              },
              // The handle only exists once _editMode == 'radius' already
              // (via the "Radio" toolbar button or the long-press above),
              // so a plain drag here works immediately — no second
              // sustained press needed on top of the one that got us here.
              onPanUpdate: (d) {
                if (_dragAnchor == null) return;
                final latLng = _globalToLatLng(d.globalPosition);
                if (latLng == null) return;
                _resetEditTimeout();
                setState(() {
                  _dragRadiusM = bearingDistanceMeters(
                    _dragAnchor!.latitude,
                    _dragAnchor!.longitude,
                    latLng.latitude,
                    latLng.longitude,
                  ).distanceM.clamp(5, 300);
                });
              },
              child: Container(
                decoration: BoxDecoration(
                  color: _editMode == 'radius' ? cYellow : cCyan,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black38, width: 1.5),
                ),
              ),
            ),
          ),
        );
        if (isSector) {
          markers.add(
            _sectorLimitHandle(
              anchorPoint: anchorPoint,
              radius: _dragRadiusM ?? widget.config.radiusM,
              isStart: true,
            ),
          );
          markers.add(
            _sectorLimitHandle(
              anchorPoint: anchorPoint,
              radius: _dragRadiusM ?? widget.config.radiusM,
              isStart: false,
            ),
          );
        }
      }
    }
    if (widget.config.showAisNearby) {
      for (final t in widget.aisTargets) {
        if (t.lat == null || t.lon == null) continue;
        // No AIS navigation-state field tracked yet — SOG is the practical
        // proxy for "anchored" vs. "underway" here.
        final anchored = (t.sogKn ?? 0) < 0.5;
        markers.add(
          fm.Marker(
            point: ll.LatLng(t.lat!, t.lon!),
            width: 110,
            height: 36,
            // NOT centerLeft — flutter_map's alignment describes where the
            // BOX sits relative to point, not where point sits in the box.
            // centerLeft puts the box (and its icon, at the box's own left
            // edge) to the LEFT of point — a ~108px screen offset, constant
            // in pixels but representing more real-world meters the further
            // you zoom out, which is exactly the "only wrong in longitude,
            // worse at low zoom" bug reported 2026-09-01. centerRight puts
            // the box's LEFT edge (where the icon sits) at the true point,
            // with the label trailing away to the right instead.
            alignment: Alignment.centerRight,
            child: Row(
              children: [
                Transform.rotate(
                  // Same bow-up icon set/rotation convention as own_ship.png
                  // — the one boat icon for every AIS target, just tinted
                  // by state, rather than a per-type SVG.
                  angle: (t.cogDeg ?? 0) * math.pi / 180,
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      anchored ? cPurple : cYellow,
                      BlendMode.modulate,
                    ),
                    child: Image.asset(
                      'assets/img/boats/pequeno/jeanneau-sun-odyssey-45-2-2000.png',
                      width: 26,
                      height: 26,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(
                    t.name ?? t.mmsi ?? '?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: cText,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    if (_historyMarkerPoint != null) {
      markers.add(
        fm.Marker(
          point: _historyMarkerPoint!,
          width: 22,
          height: 22,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: cPurple.withValues(alpha: 0.55),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  Widget _editBanner() => Positioned(
    top: 8,
    left: 0,
    right: 0,
    child: IgnorePointer(
      ignoring: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: cYellow,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.pan_tool_alt, color: Colors.black, size: 18),
              const SizedBox(width: 8),
              Text(
                _editMode == 'anchor'
                    ? 'Mantén pulsado y arrastra el ancla — luego confirma'
                    : 'Mantén pulsado y arrastra el radio'
                          '${_dragRadiusM != null ? ' (${_dragRadiusM!.round()} m)' : ''}',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              _miniBtn('Cancelar', _cancelEdit),
              const SizedBox(width: 6),
              _miniBtn('Confirmar', _confirmEdit, filled: true),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _miniBtn(String label, VoidCallback onTap, {bool filled = false}) =>
      Material(
        color: filled ? Colors.black87 : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                color: filled ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ),
      );

  // 0–180° + side, not a signed true bearing — "40° Br" reads directly off
  // the bow, "350° true" needs the reader to do the compass math
  // themselves. Falls back to the raw true bearing if there's no heading
  // to measure the demora relative to.
  String _demoraLabel(double bearingTrueDeg) {
    final heading = widget.headingDeg;
    if (heading == null) return '${bearingTrueDeg.round()}°';
    final rel = ((bearingTrueDeg - heading + 540) % 360) - 180; // -180..180
    return '${rel.abs().round()}° ${rel >= 0 ? 'Er' : 'Br'}';
  }

  Widget _statusPanel(
    double? distanceM,
    double? bearingToAnchorDeg,
    bool outside,
    bool isDragging,
    double? dragSpeedMPerMin,
    int? graceSecondsLeft,
  ) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: cPanel.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: outside ? cRed : cCyan.withValues(alpha: 0.4),
        width: outside ? 2 : 1,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Builder(
          builder: (context) {
            final label = !widget.config.armed
                ? 'SIN ARMAR'
                // Without a live connection the app has no idea what's
                // actually true right now — a stale local "armed" flag is
                // not the same as confirmed "still fine, still anchored".
                : !widget.skConnected
                ? 'SIN CONEXIÓN'
                : !outside
                ? 'FONDEADO'
                // Actively moving away vs. parked outside the circle —
                // both need attention, but only one is a live drag.
                : (isDragging ? 'GARREANDO' : 'FUERA DEL CÍRCULO');
            final color = !widget.config.armed
                ? cMuted
                : !widget.skConnected
                ? cOrange
                : (outside ? cRed : cGreen);
            final text = Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            );
            // TEMPORARY 2026-09-04: substitutes for the alarm sound, which
            // is off right now while testing garreo detection (see
            // main.dart's _activeAlarms) — a blinking status makes a
            // triggered test just as unmissable without the noise. Revert
            // (or keep, if it turns out worth keeping) once the sound is
            // back on.
            return isDragging ? _Blink(child: text) : text;
          },
        ),
        if (widget.config.armed && distanceM != null)
          Text(
            '${distanceM.round()} m / ${widget.config.radiusM.round()} m'
            '${bearingToAnchorDeg != null ? ' · ${_demoraLabel(bearingToAnchorDeg)}' : ''}',
            style: const TextStyle(color: cText, fontSize: 13),
          ),
        if (isDragging && dragSpeedMPerMin != null)
          Text(
            'Alejándose ${dragSpeedMPerMin.toStringAsFixed(1)} m/min',
            style: const TextStyle(
              color: cRed,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        // Fuera del círculo but still inside the 10s grace window after
        // arming/moving — the alarm hasn't (and won't yet) actually fire,
        // shown loudly so it doesn't read as a silent failure.
        if (graceSecondsLeft != null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cRed,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Alarma en $graceSecondsLeft s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    ),
  );

  // Deliberately loud, not a small caption tucked in the status card — if
  // you forget you're on the phone's own GPS and walk off with it, that's
  // exactly the false-drag-alarm scenario this screen needs to make
  // impossible to miss.
  Widget _deviceGpsBanner() => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: cOrange,
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.smartphone, color: Colors.black, size: 15),
        SizedBox(width: 6),
        Text(
          'Usando GPS del móvil, no del barco',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );

  Widget _windPanel() {
    final gust = widget.gustKn;
    final aws = widget.awsKn;
    final awa = widget.awaDeg;
    return GestureDetector(
      onLongPress: _showWindDebugDialog,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cPanel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'VIENTO',
                style: TextStyle(
                  color: cMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    aws != null
                        ? '${aws.toStringAsFixed(0)} kt'
                        : '--',
                    style: const TextStyle(
                      color: cCyan,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  if (widget.twdDeg != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      'TWD ${widget.twdDeg!.round()}°',
                      style: const TextStyle(color: cText, fontSize: 13),
                    ),
                  ],
                  if (awa != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      'AWA ${awa.abs().round()}°',
                      style: const TextStyle(color: cText, fontSize: 13),
                    ),
                  ],
                  // Which side the wind is on — green (starboard) points
                  // left, red (port) points right, alongside (not instead
                  // of) the number above.
                  if (awa != null) ...[
                    const SizedBox(width: 2),
                    Icon(
                      awa >= 0 ? Icons.arrow_left : Icons.play_arrow,
                      color: awa >= 0 ? cGreen : cRed,
                      size: 18,
                    ),
                  ],
                ],
              ),
              // Steady reading vs. the latest gust, kept visually separate —
              // conflating them under one number hides exactly the swing
              // that matters when judging how much scope to pay out.
              // "Racha" here means the highest raw AWS sample in the last
              // 30 min — shown with its own age, since a 24kt gust from 18
              // min ago reads very differently from one that just happened.
              if (gust != null)
                Text(
                  widget.gustAgeMin != null && widget.gustAgeMin! > 0
                      ? 'Racha ${gust.toStringAsFixed(0)} kt · hace ${widget.gustAgeMin} min'
                      : 'Racha ${gust.toStringAsFixed(0)} kt · ahora',
                  style: const TextStyle(color: cMuted, fontSize: 11),
                ),
            ],
          ),
          if (awa != null) ...[
            const SizedBox(width: 10),
            _windDirectionDial(awa),
          ],
        ],
      ),
      ),
    );
  }

  void _showWindDebugDialog() {
    final mean = widget.windMeanKn;
    final stddev = widget.windStddevKn;
    final peak = widget.windPeak3sKn;
    final floor = widget.windGustFloorKn;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cPanel,
        title: const Text(
          'Detección de racha',
          style: TextStyle(color: cText),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mean == null || stddev == null || peak == null)
              const Text(
                'Todavía no hay suficiente historial (se necesitan al '
                'menos ~30 muestras en los últimos 10 min) para calcular '
                'la media y desviación estándar.',
                style: TextStyle(color: cMuted, fontSize: 13),
              )
            else ...[
              _debugRow('Viento estable (media 10 min)', '${mean.toStringAsFixed(1)} kt'),
              _debugRow('Desviación estándar', '${stddev.toStringAsFixed(2)} kt'),
              _debugRow('Umbral 3σ', '${(mean + 3 * stddev).toStringAsFixed(1)} kt'),
              _debugRow(
                'Piso absoluto',
                '${(mean + (floor ?? 0)).toStringAsFixed(1)} kt (media + ${(floor ?? 0).toStringAsFixed(1)} kt)',
              ),
              const Divider(color: Colors.white24),
              _debugRow('Pico últimos 3 s', '${peak.toStringAsFixed(1)} kt'),
              _debugRow(
                '¿Racha ahora?',
                widget.isGusting ? 'SÍ' : 'no',
                valueColor: widget.isGusting ? cRed : cGreen,
              ),
            ],
          ],
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

  Widget _debugRow(String label, String value, {Color? valueColor}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: cMuted, fontSize: 12)),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? cText,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  // A small self-contained "wind vane" — the tick at the top is the bow
  // (this dial doesn't rotate with the boat's true heading, just shows AWA
  // relative to it), and the arrow points at where the wind is actually
  // coming from, same graphic language as the map's own wind arrow below.
  Widget _windDirectionDial(double awaDeg) => SizedBox(
    width: 38,
    height: 38,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cBg.withValues(alpha: 0.5),
            border: Border.all(color: Colors.white24),
          ),
        ),
        Positioned(
          top: 3,
          child: Container(width: 2, height: 6, color: cMuted),
        ),
        Transform.rotate(
          angle: (awaDeg + 180) * math.pi / 180,
          child: _WindArrowIcon(color: _windArrowColor, size: 26),
        ),
      ],
    ),
  );

  Widget _hudPanel(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: cPanel.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: cMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
      ],
    ),
  );

  Widget _scopePanel() {
    final depth = widget.depthM ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cPanel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'SCOPE — CUÁNTA CADENA SEGÚN LA PROFUNDIDAD',
            style: TextStyle(
              color: cMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          Wrap(
            spacing: 10,
            children: [
              for (final ratio in widget.config.scopeRatios)
                Text(
                  '$ratio:1 → ${(depth * ratio).round()} m',
                  style: const TextStyle(color: cText, fontSize: 12),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bottomToolbar() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
      _toolBtn(
        widget.config.shape == 'circle'
            ? Icons.circle_outlined
            : Icons.pie_chart_outline,
        widget.config.shape == 'circle' ? 'Círculo' : 'Sector',
        () {
          final lat = _effectiveLat, lon = _effectiveLon;
          final dropLat = widget.config.dropLat, dropLon = widget.config.dropLon;
          setState(() {
            _updateConfig((c) {
              c.shape = c.shape == 'circle' ? 'sector' : 'circle';
              if (c.shape == 'sector') {
                // Centered on the anchor→boat bearing, 30° either side —
                // the boat's own current position is inside the sector
                // from the moment you switch, not some arbitrary default.
                final centerDeg =
                    (lat != null &&
                        lon != null &&
                        dropLat != null &&
                        dropLon != null)
                    ? bearingDistanceMeters(dropLat, dropLon, lat, lon).bearingDeg
                    : 0.0;
                c.sectorStartDeg = (centerDeg - 30) % 360;
                c.sectorEndDeg = (centerDeg + 30) % 360;
              }
            });
            // Straight into edit mode — the limits are meant to be
            // adjusted right away, not found again via a second gesture.
            if (widget.config.shape == 'sector' &&
                dropLat != null &&
                dropLon != null) {
              _resetEditTimeout();
              _editMode = 'radius';
              _dragAnchor = ll.LatLng(dropLat, dropLon);
              _dragRadiusM = widget.config.radiusM;
              _dragSectorStartDeg = widget.config.sectorStartDeg;
              _dragSectorEndDeg = widget.config.sectorEndDeg;
            }
          });
        },
      ),
      const SizedBox(width: 8),
      _toolBtn(Icons.straighten, 'Cadena', _openChainDialog),
      const SizedBox(width: 8),
      _toolBtn(Icons.history, 'Historial', _openHistoryDialog),
      const SizedBox(width: 8),
      _toolBtn(
        Icons.open_with,
        'Mover ancla',
        !widget.config.armed || widget.config.dropLat == null
            ? null
            : () {
                if (_editMode == 'anchor') {
                  _confirmEdit();
                  return;
                }
                _resetEditTimeout();
                setState(() {
                  _editMode = 'anchor';
                  _dragAnchor = ll.LatLng(
                    widget.config.dropLat!,
                    widget.config.dropLon!,
                  );
                });
              },
        active: _editMode == 'anchor',
      ),
      const SizedBox(width: 8),
      _toolBtn(
        Icons.radar,
        'Radio',
        !widget.config.armed || widget.config.dropLat == null
            ? null
            : () {
                if (_editMode == 'radius') {
                  _confirmEdit();
                  return;
                }
                _resetEditTimeout();
                setState(() {
                  _editMode = 'radius';
                  _dragAnchor = ll.LatLng(
                    widget.config.dropLat!,
                    widget.config.dropLon!,
                  );
                  _dragRadiusM = widget.config.radiusM;
                  _dragSectorStartDeg = widget.config.sectorStartDeg;
                  _dragSectorEndDeg = widget.config.sectorEndDeg;
                });
              },
        active: _editMode == 'radius',
      ),
      const SizedBox(width: 8),
      _toolBtn(
        Icons.center_focus_strong,
        'Recolocar',
        (!widget.config.armed || _trackSinceDrop.length < kAnchorRefitMinPoints)
            ? null
            : _repositionAnchor,
        disabledReason: _repositionDisabledReason,
      ),
      const SizedBox(width: 8),
      _toolBtn(
        Icons.ssid_chart,
        'Guiñada',
        _yawAnalysisDisabledReason == null ? widget.onOpenYawAnalysis : null,
        disabledReason: _yawAnalysisDisabledReason,
      ),
      const SizedBox(width: 14),
      FilledButton.icon(
        onPressed: widget.config.armed ? _raiseAnchor : _dropAnchor,
        style: FilledButton.styleFrom(
          backgroundColor: widget.config.armed ? cRed : cGreen,
          foregroundColor: Colors.black,
        ),
        icon: const Icon(Icons.anchor),
        label: Text(widget.config.armed ? 'Levar' : 'Fondear'),
      ),
      ],
    ),
  );

  Widget _toolBtn(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool active = false,
    String? disabledReason,
  }) => Tooltip(
    // Only actually shown while disabled — "por qué sale disabled" was
    // otherwise a dead end with no way to tell "not armed" apart from
    // "not enough swing recorded yet" from looking at the button alone.
    // Reported live 2026-09-04.
    message: onTap == null ? (disabledReason ?? '') : '',
    triggerMode: TooltipTriggerMode.tap,
    child: Material(
      color: active ? cCyan : cPanel,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: onTap == null
                    ? cMuted.withValues(alpha: 0.4)
                    : (active ? Colors.black : cText),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  color: onTap == null
                      ? cMuted.withValues(alpha: 0.4)
                      : (active ? Colors.black : cMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// A slim shaft + triangular head, pointing "up" at angle 0 — used both as
// the small wind-vane dial in the wind panel and, rotated geographically,
// as the arrow anchored upwind of the boat on the chart itself.
class _WindArrowIcon extends StatelessWidget {
  const _WindArrowIcon({
    required this.color,
    this.size = 22,
    this.shadow = false,
  });
  final Color color;
  final double size;
  final bool shadow;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size, size),
    painter: _WindArrowPainter(color: color, shadow: shadow),
  );
}

class _WindArrowPainter extends CustomPainter {
  _WindArrowPainter({required this.color, required this.shadow});
  final Color color;
  final bool shadow;

  void _drawArrow(Canvas canvas, Size size, Color color, {double? blurSigma}) {
    final w = size.width, h = size.height, cx = w / 2;
    final shaftPaint = Paint()
      ..color = color
      ..strokeWidth = w * 0.16
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (blurSigma != null) {
      shaftPaint.maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
    }
    canvas.drawLine(Offset(cx, h * 0.94), Offset(cx, h * 0.32), shaftPaint);
    final headPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    if (blurSigma != null) {
      headPaint.maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
    }
    canvas.drawPath(
      Path()
        ..moveTo(cx, h * 0.02)
        ..lineTo(cx - w * 0.26, h * 0.38)
        ..lineTo(cx + w * 0.26, h * 0.38)
        ..close(),
      headPaint,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // A soft blurred duplicate, offset slightly down-right, in place of a
    // flat backdrop shape — reads as a drop shadow, not a plate behind it.
    if (shadow) {
      canvas.save();
      canvas.translate(1.2, 1.6);
      _drawArrow(canvas, size, Colors.black.withValues(alpha: 0.45), blurSigma: 1.1);
      canvas.restore();
    }
    _drawArrow(canvas, size, color);
  }

  @override
  bool shouldRepaint(covariant _WindArrowPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.shadow != shadow;
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.initialUser, required this.initialPass});
  final String initialUser;
  final String initialPass;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late final _userCtrl = TextEditingController(text: widget.initialUser);
  late final _passCtrl = TextEditingController(text: widget.initialPass);

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: cPanel,
    title: const Text('Iniciar sesión'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Solo quien tenga estas credenciales puede fondear o levar el ancla. '
          'Son las mismas de CFG → Conexión.',
          style: TextStyle(color: cMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _userCtrl,
          decoration: const InputDecoration(labelText: 'Usuario'),
        ),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Contraseña'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.of(context).pop((_userCtrl.text, _passCtrl.text)),
        child: const Text('Entrar'),
      ),
    ],
  );
}

// Sets/moves the anchor by distance + bearing from the current boat
// position — useful when what was actually paid out doesn't match a
// straight GPS drop-in-place (bow roller offset, chain veered out while
// reversing, etc).
class _ChainDialog extends StatefulWidget {
  const _ChainDialog({required this.initialBearing});
  final double initialBearing;

  @override
  State<_ChainDialog> createState() => _ChainDialogState();
}

class _ChainDialogState extends State<_ChainDialog> {
  late final _distCtrl = TextEditingController();
  late final _brgCtrl = TextEditingController(
    text: widget.initialBearing.round().toString(),
  );

  @override
  void dispose() {
    _distCtrl.dispose();
    _brgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: cPanel,
    title: const Text('Fondear por distancia y rumbo'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Distancia de cadena/rumbo desde la posición actual del barco '
          'hasta donde ha quedado el ancla.',
          style: TextStyle(color: cMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _distCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Distancia (m)'),
        ),
        TextField(
          controller: _brgCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Rumbo (°) — por defecto el del barco',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          final dist = double.tryParse(_distCtrl.text);
          final brg = double.tryParse(_brgCtrl.text);
          if (dist == null || brg == null) {
            Navigator.of(context).pop();
            return;
          }
          Navigator.of(context).pop((dist, brg));
        },
        child: const Text('Fijar'),
      ),
    ],
  );
}

class _LayersSheet extends StatefulWidget {
  const _LayersSheet({required this.config, required this.onChanged});
  final AnchorConfig config;
  final void Function(void Function(AnchorConfig)) onChanged;

  @override
  State<_LayersSheet> createState() => _LayersSheetState();
}

class _LayersSheetState extends State<_LayersSheet> {
  Widget _toggle(
    String label,
    bool value,
    void Function(AnchorConfig, bool) set,
  ) => SwitchListTile(
    value: value,
    onChanged: (v) {
      setState(() => widget.onChanged((c) => set(c, v)));
    },
    title: Text(label, style: const TextStyle(color: cText)),
    activeThumbColor: cCyan,
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'CAPAS',
                style: TextStyle(
                  color: cMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
            _toggle('Viento', c.showWind, (c, v) => c.showWind = v),
            _toggle('Profundidad', c.showDepth, (c, v) => c.showDepth = v),
            _toggle(
              'Scope (cadena:profundidad)',
              c.showScope,
              (c, v) => c.showScope = v,
            ),
            _toggle(
              'AIS cercanos',
              c.showAisNearby,
              (c, v) => c.showAisNearby = v,
            ),
            _toggle(
              'Traza propia',
              c.showOwnTrack,
              (c, v) => c.showOwnTrack = v,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'CAPA BASE',
                  style: TextStyle(
                    color: cMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
            _toggle(
              'Satélite',
              c.showSatelliteLayer,
              (c, v) => c.showSatelliteLayer = v,
            ),
            _toggle(
              'Carta náutica (OpenSeaMap)',
              c.showSeamarkLayer,
              (c, v) => c.showSeamarkLayer = v,
            ),
          ],
        ),
      ),
    );
  }
}

// Repeating opacity pulse — see the TEMPORARY 2026-09-04 note where this is
// used in _statusPanel.
class _Blink extends StatefulWidget {
  const _Blink({required this.child});
  final Widget child;

  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(
      begin: 1,
      end: 0.25,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
    child: widget.child,
  );
}
