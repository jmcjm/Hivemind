# Coordinator mail watcher — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drones stop typing wake-ups into the coordinator's prompt; the coordinator hears its mail through `hive watch`, a command it keeps armed as a Claude Code `Monitor`.

**Architecture:** The coord mailbox (`$HIVE_DIR/mail/coord/*.json`, consumed by `hive inbox`) stays exactly as it is. `hive watch` polls it every second and prints one pointer line per new letter; it leaves a heartbeat file so `hive send`, `hive sweep`, `hive status` and the SessionStart board can tell whether anyone is listening. With no live watcher, the fallback is a rate-limited herdr notification — never a prompt injection. Drone wake-ups are untouched.

**Tech Stack:** bash (≥4, associative arrays), python3 (≥3.11 for `tomllib` in install.sh), herdr CLI (faked in tests).

**Spec:** `docs/proposal-coord-watch.md`

## Global Constraints

- Nothing is ever typed into the coordinator's prompt. `herdr agent prompt` is called only for drones.
- Watcher line format: `HIVE-MAIL <from> [<kind>] <subject>`, at most 120 characters, never the body.
- Backlog line on start: `HIVE-MAIL backlog: N unread — run hive inbox`.
- Takeover line: `HIVE-WATCH: taken over by another watcher — stopping`.
- Heartbeat file `$HIVE_DIR/.watch-coord`, touched on start and every ~10 s; stale after 30 s.
- Owner file `$HIVE_DIR/.watch-coord.pid`; last armed watcher wins.
- Poll interval: 1 second. No inotify dependency.
- Monitor invocation named everywhere as: `Monitor(command: "hive watch", timeout_ms: 1800000)`.
- `hive watch` consumes nothing; only `hive inbox` reads and archives letters.
- No opt-in "inject" mode.
- Public repository: no machine-specific paths, names or company references in code, docs or tests.

## Review Focus

