#!/usr/bin/env bash
# Does the actual work of turning a finished session into a vault note.
# Always run in the background by session_end.sh -- it is allowed to be slow.
#
# Usage: write_session_note.sh <transcript_path> <session_id> <cwd> [reason]
set -uo pipefail

TM_TAG="note"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tm_load_config
tm_trim_log

TRANSCRIPT="${1:-}"
SESSION_ID="${2:-}"
SESSION_CWD="${3:-$PWD}"
END_REASON="${4:-}"

# Never let a note-writing session trigger another note. Belt and braces:
# session_end.sh checks this too.
[ "${TM_IN_HOOK:-0}" = "1" ] && { tm_log "nested invocation; skipping"; exit 0; }
export TM_IN_HOOK=1

tm_check_config || exit 0

if tm_excluded_cwd "$SESSION_CWD"; then
  tm_log "cwd excluded: $SESSION_CWD"; exit 0
fi

if [ ! -f "$TRANSCRIPT" ]; then
  tm_log "no transcript at '$TRANSCRIPT'"; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/team-memory.XXXXXX")" || exit 0
cleanup() { rm -rf "$WORK"; tm_unlock; }
trap cleanup EXIT INT TERM

# --- 1. condense the transcript ------------------------------------------------

if ! python3 "$TM_HOOK_DIR/extract_transcript.py" "$TRANSCRIPT" "$WORK" "$TEAM_MEMORY_MAX_DIGEST_CHARS" 2>>"$TEAM_MEMORY_LOG"; then
  tm_log "transcript extraction failed"; exit 0
fi
# shellcheck disable=SC1091
. "$WORK/facts.env"

if [ "${TM_FACT_USER_TURNS:-0}" -lt "${TEAM_MEMORY_MIN_TURNS:-2}" ]; then
  tm_log "only ${TM_FACT_USER_TURNS:-0} user turn(s); not worth a note"; exit 0
fi

# --- 2. work out where the session happened ------------------------------------

PROJECT=""
if git -C "$SESSION_CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ORIGIN="$(git -C "$SESSION_CWD" remote get-url origin 2>/dev/null)"
  PROJECT="$(printf '%s' "$ORIGIN" | sed -E 's#(git@|https?://)([^:/]+)[:/]##; s#\.git$##')"
fi
[ -z "$PROJECT" ] && PROJECT="$(basename "$SESSION_CWD")"
BRANCH="${TM_FACT_BRANCH:-$(git -C "$SESSION_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)}"

# --- 3. summarise --------------------------------------------------------------

read -r -d '' PROMPT_INSTRUCTIONS <<'PROMPT'
You are writing a session note for a shared team memory vault. Other engineers on
the team -- and Claude sessions they run later -- will read this note to pick up
context they were not present for. Write for that reader.

Input on stdin is a condensed transcript of one Claude Code session: user prompts,
assistant replies, commands run, files edited.

Output EXACTLY this structure and nothing else. No preamble, no code fences.

TOPIC: <2-4 words, lowercase, hyphenated, naming the actual subject; e.g. label-pipeline-retry>
ONELINE: <one sentence, under 140 chars, describing what was accomplished>
===NOTE===
## Summary
<2-5 sentences: what the session set out to do and where it ended up.>

## What changed
- <concrete change, naming files or components. Omit the section if nothing changed.>

## Decisions
- <a decision that was made and the reason for it. Only real decisions. "None" if there were none.>

## Open threads
- <anything unfinished, known broken, or deliberately deferred. "None" if nothing.>

Rules:
- Be specific. Name files, functions, error messages, numbers.
- No filler, no praise, no restating these instructions.
- Never include API keys, tokens, passwords, connection strings or client data.
- If the session was exploratory and nothing was built, say so plainly.
PROMPT

run_with_timeout() {
  local secs="$1"; shift
  # <&0 is required: bash points a background job's stdin at /dev/null unless the
  # redirection is explicit, which would hand the summariser an empty transcript.
  "$@" <&0 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$secs" ] && { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 2; waited=$((waited + 2))
  done
  wait "$pid"
}

summarise() {
  local out="$WORK/summary.txt"
  local model_args=()
  [ -n "$TEAM_MEMORY_MODEL" ] && model_args=(--model "$TEAM_MEMORY_MODEL")

  tm_have claude || { tm_log "claude CLI not on PATH; using facts-only note"; return 1; }

  attempt() {
    : >"$out"
    run_with_timeout "${TEAM_MEMORY_SUMMARY_TIMEOUT:-180}" \
      env TM_IN_HOOK=1 claude -p "$PROMPT_INSTRUCTIONS" "$@" \
      <"$WORK/digest.txt" >"$out" 2>>"$TEAM_MEMORY_LOG"
    [ -s "$out" ] && grep -q '===NOTE===' "$out"
  }

  attempt ${model_args[@]+"${model_args[@]}"} --output-format text --max-turns 1 && return 0
  tm_log "summariser retry without --max-turns"
  attempt ${model_args[@]+"${model_args[@]}"} --output-format text && return 0
  tm_log "summariser produced no usable output"
  return 1
}

TOPIC=""; ONELINE=""; BODY=""
if summarise; then
  TOPIC="$(sed -n 's/^TOPIC:[[:space:]]*//p' "$WORK/summary.txt" | head -n1)"
  ONELINE="$(sed -n 's/^ONELINE:[[:space:]]*//p' "$WORK/summary.txt" | head -n1)"
  BODY="$(sed -n '/^===NOTE===$/,$p' "$WORK/summary.txt" | tail -n +2)"
fi

