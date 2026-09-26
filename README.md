# Factorio harness

A CLI for agents to play Factorio through a real character. Gameplay runs in Lua inside Factorio; a small TypeScript process handles RCON, JSON, live deployment, and local map images. There is no MCP server, Python service, or production npm dependency.

The project targets **Factorio 2.0**. Start with the commands below; `describe` reports the running version's complete action interface. This is an initial engineering foundation, not yet a proven autonomous deathworld player.

## Quick start: graphical by default

Requirements: Node.js 20+, npm, Factorio 2.0, and Niri plus `niri-harness` for the focus-safe graphical launcher. The installed Steam/Flatpak location is autodetected. Use `--factorio /path/to/factorio` for another installation. Lua is needed for development tests.

```sh
npm ci
npm run build
node dist/host/cli.js start --space-age
node dist/host/cli.js doctor
node dist/host/cli.js observe
node dist/host/cli.js view --out artifacts/local-map.png
node dist/host/cli.js stop-session
```

`start` creates a private local server and joins it with a **graphical client** inside an unfocused nested Niri window. The outer window uses the existing `open-focused false` rule. The launcher never restores old focus, so it also respects a user changing windows during startup. It refuses an unprotected launch rather than taking focus. Your existing Factorio process, configuration, saves, and mods are not touched.

The default session is named `default`; later CLI commands connect to it automatically. Use `start --name experiment` and `--session experiment` for parallel worlds. `--space-age` enables installed Space Age dependencies; omit it for base-game starts. `--save /path/to/world.zip` loads a private copy and verifies that the client rejoins its first saved player; an identity mismatch aborts the launch. Use saves compatible with the selected base-game/Space Age profile; the launcher does not import custom mod packs. Nothing in the launcher grants equipment or research.

`stop-session [NAME]` saves the owned world, waits for a complete save, and stops only the processes recorded for that session. It reports the save path. Session directories are retained under `.factorio-harness/sessions/` and are not overwritten: to continue a stopped world, start a new name with `--save` pointing to that returned save. A PID ownership check prevents stopping an unrelated process after PID reuse.

On this workstation, the Steam executable launched outside Flatpak joins with an empty player name despite isolated profile settings. Fresh worlds and matching empty-name saves work. Existing named Steam saves currently need the manual connection path below; the launcher rejects mismatches instead of silently creating a replacement character.

For development or remote hosting, `start --headless` explicitly starts only the private server. Player actions still need a graphical client to join; headless-only mode supports runtime deployment and diagnostics immediately. On other desktops, launch Factorio normally and use the manual RCON connection below.

The examples below use `fh` for `node dist/host/cli.js`. `npm link` can install the short command. Normal movement, crafting, and inspection look like this:

```sh
fh describe
fh call walk --args '{"direction":"east","ticks":60}' --wait
fh call craft --args '{"recipe":"iron-gear-wheel","count":2}'
fh call status
fh call stop
```

## Manual connection

Requirements: Node.js 20+, npm, and Factorio 2.0. Lua is also required for the development tests. The free headless distribution can host a world, but a licensed graphical client is needed to join as a player; Space Age is needed for mecha armour.

```sh
npm ci
npm run build
node dist/host/cli.js install --mods "$HOME/.factorio/mods"
```

Enable `agent-harness` and load a save. This one-time bootstrap installation requires a game load. **Subsequent Lua runtime and module updates use `deploy` or `watch`, without restarting or reloading the save.** Changes to prototypes, mod dependencies, or the bootstrap itself still follow Factorio's normal reload requirements.

Host a local server with RCON enabled, using your own save and password:

```sh
export FACTORIO_RCON_PASSWORD='your-local-password'
factorio --start-server /path/to/save.zip \
  --rcon-bind 127.0.0.1:27015 \
  --rcon-password "$FACTORIO_RCON_PASSWORD"
```

Use a private server-settings file if needed; Factorio's multiplayer authentication settings are independent of RCON. RCON has operator privileges, so keep it on loopback or a trusted tunnel. The graphical launcher runs a private local server and joins it with a graphical client. Join once with your client so a normal player character exists. A newly created headless save has no player.

Credentials can instead come from `FACTORIO_RCON_PASSWORD_FILE`. Optional environment variables: `FACTORIO_RCON_HOST`, `FACTORIO_RCON_PORT`. Passwords are never recorded in the action journal.

Managed sessions automatically target their connected player; manual connections default to player 1. `--player N` overrides either choice. A connected, living character is required, including when the server is headless. `attach` supports an explicit testing opt-in for cheat mode. Game ticks determine action duration; a paused server cannot advance actions.

## Agent interface

Commands return JSON. Rejected actions exit nonzero. Tool arguments are discovered from the running game with `describe`, so a live extension is immediately usable without rebuilding the host.

