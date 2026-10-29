#!/usr/bin/env bash
# clickup.sh — optional ClickUp task tracking for the swarm. Sourced by hive (the 'ct' commands, the
# 'hive task' gate, 'hive move') and by clickup-sync.sh. Off unless $HIVE_DIR/clickup/config exists:
# without it hive makes no ClickUp call and a brief needs no task.
#
# ClickUp is the source of truth. $HIVE_DIR/clickup/registry.tsv caches the space's open tasks and
# those closed in the last 30 days: it is what 'ct find' searches and what collisions are counted on
# while ClickUp is down. Categories are tags from one taxonomy for every front (taxonomy.tsv):
#   front   exactly one per task — the front whose coordinator leads it
#   module  at least one — the systems the task touches; collisions are counted on them
#   area    exactly one — what the work is for; duplicates are searched in it
#   type    at most one — e.g. an analysis, done once it is delivered
# A tag outside the taxonomy is refused with the list of the right ones: a typo never becomes a tag.
#
# The API token never reaches argv, a variable, a log, a letter or a lasting file: the output of
# token_cmd (or token_file) goes straight into a private 0700 directory, becomes a header file curl
# reads with -H @file, and the directory goes with the process (cu_cleanup).

CU_API=https://api.clickup.com/api/v2
CU_DIR="$HIVE_DIR/clickup"
CU_CONF="$CU_DIR/config"
CU_TAXONOMY="$CU_DIR/taxonomy.tsv"
CU_REGISTRY="$CU_DIR/registry.tsv"
CU_REGISTRY_FULL="$CU_DIR/registry.full"   # its mtime: when the last full refresh of the cache began
CU_LOG="$CU_DIR/sync.log"
# clickup-sync's memory of reports, by path and mtime: applied, refused (waiting for 'ct ack'), and
# failing on ClickUp itself (retried on every run).
CU_SYNC_STATE="$CU_DIR/sync.state"
CU_SYNC_FAILED="$CU_DIR/sync.failed"
CU_SYNC_RETRY="$CU_DIR/sync.retry"
# The start writes of a brief let through while ClickUp was down, one file each; clickup-sync replays them.
CU_STARTS="$CU_DIR/starts"
CU_COMMENT_MAX=8000                  # ClickUp takes 40000 characters; a report comment stays readable
CU_REGISTRY_TTL=600                  # 'ct find' refreshes a cache older than this, clickup-sync one not fully refreshed for this long
CU_REGISTRY_STALE=3600               # 'hive task' refreshes the whole cache, not only its changed tasks, once its last full refresh is older
CU_REGISTRY_OVERLAP=120              # the changed tasks are those updated since the last refresh began, less this (clock skew)
CU_GATE_BUDGET=10                    # seconds 'hive task' waits for ClickUp before counting it down
CU_KINDS="front module area type"
CU_ROW_HEADER=$'id\tstatus\tfront\tmodules\tarea\tparent\tname\tupdated'
CU_TMP="" CU_NO_TOKEN=0 CU_LOADED=0 CU_SPACE_TAGS="" CU_DEADLINE="" CU_START_PENDING="" CU_START_QUEUED=""
declare -A CU_CFG=() CU_STATUSES=()
declare -a CU_JQ_ARGS=() CU_RETRY_GUARD=()

cu_say() { echo "clickup: $*" >&2; }
cu_die() { cu_say "$*"; exit 1; }
cu_enabled() { [ -f "$CU_CONF" ]; }
cu_cfg() { printf '%s\n' "${CU_CFG[$1]:-}"; }
cu_trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s\n' "${s%"${s##*[![:space:]]}"}"; }

# --- configuration and taxonomy -----------------------------------------------

