import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { statSync, realpathSync, createReadStream } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const WEB_ROOT = path.dirname(fileURLToPath(import.meta.url));
const TERMINAL = new Set(['victory', 'defeat', 'abandoned']);
const VERSION = 2;

export class DataError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

export function defaultDatabase() {
  return path.join(WEB_ROOT, 'sector07.sqlite');
}

function objectJson(value, description) {
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
  } catch { /* Report malformed persisted data instead of presenting an empty success. */ }
  throw new DataError('DB_INVALID', `No se pudieron leer los datos de ${description}.`);
}

/** One short, consistent read transaction per refresh; never create or migrate saves. */
export function readDashboard(databasePath) {
  let db;
  try {
    if (!statSync(databasePath).isFile()) throw new Error('not a file');
  } catch {
    throw new DataError('DB_NOT_FOUND', 'No se encontró la base del juego. Abre el juego y crea o selecciona un perfil; después pulsa Actualizar.');
  }
  try {
    db = new DatabaseSync(databasePath, { readOnly: true, timeout: 250 });
    db.exec('PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN');
    const version = db.prepare('PRAGMA user_version').get().user_version;
    if (version < 1 || version > VERSION) {
      throw new DataError('DB_VERSION_UNSUPPORTED', 'La versión de la base no es compatible con esta web. Usa la misma versión del juego y del servidor.');
    }
    const tables = new Set(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name));
    const required = ['profiles', 'level_progress', 'unlocks', 'upgrades', 'run_history'];
    if (version >= 2) required.push('run_sessions', 'game_events', 'profile_events');
    if (required.some(table => !tables.has(table))) throw new DataError('DB_INVALID', 'La base está incompleta. Abre el juego para comprobar su guardado.');
    const profiles = db.prepare('SELECT id,uuid,display_name,record,tutorial_completed,state_json FROM profiles ORDER BY created_at,id').all();
    const ids = new Map(profiles.map(row => [row.id, row.uuid]));
    const players = profiles.map(row => ({
      id: row.uuid, name: row.display_name, record: row.record, completedLevels: [], scores: {},
      weaponUnlocks: [], grenadeUnlocks: [], discoveredEnemies: [], upgrades: [],
      tutorialCompleted: Boolean(row.tutorial_completed), loadout: [],
    }));
    const byKey = new Map(profiles.map((row, index) => [row.id, players[index]]));
    for (const row of db.prepare('SELECT * FROM level_progress ORDER BY level_number').all()) {
      const player = byKey.get(row.profile_id);
      if (!player) throw new DataError('DB_INVALID', 'Hay progreso sin un perfil válido.');
      if (row.completed) player.completedLevels.push(row.level_number);
      player.scores[row.level_number] = row.best_score;
    }
    for (const row of db.prepare('SELECT * FROM unlocks ORDER BY category,item_id').all()) {
      const player = byKey.get(row.profile_id);
      if (!player) throw new DataError('DB_INVALID', 'Hay desbloqueos sin un perfil válido.');
      if (row.category === 'weapon') player.weaponUnlocks.push(row.item_id);
      if (row.category === 'grenade') player.grenadeUnlocks.push(row.item_id);
      if (row.category === 'enemy') player.discoveredEnemies.push(Number(row.item_id));
    }
    for (const row of db.prepare('SELECT * FROM upgrades ORDER BY stage').all()) {
      const player = byKey.get(row.profile_id);
      if (!player) throw new DataError('DB_INVALID', 'Hay mejoras sin un perfil válido.');
      player.upgrades.push({ stage: row.stage, id: row.upgrade_id });
    }
    for (const row of profiles) {
      const player = byKey.get(row.id), state = objectJson(row.state_json, 'un perfil');
      const available = ['pistol', ...['rifle', 'shotgun', 'precision', 'plasma'].filter(id => player.weaponUnlocks.includes(id))];
      const chosen = Array.isArray(state.loadout) ? state.loadout : ['pistol', 'rifle'];
      player.loadout = [...new Set([...chosen.filter(id => available.includes(id)), ...available])].slice(0, 2);
    }
    const history = db.prepare('SELECT * FROM run_history').all();
    const runs = new Map(history.map(row => [row.id, {
      id: row.id, playerId: ids.get(row.profile_id), level: row.level_number, difficulty: row.difficulty,
      outcome: row.outcome, durationSeconds: row.duration_seconds, score: row.score, kills: row.kills,
      startedAt: row.started_at, endedAt: row.ended_at, updatedAt: row.ended_at,
    }]));
    if (version >= 2) {
      for (const row of db.prepare('SELECT * FROM run_sessions').all()) {
        if (runs.has(row.id)) continue; // A finished attempt counts once, not once per table.
        runs.set(row.id, {
          id: row.id, playerId: ids.get(row.profile_id), level: row.level_number, difficulty: row.difficulty,
          outcome: row.outcome, durationSeconds: row.duration_seconds, score: null, kills: row.kills,
          startedAt: row.started_at, endedAt: TERMINAL.has(row.outcome) ? row.updated_at : null, updatedAt: row.updated_at,
        });
      }
    }
    const events = [];
    if (version >= 2) {
      for (const row of db.prepare('SELECT e.*,s.profile_id,s.level_number FROM game_events e JOIN run_sessions s ON s.id=e.session_id ORDER BY e.occurred_at,e.sequence').all()) {
        events.push({
          id: `game:${row.id}`, scope: 'game', runId: row.session_id, playerId: ids.get(row.profile_id),
          level: row.level_number, type: row.event_type, occurredAt: row.occurred_at, sequence: row.sequence,
          missionSeconds: row.mission_seconds, activeSeconds: row.active_seconds, payload: objectJson(row.payload_json, 'un evento'),
        });
      }
      for (const row of db.prepare('SELECT * FROM profile_events ORDER BY occurred_at,id').all()) {
        const playerId = row.profile_id === null ? null : ids.get(row.profile_id);
        if (playerId === undefined) throw new DataError('DB_INVALID', 'Hay eventos sin un perfil válido.');
        events.push({
          id: `profile:${row.id}`, scope: playerId === null ? 'system' : 'profile', runId: null, playerId,
          level: null, type: row.event_type, occurredAt: row.occurred_at, payload: objectJson(row.payload_json, 'una acción del menú'),
        });
      }
    }
    if ([...runs.values()].some(row => !row.playerId)) throw new DataError('DB_INVALID', 'Hay intentos sin un perfil válido.');
    db.exec('COMMIT');
    return {
      schemaVersion: 2, databaseSchemaVersion: version, generatedAt: new Date().toISOString(),
      capabilities: { events: version >= 2 }, players,
      runs: [...runs.values()].sort((a, b) => Date.parse(b.endedAt || b.updatedAt) - Date.parse(a.endedAt || a.updatedAt)),
      events: events.sort((a, b) => Date.parse(b.occurredAt) - Date.parse(a.occurredAt) || (b.sequence || 0) - (a.sequence || 0)),
    };
  } catch (error) {
    if (error instanceof DataError) throw error;
    if (/locked|busy/i.test(error.message)) throw new DataError('DB_BUSY', 'El juego está guardando. Espera un momento y pulsa Actualizar.');
    throw new DataError('DB_INVALID', 'No se pudo leer la base del juego. Comprueba el archivo y abre el juego para verificar su guardado.');
  } finally {
    db?.close();
  }
}