For low overhead, `stream` keeps one authenticated RCON connection open and accepts one request per line. Each response is one line. Individual errors do not terminate the stream.

```sh
printf '%s\n' \
  '{"id":"observe-1","action":"observe","args":{"radius":16}}' \
  '{"id":"walk-1","action":"walk","args":{"direction":"east","ticks":30}}' \
  | fh stream
```

`run --file plan.json` executes a JSON array of requests sequentially, waits for timed actions, and stops on the first failure. Crafting is asynchronous: `started` reports queued crafts, not completed inventory. Observe the crafting queue before using its products. Plans are useful for deterministic sequences; an agent can adapt by inspecting each JSON response. No LLM API key or built-in model loop is required.

Pass `--journal artifacts/session.jsonl` to retain requests and replies. Create its parent directory first. Mutations accept `--id` for recovery. The game caches up to 256 recent mutation results, bounded to 8 MiB total, across runtime updates and save/load. Repeating the **identical request** with the same ID returns the cached result; reuse with changed arguments is rejected. This is a bounded deduplication window, not a forever-valid transaction log. Read-only queries are always fresh.

A lost transport response is `outcome_unknown`: the action may have run. The host **does not replay it automatically**. Inspect state and retry the same ID only while its result remains cached. The next call reconnects. Gameplay errors can have partial effects (for example, a partly fulfilled inventory transfer); inspect returned counts and state rather than assuming atomicity.

## Seeing the world

`observe` returns local visible entities, inventory, position, jobs, and research, with explicit truncation flags. Add `"tiles":true` for terrain. Queries have hard radius and count bounds; they do not reveal the whole map.

`view` renders these observations into a PNG with north up. This is a schematic, not Factorio's sprites: dark background is unknown, the white square is the character, blue/orange/black marks indicate iron/copper/coal, green indicates trees or uranium, and tan indicates structures. `view` returns the image path and compact metadata; use `observe` for full entity coordinates and details. Truncated observations produce incomplete maps.

The `screenshot` action requests a real Factorio screenshot in the graphical client's `script-output` directory. Screenshots are asynchronous and the CLI reports a request, not proof that the file exists. A headless process cannot render screenshots. Prefer structured observations and the local schematic for automation; use real screenshots when visual inspection adds information.

## Live development and recovery

```sh
# Bundle runtime.lua plus its sibling Lua modules, validate, then replace live code.
fh deploy
fh watch
# A custom runtime directory works too; control.lua is excluded from the bundle.
fh deploy --file /path/to/runtime.lua
```

The bootstrap persists a successful bundle in the save, reconstructs it during `on_load`, and keeps event registrations stable. Invalid syntax or an invalid runtime contract leaves the previous runtime active. Successful replacement stops active controls first. The watcher hashes the whole bundle, so editing a sibling module also triggers deployment. It retries failures known to precede deployment and reports rejected revisions once per content change. An uncertain deployment outcome stops the watcher; inspect the game before restarting it.

A tick-loop fault stops controls and quarantines the runtime. `describe` and `status` expose the fault; further gameplay mutations are rejected until a corrected deployment succeeds. This avoids repeated execution of broken code while keeping diagnostics available.

Runtime top-level code must be pure: no game access or storage mutation during module loading. Only function bodies may operate on the game. Deployment is trusted developer code, not a sandbox. The gameplay API excludes spawning items, teleporting, revealing the map, free crafting, and instant mining. Testing fixtures deliberately use operator commands to arrange controlled experiments; those commands are outside the gameplay interface.

## Development

```sh
npm test                  # TypeScript build, framing/recovery, Lua quoting/bundling, PNG tests
npm run test:integration  # Real Factorio engine; see docs/testing.md for fixtures
```

See [architecture](docs/architecture.md) for the boundaries and extension contract, and [testing](docs/testing.md) for evidence and limitations. The existing repository license is preserved.

## Tick queues and combat

For responsive control, submit a short plan to the **in-game queue** instead of round-tripping each movement through the agent:

```sh
fh queue submit --file examples/skirmish.json
fh queue status
# Replace the first pending step, only if the queue has not changed since revision 7:
fh queue edit --args '{"expected_revision":7,"index":1,"remove":1,"steps":[{"action":"walk","args":{"direction":"north","ticks":30}}]}'
fh queue cancel                  # Stop active controls and discard pending work
fh queue cancel --args '{"clear":false}'  # Stop and retain pending work, paused
fh queue resume
fh call stop                     # Emergency stop also pauses pending work
```

Queue status includes a revision, active job, pending jobs, and the last 64 results. Pending edits require the current revision so an old observation cannot silently edit a different plan. `queue_submit` appends by default; `mode:"replace"` replaces only pending steps. Cancel explicitly to interrupt the active step. A failed step pauses the queue with the remaining plan intact. Reload and direct gameplay commands also pause queued execution so stale plans do not override the next decision.

