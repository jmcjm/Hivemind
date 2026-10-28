#!/usr/bin/env bash
# tests/clickup/test-clickup.sh [skill-dir] — ClickUp task tracking: off without a config, the
# taxonomy, 'hive ct' (find, new, show, set, check, apply, stale, todo, sync, ack), the 'hive task'
# gate with its collisions, clickup-sync applying reports, drone-ping's subject, 'hive move', and the
# API token never reaching argv, a letter or a log.
# Nothing real runs: curl is a small ClickUp API over files (fake-bin/curl), herdr and notify-send are
# the tests/ctx stand-ins. HOME, HIVE_DIR and TMPDIR are throwaway directories. The scripts under test
# (default: the repo's skill/) are COPIED into a throwaway skill directory.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="$(readlink -f "${1:-$HERE/../../skill}")"
T="$(mktemp -d)"; ERRF="$(mktemp)"
trap 'rm -rf "$T" "$ERRF"' EXIT

SK="$T/skill"; mkdir -p "$SK"
for f in hive clickup.sh clickup-sync.sh coord-scope.sh drone-ping.sh; do
  cp "$SRC/$f" "$SK/$f" || { echo "missing: $SRC/$f" >&2; exit 2; }
done
chmod +x "$SK"/hive "$SK"/*.sh
HIVE="$SK/hive"
echo "testing: $SRC"

export TZ=UTC
export HOME="$T/home" HIVE_DIR="$T/hive" TMPDIR="$T/tmp" FAKE_CU="$T/cu" FAKE_PANES="$T/panes" FAKE_HERDR_LOG="$T/herdr.log"
export HIVE_RULES_DIR="$T/rules" HIVE_COORD_DIR="$T/coord"
export PATH="$HERE/fake-bin:$HERE/../ctx/fake-bin:$PATH"
unset HIVE_DRONE HIVE_FRONT HERDR_PANE_ID HIVE_ACCOUNT CLAUDE_CONFIG_DIR FAKE_CURRENT_PANE HIVE_NO_CLICKUP HIVE_NO_RULES HIVE_WATCH_ALL KIND
mkdir -p "$HOME/.claude/skills" "$HIVE_DIR/fronts/web/drones" "$TMPDIR" "$FAKE_CU/tasks" "$FAKE_CU/comments" "$FAKE_PANES" "$HIVE_RULES_DIR"
ln -s "$SK" "$HOME/.claude/skills/hivemind"   # drone-ping.sh calls hive at its installed path
touch "$FAKE_CU/requests.log"
CU="$HIVE_DIR/clickup"

# --- assertions -------------------------------------------------------------
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing:  $2" "in:       $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "unwanted: $2" "in:       $3" ;; *) ok "$1" ;; esac; }
section() { printf '\n%s\n' "$1"; }
run() { OUT=$("$@" 2>"$ERRF"); RC=$?; ERR=$(cat "$ERRF"); }

# --- the fake ClickUp -------------------------------------------------------
cat > "$FAKE_CU/statuses.json" <<'EOF'
[{"status":"backlog","type":"open"},{"status":"ready","type":"custom"},{"status":"in progress","type":"custom"},
 {"status":"in review","type":"custom"},{"status":"testing","type":"custom"},{"status":"on hold","type":"custom"},
 {"status":"done","type":"closed"},{"status":"cancelled","type":"closed"}]
EOF
echo '[{"name":"mod-api"}]' > "$FAKE_CU/space-tags.json"
printf 'pk_fake_SECRET_TOKEN\n' > "$T/token"; chmod 600 "$T/token"
mktask() {  # mktask <id> <status> <tags,comma> <name> [parent]
  local st; st=$(jq -c --arg s "$2" '.[] | select(.status == $s)' "$FAKE_CU/statuses.json")
  jq -n --arg id "$1" --argjson st "$st" --arg tags "$3" --arg n "$4" --arg p "${5:-}" --arg du "$(( $(date +%s) * 1000 ))" \
    '{id: $id, name: $n, url: ("https://app.clickup.com/t/" + $id), status: $st, list: {id: "9012345678"},
      tags: [$tags | split(",")[] | select(. != "") | {name: .}], parent: (if $p == "" then null else $p end),
      text_content: "Description of \($id)", date_updated: $du}' > "$FAKE_CU/tasks/$1.json"
}
task_field() { jq -r "$2" "$FAKE_CU/tasks/$1.json"; }
tags_of() { jq -r '[.tags[].name] | sort | join(",")' "$FAKE_CU/tasks/$1.json"; }
comments_of() { jq -r '.[].comment_text' "$FAKE_CU/comments/$1.json" 2>/dev/null; }
ncomments() { jq 'length' "$FAKE_CU/comments/$1.json" 2>/dev/null || echo 0; }
nrequests() { wc -l < "$FAKE_CU/requests.log" 2>/dev/null || echo 0; }
writes() { grep -cE '^(POST|PUT|DELETE) ' "$FAKE_CU/requests.log"; }
subjects() {  # subjects [front] — the subjects of the coordinator's letters
  local d="$HIVE_DIR"; [ -n "${1:-}" ] && d="$HIVE_DIR/fronts/$1"
  cat "$d"/mail/coord/*.json 2>/dev/null | jq -r '.subject'
}
mkdrone() {  # mkdrone <name> <pane> <status|dead> [front]
  local d="$HIVE_DIR"; [ -n "${4:-}" ] && d="$HIVE_DIR/fronts/$4"
  mkdir -p "$d/drones/$1"
  jq -n --arg n "$1" --arg p "$2" '{name: $n, pane_id: $p, session_id: "sid-\($n)", cwd: "/tmp"}' > "$d/drones/$1/meta.json"
  if [ "$3" = dead ]; then rm -f "$FAKE_PANES/$2.status"; else echo "$3" > "$FAKE_PANES/$2.status"; fi
}
meta_of() { jq -r ".$2 // empty" "$HIVE_DIR/drones/$1/meta.json"; }
brief() {  # brief <file> <lines...> — with a boundaries section
  local f=$1; shift
  { printf '%s\n' "$@"; printf '\n## Boundaries\n- test only\n'; } > "$f"
}
report() {  # report <drone> <lines...> — the drone's report, a second newer than the last one
  local f="$HIVE_DIR/drones/$1/report.md"; shift
  printf '%s\n' "$@" > "$f"
  touch -d "@$(( ${RSEQ:-$(date +%s)} ))" "$f"; RSEQ=$(( ${RSEQ:-$(date +%s)} + 1 ))
}
sync_now() { bash "$SK/clickup-sync.sh"; }
queue_start() {  # queue_start <task> <drone> <at> [modules] — a start record as cu_started queues it
  mkdir -p "$CU/starts"
  jq -n --arg t "$1" --arg d "$2" --arg at "$3" --arg m "${4:-}" \
    '{drone: $d, front: "default", task: $t, title: "Queued", modules: $m, impact: "", settled: "", at: $at}' > "$CU/starts/$3.test.json"
}
nstarts() { find "$CU/starts" -maxdepth 1 -name '*.json' ! -name '.*' | wc -l; }

# =============================================================================
section "tracking off: no config, no ClickUp"
mkdrone d0 p0 working
brief "$T/b0" "# Plain task" "Do the thing."
run "$HIVE" task d0 "$T/b0"
eq "a brief without a ClickUp line is accepted" 0 "$RC"
hasnt "and its protocol has no ClickUp section" "## ClickUp" "$(cat "$HIVE_DIR/drones/d0/brief.md")"
eq "no ClickUp call" 0 "$(nrequests)"
run "$HIVE" ct find something
eq "'hive ct' says tracking is off" 1 "$RC"
has "and why" "ClickUp tracking is off" "$ERR"
run bash "$SK/clickup-sync.sh"
eq "clickup-sync is a no-op" "0 0" "$RC $(nrequests)"
mkdir -p "$HIVE_DIR/drones/d0"; printf 'STATUS: DONE\n## Result\nok\n' > "$HIVE_DIR/drones/d0/report.md"
HIVE_DRONE=d0 bash "$SK/drone-ping.sh" done </dev/null
has "drone-ping sends the plain end-of-turn letter" "finished a turn (report: DONE)" "$(subjects)"
hasnt "without a word about ClickUp" "ClickUp" "$(subjects)"

# --- turn tracking on ---------------------------------------------------------
mkdir -p "$CU"
cat > "$CU/config" <<EOF
# test config
workspace = 1234567
space = 7654321
list = 9012345678
token_cmd = cat $T/token
status_early = backlog | ready
status_active = ready | in progress | in review | testing
status_closed = done | cancelled
status_start = in progress
status_done = done
status_unverified = testing
verify_exempt = type-analysis
stale_hold = on hold | backlog
stale_hold_to = cancelled
stale_human_tags = human
alias_modules = Components
alias_impact = Effect
alias_none = nothing
alias_collision = Clash checked
EOF
cat > "$CU/taxonomy.tsv" <<'EOF'
# test taxonomy
kind	tag	definition	epic	default front
front	front-default	default front		default
front	front-web	web front		web
module	mod-api	the API		default
module	mod-web	the web app		web
module	mod-db	the database		default
module	mod-infra	infrastructure		default
module	mod-docs	documentation		default
module	mod-cache	the cache		default
area	area-billing	billing	epbill1	default
area	area-search	search		web
area	area-other	other		default
type	type-analysis	an analysis
EOF
mktask epbill1 "in progress" "front-default,area-billing,mod-api" "Billing epic"
mktask tinv001 "in progress" "front-default,area-billing,mod-api" "Invoices: rounding of totals" epbill1
mktask tinv002 ready "front-default,area-billing,mod-db" "Invoices: archive table" epbill1
mktask tref001 backlog "front-default,area-billing,mod-api" "Refunds: partial refund flow"
mktask told001 done "front-default,area-billing,mod-api" "Refunds: old rounding bug"
mktask tsrch01 "in review" "front-web,area-search,mod-web,mod-api" "Search: ranking of new products"
mktask thold01 "on hold" "front-default,area-other,mod-db" "Database: vacuum schedule"
mktask ttwo001 backlog "front-default,area-billing,area-other,mod-db" "Task with two areas"
mktask tsub001 ready "front-default,area-billing,mod-db" "Invoices: rounding subtask" tref001
mktask tana001 backlog "front-default,area-other,mod-infra,type-analysis" "Analysis: cluster costs"

# =============================================================================
section "config"
cp "$CU/config" "$T/config.good"
printf 'pk_fake_SECRET_TOKEN\n' > "$T/tok="
grep -v '^token_cmd' "$T/config.good" > "$CU/config"; echo "token_cmd = cat $T/tok=" >> "$CU/config"
run "$HIVE" ct show tinv001
eq "a value ending in '=' keeps it" 0 "$RC"
grep -v '^space' "$T/config.good" > "$CU/config"
mkdrone d0c p0c working
brief "$T/b0c" "# No space" "ClickUp: tref001" "Modules: api" "Impact: none"
run "$HIVE" task d0c "$T/b0c"
eq "a config without a key refuses the brief" 1 "$RC"
has "saying which key" "has no 'space'" "$ERR"
eq "and leaves no staged brief" no "$([ -e "$HIVE_DIR/drones/d0c/.brief.staged" ] && echo yes || echo no)"
cp "$T/config.good" "$CU/config"; rm -f "$FAKE_PANES/p0c.status"

# =============================================================================
section "taxonomy: only known tags"
run "$HIVE" ct new --area billing --module apii --name "Something new"
eq "a typo in a module is refused" 1 "$RC"
has "with the known modules" "known: api web db infra" "$ERR"
run "$HIVE" ct new --area bliling --module api --name "Something new"
has "a typo in an area too" "'bliling' is no area of the taxonomy" "$ERR"
run "$HIVE" ct find refunds --front nosuch
eq "and an unknown front" 1 "$RC"
eq "nothing was created or written" 0 "$(writes)"

# =============================================================================
section "ct find"
run "$HIVE" ct find rounding
eq "find succeeds" 0 "$RC"
has "an open task whose name holds the words" "tinv001" "$OUT"
hasnt "a closed one is left out" "told001" "$OUT"
run "$HIVE" ct find rounding --closed
has "--closed adds those closed in the last 30 days" "told001" "$OUT"
run "$HIVE" ct find rounding --module db
has "--module narrows to a module" "tsub001" "$OUT"
hasnt "and drops the others" "tinv001 " "$OUT"
run "$HIVE" ct find ranking products --front web --area search
has "--front and --area narrow too" "tsrch01" "$OUT"
run "$HIVE" ct find ranking --front default
eq "a front without such tasks" "no candidates" "$OUT"
eq "the cache is written" 1 "$(grep -c '^tsrch01' "$CU/registry.tsv")"
n=$(nrequests); run "$HIVE" ct find rounding
eq "a fresh cache is searched without asking ClickUp" "$n" "$(nrequests)"
touch -d '-1 hour' "$CU/registry.tsv"; touch "$FAKE_CU/down"
run "$HIVE" ct find rounding
eq "ClickUp down: a stale cache is searched all the same" "0" "$RC"
has "finding what it holds" "tinv001" "$OUT"
has "with a warning" "using the cache" "$ERR"
rm -f "$FAKE_CU/down"

# =============================================================================
section "ct new"
run "$HIVE" ct new --area billing --module api --name "Refunds: partial refund flow for vouchers"
eq "a look-alike in the same area is refused" 1 "$RC"
has "and listed" "tref001" "$ERR"
run "$HIVE" ct new --area other --module db --name "Invoices archive table cleanup"
has "a look-alike sharing a module (another area) too" "tinv002" "$ERR"
w=$(writes)
run "$HIVE" ct new --area billing --module api,db --name "Refunds: partial refund flow for vouchers" --not-dup tref001,told001
eq "--not-dup creates it" 0 "$RC"
NEW=$(sed -n 's/^new: \([^ ]*\).*/\1/p' <<<"$OUT")
eq "with the caller's front, the area and the modules" "area-billing,front-default,mod-api,mod-db" "$(tags_of "$NEW")"
has "the checked ids go into a comment" "not duplicates of this task: tref001, told001" "$(comments_of "$NEW")"
has "the area's epic is suggested" "hive ct set $NEW --parent epbill1" "$OUT"
run env HIVE_FRONT=web "$HIVE" ct new --area search --module web --name "Search: typo tolerance" --type analysis --status ready
NEWW=$(sed -n 's/^new: \([^ ]*\).*/\1/p' <<<"$OUT")
eq "a coordinator of front web creates in front web, with a type and a status" "area-search,front-web,mod-web,type-analysis ready" "$(tags_of "$NEWW") $(task_field "$NEWW" .status.status)"
has "missing tags are created in the space" "front-web" "$(jq -r '.[].name' "$FAKE_CU/space-tags.json")"
eq "coloured by kind" "#fb8c00" "$(jq -r '.[] | select(.name == "area-search") | .tag_bg' "$FAKE_CU/space-tags.json")"
run "$HIVE" ct new --area billing --module api --name "Totally new thing" --status nosuch
eq "a status the list does not have is refused" 1 "$RC"
rm -f "$FAKE_CU/tasks/$NEWW.json"   # out of the way of the collisions below

