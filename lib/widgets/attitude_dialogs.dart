part of '../main.dart';

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
