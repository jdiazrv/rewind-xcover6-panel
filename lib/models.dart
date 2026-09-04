import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'attitude_sensor.dart';
import 'data_api.dart';
import 'theme.dart';

// How far ahead/behind the connected Signal K server's own clock this
// device's clock is (server − device) — refreshed opportunistically from
// the `Date` response header on ordinary REST calls (see main.dart's
// _fetchVesselName, the call site of skRecordServerDate). The anchor
// watch's cross-device "last write wins" arbitration
// (AnchorConfig.armedOrMovedAt, set from both main.dart and
// anchor_native_view.dart) stamps edits with skNow() instead of a raw
// DateTime.now(), so two devices whose own clocks disagree still order
// their edits consistently against the ONE server clock they both
// actually talk to, rather than against each other's potentially-skewed
// local time. Lives here (not main.dart) so anchor_native_view.dart — a
// separate library that only imports models.dart/theme.dart, not a `part
// of` file — can reach it too. Verified real via external audit, fixed
// 2026-09-04.
Duration skClockOffset = Duration.zero;
DateTime skNow() => DateTime.now().toUtc().add(skClockOffset);

// RFC 7231 preferred HTTP-date format only (what every HTTP server this
// app talks to actually sends, including Signal K's), e.g.
// "Sun, 06 Nov 1994 08:49:37 GMT" — not a general RFC 7231 parser (the
// obsolete asctime()/RFC 850 alternate forms are never seen in practice
// here), and deliberately not using dart:io's HttpDate.parse, which isn't
// available on web.
final _httpDateRe = RegExp(
  r'^\w+, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);
const _httpDateMonths = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};
DateTime? _parseHttpDate(String s) {
  final m = _httpDateRe.firstMatch(s.trim());
  if (m == null) return null;
  final month = _httpDateMonths[m.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}

// Updates skClockOffset from an HTTP response's `Date` header, when
// present and parseable — call sites are ordinary REST calls this app
// already makes (see _fetchVesselName), not a dedicated round trip of its
// own. Second-precision only (HTTP dates carry no finer resolution) and
// ignores request/response latency entirely — nowhere near NTP-grade, but
// easily good enough to correct the many-minutes-to-hours clock drift that
// actually causes cross-device anchor conflicts, at zero extra network
// cost.
void skRecordServerDate(http.BaseResponse response) {
  final raw = response.headers['date'];
  if (raw == null) return;
  final serverNow = _parseHttpDate(raw);
  if (serverNow == null) return;
  skClockOffset = serverNow.difference(DateTime.now().toUtc());
}

// Moved here from utils/format_helpers.dart (a `part of main.dart` file
// that can't be reached from models.dart's own standalone library) so
// computeYawAnalysis below can use it too — main.dart and its part files
// already see this via main.dart's own `import 'models.dart';`.
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

/// Great-circle bearing/distance between two points — shared by the AIS
/// radar (ais_view.dart, in nautical miles) and the native anchor watch
/// (main.dart, in meters), so both use the same Haversine math instead of
/// two divergent copies.
({double bearingDeg, double distanceM}) bearingDistanceMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const r = 6371000.0; // meters
  final dLat = (lat2 - lat1) * math.pi / 180,
      dLon = (lon2 - lon1) * math.pi / 180;
  final lat1r = lat1 * math.pi / 180, lat2r = lat2 * math.pi / 180;
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
  return (bearingDeg: brg, distanceM: r * c);
}

/// Whether a point [distanceM] from the drop position, at true bearing
/// [bearingFromDropDeg] from it, counts as outside the anchor watch zone —
/// circle: past the radius; sector: ALSO past the radius, or past the
/// arc's span even while still inside it. Shared by the drag-alarm engine
/// (main.dart's _isOutsideAnchorZone) and the ANC screen's own live
/// "outside" status (anchor_native_view.dart) so the two can never
/// disagree about the same zone — the screen used to only ever compare
/// distance to radius, so a sector watch could show a calm "FONDEADO"
/// while the real alarm correctly fired for being outside the arc.
bool isOutsideWatchZone({
  required double distanceM,
  required double radiusM,
  required String shape,
  double? bearingFromDropDeg,
  double? sectorStartDeg,
  double? sectorEndDeg,
}) {
  if (distanceM > radiusM) return true;
  if (shape != 'sector') return false;
  if (bearingFromDropDeg == null ||
      sectorStartDeg == null ||
      sectorEndDeg == null) {
    return false;
  }
  final span = (sectorEndDeg - sectorStartDeg + 360) % 360;
  final rel = (bearingFromDropDeg - sectorStartDeg + 360) % 360;
  return rel > span;
}

class GraphPoint {
  const GraphPoint({required this.time, required this.value});
  final DateTime time;
  final double value;
}

// ─── Metric definitions ───────────────────────────────────────────────────────
class MetricDef {
  const MetricDef(
    this.skPath,
    this.label,
    this.unit, {
    this.offset = 0.0,
    this.scale = 1.0,
    this.color = cCyan,
  });
  final String skPath;
  final String label;
  final String unit;
  final double offset;
  final double scale;
  final Color color;
}

const mPressure = MetricDef(
  'environment.outside.pressure',
  'Presión',
  'mbar',
  scale: 1.0,
  color: cPurple,
);
const mOutdoorTemp = MetricDef(
  'environment.outside.temperature',
  'T. exterior',
  'C',
  offset: -273.15,
  color: cCyan,
);
const mSeaTemp = MetricDef(
  'environment.water.temperature',
  'T. mar',
  'C',
  offset: -273.15,
  color: cCyan,
);
const mSonoffTemp = MetricDef(
  'environment.sonoff.temperature',
  'T. Sonoff',
  'C',
  offset: -273.15,
  color: cOrange,
);
const mSolarFusesTemp = MetricDef(
  'environment.solar_fuses.temperature',
  'T. Fusibles solar',
  'C',
  offset: -273.15,
  color: cOrange,
);
const mDcLoads = MetricDef(
  'electrical.venus.dcPower',
  'DC Loads',
  'W',
  color: cOrange,
);
const mBowV = MetricDef(
  'electrical.batteries.bowthruster.voltage',
  'Bowthruster',
  'V',
  color: cCyan,
);
const mTws = MetricDef(
  'environment.wind.speedTrue',
  'TWS',
  'kn',
  scale: 1.94384,
  color: cCyan,
);
const mHeel = MetricDef(
  'navigation.attitude.roll',
  'Escora',
  '°',
  scale: 57.2957795,
  color: cYellow,
);
const mAws = MetricDef(
  'environment.wind.speedApparent',
  'AWS',
  'kn',
  scale: 1.94384,
  color: cGreen,
);
const mAwa = MetricDef(
  'environment.wind.angleApparent',
  'AWA',
  'deg',
  scale: 57.2957795,
  color: cGreen,
);
const mTwa = MetricDef(
  'environment.wind.angleTrueWater',
  'TWA',
  'deg',
  scale: 57.2957795,
  color: cCyan,
);
const mTwd = MetricDef(
  'environment.wind.directionTrue',
  'TWD',
  'deg',
  scale: 57.2957795,
  color: cOrange,
);
const mSog = MetricDef(
  'navigation.speedOverGround',
  'SOG',
  'kn',
  scale: 1.94384,
  color: cGreen,
);
const mStw = MetricDef(
  'navigation.speedThroughWater',
  'STW',
  'kn',
  scale: 1.94384,
  color: cCyan,
);
const mHeading = MetricDef(
  'navigation.headingTrue',
  'Rumbo',
  '°',
  scale: 57.2957795,
  color: cText,
);
const mCog = MetricDef(
  'navigation.courseOverGroundTrue',
  'COG',
  '°',
  scale: 57.2957795,
  color: cPurple,
);

const defaultNavCardIds = ['sog', 'stw', 'heading', 'cog', 'depth', 'heel'];
const allNavCardIds = [
  'sog',
  'stw',
  'heading',
  'cog',
  'depth',
  'heel',
  'position',
  'gps',
  'ais',
  'time',
  'vmgWind',
  'vmgRoute',
  'appWind',
  'engineHours',
];

class NavCardData {
  const NavCardData({
    required this.id,
    required this.title,
    required this.value,
    required this.color,
    this.unit,
    this.subtitle,
    this.graphMetrics,
    this.trend,
    this.bigLines,
    this.aisName,
    this.aisCrossing,
  });

  final String id;
  final String title;
  final String value;
  final Color color;
  final String? unit;
  final String? subtitle;
  final List<MetricDef>? graphMetrics;
  final int? trend; // -1 down, 0 flat, 1 up — confirmed trend, not noise
  // When set, the card shows these as 2+ equal-size stacked lines instead
  // of the usual single giant `value` — for cards like AIS where CPA and
  // TCPA are equally important and neither should dominate the other.
  final List<String>? bigLines;
  // AIS only, used by the Premium card (the classic card ignores these):
  // kept separate from `subtitle` so a long vessel name truncates on its
  // own and never eats into the distance/bearing or crossing side text.
  final String? aisName;
  final String? aisCrossing; // 'POR PROA' | 'POR POPA' | null
}

// ─── Alarms ─────────────────────────────────────────────────────────────────
class SkZoneAlarmSetting {
  SkZoneAlarmSetting({this.enabled = true, this.sound = true});
  bool enabled;
  bool sound;

