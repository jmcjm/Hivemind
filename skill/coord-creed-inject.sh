#!/usr/bin/env bash
# coord-creed-inject.sh — SessionStart hook for the COORDINATOR session.
#
# Compaction replaces the transcript with a summary written by a model that was never told which
# rules were load-bearing, so the coordinator drops back to default behaviour: work done inline,
# mail triage lost, waiting drones forgotten. This hook prints the creed back into the fresh
# context, together with the board read from disk at that moment.
#
# Compaction loses two different things and both are restored here:
#   the RULES  — coord-creed.md, verbatim, the single source of truth
#   the STATE  — who is in flight, who is waiting, how much mail is unread. Read from $HIVE_DIR
#                right now, so it is the one part of the injection that cannot be stale.
#
# Registered for sources compact|resume|clear|fork — deliberately NOT startup: nothing is
# registered as coordinator that early, and injecting into every fresh session on the machine
# would leak swarm text into unrelated work. On startup the CLAUDE.md section does this job.
#
# Scoping: fires ONLY in the registered coordinator session (see coord-scope.sh). Drones,
# subagents and unrelated sessions print nothing at all.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=coord-scope.sh
. "$SKILL_DIR/coord-scope.sh" 2>/dev/null || exit 0

HIVE_DIR="${HIVE_DIR:-$HOME/.herdr-hive}"
CREED="$SKILL_DIR/coord-creed.md"
[ -f "$CREED" ] || exit 0

payload=$(cat 2>/dev/null || true)
fields=$(hive_hook_field "$payload" session_id source agent_type)
# one value per line, read positionally: an absent session_id must not shift the rest
sid=$(sed -n 1p <<<"$fields")
source=$(sed -n 2p <<<"$fields")
agent_type=$(sed -n 3p <<<"$fields")
[ -n "${agent_type:-}" ] && exit 0                 # a subagent is not the coordinator
case "${source:-}" in
  compact|resume|clear|fork) ;;                    # belt and braces: the matcher already filters
  *) exit 0 ;;
esac
hive_is_coordinator_session "${sid:-}" || exit 0

# --- the board ------------------------------------------------------------
# One python pass over the swarm directory: spawning a process per drone would be slow on a hive
# that has collected hundreds of them. herdr is asked only about the drones with a task in flight.
board=$(python3 - "$HIVE_DIR" <<'PY'
import json, os, sys, time
hive = sys.argv[1]
drones = os.path.join(hive, "drones")
now = time.time()
rows, total, reported, concluded = [], 0, 0, 0
try:
    names = sorted(os.listdir(drones))
except OSError:
    names = []
for name in names:
    d = os.path.join(drones, name)
    if not os.path.isdir(d):
        continue
    total += 1
    has_report = os.path.exists(os.path.join(d, "report.md"))
    brief = os.path.join(d, "brief.md")
    if os.path.exists(os.path.join(d, ".killed")):
        concluded += 1
    if has_report:
        reported += 1
        continue
    if not os.path.exists(brief):
        continue
    pane = ""
    try:
        with open(os.path.join(d, "meta.json")) as f:
            pane = json.load(f).get("pane_id") or ""
    except Exception:
        pass
    age = int((now - os.path.getmtime(brief)) // 60)
    rows.append(f"{name}\t{pane}\t{age}")
print(f"TOTALS\t{total}\t{reported}\t{concluded}")
for r in rows:
    print(r)
PY
) || board=""

letters=$(find "$HIVE_DIR/mail/coord" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
totals=$(printf '%s\n' "$board" | awk -F'\t' '$1=="TOTALS"{print $2" "$3" "$4}')
read -r n_total n_reported n_concluded <<<"${totals:-0 0 0}"

# In-flight drones: a brief, no report. These are the ones whose state the coordinator must know
# before speaking to anybody. Capped, because the injected block has a hard size limit.
inflight=$(printf '%s\n' "$board" | awk -F'\t' '$1!="TOTALS" && NF==3')
n_inflight=$(printf '%s' "$inflight" | grep -c . || true)
lines=""
shown=0
if [ "${n_inflight:-0}" -gt 0 ]; then
  while IFS=$'\t' read -r name pane age; do
    [ -n "$name" ] || continue
    shown=$((shown + 1))
    if [ "$shown" -gt 12 ]; then break; fi
    st="?"
    if [ -n "$pane" ] && command -v herdr >/dev/null 2>&1; then
      st=$(herdr pane get "$pane" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('dead'); raise SystemExit
p=d.get('result',d).get('pane') or {}
print(p.get('agent_status') or 'unknown')" 2>/dev/null)
      [ -n "$st" ] || st=dead
    fi
    case "$st" in
      blocked) note="  <- ANSWER THIS ONE FIRST" ;;
      dead)    note="  <- died with the task unfinished: hive revive $name" ;;
      idle)    note="  <- turn ended without a report" ;;
      *)       note="" ;;
    esac
    lines="$lines$(printf '  %-16s %-8s brief %s min old%s\n' "$name" "$st" "$age" "$note")"$'\n'
  done <<<"$inflight"
fi

# --- the injection --------------------------------------------------------
echo "=== HIVE: coordinator discipline restored (SessionStart: ${source}) ==="
echo
echo "The context you are reading was rebuilt. The rules below did not survive it on their own —"
echo "they are re-stated here because they are the operating discipline of this session, and the"
echo "board under them was read from $HIVE_DIR just now, so it is fact rather than recollection."
echo
cat "$CREED"
echo
echo "--- Board ($(date '+%Y-%m-%d %H:%M')) ---"
if [ "${letters:-0}" -gt 0 ]; then
  echo "Unread coordinator mail: $letters letter(s) — run 'hive inbox' before answering the user."
else
  echo "Unread coordinator mail: none."
fi
# A live heartbeat is information, not permission: it proves some watcher runs, not that this
# rebuilt session still has its monitor.
arm='Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)'
if "$SKILL_DIR/hive" _watched 2>/dev/null; then
  echo "Mail watcher: a watcher is live — if this session has no hive watch monitor, arm one: $arm."
else
  echo "Mail watcher: NOT ARMED — you hear no drone until you arm it: $arm."
fi
if [ "${n_inflight:-0}" -gt 0 ]; then
  echo "Drones with a task in flight (brief, no report): $n_inflight"
  printf '%s' "$lines"
  [ "$n_inflight" -gt 12 ] && echo "  ... $((n_inflight - 12)) more — see: hive status"
else
  echo "Drones with a task in flight: none."
fi
echo "Swarm directory: $n_total drone(s), $n_reported with a report, $n_concluded concluded."
[ "${n_total:-0}" -gt 20 ] && echo "That is a crowded graveyard — 'hive prune --dry-run' shows what can go."
echo "Live pane states for every drone: hive status"
exit 0
