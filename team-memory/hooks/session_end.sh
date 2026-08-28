#!/usr/bin/env bash
# SessionEnd hook: hand the transcript to the note writer and get out of the way.
# Must exit fast -- everything slow happens in the detached child.
set -uo pipefail

TM_TAG="end"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tm_load_config

# Do not recurse into the summariser's own session.
[ "${TM_IN_HOOK:-0}" = "1" ] && exit 0
[ "${TEAM_MEMORY_ENABLED:-1}" = "1" ] || exit 0

INPUT="$(cat)"
TRANSCRIPT="$(tm_json_field "$INPUT" transcript_path)"
SESSION_ID="$(tm_json_field "$INPUT" session_id)"
SESSION_CWD="$(tm_json_field "$INPUT" cwd)"
REASON="$(tm_json_field "$INPUT" reason)"
[ -z "$SESSION_CWD" ] && SESSION_CWD="$PWD"

tm_log "session end (${REASON:-unknown}) cwd=$SESSION_CWD"

tm_spawn "$TM_HOOK_DIR/write_session_note.sh" "$TRANSCRIPT" "$SESSION_ID" "$SESSION_CWD" "$REASON"

exit 0
