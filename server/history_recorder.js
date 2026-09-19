/*
 * REWIND Panel — grabador de histórico ligero para servidores en tarjeta SD.
 *
 * Por qué existe: en DRAGUEUR y QUINTO REAL (Raspberry con SD, sin SSD) el
 * histórico de KIP y QuestDB escribía 1-4 GB al día en la tarjeta para
 * guardar muy pocos datos, y aun así faltaban posición, rumbo y viento real
 * (medido 2026-09-14). Este grabador guarda todo lo que la app REWIND
 * presenta con histórico, en memoria, y lo baja a disco por horas, comprimido
 * y de golpe: una escritura cada flushMinutes, nunca una por muestra.
 *
 * Modelo de datos, por serie (una ruta Signal K):
 *   - numérica: cubos de bucketSeconds con suma, cuenta, mínimo, máximo y
 *     último valor. Así se pueden servir media, máximo (rachas) y último
 *     (ángulos) sin guardar cada muestra.
 *   - texto (navigation.anchor.state…): primer y último valor por cubo.
 * Los objetos con campos numéricos (navigation.position, navigation.attitude)
 * se guardan como sus hijos (navigation.position.latitude…) y se sirven
 * también como objeto bajo la ruta padre.
 *
 * Se registra como proveedor del History API de Signal K, así que la app lo
 * lee con la misma consulta /signalk/v2/api/history/values que usaba con KIP.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const HOUR_MS = 3600000;
const FILE_VERSION = 1;

const DEFAULT_INCLUDE = [
  'navigation.position',
  'navigation.speedOverGround',
  'navigation.speedThroughWater',
  'navigation.headingTrue',
  'navigation.headingMagnetic',
  'navigation.courseOverGroundTrue',
  'navigation.magneticVariation',
  'navigation.attitude',
  'navigation.rateOfTurn',
  'navigation.anchor.state',
  'navigation.state',
  'environment.wind.*',
  'environment.depth.*',
  'environment.water.*',
  'environment.outside.*',
  'environment.inside.**',
  'environment.interior.*',
  'environment.**.temperature',
  'environment.**.humidity',
  'environment.**.relativeHumidity',
  'environment.**.pressure',
  'environment.rpi.**',
  'electrical.batteries.**',
  'electrical.solar.**',
  'electrical.chargers.**',
  'electrical.inverters.**',
  'electrical.venus.**',
  'electrical.ac.**',
  'tanks.**',
  'propulsion.**',
  'steering.rudderAngle',
];

const DEFAULT_EXCLUDE = [
  'electrical.switches.**',
  'environment.moon.**',
  'environment.sun.**',
  '**.name',
];

const DEFAULT_TEXT_PATHS = ['navigation.anchor.state', 'navigation.state'];

const DEFAULTS = {
  enabled: false,
  registerAsHistoryProvider: true,
  retentionHours: 72,
  bucketSeconds: 15,
  // Cada 10 min como mucho se pierde si el barco se queda sin corriente de
  // golpe. Antes 60: en DRAGUEUR se perdieron casi 3 h el 2026-09-19 con
  // varios reinicios seguidos de Signal K (que no avisa a los plugins al
  // pararse). Una escritura comprimida cada 10 min sigue siendo nada para
  // la SD comparado con KIP/QuestDB.
  flushMinutes: 10,
  maxSeries: 400,
  maxRowsPerQuery: 2000,
  includePaths: DEFAULT_INCLUDE,
  excludePaths: DEFAULT_EXCLUDE,
  textPaths: DEFAULT_TEXT_PATHS,
};

function clampNumber(value, fallback, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function listOption(value, fallback) {
  if (Array.isArray(value)) {
    const clean = value.map((v) => String(v).trim()).filter(Boolean);
    return clean.length ? clean : fallback;
  }
  if (typeof value === 'string' && value.trim()) {
    return value
      .split(/[\n,]/)
      .map((v) => v.trim())
      .filter(Boolean);
  }
  return fallback;
}

/** Opciones saneadas: un valor raro en el fichero de config nunca debe
 *  convertir el grabador en algo que machaque la SD (flush cada segundo) o
 *  se coma la RAM (retención de meses). */
