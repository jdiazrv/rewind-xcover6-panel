import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../theme.dart';

// ─── Motor premium panel — SIMULATION SCAFFOLDING ───────────────────────────
// This whole widget renders against a *locally simulated* engine state, not
// real telemetry: the boat has no RPM/alarm PGNs (127488/127489) wired into
// SignalKModel yet. The SIMUL switch and every field in _lamps below exist
// only to preview the design; once Signal K exposes real engine paths, this
// state machine should be replaced by values read straight from
// SignalKModel (matching how the rest of NavCardData works) and the SIMUL
// switch removed entirely.

// Approximate Volvo Penta D2 (EVC/MDI) glow-plug preheat time — begins the
// moment ON is pressed (a real diesel starts preheating on contact, not
// when you press the starter), and START stays disabled until it elapses.
const _kGlowPlugPreheatDuration = Duration(seconds: 5);

// How long the simulated crank takes once START is pressed (preheat is
// already done by then — see _kGlowPlugPreheatDuration). Timed to land
// slightly *before* starter_crank.wav's own natural end (~3.8s) so the
// idle loop crossfades in over the crank sound's tail instead of starting
// in the silence after it — a real engine "catches" mid-crank, it doesn't
// go silent first.
const _kCrankDuration = Duration(milliseconds: 3200);

// How long the crank→idle crossfade takes once the engine "catches".
const _kCrossfadeDuration = Duration(milliseconds: 700);

// Placeholder idle RPM shown once the simulated engine reaches "running", so
// the gauge isn't stuck at zero during the demo. Not real data.
const _kSimIdleRpm = 700.0;

// Matte pale-grey e-ink look, shared by every plain data readout on this
// panel (hours/torque, undecoded-PGN diagnostics) — deliberately the odd
// one out against the rest of the panel's glass/LED look, the way a real
// e-ink display sits inset in a dark instrument bezel.
const _kEInkBg = Color(0xffd8d6cd);
const _kEInkText = Color(0xff33322c);

// preheating→ready is the glow-plug wait: begins the moment ON is pressed
// (not START — a real diesel starts preheating on contact, before you ever
// touch the starter), lasts _kGlowPlugPreheatDuration, and START stays
// disabled until it reaches `ready`. From `ready`, START moves to
// `cranking` for _kCrankDuration, then `running` — no further preheat
// wait, that already happened before `ready`.
enum _EngineSimState { off, preheating, ready, cranking, running }

class _MotorLamp {
  const _MotorLamp(this.key, this.label, this.color, this.icon);
  final String key;
  final String label;
  final Color color;
  final IconData icon;
}

const _motorLamps = [
  _MotorLamp('contacto', 'CONTACTO', cGreen, Icons.vpn_key),
  _MotorLamp('carga', 'CARGA', cRed, Icons.bolt),
  _MotorLamp('aceite', 'PRESIÓN\nACEITE', cRed, Icons.opacity),
  _MotorLamp('temp', 'TEMPERATURA', cRed, Icons.thermostat),
  _MotorLamp('precal', 'PRECALENTAR', cYellow, Icons.local_fire_department),
];

/// Premium "Motor" screen — RPM arc gauge + engine warning lights, styled to
/// match the app's other Premium cards (see `_premiumSpeedCard` in
/// main.dart). With SIMUL on, it drives its lamps from a small ON/OFF/
/// START/STOP simulation (see module comment above); with SIMUL off, every
/// number and lamp reads from the real Signal K fields passed in — RPM,
/// coolant temp, oil pressure, alternator voltage, [engineRunning] for the
/// status banner, and [engineContactOn] for the CONTACTO lamp. The 3 fault
/// lamps (carga/aceite/temp) prefer the engine's own DM1 fault bit (PGN
/// 65226) when the bridge publishes one, falling back to the same
/// alarmXxx thresholds otherwise — same as the real alarm system in
/// _DashboardState._activeAlarms, EXCEPT the lamps aren't gated on
/// engineRunning the way the alarm sound is: with contact on but the
/// engine not yet turning, oil pressure/alternator genuinely read as
/// "bad" (0 bar, not charging), and the lamps are supposed to show that —
/// it's the panel's own bulb-check, not a fault. Only an actual alarm
/// *sound* firing for that same "normal at rest" reading would be a
/// nuisance, which is why that part stays gated.
class PremiumMotorEnginePanel extends StatefulWidget {
  const PremiumMotorEnginePanel({
    super.key,
    required this.engineHours,
    required this.engineRunning,
    this.engineContactOn = false,
    this.engineRpm,
    this.engineTorquePercent,
    this.engineOilPressurePa,
    this.engineCoolantTempK,
    this.engineAlternatorV,
    this.engineOverTempAlarm,
    this.engineLowOilAlarm,
    this.engineLowVoltAlarm,
    this.engineGlowPlugFaultAlarm,
    this.enginePreheatActive,
    this.engineUnknownPgn,
    this.engineUnknownFrameCount,
    this.alarmOilMinBar = 1.0,
    this.alarmTempMaxC = 100.0,
    this.alarmVoltMinV = 13.0,
    this.detailed = false,
    this.mutedAlarmCount = 0,
    this.onUnmuteAlarms,
    this.activeUnmutedAlarmCount = 0,
    this.onMuteAllAlarms,
  });

  final NavCardData engineHours;
  // Real signal (from propulsion.<id>.runTime deltas — see
  // _DashboardState._engineRunning) used for the status banner whenever
  // SIMUL is off.
  final bool engineRunning;
  // True whenever the engine ECU has reported *anything* recently (RPM,
  // coolant, oil pressure or alternator — any one is enough), regardless
  // of whether RPM is actually above zero. This is "is contact on", not
  // "is the engine running" — see _DashboardState._engineContactOn for
  // the freshness check behind it, and _isLampOnReal for why the
  // CONTACTO lamp uses this instead of [engineRunning].
  final bool engineContactOn;
  final double? engineRpm;
  // Percent load, same PGN 61444 frame as RPM (SPN 512) — informational
  // only, shown in _hoursBox() when [detailed] and available.
  final double? engineTorquePercent;
  final double? engineOilPressurePa;
  final double? engineCoolantTempK;
  final double? engineAlternatorV;
  // Discrete DM1 fault bits (PGN 65226), when the bridge decodes them —
  // take precedence over the threshold comparison below (see
  // _isLampOnReal). Null while unpublished.
  final bool? engineOverTempAlarm;
  final bool? engineLowOilAlarm;
  final bool? engineLowVoltAlarm;
  // Glow-plug/starter-relay circuit fault (SPN 677/724, FMI 5) — discrete
  // only, no threshold equivalent exists for a relay fault.
  final bool? engineGlowPlugFaultAlarm;
  // Preheat-in-progress status (PGN 65264, SPN 1494) — not a fault, drives
  // the 'precal' lamp in real mode the way the sim state machine does.
  final bool? enginePreheatActive;
  // Bridge diagnostics — undecoded PGN frames, shown only in detailed mode.
  final double? engineUnknownPgn;
  final double? engineUnknownFrameCount;
  final double alarmOilMinBar;
  final double alarmTempMaxC;
  final double alarmVoltMinV;
  // "Completo" CFG toggle (settings.motorPanelDetailed) — adds numeric
  // gauges for temp/oil/volt (each labeled CONFIRMADO/ESTIMADO/SIN DATO
  // for provenance) and the undecoded-PGN diagnostics line below the
  // existing RPM+lamps layout.
  final bool detailed;
  // How many of this screen's own engine alarms (oil/temp/volt/glow-plug)
  // are currently silenced — muting only stops the sound, the alarm stays
  // active/red until the condition itself clears, so there was previously
  // no way back to sound short of that happening on its own. Shown as a
  // small button in the status banner, hidden when 0.
  final int mutedAlarmCount;
  final VoidCallback? onUnmuteAlarms;
  // How many of this screen's own engine alarms are currently sounding
  // and NOT already muted — drives a "silenciar todas" button so the
  // user doesn't have to mute oil/temp/volt/glow-plug one at a time
  // during a real multi-fault event. Hidden when 0.
  final int activeUnmutedAlarmCount;
  final VoidCallback? onMuteAllAlarms;

