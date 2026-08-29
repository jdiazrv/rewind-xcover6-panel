part of '../main.dart';

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
    _trim(now);
  }

  void _trim(DateTime now) {
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

class _PressureHistory {
  final List<(DateTime, double)> _samples = [];
  static const _window = Duration(hours: 6);

  void add(double? value) {
    if (value == null) return;
    final now = DateTime.now();
    _samples.add((now, value));
    _trim(now);
  }

  void replaceWithGraphPoints(List<GraphPoint> points) {
    _samples
      ..clear()
      ..addAll([for (final p in points) (p.time.toLocal(), p.value)]);
    _trim(DateTime.now());
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(_window);
    while (_samples.isNotEmpty && _samples.first.$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  List<(DateTime, double)> get samples => List.unmodifiable(_samples);

  double? get ratePerHour {
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final hours = last.$1.difference(first.$1).inSeconds / 3600.0;
    if (hours <= 0) return null;
    return (last.$2 - first.$2) / hours;
  }

  int trend({double threshold = 0.15}) {
    final rate = ratePerHour;
    if (rate == null) return 0;
    if (rate > threshold) return 1;
    if (rate < -threshold) return -1;
    return 0;
  }

  String trendText() {
    final rate = ratePerHour;
    if (rate == null) return 'Tendencia pendiente';
    if (rate.abs() < 0.15) return 'Estable';
    final verb = rate > 0 ? 'Subiendo' : 'Bajando';
    return '$verb ${rate.abs().toStringAsFixed(1)} hPa/h';
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
