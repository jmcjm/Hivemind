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
  unset HIVE_DRONE HIVE_FRONT HERDR_PANE_ID KIND FAKE_HERDR_DOWN FAKE_NO_CURRENT_PANE FAKE_WORKSPACE_CREATE_FAIL FAKE_TAB_CREATE_FAIL FAKE_AGENT_START_FAIL FAKE_WORKSPACE_PANES FAKE_WORKSPACE_TABS FAKE_TAB_PANES FAKE_WORKSPACE_GET_FAIL FAKE_DEAD_PANES FAKE_PANE_TABS HIVE_DRONE_LAYOUT FAKE_AGENT_STATUS FAKE_SESSION_ID FAKE_TOAST_SHOWN FAKE_NOTIFY_FAIL \
        HIVE_UNWATCHED_GRACE HIVE_MAIL_REMIND HIVE_MAIL_OVERDUE HIVE_MAIL_OVERDUE_BUSY \
        HIVE_SWEEP_RENOTIFY HIVE_WATCH_ALL HIVE_WATCH_COALESCE_MAX
  # The watcher prints what each one-second pass found, without waiting for a burst to settle:
  # the tests below read one letter at a time. Coalescing has its own test.
  export HIVE_WATCH_COALESCE=0
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

t_watch_burst_is_one_line_and_inbox_consumes() {
  export HIVE_WATCH_COALESCE=2
  start_watch "$T/out"
  local i; for i in 1 2 3 4 5; do send_coord "d$i" decision "question $i"; done
  sleep 4
  assert_count "$T/out" "HIVE-MAIL" 1
  assert_contains "$T/out" "HIVE-MAIL 5 letters: d1 [DECISION] question 1 | d2 [DECISION] question 2 |"
  assert_contains "$T/out" "d3 [DECISION] question 3"
  "$HIVE" inbox > "$T/inbox"
  assert_count "$T/inbox" "question" 5
  [ "$(letters)" = 0 ] || fail "inbox left $(letters) letter(s)"
  sleep 2
  assert_count "$T/out" "HIVE-MAIL" 1
}

t_watch_turn_without_report_is_quiet() {
  start_watch "$T/out"
  send_coord kafka done "finished a turn (report: no report)"
  sleep 2
  assert_not_contains "$T/out" "HIVE-MAIL"
  [ "$(letters)" = 1 ] || fail "the quiet letter is not in the mailbox"
  "$HIVE" inbox > "$T/inbox"
  assert_contains "$T/inbox" "finished a turn (report: no report)"
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
  # notify-send is there and fails (no session bus), and there is no osascript: the alert did not
  # go out, and herdr's "shown" does not pass for it.
  coord_gone
  PATH="$(path_without osascript)" FAKE_NOTIFY_FAIL=1 send_coord kafka done "first"
  [ ! -e "$HIVE_DIR/.stranded-notice" ] || fail "a failed alert left its rate-limit marker"
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
  send_coord sql done "second"                            # the notifier works again: no rate limit in the way
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 2
  [ -e "$HIVE_DIR/.stranded-notice" ] || fail "a delivered alert left no rate-limit marker"
}

t_alert_falls_through_to_osascript_when_notify_send_fails() {
  # A notify-send with no notification service behind it (libnotify from a package manager on
  # macOS) must not keep the alert from the notifier that works.
  coord_gone
  FAKE_NOTIFY_FAIL=1 send_coord kafka done "finished"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail: no coordinator is listening" 1
  assert_count "$FAKE_HERDR_LOG" "osascript -e on run argv" 1
  assert_not_contains "$FAKE_HERDR_LOG" "notification show"
  [ -e "$HIVE_DIR/.stranded-notice" ] || fail "osascript took the alert, yet no rate-limit marker"
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
  assert_contains "$T/out" "sweep: unwatched-mail alert (1 letters) via notify-send"
}

t_sweep_names_a_herdr_toast_for_what_it_is() {
  # No desktop notifier: the alert is a herdr toast, and "shown" is all herdr says — also for a
  # toast its client drops. The journal must not read as if somebody had seen it.
  coord_gone
  mail_aged '-10 minutes'
  rm -f "$HIVE_DIR/.stranded-notice"
  PATH="$(path_without notify-send osascript)" "$HIVE" sweep > "$T/out"
  assert_contains "$T/out" 'sweep: unwatched-mail alert (1 letters) via herdr toast (herdr says shown; nothing is displayed when [ui.toast] delivery is "off")'
}

t_sweep_rate_limited_unwatched_alert_prints_nothing() {
  # An alert went out a moment ago: this sweep sends nothing, and says nothing either — a line
  # here would read as a second alert.
  coord_gone
  mail_aged '-10 minutes'                                 # alerts through the send path, marker left
  : > "$FAKE_HERDR_LOG"
  "$HIVE" sweep > "$T/out"
  [ "$(alerts)" = 0 ] || fail "alerted again inside the rate limit"
  [ ! -s "$T/out" ] || fail "the sweep reported an alert it did not send: $(cat "$T/out")"
}

t_sweep_reports_alert_nobody_saw() {
  # The notifier fails, as in a unit with no session bus: the journal says so, and no marker
  # holds the next sweep back.
  coord_gone
  mail_aged '-10 minutes'
  rm -f "$HIVE_DIR/.stranded-notice"
  PATH="$(path_without osascript)" FAKE_NOTIFY_FAIL=1 "$HIVE" sweep > "$T/out"
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
  assert_contains "$T/out" "sweep: overdue mail reminder (1 letters, 40 min old) via notify-send"
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
  PATH="$(path_without osascript)" FAKE_NOTIFY_FAIL=1 FAKE_AGENT_STATUS=blocked "$HIVE" sweep > "$T/out"
  assert_contains "$T/out" "sweep: overdue mail reminder NOT delivered (1 letters, 40 min old)"
  [ ! -e "$HIVE_DIR/.overdue-notice" ] || fail "a reminder nobody saw started the re-nag interval"
}

