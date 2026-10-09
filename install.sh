#!/usr/bin/env bash
# install.sh — installs hivemind (a swarm of Claude Code agents in herdr) on this machine.
# Idempotent: safe to run repeatedly. Never overwrites anything without a backup.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DST="$HOME/.claude/skills/hivemind"
BIN_DST="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"

ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

echo "== 1/9 Requirements =="
command -v herdr  >/dev/null || die "herdr missing — install from https://herdr.dev and rerun"
command -v claude >/dev/null || die "claude missing (Claude Code CLI)"
command -v python3 >/dev/null || die "python3 missing"
command -v flock  >/dev/null || die "flock missing (util-linux package)"
ok "herdr $(herdr --version 2>/dev/null | awk '{print $2}')"
ok "claude $(claude --version 2>/dev/null | awk '{print $1}')"
# Optional: an account's limits are read from a throwaway tmux session, nothing else uses tmux.
if command -v tmux >/dev/null; then ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"
else warn "tmux missing — optional, needed only to read account limits ('hive usage', 'hive accounts')"; fi
HERDR_MAJOR_MINOR=$(herdr --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
case "$HERDR_MAJOR_MINOR" in
  0.8|0.9) : ;;
  0.7) die "herdr 0.7.x will not work with this version (no agent prompt / agent start into an existing pane) — update herdr or use commit 604848c" ;;
  *)   warn "tested on herdr 0.8.x and 0.9.x — on another version check the 'herdr technicalities' section in SKILL.md" ;;
esac
# Updating the herdr client leaves the old server running, and a newer client refuses it
# (protocol_mismatch) — until the server restarts, hive cannot reach a single pane.
# Output captured first: with pipefail, 'grep -q' closing the pipe early could fail herdr's write.
HERDR_SERVER_STATUS=$(herdr status server 2>/dev/null || true)
if grep -q '^status: running' <<<"$HERDR_SERVER_STATUS"; then
  if herdr workspace list >/dev/null 2>&1; then
    ok "herdr server reachable"
  else
    warn "the running herdr server rejects this client (older than the client?) — hive will not work until it restarts: 'herdr server stop' (ends every pane process), then 'herdr'"
  fi
else
  warn "herdr server not running — start it ('herdr') before the smoke test"
fi

echo "== 2/9 Skill files =="
mkdir -p "$SKILL_DST"
for f in hive drone-ping.sh coord-mail-check.sh coord-scope.sh coord-creed-inject.sh \
         coord-compact-brief.sh coord-creed.md drone-settings.json accounts.conf.example SKILL.md; do
  if [ -e "$SKILL_DST/$f" ] && ! cmp -s "$SRC/skill/$f" "$SKILL_DST/$f"; then
    cp "$SKILL_DST/$f" "$SKILL_DST/$f.bak-$STAMP"
    warn "existing $f archived as $f.bak-$STAMP"
  fi
  cp "$SRC/skill/$f" "$SKILL_DST/$f"
done
chmod +x "$SKILL_DST/hive" "$SKILL_DST/drone-ping.sh" "$SKILL_DST/coord-mail-check.sh" \
         "$SKILL_DST/coord-creed-inject.sh" "$SKILL_DST/coord-compact-brief.sh"
ok "skill in $SKILL_DST"

echo "== 3/9 hive in PATH =="
mkdir -p "$BIN_DST"
ln -sf "$SKILL_DST/hive" "$BIN_DST/hive"
ok "symlink $BIN_DST/hive"
case ":$PATH:" in
  *":$BIN_DST:"*) ok "$BIN_DST is in PATH" ;;
  *) warn "$BIN_DST is NOT in PATH — add to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "== 4/9 herdr ↔ Claude Code integration =="
