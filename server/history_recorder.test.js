const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  createRecorder,
  normalizeOptions,
  globToRegExp,
} = require('./history_recorder');

const T0 = Date.UTC(2026, 8, 14, 10, 0, 0);

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'rewind-history-'));
}

function recorderAt(clock, options = {}, dataDir = tmpDir()) {
  return createRecorder({
    app: { selfContext: 'vessels.urn:mrn:signalk:uuid:self', debug() {} },
    dataDir,
    options: { enabled: true, ...options },
    now: () => clock.t,
  });
}

function delta(ts, values, context = 'vessels.self') {
  return {
    context,
    updates: [{ timestamp: new Date(ts).toISOString(), values }],
  };
}

const at = (ms) => ({ epochMilliseconds: ms });

test('los comodines distinguen un nivel de cualquier profundidad', () => {
  assert.ok(globToRegExp('environment.wind.*').test('environment.wind.speedTrue'));
  assert.ok(!globToRegExp('environment.wind.*').test('environment.wind.a.b'));
  assert.ok(globToRegExp('electrical.batteries.**').test('electrical.batteries.279.capacity.stateOfCharge'));
  assert.ok(globToRegExp('environment.**.temperature').test('environment.fridge_1.temperature'));
});

test('las opciones absurdas se acotan para no machacar la SD', () => {
  const o = normalizeOptions({ flushMinutes: 0, bucketSeconds: -3, retentionHours: 99999 });
  assert.equal(o.flushMinutes, 5);
  assert.equal(o.bucketSeconds, 1);
  assert.equal(o.retentionHours, 336);
  assert.equal(normalizeOptions({ flushMinutes: 60 }).flushMinutes, 15, 'volcado cada 15 min como mucho');
  assert.equal(normalizeOptions({}).flushMinutes, 10);
  assert.equal(normalizeOptions({}).enabled, false, 'apagado salvo que se active');
});

test('media, máximo y último por franja', async () => {
  const clock = { t: T0 + 60000 };
  const r = recorderAt(clock, { bucketSeconds: 15 });
  const p = 'environment.wind.speedApparent';
  r.handleDelta(delta(T0 + 1000, [{ path: p, value: 4 }]));
  r.handleDelta(delta(T0 + 5000, [{ path: p, value: 10 }]));
  r.handleDelta(delta(T0 + 20000, [{ path: p, value: 6 }]));
  const q = (aggregate) =>
    r.getValues({
      from: at(T0),
      to: at(T0 + 60000),
      resolution: 60,
      pathSpecs: [{ path: p, aggregate, parameter: [] }],
    });
  assert.deepEqual((await q('average')).data, [[new Date(T0).toISOString(), 6.66667]]);
  assert.equal((await q('max')).data[0][1], 10);
  assert.equal((await q('min')).data[0][1], 4);
  assert.equal((await q('last')).data[0][1], 6);
});

test('la posición se guarda por campos y se sirve de las dos formas', async () => {
  const clock = { t: T0 + 60000 };
  const r = recorderAt(clock);
  r.handleDelta(
    delta(T0 + 1000, [
      { path: 'navigation.position', value: { latitude: 36.9351512, longitude: 25.4716544 } },
    ]),
  );
  const res = await r.getValues({
    from: at(T0),
    to: at(T0 + 60000),
    resolution: 60,
    pathSpecs: [
      { path: 'navigation.position.latitude', aggregate: 'average', parameter: [] },
      { path: 'navigation.position', aggregate: 'average', parameter: [] },
    ],
  });
  assert.equal(res.data[0][1], 36.9351512, 'doble precisión en latitud');
  assert.deepEqual(res.data[0][2], { latitude: 36.9351512, longitude: 25.4716544 });
  assert.deepEqual(
    await r.getPaths({ from: at(T0), to: at(T0 + 60000) }),
    ['navigation.position', 'navigation.position.latitude', 'navigation.position.longitude'],
  );
});

