part of '../main.dart';

// ntfy.sh push, per alarm key — client-side HTTP POST, no Signal K plugin
// involved (per explicit "no quiero pasar por el plugin de signalk"
// instruction). Split out of main.dart into its own file to shrink it;
// _s is the Dashboard State this service reads live data from (settings,
// signalK, the anchor/wind trackers) — the same data every other part of
// the app reads directly, just threaded in explicitly here since this
// class isn't the State itself.
class _NtfyPushService {
  _NtfyPushService(this._s);
  final _DashboardState _s;

  // Which alarms push is just settings.ntfyAlarmKeys (checked off per-alarm
  // in CFG); one shared "don't repeat within N min" window applies across
  // all of them, keyed per alarm so one alarm's pushes don't suppress a
  // different one's.
  final Map<String, DateTime> _lastNtfyPushAt = {};

  // Builds the actual numbers behind each alarm into the push body, not
  // just its generic label — e.g. "GARREANDO" alone says nothing about how
  // far out, how fast, or in which direction, and this is exactly the
  // moment someone reading a phone notification wants that at a glance.
  String _ntfyBodyForAlarm(String key, String label) {
    switch (key) {
      case 'anchorDrag':
        final cfg = _s.settings.anchorConfig;
        final lat = _s._anchorEffectiveLat ?? _s.signalK.latitude;
        final lon = _s._anchorEffectiveLon ?? _s.signalK.longitude;
        final parts = <String>[
          _s._anchorIsDragging ? 'GARREANDO' : 'FUERA DEL CÍRCULO',
        ];
        if (lat != null &&
            lon != null &&
            cfg.dropLat != null &&
            cfg.dropLon != null) {
          final r = bearingDistanceMeters(
            cfg.dropLat!,
            cfg.dropLon!,
            lat,
            lon,
          );
          parts.add(
            '${r.distanceM.round()} m / ${cfg.radiusM.round()} m radio',
          );
          final heading = _s._freshHeading;
          if (heading != null) {
            final rel = ((r.bearingDeg - heading + 540) % 360) - 180;
            parts.add(
              '${rel.abs().round()}° ${rel >= 0 ? 'Er' : 'Br'}',
            );
          }
        }
        if (_s._anchorIsDragging && _s._anchorDragSpeedMPerMin != null) {
          parts.add(
            'alejándose ${_s._anchorDragSpeedMPerMin!.toStringAsFixed(1)} m/min',
          );
        }
        // Garreando rarely happens in isolation — viento y profundidad son
        // justo los dos datos que explican POR QUÉ se está garreando, así
        // que van en la misma alarma en vez de obligar a mirar otra pantalla.
        final aws = _s._freshWind(_s._dAws);
        final awa = _s._freshWind(_s._dAwa);
        if (aws != null) {
          parts.add(
            'AWS ${aws.toStringAsFixed(0)} kt'
            '${_s._awsHistory.isGusting() ? ' (RACHA)' : ''}'
            '${awa != null ? ' AWA ${awa.round()}°' : ''}',
          );
        }
        final depth = _s._fresh(_s.signalK.depthM);
        final dropDepth = cfg.dropDepthM;
        if (depth != null) {
          parts.add(
            'profundidad ${depth.toStringAsFixed(1)} m'
            '${dropDepth != null ? ' (${dropDepth.toStringAsFixed(1)} m al fondear)' : ''}',
          );
        }
        if (_s.settings.anchorTotalChainLengthM > 0) {
          parts.add('cadena ${_s.settings.anchorTotalChainLengthM.round()} m');
        }
        return parts.join(' · ');
      case 'anchorWind':
        final aws = _s._freshWind(_s._dAws);
        final twd = _s._freshWind(_s._dTwd);
        final parts = <String>[
          if (aws != null) '${aws.toStringAsFixed(0)} kt',
          if (_s._awsHistory.isGusting()) 'RACHA',
          if (twd != null) 'TWD ${twd.round()}°',
          'umbral ${_s.settings.alarmAnchorWindKn.round()} kt',
        ];
        return parts.join(' · ');
      case 'anchorDepth':
        final depth = _s._fresh(_s.signalK.depthM);
        final dropDepth = _s.settings.anchorConfig.dropDepthM;
        final parts = <String>[];
        if (depth != null) parts.add('${depth.toStringAsFixed(1)} m ahora');
        if (dropDepth != null) {
          parts.add('${dropDepth.toStringAsFixed(1)} m al fondear');
          if (depth != null) {
            final delta = depth - dropDepth;
            parts.add(
              '${delta > 0 ? '+' : ''}${delta.toStringAsFixed(1)} m',
            );
          }
        }
        parts.add('margen ${_s.settings.alarmAnchorDepthMarginM.toStringAsFixed(1)} m');
        return parts.join(' · ');
      case 'corredera':
        final sog = _s._freshSog;
        final stw = _s._freshStw;
        final parts = <String>[
          if (sog != null) 'SOG ${sog.toStringAsFixed(1)} kt',
          'STW ${stw != null ? stw.toStringAsFixed(1) : '0.0'} kt',
        ];
        return parts.join(' · ');
      default:
        return label;
    }
  }

