/** Owned local sessions: graphical by default, never changing host desktop focus. */
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { access, chmod, copyFile, cp, mkdir, open, readFile, stat, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { createServer } from 'node:net';
import { createSocket } from 'node:dgram';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomBytes } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { RconClient } from './rcon.js';
import { Harness } from './harness.js';

const exec = promisify(execFile);
const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const sessions = join(project, '.factorio-harness/sessions');
const steamEnv = { ...process.env, SteamAppId: '427520', SteamGameId: '427520' };
export interface SessionOptions { name?: string; save?: string; factorio?: string; headless?: boolean; spaceAge?: boolean }
interface ProcessIdentity { pid: number; start: string }
interface State {
  name: string; directory: string; headless: boolean; status: string;
  gamePort: number; rconPort: number; passwordFile: string; config: string;
  binary: string; save: string; server?: ProcessIdentity; nested?: ProcessIdentity;
  niriName?: string; player?: number; playerName?: string; focusBefore?: unknown; focusAfter?: unknown;
}
export function validateSessionName(name: string): string {
  if (!/^[a-z0-9][a-z0-9_-]{0,47}$/.test(name)) throw new Error('Session name must be a lowercase slug of 1..48 characters');
  return name;
}
export function shellQuote(value: string): string { return "'" + value.replaceAll("'", "'\\''") + "'"; }
/** Conservative check: refuse launch unless the exact nested-window guard exists. */
export function hasUnfocusedNiriRule(config: string): boolean {
  const source = config.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
  const rules = [...source.matchAll(/(?:^|[\n}])\s*(\/-\s*)?window-rule\s*\{([^{}]*)\}/g)]
    .filter(([, disabled]) => !disabled).map(([, , body]) => body!);
  if (rules.some(body => /open-focused\s+true/.test(body))) return false;
  return rules.some(body => /match\s+app-id="niri"\s+title="\^niri\$"/.test(body)
    && /open-focused\s+false/.test(body) && !/exclude\s/.test(body) && !body.includes('/-'));
}
async function binaryPath(explicit?: string): Promise<string> {
  const candidates = [explicit, process.env.FACTORIO_BIN,
    join(homedir(), '.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Factorio/bin/x64/factorio'),
    join(homedir(), '.local/share/Steam/steamapps/common/Factorio/bin/x64/factorio'),
    join(homedir(), '.steam/steam/steamapps/common/Factorio/bin/x64/factorio')].filter((p): p is string => !!p);
  for (const candidate of candidates) {
    try { await access(candidate, constants.X_OK); return resolve(candidate); }
    catch { if (candidate === explicit || candidate === process.env.FACTORIO_BIN) throw new Error(`Factorio executable is unavailable: ${candidate}`); }
  }
  throw new Error('Set FACTORIO_BIN or --factorio to an installed Factorio executable');
}
async function identity(pid: number): Promise<ProcessIdentity | undefined> {
  try {
    const text = await readFile(`/proc/${pid}/stat`, 'utf8');
    const fields = text.slice(text.lastIndexOf(')') + 2).split(' ');
    if (fields[0] === 'Z') return undefined;
    return { pid, start: fields[19]! };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw error;
  }
}
async function owned(process: ProcessIdentity): Promise<boolean> {
  const current = await identity(process.pid);
  if (!current) return false;
  if (current.start !== process.start) throw new Error('Refusing to signal a reused process ID');
  return true;
}
async function freePort(udp = false): Promise<number> {
  if (udp) {
    const socket = createSocket('udp4');
    await new Promise<void>((resolve, reject) => { socket.once('error', reject); socket.bind(0, '127.0.0.1', resolve); });
    const port = socket.address().port;
    await new Promise<void>(resolve => socket.close(resolve));
    return port;
  }
  const server = createServer();
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Could not allocate RCON port');
  await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return address.port;
}
async function store(state: State): Promise<void> {
  await writeFile(join(state.directory, 'session.json'), JSON.stringify(state, null, 2), { mode: 0o600 });
}
function niriEnvironment(directory: string) { return { ...process.env, NIRI_HARNESS_STATE: join(directory, 'niri-state') }; }
async function stopOwned(state: State): Promise<void> {
  const errors: unknown[] = [];
  try {
    if (state.niriName && state.nested && await owned(state.nested)) {
      await exec('niri-harness', ['--json', 'session', 'stop', state.niriName], {
        env: niriEnvironment(state.directory), timeout: 20_000,
      });
    }
  } catch (error) { errors.push(error); }
  try {
    if (state.server && await owned(state.server)) {
      process.kill(state.server.pid, 'SIGTERM');
      for (let attempt=0; attempt<100 && await owned(state.server); attempt++) await delay(100);
      if (await owned(state.server)) process.kill(state.server.pid, 'SIGKILL');
    }
  } catch (error) { errors.push(error); }
  if (errors.length) throw new AggregateError(errors, 'Could not stop every owned session process');
}
async function completedSave(path: string, previous: number): Promise<boolean> {
  try {
    const info = await stat(path);
    if (info.mtimeMs <= previous || info.size < 22) return false;
    const file = await open(path, 'r');
    try {
      const tail = Buffer.alloc(Math.min(info.size, 65557));
      await file.read(tail, 0, tail.length, info.size - tail.length);
      const index = tail.lastIndexOf(Buffer.from([0x50,0x4b,0x05,0x06]));
      return index >= 0 && index + 22 <= tail.length && index + 22 + tail.readUInt16LE(index + 20) === tail.length;
    } finally { await file.close(); }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
    throw error;
  }
}