By default a step waits for its timed control to finish. `wait:false` lets shooting overlap movement. The queue accepts at most 128 pending steps with a 1 MiB argument budget and executes at most four instant steps per game tick. `wait_ticks` is a queue-only simulation delay. The queue is for a short control horizon; agents should inspect observations and job outcomes, then revise it. It does not infer success from arrival time or navigate around obstacles automatically.

`shoot` applies normal shooting input on each tick using equipped weapons and ammunition. Auto targeting chooses local hostile targets; aim, range, cooldown, collision, damage, shields, and ammunition remain engine-controlled. A movement command does not cancel firing; `stop` cancels both. Equipment and armour are managed using owned inventory items. Mecha armour requires Space Age and an explicitly provisioned start; the harness does not grant it through gameplay commands. Vanilla starts use the same tools.

## Blueprints, ghosts, and construction

The runtime exposes `blueprint_import`, `blueprint_export`, `blueprint_list`, `blueprint_capture`, `copy`, `cut`, `blueprint_place`, `paste`, `deconstruct`, `cancel_deconstruction`, and `revive_ghost`. Use `describe` for exact argument names.

Blueprints use native Factorio strings and persistent named slots, including books and nested selection. Copy captures real entities and their settings; cut captures first and marks originals for normal deconstruction. Paste creates ghosts; it never creates free finished structures. `revive_ghost` uses an owned matching-quality item and ordinary cursor placement within character reach. Construction robots can build ghosts and remove deconstruction-marked entities normally.

Rotation and flips go through the engine's blueprint placement. Grid snapping is disabled on the temporary paste copy so the supplied position is explicit; the original string and its grid settings remain intact for export. Spatial actions are bounded to the currently visible local area. Imports and books have explicit size limits. Cursor-based operations require an empty cursor and restore borrowed stacks; an occupied cursor produces a recoverable error instead of discarding the player's items.

Blueprint file convenience commands avoid putting large strings in shell arguments:

```sh
fh blueprint import --file smelter.txt --args '{"slot":"smelter"}'
fh blueprint place --args '{"slot":"smelter","position":{"x":5,"y":5},"direction":"east"}'
fh blueprint export --args '{"slot":"smelter"}' --out artifacts/smelter.txt
```

Any call also accepts `--args-file request-arguments.json`. Blueprint books use `book_path` to select nested 1-based inventory slots. `build` reports consumed items and the actual placed entity position: use that returned position for later transfers because the engine can snap input coordinates to the placement grid.

Closing the CLI or pressing Ctrl-C does not cancel work already accepted by the game. Use `fh queue cancel` or `fh call stop` to stop controls. Standalone input actions expire after at most 600 ticks; queued plans continue independently until completion, cancellation, a runtime fault, or loss of the connected character.

The graphical window remains available for normal GUI operations that do not yet have dedicated actions, including respawn dialogs and complex editors. A managed session also reports its private `niri_session` and `niri_state` directory; `niri-harness` can inspect or operate that nested session without sending input to the host desktop. Check `niri-harness --help` for its observation and input commands. Vehicles, arbitrary circuit editing, automatic navigation, and autonomous deathworld tactics are not yet implemented as dedicated controllers.

### Compact agent output

Use `fh observe --format compact` for labelled observations with shared column
headers for entity and inventory rows. Nested coordinates become `position.x`
and `position.y` columns. All returned fields remain visible, including request
IDs, errors and truncation flags; `<absent>` marks a missing table cell. Strings
containing whitespace or delimiters are quoted and escaped. This is a display
format, not a serialization contract.

Compact output is the default. Programs that parse CLI replies must request
`--format json` explicitly. `fh stream` always emits JSONL, even with `--format compact`. The RCON
protocol and journals stay JSON. Narrow observations with `entity_names`,
`entity_types`, `exclude_resources`, and `radius` to avoid requesting irrelevant
state in either format. No implicit delta cache hides changes between calls.

Observations summarize connected resource tiles as `resource_patches` by default,
so a large deposit cannot crowd machines out of the entity limit. Each row gives
observed tile count, amount and bounding coordinates; it covers only the visible
portion inside the requested radius, and the bounding rectangle can contain gaps.
Use `resources: "tiles"` when individual ore tiles are needed or `"none"` to omit
resources. Entity rows include native operating status, including `no_power`.

`fh blueprint inspect --args '{"slot":"clipboard"}'` returns Factorio's normalized
relative layout and material costs without a base64 export string. Native cursor
placement can snap and center the layout: always use returned ghost coordinates
when connecting a placed blueprint to existing infrastructure. Inspection uses
the existing read-only export operation, so errors do not interrupt active controls.