# cu_init — reads the config and the taxonomy once per process. Returns 1, saying why, when tracking
# is off or the config is incomplete.
cu_init() {
  [ "$CU_LOADED" = 1 ] && return 0
  cu_enabled || { cu_say "ClickUp tracking is off (no $CU_CONF)"; return 1; }
  local line k v
  # Split on the first '=' by hand: read with IFS='=' would drop a trailing '=' from the value.
  while IFS= read -r line; do
    k=${line%%=*}; v=""; [ "$k" = "$line" ] || v=${line#*=}
    k=$(cu_trim "$k"); [ -n "$k" ] && CU_CFG[$k]=$(cu_trim "$v")
  done < <(grep -vE '^[[:space:]]*(#|$)' "$CU_CONF")
  : "${CU_CFG[status_early]:=to do}" "${CU_CFG[status_active]:=in progress}" "${CU_CFG[status_closed]:=complete | closed}"
  : "${CU_CFG[status_start]:=in progress}" "${CU_CFG[status_done]:=complete}"
  : "${CU_CFG[prefix_front]:=front-}" "${CU_CFG[prefix_module]:=mod-}" "${CU_CFG[prefix_area]:=area-}" "${CU_CFG[prefix_type]:=type-}"
  : "${CU_CFG[checklist]:=Small steps}" "${CU_CFG[stale_testing_days]:=7}" "${CU_CFG[stale_hold_days]:=14}"
  # Set but empty turns rule 1 off, so only an absent key takes the default.
  : "${CU_CFG[stale_testing]=${CU_CFG[status_unverified]:-}}" "${CU_CFG[stale_testing_to]=${CU_CFG[status_done]}}"
  for k in workspace space list; do
    [ -n "${CU_CFG[$k]:-}" ] || { cu_say "$CU_CONF has no '$k'"; return 1; }
  done
  [ -n "${CU_CFG[token_cmd]:-}${CU_CFG[token_file]:-}" ] || { cu_say "$CU_CONF has neither 'token_cmd' nor 'token_file'"; return 1; }
  [ -s "$CU_TAXONOMY" ] || { cu_say "no taxonomy ($CU_TAXONOMY) — see taxonomy.tsv.example"; return 1; }
  CU_JQ_ARGS=(--argjson map "$(cu_taxonomy | jq -Rn '[inputs | split("\t") | {(.[1]): .[0]}] | add // {}')"
              --argjson pre "$(jq -nc --arg f "$(cu_prefix front)" --arg m "$(cu_prefix module)" --arg a "$(cu_prefix area)" --arg t "$(cu_prefix type)" \
                               '{front: $f, module: $m, area: $a, type: $t}')"
              --argjson closed "$(cu_statuses closed | jq -Rn '[inputs]')")
  CU_LOADED=1
}

# cu_list <key> — a '|'-separated config value, lower case, one a line.
cu_list() { cu_cfg "$1" | tr '|' '\n' | while IFS= read -r s; do s=$(cu_trim "${s,,}"); [ -z "$s" ] || echo "$s"; done; }
# cu_statuses <early|active|info|closed|start|done|unverified> — the configured statuses, lower case, one a line.
cu_statuses() { cu_list "status_$1"; }
# cu_status_is <status> <group>. A here-string, not a pipe: under pipefail grep -q leaving early
# would fail the pipe on a match.
cu_status_is() { grep -qxF -- "$1" <<<"$(cu_statuses "$2")"; }
cu_prefix() { cu_cfg "prefix_$1"; }

# cu_taxonomy — kind, tag, definition, epic, default front; comments, blank lines and the header skipped.
cu_taxonomy() {
  awk -F'\t' 'function t(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
              /^[[:space:]]*(#|$)/ { next }
              { k = tolower(t($1)); g = tolower(t($2)); if (k == "kind" || g == "") next
                print k "\t" g "\t" t($3) "\t" t($4) "\t" t($5) }' "$CU_TAXONOMY"
}
cu_tags() { cu_taxonomy | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }    # cu_tags <kind>
cu_short() { local p; p=$(cu_prefix "$1"); printf '%s\n' "${2#"$p"}"; }       # cu_short <kind> <tag>

# cu_tag <kind> <value> — the full tag for a value given with or without its prefix; refuses a value
# the taxonomy does not have, listing the ones it does.
cu_tag() {
  local kind=$1 v p known; v=$(cu_trim "${2,,}"); p=$(cu_prefix "$kind")
  known=$(cu_tags "$kind")
  grep -qxF -- "$v" <<<"$known" && { echo "$v"; return 0; }
  grep -qxF -- "$p$v" <<<"$known" && { echo "$p$v"; return 0; }
  cu_say "'$2' is no $kind of the taxonomy — known: $(while IFS= read -r t; do printf '%s ' "${t#"$p"}"; done <<<"$known")"
  return 1
}

# cu_tag_list <kind> <values> — values separated by commas or spaces; full tags, one a line.
cu_tag_list() {
  local kind=$1 v
  for v in ${2//,/ }; do cu_tag "$kind" "$v" || return 1; done
}

# cu_front_tag <front> — the tag of a front ('default' for the default one).
cu_front_tag() { cu_tag front "${1:-default}"; }

# cu_epic_of <area-tag> — the epic the taxonomy names for an area, if any.
cu_epic_of() { cu_taxonomy | awk -F'\t' -v t="$1" '$1 == "area" && $2 == t { print $4 }'; }

# --- token and transport ------------------------------------------------------

# cu_cleanup — on the way out: a start record still being made goes to the queue, the private directory goes.
cu_cleanup() {
  cu_start_publish
  [ -n "$CU_TMP" ] || return 0
  local f
  for f in "$CU_TMP/tok" "$CU_TMP/auth"; do [ -f "$f" ] && shred -u "$f" 2>/dev/null; done
  rm -rf "${CU_TMP:?}"
  CU_TMP=""
}

# cu_tmpdir — the process's private directory. Call it in the main shell, never inside $(...): the
# directory and its cleanup trap belong to the process that made them.
cu_tmpdir() {
  [ -n "$CU_TMP" ] && [ -d "$CU_TMP" ] && return 0
  CU_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hive-cu.XXXXXX") || { cu_say "cannot create a private directory"; return 1; }
  trap cu_cleanup EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
}

# cu_ready — reads the token once per process (main shell only, like cu_tmpdir). 1 when there is none.
cu_ready() {
  cu_init || return 1
  cu_tmpdir || return 1
  [ -s "$CU_TMP/auth" ] && return 0
  [ "$CU_NO_TOKEN" = 0 ] || return 1
  local cmd file max
  cmd=$(cu_cfg token_cmd); file=$(cu_cfg token_file); file=${file/#\~/$HOME}
  if [ -n "$cmd" ]; then
    max=$(cu_time 60); [ "$max" -gt 0 ] || { cu_say "no time left to run token_cmd"; return 1; }
    timeout "$max" bash -c "$cmd" > "$CU_TMP/tok" 2>"$CU_TMP/tok.err" </dev/null \
      || { cu_say "token_cmd failed: $(tail -1 "$CU_TMP/tok.err" 2>/dev/null)"; CU_NO_TOKEN=1; return 1; }
  else
    cat -- "$file" > "$CU_TMP/tok" 2>/dev/null || { cu_say "cannot read token_file $file"; CU_NO_TOKEN=1; return 1; }
  fi
  if [ ! -s "$CU_TMP/tok" ]; then cu_say "the token source gave no token"; CU_NO_TOKEN=1; return 1; fi
  { printf 'Authorization: '; head -1 "$CU_TMP/tok" | tr -d '\r\n'; printf '\n'; } > "$CU_TMP/auth"
  shred -u "$CU_TMP/tok"
}

# cu_time <seconds> — that many, or fewer when the deadline CU_DEADLINE (epoch seconds, set by the
# 'hive task' gate) comes sooner: 0 once it passed.
cu_time() {
  local left
  [ -n "$CU_DEADLINE" ] || { echo "$1"; return; }
  left=$(( CU_DEADLINE - $(date +%s) )); [ "$left" -gt 0 ] || left=0
  echo $(( left < $1 ? left : $1 ))
}
cu_spent() { [ -n "$CU_DEADLINE" ] && [ "$(cu_time 1)" = 0 ]; }   # the deadline came: no call is made

# cu_api <METHOD> <path> [json-body] — prints the response body. Returns 0 on success, 3 when the
# object does not exist (ClickUp answers 401 OAUTH_027 for a task id nobody has, not 404), 1 when
# ClickUp refuses the call (its message on stderr), 2 when ClickUp is unavailable: no token, network
# down, 5xx, a rejected token, or a rate limit beyond the retries. No attempt and no wait runs past
# CU_DEADLINE. A write whose attempt timed out or got a 5xx may have landed all the same: when
# CU_RETRY_GUARD holds a command, it runs before every retry (its calls one attempt each, CU_TRIES=1),
# and its success ends the call as done.
CU_TRIES=4
cu_api() {
  local method=$1 path=$2 body=${3:-} attempt code="" wait reset err max
  local -a guard=("${CU_RETRY_GUARD[@]}"); local -a CU_RETRY_GUARD=()   # not for the guard's own calls
  [ -n "$CU_TMP" ] && [ -s "$CU_TMP/auth" ] || { cu_say "no API token (cu_ready failed or was not called)"; return 2; }
  local out="$CU_TMP/out.$BASHPID" hdr="$CU_TMP/hdr.$BASHPID" data="$CU_TMP/data.$BASHPID"
  local -a args=(-sS -X "$method" -H "@$CU_TMP/auth" -D "$hdr" -o "$out" -w '%{http_code}')
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$data"
    args+=(-H 'Content-Type: application/json' --data-binary "@$data")
  fi
  for (( attempt = 1; attempt <= CU_TRIES; attempt++ )); do
    max=$(cu_time 30); [ "$max" -gt 0 ] || break
    if [ "$attempt" -gt 1 ] && [ "$code" != 429 ] && [ ${#guard[@]} -gt 0 ] && CU_TRIES=1 "${guard[@]}" >/dev/null 2>&1; then
      rm -f "$out" "$hdr" "$data"; return 0
    fi
    code=$(curl "${args[@]}" --connect-timeout "$(( max < 5 ? max : 5 ))" --max-time "$max" "$CU_API$path" 2>/dev/null) || code=000
    case "$code" in
      2??) cat "$out"; rm -f "$out" "$hdr" "$data"; return 0 ;;
      429) reset=$(grep -i '^x-ratelimit-reset:' "$hdr" 2>/dev/null | tr -dc '0-9')
           wait=$(( ${reset:-0} - $(date +%s) ))
           [ "$wait" -ge 1 ] || wait=1; [ "$wait" -le 60 ] || wait=60 ;;
      5??|000) wait=$((attempt * 2)) ;;
      *) err=$(jq -r '[.err, .ECODE] | map(select(. != null)) | join(" ")' "$out" 2>/dev/null)
         rm -f "$out" "$hdr" "$data"
         case "$code:$err" in
           404:*|*ITEM_0*|*OAUTH_027*) cu_say "$method $path: not found${err:+ ($err)}"; return 3 ;;
           401:*) cu_say "$method $path: the token was rejected${err:+ ($err)}"; return 2 ;;
         esac
         cu_say "$method $path: HTTP $code${err:+ ($err)}"; return 1 ;;
    esac
    [ "$attempt" -lt "$CU_TRIES" ] && sleep "$(cu_time "$wait")"
  done
  rm -f "$out" "$hdr" "$data"
  cu_say "$method $path: ClickUp unavailable (last HTTP ${code:-000})"
  return 2
}

cu_uri() { jq -rn --arg s "$1" '$s | @uri'; }

# --- task views ---------------------------------------------------------------

# jq definitions: a task's tags of one kind (full or without the prefix), whether it is closed, and its
# registry row. $map (tag -> kind), $pre (kind -> prefix) and $closed come from cu_init.
CU_JQ_DEFS='
def tagnames: [.tags[]?.name | ascii_downcase];
def kind($k): [tagnames[] | select($map[.] == $k)];
def short($k): kind($k) | map(ltrimstr($pre[$k]));
def closed: (.status.type // "") == "closed" or ((.status.status // "") | ascii_downcase | IN($closed[]));
def row: [.id, (.status.status // "" | ascii_downcase), (short("front") | join(",")), (short("module") | join(",")),
          (short("area") | join(",")), (.parent // ""), (.name | gsub("[\t\n\r]"; " ")),
          ((.date_updated // "0") | tonumber / 1000 | strflocaltime("%Y-%m-%d %H:%M"))] | @tsv;'

cu_jq() { jq -r "${CU_JQ_ARGS[@]}" "$CU_JQ_DEFS $2" <<<"$1"; }   # cu_jq <task-json> <filter>
cu_task() { cu_api GET "/task/$1?include_subtasks=true"; }
cu_status_of() { jq -r '.status.status | ascii_downcase' <<<"$1"; }

# cu_space_tasks <include-closed:true|false> [updated-after-ms] — every task of the space, one JSON a line.
cu_space_tasks() {
  local q json n page=0
  q="space_ids%5B%5D=$(cu_cfg space)&subtasks=true&include_closed=$1"
  [ -n "${2:-}" ] && q+="&date_updated_gt=$2"
  while [ "$page" -lt 50 ]; do
    json=$(cu_api GET "/team/$(cu_cfg workspace)/task?$q&page=$page") || return
    jq -c --arg d "$(cu_cfg decision_list)" '.tasks[] | select($d == "" or .list.id != $d)' <<<"$json"   # decisions are no tasks
    n=$(jq '.tasks | length' <<<"$json")
    [ "$n" -ge 100 ] && [ "$(jq -r '.last_page // false' <<<"$json")" != true ] || break
    page=$((page + 1))
  done
}

# cu_space_rows <include-closed:true|false> [updated-after-ms] — every task of the space as registry rows.
cu_space_rows() {
  local tasks; tasks=$(cu_space_tasks "$@") || return
  [ -z "$tasks" ] || jq -r "${CU_JQ_ARGS[@]}" "$CU_JQ_DEFS row" <<<"$tasks"
}

# cu_registry_write <rows> <began> — the cache from these rows (the first of an id wins), written
# atomically, its mtime the time the refresh began: the next catch-up starts from there.
cu_registry_write() {
  local tmp
  mkdir -p "$CU_DIR"
  tmp=$(mktemp "$CU_DIR/.registry.XXXXXX") || return 1
  { printf '%s\n' "$CU_ROW_HEADER"; printf '%s\n' "$1" | awk -F'\t' 'NF && !seen[$1]++'; } > "$tmp"
  touch -d "@$2" "$tmp" && mv -f "$tmp" "$CU_REGISTRY"
}

# cu_registry_refresh — open tasks plus those closed in the last 30 days.
cu_registry_refresh() {
  local open closed began since
  began=$(date +%s); since=$(( (began - 30 * 86400) * 1000 ))
  open=$(cu_space_rows false) || return
  closed=$(cu_space_rows true "$since") || return
  cu_registry_write "$open"$'\n'"$closed" "$began" && touch -d "@$began" "$CU_REGISTRY_FULL"
}

# cu_age <file> — seconds since its mtime, a lot when there is no such file.
cu_age() { [ -f "$1" ] && echo $(( $(date +%s) - $(stat -c %Y "$1") )) || echo 999999999; }

# cu_registry_catchup — the cache brought up to date by the tasks updated since its last refresh, closed
# ones too; a full refresh when there is no cache or its last full refresh is older than
# CU_REGISTRY_STALE. A task deleted or moved out of the space is in no listing: it stays in the cache
# until the next full refresh, so the gate checks a collision with it (cu_vanished).
# The rows it starts from and their time come from one opening of the cache: one written meanwhile (a slow
# full refresh of clickup-sync, stamped when it began) is never merged under this catch-up's later time.
cu_registry_catchup() {
  local began since rows base
  [ -f "$CU_REGISTRY" ] && [ "$(cu_age "$CU_REGISTRY_FULL")" -lt "$CU_REGISTRY_STALE" ] || { cu_registry_refresh; return; }
  began=$(date +%s)
  { since=$(( ($(stat -L -c %Y /dev/stdin) - CU_REGISTRY_OVERLAP) * 1000 )); base=$(tail -n +2); } < "$CU_REGISTRY"
  rows=$(cu_space_rows true "$since") || return
  cu_registry_write "$rows"$'\n'"$base" "$began"
}

# cu_vanished <collisions> — the tasks among them ClickUp no longer has in the space (deleted, or moved
# out of it since the last full refresh), one id a line, dropped from the cache. A task ClickUp does
# not answer for stays: a collision is never waived on a guess.
cu_vanished() {
  local id st json rc gone=""
  while IFS=$'\t' read -r id st _; do
    [ -n "$id" ] && [ "$st" != "?" ] || continue       # '?': only a drone's claim, the cache has no such task
    json=$(cu_task "$id" 2>/dev/null); rc=$?
    if [ "$rc" = 3 ] || { [ "$rc" = 0 ] && [ "$(jq -r --arg s "$(cu_cfg space)" '(.space.id // "" | tostring) as $i | $i != "" and $i != $s' <<<"$json")" = true ]; }; then
      gone+="$id"$'\n'
    fi
  done <<<"$1"
  [ -n "$gone" ] || return 0
  cu_registry_write "$(awk -F'\t' -v g="$gone" 'BEGIN { n = split(g, x, "\n"); for (i = 1; i <= n; i++) drop[x[i]] }
                       NR > 1 && !($1 in drop)' "$CU_REGISTRY")" "$(stat -c %Y "$CU_REGISTRY")"
  printf '%s' "$gone"
}

# cu_registry_ready <max-age-seconds> — a registry no older than that when ClickUp answers, else the
# cache with a warning (CU_CACHED=1). 1 when there is neither.
CU_CACHED=0
cu_registry_ready() {
  local age=999999999
  [ -f "$CU_REGISTRY" ] && age=$(( $(date +%s) - $(stat -c %Y "$CU_REGISTRY") ))
  CU_CACHED=0
  [ "$age" -lt "$1" ] && return 0
  cu_ready && cu_registry_refresh && return 0
  [ -f "$CU_REGISTRY" ] || { cu_say "ClickUp unreachable and no cache ($CU_REGISTRY)"; return 1; }
  CU_CACHED=1
  cu_say "ClickUp unreachable — using the cache from $(date -r "$CU_REGISTRY" '+%Y-%m-%d %H:%M')"
}

# cu_rows <modules> <area> <front> <with-closed:true|false> — registry rows having any of the modules
# (short names, comma separated), the area and the front; an empty filter matches everything.
cu_rows() {
  [ -f "$CU_REGISTRY" ] || return 0
  awk -F'\t' -v m="$1" -v a="$2" -v f="$3" -v c="$4" -v closed="|$(cu_statuses closed | paste -sd'|')|" '
    function any(have, want,   n, w, i) { if (want == "") return 1
      n = split(want, w, ","); for (i = 1; i <= n; i++) if (index("," have ",", "," w[i] ",")) return 1; return 0 }
    NR > 1 && any($3, f) && any($4, m) && any($5, a) && (c == "true" || !index(closed, "|" $2 "|"))' "$CU_REGISTRY"
}

# cu_match <words...> — reads registry rows, prints those whose name holds at least half of the words,
# best first. A word counts from 3 letters and is cut to its first 6, so inflected endings still match.
cu_match() {
  awk -F'\t' -v q="$*" '
    BEGIN { n = split(tolower(q), w, /[^[:alnum:]]+/)
            for (i = 1; i <= n; i++) if (length(w[i]) >= 3) s[++k] = substr(w[i], 1, 6)
            need = int((k + 1) / 2) }
    k > 0 { name = tolower($7); c = 0
            for (i = 1; i <= k; i++) if (index(name, s[i])) c++
            if (c >= need) print c "\t" $0 }' | sort -t$'\t' -k1,1nr | cut -f2-
}

cu_print_rows() {  # registry rows -> id, status, front, modules, area, parent, name
  awk -F'\t' 'function d(s) { return s == "" ? "-" : s }
              { printf "%-11s %-20s %-10s %-16s %-18s %-11s %s\n", $1, $2, d($3), d($4), d($5), d($6), $7 }'
}
cu_print_header() { printf '%-11s %-20s %-10s %-16s %-18s %-11s %s\n' id status front modules area parent name; }

# --- statuses -----------------------------------------------------------------

# cu_list_statuses <list-id> — a list's statuses, lower case (the space's when the list has none).
cu_list_statuses() {
  local json st
  json=$(cu_api GET "/list/$1") || return
  st=$(jq -r '.statuses[]?.status | ascii_downcase' <<<"$json")
  if [ -z "$st" ]; then
    json=$(cu_api GET "/space/$(cu_cfg space)") || return
    st=$(jq -r '.statuses[]?.status | ascii_downcase' <<<"$json")
  fi
  printf '%s\n' "$st"
}

# cu_status_valid <list-id> <status> — 0, or 4 for a status the list does not have, 2 when ClickUp is down.
cu_status_valid() {
  if [ -z "${CU_STATUSES[$1]+x}" ]; then CU_STATUSES[$1]=$(cu_list_statuses "$1") || { unset 'CU_STATUSES[$1]'; return 2; }; fi
  grep -qxF -- "$2" <<<"${CU_STATUSES[$1]}" && return 0
  cu_say "status '$2' is not one of: $(paste -sd, <<<"${CU_STATUSES[$1]}" | sed 's/,/, /g')"
  return 4
}

cu_norm_status() {  # what drones write -> a status name ('done' and 'complete' mean status_done)
  local s; s=$(cu_trim "${1,,}")
  case "$s" in done|complete|completed) s=$(cu_statuses done | head -1) ;; esac
  printf '%s\n' "$s"
}

# --- writes (each is a no-op when the task already is that way) ---------------

cu_tag_color() {
  case "$(cu_taxonomy | awk -F'\t' -v t="$1" '$2 == t { print $1; exit }')" in
    front) echo '#1e88e5' ;; module) echo '#43a047' ;; area) echo '#fb8c00' ;; type) echo '#8e24aa' ;; *) echo '#7b68ee' ;;
  esac
}

# cu_ensure_tag <tag> — creates a taxonomy tag missing from the space, coloured by its kind.
cu_ensure_tag() {
  if [ -z "$CU_SPACE_TAGS" ]; then
    CU_SPACE_TAGS=$(cu_api GET "/space/$(cu_cfg space)/tag" | jq -r '.tags[]?.name | ascii_downcase') || return 2
    CU_SPACE_TAGS+=$'\n'
  fi
  grep -qxF -- "$1" <<<"$CU_SPACE_TAGS" && return 0
  cu_api POST "/space/$(cu_cfg space)/tag" \
    "$(jq -nc --arg t "$1" --arg bg "$(cu_tag_color "$1")" '{tag: {name: $t, tag_fg: "#ffffff", tag_bg: $bg}}')" >/dev/null || return
  CU_SPACE_TAGS+="$1"$'\n'
}

# cu_tags_change <task-json> <tags to add> <tags to remove> — lists one tag a line.
cu_tags_change() {
  local id have t; id=$(jq -r .id <<<"$1"); have=$(cu_jq "$1" 'tagnames[]')
  while IFS= read -r t; do
    [ -n "$t" ] && ! grep -qxF -- "$t" <<<"$have" || continue
    { cu_ensure_tag "$t" && cu_api POST "/task/$id/tag/$(cu_uri "$t")" >/dev/null; } || return
  done <<<"$2"
  while IFS= read -r t; do
    [ -n "$t" ] && grep -qxF -- "$t" <<<"$have" || continue
    cu_api DELETE "/task/$id/tag/$(cu_uri "$t")" >/dev/null || return
  done <<<"$3"
}

# cu_tags_set <task-json> <kind> <tags> — the task ends with exactly these tags of that kind.
cu_tags_set() {
  local old; old=$(cu_jq "$1" "kind(\"$2\")[]")
  cu_tags_change "$1" "$3" "$(awk -v keep="$3" 'BEGIN { n = split(keep, k, "\n"); for (i = 1; i <= n; i++) want[k[i]] } !($0 in want)' <<<"$old")"
}

cu_set_parent() {  # cu_set_parent <task-json> <parent-id>
  local id; id=$(jq -r .id <<<"$1")
  [ "$(jq -r '.parent // ""' <<<"$1")" = "$2" ] && return 0
  [ "$id" != "$2" ] || { cu_say "$id cannot be its own parent"; return 1; }
  cu_api PUT "/task/$id" "$(jq -nc --arg p "$2" '{parent: $p}')" >/dev/null
}

# cu_set_status <task-json> <status> — validated against the statuses of the task's list (4: not one).
cu_set_status() {
  local status list; status=$(cu_norm_status "$2")
  [ "$(cu_status_of "$1")" = "$status" ] && return 0
  list=$(jq -r '.list.id // empty' <<<"$1")
  cu_status_valid "${list:-$(cu_cfg list)}" "$status" || return
  cu_api PUT "/task/$(jq -r .id <<<"$1")" "$(jq -nc --arg s "$status" '{status: $s}')" >/dev/null
}

# cu_comment <id> <text> [marker] — before a retry it looks for the marker the text carries (else for
# the text): an attempt that timed out may have landed, and a retry must not double it.
cu_comment() {
  local -a CU_RETRY_GUARD=(cu_has_comment "$1" "${3:-$2}" ${3:+--contains})
  cu_api POST "/task/$1/comment" "$(jq -nc --arg t "$2" '{comment_text: $t, notify_all: false}')" >/dev/null
}

# cu_comments <id> [enough] — the task's comments, newest first, as {comments, more}. ClickUp gives
# 25 a page; the next page starts from the oldest comment of the one before (start, start_id). Pages
# are read until one comes short, the comments so far meet the jq filter enough, or 20 pages (500
# comments, well past what a task gathers, so a runaway task costs at most 20 calls); more is true
# when older comments were left unread. 2 when ClickUp fails on a page or the budget runs out:
# the comments read so far are printed all the same.
cu_comments() {
  local id=$1 enough=${2:-false} q="" json all='[]' state="more" page rc=0
  for (( page = 0; page < 20; page++ )); do
    [ "$page" = 0 ] || ! cu_spent || { rc=2; break; }
    json=$(cu_api GET "/task/$id/comment$q") || { rc=2; break; }
    # A page may begin with the comment it starts from: one seen already is not taken twice. The
    # comments so far go on stdin, not argv: a page of long comments outgrows the 128 KB of one argument.
    json=$(printf '%s\n%s' "$all" "$json" | jq -sc '.[0] as $all | .[1] | ($all | map(.id // empty)) as $seen
        | [.comments[]? | select(.id == null or (.id | IN($seen[])) == false)] as $new | ($all + $new) as $a
        | {a: $a, state: (if (.comments // [] | length) < 25 or ($new | length) == 0 then "end"
                          elif ($a | '"$enough"') then "enough" else "more" end),
           q: ($a[-1] | "?start=\(.date // "")&start_id=\(.id // "" | @uri)")}') || { rc=2; break; }
    all=$(jq -c .a <<<"$json"); state=$(jq -r .state <<<"$json"); q=$(jq -r .q <<<"$json")
    [ "$state" = more ] || break
  done
  jq -c --argjson more "$([ "$state" = end ] && echo false || echo true)" '{comments: ., more: $more}' <<<"$all"
  return "$rc"
}

# cu_has_comment <id> <text> [--contains] — among the task's comments (cu_comments): one equal to the
# text (whitespace-insensitive), or with --contains one holding it. 2 when ClickUp is down.
cu_has_comment() {
  local json rc f
  f='def n: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
     ('"$(jq -rn --arg t "$2" '$t | @json')"' | n) as $want
     | any(.[]; (.comment_text // "" | n) as $c | if '"$([ -n "${3:-}" ] && echo true || echo false)"' then $c | contains($want) else $c == $want end)'
  json=$(cu_comments "$1" "$f"); rc=$?
  jq -e ".comments | $f" <<<"$json" >/dev/null && return 0
  [ "$rc" = 2 ] && return 2
  return 1
}

cu_comment_once() {  # cu_comment_once <id> <text> [marker] — never twice the same comment (or marker)
  local rc; cu_has_comment "$1" "${3:-$2}" ${3:+--contains}; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 2 ] && return 2
  cu_spent && return 2   # the look took what was left of the budget: the comment waits for clickup-sync
  cu_comment "$@"
}

# cu_set_front <task-json> <front-tag> <why> — hands a task to another front, with a comment.
cu_set_front() {
  local old id; id=$(jq -r .id <<<"$1"); old=$(cu_jq "$1" 'kind("front") | join(",")')
  [ "$old" = "$2" ] && return 0
  cu_tags_set "$1" front "$2" || return
  cu_comment "$id" "🤖 task handed over from ${old:-no front} to $2: $3"
}

# cu_checklist_id <task-id> <name> — the id of the task's checklist of that name (case does not
# matter); 1 when it has none, 2 when ClickUp is down.
cu_checklist_id() {
  local json; json=$(cu_task "$1") || return 2
  jq -re --arg n "${2,,}" 'first(.checklists[]? | select((.name // "" | ascii_downcase) == $n) | .id)' <<<"$json"
}

# cu_checklist_has <task-id> <checklist-id> <item> — 0 when that checklist holds the item.
cu_checklist_has() {
  local json; json=$(cu_task "$1") || return 2
  jq -e --arg c "$2" --arg i "$3" 'any(.checklists[]? | select(.id == $c) | .items[]?; .name == $i)' <<<"$json" >/dev/null
}

# cu_prs <id> — the pull requests the reports of drones named in the task's comments.
cu_prs() {
  cu_api GET "/task/$1/comment" 2>/dev/null \
    | jq -r '.comments[]?.comment_text // "" | split("\n")[] | select(startswith("PR: ")) | ltrimstr("PR: ")' | awk '!seen[$0]++'
}

# --- briefs and collisions ----------------------------------------------------

# cu_brief_keys <canonical> <alias-key> — the line keys a brief may use, lower case: the English one
# and the aliases the config gives (e.g. alias_modules = Modules in another language).
cu_brief_keys() {
  printf '%s\n' "${1,,}"
  cu_cfg "$2" | tr '|' '\n' | while IFS= read -r a; do a=$(cu_trim "$a"); [ -z "$a" ] || printf '%s\n' "${a,,}"; done
}

# cu_brief_values <file> <canonical> <alias-key> — the value of every line '<key>: <value>'.
cu_brief_values() {
  awk -v keys="$(cu_brief_keys "$2" "$3")" '
    BEGIN { n = split(keys, k, "\n") }
    { line = $0; sub(/^[[:space:]>*-]+/, "", line); low = tolower(line)
      for (i = 1; i <= n; i++) if (index(low, k[i] ":") == 1) {
        v = substr(line, length(k[i]) + 2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; next } }' "$1"
}

# cu_modules <values> — short module names, comma separated; refuses a module outside the taxonomy.
cu_modules() {
  local tags t out=""
  tags=$(cu_tag_list module "$1") || return 1
  while IFS= read -r t; do [ -z "$t" ] || out+="${out:+,}$(cu_short module "$t")"; done <<<"$tags"
  printf '%s\n' "$out"
}

# cu_brief_header <brief> — the 'Modules:' and 'Impact:' lines (CU_MODS, CU_IMPACT: short names) and
# every 'Collision checked: <id> — <reason>' line (CU_CHECKED). 1 with CU_GATE_MSG when one is wrong.
cu_brief_header() {
  local mods impact none
  mods=$(cu_brief_values "$1" Modules alias_modules | head -1)
  impact=$(cu_brief_values "$1" Impact alias_impact | head -1)
  none=$(cu_brief_keys none alias_none)
  if [ -z "$mods" ]; then CU_GATE_MSG="brief has no 'Modules: <module>[, <module>]' line (modules: $(cu_tags module | while IFS= read -r t; do printf '%s ' "$(cu_short module "$t")"; done))"; return 1; fi
  if [ -z "$impact" ]; then CU_GATE_MSG="brief has no 'Impact: <module>[, <module>]' line ('Impact: none' when it touches nothing else)"; return 1; fi
  CU_MODS=$(cu_modules "$mods" 2>&1) || { CU_GATE_MSG="Modules: $CU_MODS"; return 1; }
  if grep -qxF -- "$(cu_trim "${impact,,}")" <<<"$none"; then CU_IMPACT=""
  else CU_IMPACT=$(cu_modules "$impact" 2>&1) || { CU_GATE_MSG="Impact: $CU_IMPACT"; return 1; }
  fi
  CU_CHECKED=$(cu_brief_values "$1" "Collision checked" alias_collision)
}

# cu_brief_rules <brief> — the boundary blocks its 'Rules:' lines name, lower case, one a line: the
# lines hive's rules_expand reads (a list item too, never one in a code fence).
cu_brief_rules() {
  awk -v kw='rules' '
    /^ ? ? ?(```|~~~)/ { f = $0; sub(/^ +/, "", f); f = substr(f, 1, 3)
      if (fence == "") { fence = f; next }
      if (f == fence) { fence = ""; next } }
    fence != "" { next }
    { low = tolower($0); re = "^ ? ? ?([>*_-]+[[:space:]]*)*(" kw ")[*_]*[[:space:]]*:[*_]*[[:space:]]*"
      if (!match(low, re)) next
      arg = substr(low, RLENGTH + 1); gsub(/^[ *_`.]+|[ *_`.]+$/, "", arg)
      n = split(arg, a, /[[:space:],;`]+/); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' "$1"
}

# cu_read_only <brief> — 0 when its 'Rules:' lines name a block of read_only_rules (e.g. an analysis or
# a review, whatever other blocks they name): its drone changes no code, so it collides with nobody.
cu_read_only() {
  local ro; ro=$(cu_list read_only_rules)
  [ -n "$ro" ] && grep -qxF -- "$ro" <<<"$(cu_brief_rules "$1")"
}

# cu_claims [except-front except-drone] — CU_CLAIMS: the drones at work on a task (hive's
# drone_claims: front, drone, task, modules), every front. Empty where hive is not around.
cu_claims() {
  CU_CLAIMS="$CU_TMP/claims"
  if declare -F drone_claims >/dev/null; then drone_claims "${1:-}" "${2:-}" > "$CU_CLAIMS"; else : > "$CU_CLAIMS"; fi
}

# cu_drone_refs <ids> — the drones of every front whose meta.json or brief names one of these task
# ids (one a line): id, drone, alive (1 or 0), when its brief, meta or report last changed and when its
# report did (0: none), in epoch seconds. Empty where hive is not around.
cu_drone_refs() {
  local f d pane alive changed reported ids t
  declare -F front_names >/dev/null || return 0
  ids=$(grep -v '^$' <<<"$1") || return 0
  for f in $(front_names); do
    for d in "$(front_dir "$f")"/drones/*/; do
      d=${d%/}; [ -d "$d" ] || continue
      t=$( { jq -r '.clickup_task // empty' "$d/meta.json" 2>/dev/null; grep -owF -- "$ids" "$d/brief.md" 2>/dev/null; } \
           | grep -xF -- "$ids" | sort -u)
      [ -n "$t" ] || continue
      pane=$(jq -r '.pane_id // ""' "$d/meta.json" 2>/dev/null)
      alive=0; [ -n "$pane" ] && [ "$(pane_status "$pane")" != dead ] && alive=1
      changed=$(stat -c %Y "$d/brief.md" "$d/meta.json" "$d/report.md" 2>/dev/null | sort -n | tail -1)
      reported=$(stat -c %Y "$d/report.md" 2>/dev/null) || reported=0
      awk -v d="${d##*/}" -v a="$alive" -v c="${changed:-0}" -v r="$reported" '{ print $0 "\t" d "\t" a "\t" c "\t" r }' <<<"$t"
    done
  done
}

# cu_collisions <task|-> <modules> — the tasks a drone on <task> working in <modules> would collide with:
# a task in an active status sharing a module, other than the task itself, its ancestors and its
# subtasks, and not an epic (a task with subtasks); plus the tasks living drones hold in a shared
# module, whatever their status, unless the cache has the task closed. One line each: id, status,
# front, shared modules, name, drones. With 'info': instead the tasks in an info status (status_info)
# that would collide the same way, but that no living drone holds — listed, never collisions. An
# info task a living drone holds collides, whatever modules the drone's brief names.
cu_collisions() {
  local reg=$CU_REGISTRY; [ -f "$reg" ] || reg=/dev/null
  awk -F'\t' -v self="$1" -v want="$2" -v active="|$(cu_statuses active | paste -sd'|')|" -v claims="$CU_CLAIMS" \
      -v closed="|$(cu_statuses closed | paste -sd'|')|" -v info="|$(cu_statuses info | paste -sd'|')|" -v mode="${3:-}" '
    function shared(mods,   n, a, i, out) { n = split(mods, a, ","); out = ""
      for (i = 1; i <= n; i++) if (a[i] != "" && index("," want ",", "," a[i] ",") && !index("," out ",", "," a[i] ",")) out = out (out == "" ? "" : ",") a[i]
      return out }
    function union(a, b,   n, x, i) { n = split(b, x, ",")
      for (i = 1; i <= n; i++) if (!index("," a ",", "," x[i] ",")) a = a "," x[i]
      return a }
    function related(id,   p, g) {
      if (id == self) return 1
      for (p = parent[self]; p != "" && g++ < 50; p = parent[p]) if (p == id) return 1
      for (p = parent[id]; p != "" && g++ < 100; p = parent[p]) if (p == self) return 1
      return 0 }
    FILENAME == claims { nc++; cfront[nc] = $1; cdrone[nc] = $2; ctask[nc] = $3; cmods[nc] = $4; next }
    $1 != "id" { ids[++n] = $1; status[$1] = $2; front[$1] = $3; mods[$1] = $4; parent[$1] = $6; name[$1] = $7
                 if ($6 != "") haschild[$6] = 1 }
    END {
      for (i = 1; i <= n; i++) { id = ids[i]
        if (related(id) || (id in haschild)) continue
        s = shared(mods[id]); if (s == "") continue
        if (index(active, "|" status[id] "|")) hit[id] = s
        else if (index(info, "|" status[id] "|")) seen[id] = s }
      for (j = 1; j <= nc; j++) { id = ctask[j]
        if (id == "" || related(id) || ((id in status) && index(closed, "|" status[id] "|"))) continue
        s = shared(cmods[j]); if (s == "" && (id in seen)) s = seen[id]
        if (s == "") continue
        hit[id] = (id in hit) ? union(hit[id], s) : s
        drones[id] = drones[id] (drones[id] == "" ? "" : ",") cdrone[j] " (front " cfront[j] ")" }
      if (mode == "info") { for (id in seen) if (!(id in hit)) printf "%s\t%s\t%s\t%s\t%s\t\n", id, status[id], front[id], seen[id], name[id]; exit }
      for (id in hit) printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, (id in status) ? status[id] : "?", front[id], hit[id], name[id], drones[id]
    }' "$CU_CLAIMS" "$reg" | sort
}

cu_print_collisions() {  # collision lines -> readable, with each task's pull requests while ClickUp answers
  local id st fr sh nm dr prs
  while IFS=$'\037' read -r id st fr sh nm dr; do
    prs=""; [ "${CU_UP:-0}" = 1 ] && prs=$(cu_prs "$id" | paste -sd' ')
    printf '  %s  [%s]  front %s  shared modules: %s  %s%s%s\n' "$id" "$st" "${fr:--}" "$sh" "${nm:-?}" \
      "${dr:+  — drone $dr}" "${prs:+  — PRs: $prs}"
  done < <(tr '\t' '\037' <<<"$1")
}

# cu_settle <collisions> — every collision needs its own 'Collision checked: <id> — <reason>' line in
# CU_CHECKED; a line without a reason or for a task that does not collide is refused too. Leaves the
# accepted ones in CU_SETTLED (id, reason, shared modules).
cu_settle() {
  local col=$1 line cid reason missing=""
  CU_SETTLED=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cid=${line%%[[:space:]—–:-]*}
    reason=$(sed -E 's/^[^[:space:]—–:-]+//; s/^[[:space:]]*(—|–|-|:)*[[:space:]]*//' <<<"$line")
    if ! grep -qxF -- "$cid" <<<"$(cut -f1 <<<"$col")"; then
      grep -qxF -- "$cid" <<<"$CU_GONE" && continue      # the task is gone from ClickUp since the brief was written
      grep -qxF -- "$cid" <<<"$(cut -f1 <<<"$CU_INFO")" && continue   # listed for information only: no note either
      CU_GATE_MSG="'Collision checked: $cid' — $cid is not one of the collisions$([ -n "$col" ] && printf ' (%s)' "$(cut -f1 <<<"$col" | paste -sd' ')")"
      return 1
    fi
    [ -n "$reason" ] || { CU_GATE_MSG="'Collision checked: $cid' gives no reason — say why the work does not clash"; return 1; }
    CU_SETTLED+="$cid"$'\t'"$reason"$'\t'"$(awk -F'\t' -v i="$cid" '$1 == i { print $4 }' <<<"$col")"$'\n'
  done <<<"$CU_CHECKED"
  while IFS= read -r cid; do
    [ -n "$cid" ] && ! grep -qxF -- "$cid" <<<"$(cut -f1 <<<"$CU_SETTLED")" && missing+="$cid "
  done < <(cut -f1 <<<"$col")
  [ -z "$missing" ] && return 0
  CU_GATE_MSG="collision with tasks in progress:
$(cu_print_collisions "$(awk -F'\t' -v m=" $missing" 'index(m, " " $1 " ")' <<<"$col")")
Wait for them, or once you checked the work does not clash add one line per task to the brief:
  Collision checked: <id> — <why it does not clash>"
  return 1
}

# --- the 'hive task' gate -----------------------------------------------------

CU_GATE_MSG="" CU_GATE_TASK="" CU_GATE_ID="" CU_UP=0 CU_MODS="" CU_IMPACT="" CU_CHECKED="" CU_SETTLED="" CU_CLAIMS="" CU_GONE="" CU_INFO=""
# cu_gate <drone> <task> <brief> <front> — may <drone> of <front> start on <task>? 0 yes, 1 no with
# CU_GATE_MSG saying what to fix. ClickUp being down lets the brief through with CU_GATE_MSG as a
# warning (an outage must not stop the swarm); collisions are then counted on the cache as it is and
# on the drones at work. ClickUp gets CU_GATE_BUDGET seconds for the whole of 'hive task': the token,
# the task, the cache catch-up (only the tasks changed since the last refresh), a look at each task
# it collides with, and the start writes (cu_started ends the budget; a write it cuts short waits in
# the start queue). A network that drops packets must not hold the coordinator for minutes. A
# read-only brief (cu_read_only) is checked for all of it but the collisions.
# Leaves the task id in CU_GATE_ID, the task in CU_GATE_TASK and CU_UP=1 when ClickUp answered.
cu_gate() {
  local drone=$1 id=$2 brief=$3 front=$4 rc mine fronts areas col err warn=""
  CU_UP=0 CU_GATE_TASK="" CU_GATE_ID=$id CU_GATE_MSG="" CU_GONE="" CU_INFO=""
  cu_init 2>/dev/null || { CU_GATE_MSG=$(cu_init 2>&1); return 1; }
  cu_brief_header "$brief" || return 1
  mine=$(cu_front_tag "$front" 2>&1) || { CU_GATE_MSG="front $front has no tag in $CU_TAXONOMY: $mine"; return 1; }
  cu_tmpdir || { CU_GATE_MSG="cannot create a private directory"; return 1; }
  CU_DEADLINE=$(( $(date +%s) + CU_GATE_BUDGET ))
  if cu_ready; then CU_GATE_TASK=$(cu_task "$id" 2>"$CU_TMP/gate.err"); rc=$?; else rc=2; fi
  case "$rc" in
    0) CU_UP=1 ;;
    3) CU_GATE_MSG="ClickUp task $id does not exist — find the right one: hive ct find <words>"; return 1 ;;
    1) CU_GATE_MSG="ClickUp refused to show task $id: $(tail -1 "$CU_TMP/gate.err" | sed 's/^clickup: //')"; return 1 ;;
    *) warn="ClickUp unreachable — task $id not checked, collisions counted on the cache$([ -f "$CU_REGISTRY" ] || echo ' (there is none)') and the drones at work; the start writes wait for clickup-sync" ;;
  esac
  if [ "$CU_UP" = 1 ]; then
    if [ "$(cu_jq "$CU_GATE_TASK" closed)" = true ]; then
      CU_GATE_MSG="ClickUp task $id is closed ($(cu_status_of "$CU_GATE_TASK")) — reopen it (hive ct set $id --status <s>) or create a new one (hive ct new)"
      return 1
    fi
    fronts=$(cu_jq "$CU_GATE_TASK" 'kind("front") | join(",")')
    if [ "$fronts" != "$mine" ]; then
      CU_GATE_MSG="ClickUp task $id belongs to ${fronts:-no front}, not to $mine — take it over on purpose: hive ct set $id --front $front"
      return 1
    fi
    areas=$(cu_jq "$CU_GATE_TASK" 'kind("area") | length')
    if [ "$areas" != 1 ]; then
      CU_GATE_MSG="ClickUp task $id has $areas areas, it needs exactly one — hive ct set $id --area <area>"
      return 1
    fi
  fi
  # A read-only brief skips the collisions: its 'Collision checked' lines are ignored, so no comment
  # lands on another task.
  if cu_read_only "$brief"; then CU_SETTLED=""; CU_GATE_MSG=$warn; return 0; fi
  if [ "$CU_UP" = 1 ] && ! cu_registry_catchup 2>"$CU_TMP/gate.err"; then
    err=$(tail -1 "$CU_TMP/gate.err" | sed 's/^clickup: //')
    warn="the cache was not refreshed${err:+ ($err)} — collisions counted on the cache$([ -f "$CU_REGISTRY" ] && date -r "$CU_REGISTRY" '+ from %Y-%m-%d %H:%M' || echo ' (there is none)') and the drones at work"
  fi
  cu_claims "$front" "$drone"
  col=$(cu_collisions "$id" "$CU_MODS${CU_IMPACT:+,$CU_IMPACT}")
  if [ "$CU_UP" = 1 ] && [ -n "$col" ]; then
    CU_GONE=$(cu_vanished "$col")
    [ -z "$CU_GONE" ] || col=$(cu_collisions "$id" "$CU_MODS${CU_IMPACT:+,$CU_IMPACT}")
  fi
  CU_INFO=$(cu_collisions "$id" "$CU_MODS${CU_IMPACT:+,$CU_IMPACT}" info)
  [ -z "$CU_INFO" ] || cu_say "for information, no drone at work on them (no 'Collision checked' needed):"$'\n'"$(CU_UP=0 cu_print_collisions "$CU_INFO")"
  cu_settle "$col" || { [ -z "$warn" ] || CU_GATE_MSG+=$'\n'"warning: $warn"; return 1; }
  CU_GATE_MSG=$warn
}