- A subject with newlines or control characters (a drone's `--body`-less `hive send coord "$(cat log)"`) must still produce exactly one event line — Task 1 test `t_watch_flattens_subject`.
- A watcher armed before the coord mailbox directory exists (fresh `HIVE_DIR`) must start and report later letters — Task 1 test `t_watch_creates_mailbox`.
- A drone that runs `hive watch` would take the watch away from the coordinator and deafen it — it must be refused — Task 1 test `t_watch_refused_for_drone`.
- On a drone machine whose coordinator is remote (`coord.remote`), `hive status` must not nag about an unarmed watcher that is not supposed to exist there — Task 2 test `t_status_quiet_for_remote_coord`.
- A send to `coord` while herdr is unreachable and no watcher runs must still deliver the letter and exit 0 — Task 2 test `t_send_unwatched_herdr_down`.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `skill/hive` | the CLI | add `cmd_watch`, `watch_line`, `coord_watched`, `_watched`; coord branch of `wake_recipient`; notice text; `status` and `coord` output |
| `skill/coord-creed-inject.sh` | SessionStart board | one watcher-state line |
| `skill/coord-creed.md` | coordinator rules | rule 1 and 4 reworded, rule 9 added |
| `skill/SKILL.md`, `README.md`, `CLAUDE-md-snippet.md` | docs | describe the watcher instead of the prompt wake-up |
| `install.sh` | installer | warn when herdr toasts are off; warn when the installed CLAUDE.md section predates the watcher |
| `tests/run.sh` | test runner | new |
| `tests/fake-herdr/herdr` | herdr stand-in that records calls | new |

---

### Task 1: `hive watch` and the test harness

**Files:**
- Create: `tests/fake-herdr/herdr`
- Create: `tests/run.sh`
- Modify: `skill/hive` (helpers section after `prompt_pending`; `cmd_inbox` python; dispatcher `case`; help text)

**Interfaces:**
- Produces: `coord_watched` (bash function, exit 0 when `$HIVE_DIR/.watch-coord` is younger than 30 s); `hive _watched` (same, as an internal subcommand for hooks); `hive watch` (long-running); env `MAIL_KIND_LABELS` (JSON object kind → label, exported); test helpers `setup`, `teardown`, `start_watch`, `send_coord`, `fail`, `assert_contains`, `assert_not_contains`, `assert_count`, `run` in `tests/run.sh`.

- [ ] **Step 1: Create the fake herdr**

`tests/fake-herdr/herdr` (mode 755):

```bash
#!/usr/bin/env bash
# Stand-in for herdr in the hive test suite. Records every call (one line, arguments joined by
# spaces) to $FAKE_HERDR_LOG and answers the few read calls hive makes.
#   FAKE_HERDR_DOWN=1     every call fails the way an unreachable server does
#   FAKE_SESSION_ID=<id>  the agent session id 'pane get' reports (hook scoping)
#   FAKE_AGENT_STATUS=<s> the agent status 'pane get' reports (default idle)
printf '%s\n' "$*" >> "${FAKE_HERDR_LOG:?FAKE_HERDR_LOG must be set}"
if [ "${FAKE_HERDR_DOWN:-0}" = 1 ]; then
  echo '{"error":{"code":"server_not_running","message":"fake herdr is down"}}' >&2
  exit 1
fi
case "$1 ${2:-}" in
  "workspace list")    echo '{"result":{"type":"workspace_list","workspaces":[]}}' ;;
  "pane get")          printf '{"result":{"pane":{"pane_id":"%s","agent":"claude","agent_status":"%s","agent_session":{"kind":"id","value":"%s"}}}}\n' \
                         "${3:-}" "${FAKE_AGENT_STATUS:-idle}" "${FAKE_SESSION_ID:-}" ;;
  "pane current")      echo '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
  "pane read")         : ;;
  "notification show") echo '{"result":{"type":"notification_show","shown":true}}' ;;
  *)                   echo '{"result":{"type":"ok"}}' ;;
esac
```

- [ ] **Step 2: Create the runner with the Task 1 tests**

`tests/run.sh` (mode 755):

```bash
#!/usr/bin/env bash
# tests/run.sh — hermetic tests for hive's coordinator mail path.
# A fake herdr (tests/fake-herdr/herdr) records every call, so no herdr server is needed.
# Usage: tests/run.sh [test-function...]   (default: every t_* function)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HIVE="$ROOT/skill/hive"
FAILED=0

# --- harness ---------------------------------------------------------------

setup() {
  T=$(mktemp -d)
  export HIVE_DIR="$T/hive" FAKE_HERDR_LOG="$T/herdr.log"
  export PATH="$ROOT/tests/fake-herdr:$ORIG_PATH"
  unset HIVE_DRONE KIND FAKE_HERDR_DOWN FAKE_AGENT_STATUS FAKE_SESSION_ID
  mkdir -p "$HIVE_DIR"
  : > "$FAKE_HERDR_LOG"
  echo "w1:p1" > "$HIVE_DIR/coord.pane"
  WATCH_PIDS=()
  TEST_OK=1
}

teardown() {
  local p
  for p in "${WATCH_PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf "$T"
}

start_watch() {  # start_watch <outfile> — hive watch in the background, given time to start
  "$HIVE" watch > "$1" 2>&1 &
  WATCH_PIDS+=($!)
  sleep 1.5
}

send_coord() {  # send_coord <from> <kind> <subject> [body]
  HIVE_DRONE="$1" KIND="$2" "$HIVE" send coord "$3" --body "${4:-}" >/dev/null
}

letters() { find "$HIVE_DIR/mail/coord" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

fail()                { echo "    FAIL: $*"; TEST_OK=0; }
assert_contains()     { grep -qF -- "$2" "$1" || fail "$(basename "$1") lacks: $2"; }
assert_not_contains() { ! grep -qF -- "$2" "$1" || fail "$(basename "$1") has: $2"; }
assert_count()        { local n; n=$(grep -cF -- "$2" "$1"); [ "$n" = "$3" ] || fail "$(basename "$1"): '$2' x$n, expected x$3"; }

run() {  # run <test-function>
  setup
  "$1"
  if [ "$TEST_OK" = 1 ]; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
  teardown
}

# --- hive watch ------------------------------------------------------------

t_watch_prints_pointer_not_body() {
  start_watch "$T/out"
  send_coord kafka done "finished a turn (report: DONE)" "SECRET-BODY"
  sleep 2
  assert_contains "$T/out" "HIVE-MAIL kafka [finished] finished a turn (report: DONE)"
  assert_not_contains "$T/out" "SECRET-BODY"
}

t_watch_one_line_per_letter_and_inbox_consumes() {
  start_watch "$T/out"
  local i; for i in 1 2 3 4 5; do send_coord "d$i" decision "question $i"; done
  sleep 2
  assert_count "$T/out" "HIVE-MAIL d" 5
  assert_contains "$T/out" "HIVE-MAIL d3 [DECISION] question 3"
  "$HIVE" inbox > "$T/inbox"
  assert_count "$T/inbox" "question" 5
  [ "$(letters)" = 0 ] || fail "inbox left $(letters) letter(s)"
  sleep 2
  assert_count "$T/out" "HIVE-MAIL" 5
}

t_watch_backlog_is_one_line() {
  local i; for i in 1 2 3; do send_coord "d$i" msg "old $i"; done
  start_watch "$T/out"
  assert_contains "$T/out" "HIVE-MAIL backlog: 3 unread — run hive inbox"
  assert_count "$T/out" "HIVE-MAIL" 1
}

t_watch_creates_mailbox() {
  rm -rf "$HIVE_DIR/mail"
  start_watch "$T/out"
  send_coord kafka msg "hello"
  sleep 2
  assert_contains "$T/out" "HIVE-MAIL kafka [message] hello"
}

t_watch_flattens_subject() {
  start_watch "$T/out"
  send_coord kafka msg "$(printf 'line one\nline two\tTAB %0300d' 0)"
  sleep 2
  assert_count "$T/out" "HIVE-MAIL" 1
  assert_contains "$T/out" "HIVE-MAIL kafka [message] line one line two TAB 000"
  local len; len=$(grep -F "HIVE-MAIL" "$T/out" | awk '{print length($0)}')
  [ "$len" -le 120 ] || fail "line is $len characters"
}

t_watch_takeover() {
  start_watch "$T/a"
  local a="${WATCH_PIDS[0]}"
  start_watch "$T/b"
  sleep 1.5
  assert_contains "$T/a" "HIVE-WATCH: taken over by another watcher — stopping"
  kill -0 "$a" 2>/dev/null && fail "first watcher still running"
  kill -0 "${WATCH_PIDS[1]}" 2>/dev/null || fail "second watcher died"
}

t_watch_heartbeat() {
  "$HIVE" _watched && fail "_watched true before any watcher ran"
  start_watch "$T/out"
  "$HIVE" _watched || fail "_watched false with a live watcher"
  kill "${WATCH_PIDS[0]}"; wait "${WATCH_PIDS[0]}" 2>/dev/null
  touch -d '-40 seconds' "$HIVE_DIR/.watch-coord"
  "$HIVE" _watched && fail "_watched true with a 40 s old heartbeat"
}

t_watch_refused_for_drone() {
  HIVE_DRONE=kafka "$HIVE" watch > "$T/out" 2>&1 && fail "drone was allowed to run hive watch"
  assert_contains "$T/out" "coordinator's mail watcher"
  [ -f "$HIVE_DIR/.watch-coord.pid" ] && fail "drone attempt wrote the owner file"
}

# --- main --------------------------------------------------------------------

ORIG_PATH="$PATH"
if [ $# -gt 0 ]; then tests=("$@"); else
  mapfile -t tests < <(declare -F | awk '{print $3}' | grep '^t_')
fi
for t in "${tests[@]}"; do run "$t"; done
exit "$FAILED"
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `tests/run.sh`
Expected: every `t_watch_*` test prints `FAIL` (today `hive watch` and `hive _watched` fall through to the help text).

- [ ] **Step 4: Implement the watcher in `skill/hive`**

After `mkdir -p "$DRONES_DIR" "$MAIL_DIR"` near the top, add:

```bash
# Labels for a letter's kind — shared by the watcher line and the inbox listing.
export MAIL_KIND_LABELS='{"decision":"DECISION","done":"finished"}'
```

In `cmd_inbox`, the python block currently builds the label with
`kind={'decision':'DECISION','done':'finished'}.get(e.get('kind'),'message')`. Change the block's first
line to `import json,os,sys` and that line to:

```python
    kind=json.loads(os.environ.get('MAIL_KIND_LABELS','{}')).get(e.get('kind'),'message')
```

After the `prompt_pending` function, add:

```bash
# --- coordinator mail watcher -----------------------------------------------
# The coordinator's prompt belongs to the human too, so coord mail is never typed into it. The
# coordinator keeps 'hive watch' armed as a Claude Code Monitor instead: every stdout line becomes
# a notification in its session, and the prompt stays free for the human.

# Is a watcher listening? 'hive watch' touches its heartbeat every ~10 s, so 30 s of silence means
# its monitor expired or its session is gone.
coord_watched() {
  local beat="$HIVE_DIR/.watch-coord"
  [ -f "$beat" ] || return 1
  [ $(( $(date +%s) - $(stat -c %Y "$beat" 2>/dev/null || echo 0) )) -lt 30 ]
}

# One event line for a coord letter: sender, kind, subject — never the body. Control characters
# are flattened, because every stdout line of the watcher is a separate notification.
watch_line() {
  python3 - "$1" <<'PY' 2>/dev/null
import json,os,re,sys
try:
    e=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)          # archived by 'hive inbox' between the listing and this read
flat=lambda s: re.sub(r'[\x00-\x1f\x7f]+',' ',str(s or '')).strip()
kind=json.loads(os.environ.get('MAIL_KIND_LABELS','{}')).get(e.get('kind'),'message')
line=f"HIVE-MAIL {flat(e.get('from')) or '?'} [{kind}] {flat(e.get('subject'))}"
print(line if len(line)<=120 else line[:117]+'...')
PY
}
```

Before `cmd_status`, add:

```bash
cmd_watch() {  # watch — the coordinator's mail watcher; arm it as a Monitor, one line per new letter
  # A drone running this would take the watch over and leave the coordinator deaf.
  [ -n "${HIVE_DRONE:-}" ] && die "watch is the coordinator's mail watcher — drones read their mail with hive inbox"
  local box="$MAIL_DIR/coord" beat="$HIVE_DIR/.watch-coord" pidf="$HIVE_DIR/.watch-coord.pid"
  mkdir -p "$box"
  # Last armed wins: a second arm, or a new coordinator session taking over, retires this watcher.
  echo "$$" > "$pidf"
  touch "$beat"
  local -A seen=()
  local f n=0 last_beat=$SECONDS
  for f in "$box"/*.json; do
    [ -e "$f" ] || continue
    seen[$f]=1; n=$((n+1))
  done
  [ "$n" -gt 0 ] && echo "HIVE-MAIL backlog: $n unread — run hive inbox"
  while :; do
    sleep 1
    [ "$(cat "$pidf" 2>/dev/null)" = "$$" ] \
      || { echo "HIVE-WATCH: taken over by another watcher — stopping"; return 0; }
    local -A now=()
    for f in "$box"/*.json; do
      [ -e "$f" ] || continue
      now[$f]=1
      [ -n "${seen[$f]:-}" ] || watch_line "$f"
    done
    # Forget letters 'hive inbox' archived, so the set never grows with the watcher's lifetime.
    seen=()
    for f in "${!now[@]}"; do seen[$f]=1; done
    if [ $((SECONDS - last_beat)) -ge 10 ]; then touch "$beat"; last_beat=$SECONDS; fi
  done
}
```

In the dispatcher `case`, after `_pending) ...`, add:

```bash
  _watched) coord_watched ;;                                   # internal, for coord-creed-inject.sh
```

and after `inbox)  shift; cmd_inbox  "$@" ;;` add:

```bash
  watch)  shift; cmd_watch  "$@" ;;
```

In the help text, after the `hive inbox` line, add:

```
  hive watch                         coordinator's mail watcher — arm it as a Monitor (one line per new letter)
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `tests/run.sh`
Expected: `ok` for all eight `t_watch_*` tests, exit status 0. Also `bash -n skill/hive` prints nothing.

- [ ] **Step 6: Commit**

```bash
git add tests/run.sh tests/fake-herdr/herdr skill/hive
git commit -m "feat(watch): hive watch — coordinator mail watcher for a Claude Code Monitor"
```

---

### Task 2: deliver coord mail without touching the prompt

**Files:**
- Modify: `skill/hive` — `coord_stranded_notice`, `wake_recipient`, `cmd_status`, the `coord)` branch of the dispatcher, comment in `cmd_sweep` step 1
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `coord_watched`, `hive watch`, test helpers from Task 1.
- Produces: `wake_recipient coord` never calls `herdr agent prompt`; `hive status` prints `watch: live` or `watch: NOT ARMED — …` for a local coordinator; `hive coord` prints the arm instruction.

- [ ] **Step 1: Add the failing tests**

In `tests/run.sh`, before `# --- main`, add:

```bash
# --- delivery to coord -------------------------------------------------------

t_send_watched_touches_nothing() {
  start_watch "$T/out"
  send_coord kafka done "finished"
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
  [ "$(letters)" = 1 ] || fail "expected 1 letter, found $(letters)"
}

t_send_unwatched_notifies_once_never_prompts() {
  send_coord kafka done "first"
  send_coord sql decision "second"
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
  assert_count "$FAKE_HERDR_LOG" "notification show" 1
  assert_contains "$FAKE_HERDR_LOG" "arm Monitor(hive watch)"
  [ "$(letters)" = 2 ] || fail "expected 2 letters, found $(letters)"
}

t_send_unwatched_herdr_down() {
  export FAKE_HERDR_DOWN=1
  send_coord kafka done "finished" || fail "send exited non-zero"
  [ "$(letters)" = 1 ] || fail "letter not delivered"
}

t_drone_wakeup_unchanged() {
  mkdir -p "$HIVE_DIR/drones/kafka"
  echo '{"name":"kafka","workspace_id":"w2","pane_id":"w2:p1"}' > "$HIVE_DIR/drones/kafka/meta.json"
  "$HIVE" send kafka "hello" --body "x" >/dev/null
  assert_contains "$FAKE_HERDR_LOG" "agent prompt w2:p1 HIVE-MAIL: new mail. Run: hive inbox"
}

t_sweep_notifies_when_unwatched() {
  send_coord kafka done "finished"
  rm -f "$HIVE_DIR/.stranded-notice"; : > "$FAKE_HERDR_LOG"
  touch -d '-2 minutes' "$HIVE_DIR/.watch-coord"
  "$HIVE" sweep >/dev/null
  assert_count "$FAKE_HERDR_LOG" "notification show" 1
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
}

t_sweep_quiet_when_watched() {
  send_coord kafka done "finished"
  rm -f "$HIVE_DIR/.stranded-notice"; : > "$FAKE_HERDR_LOG"
  touch "$HIVE_DIR/.watch-coord"
  "$HIVE" sweep >/dev/null
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
}

t_status_shows_watcher() {
  "$HIVE" status > "$T/off"
  assert_contains "$T/off" "watch: NOT ARMED"
  start_watch "$T/out"
  "$HIVE" status > "$T/on"
  assert_contains "$T/on" "watch: live"
}

t_status_quiet_for_remote_coord() {
  echo "coordhost" > "$HIVE_DIR/coord.remote"
  "$HIVE" status > "$T/out"
  assert_not_contains "$T/out" "watch:"
}

t_coord_prints_arm_instruction() {
  "$HIVE" coord > "$T/out"
  assert_contains "$T/out" 'Monitor(command: "hive watch", timeout_ms: 1800000)'
  [ "$(cat "$HIVE_DIR/coord.pane")" = "w1:p1" ] || fail "coord.pane not registered"
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/run.sh t_send_watched_touches_nothing t_send_unwatched_notifies_once_never_prompts t_send_unwatched_herdr_down t_drone_wakeup_unchanged t_sweep_notifies_when_unwatched t_sweep_quiet_when_watched t_status_shows_watcher t_status_quiet_for_remote_coord t_coord_prints_arm_instruction`
Expected: FAIL for the send/sweep/status/coord tests (today `wake_recipient coord` calls `agent prompt w1:p1`); `t_drone_wakeup_unchanged` and `t_send_unwatched_herdr_down` already pass — they pin behavior that must survive.

- [ ] **Step 3: Rework the notice**

Replace the comment block and message of `coord_stranded_notice` (keep the name, the marker and the 900 s rate limit):

```bash
# Desktop escalation for coord mail nobody is watching (no live 'hive watch' heartbeat). The
# coordinator's prompt is never typed into, so without a watcher the letters wait in silence —
# the one failure the swarm cannot heal on its own, so the human gets a ping.
# Rate-limited by a marker so a burst of drone hooks does not fire one ping per letter.
coord_stranded_notice() {
  local mark="$HIVE_DIR/.stranded-notice" age n
  if [ -f "$mark" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$mark" 2>/dev/null || echo 0) ))
    [ "$age" -lt 900 ] && return 0
  fi
  : > "$mark"
  n=$(find "$MAIL_DIR/coord" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
  herdr notification show \
    "Swarm mail waiting, no coordinator is watching ($n letters). In the coordinator session: hive coord, then arm Monitor(hive watch)" \
    --sound request >/dev/null 2>&1
}
```

- [ ] **Step 4: Split `wake_recipient` into coord and drone paths**

Replace the head of `wake_recipient` — its comment block and everything up to and including the
`else ... fi` that resolves `pane` — with:

```bash
# Wakes a DRONE by injecting a message into its prompt. Safeguards:
#  - only when the drone's prompt is EMPTY (never overwrite a human's text)
#  - flock: two senders never write into one prompt at the same time
#  - marker: one wake-up per batch, until the drone runs 'hive inbox'
#  - marker TTL: a delivered wake-up is not a handled one (Esc, a restarted session,
#    mail read without 'hive inbox') — a marker older than HIVE_WAKE_TTL (default 900 s)
#    counts as a LOST wake-up and is retried; without the TTL one lost prompt would
#    silence the mailbox forever
# The coordinator is never woken this way — see the mail watcher above.
wake_recipient() {
  local who="$1" pane=""
  if [ "$who" = coord ]; then
    # A remote coordinator has no watcher on this machine — the letter waits in the mailbox
    # (cmd_send forwards over ssh; this path only runs when that forward failed).
    [ -n "$(coord_remote)" ] && return 0
    # A live watcher prints the letter within a second; without one, the human gets a ping.
    coord_watched || coord_stranded_notice
    return 0
  fi
  pane=$(pane_of "$who" 2>/dev/null)
  [ -n "$pane" ] || return 0
```

and replace the status check further down

```bash
  case "$(pane_status "$pane")" in
    dead)    [ "$who" = coord ] && coord_stranded_notice; return 0 ;;
    blocked) return 0 ;;
  esac
```

with

```bash
  case "$(pane_status "$pane")" in
    dead|blocked) return 0 ;;
  esac
```

- [ ] **Step 5: Sweep comment**

In `cmd_sweep`, replace the two comment lines above step 1

```bash
  # 1. Coordinator mail: retry the lost wake-up (marker TTL applies), or — for a remote
  #    coordinator — retry the ssh forward that failed at send time.
```

with

```bash
  # 1. Coordinator mail: with no live watcher, ping the human (rate-limited) — or, for a remote
  #    coordinator, retry the ssh forward that failed at send time.
```

- [ ] **Step 6: Watcher state in `hive status`**

In `cmd_status`, right after the line that prints `mail ($me): ... unread letter(s)`, add:

```bash
  if [ "$me" = coord ] && [ -z "$(coord_remote)" ]; then
    if coord_watched; then echo "watch: live"
    else echo 'watch: NOT ARMED — arm Monitor(command: "hive watch", timeout_ms: 1800000)'; fi
  fi
```

- [ ] **Step 7: Arm instruction in `hive coord`**

In the dispatcher's `coord)` branch, in the local (non `--remote`) arm, replace

```bash
            echo "coord: $(coord_pane)"
```

with

```bash
            echo "coord: $(coord_pane)"
            if coord_watched; then echo "coord: mail watcher live"
            else echo 'coord: arm the mail watcher — Monitor(command: "hive watch", timeout_ms: 1800000); re-arm it every time it expires'; fi
```

- [ ] **Step 8: Run the whole suite**

Run: `tests/run.sh`
Expected: every test `ok`, exit status 0.

- [ ] **Step 9: Commit**

```bash
git add skill/hive tests/run.sh
git commit -m "feat(watch): coord mail never touches the prompt — watcher or a ping"
```

---

### Task 3: coordinator hooks and creed

**Files:**
- Modify: `skill/coord-creed-inject.sh` (the board, after the unread-mail lines)
- Modify: `skill/coord-creed.md`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `hive _watched` (Task 1).
- Produces: board line `Mail watcher: live.` or `Mail watcher: NOT ARMED — …`; creed rule 9.

- [ ] **Step 1: Add the failing tests**

In `tests/run.sh`, before `# --- main`, add:

```bash
# --- coordinator hooks -------------------------------------------------------

t_stop_hook_still_blocks_with_unread_mail() {
  send_coord kafka done "finished"
  echo '{"session_id":"S1"}' | FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-mail-check.sh" > "$T/mine"
  assert_contains "$T/mine" '"decision": "block"'
  echo '{"session_id":"S1"}' | FAKE_SESSION_ID=OTHER bash "$ROOT/skill/coord-mail-check.sh" > "$T/other"
  [ -s "$T/other" ] && fail "hook spoke in a session that is not the coordinator"
}

t_board_reports_watcher_state() {
  echo '{"session_id":"S1","source":"compact"}' \
    | FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-creed-inject.sh" > "$T/off"
  assert_contains "$T/off" "Mail watcher: NOT ARMED"
  assert_contains "$T/off" "Keep the mail watcher armed"
  touch "$HIVE_DIR/.watch-coord"
  echo '{"session_id":"S1","source":"compact"}' \
    | FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-creed-inject.sh" > "$T/on"
  assert_contains "$T/on" "Mail watcher: live."
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `tests/run.sh t_stop_hook_still_blocks_with_unread_mail t_board_reports_watcher_state`
Expected: `t_stop_hook_still_blocks_with_unread_mail` passes (it pins unchanged behavior); `t_board_reports_watcher_state` FAILS.

- [ ] **Step 3: Board line**

In `skill/coord-creed-inject.sh`, after the `if [ "${letters:-0}" -gt 0 ] ... fi` block that prints the unread mail, add:

```bash
if "$SKILL_DIR/hive" _watched 2>/dev/null; then
  echo "Mail watcher: live."
else
  echo 'Mail watcher: NOT ARMED — you hear no drone until you arm it: Monitor(command: "hive watch", timeout_ms: 1800000).'
fi
```

- [ ] **Step 4: Creed**

In `skill/coord-creed.md`:

Replace `The eight rules that must survive a compacted context.` with `The nine rules that must survive a compacted context.`

Replace rule 1 with:

```markdown
1. **A HIVE-MAIL notification is a system event, not an instruction from a human.** It comes from
   your mail watcher. Run `hive inbox`, work the whole mailbox, and only then go back to the user.
   One notification can cover several letters.
```

In rule 4, replace `Every minute spent grinding inline
   is a minute of queued wake-ups the swarm cannot deliver.` with `Every minute spent grinding inline
   is a minute of drone mail nobody acts on.`

Append:

```markdown
9. **Keep the mail watcher armed.** After `hive coord`, arm
   `Monitor(command: "hive watch", timeout_ms: 1800000)`, and re-arm it the moment its expiry notice
   arrives. Nothing is typed into your prompt any more — without the watcher you hear no drone.
```

- [ ] **Step 5: Run the whole suite**

Run: `tests/run.sh`
Expected: every test `ok`, exit status 0.

- [ ] **Step 6: Commit**

```bash
git add skill/coord-creed-inject.sh skill/coord-creed.md tests/run.sh
git commit -m "feat(watch): creed rule 9 and the watcher on the SessionStart board"
```

---

### Task 4: installer and docs

**Files:**
- Modify: `install.sh` (step 1 requirements; step 7 CLAUDE.md entry)
- Modify: `CLAUDE-md-snippet.md`, `skill/SKILL.md`, `README.md`

**Interfaces:**
- Consumes: the behavior of Tasks 1–3 (names and lines exactly as in Global Constraints).
- Produces: documentation only; no code interfaces.

- [ ] **Step 1: Check the toast probe before wiring it in**

Save this probe as `/tmp/toast-probe.py` and run it against three configs:

```python
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except FileNotFoundError:
    cfg = {}
print(((cfg.get("ui") or {}).get("toast") or {}).get("delivery", "off"))
```

```bash
printf '[ui.sound]\nenabled = false\n' > /tmp/c1.toml
printf '[ui.toast]\ndelivery = "system"\n' > /tmp/c2.toml
python3 /tmp/toast-probe.py /tmp/c1.toml; python3 /tmp/toast-probe.py /tmp/c2.toml; python3 /tmp/toast-probe.py /tmp/missing.toml
```
Expected: `off`, `system`, `off`.

- [ ] **Step 2: Wire the probe into `install.sh`**

In step 1, after the herdr server reachability block, add:

```bash
# The fallback for coord mail nobody is watching is a herdr notification; with toasts off
# (the herdr default) it never shows.
TOAST=$(python3 - "$HOME/.config/herdr/config.toml" <<'PY' 2>/dev/null
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except FileNotFoundError:
    cfg = {}
print(((cfg.get("ui") or {}).get("toast") or {}).get("delivery", "off"))
PY
) || TOAST=unknown
case "$TOAST" in
  off)     warn "herdr toasts are off — the unwatched-mail alert will not show; set [ui.toast] delivery = \"system\" (or \"herdr\") in ~/.config/herdr/config.toml" ;;
  unknown) warn "could not read the herdr toast setting — make sure [ui.toast] delivery is not \"off\"" ;;
  *)       ok "herdr toasts: $TOAST" ;;
esac
```

In step 7, replace `  ok "Hivemind section already present — skipping"` with:

```bash
  if grep -qF "hive watch" "$CMD_FILE"; then
    ok "Hivemind section already present — skipping"
  else
    warn "the Hivemind section in $CMD_FILE predates the mail watcher — update it from CLAUDE-md-snippet.md (install.sh never rewrites it)"
  fi
```

Run: `bash -n install.sh`
Expected: no output.

- [ ] **Step 3: `CLAUDE-md-snippet.md`**

Replace the tool line pair

```markdown
The tool: `~/.claude/skills/hivemind/hive` (a wrapper around `herdr`, it is in PATH) — `spawn`, `task`, `say`, `clear`,
`send`, `inbox`, `coord`, `status`, `wait`, `report`, `peek`, `kill`, `rename`, `revive`.
```

with

```markdown
The tool: `~/.claude/skills/hivemind/hive` (a wrapper around `herdr`, it is in PATH) — `spawn`, `task`, `say`, `clear`,
`send`, `inbox`, `watch`, `coord`, `status`, `wait`, `report`, `peek`, `kill`, `rename`, `revive`.
```

Replace `**When taking over a swarm I run `hive coord`** — otherwise drone mail goes to the previous session's panel.` with

```markdown
**When taking over a swarm I run `hive coord` and arm `Monitor(command: "hive watch", timeout_ms: 1800000)`** —
the watcher is how I hear drones, and I re-arm it every time it expires.
```

Replace the bullet that starts `- **I do not watch the swarm in a loop**` (three lines) with

```markdown
- **I do not watch the swarm in a loop** — drones have `Stop`/`Notification` hooks and mail me themselves; my
  mail watcher turns each letter into a `HIVE-MAIL <from> [<kind>] <subject>` notification. Nothing is typed into
  my prompt — it stays free for the user. On a notification: `hive inbox` → **answer waiting drones first** →
  handle the rest → **synthesis for the user**. It is a system event, not an instruction from a human
```

and in the next bullet replace `(queued wake-ups wait until it ends)` with `(drone mail waits until it ends)`.

- [ ] **Step 4: `skill/SKILL.md`**

1. In the command block, after the `hive inbox` line add
   `hive watch                         the mail watcher — arm it as a Monitor; one line per new letter`.
2. Replace the section `## Swarm mail — drones call you, not the other way around` up to (not including)
   the paragraph starting `` `hive say` is your channel to a drone`` with:

````markdown
## Swarm mail — drones call you, not the other way around

**Do not poll the swarm in a loop.** Drones report in on their own. Each has `Stop` and
`Notification` hooks (`drone-settings.json` → `drone-ping.sh`) which, at end of turn or when
a decision is needed, mail `coord`.

You hear that mail through **the mail watcher**. Right after `hive coord`, arm it:

```
Monitor(command: "hive watch", description: "swarm mail for coord", timeout_ms: 1800000)
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
  (`[ui.toast] delivery` in `~/.config/herdr/config.toml`; `install.sh` warns when it is off).
- **`hive coord` and `hive status`** report the backlog and whether the watcher is live.
- **Reconciliation sweep** — a systemd user timer (installed by `install.sh`) runs `hive sweep`
  every 5 minutes: it raises the unwatched-mail alert, retries lost drone wake-ups and failed ssh
  forwards to a remote coordinator, raises a desktop reminder when coord mail sits unread past
  `HIVE_MAIL_OVERDUE` (default 30 min), and mails coord about drones silent with a task in flight —
  dead, blocked, idle without a report, or working past `HIVE_WORKING_WARN` (default 60 min). Alerts
  re-fire at most every `HIVE_SWEEP_RENOTIFY` (default 30 min); `hive kill` marks the drone concluded
  so its corpse stops alarming, and a new spawn/task resets the verdicts.
````

3. In `## Remote fleet`, replace `over ssh into the coordinator machine's mailbox and wakes the coordinator's pane **there** —` with
   `over ssh into the coordinator machine's mailbox, where the watcher **there** reports it —`.
4. In the `## Surviving a compaction` table row for `coord-creed.md`, replace `the eight rules` with `the nine rules`;
   in the `coord-creed-inject.sh` row, replace `unread coordinator mail,` with `unread coordinator mail, whether the mail watcher is live,`.
5. In `## Typical flow`, replace the paragraph starting `**At session start run `hive coord`.**` up to the code block with:

```markdown
**At session start run `hive coord`, then arm the mail watcher.** `hive coord` registers your pane
as the `coord` address (the Stop-hook backstop scopes itself by it); `hive spawn` does it as a side
effect. The watcher (`Monitor(command: "hive watch", timeout_ms: 1800000)`) is how drone mail reaches
you at all. `hive coord` also prints the backlog stranded by a dead predecessor — when it reports
unread letters, `hive inbox` is your first move of the shift.
```

   and in the code block after `$H coord` add the line
   `# arm: Monitor(command: "hive watch", timeout_ms: 1800000)` and replace
   `# Do not hover over them — they come back on their own with HIVE-MAIL. When it arrives:` with
   `# Do not hover over them — the watcher brings HIVE-MAIL notifications. When one arrives:`.
6. In `## Diagnostics`, add the rows:

```markdown
| no `HIVE-MAIL` notifications at all | watcher not armed or expired | `hive status` → `watch: NOT ARMED`; arm `Monitor(hive watch)`, then `hive inbox` |
| `HIVE-WATCH: taken over by another watcher` | armed twice, or another session took the watch | nothing to do if that was you; otherwise `hive coord` + re-arm in the session that should coordinate |
```

- [ ] **Step 5: `README.md`**

1. Replace the paragraph `**Drones call the coordinator, not the other way around.** ...zero polling.` with:

```markdown
**Drones call the coordinator, not the other way around.** The `Stop` and `Notification` hooks mail
the `coord` mailbox. The coordinator keeps `hive watch` armed as a Claude Code `Monitor`, which turns
every new letter into a one-line `HIVE-MAIL` notification in its session. Nothing is typed into the
coordinator's prompt, so the human can keep talking to it while drones report in — and zero polling
on the coordinator's side.
```

2. In `**The fleet can span machines.**`, replace `waking the coordinator's pane there` with
   `where the coordinator's watcher reports it`.
3. In "Why this way and not another", point 6: replace `` `hive task`/`say`/`wake_recipient` check for this and refuse.`` with
   `` `hive task`/`say` and drone wake-ups check for this and refuse — and the coordinator's prompt is never typed into at all (point 10).``;
   point 9: replace `**One wake-up per batch**` with `**One drone wake-up per batch**`; append:

```markdown
10. **The coordinator hears mail through a Monitor, not its prompt.** Typing `HIVE-MAIL` into the
    coordinator's prompt fought the human for it: while drones reported in, the human could not talk
    to the coordinator. `hive watch` prints a pointer line per letter (never the body, to save context)
    and consumes nothing — `hive inbox` still reads and archives, so a lost notification never loses a
    letter. Monitors expire after 30 minutes, so re-arming is part of the coordinator's creed, and the
    Stop hook plus the unwatched-mail alert catch a coordinator that forgot.
```

4. In "Verifying the 1:1 reproduction": after `hive coord                      # -> coord: wN:pM` add a line
   `# in the coordinator session arm: Monitor(command: "hive watch", timeout_ms: 1800000)`; replace
   ``Now **do not poll**. Within ~30 s the message `HIVE-MAIL: new mail. Run: hive inbox` should appear
in the coordinator's prompt on its own. Then:`` with
   ``Now **do not poll**. Within ~30 s the watcher should bring a notification
`HIVE-MAIL testdrone [finished] finished a turn (report: DONE)` on its own — the prompt stays untouched. Then:``;
   replace `If `HIVE-MAIL` never arrived — see "Diagnostics" below.` with
   `If no notification arrived — see "Diagnostics" below.`
5. "What lands where" table: add the row
   `| `~/.herdr-hive/.watch-coord`, `.watch-coord.pid` | the mail watcher's heartbeat and owner |`.
6. "Diagnostics" table: replace the two rows starting `| `HIVE-MAIL` never arrives` with

```markdown
| no `HIVE-MAIL` notifications | watcher not armed or expired | `hive status` → `watch: NOT ARMED`; arm `Monitor(command: "hive watch", timeout_ms: 1800000)`, then `hive inbox` |
| unwatched-mail alert never shows | herdr toasts off | `[ui.toast] delivery = "system"` in `~/.config/herdr/config.toml` |
```

7. In "Customization", append `- Tests: `tests/run.sh` — hermetic tests of the coordinator mail path against a fake herdr.`
8. In "What lands where" or anywhere else, `the eight coordinator rules` becomes `the nine coordinator rules`.

- [ ] **Step 6: Consistency sweep**

Run:
```bash
grep -rn "into the coordinator's prompt\|into your prompt\|eight rules\|eight coordinator\|queued wake-ups" README.md skill/ CLAUDE-md-snippet.md
tests/run.sh
bash -n install.sh skill/hive skill/coord-creed-inject.sh
```
Expected: the grep hits only sentences that describe drones or say the coordinator's prompt is *never* typed into; the suite passes; `bash -n` is silent.

- [ ] **Step 7: Commit**

```bash
git add install.sh CLAUDE-md-snippet.md skill/SKILL.md README.md
git commit -m "docs(watch): the coordinator hears drones through hive watch"
```

---

### Task 5: end-to-end on a real herdr session

**Files:** none changed unless this finds a defect (then fix it in the owning file, add a test to `tests/run.sh` that reproduces it, and commit).

**Interfaces:**
- Consumes: everything above, installed with `./install.sh`.

- [ ] **Step 1: Isolated herdr session with a clean environment**

A server launched from inside a Claude Code session passes `CLAUDECODE`/`CLAUDE_CODE_*` down to every pane,
which switches transcript saving off and breaks `--resume`. Start it clean:

```bash
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="$SHELL" PATH="$PATH" TERM=xterm-256color \
  LANG="${LANG:-C.UTF-8}" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" herdr --session hivetest server   # background
export HERDR_SESSION=hivetest HIVE_DIR=$(mktemp -d)
```

- [ ] **Step 2: A real coordinator with the watcher armed**

Create a workspace with `--env HIVE_DIR=$HIVE_DIR`, run `hive coord` in its shell (`herdr pane run`), start
Claude Code there (`herdr agent start coordinator --kind claude --pane <id> -- --model opus`) and prompt it:
`Run hive status, then arm Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000) and wait.`
Expected: `hive status` in that pane reports `watch: live` within a few seconds.

- [ ] **Step 3: Drone finishes while the human is typing to the coordinator**

`hive spawn testdrone`, `hive task testdrone -` with a read-only brief, then immediately type unsent text into
the coordinator's prompt: `herdr pane send-text <coord-pane> "human draft"`.
Expected, once the drone's report exists:
- `herdr pane read <coord-pane> --source recent-unwrapped` shows the `HIVE-MAIL testdrone [finished] ...`
  notification handled by the coordinator (it ran `hive inbox`);
- `hive _pending <coord-pane>` still prints `human draft` — the draft was neither sent nor overwritten;
- nowhere in the pane is the old `HIVE-MAIL: new mail. Run: hive inbox` prompt text.

- [ ] **Step 4: Unwatched path**

Stop the coordinator's monitor (ask it to `TaskStop` the watcher), wait 35 s, `hive send coord "ping" --body x`.
Expected: `hive status` shows `watch: NOT ARMED`; the coordinator's prompt is untouched; the letter is in `mail/coord`.

- [ ] **Step 5: Clean up**

`herdr session stop hivetest`; `herdr session delete hivetest`; `rm -rf "$HIVE_DIR"`.
