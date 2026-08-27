import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  Vec3 get normalized {
    final l = length;
    return l < 1e-9 ? const Vec3(0, 0, 1) : Vec3(x / l, y / l, z / l);
  }
}

/// Maps the device's raw accelerometer frame to the boat's own roll/pitch
/// axes, for ANY physical mounting orientation (flat, vertical, upside
/// down, at an angle...) — unlike guessing a fixed "X or Y" axis, which
/// only works for the handful of mountings where a device axis happens to
/// line up with the boat's.
///
/// [down] alone (from a level reading) fixes 2 of gravity's 3 degrees of
/// freedom; the 3rd — rotation about the down axis, i.e. which way the
/// device is "facing" — can't be recovered from gravity alone, so [right]
/// comes from comparing the device's own tilt-compensated compass heading
/// (accelerometer for tilt, magnetometer projected orthogonal to it —
/// standard eCompass technique, see NXP AN4248) against the boat's own
/// heading from Signal K, averaged over a longer window to damp out
/// magnetic noise near a boat's engine/electronics.
class AttitudeCalibration {
  const AttitudeCalibration({required this.down, required this.right});

  final Vec3 down;
  final Vec3 right;

  /// Before any calibration: assumes the device lies flat, screen up —
  /// gives a plausible-ish reading immediately rather than nothing, though
  /// step 2 (heading comparison) is still needed for a mounting-independent
  /// result.
  static const fallback = AttitudeCalibration(
    down: Vec3(0, 0, 1),
    right: Vec3(0, 1, 0),
  );

  /// (rollDeg, pitchDeg) — positive roll = heeled to starboard, positive
  /// pitch = bow up (unverified against a real boat sensor, only chosen to
  /// match this app's existing sign convention).
  (double, double) resolve(Vec3 raw) {
    final d = down.normalized;
    // Re-orthogonalize right against down every time, in case stored
    // calibration data drifted slightly (e.g. from averaging noise).
    var r = right - d * right.dot(d);
    r = r.length < 1e-6 ? const Vec3(0, 1, 0) : r.normalized;
    final f = d.cross(r);
    final boatFwd = raw.dot(f);
    final boatRight = raw.dot(r);
    final boatDown = raw.dot(d);
    final roll = math.atan2(boatRight, boatDown) * 180 / math.pi;
    final pitch =
        math.atan2(
          -boatFwd,
          math.sqrt(boatRight * boatRight + boatDown * boatDown),
        ) *
        180 /
        math.pi;
    return (roll, pitch);
  }
}

/// Averages raw accelerometer samples over [duration] into a single
/// normalized vector — used for calibration step 1 (capture while the boat
/// is held level).
Future<Vec3> captureAveragedGravity({
  Duration duration = const Duration(seconds: 3),
}) async {
  final avg = await _captureAveragedRaw(duration);
  return avg.normalized;
}

/// Same accelerometer averaging as [captureAveragedGravity], but without
/// normalizing — the turn-based calibration method needs the small
/// residual left after subtracting gravity, not just its direction, to
/// judge whether a turn was sharp enough to trust.
Future<Vec3> captureAveragedAccel({
  Duration duration = const Duration(seconds: 6),
}) => _captureAveragedRaw(duration);

Future<Vec3> _captureAveragedRaw(Duration duration) async {
  final samples = <Vec3>[];
  final sub = accelerometerEventStream(
    samplingPeriod: const Duration(milliseconds: 100),
  ).listen((e) => samples.add(Vec3(e.x, e.y, e.z)));
  await Future.delayed(duration);
  await sub.cancel();
  if (samples.isEmpty) return const Vec3(0, 0, 1);
  var sum = const Vec3(0, 0, 0);
  for (final s in samples) {
    sum += s;
  }
  return sum * (1 / samples.length);
}

/// Horizontal component of the magnetometer reading (i.e. with the tilt
/// from [down] removed) — points toward magnetic north as seen in device
/// coordinates, however the device happens to be angled.
Vec3 _horizontalNorth(Vec3 mag, Vec3 down) {
  final d = down.normalized;
  final n = mag - d * mag.dot(d);
  return n.length < 1e-6 ? const Vec3(1, 0, 0) : n.normalized;
}

/// The boat's bow direction in device coordinates, derived from the
/// device's own magnetometer + accelerometer and the boat's own heading
/// (from Signal K). [boatHeadingDeg] is degrees clockwise from magnetic
/// north.
///
/// Ignores magnetic declination: only ever compared against the boat's own
/// heading at the same instant, so a constant declination error cancels
/// out — it doesn't matter that "north" here isn't quite true north.
Vec3 forwardFromHeading(Vec3 down, Vec3 mag, double boatHeadingDeg) {
  final d = down.normalized;
  final north = _horizontalNorth(mag, d);
  final east = d.cross(north);
  final rad = boatHeadingDeg * math.pi / 180;
  return (north * math.cos(rad) + east * math.sin(rad)).normalized;
}