t_sweep_overdue_renags_once_per_interval() {
  mail_aged '-40 minutes'
  touch "$HIVE_DIR/.watch-coord"
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=blocked "$HIVE" sweep >/dev/null
  FAKE_AGENT_STATUS=blocked "$HIVE" sweep > "$T/second"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread" 1
  [ ! -s "$T/second" ] || fail "the sweep reported a reminder it held back: $(cat "$T/second")"
  touch -d '-61 minutes' "$HIVE_DIR/.overdue-notice"      # HIVE_SWEEP_RENOTIFY (60 min) has passed
  FAKE_AGENT_STATUS=blocked "$HIVE" sweep >/dev/null
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread" 2
  "$HIVE" inbox >/dev/null                                # the mail is read: the next overdue letter is a new matter
  mail_aged '-40 minutes'
  FAKE_AGENT_STATUS=blocked "$HIVE" sweep >/dev/null
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread" 3
}

t_sweep_overdue_remote_coordinator() {
  # The coordinator lives on another machine and the ssh forward keeps failing: the letters wait
  # here, and no watcher or pane on this machine can vouch for them — the overdue alert goes out
  # whatever their state.
  echo "coordhost" > "$HIVE_DIR/coord.remote"
  mail_aged '-40 minutes'
  : > "$FAKE_HERDR_LOG"
  FAKE_AGENT_STATUS=working "$HIVE" sweep > "$T/out"
  assert_contains "$FAKE_HERDR_LOG" "ssh -o BatchMode=yes -o ConnectTimeout=5 coordhost"
  assert_count "$FAKE_HERDR_LOG" "notify-send -a hive Swarm mail unread for 40 min" 1
  [ "$(letters)" = 1 ] || fail "a letter whose forward failed left the mailbox"
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
  # A turn ended without a report is a quiet letter: in the mailbox, never a notification.
  assert_not_contains "$T/out" "finished a turn (report: no report)"
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
  mkdir -p "$T/home/work"; echo '{}' > "$T/home/.claude.json"
  # The caller's CLAUDE_CONFIG_DIR (a coordinator on another account) must not leak into the drone.
  CLAUDE_CONFIG_DIR="$T/elsewhere" hive_home spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 \
    || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "tab create --workspace w1 --label kafka"
  assert_not_contains "$FAKE_HERDR_LOG" "CLAUDE_CONFIG_DIR"
  assert_contains "$T/out" "account=default"
  [ -z "$(drone_meta_field kafka account)" ] || fail "meta account: $(drone_meta_field kafka account)"
  [ "$(trusted "$T/home/.claude.json" "$T/home/work")" = True ] || fail "cwd not trusted in ~/.claude.json"
  [ ! -e "$T/elsewhere" ] || fail "the caller's CLAUDE_CONFIG_DIR was written to"
}

t_spawn_trust_never_creates_a_config() {
  # No ~/.claude.json: the account never ran, and a config holding nothing but a trust entry is
  # not hive's to put there. The spawn goes on; its bootstrap answers the dialog if one shows.
  mkdir -p "$T/home/work"
  hive_home spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  [ ! -e "$T/home/.claude.json" ] || fail "a config was created: $(cat "$T/home/.claude.json")"
}

