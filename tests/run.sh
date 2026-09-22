#!/usr/bin/env bash
# tests/run.sh — hermetic tests for hive's coordinator mail path.
# A fake herdr (tests/fake-herdr/herdr) records every call, so no herdr server is needed.
# Usage: tests/run.sh [test-function...]   (default: every t_* function)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HIVE="$ROOT/skill/hive"
FAILED=0
# The copy-paste form every arm instruction must use (the Monitor tool requires a description).
ARM='Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)'

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
  "$HIVE" _watched || fail "the old watcher's exit took the new watcher's heartbeat with it"
}

t_watch_heartbeat_cleared_on_exit() {
  start_watch "$T/out"
  kill "${WATCH_PIDS[0]}"; wait "${WATCH_PIDS[0]}" 2>/dev/null
  "$HIVE" _watched && fail "_watched true right after the watcher was stopped"
}

t_watch_heartbeat_refreshes() {
  start_watch "$T/out"
  sleep 10.5
  local age; age=$(( $(date +%s) - $(stat -c %Y "$HIVE_DIR/.watch-coord" 2>/dev/null || echo 0) ))
  [ "$age" -lt 5 ] || fail "heartbeat is $age s old after 12 s of watching"
}

t_watch_exits_when_reader_gone() {
  # A closed reader reaches the watcher as SIGPIPE, or as a failed write (EPIPE) when a parent
  # handed SIGPIPE down ignored — both must end it.
  local mode w i
  for mode in default ignored; do
    mkfifo "$T/fifo-$mode"
    exec 7<>"$T/fifo-$mode"             # read end that never blocks the watcher's open
    ( [ "$mode" = ignored ] && trap '' PIPE
      exec timeout 20 "$HIVE" watch > "$T/fifo-$mode" 2>/dev/null 7>&- ) &
    w=$!; WATCH_PIDS+=("$w")
    sleep 1.5
    exec 7>&-                           # the reader goes away, like an expired Monitor
    send_coord kafka msg "nobody reads this ($mode)"
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$w" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$w" 2>/dev/null && fail "SIGPIPE $mode: watcher still running with nobody reading its output"
    "$HIVE" _watched && fail "SIGPIPE $mode: the orphaned watcher left a live heartbeat"
  done
}

t_watch_exits_when_parent_gone() {
  bash -c '"$0" watch > "$1" 2>&1 & echo $! > "$2"; sleep 1.5' "$HIVE" "$T/out" "$T/wpid"
  local w; w=$(cat "$T/wpid"); WATCH_PIDS+=("$w")
  local i; for i in 1 2 3 4 5 6; do kill -0 "$w" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$w" 2>/dev/null && fail "watcher outlived the process that started it"
  "$HIVE" _watched && fail "the orphaned watcher left a live heartbeat"
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
  HIVE_DRONE=kafka timeout 5 "$HIVE" watch > "$T/out" 2>&1 && fail "drone was allowed to run hive watch"
  assert_contains "$T/out" "coordinator's mail watcher"
  [ -f "$HIVE_DIR/.watch-coord.pid" ] && fail "drone attempt wrote the owner file"
}

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

t_adopted_drone_not_woken() {
  mkdir -p "$HIVE_DIR/drones/kafka"
  echo '{"name":"kafka","workspace_id":"w2","pane_id":"w2:p1","adopted":true}' > "$HIVE_DIR/drones/kafka/meta.json"
  "$HIVE" send kafka "hello" --body "x" >/dev/null
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
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
  assert_contains "$FAKE_HERDR_LOG" "workspace list"      # the sweep ran, it did not bail out early
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
}

t_status_shows_watcher() {
  "$HIVE" status > "$T/off"
  assert_contains "$T/off" "watch: NOT ARMED — arm $ARM"
  start_watch "$T/out"
  "$HIVE" status > "$T/on"
  assert_contains "$T/on" "watch: a watcher is live — if this session has no hive watch monitor, arm one: $ARM"
}

t_status_quiet_for_remote_coord() {
  echo "coordhost" > "$HIVE_DIR/coord.remote"
  "$HIVE" status > "$T/out"
  assert_contains "$T/out" "no drones"
  assert_not_contains "$T/out" "watch:"
}

t_coord_prints_arm_instruction() {
  "$HIVE" coord > "$T/out"
  assert_contains "$T/out" "coord: arm the mail watcher — $ARM"
  [ "$(cat "$HIVE_DIR/coord.pane")" = "w1:p1" ] || fail "coord.pane not registered"
  # A fresh heartbeat proves SOME watcher lives, not that this session has one.
  touch "$HIVE_DIR/.watch-coord"
  "$HIVE" coord > "$T/live"
  assert_contains "$T/live" "coord: arm the mail watcher — $ARM"
}

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
  assert_contains "$T/off" "Mail watcher: NOT ARMED — you hear no drone until you arm it: $ARM."
  assert_contains "$T/off" "Keep the mail watcher armed"
  assert_count "$T/off" "$ARM" 2                          # the board line and creed rule 9
  touch "$HIVE_DIR/.watch-coord"
  echo '{"session_id":"S1","source":"compact"}' \
    | FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-creed-inject.sh" > "$T/on"
  assert_contains "$T/on" "Mail watcher: a watcher is live — if this session has no hive watch monitor, arm one: $ARM."
}

# --- main --------------------------------------------------------------------

ORIG_PATH="$PATH"
if [ $# -gt 0 ]; then tests=("$@"); else
  mapfile -t tests < <(declare -F | awk '{print $3}' | grep '^t_')
fi
for t in "${tests[@]}"; do run "$t"; done
exit "$FAILED"