# cu_started <drone> <front> <title> — after the brief is installed: its start writes (cu_start_apply)
# go right away to ClickUp when it answered the gate, within what is left of the gate's budget. Those
# ClickUp fails on, or all of them while it is down, go to the start queue for clickup-sync. The record
# is written under a dot name and published in the queue only then: a sync never replays a start this
# process is still making. A process stopped while it makes them publishes the record on its way out
# (cu_cleanup); one killed outright leaves the dot name, which clickup-sync takes up once it is old.
# Warns, never fails.
cu_started() {
  local at tmp rc=2 why="ClickUp failed"
  at=$(date +%s)
  mkdir -p "$CU_STARTS" && tmp=$(mktemp "$CU_STARTS/.start.XXXXXX") \
    || { CU_DEADLINE=""; cu_say "could not queue the start writes of $CU_GATE_ID"; return 0; }
  # Pending from here: a signal waits for jq to finish the record, and the way out publishes it.
  CU_START_PENDING=$tmp CU_START_QUEUED="$CU_STARTS/$at.${tmp##*.}.json"   # oldest first in a listing
  jq -n --arg drone "$1" --arg front "$2" --arg title "$3" --arg task "$CU_GATE_ID" --arg mods "$CU_MODS" \
        --arg impact "$CU_IMPACT" --arg settled "$CU_SETTLED" --arg at "$at" \
        '{drone: $drone, front: $front, task: $task, title: $title, modules: $mods, impact: $impact, settled: $settled, at: $at}' > "$tmp" \
    || { CU_START_PENDING=""; rm -f "$tmp"; CU_DEADLINE=""; cu_say "could not queue the start writes of $CU_GATE_ID"; return 0; }
  [ "$CU_UP" = 1 ] && { cu_start_apply "$tmp" "$CU_GATE_TASK"; rc=$?; }
  cu_spent && why="the ${CU_GATE_BUDGET}s budget ran out"
  CU_DEADLINE=""
  [ "$rc" = 2 ] || { CU_START_PENDING=""; rm -f "$tmp"; return 0; }
  cu_start_publish || { rm -f "$tmp"; cu_say "could not queue the start writes of $CU_GATE_ID"; return 0; }
  [ "$CU_UP" = 1 ] && cu_say "$why — clickup-sync retries the start writes of $CU_GATE_ID"
  return 0
}

