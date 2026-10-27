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
CU_LOG="$CU_DIR/sync.log"
# clickup-sync's memory of reports, by path and mtime: applied, refused (waiting for 'ct ack'), and
# failing on ClickUp itself (retried on every run).
CU_SYNC_STATE="$CU_DIR/sync.state"
CU_SYNC_FAILED="$CU_DIR/sync.failed"
CU_SYNC_RETRY="$CU_DIR/sync.retry"
# The start writes of a brief let through while ClickUp was down, one file each; clickup-sync replays them.
CU_STARTS="$CU_DIR/starts"
CU_COMMENT_MAX=8000                  # ClickUp takes 40000 characters; a report comment stays readable
CU_REGISTRY_TTL=600                  # 'ct find' refreshes a cache older than this
CU_GATE_BUDGET=10                    # seconds 'hive task' waits for ClickUp before counting it down
CU_KINDS="front module area type"
CU_ROW_HEADER=$'id\tstatus\tfront\tmodules\tarea\tparent\tname\tupdated'
CU_TMP="" CU_NO_TOKEN=0 CU_LOADED=0 CU_SPACE_TAGS="" CU_DEADLINE=""
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

# cu_statuses <early|active|closed|start|done|unverified> — the configured statuses, lower case, one a line.
cu_statuses() { cu_cfg "status_$1" | tr '|' '\n' | while IFS= read -r s; do s=$(cu_trim "${s,,}"); [ -z "$s" ] || echo "$s"; done; }
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

