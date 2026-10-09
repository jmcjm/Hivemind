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
  unset HIVE_DRONE KIND FAKE_HERDR_DOWN FAKE_AGENT_STATUS FAKE_SESSION_ID FAKE_TOAST_SHOWN FAKE_NOTIFY_FAIL \
        HIVE_UNWATCHED_GRACE HIVE_MAIL_REMIND HIVE_MAIL_OVERDUE HIVE_MAIL_OVERDUE_BUSY \
        HIVE_SWEEP_RENOTIFY
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

# Every way hive can reach the human: a herdr toast or the desktop notifier (both faked).
alerts() { grep -cE '^(notification show|notify-send|osascript) ' "$FAKE_HERDR_LOG"; }

# The coordinator registered an hour ago and its last watcher stopped ten minutes ago: nobody
# has listened for longer than the grace period.
coord_gone() {
  touch -d '-1 hour' "$HIVE_DIR/coord.pane"
  touch -d '-10 minutes' "$HIVE_DIR/.watch-coord.last"
}

mail_aged() {  # mail_aged <touch -d offset> — one unread coord letter of that age
  send_coord kafka done "finished"
  touch -d "$1" "$HIVE_DIR"/mail/coord/*.json
}

# A PATH on which the named tools do not exist, the stand-ins included: every directory of the
# test PATH mirrored as symlinks, minus those names. For a machine without notify-send.
path_without() {  # path_without <tool>...
  local -a skip=()
  local tool d mirror out=""
  for tool in "$@"; do skip+=(! -name "$tool"); done
  while IFS= read -r -d : d; do
    [ -d "$d" ] || continue
    mirror=$(mktemp -d "$T/path.XXXXXX")
    find "$d/" -mindepth 1 -maxdepth 1 "${skip[@]}" -exec ln -s -t "$mirror" {} +
    out="$out${out:+:}$mirror"
  done <<<"$PATH:"
  printf '%s\n' "$out"
}

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
  # ...and the stop is remembered, so a re-arm gap is not mistaken for a coordinator gone.
  local age; age=$(( $(date +%s) - $(stat -c %Y "$HIVE_DIR/.watch-coord.last" 2>/dev/null || echo 0) ))
  [ "$age" -lt 5 ] || fail "the stopped watcher left no fresh .watch-coord.last"
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

t_watch_reminds_coordinator_of_unread_mail() {
  # Mail heard but never taken with hive inbox: the watcher reminds the coordinator itself,
  # and the human hears nothing of it.
  mail_aged '-20 minutes'
  HIVE_MAIL_REMIND=5 start_watch "$T/out"
  sleep 10
  assert_contains "$T/out" "HIVE-MAIL backlog: 1 unread — run hive inbox"
  assert_contains "$T/out" "HIVE-MAIL reminder: 1 unread, oldest 20 min — run hive inbox"
  [ "$(alerts)" = 0 ] || fail "the human was alerted"
}

t_watch_no_reminder_for_fresh_mail() {
  # The reminder is for mail left unread, not for a letter that has just arrived.
  HIVE_MAIL_REMIND=8 start_watch "$T/out"
  sleep 5
  send_coord kafka done "finished"
  sleep 6.5                                             # past the first heartbeat (~10 s)
  assert_contains "$T/out" "HIVE-MAIL kafka [finished] finished"
  assert_not_contains "$T/out" "HIVE-MAIL reminder"
}

t_watch_reminds_once_per_period() {
  # Unread mail comes up once per HIVE_MAIL_REMIND, not at every heartbeat (~10, ~20, ~30 s).
  mail_aged '-20 minutes'
  HIVE_MAIL_REMIND=15 start_watch "$T/out"
  sleep 12
  assert_count "$T/out" "HIVE-MAIL reminder" 0          # first heartbeat: the period has not passed
  sleep 11.5
  assert_count "$T/out" "HIVE-MAIL reminder" 1          # second heartbeat
  sleep 10
  assert_count "$T/out" "HIVE-MAIL reminder" 1          # third: 10 s into the next period
}

t_watch_bad_remind_falls_back_to_default() {
  HIVE_MAIL_REMIND=10m start_watch "$T/out"
  assert_contains "$T/out" "HIVE_MAIL_REMIND='10m' is not a whole number of seconds — using 600"
}

t_watch_arming_ends_the_unwatched_incident() {
  # A watcher armed after an alert ends that incident: the next time nobody listens, the alert
  # does not wait out the old rate limit.
  coord_gone
  send_coord kafka done "first"                         # alerts and leaves the rate-limit marker
  start_watch "$T/out"
  kill "${WATCH_PIDS[0]}"; wait "${WATCH_PIDS[0]}" 2>/dev/null
  touch -d '-10 minutes' "$HIVE_DIR/.watch-coord.last"
  send_coord sql done "second"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 2
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
  [ "$(alerts)" = 0 ] || fail "the human was alerted while a watcher listens"
  [ "$(letters)" = 1 ] || fail "expected 1 letter, found $(letters)"
}

t_send_unwatched_notifies_once_never_prompts() {
  coord_gone
  send_coord kafka done "first"
  send_coord sql decision "second"
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 1
  assert_contains "$FAKE_HERDR_LOG" "arm Monitor(hive watch)"
  [ "$(alerts)" = 1 ] || fail "$(alerts) pings for one alert"
  [ "$(letters)" = 2 ] || fail "expected 2 letters, found $(letters)"
}

t_send_in_rearm_gap_is_silent() {
  # The Monitor expired a moment ago and the coordinator is re-arming it — a letter landing in
  # that gap is no reason to ping the human.
  touch -d '-1 hour' "$HIVE_DIR/coord.pane"
  start_watch "$T/out"
  kill "${WATCH_PIDS[0]}"; wait "${WATCH_PIDS[0]}" 2>/dev/null
  send_coord kafka done "finished"
  [ "$(alerts)" = 0 ] || fail "the human was alerted during a re-arm gap"
  [ "$(letters)" = 1 ] || fail "letter not delivered"
}

t_send_new_coordinator_gets_grace() {
  # hive coord ran a moment ago (setup) and no watcher is armed yet: time to arm one first.
  send_coord kafka done "finished"
  [ "$(alerts)" = 0 ] || fail "the human was alerted before the coordinator could arm its watcher"
}

t_send_grace_is_configurable() {
  touch -d '-1 hour' "$HIVE_DIR/coord.pane"
  touch -d '-2 minutes' "$HIVE_DIR/.watch-coord.last"
  send_coord kafka done "first"
  [ "$(alerts)" = 0 ] || fail "alerted 2 min into the default 5 min grace"
  HIVE_UNWATCHED_GRACE=60 send_coord sql done "second"
  assert_count "$FAKE_HERDR_LOG" "notify-send" 1
}

t_alert_goes_to_the_desktop_whatever_herdr_says() {
  # herdr answers "shown" once a client has the notification, whether or not that client displays
  # it — so while a desktop notifier exists, herdr is not asked at all.
  coord_gone
  send_coord kafka done "finished"                        # the fake herdr would answer "shown"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 1
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
}

t_alert_desktop_failure_is_not_covered_by_herdr() {
  # notify-send is there and fails (no session bus): the alert did not go out, and herdr's
  # "shown" does not pass for it.
  coord_gone
  FAKE_NOTIFY_FAIL=1 send_coord kafka done "first"
  [ ! -e "$HIVE_DIR/.stranded-notice" ] || fail "a failed alert left its rate-limit marker"
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
  send_coord sql done "second"                            # the notifier works again: no rate limit in the way
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 2
  [ -e "$HIVE_DIR/.stranded-notice" ] || fail "a delivered alert left no rate-limit marker"
}

t_alert_uses_osascript_without_notify_send() {
  coord_gone
  PATH="$(path_without notify-send)" send_coord kafka done "finished"
  assert_count "$FAKE_HERDR_LOG" "osascript -e on run argv -e display notification (item 2 of argv) with title (item 1 of argv) -e end run Swarm mail: no coordinator is listening 1 letter(s) waiting." 1
  [ "$(alerts)" = 1 ] || fail "$(alerts) pings for one alert"
}

t_alert_uses_herdr_without_a_desktop_notifier() {
  # No notify-send and no osascript: a herdr toast is all there is, and its "shown" has to do.
  coord_gone
  PATH="$(path_without notify-send osascript)" send_coord kafka done "finished"
  assert_count "$FAKE_HERDR_LOG" "notification show Swarm mail: no coordinator is listening" 1
  [ -e "$HIVE_DIR/.stranded-notice" ] || fail "herdr took the alert, yet no rate-limit marker"
}

t_alert_nobody_saw_leaves_no_marker() {
  # No desktop notifier and herdr shows nothing (no client attached): nothing reached the human,
  # so nothing may hold the next attempt back.
  coord_gone
  PATH="$(path_without notify-send osascript)" FAKE_TOAST_SHOWN=0 send_coord kafka done "first"
  [ ! -e "$HIVE_DIR/.stranded-notice" ] || fail "an alert nobody saw left its rate-limit marker"
  send_coord sql done "second"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 1
  [ -e "$HIVE_DIR/.stranded-notice" ] || fail "a delivered alert left no rate-limit marker"
}

t_send_bad_grace_falls_back_to_default() {
  # "5m" is not a number of seconds: left as typed it fails the comparison and the alert never fires.
  coord_gone
  HIVE_UNWATCHED_GRACE=5m send_coord kafka done "finished" 2> "$T/err"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 1
  assert_contains "$T/err" "HIVE_UNWATCHED_GRACE='5m' is not a whole number of seconds — using 300"
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
  touch -d '-1 hour' "$HIVE_DIR/coord.pane"
  touch -d '-10 minutes' "$HIVE_DIR/.watch-coord"         # a watcher killed before its trap ran
  "$HIVE" sweep > "$T/out"
  assert_count "$FAKE_HERDR_LOG" "notify-send" 1
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
  assert_contains "$T/out" "sweep: unwatched-mail alert (1 letters)"
}

t_sweep_reports_alert_nobody_saw() {
  # The notifier fails, as in a unit with no session bus: the journal says so, and no marker
  # holds the next sweep back.
  coord_gone
  mail_aged '-10 minutes'
  rm -f "$HIVE_DIR/.stranded-notice"
  FAKE_NOTIFY_FAIL=1 "$HIVE" sweep > "$T/out"
  assert_contains "$T/out" "sweep: unwatched-mail alert NOT delivered (1 letters)"
  [ ! -e "$HIVE_DIR/.stranded-notice" ] || fail "an alert nobody saw left its rate-limit marker"
}

t_sweep_quiet_within_grace() {
  send_coord kafka done "finished"
  touch -d '-1 hour' "$HIVE_DIR/coord.pane"
  touch -d '-2 minutes' "$HIVE_DIR/.watch-coord"
  rm -f "$HIVE_DIR/.stranded-notice"; : > "$FAKE_HERDR_LOG"
  "$HIVE" sweep >/dev/null
  assert_contains "$FAKE_HERDR_LOG" "workspace list"
  [ "$(alerts)" = 0 ] || fail "the human was alerted 2 min after the watcher stopped"
}

t_sweep_overdue_quiet_while_coordinator_works() {
  mail_aged '-40 minutes'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=working "$HIVE" sweep >/dev/null
  assert_contains "$FAKE_HERDR_LOG" "pane get w1:p1"
  [ "$(alerts)" = 0 ] || fail "the human was alerted about a coordinator mid-turn"
}

t_sweep_overdue_alerts_when_coordinator_works_too_long() {
  # 'working' for hours over waiting mail is a stuck pane, not a turn in progress.
  mail_aged '-3 hours'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=working "$HIVE" sweep >/dev/null
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread for 180 min" 1
}

t_sweep_overdue_busy_limit_is_configurable() {
  mail_aged '-40 minutes'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  HIVE_MAIL_OVERDUE_BUSY=3600 FAKE_AGENT_STATUS=working "$HIVE" sweep >/dev/null
  [ "$(alerts)" = 0 ] || fail "alerted 40 min into a 60 min limit"
  HIVE_MAIL_OVERDUE_BUSY=1800 FAKE_AGENT_STATUS=working "$HIVE" sweep >/dev/null
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread for 40 min" 1
}

t_sweep_overdue_alerts_when_coordinator_stuck() {
  # A watcher printed the letters, yet the coordinator sits on a dialog: only the human can help.
  mail_aged '-40 minutes'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=blocked "$HIVE" sweep > "$T/out"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread for 40 min" 1
  assert_contains "$T/out" "sweep: overdue mail reminder (1 letters, 40 min old)"
}

t_sweep_overdue_waits_for_threshold() {
  mail_aged '-20 minutes'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=idle "$HIVE" sweep >/dev/null
  [ "$(alerts)" = 0 ] || fail "alerted about 20 min old mail (threshold 30 min)"
}

t_sweep_overdue_reminder_nobody_saw() {
  mail_aged '-40 minutes'
  touch "$HIVE_DIR/.watch-coord"
  FAKE_NOTIFY_FAIL=1 FAKE_AGENT_STATUS=blocked "$HIVE" sweep > "$T/out"
  assert_contains "$T/out" "sweep: overdue mail reminder NOT delivered (1 letters, 40 min old)"
  [ ! -e "$HIVE_DIR/.overdue-notice" ] || fail "a reminder nobody saw started the re-nag interval"
}

t_sweep_bad_overdue_falls_back_to_default() {
  mail_aged '-40 minutes'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  HIVE_MAIL_OVERDUE=30m FAKE_AGENT_STATUS=blocked "$HIVE" sweep >/dev/null 2>&1
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread for 40 min" 1
}

t_sweep_overdue_left_to_the_unwatched_alert() {
  # The watcher stopped two minutes ago and the mail is overdue. Once its grace has passed the
  # unwatched-mail alert takes these letters; an overdue ping now would make it two for one event.
  mail_aged '-40 minutes'
  touch -d '-1 hour' "$HIVE_DIR/coord.pane"
  touch -d '-2 minutes' "$HIVE_DIR/.watch-coord.last"
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=idle "$HIVE" sweep >/dev/null
  [ "$(alerts)" = 0 ] || fail "overdue reminder sent ahead of the unwatched-mail alert"
}

t_sweep_unheard_mail_alerts_once() {
  # Nobody listens and the mail is overdue too: one alert, the one that names the cure.
  coord_gone
  mail_aged '-40 minutes'
  rm -f "$HIVE_DIR/.stranded-notice"; : > "$FAKE_HERDR_LOG"
  "$HIVE" sweep >/dev/null
  [ "$(alerts)" = 1 ] || fail "$(alerts) alerts for one event"
  assert_contains "$FAKE_HERDR_LOG" "no coordinator is listening"
}

t_sweep_quiet_when_watched() {
  send_coord kafka done "finished"
  rm -f "$HIVE_DIR/.stranded-notice"; : > "$FAKE_HERDR_LOG"
  touch "$HIVE_DIR/.watch-coord"
  "$HIVE" sweep >/dev/null
  assert_contains "$FAKE_HERDR_LOG" "workspace list"      # the sweep ran, it did not bail out early
  [ "$(alerts)" = 0 ] || fail "the human was alerted while a watcher listens"
  assert_not_contains "$FAKE_HERDR_LOG" "agent prompt"
}

# --- drones never reach the human ---------------------------------------------

t_drone_ping_reports_only_to_coordinator() {
  mkdir -p "$T/home/.claude/skills/hivemind"
  ln -s "$ROOT/skill/hive" "$T/home/.claude/skills/hivemind/hive"
  start_watch "$T/out"
  : > "$FAKE_HERDR_LOG"
  echo '{"message":"Claude needs your permission"}' \
    | HOME="$T/home" HIVE_DRONE=kafka bash "$ROOT/skill/drone-ping.sh" decision
  echo '{}' | HOME="$T/home" HIVE_DRONE=kafka bash "$ROOT/skill/drone-ping.sh" done
  sleep 2
  [ "$(letters)" = 2 ] || fail "expected 2 letters, found $(letters)"
  assert_contains "$T/out" "HIVE-MAIL kafka [DECISION] needs a decision"
  assert_contains "$T/out" "HIVE-MAIL kafka [finished] finished a turn (report: no report)"
  [ "$(alerts)" = 0 ] || fail "a drone hook alerted the human while the coordinator listens"
}

t_spawn_drone_cannot_push() {
  mkdir -p "$T/home/work"
  hive_home spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "--disallowedTools PushNotification"
}

t_drone_settings_silence_claude_code() {
  python3 - "$ROOT/skill/drone-settings.json" <<'SETTINGSPY' \
    || fail "drone-settings.json leaves Claude Code's own notifications on"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("preferredNotifChannel") == "notifications_disabled"
assert d.get("inputNeededNotifEnabled") is False
assert d.get("agentPushNotifEnabled") is False
SETTINGSPY
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

# --- Claude Code accounts ----------------------------------------------------
# hive runs against a throwaway HOME: account dirs (~/.claude-<name>) and ~/.claude.json live there.

hive_home() { HOME="$T/home" "$HIVE" "$@"; }

make_account() {  # make_account <name> [--no-onboarding] — a logged-in account under the test HOME
  local d="$T/home/.claude-$1"
  mkdir -p "$d"
  touch "$d/.credentials.json"
  if [ "${2:-}" = --no-onboarding ]; then echo '{}' > "$d/.claude.json"
  else echo '{"hasCompletedOnboarding": true}' > "$d/.claude.json"; fi
}

drone_meta_field() {  # drone_meta_field <drone> <key> — empty when the key is absent
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" \
    "$HIVE_DIR/drones/$1/meta.json" "$2" 2>/dev/null
}

trusted() {  # trusted <config.json> <dir> — True when the dir is pre-trusted in that config
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('projects',{}).get(sys.argv[2],{}).get('hasTrustDialogAccepted'))" \
    "$1" "$2" 2>/dev/null
}

t_spawn_default_account_sets_no_config_dir() {
  mkdir -p "$T/home/work"
  # The caller's CLAUDE_CONFIG_DIR (a coordinator on another account) must not leak into the drone.
  CLAUDE_CONFIG_DIR="$T/elsewhere" hive_home spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 \
    || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "workspace create --label kafka"
  assert_not_contains "$FAKE_HERDR_LOG" "CLAUDE_CONFIG_DIR"
  assert_contains "$T/out" "account=default"
  [ -z "$(drone_meta_field kafka account)" ] || fail "meta account: $(drone_meta_field kafka account)"
  [ "$(trusted "$T/home/.claude.json" "$T/home/work")" = True ] || fail "cwd not trusted in ~/.claude.json"
  [ ! -e "$T/elsewhere" ] || fail "the caller's CLAUDE_CONFIG_DIR was written to"
}

t_spawn_named_account() {
  mkdir -p "$T/home/work"; make_account alt
  hive_home spawn kafka --cwd "$T/home/work" --account alt > "$T/out" 2>&1 \
    || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "--env CLAUDE_CONFIG_DIR=$T/home/.claude-alt"
  assert_contains "$T/out" "account=alt"
  [ "$(drone_meta_field kafka account)" = alt ] || fail "meta account: $(drone_meta_field kafka account)"
  [ "$(trusted "$T/home/.claude-alt/.claude.json" "$T/home/work")" = True ] || fail "cwd not trusted in the account's config"
  [ ! -e "$T/home/.claude.json" ] || fail "the default account's config was written to"
}

t_spawn_hive_account_is_the_default() {
  mkdir -p "$T/home/work"; make_account alt
  HIVE_ACCOUNT=alt hive_home spawn kafka --cwd "$T/home/work" >/dev/null 2>&1 || fail "spawn kafka failed"
  HIVE_ACCOUNT=alt hive_home spawn sql --cwd "$T/home/work" --account "" >/dev/null 2>&1 || fail "spawn sql failed"
  [ "$(drone_meta_field kafka account)" = alt ] || fail "HIVE_ACCOUNT ignored"
  [ -z "$(drone_meta_field sql account)" ] || fail "--account \"\" did not override HIVE_ACCOUNT"
}

t_spawn_refuses_unready_account() {
  mkdir -p "$T/home/work" "$T/home/.claude-nologin"; make_account fresh --no-onboarding
  hive_home spawn kafka --cwd "$T/home/work" --account nologin > "$T/a" 2>&1 && fail "spawned on a logged-out account"
  hive_home spawn kafka --cwd "$T/home/work" --account fresh > "$T/b" 2>&1 && fail "spawned on an account without onboarding"
  hive_home spawn kafka --cwd "$T/home/work" --account missing > "$T/c" 2>&1 && fail "spawned on a missing account"
  assert_contains "$T/a" "is not logged in"
  assert_contains "$T/b" "never finished onboarding"
  assert_contains "$T/c" "no config dir"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace create"
  [ ! -e "$HIVE_DIR/drones/kafka" ] || fail "a drone directory was created"
}

t_revive_keeps_account() {
  mkdir -p "$T/home/work" "$HIVE_DIR/drones/kafka"; make_account alt; make_account other
  printf '{"name":"kafka","workspace_id":"w2","pane_id":"w2:p1","session_id":"s-1","cwd":"%s","account":"alt"}\n' \
    "$T/home/work" > "$HIVE_DIR/drones/kafka/meta.json"
  # HIVE_ACCOUNT picks the account of NEW drones; a revived one stays where its session lives.
  HIVE_ACCOUNT=other hive_home revive kafka > "$T/out" 2>&1 || fail "revive failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "workspace close w2"
  assert_contains "$FAKE_HERDR_LOG" "--env CLAUDE_CONFIG_DIR=$T/home/.claude-alt"
  assert_contains "$FAKE_HERDR_LOG" "--resume s-1"
  [ "$(drone_meta_field kafka account)" = alt ] || fail "meta account: $(drone_meta_field kafka account)"
}

t_revive_move_needs_visible_session() {
  mkdir -p "$T/home/work" "$HIVE_DIR/drones/kafka"; make_account alt
  printf '{"name":"kafka","workspace_id":"w2","pane_id":"w2:p1","session_id":"s-1","cwd":"%s"}\n' \
    "$T/home/work" > "$HIVE_DIR/drones/kafka/meta.json"
  hive_home revive kafka --account alt > "$T/out" 2>&1 && fail "moved a drone whose session the account cannot see"
  assert_contains "$T/out" "does not see session s-1"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
  mkdir -p "$T/home/.claude-alt/projects/-work"; touch "$T/home/.claude-alt/projects/-work/s-1.jsonl"
  hive_home revive kafka --account alt > "$T/out2" 2>&1 || fail "move refused with the session visible: $(cat "$T/out2")"
  assert_contains "$FAKE_HERDR_LOG" "--env CLAUDE_CONFIG_DIR=$T/home/.claude-alt"
  [ "$(drone_meta_field kafka account)" = alt ] || fail "meta account: $(drone_meta_field kafka account)"
}

t_adopt_records_account() {
  make_account alt
  FAKE_SESSION_ID=s-9 hive_home adopt kafka w5:p1 --account alt > "$T/out" 2>&1 || fail "adopt failed: $(cat "$T/out")"
  [ "$(drone_meta_field kafka account)" = alt ] || fail "meta account: $(drone_meta_field kafka account)"
  hive_home adopt sql w6:p1 --account missing > "$T/out2" 2>&1 && fail "adopted onto a missing account"
  assert_not_contains "$FAKE_HERDR_LOG" "agent rename w6:p1"
  [ ! -e "$HIVE_DIR/drones/sql" ] || fail "a drone directory was created"
}

t_status_shows_account() {
  mkdir -p "$HIVE_DIR/drones/kafka" "$HIVE_DIR/drones/sql"
  echo '{"name":"kafka","workspace_id":"w2","pane_id":"w2:p1","account":"alt"}' > "$HIVE_DIR/drones/kafka/meta.json"
  echo '{"name":"sql","workspace_id":"w3","pane_id":"w3:p1"}' > "$HIVE_DIR/drones/sql/meta.json"   # pre-accounts meta
  "$HIVE" status > "$T/out"
  grep -qE '^kafka +w2:p1 +alt +' "$T/out" || fail "no account column for kafka: $(cat "$T/out")"
  grep -qE '^sql +w3:p1 +default +' "$T/out" || fail "old meta not shown as default: $(cat "$T/out")"
}

# --- install.sh: what herdr itself would announce ------------------------------

expect_pings() {  # expect_pings <expected line> — herdr-pings.py on $T/config.toml
  local out; out=$(python3 "$ROOT/lib/herdr-pings.py" "$T/config.toml")
  [ "$out" = "$1" ] || fail "expected '$1', got '$out'"
}

t_pings_herdr_defaults_without_config() {
  expect_pings "off on"
}

t_pings_reports_toast_delivery_and_never_writes() {
  printf '[ui.toast]\ndelivery = "system"\n\n[ui.sound]\nenabled = false\n' > "$T/config.toml"
  cp "$T/config.toml" "$T/before"
  expect_pings "system off"
  cmp -s "$T/config.toml" "$T/before" || fail "the config was changed"
}

t_pings_agent_sound_overrides_the_global_switch() {
  printf '[ui.sound]\nenabled = false\n\n[ui.sound.agents]\nclaude = "on"\n' > "$T/config.toml"
  expect_pings "off on"
  printf '[ui.sound.agents]\nclaude = "off"\n' > "$T/config.toml"
  expect_pings "off off"
}

t_pings_config_with_bom() {
  printf '\xef\xbb\xbf[ui.toast]\ndelivery = "system"\n' > "$T/config.toml"
  expect_pings "system on"
}

t_pings_broken_config_is_unknown() {
  printf '[ui.toast\ndelivery = \n' > "$T/config.toml"
  expect_pings "unknown unknown"
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