# =============================================================================
section "ct show"
mktask tshow01 "in review" "front-default,area-billing,mod-api,urgent" "Show me"
printf '[{"comment_text":"🤖 [drone x, front default] STATUS: DONE → in review\\nPR: https://example.com/pr/7\\nhive-report:x:1","date":"1700000000000","user":{"username":"tester"}}]' > "$FAKE_CU/comments/tshow01.json"
run "$HIVE" ct show tshow01
has "status" "status:  in review" "$OUT"
has "tags by kind" "module:  api" "$OUT"
has "tags outside the taxonomy apart" "other:   urgent" "$OUT"
has "the PRs from the report comments" "https://example.com/pr/7" "$OUT"
run "$HIVE" ct show tnone01
eq "an unknown task fails" 1 "$RC"
rm -f "$FAKE_CU/tasks/tshow01.json"

# =============================================================================
section "ct set"
mktask tset001 backlog "front-default,area-billing,mod-api" "Settable"
run "$HIVE" ct set tset001 --status ready --comment "a note" --area other --module +db,-api --parent epbill1
eq "set succeeds" 0 "$RC"
eq "status, area, modules and parent" "ready area-other,front-default,mod-db epbill1" \
  "$(task_field tset001 .status.status) $(tags_of tset001) $(task_field tset001 .parent)"
has "and the comment" "a note" "$(comments_of tset001)"
run "$HIVE" ct set tset001 --comment "a note"
eq "the same comment is not added twice" 1 "$(ncomments tset001)"
echo 1 > "$FAKE_CU/lost"
run "$HIVE" ct set tset001 --comment "landed once"
eq "a comment whose answer was lost (500) is not posted again on the retry" "0 1" "$RC $(comments_of tset001 | grep -c 'landed once')"
run "$HIVE" ct set tset001 --type analysis
has "--type sets the type" "type-analysis" "$(tags_of tset001)"
run "$HIVE" ct set tset001 --type none
hasnt "--type none removes it" "type-analysis" "$(tags_of tset001)"
run "$HIVE" ct set tset001 --front web
has "--front hands the task over" "front-web" "$(tags_of tset001)"
hasnt "leaving one front" "front-default" "$(tags_of tset001)"
has "with a comment saying so" "handed over from front-default to front-web" "$(comments_of tset001)"
run "$HIVE" ct set tset001 --module +nosuch
eq "a typo in --module changes nothing" "1 area-other,front-web,mod-db" "$RC $(tags_of tset001)"
rm -f "$FAKE_CU/tasks/tset001.json"

