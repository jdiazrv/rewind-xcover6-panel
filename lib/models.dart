import 'package:flutter/material.dart';

import 'attitude_sensor.dart';
import 'data_api.dart';
import 'theme.dart';

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
const mBowTemp = MetricDef(
  'electrical.batteries.bowthruster.temperature',
  'T. bowthruster',
  'C',
  offset: -273.15,
  color: cOrange,
);
const mSeaTemp = MetricDef(
  'environment.water.temperature',
  'T. mar',
  'C',
  offset: -273.15,
  color: cCyan,
);
const mCpuTemp = MetricDef(
  'environment.rpi.cpu.temperature',
  'T. Raspberry',
  'C',
  offset: -273.15,
  color: cMuted,
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
  final battMatch = RegExp(
    r'^electrical\.batteries\.([^.]+)\.temperature$',
  ).firstMatch(path);
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
  double? cogTrueDeg;
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
  double? waterTempK;
  double? outsideTempK;
  double? outsideHumidity; // 0-100 %
  double? outsidePressureHpa;
  double? indoorTempK;
  double? indoorHumidity; // 0-100 %
  double? cpuTempK;
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
  double? dcW;
  double? startV;
  double? bowthrusterV;
  double? bowthrusterTempK;
  // Tanks (key = "type.id", e.g. "freshWater.24")
  final tanks = <String, double?>{};
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
  String batteryHouseId = '278';
  String batteryStartId = '278-second';
  String? solarPath = 'electrical.venus.totalPanelPower';
  String? fridge1Path = 'environment.fridge_1.temperature';
  String? fridge2Path = 'environment.fridge_2.temperature';
  String? depthPath = 'environment.depth.belowKeel';
  bool hasOutsideTemp = true;
  bool hasOutsidePressure = true;
  List<TankSlot> tanks = [
    TankSlot(type: 'fuel', id: '27', groupLabel: 'Fuel', capacityL: 180),
    TankSlot(type: 'fuel', id: '26', groupLabel: 'Fuel', capacityL: 180),
    TankSlot(
      type: 'freshWater',
      id: '24',
      groupLabel: 'Fresh water',
      capacityL: 276,
    ),
    TankSlot(
      type: 'freshWater',
      id: '25',
      groupLabel: 'Fresh water',
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
    'fridge1Path': fridge1Path,
    'fridge2Path': fridge2Path,
    'depthPath': depthPath,
    'hasOutsideTemp': hasOutsideTemp,
    'hasOutsidePressure': hasOutsidePressure,
    'tanks': [for (final t in tanks) t.toJson()],
  };

  static SensorConfig fromJson(Map<String, dynamic> j) {
    final c = SensorConfig();
    c.batteryHouseId = j['batteryHouseId'] as String? ?? c.batteryHouseId;
    c.batteryStartId = j['batteryStartId'] as String? ?? c.batteryStartId;
    c.solarPath = j['solarPath'] as String?;
    c.fridge1Path = j['fridge1Path'] as String?;
    c.fridge2Path = j['fridge2Path'] as String?;
    c.depthPath = j['depthPath'] as String?;
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

// ─── Signal K path discovery (used by CFG > Sensores) ────────────────────────
class TankCandidate {
  TankCandidate({required this.type, required this.id, this.capacityL});
  final String type;
  final String id;
  final int? capacityL;
}

class SkDiscovery {
  final List<String> batteryIds = [];
  final List<String> solarPaths = [];
  final List<String> fridgePaths = [];
  final List<String> depthPaths = [];
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
  // if installed — preferred over our own client-side CPA geometry when present.
  double? pluginCpaNm;
  double? pluginTcpaMin;
  double? pluginCpaBearingDeg;
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

class SettingsModel {
  String host = 'lysmarine.local';
  int port = 3000;
  String authBase64 = ''; // Basic auth for the Signal K connection (WebSocket + REST) — not InfluxDB.
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
  // AIS "closest approach" filters — a target further than this at CPA, or
  // further out in time than this at TCPA, isn't shown as the closest
  // approach target (see _closestApproachTarget in main.dart).
  double aisCpaMaxNm = 5.0;
  double aisTcpaMaxMin = 20.0;
  // Corredera (log/speedo) stall alarm: SOG moving but STW reads zero for a
  // sustained period usually means the paddle wheel is fouled/stuck rather
  // than the boat actually being stopped in the water — a standalone alarm
  // outside the customAlarms list since it isn't threshold-configurable by
  // the user, just on/off + sound.
  bool alarmCorrederaEnabled = false;
  bool alarmCorrederaSound = true;
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
    var found = false;
    for (final s in slots) {
      final cap = s.capacityL;
      final pct = values[s.tankKey];
      if (cap <= 0 || pct == null) continue;
      liters += cap * pct / 100.0;
      capacity += cap;
      found = true;
    }
    if (!found || capacity == 0) return null;
    return liters * 100.0 / capacity;
  }
}