test('el estado del ancla se graba como texto', async () => {
  const clock = { t: T0 + 120000 };
  const r = recorderAt(clock);
  r.handleDelta(delta(T0 + 1000, [{ path: 'navigation.anchor.state', value: 'off' }]));
  r.handleDelta(delta(T0 + 70000, [{ path: 'navigation.anchor.state', value: 'on' }]));
  const res = await r.getValues({
    from: at(T0),
    to: at(T0 + 120000),
    resolution: 60,
    pathSpecs: [{ path: 'navigation.anchor.state', aggregate: 'first', parameter: [] }],
  });
  assert.deepEqual(res.data.map((row) => row[1]), ['off', 'on']);
});

test('no graba otros barcos ni rutas fuera de la lista', async () => {
  const clock = { t: T0 + 60000 };
  const r = recorderAt(clock);
  r.handleDelta(
    delta(T0, [{ path: 'navigation.speedOverGround', value: 3 }], 'vessels.urn:mrn:imo:mmsi:123'),
  );
  r.handleDelta(delta(T0, [{ path: 'environment.moon.fraction', value: 0.5 }]));
  r.handleDelta(delta(T0, [{ path: 'electrical.switches.venus-0.state', value: 1 }]));
  assert.equal(r.stats().series, 0);
});

test('vuelca por horas y lo recupera al arrancar, aunque cambie la resolución', async () => {
  const dir = tmpDir();
  const clock = { t: T0 + 30 * 60000 };
  const p = 'electrical.batteries.279.voltage';
  const a = recorderAt(clock, { bucketSeconds: 15 }, dir);
  for (let s = 0; s < 120; s += 5) {
    a.handleDelta(delta(T0 + s * 1000, [{ path: p, value: 12 + s / 100 }]));
  }
  const bytes = a.flush();
  assert.ok(bytes > 0);
  assert.equal(fs.readdirSync(path.join(dir, 'hours')).length, 1, 'un fichero por hora');
  assert.equal(a.flush(), 0, 'sin cambios no se vuelve a escribir');

  const b = recorderAt(clock, { bucketSeconds: 60 }, dir);
  assert.equal(b.load(), 1);
  const res = await b.getValues({
    from: at(T0),
    to: at(T0 + 120000),
    resolution: 120,
    pathSpecs: [
      { path: p, aggregate: 'max', parameter: [] },
      { path: p, aggregate: 'min', parameter: [] },
    ],
  });
  assert.equal(res.data.length, 1);
  assert.ok(Math.abs(res.data[0][1] - 13.15) < 1e-4);
  assert.ok(Math.abs(res.data[0][2] - 12) < 1e-4);
});

test('borra de memoria y de disco lo que pasa de la retención', () => {
  const dir = tmpDir();
  const clock = { t: T0 };
  const r = recorderAt(clock, { retentionHours: 2 }, dir);
  r.handleDelta(delta(T0, [{ path: 'navigation.speedOverGround', value: 2 }]));
  r.flush();
  clock.t = T0 + 4 * 3600000;
  r.handleDelta(delta(clock.t, [{ path: 'navigation.speedOverGround', value: 3 }]));
  r.flush();
  const files = fs.readdirSync(path.join(dir, 'hours'));
  assert.equal(files.length, 1, 'solo queda la hora reciente');
  assert.equal(r.stats().series, 1);
});

test('una consulta enorme se limita en filas', async () => {
  const clock = { t: T0 + 72 * 3600000 };
  const r = recorderAt(clock, { bucketSeconds: 15, maxRowsPerQuery: 100 });
  for (let m = 0; m < 72 * 60; m += 1) {
    r.recordValue('navigation.speedOverGround', T0 + m * 60000, 1);
  }
  const res = await r.getValues({
    from: at(T0),
    to: at(T0 + 72 * 3600000),
    resolution: 1,
    pathSpecs: [{ path: 'navigation.speedOverGround', aggregate: 'average', parameter: [] }],
  });
  assert.ok(res.data.length <= 100, `${res.data.length} filas`);
});
