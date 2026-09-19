const test = require('node:test');
const assert = require('node:assert/strict');

const { bearingDistance, isOutsideZone, acceptsRevision } =
  require('./index')._test;

test('circle and sector containment match the app rules', () => {
  const insideNorth = { latitude: 37.0001, longitude: 23 };
  assert.equal(
    isOutsideZone(37, 23, insideNorth.latitude, insideNorth.longitude, {
      type: 'circle', radius: 20,
    }),
    false,
  );
  assert.equal(
    isOutsideZone(37, 23, insideNorth.latitude, insideNorth.longitude, {
      type: 'sector', radius: 20, startDeg: 90, endDeg: 270,
    }),
    true,
  );
});

test('distance is finite and symmetric', () => {
  const ab = bearingDistance(37, 23, 37.01, 23.02);
  const ba = bearingDistance(37.01, 23.02, 37, 23);
  assert.ok(Number.isFinite(ab.distanceM));
  assert.ok(Math.abs(ab.distanceM - ba.distanceM) < 0.001);
});

test('older device revisions cannot overwrite the latest anchor state', () => {
  assert.equal(acceptsRevision(2000, 1999), false);
  assert.equal(acceptsRevision(2000, 2000), true);
  assert.equal(acceptsRevision(2000, 2001), true);
  assert.equal(acceptsRevision(2000, Number.NaN), false);
});

test('el histórico se vuelca a disco al terminar el proceso (Signal K no llama a stop)', () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const { EventEmitter } = require('events');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rewind-hist-'));
  const app = {
    selfContext: 'vessels.self',
    signalk: new EventEmitter(),
    subscriptionmanager: { subscribe() {} },
    getDataDirPath: () => dir,
    getSelfPath: () => undefined,
    handleMessage() {},
    setPluginStatus() {},
    setPluginError() {},
    debug() {},
    error() {},
  };
  const plugin = require('./index')(app);
  const before = {
    exit: process.listeners('exit').slice(),
    term: process.listeners('SIGTERM').slice(),
  };
  plugin.start({
    history: {
      enabled: true,
      includePaths: ['navigation.speedOverGround'],
      registerAsHistoryProvider: false,
      flushMinutes: 60, // config vieja: se acota a 15
    },
  });
  try {
    const exitFlush = process.listeners('exit').find((l) => !before.exit.includes(l));
    assert.ok(exitFlush, 'escucha la salida del proceso');
    assert.ok(
      process.listeners('SIGTERM').some((l) => !before.term.includes(l)),
      'escucha SIGTERM (systemctl restart)',
    );
    app.signalk.emit('delta', {
      context: 'vessels.self',
      updates: [{ timestamp: new Date().toISOString(), values: [{ path: 'navigation.speedOverGround', value: 3.1 }] }],
    });
    const hoursDir = path.join(dir, 'hours');
    const files = () => (fs.existsSync(hoursDir) ? fs.readdirSync(hoursDir) : []);
    assert.equal(files().filter((f) => f.endsWith('.json.gz')).length, 0, 'aún en memoria');
    exitFlush();
    assert.equal(files().filter((f) => f.endsWith('.json.gz')).length, 1, 'volcado al salir');
  } finally {
    plugin.stop();
  }
  assert.deepEqual(process.listeners('exit'), before.exit, 'al parar deja de escuchar');
  assert.deepEqual(process.listeners('SIGTERM'), before.term);
  fs.rmSync(dir, { recursive: true, force: true });
});