# cu_start_publish — moves the start record being made (CU_START_PENDING) into the start queue.
cu_start_publish() {
  local f=$CU_START_PENDING; CU_START_PENDING=""
  [ -n "$f" ] && [ -f "$f" ] || return 0
  mv -f "$f" "$CU_START_QUEUED"
}

# cu_start_apply <file> [task-json] — the start writes of a queued brief: the brief's modules the task
# lacks are added to it, an early status moves to status_start, the task gets a start comment (marked
# hive-start:<drone>:<time>: a replay never doubles it) naming every settled collision, and each task
# collided with a comment of its own (marked hive-collision:<drone>:<task>). The task is read from
# ClickUp unless given. 0 done, 2 when ClickUp failed on a write (worth a retry), 1 when the task
# cannot be read and 4 when the record is unreadable (nothing to retry).
cu_start_apply() {
  local drone front id title mods impact at settled json=${2:-} st m add="" cid reason shared marker notes rc=0
  IFS=$'\037' read -r drone front id title mods impact at \
    < <(jq -r '[.drone, .front, .task, .title, .modules, .impact, .at] | join("\u001f")' "$1" 2>/dev/null)
  [ -n "$id" ] && [ -n "$at" ] || { cu_say "unreadable start record $1"; return 4; }
  settled=$(jq -r .settled "$1")
  if [ -z "$json" ]; then
    json=$(cu_task "$id" 2>/dev/null); rc=$?
    case "$rc" in
      0) ;;
      2) return 2 ;;
      *) cu_say "task $id cannot be read — its start writes are dropped"; return 1 ;;
    esac
  fi
  for m in ${mods//,/ }; do add+="$(cu_tag module "$m")"$'\n'; done
  cu_tags_change "$json" "$add" "" || { [ "$?" = 2 ] && rc=2; cu_say "could not add the brief's modules to $id"; }
  st=$(cu_status_of "$json")
  if cu_status_is "$st" early; then
    cu_set_status "$json" "$(cu_statuses start | head -1)" \
      || { [ "$?" = 2 ] && rc=2; cu_say "could not move $id to '$(cu_statuses start | head -1)'"; }
  fi
  marker="hive-start:$drone:$at"
  notes=$(awk -F'\t' '$1 != "" { gsub(",", ", ", $3); printf "\ncollision checked with %s (modules %s): %s", $1, $3, $2 }' <<<"$settled")
  cu_spent && return 2   # the budget is gone: clickup-sync makes the rest, a replay doubles nothing
  cu_comment_once "$id" "🤖 drone $drone (front $front) start: $title; modules: ${mods//,/, }; impact: ${impact:-none}$notes"$'\n'"$marker" "$marker" \
    || { [ "$?" = 2 ] && rc=2; cu_spent || cu_say "could not comment on $id"; }
  # The other task gets one note per drone: a brief given again to the same drone adds none.
  while IFS=$'\t' read -r cid reason shared; do
    [ -n "$cid" ] || continue
    cu_spent && return 2   # the budget is gone: clickup-sync makes the rest, a replay doubles nothing
    cu_comment_once "$cid" "🤖 collision checked: drone $drone (front $front) on $id works in modules ${shared//,/, } of $cid as well: $reason"$'\n'"hive-collision:$drone:$id" "hive-collision:$drone:$id" \
      || { [ "$?" = 2 ] && rc=2; cu_spent || cu_say "could not comment on $cid"; }
  done <<<"$settled"
  return "$rc"
}

