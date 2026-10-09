#!/usr/bin/env bash
# tests/accounts/test-accounts.sh [path-to-hive]
# Tests of 'hive accounts' and of the account a spawn or revive lands on.
# Nothing real runs: tmux is the stand-in in fake-bin/, herdr the one in ../fake-herdr/, HOME and
# HIVE_DIR are throwaway directories, and the /usage panels are fixtures — two captured from a
# Claude Code 2.1.294 session with the machine's own lines replaced (fixtures/panel-*.txt), the rest
# built in the same layout by panel() below.
# Without an argument it tests skill/hive of this checkout.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HIVE="$(readlink -f "${1:-$ROOT/skill/hive}")"
[ -x "$HIVE" ] || { echo "not executable: $HIVE" >&2; exit 2; }
echo "testing: $HIVE"

T="$(mktemp -d)" && ERRF="$(mktemp)" || { echo "mktemp failed" >&2; exit 2; }
# world() empties "$T"/* before every section: an empty T would make that /*.
[ -n "$T" ] && [ -d "$T" ] || { echo "no temp directory: '$T'" >&2; exit 2; }
trap 'rm -rf "$T" "$ERRF"' EXIT
export TZ=Europe/Berlin
export HOME="$T/home" HIVE_DIR="$T/hive" FAKE_TMUX_DIR="$T/tmux" FAKE_PANELS="$T/panels" FAKE_HERDR_LOG="$T/herdr.log"
export PATH="$HERE/fake-bin:$ROOT/tests/fake-herdr:$PATH"
unset HIVE_ACCOUNT CLAUDE_CONFIG_DIR HIVE_DRONE HERDR_HIVE_ROLE HIVE_COORD_PANE NO_COLOR
export HIVE_USAGE_TIMEOUT=5     # seconds per measurement step; the hang tests lower it

# --- assertions -------------------------------------------------------------
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing:  $2" "in:       $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "unwanted: $2" "in:       $3" ;; *) ok "$1" ;; esac; }
like()  { if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1" "no match: $2" "in:       $3"; fi; }
section() { printf '\n%s\n' "$1"; }

# run <command...> — OUT = stdout, ERR = stderr, RC = exit code
run() { OUT=$("$@" 2>"$ERRF"); RC=$?; ERR=$(cat "$ERRF"); }
row() { printf '%s\n' "$OUT" | grep -E "^$1 " || true; }
at()  { date -d "$1" +%s; }
jget() { python3 -c "import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print('null' if v is None else v)" "$1"; }
meta_account() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['account'] or 'default')" "$HIVE_DIR/drones/$1/meta.json"; }
sessions() { grep -c "^new " "$FAKE_TMUX_DIR/log" 2>/dev/null || true; }
kills()    { grep -c "^kill " "$FAKE_TMUX_DIR/log" 2>/dev/null || true; }