t_spawn_trust_keeps_a_symlinked_config_a_link() {
  mkdir -p "$T/home/work" "$T/dotfiles"; echo '{"theme":"dark"}' > "$T/dotfiles/claude.json"
  ln -s "$T/dotfiles/claude.json" "$T/home/.claude.json"
  hive_home spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  [ -L "$T/home/.claude.json" ] || fail "the symlinked config was replaced by a regular file"
  [ "$(trusted "$T/dotfiles/claude.json" "$T/home/work")" = True ] || fail "cwd not trusted at the link's target"
  assert_contains "$T/dotfiles/claude.json" '"theme": "dark"'
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

# --- fronts --------------------------------------------------------------------
# Several independent swarms, one coordinator each. The default front is $HIVE_DIR itself.

front_add() { "$HIVE" front add "$@" > /dev/null || fail "front add $1 failed"; }

front_letters() {  # front_letters <front> [mailbox] — unread letters in that front's mailbox (default: coord)
  find "$HIVE_DIR/fronts/$1/mail/${2:-coord}" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

fake_drone() {  # fake_drone <front|default> <name> [pane] — a drone with a task in flight: a brief, no report
  local d="$HIVE_DIR/fronts/$1/drones/$2"
  [ "$1" = default ] && d="$HIVE_DIR/drones/$2"
  mkdir -p "$d"
  local pane="${3:-w7:p1}"                        # a drone from before tabs: the pane's workspace is its own
  printf '{"name":"%s","workspace_id":"%s","pane_id":"%s","session_id":"5e55e55e-0000-4000-8000-%012d","cwd":"%s","account":""}\n' \
    "$2" "${pane%%:*}" "$pane" "$RANDOM" "$T" > "$d/meta.json"
  printf '# Brief: %s\nWrite the report to %s/report.md\n' "$2" "$d" > "$d/brief.md"
}

start_watch_front() {  # start_watch_front <front> <outfile>
  HIVE_FRONT="$1" "$HIVE" watch > "$2" 2>&1 &
  WATCH_PIDS+=($!)
  sleep 1.5
}

t_front_add_creates_front_and_home() {
  "$HIVE" front add wms "Warehouse: scanners, receiving, put-away" > "$T/out" || fail "front add failed: $(cat "$T/out")"
  [ -d "$HIVE_DIR/fronts/wms/drones" ] && [ -d "$HIVE_DIR/fronts/wms/mail" ] || fail "front directories missing"
  assert_contains "$HIVE_DIR/fronts/wms/description" "Warehouse: scanners, receiving, put-away"
  assert_contains "$HIVE_DIR/coord/wms/CLAUDE.md" "# Front: wms"
  assert_contains "$HIVE_DIR/coord/wms/CLAUDE.md" 'Monitor(command: "hive --front wms watch", description: "swarm mail (wms)", timeout_ms: 1800000)'
  assert_contains "$T/out" "hive --front wms coord-start"
  "$HIVE" front add wms > /dev/null 2>&1 && fail "a second 'front add wms' was accepted"
  "$HIVE" front add default > /dev/null 2>&1 && fail "'default' was accepted as a front name"
  "$HIVE" front add Bad > /dev/null 2>&1 && fail "'Bad' was accepted as a front name"
  "$HIVE" front describe wms "WMS only" > /dev/null || fail "front describe failed"
  assert_contains "$HIVE_DIR/fronts/wms/description" "WMS only"
}

t_front_unknown_is_refused_and_not_created() {
  front_add wms
  "$HIVE" --front nope status > "$T/out" 2>&1 && fail "an unknown front was accepted"
  assert_contains "$T/out" "unknown front 'nope' — create it: hive front add nope"
  HIVE_FRONT=nope "$HIVE" send coord hi --body '' > /dev/null 2>&1 && fail "HIVE_FRONT=nope was accepted"
  [ -e "$HIVE_DIR/fronts/nope" ] && fail "a typo made a front"
  "$HIVE" --front default status > /dev/null || fail "'--front default' refused"
}

t_front_mail_stays_in_its_front() {
  front_add wms
  start_watch "$T/default"
  start_watch_front wms "$T/wms"
  HIVE_FRONT=wms HIVE_DRONE=kafka KIND=decision "$HIVE" send coord "which bin?" --body '' > /dev/null
  sleep 2
  [ "$(front_letters wms)" = 1 ] || fail "wms coord mailbox holds $(front_letters wms) letter(s)"
  [ "$(letters)" = 0 ] || fail "the default coordinator got the wms letter"
  assert_contains "$T/wms" "HIVE-MAIL kafka [DECISION] which bin?"
  assert_not_contains "$T/default" "which bin?"
  # Two watchers of two fronts are two listeners, not a takeover.
  assert_not_contains "$T/default" "taken over"
  assert_not_contains "$T/wms" "taken over"
  "$HIVE" _watched || fail "the default front's watcher is not live"
  HIVE_FRONT=wms "$HIVE" _watched || fail "the wms front's watcher is not live"
  HIVE_FRONT=wms "$HIVE" inbox > "$T/inbox"
  assert_contains "$T/inbox" "which bin?"
  [ "$(front_letters wms)" = 0 ] || fail "inbox of wms left its letter"
}

t_front_found_from_the_coordinator_pane() {
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  HERDR_PANE_ID=w3:p1 "$HIVE" status > "$T/mine"
  assert_contains "$T/mine" "front: wms"
  HERDR_PANE_ID=w9:p9 "$HIVE" status > "$T/other"
  assert_contains "$T/other" "front: default"
  # A named front wins over the pane.
  HERDR_PANE_ID=w3:p1 HIVE_FRONT=default "$HIVE" status > "$T/named"
  assert_contains "$T/named" "front: default"
}

t_coord_register_takes_the_pane_from_another_front() {
  front_add wms                                   # setup registered w1:p1 for the default front
  HIVE_FRONT=wms "$HIVE" coord > "$T/out" 2> "$T/err"
  [ "$(cat "$HIVE_DIR/fronts/wms/coord.pane" 2>/dev/null)" = "w1:p1" ] || fail "wms did not get the pane"
  [ -e "$HIVE_DIR/coord.pane" ] && fail "the pane still coordinates the default front too"
  assert_contains "$T/err" "coord: pane w1:p1 leaves front default — front default has no coordinator now"
  assert_contains "$T/out" 'coord: arm the mail watcher — Monitor(command: "hive --front wms watch", description: "swarm mail (wms)", timeout_ms: 1800000)'
}

t_spawn_into_another_front_keeps_both_coordinators() {
  front_add wms
  mkdir -p "$T/home/work"; echo '{}' > "$T/home/.claude.json"
  HOME="$T/home" "$HIVE" --front wms spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  [ -f "$HIVE_DIR/fronts/wms/drones/kafka/meta.json" ] || fail "the drone is not in front wms"
  [ -e "$HIVE_DIR/drones/kafka" ] && fail "the drone landed in the default front"
  assert_contains "$FAKE_HERDR_LOG" "--env HIVE_FRONT=wms"
  [ "$(cat "$HIVE_DIR/coord.pane")" = "w1:p1" ] || fail "the default front lost its coordinator"
  [ -e "$HIVE_DIR/fronts/wms/coord.pane" ] && fail "the default coordinator's pane was registered for wms"
  # Its own front's drones carry the default front by name.
  HOME="$T/home" "$HIVE" spawn sql --cwd "$T/home/work" > /dev/null 2>&1 || fail "default spawn failed"
  assert_contains "$FAKE_HERDR_LOG" "--env HIVE_FRONT=default"
}

t_spawn_name_is_unique_across_fronts() {
  front_add wms
  fake_drone default kafka
  mkdir -p "$T/home/work"; echo '{}' > "$T/home/.claude.json"
  HOME="$T/home" "$HIVE" --front wms spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 && fail "a second kafka was spawned"
  assert_contains "$T/out" "drone kafka belongs to front default"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace create"
}

t_send_to_another_fronts_coordinator() {
  front_add wms; front_add shp
  printf 'the body' | HIVE_FRONT=wms HIVE_DRONE=kafka "$HIVE" send shp:coord "need the SHP schema" > "$T/out" \
    || fail "cross-front send failed"
  assert_contains "$T/out" "send: kafka -> shp:coord: need the SHP schema"
  [ "$(front_letters shp)" = 1 ] || fail "shp coord mailbox holds $(front_letters shp) letter(s)"
  [ "$(front_letters wms)" = 0 ] || fail "the letter stayed in wms"
  local f; f=$(find "$HIVE_DIR/fronts/shp/mail/coord" -name '*.json' | head -1)
  local from; from=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['from'])" "$f")
  [ "$from" = "wms:kafka" ] || fail "sender is '$from', not wms:kafka"
  python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))['body']=='the body' else 1)" "$f" || fail "body lost"
  # The reply goes back the same way; the default front is addressed by name too.
  HIVE_FRONT=shp "$HIVE" send default:coord "ack" --body '' > /dev/null || fail "send to default:coord failed"
  [ "$(letters)" = 1 ] || fail "default coord got $(letters) letter(s)"
  HIVE_FRONT=wms "$HIVE" send shp:all "everyone" --body '' > "$T/all" 2>&1 && fail "a cross-front broadcast was sent"
}

t_send_bare_name_reaches_a_drone_of_another_front() {
  front_add wms; front_add shp
  fake_drone shp sql w5:p1
  HIVE_FRONT=wms HIVE_DRONE=kafka "$HIVE" send sql "column names?" --body '' > /dev/null || fail "send failed"
  [ "$(front_letters shp sql)" = 1 ] || fail "sql's mailbox in shp holds $(front_letters shp sql) letter(s)"
  [ -e "$HIVE_DIR/fronts/wms/mail/sql" ] && fail "a ghost mailbox for sql appeared in wms"
  assert_contains "$FAKE_HERDR_LOG" "agent prompt w5:p1 HIVE-MAIL: new mail. Run: hive inbox"
}

