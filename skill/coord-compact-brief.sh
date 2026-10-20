#!/usr/bin/env bash
# coord-compact-brief.sh — PreCompact hook for the COORDINATOR session.
#
# A PreCompact hook's stdout is appended to the instructions the summarizer works from, so this is
# the one place where what survives compaction can be influenced before the fact. (The hook that
# looks made for this, PostCompact, prints to the user's terminal and never reaches the model —
# the injection itself is coord-creed-inject.sh, on SessionStart.)
#
# The creed comes back either way. What cannot be reconstructed from any file is the running
# conversation: which drone was told what, which question is still open, what the user is waiting
# on. That is what this asks the summarizer to keep.
#
# Scoping: fires ONLY in a registered coordinator session (see coord-scope.sh). Drones,
# subagents and unrelated sessions print nothing.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=coord-scope.sh
. "$SKILL_DIR/coord-scope.sh" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null || true)
fields=$(hive_hook_field "$payload" session_id agent_type)
sid=$(sed -n 1p <<<"$fields")
agent_type=$(sed -n 2p <<<"$fields")
[ -n "${agent_type:-}" ] && exit 0
hive_is_coordinator_session "${sid:-}" || exit 0

if [ "$HIVE_SESSION_FRONT" != default ]; then
  echo "This session coordinates front '$HIVE_SESSION_FRONT' of a hive with several fronts. Name the"
  echo "front in the summary: its drones and its mail are that front's, the other fronts are not its own."
  echo
fi
cat <<'EOF'
This session coordinates a swarm of agents (hivemind). Preserve the following in the summary,
even at the cost of detail elsewhere — it is coordination state, and losing it stalls drones:

- Every drone currently spawned: its name, what it was told to do, and where its work lives
  (branch, commit, paths it reported).
- Every question a drone asked that has not been answered yet, and every drone waiting on a
  decision. Name them explicitly; a drone nobody answers waits forever.
- Decisions pending from the user, and anything the user explicitly forbade or approved
  (boundaries given to drones, what must not be installed or pushed).
- Reports already collected and their verdicts, in one line each.
- What the user is waiting to hear from the coordinator right now.

Verbose tool output, file listings and full drone reports may be dropped — they are on disk and
can be re-read with 'hive report <drone>'. Names, obligations and open questions may not.
EOF
exit 0