  Map<String, dynamic> toJson() => {'enabled': enabled, 'sound': sound};
  factory SkZoneAlarmSetting.fromJson(Map<String, dynamic> j) =>
      SkZoneAlarmSetting(
        enabled: j['enabled'] as bool? ?? true,
        sound: j['sound'] as bool? ?? true,
      );
}

// Custom (client-side) alarm types — evaluated against live SignalKModel
// values, independent of any Signal K server-side zone configuration.
const customAlarmTypes = [
  'depthBelow',
  'windAbove',
  'batteryVoltageBelow',
  'socBelow',
  'tempAbove',
  'tankBelow',
  'windForecastAbove',
];

String customAlarmTypeLabel(String type) => switch (type) {
  'depthBelow' => 'Profundidad menor de',
  'windAbove' => 'Viento (aparente) mayor de',
  'batteryVoltageBelow' => 'Batería menor de',
  'socBelow' => 'Batería (SOC) menor de',
  'tempAbove' => 'Temperatura mayor de',
  'tankBelow' => 'Algún tanque menor de',
  'windForecastAbove' => 'Viento previsto (6h) mayor de',
  _ => type,
};

String customAlarmTypeUnit(String type) => switch (type) {
  'depthBelow' => 'm',
  'windAbove' => 'kt',
  'batteryVoltageBelow' => 'V',
  'socBelow' => '%',
  'tempAbove' => '°C',
  'tankBelow' => '%',
  'windForecastAbove' => 'kt',
  _ => '',
};

// Signal K paths that 'tempAbove' deliberately never offers — exterior,
// interior and sea temperature already have their own display and aren't
// the kind of thing you'd want an audible alarm for.
const excludedTempAlarmPaths = {
  'environment.outside.temperature',
  'environment.interior.temperature',
  'environment.water.temperature',
};

// 'tempAbove' targets are real Signal K paths (e.g.
// "environment.fridge_1.temperature", "electrical.batteries.house.temperature")
// discovered live per boat, not a fixed list — this turns one into a
// readable label without needing any settings/discovery context, by
// pattern-matching the path text itself.
String tempAlarmTargetLabel(String path) {
  final p = path.toLowerCase();
  if (p == 'environment.rpi.cpu.temperature') return 'CPU (Raspberry Pi)';
  if (p.contains('bowthruster')) return 'Motor de proa';
  final battMatch = RegExp(r'^electrical\.batteries\.([^.]+)\.temperature$')
      .firstMatch(path);
  if (battMatch != null) return 'Batería (${battMatch.group(1)})';
  final fridgeNum = RegExp(r'fridge\D*(\d+)').firstMatch(p);
  if (fridgeNum != null) return 'Nevera ${fridgeNum.group(1)}';
  if (p.contains('fridge') || p.contains('nevera') || p.contains('freezer')) {
    return 'Nevera';
  }
  // Generic fallback: turn "environment.engine.temperature" into "Engine".
  final segs = path.split('.');
  final middle = segs.length > 2 ? segs.sublist(1, segs.length - 1) : segs;
  final words = middle.join(' ').replaceAll('_', ' ').split(' ');
  return words
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

class CustomAlarmRule {
  CustomAlarmRule({
    required this.id,
    required this.type,
    required this.threshold,
    this.target,
    this.enabled = true,
    this.sound = true,
  });
  final String id;
  String type;
  double threshold;
  String? target; // only meaningful for multi-sensor types like 'tempAbove'
  bool enabled;
  bool sound;

  String get label {
    final base =
        '${customAlarmTypeLabel(type)} $threshold ${customAlarmTypeUnit(type)}';
    return (type == 'tempAbove' && target != null)
        ? '${tempAlarmTargetLabel(target!)}: $base'
        : base;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'threshold': threshold,
    'target': target,
    'enabled': enabled,
    'sound': sound,
  };
  factory CustomAlarmRule.fromJson(Map<String, dynamic> j) {
    // Migrate the old fridge-only 'fridgeTempAbove' type (pre-1.4.13) to
    // 'tempAbove' + an explicit target, so an alarm saved before the
    // sensor picker existed doesn't show up as a broken raw type name.
    var type = j['type'] as String;
    var target = j['target'] as String?;
    if (type == 'fridgeTempAbove') {
      type = 'tempAbove';
      target ??= 'fridge1';
    }
    return CustomAlarmRule(
      id: j['id'] as String,
      type: type,
      threshold: (j['threshold'] as num).toDouble(),
      target: target,
      enabled: j['enabled'] as bool? ?? true,
      sound: j['sound'] as bool? ?? true,
    );
  }
}

// ─── Data models ──────────────────────────────────────────────────────────────
class SignalKModel {
  bool connected = false;
  String status = 'Sin conectar';
  DateTime? lastUpdate;
  // The vessel's own name, straight from Signal K (`vessels.self.name`) —
  // used anywhere the boat's name is shown (report headers, etc.) instead
  // of a hardcoded product name.
  String? vesselName;
  // Navigation/wind data must be recent to be trusted (unlike e.g. temperatures,
  // which change slowly and stay useful even a bit stale). Kept separate —
  // the wind instrument can die while GPS/compass keep updating, or vice versa,
  // so a single shared timestamp would mask a stale sensor as still-fresh.
  DateTime? navUpdate;
  DateTime? windUpdate;
  // Only set while a route/waypoint is active in Signal K — the server
  // simply stops emitting this path when there isn't one, so its own
  // staleness (vs. navUpdate) is what tells the VMG-to-waypoint card
  // "sin ruta" instead of showing a frozen old number.
  DateTime? courseUpdate;
  // Navigation
  double? latitude;
  double? longitude;
  double? sogKn;
  double? stwKn;
  double? headingTrueDeg;
  double? headingMagneticDeg;
  double? cogTrueDeg;
  // Each of these four also gets its own timestamp — navUpdate above is
  // shared by every navigation.* path, so a compass that dies while GPS
  // keeps emitting SOG/position deltas kept navUpdate ticking over and
  // heading read as "fresh" forever (the exact bug reported: heading
  // frozen at a real value since a specific time, never falling back to
  // COG because the shared timestamp masked it). These four feed that
  // fallback logic directly, so they need real per-field staleness.
  DateTime? sogKnUpdate;
  DateTime? stwKnUpdate;
  DateTime? headingTrueDegUpdate;
  DateTime? headingMagneticDegUpdate;
  DateTime? cogTrueDegUpdate;
  double? heelDeg;
  double? pitchDeg;
  // GNSS/GPS quality — separate from the position update timestamp above,
  // since these change far less often than lat/lon and shouldn't be marked
  // stale just because the receiver hasn't emitted a new fix-quality delta.
  int? gnssSatellites;
  double? gnssHdop;
  double? gnssAntennaAltitudeM;
  String? gnssFixType; // Signal K navigation.gnss.type, e.g. "GPS", "GNSS"
  String? gnssMethodQuality; // e.g. "no GPS", "GNSS Fix", "DGNSS Fix", "RTK fixed integer"
  // VMG to the active route/waypoint, straight from Signal K's own course
  // calculation (whatever plugin/core feature is computing the route) —
  // we don't derive this ourselves, unlike VMG-to-wind below.
  double? courseVmgKn;
  // Environment
  double? depthM;
  // Dedicated, not the shared navUpdate — depth arrives through a
  // dynamic handler (_buildDynamicHandlers), which _routeValue dispatches
  // to and returns from BEFORE ever reaching the code that used to try to
  // stamp navUpdate for it, so that never actually ran. Without its own
  // timestamp, depth's "fresh" status silently depended on whatever OTHER
  // navigation.* path happened to be updating nearby — reading as fresh
  // forever if GPS/SOG kept flowing even after a real depth-sounder
  // dropout, or as stale even with a perfectly live depth feed if nothing
  // else on navUpdate happened to be moving. Reported live 2026-09-04.
  DateTime? depthMUpdate;
  double? waterTempK;
  double? outsideTempK;
  double? outsideHumidity; // 0-100 %
  double? outsidePressureHpa;
  double? indoorTempK;
  double? indoorHumidity; // 0-100 %
  double? cpuTempK;
  double? gpuTempK;
  double? cpuUtil; // 0-100 %
  double? memUtil; // 0-100 %
  double? sdUtil; // 0-100 %
  double? sonoffTempK;
  double? solarFusesTempK;
  double? fridge1TempK;
  double? fridge2TempK;
  // Wind
  double? awsKn;
  double? awaDeg;
  double? twaDeg;
  double? twsKn;
  double? twdDeg;
  // Power
  double? houseV;
  double? houseA;
  double? houseW;
  double? houseSoc; // 0-100 %
  double? houseTempK;
  double? solarW;
  double? solarW2;
  double? dcW;
  double? startV;
  double? bowthrusterV;
  double? engineHours; // hours, from propulsion.<id>.runTime (seconds)
  // Real engine telemetry — siblings of enginePath under the same
  // propulsion.<id> base (see _buildDynamicHandlers), auto-registered
  // once the user picks the engine's runTime path in CFG > Sensores, no
  // separate configuration needed for each.
  double? engineRpm; // revolutions (Hz) × 60
  // Percent load, same PGN 61444 (EEC1) frame as RPM — SPN 512. Purely
  // informational (no alarm derived from it), shown only in the
  // "Completo" Motor panel.
  double? engineTorquePercent;
  double? engineCoolantTempK;
  double? engineOilPressurePa;
  double? engineAlternatorV;
  // Per-metric "last delta received" timestamps — each gauge goes stale
  // (needle to zero, "--" on its readout) independently 5s after its own
  // last update, same principle as navUpdate/windUpdate above: one sensor
  // dying shouldn't hide behind another still reporting. torquePercent
  // shares engineRpmUpdate — same PGN 61444 frame as RPM.
  DateTime? engineRpmUpdate;
  DateTime? engineCoolantTempUpdate;
  DateTime? engineOilPressureUpdate;
  DateTime? engineAlternatorVUpdate;
  // Discrete DM1 fault bits (J1939 PGN 65226 — SPN 110/FMI 0, 100/FMI 1,
  // 167/FMI 1), if the bridge firmware ever decodes them; null while
  // unpublished, in which case the threshold comparison is used instead.
  bool? engineOverTempAlarm;
  bool? engineLowOilAlarm;
  bool? engineLowVoltAlarm;
  // "Last delta received" for the 3 flags above — a fault bit has no
  // natural "cleared" value the way a number reverting to normal does, so
  // without its own staleness a bridge that stops publishing (engine off,
  // bus/bridge disconnected) left whatever it last said sitting there
  // forever, including a real fault that's actually gone stale, not gone.
  DateTime? engineOverTempAlarmUpdate;
  DateTime? engineLowOilAlarmUpdate;
  DateTime? engineLowVoltAlarmUpdate;
  // Glow-plug/starter-relay circuit fault (PGN 65226 DM1 — SPN 677 or 724,
  // FMI 5: open circuit/current below normal). No numeric equivalent
  // exists, so unlike the 3 above there's no threshold fallback — stays
  // off until the bridge actually publishes a fault.
  bool? engineGlowPlugFaultAlarm;
  DateTime? engineGlowPlugFaultAlarmUpdate;
  // Preheat-in-progress status (PGN 65264 — SPN 1494, Glow Plug Relay
  // Status). Not an alarm, just the normal "still warming the glow plugs"
  // state — drives the 'precal' lamp in real (non-SIMUL) mode.
  bool? enginePreheatActive;
  // Bridge diagnostics (propulsion.<id>.volvoMdi.*) — PGN frames seen on
  // the bus but not decoded, shown in the "Completo" Motor panel.
  double? engineUnknownPgn;
  double? engineUnknownFrameCount;
  double? bowthrusterTempK;
  // Tanks (key = "type.id", e.g. "freshWater.24")
  final tanks = <String, double?>{};

  // Anchor watch (hoekens-anchor-alarm plugin) — armed state and live
  // geometry for the native Premium "Fondeado" anchor card, as opposed to
  // embedding the plugin's own webapp.
  String? anchorState; // navigation.anchor.state: "on" | "off"
  double? anchorCurrentRadiusM;
  double? anchorMaxRadiusM;
  double? anchorApparentBearingDeg; // relative to the bow, not true north
  bool get anchorArmed => anchorState == 'on';

  // Wipes every live-data field back to "unknown" — called at the start of
  // each (re)connect (see _DashboardState._connectSignalK) so switching to
  // a different Signal K server, or even just reconnecting to the same
  // one, can never show a value that's actually left over from whatever
  // was connected before. Previously only `tanks` was cleared here, which
  // is how a stale STW/depth reading from a *previous* server could keep
  // showing forever on a new server that doesn't even publish those paths
  // — nothing was left to overwrite it with "--". Deliberately leaves
  // `connected`/`status` alone (the connection state machine owns those).
  void reset() {
    vesselName = null;
    navUpdate = null;
    windUpdate = null;
    courseUpdate = null;
    sogKnUpdate = null;
    stwKnUpdate = null;
    headingTrueDegUpdate = null;
    headingMagneticDegUpdate = null;
    cogTrueDegUpdate = null;
    latitude = null;
    longitude = null;
    sogKn = null;
    stwKn = null;
    headingTrueDeg = null;
    headingMagneticDeg = null;
    cogTrueDeg = null;
    heelDeg = null;
    pitchDeg = null;
    gnssSatellites = null;
    gnssHdop = null;
    gnssAntennaAltitudeM = null;
    gnssFixType = null;
    gnssMethodQuality = null;
    courseVmgKn = null;
    depthM = null;
    depthMUpdate = null;
    waterTempK = null;
    outsideTempK = null;
    outsideHumidity = null;
    outsidePressureHpa = null;
    indoorTempK = null;
    indoorHumidity = null;
    cpuTempK = null;
    gpuTempK = null;
    cpuUtil = null;
    memUtil = null;
    sdUtil = null;
    sonoffTempK = null;
    solarFusesTempK = null;
    fridge1TempK = null;
    fridge2TempK = null;
    awsKn = null;
    awaDeg = null;
    twaDeg = null;
    twsKn = null;
    twdDeg = null;
    houseV = null;
    houseA = null;
    houseW = null;
    houseSoc = null;
    houseTempK = null;
    solarW = null;
    solarW2 = null;
    dcW = null;
    startV = null;
    bowthrusterV = null;
    engineHours = null;
    engineRpm = null;
    engineTorquePercent = null;
    engineCoolantTempK = null;
    engineOilPressurePa = null;
    engineAlternatorV = null;
    engineRpmUpdate = null;
    engineCoolantTempUpdate = null;
    engineOilPressureUpdate = null;
    engineAlternatorVUpdate = null;
    engineOverTempAlarm = null;
    engineLowOilAlarm = null;
    engineLowVoltAlarm = null;
    engineOverTempAlarmUpdate = null;
    engineLowOilAlarmUpdate = null;
    engineLowVoltAlarmUpdate = null;
    engineGlowPlugFaultAlarm = null;
    engineGlowPlugFaultAlarmUpdate = null;
    enginePreheatActive = null;
    engineUnknownPgn = null;
    engineUnknownFrameCount = null;
    bowthrusterTempK = null;
    tanks.clear();
    anchorState = null;
    anchorCurrentRadiusM = null;
    anchorMaxRadiusM = null;
    anchorApparentBearingDeg = null;
  }
}

// ─── Per-boat sensor configuration (paths vary boat to boat) ─────────────────
class TankSlot {
  TankSlot({
    required this.type,
    required this.id,
    required this.groupLabel,
    required this.capacityL,
    this.enabled = true,
  });
  String type; // 'freshWater' | 'fuel' | 'blackWater' | ...
  String id; // Signal K instance id
  String groupLabel; // tanks sharing the same label are averaged into one card
  int capacityL;
  bool enabled;
  String get skPath => 'tanks.$type.$id.currentLevel';
  String get tankKey => '$type.$id';

  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'groupLabel': groupLabel,
    'capacityL': capacityL,
    'enabled': enabled,
  };
  factory TankSlot.fromJson(Map<String, dynamic> j) => TankSlot(
    type: j['type'] as String,
    id: j['id'] as String,
    groupLabel: j['groupLabel'] as String,
    capacityL: j['capacityL'] as int,
    enabled: j['enabled'] as bool? ?? true,
  );
}

