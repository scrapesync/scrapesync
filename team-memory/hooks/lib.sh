#!/usr/bin/env bash
# Shared helpers for the team-memory hooks.
# Sourced by session_start.sh, session_end.sh and write_session_note.sh.

TM_CONFIG_FILE="${TM_CONFIG_FILE:-$HOME/.claude/team-memory.env}"

tm_load_config() {
  # Defaults. Anything in the config file overrides these.
  TEAM_MEMORY_ENABLED=1
  TEAM_MEMORY_REPO=""
  TEAM_MEMORY_PERSON=""
  TEAM_MEMORY_MODEL=""          # empty = whatever `claude` defaults to. "sonnet"/"haiku" also work.
  TEAM_MEMORY_PUSH=1
  TEAM_MEMORY_MIN_TURNS=2       # sessions with fewer user messages than this are skipped
  TEAM_MEMORY_MAX_DIGEST_CHARS=120000
  TEAM_MEMORY_EXCLUDE_DIRS=""   # colon-separated path prefixes to never write notes for
  TEAM_MEMORY_SUMMARY_TIMEOUT=180
  TEAM_MEMORY_GIT_RETRIES=3
  TEAM_MEMORY_LOG="$HOME/.claude/team-memory.log"

  # shellcheck disable=SC1090
  [ -f "$TM_CONFIG_FILE" ] && . "$TM_CONFIG_FILE"

  TM_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

tm_log() {
  local dir
  dir="$(dirname "$TEAM_MEMORY_LOG")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${TM_TAG:-team-memory}" "$*" >>"$TEAM_MEMORY_LOG" 2>/dev/null
}

# Keep the log from growing without bound.
tm_trim_log() {
  [ -f "$TEAM_MEMORY_LOG" ] || return 0
  local lines
  lines="$(wc -l <"$TEAM_MEMORY_LOG" 2>/dev/null | tr -d ' ')"
  [ -n "$lines" ] && [ "$lines" -gt 5000 ] || return 0
  tail -n 2000 "$TEAM_MEMORY_LOG" >"$TEAM_MEMORY_LOG.tmp" 2>/dev/null && mv "$TEAM_MEMORY_LOG.tmp" "$TEAM_MEMORY_LOG"
}

tm_have() { command -v "$1" >/dev/null 2>&1; }

# Detach a child so the hook can exit immediately. macOS has no setsid.
tm_spawn() {
  if tm_have setsid; then
    nohup setsid "$@" >/dev/null 2>&1 </dev/null &
  else
    nohup "$@" >/dev/null 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
}

# --- config sanity -----------------------------------------------------------

tm_check_config() {
  if [ "${TEAM_MEMORY_ENABLED:-1}" != "1" ]; then
    tm_log "disabled via TEAM_MEMORY_ENABLED"; return 1
  fi
  if [ -z "$TEAM_MEMORY_REPO" ] || [ ! -d "$TEAM_MEMORY_REPO/.git" ]; then
    tm_log "TEAM_MEMORY_REPO is not a git clone: '${TEAM_MEMORY_REPO}' (run setup.sh)"; return 1
  fi
  if [ -z "$TEAM_MEMORY_PERSON" ]; then
    tm_log "TEAM_MEMORY_PERSON is unset (run setup.sh)"; return 1
  fi
  # Secret scrubbing is mandatory. No python3 -> we do not write anything.
  if ! tm_have python3; then
    tm_log "python3 not found; refusing to write a note without secret scrubbing"; return 1
  fi
  return 0
}

# --- json ---------------------------------------------------------------------

# tm_json_field '<json>' key   -> value on stdout ("" if absent)
tm_json_field() {
  local json="$1" key="$2"
  if tm_have python3; then
    printf '%s' "$json" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[1], "")
if v is None: v = ""
sys.stdout.write(str(v))
' "$key"
  else
    printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}

# --- locking (portable: mkdir is atomic everywhere) ---------------------------

tm_lock() {
  local lock="$TEAM_MEMORY_REPO/.tm-lock" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    # Break a stale lock (older than 10 minutes) left by a killed process.
    if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then
      tm_log "breaking stale lock"; rm -rf "$lock"; continue
    fi
    waited=$((waited + 2))
    [ "$waited" -gt 300 ] && { tm_log "gave up waiting for lock"; return 1; }
    sleep 2
  done
  TM_LOCK_DIR="$lock"
  trap 'tm_unlock' EXIT INT TERM
  return 0
}

tm_unlock() { [ -n "${TM_LOCK_DIR:-}" ] && rm -rf "$TM_LOCK_DIR"; TM_LOCK_DIR=""; }

# --- git ----------------------------------------------------------------------

tm_git() { git -C "$TEAM_MEMORY_REPO" "$@"; }

tm_repo_branch() { tm_git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# Pull --rebase then push, with backoff. Never leaves a rebase half-applied.
tm_sync_and_push() {
  local branch attempt=1 delay=2
  branch="$(tm_repo_branch)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    branch="${TEAM_MEMORY_BRANCH:-main}"
  fi

  if [ "${TEAM_MEMORY_PUSH:-1}" != "1" ]; then
    tm_log "push disabled; leaving commits local"; return 0
  fi

  while [ "$attempt" -le "${TEAM_MEMORY_GIT_RETRIES:-3}" ]; do
    if ! tm_git pull --rebase --autostash origin "$branch" >>"$TEAM_MEMORY_LOG" 2>&1; then
      tm_log "pull --rebase failed (attempt $attempt); aborting rebase and retrying"
      tm_git rebase --abort >/dev/null 2>&1
    fi
    if tm_git push origin "$branch" >>"$TEAM_MEMORY_LOG" 2>&1; then
      tm_log "pushed to origin/$branch"; return 0
    fi
    tm_log "push failed (attempt $attempt); sleeping ${delay}s"
    sleep "$delay"; delay=$((delay * 2)); attempt=$((attempt + 1))
  done
  tm_log "push failed after ${TEAM_MEMORY_GIT_RETRIES} attempts; commits are safe locally and will go out at the next SessionStart"
  return 1
}

# --- misc ---------------------------------------------------------------------

tm_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-48
}

# Should we skip this session's cwd entirely?
tm_excluded_cwd() {
  local cwd="$1" IFS=':' p
  # Never write a note about editing the memory repo itself.
  case "$cwd" in "$TEAM_MEMORY_REPO"*) return 0 ;; esac
  [ -z "$TEAM_MEMORY_EXCLUDE_DIRS" ] && return 1
  for p in $TEAM_MEMORY_EXCLUDE_DIRS; do
    [ -n "$p" ] && case "$cwd" in "$p"*) return 0 ;; esac
  done
  return 1
}
