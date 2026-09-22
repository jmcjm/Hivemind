#!/usr/bin/env bash
# coord-mail-check.sh — Stop hook for the COORDINATOR session (installed into the user's
# global Claude Code settings by install.sh).
#
# Blocks ending a turn while unread swarm mail sits in the coordinator's mailbox, so the
# coordinator answers waiting drones before going silent. The mail watcher's notifications
# (`hive watch` in a Monitor) cover the happy path; this is the level-triggered backstop for
# every way they get missed: an expired or unarmed watcher, a coordinator busy with a long
# inline task, mail read without `hive inbox`.
#
# Scoping: fires ONLY in the session whose pane is registered in coord.pane (herdr's
# claude integration reports the session id per pane). Drones ($HIVE_DRONE) and unrelated
# Claude Code sessions exit instantly, so the hook is safe to install globally.
set -uo pipefail

[ -n "${HIVE_DRONE:-}" ] && exit 0                  # drones have their own protocol
HIVE_DIR="${HIVE_DIR:-$HOME/.herdr-hive}"
box="$HIVE_DIR/mail/coord"
ls "$box"/*.json >/dev/null 2>&1 || exit 0          # no unread mail — nothing to say
pane=$(cat "$HIVE_DIR/coord.pane" 2>/dev/null); [ -n "$pane" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
read -r sid loop <<<"$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1] or '{}')
except Exception: d={}
print(d.get('session_id') or '-', 1 if d.get('stop_hook_active') else 0)
" "$payload" 2>/dev/null)" || true
# One nag per stop attempt, never a block loop: if we already blocked this stop and the
# model still could not empty the mailbox, forcing it around again will not help.
[ "${loop:-0}" = 1 ] && exit 0
[ -n "${sid:-}" ] && [ "$sid" != - ] || exit 0

pane_sid=$(herdr pane get "$pane" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
p=d.get('result',d).get('pane') or {}
print(((p.get('agent_session') or {}).get('value')) or '')" 2>/dev/null)
[ "$sid" = "$pane_sid" ] || exit 0                  # not the registered coordinator

n=$(ls "$box"/*.json 2>/dev/null | wc -l | tr -d ' ')
python3 - "$n" <<'PY'
import json, sys
n = sys.argv[1]
print(json.dumps({"decision": "block", "reason": (
    f"HIVE-MAIL backstop: {n} unread letter(s) in the coordinator mailbox. "
    "Run `hive inbox` now, answer every drone that waits on you (blocked ones first), "
    "then report the synthesis to the user before ending the turn.")}))
PY
exit 0
