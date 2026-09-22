# Proposal: coordinator mail through a watched mailbox, not the prompt

Status: **implemented.** Replaces the coordinator's prompt wake-up.

## 1. The problem

When a drone mails `coord`, `wake_recipient` types `HIVE-MAIL: new mail. Run: hive inbox` into the
coordinator's prompt with `herdr agent prompt`. That prompt belongs to the human too. While drones
report in, the human cannot talk to the coordinator: the safeguard that refuses to inject over
typed text only moves the conflict, and the wake-ups that do land compete with the human's own
messages for the coordinator's turn.

The mailbox itself is not the problem. `mail/coord/` is a directory of letters written atomically
(`mktemp` + `mv`), and `hive inbox` prints exactly the unread ones and moves them to `.archive/`.
That already is "read only what you have not read, and never lose a letter". Only the delivery of
the *signal* has to change.

## 2. What the harness offers

Claude Code's `Monitor` tool runs a command in the background and turns every stdout line into a
notification in the session. Notifications do not touch the prompt the human types into.

Constraints that shape the design:

| Fact | Consequence |
|---|---|
| A monitor expires after at most 30 minutes, with one notice | the coordinator must re-arm it; the notice is its cue |
| Monitors that emit too many events are stopped automatically | one short line per letter, never letter bodies |
| Lines within 200 ms are batched into one notification | a burst of drones finishing arrives as one event |
| Only the session that armed the monitor sees its events | the watcher belongs to the registered coordinator |

## 3. Design

### 3.1 `hive watch` — the event source

A long-running loop the coordinator arms as
`Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)`.

- Every second it lists `mail/coord/*.json` and prints one line per letter it has not seen yet:
  `HIVE-MAIL <from> [<kind>] <subject>`, truncated to ~120 characters. Bodies are never printed:
  the line is a pointer, the letter is read with `hive inbox`. The sender and kind are enough to
  triage — a `[DECISION]` is visible without reading anything.
- On start, when letters are already waiting, it prints one line instead of one per letter:
  `HIVE-MAIL backlog: N unread — run hive inbox`.
- It consumes nothing. Reading and archiving stay with `hive inbox`, so a lost notification never
  loses a letter.
- Heartbeat: every ~10 s it touches `$HIVE_DIR/.watch-coord`. A heartbeat older than 30 s means
  nobody is listening.
- Last armed wins: on start it writes its PID to `$HIVE_DIR/.watch-coord.pid`. A watcher that finds
  another PID there prints `HIVE-WATCH: taken over by another watcher — stopping` and exits. This
  covers both a double arm and a coordinator handover while the old session still runs.
- A 1-second poll instead of inotify: no dependency (`inotifywait` is not installed everywhere) and
  the cost is one directory listing per second.

### 3.2 Sending to `coord`

`wake_recipient coord` no longer types into any prompt.

- Watcher heartbeat fresh → nothing to do; the watcher prints the letter within a second.
- Heartbeat stale or missing → a rate-limited herdr notification (the existing stranded-notice
  pattern): *"Swarm mail waiting, no coordinator is watching (N letters). In the coordinator
  session: hive coord, then arm Monitor(hive watch)."*
- Remote coordinator (`coord.remote`) is unchanged: the letter travels over ssh into the
  coordinator machine's mailbox, where that machine's watcher picks it up.

Drone wake-ups are unchanged: `hive task`, `hive say` and drone-to-drone `hive send` still inject
into the drone's prompt, because nobody else types there and a drone has no monitor.

### 3.3 Safety net

- **Stop hook** (`coord-mail-check.sh`) unchanged: the coordinator cannot end a turn while unread
  mail sits in `mail/coord`. The end of a turn is the coordinator's free moment.
- **Sweep**: for a local coordinator it no longer retries a prompt wake-up; when letters wait and
  the heartbeat is stale it raises the notification from 3.2. The overdue-mail reminder stays.
- **`coord-creed-inject.sh`** (after compaction/resume/clear) adds the watcher state to the board;
  when the watcher is dead it says so and names the fix: arm `Monitor(hive watch)`.
- **`hive status`** prints the watcher state next to the unread-mail line.

### 3.4 Doctrine

- `coord-creed.md` gets a rule: after `hive coord`, arm `Monitor(hive watch)` for 30 minutes, and
  re-arm it every time the expiry notice arrives. Rule 1 changes from "HIVE-MAIL in the prompt" to
  "HIVE-MAIL notification".
- `hive coord` prints the instruction to arm the watcher.
- `SKILL.md` (swarm mail section), `README.md` (architecture, smoke test, diagnostics) and
  `CLAUDE-md-snippet.md` describe the watcher instead of the prompt injection.
- `install.sh` warns when herdr toasts are off (`[ui.toast] delivery` defaults to `"off"`), because
  the fallback notification is then invisible, and names the setting to change.

### 3.5 Rejected

- **A JSONL log with a read cursor.** It needs `flock` on every append (letters larger than 4 KB can
  interleave), a cursor that must advance atomically with the read, and rotation for a file that
  only grows; send, inbox, sweep, the Stop hook, the creed board and remote forwarding would all be
  rewritten. It adds no capability the mailbox lacks.
- **A watcher that consumes the letters it prints.** One tool call cheaper, but a monitor stopped
  for volume or killed between print and delivery would archive letters nobody saw.
- **Keeping prompt injection as an opt-in mode.** Two delivery mechanisms to maintain and document
  for one purpose.

## 4. Testing

On an isolated herdr session with a separate `HIVE_DIR`:

1. With `hive watch` running, letters from `hive send coord` appear as single lines within ~1 s;
   a burst of five letters gives five lines; `hive inbox` then reads all five and the watcher prints
   nothing more.
2. Backlog on start gives one summary line.
3. A second `hive watch` makes the first exit with the takeover line.
4. With no watcher, `hive send coord` writes the letter, raises the notification once (rate limit
   holds on the second letter) and types **nothing** into the coordinator's pane (checked with
   `herdr pane read`).
5. The Stop hook still blocks a registered coordinator session with unread mail.
6. `hive sweep` with letters waiting and a stale heartbeat raises the notification; with a fresh
   heartbeat it stays silent.
7. End to end: a real coordinator session armed with `Monitor(hive watch)`, a drone finishing a
   task, and the coordinator handling the notification while its prompt stays untouched.

## 5. Honest limits

- The watcher lives only as long as the monitor. A coordinator that ignores the expiry notice stops
  hearing drones until the Stop hook or the notification catches it.
- `Monitor` is a Claude Code tool; the coordinator must run in Claude Code.
- The fallback notification is only as visible as the herdr toast setting allows.