# =============================================================================
section "ct check: collisions"
run "$HIVE" ct check --module api
eq "a collision exits 1" 1 "$RC"
has "a task in progress sharing the module" "tinv001" "$OUT"
has "one in another front too" "tsrch01" "$OUT"
hasnt "an epic (a task with subtasks) never collides" "epbill1" "$OUT"
hasnt "a backlog task does not" "tref001" "$OUT"
run "$HIVE" ct check --module db
has "a ready task collides" "tinv002" "$OUT"
hasnt "an on-hold one does not" "thold01" "$OUT"
run "$HIVE" ct check --module infra
eq "no collision exits 0" "0 check: no collisions in infra" "$RC $OUT"
run "$HIVE" ct check --module web --impact db
has "--impact modules count" "tinv002" "$OUT"
run "$HIVE" ct check --module db --task tref001
hasnt "a subtask of the task does not collide" "tsub001" "$OUT"
run "$HIVE" ct check --module api --task tsub001
hasnt "nor does an ancestor" "tref001" "$OUT"
run "$HIVE" ct check --module db --task tsub001
has "a sibling does" "tinv002" "$OUT"
mkdrone w-live pw1 working web
jq '. + {clickup_task: "thold01", modules: "infra", impact: ""}' "$HIVE_DIR/fronts/web/drones/w-live/meta.json" > "$T/m" && mv "$T/m" "$HIVE_DIR/fronts/web/drones/w-live/meta.json"
run "$HIVE" ct check --module infra
has "a living drone of another front collides, whatever its task's status" "thold01" "$OUT"
has "and is named" "drone w-live (front web)" "$OUT"
echo dead > /dev/null; rm -f "$FAKE_PANES/pw1.status"
run "$HIVE" ct check --module infra
eq "a dead drone holds nothing" 0 "$RC"
claim() {  # claim <drone> <pane> <front> <task> <modules> [report STATUS] — a drone at work on a task, its brief an hour old
  local d="$HIVE_DIR/fronts/$3/drones/$1"; [ "$3" = default ] && d="$HIVE_DIR/drones/$1"
  mkdrone "$1" "$2" working "$([ "$3" = default ] || echo "$3")"
  jq --arg t "$4" --arg m "$5" '. + {clickup_task: $t, modules: $m, impact: ""}' "$d/meta.json" > "$T/m" && mv "$T/m" "$d/meta.json"
  echo "# brief" > "$d/brief.md"; touch -d '-1 hour' "$d/brief.md"; rm -f "$d/report.md"
  [ -z "${6:-}" ] || printf 'STATUS: %s\n## Result\nx\n' "$6" > "$d/report.md"
}
claim c-done pc1 default tinv002 infra DONE
run "$HIVE" ct check --module infra
eq "a drone whose report after its brief says DONE holds nothing" 0 "$RC"
claim c-done pc1 default tinv002 infra FAILED
run "$HIVE" ct check --module infra
eq "nor FAILED" 0 "$RC"
claim c-done pc1 default tinv002 infra BLOCKED
run "$HIVE" ct check --module infra
has "a BLOCKED one still holds its modules" "c-done (front default)" "$OUT"
claim c-done pc1 default tinv002 infra DONE; touch -d '-2 hours' "$HIVE_DIR/drones/c-done/report.md"
run "$HIVE" ct check --module infra
has "a DONE report older than the brief is the previous task's: the drone holds the new one" "c-done (front default)" "$OUT"
rm -f "$FAKE_PANES/pc1.status"
claim c-shut pc2 default told001 infra
run "$HIVE" ct check --module infra
eq "a drone whose task the cache has closed holds nothing" 0 "$RC"
rm -f "$FAKE_PANES/pc2.status"
claim c-anc pc3 default tref001 docs
run "$HIVE" ct check --module docs --task tsub001
eq "a drone on an ancestor of the task does not collide" 0 "$RC"
rm -f "$FAKE_PANES/pc3.status"
claim twin pc4 web tinv002 docs
run env HIVE_DRONE=twin "$HIVE" ct check --module docs
has "the caller is left out by front and name: its namesake in another front still counts" "twin (front web)" "$OUT"
run env HIVE_DRONE=twin HIVE_FRONT=web "$HIVE" ct check --module docs
eq "the caller itself does not" 0 "$RC"
rm -f "$FAKE_PANES/pc4.status"
echo working > "$FAKE_PANES/pw1.status"

# =============================================================================
section "hive task: the gate"
mkdrone d1 p1 working
brief "$T/b1" "# Fix refunds" "Do it."
run "$HIVE" task d1 "$T/b1"
has "a brief without a ClickUp line is refused" "no 'ClickUp: <task id>' line" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Impact: none"
run "$HIVE" task d1 "$T/b1"
has "without Modules" "no 'Modules:" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Modules: api"
run "$HIVE" task d1 "$T/b1"
has "without Impact" "no 'Impact:" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Modules: apii" "Impact: none"
run "$HIVE" task d1 "$T/b1"
has "a typo in Modules" "'apii' is no module of the taxonomy" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: zznone1" "Modules: infra" "Impact: none"
run "$HIVE" task d1 "$T/b1"
has "a task that does not exist (401 OAUTH_027)" "zznone1 does not exist" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: told001" "Modules: infra" "Impact: none"
run "$HIVE" task d1 "$T/b1"
has "a closed task" "is closed (done)" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tsrch01" "Modules: infra" "Impact: none"
run "$HIVE" task d1 "$T/b1"
has "a task of another front, with the way to take it over" "hive ct set tsrch01 --front default" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: ttwo001" "Modules: infra" "Impact: none"
run "$HIVE" task d1 "$T/b1"
has "a task with two areas" "has 2 areas" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Modules: api" "Impact: none"
run "$HIVE" task d1 "$T/b1"
eq "a collision refuses" 1 "$RC"
has "listing the task" "tinv001" "$ERR"
has "and the way through" "Collision checked: <id>" "$ERR"
eq "a refused brief writes nothing" 0 "$(grep -c '^\(POST\|PUT\) /task/tref001' "$FAKE_CU/requests.log")"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Modules: api" "Impact: none" "Collision checked: tinv001"
run "$HIVE" task d1 "$T/b1"
has "a line without a reason is refused" "gives no reason" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Modules: api" "Impact: none" "Collision checked: tinv001 — other files" "Collision checked: thold01 — whatever"
run "$HIVE" task d1 "$T/b1"
has "a line for a task that does not collide is refused" "thold01 is not one of the collisions" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Modules: api" "Impact: none" "Collision checked: tinv001 — other files"
run "$HIVE" task d1 "$T/b1"
has "one line per collision: tsrch01 still open" "tsrch01" "$ERR"
brief "$T/b1" "# Fix refunds" "ClickUp: tref001" "Components: api" "Effect: nothing" \
  "Collision checked: tinv001 — other files, no shared table" "Clash checked: tsrch01: ranking code only"
run "$HIVE" task d1 "$T/b1"
eq "settled collisions pass (aliases from the config work)" 0 "$RC"
eq "the task goes from an early status to status_start" "in progress" "$(task_field tref001 .status.status)"
has "with a start comment" "drone d1 (front default) start: Fix refunds; modules: api; impact: none" "$(comments_of tref001)"
has "each settled collision is a comment on the task" "on tref001 works in modules api of tinv001 as well: other files, no shared table" "$(comments_of tref001)"
has "and on the other task" "on tref001 works in modules api of tsrch01 as well: ranking code only" "$(comments_of tsrch01)"
eq "meta.json holds the task, modules and impact" "tref001 api -" "$(meta_of d1 clickup_task) $(meta_of d1 modules) $(meta_of d1 impact || true)-"
B=$(cat "$HIVE_DIR/drones/d1/brief.md")
has "the protocol asks for the ClickUp section" "task: tref001" "$B"
has "with '## Prod' for status done" "status: done>" "$B"
has "the task's history first" "hive ct show tref001" "$B"
has "the branch name" "tref001-<short-slug>" "$B"
has "and a check before leaving its modules" "hive ct check --module <module> --task tref001" "$B"
mkdrone d2 p2 working
brief "$T/b2" "# Analysis" "ClickUp: tana001" "Modules: infra, db" "Impact: none"
run "$HIVE" task d2 "$T/b2"
has "a living drone of another front blocks its modules" "w-live" "$ERR"
brief "$T/b2" "# Analysis" "ClickUp: tana001" "Modules: infra, db" "Impact: none" "Collision checked: thold01 — read only" "Collision checked: tinv002 — read only"
run "$HIVE" task d2 "$T/b2"
has "a subtask of another task collides like any task" "tsub001" "$ERR"
brief "$T/b2" "# Analysis" "ClickUp: tana001" "Modules: infra, db" "Impact: none" "Collision checked: thold01 — read only" \
  "Collision checked: tinv002 — read only" "Collision checked: tsub001 — read only"
