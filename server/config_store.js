/*
 * REWIND Panel — configuración del barco compartida entre dispositivos.
 *
 * El problema: cada tablet, móvil o navegador guardaba su propia
 * configuración (qué sensores tiene el barco, umbrales, tanques…), así que
 * configurar el barco había que repetirlo en cada aparato y cualquier cambio
 * se quedaba donde se hizo.
 *
 * Por qué aquí y no en otro sitio:
 *  - La configuración del PLUGIN no vale: Signal K reinicia el plugin cada vez
 *    que se guarda, y eso tiraría lo que el grabador de histórico tenga en
 *    memoria (hasta una hora de datos).
 *  - El almacén de aplicación de Signal K tampoco: en estos barcos se lee sin
 *    contraseña (comprobado 2026-09-16), y aquí viajan datos del barco.
 *
 * Reglas:
 *  - El número de revisión lo pone el servidor, NUNCA el reloj del
 *    dispositivo: los relojes de tablets y móviles no son de fiar.
 *  - Quien escribe manda su `baseRevision`. Si no es la actual, se rechaza con
 *    409 y se le devuelve lo que hay, para que decida: es la única forma de
 *    que un dispositivo que estuvo desconectado no pise lo que cambió otro.
 *  - Se guarda un historial de las últimas versiones, con qué dispositivo la
 *    cambió, para poder volver atrás.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const SCHEMA_VERSION = 1;
const HISTORY_KEEP = 10;
// Un tamaño desbocado sería un error del cliente, no una configuración: más
// vale rechazarlo que llenar la SD.
const MAX_BYTES = 512 * 1024;

function emptyDoc() {
  return {
    schemaVersion: SCHEMA_VERSION,
    revision: 0,
    updatedAt: null,
    updatedBy: '',
    config: {},
  };
}

/** Valida lo que manda un cliente antes de tocar el disco. */
function validateIncoming(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return 'cuerpo de la petición inválido';
  }
  if (typeof body.config !== 'object' || body.config === null || Array.isArray(body.config)) {
    return 'falta el objeto config';
  }
  if (body.baseRevision !== undefined && !Number.isFinite(Number(body.baseRevision))) {
    return 'baseRevision debe ser un número';
  }
  if (JSON.stringify(body.config).length > MAX_BYTES) {
    return `la configuración supera ${MAX_BYTES} bytes`;
  }
  return null;
}

/**
 * Decide qué hacer con una escritura.
 *
 * Sin `baseRevision` se acepta (primer arranque de un dispositivo que aún no
 * ha leído nada); con una que no coincide se rechaza para que el cliente vea
 * antes lo que hay.
 */
function decideWrite(current, incomingBaseRevision) {
  if (incomingBaseRevision === undefined || incomingBaseRevision === null) {
    return { ok: true, reason: 'sin base' };
  }
  const base = Number(incomingBaseRevision);
  if (base === current.revision) return { ok: true, reason: 'al día' };
  return {
    ok: false,
    reason:
      base < current.revision
        ? 'otro dispositivo cambió la configuración mientras tanto'
        : 'revisión superior a la del servidor',
  };
}

function createConfigStore({ app, dataDir, now = () => Date.now() }) {
  const file = path.join(dataDir, 'panel-config.json');
  const historyDir = path.join(dataDir, 'panel-config-history');

  function read() {
    try {
      const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!doc || typeof doc !== 'object' || !Number.isFinite(doc.revision)) {
        return emptyDoc();
      }
      return { ...emptyDoc(), ...doc };
    } catch (_) {
      // Sin fichero todavía, o ilegible: se devuelve vacío y NUNCA se
      // sobrescribe solo — un fichero corrupto se conserva para poder mirarlo.
      return emptyDoc();
    }
  }

  function writeDoc(doc) {
    fs.mkdirSync(dataDir, { recursive: true });
    const text = JSON.stringify(doc, null, 2);
    fs.writeFileSync(`${file}.tmp`, text);
    fs.renameSync(`${file}.tmp`, file);
    try {
      fs.mkdirSync(historyDir, { recursive: true });
      fs.writeFileSync(path.join(historyDir, `${doc.revision}.json`), text);
      const old = fs
        .readdirSync(historyDir)
        .filter((n) => n.endsWith('.json'))
        .sort((a, b) => Number(a.split('.')[0]) - Number(b.split('.')[0]));
      for (const name of old.slice(0, Math.max(0, old.length - HISTORY_KEEP))) {
        fs.unlinkSync(path.join(historyDir, name));
      }
    } catch (err) {
      // El historial es una comodidad: si falla, la configuración ya está
      // guardada y eso es lo que importa.
      app && app.debug && app.debug(`[config] historial: ${err && err.message}`);
    }
  }

  /** Publica la revisión en el bus de Signal K: así los demás dispositivos se
   *  enteran al instante en vez de preguntar cada pocos segundos. */
  function announce(doc) {
    if (!app || typeof app.handleMessage !== 'function') return;
    app.handleMessage('rewind-xcover6-panel', {
      updates: [
        {
          values: [
            {
              path: 'rewind.config.revision',
              value: doc.revision,
            },
          ],
        },
      ],
    });
  }

  function save(body) {
    const invalid = validateIncoming(body);
    if (invalid) return { status: 400, body: { error: invalid } };
    const current = read();
    const decision = decideWrite(current, body.baseRevision);
    if (!decision.ok) {
      return { status: 409, body: { error: decision.reason, current } };
    }
    const doc = {
      schemaVersion: SCHEMA_VERSION,
      revision: current.revision + 1,
      updatedAt: new Date(now()).toISOString(),
      updatedBy: typeof body.updatedBy === 'string' ? body.updatedBy.slice(0, 60) : '',
      config: body.config,
    };
    writeDoc(doc);
    announce(doc);
    return { status: 200, body: doc };
  }

  function history() {
    try {
      return fs
        .readdirSync(historyDir)
        .filter((n) => n.endsWith('.json'))
        .map((n) => {
          const d = JSON.parse(fs.readFileSync(path.join(historyDir, n), 'utf8'));
          return {
            revision: d.revision,
            updatedAt: d.updatedAt,
            updatedBy: d.updatedBy,
          };
        })
        .sort((a, b) => b.revision - a.revision);
    } catch (_) {
      return [];
    }
  }

  function restore(revision) {
    try {
      const d = JSON.parse(
        fs.readFileSync(path.join(historyDir, `${Number(revision)}.json`), 'utf8'),
      );
      return save({ config: d.config, updatedBy: `restaurada r${d.revision}` });
    } catch (_) {
      return { status: 404, body: { error: 'no existe esa revisión' } };
    }
  }

  return { read, save, history, restore, announce };
}

module.exports = {
  createConfigStore,
  validateIncoming,
  decideWrite,
  emptyDoc,
  SCHEMA_VERSION,
};
