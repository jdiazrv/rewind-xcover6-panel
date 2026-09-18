part of '../main.dart';

/// CFG > Diagnóstico > Signal K: el servidor por dentro.
///
/// Lo sirve nuestro plugin (server/diagnostics.js), que corre dentro de
/// Signal K y ve lo que el servidor solo enseña a un administrador: versión,
/// último reinicio, CPU, memoria, disco, temperatura, plugins con sus
/// errores, velocidad de datos por conexión y las últimas líneas del log.
class SkDiagnosticsPanel extends StatelessWidget {
  const SkDiagnosticsPanel({
    super.key,
    required this.diag,
    required this.error,
    required this.updatedAt,
    required this.loading,
    required this.onlyErrors,
    required this.onRefresh,
    required this.onToggleOnlyErrors,
  });

  final SkDiagnostics? diag;
  final String? error;
  final DateTime? updatedAt;
  final bool loading;
  final bool onlyErrors;
  final VoidCallback onRefresh;
  final ValueChanged<bool> onToggleOnlyErrors;

  // Verde hasta 70 %, naranja hasta 90 %, rojo por encima: lo mismo para
  // CPU, memoria y disco, que es como se leen de un vistazo.
  static Color _pctColor(double? pct) => pct == null
      ? cMuted
      : pct >= 90
      ? cRed
      : pct >= 70
      ? cOrange
      : cGreen;

  // Una Raspberry Pi empieza a frenarse sola a 80 °C.
  static Color _tempColor(double? c) => c == null
      ? cMuted
      : c >= 75
      ? cRed
      : c >= 65
      ? cOrange
      : cGreen;

  // Corto para que quepa junto a "hace…": solo la hora si es de hoy, día y
  // mes si no. Con el año entero se cortaba ("hace 9 …") en el XCover.
  static String _dateTime(DateTime? t) {
    if (t == null) return '--';
    final l = t.toLocal();
    final now = DateTime.now();
    final today =
        l.year == now.year && l.month == now.month && l.day == now.day;
    if (today) return 'hoy ${hhmm(l)}';
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')} ${hhmm(l)}';
  }

  static String _es(num? v) =>
      v == null ? '--' : v.toString().replaceAll('.', ',');

