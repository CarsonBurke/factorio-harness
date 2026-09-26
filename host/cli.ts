#!/usr/bin/env node
import { readFile, writeFile, cp, mkdir } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { createHash, randomUUID } from 'node:crypto';
import { RconClient, RconOutcomeUnknown } from './rcon.js';
import { Harness, type Reply } from './harness.js';
import { renderMap } from './view.js';
import { formatCompact } from './format.js';
import { bundleRuntime } from './bundle.js';
import { startSession, stopSession, sessionConnection } from './session.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const modPath = resolve(root, 'mod/agent-harness_0.1.0');
const help = `fh — Factorio agent CLI

  fh start [--name default] [--space-age]     Start graphical game without taking Niri focus
  fh start --headless                        Start only the private server
  fh stop-session [NAME]                     Save and stop only this harness session
  fh install --mods /path/to/Factorio/mods   Install bootstrap (one initial game load)
  fh doctor                                 Check connection and available actions
  fh describe                               Discover action arguments from the runtime
  fh observe [--args '{"radius":24}']        Bounded local world state
  fh call ACTION [--args JSON] [--id ID]      Execute an action; keep ID on uncertain outcomes
  fh call walk --args '{"direction":"east","ticks":60}' --wait
  fh view --out artifacts/map.png            Render a local schematic PNG, also works headless
  fh deploy [--file runtime.lua]             Validate and replace live Lua runtime
  fh watch [--file runtime.lua]              Deploy changed Lua; retain old code on invalid update
  fh blueprint import --file blueprint.txt   Import blueprint/book into a named slot
  fh blueprint export --out blueprint.txt    Export stored blueprint/book
  fh blueprint list|inspect|capture|place|copy|cut|paste --args JSON
  fh queue submit --file plan.json           Queue in-game execution; optional --args for mode
  fh queue status|edit|cancel|resume          Inspect/revise pending work; cancel controls immediately
  fh stream                                 JSON-lines requests in, replies out; one connection
  fh run --file plan.json                    Sequential actions, waits after each timed action

Options: --player N (default 1), --host HOST, --port N, --timeout MS,
         --session NAME (default: auto-use default session),
         --wait, --wait-timeout MS (default 30000), --journal PATH, --args-file PATH
         --format json|compact (default compact; stream always uses JSONL)
Credentials: FACTORIO_RCON_PASSWORD or FACTORIO_RCON_PASSWORD_FILE
Endpoint: FACTORIO_RCON_HOST (127.0.0.1), FACTORIO_RCON_PORT (27015)
Stream input: {"action":"observe","args":{},"id":"optional-stable-id"}
Plan input: [{"action":"walk","args":{"direction":"east","ticks":60}}, ...]
No automatic replay of mutations. stdout uses compact labelled tables; --format json is for programs. Diagnostics go to stderr.
`;
function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`);
  return value as Record<string, unknown>;
}
function integer(value: string | undefined, fallback: number): number {
  const result = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(result) || result < 1) throw new Error('Numeric options must be positive integers');
  return result;
}
let outputFormat: 'json' | 'compact' = 'compact';
function output(value: unknown) { process.stdout.write(outputFormat === 'compact' ? formatCompact(value) : JSON.stringify(value) + '\n'); }
async function main() {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    format:{type:'string'}, help: { type:'boolean', short:'h' }, args:{type:'string'}, 'args-file':{type:'string'}, player:{type:'string'},
    host:{type:'string'}, port:{type:'string'}, timeout:{type:'string'}, id:{type:'string'},
    file:{type:'string'}, out:{type:'string'}, mods:{type:'string'}, journal:{type:'string'},
    wait:{type:'boolean'}, 'wait-timeout':{type:'string'},
    name:{type:'string'}, session:{type:'string'}, factorio:{type:'string'}, save:{type:'string'},
    headless:{type:'boolean'}, 'space-age':{type:'boolean'},
  }});
  let command = positionals[0];
  if (!command || values.help || command === 'help') { process.stdout.write(help); return; }
  if (values.format && !['json','compact'].includes(values.format)) throw new Error('--format must be json or compact');
  outputFormat = command === 'stream' || values.format === 'json' ? 'json' : 'compact';
  if (command === 'start') {
    output({ok:true,result:await startSession({name:values.name ?? 'default',factorio:values.factorio,save:values.save,headless:values.headless,spaceAge:values['space-age']})});
    return;
  }
  if (command === 'stop-session') {
    output({ok:true,result:await stopSession(positionals[1] ?? values.session ?? values.name ?? 'default')});
    return;
  }
  if (command === 'install') {
    if (!values.mods) throw new Error('install requires --mods /path/to/Factorio/mods');
    const target = resolve(values.mods, 'agent-harness_0.1.0');
    await mkdir(dirname(target), {recursive:true});
    // No overwrite of local modifications; use deploy for runtime updates.
    await cp(modPath, target, {recursive:true, force:false, errorOnExist:true});
    output({ok:true, result:{path:target, next:'Enable agent-harness and load your save once. Runtime updates use fh deploy.'}});
    return;
  }
  if (values['args-file']) {
    if (values.args) throw new Error('Use either --args or --args-file');
    values.args = await readFile(values['args-file'],'utf8');
  }
  if (command === 'blueprint') {
    const operation = positionals[1] ?? 'list';
    if (!['import','export','inspect','list','delete','capture','place','copy','cut','paste'].includes(operation)) throw new Error('Unknown blueprint operation');
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (operation === 'import') {
      if (!values.file) throw new Error('blueprint import requires --file blueprint.txt');
      args.blueprint = (await readFile(values.file,'utf8')).trim();
    }
    if (operation === 'inspect') args.layout = true;
    values.args = JSON.stringify(args);
    positionals[1] = operation === 'inspect' ? 'blueprint_export' : ['copy','cut','paste'].includes(operation) ? operation : `blueprint_${operation}`;
    command = 'call';
  }
  if (command === 'queue') {
    const operation = positionals[1] ?? 'status';
    if (!['submit','repeat','status','edit','cancel','resume'].includes(operation)) throw new Error('queue expects submit, repeat, status, edit, cancel, or resume');
    let args = object(JSON.parse(values.args ?? '{}'),'args');
    if (values.file) args = {...args,steps:JSON.parse(await readFile(values.file,'utf8'))};
    values.args = JSON.stringify(args);
    positionals[1] = `queue_${operation}`;
    command = 'call';
  }
  const known = new Set(['doctor','describe','observe','call','view','deploy','watch','stream','run']);
  if (!known.has(command)) throw new Error(`Unknown command ${command}; use fh help`);
  let connection: Awaited<ReturnType<typeof sessionConnection>> | undefined;
  if (values.session) {
    if (values.host || values.port) throw new Error('Use --session or --host/--port, not both');
    connection = await sessionConnection(values.session);
  } else if (!values.host && !values.port && !process.env.FACTORIO_RCON_HOST && !process.env.FACTORIO_RCON_PORT && !process.env.FACTORIO_RCON_PASSWORD && !process.env.FACTORIO_RCON_PASSWORD_FILE) {
    try { connection = await sessionConnection(); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  }
  let password = connection ? undefined : process.env.FACTORIO_RCON_PASSWORD;
  const passwordFile = connection?.passwordFile ?? process.env.FACTORIO_RCON_PASSWORD_FILE;
  if (!password && passwordFile) password = (await readFile(passwordFile,'utf8')).trimEnd();
  if (!password) throw new Error('Run fh start, select --session NAME, or set FACTORIO_RCON_PASSWORD_FILE');
  const client = new RconClient({host:connection?.host ?? values.host ?? process.env.FACTORIO_RCON_HOST, port:connection?.port ?? integer(values.port ?? process.env.FACTORIO_RCON_PORT,27015), password, timeoutMs:integer(values.timeout,5000)});
  const harness = new Harness(client, integer(values.player,connection?.player ?? 1), values.journal);
  let stopping = false;
  const stop = () => { stopping = true; client.close(); };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  async function waitForAction(action: string): Promise<Reply> {
    const deadline = Date.now()+integer(values['wait-timeout'],30000);
    while (!stopping && Date.now()<deadline) {
      const status = await harness.request('status');
      const active = action === 'shoot' ? status.result?.combat : status.result?.active;
      // active may report shooting when movement has already finished.
      const stillRunning = active && (action === 'shoot' || active.kind === action);
      if (!status.ok || !stillRunning) {
        const last = action === 'shoot' ? status.result?.last_combat : status.result?.last;
        const success = ['duration_elapsed','target_mined','repair_completed','arrived'];
        if (status.ok && last?.outcome && !success.includes(last.outcome)) {
          return {...status,ok:false,error:{code:'action_interrupted',message:`Control ended: ${last.outcome}`}};
        }
        return status;
      }
      await delay(100);
    }
    throw new Error('Stopped waiting for action; inspect status. Game actions have a bounded tick duration.');
  }
  async function execute(action: string, args: Record<string,unknown>, id?: string, wait = false): Promise<Reply> {
    const requestId = id ?? randomUUID();
    let reply: Reply;
    try { reply = await harness.request(action,args,requestId); }
    catch (error) {
      if (error instanceof RconOutcomeUnknown) {
        return {id:requestId, ok:false, error:{code:'outcome_unknown', message:error.message, recovery:'Inspect status/state. Retry only the same action, args, player and ID while the dedup cache retains it.'}};
      }
      throw error;
    }
    if (wait && reply.ok && ['walk','move_to','mine','shoot','pickup','repair'].includes(action)) {
      const completion = await waitForAction(action);
      return {...reply, ok:completion.ok, result:{accepted:reply.result, completion:completion.result}, ...(completion.ok ? {} : {error:completion.error})};
    }
    return reply;
  }
  try {
    const args = object(JSON.parse(values.args ?? '{}'),'args');
    if (command === 'deploy' || command === 'watch') {
      const path = resolve(values.file ?? resolve(modPath,'runtime.lua'));
      let previous = '';
      do {
        try {
          const source = await bundleRuntime(path);
          const hash = createHash('sha256').update(source).digest('hex');
          if (hash !== previous) {
            const reply = await harness.deploy(source);
            output({...reply, source_sha256:hash});
            // Reject invalid edits once; retry connection failures on the next pass.
            previous = hash;
            if (!reply.ok && command === 'deploy') process.exitCode = 1;
          }
        } catch (error) {
          if (command === 'deploy' || error instanceof RconOutcomeUnknown) throw error;
          process.stderr.write(`watch: ${String(error)}\n`);
        }
        if (command === 'watch' && !stopping) await delay(500);
      } while (command === 'watch' && !stopping);
    } else if (command === 'stream') {
      const lines = createInterface({input:process.stdin, crlfDelay:Infinity});
      for await (const line of lines) {
        if (stopping) break;
        if (!line.trim()) continue;
        try {
          const request = object(JSON.parse(line),'request');
          if (typeof request.action !== 'string') throw new Error('action must be a string');
          if (request.id !== undefined && typeof request.id !== 'string') throw new Error('id must be a string');
          output(await execute(request.action, object(request.args ?? {},'args'),request.id as string | undefined));
        } catch (error) { output({ok:false,error:{code:'client_error',message:String(error)}}); }
      }
    } else if (command === 'run') {
      if (!values.file) throw new Error('run requires --file plan.json');
      const plan: unknown = JSON.parse(await readFile(values.file,'utf8'));
      if (!Array.isArray(plan) || plan.length > 1000) throw new Error('Plan must be an array of at most 1000 requests');
      // Validate the whole shape before executing any effects.
      const steps = plan.map((value,index) => {
        const step = object(value,`step ${index}`);
        if (typeof step.action !== 'string' || (step.id !== undefined && typeof step.id !== 'string')) throw new Error(`Invalid step ${index}`);
        return {action:step.action, args:object(step.args ?? {},'args'), id:step.id as string | undefined};
      });
      for (const [index,step] of steps.entries()) {
        if (stopping) break;
        const reply = await execute(step.action,step.args,step.id,true);
        output({step:index,...reply});
        if (!reply.ok) {process.exitCode=1; break;}
      }
    } else if (command === 'view') {
      if (!values.out) throw new Error('view requires --out path.png');
      const reply = await execute('observe',{radius:24,...args,tiles:true,resources:'tiles'});
      if (reply.ok) {
        const path = resolve(values.out);
        await mkdir(dirname(path),{recursive:true});
        await writeFile(path,renderMap(reply.result,Number(args.radius ?? 24)));
        output({ok:true,tick:reply.tick,result:{path,kind:'local-schematic',legend:'white=player, blue=iron/water, orange=copper, dark=coal, green=trees/uranium, red=enemies, tan=structures',position:reply.result.player?.position,entities:Object.keys(reply.result.entities ?? {}).length,tiles:Object.keys(reply.result.tiles ?? {}).length,truncated:reply.result.truncated ?? false,tiles_truncated:reply.result.tiles_truncated ?? false}});
      } else {output(reply);process.exitCode=1;}
    } else if (command === 'doctor') {
      const runtime = await execute('describe',{});
      const player = runtime.ok ? await execute('status',{}) : undefined;
      const fault = runtime.result?.runtime_fault || player?.result?.runtime_fault;
      const ready = runtime.ok && player?.ok === true && player.result?.supported_control === true && !fault;
      output({ok:ready,result:{runtime:runtime.result,player:player?.result},
        ...(ready ? {} : {error:player?.error ?? runtime.error ?? (fault ? {code:'runtime_fault',message:fault.message} : undefined) ?? {code:'player_not_ready',message:player?.result?.control_error ?? 'Join the server with a living player character'}})});
      if (!ready) process.exitCode=1;
    } else {
      const action = command === 'call' ? positionals[1] : command;
      if (!action) throw new Error('call requires an action; use fh describe');
      const reply = await execute(action,args,values.id,values.wait);
      if (reply.ok && action === 'blueprint_export' && !args.layout && values.out) {
        await mkdir(dirname(resolve(values.out)),{recursive:true});
        await writeFile(values.out,reply.result.blueprint+'\n');
        output({...reply,result:{...reply.result,blueprint:undefined,path:resolve(values.out)}});
      } else output(reply);
      if (!reply.ok) process.exitCode=1;
    }
  } finally {
    client.close();
    process.removeListener('SIGINT',stop); process.removeListener('SIGTERM',stop);
  }
}
main().catch(error => {
  output({ok:false,error:{code:error instanceof RconOutcomeUnknown ? 'outcome_unknown' : 'client_error',message:error instanceof Error ? error.message : String(error)}});
  process.exitCode=1;
});