class SensorConfig {
  // Plain SensorConfig() defaults to THIS boat's actual known-good sensor
  // ids/paths — appropriate the first time the app ever runs, but very
  // wrong to silently reuse when switching to a DIFFERENT, unconfigured
  // Signal K server (CFG → Admin) — that would show REWIND's tank/battery
  // ids as if they were real readings on someone else's boat. This gives a
  // genuinely blank starting point instead, so an unconfigured server just
  // shows "no data" until someone runs "Configurar sensores" for it.
  factory SensorConfig.empty() => SensorConfig()
    ..batteryHouseId = ''
    ..batteryStartId = ''
    ..solarPath = null
    ..solarPath2 = null
    ..fridge1Path = null
    ..fridge2Path = null
    ..depthPath = null
    ..enginePath = null
    ..tanks = [];

  SensorConfig();

  String batteryHouseId = '278';
  String batteryStartId = '278-second';
  String? solarPath = 'electrical.venus.totalPanelPower';
  // Optional second solar controller — when set, the PWR card shows both
  // panels' individual output plus the sum as "total"; with just the one
  // (solarPath2 null, the common case) that single value already reads as
  // the total, unchanged from before.
  String? solarPath2;
  String? fridge1Path = 'environment.fridge_1.temperature';
  String? fridge2Path = 'environment.fridge_2.temperature';
  String? depthPath = 'environment.depth.belowKeel';
  // Signal K's standard cumulative engine run time, e.g.
  // "propulsion.main.runTime" — seconds since the engine's counter started.
  String? enginePath;
  bool hasOutsideTemp = true;
  bool hasOutsidePressure = true;
  List<TankSlot> tanks = [
    TankSlot(type: 'fuel', id: '27', groupLabel: 'Fuel 1', capacityL: 180),
    TankSlot(type: 'fuel', id: '26', groupLabel: 'Fuel 2', capacityL: 180),
    TankSlot(
      type: 'freshWater',
      id: '24',
      groupLabel: 'Agua Stbd',
      capacityL: 276,
    ),
    TankSlot(
      type: 'freshWater',
      id: '25',
      groupLabel: 'Agua Port',
      capacityL: 195,
    ),
    TankSlot(
      type: 'blackWater',
      id: '30',
      groupLabel: 'Black water 1',
      capacityL: 80,
    ),
    TankSlot(
      type: 'blackWater',
      id: '31',
      groupLabel: 'Black water 2',
      capacityL: 80,
    ),
  ];

