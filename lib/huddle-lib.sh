#!/usr/bin/env bash
# shellcheck disable=SC2250  # unbraced $vars are consistent throughout this codebase
# huddle-lib.sh — shared helpers for the huddle coordination scripts.
#
# Sourced by huddle-poll.sh, huddle-session-start.sh, huddle-whoami.sh.
# Not invoked directly. Harness-agnostic — used by any agent harness whose
# bootstrap shim routes through these scripts.
#
# Why a shared lib: Huddle is globally installed, but enabled only for clones in
# the trusted repository registry. Every hook and service path must resolve the
# same repository id, canonical checkout, remote, and state root.

# Absolute path to the directory holding these scripts.
#
# Notices print runnable commands back to the agent, and those commands have to
# name a real path. It cannot be hardcoded: the huddle ships as a plugin, and
# each harness installs it somewhere different — Claude Code copies it into a
# versioned cache, Antigravity reads it from wherever it was symlinked. Derived
# from BASH_SOURCE rather than $0 so it stays correct when this file is sourced.
#
# The subagent classifier in huddle-whoami.sh is unaffected by what this
# resolves to: it matches on `basename "$0"`, the filename alone, with any
# directory prefix allowed.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
HUDDLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

huddle_registry_file() {
  printf '%s' "${HUDDLE_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agents-huddle/repos.json}"
}

huddle_agent_state_root() {
  printf '%s' "${HUDDLE_AGENT_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/agents-huddle/agent}"
}

huddle_service_state_root() {
  printf '%s' "${HUDDLE_SERVICE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/agents-huddle/service}"
}

# Print owner/repository in lower case for the GitHub URL forms accepted by git.
huddle_normalize_github_remote() {
  local value="${1:-}" path
  case "$value" in
    git@github.com:*) path="${value#git@github.com:}" ;;
    https://github.com/*) path="${value#https://github.com/}" ;;
    http://github.com/*) path="${value#http://github.com/}" ;;
    ssh://git@github.com/*) path="${value#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s' "$path" | tr '[:upper:]' '[:lower:]'
}

huddle_path_mtime() {
  local value
  value=$(stat -c %Y "$1" 2>/dev/null) && [[ "$value" =~ ^[0-9]+$ ]] && { printf '%s' "$value"; return 0; }
  value=$(stat -f %m "$1" 2>/dev/null) && [[ "$value" =~ ^[0-9]+$ ]] && { printf '%s' "$value"; return 0; }
  return 1
}

