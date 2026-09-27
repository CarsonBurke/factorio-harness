# Factorio harness

Lets an agent play Factorio 2.0 as a normal character, through a shell CLI.

The agent reads the world and gives orders with `fh` commands: walk here, mine that, craft this, paste a blueprint, defend the base. A Lua mod carries out each order tick by tick inside the game, under the same rules as a human player. There is no teleporting, no free items, and no map reveal. Items come from the inventory, reach is enforced, and combat uses real guns and ammo.

```sh
fh start --space-age                 # private server plus a graphical client, ready to play
fh observe                           # what's around the character
fh call move_to --args '{"position":{"x":40,"y":-12}}' --wait
fh call mine --args '{"position":{"x":41.5,"y":-11.5},"ticks":300}' --wait
fh call craft --args '{"recipe":"iron-gear-wheel","count":10}'
fh stop-session                      # save and shut down
```

> **Status:** usable foundation, not a finished autonomous player. The action set is broad, but no built-in policy plays a whole game on its own. That part is up to your agent.

## How it works

```text
agent ── shell ──► fh (Node CLI) ── RCON ──► agent-harness mod (Lua, in-game)
                     JSON replies ◄──────────  runs actions every tick
```

- **In game (Lua):** a small bootstrap (`control.lua`) plus a hot-swappable runtime (`runtime.lua` and sibling modules). Long-running actions such as walking, pathing, mining, building, and fighting run inside the simulation, so they need no agent round trip per tick.
- **Host (TypeScript):** `fh` handles RCON, JSON, session management, live code deployment, and PNG rendering. It has no runtime npm dependencies, no MCP server, and no LLM API key. Any agent that can run shell commands can use it.
- **Client bridge (optional, C++):** lets you play on servers you don't control. See [below](#playing-on-servers-you-dont-control).

Details: [docs/architecture.md](docs/architecture.md).

## Requirements

