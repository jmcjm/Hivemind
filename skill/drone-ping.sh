#!/usr/bin/env bash
# drone-ping.sh — hook for swarm drones. Reports end of work or a needed decision to the coordinator.
# Called from drone-settings.json (Stop / Notification). Argument: done|decision
#
# Safeguards:
#  - runs ONLY when $HIVE_DRONE is set (spawn injects it) -> the coordinator session never fires it
#  - all the heavy lifting (mailbox, locks, empty prompt) lives in `hive send` — this only reports
set -uo pipefail

[ -n "${HIVE_DRONE:-}" ] || exit 0          # not a drone -> silence

KIND_ARG="${1:-done}"
HIVE_DIR="${HIVE_DIR:-$HOME/.herdr-hive}"
HIVE_BIN="$HOME/.claude/skills/hivemind/hive"
[ -x "$HIVE_BIN" ] || exit 0

# A conversational drone (a human sits in its panel) ends a turn after EVERY utterance,
# so automatic wake-ups are pure noise for the coordinator. The marker silences them;
# an explicit 'hive send coord' from inside the drone still works.
[ -f "$HIVE_DIR/drones/$HIVE_DRONE/.mute" ] && exit 0

payload=$(cat 2>/dev/null || true)          # hook JSON on stdin (Notification carries .message)

# Status from the drone's report, if it managed to write one
report="$HIVE_DIR/drones/$HIVE_DRONE/report.md"
status="no report"
[ -f "$report" ] && status=$(grep -m1 -oE 'DONE|BLOCKED|FAILED' "$report" 2>/dev/null || echo "written")

note=$(python3 -c "
import json,sys
try: print((json.loads(sys.argv[1] or '{}') or {}).get('message','') or '')
except Exception: print('')
" "$payload" 2>/dev/null)

if [ "$KIND_ARG" = decision ]; then
  # Claude Code fires Notification for real dialogs (permission requests) AND for plain
  # idleness ("Claude is waiting for your input", after ~60s at an empty prompt). The idle
  # one is pure noise here: the Stop hook already reported the end of the turn, so forwarding
  # it again as "needs a decision" cries wolf at the coordinator after every task. Suppress
  # exactly that known message; anything else (unknown or permission-shaped) still goes
  # through — fail-open, a real dialog must never be silenced.
  case "$note" in
    *"waiting for your input"*) exit 0 ;;
  esac
  subject="needs a decision"
  herdr notification show "Drone $HIVE_DRONE awaits a decision" --sound request >/dev/null 2>&1
else
  subject="finished a turn (report: $status)"
  herdr notification show "Drone $HIVE_DRONE finished ($status)" --sound done >/dev/null 2>&1
fi

body="${note:-}"
[ -f "$report" ] && body="${body}${body:+
}report: $report"

KIND="$KIND_ARG" HIVE_DRONE="$HIVE_DRONE" HIVE_DIR="$HIVE_DIR" \
  "$HIVE_BIN" send coord "$subject" --body "$body" >/dev/null 2>&1

exit 0