/// Estimates the magnetometer's hard-iron bias (a constant offset vector
/// from the device's own speaker/camera/battery magnets, near-universal on
/// phones and never compensated by this app before) by tracking the
/// min/max reading on each axis while the device is waved through varied
/// orientations — the same idea behind the "move in a figure-8" gesture
/// compass apps prompt for. Without this, a raw magnetometer reading can
/// be tens of degrees off in azimuth, which is what was showing up as
/// pitch bleeding into the roll reading.
Future<Vec3> captureMagBias({
  Duration duration = const Duration(seconds: 12),
}) async {
  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  var minZ = double.infinity, maxZ = -double.infinity;
  final sub =
      magnetometerEventStream(samplingPeriod: const Duration(milliseconds: 50))
          .listen((e) {
            if (e.x < minX) minX = e.x;
            if (e.x > maxX) maxX = e.x;
            if (e.y < minY) minY = e.y;
            if (e.y > maxY) maxY = e.y;
            if (e.z < minZ) minZ = e.z;
            if (e.z > maxZ) maxZ = e.z;
          });
  await Future.delayed(duration);
  await sub.cancel();
  if (minX.isInfinite) return const Vec3(0, 0, 0);
  return Vec3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
}

/// Averages accelerometer + magnetometer samples over [duration] at once —
/// calibration step 2 needs both from the same window. Magnetometer
/// magnitude (µT) is kept unnormalized so the caller can sanity-check it
/// against Earth's field strength (~25-65 µT) and warn about magnetic
/// interference from the boat's own engine/electronics.
Future<({Vec3 accel, Vec3 mag})> captureAccelAndMag({
  Duration duration = const Duration(seconds: 10),
}) async {
  final accelSamples = <Vec3>[];
  final magSamples = <Vec3>[];
  final subA = accelerometerEventStream(
    samplingPeriod: const Duration(milliseconds: 100),
  ).listen((e) => accelSamples.add(Vec3(e.x, e.y, e.z)));
  final subM = magnetometerEventStream(
    samplingPeriod: const Duration(milliseconds: 100),
  ).listen((e) => magSamples.add(Vec3(e.x, e.y, e.z)));
  await Future.delayed(duration);
  await subA.cancel();
  await subM.cancel();
  Vec3 avg(List<Vec3> l) {
    if (l.isEmpty) return const Vec3(0, 0, 0);
    var sum = const Vec3(0, 0, 0);
    for (final s in l) {
      sum += s;
    }
    return sum * (1 / l.length);
  }

  final accel = accelSamples.isEmpty
      ? const Vec3(0, 0, 1)
      : avg(accelSamples).normalized;
  return (accel: accel, mag: avg(magSamples));
}

/// Continuously tracks device attitude as an alternative heel/pitch source.
/// [calibration] is mutable so CFG/the inclinometer screen can update it
/// live without recreating the tracker.
class PhoneHeelTracker {
  PhoneHeelTracker({
    required this.onUpdate,
    this.onPitchUpdate,
    this.calibration = AttitudeCalibration.fallback,
  });

  final void Function(double heelDeg) onUpdate;
  final void Function(double pitchDeg)? onPitchUpdate;
  AttitudeCalibration calibration;

  StreamSubscription<AccelerometerEvent>? _sub;
  Vec3? _smoothed;
  int _sampleCount = 0;

  bool get isRunning => _sub != null;

  void start() {
    if (_sub != null) return;
    _sampleCount = 0;
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen(_onEvent);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _smoothed = null;
  }

  void _onEvent(AccelerometerEvent e) {
    final raw = Vec3(e.x, e.y, e.z);
    // Exponential smoothing — heel/pitch themselves change slowly, but a
    // hand-held or slap-mounted device picks up a lot of higher-frequency
    // vibration at 10 Hz, so a ~1s time constant damps that while still
    // tracking real attitude changes.
    _smoothed = _smoothed == null
        ? raw
        : _smoothed! + (raw - _smoothed!) * 0.15;
    // Only push a UI update every ~300ms (every 3rd sample) — 10 Hz worth
    // of setState calls would be wasted work for a value this slow-moving.
    _sampleCount++;
    if (_sampleCount % 3 != 0) return;
    final (roll, pitch) = calibration.resolve(_smoothed!);
    onUpdate(roll);
    onPitchUpdate?.call(pitch);
  }
}