run "$HIVE" task d2 "$T/b2"
eq "passes once settled" 0 "$RC"
eq "the brief's modules the task lacked are added to it" "area-other,front-default,mod-db,mod-infra,type-analysis" "$(tags_of tana001)"
eq "start writes ClickUp took leave nothing queued" 0 "$(ls "$CU/starts" | wc -l)"
mktask trev001 "in review" "front-default,area-other,mod-docs" "Docs: in review already"
mkdrone d4 p4 working
brief "$T/b4r" "# Docs" "ClickUp: trev001" "Modules: docs" "Impact: none"
run "$HIVE" task d4 "$T/b4r"
eq "a start leaves a later status alone" "0 in review" "$RC $(task_field trev001 .status.status)"
has "and comments all the same" "drone d4 (front default) start: Docs" "$(comments_of trev001)"
has "with its marker" "hive-start:d4:" "$(comments_of trev001)"
echo 1 > "$FAKE_CU/refuse"
run "$HIVE" task d4 "$T/b4r"
eq "ClickUp refusing the task (a 4xx) refuses the brief" 1 "$RC"
has "with ClickUp's word" "HTTP 400 (Bad request INPUT_002)" "$ERR"
rm -f "$FAKE_PANES/p4.status"
section "hive task: ClickUp down"
mkdrone d3 p3 working
touch "$FAKE_CU/down"
brief "$T/b3" "# Down" "ClickUp: thold01" "Modules: api" "Impact: none"
run "$HIVE" task d3 "$T/b3"
eq "collisions are counted on the cache and the living drones" 1 "$RC"
has "the living drone d1 holds api" "d1 (front default)" "$ERR"
brief "$T/b3" "# Down" "ClickUp: thold01" "Modules: web" "Impact: none" "Collision checked: tsrch01 — ui only"
n=$(grep -c '/team/' "$FAKE_CU/curl.argv")
run "$HIVE" task d3 "$T/b3"
eq "without a collision the brief passes" 0 "$RC"
has "with a warning" "ClickUp unreachable" "$ERR"
eq "the cache is not refreshed while ClickUp is down" "$n" "$(grep -c '/team/' "$FAKE_CU/curl.argv")"
eq "the drone holds its task all the same" "thold01" "$(meta_of d3 clickup_task)"
eq "its start writes are queued" 1 "$(ls "$CU/starts" | wc -l)"
cp "$CU"/starts/*.json "$T/start.json"
sync_now
eq "a sync while ClickUp is still down keeps them" 1 "$(ls "$CU/starts" | wc -l)"
has "and says it will retry" "ClickUp unavailable for the start writes of default/d3 thold01 — will retry" "$(cat "$CU/sync.log")"
rm -f "$FAKE_CU/down"
sync_now
has "clickup-sync makes them once ClickUp is back: the modules" "mod-web" "$(tags_of thold01)"
has "the start comment" "drone d3 (front default) start: Down; modules: web" "$(comments_of thold01)"
has "the collision comment" "on thold01 works in modules web of tsrch01 as well: ui only" "$(comments_of tsrch01)"
eq "a status past the early ones stays" "on hold" "$(task_field thold01 .status.status)"
eq "and the queue is empty" 0 "$(ls "$CU/starts" | wc -l)"
cp "$T/start.json" "$CU/starts/"; n=$(ncomments thold01); sync_now
eq "a replay of the same start adds nothing (its marker)" "$n" "$(ncomments thold01)"
eq "and leaves the queue" 0 "$(ls "$CU/starts" | wc -l)"
section "hive task: a network that drops packets"
touch "$FAKE_CU/hang"
mkdrone d5 p5 working
brief "$T/b5" "# Hang" "ClickUp: tana001" "Modules: docs" "Impact: none" "Collision checked: trev001 — other pages"
s=$SECONDS; run timeout 200 "$HIVE" task d5 "$T/b5"; took=$((SECONDS - s))
eq "the gate lets the brief through" 0 "$RC"
eq "within its budget, not minutes" yes "$([ "$took" -le 15 ] && echo yes || echo "no (${took}s)")"
has "with the warning" "ClickUp unreachable" "$ERR"
rm -f "$FAKE_CU/hang" "$CU"/starts/*.json "$FAKE_PANES/p5.status"
eq "every call caps the connection, not only the whole call" 0 "$(grep -vc -- '--connect-timeout' "$FAKE_CU/curl.argv")"
section "hive task: the task answers, the writes hang"
touch "$FAKE_CU/hangwrites"
mkdrone q1 pq1 working
brief "$T/bq1" "# Hanging writes" "ClickUp: tana001" "Modules: docs" "Impact: none" "Collision checked: trev001 — other pages"
n=$(grep -c '^GET /task/tana001 $' "$FAKE_CU/requests.log")
s=$SECONDS; run timeout 200 "$HIVE" task q1 "$T/bq1"; took=$((SECONDS - s))
rm -f "$FAKE_CU/hangwrites"
eq "the brief passes" 0 "$RC"
eq "the start writes use the task the gate read" 1 "$(( $(grep -c '^GET /task/tana001 $' "$FAKE_CU/requests.log") - n ))"
eq "the budget covers the start writes too" yes "$([ "$took" -le 15 ] && echo yes || echo "no (${took}s)")"
has "which say they wait for clickup-sync" "clickup-sync retries the start writes of tana001" "$ERR"
eq "the record stays in the queue" 1 "$(nstarts)"
eq "and none under a dot name" 0 "$(find "$CU/starts" -name '.*' | wc -l)"
sync_now
has "clickup-sync makes them" "hive-start:q1:" "$(comments_of tana001)"
eq "and empties the queue" 0 "$(nstarts)"
rm -f "$FAKE_PANES/pq1.status"
section "hive task: a sync while the start writes are made"
mkdrone q2 pq2 working
brief "$T/bq2" "# Race" "ClickUp: tana001" "Modules: docs" "Impact: none" "Collision checked: trev001 — other pages"
echo 1 > "$FAKE_CU/slow"
( "$HIVE" task q2 "$T/bq2" >/dev/null 2>&1 ) & bg=$!
while kill -0 "$bg" 2>/dev/null; do sync_now; sleep 0.2; done
wait "$bg"; rc=$?
rm -f "$FAKE_CU/slow"; sync_now
eq "the brief passes" 0 "$rc"
eq "one start comment, however the syncs fall" 1 "$(comments_of tana001 | grep -c 'hive-start:q2:')"
eq "one collision comment" 1 "$(comments_of trev001 | grep -c 'drone q2 (front default) on tana001')"
eq "and nothing left in the queue" "0 0" "$(nstarts) $(find "$CU/starts" -name '.*' | wc -l)"
rm -f "$FAKE_PANES/pq2.status"
section "hive task: a token_cmd that hangs"
cp "$CU/config" "$T/config.ok"
sed -i "s|^token_cmd = .*|token_cmd = sleep 30; cat $T/token|" "$CU/config"
mkdrone q3 pq3 working
brief "$T/bq3" "# Slow token" "ClickUp: tana001" "Modules: docs" "Impact: none" "Collision checked: trev001 — other pages"
s=$SECONDS; run timeout 200 "$HIVE" task q3 "$T/bq3"; took=$((SECONDS - s))
cp "$T/config.ok" "$CU/config"
eq "the brief passes" 0 "$RC"
eq "token_cmd gets what is left of the budget" yes "$([ "$took" -le 15 ] && echo yes || echo "no (${took}s)")"
has "and ClickUp counts as unreachable" "ClickUp unreachable" "$ERR"
rm -f "$CU"/starts/*.json "$FAKE_PANES/pq3.status"
section "clickup-sync: the start queue"
mktask tq101 backlog "front-default,area-other" "Queue: tags"
mktask tq102 backlog "front-default,area-other" "Queue: status"
mktask tq103 backlog "front-default,area-other" "Queue: comment"
echo '429 4 GET /task/tq101' > "$FAKE_CU/fail"
queue_start tq101 z1 1001 api; queue_start tq102 z1 1002
sync_now
eq "the first record ClickUp fails on stops the replay" 2 "$(nstarts)"
eq "the later one waits too" 0 "$(ncomments tq102)"
rm -f "$FAKE_CU/fail" "$CU"/starts/*.json
for f in "tq101 POST /task/*/tag/* the modules" "tq102 PUT /task/* the status" "tq103 POST /task/*/comment the comment"; do
  read -r id m p what <<<"$f"
  echo "401 1 $m $p" > "$FAKE_CU/fail"
  queue_start "$id" z2 2000 api; sync_now
  eq "a record stays when ClickUp fails on $what" 1 "$(nstarts)"
  rm -f "$FAKE_CU/fail"; sync_now
  eq "and is made on the next run: $what" "0 1 in progress mod-api" \
    "$(nstarts) $(comments_of "$id" | grep -c 'hive-start:z2:2000') $(task_field "$id" .status.status) $(tags_of "$id" | grep -o mod-api)"
done
jq '[{comment_text: "start, reworded by ClickUp\nhive-start:z3:3000", date: "1", user: {username: "tester"}}] + .' \
  "$FAKE_CU/comments/tq103.json" > "$T/c" && mv "$T/c" "$FAKE_CU/comments/tq103.json"
n=$(ncomments tq103); queue_start tq103 z3 3000; sync_now
eq "the marker alone says a start is made, whatever the text around it" "$n" "$(ncomments tq103)"
queue_start tq103 z4 4000; jq 'del(.at)' "$CU/starts/4000.test.json" > "$T/s" && mv "$T/s" "$CU/starts/4000.test.json"
echo 'not json' > "$CU/starts/4001.test.json"
n=$(ncomments tq103); sync_now
eq "a record without its time or not JSON is dropped" "0 $n" "$(nstarts) $(ncomments tq103)"
eq "saying the record is unreadable, not the task" 2 "$(grep -c 'dropped (record unreadable)' "$CU/sync.log")"
section "hive task: the cache catches up"
touched() { jq --arg n "$(( $(date +%s) * 1000 ))" '.date_updated = $n' "$FAKE_CU/tasks/$1.json" > "$T/u" && mv "$T/u" "$FAKE_CU/tasks/$1.json"; }
closed_now() { jq '.status = {status: "done", type: "closed"}' "$FAKE_CU/tasks/$1.json" > "$T/u" && mv "$T/u" "$FAKE_CU/tasks/$1.json"; }
mktask tcu000 backlog "front-default,area-other" "Cache: the gate's own task"
"$HIVE" ct sync >/dev/null 2>&1
mkdrone e1 pe1 working
brief "$T/be1" "# Cache" "ClickUp: tcu000" "Modules: cache" "Impact: none"
mktask tcu001 "in progress" "front-default,area-other,mod-cache" "Cache: changed since the refresh"
n=$(grep -c '/team/' "$FAKE_CU/curl.argv")
run "$HIVE" task e1 "$T/be1"
eq "a task changed since the last refresh collides" 1 "$RC"
has "by name" "tcu001" "$ERR"
eq "the gate lists only the tasks changed since, closed ones too" "1 1" \
  "$(( $(grep -c '/team/' "$FAKE_CU/curl.argv") - n )) $(grep '/team/' "$FAKE_CU/curl.argv" | tail -1 | grep -c 'include_closed=true&date_updated_gt=')"
