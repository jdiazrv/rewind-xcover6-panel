part of '../main.dart';

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
    this.settings,
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
  final SettingsModel? settings;
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
              settings: settings,
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

class PressureTrendCard extends StatelessWidget {
  const PressureTrendCard({
    super.key,
    required this.value,
    required this.history,
    required this.fromInflux,
    required this.zoom,
  });
  final double? value;
  final _PressureHistory history;
  final bool fromInflux;
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
    final trend = history.trend();
    final trendText = history.trendText();
    final source = fromInflux ? 'InfluxDB' : 'en vivo';
    return CardShell(
      onTap: () => zoom?.call(
        'Presión',
        fmt(value, 0, ''),
        cPurple,
        subtitle: '$trendText · $source',
        graphMetrics: const [mPressure],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  'Presión',
                  style: TextStyle(
                    color: cMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                if (trend != 0) ...[
                  const SizedBox(width: 4),
                  Icon(
                    trend > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 15,
                    color: cPurple,
                  ),
                ],
                const Spacer(),
                const Text(
                  'hPa',
                  style: TextStyle(
                    color: cPurple,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.show_chart,
                  size: 13,
                  color: cPurple.withValues(alpha: 0.5),
                ),
              ],
            ),
            Expanded(
              flex: 5,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Text(
                    fmt(value, 0, ''),
                    style: const TextStyle(
                      fontSize: 300,
                      fontWeight: FontWeight.w900,
                      color: cPurple,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 82,
              width: double.infinity,
              child: CustomPaint(
                painter: _PressureSparklinePainter(
                  samples: history.samples,
                  color: cPurple,
                ),
                child: const SizedBox.expand(),
              ),
            ),
            Center(
              child: Text(
                trendText,
                textAlign: TextAlign.center,
                maxLines: 1,
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

class ModelWindCompassCard extends StatelessWidget {
  const ModelWindCompassCard({
    super.key,
    required this.forecast,
    required this.tws,
    required this.zoom,
  });
  final ForecastPoint? forecast;
  final double? tws;
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
    final color = windColor(forecast?.windKn);
    return CardShell(
      onTap: () => zoom?.call(
        'Viento modelo',
        fmt(forecast?.windKn, 0, ''),
        color,
        subtitle:
            '${forecast != null ? dir(forecast!.windDirDeg) : '--'} · TWS ${fmt(tws, 0, ' kt')}',
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  'Viento modelo',
                  style: TextStyle(
                    color: cMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  'kt',
                  style: TextStyle(
                    color: color,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: Text(
                                fmt(forecast?.windKn, 0, ''),
                                style: TextStyle(
                                  color: color,
                                  fontSize: 300,
                                  fontWeight: FontWeight.w900,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (forecast != null)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Transform.translate(
                                offset: const Offset(0, 0),
                                child: SizedBox(
                                  width: 30,
                                  height: 30,
                                  child: WindArrow(
                                    deg: forecast!.windDirDeg,
                                    speed: forecast!.windKn,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                dir(forecast!.windDirDeg),
                                style: const TextStyle(
                                  color: cMuted,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 92,
                    color: cMuted.withValues(alpha: 0.22),
                  ),
                  SizedBox(
                    width: 92,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'TWS',
                          style: TextStyle(
                            color: cMuted,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            fmt(tws, 0, ''),
                            style: TextStyle(
                              color: windColor(tws),
                              fontSize: 54,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            ),
                          ),
                        ),
                        const Text(
                          'kt',
                          style: TextStyle(
                            color: cMuted,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
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
    );
  }
}

class MarineGraphicCard extends StatelessWidget {
  const MarineGraphicCard({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.subtitle,
    required this.color,
    required this.directionDeg,
    required this.zoom,
    this.valueFontSize = 206,
    this.valueWidthFactor = 0.66,
    this.arrowSize = 68,
    this.arrowGap = 16,
    this.arrowLift = 16,
  });
  final String title;
  final double? value;
  final String unit;
  final String subtitle;
  final Color color;
  final double? directionDeg;
  final double valueFontSize;
  final double valueWidthFactor;
  final double arrowSize;
  final double arrowGap;
  final double arrowLift;
  final void Function(
    String title,
    String value,
    Color color, {
    String? subtitle,
    List<MetricDef>? graphMetrics,
  })?
  zoom;

  Widget _directionArrow() {
    final deg = directionDeg;
    if (deg == null) return const SizedBox.shrink();
    return Transform.rotate(
      angle: ((normalize360(deg) + 180) % 360) * math.pi / 180,
      child: Icon(Icons.navigation, color: color, size: arrowSize),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CardShell(
      onTap: () =>
          zoom?.call(title, fmt(value, 1, ' $unit'), color, subtitle: subtitle),
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
                Text(
                  unit,
                  style: TextStyle(
                    color: color,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 34),
                      child: CustomPaint(
                        painter: _MarineWavePainter(
                          directionDeg: directionDeg,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topLeft,
                    child: FractionallySizedBox(
                      widthFactor: valueWidthFactor,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                fmt(value, 1, ''),
                                style: TextStyle(
                                  fontSize: valueFontSize,
                                  fontWeight: FontWeight.w900,
                                  color: color,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: arrowGap),
                          Transform.translate(
                            offset: Offset(0, -arrowLift),
                            child: _directionArrow(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Center(
              child: Text(
                subtitle,
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

class PowerFlowTile extends StatelessWidget {
  const PowerFlowTile({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.subtitle,
    required this.color,
    required this.icon,
    required this.zoom,
    this.stateOfCharge,
    this.graphMetrics,
  });
  final String title;
  final String value;
  final String unit;
  final String subtitle;
  final Color color;
  final IconData icon;
  final double? stateOfCharge;
  final List<MetricDef>? graphMetrics;
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
    final soc = stateOfCharge?.clamp(0, 100).toDouble();
    return CardShell(
      onTap: () => zoom?.call(
        title,
        '$value $unit',
        color,
        subtitle: subtitle,
        graphMetrics: graphMetrics,
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cPanel2.withValues(alpha: 0.92), cPanel],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: color.withValues(alpha: 0.35)),
                  ),
                  child: Icon(icon, color: color, size: 27),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: cMuted,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                    ),
                  ),
                ),
                if (graphMetrics != null)
                  Icon(
                    Icons.show_chart,
                    size: 15,
                    color: color.withValues(alpha: 0.55),
                  ),
              ],
            ),
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        style: TextStyle(
                          color: color,
                          fontSize: 205,
                          fontWeight: FontWeight.w900,
                          height: 0.95,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 20, left: 8),
                        child: Text(
                          unit,
                          style: TextStyle(
                            color: color,
                            fontSize: 48,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (soc != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 7,
                  value: soc / 100,
                  color: color,
                  backgroundColor: cMuted.withValues(alpha: 0.22),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: const TextStyle(
                    color: cMuted,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PowerFlowConnector extends StatefulWidget {
  const PowerFlowConnector({
    super.key,
    required this.color,
    required this.watts,
    required this.label,
    required this.referenceWatts,
  });
  final Color color;
  final double? watts;
  final String label;
  final double referenceWatts;

  @override
  State<PowerFlowConnector> createState() => _PowerFlowConnectorState();
}

class _PowerFlowConnectorState extends State<PowerFlowConnector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool get _active => (widget.watts?.abs() ?? 0) > 5;
  double get _flowRatio =>
      ((widget.watts?.abs() ?? 0) / widget.referenceWatts).clamp(0.0, 1.0);
  Duration get _flowDuration {
    final ratio = _flowRatio;
    final eased = math.sqrt(ratio).clamp(0.0, 1.0);
    final ms = ui.lerpDouble(2600, 520, eased)!.round();
    return Duration(milliseconds: ms);
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _flowDuration);
    if (_active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant PowerFlowConnector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final durationChanged =
        oldWidget.watts != widget.watts ||
        oldWidget.referenceWatts != widget.referenceWatts;
    if (durationChanged) {
      _controller.duration = _flowDuration;
    }
    if (_active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (_active && durationChanged) {
      _controller.repeat();
    } else if (!_active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final watts = widget.watts;
    final reverse = watts != null && watts < -5;
    return SizedBox(
      width: 82,
      child: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (_, __) => CustomPaint(
                painter: _PowerFlowConnectorPainter(
                  color: widget.color,
                  progress: _controller.value,
                  active: _active,
                  reverse: reverse,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _active ? widget.color : cMuted,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

class _PowerFlowConnectorPainter extends CustomPainter {
  const _PowerFlowConnectorPainter({
    required this.color,
    required this.progress,
    required this.active,
    required this.reverse,
  });
  final Color color;
  final double progress;
  final bool active;
  final bool reverse;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * 0.50;
    final start = Offset(6, y);
    final end = Offset(size.width - 6, y);
    final track = Paint()
      ..color = cMuted.withValues(alpha: 0.22)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, track);

    final flowPaint = Paint()
      ..color = (active ? color : cMuted).withValues(
        alpha: active ? 0.82 : 0.34,
      )
      ..strokeWidth = active ? 5 : 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, flowPaint);

    for (var i = 0; i < 4; i++) {
      var t = (progress + i * 0.25) % 1.0;
      if (reverse) t = 1 - t;
      final x = ui.lerpDouble(start.dx + 10, end.dx - 10, t)!;
      final alpha = active ? (0.32 + 0.68 * math.sin(math.pi * t).abs()) : 0.35;
      final p = Offset(x, y);
      final dir = reverse ? -1.0 : 1.0;
      final path = Path()
        ..moveTo(p.dx + dir * 10, p.dy)
        ..lineTo(p.dx - dir * 5, p.dy - 8)
        ..lineTo(p.dx - dir * 5, p.dy + 8)
        ..close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(covariant _PowerFlowConnectorPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.progress != progress ||
      oldDelegate.active != active ||
      oldDelegate.reverse != reverse;
}

class PowerAuxTile extends StatelessWidget {
  const PowerAuxTile({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.subtitle,
    required this.color,
    required this.zoom,
    this.icon,
    this.customIcon,
    this.graphMetrics,
  });
  final String title;
  final String value;
  final String unit;
  final String subtitle;
  final Color color;
  final IconData? icon;
  final Widget? customIcon;
  final List<MetricDef>? graphMetrics;
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
        '$value $unit',
        color,
        subtitle: subtitle,
        graphMetrics: graphMetrics,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: 0.34)),
              ),
              child:
                  customIcon ??
                  Icon(icon ?? Icons.battery_std, color: color, size: 33),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: cMuted,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.7,
                          ),
                        ),
                      ),
                      if (graphMetrics != null)
                        Icon(
                          Icons.show_chart,
                          size: 14,
                          color: color.withValues(alpha: 0.55),
                        ),
                    ],
                  ),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            value,
                            style: TextStyle(
                              color: color,
                              fontSize: 118,
                              fontWeight: FontWeight.w900,
                              height: 0.95,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 10, left: 6),
                            child: Text(
                              unit,
                              style: TextStyle(
                                color: color,
                                fontSize: 36,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      style: const TextStyle(
                        color: cMuted,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
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
}

class BowThrusterGlyph extends StatelessWidget {
  const BowThrusterGlyph({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BowThrusterGlyphPainter(color),
    child: const SizedBox.expand(),
  );
}

class _BowThrusterGlyphPainter extends CustomPainter {
  const _BowThrusterGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = size.shortestSide * 0.055
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final center = Offset(size.width * 0.50, size.height * 0.61);
    final radius = size.shortestSide * 0.33;

    final head = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.50, size.height * 0.13),
        width: size.width * 0.43,
        height: size.height * 0.22,
      ),
      Radius.circular(size.shortestSide * 0.035),
    );
    canvas.drawRRect(head, fillPaint);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width * 0.50, size.height * 0.31),
        width: size.width * 0.26,
        height: size.height * 0.16,
      ),
      fillPaint,
    );
    canvas.drawCircle(center, radius, stroke..strokeWidth = radius * 0.24);

    final bladePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (var i = 0; i < 6; i++) {
      final a = -math.pi / 2 + i * math.pi / 3;
      final inner = center + Offset(math.cos(a), math.sin(a)) * radius * 0.18;
      final outer = center + Offset(math.cos(a), math.sin(a)) * radius * 0.70;
      final left =
          center +
          Offset(math.cos(a - 0.48), math.sin(a - 0.48)) * radius * 0.45;
      final right =
          center +
          Offset(math.cos(a + 0.52), math.sin(a + 0.52)) * radius * 0.53;
      final blade = Path()
        ..moveTo(inner.dx, inner.dy)
        ..quadraticBezierTo(left.dx, left.dy, outer.dx, outer.dy)
        ..quadraticBezierTo(right.dx, right.dy, inner.dx, inner.dy)
        ..close();
      canvas.drawPath(blade, bladePaint);
    }
    canvas.drawCircle(center, radius * 0.20, Paint()..color = cPanel);
    canvas.drawCircle(center, radius * 0.20, stroke..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(covariant _BowThrusterGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

class StarterMotorGlyph extends StatelessWidget {
  const StarterMotorGlyph({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _StarterMotorGlyphPainter(color),
    child: const SizedBox.expand(),
  );
}

class _StarterMotorGlyphPainter extends CustomPainter {
  const _StarterMotorGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = size.shortestSide * 0.052
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.13)
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.translate(size.width * 0.50, size.height * 0.53);
    canvas.rotate(-0.22);
    canvas.translate(-size.width * 0.50, -size.height * 0.53);

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.17,
        size.height * 0.37,
        size.width * 0.45,
        size.height * 0.24,
      ),
      Radius.circular(size.shortestSide * 0.09),
    );
    final solenoid = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.30,
        size.height * 0.19,
        size.width * 0.40,
        size.height * 0.18,
      ),
      Radius.circular(size.shortestSide * 0.08),
    );
    canvas.drawRRect(body, fill);
    canvas.drawRRect(body, stroke);
    canvas.drawRRect(solenoid, fill);
    canvas.drawRRect(solenoid, stroke);
    canvas.drawLine(
      Offset(size.width * 0.62, size.height * 0.43),
      Offset(size.width * 0.73, size.height * 0.43),
      stroke,
    );

    final noseCenter = Offset(size.width * 0.76, size.height * 0.51);
    canvas.drawCircle(noseCenter, size.shortestSide * 0.15, fill);
    canvas.drawCircle(noseCenter, size.shortestSide * 0.15, stroke);
    canvas.drawCircle(noseCenter, size.shortestSide * 0.07, stroke);
    for (var i = 0; i < 9; i++) {
      final a = i * math.pi * 2 / 9;
      final p1 =
          noseCenter +
          Offset(math.cos(a), math.sin(a)) * size.shortestSide * 0.05;
      final p2 =
          noseCenter +
          Offset(math.cos(a), math.sin(a)) * size.shortestSide * 0.12;
      canvas.drawLine(p1, p2, stroke..strokeWidth = size.shortestSide * 0.025);
    }

    canvas.drawPath(
      Path()
        ..moveTo(size.width * 0.70, size.height * 0.34)
        ..lineTo(size.width * 0.86, size.height * 0.39)
        ..lineTo(size.width * 0.86, size.height * 0.67)
        ..lineTo(size.width * 0.70, size.height * 0.72),
      stroke..strokeWidth = size.shortestSide * 0.044,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StarterMotorGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
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
                                        // "--" (not "0") when there's no
                                        // reading at all, so an actually-empty
                                        // tank and a missing/unconfigured one
                                        // don't look identical.
                                        text: value == null
                                            ? '--'
                                            : percent.round().toString(),
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
// Dot pagination for the NAV page's cyclic vertical swipe. Page 0 (the
// user's actual selected cards) is drawn as a small square instead of a
// dot — everything else is "more cards to pick from" — so it's obvious at
// a glance whether you're home or browsing the catalog.
class _NavPageIndicator extends StatelessWidget {
  const _NavPageIndicator({required this.total, required this.current});
  final int total;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      // Vertical, matching the vertical swipe direction it reflects.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(height: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: i == current ? 8 : 6,
              height: i == current ? 8 : 6,
              decoration: BoxDecoration(
                color: i == current ? cCyan : cMuted.withValues(alpha: 0.5),
                shape: i == current ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: i == current ? BorderRadius.circular(2) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