# The SessionStart hook reports session_id and transcript to herdr — without it `hive revive` does not work.
[ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak-$STAMP"
herdr integration install claude >/dev/null 2>&1 || die "herdr integration install claude failed"
grep -q '^claude: current' <<<"$(herdr integration status 2>/dev/null || true)" \
  && ok "claude integration active (settings.json backup: settings.json.bak-$STAMP)" \
  || die "claude integration does not report as active"

echo "== 5/9 Alerts for the human =="
# hive alerts the human only when nobody hears coord mail. The alert is a herdr toast when herdr
# shows one, the desktop notifier otherwise. hive never turns herdr toasts on: herdr has no
# per-pane switch, so they would announce every turn every drone ends. Read-only — the config is
# yours. The same lookup herdr does: HERDR_CONFIG_PATH, else the XDG config directory.
HERDR_CONFIG="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
# "<toast delivery> <sound for Claude Code agents: on|off>", herdr's defaults filled in.
HERDR_PINGS=$(python3 "$SRC/lib/herdr-pings.py" "$HERDR_CONFIG" 2>/dev/null) || HERDR_PINGS="unknown unknown"
read -r TOAST SOUND <<<"$HERDR_PINGS"
# A running herdr server keeps the config it started with until told to read it again.
HERDR_RELOAD="then 'herdr server reload-config' for a running server"
case "$TOAST" in
  off)     ok "herdr toasts off — drones end their turns without a desktop notification" ;;
  unknown) warn "could not read [ui.toast] delivery from $HERDR_CONFIG" ;;
  *)       warn "herdr toasts are on ([ui.toast] delivery = \"$TOAST\" in $HERDR_CONFIG): herdr notifies you of every turn every drone ends and cannot exempt drone panes. hive does not need them — set delivery = \"off\" to silence the drones (earlier installers set \"system\" themselves), $HERDR_RELOAD" ;;
esac
case "$SOUND" in
  off)     ok "herdr sounds off for Claude Code agents" ;;
  unknown) : ;;
  *)       warn "herdr plays a sound for every turn every drone ends (background workspaces) — [ui.sound] enabled = false, or [ui.sound.agents] claude = \"off\", in $HERDR_CONFIG silences it, $HERDR_RELOAD" ;;
esac
if NOTIFIER=$(command -v notify-send || command -v osascript); then
  ok "desktop notifier for hive's alerts: $NOTIFIER"
else
  warn "no desktop notifier (notify-send or osascript) — the alert for mail nobody hears shows only as a herdr toast, when herdr shows toasts"
fi

echo "== 6/9 Coordinator hooks =="
# Three hooks, all self-scoping to the registered coordinator session (drones and unrelated
# sessions exit instantly), so they are safe to install into the user's global settings:
#   Stop         - cannot end a turn while unread mail sits in mail/coord
#   SessionStart - after a compaction, re-injects the creed and the board read from disk
#   PreCompact   - tells the summarizer which coordination state must survive
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-hook-$STAMP"
HOOK_RESULT=$(python3 - "$SETTINGS" <<'HOOKPY'
import json, os, sys
path = sys.argv[1]
# The command uses $HOME rather than an expanded path: settings.json stays portable and the
# skill is always installed under the user's home.
def cmd(script):
    return 'bash "$HOME/.claude/skills/hivemind/%s"' % script

WANTED = [
    ("Stop",         "*",                        cmd("coord-mail-check.sh"),    15),
    ("SessionStart", "compact|resume|clear|fork", cmd("coord-creed-inject.sh"),  10),
    ("PreCompact",   "auto|manual",              cmd("coord-compact-brief.sh"), 10),
]

data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)

added, present = [], []
hooks = data.setdefault("hooks", {})
for event, matcher, command, timeout in WANTED:
    entries = hooks.setdefault(event, [])
    if any(h.get("command") == command for grp in entries for h in grp.get("hooks", [])):
        present.append(event)
        continue
    entries.append({"matcher": matcher,
                    "hooks": [{"type": "command", "timeout": timeout, "command": command}]})
    added.append(event)