  Map<String, dynamic> toJson() => {
    'batteryHouseId': batteryHouseId,
    'batteryStartId': batteryStartId,
    'solarPath': solarPath,
    'solarPath2': solarPath2,
    'fridge1Path': fridge1Path,
    'fridge2Path': fridge2Path,
    'depthPath': depthPath,
    'enginePath': enginePath,
    'hasOutsideTemp': hasOutsideTemp,
    'hasOutsidePressure': hasOutsidePressure,
    'tanks': [for (final t in tanks) t.toJson()],
  };

  static SensorConfig fromJson(Map<String, dynamic> j) {
    final c = SensorConfig();
    c.batteryHouseId = j['batteryHouseId'] as String? ?? c.batteryHouseId;
    c.batteryStartId = j['batteryStartId'] as String? ?? c.batteryStartId;
    c.solarPath = j['solarPath'] as String?;
    c.solarPath2 = j['solarPath2'] as String?;
    c.fridge1Path = j['fridge1Path'] as String?;
    c.fridge2Path = j['fridge2Path'] as String?;
    c.depthPath = j['depthPath'] as String?;
    c.enginePath = j['enginePath'] as String?;
    c.hasOutsideTemp = j['hasOutsideTemp'] as bool? ?? true;
    c.hasOutsidePressure = j['hasOutsidePressure'] as bool? ?? true;
    final rawTanks = j['tanks'];
    if (rawTanks is List) {
      c.tanks = [
        for (final t in rawTanks) TankSlot.fromJson(t as Map<String, dynamic>),
      ];
    }
    return c;
  }
}

// ─── Native anchor watch (ANC) — replaces the embedded hoekens-anchor-alarm
// webview entirely. State lives here instead of on the Signal K server (the
// plugin's `zone`/`on` config), so the watch works even if that plugin is
// gone or misconfigured — no PUT to Signal K, no dependency on it at all.
class AnchorConfig {
  bool armed = false;
  double? dropLat;
  double? dropLon;
  DateTime? droppedAt;
  // Depth at the moment of dropping — the reference point for the depth
  // "swing" alarm (settings.alarmAnchorDepthEnabled), not an absolute
  // threshold.
  double? dropDepthM;
  double radiusM = 30;
  // The radius set on drop (or last manually confirmed via the "Radio"
  // handle) — radiusM itself may grow past this automatically to keep the
  // watch circle around the boat, and shrinks back to this baseline once
  // the boat is close enough to the anchor again to fit inside it.
  double? initialRadiusM;
  // Set on arm and on every confirmed anchor-position change — the drag
  // alarm ignores "outside the zone" for a short grace window afterward,
  // so repositioning the anchor (or the sector) outside where the boat
  // currently sits doesn't immediately alarm on the edit itself.
  DateTime? armedOrMovedAt;
  String shape = 'circle'; // 'circle' or 'sector'
  double? sectorStartDeg; // only meaningful when shape == 'sector'
  double? sectorEndDeg;
  // Layer toggles — mirrors the show/hide checkboxes the hoekens plugin
  // offered, so switching to the native screen isn't a step down.
  bool showWind = true;
  bool showDepth = true;
  // Off by default — a minority-interest panel, not something everyone
  // wants cluttering the screen on every anchor drop.
  bool showScope = false;
  bool showAisNearby = true;
  bool showOwnTrack = true;
  // Independent checkboxes, not exclusive — satellite + OpenSeaMap
  // together is a legitimate hybrid (imagery with nautical marks on top),
  // and both off just means a plain background, not an invalid state.
  bool showSatelliteLayer = true;
  bool showSeamarkLayer = false;
  List<int> scopeRatios = [7, 5, 4, 3];
  // Past anchorages (drop → raise), most recent last — mirrors the
  // hoekens plugin's own history view. Capped in _raiseAnchor's append so
  // this doesn't grow unbounded across a season.
  List<AnchorHistoryEntry> history = [];

  Map<String, dynamic> toJson() => {
    'armed': armed,
    'dropLat': dropLat,
    'dropLon': dropLon,
    'dropDepthM': dropDepthM,
    'droppedAt': droppedAt?.toIso8601String(),
    'radiusM': radiusM,
    'initialRadiusM': initialRadiusM,
    'armedOrMovedAt': armedOrMovedAt?.toIso8601String(),
    'shape': shape,
    'sectorStartDeg': sectorStartDeg,
    'sectorEndDeg': sectorEndDeg,
    'showWind': showWind,
    'showDepth': showDepth,
    'showScope': showScope,
    'showAisNearby': showAisNearby,
    'showOwnTrack': showOwnTrack,
    'showSatelliteLayer': showSatelliteLayer,
    'showSeamarkLayer': showSeamarkLayer,
    'scopeRatios': scopeRatios,
    'history': history.map((e) => e.toJson()).toList(),
  };

  static AnchorConfig fromJson(Map<String, dynamic> j) {
    final c = AnchorConfig();
    c.armed = j['armed'] as bool? ?? false;
    c.dropLat = (j['dropLat'] as num?)?.toDouble();
    c.dropLon = (j['dropLon'] as num?)?.toDouble();
    c.dropDepthM = (j['dropDepthM'] as num?)?.toDouble();
    final droppedAtStr = j['droppedAt'] as String?;
    c.droppedAt = droppedAtStr == null ? null : DateTime.tryParse(droppedAtStr);
    c.radiusM = (j['radiusM'] as num?)?.toDouble() ?? c.radiusM;
    c.initialRadiusM = (j['initialRadiusM'] as num?)?.toDouble();
    final armedOrMovedAtStr = j['armedOrMovedAt'] as String?;
    c.armedOrMovedAt = armedOrMovedAtStr == null
        ? null
        : DateTime.tryParse(armedOrMovedAtStr);
    c.shape = j['shape'] as String? ?? c.shape;
    c.sectorStartDeg = (j['sectorStartDeg'] as num?)?.toDouble();
    c.sectorEndDeg = (j['sectorEndDeg'] as num?)?.toDouble();
    c.showWind = j['showWind'] as bool? ?? true;
    c.showDepth = j['showDepth'] as bool? ?? true;
    c.showScope = j['showScope'] as bool? ?? false;
    c.showAisNearby = j['showAisNearby'] as bool? ?? true;
    c.showOwnTrack = j['showOwnTrack'] as bool? ?? true;
    // Migrates the old exclusive 'baseLayer' string (satellite/seamark/
    // none) if present, otherwise reads the new independent checkboxes.
    final legacyBaseLayer = j['baseLayer'] as String?;
    if (legacyBaseLayer != null) {
      c.showSatelliteLayer = legacyBaseLayer == 'satellite';
      c.showSeamarkLayer = legacyBaseLayer == 'seamark';
    } else {
      c.showSatelliteLayer = j['showSatelliteLayer'] as bool? ?? true;
      c.showSeamarkLayer = j['showSeamarkLayer'] as bool? ?? false;
    }
    final rawRatios = j['scopeRatios'];
    if (rawRatios is List) {
      c.scopeRatios = rawRatios.map((e) => (e as num).toInt()).toList();
    }
    final rawHistory = j['history'];
    if (rawHistory is List) {
      c.history = rawHistory
          .whereType<Map>()
          .map((e) => AnchorHistoryEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return c;
  }
}

// One completed anchorage: drop → raise.
class AnchorHistoryEntry {
  AnchorHistoryEntry({
    required this.droppedAt,
    required this.raisedAt,
    required this.lat,
    required this.lon,
    required this.radiusM,
    this.depthM,
  });
  final DateTime droppedAt;
  final DateTime raisedAt;
  final double lat;
  final double lon;
  final double radiusM;
  final double? depthM;

  Map<String, dynamic> toJson() => {
    'droppedAt': droppedAt.toIso8601String(),
    'raisedAt': raisedAt.toIso8601String(),
    'lat': lat,
    'lon': lon,
    'radiusM': radiusM,
    'depthM': depthM,
  };

  static AnchorHistoryEntry fromJson(Map<String, dynamic> j) =>
      AnchorHistoryEntry(
        droppedAt:
            DateTime.tryParse(j['droppedAt'] as String? ?? '') ??
            DateTime.now(),
        raisedAt:
            DateTime.tryParse(j['raisedAt'] as String? ?? '') ??
            DateTime.now(),
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        radiusM: (j['radiusM'] as num).toDouble(),
        depthM: (j['depthM'] as num?)?.toDouble(),
      );
}

// ─── Signal K path discovery (used by CFG > Sensores) ────────────────────────
class TankCandidate {
  TankCandidate({
    required this.type,
    required this.id,
    this.capacityL,
    this.name,
  });
  final String type;
  final String id;
  final int? capacityL;
  // Signal K's own tanks.<type>.<id>.name, when published — "el nombre de
  // los tanques tienes que cogerlo de signalk con el sufijo .name"
  // (reported live 2026-09-04). Null when the device never publishes one.
  final String? name;
}

class SkDiscovery {
  final List<String> batteryIds = [];
  // id -> Signal K's own electrical.batteries.<id>.name, when the device
  // publishes one (lowercased) — used to guess house vs. start battery on
  // "Buscar sensores" instead of leaving both blank. See
  // _SensorConfigDialog._discoverNow's _guessBatteryRole.
  final Map<String, String> batteryNames = {};
  final List<String> solarPaths = [];
  // Subset of solarPaths that are an actual per-controller TOTAL (e.g.
  // electrical.solar.0.panelPower, electrical.venus.totalPanelPower) as
  // opposed to one individual panel's own reading (e.g.
  // electrical.solar.0.1.panelPower, one extra segment) — only these are
  // valid solarPath/solarPath2 candidates, since picking an individual
  // panel's path would silently report just that one panel's output
  // instead of the controller's real total. "analiza primero el numero de
  // paneles... electrical.solar.?.?.panelpower para los individuales y
  // electrical.solar.?.panelpower para el total" (reported live
  // 2026-09-04).
  final List<String> solarTotalPaths = [];
  final List<String> fridgePaths = [];
  final List<String> depthPaths = [];
  final List<String> enginePaths = [];
  final List<TankCandidate> tanks = [];
  final List<String> allPaths = [];
  bool hasOutsideTemp = false;
  bool hasOutsidePressure = false;
}

class ForecastPoint {
  ForecastPoint({
    required this.time,
    this.tempC,
    this.rainPct,
    this.windKn,
    this.gustKn,
    this.windDirDeg,
    this.weatherCode,
  });
  final DateTime time;
  final double? tempC, rainPct, windKn, gustKn, windDirDeg;
  final int? weatherCode;

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    'temp': tempC,
    'rain': rainPct,
    'wind': windKn,
    'gust': gustKn,
    'dir': windDirDeg,
    'code': weatherCode,
  };
  static ForecastPoint fromJson(Map<String, dynamic> j) => ForecastPoint(
    time: DateTime.parse(j['t'] as String),
    tempC: (j['temp'] as num?)?.toDouble(),
    rainPct: (j['rain'] as num?)?.toDouble(),
    windKn: (j['wind'] as num?)?.toDouble(),
    gustKn: (j['gust'] as num?)?.toDouble(),
    windDirDeg: (j['dir'] as num?)?.toDouble(),
    weatherCode: (j['code'] as num?)?.toInt(),
  );
}

class MarinePoint {
  MarinePoint({
    required this.time,
    this.waveM,
    this.waveDir,
    this.wavePeriod,
    this.swellM,
    this.swellDir,
    this.swellPeriod,
    this.seaTempC,
    this.currentKmh,
    this.currentDir,
  });
  final DateTime time;
  final double? waveM,
      waveDir,
      wavePeriod,
      swellM,
      swellDir,
      swellPeriod,
      seaTempC,
      currentKmh,
      currentDir;

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    'wave': waveM,
    'waveDir': waveDir,
    'wavePeriod': wavePeriod,
    'swell': swellM,
    'swellDir': swellDir,
    'swellPeriod': swellPeriod,
    'seaTemp': seaTempC,
    'current': currentKmh,
    'currentDir': currentDir,
  };
  static MarinePoint fromJson(Map<String, dynamic> j) => MarinePoint(
    time: DateTime.parse(j['t'] as String),
    waveM: (j['wave'] as num?)?.toDouble(),
    waveDir: (j['waveDir'] as num?)?.toDouble(),
    wavePeriod: (j['wavePeriod'] as num?)?.toDouble(),
    swellM: (j['swell'] as num?)?.toDouble(),
    swellDir: (j['swellDir'] as num?)?.toDouble(),
    swellPeriod: (j['swellPeriod'] as num?)?.toDouble(),
    seaTempC: (j['seaTemp'] as num?)?.toDouble(),
    currentKmh: (j['current'] as num?)?.toDouble(),
    currentDir: (j['currentDir'] as num?)?.toDouble(),
  );
}

