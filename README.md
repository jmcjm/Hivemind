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
`tmux` is optional: only reading an account's limits needs it (`hive usage`, `hive accounts` and the
automatic account selection — "Several Claude Code accounts" below).

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
Count the files in the home directory and report the number.
## Boundaries
Read-only: change nothing.
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
| `~/.claude/skills/hivemind/coord-creed.md` | the thirteen coordinator rules — single source of truth |
| `~/.claude/skills/hivemind/coord-creed-inject.sh` | `SessionStart` hook: after a compaction, re-injects the creed + the live board |
| `~/.claude/skills/hivemind/coord-compact-brief.sh` | `PreCompact` hook: tells the summarizer which coordination state must survive |
| `~/.claude/skills/hivemind/coord-scope.sh` | shared scoping helper — the coordinator hooks fire in one session only |
| `~/.claude/skills/hivemind/drone-settings.json` | `Stop`/`Notification` hooks **for drones only**; auto-compaction off |
| `~/.claude/skills/hivemind/coord-settings.json` | loaded by `hive coord-start` only: auto-compaction with a 400k window, the context guard |
| `~/.claude/skills/hivemind/coord-context-guard.sh` | coordinator `Stop` hook: asks to save the state once the context nears compaction |
| `~/.claude/skills/hivemind/coord-CLAUDE.md` | the template `install.sh` copies to `~/.herdr-hive/coord/CLAUDE.md` |
| `~/.claude/skills/hivemind/accounts.conf.example` | commented example of the accounts file — never read by `hive` |
| `~/.claude/skills/hivemind/clickup.sh`, `clickup-sync.sh` | optional ClickUp task tracking: `hive ct`, the brief's task gate, reports applied to their tasks |
| `~/.claude/skills/hivemind/clickup.conf.example`, `taxonomy.tsv.example` | commented examples of the ClickUp config and tag taxonomy — never read by `hive` |
| `~/.herdr-hive/clickup/` | optional, written by you: `config` and `taxonomy.tsv` turn ClickUp tracking on; the sync keeps its cache, state and log here |
| `~/.local/bin/hive` | symlink so drones have `hive` in PATH |
| `~/.claude/CLAUDE.md` | the "Hivemind" section — the coordinator's identity |
| `~/.claude/hooks/herdr-agent-state.sh` | installed by `herdr integration install claude` |
| `~/.herdr-hive/drones/<name>/` | `meta.json`, `brief.md`, `report.md` |
| `~/.herdr-hive/mail/<recipient>/` | mailboxes (file = message) |
| `~/.herdr-hive/coord/` | the coordinator's working directory (`hive coord-start`) with its own short `CLAUDE.md` |
| `~/.herdr-hive/rules/` | boundary blocks for the `Rules:` line of a brief (`common.md` + one file per block) |
| `~/.herdr-hive/.context-guard` | the context guard's state: which session was warned in this epoch |
| `~/.herdr-hive/.watch-coord`, `.watch-coord.pid`, `.watch-coord.last` | the mail watcher's heartbeat, owner, and the moment the last one stopped |
| `~/.herdr-hive/accounts.conf` | optional, written by you: the accounts drones may take, their order and thresholds |
| `~/.herdr-hive/usage-cache.json` | the last `/usage` measurement of each listed account |
| `~/.herdr-hive/usage-cwd/` | the empty directory `/usage` is measured in — the only one a measurement pre-trusts |
| herdr config (`$HERDR_CONFIG_PATH`, default `~/.config/herdr/config.toml`) | read, never written: `install.sh` warns when herdr toasts or sounds would announce every drone turn |

The global `~/.claude/settings.json` receives **only** the herdr integration hook. Swarm hooks
ride on the drones' `--settings`, so the human's session is untouched.

## Architecture

**Drone = a tab in its coordinator's workspace = a panel with an interactive Claude Code on opus.**
Each front is one workspace in herdr's sidebar — the coordinator and a tab per drone, named after it —
so the human sees who works for whom and can take over any panel at any time. Without a living local
coordinator, or with `HIVE_DRONE_LAYOUT=workspace`, a drone gets a workspace of its own. Closing a
drone closes its tab, never the coordinator's workspace.

**Communication goes through files, not the terminal.** Brief → `brief.md`, result → `report.md`.
The TUI is read (`hive peek`) strictly for diagnosis.

**Drones call the coordinator, not the other way around.** The `Stop` and `Notification` hooks mail
the `coord` mailbox. The coordinator keeps `hive watch` armed as a Claude Code `Monitor`, which turns
every new letter (or burst of letters) into a one-line `HIVE-MAIL` notification in its session; a
turn a drone ended without a report stays quiet (see "The coordinator session"). Nothing is typed into the
coordinator's prompt, so the human can keep talking to it while drones report in — and zero polling
on the coordinator's side.

