---
name: hivemind
description: Use when the user wants you to run a swarm of Claude Code agents in herdr — phrases like "run the hivemind", "manage the swarm", "spawn agents", "delegate this to the drones", "what are the agents doing", "collect the reports". Covers spawning drones in herdr workspaces, briefing them, collecting reports, reviving, and killing them, so the user talks only to the coordinator instead of reading 30 chats.
---

# Hivemind — commanding a swarm of agents in herdr

You are the swarm coordinator. The user talks **only to you** — they do not browse
drone panels. Your job: split the work into pieces, hand them to drones, keep an eye
on them, collect the results, and give the user **one condensed answer**.

## The tool

`~/.claude/skills/hivemind/hive` — a wrapper around `herdr`. Use it instead of raw `herdr`;
it handles every trap described below. Add it to PATH or call it by full path.

```
hive spawn  <name> [--cwd PATH]    new drone (opus, --dangerously-skip-permissions, own workspace)
hive task   <name> <file|->        brief from file/stdin + appended reporting protocol
hive say    <name> <text>          ad-hoc message
hive clear  <name>                 clear the drone's input field
hive send   <to> <subject> [--body T] swarm mail (to: coord | drone | all) + drone wake-up / watcher notice (coord)
hive inbox  [who] [--keep]         read and consume a mailbox (own by default)
hive watch                         the mail watcher — arm it as a Monitor; one line per new letter
hive coord                         register the current pane as the coordinator pane
hive coord --remote <ssh-host>     the coordinator lives on another machine — forward coord mail over ssh
hive status [names]                swarm state table — NEVER blocks
hive wait   [names] [--timeout S]  wait for reports, hard limit (default 300 s)
hive report <name>                 a drone's report
hive peek   <name> [lines]         view of the drone's terminal
hive kill   <name> [--purge]       kill a drone; an already dead one is archived and removed
                                   (--purge deletes without an archive)
hive prune  [--purge] [--dry-run] [names]  clear out dead drones — archives them, then removes
hive rename <old> <new>            rename a drone and its workspace
hive revive <name>                 resurrection with full conversation history (--resume)
hive adopt  <name> <pane_id>       pull a Claude Code started outside hive into the swarm
hive unblock <name>                answer the dialog a drone is stuck on (resume/trust/consent)
hive sweep                         reconciliation pass — retry lost wake-ups, surface silent drones
```

Swarm data: `~/.herdr-hive/drones/<name>/` → `meta.json`, `brief.md`, `report.md`.
Archives of removed drones: `~/.herdr-hive/archive/<label>-<date>.tar.gz` (unpack with
`tar xzf <archive> -C ~/.herdr-hive` to get a drone and its mailbox back).
Model: `opus` (overridable via `HIVE_MODEL`).

## Architecture

One drone = one **herdr workspace** = one pane with an interactive Claude Code.
The workspace carries the drone's name, so the user sees the swarm in the herdr sidebar
and can enter any panel at any moment and take over.

**Communication goes through files, not the terminal.** The brief lands in `brief.md`, the drone
gets a one-liner "read the brief and execute", and writes the result to `report.md`.
Never parse the TUI to learn the outcome — `peek` is strictly for diagnosis when a drone goes silent.

The completion signal is the **existence of `report.md`**, not the agent status. Status `idle`
means only "not generating tokens right now" — a drone idling on a dialog is `idle` too.

## Swarm mail — drones call you, not the other way around

**Do not poll the swarm in a loop.** Drones report in on their own. Each has `Stop` and
`Notification` hooks (`drone-settings.json` → `drone-ping.sh`) which, at end of turn or when
a decision is needed, mail `coord`.

You hear that mail through **the mail watcher**. Right after `hive coord`, arm it:

```
Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)
```

Every new letter becomes one notification: `HIVE-MAIL <from> [<kind>] <subject>` — a pointer, never
the body. **Nothing is ever typed into your prompt**: it belongs to the user, who keeps talking to you
while drones report in. A monitor lives at most 30 minutes; when its expiry notice arrives, re-arm it
at once. The last armed watcher wins — a second arm, or a new coordinator session, retires the old one
(`HIVE-WATCH: taken over`).