const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml' };
function json(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

export function createServer({ databasePath = defaultDatabase(), webRoot = WEB_ROOT } = {}) {
  const publicRoot = realpathSync(webRoot), assetsRoot = path.join(publicRoot, 'assets');
  return http.createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    const port = request.socket.localPort;
    const hosts = new Set([`localhost:${port}`, `127.0.0.1:${port}`]);
    if (!hosts.has(request.headers.host) || (request.headers.origin && ![...hosts].some(host => request.headers.origin === `http://${host}`))) {
      json(response, 403, { error: { code: 'LOCAL_ONLY', message: 'Esta consulta es local.' } }); return;
    }
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.setHeader('Allow', 'GET, HEAD');
      json(response, 405, { error: { code: 'READ_ONLY', message: 'El archivo web solo permite consultas.' } }); return;
    }
    let pathname;
    try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
    catch { json(response, 400, { error: { code: 'INVALID_PATH', message: 'Ruta inválida.' } }); return; }
    if (pathname === '/api/dashboard') {
      try { const data = readDashboard(databasePath); json(response, 200, data); }
      catch (error) { json(response, 503, { error: { code: error.code || 'DB_INVALID', message: error.message } }); }
      return;
    }
    const filename = pathname === '/' ? 'index.html' : pathname.slice(1);
    const staticFiles = new Set(['index.html', 'app.js', 'catalog.js', 'demo.js', 'styles.css']);
    try {
      const target = path.resolve(publicRoot, filename);
      if (!staticFiles.has(filename) && !(filename.startsWith('assets/') && target.startsWith(assetsRoot + path.sep))) throw new Error('private path');
      const actual = realpathSync(target);
      if (actual !== target || !statSync(actual).isFile() || !MIME[path.extname(actual)]) throw new Error('not public');
      response.writeHead(200, { 'Content-Type': MIME[path.extname(actual)], 'Content-Length': statSync(actual).size });
      if (request.method === 'HEAD') response.end();
      else createReadStream(actual).on('error', () => response.destroy()).pipe(response);
    } catch { json(response, 404, { error: { code: 'NOT_FOUND', message: 'Archivo no disponible.' } }); }
  });
}