function result(state: State) {
  return { name: state.name, directory: state.directory, mode: state.headless ? 'headless' : 'graphical',
    status: state.status, player: state.player ?? 1, player_name: state.playerName, host: '127.0.0.1', port: state.rconPort, game_port: state.gamePort,
    password_file: state.passwordFile, save: state.save,
    ...(state.niriName ? { niri_session: state.niriName, niri_state: join(state.directory, 'niri-state'),
      focus_before: state.focusBefore, focus_after: state.focusAfter } : {}),
    environment: { FACTORIO_RCON_HOST: '127.0.0.1', FACTORIO_RCON_PORT: String(state.rconPort), FACTORIO_RCON_PASSWORD_FILE: state.passwordFile } };
}

export async function startSession(options: SessionOptions = {}): Promise<ReturnType<typeof result>> {
  const name = validateSessionName(options.name ?? 'default');
  const binary = await binaryPath(options.factorio);
  const headless = options.headless === true;
  let focusBefore: unknown;
  if (!headless) {
    if (!process.env.NIRI_SOCKET) throw new Error('Graphical launch requires Niri isolation (NIRI_SOCKET). Use --headless explicitly for a server only.');
    const config = join(process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config'), 'niri/config.kdl');
    if (!hasUnfocusedNiriRule(await readFile(config, 'utf8'))) {
      throw new Error('Refusing to launch without the Niri nested-window open-focused false rule; host focus must remain untouched');
    }
    focusBefore = JSON.parse((await exec('niri', ['msg', '-j', 'focused-window'])).stdout);
    await exec('niri-harness', ['--help']);
  }
  await mkdir(sessions, { recursive: true });
  const directory = join(sessions, name);
  await mkdir(directory, { mode: 0o700 }); // Never overwrite an existing session.
  const state: State = { name, directory, binary, headless, status: 'preparing', gamePort: await freePort(true),
    rconPort: await freePort(), passwordFile: join(directory, 'rcon-password'), config: join(directory, 'server.ini'),
    save: join(directory, 'world.zip'), focusBefore };
  let client: RconClient | undefined;
  try {
    const password = randomBytes(32).toString('hex');
    await writeFile(state.passwordFile, password + '\n', { mode: 0o600 });
    await chmod(state.passwordFile, 0o600);
    const mods = join(directory, 'mods');
    await mkdir(mods);
    await cp(join(project, 'mod/agent-harness_0.1.0'), join(mods, 'agent-harness_0.1.0'), { recursive: true });
    await writeFile(join(mods, 'mod-list.json'), JSON.stringify({ mods: [
      { name: 'base', enabled: true }, { name: 'agent-harness', enabled: true },
      ...['space-age', 'quality', 'elevated-rails'].map(name => ({ name, enabled: options.spaceAge === true })),
    ] }));
    await mkdir(join(directory, 'server/saves'), { recursive: true });
    await writeFile(state.config, `[path]\nread-data=__PATH__executable__/../../data\nwrite-data=${join(directory, 'server')}\n`);
    const settings = join(directory, 'server-settings.json');
    const defaults = JSON.parse(await readFile(resolve(binary, '../../../data/server-settings.example.json'), 'utf8'));
    await writeFile(settings, JSON.stringify({ ...defaults, name: `Factorio harness ${name}`, visibility: { public: false, lan: false },
      require_user_verification: false, auto_pause: false, allow_commands: 'admins-only' }));
    const common = ['--config', state.config, '--mod-directory', mods];
    if (options.save) await copyFile(resolve(options.save), state.save, constants.COPYFILE_EXCL);
    else {
      const creation = await exec(binary, [...common, '--create', state.save], { env: steamEnv, timeout: 120_000, maxBuffer: 8 * 1024 * 1024 });
      await writeFile(join(directory, 'creation.log'), creation.stdout + creation.stderr);
    }
    const log = await open(join(directory, 'server.log'), 'a', 0o600);
    try {
      const child = spawn(binary, [...common, '--start-server', state.save, '--server-settings', settings,
        '--bind', `127.0.0.1:${state.gamePort}`, '--rcon-bind', `127.0.0.1:${state.rconPort}`, '--rcon-password', password],
      { env: steamEnv, stdio: ['ignore', log.fd, log.fd], detached: true });
      await new Promise<void>((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
      state.server = await identity(child.pid!);
      child.unref();
      if (!state.server) throw new Error('Factorio server exited during launch; inspect server.log');
    } finally { await log.close(); }
    state.status = 'starting'; await store(state);
    const deadline = Date.now() + 120_000;
    while (Date.now() < deadline) {
      if (!await owned(state.server!)) throw new Error('Factorio server exited; inspect server.log');
      client = new RconClient({ port: state.rconPort, password, timeoutMs: 1000 });
      try {
        const description = await new Harness(client).request('describe');
        if (description.ok) break;
      } catch { /* Startup probe is read-only; retry on a new connection. */ }
      client.close(); client = undefined;
      await delay(250);
    }
    if (!client) throw new Error('Factorio did not become RCON-ready within 120 seconds');
    if (!headless) {
      await mkdir(join(directory, 'client'));
      const clientConfig = join(directory, 'client.ini');
      const existing = options.save ? JSON.parse(await client.command('/silent-command local p=game.players[1]; rcon.print(helpers.table_to_json(p and {name=p.name} or {}))')) : {};
      state.playerName = typeof existing.name === 'string' ? existing.name : `harness-${createHash('sha256').update(name).digest('hex').slice(0, 16)}`;
      // Factorio stores its multiplayer identity in player-data.json, not INI.
      const profile = await readFile(join(directory, 'server/player-data.json'), 'utf8').then(JSON.parse).catch(() => ({}));
      profile['service-username'] = state.playerName; profile['service-token'] = '';
      await writeFile(join(directory, 'client/player-data.json'), JSON.stringify(profile), {mode:0o600});
      await writeFile(clientConfig, `[path]\nread-data=__PATH__executable__/../../data\nwrite-data=${join(directory, 'client')}\n[graphics]\nfull-screen=false\nv-sync=false\n`);
      state.niriName = `fh-${createHash('sha256').update(project).digest('hex').slice(0, 8)}-${name}`;
      const argv = [binary, '--config', clientConfig, '--mod-directory', mods, '--mp-connect', `127.0.0.1:${state.gamePort}`,
        '--graphics-quality', 'medium', '--video-memory-usage', 'all', '--window-size', '1280x720', '--disable-audio'];
      // no-window-wait intentionally avoids niri-harness's restore_host_focus
      // path: it could steal focus if the user changes windows during startup.
      // Use the nested compositor's own Xwayland display. Native Wayland on
      // this NVIDIA setup stalls while the outer window is offscreen. Factorio's
      // v-sync must also be disabled to avoid multiplayer catch-up throttling.
      await exec('niri-harness', ['--json', 'session', 'start', state.niriName, '--root', join(directory, 'nested'),
        '--no-window-wait', '--timeout', '30', '--env', 'SDL_VIDEODRIVER=x11',
        '--env', '__GL_SYNC_TO_VBLANK=0', '--env', 'vblank_mode=0', '--env', 'SteamAppId=427520', '--env', 'SteamGameId=427520', '--cmd', 'exec ' + argv.map(shellQuote).join(' ')],
      { env: niriEnvironment(directory), timeout: 40_000 });
      const nested = JSON.parse(await readFile(join(directory, 'niri-state', state.niriName + '.json'), 'utf8'));
      state.nested = await identity(nested.pid);
      if (!state.nested) throw new Error('Nested compositor exited before graphical readiness');
      await store(state);
      let connected = false;
      const graphicalDeadline = Date.now() + 120_000;
      while (Date.now() < graphicalDeadline) {
        if (!await owned(state.nested)) throw new Error('Nested compositor exited; inspect nested/session.log');
        // Exiting the introduction is the same normal action as skipping its
        // cutscene in the client; no inventory, character, or map is created.
        const reply = await client.command('/silent-command local p=game.connected_players[1]; if p and p.controller_type==defines.controllers.cutscene then p.exit_cutscene() end; rcon.print(p and p.character and p.controller_type==defines.controllers.character and helpers.table_to_json{index=p.index,name=p.name} or "waiting")');
        if (reply.trim().startsWith('{')) {
          const ready = JSON.parse(reply);
          if (typeof existing.name === 'string' && ready.name !== existing.name) {
            throw new Error('Client did not honor the saved player identity; use a client profile matching the saved player. The source save was not changed');
          }
          state.playerName = ready.name;
          await client.command(`/silent-command game.get_player(${ready.index}).game_view_settings.show_entity_info=true`);
          state.player = ready.index; connected = true; break;
        }
        await delay(250);
      }
      if (!connected) throw new Error('Graphical client did not join with a character; inspect nested/session.log');
      state.focusAfter = JSON.parse((await exec('niri', ['msg', '-j', 'focused-window'])).stdout);
      // Never restore host focus: the user may deliberately have changed it.
    }
    state.status = 'ready'; await store(state);
    return result(state);
  } catch (error) {
    client?.close();
    if (state.niriName && !state.nested) {
      try {
        const nested = JSON.parse(await readFile(join(directory, 'niri-state', state.niriName + '.json'), 'utf8'));
        if (nested.root === join(directory, 'nested')) state.nested = await identity(nested.pid);
      } catch { /* No nested instance reached its ownership handshake. */ }
    }
    try { await stopOwned(state); } catch { /* Keep ownership record for explicit cleanup. */ }
    state.status = 'failed'; await store(state);
    throw new Error(`Session ${name} failed; evidence retained at ${directory}: ${error instanceof Error ? error.message : String(error)}`);
  } finally { client?.close(); }
}

export async function stopSession(name: string): Promise<ReturnType<typeof result>> {
  validateSessionName(name);
  const directory = join(sessions, name);
  const state: State = JSON.parse(await readFile(join(directory, 'session.json'), 'utf8'));
  if (state.name !== name || state.directory !== directory || state.passwordFile !== join(directory, 'rcon-password')) {
    throw new Error('Session ownership metadata does not match its directory');
  }
  if (state.status === 'stopped') return result(state);
  if (state.server && await owned(state.server)) {
    const password = (await readFile(state.passwordFile, 'utf8')).trimEnd();
    const client = new RconClient({ port: state.rconPort, password });
    const saved = join(directory, 'server/saves/session.zip');
    const previous = await stat(saved).then(s => s.mtimeMs).catch(() => 0);
    try {
      await client.command('/silent-command game.server_save("session"); rcon.print("queued")');
      let complete = false;
      for (let attempt=0; attempt<300; attempt++) {
        if (await completedSave(saved, previous)) { complete = true; break; }
        await delay(100);
      }
      if (!complete) throw new Error('Save did not finish; session kept running');
      state.save = saved;
    } finally { client.close(); }
  }
  await stopOwned(state);
  state.status = 'stopped'; await store(state);
  return result(state);
}

/** Credentials stay in the private file; callers read it only when connecting. */
export async function sessionConnection(name = 'default'): Promise<{host: string; port: number; passwordFile: string; player: number}> {
  validateSessionName(name);
  const directory = join(sessions, name);
  const state: State = JSON.parse(await readFile(join(directory, 'session.json'), 'utf8'));
  if (state.name !== name || state.directory !== directory || state.passwordFile !== join(directory, 'rcon-password')) {
    throw new Error('Session ownership metadata does not match its directory');
  }
  if (state.status !== 'ready' || !state.server || !await owned(state.server)) throw new Error(`Session ${name} is not running`);
  return { host: '127.0.0.1', port: state.rconPort, passwordFile: state.passwordFile, player: state.player ?? 1 };
}