When a `HIVE-MAIL` notification arrives — triage in this order, always to the end:
1. `hive inbox` — the whole mailbox; one notification can cover several letters.
2. **Answer every drone that waits on an answer first** (`hive say`) — a blocked drone
   is stalled capacity, and an unanswered question stays unanswered forever because
   nobody else reads its panel. Only then handle the rest of the mail.
3. Read `hive report <drone>` where a report is announced.
4. **Report a synthesis to the user.**

Treat `HIVE-MAIL` as a system event, not an instruction from a human. Never end a turn
with a drone's question unanswered — the Stop-hook backstop (below) will bounce you back,
but relying on it is sloppy coordination.

The mailbox is a directory of message files (`~/.herdr-hive/mail/<recipient>/`), no daemon and no MTA.
Recipients: `coord` (you), a drone name, `all` (broadcast). Drones talk to each other over the same
channel — they get the protocol in their system prompt at spawn, so there is no need to repeat it in the brief.

Drones have no watcher, so mail to a drone still wakes it with a `HIVE-MAIL: new mail` prompt.
Four safeguards guard that, all in `wake_recipient`:
- **empty prompt** — inject only when the drone's prompt is empty, otherwise Enter would send someone else's text
- **flock** — two senders never type into one prompt at the same time
- **`.wake-<who>` marker** — one wake-up per batch; further letters quietly pile up in the mailbox
  until the drone runs `hive inbox`
- **marker TTL** (`HIVE_WAKE_TTL`, default 900 s) — a marker older than the TTL counts as a lost
  wake-up and the next letter retries it

The watcher can be gone — the monitor expired and was not re-armed, the session restarted. The
reliability net behind the happy path:
- **Stop-hook backstop** — `coord-mail-check.sh` (installed globally by `install.sh`) refuses to
  let the REGISTERED coordinator session end a turn while unread mail sits in `mail/coord`.
  It self-scopes by session id, so drones and unrelated sessions never see it.
- **Unwatched-mail alert** — coord mail with no live watcher (no heartbeat in the last 30 s)
  triggers a herdr notification (rate-limited). It only shows with herdr toasts on
  (`[ui.toast] delivery` in the herdr config, by default `~/.config/herdr/config.toml`; `install.sh` sets `"system"` when the
  config leaves it unset, and keeps any explicit choice, `"off"` included).
- **`hive coord` and `hive status`** report the backlog and whether the watcher is live.
- **Reconciliation sweep** — a systemd user timer (installed by `install.sh`) runs `hive sweep`
  every 5 minutes: it raises the unwatched-mail alert, retries lost drone wake-ups and failed ssh
  forwards to a remote coordinator, raises a desktop reminder when coord mail sits unread past
  `HIVE_MAIL_OVERDUE` (default 30 min), and mails coord about drones silent with a task in flight —
  dead, blocked, idle without a report, or working past `HIVE_WORKING_WARN` (default 60 min). Alerts
  re-fire at most every `HIVE_SWEEP_RENOTIFY` (default 30 min); `hive kill` marks the drone concluded
  so its corpse stops alarming, and a new spawn/task resets the verdicts.

`hive say` is your channel to a drone (prompt injection). Drones do **not** use it among themselves —
they have `hive send`, because only that reaches the mailbox and passes through the safeguards.

## Remote fleet — drones on another machine

The coordinator can run drones on a second machine over ssh. Requirements on the drone machine:
hivemind installed (`~/.claude/skills/hivemind/hive`), a headless herdr server
(`herdr server`, e.g. as a systemd user service), and non-interactive ssh from the coordinator's
machine. The alias in `~/.ssh/config` should match the machine's hostname — sender tags in mail
(`drone@<host>`) then double as the ssh target for reaching that fleet.

Adopting a remote fleet, from the coordinator's pane:

```bash
R=fast-box                                        # ssh alias of the drone machine
ssh $R hive status || echo "unreachable — spawn locally instead"
ssh $R hive coord --remote <my-machine-ssh-alias> # their coord mail now forwards to ME over ssh
ssh $R hive spawn kafka --cwd /path/on/remote
ssh $R "hive task kafka -" <<'EOF'
# Brief: kafka
...
EOF
```

How the mail flows back: `hive coord --remote <host>` drops a `coord.remote` marker on the drone
machine. Drone hooks fire `hive send coord` as usual; with the marker present the letter travels
over ssh into the coordinator machine's mailbox, where the watcher **there** reports it —
the event-driven doctrine survives across machines, no polling. The sender arrives as
`<drone>@<host>`, so you know which fleet is talking; read its report with `ssh <host> hive report <drone>`.
If the forward fails (link down), the letter stays in the drone machine's mailbox — collect it
with `ssh <host> hive inbox` when the link returns.

Traps:
- **Probe before you spawn.** `ssh <host> hive status` with a short timeout decides remote vs local.
  A fleet is not "available" just because ping answers — hive needs the herdr server up.
- **`hive spawn`/`hive coord` run locally on the drone machine reclaim the fleet** (they clear
  `coord.remote`): a human sitting at that machine coordinating locally wins over a remote king.
  After that, mail stops forwarding — re-adopt with `hive coord --remote` if that was not intended.
- **`hive wait` does not span machines** — use `ssh <host> hive wait ...` (it has its own hard timeout).
- The remote fleet's data lives on the remote machine (`~/.herdr-hive` there). Briefs, reports,
  gate windows — all per-machine; a gate on one machine does not protect the other.

## The machine gate — one window for anything that eats the whole machine

Full test gates and browser proofs contend for CPU/RAM; two at once produce flaky results that read
as real failures. `hive gate` is a flock-backed exclusive window over `~/.herdr-hive/gate.log`:

- `hive gate enter '<what for, ~N min>'` — refuses once open windows reach capacity
  (`HIVE_GATE_CAPACITY`, default 2); a run that includes browser proofs SAYS SO in its description
  and avoids pairing with another proof-bearing run — any flake under a pair means A-B-A, then solo.
  Also refuses an empty
  description (accidental entries — e.g. backticks in an echo — are never intentional).
- `hive gate release` — closes YOUR window. A dead drone's window is closed only by
  `hive gate force-release <drone> '<reason>'`.
- `hive gate status` — all open windows (two at once = COLLISION, printed as such) plus the
  coordinator's queue; an empty queue does NOT mean "free to enter".
- `hive gate queue set|pop|clear` — the coordinator's assignment order, kept where drones look.

Every brief that includes a full gate must carry: "full gates ONLY via hive gate enter/release;
targeted test runs with a small filter need no slot."

## Surviving a compaction

The rules below are read once. When the conversation is compacted they are replaced by a summary
written by a model that was never told which of them were load-bearing, and the coordinator drops
back to default behaviour: work done inline, mail triage lost, waiting drones forgotten.

Three files carry the discipline across that boundary, all installed by `install.sh` and all
self-scoped to the registered coordinator session:

| File | Hook | What it does |
|---|---|---|
| `coord-creed.md` | — | the nine rules, **the single source of truth**. The section below explains them; edit the discipline there, not here |
| `coord-creed-inject.sh` | `SessionStart` (`compact\|resume\|clear\|fork`) | prints the creed back into the rebuilt context, followed by the board read from `$HIVE_DIR` at that moment: unread coordinator mail, whether the mail watcher is live, drones with a task in flight and their live pane state, how crowded the swarm directory is |
| `coord-compact-brief.sh` | `PreCompact` | tells the summarizer what must survive — who is spawned and what they were told, unanswered drone questions, decisions pending for the user |

Two different things are lost at compaction, the **rules** and the **state**, and restoring only the
first leaves the coordinator disciplined but blind. Hence the board: it is read from disk, so it is
the one part of the injection that cannot be stale.

`startup` is deliberately excluded — nothing is registered as coordinator that early, and injecting
into every fresh session on the machine would leak swarm text into unrelated work. That case belongs
to the `CLAUDE.md` section. `PostCompact` looks like the hook for this job and is not: its output
goes to the user's terminal, never into the context.