# --- the world ----------------------------------------------------------------
account_home() {  # account_home <name> <email> — a logged-in, onboarded account sharing projects/ with the default one
  local cfg="$HOME/.claude.json"
  if [ "$1" != default ]; then
    mkdir -p "$HOME/.claude-$1"; echo '{}' > "$HOME/.claude-$1/.credentials.json"
    ln -sfn "$HOME/.claude/projects" "$HOME/.claude-$1/projects"; cfg="$HOME/.claude-$1/.claude.json"
  fi
  printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"%s"},"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' \
    "$2" "$HOME" > "$cfg"
}
world() {  # a clean HOME, HIVE_DIR and stand-in state: accounts default, alpha, beta, gamma, delta
  rm -rf "${T:?}"/*; mkdir -p "$HOME/.claude/projects" "$HIVE_DIR" "$FAKE_TMUX_DIR" "$FAKE_PANELS"
  : > "$FAKE_HERDR_LOG"; : > "$FAKE_TMUX_DIR/log"
  account_home default owner@example.com
  local a; for a in alpha beta gamma delta; do account_home "$a" "$a@example.com"; done
}
conf() { cat > "$HIVE_DIR/accounts.conf"; }
# cache <name>:<age s>:<session %>:<session reset in s|->:<week %>:<week reset in s|-> ...
cache() {
  python3 - "$HIVE_DIR/usage-cache.json" "$@" <<'PY'
import json, sys, time
now, acc = int(time.time()), {}
for spec in sys.argv[2:]:
    name, age, sp, sr, wp, wr = spec.split(':')
    acc[name] = {'measured_at': now - int(age),
                 'session_pct': int(sp), 'session_reset': None if sr == '-' else now + int(sr), 'session_reset_text': None,
                 'week_pct': int(wp), 'week_reset': None if wr == '-' else now + int(wr), 'week_reset_text': None}
json.dump({'accounts': acc}, open(sys.argv[1], 'w'))
PY
}
# panel <session %> <session reset line|-> <week %> <week reset line|-> — a /usage panel in the real layout.
# The per-model section and the "contributing" lines carry numbers of their own on purpose: a parser
# that reads the wrong line shows up as 77% or 93%.
panel() {
  printf '   Settings  Status   Config   Usage   Stats\n\n   Session\n\n   Total cost:            $0.0000\n\n'
  printf '   Current session\n   ███▌                                               %s%% used\n' "$1"
  [ "$2" = - ] || printf '   %s\n' "$2"
  printf '\n   Current week (all models)\n   █████                                              %s%% used\n' "$3"
  [ "$4" = - ] || printf '   %s\n' "$4"
  printf '\n   Current week (Fable)\n   ██████████████                                     77%% used\n   Resets Nov 1, 1am (Europe/Berlin)\n\n'
  printf "   What's contributing to your limits usage?\n\n   93%% of your usage was at >150k context\n"
  printf '   88%% of your usage was while 4+ sessions ran in parallel\n\n   Esc to cancel\n'
}
SESSION_IN_2H="$(date -d '+2 hours' '+Resets %-I:%M%P (Europe/Berlin)')"
WEEK_IN_3D="$(date -d '+3 days' '+Resets %b %-d, %-I%P (Europe/Berlin)')"
WEEK_IN_3D_SHOWN="$(date -d '+3 days' '+%b %d %H:00')"

# =============================================================================
section "parser — the /usage panel"
world
parse() { run "$HIVE" _usage-parse "$1" "$2"; }

parse "$HERE/fixtures/panel-loading.txt" "$(at '2026-10-08 15:49:53')"
eq "real panel: session percent"            35 "$(jget session_pct <<<"$OUT")"
eq "real panel: session reset 4:10pm"       "$(at '2026-10-08 16:10')" "$(jget session_reset <<<"$OUT")"
eq "real panel: week (all models) percent"  10 "$(jget week_pct <<<"$OUT")"
eq "real panel: week reset Oct 15, 9am"     "$(at '2026-10-15 09:00')" "$(jget week_reset <<<"$OUT")"
parse "$HERE/fixtures/panel-settled.txt" "$(at '2026-10-08 15:49:53')"
eq "real panel with '93% of your usage' lines: session" 35 "$(jget session_pct <<<"$OUT")"
eq "real panel with '93% of your usage' lines: week"    10 "$(jget week_pct <<<"$OUT")"

panel 100 'Resets 5:29pm (Europe/Berlin)' 100 'Resets Oct 12, 3:59pm (Europe/Berlin)' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 15:31')"
eq "exhausted: session 100"                 100 "$(jget session_pct <<<"$OUT")"
eq "exhausted: week 100, not the 77% of the per-model section" 100 "$(jget week_pct <<<"$OUT")"
eq "reset with minutes: Oct 12, 3:59pm"     "$(at '2026-10-12 15:59')" "$(jget week_reset <<<"$OUT")"

panel 0 - 23 'Resets Oct 12, 4pm (Europe/Berlin)' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 15:31')"
eq "no session window: 0 percent"           0 "$(jget session_pct <<<"$OUT")"
eq "no session window: no reset"            null "$(jget session_reset <<<"$OUT")"
eq "no session window: week still read"     23 "$(jget week_pct <<<"$OUT")"

panel 50 'Resets 2:10am (Europe/Berlin)' 5 'Resets Jan 2, 9am (Europe/Berlin)' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-12-30 23:30')"
eq "a bare time already behind us is tomorrow's" "$(at '2026-12-31 02:10')" "$(jget session_reset <<<"$OUT")"
eq "a date without a year rolls into next year"  "$(at '2027-01-02 09:00')" "$(jget week_reset <<<"$OUT")"

panel 50 'Resets 3pm (America/New_York)' 5 'Resets Oct 28, 9am (Europe/Berlin)' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-22 15:00')"
eq "the panel's own time zone is honoured"       "$(at '2026-10-22 21:00')" "$(jget session_reset <<<"$OUT")"
eq "a reset across the DST change keeps its wall time" "$(at '2026-10-28 09:00')" "$(jget week_reset <<<"$OUT")"

panel 50 'Resets 6pm' 5 'Resets Oct 12 at 12am' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 15:00')"
eq "no zone on the panel = local time"           "$(at '2026-10-08 18:00')" "$(jget session_reset <<<"$OUT")"
eq "12am is midnight; 'Oct 12 at' is understood" "$(at '2026-10-12 00:00')" "$(jget week_reset <<<"$OUT")"

panel 50 'Resets 12:30pm (Europe/Berlin)' 5 'Resets tomorrow at noon' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "12:30pm is half past noon"                   "$(at '2026-10-08 12:30')" "$(jget session_reset <<<"$OUT")"
eq "unknown reset wording: percent still read"   5 "$(jget week_pct <<<"$OUT")"
eq "unknown reset wording: no epoch guessed"     null "$(jget week_reset <<<"$OUT")"
eq "unknown reset wording: text kept"            "tomorrow at noon" "$(jget week_reset_text <<<"$OUT")"

printf '   Current session\n   ██   12%% used\n\n   Current week\n   █   34%% used\n   Resets Oct 12, 4pm\n' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "a weekly section without '(all models)'"     34 "$(jget week_pct <<<"$OUT")"

printf '   Current session\n   ██   35.5%% used\n   Resets 6pm\n\n   Current week (all models)\n   █   <1%% used\n   Resets Oct 12, 4pm\n' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "a percentage with a fraction is its whole part, not its tail" 35 "$(jget session_pct <<<"$OUT")"
eq "'<1% used' is 1"                             1 "$(jget week_pct <<<"$OUT")"

printf '   Current session\n   ██████   103%% used\n   Resets 6pm\n\n   Current week (all models)\n   █   95,5%% used\n   Resets Oct 12, 4pm\n' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "over 100 percent is read as printed"         103 "$(jget session_pct <<<"$OUT")"
eq "a decimal comma is a fraction too"           95 "$(jget week_pct <<<"$OUT")"

printf ' Welcome to Claude Code\n\n ❯ 1. Claude account with subscription\n   2. Anthropic Console account\n' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "a login screen is refused"                   1 "$RC"
has "a login screen: says what is missing"       'no "Current session" section' "$ERR"

printf '   Current session\n   ██   12%% used\n   Resets 6pm\n\n   93%% of your usage was at >150k context\n' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "a panel without the weekly section is refused" 1 "$RC"
has "missing weekly section is named"            'no "Current week (all models)" section' "$ERR"

printf '   Current session\n\n   Current week (all models)\n   █   34%% used\n' > "$T/p.txt"
parse "$T/p.txt" "$(at '2026-10-08 10:00')"
eq "a section whose percentage has not loaded is refused" 1 "$RC"
has "the section without a percentage is named"  'no percentage under "Current session"' "$ERR"

# =============================================================================
section "accounts.conf"
world
run "$HIVE" accounts
eq "no accounts.conf: hive accounts fails"       1 "$RC"
has "no accounts.conf: says so"                  "no config at $HIVE_DIR/accounts.conf" "$ERR"
has "no accounts.conf: prints the format"        "account alt      prio=1  week_threshold=80" "$ERR"
has "no accounts.conf: says the threshold is weekly" "The threshold is on the weekly limit" "$ERR"

conf <<'EOF'
max_age = 10
account Alpha prio=1
account beta prio=one
account beta week_threshold=0
account gamma colour=red
acount delta
account delta threshold=90
account zeta session_threshold=101
EOF
run "$HIVE" accounts
eq "broken accounts.conf: fails"                 1 "$RC"
has "bad name, with its line"                    "line 2: account name 'Alpha' rejected" "$ERR"
has "bad prio"                                   "line 3: 'prio=one' not understood" "$ERR"
has "duplicate account"                          "line 4: account 'beta' is listed twice" "$ERR"
has "threshold out of range"                     "line 4: 'week_threshold=0' not understood" "$ERR"
has "unknown setting"                            "line 5: 'colour=red' not understood" "$ERR"
has "unknown line"                               'line 6: expected "account <name> ..."' "$ERR"
has "a bare 'threshold' does not say which limit: refused, with the two names" \
    "line 7: 'threshold=90' not understood — prio=<n>, week_threshold=<1-100>, session_threshold=<1-100>, hard, disabled" "$ERR"
has "session threshold out of range"             "line 8: 'session_threshold=101' not understood" "$ERR"

conf <<'EOF'
max_age = 0
account alpha
EOF
run "$HIVE" accounts
has "max_age below one minute is refused"        "line 1: max_age is in minutes, 1 or more" "$ERR"

printf 'account alpha\n\xff\xfe\x00not text\n' > "$HIVE_DIR/accounts.conf"
run "$HIVE" accounts
eq "an accounts.conf that is not text: fails"    1 "$RC"
has "an accounts.conf that is not text: says so" "$HIVE_DIR/accounts.conf cannot be read" "$ERR"
hasnt "an accounts.conf that is not text: no Python traceback" "Traceback" "$ERR"

# the example shipped next to hive must stay a config hive accepts
account_home alt alt@example.com
cp "$(dirname "$HIVE")/accounts.conf.example" "$HIVE_DIR/accounts.conf"
run "$HIVE" accounts
eq "the shipped accounts.conf.example is accepted" 0 "$RC"
like "the example: its first account, to 80% of its week" '^alt +claude +1 +week 80% +alt@' "$(row alt)"
like "the example: the default account behind a hard 60%" '^default +claude +2 +week 60% hard +owner@' "$(row default)"
hasnt "the example: its commented-out account is not listed" "spare" "$OUT"

conf <<'EOF'
# comments and blank lines are fine

max_age=5
account beta                      # no prio = position in the file, no threshold = week 90
account alpha week_threshold=85% hard
account gamma week_threshold=70 session_threshold=95
EOF
run "$HIVE" accounts
eq "defaults: accepted"                          0 "$RC"
like "no prio: first line is prio 1, threshold week 90%" '^beta +claude +1 +week 90% +beta@' "$(row beta)"
like "no prio: second line is prio 2; week 85% hard" '^alpha +claude +2 +week 85% hard +alpha@' "$(row alpha)"
like "a session threshold is shown next to the weekly one" '^gamma +claude +3 +week 70%, session 95% +gamma@' "$(row gamma)"
has "never measured: says so"                    "usage: never measured — run: hive accounts --refresh" "$OUT"
like "never measured: no data, and the best blind guess is marked" 'no data <- SELECTED$' "$(row beta)"

# =============================================================================
section "table and statuses (the reference picture)"
world
conf <<'EOF'
max_age = 10
account alpha    prio=1  week_threshold=90
account beta     prio=2  week_threshold=90
account gamma    prio=3  week_threshold=90
account delta    prio=4  week_threshold=90  hard
account default  prio=5  week_threshold=90
account off      prio=6  week_threshold=90  disabled
EOF
cache alpha:240:24:16110:90:432000 beta:240:0:-:100:10800 gamma:240:100:7110:23:345600 \
      delta:240:0:-:92:25200 default:240:0:-:28:500000 off:240:1:-:1:-
run "$HIVE" accounts
eq "table: exit 0"                               0 "$RC"
eq "header: age of the measurement"              "usage from 4 min ago" "$(head -1 <<<"$OUT")"
like "column headers"                            '^ACCOUNT +ENGINE +PRIO +THRESHOLD +EMAIL +SESSION +SESSION RESET +WEEK +WEEK RESET +STATUS$' "$(sed -n 2p <<<"$OUT")"
like "alpha: over threshold: week"               '^alpha +claude +1 +week 90% +alpha@example.com +24% +[A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in 4h28m\) +90% +[A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} +over threshold: week$' "$(row alpha)"
like "beta: UNAVAILABLE: week 100%, no session window" '^beta .* 0% +- +100% .* UNAVAILABLE: week 100%$' "$(row beta)"
like "gamma: UNAVAILABLE: session 100%"          '^gamma .* 100% .*\(in 1h58m\) +23% .* UNAVAILABLE: session 100%$' "$(row gamma)"
like "delta: hard threshold shown and named"     '^delta +claude +4 +week 90% hard .* 92% .* over threshold: week \(hard\)$' "$(row delta)"
like "default: available and SELECTED"           '^default +claude +5 +week 90% +owner@example.com +0% +- +28% .* available <- SELECTED$' "$(row default)"
like "off: disabled, its numbers not shown"      '^off +claude +6 +week 90% +- +- +- +- +- +disabled$' "$(row off)"
eq "exactly one account is SELECTED"             1 "$(grep -c 'SELECTED' <<<"$OUT")"
hasnt "piped output carries no colours"          $'\x1b' "$OUT"

if command -v script >/dev/null; then
  TTY_OUT=$(script -qec "$(printf '%q' "$HIVE") accounts" /dev/null)
  has "on a TTY: selected account green"         $'\x1b[32mdefault\x1b[0m' "$TTY_OUT"
  has "on a TTY: over threshold yellow"          $'\x1b[33mover threshold: week\x1b[0m' "$TTY_OUT"
  has "on a TTY: unavailable red"                $'\x1b[31mUNAVAILABLE: week 100%\x1b[0m' "$TTY_OUT"
  has "on a TTY: a full percentage red"          $'\x1b[31m100%\x1b[0m' "$TTY_OUT"
  has "on a TTY: a percentage over threshold yellow" $'\x1b[33m92%\x1b[0m' "$TTY_OUT"
  has "on a TTY: a low percentage green"         $'\x1b[32m24%\x1b[0m' "$TTY_OUT"
  TTY_OUT=$(NO_COLOR=1 script -qec "$(printf '%q' "$HIVE") accounts" /dev/null)
  hasnt "NO_COLOR switches colours off on a TTY" $'\x1b[3' "$TTY_OUT"
else
  echo "  skip  colour tests: no script(1) to provide a TTY"
fi

cache alpha:2820:10:3600:10:432000
run "$HIVE" accounts
has "an old measurement is called stale"         "usage from 47 min ago — STALE (max_age 10 min)" "$OUT"

# the threshold is on the weekly limit; the session limit counts earlier than 100% only where asked
conf <<'EOF'
account alpha    prio=1  week_threshold=90  session_threshold=90
account beta     prio=2  week_threshold=90
account gamma    prio=3  week_threshold=90
EOF
cache alpha:60:95:3600:91:432000 beta:60:95:3600:10:432000 gamma:60:100:-30:20:432000
run "$HIVE" accounts
like "a session threshold, when set, counts: both windows over, both named" '^alpha +claude +1 +week 90%, session 90% .* over threshold: session, week$' "$(row alpha)"
like "without a session threshold a session at 95% is still room" '^beta .* 95% .* 10% .* available <- SELECTED$' "$(row beta)"
like "a window whose reset has passed counts as 0%" '^gamma .* 0% +- +20% .* available$' "$(row gamma)"
if command -v script >/dev/null; then
  TTY_OUT=$(script -qec "$(printf '%q' "$HIVE") accounts" /dev/null)
  has "on a TTY: a session over its own threshold yellow" $'\x1b[33m95%\x1b[0m' "$TTY_OUT"
  has "on a TTY: a session at 95% without a session threshold green" $'\x1b[32m95%\x1b[0m' "$TTY_OUT"
fi

HIVE_ACCOUNT=beta run "$HIVE" accounts
like "HIVE_ACCOUNT: the pinned account is the SELECTED one" 'SELECTED \(HIVE_ACCOUNT\)$' "$(row beta)"
has "HIVE_ACCOUNT: the table says the selection is off" "HIVE_ACCOUNT=beta is set: spawn uses it and the automatic selection is off" "$OUT"

# a cache somebody edited by hand: valid JSON, wrong types
printf '{"accounts":{"alpha":{"measured_at":"yesterday","session_pct":"12","week_pct":5},"beta":["x"],"gamma":{"measured_at":%s,"session_pct":10,"session_reset":"soon","week_pct":20,"week_reset":null},"delta":7}}' \
  "$(date +%s)" > "$HIVE_DIR/usage-cache.json"
run "$HIVE" accounts
eq "a cache with wrong types: the table still comes out" 0 "$RC"
hasnt "a cache with wrong types: no Python traceback" "Traceback" "$ERR$OUT"
like "an entry with wrong types is no data"      '^alpha .* no data$' "$(row alpha)"
like "an entry that is not an object is no data" '^beta .* no data$' "$(row beta)"
like "a bad reset next to good numbers: the numbers stay, the reset goes" '^gamma .* 10% +- +20% +- +available <- SELECTED$' "$(row gamma)"
HIVE_USAGE_TIMEOUT=2 run "$HIVE" accounts --pick
eq "a cache with wrong types: the pick still works" "gamma" "${OUT%% *}"
printf 'not json at all' > "$HIVE_DIR/usage-cache.json"
run "$HIVE" accounts
has "a cache that is not JSON counts as never measured" "usage: never measured" "$OUT"

# =============================================================================
section "selection — hive accounts --pick (fresh cache, nothing is measured)"
world
three() { conf <<'EOF'
max_age = 10
account alpha    prio=1  week_threshold=90
account beta     prio=2  week_threshold=90
account default  prio=3  week_threshold=90
EOF
}
three; cache alpha:60:10:3600:20:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
eq "lowest prio under its threshold" "alpha — prio 1, session 10%, week 20%, under its threshold (week 90%)" "$OUT"

cache alpha:60:10:3600:95:432000 beta:60:30:3600:40:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
eq "prio 1 over threshold: prio 2 takes it" \
   "beta — prio 2, session 30%, week 40%, under its threshold (week 90%); passed over: alpha (over threshold: week)" "$OUT"

cache alpha:60:10:3600:100:432000 beta:60:100:3600:40:432000 default:60:89:3600:89:432000
run "$HIVE" accounts --pick
eq "full accounts are never taken; 89% is under 90%" \
   "default — prio 3, session 89%, week 89%, under its threshold (week 90%); passed over: alpha (UNAVAILABLE: week 100%), beta (UNAVAILABLE: session 100%)" "$OUT"

cache alpha:60:99:3600:10:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
eq "the threshold is weekly: a session at 99% is still room" \
   "alpha — prio 1, session 99%, week 10%, under its threshold (week 90%)" "$OUT"

cache alpha:60:10:3600:90:432000 beta:60:10:3600:95:432000 default:60:10:3600:99:432000
run "$HIVE" accounts --pick
eq "all over threshold: the first by prio, as a last resort (90% is over 90%)" \
   "alpha — LAST RESORT — no account is under its threshold; prio 1, session 10%, week 90%, its threshold (week 90%) is not hard" "$OUT"

conf <<'EOF'
account alpha    prio=1  week_threshold=90  session_threshold=80
account beta     prio=2  week_threshold=90
EOF
cache alpha:60:85:3600:10:432000 beta:60:85:3600:10:432000
run "$HIVE" accounts --pick
eq "a session threshold, where set, takes the account out of the first choice" \
   "beta — prio 2, session 85%, week 10%, under its threshold (week 90%); passed over: alpha (over threshold: session)" "$OUT"
cache alpha:60:70:3600:10:432000 beta:60:85:3600:10:432000
run "$HIVE" accounts --pick
eq "under both of its thresholds: both are named in the reason" \
   "alpha — prio 1, session 70%, week 10%, under its threshold (week 90%, session 80%)" "$OUT"

conf <<'EOF'
account alpha    prio=1  week_threshold=90  hard
account beta     prio=2  week_threshold=90
account default  prio=3  week_threshold=90  hard
EOF
cache alpha:60:10:3600:95:432000 beta:60:10:3600:95:432000 default:60:10:3600:95:432000
run "$HIVE" accounts --pick
like "hard: over its threshold an account is not even a last resort" '^beta — LAST RESORT .*passed over: alpha \(over threshold: week \(hard\)\)$' "$OUT"

cache alpha:60:10:3600:95:432000 beta:60:10:3600:100:172800 default:60:10:3600:91:432000
run "$HIVE" accounts --pick
eq "nothing selectable: refused"                 1 "$RC"
has "nothing selectable: says so"                "no account is selectable:" "$ERR"
has "nothing selectable: each account with its state" "alpha: over threshold: week (hard) — room again" "$ERR"
like "nothing selectable: when a full account gets room" 'beta: UNAVAILABLE: week 100% — room again [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}' "$ERR"
has "nothing selectable: the way out"            "force an account with --account NAME" "$ERR"
run "$HIVE" accounts
has "nothing selectable: the table says it too"  "no account is selectable: a spawn without --account is refused" "$OUT"
hasnt "nothing selectable: nothing is marked"    "SELECTED" "$OUT"

conf <<'EOF'
account alpha    prio=1  week_threshold=90  disabled
account beta     prio=2  week_threshold=90
EOF
cache alpha:60:0:-:0:432000 beta:60:10:3600:95:432000
run "$HIVE" accounts --pick
like "disabled: never taken, even when it is the only one with room" '^beta — LAST RESORT' "$OUT"

three; cache alpha:60:100:-30:20:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
like "a full window whose reset has passed is room again" '^alpha — prio 1, session 0%, week 20%' "$OUT"

conf <<'EOF'
account default  prio=3
account beta     prio=2
account alpha    prio=1
EOF
cache alpha:60:10:3600:20:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
like "prio decides, not the order in the file"   '^alpha — prio 1' "$OUT"

conf <<'EOF'
account alpha    prio=1  week_threshold=50
account beta     prio=2  week_threshold=90
EOF
cache alpha:60:20:3600:60:432000 beta:60:20:3600:60:432000
run "$HIVE" accounts --pick
like "thresholds are per account"                '^beta — prio 2, .*passed over: alpha \(over threshold: week\)$' "$OUT"

# a table of ceilings: the first account to 100%; the next two to 80% of the week, default to 60% —
# all three hard: past them an account is not taken at all
ceilings() { conf <<'EOF'
account alpha    prio=1  week_threshold=100
account beta     prio=2  week_threshold=80  hard
account gamma    prio=3  week_threshold=80  hard
account default  prio=4  week_threshold=60  hard
EOF
}
ceilings; cache alpha:60:99:3600:99:432000 beta:60:0:-:0:432000 gamma:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
like "a 100% threshold: the first account is taken until it is full" '^alpha — prio 1, session 99%, week 99%, under its threshold \(week 100%\)$' "$OUT"
ceilings; cache alpha:60:10:3600:100:432000 beta:60:10:3600:80:432000 gamma:60:99:3600:79:432000 default:60:0:-:0:432000
run "$HIVE" accounts --pick
like "first full, second at its 80% ceiling: the third at 79% of the week takes it" '^gamma — prio 3, session 99%, week 79%, under its threshold \(week 80%\); passed over: alpha \(UNAVAILABLE: week 100%\), beta \(over threshold: week \(hard\)\)$' "$OUT"
ceilings; cache alpha:60:10:3600:100:432000 beta:60:100:3600:85:432000 gamma:60:10:3600:100:432000 default:60:10:3600:59:432000
run "$HIVE" accounts --pick
like "the default account under its 60% is taken when the others have no room" '^default — prio 4, session 10%, week 59%, under its threshold \(week 60%\)' "$OUT"

# no account has room: first full for another 2 h (session), the ceilings of the rest reset in 1, 3 and 5 days
ceilings; cache alpha:60:100:7230:10:500000 beta:60:10:3600:85:86430 gamma:60:10:3600:90:259230 default:60:10:3600:60:432030
run "$HIVE" accounts --pick
eq "every ceiling reached: nothing is taken, not even as a last resort" 1 "$RC"
eq "every ceiling reached: nothing on stdout"    "" "$OUT"
has "refusal: says so"                           "no account is selectable:" "$ERR"
like "refusal: the full account, with when its session comes back" 'alpha: UNAVAILABLE: session 100% — room again [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in 2h00m\)' "$ERR"
like "refusal: an account at its ceiling, with when its week resets" 'beta: over threshold: week \(hard\) — room again [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in 1d0h\)' "$ERR"
like "refusal: the third account"                'gamma: over threshold: week \(hard\) — room again .* \(in 3d0h\)' "$ERR"
like "refusal: the default account at exactly its 60%" 'default: over threshold: week \(hard\) — room again .* \(in 5d0h\)' "$ERR"
like "refusal: names the account that gets room first" 'First to get room: alpha, [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in 2h00m\)\.' "$ERR"
has "refusal: the way out"                       "Wait for that reset, or force an account with --account NAME." "$ERR"
run "$HIVE" accounts
has "every ceiling reached: the table says a spawn is refused" "no account is selectable: a spawn without --account is refused" "$OUT"
hasnt "every ceiling reached: nothing is marked SELECTED" "SELECTED" "$OUT"
like "every ceiling reached: the table shows the ceiling and what hit it" '^beta +claude +2 +week 80% hard .* 85% .* over threshold: week \(hard\)$' "$(row beta)"

# the account that gets room first is the one whose blocking window ends first, not the first in the list
ceilings; cache alpha:60:10:3600:100:500000 beta:60:10:3600:85:7230 gamma:60:10:3600:90:259230 default:60:10:3600:60:432030
run "$HIVE" accounts --pick
like "refusal: the first reset can belong to an account further down" 'First to get room: beta, .* \(in 2h00m\)\.' "$ERR"

three; cache alpha:60:10:3600:20:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
HIVE_ACCOUNT=beta run "$HIVE" accounts --pick
eq "HIVE_ACCOUNT pins the account"               "beta — HIVE_ACCOUNT pins it; the automatic selection is off" "$OUT"
eq "none of the picks above measured anything"   0 "$(sessions)"

# =============================================================================
section "measurement — hive accounts --refresh (stand-in tmux, fixture panels)"
world
conf <<'EOF'
max_age = 10
account alpha    prio=1  week_threshold=90
account beta     prio=2  week_threshold=90
account default  prio=3  week_threshold=90
account gamma    prio=4  week_threshold=90  disabled
account ghost    prio=5  week_threshold=90
EOF
mkdir -p "$HOME/.claude-ghost"      # a config dir nobody logged in to
panel 24 "$SESSION_IN_2H" 91 "$WEEK_IN_3D"  > "$FAKE_PANELS/alpha.txt"
panel 100 "$SESSION_IN_2H" 12 "$WEEK_IN_3D" > "$FAKE_PANELS/beta.txt"
panel 0 - 28 'Resets tomorrow at noon'      > "$FAKE_PANELS/default.txt"
panel 1 - 1 "$WEEK_IN_3D"                   > "$FAKE_PANELS/gamma.txt"
run "$HIVE" accounts --refresh
eq "refresh: exit 0"                             0 "$RC"
has "refresh: says what it measures"             "accounts: measuring alpha beta default ghost" "$ERR"
eq "refresh: one session per enabled, usable account" 3 "$(sessions)"
eq "refresh: every session is killed"            3 "$(kills)"
hasnt "refresh: a disabled account is not measured" " gamma" "$(cat "$FAKE_TMUX_DIR/log")"
eq "refresh: the sessions have distinct names"   3 "$(grep '^new ' "$FAKE_TMUX_DIR/log" | awk '{print $2}' | sort -u | wc -l)"
like "refresh: header says fresh"                '^usage from <1 min ago$' "$(head -1 <<<"$OUT")"
like "alpha measured: 24% / 91%, resets shown"   "^alpha .* 24% +[A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in (1h5[89]m|2h00m)\) +91% +$WEEK_IN_3D_SHOWN +over threshold: week\$" "$(row alpha)"
like "beta measured: session 100%"               'UNAVAILABLE: session 100%$' "$(row beta)"
like "default measured: unknown reset wording shown as printed" '^default .* 0% +- +28% +tomorrow at noon +available <- SELECTED$' "$(row default)"
like "ghost: not logged in = UNAVAILABLE"        "^ghost .* - +- +- +- +UNAVAILABLE: account 'ghost' is not logged in" "$(row ghost)"
run "$HIVE" accounts --pick
like "pick after refresh: the only account with room" '^default — prio 3' "$OUT"
eq "pick on a fresh cache measures nothing"      3 "$(sessions)"

run "$HIVE" usage --account alpha --cwd "$HOME" --timeout 5
has "hive usage still prints the compact panel: account" "account: alpha" "$OUT"
has "hive usage still prints the compact panel: session" "Current session" "$OUT"
has "hive usage still prints the compact panel: percent" "24% used" "$OUT"
has "hive usage still prints the compact panel: reset"   "$SESSION_IN_2H" "$OUT"
eq "hive usage kills its session"                "$(sessions)" "$(kills)"

printf 'something else entirely\n 5%% used\n' > "$FAKE_PANELS/beta.txt"
run "$HIVE" accounts --refresh
has "unreadable panel: reported"                 "accounts: beta: the /usage panel was not understood" "$ERR"
like "unreadable panel: the last good numbers stay, flagged" '^beta .* 100% .* UNAVAILABLE: session 100% — last measurement FAILED: the /usage panel was not understood' "$(row beta)"
eq "unreadable panel: kept as evidence"          yes "$([ -s "$HIVE_DIR/usage-panel-beta.txt" ] && echo yes || echo no)"

: > "$FAKE_PANELS/alpha.noprompt"
HIVE_USAGE_TIMEOUT=2 run "$HIVE" accounts --refresh
has "a Claude Code that never starts: bounded by the timeout" "accounts: alpha: claude did not start in 2s" "$ERR"
eq "a Claude Code that never starts: its session is killed too" "$(sessions)" "$(kills)"
rm -f "$FAKE_PANELS/alpha.noprompt"

# a credentials file with a dead token: Claude Code opens on the login selector, whose cursor is a ❯ too
typed_into_alpha() { grep -c -- '-alpha /usage$' "$FAKE_TMUX_DIR/log" || true; }
: > "$FAKE_PANELS/alpha.login"
n=$(typed_into_alpha)
run "$HIVE" accounts --refresh
like "a logged-out account is UNAVAILABLE, not a timeout" "^alpha .* UNAVAILABLE: account 'alpha' is logged out \(Claude Code opens on the login screen\)" "$(row alpha)"
eq "nothing is typed into the login selector"    "$n" "$(typed_into_alpha)"
hasnt "a logged-out account is not reported as a missing panel" "no /usage panel" "$ERR"
run "$HIVE" accounts --pick
like "a logged-out account is never picked"      '^default — ' "$OUT"
rm -f "$FAKE_PANELS/alpha.login"

run "$HIVE" usage --account ghost --cwd "$HOME"
eq "hive usage on an account that is not logged in: fails" 1 "$RC"
eq "hive usage on an account that is not logged in: nothing on stdout" "" "$OUT"
has "hive usage on an account that is not logged in: says why" "account 'ghost' is not logged in" "$ERR"
run "$HIVE" usage --account alpha --cwd "$T/nowhere"
eq "hive usage in a missing directory: nothing on stdout" "" "$OUT"
has "hive usage in a missing directory: says why" "no such directory: $T/nowhere" "$ERR"

# sessions a SIGKILLed hive left behind: no trap ran, so the next measurement sweeps them
( exit 0 ) & dead=$!; wait "$dead"
echo alpha > "$FAKE_TMUX_DIR/hive-usage-$dead-alpha.account"    # its hive is gone
echo beta  > "$FAKE_TMUX_DIR/hive-usage-$$-beta.account"        # its hive is alive (this script's pid)
echo alpha > "$FAKE_TMUX_DIR/hive-usage-$dead.account"          # the naming of the old hive usage: not ours to judge
run "$HIVE" accounts --refresh
eq "a session orphaned by a dead hive is swept"  1 "$(grep -c -- "^kill hive-usage-$dead-alpha\$" "$FAKE_TMUX_DIR/log")"
eq "a session of a live hive is left alone"      0 "$(grep -c -- "^kill hive-usage-$$-beta\$" "$FAKE_TMUX_DIR/log")"
eq "a session with the old naming is left alone" 0 "$(grep -c -- "^kill hive-usage-$dead\$" "$FAKE_TMUX_DIR/log")"

# tmux matches a bare target by prefix. The session of account "ab" never comes up, and while "abc"
# is still being measured the clean-up of "ab" fires: it must not reach into the session of "abc".
world
account_home ab ab@example.com; account_home abc abc@example.com
conf <<'EOF'
account abc  prio=1
account ab   prio=2
EOF
panel 11 "$SESSION_IN_2H" 12 "$WEEK_IN_3D" > "$FAKE_PANELS/abc.txt"
: > "$FAKE_PANELS/ab.nosession"
run "$HIVE" accounts --refresh
like "an account whose name is a prefix of another: abc is measured" '^abc .* 11% .* 12% ' "$(row abc)"
like "an account whose name is a prefix of another: ab failed on its own" '^ab .* no data — measurement failed' "$(row ab)"
eq "the session of abc is killed once, when its own measurement ends" 1 "$(kills)"

# A named account gets $HOME pre-trusted by the measurement itself. The default account has trusted
# it only if a drone was ever spawned there — on a machine where none was, the measurement trusts it.
world
conf <<'EOF'
account default prio=1
EOF
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"owner@example.com"}}\n' > "$HOME/.claude.json"
panel 3 "$SESSION_IN_2H" 4 "$WEEK_IN_3D" > "$FAKE_PANELS/default.txt"
run "$HIVE" accounts --refresh
eq "the default account: \$HOME is trusted before its first measurement" True \
   "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('projects',{}).get(sys.argv[2],{}).get('hasTrustDialogAccepted'))" "$HOME/.claude.json" "$(cd "$HOME" && pwd)")"
like "the default account: measured, the rest of its config kept" '^default +claude +1 +week 90% +owner@example.com +3% .* 4% ' "$(row default)"

# =============================================================================
section "selection on a stale cache — measure first, then pick"
world; three
panel 100 "$SESSION_IN_2H" 10 "$WEEK_IN_3D" > "$FAKE_PANELS/alpha.txt"
panel 10 "$SESSION_IN_2H" 10 "$WEEK_IN_3D"  > "$FAKE_PANELS/beta.txt"
panel 0 - 5 "$WEEK_IN_3D"                   > "$FAKE_PANELS/default.txt"
cache alpha:1200:5:3600:5:432000 beta:1200:5:3600:5:432000 default:1200:5:3600:5:432000
run "$HIVE" accounts --pick
eq "stale cache: all three accounts are re-measured" 3 "$(sessions)"
like "stale cache: the pick follows the new numbers, not the old ones" '^beta — prio 2, session 10%, week 10%.*passed over: alpha \(UNAVAILABLE: session 100%\)$' "$OUT"
run "$HIVE" accounts --pick
eq "the next pick finds the cache fresh"         3 "$(sessions)"

world; three
cache alpha:1200:5:3600:5:432000 beta:1200:5:3600:5:432000 default:1200:5:3600:5:432000
( "$HIVE" accounts --pick >/dev/null 2>&1 & "$HIVE" accounts --pick >/dev/null 2>&1 & wait )
eq "two picks at once on a stale cache measure once" 3 "$(sessions)"

world; three
: > "$FAKE_PANELS/alpha.noprompt"
panel 10 "$SESSION_IN_2H" 10 "$WEEK_IN_3D" > "$FAKE_PANELS/beta.txt"
panel 0 - 5 "$WEEK_IN_3D"                  > "$FAKE_PANELS/default.txt"
HIVE_USAGE_TIMEOUT=2 run "$HIVE" accounts --pick
like "an account that cannot be measured is passed over for a measured one" '^beta — prio 2, .*passed over: alpha \(no fresh usage data\)$' "$OUT"
n=$(sessions)
HIVE_USAGE_TIMEOUT=2 run "$HIVE" accounts --pick
eq "a failed measurement is not retried before max_age" "$n" "$(sessions)"

world; three
for a in alpha beta default; do : > "$FAKE_PANELS/$a.noprompt"; done
HIVE_USAGE_TIMEOUT=2 run "$HIVE" accounts --pick
like "nothing can be measured: the first by prio, blind and said so" '^alpha — BLIND — no fresh usage data: no data — measurement failed: claude did not start in 2s; prio 1$' "$OUT"

world; three
for a in alpha beta default; do : > "$FAKE_PANELS/$a.noprompt"; done
cache alpha:1200:10:3600:100:172800 beta:1200:10:3600:10:432000 default:1200:10:3600:10:432000
HIVE_USAGE_TIMEOUT=2 run "$HIVE" accounts --pick
like "a stale 'full' is still full; a stale 'available' is taken blind" '^beta — BLIND — no fresh usage data: last measured 20 min ago \(session 10%, week 10%\); prio 2; passed over: alpha \(UNAVAILABLE: week 100%\)$' "$OUT"

# When no measurement succeeds (a Claude Code update changed the panel, tmux is gone) the pick falls
# back on the stored numbers — and the table must mark the very account the pick takes.
agree() {  # agree <description> — 'hive accounts --pick' and the table's SELECTED name the same account
  local picked
  run "$HIVE" accounts --pick; picked="${OUT%% *}"
  run "$HIVE" accounts
  eq "$1: the table marks the account the pick takes" "$picked" "$(grep 'SELECTED' <<<"$OUT" | awk '{print $1}')"
}
export HIVE_USAGE_TIMEOUT=2
world; three
for a in alpha beta default; do : > "$FAKE_PANELS/$a.noprompt"; done
cache alpha:1200:57:14400:98:500000 beta:1200:100:9000:11:500000 default:1200:2:14400:11:500000
run "$HIVE" accounts --pick
eq "no measurement succeeds: an account last seen over its threshold goes behind one last seen under it" \
   "default — BLIND — no fresh usage data: last measured 20 min ago (session 2%, week 11%); prio 3; passed over: alpha (over threshold: week, stale), beta (UNAVAILABLE: session 100%)" "$OUT"
agree "no measurement succeeds"

world; three
for a in alpha beta default; do : > "$FAKE_PANELS/$a.noprompt"; done
cache alpha:1200:10:14400:95:500000 beta:1200:10:14400:91:500000 default:1200:100:14400:10:500000
run "$HIVE" accounts --pick
like "no measurement succeeds, every account last seen over its threshold: the first by prio" \
     '^alpha — BLIND — no fresh usage data: last measured 20 min ago \(session 10%, week 95%\); prio 1$' "$OUT"
agree "every account last seen over its threshold"

world; three
for a in alpha beta default; do : > "$FAKE_PANELS/$a.noprompt"; done
cache beta:1200:10:14400:10:500000 default:1200:10:14400:10:500000
run "$HIVE" accounts --pick
like "no measurement succeeds: a never-measured account keeps its priority over ones last seen under their threshold" '^alpha — BLIND — no fresh usage data: no data' "$OUT"
agree "a never-measured account next to old measurements"

world; three
: > "$FAKE_PANELS/alpha.noprompt"
panel 10 "$SESSION_IN_2H" 10 "$WEEK_IN_3D" > "$FAKE_PANELS/beta.txt"
panel 0 - 5 "$WEEK_IN_3D"                  > "$FAKE_PANELS/default.txt"
cache alpha:1200:5:14400:5:500000 beta:1200:5:14400:5:500000 default:1200:5:14400:5:500000
run "$HIVE" accounts --pick
like "one account fails to measure: a fresh measurement beats its old one, whatever the prio" '^beta — prio 2, session 10%, week 10%.*passed over: alpha \(no fresh usage data\)$' "$OUT"
agree "old and fresh measurements side by side"

world; three
cache alpha:60:10:3600:95:432000 beta:60:30:3600:40:432000 default:60:0:-:0:432000
agree "fresh measurements"
export HIVE_USAGE_TIMEOUT=5

world; three
for a in alpha beta default; do : > "$FAKE_PANELS/$a.noprompt"; done
mkdir "$T/tmp"
HIVE_USAGE_TIMEOUT=30 TMPDIR="$T/tmp" setsid "$HIVE" accounts --refresh >/dev/null 2>&1 &
victim=$!
for _ in $(seq 1 50); do [ "$(sessions)" = 3 ] && break; sleep 0.1; done
kill -TERM -- "-$victim" 2>/dev/null; wait "$victim" 2>/dev/null
for _ in $(seq 1 30); do [ "$(kills)" = 3 ] && break; sleep 0.1; done
eq "a hive killed mid-measurement started three sessions" 3 "$(sessions)"
eq "a hive killed mid-measurement leaves no session behind" 3 "$(kills)"
eq "a hive killed mid-measurement leaves no temp files"  0 "$(find "$T/tmp" -mindepth 1 | wc -l)"

# =============================================================================
section "spawn and revive (stand-in herdr)"
world
spawned() { grep -c '^workspace create' "$FAKE_HERDR_LOG" || true; }
last_create() { grep '^workspace create' "$FAKE_HERDR_LOG" | tail -1; }

run "$HIVE" spawn d0
eq "no accounts.conf: spawn works as before"     0 "$RC"
eq "no accounts.conf: default account"           default "$(meta_account d0)"
hasnt "no accounts.conf: no CLAUDE_CONFIG_DIR for the drone" "CLAUDE_CONFIG_DIR" "$(last_create)"
hasnt "no accounts.conf: no selection line"      "spawn: account" "$OUT"
eq "no accounts.conf: nothing measured"          0 "$(sessions)"

three; cache alpha:60:10:3600:20:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" spawn d1
has "spawn: says which account and why"          "spawn: account alpha — prio 1, session 10%, week 20%, under its threshold (week 90%)" "$OUT"
eq "spawn: the drone is recorded on the picked account" alpha "$(meta_account d1)"
has "spawn: the drone gets the picked account's config dir" "--env CLAUDE_CONFIG_DIR=$HOME/.claude-alpha" "$(last_create)"
has "spawn: the summary line names the account"  "account=alpha" "$OUT"

run "$HIVE" spawn d2 --account beta
eq "--account wins over the selection"           beta "$(meta_account d2)"
hasnt "--account: no selection line"             "spawn: account" "$OUT"

HIVE_ACCOUNT=beta run "$HIVE" spawn d3
eq "HIVE_ACCOUNT wins over the selection"        beta "$(meta_account d3)"
HIVE_ACCOUNT=default run "$HIVE" spawn d4
eq "HIVE_ACCOUNT=default pins the default account" default "$(meta_account d4)"
hasnt "HIVE_ACCOUNT=default: no CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR" "$(last_create)"

cache alpha:60:10:3600:95:432000 beta:60:100:3600:0:432000 default:60:0:-:0:432000
run "$HIVE" spawn d5
has "spawn: picked 'default' is the default account" "spawn: account default — prio 3" "$OUT"
eq "spawn on default: recorded as default"       default "$(meta_account d5)"
hasnt "spawn on default: no CLAUDE_CONFIG_DIR"   "CLAUDE_CONFIG_DIR" "$(last_create)"

cache alpha:60:10:3600:100:432000 beta:60:100:3600:0:432000 default:60:100:3600:0:432000
n=$(spawned)
run "$HIVE" spawn d6
eq "nothing selectable: spawn is refused"        1 "$RC"
has "nothing selectable: spawn says nothing started" "spawn: no account for d6 — nothing started" "$ERR"
# the cache above puts the resets exactly 5 days and 1 hour ahead, so the clock may tick over between the two
like "nothing selectable: spawn says which account resets when" 'alpha: UNAVAILABLE: week 100% — room again [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in (5d0h|4d23h)\)' "$ERR"
like "nothing selectable: spawn names the first account to get room" 'First to get room: beta, [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2} \(in (1h00m|59m)\)\.' "$ERR"
eq "nothing selectable: no workspace is created" "$n" "$(spawned)"
eq "nothing selectable: no drone is recorded"    no "$([ -e "$HIVE_DIR/drones/d6/meta.json" ] && echo yes || echo no)"
run "$HIVE" spawn d6 --account alpha
eq "nothing selectable: --account still forces one" alpha "$(meta_account d6)"

panel 100 "$SESSION_IN_2H" 10 "$WEEK_IN_3D" > "$FAKE_PANELS/alpha.txt"
panel 10 "$SESSION_IN_2H" 10 "$WEEK_IN_3D"  > "$FAKE_PANELS/beta.txt"
panel 0 - 5 "$WEEK_IN_3D"                   > "$FAKE_PANELS/default.txt"
cache alpha:1200:5:3600:5:432000 beta:1200:5:3600:5:432000 default:1200:5:3600:5:432000
run "$HIVE" spawn d7
eq "spawn on a stale cache measures first"       3 "$(sessions)"
has "spawn on a stale cache: says it measures"   "accounts: measuring alpha beta default" "$ERR"
eq "spawn on a stale cache: lands by the new numbers" beta "$(meta_account d7)"

# revive: d1 lives on alpha; its transcript sits in the shared projects/.
# The rule: a drone keeps its account for as long as that account has room, and moves only off one
# that is over its threshold, full, unusable or disabled.
sid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['session_id'])" "$HIVE_DIR/drones/d1/meta.json")
mkdir -p "$HOME/.claude/projects/-home" && : > "$HOME/.claude/projects/-home/$sid.jsonl"
revive_line() { grep '^revive:' <<<"$OUT" || true; }

cache alpha:60:10:3600:20:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
eq "revive: an account with room keeps its drone" "revive: d1 stays on alpha — session 10%, week 20%, under its threshold (week 90%)" "$(revive_line)"
eq "revive stays: still alpha"                   alpha "$(meta_account d1)"
has "revive resumes the session"                 "--resume $sid" "$(grep '^agent start' "$FAKE_HERDR_LOG" | tail -1)"

run "$HIVE" revive d1 --account beta
eq "revive --account wins over the selection"    beta "$(meta_account d1)"
eq "revive --account: no selection line"         "" "$(revive_line)"

cache alpha:60:0:-:0:432000 beta:60:5:3600:5:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
eq "revive: a better priority elsewhere does not move a drone whose account has room" \
   "revive: d1 stays on beta — session 5%, week 5%, under its threshold (week 90%)" "$(revive_line)"
eq "revive stays: still beta"                    beta "$(meta_account d1)"

cache alpha:60:0:-:0:432000 beta:60:100:3600:5:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
eq "revive: off a full account, and says why" \
   "revive: d1 moves beta -> alpha — beta has no room (UNAVAILABLE: session 100%); alpha: prio 1, session 0%, week 0%, under its threshold (week 90%)" "$(revive_line)"
eq "revive moves: now on alpha"                  alpha "$(meta_account d1)"
has "revive moves: the drone gets alpha's config dir" "--env CLAUDE_CONFIG_DIR=$HOME/.claude-alpha" "$(last_create)"

cache alpha:60:0:-:95:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
has "revive: off an account over its threshold"  "revive: d1 moves alpha -> beta — alpha has no room (over threshold: week); beta: prio 2" "$(revive_line)"
eq "revive off an over-threshold account: on beta" beta "$(meta_account d1)"

cache alpha:60:0:-:0:432000 beta:60:99:3600:10:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
eq "revive: a session at 99% is not a reason to move — the threshold is weekly" \
   "revive: d1 stays on beta — session 99%, week 10%, under its threshold (week 90%)" "$(revive_line)"

cache alpha:60:100:3600:0:432000 beta:60:0:-:95:432000 default:60:100:3600:0:432000
run "$HIVE" revive d1
has "revive: over its threshold with nowhere better to go, the drone stays as the last resort" \
    "revive: d1 stays on beta — LAST RESORT — no account is under its threshold; prio 2" "$(revive_line)"
eq "revive last resort: still beta"              beta "$(meta_account d1)"

: > "$FAKE_PANELS/beta.noprompt"
cache alpha:60:0:-:0:432000 default:60:0:-:0:432000
HIVE_USAGE_TIMEOUT=2 run "$HIVE" revive d1
has "revive: an account that could not be measured keeps its drone" \
    "revive: d1 stays on beta — no data — measurement failed: claude did not start in 2s" "$(revive_line)"
rm -f "$FAKE_PANELS/beta.noprompt"

run "$HIVE" revive d1 --account gamma
cache alpha:60:0:-:0:432000 beta:60:0:-:0:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
eq "revive: an account outside accounts.conf keeps its drone" "revive: d1 stays on gamma — gamma is not in accounts.conf" "$(revive_line)"
eq "revive outside accounts.conf: still gamma"   gamma "$(meta_account d1)"

HIVE_ACCOUNT=beta run "$HIVE" revive d1
eq "revive with HIVE_ACCOUNT pinned: stays where it ran" gamma "$(meta_account d1)"
eq "revive with HIVE_ACCOUNT pinned: no selection" "" "$(revive_line)"

run "$HIVE" spawn d1 --resume
eq "spawn --resume by hand stays on the recorded account" gamma "$(meta_account d1)"

three; echo "account gamma prio=4 disabled" >> "$HIVE_DIR/accounts.conf"
run "$HIVE" revive d1
has "revive: off a disabled account"             "revive: d1 moves gamma -> alpha — gamma has no room (disabled); alpha: prio 1" "$(revive_line)"
three

# alpha keeps its own projects/ and cannot see the transcript; a drone leaving beta must not land there
run "$HIVE" revive d1 --account beta
rm "$HOME/.claude-alpha/projects" && mkdir "$HOME/.claude-alpha/projects"
cache alpha:60:0:-:0:432000 beta:60:100:3600:0:432000 default:60:0:-:0:432000
run "$HIVE" revive d1
has "revive: an account that cannot see the transcript is passed over" \
    "revive: d1 moves beta -> default — beta has no room (UNAVAILABLE: session 100%); default: prio 3" "$(revive_line)"
has "revive: and the reason says so"             "alpha does not see session $sid" "$(revive_line)"
eq "revive past a blind account: on default"     default "$(meta_account d1)"

cache alpha:60:0:-:0:432000 beta:60:100:3600:0:432000 default:60:100:3600:0:432000
n=$(grep -c '^workspace close' "$FAKE_HERDR_LOG")
run "$HIVE" revive d1
eq "revive: no account can take the drone — refused" 1 "$RC"
has "revive refused: says nothing was closed"    "revive: no account for d1 — nothing closed" "$ERR"
has "revive refused: names the way out"          "hive revive d1 --account default" "$ERR"
eq "revive refused: the workspace is not closed" "$n" "$(grep -c '^workspace close' "$FAKE_HERDR_LOG")"
eq "revive refused: the drone stays recorded where it was" default "$(meta_account d1)"

conf <<'EOF'
account alpha prio=first
EOF
n=$(spawned)
run "$HIVE" spawn d8
eq "broken accounts.conf: spawn is refused"      1 "$RC"
eq "broken accounts.conf: reported once"         1 "$(grep -c 'is broken' <<<"$ERR")"
eq "broken accounts.conf: no workspace is created" "$n" "$(spawned)"
run "$HIVE" spawn d8 --account beta
eq "broken accounts.conf: --account still spawns" beta "$(meta_account d8)"

# =============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