  @override
  State<PremiumMotorEnginePanel> createState() =>
      _PremiumMotorEnginePanelState();
}

class _PremiumMotorEnginePanelState extends State<PremiumMotorEnginePanel> {
  // See _DashboardState._isCompactPremium in main.dart for the full
  // rationale — same tablet-vs-phone split, mirrored locally here since
  // this panel is its own widget without access to that getter.
  bool get _isCompact => MediaQuery.sizeOf(context).height < 500;

  _EngineSimState _engineState = _EngineSimState.off;
  bool _simulEnabled = false;
  Timer? _preheatTimer;
  final Map<String, bool> _lamps = {for (final l in _motorLamps) l.key: false};
  // Manual RPM override, dragged from the SIMUL slider once running —
  // starts at idle (see _kSimIdleRpm) and stays null (→ shows 0) whenever
  // the engine isn't actually running.
  double? _manualRpm;

  // Separate players/channel from the app's real alarm sound (see
  // _DashboardState._alarmPlayer in main.dart) so a SIMUL preview sound
  // never fights with — or gets silently cut off by — an actual alarm.
  // Two distinct players (crank + idle loop) rather than one reused
  // player, so the crank's tail and the idle loop's head can play
  // simultaneously during the crossfade instead of one hard-cutting the
  // other (see _crossfadeToIdle).
  AudioPlayer? _simSoundPlayer;
  AudioPlayer? _idleLoopPlayer;
  Timer? _hapticTimer;
  Timer? _crossfadeTimer;

  @override
  void dispose() {
    _preheatTimer?.cancel();
    _hapticTimer?.cancel();
    _crossfadeTimer?.cancel();
    _simSoundPlayer?.dispose();
    _idleLoopPlayer?.dispose();
    super.dispose();
  }

  Future<void> _playSimSound(String asset) async {
    _simSoundPlayer ??= AudioPlayer();
    await _simSoundPlayer!.stop();
    await _simSoundPlayer!.setReleaseMode(ReleaseMode.stop);
    await _simSoundPlayer!.setPlayerMode(PlayerMode.mediaPlayer);
    await _simSoundPlayer!.setVolume(1);
    await _simSoundPlayer!.play(AssetSource('sound/$asset'));
  }