// ─── Weather model comparison (PRON > Comparar modelos) ──────────────────────
class ModelSeries {
  const ModelSeries({
    required this.id,
    required this.label,
    required this.color,
  });
  final String id;
  final String label;
  final Color color;
}

// Free Open-Meteo models, no API key. Unknown/unsupported ids for a given
// location just come back empty and are skipped, so it's safe to list several.
const weatherModels = [
  ModelSeries(id: 'gfs_seamless', label: 'GFS', color: cCyan),
  ModelSeries(id: 'ecmwf_ifs025', label: 'ECMWF', color: cOrange),
  ModelSeries(id: 'icon_eu', label: 'ICON-EU', color: cGreen),
  ModelSeries(id: 'arpege_europe', label: 'ARPEGE', color: cPurple),
  ModelSeries(id: 'gem_seamless', label: 'GEM', color: cYellow),
];

// ─── AIS targets (MAP > swipe down) ───────────────────────────────────────────
class AisTarget {
  AisTarget(this.context);
  final String context; // e.g. 'vessels.urn:mrn:imo:mmsi:123456789'
  String? mmsi;
  String? name;
  double? lat, lon;
  double? cogDeg;
  double? sogKn;
  int? shipTypeId; // AIS ship type code, e.g. 70 = cargo, 80 = tanker
  DateTime? lastUpdate;
  // Provided by a Signal K collision-alert plugin (navigation.closestApproach.*),
  // if installed — preferred over our own client-side CPA geometry when
  // present AND recent (see pluginCpaUpdate). NOT gated by the target's
  // own shared `lastUpdate` above — that refreshes on ANY field (name,
  // position, mmsi, ...), so if the collision plugin itself stopped
  // publishing while ordinary AIS reception for this target kept going,
  // lastUpdate stayed fresh while these three quietly froze at a stale
  // prediction that would otherwise keep winning over a fresh local
  // calculation forever. Reported live 2026-09-04.
  double? pluginCpaNm;
  double? pluginTcpaMin;
  double? pluginCpaBearingDeg;
  DateTime? pluginCpaUpdate;
  // Rolling 1h position history for the optional on-screen track.
  final List<({DateTime t, double lat, double lon})> track = [];
  void recordTrackPoint() {
    final la = lat, lo = lon;
    if (la == null || lo == null) return;
    final now = DateTime.now();
    if (track.isNotEmpty &&
        now.difference(track.last.t) < const Duration(seconds: 15)) {
      return;
    }
    track.add((t: now, lat: la, lon: lo));
    track.removeWhere((p) => now.difference(p.t) > const Duration(hours: 1));
  }
}

// Own-boat position trail for the native anchor watch — same shape/rules as
// AisTarget.track above (min spacing, rolling window), just not tied to a
// specific AIS target since it's our own position.
class AnchorTrackPoint {
  const AnchorTrackPoint(this.t, this.lat, this.lon);
  final DateTime t;
  final double lat;
  final double lon;
}

class OwnTrackHistory {
  final List<AnchorTrackPoint> points = [];
  void add(double? lat, double? lon) {
    if (lat == null || lon == null) return;
    final now = DateTime.now();
    if (points.isNotEmpty &&
        now.difference(points.last.t) < const Duration(seconds: 15)) {
      return;
    }
    points.add(AnchorTrackPoint(now, lat, lon));
    points.removeWhere((p) => now.difference(p.t) > const Duration(hours: 24));
  }

  void clear() => points.clear();

  // Backfills from Signal K's own history API on app start, so a fresh
  // launch doesn't show an empty trail until enough live points accumulate
  // — unlike add(), timestamps here are the recorded ones, not "now", so
  // the same 15s-spacing/24h-window rules are re-applied explicitly rather
  // than relying on add()'s live-clock-relative checks.
  //
  // The history fetch is a several-second round trip, so by the time it
  // resolves live points have almost always already started arriving via
  // add() — bailing out whenever points was non-empty (the original
  // approach) meant this never actually ran in practice. Instead, only
  // backfill points OLDER than whatever's already there, prepending them —
  // live data always wins for anything it already covers.
  void seedFromHistory(List<AnchorTrackPoint> historical) {
    final now = DateTime.now();
    final cutoff = points.isEmpty ? now : points.first.t;
    final sorted = [...historical]..sort((a, b) => a.t.compareTo(b.t));
    final backfill = <AnchorTrackPoint>[];
    AnchorTrackPoint? last;
    for (final p in sorted) {
      if (now.difference(p.t) > const Duration(hours: 24)) continue;
      if (!p.t.isBefore(cutoff)) continue;
      if (last != null && p.t.difference(last.t) < const Duration(seconds: 15)) {
        continue;
      }
      backfill.add(p);
      last = p;
    }
    points.insertAll(0, backfill);
  }
}

// Minimum points (since the current drop — see ANC's "Recolocar" use)
// before a fit is even attempted.
const kAnchorRefitMinPoints = 8;

