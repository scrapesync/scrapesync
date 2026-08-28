#!/usr/bin/env bash
# One-time setup for a teammate's machine.
#
#   ./setup.sh --person faheem --repo ~/vaults/team-memory
#   ./setup.sh --check          # verify an existing install
#   ./setup.sh --uninstall      # remove the hooks (keeps the vault and its notes)
#
# Writes:
#   ~/.claude/team-memory.env   your settings
#   ~/.claude/settings.json     adds the SessionStart / SessionEnd hooks
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/hooks"
CONFIG="$HOME/.claude/team-memory.env"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

PERSON=""; REPO=""; MODEL=""; PUSH=1; MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --person) PERSON="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --settings) SETTINGS="${2:-}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --check) MODE="check"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# Files can arrive without the executable bit (zip download, API push, some clones).
chmod +x "$HOOKS"/*.sh "$HOOKS"/*.py 2>/dev/null

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; }

# --- uninstall -----------------------------------------------------------------

if [ "$MODE" = "uninstall" ]; then
  python3 - "$SETTINGS" "$HOOKS" <<'PY'
import json, sys, os
path, hooks_dir = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print("  nothing to remove"); raise SystemExit
data = json.load(open(path))
removed = 0
for event in ("SessionStart", "SessionEnd"):
    groups = data.get("hooks", {}).get(event, [])
    kept = []
    for g in groups:
        inner = [h for h in g.get("hooks", []) if hooks_dir not in str(h.get("command", ""))]
        removed += len(g.get("hooks", [])) - len(inner)
        if inner:
            g["hooks"] = inner
            kept.append(g)
    if kept:
        data["hooks"][event] = kept
    elif event in data.get("hooks", {}):
        del data["hooks"][event]
json.dump(data, open(path, "w"), indent=2)
print("  removed %d hook(s) from %s" % (removed, path))
PY
  say "config left at $CONFIG (delete it if you want a clean slate)"
  exit 0
fi

# --- check ---------------------------------------------------------------------

run_check() {
  local fails=0
  echo "team-memory check"
  # shellcheck disable=SC1090
  if [ -f "$CONFIG" ]; then ok "config $CONFIG"; . "$CONFIG"; else bad "no config at $CONFIG (run setup.sh)"; fails=1; fi
  command -v python3 >/dev/null 2>&1 && ok "python3 $(python3 -V 2>&1 | cut -d' ' -f2)" \
    || { bad "python3 missing -- notes will not be written (secret scrubbing needs it)"; fails=1; }
  command -v claude >/dev/null 2>&1 && ok "claude CLI" \
    || warn "claude CLI not on PATH -- notes fall back to facts only"
  command -v git >/dev/null 2>&1 && ok "git" || { bad "git missing"; fails=1; }
  if [ -n "${TEAM_MEMORY_REPO:-}" ] && [ -d "${TEAM_MEMORY_REPO}/.git" ]; then
    ok "vault $TEAM_MEMORY_REPO"
    if git -C "$TEAM_MEMORY_REPO" ls-remote --exit-code origin >/dev/null 2>&1; then
      ok "origin reachable"
    else
      bad "cannot reach origin -- check your GitHub access"; fails=1
    fi
  else
    bad "vault repo missing or not a git clone: '${TEAM_MEMORY_REPO:-unset}'"; fails=1
  fi
  if [ -n "$(git config --global user.email 2>/dev/null)" ]; then
    ok "git identity: $(git config --global user.email)"
  else
    warn "no global git identity -- notes will be committed as <you>@team-memory.local"
  fi
  [ -n "${TEAM_MEMORY_PERSON:-}" ] && ok "person: $TEAM_MEMORY_PERSON" || { bad "person unset"; fails=1; }
  if [ -f "$SETTINGS" ] && grep -q "$HOOKS" "$SETTINGS" 2>/dev/null; then
    ok "hooks installed in $SETTINGS"
  else
    bad "hooks not found in $SETTINGS"; fails=1
  fi
  echo
  [ "$fails" -eq 0 ] && echo "all good." || echo "fix the FAIL lines above, then re-run --check."
  return "$fails"
}

[ "$MODE" = "check" ] && { run_check; exit $?; }

# --- install -------------------------------------------------------------------

echo "team-memory setup"
echo

if [ -z "$PERSON" ]; then
  printf '  your first name (used in filenames and your index file): '
  read -r PERSON
fi
PERSON="$(printf '%s' "$PERSON" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
[ -z "$PERSON" ] && { bad "a name is required"; exit 1; }

if [ -z "$REPO" ]; then
  printf '  path to your clone of the vault repo: '
  read -r REPO
fi
REPO="${REPO/#\~/$HOME}"
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { bad "no such directory: $REPO"; exit 1; }
[ -d "$REPO/.git" ] || { bad "$REPO is not a git clone"; exit 1; }

mkdir -p "$HOME/.claude" "$REPO/sessions/index"

cat >"$CONFIG" <<EOF
# team-memory settings -- written by setup.sh on $(date '+%Y-%m-%d')
# Edit by hand any time; the hooks read this file on every session.

TEAM_MEMORY_ENABLED=1
TEAM_MEMORY_PERSON="$PERSON"
TEAM_MEMORY_REPO="$REPO"

# Model used to summarise the session. Empty = the claude CLI default.
TEAM_MEMORY_MODEL="$MODEL"

# 0 = commit notes locally but never push (useful while you are trying this out).
TEAM_MEMORY_PUSH=$PUSH

# Sessions with fewer user messages than this get no note.
TEAM_MEMORY_MIN_TURNS=2

# Colon-separated path prefixes that never produce a note (client work, personal repos).
TEAM_MEMORY_EXCLUDE_DIRS=""

# Print recent team index lines into every new session's context.
TEAM_MEMORY_INJECT_CONTEXT=1
TEAM_MEMORY_CONTEXT_LINES=6

TEAM_MEMORY_SUMMARY_TIMEOUT=180
TEAM_MEMORY_GIT_RETRIES=3
TEAM_MEMORY_LOG="\$HOME/.claude/team-memory.log"
EOF
ok "wrote $CONFIG"

python3 - "$SETTINGS" "$HOOKS" <<'PY'
import json, os, shutil, sys, time
path, hooks_dir = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)

data = {}
if os.path.exists(path):
    shutil.copy(path, "%s.bak.%d" % (path, int(time.time())))
    try:
        data = json.load(open(path))
    except Exception:
        print("  FAIL  %s is not valid JSON -- fix it and re-run" % path)
        raise SystemExit(1)

data.setdefault("hooks", {})
wanted = {"SessionStart": "session_start.sh", "SessionEnd": "session_end.sh"}
for event, script in wanted.items():
    groups = [
        g for g in data["hooks"].get(event, [])
        if [h for h in g.get("hooks", []) if hooks_dir not in str(h.get("command", ""))]
    ]
    for g in groups:
        g["hooks"] = [h for h in g["hooks"] if hooks_dir not in str(h.get("command", ""))]
    groups.append({"hooks": [{
        "type": "command",
        "command": os.path.join(hooks_dir, script),
        "timeout": 15,
    }]})
    data["hooks"][event] = groups

json.dump(data, open(path, "w"), indent=2)
print("  ok    hooks installed in %s" % path)
PY

INDEX="$REPO/sessions/index/$PERSON.md"
if [ ! -f "$INDEX" ]; then
  {
    printf -- '---\nperson: %s\ntype: index\n---\n\n' "$PERSON"
    printf '# %s — session index\n\n' "$PERSON"
    printf 'One line per session, newest at the bottom. Read this before opening individual notes.\n\n'
  } >"$INDEX"
  ok "created sessions/index/$PERSON.md"
fi

echo
run_check
echo
say "Next: open Obsidian → 'Open folder as vault' → $REPO"
say "Then finish any Claude Code session; your note lands in sessions/ a few seconds later."
say "Logs: ~/.claude/team-memory.log"
