/*
 * REWIND Panel — background anchor-drag watchdog.
 *
 * The REWIND app (Android/webapp) already IS the anchor watch's source of
 * truth: it publishes navigation.anchor.state/position/watchZone onto the
 * Signal K bus itself (see lib/main.dart's _publishAnchorDelta), tagged
 * with a $source starting "rewind-panel-anchor". That's how one install
 * shows "Fondeado" the instant another install arms it.
 *
 * The gap that motivated this plugin: NONE of that evaluates the actual
 * drag alarm unless some device has the app open right now — no phone,
 * tablet, or browser connected means nothing is watching at all. This
 * plugin closes that gap by listening to those same paths and running the
 * exact same containment check server-side, inside the Signal K process
 * itself, which is expected to be on 24/7 regardless of any client.
 *
 * It does NOT own any anchor state of its own, has no config UI, and
 * never accepts a drop/raise/setZone command from anyone — it is purely a
 * read-only observer of what the app already publishes, plus (optionally)
 * an ntfy.sh push when it detects the boat has left the watch zone. If a
 * genuinely different anchor-watch plugin (hoekens-anchor-alarm, etc.) is
 * armed at the same time, this one backs off entirely rather than risk a
 * second, possibly-disagreeing alarm — see isForeignArmed below.
 */

const https = require('https');

const EARTH_RADIUS_M = 6371000;
const OWN_SOURCE_PREFIX = 'rewind-panel-anchor';
const ANCHOR_PATHS = [
  'navigation.anchor.state',
  'navigation.anchor.position',
  'navigation.anchor.watchZone',
];

function toRad(deg) {
  return (deg * Math.PI) / 180;
}

// Great-circle bearing (0-360, true) + distance (meters) from point 1 to
// point 2 — ported 1:1 from lib/models.dart's bearingDistanceMeters so the
// server's containment check agrees with what the app itself would compute,
// not a subtly different formula.
function bearingDistance(lat1, lon1, lat2, lon2) {
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const lat1r = toRad(lat1);
  const lat2r = toRad(lat2);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1r) * Math.cos(lat2r) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  const y = Math.sin(dLon) * Math.cos(lat2r);
  const x =
    Math.cos(lat1r) * Math.sin(lat2r) -
    Math.sin(lat1r) * Math.cos(lat2r) * Math.cos(dLon);
  const bearingDeg = (((Math.atan2(y, x) * 180) / Math.PI) + 360) % 360;
  return { bearingDeg, distanceM: EARTH_RADIUS_M * c };
}

// Circle: outside once past the radius. Sector: ALSO outside once past the
// arc's span, even while still inside the radius — same two-part rule as
// lib/main.dart's _isOutsideAnchorZone, ported to match exactly.
function isOutsideZone(dropLat, dropLon, lat, lon, zone) {
  const { bearingDeg, distanceM } = bearingDistance(dropLat, dropLon, lat, lon);
  const radius = Number(zone && zone.radius);
  if (!Number.isFinite(radius) || distanceM > radius) return true;
  if (!zone || zone.type !== 'sector') return false;
  // startDeg/endDeg, NOT startAngle/endAngle — matching what
  // lib/main.dart's _publishAnchorDelta actually puts in
  // navigation.anchor.watchZone (hoekens-anchor-alarm's OWN sector zone
  // uses startAngle/endAngle instead, easy to mix up — this plugin only
  // ever reads OUR app's own published shape, never hoekens'). Wrong
  // field names here meant a sector watch's arc was silently never
  // enforced — every check fell through to "no valid angles, treat as
  // inside" — until this was caught by reading the actual publish code
  // directly. Reported live 2026-09-04.
  const start = Number(zone.startDeg);
  const end = Number(zone.endDeg);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return false;
  const span = ((end - start) % 360 + 360) % 360;
  const rel = ((bearingDeg - start) % 360 + 360) % 360;
  return rel > span;
}

function sendNtfy(app, topic, title, body) {
  return new Promise((resolve) => {
    if (!topic || !topic.trim()) {
      resolve();
      return;
    }
    // Node's http client validates header VALUES as Latin-1/ASCII and
    // throws synchronously (ERR_INVALID_CHAR) on anything outside that —
    // https.request() itself can throw here, not just emit 'error' async.
    // Caught once already (an em dash in a hardcoded title slipped past
    // review); this try/catch is the backstop for the next mistake like
    // it, so a bad header value degrades to "push silently skipped"
    // rather than an unhandled rejection.
    try {
      const payload = Buffer.from(body, 'utf8');
      const req = https.request(
        {
          hostname: 'ntfy.sh',
          path: `/${encodeURIComponent(topic.trim())}`,
          method: 'POST',
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Content-Length': payload.length,
            // Plain-ASCII only — the real content (any charset) goes in
            // the body instead, which has no such restriction. See the
            // call site for why.
            Title: title,
            Priority: 'urgent',
            Tags: 'warning',
          },
          timeout: 8000,
        },
        (res) => {
          res.resume(); // drain, we don't care about the body
          resolve();
        },
      );
      req.on('error', () => resolve()); // best-effort — never throw
      req.on('timeout', () => req.destroy());
      req.write(payload);
      req.end();
    } catch (err) {
      app.debug(`ntfy push failed: ${err && err.message}`);
      resolve();
    }
  });
}