  Future<void> _maybeSendNtfyForAlarm(String key, String label) async {
    final topic = _s.settings.ntfyTopic.trim();
    if (topic.isEmpty || !_s.settings.ntfyAlarmKeys.contains(key)) return;
    final now = DateTime.now();
    final last = _lastNtfyPushAt[key];
    if (last != null &&
        now.difference(last) < Duration(seconds: _s.settings.ntfyMinIntervalSec)) {
      return;
    }
    final vessel = _s.signalK.vesselName ?? 'REWIND';
    final detail = _ntfyBodyForAlarm(key, label);
    var delivered = false;
    try {
      // ASCII-only header values — alarm labels and vessel names routinely
      // have accents/em-dashes, which throw in Dart's http client if put
      // directly in a header. The real message (any charset) goes in the
      // UTF-8 body instead, same fix as the test-push button.
      final resp = await http
          .post(
            Uri.parse('https://ntfy.sh/${Uri.encodeComponent(topic)}'),
            headers: const {
              'Title': 'REWIND Panel - Alarma',
              'Priority': 'urgent',
              'Tags': 'warning',
            },
            body: '$vessel: $label\n$detail',
          )
          .timeout(const Duration(seconds: 8));
      delivered = resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      // Best-effort — a failed push shouldn't affect the on-device alarm.
    }
    // Only start the throttle window on a CONFIRMED delivery — this used to
    // stamp _lastNtfyPushAt unconditionally before even attempting the
    // request, so a failed attempt (network error, or ntfy.sh itself
    // returning 401/404/500, never checked before) silently burned the
    // same ntfyMinIntervalSec window as a real push, delaying the next
    // retry by up to a minute while the boat kept dragging. Audit finding,
    // verified 2026-09-05.
    if (delivered) _lastNtfyPushAt[key] = now;
    // Genuinely awaited, not fire-and-forget — garreo is almost always
    // noticed from the phone notification while the app is backgrounded,
    // and Android can freeze/kill a backgrounded isolate's pending work the
    // moment the awaited call above returns, so an unawaited follow-up here
    // frequently never actually ran. Confirmed live 2026-09-01: the text
    // alert always arrived, the attachment never did — this is why.
    if (key == 'anchorDrag' && delivered) {
      await _sendNtfyMapSnapshot(topic);
    }
  }

  Future<void> _sendNtfyMapSnapshot(String topic) async {
    try {
      // toImage() needs the engine's raster thread, which Android can
      // starve/stall while the app is backgrounded — exactly when garreo
      // is usually noticed. Without a timeout that hang sat in the awaited
      // path all the way up into _maybeSendNtfyForAlarm, which is the
      // likely reason the alarm itself started repeating outside its
      // configured interval (confirmed live 2026-09-01) — a wedged Future
      // here can outlive the app's own foreground/background cycle.
      final bytes = await _renderAnchorSnapshotPng().timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
      if (bytes == null) {
        lastCrashInfo =
            '${DateTime.now()} ntfy snapshot: _renderAnchorSnapshotPng '
            'returned null (dropLat/dropLon likely null)';
        return;
      }
      await http
          .put(
            Uri.parse('https://ntfy.sh/${Uri.encodeComponent(topic)}'),
            headers: const {
              'Filename': 'fondeo.png',
              'Title': 'REWIND Panel - Posicion',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 20));
    } catch (e, st) {
      // Previously silent — a failure here was indistinguishable from the
      // attachment simply not being tried at all. Surfaced via
      // CFG → Diagnóstico's "último error" card instead.
      lastCrashInfo = '${DateTime.now()} ntfy snapshot failed:\n$e\n$st';
    }
  }