if added:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
print("added: %s | already there: %s" % (", ".join(added) or "none", ", ".join(present) or "none"))
HOOKPY
) || die "failed to update $SETTINGS (backup: $SETTINGS.bak-hook-$STAMP)"
ok "coordinator hooks - $HOOK_RESULT (backup: settings.json.bak-hook-$STAMP)"

echo "== 7/9 Reconciliation sweep timer =="
# The wake-up path is event-driven and every event can be lost; `hive sweep` is the
# level-triggered floor (retries lost wake-ups, reminds about overdue mail, surfaces
# silent drones). A systemd user timer runs it every 5 minutes.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/systemd/user"
  cp "$SRC/systemd/hive-sweep.service" "$SRC/systemd/hive-sweep.timer" "$HOME/.config/systemd/user/"
  systemctl --user daemon-reload
  if systemctl --user enable --now hive-sweep.timer >/dev/null 2>&1; then
    ok "hive-sweep.timer active (every 5 min)"
  else
    warn "could not enable hive-sweep.timer — run: systemctl --user enable --now hive-sweep.timer"
  fi
else
  warn "no systemd user session — schedule '$SKILL_DST/hive sweep' yourself (cron: */5 * * * *)"
fi

echo "== 8/9 CLAUDE.md entry =="
CMD_FILE="$HOME/.claude/CLAUDE.md"
MARKER="## Hivemind — commanding a swarm of agents in herdr"
MARKER_PL="## Hivemind — dowodzenie rojem agentów w herdr"   # pre-translation installs
if [ -f "$CMD_FILE" ] && { grep -qF "$MARKER" "$CMD_FILE" || grep -qF "$MARKER_PL" "$CMD_FILE"; }; then
  if grep -qF "hive watch" "$CMD_FILE"; then
    ok "Hivemind section already present — skipping"
  else
    warn "the Hivemind section in $CMD_FILE predates the mail watcher — update it from CLAUDE-md-snippet.md (install.sh never rewrites it)"
  fi
else
  [ -f "$CMD_FILE" ] && cp "$CMD_FILE" "$CMD_FILE.bak-$STAMP"
  { [ -f "$CMD_FILE" ] && echo; cat "$SRC/CLAUDE-md-snippet.md"; } >> "$CMD_FILE"
  ok "Hivemind section appended to $CMD_FILE"
fi

echo "== 9/9 Verification =="
bash -n "$SKILL_DST/hive"                || die "hive: syntax error"
bash -n "$SKILL_DST/drone-ping.sh"       || die "drone-ping.sh: syntax error"
bash -n "$SKILL_DST/coord-mail-check.sh"    || die "coord-mail-check.sh: syntax error"
bash -n "$SKILL_DST/coord-scope.sh"         || die "coord-scope.sh: syntax error"
bash -n "$SKILL_DST/coord-creed-inject.sh"  || die "coord-creed-inject.sh: syntax error"
bash -n "$SKILL_DST/coord-compact-brief.sh" || die "coord-compact-brief.sh: syntax error"
python3 -c "import json;json.load(open('$SKILL_DST/drone-settings.json'))" || die "drone-settings.json: invalid JSON"
"$SKILL_DST/hive" >/dev/null        || die "hive does not start"
ok "syntax and JSON valid"
mkdir -p "$HOME/.herdr-hive/drones" "$HOME/.herdr-hive/mail"
ok "swarm directories ready"

cat <<EOF

Installed. Smoke test (requires a running herdr server):

  hive coord
  # in the coordinator's Claude Code session arm: Monitor(command: "hive watch", description: "swarm mail", timeout_ms: 1800000)
  hive spawn testdrone
  hive task testdrone - <<'BRIEF'
  # Brief: testdrone
  Count the files in the home directory and report the number. Boundaries: read-only.
  BRIEF
  # do not poll — wait for the watcher's HIVE-MAIL notification, then:
  hive inbox && hive report testdrone && hive kill testdrone --purge

Full manual and traps: $SKILL_DST/SKILL.md
EOF