// Finds the anchor's true position from the boat's own swing track, given
// a KNOWN (not fitted) chain-taut radius — config.radiusM, the anchor
// watch's own configured radius, which the user already set (often from
// the 7:1 scope rule _dropAnchor itself uses). The boat, tethered to the
// anchor, traces an arc centered on the anchor's TRUE position when the
// chain is taut; that center can be a more accurate estimate than the
// originally recorded drop fix (GPS settling at the moment of dropping, a
// position taken at the bow rather than the anchor itself, etc). Used by
// ANC's "Recolocar ancla" button. Reported live 2026-09-04 ("cuando ha
// pasado tiempo y hay trazas se forma un sector de circulo que
// permitiria... recolocar automaticamente el ancla").
//
// An EARLIER version of this fit solved for center AND radius together
// (3 unknowns) via Kasa's least-squares method — that needed a wide
// (60°+) swing to be well-conditioned; a narrower arc could produce a
// "confident"-looking fit 15m+ off from the truth. Fixing the radius
// (an external follow-up suggestion, evaluated and agreed with 2026-09-04)
// reduces this to 2 unknowns (just the center), which is dramatically
// better conditioned — verified empirically down to a 10° swing giving
// ~4-8m error (close to GPS's own ~2.5m noise floor) as long as the known
// radius is reasonably accurate.
//
// Method: gradient descent minimizing Σ max(0, distance_i − R)² — points
// already within R cost nothing (interior points, chain slack in light
// wind/tide, are correctly ignored rather than corrupting the fit), points
// beyond R pull the center toward them until their distance approaches R
// (only the perimeter, taut-chain points actually pin down where the
// anchor is). This is a fixed-radius "shrink-wrap" fit, not a classic
// circle regression.
//
// refLat/refLon should be the CURRENTLY recorded anchor position (config.
// dropLat/dropLon) — the local-projection origin and the starting point
// for the descent, not otherwise part of the math.
({double lat, double lon})? fitAnchorCenterKnownRadius(
  List<AnchorTrackPoint> points, {
  required double radiusM,
  required double refLat,
  required double refLon,
}) {
  if (points.length < kAnchorRefitMinPoints || radiusM <= 0) return null;
  final cosRef = math.cos(refLat * math.pi / 180);
  final n = points.length;
  final xs = [for (final p in points) (p.lon - refLon) * cosRef * 111320];
  final ys = [for (final p in points) (p.lat - refLat) * 110540];
  var cx = 0.0, cy = 0.0;
  const learningRate = 0.5;
  const iterations = 500;
  for (var iter = 0; iter < iterations; iter++) {
    var gx = 0.0, gy = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = cx - xs[i], dy = cy - ys[i];
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > radiusM && d > 1e-9) {
        final coeff = 2 * (d - radiusM) / d;
        gx += coeff * dx;
        gy += coeff * dy;
      }
    }
    cx -= learningRate * gx / n;
    cy -= learningRate * gy / n;
  }
  // Require several points actually near the fitted radius, not just
  // one — a real taut-chain swing leaves a CLUSTER of points out there;
  // a single stray GPS glitch reaching R shouldn't alone be trusted to
  // drag the center (verified empirically: one such outlier could pull
  // the result 10m+ without this). Also correctly rejects an all-calm
  // anchorage (chain never went taut this whole session) instead of
  // silently "succeeding" at zero actual movement.
  final nearRadiusCount = [
    for (var i = 0; i < n; i++)
      math.sqrt((cx - xs[i]) * (cx - xs[i]) + (cy - ys[i]) * (cy - ys[i])),
  ].where((d) => d >= radiusM * 0.7 && d <= radiusM * 1.3).length;
  if (nearRadiusCount < 3) return null;
  return (lat: refLat + cy / 110540, lon: refLon + cx / (cosRef * 111320));
}

// ─── Guiñada (yaw-at-anchor analysis) ─────────────────────────────────────────
// "analizar analíticamente cómo 'navega' el barco sobre el ancla... en lugar
// de limitarse a mostrar solo el círculo de borneo estático" (reported live
// 2026-09-04) — a new ANC sub-screen. Purely single-boat, no cross-vessel
// data sharing and no chain-scope event log (both explicitly descoped by the
// user: comparing boats happens by talking over the radio, not in-app; the
// effect of paying out more/less chain is judged by eye, re-opening this
// screen before/after, not by an automatic before/after annotation).

// One sample for yaw analysis — like AnchorTrackPoint but also carries
// heading/COG/SOG at that instant, needed for the yaw/leeway math below.
class AnchorYawPoint {
  const AnchorYawPoint({
    required this.t,
    required this.lat,
    required this.lon,
    this.headingDeg,
    this.cogDeg,
    this.sogKn,
  });
  final DateTime t;
  final double lat;
  final double lon;
  final double? headingDeg;
  final double? cogDeg;
  final double? sogKn;
}

// Live, in-memory rolling buffer for Guiñada's "Última hora" (high-
// resolution) mode — NOT persisted across app restarts/reconnects, unlike
// OwnTrackHistory: the point of this window is "what is the boat doing
// right now", so starting empty after a restart is correct, not a gap to
// backfill. Sampled far more often than OwnTrackHistory's 15s (oscillation
// itself can complete a full cycle in well under a minute), but only kept
// for 2h — comfortably past the 1h the UI actually offers, with margin.
class YawTrackHistory {
  final List<AnchorYawPoint> points = [];
  void add({
    required double? lat,
    required double? lon,
    double? headingDeg,
    double? cogDeg,
    double? sogKn,
  }) {
    if (lat == null || lon == null) return;
    final now = DateTime.now();
    if (points.isNotEmpty &&
        now.difference(points.last.t) < const Duration(seconds: 3)) {
      return;
    }
    points.add(
      AnchorYawPoint(
        t: now,
        lat: lat,
        lon: lon,
        headingDeg: headingDeg,
        cogDeg: cogDeg,
        sogKn: sogKn,
      ),
    );
    points.removeWhere((p) => now.difference(p.t) > const Duration(hours: 2));
  }

  void clear() => points.clear();
}

// Δψ: how far the bow is pointing away from directly away-from-the-anchor
// (i.e. away from the reciprocal of the rode) — 0° means lying calmly
// head-to-rode, ±90° means lying broadside to it. Signed, -180..180.
double? yawMisalignmentDeg({
  required double anchorLat,
  required double anchorLon,
  required double boatLat,
  required double boatLon,
  required double headingDeg,
}) {
  final expected = bearingDistanceMeters(
    anchorLat,
    anchorLon,
    boatLat,
    boatLon,
  ).bearingDeg;
  return normalizeRelativeAngle(headingDeg - expected);
}

// Leeway/abatimiento: how far the boat's actual movement (COG) diverges
// from where the bow points (heading) — near 0 lying still or moving
// straight ahead, larger when sliding sideways (typical mid-swing, chain
// still slack). Signed, -180..180.
double? leewayDeg({required double cogDeg, required double headingDeg}) =>
    normalizeRelativeAngle(cogDeg - headingDeg);

class YawAnalysisResult {
  const YawAnalysisResult({
    required this.samples,
    required this.yawSeries,
    required this.yawAmplitudeDeg,
    required this.oscillationPeriod,
    required this.sweptAreaM2,
  });
  // (time, Δψ) — the plotted series.
  final List<({DateTime t, double yawDeg})> yawSeries;
  final int samples;
  final double? yawAmplitudeDeg;
  final Duration? oscillationPeriod;
  final double? sweptAreaM2;
}

// Odd-length centered moving average — enough to take the worst of raw GPS/
// compass jitter off the yaw series before amplitude/period/area are
// measured from it, without a full signal-processing library.
List<double> _movingAverage(List<double> values, int window) {
  if (window < 3 || values.length < window) return values;
  final w = window.isOdd ? window : window + 1;
  final half = w ~/ 2;
  return [
    for (var i = 0; i < values.length; i++)
      () {
        final lo = (i - half).clamp(0, values.length - 1);
        final hi = (i + half).clamp(0, values.length - 1);
        var sum = 0.0;
        for (var j = lo; j <= hi; j++) {
          sum += values[j];
        }
        return sum / (hi - lo + 1);
      }(),
  ];
}

// Turns a raw track (own position + heading, since the current drop) into
// the KPIs Guiñada shows. anchorLat/anchorLon is the CURRENT drop position
// (config.dropLat/dropLon) — same "known, not fitted" spirit as
// fitAnchorCenterKnownRadius, just used here as a fixed reference instead
// of something to solve for.
YawAnalysisResult computeYawAnalysis({
  required List<AnchorYawPoint> points,
  required double anchorLat,
  required double anchorLon,
}) {
  final usable = points.where((p) => p.headingDeg != null).toList();
  if (usable.length < 4) {
    return const YawAnalysisResult(
      samples: 0,
      yawSeries: [],
      yawAmplitudeDeg: null,
      oscillationPeriod: null,
      sweptAreaM2: null,
    );
  }
  final rawYaw = [
    for (final p in usable)
      yawMisalignmentDeg(
        anchorLat: anchorLat,
        anchorLon: anchorLon,
        boatLat: p.lat,
        boatLon: p.lon,
        headingDeg: p.headingDeg!,
      )!,
  ];
  // Smoothing window scales a little with sample count so a handful of
  // points (start of the "última hora" window) isn't over-smoothed into a
  // flat line, but a long dense series still gets real noise reduction.
  final smoothed = _movingAverage(rawYaw, (usable.length ~/ 20).clamp(3, 9));
  final yawSeries = [
    for (var i = 0; i < usable.length; i++)
      (t: usable[i].t, yawDeg: smoothed[i]),
  ];
  final amplitude =
      smoothed.reduce(math.max) - smoothed.reduce(math.min);

  // Oscillation period — average time between consecutive UPWARD
  // zero-crossings of the smoothed yaw series (one full cycle = port to
  // starboard and back). A simple, honest approximation, not a spectral
  // analysis — deliberately ignores crossings closer together than 20s
  // (GPS/compass jitter, not a real half-cycle) and requires the series to
  // have actually swung at least a couple of degrees either side of zero.
  Duration? period;
  if (amplitude > 4) {
    final crossings = <DateTime>[];
    for (var i = 1; i < smoothed.length; i++) {
      if (smoothed[i - 1] <= 0 && smoothed[i] > 0) {
        if (crossings.isEmpty ||
            usable[i].t.difference(crossings.last) >
                const Duration(seconds: 20)) {
          crossings.add(usable[i].t);
        }
      }
    }
    if (crossings.length >= 2) {
      final totalMs = crossings.last
          .difference(crossings.first)
          .inMilliseconds;
      period = Duration(
        milliseconds: (totalMs / (crossings.length - 1)).round(),
      );
    }
  }

  // Swept area: the footprint the boat has actually occupied, in a local
  // flat projection centered on the anchor (same convention used
  // throughout this file). NOT a shoelace over the raw TIME-ordered
  // points — a boat yawing is oscillating back and forth over roughly the
  // SAME arc, not tracing one clean loop, so a time-ordered shoelace
  // mostly cancels itself out to near zero (verified empirically: a
  // realistic 40° yaw over 40 cycles came out as 0.0 m²). The convex hull
  // of the visited points, then shoelace on THAT (properly boundary-
  // ordered) polygon, gives the actual occupied area instead.
  final cosLat = math.cos(anchorLat * math.pi / 180);
  final xy = [
    for (final p in usable)
      (
        x: (p.lon - anchorLon) * cosLat * 111320,
        y: (p.lat - anchorLat) * 110540,
      ),
  ];
  final areaM2 = _convexHullArea(xy);

  return YawAnalysisResult(
    samples: usable.length,
    yawSeries: yawSeries,
    yawAmplitudeDeg: amplitude,
    oscillationPeriod: period,
    sweptAreaM2: areaM2,
  );
}

