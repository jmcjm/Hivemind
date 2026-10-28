#!/usr/bin/env bash
# clickup-sync.sh — applies the '## ClickUp' section of every drone report to its ClickUp task, so
# drones never write to ClickUp themselves:
#   - one comment carrying the report: the drone's STATUS, the proposed status, its comment, PRs,
#     branch and the '## Result' section (cut to CU_COMMENT_MAX characters, pointing at the report);
#   - the status: 'done'/'complete' mean status_done; with status_unverified set, status_done needs a
#     '## Prod' section (what was checked in production) or lands on status_unverified instead — a task
#     tagged verify_exempt (e.g. an analysis) is done once delivered; a closed task is never reopened.
# Does nothing without $HIVE_DIR/clickup/config. Runs right after a drone writes its report
# (drone-ping.sh, in the background) and from the systemd user timer hive-clickup-sync.timer.
#
# A report is applied once: its path and mtime go to clickup/sync.state, so a rewritten report is
# looked at again. The comment ends with the marker hive-report:<drone>:<mtime>, looked for before
# commenting, so a lost state never doubles it.
# The coordinator of the report's front gets a letter only when something needs a person: no section,
# no task, a task that does not exist, a status its list does not have, a done status lowered for
# want of a '## Prod' section, or ClickUp failing (that one once; the report is retried on every run).
# A report refused that way waits in clickup/sync.failed for 'hive ct ack <drone> --manual <reason>'.
# Every outcome is a line in clickup/sync.log and, for drone-ping, in the drone's .clickup-sync file.
# First run (no state): reports older than HIVE_CLICKUP_SYNC_SINCE seconds (default 24 h) are recorded
# without a word, and so is every report in the format from before this sync (an 'applied:' line).
# Reports of drones without a ClickUp task in their meta.json and of muted drones are skipped.
# Before the reports it replays the start writes 'hive task' could not make (clickup/starts).
set -uo pipefail

HIVE_DIR="${HIVE_DIR:-$HOME/.herdr-hive}"
SKILL_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
HIVE_BIN="$SKILL_DIR/hive"
# shellcheck source=clickup.sh
. "$SKILL_DIR/clickup.sh"
cu_enabled || exit 0
cu_init || exit 1

mkdir -p "$CU_DIR"
# One sync at a time: the hook of every drone that ends a turn starts one.
exec 9>"$CU_DIR/sync.lock"
flock -w 300 9 || exit 0

first=0; [ -f "$CU_SYNC_STATE" ] || first=1
since=$(( $(date +%s) - ${HIVE_CLICKUP_SYNC_SINCE:-86400} ))
touch "$CU_SYNC_STATE" "$CU_SYNC_FAILED" "$CU_SYNC_RETRY"