  Widget _header() {
    final age = updatedAt == null
        ? null
        : DateTime.now().difference(updatedAt!).inSeconds;
    return Row(
      children: [
        Icon(
          error != null ? Icons.error_outline : Icons.dns_outlined,
          size: 16,
          color: error != null ? cRed : cCyan,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            error ??
                (diag == null
                    ? 'Pidiendo el diagnóstico al servidor…'
                    : 'Diagnóstico del servidor · actualizado hace ${age ?? 0} s'),
            style: TextStyle(
              color: error != null ? cRed : cMuted,
              fontSize: 12,
            ),
          ),
        ),
        if (loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          IconButton(
            tooltip: 'Actualizar',
            visualDensity: VisualDensity.compact,
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, color: cCyan, size: 20),
          ),
      ],
    );
  }

  Widget _bar(String label, double? pct, {String? detail, Color? color}) {
    final c = color ?? _pctColor(pct);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: cText, fontSize: 13),
                ),
              ),
              if (detail != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    detail,
                    style: const TextStyle(color: cMuted, fontSize: 11),
                  ),
                ),
              Text(
                pct == null ? '--' : '${pct.round()} %',
                style: TextStyle(
                  color: c,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct == null ? 0 : (pct / 100).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation(c),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusLine(SkDiagPlugin p) {
    final color = p.enabled == false
        ? cMuted
        : p.statusType == 'error'
        ? cRed
        : p.statusType == 'warning'
        ? cOrange
        : cGreen;
    final detail = [
      if (p.message != null) p.message!,
      if (p.statusType != 'error' && p.lastError != null)
        'último error: ${p.lastError}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(Icons.circle, size: 9, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.enabled == false ? cMuted : cText,
                    fontSize: 13,
                    fontWeight: p.statusType == 'error'
                        ? FontWeight.w800
                        : FontWeight.w500,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: p.statusType == 'error' ? 4 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.statusType == 'error' ? cRed : cMuted,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = diag;
    if (d == null) {
      return SettingsGroup(
        title: 'SIGNAL K',
        icon: Icons.dns_outlined,
        children: [_header()],
      );
    }
    final now = DateTime.now();
    final serverUp = d.serverStartedAt == null
        ? null
        : humanDuration(now.difference(d.serverStartedAt!));
    final hostUp = d.hostBootedAt == null
        ? null
        : humanDuration(now.difference(d.hostBootedAt!));

    final servidor = SettingsGroup(
      title: 'SERVIDOR',
      icon: Icons.dns_outlined,
      children: [
        _header(),
        SettingsStatusRow(
          label: 'Versión de Signal K',
          value: d.version ?? '--',
          color: cCyan,
        ),
        SettingsStatusRow(
          label: 'Node.js',
          value: d.nodeVersion ?? '--',
          color: cMuted,
        ),
        SettingsStatusRow(
          label: 'Último reinicio de Signal K',
          value: serverUp == null
              ? '--'
              : '${_dateTime(d.serverStartedAt)} · hace $serverUp',
          color: cText,
          icon: Icons.restart_alt,
        ),
        SettingsStatusRow(
          label: 'Datos recibidos',
          value: d.deltaRate == null
              ? '--'
              : '${_es(double.parse(d.deltaRate!.toStringAsFixed(1)))} /s',
          color: d.deltaRate == null || d.deltaRate == 0 ? cOrange : cGreen,
          icon: Icons.speed,
        ),
        SettingsStatusRow(
          label: 'Rutas disponibles',
          value: d.paths?.toString() ?? '--',
          color: cMuted,
        ),
        SettingsStatusRow(
          label: 'Clientes conectados',
          value: d.wsClients?.toString() ?? '--',
          color: cMuted,
        ),
        SettingsStatusRow(
          label: 'Memoria del servidor',
          value: d.rssMb == null ? '--' : '${d.rssMb!.round()} MB',
          color: cMuted,
        ),
      ],
    );

    final maquina = SettingsGroup(
      title: 'MÁQUINA',
      icon: Icons.memory,
      children: [
        SettingsStatusRow(
          label: d.hostname ?? 'Equipo',
          value: [
            if (d.cpuCount != null) '${d.cpuCount} núcleos',
            if (d.kernel != null) 'Linux ${d.kernel}',
          ].join(' · '),
          color: cMuted,
          icon: Icons.computer,
        ),
        SettingsStatusRow(
          label: 'Último arranque del equipo',
          value: hostUp == null
              ? '--'
              : '${_dateTime(d.hostBootedAt)} · hace $hostUp',
          color: cText,
          icon: Icons.power_settings_new,
        ),
        SettingsStatusRow(
          label: 'Temperatura de la CPU',
          value: d.cpuTempC == null
              ? '--'
              : '${_es(double.parse(d.cpuTempC!.toStringAsFixed(1)))} °C',
          color: _tempColor(d.cpuTempC),
          icon: Icons.thermostat,
        ),
        _bar(
          'Carga de CPU',
          d.loadPct,
          detail: d.load1 == null
              ? null
              : '${_es(d.load1)} · ${_es(d.load5)} · ${_es(d.load15)}',
        ),
        _bar(
          'Memoria',
          d.memUsedPct,
          detail: d.memTotalMb == null
              ? null
              : 'de ${_es(double.parse((d.memTotalMb! / 1000).toStringAsFixed(1)))} GB',
        ),
        _bar(
          'Disco',
          d.diskUsedPct,
          detail: d.diskFreeGb == null
              ? null
              : '${_es(d.diskFreeGb)} GB libres de ${_es(d.diskTotalGb)} GB',
        ),
        if (d.dataDiskUsedPct != null)
          _bar('Disco de datos', d.dataDiskUsedPct),
      ],
    );

    final activos = d.plugins.where((p) => p.enabled != false).toList();
    final apagados = d.plugins.where((p) => p.enabled == false).toList();
    final plugins = SettingsGroup(
      title: 'PLUGINS',
      icon: Icons.extension_outlined,
      children: [
        SettingsStatusRow(
          label: '${d.pluginsEnabled} activos de ${d.pluginsTotal}',
          value: d.pluginsWithErrors == 0
              ? 'sin errores'
              : '${d.pluginsWithErrors} con error',
          color: d.pluginsWithErrors == 0 ? cGreen : cRed,
        ),
        const SizedBox(height: 4),
        for (final p in activos) _statusLine(p),
        if (apagados.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Desactivados: ${apagados.map((p) => p.name).join(', ')}',
            style: const TextStyle(color: cMuted, fontSize: 11),
          ),
        ],
      ],
    );

    final rates = {for (final p in d.providers) p.id: p.deltaRate};
    final conexiones = SettingsGroup(
      title: 'CONEXIONES',
      icon: Icons.cable,
      children: [
        if (d.connections.isEmpty && d.providers.isEmpty)
          const Text(
            'El servidor no informa de sus conexiones.',
            style: TextStyle(color: cMuted, fontSize: 12),
          ),
        for (final c in d.connections)
          _statusLine(
            SkDiagPlugin(
              id: c.id,
              name: rates[c.id] == null
                  ? c.id
                  : '${c.id} · ${rates[c.id]!.toStringAsFixed(1)} datos/s',
              statusType: c.statusType,
              message: c.message,
              lastError: c.lastError,
              lastErrorAt: c.lastErrorAt,
            ),
          ),
        // Conexiones con tráfico pero sin estado publicado.
        for (final p in d.providers)
          if (!d.connections.any((c) => c.id == p.id))
            SettingsStatusRow(
              label: p.id,
              value: p.deltaRate == null
                  ? '--'
                  : '${p.deltaRate!.toStringAsFixed(1)} datos/s',
              color: (p.deltaRate ?? 0) > 0 ? cGreen : cOrange,
            ),
      ],
    );

    final lines = [
      for (final l in d.logLines.reversed)
        if (!onlyErrors || l.error) l,
    ];
    final log = SettingsGroup(
      title: 'LOG DEL SERVIDOR',
      icon: Icons.receipt_long_outlined,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                d.logLines.isEmpty
                    ? 'El servidor no devuelve su log.'
                    : '${d.logErrors} errores · ${d.logWarnings} avisos en las últimas ${d.logLines.length} líneas · lo más nuevo arriba',
                style: TextStyle(
                  color: d.logErrors > 0 ? cOrange : cMuted,
                  fontSize: 12,
                ),
              ),
            ),
            // Ancho fijo: SettingsCheckRow ocupa todo el que le den y, dentro
            // de otra fila, no le dan ninguno.
            SizedBox(
              width: 140,
              child: SettingsCheckRow(
                value: onlyErrors,
                onChanged: onToggleOnlyErrors,
                title: 'Solo errores',
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 360),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
          ),
          child: lines.isEmpty
              ? const Text(
                  'Nada que enseñar.',
                  style: TextStyle(color: cMuted, fontSize: 11),
                )
              : SingleChildScrollView(
                  child: SelectableText.rich(
                    TextSpan(
                      children: [
                        for (final l in lines)
                          TextSpan(
                            text: '${l.ts ?? ''}  ${l.text}\n',
                            style: TextStyle(
                              color: l.error
                                  ? cRed
                                  : l.warning
                                  ? cOrange
                                  : cMuted,
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              height: 1.35,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Las claves que aparezcan en el log se tapan antes de enseñarlo.',
          style: TextStyle(color: cMuted, fontSize: 10),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsResponsiveGroups(children: [servidor, maquina]),
        SettingsResponsiveGroups(children: [plugins, conexiones]),
        log,
      ],
    );
  }
}