**While the coordinator listens, the swarm never pings the human.** Drones report only to the
coordinator: no desktop notification from the drone hooks, no `PushNotification` tool, and Claude
Code's own notifications off in `drone-settings.json`. The human hears from hive only when nobody
hears the swarm: coord mail with no live watcher for `HIVE_UNWATCHED_GRACE` (default 5 min — a
monitor re-arm is seconds), or mail unread past `HIVE_MAIL_OVERDUE` (default 30 min) while the
coordinator is not working. Before that the watcher reminds the coordinator itself
(`HIVE_MAIL_REMIND`, default 10 min). A coordinator mid-turn keeps the overdue alert quiet only
until that mail is `HIVE_MAIL_OVERDUE_BUSY` old (default 2 h): a pane "working" that long over
waiting mail is stuck. The grace is a trade-off — it ignores what the coordinator is doing, so a
blocking call that outlasts it after the monitor expired can still ping you, and a longer grace
notices a dead coordinator later. All four are set in whole seconds. The alert goes through the
desktop notifier: `notify-send`, then `osascript` when the first is missing or fails. Only a
machine with neither gets a herdr toast instead, and herdr reports that as shown once a client has
it, even when `[ui.toast] delivery` makes the client drop it or draw it inside the terminal.

herdr's own notifications cannot be limited to the coordinator's pane: with `[ui.toast] delivery`
on or `[ui.sound]` on (herdr's default), herdr announces every turn every drone ends. Keep both off
— earlier `install.sh` versions set `delivery = "system"` themselves; the installer now only reads
the config and warns.

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
4. **Swarm variables go through `tab create --env`** (or `workspace create --env`), because `agent
   start` (0.8) starts the agent in the existing root pane and has no `--env` of its own. That is how drones learn `HIVE_DRONE`.
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
  zero splits. Drone env enters via `tab create --env` / `workspace create --env`.
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

## The coordinator session

The coordinator's context is what runs out first: every notification, every report and every
`CLAUDE.md` it carries costs it on each turn. Measured on one swarm it grew by ~90k tokens per hour.
Three things keep it small.

**Quiet mail.** A turn a drone ended without a report — almost always a drone waiting on its own
tests or CI — still lands in the mailbox and shows in `hive inbox`, but wakes nobody: the watcher
prints nothing for it, the Stop backstop and the reminders do not count it. A drone that stays stuck
that way is the sweep's to report, once. Letters that arrive within a few seconds of each other share
one notification line, and the sweep sends one alert per drone and state instead of one every half
hour. A drone whose Claude Code still runs background shells (found through `/proc`, Linux only) is
waiting, not stalled.

**Its own directory.** `hive coord-start`, run in a plain herdr shell pane, registers that pane as the
coordinator's, enters `~/.herdr-hive/coord/` and starts Claude Code there with
`--settings ~/.claude/skills/hivemind/coord-settings.json`. Claude Code sends the `CLAUDE.md` of its
working directory with every request; a project's can be 100 KB the coordinator never needs.
`install.sh` puts a short template there once — edit it, it is yours. Restart the same way:
`hive coord-start -- --continue` (anything after `--` goes to `claude`). `--dry-run` prints the command.

**Auto-compaction for the coordinator only.** Drones keep it off: `drone-settings.json` says
`"autoCompactEnabled": false` itself, whatever the user's settings say. `coord-settings.json`
turns it on for the coordinator with a 400k window and wires a Stop hook, `coord-context-guard.sh`.
Once the last call's input passes `HIVE_COORD_WARN_TOKENS` (330k) the guard holds ONE end of turn and
asks the coordinator to save its state — drones in flight, what each was told, decisions pending —
before the compaction summarises it away. It warns once per epoch; the epoch ends when the context
falls under the threshold again.

> **The window is set in the `env` block, not only as a key.** A `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
> variable in the environment beats the `autoCompactWindow` key of any settings file, and herdr panes
> inherit the environment of the shell that started the herdr server. The `env` block of a
> `--settings` file beats the inherited variable, so `coord-settings.json` sets
> `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` there. Idle compaction comes with auto-compaction;
> `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=330000` keeps it from compacting an idle session before the
> guard asked for the save.

Moving a running coordinator: save its state, let it end its turn, run `hive coord-start` in a new
pane (the registration moves at once), read the state back there, then `/exit` the old session —
and keep its workspace open while its tabs hold drones.

## Fronts: several coordinators on one machine

One coordinator for every domain at once interleaves their decisions in one conversation, talks to
thirty drones and has no time left for you. A **front** is an independent swarm with a coordinator of
its own — its drones, mail, watcher and alerts — while the machine's resources stay shared: the gate,
the accounts and their limits, the boundary blocks, and drone names (herdr's agent names are
machine-wide).

```bash
hive front add wms "Warehouse: the WMS API and the scanner app"   # ~/.herdr-hive/fronts/wms
hive --front wms coord-start                                       # in a new plain herdr pane
hive fronts                                                        # every front at a glance
hive send shp:coord "the label format changed" --body "..."        # to another front's coordinator
hive move picker wms                                               # hand a drone to another front
```

The default front is `~/.herdr-hive` itself, so a hive without fronts — and a swarm already running —
is untouched. A front's coordinator runs in `~/.herdr-hive/coord/<front>/` and reads the shared
`coord/CLAUDE.md` above it as well as its own. `coord-start` and `spawn` pin the coordinator and its
drones to their front through `HIVE_FRONT`; a coordinator registered by hand is found through its
pane. The hooks, the sweep timer and the alerts each act on the front they belong to. Details and
traps: SKILL.md, "Fronts".

## Boundaries in files

Drones run with bypass permissions and ask about nothing, so every brief needs its boundaries — and
retyping the same block into every brief wastes the coordinator's context. Keep the blocks in
`~/.herdr-hive/rules/` and write one line:

```markdown
# Brief: fix the flaky export test
Rules: repo review
...
```

`hive task` replaces the line with a `## Boundaries (absolute)` section holding `common.md` (always,
first), then `repo.md` and `review.md`. If the brief has its own `## Boundaries` section, the blocks
go to the top of it. A brief with neither the line nor such a section is refused, so is one naming a
block that does not exist; `HIVE_NO_RULES=1` lets a brief through on purpose. A refused brief never
replaces the drone's current one. Lines in code fences are text, not directives; every other line
starting with `Rules:` is one, a list item too, so reword a sentence that starts that way. An example
`common.md`:

```markdown
- Work only in your own clone or worktree; other repositories and other drones' directories are read-only.
- Commits on your branch only. No push, PR, merge or tag unless this brief says so.
- No writes to production, no production credentials.
- Delete only literal paths or "${VAR:?}", never a bare variable.
- Never quote passwords, tokens or keys in a report.
```

## Task tracking in ClickUp (optional)

Off unless `~/.herdr-hive/clickup/config` exists. Turned on, every brief names its ClickUp task, the
modules it works in and the ones it affects; `hive task` refuses a brief whose task is closed, belongs to
another front or collides with a task in progress in the same modules (unless the brief says why it does
not clash), and drone reports reach their tasks by themselves — a comment with the result and PRs, and
the status. Setup: copy `skill/clickup.conf.example` and `skill/taxonomy.tsv.example` to
`~/.herdr-hive/clickup/config` and `taxonomy.tsv`, fill them in, run `hive ct sync`. Details:
"Task tracking in ClickUp" in `SKILL.md`. Tests: `tests/clickup/test-clickup.sh` (a fake ClickUp API).

With `decision_list` in the config, the questions a coordinator waits on from the owner are tasks on a
list of their own (`hive ct decision`). hive numbers each one `D-<n>`: one counter for every front, never
reused, not even after the answer, so the owner answers "D-7 ok". A question numbered by hand is
refused, and decisions from before the numbering get theirs with `hive ct decision number --yes`. The
next number is the highest on the list or the highest kept in `~/.herdr-hive/clickup/decision.last`,
so a deleted or archived decision does not give its number back. The counter and that file are per
machine; coordinators on two machines are not covered.

## Watching outside sources

A coordinator that polls something outside the swarm from a session cron — a chat, a ticket
tracker, a CI dashboard — pays a turn for every check, and nearly every check finds nothing. Move
the polling out of the session: a systemd user timer runs a script, and the script writes to the
coordinator only when something happened:

```bash
hive send coord "CHAT: <who> <first words>" --body "<full text, where it came from>" </dev/null \
  && <move the script's own "seen up to" marker>
```

hivemind ships no such script — what to read and how is specific to each source — but the ones that
work share a shape:

- **Mail only on an event, never "nothing new".** The letter is loud and wakes the coordinator; a
  silent run costs nothing.
- **Move your marker only after a delivered letter.** `hive send` exits non-zero when the letter did
  not reach the mailbox; a script that ignores that loses the message.