closed_now tcu001
jq '.date_updated = "1000"' "$FAKE_CU/tasks/tcu001.json" > "$T/u" && mv "$T/u" "$FAKE_CU/tasks/tcu001.json"
run "$HIVE" task e1 "$T/be1"
eq "a task the listing does not bring keeps its row: the cache is not listed whole" 1 "$RC"
touched tcu001
run "$HIVE" task e1 "$T/be1"
eq "a task closed since releases the collision" 0 "$RC"
eq "and the cache has it closed" done "$(awk -F'\t' '$1 == "tcu001" { print $2 }' "$CU/registry.tsv")"
mktask tcu003 "in progress" "front-default,area-other,mod-cache" "Cache: deleted later"
mktask tcu004 "in progress" "front-default,area-other,mod-cache" "Cache: moved later"
run "$HIVE" task e1 "$T/be1"
has "both collide while ClickUp has them" "tcu003" "$ERR"
rm -f "$FAKE_CU/tasks/tcu003.json"
jq '.space = {id: "999"}' "$FAKE_CU/tasks/tcu004.json" > "$T/u" && mv "$T/u" "$FAKE_CU/tasks/tcu004.json"
brief "$T/be1" "# Cache" "ClickUp: tcu000" "Modules: cache" "Impact: none" "Collision checked: tcu003 — written before it was deleted"
run "$HIVE" task e1 "$T/be1"
eq "a task deleted or moved out of the space refuses nothing, a line for it neither" 0 "$RC"
eq "both leave the cache" 0 "$(grep -cE '^tcu00[34]' "$CU/registry.tsv")"
mktask tcu006 "in progress" "front-default,area-other,mod-cache" "Cache: ClickUp does not answer for it"
brief "$T/be1" "# Cache" "ClickUp: tcu000" "Modules: cache" "Impact: none"
run "$HIVE" task e1 "$T/be1"
echo '401 1 GET /task/tcu006' > "$FAKE_CU/fail"
run "$HIVE" task e1 "$T/be1"
eq "a collision ClickUp does not answer for stays" 1 "$RC"
has "named" "tcu006" "$ERR"
closed_now tcu006; touched tcu006
run "$HIVE" task e1 "$T/be1"
eq "and goes once ClickUp has it closed" 0 "$RC"
echo '401 1 GET /team/*' > "$FAKE_CU/fail"
run "$HIVE" task e1 "$T/be1"
eq "a catch-up ClickUp fails on lets the brief through" 0 "$RC"
has "telling the caller the cache was used" "warning — the cache was not refreshed" "$ERR"
rm -f "$FAKE_CU/fail"
mktask tcu005 "in progress" "front-default,area-other,mod-cache" "Cache: collides while the catch-up fails"
run "$HIVE" task e1 "$T/be1"
echo '401 1 GET /team/*' > "$FAKE_CU/fail"
run "$HIVE" task e1 "$T/be1"
eq "a collision on a cache the gate could not refresh refuses" 1 "$RC"
has "saying the cache was not refreshed" "warning: the cache was not refreshed" "$ERR"
rm -f "$FAKE_CU/fail"; closed_now tcu005; touched tcu005
run "$HIVE" task e1 "$T/be1"
mktask tcu007 "in progress" "front-default,area-other,mod-cache" "Cache: only a full refresh finds it"
jq '.date_updated = "1000"' "$FAKE_CU/tasks/tcu007.json" > "$T/u" && mv "$T/u" "$FAKE_CU/tasks/tcu007.json"
run "$HIVE" task e1 "$T/be1"
eq "a task no listing of changes brings is missed while the full refresh is recent" 0 "$RC"
touch -d '-2 hours' "$CU/registry.full"
run "$HIVE" task e1 "$T/be1"
eq "and found once it is not: the gate refreshes the whole cache" 1 "$RC"
has "named" "tcu007" "$ERR"
rm -f "$FAKE_CU/tasks/tcu007.json"; touch -d '-20 minutes' "$CU/registry.full"
sync_now
eq "clickup-sync refreshes the whole cache once its last full refresh is 10 minutes old" "0 yes" \
  "$(grep -c '^tcu007' "$CU/registry.tsv") $([ $(( $(date +%s) - $(stat -c %Y "$CU/registry.full") )) -lt 60 ] && echo yes || echo no)"
section "hive task: a catch-up overlapping a slow full refresh of clickup-sync"
# The catch-up's cache is 50 s old and has the task in progress; a full refresh began 200 s ago, when the
# task was still in the backlog, and writes its cache, stamped then, while the catch-up lists the changes.
RACE="$T/race/clickup"; mkdir -p "$RACE"; now=$(date +%s)
racerows() { head -1 "$CU/registry.tsv"; printf 'tcu009\t%s\t\t\tcache\t\tCache: a race\t-\n' "$1"; }
racerows "in progress" > "$RACE/registry.tsv"; touch -d "@$((now - 50))" "$RACE/registry.tsv"
racerows backlog > "$RACE/sync.tsv"; touch -d "@$((now - 200))" "$RACE/sync.tsv" "$RACE/registry.full"
HIVE_DIR="$T/race" bash -c '. "$1"; cu_space_rows() { mv -f "$CU_DIR/sync.tsv" "$CU_REGISTRY"; }; cu_registry_catchup' _ "$SK/clickup.sh"
eq "the cache written meanwhile does not bring the task's old status back" "in progress" \
  "$(awk -F'\t' '$1 == "tcu009" { print $2 }' "$RACE/registry.tsv")"
section "hive task: stopped while making the start writes"
for sig in HUP TERM INT; do
  mkdrone "k${sig,,}" "pk$sig" working
  touch "$FAKE_CU/hangwrites"
  # Job control on: a background job of a script otherwise ignores SIGINT, and no trap could catch it.
  set -m; "$HIVE" task "k${sig,,}" "$T/be1" >/dev/null 2>&1 & bg=$!; set +m
  # Signalled once a write hangs: the trap waits for it to end, the shell's own exit on the signal would not.
  for i in $(seq 150); do
    [ -n "$(find "$CU/starts" -name '.start.*')" ] && tail -1 "$FAKE_CU/curl.argv" | grep -qE -- '-X (POST|PUT|DELETE)' && break
    sleep 0.1
  done
  kill -"$sig" "$bg"; sleep 0.2
  eq "SIG$sig waits for the write under way, the record out of the queue until it ends" "alive 0" \
    "$(kill -0 "$bg" 2>/dev/null && echo alive || echo gone) $(nstarts)"
  wait "$bg"
  rm -f "$FAKE_CU/hangwrites"
  eq "SIG$sig puts the start record being made in the queue" "1 0" "$(nstarts) $(find "$CU/starts" -name '.*' | wc -l)"
  sync_now
  eq "where clickup-sync makes it" "0 1" "$(nstarts) $(comments_of tcu000 | grep -c "hive-start:k${sig,,}:")"
  rm -f "$FAKE_PANES/pk$sig.status"
done
mktask tcu008 "in progress" "front-default,area-other,mod-cache" "Cache: a settled collision"
brief "$T/bk" "# Cache" "ClickUp: tcu000" "Modules: cache" "Impact: none" "Collision checked: tcu008 — other keys"
mkdrone kk pkk working
echo 1 > "$FAKE_CU/slow"
"$HIVE" task kk "$T/bk" >/dev/null 2>&1 & bg=$!
for i in $(seq 300); do comments_of tcu000 | grep -q 'hive-start:kk:' && break; sleep 0.1; done
kill -KILL "$bg"; wait "$bg" 2>/dev/null
rm -f "$FAKE_CU/slow"; sleep 1.5
rm -rf "${TMPDIR:?}"/hive-cu.*   # a killed process leaves its private directory: not what the token section counts
sync_now
eq "SIGKILL leaves the record under its dot name, a young one is left alone" 1 "$(find "$CU/starts" -name '.start.*' | wc -l)"
touch -d '-2 minutes' "$CU"/starts/.start.*
sync_now
eq "an old one clickup-sync takes up and makes" "0 0" "$(nstarts) $(find "$CU/starts" -name '.*' | wc -l)"
eq "without doubling the start comment made before the kill" 1 "$(comments_of tcu000 | grep -c 'hive-start:kk:')"
eq "and with the collision comments" "1 1" "$(comments_of tcu000 | grep -c 'drone kk (front default) on tcu000') $(comments_of tcu008 | grep -c 'drone kk (front default) on tcu000')"
has "saying so" "taken up: its 'hive task' died" "$(cat "$CU/sync.log")"
rm -f "$FAKE_PANES/pkk.status"
mkdir -p "$T/badjq"
printf '#!/usr/bin/env bash\ncase "$*" in *"settled: \\$settled"*) exit 5 ;; esac\nexec %q "$@"\n' "$(command -v jq)" > "$T/badjq/jq"; chmod +x "$T/badjq/jq"
mkdrone kj pkj working
run env PATH="$T/badjq:$PATH" "$HIVE" task kj "$T/bk"
eq "a start record jq cannot write lets the brief through" 0 "$RC"
has "saying the start writes are lost" "could not queue the start writes of tcu000" "$ERR"
eq "and leaves no record behind" "0 0" "$(nstarts) $(find "$CU/starts" -name '.*' | wc -l)"
rm -f "$FAKE_PANES/pkj.status" "$FAKE_PANES/pe1.status"
section "the retry guard"
cu_probe() { bash -c '. "$1"; cu_ready && cu_comment tq103 "$2" "$2"' _ "$SK/clickup.sh" "$1"; }
printf '503 1 POST /task/tq103/comment\n503 9 GET /task/tq103/comment\n' > "$FAKE_CU/fail"
n=$(grep -c '^GET /task/tq103/comment' "$FAKE_CU/requests.log")
run cu_probe "guard probe one"
eq "a guard that fails is one attempt, then the write is retried" "0 1 1" \
  "$RC $(( $(grep -c '^GET /task/tq103/comment' "$FAKE_CU/requests.log") - n )) $(comments_of tq103 | grep -c 'guard probe one')"