# --- hive ct ------------------------------------------------------------------

cu_need() { cu_ready || cu_die "ClickUp unreachable"; }

ct_find() {  # find <words> [--module M] [--area A] [--front F] [--closed]
  local mods="" area="" front="" closed=false rows; local -a words=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --module) mods=$(cu_modules "${2:?--module needs a value}") || exit 1; shift 2 ;;
      --area) area=$(cu_tag area "${2:?--area needs a value}") || exit 1; area=$(cu_short area "$area"); shift 2 ;;
      --front) front=$(cu_front_tag "${2:?--front needs a value}") || exit 1; front=$(cu_short front "$front"); shift 2 ;;
      --closed) closed=true; shift ;;
      *) words+=("$1"); shift ;;
    esac
  done
  [ ${#words[@]} -gt 0 ] || cu_die "usage: hive ct find <words> [--module M] [--area A] [--front F] [--closed]"
  cu_registry_ready "$CU_REGISTRY_TTL" || exit 1
  rows=$(cu_rows "$mods" "$area" "$front" "$closed" | cu_match "${words[@]}")
  [ -n "$rows" ] || { echo "no candidates"; return 0; }
  cu_print_header; printf '%s\n' "$rows" | cu_print_rows
}

ct_new() {  # new --area A --module M[,M] --name N [--type T] [--parent ID] [--desc FILE] [--status S] [--not-dup ID,...]
  local area="" mods="" type="" name="" parent="" desc="" status="" notdup="" front dups list body json id tags epic
  while [ $# -gt 0 ]; do
    case "$1" in
      --area) area=$(cu_tag area "${2:?--area needs a value}") || exit 1; shift 2 ;;
      --module) mods=$(cu_modules "${2:?--module needs a value}") || exit 1; shift 2 ;;
      --type) type=$(cu_tag type "${2:?--type needs a value}") || exit 1; shift 2 ;;
      --name) name=${2:?--name needs a value}; shift 2 ;;
      --parent) parent=${2:?--parent needs a value}; shift 2 ;;
      --desc) desc=${2:?--desc needs a file}; shift 2 ;;
      --status) status=$(cu_norm_status "${2:?--status needs a value}"); shift 2 ;;
      --not-dup) notdup=${2:?--not-dup needs task ids}; shift 2 ;;
      *) cu_die "ct new: unknown argument '$1'" ;;
    esac
  done
  [ -n "$area" ] && [ -n "$mods" ] && [ -n "$name" ] \
    || cu_die "usage: hive ct new --area A --module M[,M] --name \"...\" [--type T] [--parent ID] [--desc FILE] [--status S] [--not-dup ID,...]"
  [ -z "$desc" ] || [ -r "$desc" ] || cu_die "cannot read $desc"
  front=$(cu_front_tag "$(front_label "${HIVE_FRONT:-}")") || exit 1
  cu_need
  cu_registry_refresh || cu_die "cannot search for duplicates — not creating"
  dups=$( { cu_rows "" "$(cu_short area "$area")" "" true; cu_rows "$mods" "" "" true; } | awk -F'\t' '!seen[$1]++' \
          | cu_match "$name" | awk -F'\t' -v ok=",$notdup," 'index(ok, "," $1 ",") == 0')
  if [ -n "$dups" ]; then
    cu_say "tasks in the same area or modules (open, or closed in the last 30 days) look like this one — use one of them, or rerun with --not-dup <ids> once you checked they are not it:"
    { cu_print_header; printf '%s\n' "$dups" | cu_print_rows; } >&2
    exit 1
  fi
  list=$(cu_cfg list)
  if [ -n "$parent" ]; then
    json=$(cu_task "$parent") || cu_die "no parent task $parent"
    list=$(jq -r '.list.id' <<<"$json")      # ClickUp puts a subtask in its parent's list
  fi
  if [ -n "$status" ]; then cu_status_valid "$list" "$status" || exit 1; fi
  tags=$(printf '%s\n' "$front" "$area" $(cu_tag_list module "$mods") ${type:+"$type"})
  while IFS= read -r id; do cu_ensure_tag "$id" || cu_die "cannot create the tag '$id' in the space"; done <<<"$tags"
  body=$(jq -nc --arg n "$name" --arg t "$tags" --arg p "$parent" --arg s "$status" --rawfile d "${desc:-/dev/null}" \
           '{name: $n, tags: ($t | split("\n") | map(select(. != "")))} + (if $p != "" then {parent: $p} else {} end)
            + (if $s != "" then {status: $s} else {} end) + (if $d != "" then {markdown_content: $d} else {} end)')
  json=$(cu_api POST "/list/$list/task" "$body") || cu_die "task not created"
  id=$(jq -r .id <<<"$json")
  [ -z "$notdup" ] || cu_comment "$id" "🤖 checked before creating, not duplicates of this task: ${notdup//,/, }" || cu_say "could not record --not-dup on $id"
  echo "new: $id $(jq -r .url <<<"$json")"
  epic=$(cu_epic_of "$area")
  [ -n "$parent" ] || [ -z "$epic" ] || echo "hint: the epic of $(cu_short area "$area") is $epic — hive ct set $id --parent $epic"
  cu_registry_refresh 2>/dev/null || true
}

