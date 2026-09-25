#!/usr/bin/env bash
# Fetch registered repositories, fast-forward clean main roots, and optionally
# announce newly observed squash merges. Intended for launchd/systemd user jobs.
set -uo pipefail
umask 077
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=15
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 1
# shellcheck source=huddle-lib.sh disable=SC1091
source "$SCRIPT_DIR/huddle-lib.sh"

huddle_service_usage() {
  printf 'Usage: huddle-service.sh run --role updater|leader\n' >&2
  printf '       huddle-service.sh status\n' >&2
}

huddle_service_atomic_line() {
  local path="$1" value="$2" temp
  temp="${path}.tmp.$$"
  printf '%s\n' "$value" >"$temp" 2>/dev/null || return 1
  mv -f "$temp" "$path" 2>/dev/null || { rm -f "$temp" 2>/dev/null || true; return 1; }
}

huddle_service_log() {
  local state_dir="$1" level="$2" message="$3" log_file
  log_file="$state_dir/service.log"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$message" >>"$log_file" 2>/dev/null || true
}

huddle_service_write_status() {
  local state_dir="$1" role="$2" healthy="$3" message="$4" remote_head="${5:-}" outcome="${6:-}" temp checked_epoch
  mkdir -p "$state_dir" 2>/dev/null || return 1
  temp="$state_dir/status.json.tmp.$$"
  checked_epoch=$(date +%s 2>/dev/null) || checked_epoch=0
  jq -n \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson checked_at_epoch "$checked_epoch" \
    --arg role "$role" \
    --arg message "$message" \
    --arg remote_head "$remote_head" \
    --arg outcome "$outcome" \
    --argjson healthy "$healthy" \
    '{schema_version: 1, checked_at: $checked_at, checked_at_epoch: $checked_at_epoch,
      role: $role, healthy: $healthy,
      message: $message, remote_head: $remote_head, outcome: $outcome}' >"$temp" 2>/dev/null || return 1
  mv -f "$temp" "$state_dir/status.json" 2>/dev/null || { rm -f "$temp" 2>/dev/null || true; return 1; }
}

huddle_service_fail() {
  local state_dir="$1" role="$2" message="$3" remote_head="${4:-}"
  huddle_service_log "$state_dir" ERROR "$message"
  huddle_service_write_status "$state_dir" "$role" false "$message" "$remote_head" failed || true
  return 1
}