  // Draws a self-contained schematic (not a live capture of the ANC screen
  // — that only worked while ANC happened to be the visible tab, which
  // isn't true most of the time an alarm actually fires, so the attachment
  // silently never arrived) via a plain dart:ui Canvas. No widget needs to
  // be mounted/laid out for this to work, so it's reliable regardless of
  // which tab the app is showing. Bakes in the same numbers as the text
  // push (distance/radius, drag speed, wind, depth) directly onto the
  // image, per explicit request.
  Future<Uint8List?> _renderAnchorSnapshotPng() async {
    final cfg = _s.settings.anchorConfig;
    final dropLat = cfg.dropLat, dropLon = cfg.dropLon;
    final lat = _s._anchorEffectiveLat ?? _s.signalK.latitude;
    final lon = _s._anchorEffectiveLon ?? _s.signalK.longitude;
    if (dropLat == null || dropLon == null) return null;

    const w = 480.0, h = 560.0;
    const mapH = 380.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = cBg);

    // ── Schematic: anchor at center, boat offset by real bearing/distance ──
    final center = const Offset(w / 2, mapH / 2 + 20);
    final rel = (lat != null && lon != null)
        ? bearingDistanceMeters(dropLat, dropLon, lat, lon)
        : null;
    final radiusM = cfg.radiusM;
    final maxSpanM = math.max(radiusM * 1.35, (rel?.distanceM ?? 0) * 1.25)
        .clamp(15, 100000)
        .toDouble();
    final pxPerM = 130 / maxSpanM;

