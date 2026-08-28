#!/usr/bin/env bash
# Background half of the SessionStart hook: commit anything a crashed session
# left in the working tree, then pull/push so this machine is in sync.
set -uo pipefail

TM_TAG="catchup"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tm_load_config
tm_check_config || exit 0
export TM_IN_HOOK=1

tm_lock || exit 0

PERSON="$(tm_slug "$TEAM_MEMORY_PERSON")"

# Notes left uncommitted by a hard kill.
if [ -n "$(tm_git status --porcelain -- sessions 2>/dev/null)" ]; then
  tm_git add sessions >>"$TEAM_MEMORY_LOG" 2>&1
  if ! tm_git diff --cached --quiet; then
    GIT_IDENT=()
    [ -z "$(tm_git config user.name 2>/dev/null)" ] && GIT_IDENT+=(-c "user.name=$PERSON")
    [ -z "$(tm_git config user.email 2>/dev/null)" ] && GIT_IDENT+=(-c "user.email=$PERSON@team-memory.local")
    tm_git ${GIT_IDENT[@]+"${GIT_IDENT[@]}"} commit -q -m "session($PERSON): catch-up commit" \
      -m "Notes left uncommitted by a previous session." >>"$TEAM_MEMORY_LOG" 2>&1 \
      && tm_log "committed leftovers from a previous session"
  fi
fi

# Sync even when there is nothing local to push -- this is how teammates' notes arrive.
tm_sync_and_push
