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