huddle_service_post_merges() {
  local checkout="$1" state_dir="$2" remote_head="$3" cursor old sha subject pr title today comments existing temp commits
  cursor="$state_dir/announcement-cursor"
  if [[ ! -f "$cursor" ]]; then
    huddle_service_atomic_line "$cursor" "$remote_head" || return 1
    HUDDLE_ANNOUNCEMENT_OUTCOME="baselined"
    return 0
  fi
  old=""
  read -r old <"$cursor" 2>/dev/null || true
  if [[ -z "$old" ]] || ! git -C "$checkout" cat-file -e "$old^{commit}" 2>/dev/null; then
    huddle_service_atomic_line "$cursor" "$remote_head" || return 1
    HUDDLE_ANNOUNCEMENT_OUTCOME="cursor-reset"
    return 0
  fi
  if ! git -C "$checkout" merge-base --is-ancestor "$old" "$remote_head" 2>/dev/null; then
    huddle_service_atomic_line "$cursor" "$remote_head" || return 1
    HUDDLE_ANNOUNCEMENT_OUTCOME="force-push-reset"
    return 0
  fi

  HUDDLE_ANNOUNCEMENT_OUTCOME="unchanged"
  commits=$(git -C "$checkout" log --first-parent --reverse --format='%H%x1f%s' "$old..$remote_head" 2>/dev/null) || return 1
  while IFS=$'\037' read -r sha subject; do
    [[ -n "$sha" ]] || continue
    if [[ "$subject" =~ \ \(#([0-9]+)\)$ ]]; then
      pr="${BASH_REMATCH[1]}"
      title="${subject% (#"$pr")}"
      today=$(cd "$checkout" && HUDDLE_CWD="$checkout" huddle_today_bead_id 2>/dev/null) || return 1
      [[ -n "$today" ]] || return 1
      comments=$(cd "$checkout" && bd comments "$today" --json 2>/dev/null) || return 1
      printf '%s' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
      existing=$(printf '%s' "$comments" | jq -r '.[].text' 2>/dev/null | grep -E "Merged PR #${pr}([^0-9]|$)" || true)
      if [[ -z "$existing" ]]; then
        (cd "$checkout" && bd comments add "$today" "Merged PR #$pr: $title —huddle-auto") >/dev/null 2>&1 || return 1
      fi
      HUDDLE_ANNOUNCEMENT_OUTCOME="announced"
    fi
    huddle_service_atomic_line "$cursor" "$sha" || return 1
  done <<<"$commits"
  return 0
}

huddle_service_run_repo() {
  local role="$1" id="$2" checkout="$3" branch="$4" state_dir lock now lock_time remote_ref remote_head
  local local_branch dirty local_head update_outcome message
  state_dir="$(huddle_service_state_root)/$id"
  mkdir -p "$state_dir" 2>/dev/null || return 1
  lock="$state_dir/run.lock"
  now=$(date +%s 2>/dev/null) || now=0
  if ! mkdir "$lock" 2>/dev/null; then
    lock_time=$(huddle_path_mtime "$lock" 2>/dev/null) || lock_time="$now"
    if [[ "$now" =~ ^[0-9]+$ && "$lock_time" =~ ^[0-9]+$ ]] && (( now - lock_time > 300 )); then
      rmdir "$lock" 2>/dev/null || true
      mkdir "$lock" 2>/dev/null || return 0
    else
      huddle_service_log "$state_dir" INFO "run skipped: another invocation holds the lock"
      return 0
    fi
  fi

  remote_ref="refs/remotes/origin/$branch"
  if ! git -C "$checkout" fetch --quiet origin "$branch"; then
    rmdir "$lock" 2>/dev/null || true
    huddle_service_fail "$state_dir" "$role" "fetch failed for origin/$branch"
    return 1
  fi
  remote_head=$(git -C "$checkout" rev-parse "$remote_ref" 2>/dev/null) || {
    rmdir "$lock" 2>/dev/null || true
    huddle_service_fail "$state_dir" "$role" "fetched ref is unavailable: $remote_ref"
    return 1
  }
  huddle_service_atomic_line "$state_dir/fetch-cursor" "$remote_head" || {
    rmdir "$lock" 2>/dev/null || true
    huddle_service_fail "$state_dir" "$role" "could not write fetch cursor" "$remote_head"
    return 1
  }

  local_branch=$(git -C "$checkout" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  dirty=$(git -C "$checkout" status --porcelain 2>/dev/null || printf 'unknown')
  update_outcome="skipped-off-main"
  if [[ "$local_branch" == "$branch" ]]; then
    if [[ -n "$dirty" ]]; then
      update_outcome="skipped-dirty"
    else
      local_head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
      if [[ "$local_head" == "$remote_head" ]]; then
        update_outcome="already-current"
      elif git -C "$checkout" merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null \
        && git -C "$checkout" merge --ff-only --quiet "$remote_ref" >/dev/null 2>&1; then
        update_outcome="fast-forwarded"
      else
        update_outcome="skipped-diverged"
      fi
    fi
  fi

  # Push local huddle posts and pull other machines' posts. Runs here rather
  # than in hooks so the network wait never counts against a hook timeout.
  # Before announcements, so the dedup check sees posts from other machines.
  # Fail-open and throttled by huddle_sync itself.
  (cd "$checkout" && HUDDLE_CWD="$checkout" huddle_sync) || true

  HUDDLE_ANNOUNCEMENT_OUTCOME="updater"
  if [[ "$role" == leader ]]; then
    if ! huddle_service_post_merges "$checkout" "$state_dir" "$remote_head"; then
      rmdir "$lock" 2>/dev/null || true
      huddle_service_fail "$state_dir" "$role" "merge announcement failed; cursor retained for retry" "$remote_head"
      return 1
    fi
  fi

  message="fetch ok; root $update_outcome; announcements $HUDDLE_ANNOUNCEMENT_OUTCOME"
  huddle_service_log "$state_dir" INFO "$message"
  if ! huddle_service_write_status "$state_dir" "$role" true "$message" "$remote_head" "$update_outcome"; then
    huddle_service_log "$state_dir" ERROR "could not persist successful service status"
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi
  rmdir "$lock" 2>/dev/null || true
  return 0
}

huddle_service_run() {
  local role="$1" failures id checkout branch registry_state dependency index
  registry_state="$(huddle_service_state_root)/_registry"
  for dependency in git jq; do
    command -v "$dependency" >/dev/null 2>&1 || {
      huddle_service_fail "$registry_state" "$role" "required command is unavailable: $dependency"
      return 1
    }
  done
  if [[ "$role" == leader ]] && ! command -v bd >/dev/null 2>&1; then
    huddle_service_fail "$registry_state" "$role" "required command is unavailable: bd"
    return 1
  fi
  if ! huddle_validate_registry; then
    huddle_service_fail "$registry_state" "$role" "trusted repository registry is invalid"
    return 1
  fi
  if ! huddle_service_write_status "$registry_state" "$role" true "trusted repository registry is valid" "" validated; then
    huddle_service_log "$registry_state" ERROR "could not persist successful registry status"
    return 1
  fi
  failures=0
  for index in "${!HUDDLE_REGISTRY_IDS[@]}"; do
    id="${HUDDLE_REGISTRY_IDS[$index]}"
    checkout="${HUDDLE_REGISTRY_CHECKOUTS[$index]}"
    branch="${HUDDLE_REGISTRY_BRANCHES[$index]}"
    huddle_service_run_repo "$role" "$id" "$checkout" "$branch" || failures=$((failures + 1))
  done
  [[ "$failures" -eq 0 ]]
}

huddle_service_check_status() {
  local label="$1" state_file="$2" now="$3" healthy checked checked_epoch message
  if [[ ! -f "$state_file" ]]; then
    printf '%s: no status yet\n' "$label"
    return 1
  fi
  healthy=$(jq -r '.healthy // false' "$state_file" 2>/dev/null) || healthy=false
  checked=$(jq -r '.checked_at // "unknown"' "$state_file" 2>/dev/null) || checked=unknown
  checked_epoch=$(jq -r '.checked_at_epoch // 0' "$state_file" 2>/dev/null) || checked_epoch=0
  message=$(jq -r '.message // "missing message"' "$state_file" 2>/dev/null) || message="invalid status"
  if [[ "$checked_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] && (( now - checked_epoch > 180 )); then
    printf '%s: stale (%s) %s\n' "$label" "$checked" "$message"
    return 1
  fi
  if [[ "$healthy" == true ]]; then
    printf '%s: healthy (%s) %s\n' "$label" "$checked" "$message"
    return 0
  fi
  printf '%s: unhealthy (%s) %s\n' "$label" "$checked" "$message"
  return 1
}

huddle_service_status() {
  local id state_file failures registry_status now index
  failures=0
  now=$(date +%s 2>/dev/null) || now=0
  if ! huddle_validate_registry; then
    printf 'registry: invalid current configuration\n'
    return 1
  fi
  registry_status="$(huddle_service_state_root)/_registry/status.json"
  huddle_service_check_status registry "$registry_status" "$now" || failures=$((failures + 1))
  for index in "${!HUDDLE_REGISTRY_IDS[@]}"; do
    id="${HUDDLE_REGISTRY_IDS[$index]}"
    state_file="$(huddle_service_state_root)/$id/status.json"
    huddle_service_check_status "$id" "$state_file" "$now" || failures=$((failures + 1))
  done
  [[ "$failures" -eq 0 ]]
}

case "${1:-}" in
  run)
    shift
    role=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --role) role="${2:-}"; shift 2 ;;
        *) huddle_service_usage; exit 2 ;;
      esac
    done
    case "$role" in updater|leader) ;; *) huddle_service_usage; exit 2 ;; esac
    huddle_service_run "$role"
    ;;
  status)
    [[ $# -eq 1 ]] || { huddle_service_usage; exit 2; }
    huddle_service_status
    ;;
  *)
    huddle_service_usage
    exit 2
    ;;
esac
