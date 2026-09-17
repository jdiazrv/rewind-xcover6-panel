part of '../main.dart';

/// Los últimos usos del motor, en lista o en gráfico, con el periodo a elegir.
///
/// Se abre tocando la línea de "último uso" / "en marcha desde" de la pantalla
/// de motor. Los datos se piden al histórico del servidor a través de [load],
/// que inyecta main.dart, para que este diálogo no sepa nada de red.
class EngineRunsDialog extends StatefulWidget {
  const EngineRunsDialog({super.key, required this.load, this.runningSince});

  final Future<List<EngineRunSummary>> Function(Duration range) load;

  /// Arranque en curso, para pintarlo arriba aunque el histórico no lo tenga
  /// todavía (el servidor puede ir con unos minutos de retraso).
  final DateTime? runningSince;

  @override
  State<EngineRunsDialog> createState() => _EngineRunsDialogState();
}

class _EngineRunsDialogState extends State<EngineRunsDialog> {
  static const _ranges = <(String, Duration)>[
    ('24 h', Duration(days: 1)),
    ('7 días', Duration(days: 7)),
    ('30 días', Duration(days: 30)),
    ('1 año', Duration(days: 365)),
  ];

  int _rangeIndex = 1;
  bool _asChart = false;
  bool _loading = true;
  String? _error;
  List<EngineRunSummary> _runs = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final runs = await widget.load(_ranges[_rangeIndex].$2);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyApiError(e);
        _loading = false;
      });
    }
  }

  String _fecha(DateTime value) {
    final d = value.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}';
  }

  // hhmm ya formatea la hora en toda la app; aquí solo hay que pasar a local.
  String _hora(DateTime value) => hhmm(value.toLocal());

  String _duracion(double hours) => hours >= 1
      ? '${hours.toStringAsFixed(1)} h'
      : '${(hours * 60).round()} min';

  Widget _header() => Row(
    children: [
      const Icon(Icons.timelapse, color: cOrange, size: 20),
      const SizedBox(width: 8),
      const Expanded(
        child: Text(
          'Usos del motor',
          style: TextStyle(
            color: cText,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      IconButton(
        tooltip: _asChart ? 'Ver en lista' : 'Ver en gráfico',
        icon: Icon(
          _asChart ? Icons.list_alt : Icons.bar_chart,
          color: cCyan,
          size: 20,
        ),
        onPressed: () => setState(() => _asChart = !_asChart),
      ),
      IconButton(
        tooltip: 'Cerrar',
        icon: const Icon(Icons.close, color: cMuted, size: 20),
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );

  Widget _rangeChips() => Wrap(
    spacing: 6,
    children: [
      for (var i = 0; i < _ranges.length; i++)
        ChoiceChip(
          label: Text(_ranges[i].$1, style: const TextStyle(fontSize: 12)),
          selected: _rangeIndex == i,
          onSelected: (_) {
            if (_rangeIndex == i) return;
            setState(() => _rangeIndex = i);
            unawaited(_reload());
          },
        ),
    ],
  );

  Widget _resumen() {
    if (_runs.isEmpty) return const SizedBox.shrink();
    final total = _runs.fold<double>(0, (sum, r) => sum + r.durationHours);
    final masLargo = _runs
        .map((r) => r.durationHours)
        .reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(
        '${_runs.length} ${_runs.length == 1 ? 'uso' : 'usos'} · '
        'total ${_duracion(total)} · más largo ${_duracion(masLargo)}',
        style: const TextStyle(color: cMuted, fontSize: 12),
      ),
    );
  }

  Widget _lista() => ListView.separated(
    itemCount: _runs.length,
    separatorBuilder: (_, _) => const Divider(height: 1, color: cPanel2),
    itemBuilder: (context, i) {
      final r = _runs[i];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(
                _fecha(r.startedAt),
                style: const TextStyle(
                  color: cMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Text(
                '${_hora(r.startedAt)} → ${_hora(r.endedAt)}',
                style: const TextStyle(color: cText, fontSize: 13),
              ),
            ),
            Text(
              _duracion(r.durationHours),
              style: const TextStyle(
                color: cOrange,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _grafico() {
    final maxHoras = _runs
        .map((r) => r.durationHours)
        .reduce((a, b) => a > b ? a : b);
    return ListView.builder(
      itemCount: _runs.length,
      itemBuilder: (context, i) {
        final r = _runs[i];
        final fraccion = maxHoras <= 0 ? 0.0 : r.durationHours / maxHoras;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 78,
                child: Text(
                  '${_fecha(r.startedAt)} ${_hora(r.startedAt)}',
                  style: const TextStyle(color: cMuted, fontSize: 11),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: fraccion,
                    minHeight: 14,
                    backgroundColor: cPanel2,
                    valueColor: const AlwaysStoppedAnimation(cOrange),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 54,
                child: Text(
                  _duracion(r.durationHours),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: cText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.runningSince;
    return Dialog(
      backgroundColor: cPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              if (running != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    engineCurrentRunLabel(running, DateTime.now()),
                    style: const TextStyle(
                      color: cGreen,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              _rangeChips(),
              _resumen(),
              const SizedBox(height: 4),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'No se pudo leer el histórico: $_error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: cRed, fontSize: 13),
                          ),
                        ),
                      )
                    : _runs.isEmpty
                    ? const Center(
                        child: Text(
                          'Sin usos del motor en este periodo',
                          style: TextStyle(color: cMuted, fontSize: 13),
                        ),
                      )
                    : (_asChart ? _grafico() : _lista()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
