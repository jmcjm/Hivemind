#!/usr/bin/env bash
# tests/ctx/test-ctx.sh [skill-dir] — what keeps the coordinator's context small:
# the watcher's quiet filter and burst coalescing, the sweep's per-state deduplication and its
# background-shell check, 'Rules:' expansion and the refusal without boundaries, coord-start,
# the Stop backstop counting only loud mail, the context guard and coord-settings.json.
# Nothing real runs: herdr and notify-send are the stand-ins in fake-bin/, HOME and HIVE_DIR are
# throwaway directories. The scripts under test (default: the repo's skill/) are COPIED into a
# throwaway skill directory, so every script finds its siblings (hive) next to itself.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="$(readlink -f "${1:-$HERE/../../skill}")"
T="$(mktemp -d)"; ERRF="$(mktemp)"
BG_PIDS=()
cleanup() {
  local p
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$T" "$ERRF"
}
trap cleanup EXIT

SK="$T/skill"; mkdir -p "$SK"
for f in hive coord-mail-check.sh coord-context-guard.sh coord-settings.json coord-scope.sh; do
  cp "$SRC/$f" "$SK/$f" || { echo "missing: $SRC/$f" >&2; exit 2; }
done
chmod +x "$SK"/hive "$SK"/*.sh 2>/dev/null
HIVE="$SK/hive"
echo "testing: $SRC"

export TZ=UTC
export HOME="$T/home" HIVE_DIR="$T/hive" FAKE_PANES="$T/panes" FAKE_HERDR_LOG="$T/herdr.log" FAKE_NOTIFY_LOG="$T/notify.log"
export HIVE_RULES_DIR="$T/rules" HIVE_COORD_DIR="$T/coord"
export PATH="$HERE/fake-bin:$PATH"
unset HIVE_DRONE HIVE_FRONT HERDR_PANE_ID HERDR_HIVE_ROLE HIVE_COORD_PANE HIVE_ACCOUNT CLAUDE_CONFIG_DIR FAKE_CURRENT_PANE HIVE_WATCH_ALL KIND
mkdir -p "$HOME" "$HIVE_DIR" "$FAKE_PANES" "$HIVE_RULES_DIR"
echo '{}' > "$HOME/.claude.json"

# --- assertions -------------------------------------------------------------
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing:  $2" "in:       $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "unwanted: $2" "in:       $3" ;; *) ok "$1" ;; esac; }
section() { printf '\n%s\n' "$1"; }
run() { OUT=$("$@" 2>"$ERRF"); RC=$?; ERR=$(cat "$ERRF"); }

# send_as <from> <kind> <subject> — a letter to coord, the way drone-ping.sh and drones send it
send_as() { HIVE_DRONE="$1" KIND="$2" "$HIVE" send coord "$3" --body "body of $3" >/dev/null 2>&1; }
coord_letters() { find "$HIVE_DIR/mail/coord" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
coord_subjects() {
  local f
  for f in "$HIVE_DIR"/mail/coord/*.json; do
    [ -e "$f" ] && python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['subject'])" "$f"
  done
}
clear_coord() { rm -f "$HIVE_DIR"/mail/coord/*.json; }
NOREP="finished a turn (report: no report)"

# =============================================================================
section "classification: which letters wake the coordinator"
send_as a done "$NOREP"
send_as b done "finished a turn (report: DONE)"
send_as c done "finished a turn (report: BLOCKED)"
send_as d decision "needs a decision"
send_as e msg "question about the schema"
HIVE_DRONE=sweep KIND=sweep "$HIVE" send coord "SWEEP: drone x sits idle without a report" --body x >/dev/null 2>&1
run "$HIVE" _loud
eq "five of six letters are loud (the no-report turn is quiet)" 5 "$OUT"
eq "the quiet letter is still delivered to the mailbox" 6 "$(coord_letters)"
run env HIVE_WATCH_ALL=1 "$HIVE" _loud
eq "HIVE_WATCH_ALL=1 makes every letter loud" 6 "$OUT"
run "$HIVE" inbox --keep
has "hive inbox lists the quiet letter too" "$NOREP" "$OUT"
send_as m msg "$NOREP"
run "$HIVE" _loud
eq "the no-report subject is quiet only on a finished turn (kind done), not in a message" 6 "$OUT"
printf '{"from":"x","subj' > "$HIVE_DIR/mail/coord/1-cut.json"
echo '[]' > "$HIVE_DIR/mail/coord/2-list.json"
run "$HIVE" _loud
eq "a letter that cannot be read is loud, not skipped" 8 "$OUT"
run "$HIVE" inbox --keep
has "hive inbox names an unreadable letter instead of skipping it" "unreadable letter: 1-cut.json" "$OUT"
has "a letter that is valid JSON but no letter is named too" "unreadable letter: 2-list.json" "$OUT"
has "with --keep, at its place in the mailbox" "$HIVE_DIR/mail/coord/1-cut.json" "$OUT"
run "$HIVE" inbox
has "without --keep, at its place in the archive" "$HIVE_DIR/mail/.archive/1-cut.json" "$OUT"
clear_coord

# =============================================================================
section "watch: quiet letters wake nobody, a burst is one line, the reminder counts loud mail only"
send_as old-quiet done "$NOREP"
send_as old-loud msg "left from before the watcher"
export HIVE_WATCH_COALESCE=2 HIVE_MAIL_REMIND=1
"$HIVE" watch > "$T/watch.out" 2>&1 &
WPID=$!; BG_PIDS+=("$WPID")
sleep 1.5
send_as q1 done "$NOREP"
send_as l1 msg "first of a burst"
send_as l2 done "finished a turn (report: DONE)"
send_as l3 decision "needs a decision"
sleep 5
send_as solo msg "alone"
sleep 7
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
unset HIVE_WATCH_COALESCE HIVE_MAIL_REMIND
W=$(cat "$T/watch.out")
has "backlog counts the loud letter and names the quiet one" "HIVE-MAIL backlog: 1 unread (+1 quiet)" "$W"
hasnt "a turn ended without a report prints nothing" "q1 [finished]" "$W"
has "three letters within the coalescing window are one line" "HIVE-MAIL 3 letters: l1 [message] first of a burst | l2 [finished]" "$W"
eq "the burst produced exactly one notification" 1 "$(grep -c '^HIVE-MAIL 3 letters' "$T/watch.out")"
has "a lone letter keeps the classic line" "HIVE-MAIL solo [message] alone" "$W"
has "the reminder counts the five loud letters, not the two quiet ones" "HIVE-MAIL reminder: 5 unread" "$W"
eq "nothing but backlog, burst, solo and reminders was printed" 0 "$(grep -vcE '^HIVE-MAIL (backlog|3 letters|solo|reminder)' "$T/watch.out")"
clear_coord

# =============================================================================
section "the human is not pinged about quiet mail nobody listens to"
rm -f "$HIVE_DIR/.watch-coord" "$HIVE_DIR/.watch-coord.last" "$HIVE_DIR/.stranded-notice"
echo "wC:p1" > "$HIVE_DIR/coord.pane"; touch -d '1 hour ago' "$HIVE_DIR/coord.pane"
export HIVE_UNWATCHED_GRACE=0
: > "$FAKE_NOTIFY_LOG"
send_as a done "$NOREP"
eq "a quiet letter to an unwatched coordinator raises no alert" 0 "$(wc -l < "$FAKE_NOTIFY_LOG" | tr -d ' ')"
send_as b msg "a real question"
has "a loud one does" "no coordinator is listening" "$(cat "$FAKE_NOTIFY_LOG")"
has "the alert counts loud letters only" "1 letter(s) waiting" "$(cat "$FAKE_NOTIFY_LOG")"
unset HIVE_UNWATCHED_GRACE
clear_coord; rm -f "$HIVE_DIR/.stranded-notice"

# =============================================================================
section "sweep: one alert per drone and state"
mkdrone() {  # mkdrone <name> <pane> <status> <sid>
  mkdir -p "$HIVE_DIR/drones/$1"
  printf '{"name":"%s","workspace_id":"w","pane_id":"%s","session_id":"%s","cwd":"/tmp","account":""}\n' "$1" "$2" "$4" \
    > "$HIVE_DIR/drones/$1/meta.json"
  echo "# brief" > "$HIVE_DIR/drones/$1/brief.md"
  echo "$3" > "$FAKE_PANES/$2.status"
}
sweep_count() { coord_subjects | grep -c "SWEEP: drone $1 " || true; }
touch "$HIVE_DIR/.watch-coord"     # a live watcher: the sweep's mail section stays quiet
SID1="test-sid-$$-d1"
mkdrone d1 wD:p1 idle "$SID1"
"$HIVE" sweep >/dev/null 2>&1
eq "an idle drone without a report is reported" 1 "$(sweep_count d1)"
"$HIVE" sweep >/dev/null 2>&1; "$HIVE" sweep >/dev/null 2>&1
eq "the same state is not reported again on later passes" 1 "$(sweep_count d1)"
echo done > "$FAKE_PANES/wD:p1.status"
"$HIVE" sweep >/dev/null 2>&1
eq "idle and done are one state" 1 "$(sweep_count d1)"
echo working > "$FAKE_PANES/wD:p1.status"
"$HIVE" sweep >/dev/null 2>&1
eq "working (under the hour) raises nothing" 1 "$(sweep_count d1)"
echo idle > "$FAKE_PANES/wD:p1.status"
"$HIVE" sweep >/dev/null 2>&1
eq "back to idle after working: a new stall, reported again" 2 "$(sweep_count d1)"
touch -d '2 hours ago' "$HIVE_DIR/drones/d1/.sweep-idle"
"$HIVE" sweep >/dev/null 2>&1
eq "after HIVE_SWEEP_RENOTIFY (60 min) the same state is reported again" 3 "$(sweep_count d1)"
touch -d '40 minutes ago' "$HIVE_DIR/drones/d1/.sweep-idle"
"$HIVE" sweep >/dev/null 2>&1
eq "40 minutes is not enough for a re-alert (the old limit was 30)" 3 "$(sweep_count d1)"
clear_coord
rm -f "$HIVE_DIR/drones/d1/.sweep-idle"; chmod a-w "$HIVE_DIR/mail/coord"
run "$HIVE" sweep
chmod u+w "$HIVE_DIR/mail/coord"
has "an alert that cannot reach the mailbox is logged as not delivered" "sweep: NOT delivered" "$OUT"
eq "and keeps no marker" no "$([ -e "$HIVE_DIR/drones/d1/.sweep-idle" ] && echo yes || echo no)"
"$HIVE" sweep >/dev/null 2>&1
eq "so the next pass delivers it, not one an hour later" 1 "$(sweep_count d1)"
clear_coord

# =============================================================================
section "sweep: a drone waiting on its own background shells is not stalled"
SID2="test-sid-$$-d2"
mkdrone d2 wD:p2 idle "$SID2"
# A stand-in for the drone's Claude Code: argv[0] 'claude', the session id on its command line, one
# child that looks like a Bash tool shell (its command line names a shell snapshot).
( exec -a claude bash -c 'bash -c "sleep 60; :" /x/shell-snapshots/snapshot-zsh-test & wait' _ --session-id "$SID2" ) &
CPID=$!; BG_PIDS+=("$CPID")
sleep 0.5
run "$HIVE" sweep
eq "an idle drone with a background shell is not reported" 0 "$(sweep_count d2)"
has "the sweep says why in its log" "d2 waits on 1 background shell(s)" "$OUT"
"$HIVE" sweep >/dev/null 2>&1
eq "still waiting: still nothing" 0 "$(sweep_count d2)"
# Processes come and go while the sweep reads /proc (drones build and test): a process gone between
# the listing and the read of its cmdline must not crash the scan into "nothing runs".
( while :; do /bin/true; done ) &
CHURN=$!; BG_PIDS+=("$CHURN")
touch -d '10 minutes ago' "$HIVE_DIR/drones/d2/.sweep-bgwait"
BGM=$(stat -c %Y "$HIVE_DIR/drones/d2/.sweep-bgwait")
for i in 1 2 3 4 5 6 7 8 9 10; do "$HIVE" sweep >/dev/null 2>&1; done
kill "$CHURN" 2>/dev/null; wait "$CHURN" 2>/dev/null
eq "process churn during the scan raises no false stall (10 passes)" 0 "$(sweep_count d2)"
eq "and does not restart the bgwait clock" "$BGM" "$(stat -c %Y "$HIVE_DIR/drones/d2/.sweep-bgwait" 2>/dev/null)"
# A scan that fails outright: a python3 that dies on the /proc scan and runs everything else.
REALPY=$(command -v python3); mkdir -p "$T/badpy"
cat > "$T/badpy/python3" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = - ]; then
  s=\$(cat); case "\$s" in *shell-snapshots*) exit 1 ;; esac
  printf '%s\n' "\$s" | exec "$REALPY" "\$@"
fi
exec "$REALPY" "\$@"
EOF
chmod +x "$T/badpy/python3"
run env PATH="$T/badpy:$PATH" "$HIVE" sweep
has "a failed /proc scan is logged as unknown" "d2 background shells unknown" "$OUT"
eq "and raises nothing" 0 "$(sweep_count d2)"
eq "and leaves the bgwait marker as it was" "$BGM" "$(stat -c %Y "$HIVE_DIR/drones/d2/.sweep-bgwait" 2>/dev/null)"
noscan() { coord_subjects | grep -c 'SWEEP: cannot scan /proc for drone d2' || true; }
for i in 2 3 4 5; do env PATH="$T/badpy:$PATH" "$HIVE" sweep >/dev/null 2>&1; done
eq "five failed scans in a row: still nothing" 0 "$(noscan)"
env PATH="$T/badpy:$PATH" "$HIVE" sweep >/dev/null 2>&1
eq "the sixth (HIVE_SWEEP_NOSCAN) tells the coordinator the scan keeps failing" 1 "$(noscan)"
env PATH="$T/badpy:$PATH" "$HIVE" sweep >/dev/null 2>&1
eq "once" 1 "$(noscan)"
eq "still without a stall alert or a restarted bgwait clock" "0 $BGM" "$(sweep_count d2) $(stat -c %Y "$HIVE_DIR/drones/d2/.sweep-bgwait" 2>/dev/null)"
"$HIVE" sweep >/dev/null 2>&1
eq "a scan that works again clears the count" no "$([ -e "$HIVE_DIR/drones/d2/.sweep-bgunknown" ] && echo yes || echo no)"
touch -d '3 hours ago' "$HIVE_DIR/drones/d2/.sweep-bgwait"
"$HIVE" sweep >/dev/null 2>&1
has "a wait longer than HIVE_SWEEP_BGWAIT (2 h) is reported" "SWEEP: drone d2 idle" "$(coord_subjects)"
"$HIVE" sweep >/dev/null 2>&1
eq "and only once" 1 "$(sweep_count d2)"
for c in $(pgrep -P "$CPID"); do pkill -P "$c" 2>/dev/null; kill "$c" 2>/dev/null; done   # by PID only
kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
sleep 0.3
"$HIVE" sweep >/dev/null 2>&1
has "background work gone, turn ended, no report: now it is a stall" "SWEEP: drone d2 sits idle without a report" "$(coord_subjects)"
rm -rf "$HIVE_DIR/drones/d1" "$HIVE_DIR/drones/d2"
clear_coord

# =============================================================================
section "sweep: the overdue reminder re-nags on the one HIVE_SWEEP_RENOTIFY default (60 min)"
echo "wC:p1" > "$HIVE_DIR/coord.pane"; echo idle > "$FAKE_PANES/wC:p1.status"
send_as o msg "an old question"; touch -d '45 minutes ago' "$HIVE_DIR"/mail/coord/*.json
touch -d '40 minutes ago' "$HIVE_DIR/.overdue-notice"; : > "$FAKE_NOTIFY_LOG"
touch "$HIVE_DIR/.watch-coord"; "$HIVE" sweep >/dev/null 2>&1
eq "40 minutes after the last reminder: none (the overdue path used to say 30)" 0 "$(grep -c 'Swarm mail unread' "$FAKE_NOTIFY_LOG")"
touch -d '61 minutes ago' "$HIVE_DIR/.overdue-notice"
touch "$HIVE_DIR/.watch-coord"; "$HIVE" sweep >/dev/null 2>&1
eq "after 60 minutes: reminded again" 1 "$(grep -c 'Swarm mail unread' "$FAKE_NOTIFY_LOG")"
clear_coord; rm -f "$HIVE_DIR/.overdue-notice"

# =============================================================================
section "task: 'Rules:' pulls the boundary blocks from files"
printf -- '- COMMON-1\n- COMMON-2\n' > "$HIVE_RULES_DIR/common.md"
printf -- '- REPO-1\n' > "$HIVE_RULES_DIR/repo.md"
printf -- '- REVIEW-1\n' > "$HIVE_RULES_DIR/review.md"
mkdrone t1 wT:p1 working "test-sid-$$-t1"
brief() { printf '%s\n' "$@" > "$T/brief.md"; }
B="$HIVE_DIR/drones/t1/brief.md"

brief "# Task" "" "Do the thing." "" "Rules: repo review" "" "## Next"
run "$HIVE" task t1 "$T/brief.md"
eq "a brief with 'Rules:' is accepted" 0 "$RC"
has "the task names the blocks it used" "common.md repo.md review.md" "$OUT"
G=$(cat "$B")
has "the common block comes first, then the named ones in order" $'## Boundaries (absolute)\n\n- COMMON-1\n- COMMON-2\n\n- REPO-1\n\n- REVIEW-1' "$G"
hasnt "the directive line is gone" "Rules: repo review" "$G"
has "the rest of the brief stays" $'Do the thing.' "$G"
has "the reporting protocol is still appended" "## Reporting protocol (mandatory)" "$G"

brief "# Task" "Rules: repo" "" "## Boundaries" "- TASK-SPECIFIC" "" "## Next"
run "$HIVE" task t1 "$T/brief.md"
G=$(cat "$B")
eq "a brief with its own boundaries heading gets no second one" 1 "$(grep -c '^## Boundaries' "$B")"
has "the blocks go to the top of that section, before the task's own lines" $'## Boundaries\n\n- COMMON-1\n- COMMON-2\n\n- REPO-1\n\n- TASK-SPECIFIC' "$G"

brief "# Task" "" "## Boundaries (absolute)" "- written by hand"
run "$HIVE" task t1 "$T/brief.md"
eq "a brief with a hand-written boundaries section is accepted as it is" 0 "$RC"
has "and left alone" $'## Boundaries (absolute)\n- written by hand' "$(cat "$B")"

brief "# Task" "Do the thing."
run "$HIVE" task t1 "$T/brief.md"
eq "a brief with no boundaries at all is refused" 1 "$RC"
has "the refusal says what to add" "brief has no boundaries" "$ERR"
has "and lists the blocks there are" "common repo review" "$ERR"
has "a refused brief leaves the drone's current brief as it was" "written by hand" "$(cat "$B" 2>/dev/null)"
hasnt "and is not installed" "Do the thing." "$(cat "$B" 2>/dev/null)"
eq "and leaves no staging file behind" no "$([ -e "$HIVE_DIR/drones/t1/.brief.staged" ] && echo yes || echo no)"

brief "# Task" '```' "Rules: repo" '```'
run "$HIVE" task t1 "$T/brief.md"
eq "a 'Rules:' line inside a code fence is text, not a directive" 1 "$RC"

brief "# Task" "Rules: repo nosuch"
run "$HIVE" task t1 "$T/brief.md"
eq "an unknown block is refused" 1 "$RC"
has "naming the missing one" "no boundary block for: nosuch" "$ERR"
has "and the drone's current brief stays" "written by hand" "$(cat "$B" 2>/dev/null)"

run "$HIVE" task t1 "$T/no-such-brief.md"
eq "a brief file that cannot be read is refused" 1 "$RC"
has "and the drone's current brief stays too" "written by hand" "$(cat "$B" 2>/dev/null)"

brief "# Task" "Do the thing."
run env HIVE_NO_RULES=1 "$HIVE" task t1 "$T/brief.md"
eq "HIVE_NO_RULES=1 lets a brief without boundaries through" 0 "$RC"

brief "# Task" "Rules: repo" "" "Do the thing." "" "Rules: review"
run "$HIVE" task t1 "$T/brief.md"
G=$(cat "$B")
eq "two directive lines are one: accepted" 0 "$RC"
has "with the blocks of both, in order" $'- REPO-1\n\n- REVIEW-1' "$G"
hasnt "and the second line does not stay behind" "Rules: review" "$G"
eq "under one heading" 1 "$(grep -c '^## Boundaries' "$B")"

brief "# Task" "### Rules of the game" "- be nice"
run "$HIVE" task t1 "$T/brief.md"
eq "a heading that only starts with 'Rules' is no boundaries section" 1 "$RC"

brief "# Task" "~~~" "Rules: repo" "~~~"
run "$HIVE" task t1 "$T/brief.md"
eq "a 'Rules:' line inside a ~~~ fence is text" 1 "$RC"

brief "# Task" "Example:" "" "    Rules: nosuch" "" "Rules: repo"
run "$HIVE" task t1 "$T/brief.md"
eq "an indented code line is not a directive" 0 "$RC"

brief "# Task" 'Rules: `repo`, `review`'
run "$HIVE" task t1 "$T/brief.md"
eq "block names in backticks work" 0 "$RC"

printf '\xef\xbb\xbfRules: repo\nDo the thing.\n' > "$T/brief.md"
run "$HIVE" task t1 "$T/brief.md"
eq "a brief starting with a BOM works" 0 "$RC"

brief "# Task" "**Rules:** review"
run "$HIVE" task t1 "$T/brief.md"
eq "a bold 'Rules:' line is a directive too" 0 "$RC"
has "with the common block and the named one only" $'## Boundaries (absolute)\n\n- COMMON-1\n- COMMON-2\n\n- REVIEW-1' "$(cat "$B")"

rm -f "$HIVE_RULES_DIR/common.md"
brief "# Task" "Rules: review"
run "$HIVE" task t1 "$T/brief.md"
eq "without common.md the named blocks still work" 0 "$RC"
has "on their own" $'## Boundaries (absolute)\n\n- REVIEW-1' "$(cat "$B")"
brief "# Task" "Rules:"
run "$HIVE" task t1 "$T/brief.md"
eq "a 'Rules:' line naming nothing, without common.md, is refused" 1 "$RC"
has "saying so" "has no common.md" "$ERR"
rm -rf "$HIVE_DIR/drones/t1"

# =============================================================================
section "coord-start"
run "$HIVE" coord-start --dry-run
eq "outside a herdr pane it refuses" 1 "$RC"
has "saying where to run it" "run it in the herdr pane" "$ERR"
export FAKE_CURRENT_PANE="wK:p1"
run "$HIVE" coord-start --dry-run -- --resume abc
eq "in a pane, --dry-run succeeds" 0 "$RC"
has "it runs in the coordinator directory" "$HIVE_COORD_DIR" "$OUT"
has "with coord-settings.json" "--settings $SK/coord-settings.json" "$OUT"
has "and passes claude's own flags through" "--resume abc" "$OUT"
eq "a dry run registers nothing" "" "$(cat "$HIVE_DIR/coord.pane" 2>/dev/null | grep -x wK:p1)"
run env HIVE_DRONE=x "$HIVE" coord-start --dry-run
eq "a drone cannot start a coordinator" 1 "$RC"
unset FAKE_CURRENT_PANE

# =============================================================================
section "Stop backstop: only loud mail holds the coordinator's turn"
echo "wC:p1" > "$HIVE_DIR/coord.pane"; echo idle > "$FAKE_PANES/wC:p1.status"; echo "coord-sid" > "$FAKE_PANES/wC:p1.sid"
send_as a done "$NOREP"
run bash -c "echo '{\"session_id\":\"coord-sid\"}' | bash '$SK/coord-mail-check.sh'"
eq "only quiet mail: the turn may end" "" "$OUT"
send_as b msg "a real question"
run bash -c "echo '{\"session_id\":\"coord-sid\"}' | bash '$SK/coord-mail-check.sh'"
has "loud mail: the turn is held" '"decision": "block"' "$OUT"
has "and the count is of loud letters" "1 unread letter(s)" "$OUT"
run bash -c "python3 -c 'import json; print(json.dumps({\"session_id\":\"coord-sid\",\"last_assistant_message\":\"x\"*200000}))' | bash '$SK/coord-mail-check.sh'"
has "a payload over 128 KB (a long last message) is still read" '"decision": "block"' "$OUT"
run bash -c "echo '{\"session_id\":\"other-sid\"}' | bash '$SK/coord-mail-check.sh'"
eq "another session is never held" "" "$OUT"
clear_coord

# =============================================================================
section "context guard"
TR="$T/transcript.jsonl"
usage_line() { printf '{"type":"assistant","isSidechain":%s,"message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$@"; }
guard() { printf '{"session_id":"s1","transcript_path":"%s","stop_hook_active":%s}' "$TR" "${1:-false}" \
          | HIVE_COORD_GUARD_NOTIFY=0 bash "$SK/coord-context-guard.sh"; }
{ usage_line false 2 300000 1000; usage_line true 2 900000 0; } > "$TR"
eq "under the threshold: nothing (a sidechain's size is not the coordinator's)" "" "$(guard)"
usage_line false 2 349000 2000 >> "$TR"
O=$(guard)
has "over the threshold (330k): the end of the turn is blocked" '"decision": "block"' "$O"
has "with the size in the reason" "Context ~351k" "$O"
eq "a second stop in the same epoch passes" "" "$(guard)"
eq "a stop the hook already held passes" "" "$(guard true)"
usage_line false 2 40000 1000 >> "$TR"
eq "after the compaction the context is small: nothing" "" "$(guard)"
usage_line false 2 360000 1000 >> "$TR"
has "the next epoch warns again" '"decision": "block"' "$(guard)"
usage_line false 2 360000 1000 >> "$TR"
has "the reason text can be set (HIVE_COORD_GUARD_MSG)" "Save to STATE.md, context ~361k" \
  "$(printf '{"session_id":"s2","transcript_path":"%s"}' "$TR" | HIVE_COORD_GUARD_NOTIFY=0 HIVE_COORD_GUARD_MSG='Save to STATE.md, context ~{k}k' bash "$SK/coord-context-guard.sh")"
has "the reason text names the session's front ({front})" "Save the state of front wms" \
  "$(printf '{"session_id":"s4","transcript_path":"%s"}' "$TR" | HIVE_FRONT=wms HIVE_COORD_GUARD_NOTIFY=0 HIVE_COORD_GUARD_MSG='Save the state of front {front}' bash "$SK/coord-context-guard.sh")"
has "a session without a front is the default front's" "Save the state of front default" \
  "$(printf '{"session_id":"s5","transcript_path":"%s"}' "$TR" | HIVE_COORD_GUARD_NOTIFY=0 HIVE_COORD_GUARD_MSG='Save the state of front {front}' bash "$SK/coord-context-guard.sh")"
eq "no temporary file is left behind" "" "$(ls -A "$HIVE_DIR" | grep '^\.context-guard\.' || true)"
run env HIVE_DRONE=x bash -c "printf '{\"session_id\":\"s3\",\"transcript_path\":\"$TR\"}' | bash '$SK/coord-context-guard.sh'"
eq "a drone is never guarded" "" "$OUT"
rm -f "$HIVE_DIR/.context-guard"
usage_line false 2 360000 1000 > "$TR"
has "a fresh epoch over the threshold warns" '"decision": "block"' "$(guard)"
printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TR"
eq "an API error (a synthetic message, usage 0) is no reading: the epoch goes on" "" "$(guard)"
usage_line false 2 361000 1000 >> "$TR"
eq "so the next turn over the threshold is not warned a second time" "" "$(guard)"
rm -f "$HIVE_DIR/.context-guard"
O=$(printf '{"session_id":"s9","transcript_path":"%s","last_assistant_message":"%s"}' "$TR" "$(printf 'x%.0s' $(seq 1 140000))" \
    | HIVE_COORD_GUARD_NOTIFY=0 bash "$SK/coord-context-guard.sh")
has "a payload over 128 KB (a long last message) still reaches the guard" '"decision": "block"' "$O"

# =============================================================================
section "coord-settings.json"
S=$(cat "$SK/coord-settings.json")
has "auto-compaction on" '"autoCompactEnabled": true' "$S"
has "the window is set in env (a shell's CLAUDE_CODE_AUTO_COMPACT_WINDOW would beat the key)" '"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"' "$S"
has "the guard is the Stop hook" "coord-context-guard.sh" "$S"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
