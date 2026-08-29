part of '../main.dart';

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
    this.subtitleFontSize = 28,
  });

  final String title;
  final String value;
  final String? unit;
  final String? subtitle;
  final double subtitleFontSize;
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
                          crossAxisAlignment: CrossAxisAlignment.start,
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
                  style: TextStyle(
                    color: cMuted,
                    fontSize: subtitleFontSize,
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
