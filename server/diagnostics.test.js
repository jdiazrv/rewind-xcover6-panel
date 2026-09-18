const test = require('node:test');
const assert = require('node:assert/strict');
const { collectDiagnostics, redact } = require('./diagnostics');

// Un servidor Signal K de mentira con la misma forma que el de REWIND
// (signalk-server 2.31.1): lo que no esté debe llegar como null, no romper.
function fakeApp(overrides = {}) {
  return {
    config: { version: '2.31.1', vesselName: 'REWIND' },
    getDataDirPath: () => '/home/signalk/.signalk/plugin-config-data/x',
    lastServerEvents: {
      SERVERSTATISTICS: {
        data: {
          deltaRate: 42.4,
          numberOfAvailablePaths: 812,
          wsClients: 3,
          providerStatistics: {
            N2k: { deltaRate: 30.2, deltaCount: 1000 },
            GPS: { deltaRate: 5.1, deltaCount: 200 },
          },
          uptime: 3600,
        },
      },
    },
    // Como en signalk-server 2.31.1: `type` es la gravedad y `statusType`
    // de quién es. Y app.plugins llega vacío en la copia del plugin.
    plugins: [],
    getProviderStatus: () => [
      { id: 'good', statusType: 'plugin', type: 'status', message: 'Funcionando' },
      {
        id: 'broken',
        statusType: 'plugin',
        type: 'error',
        message: 'Fallo al llamar a https://x.io/api?key=SECRETO123',
      },
      { id: 'N2k', statusType: 'provider', type: 'status', message: 'Conectado' },
    ],
    logging: {
      getLog: () => [
        { ts: 'Sep 18 08:44:01', row: 'arranque' },
        { ts: 'Sep 18 08:44:02', row: 'Error: token=abcdef123456', isError: true },
        {
          ts: 'Sep 18 08:44:03',
          row: '(node:388091) DeprecationWarning: [x] setProviderStatus() is deprecated',
          isError: true,
        },
        // Un salto de línea suelto por stderr: no es un error sin texto.
        { ts: 'Sep 18 08:44:04', row: '   ', isError: true },
      ],
    },
    ...overrides,
  };
}

const deps = {
  now: () => Date.parse('2026-09-18T08:00:00Z'),
  process: {
    uptime: () => 7200,
    version: 'v22.1.0',
    memoryUsage: () => ({ rss: 250e6, heapUsed: 120e6 }),
  },
  os: {
    cpus: () => [{ model: 'Cortex-A72' }, {}, {}, {}],
    loadavg: () => [2, 1.5, 1],
    totalmem: () => 4e9,
    freemem: () => 1e9,
    uptime: () => 86400,
    hostname: () => 'lysmarine',
    platform: () => 'linux',
    arch: () => 'arm64',
    release: () => '6.6.51',
  },
  fs: {
    readdirSync: () => ['good.json', 'broken.json', 'off.json', 'notas.txt'],
    readFileSync: (f) =>
      String(f).endsWith('off.json')
        ? '{"enabled": false}'
        : String(f).endsWith('.json')
        ? '{"enabled": true}'
        : '61234\n',
    statfsSync: () => ({ blocks: 1000, bsize: 32e6, bavail: 250 }),
  },
};

test('servidor, máquina y último reinicio', () => {
  const d = collectDiagnostics(fakeApp(), deps);
  assert.equal(d.server.version, '2.31.1');
  assert.equal(d.server.nodeVersion, 'v22.1.0');
  assert.equal(d.server.startedAt, '2026-09-18T06:00:00.000Z');
  assert.equal(d.host.bootedAt, '2026-09-17T08:00:00.000Z');
  assert.equal(d.host.cpuTempC, 61.2);
  assert.equal(d.host.loadPct, 50); // 2 de carga en 4 núcleos
  assert.equal(d.host.memUsedPct, 75);
  assert.equal(d.host.disk.usedPct, 75);
});

test('tráfico, conexiones ordenadas por velocidad', () => {
  const d = collectDiagnostics(fakeApp(), deps);
  assert.equal(d.traffic.deltaRate, 42.4);
  assert.equal(d.traffic.paths, 812);
  assert.equal(d.traffic.wsClients, 3);
  assert.deepEqual(d.traffic.providers.map((p) => p.id), ['N2k', 'GPS']);
});

test('plugins: los que fallan primero y los apagados al final', () => {
  const d = collectDiagnostics(fakeApp(), deps);
  assert.equal(d.plugins.total, 3);
  assert.equal(d.plugins.enabled, 2);
  assert.equal(d.plugins.withErrors, 1);
  assert.deepEqual(d.plugins.list.map((p) => p.id), ['broken', 'good', 'off']);
  // Las conexiones no se cuelan entre los plugins.
  assert.deepEqual(d.connections.map((c) => c.id), ['N2k']);
});

test('las claves del log y de los estados se tapan', () => {
  const d = collectDiagnostics(fakeApp(), deps);
  const all = JSON.stringify(d);
  assert.ok(!all.includes('SECRETO123'));
  assert.ok(!all.includes('abcdef123456'));
  assert.equal(d.log.lines[1].text, 'Error: token=***');
});

test('los avisos de Node no cuentan como errores del log', () => {
  const d = collectDiagnostics(fakeApp(), deps);
  assert.equal(d.log.errors, 1);
  assert.equal(d.log.warnings, 1);
  assert.equal(d.log.lines.length, 3);
  assert.equal(d.log.lines[2].warning, true);
  assert.equal(d.log.lines[2].error, false);
});

test('redact: tipos habituales de secreto', () => {
  assert.equal(redact('GET /x?apikey=abc123&y=1'), 'GET /x?apikey=***&y=1');
  assert.equal(redact('Authorization: Bearer eyJhbGciOiJIUzI1'), 'Authorization: Bearer ***');
  assert.equal(redact('http://user:hunter2@host/'), 'http://user:***@host/');
  assert.equal(redact('password: "qwerty"'), 'password: "***"');
  assert.equal(redact('nada que tapar'), 'nada que tapar');
});

test('un servidor sin las piezas internas no rompe nada', () => {
  const d = collectDiagnostics({ config: {} }, deps);
  assert.equal(d.server.version, null);
  assert.equal(d.traffic.deltaRate, null);
  assert.equal(d.plugins.total, 0);
  assert.deepEqual(d.log.lines, []);
});
