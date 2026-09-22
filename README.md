# Hivemind — a swarm of Claude Code agents in herdr

A package reproducing 1:1 a working system in which **one Claude Code (the coordinator) commands
a swarm of other Claude Codes (drones)** running in separate [herdr](https://herdr.dev) panels.
The human talks only to the coordinator and never browses drone panels.

Reading this as a Claude who is supposed to set it up on a new machine? Read **all of it** before
you start — the "Why this way and not another" section describes the traps that cost a few
burnt drones. The installer is easy; understanding the architecture is what counts.

## Installation

```bash
git clone https://github.com/jmcjm/claude-hivemind.git
cd claude-hivemind
./install.sh
```

Idempotent. Every overwritten file lands as `*.bak-<timestamp>` first. It does six things:
checks requirements, copies the skill, exposes `hive` in PATH, installs the herdr↔Claude Code
integration, appends a section to `~/.claude/CLAUDE.md`, verifies syntax.

**Requirements:** `herdr` **≥ 0.8** (tested on 0.8.2 and 0.9.1 — 0.7.5 removed `agent send` and the
top-level `wait` that the old version rode on; for herdr 0.7.x use commit `604848c`), `claude`
(Claude Code CLI), `python3`, `flock`. The herdr server must be running — check `herdr status`.

**After updating herdr, restart its server.** The update replaces only the client; the old server
keeps running, and a newer client refuses it (`protocol_mismatch`) — until the restart every drone
reads as `dead`. `herdr status` shows `restart_needed: yes`. `herdr server stop` ends every pane
process, so do it when no drone is working, then start `herdr` again. Re-run `./install.sh` too:
it refreshes the herdr↔Claude Code integration, which herdr versions along with itself.

## Verifying the 1:1 reproduction

After installation run the smoke test. It should pass **without a single manual click**:

```bash
hive coord                      # -> coord: wN:pM
# in the coordinator's Claude Code session arm: Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)
hive spawn testdrone            # -> spawn: testdrone  ws=.. pane=.. model=opus
hive task testdrone - <<'BRIEF'
# Brief: testdrone
Count the files in the home directory and report the number. Boundaries: read-only.
BRIEF
                                # -> task: testdrone <- ... (attempt 1)   <= MUST say "attempt 1"
```

Now **do not poll**. Within ~30 s the watcher should bring a notification
`HIVE-MAIL testdrone [finished] finished a turn (report: DONE)` on its own — the prompt stays untouched. Then:

```bash
hive inbox                      # -> a [finished] entry from drone "testdrone"
hive report testdrone           # -> STATUS: DONE + content
hive kill testdrone --purge      # or: hive prune, which sweeps every dead drone at once
```

If `task` showed "attempt 2/3" — the drone was losing input, but the retry mechanism worked (OK).
If no notification arrived — see "Diagnostics" below.

## What lands where

| Path | Role |
|---|---|
| `~/.claude/skills/hivemind/SKILL.md` | doctrine for the coordinator, loaded automatically |
| `~/.claude/skills/hivemind/hive` | swarm CLI (a wrapper around `herdr`) |
| `~/.claude/skills/hivemind/drone-ping.sh` | drone hook: reports end of turn / needed decision |
| `~/.claude/skills/hivemind/coord-creed.md` | the nine coordinator rules — single source of truth |
| `~/.claude/skills/hivemind/coord-creed-inject.sh` | `SessionStart` hook: after a compaction, re-injects the creed + the live board |
| `~/.claude/skills/hivemind/coord-compact-brief.sh` | `PreCompact` hook: tells the summarizer which coordination state must survive |
| `~/.claude/skills/hivemind/coord-scope.sh` | shared scoping helper — the coordinator hooks fire in one session only |
| `~/.claude/skills/hivemind/drone-settings.json` | `Stop`/`Notification` hooks **for drones only** |
| `~/.local/bin/hive` | symlink so drones have `hive` in PATH |
| `~/.claude/CLAUDE.md` | the "Hivemind" section — the coordinator's identity |
| `~/.claude/hooks/herdr-agent-state.sh` | installed by `herdr integration install claude` |
| `~/.herdr-hive/drones/<name>/` | `meta.json`, `brief.md`, `report.md` |
| `~/.herdr-hive/mail/<recipient>/` | mailboxes (file = message) |
| `~/.herdr-hive/.watch-coord`, `.watch-coord.pid` | the mail watcher's heartbeat and owner |

The global `~/.claude/settings.json` receives **only** the herdr integration hook. Swarm hooks
ride on the drones' `--settings`, so the human's session is untouched.

## Architecture

**Drone = herdr workspace = a panel with an interactive Claude Code on opus.** The workspace carries
the drone's name, so the human sees the swarm in the sidebar and can take over any panel at any time.

**Communication goes through files, not the terminal.** Brief → `brief.md`, result → `report.md`.
The TUI is read (`hive peek`) strictly for diagnosis.

**Drones call the coordinator, not the other way around.** The `Stop` and `Notification` hooks mail
the `coord` mailbox. The coordinator keeps `hive watch` armed as a Claude Code `Monitor`, which turns
every new letter into a one-line `HIVE-MAIL` notification in its session. Nothing is typed into the
coordinator's prompt, so the human can keep talking to it while drones report in — and zero polling
on the coordinator's side.

**Mail is a directory of files**, no daemon and no MTA. Atomic writes (`mktemp` + `mv`).
Recipients: `coord`, a drone name, `all`. Drones talk to each other over the same channel.

**The fleet can span machines.** `hive coord --remote <ssh-host>` on a drone machine forwards its
coord mail over ssh to the coordinator's machine, where the coordinator's watcher reports it — the
event-driven flow survives across hosts. The coordinator drives the remote fleet with plain
`ssh <host> hive spawn/task/report ...`; senders arrive tagged `<drone>@<host>`. Requirements on
the drone machine: hivemind installed, a headless herdr server (`herdr server`), non-interactive ssh.

## Why this way and not another

Each of these points comes from a burnt drone or a hung coordinator. Do not "simplify" them.

1. **`--dangerously-skip-permissions`, not `acceptEdits`.** With `acceptEdits` a drone stops at the
   first Bash question (in our case: `xargs`) and the whole swarm waits. Consequence: the drone will
   ask about nothing, so **boundaries must be in the brief** ("read-only", "zero deploys").
2. **No blocking `herdr` waits without a limit.** When a drone gets stuck, the coordinator hangs with
   it and the human loses their only interface. `hive wait` has a hard timeout and also ends on `blocked`/`dead`.
3. **The completion signal is `report.md`, not the agent status.** `idle` means only "not generating
   tokens right now" — a drone hanging on a dialog is `idle` too.
4. **Swarm variables go through `workspace create --env`**, because `agent start` (0.8) starts the
   agent in the existing root pane and has no `--env` of its own. That is how drones learn `HIVE_DRONE`.
5. **A fresh drone loses its first input** — `SessionStart` hooks clear the prompt, and `herdr agent
   prompt` without `--wait` does not confirm receipt. `hive task` confirms delivery (the status must
   jump to `working`) and retries up to 3 times.
6. **The prompt is shared with the human.** Sending Enter would send the text the human is typing
   right now. `hive task`/`say` and drone wake-ups check for this and refuse — and the coordinator's prompt is never typed into at all (point 10).
7. **But ghost text is not human text.** Claude Code suggests ready-made prompts as dimmed text
   (SGR `2`). A naive detector takes them for input and **blocks every idle drone**.
   `prompt_pending` reads `--format ansi` and counts only characters outside dim fragments.
8. **The swarm protocol sits in `--append-system-prompt`, not in the brief.** When it lived in the
   brief, drones improvised and used `hive say` instead of `hive send`, bypassing the mailbox and the safeguards.
9. **One drone wake-up per batch** (the `.wake-<who>` marker) + `flock`. Without it, five drones finishing
   at once all type into one prompt simultaneously and the result is mush.
10. **The coordinator hears mail through a Monitor, not its prompt.** Typing `HIVE-MAIL` into the
    coordinator's prompt fought the human for it: while drones reported in, the human could not talk
    to the coordinator. `hive watch` prints a pointer line per letter (never the body, to save context)
    and consumes nothing — `hive inbox` still reads and archives, so a lost notification never loses a
    letter. Monitors expire after 30 minutes, so re-arming is part of the coordinator's creed, and the
    Stop hook plus the unwatched-mail alert catch a coordinator that forgot.

## herdr 0.8.x / 0.9.x technicalities

- Public IDs are short stable handles (`w1`, `w1:t1`, `w1:p1`); IDs of closed panes are never
  reused. Always take them from JSON responses.
- `herdr agent *` commands are addressed by **agent name** (= drone name) or pane ID.
  Name: `[a-z][a-z0-9_-]{0,31}`, unique among live agents.
- `herdr agent start <name> --kind claude --pane <id>` starts in an **existing** shell pane —
  zero splits. Drone env enters via `workspace create --env`.
- `herdr agent prompt` appends Enter atomically and returns immediately; an agent at a dialog →
  `agent_blocked`, nothing gets sent. `--timeout` works only with `--wait`.
  The old `agent send` and top-level `wait` are gone since 0.7.5.
  0.9: success is reported only once the text and Enter are written — still no proof that the
  agent started a turn, so `hive task` keeps confirming delivery through the status.
- Agent arguments still cannot span lines (`invalid_agent_argument`, checked on 0.9.1) — hence the
  single-line system prompt.
- 0.9: `herdr status server` exits 0 even when no server runs. `hive sweep` and `hive prune` probe
  reachability with a real API call instead and refuse to judge drones while the server is
  unreachable; `hive status` still shows every drone as `dead` then.
- 0.9: `herdr --machine <label>` forwards CLI commands to a saved SSH machine. `hive coord --remote`
  keeps using plain ssh, which works without a saved profile on either side.
- `pane read` and `agent read` return raw text. A fresh pane can have an empty
  `--source recent` — for diagnosis use `visible`.
- `herdr pane current --current` gives the **caller's** pane (hence `hive coord`).
- The trust dialog ("Is this a project you trust?") appears for an untrusted `--cwd` **despite**
  `--dangerously-skip-permissions`; herdr reports it as `blocked` and `agent start`
  returns `agent_not_ready`. `hive spawn` detects and accepts it.
- The first spawn on a fresh machine has an extra first-run dialog —
  `hive spawn` handles it in the bootstrap the same way as the trust dialog.
- Statuses: `idle | working | blocked | done | unknown` (`dead` is added by `hive`). `done` is idle
  after work finished outside UI focus — CLI reads do not clear it.
- The official API cheat sheet: `herdr --skill`.

## Diagnostics

| Symptom | Cause | Move |
|---|---|---|
| every drone `dead` right after a herdr update | new client, old server (`protocol_mismatch`) | `herdr status` → `restart_needed: yes`; stop the old server when no drone works, start `herdr` |
| no `HIVE-MAIL` notifications | watcher not armed or expired | `hive status` → `watch: NOT ARMED`; arm `Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)`, then `hive inbox` |
| unwatched-mail alert never shows | herdr toasts off | `[ui.toast] delivery = "system"` in `~/.config/herdr/config.toml` |
| `hive task` says the drone did not start | drone hanging on a dialog | `hive peek <drone>` |
| drone `idle`, no report | considered the task done without writing | `hive say <drone> "write the report to <path>"` |
| status `dead` | drone killed or crashed | `hive revive <drone>` — conversation history survives |
| drone stuck at a dialog (`blocked`) | trust/consent dialog, or its context ran out | `hive unblock <drone>` |
| `dead` drones pile up in `status` | directories outlive the sessions | `hive prune --dry-run`, then `hive prune` |
| `hive revive` loses history | herdr integration missing | `herdr integration status` → must say `claude: current` |
| drones bypass the mailbox | old spawn without the system prompt | kill and spawn anew |

## Customization

- Drone model: `HIVE_MODEL=sonnet hive spawn <name>` (default `opus`).
- Swarm directory: `HIVE_DIR=/other/path` (consistently for all invocations).
- Language: the skill and the drones' system prompt are in English — translate `SKILL.md` and
  `$sysprompt` in the `cmd_spawn` function if the target human speaks another language.
- Tests: `tests/run.sh` — hermetic tests of the coordinator mail path against a fake herdr.
