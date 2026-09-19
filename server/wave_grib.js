/*
 * REWIND Panel — ola de NOAA GFS-Wave para el routing, servida por el
 * servidor del barco.
 *
 * Por qué: Open-Meteo cuenta cada punto de la rejilla como una llamada de su
 * cuota gratuita, y la ola (que va después del viento) era la primera en
 * quedarse sin cuota. NOAA publica GFS-Wave (WAVEWATCH III, 0,25°, cubre el
 * Mediterráneo) sin clave ni cuota por punto, y su "grib filter" recorta la
 * zona y las variables en el propio servidor: altura, periodo y dirección de
 * todo el Egeo en un paso de previsión son < 1 KB. Lo baja el barco una vez y
 * lo comparten todos sus dispositivos.
 *
 * El GRIB2 que devuelve NOAA viene con "simple packing" (plantilla 5.0) y
 * mapa de bits: se decodifica aquí en JavaScript puro, sin ecCodes. Si algún
 * día cambia de empaquetado, se dice (error claro), no se inventa.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const NOMADS = 'https://nomads.ncep.noaa.gov/cgi-bin/filter_gfswave.pl';

// ── Decodificador GRIB2 mínimo: rejilla lat/lon (3.0), producto 4.0/4.8,
// empaquetado simple (5.0) con o sin mapa de bits.

/** Entero con signo de GRIB2: el bit alto es el signo (no complemento a 2). */
function signed(buf, off, bytes) {
  let v = 0;
  for (let i = 0; i < bytes; i++) v = v * 256 + buf[off + i];
  const signBit = 2 ** (8 * bytes - 1);
  return v >= signBit ? -(v - signBit) : v;
}

function unsigned(buf, off, bytes) {
  let v = 0;
  for (let i = 0; i < bytes; i++) v = v * 256 + buf[off + i];
  return v;
}

/** Lee [nbits] bits a partir del bit [bitPos] (big-endian). */
function readBits(buf, bitPos, nbits) {
  let v = 0;
  for (let i = 0; i < nbits; i++) {
    const p = bitPos + i;
    const bit = (buf[p >> 3] >> (7 - (p & 7))) & 1;
    v = v * 2 + bit;
  }
  return v;
}

/**
 * Decodifica todos los mensajes GRIB2 de [buf]. Cada mensaje:
 * { discipline, category, number, forecastHours, refTime (ms),
 *   ni, nj, lat1, lon1, lat2, lon2, di, dj, jPositive,
 *   values: Float64Array (NaN = sin dato), filas de la rejilla tal cual }
 */