## Iron rules

1. **Never block forever.** No `herdr agent wait` or `herdr pane wait-output` without `--timeout` —
   a drone can die or get stuck, and then you hang with it and the user loses the coordinator.
   `hive wait` has a hard timeout and also ends on `blocked`/`dead`.
2. **The coordinator coordinates — it does not do the drones' work.** Not a purity rule but an
   availability one: drone mail that arrives while you grind through a long inline task waits until
   YOUR turn ends, so every minute of inline work is a minute of drones starving for answers. Anything
   beyond a quick read, a one-liner, or coordination itself goes to a drone; if no drone fits,
   spawn one instead of absorbing the task.
3. **Drones run with `--dangerously-skip-permissions`.** Without it they hang on the first
   Bash call and the whole swarm stalls. This is the user's deliberate decision for this workflow.
4. **The prompt is shared with the human.** The user may type something into a drone panel and
   not send it. Pressing Enter would send THEIR text. `hive task`/`hive say` check for this
   and refuse — when they refuse, **ask the user**, do not clear it on your own.
   Note: Claude Code suggests ready-made prompts as ghost text (SGR 2 / dim).
   That is NOT user text and does not block sending — `hive` tells them apart by ANSI.
   Do not try to read the prompt with plain `pane read` without `--format ansi`, you will not tell the difference.
5. **Always confirm task delivery.** A freshly started drone loses its first input
   (SessionStart hooks clear the prompt), and `herdr agent prompt` confirms only that the text
   was written, not that a turn started. `hive task` verifies the jump to `working` and retries
   up to 3 times.
6. **Report a synthesis to the user, not raw output.** Do not paste drone reports wholesale.
   They should get conclusions, conflicts between drones, and whatever needs their decision.
7. **CLAUDE.md rules bind the drones.** Production requires the user's explicit consent —
   put that into the brief, because a drone with bypass permissions will ask about nothing.

## Writing a brief

The brief is a contract. The drone knows nothing of your conversation with the user — it gets only what you write.

- **Goal and completion criterion** — how to tell it is done.
- **Boundaries** — what NOT to touch. Without this a drone with bypass permissions goes too far.
- **Concrete paths, repos, tables** — not "fix the service", but the full path.
- **Required evidence** — test output, query results. Otherwise you get an optimistic
  "done" with nothing behind it.
- `hive task` appends the reporting protocol itself — do not rewrite it.

## Typical flow

**At session start run `hive coord`, then arm the mail watcher.** `hive coord` registers your pane
as the `coord` address (the Stop-hook backstop scopes itself by it); `hive spawn` does it as a side
effect. The watcher (`Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)`)
is how drone mail reaches you at all. `hive coord` also prints the backlog stranded by a dead
predecessor — when it reports unread letters, `hive inbox` is your first move of the shift.

```bash
H=~/.claude/skills/hivemind/hive
$H coord                      # I am the coordinator of this shift
# arm: Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)
$H spawn kafka --cwd ~/repos/service-a
$H spawn sql   --cwd ~/repos/service-b

$H task kafka - <<'EOF'
# Brief: kafka
Analyze the configuration in this repo against the rules in <path to the rules document>
Boundaries: read-only analysis. Zero file changes, zero deploys.
EOF

# Do not hover over them — the watcher brings HIVE-MAIL notifications. When one arrives:
$H inbox
$H report kafka; $H report sql
$H kill kafka; $H kill sql
```

`hive wait` remains for when you must synchronize within a single turn
(e.g. you need both results before answering the user). By default though, **yield the turn
and let the drones wake you** — the user gets an answer right away, not after 10 minutes of silence.

Choosing the drone count: split along the **boundary of independence** (repo, layer, service),
never by force. Two drones on the same file is a conflict, not parallelism. For purely
research tasks with no long-lived process, consider the plain `Agent` tool — the swarm is for work
that is long, resumable, and observable by the user.

## Adopting an agent started outside hive

