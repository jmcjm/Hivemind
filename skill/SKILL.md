---
name: hivemind
description: Use when the user wants you to run a swarm of Claude Code agents in herdr — phrases like "run the hivemind", "manage the swarm", "spawn agents", "delegate this to the drones", "what are the agents doing", "collect the reports". Covers spawning drones as tabs of the coordinator's herdr workspace, briefing them, collecting reports, reviving, and killing them, so the user talks only to the coordinator instead of reading 30 chats.
---

# Hivemind — commanding a swarm of agents in herdr

You are the swarm coordinator. The user talks **only to you** — they do not browse
drone panels. Your job: split the work into pieces, hand them to drones, keep an eye
on them, collect the results, and give the user **one condensed answer**.

## The tool

`~/.claude/skills/hivemind/hive` — a wrapper around `herdr`. Use it instead of raw `herdr`;
it handles every trap described below. Add it to PATH or call it by full path.

```
hive spawn  <name> [--cwd PATH] [--account NAME]  new drone (opus, --dangerously-skip-permissions), a tab in its coordinator's workspace
hive task   <name> <file|->        brief from file/stdin + appended reporting protocol; needs a
                                   'Rules: <blocks>' line or a '## Boundaries' section
hive say    <name> <text>          ad-hoc message
hive clear  <name>                 clear the drone's input field
hive send   <to> <subject> [--body T] swarm mail (to: coord | drone | all | <front>:coord | <front>:<drone>) + drone wake-up / watcher notice (coord)
hive inbox  [who] [--keep]         read and consume a mailbox (own by default)
hive watch                         the mail watcher — arm it as a Monitor; one line per burst of letters
hive coord                         register the current pane as the coordinator pane
hive coord --remote <ssh-host>     the coordinator lives on another machine — forward coord mail over ssh
hive coord-start [--dry-run] [-- ARGS]  start the coordinator in THIS pane: own directory, auto-compaction
hive status [--all | names]        swarm state table — NEVER blocks; --all: every front
hive wait   [names] [--timeout S]  wait for reports, hard limit (default 300 s)
hive report <name>                 a drone's report
hive peek   <name> [lines]         view of the drone's terminal
hive kill   <name> [--purge]       kill a drone; an already dead one is archived and removed
                                   (--purge deletes without an archive)
hive prune  [--purge] [--dry-run] [names]  clear out dead drones — archives them, then removes
hive rename <old> <new>            rename a drone and its tab (or its own workspace)
hive revive <name> [--account NAME]  resurrection with full conversation history (--resume); --account moves it
hive adopt  <name> <pane_id> [--account NAME]  pull a Claude Code started outside hive into the swarm
hive accounts [--refresh] [--pick] accounts table: limits, resets, status, and the account a spawn takes
hive unblock <name>                answer the dialog a drone is stuck on (resume/trust/consent)
hive sweep                         reconciliation pass — retry lost wake-ups, surface silent drones
hive --front <front> <command>     act on that front (see "Fronts" below)
hive fronts                        every front: its coordinator, watcher, unread mail, drones
hive front add <front> [desc]      new front + its coordinator's home; describe <front> <desc>; rm <front>
hive move   <drone> <front> [--force]  hand a drone to another front (a living one is resumed there)
```

Swarm data: `~/.herdr-hive/drones/<name>/` → `meta.json`, `brief.md`, `report.md`.
Archives of removed drones: `~/.herdr-hive/archive/<label>-<date>.tar.gz` (unpack with
`tar xzf <archive> -C ~/.herdr-hive` to get a drone and its mailbox back).
Model: `opus` (overridable via `HIVE_MODEL`).

## Architecture

One drone = one **tab in its coordinator's workspace** = one pane with an interactive Claude Code.
A front is then one workspace in the herdr sidebar: the coordinator's tab and a tab per drone, each
labelled with the drone's name, so the user sees who works for whom and can enter any panel at any
moment and take over.

- A front without a living local coordinator (none registered, a remote one, its pane gone) gives a
  new drone a workspace of its own, as `HIVE_DRONE_LAYOUT=workspace` does for every spawn.
- `meta.json` says what a drone owns: `tab_id` (its tab; the workspace is `home_workspace_id`, never
  `workspace_id`, which older versions of hive close outright), `workspace_id` (a workspace of its
  own — drones from before tabs), or neither (an adopted agent that shares its tab). `kill`,
  `revive`, `move` and a failed start close what it owns only after herdr confirms, at that moment,
  that it is alone there and no coordinator is; otherwise only the drone's pane goes. A coordinator
  later started inside an old drone's workspace, or a shell split into a drone's tab, survives.