echo '429 1 POST /task/tq103/comment' > "$FAKE_CU/fail"
n=$(grep -c '^GET /task/tq103/comment' "$FAKE_CU/requests.log")
run cu_probe "guard probe two"
eq "a 429 changed nothing: no guard before its retry" "0 0 1" \
  "$RC $(( $(grep -c '^GET /task/tq103/comment' "$FAKE_CU/requests.log") - n )) $(comments_of tq103 | grep -c 'guard probe two')"
rm -f "$FAKE_CU/fail"
section "hive task: HIVE_NO_CLICKUP"
n=$(nrequests)
brief "$T/b4" "# Helper" "Look around."
run env HIVE_NO_CLICKUP=1 "$HIVE" task d3 "$T/b4"
eq "passes on purpose, without a call" "0 $n" "$RC $(nrequests)"
eq "and the drone holds no task any more" "" "$(meta_of d3 clickup_task)"

# =============================================================================
section "clickup-sync"
mktask tbase01 "in progress" "front-default,area-other,mod-docs" "Baseline"
mkdrone s0 ps0 idle
jq '. + {clickup_task: "tbase01"}' "$HIVE_DIR/drones/s0/meta.json" > "$T/m" && mv "$T/m" "$HIVE_DIR/drones/s0/meta.json"
report s0 "STATUS: DONE" "## Result" "Old." "## ClickUp" "task: tbase01" "status: in review" "comment: old news"
touch -d '-2 days' "$HIVE_DIR/drones/s0/report.md"
rm -f "$CU/sync.state"; sync_now
eq "first run: a report older than 24 h is recorded without a call" "0 in progress" "$(ncomments tbase01) $(task_field tbase01 .status.status)"
has "and not looked at again" "$HIVE_DIR/drones/s0/report.md" "$(cat "$CU/sync.state")"
mkdrone s1 ps1 idle
jq '. + {clickup_task: "tinv001"}' "$HIVE_DIR/drones/s1/meta.json" > "$T/m" && mv "$T/m" "$HIVE_DIR/drones/s1/meta.json"
report s1 "STATUS: DONE" "## Result" "Rounding fixed." "## ClickUp" "task: tinv001" "status: in review" "comment: rounding fixed, PR open" \
  "pr: https://example.com/pr/1" "pr: https://example.com/pr/2" "branch: tinv001-rounding"
nl=$(subjects | wc -l)
sync_now
C=$(comments_of tinv001)
eq "the status is applied" "in review" "$(task_field tinv001 .status.status)"
has "one comment with the header" "🤖 [drone s1, front default] STATUS: DONE → in review" "$C"
has "the PRs" "PR: https://example.com/pr/2" "$C"
has "the branch" "branch: tinv001-rounding" "$C"
has "the Result section" "Rounding fixed." "$C"
has "and the marker" "hive-report:s1:" "$C"
has "a line in the log" "applied default/s1 tinv001" "$(cat "$CU/sync.log")"
has "the outcome for drone-ping" "tinv001 → in review ✓" "$(cat "$HIVE_DIR/drones/s1/.clickup-sync")"
eq "no letter for a success" "$nl" "$(subjects | wc -l)"
n=$(ncomments tinv001); sync_now
eq "a second run adds nothing" "$n" "$(ncomments tinv001)"
: > "$CU/sync.state"; sync_now
eq "nor does a run after the state was lost (the marker)" "$n" "$(ncomments tinv001)"
report s1 "STATUS: DONE" "## Result" "Again." "## ClickUp" "task: tinv001" "status: in review" "comment: two syncs at once"
echo 0.3 > "$FAKE_CU/slow"; n=$(ncomments tinv001)
sync_now & sync_now; wait
rm -f "$FAKE_CU/slow"
eq "two syncs at once comment once (the lock)" "$((n + 1))" "$(ncomments tinv001)"
report s1 "STATUS: DONE" "## Result" "Again." "## ClickUp" "task: tinv001" "status: in review" "comment: answer lost"
echo 1 > "$FAKE_CU/lost"; n=$(ncomments tinv001); sync_now
eq "a report comment whose answer was lost (500) is not posted again" "$((n + 1))" "$(ncomments tinv001)"
report s1 "STATUS: DONE" "## Result" "Deployed." "## ClickUp" "task: tinv001" "status: done" "comment: deployed"
sync_now
eq "done without '## Prod' is lowered" "testing" "$(task_field tinv001 .status.status)"
has "the comment says so" "no production check" "$(comments_of tinv001)"
has "and the coordinator gets a letter" "CLICKUP s1 tinv001: done lowered to testing" "$(subjects)"
report s1 "STATUS: DONE" "## Result" "Deployed." "## ClickUp" "task: tinv001" "status: done" "comment: deployed" "## Prod" "image 1.2.3 runs, totals checked"
sync_now
eq "done with '## Prod' is done" "done" "$(task_field tinv001 .status.status)"
report s1 "STATUS: DONE" "## Result" "More." "## ClickUp" "task: tinv001" "status: in review" "comment: reopen?"
sync_now
eq "a closed task is never reopened" "done" "$(task_field tinv001 .status.status)"
has "and the comment says why" "never reopens a closed task" "$(comments_of tinv001)"
jq '. + {clickup_task: "tana001"}' "$HIVE_DIR/drones/s1/meta.json" > "$T/m" && mv "$T/m" "$HIVE_DIR/drones/s1/meta.json"
report s1 "STATUS: DONE" "## Result" "Costs analysed." "## ClickUp" "task: tana001" "status: complete" "comment: analysis delivered"
sync_now
eq "an analysis is done once delivered, without '## Prod' ('complete' means done)" "done" "$(task_field tana001 .status.status)"
report s1 "STATUS: DONE" "## Result" "x" "## ClickUp" "task: thold01" "status: shipped-ish" "comment: odd status"
sync_now
has "a status the list does not have: a letter" "CLICKUP ✗ s1 thold01: status 'shipped-ish' does not exist" "$(subjects)"
has "the comment still lands" "odd status" "$(comments_of thold01)"
run env HIVE_DRONE= "$HIVE" ct ack s1
eq "ack needs a reason" 1 "$RC"
run "$HIVE" ct ack s1 --manual "set to on hold by hand"
eq "ack with a reason" 0 "$RC"
has "the reason is logged" "ack default/s1: set to on hold by hand" "$(cat "$CU/sync.log")"
run "$HIVE" ct ack s1 --manual "again"
has "an applied report cannot be acked" "not one clickup-sync failed on" "$ERR"
report s1 "STATUS: DONE" "## Result" "x"
sync_now
has "no section: a letter" "CLICKUP ✗ s1: no ClickUp section" "$(subjects)"
report s1 "STATUS: DONE" "## Result" "x" "## ClickUp" "task: none" "status: done"
sync_now
has "no task: a letter" "the report names no task" "$(subjects)"
report s1 "STATUS: DONE" "## Result" "x" "## ClickUp" "task: zzgone1" "status: done"
sync_now
has "a task that does not exist: a letter" "task zzgone1 does not exist" "$(subjects)"
report s1 "STATUS: DONE" "## Result" "x" "## ClickUp" "task: thold01" "status: done" "applied: no"
n=$(nrequests); sync_now
eq "a report in the old format is recorded without a call" "$n" "$(nrequests)"
long=$(head -c 30000 /dev/zero | tr '\0' 'x')
report s1 "STATUS: DONE" "## Result" "$long" "## ClickUp" "task: thold01" "comment: long one"
sync_now
L=$(comments_of thold01 | head -c 100000)
c=$(jq -r '.[0].comment_text | length' "$FAKE_CU/comments/thold01.json")
eq "a long Result is cut to the limit" yes "$([ "$c" -le 8000 ] && echo yes || echo "no ($c)")"
has "pointing at the report" "the whole report is at the path below" "$L"
has "and still marked" "hive-report:s1:" "$(jq -r '.[0].comment_text' "$FAKE_CU/comments/thold01.json")"
touch "$FAKE_CU/down"
report s1 "STATUS: DONE" "## Result" "x" "## ClickUp" "task: thold01" "comment: while down"
sync_now; sync_now
eq "ClickUp down: one letter, however many runs" 1 "$(subjects | grep -c 'ClickUp unavailable')"
rm -f "$FAKE_CU/down"; sync_now
has "applied once ClickUp is back" "while down" "$(comments_of thold01)"
mkdrone s2 ps2 idle
report s2 "STATUS: DONE" "## Result" "x"
n=$(nrequests); sync_now
eq "a drone without a task is skipped" "$n" "$(nrequests)"
hasnt "silently" "s2" "$(subjects)"