// Andrew's monotone chain: convex hull in O(n log n), then shoelace on the
// hull's own (properly boundary-ordered) vertices. See computeYawAnalysis's
// doc comment above for why the hull is used instead of a direct
// time-ordered shoelace.
double _convexHullArea(List<({double x, double y})> pts) {
  if (pts.length < 3) return 0;
  final sorted = [...pts]
    ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  double cross(
    ({double x, double y}) o,
    ({double x, double y}) a,
    ({double x, double y}) b,
  ) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <({double x, double y})>[];
  for (final p in sorted) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <({double x, double y})>[];
  for (final p in sorted.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  final hull = [...lower, ...upper];
  if (hull.length < 3) return 0;
  double shoelace = 0;
  for (var i = 0; i < hull.length; i++) {
    final j = (i + 1) % hull.length;
    shoelace += hull[i].x * hull[j].y - hull[j].x * hull[i].y;
  }
  return shoelace.abs() / 2;
}

class ModelForecastPoint {
  const ModelForecastPoint({
    required this.time,
    this.tempC,
    this.windKn,
    this.gustKn,
    this.rainPct,
    this.rainMm,
    this.windDirDeg,
    this.pressureHpa,
  });
  final DateTime time;
  final double? tempC, windKn, gustKn, rainPct, rainMm, windDirDeg, pressureHpa;
}

class WeatherModel {
  String place = 'Sin posicion';
  DateTime? updated;
  String? error;
  final summary = <ForecastPoint>[];
  final hourly = <ForecastPoint>[];
  final marine = <MarinePoint>[];

  Map<String, dynamic> toJson() => {
    'place': place,
    'updated': updated?.toIso8601String(),
    'summary': [for (final p in summary) p.toJson()],
    'hourly': [for (final p in hourly) p.toJson()],
    'marine': [for (final p in marine) p.toJson()],
  };

  void loadFromJson(Map<String, dynamic> j) {
    place = j['place'] as String? ?? place;
    final updatedStr = j['updated'] as String?;
    updated = updatedStr == null ? null : DateTime.tryParse(updatedStr);
    summary
      ..clear()
      ..addAll([
        for (final e in (j['summary'] as List? ?? []))
          ForecastPoint.fromJson(e as Map<String, dynamic>),
      ]);
    hourly
      ..clear()
      ..addAll([
        for (final e in (j['hourly'] as List? ?? []))
          ForecastPoint.fromJson(e as Map<String, dynamic>),
      ]);
    marine
      ..clear()
      ..addAll([
        for (final e in (j['marine'] as List? ?? []))
          MarinePoint.fromJson(e as Map<String, dynamic>),
      ]);
  }
}

// A remembered Signal K server (CFG → Admin, owner-only) — lets the app
// jump between several boats' servers without retyping host/port/login
// each time. Each server keeps its OWN sensor mapping (see
// SettingsModel.sensorConfigJsonForHost) so switching boats never
// overwrites another boat's tank/battery/solar setup.
class SavedServer {
  SavedServer({
    required this.name,
    required this.host,
    this.port = 3000,
    this.skUsername = '',
    this.skPassword = '',
  });
  String name;
  String host;
  int port;
  String skUsername;
  String skPassword;

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'skUsername': skUsername,
    'skPassword': skPassword,
  };

  static SavedServer fromJson(Map<String, dynamic> j) => SavedServer(
    name: j['name'] as String? ?? '',
    host: j['host'] as String? ?? '',
    port: (j['port'] as num?)?.toInt() ?? 3000,
    skUsername: j['skUsername'] as String? ?? '',
    skPassword: j['skPassword'] as String? ?? '',
  );
}