- **Never close the coordinator's workspace while it holds drones**: that ends every one of them
  (`hive revive` brings each back, in the workspace of whoever coordinates the front then). Moving
  the coordinator elsewhere, close its own tab, not the workspace.

**Communication goes through files, not the terminal.** The brief lands in `brief.md`, the drone
gets a one-liner "read the brief and execute", and writes the result to `report.md`.
Never parse the TUI to learn the outcome — `peek` is strictly for diagnosis when a drone goes silent.

The completion signal is the **existence of `report.md`**, not the agent status. Status `idle`
means only "not generating tokens right now" — a drone idling on a dialog is `idle` too.

## Swarm mail — drones call you, not the other way around

**Do not poll the swarm in a loop.** Drones report in on their own. Each has `Stop` and
`Notification` hooks (`drone-settings.json` → `drone-ping.sh`) which, at end of turn or when
a decision is needed, mail `coord`.

**While you listen, the swarm is silent towards the user.** A drone reports to you and nobody
else: `drone-ping.sh` only mails `coord`, a drone has no `PushNotification` tool, and
`drone-settings.json` turns Claude Code's own notifications off (`preferredNotifChannel`,
`inputNeededNotifEnabled`, `agentPushNotifEnabled`). The user hears from the swarm only when
nobody hears it (the alerts below) — everything else reaches them through you.

You hear that mail through **the mail watcher**. Right after `hive coord`, arm it:

```
Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)
```

Every new letter becomes one notification: `HIVE-MAIL <from> [<kind>] <subject>` — a pointer, never
the body. Letters that land within a few seconds of each other (`HIVE_WATCH_COALESCE`, default 3 s,
held at most `HIVE_WATCH_COALESCE_MAX`, 15 s) share ONE line: `HIVE-MAIL 3 letters: a [..] .. | b [..] ..`.
**Quiet letters wake nobody:** a turn a drone ended without a report (`finished a turn (report: no
report)`, almost always a drone waiting on its own tests, mutants or CI) still lands in the mailbox and
shows in `hive inbox`, but the watcher prints nothing for it, the reminder and the backstop do not count
it, and the user is never pinged about it. A drone that stays stuck that way is the sweep's to report,
once. Everything else is loud: messages, decisions, a turn ended with a report, `SWEEP:` findings,
mail from outside the swarm. `HIVE_WATCH_ALL=1` turns the filter off. A letter hive cannot read (cut
short, another format) is loud too, and `hive inbox` shows it as `unreadable letter` instead of skipping
it. **Nothing is ever typed into your prompt**: it belongs to the user, who keeps talking to you
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
  let the REGISTERED coordinator session end a turn while unread LOUD mail sits in `mail/coord`.
  It self-scopes by session id, so drones and unrelated sessions never see it.
- **Unwatched-mail alert** — coord mail when nobody has listened for `HIVE_UNWATCHED_GRACE`
  (default 300 s, counted from the last live heartbeat, the last watcher's stop, or `hive coord`
  and spawn, whichever is latest) pings the user, rate-limited. The grace keeps the routine
  re-arm silent: a letter that lands between a monitor's expiry and your re-arm reaches you as
  the new watcher's backlog line. The grace does not look at what you are doing: stay inside one
  blocking call for longer than the grace after your monitor expired (`hive wait` defaults to
  the same 300 s) and a letter that arrives meanwhile pings the user although you are alive. A
  longer grace closes that gap at the price of noticing a coordinator that is really gone that
  much later. Arming a watcher ends the incident: the next one is alerted without waiting out
  the old rate limit. The ping goes through the desktop notifier: `notify-send`, then
  `osascript` when the first is missing or fails. Only a machine with neither gets a herdr toast
  instead, which herdr may not display (see "herdr technicalities"). hive never turns herdr
  toasts on — herdr cannot exempt drone panes, so its toasts would announce every turn every
  drone ends.
- **Unread-mail reminder** — the watcher itself reminds you, in your session, of letters nobody took
  with `hive inbox` for `HIVE_MAIL_REMIND` (default 600 s): `HIVE-MAIL reminder: N unread, oldest
  M min`. Answer it with `hive inbox`, like any `HIVE-MAIL` line.