# Parse and validate one trusted registry entry. On success, set the HUDDLE_REPO_*
# globals used by both hook and service callers.
huddle_load_registry_entry() {
  local entry="$1" id checkout github branch home_real canonical top remote actual common
  command -v jq >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  id=$(printf '%s' "$entry" | jq -er '.id | select(type == "string")' 2>/dev/null) || return 1
  checkout=$(printf '%s' "$entry" | jq -er '.checkout | select(type == "string")' 2>/dev/null) || return 1
  github=$(printf '%s' "$entry" | jq -er '.github_remote | select(type == "string")' 2>/dev/null) || return 1
  branch=$(printf '%s' "$entry" | jq -er '.main_branch | select(type == "string")' 2>/dev/null) || return 1
  [[ "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  [[ -n "$checkout" && "$checkout" != /* && "$checkout" != "." ]] || return 1
  case "/$checkout/" in *"/../"*|*"/./"*|*"//"*) return 1 ;; esac
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
  github=$(huddle_normalize_github_remote "https://github.com/$github") || return 1

  home_real=$(cd "$HOME" 2>/dev/null && pwd -P) || return 1
  canonical=$(cd "$HOME/$checkout" 2>/dev/null && pwd -P) || return 1
  case "$canonical" in "$home_real"/*) ;; *) return 1 ;; esac
  top=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  [[ "$top" == "$canonical" ]] || return 1
  remote=$(git -C "$canonical" remote get-url origin 2>/dev/null) || return 1
  actual=$(huddle_normalize_github_remote "$remote") || return 1
  [[ "$actual" == "$github" ]] || return 1
  common=$(git -C "$canonical" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 1

  HUDDLE_REPO_ID="$id"
  HUDDLE_REPO_CHECKOUT="$canonical"
  HUDDLE_REPO_GITHUB="$github"
  HUDDLE_REPO_BRANCH="$branch"
  HUDDLE_REPO_COMMON_DIR="$common"
  return 0
}

# Validate the entire registry before trusting any entry. A malformed, duplicate,
# moved, or remote-mismatched entry disables every Huddle operation.
huddle_validate_registry() {
  local config entry
  HUDDLE_REGISTRY_IDS=()
  HUDDLE_REGISTRY_CHECKOUTS=()
  HUDDLE_REGISTRY_GITHUBS=()
  HUDDLE_REGISTRY_BRANCHES=()
  HUDDLE_REGISTRY_COMMON_DIRS=()
  config=$(huddle_registry_file)
  # GNU Stow normally deploys this file as a symlink into the dotfiles tree.
  [[ -f "$config" ]] || return 1
  jq -e '
    .schema_version == 1
    and (.repositories | type == "array" and length > 0)
    and ([.repositories[].id] | all(type == "string"))
    and ([.repositories[].id] | length == (unique | length))
    and ([.repositories[].checkout] | length == (unique | length))
  ' "$config" >/dev/null 2>&1 || return 1
  while IFS= read -r entry; do
    huddle_load_registry_entry "$entry" || return 1
    HUDDLE_REGISTRY_IDS+=("$HUDDLE_REPO_ID")
    HUDDLE_REGISTRY_CHECKOUTS+=("$HUDDLE_REPO_CHECKOUT")
    HUDDLE_REGISTRY_GITHUBS+=("$HUDDLE_REPO_GITHUB")
    HUDDLE_REGISTRY_BRANCHES+=("$HUDDLE_REPO_BRANCH")
    HUDDLE_REGISTRY_COMMON_DIRS+=("$HUDDLE_REPO_COMMON_DIR")
  done < <(jq -c '.repositories[]' "$config" 2>/dev/null)
}

# Resolve cwd to exactly one registered canonical clone. Linked worktrees match
# through git's shared common directory; independent clones stay unregistered.
huddle_resolve_repo() {
  local cwd="${1:-$PWD}" current_common index matches
  huddle_validate_registry || return 1
  current_common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  current_common=$(cd "$current_common" 2>/dev/null && pwd -P) || return 1
  matches=0
  for index in "${!HUDDLE_REGISTRY_IDS[@]}"; do
    if [[ "${HUDDLE_REGISTRY_COMMON_DIRS[$index]}" == "$current_common" ]]; then
      matches=$((matches + 1))
      HUDDLE_MATCH_ID="${HUDDLE_REGISTRY_IDS[$index]}"
      HUDDLE_MATCH_CHECKOUT="${HUDDLE_REGISTRY_CHECKOUTS[$index]}"
      HUDDLE_MATCH_GITHUB="${HUDDLE_REGISTRY_GITHUBS[$index]}"
      HUDDLE_MATCH_BRANCH="${HUDDLE_REGISTRY_BRANCHES[$index]}"
      HUDDLE_MATCH_COMMON_DIR="${HUDDLE_REGISTRY_COMMON_DIRS[$index]}"
    fi
  done
  [[ "$matches" -eq 1 ]] || return 1
  HUDDLE_REPO_ID="$HUDDLE_MATCH_ID"
  HUDDLE_REPO_CHECKOUT="$HUDDLE_MATCH_CHECKOUT"
  HUDDLE_REPO_GITHUB="$HUDDLE_MATCH_GITHUB"
  HUDDLE_REPO_BRANCH="$HUDDLE_MATCH_BRANCH"
  HUDDLE_REPO_COMMON_DIR="$HUDDLE_MATCH_COMMON_DIR"
  return 0
}

# Preserve the legacy per-worktree poll throttle on its first poll after the
# state migration. The atomic hard-link create never overwrites a newer marker.
huddle_migrate_legacy_poll_marker() {
  local worktree_root="$1" target="$2" source temp
  source="$worktree_root/.agents/.huddle-last-poll"
  [[ ! -e "$target" && -f "$source" && ! -L "$source" ]] || return 0
  mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
  temp="${target}.migrate.$$"
  cp -p "$source" "$temp" 2>/dev/null || return 1
  ln "$temp" "$target" 2>/dev/null || true
  rm -f "$temp" 2>/dev/null || true
  return 0
}

# Copy recognized legacy agent state once. Files are copied through same-directory
# temporary paths, stale lock files are excluded, and the source stays untouched.
huddle_migrate_legacy_state() {
  local legacy="$1" target="$2" marker lock now lock_time waited name source temp
  marker="$target/.legacy-migration-complete"
  lock="$target/.legacy-migration-lock"
  mkdir -p "$target" 2>/dev/null || return 1
  [[ -f "$marker" ]] && return 0
  # Existing tests may intentionally point the state override at the legacy
  # directory. There is nothing to copy in that case; mark the seam complete.
  if [[ "$legacy" == "$target" ]]; then
    temp="$target/.legacy-migration-complete-$$"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$temp" 2>/dev/null || return 1
    mv -f "$temp" "$marker" 2>/dev/null || return 1
    return 0
  fi

  if ! mkdir "$lock" 2>/dev/null; then
    now=$(date +%s 2>/dev/null) || now=0
    lock_time=$(huddle_path_mtime "$lock" 2>/dev/null) || lock_time="$now"
    if [[ "$now" =~ ^[0-9]+$ && "$lock_time" =~ ^[0-9]+$ ]] && (( now - lock_time > 60 )); then
      rmdir "$lock" 2>/dev/null || true
      mkdir "$lock" 2>/dev/null || return 1
    else
      waited=0
      while [[ -d "$lock" && ! -f "$marker" && "$waited" -lt 100 ]]; do
        sleep 0.05
        waited=$((waited + 1))
      done
      [[ -f "$marker" ]] && return 0
      mkdir "$lock" 2>/dev/null || return 1
    fi
  fi

  trap 'rmdir "$lock" 2>/dev/null || true' RETURN
  if [[ -d "$legacy" ]]; then
    for source in "$legacy"/*; do
      [[ -f "$source" && ! -L "$source" ]] || continue
      name=$(basename "$source")
      case "$name" in
        config.json|session-names.json|degraded-warned|last-pull|last-seen-*|nudged-*) ;;
        *) continue ;;
      esac
      [[ -e "$target/$name" ]] && continue
      temp="$target/.migrate-$name-$$"
      if cp -p "$source" "$temp" 2>/dev/null; then
        mv -f "$temp" "$target/$name" 2>/dev/null || { rm -f "$temp" 2>/dev/null || true; return 1; }
      else
        rm -f "$temp" 2>/dev/null || true
        return 1
      fi
    done
  fi
  temp="$target/.legacy-migration-complete-$$"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$temp" 2>/dev/null || return 1
  mv -f "$temp" "$marker" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null || true
  trap - RETURN
  return 0
}

# huddle_state_dir — print the registered repository's agent-writable state dir.
# Unknown repositories and invalid registry entries return 1 without output.
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_state_dir() {
  local state_dir
  huddle_resolve_repo "${HUDDLE_CWD:-$PWD}" || return 1
  state_dir="$(huddle_agent_state_root)/$HUDDLE_REPO_ID"
  huddle_migrate_legacy_state "$HUDDLE_REPO_CHECKOUT/.agents/huddle" "$state_dir" || return 1
  printf '%s' "$state_dir"
}

# huddle_dolt_mode — print the beads Dolt backend mode: "server" or "embedded".
#
# Reads `dolt_mode` from the registered canonical checkout's
# .beads/metadata.json (gitignored, per-machine). Parse is deliberately minimal and
# TOLERANT: a missing git dir, missing file, missing/blank key, absent jq, or
# any parse error all fall through to "embedded" — today's behavior and the safe
# default. Only the exact string "server" flips the mode. This is the single
# gate every hot-path `bd dolt push/pull` consults: when metadata.json says
# "server", beads is talking to a live SQL server and the sync calls no-op.
#
# Keep this to the mode string only. Any deeper server-config drift check
# belongs in beads' own tooling rather than hand-parsing more of this JSON here.
#
# Always returns 0 and always prints something (never empty).
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_dolt_mode() {
  local meta mode
  huddle_resolve_repo "${HUDDLE_CWD:-$PWD}" || { printf 'embedded'; return 0; }
  meta="$HUDDLE_REPO_CHECKOUT/.beads/metadata.json"
  [[ -f "$meta" ]] || { printf 'embedded'; return 0; }
  if command -v jq >/dev/null 2>&1; then
    mode=$(jq -r '.dolt_mode // "embedded"' "$meta" 2>/dev/null) || mode="embedded"
  else
    # jq-less tolerant fallback: grep the "dolt_mode": "..." pair.
    mode=$(grep -o '"dolt_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$meta" 2>/dev/null \
      | head -n1 | sed 's/.*"\([^"]*\)"$/\1/') || mode="embedded"
  fi
  [[ "$mode" == "server" ]] && { printf 'server'; return 0; }
  printf 'embedded'
  return 0
}

# huddle_warn_degraded — throttled one-line stderr notice when the shared beads
# server is unreachable in server mode. No-op in embedded mode (there is no
# server to be down). The huddle hooks are deliberately fail-open, so without
# this a down server would silently kill coordination on BOTH machines with zero
# signal (PP-0b7p class). Throttled to ~once per 10 min via a marker in the
# shared state dir so it never spams a session. Always returns 0.
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_warn_degraded() {
  [[ "$(huddle_dolt_mode)" == "server" ]] || return 0
  local state_dir marker interval now last
  state_dir=$(huddle_state_dir) || return 0
  marker="$state_dir/degraded-warned"
  interval=600
  if [[ -f "$marker" ]]; then
    last=0
    read -r last < "$marker" 2>/dev/null || true
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$last" -gt 0 ]]; then
      now=$(date +%s)
      (( now - last < interval )) && return 0
    fi
  fi
  mkdir -p "$state_dir" 2>/dev/null || true
  date +%s > "$marker" 2>/dev/null || true
  printf 'huddle degraded: beads server unreachable\n' >&2
  return 0
}

# huddle_root_id — resolve the coordination root epic id, treating
# <state_dir>/config.json as a REBUILDABLE CACHE rather than a source of truth.
# Reads the cached root_bead_id; if it's missing or no longer resolves (`bd show`
# fails), re-discovers the root by title query (huddle_discover_root) and rewrites
# config.json. Prints the id on success; non-zero + empty on any failure.
# Fail-open: callers MUST treat non-zero as "skip quietly".
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_root_id() {
  command -v bd >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local state_dir config_file root_id
  state_dir=$(huddle_state_dir) || return 1
  config_file="$state_dir/config.json"
  if [[ -f "$config_file" ]]; then
    root_id=$(jq -r '.root_bead_id // ""' "$config_file" 2>/dev/null) || root_id=""
    if [[ -n "$root_id" ]] && bd show "$root_id" --json >/dev/null 2>&1; then
      printf '%s' "$root_id"
      return 0
    fi
  fi
  # Cache miss or stale pointer → rediscover by title query and rewrite the cache.
  root_id=$(huddle_discover_root 2>/dev/null) || return 1
  [[ -n "$root_id" ]] || return 1
  mkdir -p "$state_dir" 2>/dev/null || true
  printf '{"schema_version": 1, "root_bead_id": "%s"}\n' "$root_id" > "$config_file" 2>/dev/null || true
  printf '%s' "$root_id"
}

# huddle_today_bead_id [root_id] [root_json] — print the ID of today's active
# coordination bead. Returns 0 on success (and prints the ID), non-zero + empty
# on any failure. Fail-open: callers MUST treat a non-zero return as "skip
# quietly".
#
# Optional pre-fetched args (hot-path budget): when the caller already holds the
# root id AND its `bd show <root> --json` blob — huddle-poll.sh does — pass both
# so this function skips huddle_root_id and the root `bd show` entirely. The
# pre-fetched form makes NO root bd show. Omit both (merge-pr.sh,
# huddle-pr-announce.sh) to resolve them internally.
#
# Resolution (reads the live DB, not a cache — PP-9lq5):
#   1. root id: caller-supplied, else huddle_root_id (rebuildable config cache
#      → title-query fallback).
#   2. Fast-path HINT: root notes .today_bead.id, but VERIFIED via `bd show`
#      (must still be open AND titled "Huddle daily <today>") before trust —
#      a dangling/stale pointer is never returned.
#   3. Fallback: title query over `bd children <root>` for the open
#      "Huddle daily <today>" (lowest id wins). Missing entirely ⇒ non-zero,
#      and the rotation path self-heals by (re)creating it.
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_today_bead_id() {
  command -v bd >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local root_id="${1:-}" root_json="${2:-}" today hint verified id
  if [[ -z "$root_id" ]]; then
    root_id=$(huddle_root_id) || return 1
    [[ -n "$root_id" ]] || return 1
  fi
  today=$(date +%F)

  # Fast-path hint from root notes. Reuse the caller's pre-fetched root JSON when
  # given; otherwise fetch it once (the only root show in the no-arg form).
  if [[ -z "$root_json" ]]; then
    root_json=$(bd show "$root_id" --json 2>/dev/null) || root_json=""
  fi
  hint=$(printf '%s' "$root_json" \
    | jq -r '.[0].notes // "{}" | (fromjson? // {}) | .today_bead.id // ""' 2>/dev/null) || hint=""
  if [[ -n "$hint" ]]; then
    verified=$(bd show "$hint" --json 2>/dev/null \
      | jq -r --arg t "Huddle daily $today" \
        '.[0] | select(.title==$t and .status!="closed") | .id // ""' 2>/dev/null) || verified=""
    if [[ -n "$verified" ]]; then
      printf '%s' "$verified"
      return 0
    fi
  fi

  # Fallback: canonical title query over children (self-healing source of truth).
  id=$(bd children "$root_id" --json 2>/dev/null \
    | jq -r --arg t "Huddle daily $today" \
      '[ .[] | select(.title==$t and .status!="closed") ] | sort_by(.id) | (.[0].id // "")' 2>/dev/null) || return 1
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# huddle_sync — throttled, per-machine Dolt push+pull to keep the huddle beads
# fresh across the user's machines. Fail-open: any error (offline,
# no remote, bd missing, lock held) returns 0 silently.
#
# Caller: huddle-service.sh, once per registered repository per run. Hooks must
# not call this. A push+pull takes several seconds on a healthy network, and
# while it runs every other session's `bd` read waits on the embedded Dolt lock,
# so calling it from a hook blew through the 10s hook timeout.
#
# Bounded blocking: each call is wrapped in `timeout` (GNU `timeout`, or
# `gtimeout` from coreutils on macOS) capped at $HUDDLE_SYNC_TIMEOUT seconds
# (default 15). If neither timeout binary exists the calls run unwrapped
# (bd/dolt still apply their own network deadlines).
#
# Per-machine throttle: the marker lives in the shared XDG agent-state directory
# (`agent/<repo-id>/last-pull`), which every worktree of this clone resolves to
# identically via huddle_state_dir. A non-blocking lock ensures exactly one
# caller syncs at a time; the rest skip.
#
# Interval: $HUDDLE_SYNC_SECONDS (default 180 — matches the poll throttle).
# Push-before-pull: local coordination posts propagate first, then peers ingest.
# The marker is written INSIDE the lock BEFORE the network calls (same backoff
# discipline as huddle-poll.sh's poll throttle) so a broken remote can't cause a
# hammer loop.
#
# Server mode: `huddle_sync` is a no-op. There is no local embedded Dolt to
# push or pull — every session reads and writes the one shared `dolt sql-server`
# directly, so coordination is already real-time and a sync step would be
# meaningless. Embedded mode, the default, keeps the throttled push+pull below.
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_sync() {
  command -v bd >/dev/null 2>&1 || return 0
  [[ "$(huddle_dolt_mode)" == "server" ]] && return 0
  local state_dir marker lockfile interval now last
  state_dir=$(huddle_state_dir) || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0
  marker="$state_dir/last-pull"
  lockfile="$state_dir/pull.lock"
  interval="${HUDDLE_SYNC_SECONDS:-180}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=180
  local sync_timeout="${HUDDLE_SYNC_TIMEOUT:-15}"
  [[ "$sync_timeout" =~ ^[0-9]+$ ]] || sync_timeout=15
  # Resolve a timeout binary once (GNU `timeout`, or `gtimeout` on macOS via
  # coreutils). Empty → run the network calls unwrapped.
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi

  # Fast throttle check (no lock): skip if the marker is fresh.
  if [[ -f "$marker" ]]; then
    # `read` returns non-zero on a marker with no trailing newline but still
    # assigns the partial value — keep it (|| true), then validate numeric.
    last=0
    read -r last < "$marker" 2>/dev/null || true
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$last" -gt 0 ]]; then
      now=$(date +%s)
      (( now - last < interval )) && return 0
    fi
  fi

  # The locked body re-checks the marker (a peer may have synced between our
  # fast check and acquiring the lock), writes the marker, then push+pulls.
  # It reads the marker path + interval from exported env vars (not positional
  # args) so the `bash -c` string needs no single-quote expansion — same
  # exported-function + exported-vars pattern as huddle-rotate.sh's do_rotation.
  export _HS_MARKER="$marker" _HS_INTERVAL="$interval"
  export _HS_TIMEOUT_BIN="$timeout_bin" _HS_TIMEOUT="$sync_timeout"
  _huddle_sync_body() {
    local m="$_HS_MARKER" iv="$_HS_INTERVAL" l n
    if [[ -f "$m" ]]; then
      l=0
      read -r l < "$m" 2>/dev/null || true
      [[ "$l" =~ ^[0-9]+$ ]] || l=0
      if [[ "$l" -gt 0 ]]; then
        n=$(date +%s)
        (( n - l < iv )) && return 0
      fi
    fi
    date +%s > "$m" 2>/dev/null || true
    # Wrap each network call in the resolved timeout binary (if any) so a hung
    # remote is killed at the cap rather than stalling the hook.
    if [[ -n "$_HS_TIMEOUT_BIN" ]]; then
      "$_HS_TIMEOUT_BIN" "$_HS_TIMEOUT" bd dolt push --quiet >/dev/null 2>&1 || true
      "$_HS_TIMEOUT_BIN" "$_HS_TIMEOUT" bd dolt pull --quiet >/dev/null 2>&1 || true
    else
      bd dolt push --quiet >/dev/null 2>&1 || true
      bd dolt pull --quiet >/dev/null 2>&1 || true
    fi
  }
  export -f _huddle_sync_body

  # Non-blocking lock — same lockf(macOS)/flock(Linux) split as huddle-rotate.sh.
  # If another session holds it, skip immediately (it is doing the sync for us).
  if command -v flock >/dev/null 2>&1; then
    flock -n "$lockfile" bash -c '_huddle_sync_body' 2>/dev/null || true
  elif command -v lockf >/dev/null 2>&1; then
    lockf -t 0 "$lockfile" bash -c '_huddle_sync_body' 2>/dev/null || true
  else
    _huddle_sync_body
  fi
  unset -f _huddle_sync_body 2>/dev/null || true
  unset _HS_MARKER _HS_INTERVAL _HS_TIMEOUT_BIN _HS_TIMEOUT 2>/dev/null || true
  return 0
}

# huddle_discover_root — find an existing "Huddle coordination root" epic in the
# (synced) beads DB and print its id; empty + non-zero if none. Pulls first so a
# freshly-cloned machine sees the remote's root instead of forking a duplicate.
# Fail-open: prints nothing and returns non-zero on any error.
#
# Used by huddle-bootstrap.sh (adopt-not-create) and huddle-session-start.sh
# (fresh-machine auto-adopt when config.json is missing).
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_discover_root() {
  command -v bd >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Embedded mode: pull first so a freshly-cloned machine sees the remote's root
  # rather than forking a duplicate. Server mode: the query already runs against
  # the shared live DB — no pull needed.
  if [[ "$(huddle_dolt_mode)" != "server" ]]; then
    bd dolt pull --quiet >/dev/null 2>&1 || true
  fi
  local id
  # Lowest id wins if (pathologically) more than one root exists — deterministic
  # so every machine picks the same canonical root.
  id=$(bd list --type=epic --json 2>/dev/null \
    | jq -r '[ .[] | select(.title=="Huddle coordination root" and .status!="closed") ]
             | sort_by(.id) | (.[0].id // "")' 2>/dev/null) || return 1
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# huddle_reconcile_today [root_id] [root_json] [children_json] — safety-net dedup for the rare cross-machine rotation
# race. If two machines both created a "Huddle daily <date>" for the current
# today_bead date before either pushed, this collapses them to a deterministic
# canonical (lowest id), re-points root notes at it, and closes the loser(s) with
# a merge marker. Idempotent no-op when there is 0 or 1 daily (the common case →
# two cheap local reads, no writes). Every machine picks the same canonical, so
# all converge. Fail-open; silent (no stdout). Returns 0 always.
#
# Optional pre-fetched args (hot-path budget): when the caller already holds the
# root id, root JSON, or children JSON — huddle-session-start.sh does — pass them
# so this function skips redundant `bd show` and `bd children` calls.
#
# No explicit `bd dolt push` here — in server mode writes hit the shared DB
# directly, and in embedded mode the next huddle_sync / pre-push flush carries
# the dedup to the remote. Server mode is the reliable home for this net: it now
# operates on the one live DB instead of racing two divergent copies.
#
# shellcheck disable=SC2317  # function is sourced and called by callers
huddle_reconcile_today() {
  command -v bd >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local root_id="${1:-}" root_json="${2:-}" children_json="${3:-}"
  local state_dir config_file notes_str today dailies count canon cur_today_id new_notes d
  if [[ -z "$root_id" ]]; then
    state_dir=$(huddle_state_dir) || return 0
    config_file="$state_dir/config.json"
    [[ -f "$config_file" ]] || return 0
    root_id=$(jq -r '.root_bead_id // ""' "$config_file" 2>/dev/null) || return 0
    [[ -n "$root_id" ]] || return 0
  fi
  if [[ -z "$root_json" ]]; then
    root_json=$(bd show "$root_id" --json 2>/dev/null) || return 0
  fi
  notes_str=$(printf '%s' "$root_json" | jq -r '.[0].notes // ""' 2>/dev/null) || return 0
  [[ -n "$notes_str" ]] || return 0
  today=$(printf '%s' "$notes_str" | jq -r '.today_bead.date // ""' 2>/dev/null) || return 0
  [[ -n "$today" ]] || return 0

  if [[ -z "$children_json" ]]; then
    children_json=$(bd children "$root_id" --json 2>/dev/null) || return 0
  fi

  # All open dailies for today's date, sorted by id (ascending → canonical first).
  dailies=$(printf '%s' "$children_json" \
    | jq -r --arg t "Huddle daily $today" \
      '[ .[] | select(.title==$t and .status!="closed") ] | sort_by(.id) | .[].id' 2>/dev/null) || return 0
  count=$(printf '%s\n' "$dailies" | grep -c . 2>/dev/null || true)
  [[ "${count:-0}" -gt 1 ]] || return 0   # 0 or 1 daily → nothing to reconcile

  canon=$(printf '%s\n' "$dailies" | head -n1)
  [[ -n "$canon" ]] || return 0

  # Repoint FIRST, close SECOND. If we closed losers first and the repoint then
  # failed, root notes could be left pointing at a now-closed daily. Repointing
  # up front means the worst case is a still-open duplicate (harmless, caught on
  # the next reconcile) rather than a dangling pointer. Only close duplicates
  # once root is confirmed pointing at the canonical id.
  cur_today_id=$(printf '%s' "$notes_str" | jq -r '.today_bead.id // ""' 2>/dev/null) || cur_today_id=""
  if [[ "$cur_today_id" != "$canon" ]]; then
    new_notes=$(printf '%s' "$notes_str" | jq -c --arg id "$canon" '.today_bead.id = $id' 2>/dev/null) || new_notes=""
    if [[ -z "$new_notes" ]]; then
      return 0   # couldn't build the repoint → leave dups open for next reconcile
    fi
    # `bd update` is transactional — a zero exit means the notes were written, so
    # it confirms root now points at the canonical id. On any failure, skip the
    # closes and leave the duplicate open for the next reconcile to collapse.
    bd update "$root_id" --notes "$new_notes" >/dev/null 2>&1 || return 0
  fi

  # Root now points at the canonical → safe to close every non-canonical dup.
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ "$d" == "$canon" ]] && continue
    bd comments add "$d" "→ merged into $canon (duplicate daily reconciled across machines)" >/dev/null 2>&1 || true
    bd close "$d" >/dev/null 2>&1 || true
  done <<< "$dailies"

  return 0
}