class SettingsModel {
  // Random, generated once on first run and persisted — lets the app tell
  // "my own anchor.* publish echoing back" apart from "a DIFFERENT install
  // of this same app (another phone/tablet, or the web version) changed
  // the shared anchor watch", since both currently publish under the same
  // 'rewind-panel-anchor' label prefix. Without this, every install was
  // forced to ignore ALL rewind-panel-anchor-labeled data including from
  // other installs — meaning anchoring from the webapp never showed as
  // anchored on Android and vice versa.
  String anchorDeviceId = '';
  // CFG → Admin (owner-only, revealed by a long-press — see _settingsPage):
  // other boats' Signal K servers, for quickly switching which one this
  // install talks to. Each entry's sensor mapping is kept separately (see
  // sensorConfigJsonByHost) so switching servers never overwrites another
  // boat's tank/battery/solar setup.
  List<SavedServer> savedServers = [];
  Map<String, Map<String, dynamic>> sensorConfigJsonByHost = {};
  // Anchor watch state (armed, drop position, radius) is boat-specific —
  // without this, switching servers while armed on one boat carried that
  // "anchored" state (and kept publishing it) onto whichever server you
  // switched to next. Confirmed live 2026-09-02.
  Map<String, Map<String, dynamic>> anchorConfigJsonByHost = {};
  String host = 'lysmarine.local';
  int port = 3000;
  String authBase64 = ''; // Basic auth for the Signal K connection (WebSocket + REST) — not InfluxDB.
  // Separate from authBase64 above: a real Signal K session login (POST
  // /signalk/v1/auth/login). Only meaningful running as the Signal K
  // webapp — the browser then holds the session cookie itself, so
  // same-origin embedded pages (Freeboard-SK, the anchor alarm plugin)
  // that need write access (e.g. dragging to set the anchor) are
  // authenticated too, without the app having to touch their iframes.
  String skUsername = '';
  String skPassword = '';
  // Whether the user has consented to the anchor screen falling back to
  // the device's own GPS when Signal K has no vessel position — null
  // means "never asked yet" (see _AnchorWebView's explanatory dialog,
  // shown only on the ANC screen and only when actually needed, never at
  // app launch or on MAP). A privacy-sensitive choice, so it's asked
  // explicitly rather than assumed, and remembered once answered.
  bool? gpsFallbackConsent;
  bool keepAwake = true;
  String brightnessMode = 'dia'; // 'dia', 'noche', 'auto'
  // Historical-chart data source: 'auto' tries InfluxDB first and falls back
  // to the Signal K History API (e.g. KIP/SQLite) if that fails — 'influx'
  // and 'sk' force one or the other regardless of availability.
  String historySource = 'auto';
  String influxHost = ''; // empty = same as `host` above
  String influxOrg = influxOrgDefault;
  String influxToken = influxTokenDefault;
  String influxBucket = influxBucketDefault;
  String influxArchiveBucket = influxBucketDefault; // bucket for 7d / 1mes
  SensorConfig sensorConfig = SensorConfig();
  AnchorConfig anchorConfig = AnchorConfig();
  // Selected id from kBoatIconOptions (lib/boat_icons.dart) — null/unknown
  // falls back to the 'default' entry (the original own_ship.png).
  String shipIconId = 'default';
  String navLayoutMode = 'premium'; // 'classic', 'premium', or 'both'
  List<String> navCardIds = List<String>.of(defaultNavCardIds);
  int navGridColumns = 3; // 3 -> 3x2 (6 cards), 4 -> 4x2 (8 cards)
  // Alarms — see AlarmEngine in main.dart for how these drive live state.
  bool alarmsUseSkZones = false;
  // Keyed by the Signal K notification path (e.g.
  // "notifications.environment.wind.speedApparent") — only paths this app
  // has actually seen a notification for get an entry; unseen ones default
  // to enabled+sound so a brand new zone alarm is on by default.
  Map<String, SkZoneAlarmSetting> skZoneAlarms = {};
  List<CustomAlarmRule> customAlarms = [];
  // AIS "closest approach" DISPLAY filter — not an alarm. A target further
  // than this at CPA, or further out in time than this at TCPA, just isn't
  // shown as the closest-approach target on the NAV AIS card (see
  // _closestApproachTarget in main.dart). See alarmAis* below for the
  // actual collision alarm, which uses much tighter thresholds.
  double aisCpaMaxNm = 5.0;
  double aisTcpaMaxMin = 20.0;
  // AIS collision alarm — genuinely alerts (card highlight + header bell +
  // optional sound) when the closest AIS target's CPA/TCPA both come in
  // under these, tighter than the aisCpaMaxNm/aisTcpaMaxMin display filter
  // above on purpose: "worth showing on NAV" and "worth alerting for" are
  // different bars. Same on/off + sound shape as alarmCorrederaEnabled.
  bool alarmAisEnabled = false;
  bool alarmAisSound = true;
  double alarmAisCpaNm = 1.0;
  double alarmAisTcpaMin = 10.0;
  // Engine alarms — prefer the engine's own DM1 fault bit (J1939 PGN
  // 65226 — SPN 100/FMI 1 oil, SPN 110/FMI 0 coolant, SPN 167/FMI 1
  // alternator) when the NMEA2000 bridge (a Volvo Penta MDI-specific
  // gateway) publishes one; the threshold below is only the fallback for
  // as long as that signal stays unpublished (see engineOverTempAlarm et
  // al. in SignalKModel and the precedence in _activeAlarms/
  // _isLampOnReal). Evaluated only while the engine is running (see
  // _engineRunning in main.dart) so a stopped engine's naturally-zero oil
  // pressure and ambient coolant temp don't fire false alarms. Not
  // user-toggleable off — unlike AIS/Corredera these are safety alarms,
  // only the sound and the threshold are configurable.
  bool alarmEngineOilSound = true;
  double alarmEngineOilMinBar = 1.0;
  bool alarmEngineTempSound = true;
  double alarmEngineTempMaxC = 100.0;
  bool alarmEngineVoltSound = true;
  double alarmEngineVoltMinV = 13.0;
  // Glow-plug/starter-relay circuit fault (SPN 677 or 724, FMI 5) — a
  // discrete DM1 fault with no numeric equivalent, so no threshold to
  // configure, just the sound. Also not user-toggleable off.
  bool alarmEngineGlowPlugSound = true;
  // "Simple" (current design: RPM + status + 5 lamps) vs "Completo" (adds
  // numeric gauges for temp/oil/volt with their data source — DM1 or
  // threshold — plus an undecoded-PGN diagnostics line) — see CFG >
  // Sensores and PremiumMotorEnginePanel's `detailed` param. Ignored
  // (Motor screen never even joins the NAV swipe cycle) when
  // motorPanelEnabled is false.
  bool motorPanelDetailed = false;
  // "Ninguno" in CFG > Pantalla > ESTILO MOTOR — a boat with no engine
  // telemetry wired up at all can drop the Motor screen from the NAV
  // swipe cycle entirely instead of it always sitting there as an empty
  // simulation preview (see _kMotorPanelAlwaysVisible in main.dart).
  bool motorPanelEnabled = true;
  // Whether NAV's header auto-hides after a few seconds like ANC/MAP
  // always do (those two are non-negotiable — a WebView needs the full
  // screen). NAV doesn't have that constraint, so it's the user's call;
  // true matches the original behavior.
  bool autoHideHeaderOnNav = true;
  // Corredera (log/speedo) stall alarm: SOG moving but STW reads zero for a
  // sustained period usually means the paddle wheel is fouled/stuck rather
  // than the boat actually being stopped in the water — a standalone alarm
  // outside the customAlarms list since it isn't threshold-configurable by
  // the user, just on/off + sound.
  bool alarmCorrederaEnabled = false;
  bool alarmCorrederaSound = true;
  // Anchor watch alarms — only evaluated while settings.anchorConfig.armed
  // (see _activeAlarms in main.dart). Depth-swing is a margin around the
  // depth recorded at the moment of dropping, not the absolute value — a
  // tide change or the boat settling over different bottom both show up as
  // a swing, which is a useful drag proxy even before the boat leaves the
  // watch circle. Explicitly NOT a scope-ratio alarm (chain:depth) — asked
  // for and declined; depth swing is what's wanted instead.
  bool alarmAnchorDepthEnabled = false;
  // Sound off by default (reported live 2026-09-04) — the anchor-drag
  // alarm itself (garreo) always sounds regardless, un-configurable; these
  // three secondary anchor alarms (depth swing, wind, no-position) stay
  // silent until the user opts in per-alarm in CFG > Fondeo, same as the
  // AIS/corredera/engine alarms already default to sound-on but these
  // specifically default to off.
  bool alarmAnchorDepthSound = false;
  double alarmAnchorDepthMarginM = 1.5;
  bool alarmAnchorWindEnabled = false;
  bool alarmAnchorWindSound = false;
  double alarmAnchorWindKn = 25.0;
  // "Fails loud, not silent" — losing position entirely while armed (both
  // Signal K and any device-GPS fallback) is itself worth alerting on, not
  // just silently showing "--" the way it would for an unarmed watch. On
  // by default, unlike the other two — this one has no false-positive risk
  // (it only fires when there's truly nothing to watch with). Sound still
  // defaults off though, same as the other two anchor alarms above.
  bool alarmAnchorNoPositionEnabled = true;
  bool alarmAnchorNoPositionSound = false;
  // A single implausible GPS fix (a big instantaneous jump, then back) can
  // read as "outside the watch circle" even though the boat never actually
  // moved — this ignores any one reading that jumps further than this from
  // the last trusted fix, rather than trusting it as real drift.
  bool alarmAnchorFilterGlitches = true;
  double alarmAnchorGlitchJumpM = 50;
  // Vessel-design facts, not per-anchorage state — published to Signal K
  // as design.bowAnchorRollerHeight / design.totalAnchorChainLength
  // alongside the anchor watch data, same paths hoekens used.
  double anchorBowRollerHeightM = 0;
  double anchorTotalChainLengthM = 100;
  // ntfy.sh push, per-alarm opt-in — client-side, no Signal K plugin
  // involved. Empty topic gets a "SV_<nombre del barco>" default the first
  // time CFG is opened (see _settingsPage). Which alarms actually push is
  // just the set of alarm keys (same keys _activeAlarms uses) present here
  // — no separate master enable switch, no path to type.
  String ntfyTopic = '';
  final Set<String> ntfyAlarmKeys = {};
  // Minimum minutes between repeat pushes for the same alarm key — applies
  // uniformly to every alarm that pushes, not configured per-alarm.
  int ntfyMinIntervalSec = 60;
  // "Te has llevado el móvil" detectors — only meaningful while armed AND
  // actually relying on the device's own GPS as the anchor position (see
  // NativeAnchorView._preferDeviceGps/_hasSkPosition): if Signal K has its
  // own position, the boat's watch is accurate regardless of where the
  // phone wanders, so these three stay dormant until device GPS is the
  // one actually being trusted.
  bool anchorDetectPhoneLeftByMotion = false;
  bool anchorDetectPhoneLeftBySteps = false;
  bool anchorDetectPhoneLeftByWifi = false;
  String anchorBoatWifiSsid = '';
  bool demoMode = false;
  // Use the device's own accelerometer as the heel/pitch source instead of
  // Signal K, for a boat with no attitude sensor. The device can be mounted
  // at any orientation, so a 2-point calibration (down from a level
  // reading, "right"/starboard from comparing the device's own
  // magnetometer heading against Signal K's boat heading — see
  // AttitudeCalibration / forwardFromHeading) is stored rather than a
  // guessed axis — set via the inclinometer screen's calibration wizard.
  bool usePhoneHeel = false;
  bool phoneAttitudeCalibrated = false;
  double phoneDownX = 0, phoneDownY = 0, phoneDownZ = 1;
  double phoneRightX = 0, phoneRightY = 1, phoneRightZ = 0;
  // Safety net: the heading-based sign convention for roll hasn't been
  // verified against a real boat (no way to test that here) — flip this if
  // a live calibrated reading turns out E/B-reversed, without recalibrating.
  bool phoneAttitudeInvertRoll = false;

  AttitudeCalibration get phoneCalibration => phoneAttitudeCalibrated
      ? AttitudeCalibration(
          down: Vec3(phoneDownX, phoneDownY, phoneDownZ),
          right: Vec3(phoneRightX, phoneRightY, phoneRightZ),
        )
      : AttitudeCalibration.fallback;

  void savePhoneCalibration(AttitudeCalibration c) {
    phoneAttitudeCalibrated = true;
    phoneDownX = c.down.x;
    phoneDownY = c.down.y;
    phoneDownZ = c.down.z;
    phoneRightX = c.right.x;
    phoneRightY = c.right.y;
    phoneRightZ = c.right.z;
  }

  String get effectiveInfluxHost => influxHost.isEmpty ? host : influxHost;
}

class TankViewData {
  const TankViewData({
    required this.name,
    required this.slots,
    required this.color,
    required this.icon,
  });
  final String name;
  final List<TankSlot> slots;
  final Color color;
  final IconData icon;
  int get capacityL => slots.fold(0, (sum, s) => sum + s.capacityL);
  double? percent(Map<String, double?> values) {
    var liters = 0.0;
    var capacity = 0;
    var unweightedSum = 0.0;
    var unweightedCount = 0;
    for (final s in slots) {
      final pct = values[s.tankKey];
      if (pct == null) continue;
      final cap = s.capacityL;
      if (cap > 0) {
        liters += cap * pct / 100.0;
        capacity += cap;
      } else {
        // Discovered tanks whose Signal K server only publishes
        // currentLevel (no capacity node) default to capacityL 0 until
        // someone fills it in — without this fallback, a perfectly valid
        // live reading got silently dropped here (liters-weighted average
        // saw zero total capacity) and the card showed a misleading "0%"
        // instead of the real level.
        unweightedSum += pct;
        unweightedCount++;
      }
    }
    if (capacity > 0) return liters * 100.0 / capacity;
    if (unweightedCount > 0) return unweightedSum / unweightedCount;
    return null;
  }
}