function decodeGrib2(buf) {
  const out = [];
  let pos = 0;
  while (pos + 16 <= buf.length) {
    if (buf.toString('latin1', pos, pos + 4) !== 'GRIB') {
      pos++;
      continue;
    }
    const discipline = buf[pos + 6];
    const edition = buf[pos + 7];
    if (edition !== 2) throw new Error(`GRIB edición ${edition}: solo se lee GRIB2`);
    const total = unsigned(buf, pos + 8, 8);
    const end = pos + total;
    let p = pos + 16;
    const msg = { discipline };
    let bitmap = null;
    let packing = null;
    while (p < end - 4) {
      if (buf.toString('latin1', p, p + 4) === '7777') break;
      const len = unsigned(buf, p, 4);
      const num = buf[p + 4];
      const s = p;
      if (num === 1) {
        const y = unsigned(buf, s + 12, 2);
        msg.refTime = Date.UTC(y, buf[s + 14] - 1, buf[s + 15], buf[s + 16], buf[s + 17], buf[s + 18]);
      } else if (num === 3) {
        const tmpl = unsigned(buf, s + 12, 2);
        if (tmpl !== 0) throw new Error(`rejilla GRIB2 3.${tmpl}: solo se lee lat/lon (3.0)`);
        msg.ni = unsigned(buf, s + 30, 4);
        msg.nj = unsigned(buf, s + 34, 4);
        msg.lat1 = signed(buf, s + 46, 4) / 1e6;
        msg.lon1 = signed(buf, s + 50, 4) / 1e6;
        msg.lat2 = signed(buf, s + 55, 4) / 1e6;
        msg.lon2 = signed(buf, s + 59, 4) / 1e6;
        msg.di = unsigned(buf, s + 63, 4) / 1e6;
        msg.dj = unsigned(buf, s + 67, 4) / 1e6;
        const scan = buf[s + 71];
        if (scan & 0x80) throw new Error('GRIB2: barrido oeste→este invertido no soportado');
        if (scan & 0x20) throw new Error('GRIB2: barrido por columnas no soportado');
        msg.jPositive = (scan & 0x40) !== 0;
      } else if (num === 4) {
        const tmpl = unsigned(buf, s + 7, 2);
        if (tmpl !== 0 && tmpl !== 8) throw new Error(`producto GRIB2 4.${tmpl} no soportado`);
        msg.category = buf[s + 9];
        msg.number = buf[s + 10];
        const unit = buf[s + 17];
        const ft = signed(buf, s + 18, 4);
        // 1 = horas, 0 = minutos, 2 = días.
        msg.forecastHours = unit === 1 ? ft : unit === 0 ? ft / 60 : unit === 2 ? ft * 24 : NaN;
      } else if (num === 5) {
        const n = unsigned(buf, s + 5, 4);
        const tmpl = unsigned(buf, s + 9, 2);
        if (tmpl !== 0) throw new Error(`empaquetado GRIB2 5.${tmpl}: solo simple (5.0)`);
        packing = {
          n,
          ref: buf.readFloatBE(s + 11),
          e: signed(buf, s + 15, 2),
          d: signed(buf, s + 17, 2),
          nbits: buf[s + 19],
        };
      } else if (num === 6) {
        const ind = buf[s + 5];
        if (ind === 0) bitmap = { off: s + 6 };
        else if (ind !== 255) throw new Error(`mapa de bits GRIB2 ${ind} no soportado`);
      } else if (num === 7) {
        if (!packing || !msg.ni) throw new Error('GRIB2 sin secciones 3/5 antes de los datos');
        const count = msg.ni * msg.nj;
        const values = new Float64Array(count).fill(NaN);
        const scaleE = 2 ** packing.e;
        const scaleD = 10 ** -packing.d;
        let k = 0; // índice del siguiente valor empaquetado
        const dataBit = (s + 5) * 8;
        for (let i = 0; i < count; i++) {
          if (bitmap && readBits(buf, bitmap.off * 8 + i, 1) === 0) continue;
          const x = packing.nbits === 0 ? 0 : readBits(buf, dataBit + k * packing.nbits, packing.nbits);
          values[i] = (packing.ref + x * scaleE) * scaleD;
          k++;
        }
        msg.values = values;
      }
      p += len;
    }
    if (msg.values) out.push(msg);
    pos = end;
  }
  return out;
}

// ── Productos de NOAA que se sirven: qué pedir y cómo montarlo.

/**
 * Pasos de previsión: [hourlyUntil] horas de hora en hora y después cada
 * 3 h, de 0 a 72 h desde el ciclo como poco — una ventana fija por ciclo y
 * zona que sirve cualquier petición posterior sin bajar nada — y más allá
 * solo si se pide (GFS llega a 384 h).
 */
function forecastHoursFor(cycleMs, toMs, hourlyUntil = 0) {
  const need = Math.ceil((toMs - cycleMs) / 3600000);
  const last = Math.min(384, Math.max(72, Math.ceil(need / 3) * 3));
  const hours = [];
  for (let h = 0; h <= last; h += h < hourlyUntil ? 1 : 3) hours.push(h);
  return hours;
}

