#!/usr/bin/env bash
# coord-scope.sh — shared scoping for the coordinator hooks. Sourced, never run on its own.
#
# The coordinator hooks are installed into the user's GLOBAL Claude Code settings, so they fire in
# every session on the machine: drones, unrelated projects, subagents. Everything that is not a
# registered coordinator session must exit instantly and print nothing — a hook that injects
# swarm text into unrelated work is worse than no hook at all.
#
# A hive can have several fronts, each with a coordinator of its own (see 'fronts' in hive). A
# session is the coordinator of at most one of them; the hooks find which, and act on that front.

# hive_front_dir <front> — the directory of a front: the hive directory itself for the default
# front ('' or 'default'), $HIVE_DIR/fronts/<front> for a named one. The same rule as hive's.
hive_front_dir() {
  [ -n "${HIVE_DIR:-}" ] || HIVE_DIR="$HOME/.herdr-hive"
  case "${1:-}" in
    ''|default) printf '%s\n' "$HIVE_DIR" ;;
    *)          printf '%s\n' "$HIVE_DIR/fronts/$1" ;;
  esac
}

# hive_front_coordinator <front> <session_id> — true when the session is that front's registered
# coordinator.
hive_front_coordinator() {
  local dir sid="$2"
  dir=$(hive_front_dir "$1")

  # A coordinator living on another machine has no session here (hive coord --remote).
  [ -s "$dir/coord.remote" ] && return 1

  # Preferred: the session id recorded at registration. Costs nothing and works while the herdr
  # server is down. Optional — older installs only have coord.pane.
  local registered
  registered=$(cat "$dir/coord.session" 2>/dev/null)
  if [ -n "$registered" ]; then
    [ "$sid" = "$registered" ] && return 0
    return 1
  fi

  # Fallback: ask herdr which session owns the registered pane.
  local pane; pane=$(cat "$dir/coord.pane" 2>/dev/null)
  [ -n "$pane" ] || return 1
  # A hook runs inside its session's pane, and herdr names that pane in HERDR_PANE_ID: a session in
  # another pane is not this front's coordinator, and herdr need not be asked. That keeps the hooks
  # of every unrelated session on the machine at no herdr call per front.
  [ -n "${HERDR_PANE_ID:-}" ] && [ "$HERDR_PANE_ID" != "$pane" ] && return 1
  command -v herdr >/dev/null 2>&1 || return 1
  local pane_sid
  pane_sid=$(herdr pane get "$pane" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
p=d.get('result',d).get('pane') or {}
print(((p.get('agent_session') or {}).get('value')) or '')" 2>/dev/null)
  [ -n "$pane_sid" ] && [ "$sid" = "$pane_sid" ]
}

# hive_is_coordinator_session <session_id> — true only for a registered coordinator, and then
# HIVE_SESSION_FRONT names its front ('default' for the default one). A session that carries
# HIVE_FRONT (hive coord-start sets it) is checked against that front alone; any other against
# each front in turn.
# Silence is the deliberate failure mode: when the registration cannot be confirmed, the answer
# is "no", never a guess.
HIVE_SESSION_FRONT=""
hive_is_coordinator_session() {
  local sid="${1:-}" f d
  HIVE_SESSION_FRONT=""
  [ -n "$sid" ] && [ "$sid" != "-" ] || return 1
  [ -n "${HIVE_DRONE:-}" ] && return 1            # drones have their own protocol
  [ -n "${HIVE_DIR:-}" ] || HIVE_DIR="$HOME/.herdr-hive"

  local -a fronts=()
  if [ -n "${HIVE_FRONT+x}" ]; then
    fronts=("${HIVE_FRONT:-default}")
  else
    fronts=(default)
    for d in "$HIVE_DIR"/fronts/*/; do [ -d "$d" ] && fronts+=("$(basename "$d")"); done
  fi
  for f in "${fronts[@]}"; do
    if hive_front_coordinator "$f" "$sid"; then
      HIVE_SESSION_FRONT="$f"
      return 0
    fi
  done
  return 1
}

# hive_hook_field <payload-json> <key>... — prints one value per line, empty when absent.
hive_hook_field() {
  local payload="$1"; shift
  python3 -c "
import json,sys
try: d=json.loads(sys.argv[1] or '{}')
except Exception: d={}
for k in sys.argv[2:]:
    v=d.get(k)
    print(v if isinstance(v,str) else ('' if v is None else str(v)))
" "$payload" "$@" 2>/dev/null
}