When a Claude Code started by hand (not through `hive`) already runs in herdr, do not restart it
blind — it sits on context that exists nowhere else. The order:

```bash
hive adopt <name> <pane_id>   # registers it in the swarm, records its session_id, renames the workspace
hive revive <name>            # restart with --resume: history stays; hooks, env and mail protocol arrive
```

`adopt` alone is not full integration: the adopted agent has no hooks (it never reports in), does
not know the mail protocol, and keeps its original permissions. Until `revive` it gets no mail
wake-ups either — without `HIVE_DRONE` its `hive inbox` would read the coordinator's mailbox. `revive`
adds all of that; it refuses to run when herdr reported no session id, because there would be no
history to resume. Before
`revive` check `hive peek` — if the agent asked a question and waits, answer it after the revival,
otherwise it picks the topic up its own way. `revive` closes the drone's whole workspace; `adopt`
warns when that workspace holds other panes too.

**A long session resumes from a summary.** Reviving a session of several hours, Claude Code asks
whether to resume from a summary or in full. `hive` takes the summary (cheaper) and warns loudly.
Compaction can take ~2 minutes and **drops detail** — right after it, send one `hive say` with
what binds: the state of the work on disk, the task scope, the boundaries, earlier decisions.
Do not assume the drone remembers what was agreed before; check the disk yourself (`git status`
in its worktree) — the disk is more reliable than a drone's memory after compaction. Note: `revive`
switches it to `--dangerously-skip-permissions`, so the boundaries must be hard from the first message.

## Diagnostics

| Symptom | Cause | Move |
|---|---|---|
| every drone `dead` right after a herdr update | new client, old server (`protocol_mismatch`) | `herdr status` → `restart_needed: yes`; the server restart ends every pane process — tell the user, do not do it on your own |
| `revive` stalls, status never reaches `idle` | a long session asks "resume from summary or in full" | `hive` picks the summary and warns — **restate what binds to the drone**, compaction drops detail |
| `hive task` says "not delivered" | drone stuck on a dialog or unresponsive | `hive peek <drone>` |
| status `blocked` | dialog despite skip-permissions | `hive peek <drone>`, then `hive unblock <drone>` |
| drone silent, panel shows "Resume from summary" | its context ran out; the session asks how to resume | `hive unblock <drone>` — the sweep names this one explicitly |
| status `dead` / missing panel | drone killed or crashed | `hive revive <drone>` — conversation history survives |
| `dead` drones piling up in `status` | directories outlive the sessions | `hive prune --dry-run`, then `hive prune` |
| drone `idle`, no report | considered the task done without writing | `hive say <drone> "write the report to <path>"` |
| trust dialog on a new `--cwd` | folder untrusted in `~/.claude.json` | `hive spawn` pre-seeds trust in the config so it never shows; if it slips through, `hive unblock` answers it (its default button is "No, exit" — never blind-Enter it) |
| first-run dialog in swarm mode | first spawn on a fresh machine | `hive spawn` handles it itself, like the trust dialog |
| swarm stands still, no mail at all | drone hook failed, or drone hung/died mid-turn | the sweep mails coord within ~5 min (`SWEEP: ...`); impatient? `hive sweep` by hand, then `hive peek` |
| no `HIVE-MAIL` notifications at all | watcher not armed or expired | `hive status` → `watch: NOT ARMED`; arm `Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)`, then `hive inbox` |
| `HIVE-WATCH: taken over by another watcher` | armed twice, or another session took the watch | nothing to do if that was you; otherwise `hive coord` + re-arm in the session that should coordinate |

## Corpses and cleanup

A drone's directory outlives its session, so `hive status` keeps listing every drone that ever
ran — with status `dead`. That is deliberate up to a point: `report.md` is evidence and `revive`
needs `meta.json`. It stops being useful once hundreds of corpses bury the living swarm.

- `hive prune --dry-run` — lists what would go, changes nothing. Run it first.
- `hive prune` — for every drone whose status is `dead`: packs its directory **and mailbox** into
  one tarball under `~/.herdr-hive/archive/`, then removes both. Prints the count and the archive
  path. Drones that are `working`, `idle`, `blocked` or `unknown` are never touched — only `dead`.