- **Count failures, mail the outage once.** After N failed runs in a row send one `<SOURCE> DOWN:
  <first error>` and keep a marker so it is not repeated; the first good run sends `<SOURCE> OK again`
  and clears it. An expired login otherwise looks exactly like a quiet day.
- **Run it read-only.** A headless `claude -p` reader gets an allow-list of read tools, everything else
  denied, and the script refuses to start when inherited settings allow more.
- **With fronts, the script picks the front.** `HIVE_FRONT=<front> hive send coord ...` lands in that
  front's coordinator mailbox; `~/.herdr-hive/fronts/<front>/description` is the one line to classify
  against. A timer that names no front writes to the default one.

## Several Claude Code accounts

A fleet burns one subscription's limits in hours. `hive` can run drones on other Claude Code logins
and choose, at every spawn, the one that still has room. All of it is optional: **without
`~/.herdr-hive/accounts.conf` nothing changes** — a drone runs on the default account (`~/.claude`)
unless `--account` or `HIVE_ACCOUNT` names another.

**Requirements:** one config directory per extra account, and `tmux` for the automatic selection —
an account's limits are read from the `/usage` panel: `hive` opens a throwaway Claude Code session in
tmux, types `/usage` and reads the answer. That session runs in `~/.herdr-hive/usage-cwd`, an empty
directory of hive's own, and a measurement adds one entry to the measured account's `.claude.json`:
trust for that directory, so no trust dialog stands in the way. It never trusts `$HOME` or a
project.

**1. Prepare an account directory.** A named account is `~/.claude-<name>`: its own login and its own
`.claude.json`, everything else symlinked into `~/.claude`, so every account runs the same
instructions, hooks, skills and plugins and sees the same session transcripts:

```bash
mkdir -m 700 ~/.claude-alt
for f in CLAUDE.md settings.json skills plugins projects; do ln -s ~/.claude/$f ~/.claude-alt/$f; done
CLAUDE_CONFIG_DIR=~/.claude-alt claude      # once, interactively: onboarding + /login
hive usage --account alt                    # the account answers: its session and weekly limits
```

**2. Use it by hand** — no config needed: `hive spawn <name> --account alt`, or `HIVE_ACCOUNT=alt`
for every new drone. `hive revive <name> --account alt` moves an existing drone there, history included.

**3. Let `hive` choose.** List the accounts in your order of preference, each with the share of its
weekly limit it may be used up to:

```bash
cp ~/.claude/skills/hivemind/accounts.conf.example ~/.herdr-hive/accounts.conf   # then edit
hive accounts --refresh         # measure every listed account and show the table
hive accounts --pick            # the account a spawn would take right now, and why
```

```
max_age = 10                                        # minutes a /usage measurement stays good for a spawn
account alt      prio=1  week_threshold=80          # ~/.claude-alt: taken first, up to 80% of its week
account default  prio=2  week_threshold=60  hard    # ~/.claude: never past 60%
```

From then on `hive spawn <name>` without `--account` lands on the lowest `prio` that is under its
threshold and says why (`spawn: account alt — prio 1, session 24%, week 60%, under its threshold
(week 80%)`), and `hive revive` moves a drone off an account that ran out of room — only to one that
shares `projects/`, so the history comes along. When no account has room, spawn starts nothing and
names the account that gets room first. Precedence: `--account` > `HIVE_ACCOUNT` > the pick.

The table, the selection rules and the traps: "Several Claude Code accounts" and "Which account a
drone lands on" in `skill/SKILL.md`.

## Diagnostics