t_sweep_covers_every_front() {
  front_add wms
  fake_drone wms stuck w5:p1
  export FAKE_AGENT_STATUS=idle
  HIVE_FRONT=default "$HIVE" sweep > "$T/one"
  [ "$(front_letters wms)" = 0 ] || fail "a sweep of the default front reported a wms drone"
  "$HIVE" sweep > "$T/all"
  assert_contains "$T/all" "sweep [wms]: SWEEP: drone stuck sits idle without a report"
  [ "$(front_letters wms)" = 1 ] || fail "wms coord mailbox holds $(front_letters wms) letter(s)"
  [ "$(letters)" = 0 ] || fail "the default coordinator got the wms sweep alert"
}

t_stop_hook_is_scoped_to_the_sessions_front() {
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"   # the default front's coordinator is w1:p1
  HIVE_FRONT=wms HIVE_DRONE=kafka "$HIVE" send coord "finished" --body '' > /dev/null
  # The wms coordinator (its hooks run in its pane, w3:p1) is held...
  echo '{"session_id":"S1"}' | HERDR_PANE_ID=w3:p1 FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-mail-check.sh" > "$T/wms"
  assert_contains "$T/wms" '"decision": "block"'
  assert_contains "$T/wms" "the coordinator mailbox of front wms"
  # ...and so is a session started by coord-start, which carries its front...
  echo '{"session_id":"S1"}' | HIVE_FRONT=wms FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-mail-check.sh" > "$T/env"
  assert_contains "$T/env" '"decision": "block"'
  # ...while the default coordinator, whose own mailbox is empty, is not.
  echo '{"session_id":"S2"}' | HERDR_PANE_ID=w1:p1 FAKE_SESSION_ID=S2 bash "$ROOT/skill/coord-mail-check.sh" > "$T/default"
  [ -s "$T/default" ] && fail "the default coordinator was held for wms mail"
  # Default-front mail does not hold the wms coordinator either.
  "$HIVE" inbox > /dev/null; HIVE_FRONT=wms "$HIVE" inbox > /dev/null
  HIVE_DRONE=sql "$HIVE" send coord "finished" --body '' > /dev/null
  echo '{"session_id":"S1"}' | HERDR_PANE_ID=w3:p1 FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-mail-check.sh" > "$T/cross"
  [ -s "$T/cross" ] && fail "the wms coordinator was held for default-front mail"
}

t_board_is_the_fronts_own() {
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  fake_drone default homebody
  fake_drone wms picker
  echo '{"session_id":"S1","source":"compact"}' \
    | HERDR_PANE_ID=w3:p1 FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-creed-inject.sh" > "$T/board"
  assert_contains "$T/board" "You coordinate front 'wms'"
  assert_contains "$T/board" 'Mail watcher: NOT ARMED — you hear no drone until you arm it: Monitor(command: "hive --front wms watch", description: "swarm mail (wms)", timeout_ms: 1800000).'
  assert_contains "$T/board" "picker"
  assert_not_contains "$T/board" "homebody"
  echo '{"session_id":"S1"}' | HERDR_PANE_ID=w3:p1 FAKE_SESSION_ID=S1 bash "$ROOT/skill/coord-compact-brief.sh" > "$T/brief"
  assert_contains "$T/brief" "This session coordinates front 'wms'"
}

t_drone_ping_reports_to_its_front() {
  front_add wms
  mkdir -p "$T/home/.claude/skills/hivemind" "$HIVE_DIR/fronts/wms/drones/kafka"
  ln -s "$ROOT/skill/hive" "$T/home/.claude/skills/hivemind/hive"
  printf 'STATUS: DONE\n' > "$HIVE_DIR/fronts/wms/drones/kafka/report.md"
  echo '{}' | HOME="$T/home" HIVE_FRONT=wms HIVE_DRONE=kafka bash "$ROOT/skill/drone-ping.sh" done
  [ "$(front_letters wms)" = 1 ] || fail "wms coord mailbox holds $(front_letters wms) letter(s)"
  [ "$(letters)" = 0 ] || fail "the default coordinator got the wms drone's letter"
  HIVE_FRONT=wms "$HIVE" inbox > "$T/inbox"
  assert_contains "$T/inbox" "finished a turn (report: DONE)"
}

t_move_a_dead_drone() {
  front_add wms
  fake_drone default old w5:p1
  HIVE_DRONE=coord "$HIVE" send old "a letter waiting" --body '' > /dev/null
  FAKE_AGENT_STATUS=dead "$HIVE" move old wms > "$T/out" 2>&1 || fail "move failed: $(cat "$T/out")"
  [ -f "$HIVE_DIR/fronts/wms/drones/old/meta.json" ] || fail "the drone is not in wms"
  [ -e "$HIVE_DIR/drones/old" ] && fail "the drone is still in the default front"
  [ "$(front_letters wms old)" = 1 ] || fail "its mailbox did not move along"
  assert_contains "$HIVE_DIR/fronts/wms/drones/old/brief.md" "$HIVE_DIR/fronts/wms/drones/old/report.md"
  assert_contains "$T/out" "hive --front wms revive old"
  assert_not_contains "$FAKE_HERDR_LOG" "agent start"
}

t_move_a_living_drone_resumes_it_in_the_new_front() {
  front_add wms
  fake_drone default live w5:p1
  local sid; sid=$(drone_meta_field live session_id)
  mkdir -p "$T/home"; echo '{}' > "$T/home/.claude.json"
  HOME="$T/home" "$HIVE" move live wms > "$T/out" 2>&1 || fail "move failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "workspace close w5"
  assert_contains "$FAKE_HERDR_LOG" "--env HIVE_FRONT=wms"
  assert_contains "$FAKE_HERDR_LOG" "--resume $sid"
  assert_contains "$FAKE_HERDR_LOG" "agent prompt live hive: you were moved to front 'wms'"
  [ -f "$HIVE_DIR/fronts/wms/drones/live/meta.json" ] || fail "the drone is not in wms"
  [ "$(cat "$HIVE_DIR/coord.pane")" = "w1:p1" ] || fail "the default front lost its coordinator"
  [ -e "$HIVE_DIR/fronts/wms/coord.pane" ] && fail "the move registered a coordinator for wms"
}