- **`hive coord` and `hive status`** report the backlog and whether the watcher is live.
- **Reconciliation sweep** — a systemd user timer (installed by `install.sh`) runs `hive sweep`
  every 5 minutes: it raises the unwatched-mail alert, retries lost drone wake-ups and failed ssh
  forwards to a remote coordinator, raises a desktop reminder when coord mail sits unread past
  `HIVE_MAIL_OVERDUE` (default 30 min) while a watcher lives and the coordinator is not working
  (idle, blocked on a dialog), and mails coord about drones silent with a task in flight —
  dead, blocked, idle without a report, or working past `HIVE_WORKING_WARN` (default 60 min). One
  alert per drone and state: it comes again only when the drone left the state and came back, or after
  `HIVE_SWEEP_RENOTIFY` (default 60 min; the overdue reminder to the user re-nags on the same
  interval). An idle drone whose Claude Code still runs background shells
  (its Bash tool shells, children of its `claude` process — found in `/proc`) is waiting, not stalled:
  it is reported only after `HIVE_SWEEP_BGWAIT` (default 2 h) of that. A `/proc` scan that fails twice
  in a pass leaves the drone as it was (no alert, no marker touched) and logs `background shells
  unknown` in the sweep journal; after `HIVE_SWEEP_NOSCAN` such passes in a row (default 6) you get
  `SWEEP: cannot scan /proc for drone <name>`, again every `HIVE_SWEEP_RENOTIFY` while the scan keeps
  failing. An alert that could not be written to the mailbox
  keeps no marker, so the next pass tries again. `hive kill` marks the drone
  concluded so its corpse stops alarming, and a new spawn/task resets the verdicts.
  A coordinator mid-turn keeps the overdue reminder quiet only until the oldest letter is
  `HIVE_MAIL_OVERDUE_BUSY` old (default 7200 s): a pane that reports `working` for two hours over
  waiting mail is stuck — a hung tool call, a retry loop — and nothing else would tell the user.
  Every alert the sweep raises for the user leaves a line in its output
  (`journalctl --user -u hive-sweep`) that names the channel — `via notify-send`, or `via herdr
  toast` with the reminder that herdr may have displayed nothing. It is marked `NOT delivered`
  when the desktop notifier failed (or there is none and herdr showed nothing); such an alert is
  not rate-limited and the next sweep tries again. A sweep run from cron instead of the systemd
  timer needs the session bus in its environment (`DBUS_SESSION_BUS_ADDRESS`), or `notify-send`
  fails every time. These
  settings are whole seconds; anything else falls back to the default with a line on stderr.

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

## Fronts — several independent coordinators

One coordinator holding fifteen topics of one domain, ten of a second and five of a third interleaves
decisions from all of them in one conversation, talks to thirty drones at once and has no turn left
for the user. A **front** is an independent swarm with a coordinator of its own: its drones, its mail,
its watcher, its alerts. The user switches domains by switching panes.

```bash
hive front add wms "Warehouse: the WMS API, the scanner app, receiving and put-away"
# then, in a new plain herdr pane:
hive --front wms coord-start
```

| Per front | Shared by every front (`~/.herdr-hive/`) |
|---|---|
| drones (`fronts/<front>/drones/`), mailboxes, the coordinator's registration (`coord.pane`, `coord.remote`), the watcher and its heartbeat, the unwatched and overdue alerts, the archive, the coordinator's home (`coord/<front>/`) | the machine gate (`gate.log` — one machine, one RAM), `accounts.conf` and the `/usage` cache, the boundary blocks (`rules/`), drone names (herdr agent names are machine-wide, so `spawn`, `rename` and `adopt` refuse a name another front holds) |

**The default front is `~/.herdr-hive` itself.** A hive without fronts works exactly as before, and an
existing swarm becomes the default front without any migration. `default` names it wherever a front is
asked for.

**Which front a command acts on:** `hive --front <front> <command>`, else `HIVE_FRONT`, else the front
whose coordinator is registered in the calling pane (herdr's `HERDR_PANE_ID`, set in every pane by
herdr 0.9; without it, name the front), else the default front.
`coord-start` exports `HIVE_FRONT` into the coordinator session, so its commands, its hooks and its
Monitor stay on its front; `spawn` gives every drone its front the same way. A coordinator registered
by hand (`hive --front wms coord`) is found through its pane. A front that does not exist is refused
everywhere but `hive front add` — a typo never creates one.