export function parseOptions(args, env = process.env) {
  const options = { port: Number(env.PORT || 3000), databasePath: path.resolve(env.SECTOR07_DB_PATH || defaultDatabase(env)), open: false };
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--open') options.open = true;
    else if (args[index] === '--port' && args[index + 1]) options.port = Number(args[++index]);
    else if (args[index] === '--db' && args[index + 1]) options.databasePath = path.resolve(args[++index]);
    else throw new Error(`Opción no válida: ${args[index]}. Usa --port 3000, --db "ruta.sqlite" o --open.`);
  }
  if (!Number.isInteger(options.port) || options.port < 1 || options.port > 65535) throw new Error('El puerto debe ser un número entre 1 y 65535.');
  return options;
}

export async function main(args = process.argv.slice(2)) {
  if (Number(process.versions.node.split('.')[0]) < 24) throw new Error('Se necesita Node.js 24 o superior. No hace falta ejecutar npm install.');
  const options = parseOptions(args), server = createServer(options);
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(options.port, '127.0.0.1', resolve); });
  const url = `http://localhost:${server.address().port}`;
  console.log(`\nSECTOR 07 · Archivo local\nWeb: ${url}\nSQLite (solo lectura): ${options.databasePath}\nPulsa Ctrl+C para detener el servidor.\n`);
  try { readDashboard(options.databasePath); console.log('Conexión con SQLite comprobada.'); }
  catch (error) { console.warn(error.message); }
  if (options.open) {
    const [command, launchArgs] = process.platform === 'win32' ? ['rundll32.exe', ['url.dll,FileProtocolHandler', url]] : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
    const browser = spawn(command, launchArgs, { windowsHide: true, stdio: 'ignore' });
    browser.on('error', () => console.warn(`Abre ${url} en tu navegador.`));
    browser.unref();
  }
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close());
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(error.code === 'EADDRINUSE' ? 'El puerto está ocupado. Prueba: node web/server.mjs --port 3001' : error.message);
    process.exitCode = 1;
  });
}