# section <heading> — the body of '## <heading>' in $report, up to the next '## ' heading.
section() { awk -v h="## $1" 'index($0, "## ") == 1 { on = (tolower($0) == tolower(h)); next } on' "$report"; }
# field <key> [all] — '<key>: value' from the ClickUp section; every one with 'all'.
field() {
  awk -v k="$1" -v all="${2:-}" 'BEGIN { k = tolower(k) ":" }
    { l = $0; sub(/^[[:space:]]+/, "", l)
      if (index(tolower(l), k) == 1) { v = substr(l, length(k) + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; if (all == "") exit } }' <<<"$cu_section"
}
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$CU_LOG"; }
add() { printf '%s\n' "$key" >> "$1"; }
drop() { grep -qxF -- "$key" "$1" || return 0; grep -vxF -- "$key" "$1" > "$1.tmp"; mv -f "$1.tmp" "$1"; }

# letter <subject> <body> — to the coordinator of the report's front.
letter() {
  HIVE_DRONE=clickup-sync HIVE_DIR="$HIVE_DIR" HIVE_FRONT="$front" "$HIVE_BIN" send coord "$1" --body "$2" >/dev/null 2>&1
}

# refuse <reason> <what to do> — hands the report to the coordinator: 1, or 5 when the letter failed.
refuse() {
  outcome="✗ $1"
  letter "CLICKUP ✗ $drone${task:+ $task}: $1" "report: $report
$2
Then: hive ct ack $drone --manual \"<what you did>\"" && return 1
  return 5
}

# report_comment <shown status> <note> — the comment carrying the report, at most CU_COMMENT_MAX characters.
report_comment() {
  local head tail result pr room
  head="🤖 [drone $drone, front $front] STATUS: ${rstatus:-?} → $1"
  [ -z "$comment" ] || head+=$'\n'"$comment"
  while IFS= read -r pr; do [ -z "$pr" ] || head+=$'\n'"PR: $pr"; done <<<"$prs"
  [ -z "$branch" ] || head+=$'\n'"branch: $branch"
  [ -z "$2" ] || head+=$'\n'"⚠ $2"
  tail=$'\n\n'"report: $report"$'\n'"$marker"
  result=$(section Result)
  room=$(( CU_COMMENT_MAX - ${#head} - ${#tail} - 20 ))
  if [ "${#result}" -gt "$room" ]; then
    result="${result:0:$(( room - 60 ))}"$'\n'"… (cut — the whole report is at the path below)"
  fi
  printf '%s\n\n## Result\n%s%s\n' "$head" "$result" "$tail"
}

# sync_report — 0 applied, 1 refused with a letter, 2 ClickUp unavailable, 5 the letter failed,
# 6 a report in the format from before this sync (recorded, not applied).
sync_report() {
  local json rc now want shown note="" setto="" list lowered=0 done_st unverified exempt
  cu_section=$(section ClickUp)
  task="" outcome=""
  [ -n "$cu_section" ] || { refuse "no ClickUp section" "Apply it by hand: hive ct set <id> --status <s> --comment @<file>"; return; }
  [ -n "$(field applied)" ] && return 6
  task=$(field task); task=${task##*/}
  rstatus=$(grep -m1 -oE '^STATUS:[[:space:]]*[A-Z]+' "$report" | sed -E 's/^STATUS:[[:space:]]*//')
  comment=$(field comment); prs=$(field pr all); branch=$(field branch)
  case "${task,,}" in
    ''|none|'?') task=""; refuse "the report names no task" "Find or create it (hive ct find / hive ct new) and apply the section: hive ct set <id> --status <s> --comment @<file>"; return ;;
  esac
  cu_ready || return 2
  json=$(cu_task "$task" 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    3) refuse "task $task does not exist" "Find the right one (hive ct find <words>) and apply the section with hive ct set"; return ;;
    *) return 2 ;;
  esac
  now=$(cu_status_of "$json"); shown=$now
  want=$(cu_norm_status "$(field status)")
  done_st=$(cu_statuses done | head -1); unverified=$(cu_statuses unverified | head -1); exempt=$(cu_cfg verify_exempt)
  if [ -n "$want" ] && [ "$want" != "$now" ]; then
    if cu_status_is "$now" closed; then
      note="the status stays '$now': the sync never reopens a closed task (proposed: $want)"
    else
      if [ "$want" = "$done_st" ] && [ -n "$unverified" ] && [ -z "$(section Prod | tr -d '[:space:]')" ] \
         && ! { [ -n "$exempt" ] && grep -qxF -- "${exempt,,}" <<<"$(cu_jq "$json" 'tagnames[]')"; }; then
        want=$unverified; lowered=1
        note="no production check (no '## Prod' section): $done_st lowered to $unverified"
      fi
      list=$(jq -r '.list.id // empty' <<<"$json")
      cu_status_valid "${list:-$(cu_cfg list)}" "$want" 2>/dev/null; rc=$?
      case "$rc" in
        0) setto=$want; shown=$want ;;
        4) note="status '$want' does not exist in the task's list — it stays '$now'" ;;
        *) return 2 ;;
      esac
    fi
  fi
  cu_has_comment "$task" "$marker" --contains; rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) cu_comment "$task" "$(report_comment "$shown" "$note")" "$marker" || return 2 ;;
  esac
  if [ -n "$setto" ]; then cu_set_status "$json" "$setto" || return 2; fi
  log "applied $front/$drone $task: comment${setto:+, status $now -> $setto}${note:+ ($note)}"
  if [ -n "$want" ] && [ -z "$setto" ] && [ "$want" != "$now" ] && ! cu_status_is "$now" closed; then
    refuse "status '$want' does not exist for $task" "The comment is on the task. Set the status by hand: hive ct set $task --status <s>"; return
  fi
  outcome="$task → $shown ✓"
  if [ "$lowered" = 1 ]; then
    outcome="$task → $shown ✓ (no ## Prod)"
    letter "CLICKUP $drone $task: $done_st lowered to $unverified" "report: $report