**The coordinator's home** is `~/.herdr-hive/coord/<front>/`, with a `CLAUDE.md` that `front add` writes
once: what the front is about — edit it. Claude Code loads the `CLAUDE.md` of every directory above the
one it runs in, so the shared `coord/CLAUDE.md` is read as well: what every coordinator shares is
written there, once.

**Between fronts:**
- `hive send <front>:coord '<subject>'` writes to another front's coordinator; the sender arrives as
  `<front>:<name>`, which is the reply address (`default:coord` for the default front). A bare drone
  name that lives in another front reaches that drone. A broadcast (`all`) stays within its front.
- `hive move <drone> <front>` hands a drone over: its directory, reports and mailbox move, and a living
  drone is closed and resumed in the new front with its conversation (`--resume`), then told its new
  paths in one `hive say`. A working drone is refused (`--force` cuts its turn off); a dead one only
  moves — revive it there. Letters already waiting in the new front's mailbox for it are merged, and
  with the herdr server unreachable nothing moves (every drone would read as dead). If the restart
  fails, the drone stays in its new front, closed: `hive --front <front> revive <drone>`.
- A command naming a drone of another front fails with where it is: `unknown drone in front wms:
  picker — it belongs to front shp (hive --front shp <command> picker)`. `<front>:<drone>` must name a
  drone of that front; a bare name is looked up in every front.
- `hive fronts` is the table of all fronts; `hive status --all` lists every front's drones.

