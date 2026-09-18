import 'dart:convert';

import 'models.dart';

/// Configuración del BARCO compartida entre todos los dispositivos.
///
/// La guarda el plugin REWIND en el servidor (ver server/config_store.js) y
/// cada tablet, móvil o navegador la lee al conectar. Aquí solo vive la
/// decisión de QUÉ se comparte y cómo se aplica; el número de revisión y los
/// conflictos los resuelve el servidor, que es el único con un reloj y un
/// contador fiables.
///
/// Dos reglas que no se pueden relajar:
///  - **Nada de credenciales.** Usuario, contraseña, token de InfluxDB y
///    autenticación básica se quedan en el dispositivo.
///  - **Nada que sea del aparato y no del barco**: brillo, mantener la
///    pantalla encendida, calibración del móvil, modo DEMO o el permiso del
///    GPS del dispositivo.
const kSharedConfigSchemaVersion = 1;

/// Comprobado en los tests: ninguna de estas claves puede aparecer nunca en
/// el documento compartido.
const kNeverSharedKeys = <String>[
  'skUsername',
  'skPassword',
  'authBase64',
  'influxToken',
  'influxHost',
  'influxOrg',
  'influxBucket',
  'influxArchiveBucket',
  'anchorDeviceId',
  'brightnessMode',
  'keepAwake',
  'demoMode',
  'usePhoneHeel',
  'phoneAttitudeCalibrated',
  'gpsFallbackConsent',
  // Cómo avisa ESTE aparato, no qué vigila el barco: la tablet de la mesa de
  // cartas puede sonar de noche y el móvil no. Los interruptores de "aviso
  // sonoro" llevan su propia etiqueta en CFG para que se vea.
  'alarmCorrederaSound',
  'alarmAisSound',
  'alarmEngineOilSound',
  'alarmEngineTempSound',
  'alarmEngineVoltSound',
  'alarmEngineGlowPlugSound',
  'alarmAnchorDepthSound',
  'alarmAnchorWindSound',
  // Detectar que te has ido con el móvil solo tiene sentido en el móvil.
  'anchorDetectPhoneLeftByMotion',
  'anchorDetectPhoneLeftBySteps',
  'anchorDetectPhoneLeftByWifi',
];

/// Lo que este dispositivo propone como configuración del barco.
Map<String, dynamic> sharedConfigFromSettings(SettingsModel s) => {
  'schemaVersion': kSharedConfigSchemaVersion,
  'sensors': s.sensorConfig.toJson(),
  'polar': s.polarConfigToJson(),
  'ship': {'iconId': s.shipIconId},
  'anchor': {
    'bowRollerHeightM': s.anchorBowRollerHeightM,
    'totalChainLengthM': s.anchorTotalChainLengthM,
    'gpsToBowM': s.anchorGpsToBowM,
    'boatWifiSsid': s.anchorBoatWifiSsid,
  },
  'battery': {
    'chemistryStart': s.batteryChemistryStart,
    'chemistryBow': s.batteryChemistryBow,
  },
  'alarms': {
    'ntfyTopic': s.ntfyTopic,
    'ntfyMinIntervalSec': s.ntfyMinIntervalSec,
    'aisEnabled': s.alarmAisEnabled,
    'aisCpaNm': s.alarmAisCpaNm,
    'aisTcpaMin': s.alarmAisTcpaMin,
    // Qué vigila el barco va con el barco. Antes la corredera y el "sin
    // posición" eran las dos únicas alarmas que se quedaban en el aparato,
    // mientras sus vecinas de la misma tarjeta sí viajaban: apagabas la
    // corredera en la tablet y seguía sonando en el móvil.
    'correderaEnabled': s.alarmCorrederaEnabled,
    'anchorNoPositionEnabled': s.alarmAnchorNoPositionEnabled,
    'anchorFilterGlitches': s.alarmAnchorFilterGlitches,
    'anchorGlitchJumpM': s.alarmAnchorGlitchJumpM,
    // Y a cuáles de ellas hay que avisar por push, ya que el topic —el dato
    // que de verdad manda el aviso— también se comparte.
    'ntfyKeys': s.ntfyAlarmKeys.toList()..sort(),
    'engineOilMinBar': s.alarmEngineOilMinBar,
    'engineTempMaxC': s.alarmEngineTempMaxC,
    'engineVoltMinV': s.alarmEngineVoltMinV,
    'anchorDepthEnabled': s.alarmAnchorDepthEnabled,
    'anchorDepthMarginM': s.alarmAnchorDepthMarginM,
    'anchorWindEnabled': s.alarmAnchorWindEnabled,
    'anchorWindKn': s.alarmAnchorWindKn,
    'useSkZones': s.alarmsUseSkZones,
    'custom': [for (final r in s.customAlarms) r.toJson()],
  },
};