function normalizeOptions(raw) {
  const o = raw || {};
  return {
    enabled: o.enabled === true,
    registerAsHistoryProvider: o.registerAsHistoryProvider !== false,
    retentionHours: clampNumber(o.retentionHours, DEFAULTS.retentionHours, 1, 24 * 14),
    bucketSeconds: clampNumber(o.bucketSeconds, DEFAULTS.bucketSeconds, 1, 600),
    // Tope de 15 min aunque la config guardada diga más (las apps hasta la
    // 1.4.254 guardaban 60 por defecto).
    flushMinutes: clampNumber(o.flushMinutes, DEFAULTS.flushMinutes, 5, 15),
    maxSeries: clampNumber(o.maxSeries, DEFAULTS.maxSeries, 10, 5000),
    maxRowsPerQuery: clampNumber(o.maxRowsPerQuery, DEFAULTS.maxRowsPerQuery, 50, 100000),
    includePaths: listOption(o.includePaths, DEFAULTS.includePaths),
    excludePaths: listOption(o.excludePaths, DEFAULTS.excludePaths),
    textPaths: listOption(o.textPaths, DEFAULTS.textPaths),
  };
}

/** `*` = un segmento de ruta, `**` = cualquier número de segmentos. */
function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const ch = glob[i];
    if (ch === '*') {
      if (glob[i + 1] === '*') {
        re += '.*';
        i++;
      } else {
        re += '[^.]+';
      }
    } else if ('\\^$+?.()|{}[]'.includes(ch)) {
      re += `\\${ch}`;
    } else {
      re += ch;
    }
  }
  return new RegExp(`^${re}$`);
}

function makeMatcher(patterns) {
  const regs = patterns.map(globToRegExp);
  return (p) => regs.some((r) => r.test(p));
}

// Lat/lon necesitan doble precisión (Float32 ya da errores de metros); el
// resto va en Float32 para que 72 h de cientos de series quepan holgadas
// incluso en la Pi 5 de 4 GB de DRAGUEUR.
function isPrecisePath(p) {
  return /(^|\.)(latitude|longitude)$/.test(p);
}

function roundFor(p, v) {
  const f = isPrecisePath(p) ? 1e7 : 1e5;
  return Math.round(v * f) / f;
}

class NumericChunk {
  constructor(size, precise) {
    const F = precise ? Float64Array : Float32Array;
    this.count = new Uint16Array(size);
    this.sum = new Float64Array(size);
    this.min = new F(size);
    this.max = new F(size);
    this.last = new F(size);
  }
}