**What keeps them apart:**
- One pane coordinates one front. `hive coord` or `coord-start` in a pane registered for another front
  takes the pane over, says so, and retires that front's watcher (`HIVE-WATCH: the pane of front <f> now
  coordinates another front`), so the front left without a coordinator is alerted about like any other.
  A session `coord-start` pinned to one front refuses `hive --front <other> coord`: its environment, and
  so its hooks, would stay on the first front — start the other front's coordinator in a pane of its own.
  `spawn`, `revive` and `move` never take a pane away from another front, and a spawn into a named
  front from a pane that coordinates nothing leaves that front's living coordinator registered. A
  drone that spawns, and a session pinned to another front, never register their pane.
- The Stop backstop, the SessionStart board and the PreCompact brief find which front the session
  coordinates and look at that front only.
- The sweep timer covers every front, each alert to its own coordinator; a named front's journal lines
  read `sweep [<front>]: ...`. `hive --front <front> sweep` sweeps one.
- A front coordinator's gate windows are logged as `<front>:coord`, so two coordinators never release
  each other's window. The gate queue is the machine's too: one order for every front.
- A remote fleet's forward of a named front's mail carries `HIVE_FRONT`, so it lands in the same front
  on the coordinator's machine — which has to have that front.

Traps:
- **State kept outside hive must be per front too.** A memory-server entity, a state file, a list of
  watched threads: one record for two coordinators is two coordinators overwriting each other.
- **Outside sources choose the front.** A chat watcher or a ticket timer writes with
  `HIVE_FRONT=<front> hive send coord ...`; `fronts/<front>/description` (set by `front add` or
  `hive front describe`) is the one line a router can classify against.
- **`hive front rm`** refuses a front with drones, unread mail or a live watcher, archives the rest to
  `~/.herdr-hive/archive/front-<front>-<date>.tar.gz` and leaves the coordinator's home in place.
- **A drone spawned before fronts existed** carries no `HIVE_FRONT` and stays on the default front,
  which is where its directory is. `hive move` takes it elsewhere.

## Several Claude Code accounts — spreading the swarm over subscriptions

A fleet of drones burns an account's limits in hours. `--account NAME` runs a drone on a second
Claude Code login: a separate config dir `~/.claude-NAME`, which the drone gets as `CLAUDE_CONFIG_DIR`.
That dir holds the account's own login (`.credentials.json`) and its own `.claude.json` (onboarding,
folder trust, MCP servers). Everything else should be a symlink into `~/.claude`, so both accounts run
the same instructions, hooks, skills and plugins, and share the session transcripts:

```bash
mkdir -m 700 ~/.claude-alt
for f in CLAUDE.md settings.json skills plugins projects; do ln -s ~/.claude/$f ~/.claude-alt/$f; done
CLAUDE_CONFIG_DIR=~/.claude-alt claude      # once, interactively: onboarding + /login
```

- `hive spawn <name> --account alt` — a drone on that account. `HIVE_ACCOUNT=alt` makes it the default
  for new drones and for `hive usage`; `--account ""` (or `default`) is the `~/.claude` account.
- The account is recorded in `meta.json`: `hive revive` resumes the drone where it ran, whatever
  `HIVE_ACCOUNT` says. `hive revive <name> --account other` moves a drone, history included, off an
  account that hit its limit — possible only because `projects/` is shared. When the target account
  cannot see the transcript, revive refuses before closing anything.
- `hive usage --account alt` measures that account's limits; `hive status` shows each drone's account.
- `hive adopt <name> <pane> --account alt` for an agent started on that account by hand. Adopt cannot
  tell the account on its own — without the flag the agent is recorded on the default one.

Traps:
- **`spawn` refuses an account that is not logged in or never finished onboarding** — the drone would
  sit on the login or onboarding screen, which the startup bootstrap does not answer.
- **The default account gets no `CLAUDE_CONFIG_DIR` at all.** An empty value is not "the default" to
  Claude Code but a config dir named `""` (logged out), and `CLAUDE_CONFIG_DIR=~/.claude` would look for
  `~/.claude/.claude.json` instead of `~/.claude.json`. So a default drone inherits whatever the herdr
  **server** process carries: a server started from a shell that exports `CLAUDE_CONFIG_DIR` puts every
  "default" drone on that account while `hive status` still says `default`.
- **Folder trust is pre-seeded in the drone's account**, never in the caller's `CLAUDE_CONFIG_DIR` — a
  coordinator running on another account exports it into every command it runs.

### Which account a drone lands on — `hive accounts`

`~/.herdr-hive/accounts.conf` lists the accounts in the user's order of preference. With it in place, a `spawn`
without `--account` (and without `HIVE_ACCOUNT`) picks the account itself and prints why, and a
`revive` moves a drone off an account that has run out of room. Without the file nothing changes:
a drone stays on the default account.

What it needs:
- **`tmux`** — a limit is read by opening a throwaway Claude Code session in tmux and typing `/usage`.
  Without tmux every account is taken blind (see Traps).
- **Every listed account ready to run**: `default` is `~/.claude`, any other name is `~/.claude-<name>`
  set up as in the section above (logged in, onboarded, `projects` symlinked — only an account that
  shares `projects/` can take over a drone on `revive`).
- **The file itself.** A commented example sits next to `hive`:
  `cp ~/.claude/skills/hivemind/accounts.conf.example ~/.herdr-hive/accounts.conf`, then edit.

```
max_age = 10                                    # minutes a /usage measurement stays good for a spawn
account alt      prio=1  week_threshold=80      # lower prio = preferred; "alt" = ~/.claude-alt
account default  prio=2  week_threshold=60  hard       # hard: over the threshold = never taken
account spare    prio=3  disabled                      # disabled: never taken, never measured
```

**The threshold is on the weekly limit.** `week_threshold=80` reads "use this account up to 80% of
its week" (default 90; 100 = until it is full). The session limit is a 5-hour window that comes back
by itself, so it blocks an account only at 100%; `session_threshold=<percent>` makes it count earlier.

```
$ hive accounts
usage from 4 min ago
ACCOUNT  ENGINE  PRIO  THRESHOLD      EMAIL            SESSION  SESSION RESET            WEEK  WEEK RESET    STATUS
alt      claude  1     week 80%       alt@example.com  57%      Oct 08 20:00 (in 3h42m)  98%   Oct 14 14:00  over threshold: week
default  claude  2     week 60% hard  me@example.com   2%       Oct 08 21:10 (in 4h52m)  11%   Oct 15 09:00  available <- SELECTED
spare    claude  3     week 90%       s@example.com    -        -                        -     -             disabled
```

EMAIL is the login each account's own `.claude.json` records — it tells two config dirs apart.
ENGINE is the agent an account runs; hive drives only Claude Code, so every row says `claude`.

- **The pick**: the lowest `prio` among the accounts under their threshold. When none is, the first
  over-threshold account not marked `hard` — a LAST RESORT, and the output says so. Never: `disabled`,
  `UNAVAILABLE` (session or week at 100%, or an account that is logged out) and an account over a
  `hard` threshold. When nothing is left, spawn refuses and starts nothing — the message lists every
  account with what blocks it and when it gets room again, and names the one that is first
  (`First to get room: alt, Oct 08 18:40 (in 1h02m).`); `--account NAME` still forces one. STATUS
  names the limit that decides: `over threshold: week`, `UNAVAILABLE: session 100%`.
- **Precedence**: `--account` > `HIVE_ACCOUNT` > the pick. `HIVE_ACCOUNT=<name>` (including `default`)
  switches the selection off — spawn uses that account, revive brings a drone back where it ran.
  `--account` bypasses the selection whole, `disabled` and `hard` included: thresholds are enforced
  only on the automatic pick.
- **`hive revive` keeps a drone on its account for as long as that account has room.** A better
  priority elsewhere is no reason to move, and neither is an account that could not be measured or
  is not in `accounts.conf`. The drone moves only off an account that is over its threshold, full,
  logged out or `disabled` — to the picked account, and only to one that sees its transcript (shared
  `projects/`), so a move never loses the history. The output says `stays on X — <why>` or
  `moves X -> Y — X has no room (<state>); Y: <why>`. When no account can take the drone, revive
  refuses before closing anything and names the way out (`hive revive <name> --account X`).
  `hive spawn <name> --resume` by hand stays put.
- `hive accounts` only reads the cache (`~/.herdr-hive/usage-cache.json`); the header gives its age.
  `--refresh` measures every enabled account in parallel — one throwaway tmux session each, a few
  seconds in total. `--pick` prints what a spawn would take right now and why, measuring first if it
  has to.
- **A spawn never picks on old numbers.** A measurement older than `max_age` minutes is re-measured
  before the pick, under a lock, so a burst of spawns measures once. It cannot hang, but the bound is
  not seconds: each step (Claude Code starting, the panel loading) is limited by `HIVE_USAGE_TIMEOUT`
  (default 45 s, whole seconds; `hive usage` obeys it too), so one hanging account costs a spawn
  up to ~95 s once per `max_age`, and a second spawn waits for the first one's measurement (up to
  twice the timeout plus 60 s — 150 s by default) instead of measuring again.
- **A broken `accounts.conf` refuses spawn and revive** without `--account` — loudly, with the line
  number. `--account NAME` and `HIVE_ACCOUNT=NAME` do not read the file and keep working.

Traps:
- **An account whose measurement fails is taken BLIND, after every measured one** — the reason line
  starts with `BLIND`. Among the blind ones an account last seen over its threshold goes last: usage
  only grows inside a window. A failed measurement is retried only after `max_age`, so a broken
  account does not cost every spawn its timeout. Look at `hive accounts`: the status names the failure.
- **The SELECTED mark and the pick come from one ranking**, so on the same stored numbers they cannot
  disagree. Under a `STALE` header the mark is what a spawn takes if its measurement fails; a
  measurement that succeeds may move it.
- **A window whose reset time has passed counts as 0%** — the table shows the account as it stands
  now, not as it was measured. Inside a window usage only grows, so an old `UNAVAILABLE` stays
  `UNAVAILABLE` until its reset, while an old `available` is not trusted (re-measured, or blind).
- **The parser reads two sections of the `/usage` panel: `Current session` and `Current week (all
  models)`** (written against Claude Code 2.1.294). Per-model sections are ignored. A panel missing
  either one is refused, not guessed, and saved to `~/.herdr-hive/usage-panel-<account>.txt` — that
  is what a Claude Code update that renames them looks like, and the saved panel is the fixture for
  teaching the parser. Tests with captured panels live in the repository:
  `tests/accounts/test-accounts.sh` (no real sessions).
- **A logged-out account is `UNAVAILABLE`, not a timeout.** A dead token makes Claude Code open on the
  login selector, whose cursor is the same `❯` as the prompt; the measurement recognises the selector
  and types nothing into it. The same goes for an account that never finished onboarding, the
  default one included: it is not measured at all.
- **The measurement runs in `~/.herdr-hive/usage-cwd`**, a directory of hive's own: empty, so no
  project hooks, MCP servers or `CLAUDE.md` load there. hive pre-trusts that directory, and no
  other, in the measured account's `.claude.json`, so no trust dialog stands between it and the
  panel. Never `$HOME`: Claude Code looks for trust in the parent directories too, so a trusted
  home would cover every directory under it that is not inside a git repository. `hive usage
  --cwd DIR` measures elsewhere, and then only in a directory the account trusts already.
- **A burst lands on one account.** The pick is by priority, not by load: five spawns in a minute all
  take the same account, and its numbers move only at the next measurement.
- **Measurement sessions are `hive-usage-<pid>-<account>` in tmux.** A hive that exits, or is killed by
  TERM/INT/HUP, kills its own; a session orphaned by SIGKILL is collected by the next measurement
  (its pid is dead), and so is a `hive-usage-<pid>` left by a version from before accounts.
  `tmux ls | grep hive-usage` outside a measurement should be empty.

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

## Coordinator context — its own directory, auto-compaction, no session crons

Measured on one swarm: the coordinator's context grew by ~90k per hour of swarm work. The causes and
what replaced each:

| Cause | Now |
|---|---|
| 289 watcher events in 4 h, 149 of them `finished a turn (report: no report)`; the sweep repeating the same stall every 30 min | quiet letters, bursts in one line, one sweep alert per drone and state, background shells checked (above) |
| Session crons polling an outside source (a chat, a tracker) — nearly always to find nothing | a systemd user timer outside the session that mails coord only when something happened (README, "Watching outside sources") |
| The project's `CLAUDE.md` (100+ KB in the measured case) loaded with every request | the coordinator runs in `~/.herdr-hive/coord/` with a short `CLAUDE.md` of its own |
| The boundaries block rewritten in every brief | `Rules: <blocks>` (see "Writing a brief") |

**`hive coord-start [--dry-run] [-- <claude args>]`** — run it in a plain shell pane of herdr. It
registers that pane as the coordinator's (like `hive coord`), enters `$HIVE_COORD_DIR`
(`~/.herdr-hive/coord`) and execs `claude --dangerously-skip-permissions --model opus --settings
~/.claude/skills/hivemind/coord-settings.json` (`HIVE_COORD_MODEL` picks another model). In the new
session: arm the watcher, read back your saved state, `hive status`, `hive inbox`.
**Restarting the coordinator goes through `coord-start` too**: `hive coord-start -- --continue` (or
`-- --resume <session id>`). A bare `claude --resume` in `~/.herdr-hive/coord` comes back without
`coord-settings.json` — whatever window the environment carries, no auto-compaction, no context guard.
`install.sh` puts a short `CLAUDE.md` template into `~/.herdr-hive/coord/` (never over an existing one);
make it yours — where you keep the coordinator state, which accounts and repos exist.

**`coord-settings.json`** is loaded only by that session (drones have `drone-settings.json`, which says
`"autoCompactEnabled": false` itself):
- `"autoCompactEnabled": true` — overrides a `false` in `~/.claude/settings.json` (`--settings` sits
  above user settings; verified: same threshold, compaction with the override, none without).
- The window, 400k, is set in its `env` block as `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, not only as the
  `autoCompactWindow` key: a `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in the shell environment (a herdr server
  started from such a shell passes it to every pane) beats the key (verified). The settings `env` block
  beats the inherited variable (verified).
- `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=330000`: idle compaction (on with auto-compaction; ~54 min idle,
  default from 200k) waits for the guard's threshold, so a session is never compacted idle before its
  state was saved.
- **Context guard** (`coord-context-guard.sh`, Stop hook): once the last main-thread call's input
  (`input + cache_read + cache_creation`) passes `HIVE_COORD_WARN_TOKENS` (330k: the 400k window
  compacts below its effective 380k, and compaction strikes mid-turn, so the warning keeps a large turn
  of margin), it blocks ONE end of turn per epoch asking to save the coordinator state; the epoch ends
  when the context falls back under the threshold (after the compaction). `HIVE_COORD_GUARD_MSG`
  replaces the text (`{k}` = the context in thousands) — name the place you keep the state there.
  State: `~/.herdr-hive/.context-guard`.
- The PreCompact (`coord-compact-brief.sh`) and SessionStart:compact (`coord-creed-inject.sh`) hooks stay
  in `~/.claude/settings.json`: they scope themselves to the registered coordinator, and Claude Code
  runs an identical handler from two settings files once, so nothing would double if they were copied.

**Moving a running coordinator** (the user does this; nobody kills the old session for them):
1. In the old session: save the coordinator state, let it finish its turn.
2. Open a new herdr pane (plain shell) and run `hive coord-start`. The pane is registered at once;
   the old session's hooks stop treating it as the coordinator.
3. In the new session: arm the watcher, read the saved state back, `hive status`, `hive inbox`, then
   delete any session crons it recreated from memory whose work a timer now does.
4. Close the old session when its last turn is over (`/exit`). Its own crons die with it. Leave its
   workspace open while drones live in its tabs — closing it would end them all; close the old
   coordinator's tab only. New drones open in the new coordinator's workspace.

## Surviving a compaction

The rules below are read once. When the conversation is compacted they are replaced by a summary
written by a model that was never told which of them were load-bearing, and the coordinator drops
back to default behaviour: work done inline, mail triage lost, waiting drones forgotten.

Three files carry the discipline across that boundary, all installed by `install.sh` and all
self-scoped to the registered coordinator session:

| File | Hook | What it does |
|---|---|---|
| `coord-creed.md` | — | the eleven rules, **the single source of truth**. The section below explains them; edit the discipline there, not here |
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
  Write one line, `Rules: repo review`: `hive task` replaces it with a `## Boundaries (absolute)`
  section holding the full text of `~/.herdr-hive/rules/common.md` plus `repo.md` and `review.md`
  (`$HIVE_RULES_DIR`; the common block always comes first). Task-specific bounds go in a
  `## Boundaries` section of the brief — with the line too, the blocks land at the top of it. A brief
  with neither the line nor such a section is refused, and so is one that names a block that does not
  exist; a refused brief never replaces the drone's current one. `HIVE_NO_RULES=1` lets a brief without
  boundaries through on purpose. Lines in code fences are text, not directives; every other line
  starting with `Rules:` is one, a list item too, so reword a sentence that starts that way.
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
hive adopt <name> <pane_id>   # registers it in the swarm, records its session_id and what it owns, renames its workspace or tab
hive revive <name>            # restart with --resume: history stays; hooks, env and mail protocol arrive
```

`adopt` alone is not full integration: the adopted agent has no hooks (it never reports in), does
not know the mail protocol, and keeps its original permissions. Until `revive` it gets no mail
wake-ups either — without `HIVE_DRONE` its `hive inbox` would read the coordinator's mailbox. `revive`
adds all of that; it refuses to run when herdr reported no session id, because there would be no
history to resume. Before
`revive` check `hive peek` — if the agent asked a question and waits, answer it after the revival,
otherwise it picks the topic up its own way. `revive` closes what the drone owns: an agent alone in
its workspace owns the workspace; one in a shared workspace (a coordinator's, yours) owns its tab when
it is alone there, and only its pane when it shares the tab (`adopt` says so).

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
| the user gets a desktop ping for every drone turn | herdr's own toasts or sounds for background agents (`[ui.toast] delivery` on, `[ui.sound]` on) — herdr cannot limit them to your pane | tell the user: `delivery = "off"` and `[ui.sound] enabled = false` in the herdr config silence them, after `herdr server reload-config` when the server is running; hive's own alerts use the desktop notifier and do not need them |
| `HIVE-WATCH: taken over by another watcher` | armed twice, or another session took the watch | nothing to do if that was you; otherwise `hive coord` + re-arm in the session that should coordinate |
| a front's coordinator sees another front's drones, or `hive status` says `front: default` | the session carries no `HIVE_FRONT` and its pane is not registered for its front | `hive --front <front> coord` in that session and re-arm the watcher it prints. A conversation cannot move into the front's home (`--continue`/`--resume` look in the directory a session ran in): for the auto-compaction settings, save the state and start a fresh `hive --front <front> coord-start` |
| `drone X belongs to front Y` on spawn | drone names are unique across fronts (herdr agent names are machine-wide) | another name, or `hive move X <front>` |

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
  and removes. Killing a **living** drone still only closes its tab (or own workspace) and keeps the report,
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
  shell pane — zero splits. `hive spawn` uses the root pane from `tab create` (or `workspace create`).
  Environment variables enter via their `--env` (`agent start` has no `--env`).
- `workspace get` reports `pane_count` and `tab_count`, `tab get` the tab's `pane_count`, `pane get` the
  pane's `workspace_id` and `tab_id`. hive closes a drone's workspace or tab only after these confirm
  the drone is alone there and no coordinator is (`drone_close`); otherwise `pane close` takes its pane.
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
- herdr notifies about a background agent that finishes or needs input through `[ui.toast]
  delivery` (default `"off"`) and plays a sound through `[ui.sound]` (default on). Neither can be
  limited per pane — 0.9.x has only the global toast delivery and per-agent-kind sound overrides
  (`[ui.sound.agents] claude`, which mutes the coordinator too). With a swarm, either one fires
  for every turn every drone ends.
- `herdr notification show` answering `"shown": true` does not mean anybody saw it. The server
  says so once it has handed the notification to an attached client; the client then follows its
  own `[ui.toast] delivery` — `"off"` drops it, `"herdr"` draws it inside the terminal, only
  `"terminal"` and `"system"` leave herdr. `"shown": false` comes with no client attached,
  under the API's rate limit, or when the write to every client failed. That is why hive's
  alerts use the desktop notifier and ask herdr only where there is none.
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