const PRODUCTS = {
  // Ola: WAVEWATCH III de GFS. Cada 3 h (cambia despacio; se interpola).
  waves: {
    label: 'NOAA GFS-Wave 0,25°',
    script: 'filter_gfswave.pl',
    dir: (ymd, cc) => `/gfs.${ymd}/${cc}/wave/gridded`,
    file: (cc, fff) => `gfswave.t${cc}z.global.0p25.f${fff}.grib2`,
    params: { var_HTSGW: 'on', var_PERPW: 'on', var_DIRPW: 'on' },
    // disciplina 10 (océano), categoría 0 (olas)
    vars: [
      { d: 10, c: 0, n: 3, name: 'height' }, // HTSGW, altura significativa (m)
      { d: 10, c: 0, n: 11, name: 'period' }, // PERPW, periodo ola primaria (s)
      { d: 10, c: 0, n: 10, name: 'direction' }, // DIRPW, DE DONDE VIENE (°)
    ],
    hourlyUntil: 0,
  },
  // Viento a 10 m y racha del GFS 0,25°: de hora en hora las primeras 24 h
  // (lo que más pesa en una ruta), luego cada 3 h interpolado a horas.
  wind: {
    label: 'NOAA GFS 0,25°',
    script: 'filter_gfs_0p25_1hr.pl',
    dir: (ymd, cc) => `/gfs.${ymd}/${cc}/atmos`,
    file: (cc, fff) => `gfs.t${cc}z.pgrb2.0p25.f${fff}`,
    params: {
      var_UGRD: 'on',
      var_VGRD: 'on',
      var_GUST: 'on',
      lev_10_m_above_ground: 'on',
      lev_surface: 'on',
    },
    // disciplina 0 (meteorología), categoría 2 (momento), m/s
    vars: [
      { d: 0, c: 2, n: 2, name: 'u' }, // UGRD 10 m, hacia el este
      { d: 0, c: 2, n: 3, name: 'v' }, // VGRD 10 m, hacia el norte
      { d: 0, c: 2, n: 22, name: 'gust' }, // GUST en superficie
    ],
    hourlyUntil: 24,
    hourlyOutput: true,
  },
};

function two(n) {
  return String(n).padStart(2, '0');
}