| Symptom | Cause | Move |
|---|---|---|
| every drone `dead` right after a herdr update | new client, old server (`protocol_mismatch`) | `herdr status` → `restart_needed: yes`; stop the old server when no drone works, start `herdr` |
| no `HIVE-MAIL` notifications | watcher not armed or expired | `hive status` → `watch: NOT ARMED`; arm `Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)`, then `hive inbox` |
| unwatched-mail alert never shows | no desktop notifier (`notify-send` / `osascript`), so the alert is a herdr toast that herdr drops or keeps inside the terminal; or the notifier cannot reach a desktop session | install `libnotify` (`notify-send`); the alert also waits `HIVE_UNWATCHED_GRACE` (5 min) before it fires. `journalctl --user -u hive-sweep` shows each alert the sweep raised and its channel, `NOT delivered` when the notifier failed. A sweep run from cron has no session bus: give it `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus` |
| a desktop ping for every drone turn | herdr's own toasts or sounds for background agents | `[ui.toast] delivery = "off"` and `[ui.sound] enabled = false` in `~/.config/herdr/config.toml`, then `herdr server reload-config` — a running server keeps the config it started with |
| `hive task` says the drone did not start | drone hanging on a dialog | `hive peek <drone>` |
| `hive task` refuses: `brief has no boundaries` / `no boundary block for` | no `Rules:` line and no `## Boundaries` section, or a block missing in `~/.herdr-hive/rules/` | add the line or the section; the message lists the blocks there. `HIVE_NO_RULES=1` skips the check on purpose |
| the coordinator does not compact at its 400k window, or the guard never warns | started without `coord-settings.json` (a bare `claude --resume`) | restart with `hive coord-start -- --continue` |
| a drone waiting on its tests is reported as idle | its background shells were not found (no `/proc`, or another Claude Code process layout) | `journalctl --user -u hive-sweep` says `waits on N background shell(s)` when they are found |
| drone `idle`, no report | considered the task done without writing | `hive say <drone> "write the report to <path>"` |
| status `dead` | drone killed or crashed | `hive revive <drone>` — conversation history survives |
| drone stuck at a dialog (`blocked`) | trust/consent dialog, or its context ran out | `hive unblock <drone>` |
| `dead` drones pile up in `status` | directories outlive the sessions | `hive prune --dry-run`, then `hive prune` |
| `hive revive` loses history | herdr integration missing | `herdr integration status` → must say `claude: current` |
| drones bypass the mailbox | old spawn without the system prompt | kill and spawn anew |
| `hive accounts` shows `no data — measurement failed: …` | tmux missing, Claude Code slower than `HIVE_USAGE_TIMEOUT`, or a `/usage` panel the parser does not know | the status names the cause; an unknown panel is kept in `~/.herdr-hive/usage-panel-<account>.txt` |
| spawn refuses: `no account is selectable` | every listed account is full, over a `hard` threshold or `disabled` | wait for the reset the message names (`hive accounts`) |
| spawn refuses: `account NAME has no room` | the account named with `--account` or `HIVE_ACCOUNT` is full, over its threshold or `disabled`; a drone started there would take its brief and sit on the usage-limit screen | wait for its reset, pick another account, or pass `--force` |

## Customization

- Drone model: `HIVE_MODEL=sonnet hive spawn <name>` (default `opus`).
- Claude Code account: `hive spawn <name> --account alt` runs the drone with `CLAUDE_CONFIG_DIR=~/.claude-alt`
  (`HIVE_ACCOUNT=alt` for every new drone); `~/.herdr-hive/accounts.conf` lets `hive` pick the account
  with room. Setup: "Several Claude Code accounts" above.
- Limit measurement: `HIVE_USAGE_TIMEOUT=<seconds>` bounds each step of a `/usage` measurement,
  for `hive usage` and `hive accounts` alike (default 45).
- Swarm directory: `HIVE_DIR=/other/path` (consistently for all invocations).
- Mail watcher: `HIVE_WATCH_ALL=1` makes quiet letters loud again; `HIVE_WATCH_COALESCE` (3 s of quiet)
  and `HIVE_WATCH_COALESCE_MAX` (15 s) bound how long a burst is gathered into one line.
- Sweep: `HIVE_SWEEP_RENOTIFY` (3600 s) before the same alert comes again, `HIVE_SWEEP_BGWAIT` (7200 s)
  before a drone waiting on background shells is reported, `HIVE_SWEEP_NOSCAN` (6) failed `/proc`
  scans in a row before the coordinator hears that the sweep cannot tell.
- Boundaries: `HIVE_RULES_DIR` (default `~/.herdr-hive/rules`).
- Coordinator session: `HIVE_COORD_DIR` (default `~/.herdr-hive/coord`), `HIVE_COORD_MODEL` (default
  `opus`); in `coord-settings.json` the window, `HIVE_COORD_WARN_TOKENS`, and `HIVE_COORD_GUARD_MSG` for
  the guard's text (`{k}` = context in thousands) — name the place you keep the coordinator state there;
  `HIVE_COORD_GUARD_NOTIFY=0` keeps the guard off the desktop (no notification when it holds a turn).
- Language: the skill and the drones' system prompt are in English — translate `SKILL.md` and
  `$sysprompt` in the `cmd_spawn` function if the target human speaks another language.
- Tests: `tests/run.sh` — hermetic tests of the coordinator mail path and of account handling against a fake herdr;
  `tests/accounts/test-accounts.sh` — the accounts table, the selection and the `/usage` parser against a
  fake tmux and captured panels; `tests/ctx/test-ctx.sh` — quiet mail and coalescing, sweep
  deduplication and background shells, `Rules:` expansion, `coord-start`, the context guard and the
  backstop. None starts a real session.
