# Usage

## Sessions

`fh start` runs a private server plus a graphical client. The client sits in an unfocused nested Niri window, so it never touches your desktop focus or your normal Factorio config, saves and mods.

```sh
fh start                          # session "default"
fh start --space-age --name exp   # another, independent world
fh start --save ~/saves/base.zip  # play a copy of an existing save
fh start --headless               # server only: no character, for deploys and diagnostics
fh doctor                         # can the character be controlled?
fh stop-session exp               # save, verify the ZIP, stop this session's processes
```

- Commands go to the `default` session unless you pass `--session NAME`.
- Sessions live in `.factorio-harness/sessions/` inside this repository. A name can be used once. To continue a world, start a new session with `--save` pointing at the save `stop-session` printed.
- Factorio is found in the usual Steam locations. Otherwise use `--factorio PATH` or `FACTORIO_BIN`.
- Niri needs a window rule matching `app-id="niri" title="^niri$"` with `open-focused false`. `fh start` refuses to launch without it.
- The graphical window stays usable for things without an action, such as respawning or complex GUIs.
- Known issue: outside Steam, the client joins with an empty player name. `--save` therefore rejects saves whose first player has a name.

## Your own server

Use this on other desktops, or when you host the game yourself:

```sh
fh install --mods ~/.factorio/mods   # then enable agent-harness and load the save once
export FACTORIO_RCON_PASSWORD=...     # or FACTORIO_RCON_PASSWORD_FILE
factorio --start-server save.zip --rcon-bind 127.0.0.1:27015 --rcon-password "$FACTORIO_RCON_PASSWORD"
```

- Join with a graphical client; the agent needs a living, connected character.
- Commands control player 1 unless you pass `--player N`.
- RCON has operator rights, so keep it on localhost.

## Running actions

```sh
fh call walk --args '{"direction":"east","ticks":60}' --wait
fh call status
```

- Arguments go in `--args JSON` or `--args-file F`. `fh describe` lists every action's arguments.
- Timed actions return as soon as the game accepts them. `--wait` blocks until the action finishes. It works with `walk`, `move_to`, `mine`, `build_path`, `construct`, `shoot`, `pickup` and `repair`, and with `collect`, `rearm` or `refuel` when a `radius` is given.
- With `--wait`, the command exits nonzero unless the action ended successfully (so `move_to` ending `arrived_near` counts as a failure), or when the wait times out (`--wait-timeout`, default 30 s).
- Ctrl-C does not stop an action the game already accepted. `fh call stop` does.
- Output is compact tables meant for reading. Use `--format json` for programs.

## The in-game queue

A queue plan runs inside the game, with no CLI round trip between steps:

```json
[
  {"action":"shoot","args":{"auto":true,"radius":24,"ticks":300},"wait":false},
  {"action":"walk","args":{"direction":"west","ticks":90}},
  {"action":"wait_until","args":{"until":"no_enemies","radius":24}}
]
```

```sh
fh queue submit --file plan.json
fh queue status
fh queue edit --args '{"expected_revision":7,"index":1,"remove":1,"steps":[]}' # drop the next pending step
fh queue cancel          # add --args '{"clear":false}' to keep pending steps
fh queue resume
fh queue repeat --file plan.json
```

- `"wait":false` lets a step overlap the next one, for example shooting while walking.
- `wait_ticks` and `wait_until` only work inside a queue.
- A failed step pauses the queue. Use `on_fail` (`abort`, `skip`, `goto:<label>`) and `guards` to handle failures instead.
- `queue edit` needs the current revision, so you can't accidentally edit a plan that has already moved on.
- A direct call that moves or acts as the character pauses the queue. Reads and actions like `craft` or `research` don't.

## Retries

- A dropped connection reports `outcome_unknown`. The CLI never replays the action automatically.
- Pass `--id ID` on a call to make retries safe. Repeating the same call with the same ID returns the cached result instead of running it again. The game keeps the last 256 results.
- Bridge sessions don't cache results, so a retry there runs the action again.
- Some actions, such as transfers, can partly succeed. Check the counts in the reply.
- `--journal FILE.jsonl` records every request and reply.

## Rules

Gameplay actions use the same mechanics as a human player: items come from the inventory, and reach and time apply. Nothing spawns items, teleports, or reveals the map.

Some actions work at a distance, the way a player can through remote view:

- `configure`, `requests` and `launch` in visible chunks
- ghosts and deconstruction marks in charted chunks

Not supported yet: vehicles, rails, circuit editing, and fluid transfers.

## Live reload

```sh
fh deploy   # bundle runtime.lua and its sibling modules, validate, swap in
fh watch    # deploy on every change
```

- An invalid deploy is rejected, and the old code keeps running.
- The deployed code is stored in the save and takes priority over the mod's `runtime.lua`. For an existing save, edits only take effect after a deploy.
- A runtime error quarantines the runtime. Read-only calls still work until a fixed deploy succeeds.
- Module top-level code must not touch the game. Persistent state goes in `storage.agent_harness`.
- Changing prototypes or `control.lua` still needs a game reload.