cu_cleanup() {
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
  local cmd file
  cmd=$(cu_cfg token_cmd); file=$(cu_cfg token_file); file=${file/#\~/$HOME}
  if [ -n "$cmd" ]; then
    [ "$(cu_time 60)" -gt 0 ] || { cu_say "no time left to run token_cmd"; return 1; }
    timeout "$(cu_time 60)" bash -c "$cmd" > "$CU_TMP/tok" 2>"$CU_TMP/tok.err" </dev/null \
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

# cu_api <METHOD> <path> [json-body] — prints the response body. Returns 0 on success, 3 when the
# object does not exist (ClickUp answers 401 OAUTH_027 for a task id nobody has, not 404), 1 when
# ClickUp refuses the call (its message on stderr), 2 when ClickUp is unavailable: no token, network
# down, 5xx, a rejected token, or a rate limit beyond the retries. No attempt and no wait runs past
# CU_DEADLINE. A write whose attempt timed out or got a 5xx may have landed all the same: when
# CU_RETRY_GUARD holds a command, it runs before every retry, and its success ends the call as done.
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
  for attempt in 1 2 3 4; do
    max=$(cu_time 30); [ "$max" -gt 0 ] || break
    if [ "$attempt" -gt 1 ] && [ "$code" != 429 ] && [ ${#guard[@]} -gt 0 ] && "${guard[@]}" 2>/dev/null; then
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
    [ "$attempt" -lt 4 ] && sleep "$(cu_time "$wait")"
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

# cu_space_rows <include-closed:true|false> [updated-after-ms] — every task of the space as registry rows.
cu_space_rows() {
  local q json n page=0
  q="space_ids%5B%5D=$(cu_cfg space)&subtasks=true&include_closed=$1"
  [ -n "${2:-}" ] && q+="&date_updated_gt=$2"
  while [ "$page" -lt 50 ]; do
    json=$(cu_api GET "/team/$(cu_cfg workspace)/task?$q&page=$page") || return
    cu_jq "$json" '.tasks[] | row'
    n=$(jq '.tasks | length' <<<"$json")
    [ "$n" -ge 100 ] && [ "$(jq -r '.last_page // false' <<<"$json")" != true ] || break
    page=$((page + 1))
  done
}

# cu_registry_refresh — open tasks plus those closed in the last 30 days, written atomically.
cu_registry_refresh() {
  local open closed since tmp
  since=$(( ($(date +%s) - 30 * 86400) * 1000 ))
  open=$(cu_space_rows false) || return
  closed=$(cu_space_rows true "$since") || return
  mkdir -p "$CU_DIR"
  tmp=$(mktemp "$CU_DIR/.registry.XXXXXX") || return 1
  { printf '%s\n' "$CU_ROW_HEADER"; printf '%s\n%s\n' "$open" "$closed" | awk -F'\t' 'NF && !seen[$1]++'; } > "$tmp"
  mv -f "$tmp" "$CU_REGISTRY"
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

# cu_has_comment <id> <text> [--contains] — among the 25 latest comments: one equal to the text
# (whitespace-insensitive), or with --contains one holding it. 2 when ClickUp is down.
cu_has_comment() {
  local json
  json=$(cu_api GET "/task/$1/comment") || return 2
  jq -e --arg t "$2" --arg how "${3:-}" 'def n: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
      ($t | n) as $want | any(.comments[]?; (.comment_text // "" | n) as $c | if $how == "" then $c == $want else ($c | contains($want)) end)' \
    <<<"$json" >/dev/null
}

cu_comment_once() {  # cu_comment_once <id> <text> [marker] — never twice the same comment (or marker)
  local rc; cu_has_comment "$1" "${3:-$2}" ${3:+--contains}; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 2 ] && return 2
  cu_comment "$@"
}

# cu_set_front <task-json> <front-tag> <why> — hands a task to another front, with a comment.
cu_set_front() {
  local old id; id=$(jq -r .id <<<"$1"); old=$(cu_jq "$1" 'kind("front") | join(",")')
  [ "$old" = "$2" ] && return 0
  cu_tags_set "$1" front "$2" || return
  cu_comment "$id" "🤖 task handed over from ${old:-no front} to $2: $3"
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

# cu_claims [except-front except-drone] — CU_CLAIMS: the drones at work on a task (hive's
# drone_claims: front, drone, task, modules), every front. Empty where hive is not around.
cu_claims() {
  CU_CLAIMS="$CU_TMP/claims"
  if declare -F drone_claims >/dev/null; then drone_claims "${1:-}" "${2:-}" > "$CU_CLAIMS"; else : > "$CU_CLAIMS"; fi
}

# cu_collisions <task|-> <modules> — the tasks a drone on <task> working in <modules> would collide with:
# a task in an active status sharing a module, other than the task itself, its ancestors and its
# subtasks, and not an epic (a task with subtasks); plus the tasks living drones hold in a shared
# module, whatever their status, unless the cache has the task closed. One line each: id, status,
# front, shared modules, name, drones.
cu_collisions() {
  local reg=$CU_REGISTRY; [ -f "$reg" ] || reg=/dev/null
  awk -F'\t' -v self="$1" -v want="$2" -v active="|$(cu_statuses active | paste -sd'|')|" -v claims="$CU_CLAIMS" \
      -v closed="|$(cu_statuses closed | paste -sd'|')|" '
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
        if (related(id) || (id in haschild) || !index(active, "|" status[id] "|")) continue
        s = shared(mods[id]); if (s != "") hit[id] = s }
      for (j = 1; j <= nc; j++) { id = ctask[j]
        if (id == "" || related(id) || ((id in status) && index(closed, "|" status[id] "|"))) continue
        s = shared(cmods[j]); if (s == "") continue
        hit[id] = (id in hit) ? union(hit[id], s) : s
        drones[id] = drones[id] (drones[id] == "" ? "" : ",") cdrone[j] " (front " cfront[j] ")" }
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

CU_GATE_MSG="" CU_GATE_TASK="" CU_GATE_ID="" CU_UP=0 CU_MODS="" CU_IMPACT="" CU_CHECKED="" CU_SETTLED="" CU_CLAIMS=""
# cu_gate <drone> <task> <brief> <front> — may <drone> of <front> start on <task>? 0 yes, 1 no with
# CU_GATE_MSG saying what to fix. ClickUp being down lets the brief through with CU_GATE_MSG as a
# warning (an outage must not stop the swarm); collisions are then counted on the cache as it is and
# on the drones at work. ClickUp gets CU_GATE_BUDGET seconds for the token and the task: a network
# that drops packets must not hold the coordinator for minutes. Leaves the task id in CU_GATE_ID,
# the task in CU_GATE_TASK and CU_UP=1 when ClickUp answered.
cu_gate() {
  local drone=$1 id=$2 brief=$3 front=$4 rc mine fronts areas col warn=""
  CU_UP=0 CU_GATE_TASK="" CU_GATE_ID=$id CU_GATE_MSG=""
  cu_init 2>/dev/null || { CU_GATE_MSG=$(cu_init 2>&1); return 1; }
  cu_brief_header "$brief" || return 1
  mine=$(cu_front_tag "$front" 2>&1) || { CU_GATE_MSG="front $front has no tag in $CU_TAXONOMY: $mine"; return 1; }
  cu_tmpdir || { CU_GATE_MSG="cannot create a private directory"; return 1; }
  CU_DEADLINE=$(( $(date +%s) + CU_GATE_BUDGET ))
  if cu_ready; then CU_GATE_TASK=$(cu_task "$id" 2>"$CU_TMP/gate.err"); rc=$?; else rc=2; fi
  CU_DEADLINE=""
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
  [ "$CU_UP" = 1 ] && { cu_registry_ready 0 2>/dev/null || true; }
  cu_claims "$front" "$drone"
  col=$(cu_collisions "$id" "$CU_MODS${CU_IMPACT:+,$CU_IMPACT}")
  cu_settle "$col" || return 1
  CU_GATE_MSG=$warn
}

# cu_started <drone> <front> <title> — after the brief is installed: its start writes (cu_start_apply)
# go to the start queue, and right away to ClickUp when it answered the gate. Those ClickUp fails on,
# or all of them while it is down, wait in the queue for clickup-sync. Warns, never fails.
cu_started() {
  local at tmp f
  at=$(date +%s)
  mkdir -p "$CU_STARTS" && tmp=$(mktemp "$CU_STARTS/.start.XXXXXX") \
    || { cu_say "could not queue the start writes of $CU_GATE_ID"; return 0; }
  f="$CU_STARTS/$at.${tmp##*.}.json"   # oldest first in a listing
  jq -n --arg drone "$1" --arg front "$2" --arg title "$3" --arg task "$CU_GATE_ID" --arg mods "$CU_MODS" \
        --arg impact "$CU_IMPACT" --arg settled "$CU_SETTLED" --arg at "$at" \
        '{drone: $drone, front: $front, task: $task, title: $title, modules: $mods, impact: $impact, settled: $settled, at: $at}' > "$tmp" \
    && mv -f "$tmp" "$f" || { rm -f "$tmp"; cu_say "could not queue the start writes of $CU_GATE_ID"; return 0; }
  [ "$CU_UP" = 1 ] || return 0
  cu_start_apply "$f"
  if [ "$?" = 2 ]; then cu_say "ClickUp failed — clickup-sync retries the start writes of $CU_GATE_ID"; else rm -f "$f"; fi
}

# cu_start_apply <file> — the start writes of a queued brief: the brief's modules the task lacks are
# added to it, an early status moves to status_start, the task gets a start comment (marked
# hive-start:<drone>:<time>: a replay never doubles it) and every settled collision a comment on both
# tasks. 0 done, 2 when ClickUp failed on a write (worth a retry), 1 when there is nothing to retry:
# the record is unreadable or the task cannot be read.
cu_start_apply() {
  local drone front id title mods impact at settled json st m add="" cid reason shared marker rc
  IFS=$'\037' read -r drone front id title mods impact at \
    < <(jq -r '[.drone, .front, .task, .title, .modules, .impact, .at] | join("\u001f")' "$1" 2>/dev/null)
  [ -n "$id" ] && [ -n "$at" ] || { cu_say "unreadable start record $1"; return 1; }
  settled=$(jq -r .settled "$1")
  json=$(cu_task "$id" 2>/dev/null); rc=$?
  case "$rc" in
    0) rc=0 ;;
    2) return 2 ;;
    *) cu_say "task $id cannot be read — its start writes are dropped"; return 1 ;;
  esac
  for m in ${mods//,/ }; do add+="$(cu_tag module "$m")"$'\n'; done
  cu_tags_change "$json" "$add" "" || { [ "$?" = 2 ] && rc=2; cu_say "could not add the brief's modules to $id"; }
  st=$(cu_status_of "$json")
  if cu_status_is "$st" early; then
    cu_set_status "$json" "$(cu_statuses start | head -1)" \
      || { [ "$?" = 2 ] && rc=2; cu_say "could not move $id to '$(cu_statuses start | head -1)'"; }
  fi
  marker="hive-start:$drone:$at"
  cu_comment_once "$id" "🤖 drone $drone (front $front) start: $title; modules: ${mods//,/, }; impact: ${impact:-none}"$'\n'"$marker" "$marker" \
    || { [ "$?" = 2 ] && rc=2; cu_say "could not comment on $id"; }
  while IFS=$'\t' read -r cid reason shared; do
    [ -n "$cid" ] || continue
    for m in "$id" "$cid"; do
      cu_comment_once "$m" "🤖 collision checked: drone $drone (front $front) on $id works in modules ${shared//,/, } of $cid as well: $reason" \
        || { [ "$?" = 2 ] && rc=2; cu_say "could not comment on $m"; }
    done
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
  comments=$(cu_api GET "/task/$id/comment") || comments='{"comments":[]}'
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
  echo; echo "--- latest comments (oldest first)"
  jq -r '.comments[:8] | reverse | if length == 0 then "(none)" else .[] |
         "[\((.date | tonumber / 1000 | strflocaltime("%Y-%m-%d %H:%M"))) \(.user.username // "?")] \(.comment_text)" end' <<<"$comments"
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
  local mods="" impact="" task="-" col
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
    sync)  ct_sync  "$@" ;;
    ack)   ct_ack   "$@" ;;
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
  hive ct sync                        refresh the cache, create the taxonomy's missing tags
  hive ct ack <drone> --manual "<reason>"   a report clickup-sync could not apply, settled by hand
EOF
       [ -z "$sub" ] || [ "$sub" = help ] || [ "$sub" = -h ] || [ "$sub" = --help ] || exit 1 ;;
  esac
}