function createRecorder({ app, dataDir, options, now = () => Date.now() }) {
  const opts = normalizeOptions(options);
  const bucketMs = opts.bucketSeconds * 1000;
  const bucketsPerHour = Math.ceil(HOUR_MS / bucketMs);
  const retentionMs = opts.retentionHours * HOUR_MS;
  const included = makeMatcher(opts.includePaths);
  const excluded = makeMatcher(opts.excludePaths);
  const isText = makeMatcher(opts.textPaths);
  const hoursDir = path.join(dataDir, 'hours');

  // path -> { kind: 'num'|'text', hours: Map<hourMs, chunk> }
  const series = new Map();
  const matchCache = new Map();
  const dirtyHours = new Set();
  let refusedSeries = 0;
  let lastFlushAt = null;
  let lastFlushBytes = 0;
  let lastError = null;

  const log = (msg) => app && app.debug && app.debug(`[histórico] ${msg}`);

  function wanted(p) {
    let hit = matchCache.get(p);
    if (hit === undefined) {
      hit = included(p) && !excluded(p);
      matchCache.set(p, hit);
    }
    return hit;
  }

  function seriesFor(p, kind) {
    let s = series.get(p);
    if (s) return s.kind === kind ? s : null;
    if (series.size >= opts.maxSeries) {
      refusedSeries++;
      return null;
    }
    s = { kind, hours: new Map() };
    series.set(p, s);
    return s;
  }

  function slotOf(ts) {
    const hour = Math.floor(ts / HOUR_MS) * HOUR_MS;
    return { hour, idx: Math.min(bucketsPerHour - 1, Math.floor((ts - hour) / bucketMs)) };
  }

  /** Funde un cubo (o una muestra suelta: count 1, todo igual a v) en la
   *  serie. Lo usan tanto las muestras en vivo como la recarga desde disco,
   *  que así se adapta sola si bucketSeconds cambió entre reinicios. */
  function mergeNumeric(p, ts, sum, count, min, max, last) {
    const s = seriesFor(p, 'num');
    if (!s) return;
    const { hour, idx } = slotOf(ts);
    let chunk = s.hours.get(hour);
    if (!chunk) {
      chunk = new NumericChunk(bucketsPerHour, isPrecisePath(p));
      s.hours.set(hour, chunk);
    }
    if (chunk.count[idx] === 0) {
      chunk.sum[idx] = sum;
      chunk.min[idx] = min;
      chunk.max[idx] = max;
    } else {
      chunk.sum[idx] += sum;
      if (min < chunk.min[idx]) chunk.min[idx] = min;
      if (max > chunk.max[idx]) chunk.max[idx] = max;
    }
    chunk.count[idx] = Math.min(65535, chunk.count[idx] + count);
    chunk.last[idx] = last;
    dirtyHours.add(hour);
  }

  function mergeText(p, ts, first, last) {
    const s = seriesFor(p, 'text');
    if (!s) return;
    const { hour, idx } = slotOf(ts);
    let chunk = s.hours.get(hour);
    if (!chunk) {
      chunk = new Map();
      s.hours.set(hour, chunk);
    }
    const cur = chunk.get(idx);
    if (cur) cur[1] = last;
    else chunk.set(idx, [first, last]);
    dirtyHours.add(hour);
  }

  function recordValue(p, ts, value) {
    if (value === null || value === undefined) return;
    if (typeof value === 'number') {
      if (Number.isFinite(value) && wanted(p)) {
        mergeNumeric(p, ts, value, 1, value, value, value);
      }
      return;
    }
    if (typeof value === 'string') {
      if (wanted(p) && isText(p)) mergeText(p, ts, value, value);
      return;
    }
    if (typeof value === 'object' && !Array.isArray(value) && wanted(p)) {
      // navigation.position, navigation.attitude…: se guardan sus campos
      // numéricos directos como series hijas.
      for (const [k, v] of Object.entries(value)) {
        if (typeof v === 'number' && Number.isFinite(v)) {
          const child = `${p}.${k}`;
          if (!excluded(child)) mergeNumeric(child, ts, v, 1, v, v, v);
        }
      }
    }
  }

  function handleDelta(delta) {
    if (!delta || !Array.isArray(delta.updates)) return;
    const ctx = delta.context;
    if (ctx && ctx !== 'vessels.self' && app && ctx !== app.selfContext) return;
    const t = now();
    for (const update of delta.updates) {
      if (!update || !Array.isArray(update.values)) continue;
      let ts = Date.parse(update.timestamp);
      // Sin marca de tiempo, o una absurda (reloj del GPS sin fijar, datos
      // reenviados de hace días): cuenta como ahora.
      if (!Number.isFinite(ts) || ts > t + 5 * 60000 || ts < t - HOUR_MS) ts = t;
      for (const entry of update.values) {
        if (entry && typeof entry.path === 'string' && entry.path) {
          recordValue(entry.path, ts, entry.value);
        }
      }
    }
  }

  // ── Persistencia ────────────────────────────────────────────────────────

  function hourFile(hour) {
    return path.join(hoursDir, `${hour}.json.gz`);
  }

  function serializeHour(hour) {
    const out = { v: FILE_VERSION, hour, bucketSeconds: opts.bucketSeconds, series: {} };
    for (const [p, s] of series) {
      const chunk = s.hours.get(hour);
      if (!chunk) continue;
      if (s.kind === 'num') {
        const i = [], c = [], sm = [], mn = [], mx = [], l = [];
        for (let k = 0; k < chunk.count.length; k++) {
          if (chunk.count[k] === 0) continue;
          i.push(k);
          c.push(chunk.count[k]);
          sm.push(roundFor(p, chunk.sum[k]));
          mn.push(roundFor(p, chunk.min[k]));
          mx.push(roundFor(p, chunk.max[k]));
          l.push(roundFor(p, chunk.last[k]));
        }
        if (i.length) out.series[p] = { k: 'n', i, c, s: sm, mn, mx, l };
      } else {
        const i = [], f = [], l = [];
        for (const [k, [first, last]] of [...chunk.entries()].sort((a, b) => a[0] - b[0])) {
          i.push(k);
          f.push(first);
          l.push(last);
        }
        if (i.length) out.series[p] = { k: 't', i, f, l };
      }
    }
    return out;
  }

  function loadHourObject(obj) {
    if (!obj || obj.v !== FILE_VERSION || !Number.isFinite(obj.hour)) return;
    const fileBucketMs = clampNumber(obj.bucketSeconds, opts.bucketSeconds, 1, 600) * 1000;
    for (const [p, s] of Object.entries(obj.series || {})) {
      if (!Array.isArray(s.i)) continue;
      for (let n = 0; n < s.i.length; n++) {
        const ts = obj.hour + s.i[n] * fileBucketMs;
        if (s.k === 'n') {
          mergeNumeric(p, ts, s.s[n], s.c[n], s.mn[n], s.mx[n], s.l[n]);
        } else if (s.k === 't') {
          mergeText(p, ts, s.f[n], s.l[n]);
        }
      }
    }
  }

  function pruneMemory() {
    const cutoff = Math.floor((now() - retentionMs) / HOUR_MS) * HOUR_MS;
    for (const [p, s] of series) {
      for (const hour of s.hours.keys()) {
        if (hour < cutoff) s.hours.delete(hour);
      }
      if (s.hours.size === 0) series.delete(p);
    }
    for (const hour of [...dirtyHours]) if (hour < cutoff) dirtyHours.delete(hour);
    return cutoff;
  }

  function pruneFiles(cutoff) {
    let names;
    try {
      names = fs.readdirSync(hoursDir);
    } catch (_) {
      return;
    }
    for (const name of names) {
      const hour = Number(name.split('.')[0]);
      if (Number.isFinite(hour) && hour < cutoff) {
        try {
          fs.unlinkSync(path.join(hoursDir, name));
        } catch (_) {
          // Otro intento en el próximo volcado.
        }
      }
    }
  }

  /** Vuelca a disco solo las horas que han cambiado desde el último volcado,
   *  cada una en un único fichero comprimido escrito de golpe (tmp + rename,
   *  para que un corte de corriente nunca deje un fichero a medias). */
  function flush() {
    const cutoff = pruneMemory();
    let bytes = 0;
    try {
      fs.mkdirSync(hoursDir, { recursive: true });
      for (const hour of [...dirtyHours].sort((a, b) => a - b)) {
        const gz = zlib.gzipSync(Buffer.from(JSON.stringify(serializeHour(hour))), { level: 9 });
        const target = hourFile(hour);
        fs.writeFileSync(`${target}.tmp`, gz);
        fs.renameSync(`${target}.tmp`, target);
        bytes += gz.length;
        dirtyHours.delete(hour);
      }
      pruneFiles(cutoff);
      lastFlushAt = now();
      lastFlushBytes = bytes;
      lastError = null;
    } catch (err) {
      lastError = err && err.message;
      log(`fallo al volcar: ${lastError}`);
    }
    return bytes;
  }

  function load() {
    let names = [];
    try {
      names = fs.readdirSync(hoursDir);
    } catch (_) {
      return 0;
    }
    const cutoff = Math.floor((now() - retentionMs) / HOUR_MS) * HOUR_MS;
    let loaded = 0;
    for (const name of names.sort()) {
      if (!name.endsWith('.json.gz')) continue;
      const hour = Number(name.split('.')[0]);
      if (!Number.isFinite(hour) || hour < cutoff) continue;
      try {
        loadHourObject(JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(hoursDir, name)))));
        loaded++;
      } catch (err) {
        log(`fichero ilegible ${name}: ${err && err.message}`);
      }
    }
    // Lo recién cargado ya está en disco: no hay que reescribirlo.
    dirtyHours.clear();
    return loaded;
  }

  // ── Consulta (History API) ──────────────────────────────────────────────

  function toMs(x) {
    if (x === undefined || x === null) return undefined;
    if (typeof x === 'number') return x;
    if (typeof x.epochMilliseconds === 'number') return x.epochMilliseconds;
    const parsed = Date.parse(String(x));
    return Number.isFinite(parsed) ? parsed : undefined;
  }

  function durationMs(d) {
    if (d === undefined || d === null) return undefined;
    if (typeof d === 'number') return d * 1000;
    if (typeof d.total === 'function') {
      try {
        return d.total({ unit: 'milliseconds' });
      } catch (_) {
        // Duraciones con días/meses sin fecha de referencia.
      }
    }
    if (typeof d === 'string') {
      const n = Number(d);
      if (Number.isFinite(n)) return n * 1000;
    }
    return undefined;
  }

  function rangeOf(query) {
    const q = query || {};
    let from = toMs(q.from);
    let to = toMs(q.to);
    const dur = durationMs(q.duration);
    const t = now();
    if (from === undefined && to === undefined) {
      to = t;
      from = t - (dur ?? HOUR_MS);
    } else if (from === undefined) {
      from = to - (dur ?? HOUR_MS);
    } else if (to === undefined) {
      to = dur !== undefined ? from + dur : t;
    }
    return { from, to };
  }

  function childPaths(parent) {
    const prefix = `${parent}.`;
    return [...series.keys()].filter((p) => p.startsWith(prefix) && !p.slice(prefix.length).includes('.'));
  }

  /** Recorre los cubos de una serie dentro de [from, to) y los agrupa en
   *  franjas de resMs. Devuelve Map<slot, acumulado>. */
  function collect(p, from, to, resMs) {
    const s = series.get(p);
    const slots = new Map();
    if (!s) return slots;
    const hours = [...s.hours.keys()].filter((h) => h + HOUR_MS > from && h < to).sort((a, b) => a - b);
    for (const hour of hours) {
      const chunk = s.hours.get(hour);
      const indexes = s.kind === 'num' ? null : [...chunk.keys()].sort((a, b) => a - b);
      const n = s.kind === 'num' ? chunk.count.length : indexes.length;
      for (let j = 0; j < n; j++) {
        const k = s.kind === 'num' ? j : indexes[j];
        if (s.kind === 'num' && chunk.count[k] === 0) continue;
        const bt = hour + k * bucketMs;
        if (bt < from || bt >= to) continue;
        const slot = Math.floor((bt - from) / resMs);
        let acc = slots.get(slot);
        if (s.kind === 'num') {
          const c = chunk.count[k];
          const avg = chunk.sum[k] / c;
          if (!acc) {
            acc = { sum: 0, count: 0, min: Infinity, max: -Infinity, first: avg, last: 0, buckets: [] };
            slots.set(slot, acc);
          }
          acc.sum += chunk.sum[k];
          acc.count += c;
          if (chunk.min[k] < acc.min) acc.min = chunk.min[k];
          if (chunk.max[k] > acc.max) acc.max = chunk.max[k];
          acc.last = chunk.last[k];
          acc.buckets.push(avg);
        } else {
          const [first, last] = chunk.get(k);
          if (!acc) {
            acc = { first, last };
            slots.set(slot, acc);
          } else {
            acc.last = last;
          }
        }
      }
    }
    return slots;
  }

  function aggregateNumeric(acc, method) {
    switch (method) {
      case 'min':
        return acc.min;
      case 'max':
        return acc.max;
      case 'first':
        return acc.first;
      case 'last':
        return acc.last;
      case 'mid':
        return (acc.min + acc.max) / 2;
      case 'middle_index':
        return acc.buckets[Math.floor(acc.buckets.length / 2)];
      default:
        // average, y también sma/ema: sobre franjas ya agregadas la media es
        // la aproximación honesta.
        return acc.sum / acc.count;
    }
  }

  async function getValues(query) {
    const { from, to } = rangeOf(query);
    const span = Math.max(0, to - from);
    const requested = Number(query && query.resolution);
    let resMs = Number.isFinite(requested) && requested > 0 ? requested * 1000 : bucketMs;
    resMs = Math.max(bucketMs, resMs);
    // Nunca más filas de las configuradas: una consulta de 72 h a 1 s no debe
    // generar 259.200 filas en la Pi.
    const minRes = Math.ceil(span / opts.maxRowsPerQuery / bucketMs) * bucketMs;
    resMs = Math.max(resMs, minRes);

    const specs = (query && query.pathSpecs) || [];
    const columns = specs.map((spec) => {
      const p = spec.path;
      const method = spec.aggregate || 'average';
      if (series.has(p)) {
        const s = series.get(p);
        return { kind: s.kind, path: p, method, slots: collect(p, from, to, resMs) };
      }
      const children = childPaths(p);
      if (children.length) {
        return {
          kind: 'object',
          method,
          children: children.map((c) => ({
            key: c.slice(p.length + 1),
            slots: collect(c, from, to, resMs),
          })),
        };
      }
      return { kind: 'none', method, slots: new Map() };
    });

    const allSlots = new Set();
    for (const col of columns) {
      const maps = col.kind === 'object' ? col.children.map((c) => c.slots) : [col.slots];
      for (const m of maps) for (const k of m.keys()) allSlots.add(k);
    }
    const data = [...allSlots]
      .sort((a, b) => a - b)
      .map((slot) => {
        const row = [new Date(from + slot * resMs).toISOString()];
        for (const col of columns) {
          if (col.kind === 'num') {
            const acc = col.slots.get(slot);
            // Redondeo por ruta: lat/lon conservan 7 decimales (cm), el
            // resto 5.
            row.push(acc ? roundFor(col.path, aggregateNumeric(acc, col.method)) : null);
          } else if (col.kind === 'text') {
            const acc = col.slots.get(slot);
            row.push(acc ? (col.method === 'first' ? acc.first : acc.last) : null);
          } else if (col.kind === 'object') {
            const obj = {};
            let any = false;
            for (const child of col.children) {
              const acc = child.slots.get(slot);
              if (acc) {
                obj[child.key] = aggregateNumeric(acc, col.method);
                any = true;
              }
            }
            row.push(any ? obj : null);
          } else {
            row.push(null);
          }
        }
        return row;
      });

    return {
      context: (query && query.context) || 'vessels.self',
      range: { from: new Date(from).toISOString(), to: new Date(to).toISOString() },
      values: specs.map((spec) => ({ path: spec.path, method: spec.aggregate || 'average' })),
      data,
    };
  }

  function pathsWithData(from, to) {
    const out = new Set();
    for (const [p, s] of series) {
      for (const hour of s.hours.keys()) {
        if (hour + HOUR_MS > from && hour < to) {
          out.add(p);
          const parent = p.slice(0, p.lastIndexOf('.'));
          if (/\.(latitude|longitude|roll|pitch|yaw)$/.test(p)) out.add(parent);
          break;
        }
      }
    }
    return [...out].sort();
  }

  async function getPaths(query) {
    const { from, to } = rangeOf(query);
    return pathsWithData(from, to);
  }

  async function getContexts(query) {
    const { from, to } = rangeOf(query);
    return pathsWithData(from, to).length ? ['vessels.self'] : [];
  }

  function stats() {
    let buckets = 0;
    for (const s of series.values()) {
      for (const chunk of s.hours.values()) {
        if (s.kind === 'num') {
          for (let k = 0; k < chunk.count.length; k++) if (chunk.count[k]) buckets++;
        } else {
          buckets += chunk.size;
        }
      }
    }
    return {
      series: series.size,
      buckets,
      refusedSeries,
      lastFlushAt,
      lastFlushBytes,
      lastError,
      pendingHours: dirtyHours.size,
    };
  }

  return {
    options: opts,
    handleDelta,
    recordValue,
    flush,
    load,
    getValues,
    getPaths,
    getContexts,
    stats,
    provider: { getValues, getPaths, getContexts },
  };
}

module.exports = {
  createRecorder,
  normalizeOptions,
  globToRegExp,
  DEFAULTS,
};