- Node.js 20+ and npm
- Factorio 2.0. A Steam or Flatpak install is detected automatically; otherwise pass `--factorio PATH` or set `FACTORIO_BIN`. Space Age is optional.
- For the managed graphical session (`fh start`): the [Niri](https://github.com/YaLTeR/niri) compositor, `niri-harness`, and a Niri window rule that opens nested windows with `open-focused false`. On other setups, use [manual mode](#manual-mode-your-own-server).
- For development: Lua, to run the Lua unit tests.

## Setup

```sh
npm ci
npm run build
npm link          # optional: installs the `fh` command (otherwise use node dist/host/cli.js)
```

## Sessions

`fh start` creates a self-contained world. It runs a private local server and a graphical client. The client runs inside an unfocused nested Niri window, so your desktop focus is never touched. Your existing Factorio config, saves, and mods are also left alone.

```sh
fh start                              # base game, session "default"
fh start --space-age --name exp       # a second, independent world
fh start --save ~/saves/base.zip      # play a private copy of an existing save
fh start --headless                   # server only (for deployment/diagnostics; no character)
fh doctor                             # is the runtime loaded and the character controllable?
fh stop-session exp                   # save, verify the ZIP, stop only this session's processes
```

- Commands target the `default` session automatically. Use `--session NAME` for any other session.
- Session data lives in `.factorio-harness/sessions/NAME/`. Directories are never reused. To continue a stopped world, run `fh start --name new --save <path printed by stop-session>`.
- The graphical window stays usable for things without a dedicated action, such as respawn dialogs and complex GUIs. The session reports its `niri_session`, so `niri-harness` can inspect or drive the nested window.

## Playing

### The loop

Agents work in an **observe → act → verify** loop:

```sh
fh describe                                   # every action and its arguments, from the running runtime
fh observe --args '{"radius":24}'             # nearby entities, inventory, crafting, research
fh call walk --args '{"direction":"east","ticks":60}' --wait
fh call status                                # active controls, last outcome, alerts
```

- `fh call ACTION --args JSON` runs any action. `--args-file F` reads the arguments from a file.
- Timed actions (walk, mine, move_to, construct, …) return as soon as the game accepts them. Add `--wait` to block until they finish and get the outcome, such as `arrived`, `target_mined`, or `inventory_full`. The command exits nonzero if the action fails or is interrupted.
- Pressing Ctrl-C or closing the CLI does **not** stop work the game has already accepted. Use `fh call stop` or `fh queue cancel` for that.
- Output is compact labelled tables by default, which is easy for an LLM to read. Programs should pass `--format json`.

### What the character can do

`describe` is the source of truth. It covers all argument names, limits, and result fields. Here is an overview:

| Area | Actions |
|---|---|
| Looking | `observe`, `status`, `scan`, `nearest`, `map` (charted overview), `grid` (ASCII tile map), `inspect`, `power`, `stock`, `recipes`, `craftable`, `technologies`, `screenshot` |
| Moving | `walk`, `move_to` (engine pathfinder with stall recovery), `stop` |
| Gathering | `mine`, `pickup`, `transfer`, `collect` (walks a route through machines/chests holding an item) |
| Crafting & research | `craft`, `cancel_craft`, `research`, `research_next` |
| Building | `build`, `rotate`, `configure`, `wire`, `build_path` (lay belts while walking), `belt_route` / `pipe_route` (routed placement with undergrounds), `place_ghosts`, `construct` (build all ghosts by hand from inventory), `deconstruct`, `revive_ghost` |
| Blueprints | `blueprint_import`/`export`/`list`/`delete`/`capture`/`place`, `copy`, `cut`, `paste` |
| Upkeep & analysis | `rearm`, `refuel`, `repair`, `rates` (production/consumption per minute), `bottleneck` |
| Combat | `shoot` (manual or auto-target), `kite` (hold distance while clearing), `equip`, `equipment` |
| Space Age | `requests`, `platforms`, `platform_create`, `platform_schedule`, `launch` (optionally riding along), `land` |
| Queue | `queue_submit`, `queue_repeat`, `queue_status`, `queue_edit`, `queue_cancel`, `queue_resume`, `wait_ticks`, `wait_until` |

Two helpers are also available as subcommands:

```sh
fh view --out artifacts/map.png        # schematic PNG of the observed area (north up)
fh blueprint import --file smelter.txt --args '{"slot":"smelter"}'
fh blueprint place  --args '{"slot":"smelter","position":{"x":5,"y":5},"direction":"east"}'
fh blueprint export --args '{"slot":"smelter"}' --out smelter.txt
fh blueprint inspect --args '{"slot":"smelter"}'   # relative layout + material cost
```

### The in-game queue

To react faster than a CLI round trip, submit a short plan for the game to run itself:

```json
[
  {"action":"shoot","args":{"auto":true,"radius":24,"ticks":300},"wait":false},
  {"action":"walk","args":{"direction":"west","ticks":90}},
  {"action":"wait_until","args":{"until":"no_enemies","radius":24}}
]
```

```sh
fh queue submit --file examples/skirmish.json
fh queue status                     # revision, active step, pending steps, recent results
fh queue edit --args '{"expected_revision":7,"index":1,"remove":1,"steps":[...]}'
fh queue cancel                     # stop now and drop pending steps ({"clear":false} keeps them)
fh queue resume
```

- Steps run in order. `"wait":false` lets a step overlap the next one, for example shooting while walking.
- A failed step pauses the queue. Steps can use `label` and `on_fail` (`skip`, `goto:<label>`), and `guards` can interrupt the plan when a condition fires.
- Edits must pass the current `expected_revision`. That way a plan the game has already moved past is never edited silently.
- A direct `fh call` pauses the running queue, so a stale plan can't override your latest decision. `queue_repeat` runs a plan on a loop.

### Batch and streaming

```sh
fh run --file plan.json     # a JSON array of requests, run in order; waits on timed actions; stops at the first failure
fh stream                   # JSON lines in, JSON lines out, over one persistent connection
```

## Reliability and the rules

- **Survival rules.** Every gameplay action goes through normal player mechanics. It costs items, respects reach, and takes game time. Nothing spawns items, teleports, or reveals the map. The only exception is an explicit testing opt-in (`attach` with `allow_cheat_mode`).
- **Retries and uncertainty.** Pass `--id ID` on a mutating call. If the reply is lost, the CLI reports `outcome_unknown` and does **not** replay the call. Check the game state, then retry with the same ID. The game keeps the last 256 results (up to 8 MiB), so an identical repeat returns the cached result instead of acting twice. Reusing an ID with different arguments is rejected.
- **Partial effects.** Some actions, such as a transfer, can partly succeed. Read the counts in the reply instead of assuming all-or-nothing.
- **Journal.** `--journal session.jsonl` records every request and reply. Passwords are never logged.

## Live development

The runtime can be replaced **while the game is running**, with no restart or reload:

```sh
fh deploy        # bundle runtime.lua + sibling modules, validate, hot-swap
fh watch         # redeploy on every file change
```

- A deploy with a syntax or contract error is rejected, and the old runtime keeps running.
- A successful deploy stops active controls and pauses the queue.
- The deployed bundle is saved inside the save file and reloads with it.
- If the runtime crashes during a tick, it is quarantined. `status` and `describe` report the fault, and gameplay commands are refused until a fixed deploy succeeds.
- Module top-level code must be pure: define functions and constants only, without touching the game. Persistent state lives in `storage.agent_harness`.

Changes to prototypes, mod dependencies, or `control.lua` itself still need a normal game reload.

## Manual mode (your own server)

Use this on non-Niri desktops, or to host the world yourself:

```sh
fh install --mods ~/.factorio/mods     # then enable agent-harness and load your save once
factorio --start-server save.zip --rcon-bind 127.0.0.1:27015 --rcon-password "$FACTORIO_RCON_PASSWORD"
export FACTORIO_RCON_PASSWORD=...      # or FACTORIO_RCON_PASSWORD_FILE; FACTORIO_RCON_HOST / _PORT optional
```

Join with a graphical client, because an agent needs a connected, living character. Commands target player 1 unless you pass `--player N`. RCON has full operator rights, so keep it on loopback or a trusted tunnel.

## Playing on servers you don't control

The client bridge is an `LD_PRELOAD` library for **your own** Factorio client. It turns agent commands into the same input actions the GUI sends, so the server needs no mod and no RCON, and it sees an ordinary player. **Only use it where the server's operator allows automated play.**

```sh
npm run build:bridge
fh connect --server 203.0.113.5:34197 --name mp [--player-data ~/.factorio/player-data.json] [--password-file F]
fh --session mp observe
fh --session mp call walk --args '{"direction":"east","ticks":120}' --wait
fh start --bridge --name trial         # try it against a private vanilla server first
```

The bridge supports a smaller action set: `observe`, `scan`, `walk`, `mine`, `craft`, `build`, and `stop`. It only works on Linux x86-64, and only with the specific Factorio build it was derived from (2.0.77, Steam). Design, verification, and limits: [docs/bridge.md](docs/bridge.md).

## Limitations

- No dedicated controllers yet for vehicles, rail placement, circuit-network editing, or fluid transfers. Use the graphical window for these.
- Observations are bounded in radius and count, so check the `truncated` flags. Areas under fog are not remembered from earlier sightings.
- `screenshot` needs a graphical client, and it only *requests* a capture. The file appears asynchronously in `script-output`.
- One controller per player. Agents sharing one character must coordinate outside the harness.
- On the tested Steam build, a client launched outside Steam joins with an empty player name. `fh start --save` therefore rejects saves whose player has a different name, rather than silently creating a new character. Use manual mode for those saves.

## Development

```sh
npm test                    # TypeScript build, host tests, Lua unit tests against a fake engine
npm run test:integration    # against a real Factorio engine
npm run test:bridge         # client bridge unit tests
```

Test setup, fixtures, and what has been verified on real builds: [docs/testing.md](docs/testing.md). To add an action, put a handler in the runtime's handler table, describe it in `describe`, and add a test covering both the useful behavior and the rule it must not break. See [docs/architecture.md](docs/architecture.md#hot-reload-contract).

## License

[MIT](LICENSE)
