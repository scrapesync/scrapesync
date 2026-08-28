#!/usr/bin/env bash
# SessionStart hook: two jobs.
#   1. Print the team's recent session index into the new session's context.
#   2. In the background, push anything a crashed session left behind and pull
#      down everyone else's notes.
set -uo pipefail

TM_TAG="start"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tm_load_config

[ "${TM_IN_HOOK:-0}" = "1" ] && exit 0
[ "${TEAM_MEMORY_ENABLED:-1}" = "1" ] || exit 0
[ -d "${TEAM_MEMORY_REPO:-/nonexistent}/.git" ] || exit 0

cat >/dev/null   # drain hook stdin

# --- 1. context injection (synchronous, local reads only, hard-capped) ---------

if [ "${TEAM_MEMORY_INJECT_CONTEXT:-1}" = "1" ] && [ -d "$TEAM_MEMORY_REPO/sessions/index" ]; then
  lines_per_person="${TEAM_MEMORY_CONTEXT_LINES:-6}"
  printed=0
  for index in "$TEAM_MEMORY_REPO"/sessions/index/*.md; do
    [ -f "$index" ] || continue
    recent="$(grep '^- ' "$index" | tail -n "$lines_per_person")"
    [ -z "$recent" ] && continue
    if [ "$printed" -eq 0 ]; then
      printf 'Recent team session notes (shared memory vault at %s).\n' "$TEAM_MEMORY_REPO"
      printf 'Full notes live in sessions/. Read one before assuming context you do not have.\n\n'
      printed=1
    fi
    printf '## %s\n%s\n\n' "$(basename "${index%.md}")" "$recent"
  done
fi

# --- 2. catch-up sync (background) --------------------------------------------

tm_spawn "$TM_HOOK_DIR/catch_up.sh"

exit 0