  // Fades the idle loop in while fading the still-playing crank sound out,
  // over _kCrossfadeDuration — called shortly before the crank clip's own
  // natural end (see _kPreheatDuration) so the two genuinely overlap,
  // instead of the idle loop starting in dead silence after the crank
  // sound has already finished (which is what read as "abrupto").
  Future<void> _crossfadeToIdle() async {
    _idleLoopPlayer ??= AudioPlayer();
    await _idleLoopPlayer!.setReleaseMode(ReleaseMode.loop);
    // lowLatency (SoundPool-backed on Android) loops a short clip
    // sample-accurately; the default mode (MediaPlayer-backed) re-seeks
    // the file on every repeat, which is where the audible gap at the
    // loop point was coming from — the WAV itself is already built as a
    // seamless loop (crossfaded at its own seam — see the asset's
    // generation notes), so the join was never in the audio data.
    await _idleLoopPlayer!.setPlayerMode(PlayerMode.lowLatency);
    await _idleLoopPlayer!.setPlaybackRate(_idleRateForRpm(_manualRpm));
    await _idleLoopPlayer!.setVolume(0);
    await _idleLoopPlayer!.play(AssetSource('sound/engine_idle.wav'));

    _crossfadeTimer?.cancel();
    const stepMs = 40;
    final steps = _kCrossfadeDuration.inMilliseconds ~/ stepMs;
    var step = 0;
    _crossfadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (
      timer,
    ) {
      step++;
      final f = (step / steps).clamp(0.0, 1.0);
      unawaited(_idleLoopPlayer?.setVolume(f));
      unawaited(_simSoundPlayer?.setVolume(1 - f));
      if (step >= steps) {
        timer.cancel();
        unawaited(_simSoundPlayer?.stop());
      }
    });
  }

  // Diesel idle noise played faster both raises pitch and quickens the
  // firing rate, reading as a rev — not physically exact, but the
  // simplest way to make the SIMUL loop respond to the RPM slider instead
  // of holding one static idle tone regardless of dragged RPM.
  double _idleRateForRpm(double? rpm) =>
      (0.85 + 0.9 * (rpm ?? _kSimIdleRpm) / 4000).clamp(0.85, 1.9);

  void _stopSimSound() {
    unawaited(_simSoundPlayer?.stop());
    unawaited(_idleLoopPlayer?.stop());
    _hapticTimer?.cancel();
    _hapticTimer = null;
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
  }

  // Turning SIMUL itself off mid-"running" would otherwise leave the idle
  // loop (and, if caught mid-crank, the haptic timer) running forever with
  // no state left to stop it from.
  void _onSimulToggle(bool v) {
    if (!v) _stopSimSound();
    setState(() => _simulEnabled = v);
  }

  void _toggleLampManually(String key) {
    if (!_simulEnabled) return;
    setState(() => _lamps[key] = !(_lamps[key] ?? false));
  }

  // A real diesel keeps running on its own compression ignition once
  // started — the key switch only controls the electrics (dash lights,
  // glow plugs, starter circuit), not fuel — so turning it OFF while the
  // engine is running does NOT stop the engine, only STOP does. OFF just
  // drops "contact" (and, if the engine hadn't started yet, cancels
  // whatever preheat/crank was in progress).
  void _pressOff() {
    // Once the starter's been committed to (cranking or fully running),
    // OFF must leave the engine alone — only preheat/ready (nothing
    // actually turning yet) gets cancelled outright.
    final engineStarted =
        _engineState == _EngineSimState.cranking ||
        _engineState == _EngineSimState.running;
    if (!engineStarted) {
      _preheatTimer?.cancel();
      _hapticTimer?.cancel();
      _stopSimSound();
    }
    setState(() {
      if (!engineStarted) {
        _engineState = _EngineSimState.off;
        _lamps.updateAll((_, _) => false);
        _manualRpm = null;
      }
      // engineStarted: _engineState is intentionally left untouched.
      _lamps['contacto'] = false;
    });
  }

  // Contact starts the glow-plug preheat immediately — a real diesel
  // begins preheating as soon as the key reaches "on", well before you
  // touch the starter — so START stays disabled (see _buttonsAndSlider)
  // until _kGlowPlugPreheatDuration elapses and the state reaches `ready`.
  void _pressOn() {
    if (_engineState != _EngineSimState.off) return;
    _preheatTimer?.cancel();
    _stopSimSound();
    setState(() {
      _engineState = _EngineSimState.preheating;
      _lamps['contacto'] = true;
      _lamps['carga'] = true;
      _lamps['aceite'] = true;
      _lamps['precal'] = true;
    });
    _preheatTimer = Timer(_kGlowPlugPreheatDuration, _onPreheatDone);
  }

  // Shared by _pressOn and _pressStop, which both end their preheat wait
  // the same way: the two beeps are the "ready to start" cue.
  void _onPreheatDone() {
    if (!mounted) return;
    setState(() {
      _engineState = _EngineSimState.ready;
      _lamps['precal'] = false;
    });
    unawaited(_playSimSound('ready_beeps.wav'));
  }

  void _pressStart() {
    // Only does something once preheat has actually finished — mirrors a
    // real key switch where the starter circuit is interlocked with the
    // glow plugs, and is a no-op if the engine is already turning over.
    if (_engineState != _EngineSimState.ready) return;
    setState(() => _engineState = _EngineSimState.cranking);
    unawaited(_playSimSound('starter_crank.wav'));
    // A haptic pulse in time with the crank sound — only while it's
    // actually cranking, not once it settles into running.
    _hapticTimer?.cancel();
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      unawaited(HapticFeedback.heavyImpact());
    });
    _preheatTimer?.cancel();
    _preheatTimer = Timer(_kCrankDuration, () {
      _hapticTimer?.cancel();
      _hapticTimer = null;
      if (!mounted) return;
      unawaited(_crossfadeToIdle());
      setState(() {
        _engineState = _EngineSimState.running;
        _lamps['aceite'] = false;
        _lamps['carga'] = false;
        _manualRpm = _kSimIdleRpm;
      });
    });
  }

  // The only way to actually stop the (simulated) engine — see _pressOff.
  // Matches the STOP button's own enabled condition in _buttonsAndSlider:
  // only once the starter's actually committed (cranking or running).
  void _pressStop() {
    if (_engineState != _EngineSimState.running &&
        _engineState != _EngineSimState.cranking) {
      return;
    }
    _preheatTimer?.cancel();
    _hapticTimer?.cancel();
    _stopSimSound();
    setState(() {
      // Stopping the engine drops oil pressure and charging again, same
      // as right after key-on — contact stays live, and goes straight to
      // `ready` rather than back through a fresh preheat: the engine's
      // already warm, a real diesel doesn't need the glow plugs again for
      // a same-session restart.
      _engineState = _EngineSimState.ready;
      _lamps['precal'] = false;
      _lamps['aceite'] = true;
      _lamps['carga'] = true;
      _manualRpm = null;
    });
  }

  // With SIMUL off, the banner reflects the real engineRunning signal
  // instead of the simulation's own state machine — otherwise it just sat
  // on "MOTOR PARADO" forever regardless of whether the engine was
  // actually running.
  String get _statusText {
    if (!_simulEnabled) {
      return widget.engineRunning ? 'MOTOR EN MARCHA' : 'MOTOR PARADO';
    }
    switch (_engineState) {
      case _EngineSimState.off:
        return 'MOTOR PARADO';
      case _EngineSimState.preheating:
        return 'PRECALENTANDO…';
      case _EngineSimState.ready:
        return 'LISTO PARA ARRANCAR';
      case _EngineSimState.cranking:
        return 'ARRANCANDO…';
      case _EngineSimState.running:
        return 'MOTOR EN MARCHA';
    }
  }

  Color get _statusColor {
    if (!_simulEnabled) {
      return widget.engineRunning ? cGreen : cMuted;
    }
    switch (_engineState) {
      case _EngineSimState.off:
        return cMuted;
      case _EngineSimState.preheating:
        return cYellow;
      case _EngineSimState.ready:
        return cCyan;
      case _EngineSimState.cranking:
        return cYellow;
      case _EngineSimState.running:
        return cGreen;
    }
  }

  // Outside SIMUL this reads the real propulsion.<id>.revolutions signal
  // (widget.engineRpm); null when that path hasn't reported yet (renders
  // as "--", see _rpmCard) rather than a fabricated 0, which would read
  // as "engine off" even while it's actually running.
  // OFF means no power at all — a real ECU with the key out reports
  // nothing, so this reads as stale/no-data ("--"), not a fabricated
  // resting number. Contact/preheating do have power (sensors read, just
  // nothing running yet); running gets the operating-range numbers.
  bool get _simOff => _simulEnabled && _engineState == _EngineSimState.off;
  bool get _simRunning =>
      _simulEnabled && _engineState == _EngineSimState.running;

  double? get _displayRpm {
    if (!_simulEnabled) return widget.engineRpm;
    if (_simOff) return null;
    return _simRunning ? (_manualRpm ?? _kSimIdleRpm) : 0;
  }

  // Same SIMUL-vs-real split as _displayRpm, for the "Completo" gauges —
  // plausible resting-vs-running numbers rather than always 0, so SIMUL
  // actually previews what those gauges look like with real data instead
  // of just parking them at "--" the whole time.
  double? get _displayCoolantTempK {
    if (!_simulEnabled) return widget.engineCoolantTempK;
    if (_simOff) return null;
    return _simRunning ? 358.15 : 288.15; // 85°C running, 15°C ambient
  }

  double? get _displayOilPressurePa {
    if (!_simulEnabled) return widget.engineOilPressurePa;
    if (_simOff) return null;
    return _simRunning ? 250000 : 0; // 2.5 bar running, 0 at rest
  }

  double? get _displayAlternatorV {
    if (!_simulEnabled) return widget.engineAlternatorV;
    if (_simOff) return null;
    return _simRunning ? 14.2 : 12.6; // charging vs. resting battery
  }

  double? get _displayTorquePercent {
    if (!_simulEnabled) return widget.engineTorquePercent;
    if (_simOff) return null;
    if (!_simRunning) return 0;
    return ((_manualRpm ?? _kSimIdleRpm) / 4000 * 80).clamp(0, 100);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        _statusBanner(),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 16,
                child: widget.detailed ? _detailGaugeGrid() : _rpmCard(),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 7,
                // Same card as the RPM/gauge side — previously the side
                // column had no card of its own and just floated straight
                // on the page background, so this half read as flatly
                // darker next to the gauges' card next to it. Uniform now:
                // both halves are the identical panelShell gradient, with
                // the pale e-ink boxes/lamps sitting on top of it just
                // like the gauges' own readouts do on their side.
                child: _panelShell(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _sideColumn(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  // "Completo": RPM stays the big, dominant gauge (same card, same width
  // share as Simple mode) — real tachometers are always the largest dial
  // on a dash, with oil/temp/volt as smaller secondary gauges beside it,
  // stacked in a narrower column rather than matched to RPM's size.
  // Reusing _isLampOnReal for the alarm color keeps every gauge in
  // agreement with the lamp/alarm banner everywhere else here.
  Widget _detailGaugeGrid() => Row(
    children: [
      Expanded(flex: 3, child: _rpmCard()),
      const SizedBox(width: 8),
      Expanded(
        flex: 2,
        child: Column(
          children: [
            Expanded(child: _tempGaugeTile()),
            const SizedBox(height: 8),
            Expanded(child: _oilGaugeTile()),
            const SizedBox(height: 8),
            Expanded(child: _voltGaugeTile()),
          ],
        ),
      ),
    ],
  );

  // 'CONFIRMADO' when the bridge publishes the engine's own fault bit for
  // this metric (authoritative — "DM1"/"J1939" would mean nothing to
  // someone who isn't us), 'ESTIMADO' when falling back to our own
  // threshold instead (a stand-in, not the engine's own verdict), 'SIN
  // DATO' when there's no reading at all yet.
  String _sourceLabel(bool? discreteFlag, double? value) {
    if (discreteFlag != null) return 'CONFIRMADO';
    if (value != null) return 'ESTIMADO';
    return 'SIN DATO';
  }

  // Green/red telltale for each secondary gauge — no LED at all (not a
  // third color) when there's no reading to judge.
  _LedState? _ledStateFor(double? value, bool alarm) {
    if (value == null) return null;
    return alarm ? _LedState.alarm : _LedState.ok;
  }

  // "TEMP" alone reads as ambiguous (coolant? oil? exhaust?) — spelling out
  // "refrigerante" matches what SPN 110 actually measures and what the
  // 'temp' lamp's own tooltip-equivalent (_MotorLamp label) implies.
  // Under SIMUL, the source caption reads "SIMULADO" rather than lying
  // about DM1/UMBRAL provenance the displayed number doesn't actually have.
  String _sourceOrSim(bool? discreteFlag, double? value) =>
      _simulEnabled ? 'SIMULADO' : _sourceLabel(discreteFlag, value);

  Widget _tempGaugeTile() {
    final k = _displayCoolantTempK;
    final value = k == null ? null : k - 273.15;
    final alarm = _lampOn('temp');
    return _panelShell(
      child: _AnalogGauge(
        label: 'TEMP. REFRIGERANTE',
        value: value,
        valueText: value == null ? '' : '${value.toStringAsFixed(1)}°C',
        min: 40,
        max: 120,
        majorStep: 20,
        // High is bad: red zone runs from the alarm threshold up to max.
        dangerStart: widget.alarmTempMaxC,
        dangerEnd: 120,
        needleColor: alarm ? cRed : cCyan,
        source: _sourceOrSim(widget.engineOverTempAlarm, value),
        ledState: _ledStateFor(value, alarm),
      ),
    );
  }

  Widget _oilGaugeTile() {
    final pa = _displayOilPressurePa;
    final value = pa == null ? null : pa / 100000.0;
    final alarm = _lampOn('aceite');
    return _panelShell(
      child: _AnalogGauge(
        label: 'PRESIÓN ACEITE',
        value: value,
        valueText: value == null ? '' : '${value.toStringAsFixed(1)} bar',
        min: 0,
        max: 6,
        majorStep: 1,
        // Low is bad here: red zone runs from 0 up to the minimum threshold.
        dangerStart: 0,
        dangerEnd: widget.alarmOilMinBar,
        needleColor: alarm ? cRed : cCyan,
        source: _sourceOrSim(widget.engineLowOilAlarm, value),
        ledState: _ledStateFor(value, alarm),
      ),
    );
  }

  Widget _voltGaugeTile() {
    final value = _displayAlternatorV;
    final alarm = _lampOn('carga');
    return _panelShell(
      child: _AnalogGauge(
        label: 'ALTERNADOR',
        value: value,
        valueText: value == null ? '' : '${value.toStringAsFixed(1)} V',
        min: 10,
        max: 16,
        majorStep: 1,
        dangerStart: 10,
        dangerEnd: widget.alarmVoltMinV,
        needleColor: alarm ? cRed : cCyan,
        source: _sourceOrSim(widget.engineLowVoltAlarm, value),
        ledState: _ledStateFor(value, alarm),
      ),
    );
  }

  // Diagnostic-only readout of PGN frames the bridge sees but doesn't
  // decode yet — hidden entirely once there's nothing to report, so a
  // fully-decoded bridge doesn't leave an empty bar sitting there. Styled
  // like a little e-ink strip (matte pale-grey ground, dark flat text, no
  // backlight/glow) — deliberately the odd one out against the rest of
  // this panel's glass/LED look, the way a real e-ink diagnostic display
  // would sit inset in a dark instrument bezel.
  Widget _diagnosticsFooter() {
    final count = widget.engineUnknownFrameCount;
    if (count == null || count <= 0) return const SizedBox.shrink();
    final pgn = widget.engineUnknownPgn;
    return _eInkBox(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            const Text(
              'PGN SIN DECODIFICAR',
              style: TextStyle(
                color: _kEInkText,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Text(
              pgn == null
                  ? count.round().toString()
                  : '${count.round()} · último ${pgn.round()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kEInkText,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Shared e-ink chrome for every plain data readout on this panel: matte
  // pale ground, then a dark gradient hugging the top edge and a faint
  // highlight along the bottom (clipped to the same rounded rect as the
  // fill), so the box reads as recessed into the panel rather than a flat
  // sticker sitting on top of it — same treatment as the gauges' own LCD
  // readouts (see _AnalogGaugePainter), just built from widgets instead of
  // Canvas since these are plain Containers, not part of a CustomPainter.
  Widget _eInkBox({required Widget child}) {
    final radius = BorderRadius.circular(4);
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: _kEInkBg, borderRadius: radius),
            child: child,
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: const Alignment(0, -0.1),
                  colors: [
                    Colors.black.withValues(alpha: 0.28),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: const Alignment(0, 0.4),
                  colors: [
                    Colors.white.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: Colors.black.withValues(alpha: 0.25)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelShell({required Widget child}) => Card(
    color: Colors.transparent,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    clipBehavior: Clip.antiAlias,
    child: Container(color: cBg, child: child),
  );

  Widget _statusBanner() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    decoration: BoxDecoration(
      color: _statusColor.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _statusColor.withValues(alpha: 0.45)),
    ),
    child: Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: _statusColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _statusText,
          style: TextStyle(
            color: _statusColor,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        if (widget.activeUnmutedAlarmCount > 0 ||
            widget.mutedAlarmCount > 0) ...[
          const Spacer(),
          if (widget.activeUnmutedAlarmCount > 0) ...[
            _muteAllAlarmsButton(),
            if (widget.mutedAlarmCount > 0) const SizedBox(width: 8),
          ],
          if (widget.mutedAlarmCount > 0) _mutedAlarmsButton(),
        ],
      ],
    ),
  );

  Widget _muteAllAlarmsButton() => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: widget.onMuteAllAlarms,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cRed.withValues(alpha: 0.5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_off, size: 15, color: cRed),
          SizedBox(width: 6),
          Text(
            'Silenciar todas',
            style: TextStyle(
              color: cRed,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    ),
  );

  // Muting an alarm only stops the sound — the alarm itself stays active
  // (red lamp/gauge) until the underlying condition clears on its own, so
  // without this there was no way back to sound before that happens.
  Widget _mutedAlarmsButton() => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: widget.onUnmuteAlarms,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cOrange.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.notifications_off, size: 15, color: cOrange),
          const SizedBox(width: 6),
          Text(
            widget.mutedAlarmCount == 1
                ? '1 alarma silenciada'
                : '${widget.mutedAlarmCount} alarmas silenciadas',
            style: const TextStyle(
              color: cOrange,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _rpmCard() => _panelShell(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        _isCompact ? 14 : 16,
        _isCompact ? 8 : 12,
        _isCompact ? 14 : 16,
        _isCompact ? 6 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Phone: "RPM" + "×1000" in one compact strip (instead of the
          // tablet's original two rows) frees up real height for the
          // circle below to actually double in size instead of just
          // filling whatever was left over.
          if (_isCompact)
            Row(
              children: [
                const Text(
                  'RPM',
                  style: TextStyle(
                    color: cMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                const Text(
                  '×1000',
                  style: TextStyle(
                    color: cCyan,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            )
          else ...[
            Row(
              children: [
                const Text(
                  'RPM',
                  style: TextStyle(
                    color: cMuted,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                const Text(
                  '×1000',
                  style: TextStyle(
                    color: cCyan,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
          Expanded(
            // RPM's "RPM"/×1000 header row above already says what this
            // gauge is, so it renders with no label of its own — just the
            // dial, needle and its own digital RPM readout.
            child: _AnalogGauge(
              label: null,
              value: _displayRpm == null ? null : _displayRpm! / 1000,
              valueText: _displayRpm == null
                  ? ''
                  : _displayRpm!.round().toString(),
              min: 0,
              max: 4,
              majorStep: 1,
              // Decorative redline (not tied to any alarm — there's no
              // real over-rev signal yet) at the conventional ~85% mark,
              // matching what every physical tachometer shows.
              dangerStart: 3.4,
              dangerEnd: 4,
              needleColor: cCyan,
              big: true,
            ),
          ),
        ],
      ),
    ),
  );

  // Phone: a plain Column here overflowed on a phone's much shorter
  // landscape row — hoursBox + 5 lamp chips alone could already eat the
  // whole available height, silently pushing the SIMUL toggle (last
  // child) past the bottom of the screen with no way to reach it. A
  // scroll view would be the obvious fix, but the NAV page this panel
  // lives on already uses whole-screen vertical swipes to switch between
  // Vela/Motor/Fondeado (see the comment on that ListView in main.dart) —
  // a nested Scrollable's own gesture just gets read as that outer swipe
  // instead, so scrolling here is a dead end. Two columns of lamps
  // (paired up, last one alone) instead of one per row halves the number
  // of rows, and bounding both blocks in their own Expanded+
  // FittedBox(scaleDown) guarantees SIMUL always has real space rather
  // than being pushed off, even if it means shrinking on a very short
  // screen. Tablet uses the same two-column pairing (just without the
  // phone's FittedBox/scaling — it isn't short on height, so the plain
  // paired Rows fit at full size).
  Widget _sideColumn() {
    if (!_isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hoursBox(),
          if (_torqueBox() case final box?) ...[const SizedBox(height: 6), box],
          const SizedBox(height: 6),
          for (var i = 0; i < _motorLamps.length; i += 2) ...[
            Row(
              children: [
                Expanded(child: _lampChip(_motorLamps[i])),
                const SizedBox(width: 6),
                Expanded(
                  child: i + 1 < _motorLamps.length
                      ? _lampChip(_motorLamps[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          // "Completo" only, and only once the bridge actually reports
          // something undecoded — right under the lamps rather than as a
          // page-wide footer, since it's diagnostic detail about the same
          // signals the lamps above summarize.
          if (widget.detailed) ...[
            _diagnosticsFooter(),
            const SizedBox(height: 6),
          ],
          Expanded(child: _simulArea()),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final lamps = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _motorLamps.length; i += 2) ...[
              // Not CrossAxisAlignment.stretch — this Row is measured with
              // an *unbounded* height (it's inside a mainAxisSize.min
              // Column being intrinsically sized by the FittedBox below),
              // and stretch needs a definite cross-axis extent to stretch
              // into. Under an unbounded height that's an invalid layout
              // that silently blanked this whole lamp block in release
              // mode. Each chip already has its own minHeight, so plain
              // center alignment still looks right.
              Row(
                children: [
                  Expanded(child: _lampChip(_motorLamps[i])),
                  const SizedBox(width: 6),
                  Expanded(
                    child: i + 1 < _motorLamps.length
                        ? _lampChip(_motorLamps[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _hoursBox(),
            if (_torqueBox() case final box?) ...[
              const SizedBox(height: 6),
              box,
            ],
            const SizedBox(height: 6),
            Expanded(
              flex: 3,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(width: constraints.maxWidth, child: lamps),
              ),
            ),
            Expanded(
              flex: 2,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: _simulArea(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _hoursBox() => _eInkBox(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'HORAS MOTOR',
            style: TextStyle(
              color: _kEInkText,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            widget.engineHours.value,
            style: const TextStyle(
              color: _kEInkText,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    ),
  );

  // Same PGN 61444 frame as RPM (SPN 512) — its own recessed screen, not a
  // second row inside HORAS MOTOR's, matching how every other readout on
  // this panel gets its own box. Only worth showing in "Completo" mode,
  // once there's actually a reading.
  Widget? _torqueBox() {
    final torque = _displayTorquePercent;
    if (!widget.detailed || torque == null) return null;
    return _eInkBox(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'PAR MOTOR',
              style: TextStyle(
                color: _kEInkText,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
            Text(
              '${torque.round()}%',
              style: const TextStyle(
                color: _kEInkText,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Lit lamps fill with their own colour like a real panel LED (contacto's
  // green, the fault lamps' red) instead of just tinting the border/icon —
  // the previous treatment was too subtle to read as "alarm" at a glance.
  // All five stack in one column at the same width, packed tightly, rather
  // than pairing two-per-row (which made "precal" alone stretch twice as
  // wide as the rest).
  // Real-mode lamp states — deliberately using the exact same precedence
  // as _DashboardState._activeAlarms (via the values passed in): the
  // engine's own DM1 fault bit (PGN 65226) wins when the bridge publishes
  // it, the fixed threshold is only a stand-in while that signal is
  // unpublished, so this lamp and the app's real alarm banner/sound never
  // disagree. 'precal' doubles up: lit yellow for a normal preheat cycle
  // (SPN 1494) or red for an actual glow-plug/relay fault (SPN 677/724,
  // FMI 5) — see _lampColorReal for the color half of that.
  //
  // 'carga'/'aceite'/'temp' deliberately do NOT require engineRunning here
  // (unlike the real alarm/sound system in _DashboardState._activeAlarms,
  // which still does) — this is the lamp's own "bulb check" behavior, the
  // same as a real analog panel: with contact on but the engine not yet
  // turning, oil pressure genuinely reads ~0 and the alternator genuinely
  // isn't charging, so those lamps are *supposed* to light up before
  // start — that's how you can see the sensors/bulbs actually work. They
  // go out on their own once real running data crosses the threshold, no
  // special-casing needed. A real alarm *sound* staying gated on
  // engineRunning is what keeps this from being a nuisance alarm.
  bool _isLampOnReal(String key) {
    switch (key) {
      case 'contacto':
        // Contact is "is the engine ECU alive and reporting", not "is it
        // running" — while stopped-but-still-contacted it keeps
        // publishing rpm≈0 with a fresh timestamp, which is exactly what
        // should keep this lamp lit (a reminder to actually press OFF).
        // See _DashboardState._engineContactOn.
        return widget.engineContactOn;
      case 'carga':
        final v = widget.engineAlternatorV;
        final threshold = v != null && v < widget.alarmVoltMinV;
        return widget.engineLowVoltAlarm ?? threshold;
      case 'aceite':
        final pa = widget.engineOilPressurePa;
        final bar = pa == null ? null : pa / 100000.0;
        final threshold = bar != null && bar < widget.alarmOilMinBar;
        return widget.engineLowOilAlarm ?? threshold;
      case 'temp':
        final k = widget.engineCoolantTempK;
        final c = k == null ? null : k - 273.15;
        final threshold = c != null && c > widget.alarmTempMaxC;
        return widget.engineOverTempAlarm ?? threshold;
      case 'precal':
        return (widget.enginePreheatActive ?? false) ||
            (widget.engineGlowPlugFaultAlarm ?? false);
      default:
        return false;
    }
  }

  // 'precal' is the one lamp whose color changes at runtime in real mode —
  // yellow for a normal preheat cycle, red the moment it's an actual fault
  // instead. Every other lamp keeps its fixed _MotorLamp.color.
  Color _lampColorReal(_MotorLamp lamp) {
    if (lamp.key == 'precal' && (widget.engineGlowPlugFaultAlarm ?? false)) {
      return cRed;
    }
    return lamp.color;
  }

  // Same SIMUL-vs-real split used by every _displayXxx getter above — the
  // gauge tiles' alarm color/LED use this too, so a manually-toggled lamp
  // under SIMUL is reflected there as well, not just on the lamp chip.
  bool _lampOn(String key) =>
      _simulEnabled ? (_lamps[key] ?? false) : _isLampOnReal(key);

  Widget _lampChip(_MotorLamp lamp) {
    final on = _lampOn(lamp.key);
    final color = _simulEnabled ? lamp.color : _lampColorReal(lamp);
    return GestureDetector(
      onTap: () => _toggleLampManually(lamp.key),
      child: Container(
        constraints: const BoxConstraints(minHeight: 38),
        decoration: BoxDecoration(
          color: on
              ? color.withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: on ? color : cMuted.withValues(alpha: 0.16),
            width: on ? 1.5 : 1,
          ),
          boxShadow: on
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.65),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          children: [
            Icon(
              lamp.icon,
              size: 18,
              color: on
                  ? Colors.black.withValues(alpha: 0.75)
                  : cMuted.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                lamp.label.replaceAll('\n', ' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: on
                      ? Colors.black.withValues(alpha: 0.85)
                      : cMuted.withValues(alpha: 0.45),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Temporary dev aid (see module comment above) — the OFF/ON/START/STOP
  // key buttons and the RPM slider only make sense while SIMUL is driving
  // this screen; with it off there's nothing real for them to control, so
  // they disappear rather than sit there doing nothing.
  Widget _buttonsAndSlider() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_simulEnabled) ...[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _roundKeyButton('OFF', Icons.power_settings_new, cMuted, _pressOff),
            _roundKeyButton(
              'ON',
              Icons.vpn_key,
              cCyan,
              _engineState == _EngineSimState.off ? _pressOn : null,
            ),
            _roundKeyButton(
              'START',
              Icons.play_arrow,
              cGreen,
              // Disabled until preheat actually finishes — see _pressOn.
              _engineState == _EngineSimState.ready ? _pressStart : null,
            ),
            _roundKeyButton(
              'STOP',
              Icons.stop,
              cRed,
              // Only once the starter's actually committed — during the
              // plain preheat wait there's nothing running yet to stop,
              // OFF is the right button to cancel that.
              (_engineState == _EngineSimState.cranking ||
                      _engineState == _EngineSimState.running)
                  ? _pressStop
                  : null,
            ),
          ],
        ),
        if (_engineState == _EngineSimState.running) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'RPM',
                style: TextStyle(
                  color: cCyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              Expanded(
                child: Slider(
                  value: (_manualRpm ?? _kSimIdleRpm).clamp(0, 4000),
                  min: 0,
                  max: 4000,
                  divisions: 40,
                  activeColor: cCyan,
                  // Only ever shown while simulating and running, so
                  // _displayRpm is guaranteed non-null here.
                  label: _displayRpm!.round().toString(),
                  onChanged: (v) {
                    setState(() => _manualRpm = v);
                    unawaited(
                      _idleLoopPlayer?.setPlaybackRate(_idleRateForRpm(v)),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    ],
  );

  Widget _simulArea() {
    if (_isCompact) {
      // Phone: SIMUL sits beside the buttons (not below them) — that's
      // what actually recovers the vertical room SIMUL needs on a short
      // screen, since a single row of buttons is already only one row
      // tall and stacking anything below it just adds height back.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _buttonsAndSlider()),
          _simulToggle(),
        ],
      );
    }
    // Tablet: original — SIMUL in its own row underneath the buttons.
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buttonsAndSlider(),
        if (_simulEnabled) const SizedBox(height: 6),
        Row(
          children: [
            const Spacer(),
            const Text(
              'SIMUL',
              style: TextStyle(
                color: cOrange,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            Switch(
              value: _simulEnabled,
              activeThumbColor: cOrange,
              onChanged: _onSimulToggle,
            ),
          ],
        ),
      ],
    );
  }

  Widget _simulToggle() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text(
        'SIMUL',
        style: TextStyle(
          color: cOrange,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
      Switch(
        value: _simulEnabled,
        activeThumbColor: cOrange,
        onChanged: _onSimulToggle,
      ),
    ],
  );

  Widget _roundKeyButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback? onTap,
  ) {
    final enabled = onTap != null;
    final c = enabled ? color : cMuted.withValues(alpha: 0.35);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.withValues(alpha: enabled ? 0.12 : 0.05),
              border: Border.all(color: c.withValues(alpha: 0.7), width: 1.6),
            ),
            child: Icon(icon, color: c, size: 20),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            color: c,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

// Realistic analog instrument — dial face, major/minor ticks, an optional
// colored danger arc, a tapered needle (with drop shadow + highlight
// stripe), a metal hub, a small digital LCD readout, and a soft glass-cover
// reflection on top. Replaces the old flat progress-arc gauges (the
// "muy feo" complaint) with something closer to a real boat gauge —
// modeled after physical marine tachometer/temp/oil/volt gauge clusters
// (85mm primary tach, smaller 52mm secondary gauges; see the research this
// design is based on). One implementation serves both the big RPM dial and
// the smaller secondary gauges — [big] only tunes label/tick font scale.
class _AnalogGaugePainter extends CustomPainter {
  const _AnalogGaugePainter({
    required this.value,
    required this.min,
    required this.max,
    required this.majorStep,
    required this.needleColor,
    required this.valueText,
    this.dangerStart,
    this.dangerEnd,
    this.big = false,
  });

  final double value;
  final double min;
  final double max;
  final double majorStep;
  final double? dangerStart;
  final double? dangerEnd;
  final Color needleColor;
  final bool big;
  final String valueText;

  // Bottom-left start, 270° clockwise sweep to bottom-right — a small gap
  // at the bottom like a real automotive dial, so 0 and max never overlap.
  static const _startRad = math.pi * 0.75;
  static const _sweepRad = math.pi * 1.5;

  double _angleFor(double v) {
    final t = ((v - min) / (max - min)).clamp(0.0, 1.0);
    return _startRad + _sweepRad * t;
  }

  String _fmtTick(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final r = s / 2;

    // Dial face — flat cBg, same as _panelShell's own card background, so
    // the circle blends continuously into the card with no visible seam.
    canvas.drawCircle(center, r, Paint()..color = cBg);

    // Bezel ring — a swept gradient stands in for a brushed-metal highlight.
    canvas.drawCircle(
      center,
      r - s * 0.015,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.025
        ..shader = const SweepGradient(
          colors: [
            Color(0xff3a4a54),
            Color(0xff0c1418),
            Color(0xff3a4a54),
            Color(0xff0c1418),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    final tickOuter = r * 0.82;
    final tickInner = r * 0.72;
    final minorInner = r * 0.77;

    if (dangerStart != null && dangerEnd != null && dangerStart! < dangerEnd!) {
      final a0 = _angleFor(dangerStart!);
      final a1 = _angleFor(dangerEnd!);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: tickOuter + s * 0.03),
        a0,
        a1 - a0,
        false,
        Paint()
          ..color = cRed.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.02
          ..strokeCap = StrokeCap.round,
      );
    }

    // Major ticks + numeric labels, with 3 unlabeled minor ticks between
    // each pair.
    final steps = ((max - min) / majorStep).round().clamp(1, 20);
    for (var i = 0; i <= steps; i++) {
      final v = min + majorStep * i;
      final a = _angleFor(v);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * tickInner,
        center + dir * tickOuter,
        Paint()
          ..color = cText.withValues(alpha: 0.85)
          ..strokeWidth = s * 0.012,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: _fmtTick(v),
          style: TextStyle(
            color: cMuted,
            fontSize: s * (big ? 0.06 : 0.095),
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = center + dir * (tickInner - s * 0.09);
      tp.paint(canvas, Offset(lp.dx - tp.width / 2, lp.dy - tp.height / 2));

      if (i < steps) {
        for (var m = 1; m < 4; m++) {
          final ma = _angleFor(v + majorStep * m / 4);
          final mdir = Offset(math.cos(ma), math.sin(ma));
          canvas.drawLine(
            center + mdir * minorInner,
            center + mdir * tickOuter,
            Paint()
              ..color = cMuted.withValues(alpha: 0.45)
              ..strokeWidth = s * 0.006,
          );
        }
      }
    }

    // Needle — a tapered quadrilateral (wide at the pivot, pointed tip)
    // plus a short tail for a counterweight look, with its own drop
    // shadow and a thin lengthwise highlight.
    final a = _angleFor(value);
    final dir = Offset(math.cos(a), math.sin(a));
    final perp = Offset(-math.sin(a), math.cos(a));
    final needleLen = tickInner * 0.92;
    final tailLen = r * 0.18;
    final baseW = s * (big ? 0.05 : 0.075);
    final tip = center + dir * needleLen;
    final baseL = center + perp * (baseW / 2) - dir * (tailLen * 0.1);
    final baseR = center - perp * (baseW / 2) - dir * (tailLen * 0.1);
    final tail = center - dir * tailLen;
    final needlePath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(baseL.dx, baseL.dy)
      ..lineTo(tail.dx, tail.dy)
      ..lineTo(baseR.dx, baseR.dy)
      ..close();

    canvas.save();
    canvas.translate(s * 0.012, s * 0.018);
    canvas.drawPath(
      needlePath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.012),
    );
    canvas.restore();

    canvas.drawPath(
      needlePath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [needleColor, needleColor.withValues(alpha: 0.7)],
        ).createShader(needlePath.getBounds()),
    );
    canvas.drawLine(
      center - dir * (tailLen * 0.5),
      center + dir * (needleLen * 0.9),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.3)
        ..strokeWidth = s * 0.006
        ..strokeCap = StrokeCap.round,
    );

    // Center hub.
    final hubR = s * (big ? 0.055 : 0.075);
    canvas.drawCircle(
      center,
      hubR,
      Paint()
        ..shader = RadialGradient(
          colors: const [cMuted, cPanel2, Colors.black],
          stops: const [0, 0.6, 1],
        ).createShader(Rect.fromCircle(center: center, radius: hubR)),
    );
    canvas.drawCircle(
      center,
      hubR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.6),
    );

    // Digital readout — e-ink style (matte pale ground, flat dark text),
    // matching every other plain numeric readout on this panel, instead of
    // the black-glass LCD look. Bigger than before per "se ven muy
    // pequeños": lcdH grew room-for-room with the font bump, so the box
    // still clears the min/max tick labels the same way it did at the
    // smaller size. Smaller/lower on the secondary gauges — their 2-3
    // digit min/max tick labels (e.g. "40"/"120") sit close enough to
    // center that the wider RPM-sized box used to run right over them.
    // RPM's box is sized just wide enough for 4 digits ("9999", the
    // widest it ever needs to show up to the 4000 RPM max) instead of
    // spanning nearly the whole dial with empty space either side.
    final lcdW = r * (big ? 0.62 : 0.8);
    final lcdH = r * 0.30;
    final lcdCenter = center + Offset(0, r * 0.60);
    final lcdRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: lcdCenter, width: lcdW, height: lcdH),
      Radius.circular(lcdH * 0.2),
    );
    // No contact (SIMUL OFF) means no power to the instrument at all — an
    // unpowered LCD isn't pale/legible, it's just a dim, slightly
    // greenish-grey panel with nothing on it. Reusing valueText.isEmpty as
    // the signal (see the SIMUL-off call sites, which pass '' instead of
    // '--' for exactly this) keeps this a one-line change instead of a
    // new prop threaded through _AnalogGauge.
    final unlit = valueText.isEmpty;
    canvas.drawRRect(
      lcdRect,
      Paint()..color = unlit ? const Color(0xff23241f) : _kEInkBg,
    );
    // Inset shadow — a dark gradient hugging the top edge and a faint
    // highlight along the bottom, clipped to the readout's own rounded
    // rect, so it reads as a screen recessed into the panel rather than
    // a flat sticker sitting on top of it.
    canvas.save();
    canvas.clipRRect(lcdRect);
    final insetRect = lcdRect.outerRect;
    canvas.drawRect(
      insetRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: const Alignment(0, -0.1),
          colors: [Colors.black.withValues(alpha: 0.32), Colors.transparent],
        ).createShader(insetRect),
    );
    canvas.drawRect(
      insetRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: const Alignment(0, 0.4),
          colors: [Colors.white.withValues(alpha: 0.10), Colors.transparent],
        ).createShader(insetRect),
    );
    canvas.restore();
    canvas.drawRRect(
      lcdRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.25),
    );
    final vtp = TextPainter(
      text: TextSpan(
        text: valueText,
        style: TextStyle(
          color: _kEInkText,
          fontSize: lcdH * 0.6,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: lcdW * 0.92);
    vtp.paint(
      canvas,
      Offset(lcdCenter.dx - vtp.width / 2, lcdCenter.dy - vtp.height / 2),
    );

    // Glass-cover reflection, drawn last and clipped to the dial.
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: r)),
    );
    final reflectRect = Rect.fromCenter(
      center: center + Offset(-r * 0.32, -r * 0.42),
      width: r * 1.15,
      height: r * 0.62,
    );
    canvas.drawOval(
      reflectRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(reflectRect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AnalogGaugePainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.majorStep != majorStep ||
      old.dangerStart != dangerStart ||
      old.dangerEnd != dangerEnd ||
      old.needleColor != needleColor ||
      old.valueText != valueText ||
      old.big != big;
}

// Wraps _AnalogGaugePainter with an optional label above, an optional
// DM1/UMBRAL/SIN DATO source caption below, and a TweenAnimationBuilder so
// the needle eases to a new value instead of snapping ("movimientos" —
// TweenAnimationBuilder automatically re-animates from wherever the needle
// currently is to the new target whenever [value] changes between builds).
class _AnalogGauge extends StatelessWidget {
  const _AnalogGauge({
    required this.value,
    required this.min,
    required this.max,
    required this.majorStep,
    required this.valueText,
    this.label,
    this.dangerStart,
    this.dangerEnd,
    this.needleColor = cCyan,
    this.big = false,
    this.source,
    this.ledState,
  });

  final String? label;
  final double? value;
  final double min;
  final double max;
  final double majorStep;
  final double? dangerStart;
  final double? dangerEnd;
  final Color needleColor;
  final bool big;
  final String valueText;
  final String? source;
  final _LedState? ledState;

  @override
  Widget build(BuildContext context) {
    final display = (value ?? min).clamp(min, max);
    // _panelShell has no padding of its own — without this, the label/LED
    // row sits flush against the card's rounded corners (radius 14) and
    // visually collides with the curve instead of clearing it.
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        // Stretch so the label gets the card's full width to left-align
        // into — same as every other card title in this app — instead of
        // shrink-wrapping to its own text width and centering that under
        // the (much wider) circular gauge below it.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null)
            Text(
              label!,
              style: TextStyle(
                color: cMuted,
                fontSize: big ? 12 : 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final d = math.min(constraints.maxWidth, constraints.maxHeight);
                return Center(
                  child: SizedBox(
                    width: d,
                    height: d,
                    // LED sits right on the dial's own rim (a real telltale
                    // mounted beside its gauge, not off in a header row) —
                    // Stack instead of the label Row is what gets it close.
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Positioned.fill, not a bare Stack child — a
                        // non-positioned child in a default (loose-fit)
                        // Stack is sized as small as it's allowed to be,
                        // and CustomPaint with no child of its own defaults
                        // to zero size under loose constraints. Without
                        // this the whole dial silently rendered blank.
                        Positioned.fill(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: display, end: display),
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOutCubic,
                            builder: (context, animatedValue, child) =>
                                CustomPaint(
                                  painter: _AnalogGaugePainter(
                                    value: animatedValue,
                                    min: min,
                                    max: max,
                                    majorStep: majorStep,
                                    dangerStart: dangerStart,
                                    dangerEnd: dangerEnd,
                                    needleColor: needleColor,
                                    big: big,
                                    valueText: valueText,
                                  ),
                                ),
                          ),
                        ),
                        if (ledState != null)
                          Positioned(
                            top: d * 0.04,
                            right: d * 0.04,
                            child: _StatusLed(state: ledState!),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (source != null)
            Text(
              source!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: needleColor.withValues(alpha: 0.75),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
        ],
      ),
    );
  }
}

enum _LedState { ok, alarm }

// A physical-panel-style telltale LED — bright off-center highlight,
// radial falloff to a darker rim, a thin bezel, and a soft colored glow
// bleeding outward, instead of a flat dot. Steady green/red only — when
// there's no reading to judge, the caller passes a null _LedState and
// skips this widget entirely rather than showing some third color.
class _StatusLed extends StatelessWidget {
  const _StatusLed({required this.state});
  final _LedState state;

  @override
  Widget build(BuildContext context) {
    final c = state == _LedState.ok ? cGreen : cRed;
    return Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black.withValues(alpha: 0.55)),
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.35),
          colors: [
            Color.lerp(Colors.white, c, 0.3)!,
            c,
            Color.lerp(c, Colors.black, 0.45)!,
          ],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: [
          BoxShadow(
            color: c.withValues(alpha: 0.7),
            blurRadius: 6,
            spreadRadius: 0.5,
          ),
        ],
      ),
    );
  }
}