# =============================================================================
section "drone-ping: the subject carries the outcome"
mkdrone p-1 pp1 idle
jq '. + {clickup_task: "thold01"}' "$HIVE_DIR/drones/p-1/meta.json" > "$T/m" && mv "$T/m" "$HIVE_DIR/drones/p-1/meta.json"
report p-1 "STATUS: DONE" "## Result" "ok" "## ClickUp" "task: thold01" "status: in review" "comment: ping"
HIVE_DRONE=p-1 bash "$SK/drone-ping.sh" done </dev/null
for _ in $(seq 1 50); do subjects | grep -q 'p-1\|ClickUp thold01' && break; sleep 0.2; done
has "ClickUp <id> → <status> ✓" "finished a turn (report: DONE, ClickUp thold01 → in review ✓)" "$(subjects)"

# =============================================================================
section "hive move: the task goes along"
mkdrone mv1 pm1 dead
jq '. + {clickup_task: "tinv002", modules: "db", impact: ""}' "$HIVE_DIR/drones/mv1/meta.json" > "$T/m" && mv "$T/m" "$HIVE_DIR/drones/mv1/meta.json"
run "$HIVE" move mv1 web
eq "the move succeeds" 0 "$RC"
has "the task's front follows the drone" "front-web" "$(tags_of tinv002)"
has "with a comment" "hive move mv1 (front default -> web)" "$(comments_of tinv002)"

# =============================================================================
section "ct apply"
mktask apply01 backlog "front-default,area-other,mod-db" "Apply one"
mktask apply02 ready "front-default,area-other,mod-db" "Apply two"
printf 'id\tfront\tarea\tmodules\tparent\tcurrent status\tnew status\tcomment\n' > "$T/apply.tsv"
printf 'apply01\tweb\tsearch\tweb,api\tepbill1\tbacklog\tready\tmigrated\n' >> "$T/apply.tsv"
printf 'apply02\t\tnosuch\t\t—\tbacklog\tin progress\t\n' >> "$T/apply.tsv"
printf 'apply02\t\t\tdbb\tNEW:epic\tready\t\tonly a comment\n' >> "$T/apply.tsv"
run "$HIVE" ct apply "$T/apply.tsv"
has "a dry run plans" "PLAN apply01: front -> front-web; area -> area-search; modules -> mod-web,mod-api; parent -> epbill1; status backlog -> ready" "$OUT"
has "a row whose status changed is skipped" "SKIP apply02: status in ClickUp is 'ready', the file expects 'backlog'" "$OUT"
has "a wrong field skips only that field" "SKIP apply02 field — modules" "$OUT"
has "a parent that is no task id too" "parent 'NEW:epic' is not a task id" "$OUT"
has "the rest of the row stays" "PLAN apply02: comment: only a comment" "$OUT"
eq "a dry run writes nothing" backlog "$(task_field apply01 .status.status)"
run "$HIVE" ct apply "$T/apply.tsv" --yes
eq "--yes applies" "ready area-search,front-web,mod-api,mod-web epbill1" "$(task_field apply01 .status.status) $(tags_of apply01) $(task_field apply01 .parent)"
has "the comment too" "only a comment" "$(comments_of apply02)"
run "$HIVE" ct apply "$T/apply.tsv" --yes
has "a second run changes nothing" "0 to change" "$OUT"

# =============================================================================
section "ct stale"
DAY=86400
aged() {  # aged <id> <days> — the task last updated that many days ago
  jq --arg du "$(( ($(date +%s) - $2 * DAY) * 1000 ))" '.date_updated = $du' "$FAKE_CU/tasks/$1.json" > "$T/a" && mv "$T/a" "$FAKE_CU/tasks/$1.json"
}
oldcomment() {  # oldcomment <id> <days> [text] — a comment made that many days ago
  jq -n --arg d "$(( ($(date +%s) - $2 * DAY) * 1000 ))" --arg t "${3:-a word}" \
    '[{id: "old", comment_text: $t, date: $d, user: {username: "tester"}}]' > "$FAKE_CU/comments/$1.json"
}
swarmtask() {  # swarmtask <id> <status> <tags,comma> <name> <days> — stale, with a drone's start comment
  mktask "$1" "$2" "$3" "$4"; aged "$1" "$5"; oldcomment "$1" "$(( $5 + 1 ))" "🤖 drone x start: y
hive-start:x:1"
}
stale_drone() {  # stale_drone <name> <pane> <status|dead> <task> <days since its files changed> [brief text]
  mkdrone "$1" "$2" "$3"
  local d="$HIVE_DIR/drones/$1"
  jq --arg t "$4" '. + {clickup_task: $t, modules: "docs", impact: ""}' "$d/meta.json" > "$T/m" && mv "$T/m" "$d/meta.json"
  printf '# Brief\n%s\n' "${6:-ClickUp: $4}" > "$d/brief.md"
  touch -d "@$(( $(date +%s) - $5 * DAY ))" "$d/meta.json" "$d/brief.md"
}
mktask st01 testing "front-default,area-other,mod-docs" "Stale testing";            aged st01 10
mktask st02 testing "front-default,area-other,mod-docs" "Fresh testing";            aged st02 3
mktask st03 testing "front-default,area-other,mod-docs" "Testing commented on";     aged st03 10; oldcomment st03 2
mktask st04 "on hold" "front-default,area-other,mod-docs" "Never the swarm's";      aged st04 20
mktask st05 backlog "front-default,area-other,mod-docs" "Assigned backlog";         aged st05 20
jq '. + {assignees: [{id: 7, username: "alice"}]}' "$FAKE_CU/tasks/st05.json" > "$T/a" && mv "$T/a" "$FAKE_CU/tasks/st05.json"
mktask st06 "on hold" "front-default,area-other,mod-docs,human" "Tagged human";     aged st06 20
mktask st07 backlog "front-default,area-other,mod-docs" "Named by a living drone";  aged st07 20
mktask st08 backlog "front-default,area-other,mod-docs" "Named by an old dead drone"; aged st08 20
mktask st09 "on hold" "front-default,area-other,mod-docs" "Named by a recent brief"; aged st09 20
mktask st10 testing "front-default,area-other,mod-docs" "Testing with a fresh report"; aged st10 10
mktask st11 "on hold" "front-default,area-other,mod-docs" "Epic on hold";           aged st11 20
mktask st12 "in progress" "front-default,area-other,mod-docs" "Its subtask" st11
mktask st13 testing "front-default,area-other,mod-docs" "Changes meanwhile";        aged st13 10
mktask st14 "on hold" "front-default,area-other,mod-docs" "Hold not yet stale";     aged st14 10
swarmtask st16 "on hold" "front-default,area-other,mod-docs" "Stale on hold" 20
swarmtask st17 "on hold" "front-web,area-other,mod-docs" "Another front's" 20
stale_drone sd-live psd1 working st07 30
stale_drone sd-old psd2 dead st08 30
stale_drone sd-recent psd3 dead other 2 "Also look at st09 while at it."
stale_drone sd-report psd4 dead st10 30
printf 'STATUS: DONE\n' > "$HIVE_DIR/drones/sd-report/report.md"; touch -d "@$(( $(date +%s) - DAY ))" "$HIVE_DIR/drones/sd-report/report.md"
w0=$(writes)
run "$HIVE" ct stale
eq "a dry run exits 0" 0 "$RC"
has "the table has a header" "action id          rule change" "$OUT"
has "rule 1: testing not moved for over 7 days goes to done" "PLAN   st01        1    testing -> done" "$OUT"
has "with the reason" "no movement since $(date -d "@$(( $(date +%s) - 10 * DAY ))" +%F) — Stale testing" "$OUT"
hasnt "testing moved 3 days ago is no candidate" "st02" "$OUT"
has "a recent comment is movement" "KEEP   st03        1    testing" "$OUT"
has "rule 2: on hold not moved for over 14 days goes to cancelled" "PLAN   st16        2    on hold -> cancelled" "$OUT"
has "a task the swarm never worked on is only listed for a person" "CHECK  st04        2    on hold -> cancelled by hand" "$OUT"
has "and says why" "never the swarm's work (no drone names it, no hive-start or hive-report comment)" "$OUT"
hasnt "another front's task is no candidate" "st17" "$OUT"
has "an assigned task is only listed for a person" "CHECK  st05        2    backlog -> cancelled by hand" "$OUT"
has "and says who" "assigned to alice" "$OUT"
has "a task with a human tag too" "CHECK  st06" "$OUT"
has "with the tag" "tagged human" "$OUT"
has "a task a living drone's meta names stays" "KEEP   st07        2    backlog" "$OUT"
has "and says which drone" "named by the brief of sd-live" "$OUT"
has "a dead drone not changed for 30 days does not keep it" "PLAN   st08        2    backlog -> cancelled" "$OUT"
has "a task named in the text of a recent brief stays" "named by the brief of sd-recent" "$OUT"
has "a drone's fresh report is movement" "KEEP   st10        1    testing" "$OUT"
hasnt "an epic with an open subtask is never stale" "st11" "$OUT"
hasnt "on hold for 10 days is no candidate" "st14" "$OUT"
has "the summary counts" "stale: 4 to change, 3 for a person to check, 0 skipped — dry run" "$OUT"
run env HIVE_FRONT=web "$HIVE" ct stale
has "the other front sees its own" "PLAN   st17" "$OUT"
hasnt "and not this one's" "st16" "$OUT"
eq "a dry run writes nothing" "$w0" "$(writes)"
echo "GET /task/st13/comment st13 .date_updated = \"$(( $(date +%s) * 1000 ))\"" > "$FAKE_CU/edit"
run "$HIVE" ct stale --yes
eq "--yes exits 0" 0 "$RC"
eq "rule 1 applied" done "$(task_field st01 .status.status)"
has "with a comment" "🤖 hive ct stale, rule 1: 'testing' with no movement since" "$(comments_of st01)"
eq "rule 2 applied" "cancelled cancelled" "$(task_field st16 .status.status) $(task_field st08 .status.status)"
has "with a comment saying no brief names it" "named by no drone's brief → 'cancelled'." "$(comments_of st16)"
eq "a person's tasks keep their status" "backlog on hold on hold" "$(task_field st05 .status.status) $(task_field st06 .status.status) $(task_field st04 .status.status)"
eq "another front's task too" "on hold" "$(task_field st17 .status.status)"
eq "the kept ones too" "testing backlog testing" "$(task_field st03 .status.status) $(task_field st07 .status.status) $(task_field st10 .status.status)"
has "a task changed since it was read is skipped" "SKIP   st13" "$OUT"
eq "and left alone" testing "$(task_field st13 .status.status)"
has "the summary says so" "stale: 3 to change, 3 for a person to check, 1 skipped" "$OUT"
w1=$(writes)
run "$HIVE" ct stale --yes
has "a second run changes nothing" "stale: 0 to change, 3 for a person to check, 0 skipped" "$OUT"
eq "and writes nothing" "$w1" "$(writes)"
eq "no comment is doubled" 1 "$(comments_of st01 | grep -c 'hive ct stale')"
swarmtask st18 "on hold" "front-default,area-other,mod-docs" "Comment answer lost" 20
echo 1 > "$FAKE_CU/lost"
run "$HIVE" ct stale --yes
eq "a stale comment whose answer was lost (500) is not posted again" "0 cancelled 1" \
   "$RC $(task_field st18 .status.status) $(comments_of st18 | grep -c 'hive ct stale')"
