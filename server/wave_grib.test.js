const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const {
  decodeGrib2,
  assembleGrid,
  forecastHoursFor,
  createWaveService,
} = require('./wave_grib');

// GRIB2 real de NOAA GFS-Wave (ciclo 2026-09-19 12z, +3 h) recortado al
// Egeo; valores de referencia sacados con ecCodes.
const FIXTURE = fs.readFileSync(path.join(__dirname, 'fixtures/gfswave_aegean_f003.grib2'));

test('decodifica el GRIB2 de GFS-Wave igual que ecCodes', () => {
  const msgs = decodeGrib2(FIXTURE);
  assert.equal(msgs.length, 3);
  const byNum = Object.fromEntries(msgs.map((m) => [m.number, m]));
  const swh = byNum[3];
  assert.equal(swh.discipline, 10);
  assert.equal(swh.ni, 12);
  assert.equal(swh.nj, 9);
  assert.equal(swh.lat1, 36.5);
  assert.equal(swh.di, 0.25);
  assert.equal(swh.jPositive, true);
  assert.equal(swh.forecastHours, 3);
  assert.equal(swh.refTime, Date.UTC(2026, 8, 19, 12));
  const expect = {
    3: [0.31, 0.32, 0.26, 0.24, 0.36, 0.37, 0.51, 0.64, 0.58, 0.65, 0.84, 0.8, 0.28, 0.36],
    11: [3.21, 3.27, 3.17, 2.98, 2.78, 3.16, 3.22, 3.57, 3.65, 3.89, 3.96, 4.12, 3.27, 3.3],
    10: [36.1, 19.36, 2.41, 4.72, 359.55, 356.19, 353.8, 351.28, 333.55, 349.15, 342.98, 330.04, 43.47, 24.43],
  };
  for (const [num, vals] of Object.entries(expect)) {
    vals.forEach((v, i) => {
      assert.ok(Math.abs(byNum[num].values[i] - v) < 0.006, `${num}[${i}] ${byNum[num].values[i]} ≠ ${v}`);
    });
    // Tierra: sin dato (NaN), no 0.
    const land = Array.from(byNum[num].values).filter(Number.isNaN).length;
    assert.equal(land, 17);
  }
});

test('la rejilla se monta de sur a norte, con null en tierra', () => {
  const msgs = decodeGrib2(FIXTURE);
  const g = assembleGrid([{ time: Date.UTC(2026, 8, 19, 15), messages: msgs }]);
  assert.equal(g.nLat, 9);
  assert.equal(g.nLon, 12);
  assert.equal(g.lat0, 36.5);
  assert.ok(Math.abs(g.lon0 - 23.5) < 1e-5);
  assert.equal(g.height[0], 0.31);
  assert.equal(g.height.filter((v) => v === null).length, 17);
  assert.equal(g.times.length, 1);
});

test('pasos de 3 h, 72 h como poco, más si se piden', () => {
  const c = Date.UTC(2026, 8, 19, 12);
  const h = forecastHoursFor(c, c + 10 * 3600000);
  assert.equal(h[0], 0);
  assert.equal(h[h.length - 1], 72);
  assert.ok(h.every((x) => x % 3 === 0));
  assert.equal(forecastHoursFor(c, c + 100 * 3600000).at(-1), 102);
  assert.equal(forecastHoursFor(c, c + 500 * 3600000).at(-1), 384);
});