module.exports = function (app) {
  const plugin = {};
  plugin.id = 'rewind-xcover6-panel';
  plugin.name = 'REWIND Panel — Anchor Watch';
  plugin.description =
    'Background anchor-drag watchdog for the REWIND panel app. Watches ' +
    'navigation.anchor.state/position/watchZone — the same paths the ' +
    'REWIND app itself publishes when you arm the anchor watch — and ' +
    'raises a Signal K notification (and optionally an ntfy.sh push) if ' +
    'the boat leaves the watch zone. Runs inside the server, so it keeps ' +
    'working even with no phone, tablet, or browser connected. Purely a ' +
    'read-only observer: it never drops, raises, or moves an anchor ' +
    'itself, and automatically stays quiet whenever a genuinely different ' +
    'anchor-watch plugin (hoekens-anchor-alarm, etc.) is armed, so the ' +
    'two can never disagree out loud at the same time.';

  plugin.schema = {
    type: 'object',
    properties: {
      ntfyTopic: {
        type: 'string',
        title:
          'ntfy.sh topic to push a drag alert to (leave empty to only ' +
          'raise the Signal K notification — kept in sync automatically ' +
          'from the REWIND app\'s own CFG > Alarmas topic once you\'ve ' +
          'logged in there, but can be set here directly too)',
      },
      checkIntervalSec: {
        type: 'number',
        title: 'How often to check the boat against the watch zone (seconds)',
        default: 15,
        minimum: 5,
      },
      pushMinIntervalSec: {
        type: 'number',
        title: 'Minimum seconds between repeated ntfy pushes while dragging',
        default: 60,
        minimum: 10,
      },
    },
  };

  // ── Live state, entirely mirrored from what the app itself publishes ──
  let unsubscribes = [];
  let checkTimer = null;
  let armed = false;
  let armedAtMs = null;
  let dropPosition = null; // {latitude, longitude}
  let zone = null; // {type, radius, startDeg?, endDeg?}
  // Every DISTINCT foreign source currently reporting itself armed — a
  // Set, not a single flag, so if two different third-party anchor
  // plugins both happen to be armed and one of them disarms, we correctly
  // keep standing down for the other rather than resuming just because
  // the one we happened to be tracking went away.
  const foreignArmedSources = new Set();
  let lastNotifKey = null; // `${state}|${message}` — dedup only, not a lock
  let lastPushAt = 0;
  // GPS glitch filter — mirrors lib/main.dart's own alarmAnchorFilterGlitches
  // (same GLITCH_JUMP_M default as its alarmAnchorGlitchJumpM). A single
  // implausible jump gets ignored rather than trusted as "the boat is now
  // there", the same way the app's own check does.
  let lastGoodPosition = null;
  // A jump beyond GLITCH_JUMP_M that hasn't been corroborated yet — see
  // its use in checkDragging below. {lat, lon, streak} | null.
  let pendingGlitch = null;
  const GRACE_MS = 10000;
  const GLITCH_JUMP_M = 50; // matches SettingsModel.alarmAnchorGlitchJumpM's default
  // Consecutive readings that must agree with EACH OTHER (not with the
  // stale baseline) before a jump past GLITCH_JUMP_M is trusted as real
  // movement rather than a one-off GPS glitch.
  const GLITCH_CONFIRM_STREAK = 2;
  const GLITCH_CONFIRM_TOLERANCE_M = 30;
  const POSITION_MAX_AGE_MS = 60000;

  function sourceLabelOf(update) {
    if (typeof update.$source === 'string') return update.$source;
    if (update.source && typeof update.source.label === 'string') {
      return update.source.label;
    }
    return '';
  }

  // `value: null` for the clear case, NOT a `{state: 'normal', ...}`
  // object — that's the actual Signal K convention for "no active
  // notification here anymore" (same thing hoekens-anchor-alarm's own
  // updateAnchorAlarm does), and some consumers (Signal K's own admin UI
  // included) keep treating a still-present notification object as
  // active regardless of its `state` field. Sending an object instead of
  // null here was very likely why raising the anchor didn't actually
  // silence an already-firing alarm. Reported live 2026-09-04.
  function setNotification(state, message) {
    const key = state === 'normal' ? 'normal' : `${state}|${message}`;
    if (key === lastNotifKey) return;
    lastNotifKey = key;
    const value =
      state === 'normal'
        ? null
        : {
            state,
            method: ['visual', 'sound'],
            message,
            timestamp: new Date().toISOString(),
          };
    app.handleMessage(plugin.id, {
      updates: [
        { values: [{ path: 'notifications.navigation.anchor', value }] },
      ],
    });
  }

  function clearAlarmIfAny(reason) {
    if (lastNotifKey && lastNotifKey !== 'normal') {
      app.debug(`clearing anchor alarm: ${reason}`);
    }
    setNotification('normal', reason);
  }

  function handleAnchorDelta(delta) {
    if (!delta.updates) return;
    for (const update of delta.updates) {
      if (!update.values) continue;
      const label = sourceLabelOf(update);
      const isOwn = label.startsWith(OWN_SOURCE_PREFIX);
      const isForeign = !isOwn && label !== '';
      for (const { path, value } of update.values) {
        if (isOwn) {
          if (path === 'navigation.anchor.state') {
            const nowArmed = value === 'on';
            if (nowArmed !== armed) {
              armed = nowArmed;
              if (armed) {
                armedAtMs = Date.now();
                lastGoodPosition = null; // fresh watch — don't compare against wherever the last one was
                pendingGlitch = null;
              } else {
                clearAlarmIfAny('disarmed');
              }
            }
          } else if (path === 'navigation.anchor.position') {
            const next = value && typeof value === 'object' ? value : null;
            if (
              !next ||
              !dropPosition ||
              next.latitude !== dropPosition.latitude ||
              next.longitude !== dropPosition.longitude
            ) {
              lastGoodPosition = null; // the anchor itself moved — don't compare the boat's next fix against the old spot
              pendingGlitch = null;
            }
            dropPosition = next;
          } else if (path === 'navigation.anchor.watchZone') {
            zone = value && typeof value === 'object' ? value : null;
          }
        } else if (isForeign && path === 'navigation.anchor.state') {
          const wasAnyForeignArmed = foreignArmedSources.size > 0;
          if (value === 'on') {
            foreignArmedSources.add(label);
          } else {
            foreignArmedSources.delete(label);
          }
          const isAnyForeignArmed = foreignArmedSources.size > 0;
          if (isAnyForeignArmed !== wasAnyForeignArmed) {
            if (isAnyForeignArmed) {
              app.setPluginStatus(
                `Standing down — "${label}" has its own anchor watch armed`,
              );
              clearAlarmIfAny('another anchor watch plugin took over');
            } else {
              app.setPluginStatus('Watching for the REWIND app\'s anchor state');
            }
          }
        }
      }
    }
  }

  async function checkDragging() {
    if (!armed || foreignArmedSources.size > 0 || !dropPosition || !zone) {
      return;
    }
    // 10s grace after arming/re-dropping — mirrors lib/main.dart's own
    // anchorGraceOk: the drop itself (or a GPS fix settling in) shouldn't
    // immediately read as garreo.
    if (armedAtMs != null && Date.now() - armedAtMs < GRACE_MS) return;

    // Full node, not just .value — need the timestamp to know how stale
    // this fix actually is. A position too old to trust is treated the
    // same as no position at all for the containment check below — but
    // unlike before, this no longer just silently stops checking: this
    // plugin's whole reason to exist is to keep watching when nothing
    // else is, so losing its own position feed is exactly the failure
    // mode it must not go quiet about. Verified real via external audit,
    // fixed 2026-09-04.
    const posNode = app.getSelfPath('navigation.position');
    const pos = posNode && posNode.value;
    const posAgeMs =
      posNode && posNode.timestamp
        ? Date.now() - Date.parse(posNode.timestamp)
        : null;
    const positionMissing = !pos || pos.latitude == null || pos.longitude == null;
    const positionStale =
      !positionMissing && Number.isFinite(posAgeMs) && posAgeMs > POSITION_MAX_AGE_MS;
    if (positionMissing || positionStale) {
      setNotification(
        'alert',
        positionMissing
          ? 'Vigilante de fondeo: sin posición del barco'
          : `Vigilante de fondeo: posición obsoleta (${Math.round(posAgeMs / 1000)}s)`,
      );
      return;
    }

    // GPS glitch filter — mirrors alarmAnchorFilterGlitches: a single
    // implausible jump from the last position we actually trusted isn't
    // adopted immediately, since a bad GPS fix can produce exactly this.
    // But a genuine sustained drag ALSO produces exactly this on its first
    // reading — rejecting every jump forever without ever re-baselining
    // left the alarm permanently blind to any real drag whose first fix
    // happened to land more than GLITCH_JUMP_M away, which is precisely a
    // severe garreo. Now requires GLITCH_CONFIRM_STREAK consecutive
    // readings that agree with EACH OTHER (not with the stale baseline)
    // before trusting the new position — a real drag keeps producing
    // readings near where the boat actually now is, a one-off glitch
    // doesn't. Verified real via external audit, fixed 2026-09-04.
    if (lastGoodPosition) {
      const jump = bearingDistance(
        lastGoodPosition.latitude,
        lastGoodPosition.longitude,
        pos.latitude,
        pos.longitude,
      ).distanceM;
      if (jump > GLITCH_JUMP_M) {
        if (
          pendingGlitch &&
          bearingDistance(pendingGlitch.lat, pendingGlitch.lon, pos.latitude, pos.longitude)
            .distanceM <= GLITCH_CONFIRM_TOLERANCE_M
        ) {
          pendingGlitch.streak++;
        } else {
          pendingGlitch = { lat: pos.latitude, lon: pos.longitude, streak: 1 };
        }
        if (pendingGlitch.streak < GLITCH_CONFIRM_STREAK) return;
        pendingGlitch = null; // confirmed — trust it from here on
      } else {
        pendingGlitch = null; // agrees with the trusted baseline again
      }
    }
    lastGoodPosition = pos;

    const outside = isOutsideZone(
      dropPosition.latitude,
      dropPosition.longitude,
      pos.latitude,
      pos.longitude,
      zone,
    );
    if (!outside) {
      clearAlarmIfAny('back inside the watch zone');
      return;
    }
    const { distanceM } = bearingDistance(
      dropPosition.latitude,
      dropPosition.longitude,
      pos.latitude,
      pos.longitude,
    );
    const message = `Garreando — ${Math.round(distanceM)} m / ${Math.round(
      Number(zone.radius) || 0,
    )} m`;
    setNotification('emergency', message);

    const cfg = plugin.configuration || {};
    // Clamped, not just schema-hinted — the schema's `minimum` only guides
    // Signal K's own admin form, it doesn't stop a hand-edited config file
    // (or one saved before this schema existed) from carrying a zero or
    // negative value, which would turn this into a near-continuous push
    // loop. Verified real via external audit, fixed 2026-09-04.
    const minIntervalMs = 1000 * Math.max(10, Number(cfg.pushMinIntervalSec) || 60);
    const now = Date.now();
    if (now - lastPushAt >= minIntervalMs) {
      lastPushAt = now;
      // Fixed, plain-ASCII title — NOT interpolating the vessel name (or
      // the em dash) in here, since ntfy.sh's Title goes out as a raw HTTP
      // header and Node's http client rejects non-ASCII header content
      // outright (confirmed live: `https.request` throws
      // ERR_INVALID_CHAR synchronously for a "—" in a header value,
      // silently failing the whole push, every time, since this was
      // inside a Promise executor with no surrounding try/catch of its
      // own). Same reason lib/signalk/ntfy_push.dart's Title is always a
      // plain constant — any real charset content (vessel name included)
      // belongs in the body instead, which has no such restriction.
      const vesselName = app.getSelfPath('name.value') || 'REWIND';
      await sendNtfy(
        app,
        cfg.ntfyTopic,
        'REWIND Panel - Garreando',
        `${vesselName}: ${message}\n(aviso del vigilante de respaldo, sin ningún dispositivo conectado)`,
      );
    }
  }

  plugin.start = function (options) {
    plugin.configuration = options || {};
    armed = false;
    armedAtMs = null;
    dropPosition = null;
    zone = null;
    foreignArmedSources.clear();
    lastNotifKey = null;
    lastPushAt = 0;
    lastGoodPosition = null;
    pendingGlitch = null;

    app.subscriptionmanager.subscribe(
      {
        context: 'vessels.self',
        subscribe: ANCHOR_PATHS.map((path) => ({ path, period: 1000 })),
      },
      unsubscribes,
      (err) => app.error(err),
      handleAnchorDelta,
    );

    // Same clamp as pushMinIntervalSec above — a zero/negative
    // checkIntervalSec would otherwise create a near-continuous setInterval
    // loop.
    const intervalMs =
      1000 * Math.max(5, Number(plugin.configuration.checkIntervalSec) || 15);
    checkTimer = setInterval(() => {
      checkDragging().catch((err) => app.debug(String(err)));
    }, intervalMs);
    checkTimer.unref?.();
    unsubscribes.push(() => clearInterval(checkTimer));

    app.setPluginStatus('Watching for the REWIND app\'s anchor state');
  };

  plugin.stop = function () {
    unsubscribes.forEach((fn) => fn());
    unsubscribes = [];
    checkTimer = null;
    app.setPluginStatus('Stopped');
  };

  return plugin;
};
