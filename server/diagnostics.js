'use strict';

const path = require('path');

/**
 * Diagnóstico completo del servidor Signal K, para CFG > Diagnóstico.
 *
 * Casi todo esto —el log, la lista de plugins, la velocidad de datos, el
 * último reinicio— Signal K solo lo enseña a un administrador, y la app no
 * debe llevar credenciales de administrador. Pero este plugin corre DENTRO
 * del servidor y lo ve todo, así que lo junta aquí y lo sirve con el mismo
 * nivel de lectura que el resto de /plugins/rewind-xcover6-panel.
 *
 * Varias de las piezas (lastServerEvents, logging, getProviderStatus) son
 * internas de signalk-server, no de su API de plugins: se leen todas con
 * cuidado para que una versión distinta del servidor no rompa nada, y lo que
 * no esté llega como null en vez de tumbar la respuesta.
 */

// Lo que parezca una clave dentro del log se tapa antes de servirlo: esta
// ruta la puede leer cualquiera con acceso de lectura al barco, y los plugins
// escriben a veces URLs con su clave de API o el topic de ntfy.
const SECRET_PATTERNS = [
  // ?token=…, &apikey=…, password: …, "secret":"…"
  /((?:token|api[_-]?key|apikey|key|password|passwd|secret|auth|topic)["']?\s*[=:]\s*["']?)([^\s"'&,;}]+)/gi,
  // Authorization: Bearer …
  /(bearer\s+)([A-Za-z0-9._~+/=-]{8,})/gi,
  // Usuario y contraseña dentro de una URL: http://user:pass@host
  /(\/\/[^:/\s@]+:)([^@/\s]+)(@)/g,
];

function redact(text) {
  if (typeof text !== 'string') return text;
  let out = text;
  out = out.replace(SECRET_PATTERNS[0], (_, pre) => `${pre}***`);
  out = out.replace(SECRET_PATTERNS[1], (_, pre) => `${pre}***`);
  out = out.replace(SECRET_PATTERNS[2], (_, pre, _p, at) => `${pre}***${at}`);
  return out;
}

function safe(fn, fallback = null) {
  try {
    const v = fn();
    return v === undefined ? fallback : v;
  } catch (_) {
    return fallback;
  }
}

const round = (n, d = 1) =>
  typeof n === 'number' && Number.isFinite(n)
    ? Math.round(n * 10 ** d) / 10 ** d
    : null;

function cpuTemperatureC(fs) {
  // Raspberry Pi y la mayoría de Linux: miligrados en la primera zona.
  const raw = safe(() =>
    fs.readFileSync('/sys/class/thermal/thermal_zone0/temp', 'utf8'),
  );
  const milli = raw == null ? NaN : Number(String(raw).trim());
  return Number.isFinite(milli) ? round(milli / 1000, 1) : null;
}

function diskUsage(fs, p) {
  if (typeof fs.statfsSync !== 'function') return null;
  return safe(() => {
    const s = fs.statfsSync(p);
    const total = s.blocks * s.bsize;
    const free = s.bavail * s.bsize;
    if (!total) return null;
    return {
      path: p,
      totalGb: round(total / 1e9, 1),
      freeGb: round(free / 1e9, 1),
      usedPct: round(((total - free) / total) * 100, 0),
    };
  });
}

/**
 * @param app  el objeto app de Signal K
 * @param deps { os, fs, process, now } — inyectables para los tests
 */