# Deterministic fallback: a note built from facts alone is still worth having.
if [ -z "$BODY" ]; then
  ONELINE="${ONELINE:-${TM_FACT_FIRST_PROMPT:-session with no summary}}"
  BODY="$(printf '## Summary\n\nNo generated summary for this session (the summariser was unavailable). Facts below are taken from the transcript.\n\nFirst prompt: %s\n' "${TM_FACT_FIRST_PROMPT:-n/a}")"
fi
# Fallback topic: the first few words of the opening prompt, not the whole thing.
[ -z "$TOPIC" ] && TOPIC="$(tm_slug "$(printf '%s' "${TM_FACT_FIRST_PROMPT:-session}" | cut -d' ' -f1-5)")"
TOPIC="$(tm_slug "$TOPIC")"
[ -z "$TOPIC" ] && TOPIC="session"
[ -z "$ONELINE" ] && ONELINE="(no summary)"
ONELINE="$(printf '%s' "$ONELINE" | tr '\n' ' ' | cut -c1-160)"

# --- 4. assemble the note ------------------------------------------------------

DATE="$(date '+%Y-%m-%d')"
TIME="$(date '+%H%M')"
TIME_H="$(date '+%H:%M')"
PERSON="$(tm_slug "$TEAM_MEMORY_PERSON")"

{
  printf -- '---\n'
  printf 'date: %s\n' "$DATE"
  printf 'time: "%s"\n' "$TIME_H"
  printf 'person: %s\n' "$PERSON"
  printf 'topic: %s\n' "$TOPIC"
  printf 'repo: %s\n' "$PROJECT"
  printf 'branch: %s\n' "${BRANCH:-unknown}"
  printf 'session_id: %s\n' "${SESSION_ID:-${TM_FACT_SESSION_ID:-unknown}}"
  printf 'duration_min: %s\n' "${TM_FACT_DURATION_MIN:-0}"
  printf 'end_reason: %s\n' "${END_REASON:-unknown}"
  printf 'summary: "%s"\n' "$(printf '%s' "$ONELINE" | sed 's/"/\\"/g')"
  printf 'tags: [session, %s, %s]\n' "$PERSON" "$(tm_slug "$(basename "$PROJECT")")"
  printf -- '---\n\n'
  printf '# %s — %s\n\n' "$DATE" "$TOPIC"
  printf '%s\n' "$BODY"
  printf '\n## Session facts\n\n'
  printf -- '- Turns: %s · Commands: %s · Files touched: %s · Commits: %s\n' \
    "${TM_FACT_USER_TURNS:-0}" "${TM_FACT_COMMAND_COUNT:-0}" "${TM_FACT_FILE_COUNT:-0}" "${TM_FACT_COMMIT_COUNT:-0}"
  if [ -s "$WORK/files.txt" ]; then
    printf -- '- Files:\n'
    head -n 15 "$WORK/files.txt" | sed 's|^|  - `|; s|$|`|'
  fi
  printf '\n'
} >"$WORK/note.raw.md"

# --- 5. scrub (fail closed) ----------------------------------------------------

if ! python3 "$TM_HOOK_DIR/scrub_secrets.py" <"$WORK/note.raw.md" >"$WORK/note.md" 2>>"$TEAM_MEMORY_LOG"; then
  tm_log "scrubbing failed; refusing to write the note"; exit 1
fi
[ -s "$WORK/note.md" ] || { tm_log "scrubbed note is empty; aborting"; exit 1; }

# --- 6. commit and push --------------------------------------------------------

tm_lock || exit 1

NOTES_DIR="$TEAM_MEMORY_REPO/sessions"
INDEX_DIR="$NOTES_DIR/index"
mkdir -p "$NOTES_DIR" "$INDEX_DIR"

BASENAME="${DATE}-${TIME}-${PERSON}-${TOPIC}"
NOTE_PATH="$NOTES_DIR/${BASENAME}.md"
n=2
while [ -e "$NOTE_PATH" ]; do
  NOTE_PATH="$NOTES_DIR/${BASENAME}-${n}.md"
  n=$((n + 1))
done
cp "$WORK/note.md" "$NOTE_PATH"

INDEX="$INDEX_DIR/${PERSON}.md"
if [ ! -f "$INDEX" ]; then
  {
    printf -- '---\nperson: %s\ntype: index\n---\n\n' "$PERSON"
    printf '# %s — session index\n\n' "$PERSON"
    printf 'One line per session, newest at the bottom. Read this before opening individual notes.\n\n'
  } >"$INDEX"
fi
printf -- '- %s %s — [[%s]] — %s — %s\n' \
  "$DATE" "$TIME_H" "$(basename "${NOTE_PATH%.md}")" "$PROJECT" "$ONELINE" \
  | python3 "$TM_HOOK_DIR/scrub_secrets.py" 2>>"$TEAM_MEMORY_LOG" >>"$INDEX"

tm_git add "sessions" >>"$TEAM_MEMORY_LOG" 2>&1
if tm_git diff --cached --quiet; then
  tm_log "nothing staged; done"; exit 0
fi

# Machines with no global git identity would otherwise fail every commit.
GIT_IDENT=()
[ -z "$(tm_git config user.name 2>/dev/null)" ] && GIT_IDENT+=(-c "user.name=$PERSON")
[ -z "$(tm_git config user.email 2>/dev/null)" ] && GIT_IDENT+=(-c "user.email=$PERSON@team-memory.local")

tm_git ${GIT_IDENT[@]+"${GIT_IDENT[@]}"} \
       commit -q -m "session($PERSON): $TOPIC" -m "$ONELINE" >>"$TEAM_MEMORY_LOG" 2>&1 \
  || { tm_log "commit failed"; exit 1; }

tm_sync_and_push
tm_log "wrote $(basename "$NOTE_PATH")"