t_move_refuses_a_working_drone() {
  front_add wms
  fake_drone default busy w5:p1
  FAKE_AGENT_STATUS=working "$HIVE" move busy wms > "$T/out" 2>&1 && fail "a working drone was moved"
  assert_contains "$T/out" "busy is working"
  [ -d "$HIVE_DIR/drones/busy" ] || fail "the refused move moved it anyway"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
}

t_fronts_overview_and_status_all() {
  front_add wms "Warehouse"
  fake_drone default homebody
  fake_drone wms picker
  "$HIVE" fronts > "$T/fronts"
  assert_contains "$T/fronts" "FRONT"
  grep -qE '^default +w1:p1 ' "$T/fronts" || fail "default row: $(grep '^default' "$T/fronts")"
  grep -qE '^wms +- +- +off +0 +1 +1 +Warehouse$' "$T/fronts" || fail "wms row: $(grep '^wms' "$T/fronts")"
  "$HIVE" status --all > "$T/all"
  assert_contains "$T/all" "front: default"
  assert_contains "$T/all" "front: wms"
  assert_contains "$T/all" "homebody"
  assert_contains "$T/all" "picker"
}

t_front_rm() {
  front_add wms
  fake_drone wms picker
  "$HIVE" front rm wms > "$T/out" 2>&1 && fail "a front with drones was removed"
  rm -rf "$HIVE_DIR/fronts/wms/drones/picker"
  "$HIVE" front rm wms > "$T/out" 2>&1 || fail "front rm failed: $(cat "$T/out")"
  [ -e "$HIVE_DIR/fronts/wms" ] && fail "the front is still there"
  ls "$HIVE_DIR"/archive/front-wms-*.tar.gz > /dev/null 2>&1 || fail "no archive of the front"
}

t_coord_start_runs_in_the_fronts_home() {
  front_add wms
  HIVE_FRONT=wms "$HIVE" coord-start --dry-run > "$T/out" 2>&1 || fail "dry run failed: $(cat "$T/out")"
  assert_contains "$T/out" "for front wms and run in $HIVE_DIR/coord/wms"
  assert_contains "$T/out" "HIVE_FRONT=wms"
}

t_gate_is_shared_and_names_the_fronts_coordinator() {
  front_add wms
  HIVE_FRONT=wms "$HIVE" gate enter "full gate, ~5 min" > /dev/null || fail "gate enter failed"
  assert_contains "$HIVE_DIR/gate.log" "wms:coord ENTER full gate, ~5 min"
  [ -e "$HIVE_DIR/fronts/wms/gate.log" ] && fail "the front got a gate of its own"
  "$HIVE" gate status > "$T/status"
  assert_contains "$T/status" "wms:coord ENTER"
}

t_remote_forward_keeps_the_front() {
  front_add wms
  echo "coordhost" > "$HIVE_DIR/fronts/wms/coord.remote"
  HIVE_FRONT=wms HIVE_DRONE=kafka "$HIVE" send coord "hello" --body '' > /dev/null
  assert_contains "$FAKE_HERDR_LOG" "HIVE_FRONT=wms HIVE_DRONE=kafka@"
  [ "$(front_letters wms)" = 1 ] || fail "the failed forward did not leave the letter in wms"
}

t_move_refuses_while_herdr_is_unreachable() {
  front_add wms
  fake_drone default live w5:p1
  FAKE_HERDR_DOWN=1 "$HIVE" move live wms > "$T/out" 2>&1 && fail "a move went ahead without herdr"
  assert_contains "$T/out" "herdr server unreachable"
  [ -d "$HIVE_DIR/drones/live" ] || fail "the drone was moved anyway"
}