function collectDiagnostics(app, deps = {}) {
  const os = deps.os || require('os');
  const fs = deps.fs || require('fs');
  const proc = deps.process || process;
  const now = deps.now ? deps.now() : Date.now();

  // ── Servidor
  const uptimeSec = safe(() => proc.uptime());
  const mem = safe(() => proc.memoryUsage(), {});
  const server = {
    version: safe(() => app.config.version),
    nodeVersion: safe(() => proc.version),
    uptimeSec: round(uptimeSec, 0),
    startedAt:
      uptimeSec == null ? null : new Date(now - uptimeSec * 1000).toISOString(),
    rssMb: round((mem.rss || 0) / 1e6, 0),
    heapUsedMb: round((mem.heapUsed || 0) / 1e6, 0),
    vesselName: safe(() => app.config.vesselName),
  };

  // ── Máquina
  const cpus = safe(() => os.cpus(), []) || [];
  const load = safe(() => os.loadavg(), [null, null, null]) || [];
  const memTotal = safe(() => os.totalmem());
  const memFree = safe(() => os.freemem());
  const hostUptime = safe(() => os.uptime());
  const dataDir = safe(() =>
    typeof app.getDataDirPath === 'function' ? app.getDataDirPath() : null,
  );
  const rootDisk = diskUsage(fs, '/');
  const dataDisk = dataDir ? diskUsage(fs, dataDir) : null;
  const host = {
    hostname: safe(() => os.hostname()),
    platform: safe(() => os.platform()),
    arch: safe(() => os.arch()),
    kernel: safe(() => os.release()),
    uptimeSec: round(hostUptime, 0),
    bootedAt:
      hostUptime == null
        ? null
        : new Date(now - hostUptime * 1000).toISOString(),
    cpuCount: cpus.length || null,
    cpuModel: cpus.length ? cpus[0].model : null,
    load1: round(load[0], 2),
    load5: round(load[1], 2),
    load15: round(load[2], 2),
    // Carga del último minuto como % de los núcleos: 100 % = todos ocupados.
    loadPct: cpus.length ? round((load[0] / cpus.length) * 100, 0) : null,
    memTotalMb: round((memTotal || 0) / 1e6, 0),
    memUsedPct:
      memTotal && memFree != null
        ? round(((memTotal - memFree) / memTotal) * 100, 0)
        : null,
    cpuTempC: cpuTemperatureC(fs),
    disk: rootDisk,
    // Solo si los datos de Signal K están en otro disco (una SD aparte).
    dataDisk:
      dataDisk && rootDisk && dataDisk.totalGb !== rootDisk.totalGb
        ? dataDisk
        : null,
  };

  // ── Tráfico de datos (la estadística que Signal K refresca cada 5 s)
  const stats = safe(() => app.lastServerEvents.SERVERSTATISTICS.data, {}) || {};
  const providerStats = stats.providerStatistics || {};
  const traffic = {
    deltaRate: round(stats.deltaRate, 1),
    paths: stats.numberOfAvailablePaths ?? null,
    wsClients: stats.wsClients ?? null,
    providers: Object.entries(providerStats)
      .map(([id, s]) => ({
        id,
        deltaRate: round(s && s.deltaRate, 1),
        deltaCount: s && s.deltaCount != null ? s.deltaCount : null,
      }))
      .sort((a, b) => (b.deltaRate || 0) - (a.deltaRate || 0)),
  };

  // ── Estado de conexiones y plugins (lo que enseña el panel de Signal K)
  // Cada entrada de getProviderStatus() trae DOS campos que se confunden:
  // `type` es la gravedad (status | warning | error) y `statusType` es de
  // quién es (plugin | provider). Comprobado en signalk-server 2.31.1.
  const statuses =
    safe(() =>
      typeof app.getProviderStatus === 'function'
        ? app.getProviderStatus()
        : Object.values(app.providerStatus || {}),
    ) || [];
  const statusById = {};
  for (const st of statuses) if (st && st.id) statusById[st.id] = st;
  const describe = (st) =>
    st
      ? {
          statusType: st.type || null, // status | warning | error
          message: redact(st.message || null),
          at: st.timeStamp || null,
          lastError: redact(st.lastError || null),
          lastErrorAt: st.lastErrorTimeStamp || null,
        }
      : { statusType: null, message: null, at: null, lastError: null, lastErrorAt: null };

  // Qué plugins hay y cuáles están activados. app.plugins NO sirve aquí: el
  // app que recibe un plugin es una copia superficial hecha al cargarlo, y
  // su lista de plugins llega vacía (visto en REWIND). Se juntan dos fuentes
  // que sí son fiables: los plugins que están corriendo (tienen estado) y la
  // carpeta plugin-config-data, donde Signal K guarda de cada uno si está
  // activado.
  const running = new Set(
    statuses
      .filter((st) => st && st.id && st.statusType === 'plugin')
      .map((st) => st.id),
  );
  const configured = {};
  const configDir = safe(() => {
    const own =
      typeof app.getDataDirPath === 'function' ? app.getDataDirPath() : null;
    return own ? path.dirname(own) : null;
  });
  if (configDir) {
    for (const f of safe(() => fs.readdirSync(configDir), []) || []) {
      if (!f.endsWith('.json')) continue;
      const cfg = safe(() => JSON.parse(fs.readFileSync(path.join(configDir, f), 'utf8')));
      if (cfg && typeof cfg === 'object') {
        configured[f.slice(0, -5)] = cfg.enabled === true;
      }
    }
  }
  const fromApp = safe(() => app.plugins, []) || [];
  const names = {};
  for (const p of fromApp) if (p && p.id) names[p.id] = p.name || p.id;
  const ids = new Set([...running, ...Object.keys(configured), ...fromApp.map((p) => p && p.id).filter(Boolean)]);
  const pluginList = [...ids].map((id) => ({
    id,
    name: names[id] || id,
    // Corriendo = activado, aunque no tenga fichero (activado por defecto).
    enabled: running.has(id) || configured[id] === true,
    ...describe(statusById[id]),
  }));
  const connections = statuses
    .filter((st) => st && st.id && st.statusType !== 'plugin' && !ids.has(st.id))
    .map((st) => ({ id: st.id, ...describe(st) }));

  const plugins = {
    total: pluginList.length,
    enabled: pluginList.filter((p) => p.enabled).length,
    withErrors: pluginList.filter((p) => p.enabled && p.statusType === 'error')
      .length,
    list: pluginList.sort((a, b) => {
      const rank = (p) =>
        !p.enabled ? 3 : p.statusType === 'error' ? 0 : p.statusType === 'warning' ? 1 : 2;
      return rank(a) - rank(b) || String(a.name).localeCompare(String(b.name));
    }),
  };

  // ── Log: las últimas líneas que guarda Signal K (100), las de error marcadas
  // Signal K marca como error todo lo que sale por stderr, y ahí Node escribe
  // también sus avisos (DeprecationWarning de plugins viejos): en REWIND eran
  // 7 "errores" de 7 y ninguno era un fallo. Se separan.
  const rawLog = safe(() => app.logging.getLog(), []) || [];
  // Las líneas vacías (un salto de línea suelto por stderr) salían como un
  // "error" sin texto.
  const nonEmpty = rawLog.filter((l) => l && l.row != null && String(l.row).trim() !== '');
  const lines = nonEmpty.map((l) => {
    const text = redact(l && l.row != null ? String(l.row).trimEnd() : '');
    const stderr = !!(l && l.isError);
    const warning =
      stderr && /DeprecationWarning|ExperimentalWarning|\bWarning:|\(node:\d+\) \[?\w*Warning/.test(text);
    return {
      ts: l && l.ts ? String(l.ts) : null,
      error: stderr && !warning,
      warning,
      text,
    };
  });
  const log = {
    available: rawLog.length > 0 || safe(() => typeof app.logging.getLog === 'function', false),
    errors: lines.filter((l) => l.error).length,
    warnings: lines.filter((l) => l.warning).length,
    lines,
  };

  return {
    generatedAt: new Date(now).toISOString(),
    server,
    host,
    traffic,
    plugins,
    connections,
    log,
  };
}

module.exports = { collectDiagnostics, redact };
