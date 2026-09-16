const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  createConfigStore,
  validateIncoming,
  decideWrite,
  emptyDoc,
} = require('./config_store');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'rewind-config-'));
}

function storeAt(clock, dir = tmpDir()) {
  const announced = [];
  const app = {
    debug() {},
    handleMessage(_id, delta) {
      announced.push(delta.updates[0].values[0]);
    },
  };
  return {
    store: createConfigStore({ app, dataDir: dir, now: () => clock.t }),
    announced,
    dir,
  };
}

const T0 = Date.UTC(2026, 8, 16, 12);

test('sin configuración guardada devuelve un documento vacío, no un error', () => {
  const { store } = storeAt({ t: T0 });
  const doc = store.read();
  assert.equal(doc.revision, 0);
  assert.deepEqual(doc.config, {});
});

test('rechaza lo que no es una configuración', () => {
  assert.ok(validateIncoming(null));
  assert.ok(validateIncoming({}), 'falta config');
  assert.ok(validateIncoming({ config: [] }), 'config no puede ser una lista');
  assert.ok(validateIncoming({ config: {}, baseRevision: 'x' }));
  assert.equal(validateIncoming({ config: { a: 1 }, baseRevision: 2 }), null);
});

test('guarda, numera la revisión y avisa por Signal K', () => {
  const { store, announced } = storeAt({ t: T0 });
  const res = store.save({ config: { a: 1 }, updatedBy: 'XCover' });
  assert.equal(res.status, 200);
  assert.equal(res.body.revision, 1);
  assert.equal(res.body.updatedBy, 'XCover');
  assert.equal(res.body.updatedAt, new Date(T0).toISOString());
  assert.deepEqual(announced, [{ path: 'rewind.config.revision', value: 1 }]);
  assert.deepEqual(store.read().config, { a: 1 });
});

test('la revisión la pone el servidor, no el reloj del dispositivo', () => {
  const clock = { t: T0 };
  const { store } = storeAt(clock);
  store.save({ config: { a: 1 } });
  // Un móvil con la hora atrasada no puede "ganar" por tener fecha anterior.
  clock.t = T0 - 86400000;
  const res = store.save({ config: { a: 2 }, baseRevision: 1 });
  assert.equal(res.body.revision, 2);
  assert.deepEqual(store.read().config, { a: 2 });
});

test('un dispositivo con la configuración vieja no pisa la nueva', () => {
  const { store } = storeAt({ t: T0 });
  store.save({ config: { a: 1 } }); // revisión 1
  store.save({ config: { a: 2 }, baseRevision: 1 }); // revisión 2, otro móvil
  const stale = store.save({ config: { a: 99 }, baseRevision: 1 });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.current.revision, 2);
  assert.deepEqual(
    store.read().config,
    { a: 2 },
    'lo guardado no se toca en un conflicto',
  );
});

test('el primer envío de un dispositivo que aún no ha leído se acepta', () => {
  const { store } = storeAt({ t: T0 });
  store.save({ config: { a: 1 } });
  const res = store.save({ config: { a: 2 } }); // sin baseRevision
  assert.equal(res.status, 200);
  assert.equal(res.body.revision, 2);
});

test('guarda historial y permite volver atrás', () => {
  const { store } = storeAt({ t: T0 });
  store.save({ config: { nombre: 'antes' }, updatedBy: 'tablet' });
  store.save({ config: { nombre: 'después' }, baseRevision: 1 });
  const hist = store.history();
  assert.equal(hist.length, 2);
  assert.equal(hist[0].revision, 2, 'la más reciente primero');
  assert.equal(hist[1].updatedBy, 'tablet');

  const restored = store.restore(1);
  assert.equal(restored.status, 200);
  assert.equal(restored.body.revision, 3, 'restaurar crea una revisión nueva');
  assert.deepEqual(store.read().config, { nombre: 'antes' });
  assert.equal(store.restore(999).status, 404);
});

test('el historial se queda en las últimas 10 versiones', () => {
  const { store, dir } = storeAt({ t: T0 });
  for (let i = 1; i <= 14; i++) {
    store.save({ config: { i }, baseRevision: i - 1 });
  }
  const files = fs.readdirSync(path.join(dir, 'panel-config-history'));
  assert.equal(files.length, 10);
  assert.equal(store.read().config.i, 14);
});

test('una configuración corrupta no se sobrescribe sola', () => {
  const dir = tmpDir();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'panel-config.json'), '{roto');
  const { store } = storeAt({ t: T0 }, dir);
  assert.deepEqual(store.read(), emptyDoc(), 'se presenta como vacía');
  assert.equal(
    fs.readFileSync(path.join(dir, 'panel-config.json'), 'utf8'),
    '{roto',
    'pero el fichero sigue ahí para poder mirarlo',
  );
});

test('una configuración gigante se rechaza', () => {
  const { store } = storeAt({ t: T0 });
  const res = store.save({ config: { basura: 'x'.repeat(600 * 1024) } });
  assert.equal(res.status, 400);
});

test('decideWrite explica por qué rechaza', () => {
  const current = { ...emptyDoc(), revision: 5 };
  assert.equal(decideWrite(current, 5).ok, true);
  assert.equal(decideWrite(current, undefined).ok, true);
  assert.equal(decideWrite(current, 4).ok, false);
  assert.match(decideWrite(current, 4).reason, /otro dispositivo/);
  assert.equal(decideWrite(current, 9).ok, false);
});