/// ¿Trae este valor información de verdad, o es "no configurado"?
bool _meaningful(dynamic v) {
  if (v == null) return false;
  if (v is String) return v.trim().isNotEmpty;
  if (v is Iterable) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// Mezcla la configuración de sensores del servidor sobre la de este
/// dispositivo: el servidor manda, pero **un valor vacío nunca borra uno que
/// ya está puesto**.
///
/// Sin esto, la primera sincronización con un barco cuya configuración aún no
/// tenía modelo de motor se llevaba por delante el perfil local y con él el
/// consumo estimado de la pantalla de motor (visto en vivo 2026-09-17).
///
/// La contrapartida, deliberada: borrar un valor en un dispositivo no lo
/// borra en los demás. Quitar un sensor se hace donde está configurado, y es
/// preferible a perder configuración por accidente.
Map<String, dynamic> mergeSensorJson({
  required Map<String, dynamic> local,
  required Map<String, dynamic> remote,
}) {
  final merged = Map<String, dynamic>.from(local);
  for (final entry in remote.entries) {
    if (_meaningful(entry.value)) merged[entry.key] = entry.value;
  }
  return merged;
}

double? _double(dynamic v) => v is num ? v.toDouble() : null;
int? _int(dynamic v) => v is num ? v.toInt() : null;

Map<String, dynamic>? _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

/// Aplica lo que manda el servidor sobre los ajustes de este dispositivo.
///
/// Tolerante a propósito: lo que no venga se queda como está y lo que no se
/// entienda se ignora, para que una versión más nueva de la app no rompa a
/// una más vieja ni al revés.
void applySharedConfig(SettingsModel s, Map<String, dynamic> config) {
  final sensors = _map(config['sensors']);
  if (sensors != null) {
    s.sensorConfig = SensorConfig.fromJson(
      mergeSensorJson(local: s.sensorConfig.toJson(), remote: sensors),
    );
  }
  final polar = _map(config['polar']);
  if (polar != null) s.polarConfigFromJson(polar);
  final ship = _map(config['ship']);
  if (ship != null && ship['iconId'] is String) {
    s.shipIconId = ship['iconId'] as String;
  }
  final anchor = _map(config['anchor']);
  if (anchor != null) {
    s.anchorBowRollerHeightM =
        _double(anchor['bowRollerHeightM']) ?? s.anchorBowRollerHeightM;
    s.anchorTotalChainLengthM =
        _double(anchor['totalChainLengthM']) ?? s.anchorTotalChainLengthM;
    s.anchorGpsToBowM = _double(anchor['gpsToBowM']) ?? s.anchorGpsToBowM;
    if (anchor['boatWifiSsid'] is String) {
      s.anchorBoatWifiSsid = anchor['boatWifiSsid'] as String;
    }
  }
  final battery = _map(config['battery']);
  if (battery != null) {
    if (battery['chemistryStart'] is String) {
      s.batteryChemistryStart = battery['chemistryStart'] as String;
    }
    if (battery['chemistryBow'] is String) {
      s.batteryChemistryBow = battery['chemistryBow'] as String;
    }
  }
  final alarms = _map(config['alarms']);
  if (alarms != null) {
    if (alarms['ntfyTopic'] is String) {
      s.ntfyTopic = alarms['ntfyTopic'] as String;
    }
    s.ntfyMinIntervalSec =
        _int(alarms['ntfyMinIntervalSec']) ?? s.ntfyMinIntervalSec;
    s.alarmAisEnabled = alarms['aisEnabled'] as bool? ?? s.alarmAisEnabled;
    s.alarmAisCpaNm = _double(alarms['aisCpaNm']) ?? s.alarmAisCpaNm;
    s.alarmAisTcpaMin = _double(alarms['aisTcpaMin']) ?? s.alarmAisTcpaMin;
    s.alarmEngineOilMinBar =
        _double(alarms['engineOilMinBar']) ?? s.alarmEngineOilMinBar;
    s.alarmEngineTempMaxC =
        _double(alarms['engineTempMaxC']) ?? s.alarmEngineTempMaxC;
    s.alarmEngineVoltMinV =
        _double(alarms['engineVoltMinV']) ?? s.alarmEngineVoltMinV;
    s.alarmAnchorDepthEnabled =
        alarms['anchorDepthEnabled'] as bool? ?? s.alarmAnchorDepthEnabled;
    s.alarmAnchorDepthMarginM =
        _double(alarms['anchorDepthMarginM']) ?? s.alarmAnchorDepthMarginM;
    s.alarmAnchorWindEnabled =
        alarms['anchorWindEnabled'] as bool? ?? s.alarmAnchorWindEnabled;
    s.alarmAnchorWindKn =
        _double(alarms['anchorWindKn']) ?? s.alarmAnchorWindKn;
    s.alarmCorrederaEnabled =
        alarms['correderaEnabled'] as bool? ?? s.alarmCorrederaEnabled;
    s.alarmAnchorNoPositionEnabled =
        alarms['anchorNoPositionEnabled'] as bool? ??
        s.alarmAnchorNoPositionEnabled;
    s.alarmAnchorFilterGlitches =
        alarms['anchorFilterGlitches'] as bool? ?? s.alarmAnchorFilterGlitches;
    s.alarmAnchorGlitchJumpM =
        _double(alarms['anchorGlitchJumpM']) ?? s.alarmAnchorGlitchJumpM;
    final ntfyKeys = alarms['ntfyKeys'];
    // Misma regla que los sensores: una lista vacía no borra la que ya hay.
    // Perder los avisos push porque un aparato recién estrenado subió su
    // lista en blanco sería mucho peor que no propagar un "apágalos todos".
    if (ntfyKeys is List && ntfyKeys.isNotEmpty) {
      // Set final: se vacía y se rellena, no se sustituye.
      s.ntfyAlarmKeys
        ..clear()
        ..addAll(ntfyKeys.whereType<String>());
    }
    s.alarmsUseSkZones = alarms['useSkZones'] as bool? ?? s.alarmsUseSkZones;
    final custom = alarms['custom'];
    if (custom is List) {
      s.customAlarms = [
        for (final r in custom)
          if (r is Map) CustomAlarmRule.fromJson(Map<String, dynamic>.from(r)),
      ];
    }
  }
}

bool sharedConfigEquals(Map<String, dynamic> a, Map<String, dynamic> b) =>
    jsonEncode(a) == jsonEncode(b);

/// ¿Hay que adoptar lo del servidor?
///
/// Solo si trae una revisión distinta de la última vista. Un dispositivo que
/// vuelve de estar desconectado NO sube lo suyo por el hecho de reconectar:
/// lee primero, y solo escribe cuando alguien cambia algo aquí. Es el mismo
/// error que ya cometimos con el fondeo.
bool shouldAdoptRemote({
  required int remoteRevision,
  required int localKnownRevision,
}) => remoteRevision > 0 && remoteRevision != localKnownRevision;