    final circlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = (rel != null && rel.distanceM > radiusM) ? cRed : cCyan;
    if (cfg.shape == 'sector' &&
        cfg.sectorStartDeg != null &&
        cfg.sectorEndDeg != null) {
      final startDeg = cfg.sectorStartDeg! - 90;
      final sweep =
          ((cfg.sectorEndDeg! - cfg.sectorStartDeg!) + 360) % 360;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radiusM * pxPerM),
        startDeg * math.pi / 180,
        sweep * math.pi / 180,
        false,
        circlePaint,
      );
    } else {
      canvas.drawCircle(center, radiusM * pxPerM, circlePaint);
    }
    // Anchor mark.
    canvas.drawCircle(center, 4, Paint()..color = cText);

    // Boat mark, at its real bearing/distance from the anchor.
    if (rel != null) {
      final rad = rel.bearingDeg * math.pi / 180;
      final boatOffset = Offset(
        center.dx + math.sin(rad) * rel.distanceM * pxPerM,
        center.dy - math.cos(rad) * rel.distanceM * pxPerM,
      );
      final boatColor = _s._anchorIsDragging ? cRed : cYellow;
      final heading = _s._freshHeading;
      canvas.save();
      canvas.translate(boatOffset.dx, boatOffset.dy);
      if (heading != null) canvas.rotate(heading * math.pi / 180);
      final boatPath = Path()
        ..moveTo(0, -12)
        ..lineTo(8, 10)
        ..lineTo(0, 5)
        ..lineTo(-8, 10)
        ..close();
      canvas.drawPath(boatPath, Paint()..color = boatColor);
      canvas.restore();
    }

    // ── Text block: same numbers as the ntfy text push ──────────────────
    final lines = <String>[
      _s.signalK.vesselName ?? 'REWIND',
      _s._anchorIsDragging ? 'GARREANDO' : 'Vigilancia de fondeo',
    ];
    if (rel != null) {
      lines.add(
        'Distancia: ${rel.distanceM.round()} m / radio ${radiusM.round()} m',
      );
    }
    if (_s._anchorIsDragging && _s._anchorDragSpeedMPerMin != null) {
      lines.add(
        'Velocidad de garreo: ${_s._anchorDragSpeedMPerMin!.toStringAsFixed(1)} m/min',
      );
    }
    final aws = _s._freshWind(_s._dAws);
    final awa = _s._freshWind(_s._dAwa);
    if (aws != null) {
      lines.add(
        'AWS: ${aws.toStringAsFixed(0)} kt'
        '${_s._awsHistory.isGusting() ? ' (RACHA)' : ''}'
        '${awa != null ? ' · AWA ${awa.round()}°' : ''}',
      );
    }
    final depth = _s._fresh(_s.signalK.depthM);
    if (depth != null) {
      lines.add(
        'Profundidad: ${depth.toStringAsFixed(1)} m'
        '${cfg.dropDepthM != null ? ' (${cfg.dropDepthM!.toStringAsFixed(1)} m al fondear)' : ''}',
      );
    }
    if (_s.settings.anchorTotalChainLengthM > 0) {
      lines.add('Cadena disponible: ${_s.settings.anchorTotalChainLengthM.round()} m');
    }

    var ty = mapH + 16;
    for (var i = 0; i < lines.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: lines[i],
          style: TextStyle(
            color: i == 0 ? cMuted : (i == 1 ? cYellow : cText),
            fontSize: i == 1 ? 20 : 15,
            fontWeight: i <= 1 ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w - 32);
      tp.paint(canvas, Offset(16, ty));
      ty += tp.height + 6;
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(w.round(), h.round());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  // Sends (rate-limited) a push for every currently-active, unmuted alarm
  // whose key is checked in CFG → Alarmas.
  Future<void> _maybeSendNtfyAlarms() async {
    // _s._staleWatchdog calls this unconditionally every 2s, DEMO mode or
    // not — DEMO's own tick feeds signalK real-looking oscillating wind/
    // battery/etc. values specifically to LOOK like live data, which can
    // genuinely cross a configured alarm threshold and would otherwise
    // push a real ntfy alert built entirely from fabricated demo numbers.
    // Reported live 2026-09-04.
    if (_s.settings.demoMode) return;
    if (_s.settings.ntfyTopic.trim().isEmpty || _s.settings.ntfyAlarmKeys.isEmpty) {
      return;
    }
    for (final a in _s._activeAlarms) {
      if (a.muted) continue;
      unawaited(_maybeSendNtfyForAlarm(a.key, a.label));
    }
  }

  // Unconditional — bypasses the alarm-active and rate-limit checks, so
  // CFG's "Enviar prueba" button can confirm the topic/connection actually
  // work without needing to fake an alarm condition first.
  Future<bool> _sendNtfyTestPush() async {
    final topic = _s.settings.ntfyTopic.trim();
    if (topic.isEmpty) return false;
    try {
      // Title as a plain-ASCII header, everything boat-specific (vessel
      // name may have accents) in the UTF-8 body instead — an HTTP header
      // value with non-Latin1 characters (found live: the "—" em dash this
      // used to put directly in Title) makes Dart's http client throw
      // before the request is even sent, which is why this always failed.
      final resp = await http
          .post(
            Uri.parse('https://ntfy.sh/${Uri.encodeComponent(topic)}'),
            headers: const {'Title': 'REWIND Panel - Prueba', 'Tags': 'test_tube'},
            body:
                'Prueba desde ${_s.signalK.vesselName ?? "REWIND"}. Si ves esto, ntfy funciona.',
          )
          .timeout(const Duration(seconds: 8));
      final ok = resp.statusCode == 200;
      // Follow-up attachment (the large ship icon) so the test button also
      // confirms the file-upload path — non-blocking, doesn't affect `ok`.
      if (ok) unawaited(_sendNtfyTestAttachment(topic));
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sendNtfyTestAttachment(String topic) async {
    try {
      final asset = boatIconById(_s.settings.shipIconId).grandeAsset;
      final bytes = await rootBundle.load(asset);
      final filename = asset.split('/').last;
      await http
          .put(
            Uri.parse('https://ntfy.sh/${Uri.encodeComponent(topic)}'),
            headers: {
              'Filename': filename,
              'Title': 'REWIND Panel - Prueba adjunto',
            },
            body: bytes.buffer.asUint8List(),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Best-effort — the text test push already confirmed above.
    }
  }
}