test('servicio: último ciclo publicado, descarga una vez y reutiliza', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rewind-waves-'));
  const now = Date.UTC(2026, 8, 19, 16, 30);
  const requested = [];
  const fetchImpl = async (url) => {
    const u = new URL(url);
    requested.push(`${u.searchParams.get('dir')} ${u.searchParams.get('file')}`);
    // El ciclo de las 12z aún no está: se usa el de las 06z.
    if (u.searchParams.get('dir').endsWith('/12/wave/gridded')) {
      return { status: 404, ok: false };
    }
    return {
      status: 200,
      ok: true,
      arrayBuffer: async () => FIXTURE.buffer.slice(FIXTURE.byteOffset, FIXTURE.byteOffset + FIXTURE.length),
    };
  };
  const svc = createWaveService({ dataDir: dir, fetchImpl, now: () => now });
  const box = { south: 36.8, west: 23.8, north: 38.2, east: 26.2 };
  const g = await svc.getWaves(box, now, now + 24 * 3600000);
  assert.equal(g.cycle, Date.UTC(2026, 8, 19, 6));
  assert.match(g.source, /GFS-Wave.*20260919 06z/);
  assert.equal(g.times.length, 25); // 0..72 h cada 3 h
  const count = requested.length;
  // Zona contenida y mismo ciclo: no vuelve a bajar nada.
  await svc.getWaves({ south: 37, west: 24, north: 38, east: 26 }, now, now + 24 * 3600000);
  assert.equal(requested.length, count);
  // Y queda en disco para después de un reinicio.
  assert.equal(fs.readdirSync(path.join(dir, 'waves')).length, 1);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('viento del GFS: u/v a 10 m y racha, decodificados', () => {
  const { PRODUCTS, assembleGrid } = require('./wave_grib');
  const buf = fs.readFileSync(path.join(__dirname, 'fixtures/gfs_wind_aegean_f003.grib2'));
  const msgs = decodeGrib2(buf);
  assert.equal(msgs.length, 3);
  const g = assembleGrid([{ time: 0, messages: msgs }], PRODUCTS.wind);
  assert.equal(g.nLat * g.nLon, 165);
  // Valores de referencia de ecCodes (primeros puntos).
  const ref = { gust: [5.61, 5.81, 2.61, 1.01, 5.21], u: [-2.35, -1.31, -1.01, 0.08, 1.42], v: [-2.7, -2.79, -1.14, -0.52, -2.24] };
  for (const [name, vals] of Object.entries(ref)) {
    const firstRow = g.lat0 === Math.min(msgs[0].lat1, msgs[0].lat2) && msgs[0].jPositive
      ? g[name].slice(0, 5)
      : g[name].slice((g.nLat - 1) * g.nLon, (g.nLat - 1) * g.nLon + 5);
    vals.forEach((v, i) => assert.ok(Math.abs(firstRow[i] - v) < 0.01, `${name}[${i}] ${firstRow[i]} ≠ ${v}`));
  }
});

test('de 1 y 3 h a horas: interpolación lineal y pasos equiespaciados', () => {
  const { toHourly } = require('./wave_grib');
  const g = { nLat: 1, nLon: 1, times: [0, 3600000, 4 * 3600000], u: [0, 3, 6] };
  const h = toHourly(g, ['u']);
  assert.deepEqual(h.times, [0, 1, 2, 3, 4].map((x) => x * 3600000));
  assert.deepEqual(h.u, [0, 3, 4, 5, 6]);
});

test('limitador: nunca más de perMinute peticiones a NOAA por minuto', async () => {
  const { createNoaaService } = require('./wave_grib');
  let t = 0;
  const calls = [];
  const svc = createNoaaService({
    dataDir: fs.mkdtempSync(path.join(os.tmpdir(), 'rewind-noaa-')),
    now: () => t,
    sleep: async (ms) => {
      t += ms;
    },
    perMinute: 5,
    fetchImpl: async () => {
      calls.push(t);
      return { status: 200, ok: true, arrayBuffer: async () => FIXTURE.buffer.slice(FIXTURE.byteOffset, FIXTURE.byteOffset + FIXTURE.length) };
    },
  });
  await svc.getWaves({ south: 37, west: 24, north: 38, east: 25 }, 0, 3600000);
  // 1 sondeo de ciclo + 25 pasos, a 5 por minuto.
  for (let i = 5; i < calls.length; i++) {
    assert.ok(calls[i] - calls[i - 5] >= 60000, `petición ${i}`);
  }
});
