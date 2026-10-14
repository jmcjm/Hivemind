#!/usr/bin/env bash
# coord-context-guard.sh — Stop hook of the COORDINATOR session, wired in coord-settings.json only
# (drones never load that file).
#
# The coordinator runs with auto-compaction (coord-settings.json). Compaction keeps a summary, and
# what a summary drops is exactly the running state: which drone was told what, what waits on the
# user. That state belongs outside the conversation before the compaction comes, so once the context
# passes HIVE_COORD_WARN_TOKENS (default 330000) this hook blocks ONE
# end of turn per epoch and asks for the save. An epoch ends when the context falls back under the
# threshold — i.e. after the compaction — and then the guard arms again.
#
# The context size is the input of the last main-thread API call, read from the transcript:
# input_tokens + cache_read_input_tokens + cache_creation_input_tokens. The transcript is written
# asynchronously and may miss the newest message; one call late is close enough. A synthetic entry
# (an API error Claude Code writes as a message: model "<synthetic>", usage all zero) is no call
# and says nothing about the context — read as 0 it would end the epoch and warn twice.
# The payload is read from stdin by Python itself, never passed as an argument: it carries the last
# assistant message, and one over 128 KB (MAX_ARG_STRLEN) would not even start the interpreter.
# The margin: a 400000 window leaves an effective window of 380000 (Claude Code's debug log:
# "autocompact: ... effectiveWindow=380000") and compacts below that. Compaction strikes mid-turn,
# the guard only at the end of one — so the warning sits a whole large turn (~40-50k) under it.
#
# Settings: HIVE_COORD_WARN_TOKENS (threshold), HIVE_COORD_GUARD_NOTIFY=0 (no desktop notification),
# HIVE_COORD_GUARD_MSG (the reason text; {k} is replaced by the context size in thousands).
set -uo pipefail

[ -n "${HIVE_DRONE:-}" ] && exit 0                 # never in a drone, whatever loaded this file
HIVE_DIR="${HIVE_DIR:-$HOME/.herdr-hive}"
STATE="$HIVE_DIR/.context-guard"
python3 - "$STATE" "${HIVE_COORD_WARN_TOKENS:-330000}" 3<&0 <<'PY'
import json, os, subprocess, sys
state, warn = sys.argv[1], sys.argv[2]
try:
    with os.fdopen(3) as f:
        d = json.loads(f.read() or '{}')
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
if d.get('stop_hook_active'):          # this stop was already held once — never loop
    sys.exit(0)
path, sid = d.get('transcript_path') or '', d.get('session_id') or ''
try:
    warn = int(warn)
except ValueError:
    warn = 330000
if not path or not os.path.isfile(path):
    sys.exit(0)

def last_context(path):
    """Input size of the last main-thread assistant message, reading from the end of the file."""
    size = os.path.getsize(path)
    for chunk in (4 << 20, 32 << 20, size):
        with open(path, 'rb') as f:
            f.seek(max(0, size - chunk))
            data = f.read()
        best = None
        for line in data.split(b'\n'):
            if b'"assistant"' not in line or b'"usage"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get('type') != 'assistant' or e.get('isSidechain') or e.get('isApiErrorMessage'):
                continue
            m = e.get('message') or {}
            if m.get('model') == '<synthetic>':
                continue
            u = m.get('usage') or {}
            n = sum(int(u.get(k) or 0) for k in
                    ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
            if n > 0:
                best = n
        if best is not None or chunk >= size:
            return best
    return None

tokens = last_context(path)
if tokens is None:
    sys.exit(0)
try:
    with open(state) as f:
        st = json.load(f)
except Exception:
    st = {}
if tokens < warn:
    # Under the threshold: a new epoch (after a compaction, or a fresh session) — arm again.
    if st.get(sid):
        st.pop(sid, None)
        with open(state + '.tmp', 'w') as f: json.dump(st, f)
        os.replace(state + '.tmp', state)
    sys.exit(0)
if st.get(sid):                        # already warned in this epoch
    sys.exit(0)
st[sid] = tokens
with open(state + '.tmp', 'w') as f: json.dump(st, f)
os.replace(state + '.tmp', state)
k = f"{tokens // 1000}"
msg = os.environ.get('HIVE_COORD_GUARD_MSG') or (
    "Context ~{k}k — auto-compaction is close. Save the coordinator state now (drones in flight, "
    "what each was told, open questions, decisions pending from the owner) wherever you keep it, "
    "and only then end the turn.")
print(json.dumps({"decision": "block", "reason": msg.replace('{k}', k)}, ensure_ascii=False))
if os.environ.get('HIVE_COORD_GUARD_NOTIFY', '1') != '0':
    try:
        subprocess.run(['notify-send', '-a', 'hive', f'Coordinator context ~{k}k',
                        'Auto-compaction is near; the coordinator was asked to save its state.'],
                       timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
PY
exit 0