hasnt "and is no failure" "FAILED st18" "$OUT"
swarmtask st19 testing "front-default,area-other,mod-docs" "Comment already there" 10
oldcomment st19 11 "🤖 hive ct stale, rule 1: 'testing' with no movement since $(date -d "@$(( $(date +%s) - 10 * DAY ))" +%F) (over 7 days) → 'done'."
run "$HIVE" ct stale --yes
eq "a stale comment already on the task (another run) is not doubled" "done 1" \
   "$(task_field st19 .status.status) $(comments_of st19 | grep -c 'hive ct stale')"
swarmtask st20 "on hold" "front-default,area-other,mod-docs" "Comment refused" 20
echo "400 1 POST /task/st20/comment" > "$FAKE_CU/fail"
run "$HIVE" ct stale --yes
eq "a comment that fails after the status was set" cancelled "$(task_field st20 .status.status)"
has "is printed as the command that adds it" "FAILED st20 comment — add it with: hive ct set st20 --comment '" "$OUT"
eval "set -- $(grep -o "hive ct set st20 --comment .*" <<<"$OUT")"; shift
run "$HIVE" "$@"
eq "which adds it word for word" 1 "$(comments_of st20 | grep -cxF "🤖 hive ct stale, rule 2: 'on hold' with no movement since $(date -d "@$(( $(date +%s) - 20 * DAY ))" +%F) (over 14 days), named by no drone's brief → 'cancelled'.")"
mktask st21 backlog "front-default,area-other,mod-docs" "Reported on, its drone pruned"; aged st21 20
oldcomment st21 21 "🤖 report of x: done
hive-report:x:1"
run "$HIVE" ct stale --yes
eq "a hive-report comment makes it the swarm's work" cancelled "$(task_field st21 .status.status)"
run "$HIVE" ct stale --now
eq "an unknown argument is refused" 1 "$RC"
sed -i 's/^stale_hold_to = cancelled$/stale_hold_to = nosuch/' "$CU/config"
swarmtask st15 "on hold" "front-default,area-other,mod-docs" "Hold to a missing status" 20
run "$HIVE" ct stale --yes
has "a target the list lacks fails that task" "FAILED st15 status" "$OUT"
eq "which keeps its status" "on hold" "$(task_field st15 .status.status)"
sed -i 's/^stale_hold_to = nosuch$/stale_hold_to =/; s/^status_unverified = testing$/status_unverified = testing\nstale_testing =/' "$CU/config"
run "$HIVE" ct stale
eq "with every rule off it refuses" 1 "$RC"
has "and says why" "no stale rule configured" "$ERR"
sed -i 's/^stale_hold_to =$/stale_hold_to = cancelled/; /^stale_testing =$/d' "$CU/config"

# =============================================================================
section "ct todo"
mktask td01 ready "front-default,area-other,mod-docs" "Epic without a checklist"
mktask td02 ready "front-default,area-other,mod-docs" "Epic with a checklist"
jq '. + {checklists: [{id: "clx", name: "small STEPS", items: [{id: "clx-0", name: "first"}]}]}' "$FAKE_CU/tasks/td02.json" > "$T/a" && mv "$T/a" "$FAKE_CU/tasks/td02.json"
checklists_of() { jq -r '[.checklists[]? | "\(.name): \([.items[].name] | join(", "))"] | join(" | ")' "$FAKE_CU/tasks/$1.json"; }
run "$HIVE" ct todo td01 "  write the docs "
eq "todo exits 0" 0 "$RC"
has "a task without a checklist gets the default one" "todo: td01 new checklist 'Small steps'" "$OUT"
eq "with the item, trimmed" "Small steps: write the docs" "$(checklists_of td01)"
w2=$(writes)
run "$HIVE" ct todo td01 "write the docs"
has "an item already there is not added twice" "already has 'write the docs'" "$OUT"
eq "and nothing is written" "$w2" "$(writes)"
run "$HIVE" ct todo td01 "bump the version"
eq "a second item goes to the same checklist" "Small steps: write the docs, bump the version" "$(checklists_of td01)"
run "$HIVE" ct todo td01 "tag it" --checklist Release
eq "--checklist names another one" "Small steps: write the docs, bump the version | Release: tag it" "$(checklists_of td01)"
run "$HIVE" ct todo td02 "second"
hasnt "an existing checklist is found whatever its case" "new checklist" "$OUT"
eq "and gets the item" "small STEPS: first, second" "$(checklists_of td02)"
echo 1 > "$FAKE_CU/lost"
run "$HIVE" ct todo td02 "third"
eq "an item whose answer was lost" 0 "$RC"
eq "is not added again by the retry" "small STEPS: first, second, third" "$(checklists_of td02)"
run "$HIVE" ct todo nosuch01 "anything"
eq "an unknown task is refused" 1 "$RC"
run "$HIVE" ct todo td01
eq "an item is required" 1 "$RC"
has "with the usage" 'usage: hive ct todo <id> "<item>"' "$ERR"

# =============================================================================
section "ct sync and the rate limit"
run "$HIVE" ct sync
eq "sync refreshes the cache" 0 "$RC"
has "and creates every taxonomy tag in the space" "mod-infra" "$(jq -r '.[].name' "$FAKE_CU/space-tags.json")"
echo 2 > "$FAKE_CU/429"
run "$HIVE" ct show thold01
eq "a 429 is waited out" 0 "$RC"

# =============================================================================
section "the token"
hasnt "never in curl's argv" "pk_fake_SECRET_TOKEN" "$(cat "$FAKE_CU/curl.argv")"
hasnt "never in a letter" "pk_fake_SECRET_TOKEN" "$(cat "$HIVE_DIR"/mail/*/*.json "$HIVE_DIR"/fronts/*/mail/*/*.json 2>/dev/null)"
hasnt "never in the log" "pk_fake_SECRET_TOKEN" "$(cat "$CU/sync.log")"
hasnt "never in a brief or meta" "pk_fake_SECRET_TOKEN" "$(cat "$HIVE_DIR"/drones/*/brief.md "$HIVE_DIR"/drones/*/meta.json 2>/dev/null)"
eq "the private directories are gone" 0 "$(find "$TMPDIR" -maxdepth 1 -name 'hive-cu.*' | wc -l)"
printf 'pk_other\n' > "$T/token"
run "$HIVE" ct show thold01
eq "a rejected token is 'unavailable'" 1 "$RC"
has "and says so" "the token was rejected" "$ERR"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