function cycleName(ms) {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}${two(d.getUTCMonth() + 1)}${two(d.getUTCDate())} ${two(d.getUTCHours())}z`;
}

function filterUrl(cycleMs, fh, box, product = PRODUCTS.waves) {
  const d = new Date(cycleMs);
  const ymd = `${d.getUTCFullYear()}${two(d.getUTCMonth() + 1)}${two(d.getUTCDate())}`;
  const cc = two(d.getUTCHours());
  const q = new URLSearchParams({
    dir: product.dir(ymd, cc),
    file: product.file(cc, String(fh).padStart(3, '0')),
    ...product.params,
    subregion: '',
    // Un paso de más por cada lado: el filtro deja fuera el borde exacto.
    toplat: String(box.north + 0.25),
    leftlon: String(box.west - 0.25),
    rightlon: String(box.east + 0.25),
    bottomlat: String(box.south - 0.25),
  });
  return `${NOMADS.replace('filter_gfswave.pl', product.script)}?${q}`;
}

/**
 * Monta la rejilla a partir de los mensajes de cada paso:
 * { lat0, lon0, step, nLat, nLon, times:[ms], <var>: [...] } con filas de S
 * a N y columnas de W a E, índice (t * nLat + i) * nLon + j, null donde no
 * hay dato (tierra, en la ola).
 */
function assembleGrid(steps, product = PRODUCTS.waves) {
  const first = steps[0].messages[0];
  const nLat = first.nj;
  const nLon = first.ni;
  const south = Math.min(first.lat1, first.lat2);
  let lon0 = first.lon1;
  if (lon0 > 180) lon0 -= 360;
  const grid = { lat0: south, lon0, step: first.di, nLat, nLon, times: [] };
  for (const v of product.vars) grid[v.name] = [];
  for (const st of steps) {
    grid.times.push(st.time);
    const byVar = {};
    for (const m of st.messages) {
      const def = product.vars.find(
        (v) => v.d === m.discipline && v.c === m.category && v.n === m.number,
      );
      if (!def) continue;
      if (m.ni !== nLon || m.nj !== nLat) throw new Error('NOAA: rejillas de distinto tamaño');
      byVar[def.name] = m;
    }
    for (const { name } of product.vars) {
      const m = byVar[name];
      for (let i = 0; i < nLat; i++) {
        // Fila i contando desde el sur.
        const row = m && m.jPositive ? i : nLat - 1 - i;
        for (let j = 0; j < nLon; j++) {
          const v = m ? m.values[row * nLon + j] : NaN;
          grid[name].push(Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
        }
      }
    }
  }
  return grid;
}

/**
 * Pasa una rejilla con pasos de 1 y 3 h a pasos de 1 h, interpolando en
 * línea recta entre los dos pasos que rodean cada hora (lo mismo que haría
 * la app, que necesita horas equiespaciadas).
 */
function toHourly(grid, names) {
  const n = grid.nLat * grid.nLon;
  const t0 = grid.times[0];
  const t1 = grid.times[grid.times.length - 1];
  const out = { ...grid, times: [] };
  for (const name of names) out[name] = [];
  let k = 0;
  for (let t = t0; t <= t1; t += 3600000) {
    while (k < grid.times.length - 2 && grid.times[k + 1] < t) k++;
    const ta = grid.times[k];
    const tb = grid.times[Math.min(k + 1, grid.times.length - 1)];
    const f = tb === ta ? 0 : (t - ta) / (tb - ta);
    out.times.push(t);
    for (const name of names) {
      const a = grid[name];
      for (let c = 0; c < n; c++) {
        const va = a[k * n + c];
        const vb = a[Math.min(k + 1, grid.times.length - 1) * n + c];
        out[name].push(
          va === null || vb === null ? null : Math.round((va + (vb - va) * f) * 100) / 100,
        );
      }
    }
  }
  return out;
}

/**
 * Servicio NOAA: busca el último ciclo publicado de cada producto, baja los
 * pasos que cubren [from, to] para la zona y los guarda en disco (un ciclo
 * sirve 6 h: dos peticiones de la misma zona no vuelven a bajar nada).
 */
function createNoaaService({
  dataDir,
  fetchImpl = fetch,
  now = () => Date.now(),
  log = () => {},
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  perMinute = 100,
}) {
  // NOMADS bloquea un rato la IP que pasa de ~120 peticiones por minuto:
  // tope común de [perMinute] para viento y ola juntos.
  // Las peticiones pasan por el limitador de una en una (las descargas en
  // paralelo no pueden colarse a la vez por el mismo hueco).
  const recent = [];
  let gate = Promise.resolve();
  function throttle() {
    const turn = gate.then(async () => {
      for (;;) {
        const t = now();
        while (recent.length && recent[0] <= t - 60000) recent.shift();
        if (recent.length < perMinute) break;
        await sleep(recent[0] + 60000 - t + 50);
      }
      recent.push(now());
    });
    gate = turn.catch(() => {});
    return turn;
  }

  async function getBuffer(url) {
    await throttle();
    const res = await fetchImpl(url);
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`NOAA NOMADS: HTTP ${res.status}`);
    return Buffer.from(await res.arrayBuffer());
  }

  // Zona redondeada hacia fuera a medio grado: peticiones parecidas
  // (mover un poco un punto de la ruta) comparten descarga.
  function roundBox(box) {
    return {
      south: Math.floor(box.south * 2) / 2,
      west: Math.floor(box.west * 2) / 2,
      north: Math.ceil(box.north * 2) / 2,
      east: Math.ceil(box.east * 2) / 2,
    };
  }

  function forProduct(kind) {
    const product = PRODUCTS[kind];
    const cacheDir = path.join(dataDir, kind === 'waves' ? 'waves' : `noaa-${kind}`);
    const memory = new Map();
    let knownCycle = null; // { cycle, checkedAt }

    /** Último ciclo con el paso f000 ya publicado (tarda ~4-5 h). */
    async function latestCycle(box) {
      const sixH = 6 * 3600000;
      let c = Math.floor(now() / sixH) * sixH;
      for (let i = 0; i < 4; i++, c -= sixH) {
        const buf = await getBuffer(filterUrl(c, 0, box, product));
        if (buf && buf.length > 20 && buf.toString('latin1', 0, 4) === 'GRIB') return c;
      }
      throw new Error(`NOAA NOMADS: no hay ningún ciclo reciente de ${product.label} publicado`);
    }

    async function currentCycle(box) {
      if (knownCycle && now() - knownCycle.checkedAt < 30 * 60000) return knownCycle.cycle;
      const cycle = await latestCycle(box);
      knownCycle = { cycle, checkedAt: now() };
      return cycle;
    }

    return async function get(requestBox, fromMs, toMs) {
      const box = roundBox(requestBox);
      const cycle = await currentCycle(box);
      const hours = forecastHoursFor(cycle, toMs, product.hourlyUntil);
      if (cycle + hours[hours.length - 1] * 3600000 < fromMs) {
        throw new Error(`${product.label}: las horas pedidas quedan fuera de la previsión`);
      }
      // Una descarga de este ciclo cuya zona contenga la pedida y con horas
      // suficientes vale tal cual.
      for (const g of memory.values()) {
        if (
          g.cycle === cycle &&
          g.box.south <= box.south &&
          g.box.west <= box.west &&
          g.box.north >= box.north &&
          g.box.east >= box.east &&
          g.times[g.times.length - 1] >= toMs
        ) {
          return g;
        }
      }
      const k = `${cycle}_${box.south}_${box.west}_${box.north}_${box.east}_${hours[hours.length - 1]}`;
      if (memory.has(k)) return memory.get(k);
      const file = path.join(cacheDir, `${k}.json`);
      try {
        const cached = JSON.parse(fs.readFileSync(file, 'utf8'));
        memory.set(k, cached);
        return cached;
      } catch (_) {}

      // Dos descargas a la vez: NOMADS admite unas 120 peticiones por
      // minuto por IP y cada una tarda ~1-1,5 s. Un paso aún no publicado
      // (404) se queda fuera.
      const steps = [];
      let next = 0;
      async function worker() {
        while (next < hours.length) {
          const fh = hours[next++];
          const buf = await getBuffer(filterUrl(cycle, fh, box, product));
          if (buf) steps.push({ time: cycle + fh * 3600000, messages: decodeGrib2(buf) });
        }
      }
      await Promise.all([worker(), worker()]);
      if (!steps.length) throw new Error(`${product.label}: ningún paso de previsión disponible`);
      steps.sort((a, b) => a.time - b.time);
      let grid = assembleGrid(steps, product);
      if (product.hourlyOutput) grid = toHourly(grid, product.vars.map((v) => v.name));
      grid.source = `${product.label} · ciclo ${cycleName(cycle)}`;
      grid.cycle = cycle;
      grid.box = box;
      grid.fetchedAt = now();
      try {
        fs.mkdirSync(cacheDir, { recursive: true });
        // Solo los ciclos de las últimas 24 h.
        for (const f of fs.readdirSync(cacheDir)) {
          const c = Number(f.split('_')[0]);
          if (Number.isFinite(c) && c < now() - 24 * 3600000) fs.unlinkSync(path.join(cacheDir, f));
        }
        fs.writeFileSync(file, JSON.stringify(grid));
      } catch (err) {
        log(`[noaa] no se pudo guardar en disco: ${err && err.message}`);
      }
      memory.set(k, grid);
      while (memory.size > 6) memory.delete(memory.keys().next().value);
      return grid;
    };
  }

  return { getWaves: forProduct('waves'), getWind: forProduct('wind') };
}

/** Compatibilidad: el servicio de ola (lo que había antes del viento). */
function createWaveService(opts) {
  return createNoaaService(opts);
}

module.exports = {
  decodeGrib2,
  assembleGrid,
  toHourly,
  forecastHoursFor,
  filterUrl,
  PRODUCTS,
  createNoaaService,
  createWaveService,
};
