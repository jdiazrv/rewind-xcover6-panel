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
  const start = Number(zone.startAngle);
  const end = Number(zone.endAngle);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return false;
  const span = ((end - start) % 360 + 360) % 360;
  const rel = ((bearingDeg - start) % 360 + 360) % 360;
  return rel > span;
}

function sendNtfy(topic, title, body) {
  return new Promise((resolve) => {
    if (!topic || !topic.trim()) {
      resolve();
      return;
    }
    const payload = Buffer.from(body, 'utf8');
    const req = https.request(
      {
        hostname: 'ntfy.sh',
        path: `/${encodeURIComponent(topic.trim())}`,
        method: 'POST',
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Content-Length': payload.length,
          // ASCII-only header values — vessel names / messages routinely
          // have accents, which some HTTP client fail on in headers (same
          // reason the app's own ntfy push keeps this out of the title
          // where it can, see lib/signalk/ntfy_push.dart).
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
      },
      pushMinIntervalSec: {
        type: 'number',
        title: 'Minimum seconds between repeated ntfy pushes while dragging',
        default: 60,
      },
    },
  };

  // ── Live state, entirely mirrored from what the app itself publishes ──
  let unsubscribes = [];
  let checkTimer = null;
  let armed = false;
  let dropPosition = null; // {latitude, longitude}
  let zone = null; // {type, radius, startAngle?, endAngle?}
  let foreignArmed = false;
  let foreignSourceLabel = null;
  let lastNotifKey = null; // `${state}|${message}` — dedup only, not a lock
  let lastPushAt = 0;

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
              if (!armed) clearAlarmIfAny('disarmed');
            }
          } else if (path === 'navigation.anchor.position') {
            dropPosition =
              value && typeof value === 'object' ? value : null;
          } else if (path === 'navigation.anchor.watchZone') {
            zone = value && typeof value === 'object' ? value : null;
          }
        } else if (isForeign && path === 'navigation.anchor.state') {
          const nowForeignArmed = value === 'on';
          if (nowForeignArmed !== foreignArmed) {
            foreignArmed = nowForeignArmed;
            foreignSourceLabel = nowForeignArmed ? label : null;
            if (foreignArmed) {
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
    if (!armed || foreignArmed || !dropPosition || !zone) return;
    const pos = app.getSelfPath('navigation.position.value');
    if (!pos || pos.latitude == null || pos.longitude == null) return;
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
    const minIntervalMs = 1000 * (Number(cfg.pushMinIntervalSec) || 60);
    const now = Date.now();
    if (now - lastPushAt >= minIntervalMs) {
      lastPushAt = now;
      const vesselName =
        (app.getSelfPath('name.value')) || 'REWIND';
      await sendNtfy(
        cfg.ntfyTopic,
        `${vesselName} — Garreando`,
        `${message}\n(aviso del vigilante de respaldo, sin ningún dispositivo conectado)`,
      );
    }
  }

  plugin.start = function (options) {
    plugin.configuration = options || {};
    armed = false;
    dropPosition = null;
    zone = null;
    foreignArmed = false;
    foreignSourceLabel = null;
    lastNotifKey = null;
    lastPushAt = 0;

    app.subscriptionmanager.subscribe(
      {
        context: 'vessels.self',
        subscribe: ANCHOR_PATHS.map((path) => ({ path, period: 1000 })),
      },
      unsubscribes,
      (err) => app.error(err),
      handleAnchorDelta,
    );

    const intervalMs =
      1000 * (Number(plugin.configuration.checkIntervalSec) || 15);
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