ct_show() {  # show <id>
  local id=${1:?usage: hive ct show <id>} json comments pname="" parent prs k
  cu_need
  json=$(cu_task "$id") || exit 1
  comments=$(cu_comments "$id" '[.[] | select(.comment_text // "" | startswith("🤖 collision checked:") | not)] | length >= 8')
  parent=$(jq -r '.parent // ""' <<<"$json")
  [ -n "$parent" ] && pname=$(cu_api GET "/task/$parent" 2>/dev/null | jq -r .name)
  cu_jq "$json" '"\(.id)  \(.name)\n\(.url)\nstatus:  \(.status.status)\(if closed then " (closed)" else "" end)"'
  for k in $CU_KINDS; do
    printf '%-8s %s\n' "$k:" "$(cu_jq "$json" "short(\"$k\") | if length == 0 then \"-\" else join(\", \") end")"
  done
  cu_jq "$json" '[.tags[]?.name | ascii_downcase | select($map[.] == null)] | if length > 0 then "other:   \(join(", "))" else empty end'
  echo "parent:  ${parent:--}${pname:+  $pname}"
  jq -r '"subtasks: \(.subtasks // [] | length)", (.subtasks // [] | .[] | "  \(.id)  [\(.status.status)]  \(.name)")' <<<"$json"
  prs=$(jq -r '.comments[]?.comment_text // "" | split("\n")[] | select(startswith("PR: ")) | ltrimstr("PR: ")' <<<"$comments" | awk '!seen[$0]++')
  [ -z "$prs" ] || { echo "PRs:"; sed 's/^/  /' <<<"$prs"; }
  echo; echo "--- description"
  jq -r '.text_content // .description // "" | if . == "" then "(empty)" else . end' <<<"$json"
  # Notes left by other tasks' collisions are counted on one line: listed, they push the history out.
  echo; echo "--- latest comments (oldest first)"
  jq -r 'def when: .date | tonumber / 1000 | strflocaltime("%Y-%m-%d %H:%M");
         (.comments // []) as $all | [$all[] | select(.comment_text // "" | startswith("🤖 collision checked:"))] as $notes
         | ([$all[] | select(.comment_text // "" | startswith("🤖 collision checked:") | not)][:8] | reverse
            | if length == 0 then "(none)" else .[] | "[\(when) \(.user.username // "?")] \(.comment_text)" end),
           (if ($notes | length) > 0 then "(\($notes | length) collision notes not shown\(if .more then " among the \($all | length) latest comments" else "" end), the latest \($notes[0] | when))" else empty end)' <<<"$comments"
}

# cu_module_changes <+M,-M,M> — two lists of full tags: what to add, then (after a line '--') what to remove.
cu_module_changes() {
  local v add="" del="" t
  for v in ${1//,/ }; do
    case "$v" in
      -*) t=$(cu_tag module "${v#-}") || return 1; del+="$t"$'\n' ;;
      *) t=$(cu_tag module "${v#+}") || return 1; add+="$t"$'\n' ;;
    esac
  done
  printf '%s--\n%s' "$add" "$del"
}

ct_set() {  # set <id> [--status S] [--comment TEXT|@FILE] [--area A] [--module +M,-M] [--type T|none] [--parent ID] [--front F]
  local id=${1:?usage: hive ct set <id> [--status S] [--comment TEXT|@FILE] [--area A] [--module +M,-M] [--type T|none] [--parent ID] [--front F]}; shift
  local status="" comment="" area="" modch="" type="" settype=0 parent="" front="" json
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status=${2:?--status needs a value}; shift 2 ;;
      --comment) comment=${2:?--comment needs a text}; shift 2 ;;
      --area) area=$(cu_tag area "${2:?--area needs a value}") || exit 1; shift 2 ;;
      --module) modch=$(cu_module_changes "${2:?--module needs a value}") || exit 1; shift 2 ;;
      --type) settype=1; [ "${2:?--type needs a value}" = none ] || { type=$(cu_tag type "$2") || exit 1; }; shift 2 ;;
      --parent) parent=${2:?--parent needs a value}; shift 2 ;;
      --front) front=$(cu_front_tag "${2:?--front needs a value}") || exit 1; shift 2 ;;
      *) cu_die "ct set: unknown argument '$1'" ;;
    esac
  done
  [ -n "$status$comment$area$modch$parent$front" ] || [ "$settype" = 1 ] || cu_die "ct set: nothing to change"
  if [ "${comment:0:1}" = @ ]; then comment=$(cat -- "${comment:1}") || cu_die "cannot read ${comment:1}"; fi
  cu_need
  json=$(cu_task "$id") || exit 1
  if [ -n "$parent" ]; then cu_set_parent "$json" "$parent" || cu_die "parent not set"; echo "set: $id parent $parent"; fi
  if [ -n "$front" ]; then cu_set_front "$json" "$front" "hive ct set by front $(front_label "${HIVE_FRONT:-}")" || cu_die "front not set"; echo "set: $id front $front"; fi
  if [ -n "$area" ]; then cu_tags_set "$json" area "$area" || cu_die "area not set"; echo "set: $id area $area"; fi
  if [ "$settype" = 1 ]; then cu_tags_set "$json" type "$type" || cu_die "type not set"; echo "set: $id type ${type:-none}"; fi
  if [ -n "$modch" ]; then
    cu_tags_change "$json" "${modch%%--*}" "${modch#*--}" || cu_die "modules not changed"; echo "set: $id modules"
  fi
  if [ -n "$status" ]; then cu_set_status "$json" "$status" || cu_die "status not set"; echo "set: $id status $(cu_norm_status "$status")"; fi
  if [ -n "$comment" ]; then cu_comment_once "$id" "$comment" || cu_die "comment not added"; echo "set: $id comment"; fi
}

ct_check() {  # check --module M[,M] [--impact M[,M]] [--task ID]
  local mods="" impact="" task="-" col info
  while [ $# -gt 0 ]; do
    case "$1" in
      --module) mods=$(cu_modules "${2:?--module needs a value}") || exit 1; shift 2 ;;
      --impact) impact=$(cu_modules "${2:?--impact needs a value}") || exit 1; shift 2 ;;
      --task) task=${2:?--task needs an id}; shift 2 ;;
      *) cu_die "ct check: unknown argument '$1'" ;;
    esac
  done
  [ -n "$mods" ] || cu_die "usage: hive ct check --module M[,M] [--impact M[,M]] [--task ID]"
  cu_tmpdir || exit 1
  cu_registry_ready 0 || true
  cu_ready 2>/dev/null && CU_UP=1
  cu_claims "$(front_label "${HIVE_FRONT:-}")" "${HIVE_DRONE:-}"
  col=$(cu_collisions "$task" "$mods${impact:+,$impact}")
  info=$(cu_collisions "$task" "$mods${impact:+,$impact}" info)
  if [ -n "$info" ]; then echo "check: for information, no drone at work on them:"; cu_print_collisions "$info"; fi
  if [ -z "$col" ]; then echo "check: no collisions in ${mods//,/, }${impact:+ (impact ${impact//,/, })}"; return 0; fi
  echo "check: collisions in ${mods//,/, }${impact:+ (impact ${impact//,/, })}:"
  cu_print_collisions "$col"
  exit 1
}