t_move_merges_into_an_existing_mailbox() {
  front_add wms
  fake_drone default old w5:p1
  HIVE_DRONE=coord "$HIVE" send old "waiting in default" --body '' > /dev/null
  mkdir -p "$HIVE_DIR/fronts/wms/mail/old"
  cp "$HIVE_DIR"/mail/old/*.json "$HIVE_DIR/fronts/wms/mail/old/1-already-there.json"
  FAKE_AGENT_STATUS=dead "$HIVE" move old wms > "$T/out" 2>&1 || fail "move failed: $(cat "$T/out")"
  [ "$(front_letters wms old)" = 2 ] || fail "wms mailbox of old holds $(front_letters wms old) letter(s), expected 2"
  [ -e "$HIVE_DIR/fronts/wms/mail/old/old" ] && fail "the mailbox was nested inside the existing one"
  [ -e "$HIVE_DIR/mail/old" ] && fail "the old mailbox is still there"
  assert_not_contains "$T/out" "warning"
}

t_move_takes_force_anywhere_and_names_the_way_back() {
  front_add wms
  fake_drone default busy w5:p1
  mkdir -p "$T/home"; echo '{}' > "$T/home/.claude.json"
  FAKE_AGENT_STATUS=working FAKE_WORKSPACE_CREATE_FAIL=1 HOME="$T/home" "$HIVE" move --force busy wms > "$T/out" 2>&1 \
    && fail "a failed restart reported success"
  assert_contains "$FAKE_HERDR_LOG" "workspace close w5"
  assert_contains "$T/out" "hive --front wms revive busy"
  [ -f "$HIVE_DIR/fronts/wms/drones/busy/meta.json" ] || fail "the drone is not in wms"
  "$HIVE" move busy wms extra > /dev/null 2>&1 && fail "a third argument was accepted"
}

t_coord_takeover_retires_the_old_fronts_watcher() {
  front_add wms
  start_watch "$T/default"                        # the default front's watcher, in pane w1:p1
  local w="${WATCH_PIDS[0]}"
  HIVE_FRONT=wms "$HIVE" coord > /dev/null 2>&1
  sleep 2
  assert_contains "$T/default" "HIVE-WATCH: the pane of front default now coordinates another front — stopping"
  kill -0 "$w" 2>/dev/null && fail "the default front's watcher still runs"
}

t_coord_refuses_a_front_other_than_the_sessions_own() {
  front_add wms
  HIVE_FRONT=default "$HIVE" --front wms coord > "$T/out" 2>&1 && fail "a pinned session was registered for another front"
  assert_contains "$T/out" "coord-start pinned it to that front"
  assert_contains "$T/out" "hive --front wms coord-start"
  [ "$(cat "$HIVE_DIR/coord.pane")" = "w1:p1" ] || fail "the default front lost its coordinator"
  [ -e "$HIVE_DIR/fronts/wms/coord.pane" ] && fail "wms was registered anyway"
}

t_coord_without_a_pane_is_refused() {
  front_add wms
  FAKE_NO_CURRENT_PANE=1 "$HIVE" coord > "$T/out" 2>&1 && fail "coord without a pane succeeded"
  assert_contains "$T/out" "no herdr pane to register"
  assert_not_contains "$T/out" "leaves front"
  [ "$(cat "$HIVE_DIR/coord.pane")" = "w1:p1" ] || fail "the registration was overwritten"
}

t_spawn_with_front_flag_keeps_a_living_coordinator() {
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  rm -f "$HIVE_DIR/coord.pane"                    # the calling pane, w1:p1, coordinates nothing
  mkdir -p "$T/home/work"; echo '{}' > "$T/home/.claude.json"
  HOME="$T/home" "$HIVE" --front wms spawn kafka --cwd "$T/home/work" > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  [ "$(cat "$HIVE_DIR/fronts/wms/coord.pane")" = "w3:p1" ] || fail "wms's living coordinator was replaced"
}

t_spawn_never_registers_a_drone_or_a_session_pinned_elsewhere() {
  front_add wms
  rm -f "$HIVE_DIR/coord.pane"                    # the calling pane, w1:p1, coordinates nothing
  mkdir -p "$T/home/work"; echo '{}' > "$T/home/.claude.json"
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  HIVE_FRONT=wms HOME="$T/home" "$HIVE" spawn one --cwd "$T/home/work" > /dev/null 2>&1 || fail "spawn one failed"
  [ "$(cat "$HIVE_DIR/fronts/wms/coord.pane")" = "w3:p1" ] || fail "HIVE_FRONT=wms spawn replaced wms's living coordinator"
  HIVE_DRONE=kafka HOME="$T/home" "$HIVE" spawn two --cwd "$T/home/work" > /dev/null 2>&1 || fail "spawn two failed"
  [ -e "$HIVE_DIR/coord.pane" ] && fail "a drone's spawn registered its pane as the coordinator"
  rm -f "$HIVE_DIR/fronts/wms/coord.pane"
  HIVE_FRONT=default HOME="$T/home" "$HIVE" --front wms spawn three --cwd "$T/home/work" > /dev/null 2>&1 || fail "spawn three failed"
  [ -e "$HIVE_DIR/fronts/wms/coord.pane" ] && fail "a session pinned to default registered its pane for wms"
}

t_front_rm_refuses_while_herdr_is_unreachable() {
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  FAKE_HERDR_DOWN=1 "$HIVE" front rm wms > "$T/out" 2>&1 && fail "a front was removed without herdr"
  assert_contains "$T/out" "herdr is unreachable — nothing removed"
  [ -d "$HIVE_DIR/fronts/wms" ] || fail "the front is gone"
}

t_send_explicit_front_must_hold_the_drone() {
  front_add wms; front_add shp
  fake_drone shp sql w5:p1
  HIVE_FRONT=wms HIVE_DRONE=kafka "$HIVE" send wms:sql "x" --body '' > "$T/out" 2>&1 && fail "a wrong address was delivered"
  assert_contains "$T/out" "front wms has no drone sql (it belongs to front shp)"
  [ "$(front_letters shp sql)" = 0 ] || fail "the letter was rerouted to shp"
  HIVE_FRONT=wms "$HIVE" send nope:coord "x" --body '' > "$T/out" 2>&1 && fail "an unknown front was accepted"
  assert_contains "$T/out" "unknown front 'nope'"
}

t_unknown_drone_names_its_front() {
  front_add shp
  fake_drone shp sql w5:p1
  "$HIVE" peek sql > "$T/out" 2>&1 && fail "peek of another front's drone succeeded"
  assert_contains "$T/out" "it belongs to front shp (hive --front shp <command> sql)"
  "$HIVE" peek nobody > "$T/none" 2>&1
  assert_contains "$T/none" "unknown drone: nobody"
}

t_rename_keeps_names_unique_across_fronts() {
  front_add wms
  fake_drone default alpha
  fake_drone wms beta
  HIVE_FRONT=wms "$HIVE" rename beta alpha > "$T/out" 2>&1 && fail "a rename took a name another front holds"
  assert_contains "$T/out" "drone alpha belongs to front default"
  [ -d "$HIVE_DIR/fronts/wms/drones/beta" ] || fail "the refused rename moved the drone"
}

t_front_rm_refuses_mail_and_a_living_coordinator() {
  front_add wms
  HIVE_FRONT=wms HIVE_DRONE=kafka "$HIVE" send coord "unread" --body '' > /dev/null
  "$HIVE" front rm wms > "$T/out" 2>&1 && fail "a front with unread mail was removed"
  assert_contains "$T/out" "has unread mail"
  HIVE_FRONT=wms "$HIVE" inbox > /dev/null
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  "$HIVE" front rm wms > "$T/out" 2>&1 && fail "a front with a living coordinator was removed"
  assert_contains "$T/out" "still has its coordinator in pane w3:p1"
  FAKE_AGENT_STATUS=dead "$HIVE" front rm wms > "$T/out" 2>&1 || fail "rm with a dead coordinator failed: $(cat "$T/out")"
}

t_front_names_skip_stray_directories() {
  front_add wms
  mkdir -p "$HIVE_DIR/fronts/My Front" "$HIVE_DIR/fronts/default"
  "$HIVE" fronts > "$T/out"
  assert_not_contains "$T/out" "My "
  assert_not_contains "$T/out" "Front "
  [ "$(grep -c '^default ' "$T/out")" = 1 ] || fail "a directory named default became a second default front"
}

t_gate_queue_is_one_for_the_machine() {
  front_add wms
  HIVE_FRONT=wms "$HIVE" gate queue set kafka sql > /dev/null || fail "queue set failed"
  "$HIVE" gate queue > "$T/q"
  assert_contains "$T/q" "1. kafka"
  [ -e "$HIVE_DIR/fronts/wms/gate.queue" ] && fail "the front got a queue of its own"
}

# --- drones as tabs of their coordinator's workspace ---------------------------
# setup registers w1:p1 as the default front's coordinator: the fake places it in workspace w1.

spawn_home() {  # spawn_home <name> [args...] — spawn under the test HOME, into $T/home/work
  mkdir -p "$T/home/work"; [ -f "$T/home/.claude.json" ] || echo '{}' > "$T/home/.claude.json"
  local n="$1"; shift
  HOME="$T/home" "$HIVE" spawn "$n" --cwd "$T/home/work" "$@"
}

t_spawn_opens_a_tab_in_the_coordinators_workspace() {
  spawn_home kafka > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "tab create --workspace w1 --label kafka --cwd $T/home/work --no-focus --env HIVE_DRONE=kafka"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace create"
  assert_contains "$T/out" "ws=w1 tab=w1:t9 pane=w1:p9"
  [ "$(drone_meta_field kafka tab_id)" = "w1:t9" ] || fail "meta tab_id: $(drone_meta_field kafka tab_id)"
  [ "$(drone_meta_field kafka home_workspace_id)" = "w1" ] || fail "meta home_workspace_id: $(drone_meta_field kafka home_workspace_id)"
  # Older hive closes workspace_id outright: a drone in a tab must never carry the coordinator's.
  [ -z "$(drone_meta_field kafka workspace_id)" ] || fail "a drone in a tab carries workspace_id $(drone_meta_field kafka workspace_id)"
}

t_spawn_without_a_living_coordinator_opens_a_workspace() {
  rm -f "$HIVE_DIR/coord.pane"
  FAKE_NO_CURRENT_PANE=1 spawn_home lone > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "workspace create --label lone"
  assert_not_contains "$FAKE_HERDR_LOG" "tab create"
  [ -z "$(drone_meta_field lone tab_id)" ] || fail "a drone with its own workspace recorded a tab"
  # The layout can be forced back to a workspace per drone, and nothing else is accepted.
  : > "$FAKE_HERDR_LOG"
  HIVE_DRONE_LAYOUT=workspace spawn_home solo > /dev/null 2>&1 || fail "spawn with HIVE_DRONE_LAYOUT=workspace failed"
  assert_contains "$FAKE_HERDR_LOG" "workspace create --label solo"
  HIVE_DRONE_LAYOUT=grid spawn_home odd > "$T/bad" 2>&1 && fail "HIVE_DRONE_LAYOUT=grid was accepted"
  assert_contains "$T/bad" "HIVE_DRONE_LAYOUT='grid' — tab or workspace"
}

t_kill_closes_the_tab_never_the_coordinators_workspace() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  : > "$FAKE_HERDR_LOG"
  "$HIVE" kill kafka > "$T/out" 2>&1 || fail "kill failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "tab close w1:t9"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
  assert_contains "$T/out" "kill: kafka (tab w1:t9 closed, report kept)"
}

t_drone_from_before_tabs_closes_its_own_workspace() {
  fake_drone default old w7:p1                    # meta: workspace w7, no tab_id
  "$HIVE" kill old > "$T/out" 2>&1 || fail "kill failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "workspace close w7"
  assert_not_contains "$FAKE_HERDR_LOG" "tab close"
}

t_revive_reopens_the_drone_in_a_tab() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  : > "$FAKE_HERDR_LOG"
  HOME="$T/home" "$HIVE" revive kafka > "$T/out" 2>&1 || fail "revive failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "tab close w1:t9"
  assert_contains "$FAKE_HERDR_LOG" "tab create --workspace w1 --label kafka"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
}

t_failed_start_closes_only_its_tab() {
  FAKE_AGENT_START_FAIL=1 spawn_home kafka > "$T/out" 2>&1 && fail "a failed launch reported success"
  assert_contains "$T/out" "failed to start the agent"
  assert_contains "$FAKE_HERDR_LOG" "tab close w1:t9"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
}

t_rename_renames_the_tab() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  "$HIVE" rename kafka kafka2 > /dev/null 2>&1 || fail "rename failed"
  assert_contains "$FAKE_HERDR_LOG" "tab rename w1:t9 kafka2"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace rename"
}

t_adopt_in_a_shared_workspace_owns_only_its_tab() {
  FAKE_WORKSPACE_PANES=3 "$HIVE" adopt guest w5:p2 > "$T/out" 2>&1 || fail "adopt failed: $(cat "$T/out")"
  [ "$(drone_meta_field guest tab_id)" = "w5:t2" ] || fail "meta tab_id: $(drone_meta_field guest tab_id)"
  [ -z "$(drone_meta_field guest workspace_id)" ] || fail "an agent in a shared workspace recorded workspace_id"
  assert_contains "$FAKE_HERDR_LOG" "tab rename w5:t2 guest"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace rename"
  : > "$FAKE_HERDR_LOG"
  "$HIVE" kill guest > /dev/null 2>&1
  assert_contains "$FAKE_HERDR_LOG" "tab close w5:t2"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
  # Alone in its workspace, an adopted agent owns the workspace, as before.
  : > "$FAKE_HERDR_LOG"
  FAKE_WORKSPACE_PANES=1 "$HIVE" adopt hermit w6:p1 > /dev/null 2>&1 || fail "adopt of a lone agent failed"
  [ -z "$(drone_meta_field hermit tab_id)" ] || fail "a lone agent recorded a tab"
  assert_contains "$FAKE_HERDR_LOG" "workspace rename w6 hermit"
}

t_move_lands_in_the_new_coordinators_workspace() {
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  fake_drone default live w5:p1
  mkdir -p "$T/home"; echo '{}' > "$T/home/.claude.json"
  HOME="$T/home" "$HIVE" move live wms > "$T/out" 2>&1 || fail "move failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "workspace close w5"           # its own workspace, from before tabs
  assert_contains "$FAKE_HERDR_LOG" "tab create --workspace w3 --label live"
  [ "$(python3 -c "import json;print(json.load(open('$HIVE_DIR/fronts/wms/drones/live/meta.json')).get('tab_id',''))")" = "w3:t9" ] \
    || fail "the moved drone did not record its new tab"
}

t_a_coordinator_inside_an_old_drones_workspace_survives_its_kill() {
  fake_drone default old w7:p1                    # its own workspace w7, from before tabs
  echo "w7:p2" > "$HIVE_DIR/coord.pane"           # the coordinator was started in that workspace
  "$HIVE" kill old > "$T/out" 2>&1 || fail "kill failed: $(cat "$T/out")"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
  assert_contains "$FAKE_HERDR_LOG" "tab close w7:t1"
  assert_not_contains "$FAKE_HERDR_LOG" "tab close w7:t2"
}

t_a_split_tab_loses_only_the_drones_pane() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  : > "$FAKE_HERDR_LOG"
  FAKE_TAB_PANES=2 "$HIVE" kill kafka > "$T/out" 2>&1 || fail "kill failed"
  assert_contains "$FAKE_HERDR_LOG" "pane close w1:p9"
  assert_not_contains "$FAKE_HERDR_LOG" "tab close"
  assert_contains "$T/out" "kill: kafka (pane w1:p9 closed, report kept)"
}

t_adopt_a_split_of_the_coordinators_tab_owns_only_its_pane() {
  FAKE_WORKSPACE_PANES=2 FAKE_PANE_TABS="w1:p2=w1:t1" "$HIVE" adopt split w1:p2 > "$T/out" 2>&1 \
    || fail "adopt failed: $(cat "$T/out")"
  assert_contains "$T/out" "the drone owns only its pane"
  [ -z "$(drone_meta_field split tab_id)$(drone_meta_field split workspace_id)" ] || fail "the split claimed a tab or a workspace"
  assert_not_contains "$FAKE_HERDR_LOG" "tab rename"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace rename"
  : > "$FAKE_HERDR_LOG"
  FAKE_PANE_TABS="w1:p2=w1:t1" "$HIVE" kill split > /dev/null 2>&1
  assert_contains "$FAKE_HERDR_LOG" "pane close w1:p2"
  assert_not_contains "$FAKE_HERDR_LOG" "tab close"
}

t_adopt_refuses_when_herdr_cannot_describe_the_workspace() {
  FAKE_WORKSPACE_GET_FAIL=1 "$HIVE" adopt guest w5:p2 > "$T/out" 2>&1 && fail "adopt went ahead blind"
  assert_contains "$T/out" "nothing adopted"
  assert_not_contains "$FAKE_HERDR_LOG" "agent rename"
  [ -e "$HIVE_DIR/drones/guest" ] && fail "the refused adopt left a drone"
}

t_a_bad_layout_closes_nothing() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  front_add wms
  : > "$FAKE_HERDR_LOG"
  HIVE_DRONE_LAYOUT=grid HOME="$T/home" "$HIVE" revive kafka > "$T/out" 2>&1 && fail "revive accepted a bad layout"
  HIVE_DRONE_LAYOUT=grid HOME="$T/home" "$HIVE" move kafka wms > "$T/out2" 2>&1 && fail "move accepted a bad layout"
  assert_not_contains "$FAKE_HERDR_LOG" "close"
  [ -d "$HIVE_DIR/drones/kafka" ] || fail "the refused move moved the drone"
}

t_spawn_falls_back_to_a_workspace_of_its_own() {
  FAKE_TAB_CREATE_FAIL=1 spawn_home kafka > "$T/out" 2>&1 || fail "spawn failed: $(cat "$T/out")"
  assert_contains "$T/out" "kafka gets a workspace of its own"
  assert_contains "$FAKE_HERDR_LOG" "workspace create --label kafka"
  [ "$(drone_meta_field kafka workspace_id)" = "w9" ] || fail "meta workspace_id: $(drone_meta_field kafka workspace_id)"
  # A coordinator whose pane is gone, or one on another machine, has no workspace to share.
  rm -f "$HIVE_DIR/coord.pane"; echo "w4:p1" > "$HIVE_DIR/coord.pane"
  : > "$FAKE_HERDR_LOG"
  FAKE_NO_CURRENT_PANE=1 FAKE_DEAD_PANES="w4:p1" spawn_home ghostly > /dev/null 2>&1 || fail "spawn with a dead coordinator failed"
  assert_contains "$FAKE_HERDR_LOG" "workspace create --label ghostly"
  echo "coordhost" > "$HIVE_DIR/coord.remote"
  : > "$FAKE_HERDR_LOG"
  FAKE_NO_CURRENT_PANE=1 spawn_home faraway > /dev/null 2>&1 || fail "spawn with a remote coordinator failed"
  assert_contains "$FAKE_HERDR_LOG" "workspace create --label faraway"
}

t_move_a_tab_drone_closes_its_source_tab() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  front_add wms
  echo "w3:p1" > "$HIVE_DIR/fronts/wms/coord.pane"
  : > "$FAKE_HERDR_LOG"
  HOME="$T/home" "$HIVE" move kafka wms > "$T/out" 2>&1 || fail "move failed: $(cat "$T/out")"
  assert_contains "$FAKE_HERDR_LOG" "tab close w1:t9"
  assert_contains "$FAKE_HERDR_LOG" "tab create --workspace w3 --label kafka"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace close"
}

t_a_drone_whose_pane_is_gone_closes_nothing() {
  spawn_home kafka > /dev/null 2>&1 || fail "spawn failed"
  fake_drone default old w7:p1
  : > "$FAKE_HERDR_LOG"
  # Its tab, or its old workspace, may hold somebody else's pane by now.
  FAKE_DEAD_PANES="w1:p9 w7:p1" "$HIVE" kill kafka > "$T/out" 2>&1 || fail "kill failed"
  FAKE_DEAD_PANES="w1:p9 w7:p1" "$HIVE" kill old > /dev/null 2>&1
  assert_not_contains "$FAKE_HERDR_LOG" "close"
}

t_rename_leaves_a_workspace_the_drone_does_not_own() {
  fake_drone default old w7:p1
  echo "w7:p2" > "$HIVE_DIR/coord.pane"           # the coordinator moved into the old drone's workspace
  "$HIVE" rename old older > /dev/null 2>&1 || fail "rename failed"
  assert_not_contains "$FAKE_HERDR_LOG" "workspace rename"
  assert_contains "$FAKE_HERDR_LOG" "agent rename w7:p1 older"
  HIVE_DRONE_LAYOUT="tab workspace" spawn_home odd > "$T/bad" 2>&1 && fail "a layout with a space was accepted"
  assert_contains "$T/bad" "tab or workspace"
}

# --- main --------------------------------------------------------------------

ORIG_PATH="$PATH"
if [ $# -gt 0 ]; then tests=("$@"); else
  mapfile -t tests < <(declare -F | awk '{print $3}' | grep '^t_')
fi
for t in "${tests[@]}"; do run "$t"; done
exit "$FAILED"