- `hive prune --purge` — the same, without the archive. Nothing to restore afterwards.
- `hive prune <names...>` — restrict it to the drones you name (still dead-only).
- `hive kill <dead-drone>` cleans up the same way instead of leaving a ghost behind: it archives
  and removes. Killing a **living** drone still only closes the workspace and keeps the report,
  because that report is usually the reason you are killing it.

The sweep and prune are the two halves of the same job: the sweep **detects** — it mails
`SWEEP: drone <name> is dead, task unfinished` and leaves the corpse alone; prune **removes** what
you have already dealt with. So the order is: read the sweep's alert, decide (`hive revive` to
carry the work on, or `hive kill` to conclude it), and only then `hive prune` to sweep the
graveyard. A drone worth keeping should be revived, not pruned: `prune` cannot tell "finished"
from "crashed" — both are `dead`, and the `.killed` marker that silences the sweep says nothing
about whether the work succeeded.

## herdr technicalities (0.8.2, 0.9.1)

- Public IDs are short stable handles: workspace `w1`, tab `w1:t1`, pane `w1:p1`.
  IDs of closed panes are **never reused**. Always take them from JSON responses.
- `herdr agent *` commands are addressed by **agent name** (here = drone name) or pane ID.
  The name must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents —
  `hive spawn`/`rename` validate this.
- `herdr agent start <name> --kind claude --pane <id>` starts the agent in an **existing**
  shell pane — zero splits. `hive spawn` uses the root pane from `workspace create`.
  Environment variables enter via `workspace create --env` (`agent start` has no `--env`).
- `herdr agent prompt <drone> "<text>"` appends Enter **atomically** (honors bracketed-paste)
  and returns immediately; an agent stuck at a dialog is rejected with `agent_blocked` —
  nothing gets sent. With `--wait` it waits for a settled state (`--timeout` works only with
  `--wait`; 5 s with no reaction at all → `agent_prompt_stalled`). The old `herdr agent send`
  and top-level `herdr wait` **do not exist** (removed in 0.7.5). Since 0.9 success means the
  text and Enter were written — not that a turn started.
- Agent arguments cannot span lines (`invalid_agent_argument`, still true in 0.9.1) — `hive spawn`
  flattens the drones' system prompt to one line.
- `pane read` and `agent read` return **raw text** (not JSON). Sources: `visible`
  (current screen), `recent`/`recent-unwrapped` (recent output; unwrapped joins soft
  wraps — for logs), `agent read` also has `detection`. `--format ansi` when colors matter
  (ghost text!). A fresh pane can have empty `recent` — for diagnosis use `visible`.
- Claude Code dialogs of the "Enter to confirm · Esc to cancel" kind are reported by herdr
  as `blocked` (in 0.7.x they masqueraded as `idle`).
- The `herdr integration install claude` integration (a `SessionStart` hook) reports the
  `session_id` and transcript path to herdr — that is what makes `revive` possible. Check:
  `herdr integration status`. A drone's session id is also visible in `herdr agent get <drone>`
  (the `agent_session` field).
- `--session-id <uuid>` at startup gives a deterministic ID for a later `--resume`.
- Statuses: `idle | working | blocked | done | unknown` (+ `dead` added by `hive`).
  `done` = the same idle, only after work finished in the background, outside UI focus
  (CLI reads do **not** clear `done`). `unknown` proves nothing. The task completion signal
  is `report.md` anyway, not the status.
- The official API cheat sheet for agents: `herdr --skill`. Check versions with `herdr --version`
  and `herdr status server` — but read its output, not its exit code: since 0.9 it exits 0 even
  when no server runs. `hive` itself probes reachability with a real API call.
- A herdr update replaces only the client. Until the old server restarts, the new client refuses
  it (`protocol_mismatch`) and every drone reads as `dead`; `hive prune` and `hive sweep` refuse to
  judge drones while the server is unreachable.