# apply <file.tsv> [--yes] — columns: id, front, area, modules, parent, current status, new status,
# comment. An empty field changes nothing; 'modules' leaves the task with exactly those. A row whose
# current status no longer matches ClickUp is skipped; a wrong field skips only that field. Dry run
# unless --yes; a second run changes nothing.
ct_apply() {
  local file="" yes=0 id front area mods parent cur new comment json now n_rows=0 n_skip=0 n_change=0 t
  local -a plan notes
  while [ $# -gt 0 ]; do
    case "$1" in --yes) yes=1; shift ;; *) file=$1; shift ;; esac
  done
  [ -r "$file" ] || cu_die "usage: hive ct apply <file.tsv> [--yes]"
  cu_need
  # Tab is IFS whitespace: read would merge empty columns, so the columns are split on \037 instead.
  while IFS=$'\037' read -r -u 3 id front area mods parent cur new comment || [ -n "$id" ]; do
    id=$(cu_trim "$id"); parent=$(cu_trim "$parent")
    case "$id" in ''|'#'*|id) continue ;; esac
    n_rows=$((n_rows + 1)); plan=(); notes=()
    json=$(cu_task "$id" 2>/dev/null) || { echo "SKIP $id: not found or ClickUp unavailable"; n_skip=$((n_skip + 1)); continue; }
    now=$(cu_status_of "$json"); cur=$(cu_norm_status "$cur"); new=$(cu_norm_status "$new")
    if [ -n "$cur" ] && [ "$cur" != "$now" ]; then
      echo "SKIP $id: status in ClickUp is '$now', the file expects '$cur'"; n_skip=$((n_skip + 1)); continue
    fi
    if [ -n "$(cu_trim "$front")" ]; then
      if t=$(cu_front_tag "$(cu_trim "$front")" 2>&1); then front=$t; else notes+=("front: ${t#clickup: }"); front=""; fi
    else front=""; fi
    if [ -n "$(cu_trim "$area")" ]; then
      if t=$(cu_tag area "$(cu_trim "$area")" 2>&1); then area=$t; else notes+=("area: ${t#clickup: }"); area=""; fi
    else area=""; fi
    if [ -n "$(cu_trim "$mods")" ]; then
      if t=$(cu_tag_list module "$mods" 2>&1); then mods=$t; else notes+=("modules: ${t#clickup: }"); mods=""; fi
    else mods=""; fi
    case "$parent" in —|–|-) parent="" ;; esac
    if [ -n "$parent" ] && ! [[ "$parent" =~ ^[0-9a-z]{6,}$ ]]; then notes+=("parent '$parent' is not a task id"); parent=""; fi
    [ "$parent" = "$id" ] && parent=""
    if [ -n "$new" ] && [ "$new" != "$now" ] && ! cu_status_valid "$(jq -r '.list.id // empty' <<<"$json")" "$new" 2>/dev/null; then
      notes+=("status '$new' does not exist in its list"); new=""
    fi
    [ -n "$front" ] && [ "$(cu_jq "$json" 'kind("front") | join(",")')" != "$front" ] && plan+=("front -> $front")
    [ -n "$area" ] && [ "$(cu_jq "$json" 'kind("area") | join(",")')" != "$area" ] && plan+=("area -> $area")
    [ -n "$mods" ] && [ "$(cu_jq "$json" 'kind("module") | sort | join(",")')" != "$(sort <<<"$mods" | paste -sd,)" ] && plan+=("modules -> $(paste -sd, <<<"$mods")")
    [ -n "$parent" ] && [ "$(jq -r '.parent // ""' <<<"$json")" != "$parent" ] && plan+=("parent -> $parent")
    [ -n "$new" ] && [ "$new" != "$now" ] && plan+=("status $now -> $new")
    [ -n "$comment" ] && ! cu_has_comment "$id" "$comment" && plan+=("comment: ${comment:0:80}")
    for t in "${notes[@]}"; do echo "SKIP $id field — $t"; done
    [ ${#plan[@]} -gt 0 ] || continue
    n_change=$((n_change + 1))
    printf '%s %s: %s\n' "$([ "$yes" = 1 ] && echo APPLY || echo PLAN)" "$id" "$(printf '%s; ' "${plan[@]}" | sed 's/; $//')"
    [ "$yes" = 1 ] || continue
    [ -z "$parent" ] || cu_set_parent "$json" "$parent" || echo "FAILED $id parent"
    [ -z "$front" ] || cu_tags_set "$json" front "$front" || echo "FAILED $id front"
    [ -z "$area" ] || cu_tags_set "$json" area "$area" || echo "FAILED $id area"
    [ -z "$mods" ] || cu_tags_set "$json" module "$mods" || echo "FAILED $id modules"
    [ -z "$new" ] || cu_set_status "$json" "$new" || echo "FAILED $id status"
    [ -z "$comment" ] || cu_comment_once "$id" "$comment" || echo "FAILED $id comment"
  done 3< <(tr '\t' '\037' < "$file")
  echo "apply: $n_rows rows, $n_change to change, $n_skip skipped$([ "$yes" = 1 ] || echo ' — dry run, rerun with --yes to write')"
}

# stale [--yes] — tasks left lying; the coordinator runs it by hand, never a timer. Moved means updated,
# commented on, or reported on by a drone whose meta.json or brief names the task.
#   rule 1: in stale_testing, not moved for stale_testing_days -> stale_testing_to
#   rule 2: in stale_hold, not moved for stale_hold_days and named by no brief of a drone alive or
#           changed within those days -> stale_hold_to. A person's task (assigned to someone, or with
#           a tag of stale_human_tags) is only listed, to be checked by hand; so is a task the swarm
#           never worked on (no drone's directory names it, no hive-start or hive-report comment).
# Only the tasks of the caller's front; an epic with an open subtask is never stale. Dry run unless
# --yes; a task that changed since it was read is skipped, and a second run changes nothing. A comment
# that fails after its status was set is printed as the command that adds it.
cu_stale_row() { printf '%-6s %-11s %-4s %-30s %-5s %s — %s\n' "$@"; }   # action id rule change idle reason name

ct_stale() {
  local yes=0 s1 s2 to1 to2 d1 d2 now cut1 cut2 tasks cand refs id rule st upd who tags name
  local front cj c rep last to cut days since idle named json text n_plan=0 n_hand=0 n_skip=0
  case "${1:-}" in --yes) yes=1 ;; '') ;; *) cu_die "usage: hive ct stale [--yes]" ;; esac
  s1=$(cu_list stale_testing); s2=$(cu_list stale_hold)
  to1=$(cu_norm_status "$(cu_list stale_testing_to | head -1)"); to2=$(cu_norm_status "$(cu_list stale_hold_to | head -1)")
  d1=$(cu_cfg stale_testing_days); d2=$(cu_cfg stale_hold_days)
  [[ "$d1" =~ ^[0-9]+$ && "$d2" =~ ^[0-9]+$ ]] || cu_die "stale_testing_days and stale_hold_days are whole days"
  [ -n "$to1" ] || s1=""; [ -n "$to2" ] || s2=""
  [ -n "$s1$s2" ] || cu_die "no stale rule configured (stale_testing and stale_testing_to, stale_hold and stale_hold_to)"
  front=$(cu_front_tag "$(front_label "${HIVE_FRONT:-}")") || exit 1
  cu_need
  tasks=$(cu_space_tasks false) || cu_die "cannot list the tasks of the space"
  now=$(( $(date +%s) * 1000 )); cut1=$(( now - d1 * 86400000 )); cut2=$(( now - d2 * 86400000 ))
  cand=$(jq -rs "${CU_JQ_ARGS[@]}" --argjson r1 "$(printf '%s' "$s1" | jq -Rn '[inputs]')" \
           --argjson r2 "$(printf '%s' "$s2" | jq -Rn '[inputs]')" --argjson c1 "$cut1" --argjson c2 "$cut2" \
           --argjson ht "$(cu_list stale_human_tags | jq -Rn '[inputs]')" --arg front "$front" "$CU_JQ_DEFS"'
    [.[] | select(closed | not)] as $open | [$open[].parent // empty] as $parents
    | $open[] | select(tagnames | index($front)) | (.status.status // "" | ascii_downcase) as $s
    | (if ($s | IN($r1[])) then 1 elif ($s | IN($r2[])) then 2 else 0 end) as $rule | select($rule > 0)
    | select(.id | IN($parents[]) | not)
    | select((.date_updated // "0" | tonumber) < (if $rule == 1 then $c1 else $c2 end))
    | [.id, $rule, $s, (.date_updated // "0"), ([.assignees[]? | .username // .email // (.id | tostring)] | join(",")),
       ([tagnames[] | select(IN($ht[]))] | join(",")), (.name | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$tasks") \
    || cu_die "cannot read the tasks of the space"
  refs=$(cu_drone_refs "$(cut -f1 <<<"$cand")")
  cu_stale_row action id rule change idle reason name
  # Tab is IFS whitespace: read would merge empty columns, so the columns are split on \037 instead.
  while IFS=$'\037' read -r -u 3 id rule st upd who tags name; do
    [ -n "$id" ] || continue
    if [ "$rule" = 1 ]; then to=$to1 cut=$cut1 days=$d1; else to=$to2 cut=$cut2 days=$d2; fi
    cj=$(cu_api GET "/task/$id/comment") && c=$(jq '[.comments[]?.date // "0" | tonumber] | max // 0' <<<"$cj") \
      || { cu_stale_row SKIP "$id" "$rule" "$st" - "its comments cannot be read" "$name"; n_skip=$((n_skip + 1)); continue; }
    rep=$(awk -F'\t' -v i="$id" '$1 == i && $5 > m { m = $5 } END { print (m ? m "000" : 0) }' <<<"$refs")
    last=$upd; [ "$c" -gt "$last" ] && last=$c; [ "$rep" -gt "$last" ] && last=$rep
    since=$(date -d "@$((last / 1000))" +%F); idle="$(( (now - last) / 86400000 ))d"
    if [ "$last" -ge "$cut" ]; then cu_stale_row KEEP "$id" "$rule" "$st" "$idle" "moved on $since" "$name"; continue; fi
    if [ "$rule" = 2 ]; then
      named=$(awk -F'\t' -v i="$id" -v since="$((cut / 1000))" '$1 == i && ($3 == 1 || $4 >= since) { print $2 }' <<<"$refs" | paste -sd, -)
      if [ -n "$named" ]; then cu_stale_row KEEP "$id" "$rule" "$st" "$idle" "named by the brief of $named" "$name"; continue; fi
      if [ -n "$who$tags" ]; then
        cu_stale_row CHECK "$id" "$rule" "$st -> $to by hand" "$idle" \
          "a person's task (${who:+assigned to $who}${who:+${tags:+, }}${tags:+tagged $tags})" "$name"
        n_hand=$((n_hand + 1)); continue
      fi
      if ! awk -F'\t' -v i="$id" '$1 == i { f = 1 } END { exit !f }' <<<"$refs" \
         && ! jq -e 'any(.comments[]?; .comment_text // "" | test("(^|\n)hive-(start|report):[^\\s:]+:[0-9]+(\n|$)"))' <<<"$cj" >/dev/null; then
        cu_stale_row CHECK "$id" "$rule" "$st -> $to by hand" "$idle" "never the swarm's work (no drone names it, no hive-start or hive-report comment)" "$name"
        n_hand=$((n_hand + 1)); continue
      fi
    fi
    if [ "$yes" = 1 ]; then
      json=$(cu_task "$id" 2>/dev/null) || { cu_stale_row SKIP "$id" "$rule" "$st" "$idle" "it cannot be read" "$name"; n_skip=$((n_skip + 1)); continue; }
      if [ "$(cu_status_of "$json")" != "$st" ] || [ "$(jq -r '.date_updated // "0"' <<<"$json")" != "$upd" ]; then
        cu_stale_row SKIP "$id" "$rule" "$st" "$idle" "changed in ClickUp since it was read" "$name"; n_skip=$((n_skip + 1)); continue
      fi
    fi
    cu_stale_row "$([ "$yes" = 1 ] && echo APPLY || echo PLAN)" "$id" "$rule" "$st -> $to" "$idle" "no movement since $since" "$name"
    n_plan=$((n_plan + 1))
    [ "$yes" = 1 ] || continue
    cu_set_status "$json" "$to" || { echo "FAILED $id status"; continue; }
    text="🤖 hive ct stale, rule $rule: '$st' with no movement since $since (over $days days)$([ "$rule" = 2 ] && echo ", named by no drone's brief") → '$to'."
    cu_comment_once "$id" "$text" || echo "FAILED $id comment — add it with: hive ct set $id --comment '${text//\'/\'\\\'\'}'"
  done 3< <(tr '\t' '\037' <<<"$cand")
  echo "stale: $n_plan to change, $n_hand for a person to check, $n_skip skipped$([ "$yes" = 1 ] || echo ' — dry run, rerun with --yes to write')"
}

# todo <id> "<item>" [--checklist NAME] — adds the item to the task's checklist of that name (default:
# the config's 'checklist'), creating the checklist when the task has none. An item already there is
# not added twice, and a retry first looks whether the timed-out attempt landed.
ct_todo() {
  local id="" item="" name="" cl rc
  local -a CU_RETRY_GUARD=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --checklist) name=${2:?--checklist needs a name}; shift 2 ;;
      *) if [ -z "$id" ]; then id=$1; elif [ -z "$item" ]; then item=$1; else cu_die "ct todo: unexpected argument '$1'"; fi; shift ;;
    esac
  done
  item=$(cu_trim "$item"); name=$(cu_trim "${name:-$(cu_cfg checklist)}")
  [ -n "$id" ] && [ -n "$item" ] && [ -n "$name" ] || cu_die 'usage: hive ct todo <id> "<item>" [--checklist NAME]'
  cu_need
  cl=$(cu_checklist_id "$id" "$name"); rc=$?
  [ "$rc" = 2 ] && exit 1
  if [ "$rc" != 0 ]; then
    CU_RETRY_GUARD=(cu_checklist_id "$id" "$name")
    cu_api POST "/task/$id/checklist" "$(jq -nc --arg n "$name" '{name: $n}')" >/dev/null || cu_die "checklist '$name' not created on $id"
    CU_RETRY_GUARD=()
    cl=$(cu_checklist_id "$id" "$name") || cu_die "checklist '$name' not found on $id after creating it"
    echo "todo: $id new checklist '$name'"
  fi
  if cu_checklist_has "$id" "$cl" "$item"; then echo "todo: $id already has '$item' in '$name'"; return 0; fi
  CU_RETRY_GUARD=(cu_checklist_has "$id" "$cl" "$item")
  cu_api POST "/checklist/$cl/checklist_item" "$(jq -nc --arg n "$item" '{name: $n}')" >/dev/null || cu_die "item not added to '$name' on $id"
  echo "todo: $id + '$item' in '$name'"
}

ct_sync() {  # sync — refreshes the cache and creates the taxonomy's tags missing from the space
  local t
  cu_need
  while IFS= read -r t; do cu_ensure_tag "$t" || cu_die "cannot create the tag '$t' in the space"; done < <(cu_taxonomy | cut -f2)
  cu_registry_refresh || cu_die "cache not refreshed"
  echo "sync: $(($(wc -l < "$CU_REGISTRY") - 1)) tasks in $CU_REGISTRY"
}

# ack <drone> --manual "<reason>" — settles by hand a report clickup-sync could not apply (it wrote why
# in a letter): the sync stops retrying it and the reason goes to its log. Only such a report, and
# never without a reason.
ct_ack() {
  local name="" reason="" report key
  while [ $# -gt 0 ]; do
    case "$1" in --manual) reason=${2:-}; shift; shift || true ;; *) name=$1; shift ;; esac
  done
  [ -n "$name" ] && [ -n "${reason// /}" ] || cu_die "usage: hive ct ack <drone> --manual \"<what you did by hand>\""
  report="$DRONES_DIR/$name/report.md"   # the path exactly as clickup-sync.sh globs it
  [ -f "$report" ] || cu_die "no report for $name ($report)"
  key="$report $(stat -c %Y "$report")"
  exec 8>"$CU_DIR/sync.lock"; flock -w 60 8 || cu_die "clickup-sync is busy, try again"
  grep -qxF -- "$key" "$CU_SYNC_FAILED" "$CU_SYNC_RETRY" 2>/dev/null \
    || cu_die "the report of $name is not one clickup-sync failed on — nothing to ack"
  local f
  for f in "$CU_SYNC_FAILED" "$CU_SYNC_RETRY"; do
    [ -f "$f" ] && { grep -vxF -- "$key" "$f" > "$f.tmp"; mv -f "$f.tmp" "$f"; }
  done
  printf '%s\n' "$key" >> "$CU_SYNC_STATE"
  printf '%s ack %s/%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(front_label "${HIVE_FRONT:-}")" "$name" "$reason" >> "$CU_LOG"
  echo "ack: $name — clickup-sync stops retrying this report"
}

# --- decisions ----------------------------------------------------------------
# A decision a coordinator waits on from the owner is a task on its own list (decision_list in the
# config): its name the question, its description the context and the options, one front tag, a link
# to the task it is about. The list's first open status means waiting, its first closed one answered;
# the answer lands as a comment on the decision and on that task. The list stays out of the cache, so
# decisions never show up in 'ct find', duplicates or collisions.
# A decision's number is hive's, never a person's: 'D-<n> ' in front of the question, one counter for
# the whole list (every front, open and closed) and $CU_DIR/decision.last, the highest number this
# machine gave, so the number of a deleted or archived decision does not come back either. The read of
# the highest number, the POST and decision.last hold a lock in $CU_DIR: two fronts on this machine
# never draw the same number (a coordinator on another machine is not covered).

cu_decision_list() { cu_cfg decision_list; }
cu_need_decisions() {
  [ -n "$(cu_decision_list)" ] || cu_die "no decision list — set 'decision_list' in $CU_CONF"
  cu_need
}
cu_decision_lock() {
  mkdir -p "$CU_DIR"
  exec 9>"$CU_DIR/decision.lock"; flock -w 60 9 || cu_die "another decision is being numbered, try again"
}

# jq definitions: a decision's number (null without one) and its question without the number.
CU_DECISION_DEFS='
def dnum: (.name | capture("^D-(?<n>[1-9][0-9]*) ")?.n | tonumber) // null;
def dquestion: .name | sub("^D-[1-9][0-9]* "; "");'

# cu_decision_statuses — two lines: the decision list's waiting (first open) and answered (first closed) status.
cu_decision_statuses() {
  local json; json=$(cu_api GET "/list/$(cu_decision_list)") || return
  jq -re '[.statuses[]? | {s: (.status | ascii_downcase), t: .type}] as $st
          | [first($st[] | select(.t == "open") | .s), first($st[] | select(.t == "closed") | .s)] | select(length == 2) | .[]' <<<"$json" \
    || { cu_say "the decision list $(cu_decision_list) needs an open and a closed status"; return 1; }
}

# cu_decisions — every decision of the list, closed ones included, one JSON a line, oldest first.
cu_decisions() {
  local json n page=0
  while [ "$page" -lt 50 ]; do
    json=$(cu_api GET "/list/$(cu_decision_list)/task?include_closed=true&subtasks=true&page=$page") || return
    jq -c '.tasks[]' <<<"$json"
    n=$(jq '.tasks | length' <<<"$json")
    [ "$n" -ge 100 ] && [ "$(jq -r '.last_page // false' <<<"$json")" != true ] || break
    page=$((page + 1))
  done | jq -sc 'sort_by(.date_created // "0" | tonumber)[]'
}

# cu_decision_match <question> <front-tag> — reads decisions, prints the id of a waiting one of that
# front with that question, whatever its number; 1 when there is none.
cu_decision_match() {
  cu_jq_lines --arg n "$1" --arg f "$2" \
    'select((closed | not) and (dquestion | ascii_downcase) == ($n | ascii_downcase) and any(tagnames[]; . == $f)) | .id' | grep -m1 .
}
cu_decision_waiting() { local all; all=$(cu_decisions) || return; cu_decision_match "$@" <<<"$all"; }
cu_jq_lines() { local -a a=("$@"); local f=${a[-1]}; unset 'a[-1]'; jq -r "${CU_JQ_ARGS[@]}" "${a[@]}" "$CU_JQ_DEFS $CU_DECISION_DEFS $f"; }
# cu_decision_last — the highest number this machine gave, 0 without one; cu_decision_mark <n> writes it.
cu_decision_last() { local n; n=$(cat "$CU_DIR/decision.last" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
cu_decision_mark() { echo "$1" > "$CU_DIR/decision.last.tmp" && mv -f "$CU_DIR/decision.last.tmp" "$CU_DIR/decision.last"; }
cu_decision_next() {   # reads decisions: the next number
  cu_jq_lines -s --argjson last "$(cu_decision_last)" '[(map(dnum // 0) | max // 0), $last] | max + 1'
}

ct_decision_new() {  # decision new --name Q [--task ID] [--desc FILE] [--front F]
  local name="" task="" desc="" front="" st waiting tjson="" tname="" body json id n
  local re='^(\[[^]]*\]|[Dd]-[0-9]+([^0-9]|$))'
  local -a CU_RETRY_GUARD=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=$(cu_trim "${2:?--name needs a question}"); shift 2 ;;
      --task) task=${2:?--task needs a task id}; shift 2 ;;
      --desc) desc=${2:?--desc needs a file}; shift 2 ;;
      --front) front=$(cu_front_tag "${2:?--front needs a value}") || exit 1; shift 2 ;;
      *) cu_die "ct decision new: unknown argument '$1'" ;;
    esac
  done
  [ -n "$name" ] || cu_die 'usage: hive ct decision new --name "<the question>" [--task ID] [--desc FILE] [--front F]'
  [[ "$name" != *$'\n'* ]] || cu_die "the name is the question in one line; the rest goes to --desc"
  [[ ! "$name" =~ $re ]] || cu_die "'${BASH_REMATCH[1]}' in front of the question: the number is hive's (D-<n>), give only the question"
  [ -z "$desc" ] || [ -r "$desc" ] || cu_die "cannot read $desc"
  [ -n "$front" ] || front=$(cu_front_tag "$(front_label "${HIVE_FRONT:-}")") || exit 1
  cu_need_decisions
  st=$(cu_decision_statuses) || exit 1; waiting=$(head -1 <<<"$st")
  if [ -n "$task" ]; then
    tjson=$(cu_task "$task") || cu_die "no task $task"
    tname=$(jq -r .name <<<"$tjson")
  fi
  cu_ensure_tag "$front" || cu_die "cannot create the tag '$front' in the space"
  cu_decision_lock
  json=$(cu_decisions) || cu_die "cannot read the decision list — not creating"
  id=$(cu_decision_match "$name" "$front" <<<"$json") && cu_die "decision $id already waits with this question — hive ct show $id"
  n=$(cu_decision_next <<<"$json") || cu_die "cannot number the decision — not creating"
  body=$(jq -nc --arg n "D-$n $name" --arg f "$front" --arg s "$waiting" --rawfile d "${desc:-/dev/null}" \
           '{name: $n, tags: [$f], status: $s} + (if $d != "" then {markdown_content: $d} else {} end)')
  # A POST that timed out may have landed: before a retry the guard looks for the decision.
  CU_RETRY_GUARD=(cu_decision_waiting "$name" "$front")
  json=$(cu_api POST "/list/$(cu_decision_list)/task" "$body") || cu_die "decision not created"
  CU_RETRY_GUARD=()
  if [ -z "$json" ]; then
    id=$(cu_decision_waiting "$name" "$front") || cu_die "decision created, but not found afterwards"
  else
    id=$(jq -r .id <<<"$json")
  fi
  cu_decision_mark "$n" || cu_say "D-$n not written to $CU_DIR/decision.last"
  exec 9>&-
  echo "decision: D-$n $id https://app.clickup.com/t/$id"
  [ -n "$task" ] || return 0
  cu_api POST "/task/$id/link/$task" >/dev/null || cu_die "decision D-$n not linked to $task — link it by hand"
  cu_comment_once "$task" "🤖 decision waiting: D-$n $name ($id)" || cu_die "the note on $task not added"
  echo "decision: D-$n linked to $task ($tname)"
}

ct_decision_answer() {  # decision answer <D-n|id> --comment TEXT|@FILE
  local id="" comment="" st answered json task ids
  while [ $# -gt 0 ]; do
    case "$1" in
      --comment) comment=${2:?--comment needs a text}; shift 2 ;;
      *) [ -z "$id" ] || cu_die "ct decision answer: unexpected argument '$1'"; id=$1; shift ;;
    esac
  done
  if [ "${comment:0:1}" = @ ]; then comment=$(cat -- "${comment:1}") || cu_die "cannot read ${comment:1}"; fi
  comment=$(cu_trim "$comment")
  [ -n "$id" ] && [ -n "$comment" ] || cu_die 'usage: hive ct decision answer <D-n|id> --comment "<the answer>"|@FILE'
  cu_need_decisions
  if [[ "$id" =~ ^[Dd]-([1-9][0-9]*)$ ]]; then
    json=$(cu_decisions) || cu_die "cannot read the decision list"
    ids=$(cu_jq_lines --argjson k "${BASH_REMATCH[1]}" 'select(dnum == $k) | .id' <<<"$json")
    case "$(grep -c . <<<"$ids")" in
      0) cu_die "no decision ${id^^} on the list" ;;
      1) id=$ids ;;
      *) cu_die "${id^^} is on more than one decision ($(paste -sd, - <<<"$ids")) — renumber all but one by hand" ;;
    esac
  fi
  json=$(cu_task "$id") || exit 1
  [ "$(jq -r '.list.id // ""' <<<"$json")" = "$(cu_decision_list)" ] || cu_die "$id is not on the decision list"
  st=$(cu_decision_statuses) || exit 1; answered=$(tail -1 <<<"$st")
  cu_comment_once "$id" "🤖 answer: $comment" || cu_die "answer not added to $id"
  cu_set_status "$json" "$answered" || cu_die "status of $id not set"
  echo "decision: $id $answered"
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    cu_comment_once "$task" "🤖 decision $id answered: $(jq -r .name <<<"$json") — $comment" \
      && echo "decision: answer noted on $task" || cu_say "the answer not noted on $task"
  done < <(jq -r --arg me "$id" '.linked_tasks[]? | [.task_id, .link_id] | map(select(. != $me))[]' <<<"$json" | awk '!seen[$0]++')
}