The report proposes '$done_st' without a '## Prod' section (what was checked in production after the deploy).
Once production is checked: hive ct set $task --status $done_st --comment \"<what was checked>\"" || true
  fi
  return 0
}

# The start writes 'hive task' queued (ClickUp down at the gate, or failing on a write), oldest first,
# before the reports: a start never lands after the report that ends the work. The first one ClickUp
# fails on stops the replay; it and the rest wait for the next run.
for start in "$CU_STARTS"/*.json; do
  [ -f "$start" ] || continue
  what=$(jq -r '"\(.front)/\(.drone) \(.task)"' "$start" 2>/dev/null)
  rc=2; cu_ready && { cu_start_apply "$start" 2>/dev/null; rc=$?; }
  if [ "$rc" = 2 ]; then log "ClickUp unavailable for the start writes of ${what:-$start} — will retry"; break; fi
  rm -f "$start"
  case "$rc" in
    0) log "start writes $what: applied" ;;
    4) log "start writes ${what:-$start}: dropped (record unreadable)" ;;
    *) log "start writes $what: dropped (task unreadable)" ;;
  esac
done

for report in "$HIVE_DIR"/drones/*/report.md "$HIVE_DIR"/fronts/*/drones/*/report.md; do
  [ -f "$report" ] || continue
  ddir=$(dirname "$report"); drone=$(basename "$ddir")
  front=default
  case "$report" in "$HIVE_DIR"/fronts/*) front=$(basename "$(dirname "$(dirname "$ddir")")") ;; esac
  [ -f "$ddir/.mute" ] && continue
  [ -n "$(jq -r '.clickup_task // empty' "$ddir/meta.json" 2>/dev/null)" ] || continue
  mtime=$(stat -c %Y "$report" 2>/dev/null) || continue
  key="$report $mtime"
  grep -qxF -- "$key" "$CU_SYNC_STATE" "$CU_SYNC_FAILED" 2>/dev/null && continue
  if [ "$first" = 1 ] && [ "$mtime" -lt "$since" ]; then add "$CU_SYNC_STATE"; continue; fi
  marker="hive-report:$drone:$mtime"

  sync_report; rc=$?
  case "$rc" in
    0) add "$CU_SYNC_STATE"; drop "$CU_SYNC_RETRY" ;;
    1) add "$CU_SYNC_FAILED"; drop "$CU_SYNC_RETRY"; log "refused $front/$drone ${task:-?}: ${outcome#✗ }" ;;
    2) outcome="✗ ClickUp unavailable, retrying"
       log "ClickUp unavailable for $front/$drone — will retry"
       if ! grep -qxF -- "$key" "$CU_SYNC_RETRY"; then
         letter "CLICKUP ✗ $drone${task:+ $task}: ClickUp unavailable" "report: $report
The sync retries on every run (hook and timer). If it keeps failing, apply the section by hand with
hive ct set, then: hive ct ack $drone --manual \"<what you did>\"" && add "$CU_SYNC_RETRY"
       fi ;;
    6) add "$CU_SYNC_STATE"; continue ;;
    *) continue ;;
  esac
  printf '%s\t%s\n' "$mtime" "$outcome" > "$ddir/.clickup-sync"
done
exit 0