ct_decision_list() {  # decision list [--front F|--all] [--open]
  local front="" open=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --front) front=$(cu_front_tag "${2:?--front needs a value}") || exit 1; shift 2 ;;
      --all) front=all; shift ;;
      --open) open=true; shift ;;
      *) cu_die "ct decision list: unknown argument '$1'" ;;
    esac
  done
  [ -n "$front" ] || front=$(cu_front_tag "$(front_label "${HIVE_FRONT:-}")") || exit 1
  cu_need_decisions
  local rows; rows=$(cu_decisions) || exit 1
  rows=$(cu_jq_lines --arg f "$front" --argjson open "$open" --arg now "$(date +%s)" '
    select(($f == "all" or any(tagnames[]; . == $f)) and ($open == false or (closed | not)))
    | ((($now | tonumber) - ((.date_created // "0") | tonumber / 1000)) / 3600 | floor) as $h
    | .id as $me | def dash: if . == "" then "-" else . end;
    [(dnum | if . then "D-\(.)" else "-" end), .id, (.status.status // "" | ascii_downcase), (short("front") | join(",") | dash),
     (if $h < 48 then "\($h)h" else "\($h / 24 | floor)d" end),
     ([.linked_tasks[]? | .task_id, .link_id] | map(select(. != null and . != $me)) | unique | join(",") | dash),
     (dquestion | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$rows")
  [ -n "$rows" ] || { echo "no decisions"; return 0; }
  { echo "number id status front age task question" | tr ' ' '\t'; printf '%s\n' "$rows"; } \
    | awk -F'\t' '{ printf "%-6s %-11s %-14s %-10s %-5s %-11s %s\n", $1, $2, $3, $4, $5, $6, $7 }'
}

# decision number [--yes] — numbers the decisions without a number, oldest first, after the highest
# number on the list or in decision.last, and drops a hand-made '[...] ' from the front of the name. A dry
# run unless --yes; a decision renamed in ClickUp since it was read is skipped, a rename ClickUp refuses
# fails the run. A second run changes nothing.
ct_decision_number() {
  local yes=0 json plan row id old new n_plan=0 n_skip=0 n_fail=0
  case "${1:-}" in --yes) yes=1 ;; '') ;; *) cu_die "usage: hive ct decision number [--yes]" ;; esac
  cu_need_decisions
  cu_decision_lock
  json=$(cu_decisions) || cu_die "cannot read the decision list"
  plan=$(cu_jq_lines -s -c --argjson last "$(cu_decision_last)" '([(map(dnum // 0) | max // 0), $last] | max) as $m
    | [.[] | select(dnum == null)] | to_entries[]
    | (.value.name | sub("^\\[[^\\]]*\\]\\s*"; "")) as $q
    | {id: .value.id, old: .value.name, n: ($m + .key + 1), new: "D-\($m + .key + 1) \(if $q == "" then .value.name else $q end)"}' <<<"$json") \
    || cu_die "cannot read the decision list"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(jq -r .id <<<"$row"); old=$(jq -r .old <<<"$row"); new=$(jq -r .new <<<"$row")
    if [ "$yes" = 1 ]; then
      if ! json=$(cu_task "$id" 2>/dev/null) || [ "$(jq -r .name <<<"$json")" != "$old" ]; then
        printf '%-5s %-11s %s (renamed or gone since it was read)\n' SKIP "$id" "$old"; n_skip=$((n_skip + 1)); continue
      fi
      cu_api PUT "/task/$id" "$(jq -nc --arg n "$new" '{name: $n}')" >/dev/null \
        || { printf '%-5s %-11s %s (not renamed)\n' FAIL "$id" "$old"; n_fail=$((n_fail + 1)); continue; }
      cu_decision_mark "$(jq -r .n <<<"$row")" || cu_say "${new%% *} not written to $CU_DIR/decision.last"
    fi
    printf '%-5s %-11s %s -> %s\n' "$([ "$yes" = 1 ] && echo DONE || echo PLAN)" "$id" "$old" "$new"
    n_plan=$((n_plan + 1))
  done <<<"$plan"
  echo "number: $n_plan to number, $n_skip skipped, $n_fail failed$([ "$yes" = 1 ] || echo ' — dry run, rerun with --yes to write')"
  [ "$n_fail" = 0 ]
}

ct_decision() {
  local sub=${1:-}; shift || true
  case "$sub" in
    new) ct_decision_new "$@" ;;
    answer) ct_decision_answer "$@" ;;
    list) ct_decision_list "$@" ;;
    number) ct_decision_number "$@" ;;
    *) cu_die 'usage: hive ct decision new --name "<the question>" [--task ID] [--desc FILE] [--front F] | answer <D-n|id> --comment TEXT|@FILE | list [--front F|--all] [--open] | number [--yes]' ;;
  esac
}

ct_main() {
  local sub=${1:-}; shift || true
  case "$sub" in
    ''|help|-h|--help) ;;
    *) cu_init || exit 1 ;;
  esac
  case "$sub" in
    find)  ct_find  "$@" ;;
    new)   ct_new   "$@" ;;
    show)  ct_show  "$@" ;;
    set)   ct_set   "$@" ;;
    check) ct_check "$@" ;;
    apply) ct_apply "$@" ;;
    stale) ct_stale "$@" ;;
    todo)  ct_todo  "$@" ;;
    sync)  ct_sync  "$@" ;;
    ack)   ct_ack   "$@" ;;
    decision) ct_decision "$@" ;;
    *) cat <<'EOF'
hive ct — the swarm's ClickUp tasks (configured in ~/.herdr-hive/clickup/config and taxonomy.tsv).
Every task has one front, one area and at least one module.
  hive ct find <words> [--module M] [--area A] [--front F] [--closed]   candidates by name
  hive ct new --area A --module M[,M] --name "..." [--type T] [--parent ID] [--desc FILE] [--status S]
              [--not-dup ID,...]      create in the caller's front; refuses while similar tasks exist
  hive ct show <id>                   status, tags, parent, subtasks, PRs, description, latest comments
  hive ct set <id> [--status S] [--comment TEXT|@FILE] [--area A] [--module +M,-M] [--type T|none]
              [--parent ID] [--front F]   --front hands the task to another front
  hive ct check --module M[,M] [--impact M[,M]] [--task ID]   collisions with tasks in progress
  hive ct apply <file.tsv> [--yes]    bulk changes (id, front, area, modules, parent, current status,
                                      new status, comment); a dry run unless --yes
  hive ct stale [--yes]               tasks left lying in testing or on hold (rules in the config);
                                      a dry run unless --yes, a person's task only listed
  hive ct todo <id> "<item>" [--checklist NAME]   an item on the task's checklist (created if missing)
  hive ct sync                       refresh the cache, create the taxonomy's missing tags
  hive ct ack <drone> --manual "<reason>"   a report clickup-sync could not apply, settled by hand
  hive ct decision new --name "<question>" [--task ID] [--desc FILE] [--front F]
                                      a decision the owner is asked for, on the decision list,
                                      numbered D-<n> by hive
  hive ct decision answer <D-n|id> --comment TEXT|@FILE   the answer, noted on the linked task too
  hive ct decision list [--front F|--all] [--open]   the caller's front's decisions, oldest first
  hive ct decision number [--yes]     numbers the decisions without a number; a dry run unless --yes
EOF
       [ -z "$sub" ] || [ "$sub" = help ] || [ "$sub" = -h ] || [ "$sub" = --help ] || exit 1 ;;
  esac
}
