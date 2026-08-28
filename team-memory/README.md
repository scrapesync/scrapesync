# team-memory — shared session memory over git

A template for a shared Obsidian vault that fills itself in.

Obsidian has no server: every person always has their own local vault, and
connecting several people to one vault over MCP does not carry anyone's context to
anyone else. Git does. So the vault becomes a private repo everyone clones, and a
pair of Claude Code hooks writes a note into it at the end of every session.
Over a few weeks that turns into a searchable record of what the team actually
did, readable both in Obsidian and by any Claude session.

```
  session ends
      │
      ▼
  SessionEnd hook ──► (returns immediately)
      │
      └─► background: condense transcript
                      summarise with `claude -p`
                      scrub secrets            ◄── fails closed
                      write sessions/<note>.md
                      append sessions/index/<person>.md
                      commit → pull --rebase → push

  next session starts
      │
      ▼
  SessionStart hook ──► prints recent index lines into the new session's context
      │
      └─► background: commit anything a crash left behind, pull, push
```

## Setting up the vault repo (once, by whoever owns it)

1. Create a **private** repo, e.g. `scrapesync/team-memory`, and add the team as
   collaborators.
2. Copy the contents of this folder into it and push:

   ```bash
   cp -r team-memory/. /path/to/team-memory-clone/
   cd /path/to/team-memory-clone
   # index files for saad, asad, faheem, muneeb, muteeb and wahab are already there
   chmod +x setup.sh hooks/*.sh hooks/*.py
   git add . && git commit -m "Set up team memory vault" && git push
   ```

   `.gitignore` is already at the root of this folder and belongs at the root of
   the vault repo.
3. Tell everyone to follow the next section.

Keep it private. Session notes are summaries of real work: client names, internal
URLs, architecture. The scrubber removes credentials, not confidentiality.

## Setting up your machine (each person, ~2 minutes)

```bash
git clone git@github.com:scrapesync/team-memory.git ~/vaults/team-memory
cd ~/vaults/team-memory
bash setup.sh --person faheem --repo ~/vaults/team-memory
```

That writes `~/.claude/team-memory.env`, adds the two hooks to
`~/.claude/settings.json` (backing up the old file first), and creates
`sessions/index/faheem.md`.

Then in Obsidian: **Open folder as vault** → `~/vaults/team-memory`.

Check it whenever something looks off:

```bash
bash setup.sh --check       # verifies python3, claude, git, vault, origin, hooks
bash setup.sh --uninstall   # removes the hooks, keeps the notes
```

Requirements: `git`, `python3`, and the `claude` CLI. macOS and Linux.
Without `claude` you still get notes, built from transcript facts instead of a
summary. Without `python3` **nothing is written** — the scrubber cannot run and
the hook refuses to commit unscrubbed text.

## What lands in the vault

```
sessions/2026-08-27-1430-faheem-labeling.md     one note per session
sessions/index/faheem.md                        one line per session, per person
sessions/index/{saad,asad,muneeb,muteeb,wahab}.md   one per person, pre-created
```

Filenames are `YYYY-MM-DD-HHMM-person-topic.md`, so two people writing at the same
moment can never collide; a same-minute collision by one person gets a `-2` suffix.
Each note opens with YAML frontmatter (`date`, `person`, `topic`, `repo`, `branch`,
`summary`, `tags`), which makes it queryable from Obsidian's Dataview and readable
by anything that parses frontmatter. See `templates/session-note.md` for the shape
and `templates/example-session-note.md` for a filled-in example.

Indexes are per person, deliberately. A single shared `INDEX.md` is the one file
everybody would append to at once — the only guaranteed merge conflict in the
design. Five small index files are also cheap for Claude to read: a new session
starts with everyone's last few lines already in context, and opens a full note
only when it needs the detail.

## Using it

Mostly you don't do anything — the notes accumulate. When you want context:

- **In Obsidian**: search, or open your index and follow the wiki-links.
- **In Claude Code**: the recent index lines are already in context at session
  start. Beyond that, just ask — "read `~/vaults/team-memory/sessions/index/asad.md`
  and catch me up on the scraper work".
- **Pull before a standup**: `git -C ~/vaults/team-memory pull` (the hooks do this
  for you at session start anyway).

## Configuration

Everything lives in `~/.claude/team-memory.env`. Edit it any time; the hooks
re-read it on every session.

| Setting | Default | What it does |
| --- | --- | --- |
| `TEAM_MEMORY_ENABLED` | `1` | `0` turns the whole thing off without uninstalling. |
| `TEAM_MEMORY_PERSON` | — | Your name in filenames, frontmatter and your index. |
| `TEAM_MEMORY_REPO` | — | Absolute path to your vault clone. |
| `TEAM_MEMORY_MODEL` | *(empty)* | Model for the summary; empty uses the `claude` CLI default. Aliases like `sonnet` or `haiku` work. |
| `TEAM_MEMORY_PUSH` | `1` | `0` commits locally and never pushes — good for a trial run. |
| `TEAM_MEMORY_MIN_TURNS` | `2` | Sessions shorter than this get no note. |
| `TEAM_MEMORY_EXCLUDE_DIRS` | *(empty)* | Colon-separated path prefixes that never produce a note. Use it for client work and personal repos. |
| `TEAM_MEMORY_INJECT_CONTEXT` | `1` | Print recent index lines into new sessions. |
| `TEAM_MEMORY_CONTEXT_LINES` | `6` | How many lines per person to inject. |
| `TEAM_MEMORY_SUMMARY_TIMEOUT` | `180` | Seconds before the summariser is killed and the facts-only note is used. |
| `TEAM_MEMORY_GIT_RETRIES` | `3` | Push attempts, backing off 2s / 4s / 8s. |
| `TEAM_MEMORY_LOG` | `~/.claude/team-memory.log` | Every run appends here. Trimmed at 5000 lines. |

## The things that go wrong, and what handles them

**Secrets in transcripts.** Every note and index line passes through
`hooks/scrub_secrets.py` before it touches the repo — Anthropic/OpenAI/GitHub/AWS/
Google/Slack/Stripe keys, JWTs, bearer tokens, private key blocks, `KEY=value`
assignments where the key name looks like a credential, and passwords inside
connection strings. It is deliberately over-eager, and it fails closed: if it
cannot run, no note is written. Test it on anything you like:

```bash
python3 hooks/scrub_secrets.py --check < some-file.txt
```

**SessionEnd doesn't always fire.** Crashes and hard kills skip the hook entirely,
and a note that was written but not pushed sits in the working tree. The
SessionStart hook commits and pushes whatever it finds left over, so the next
session you start repairs the previous one.

**Two people pushing at once.** Every write is `pull --rebase --autostash` then
push, retried three times with backoff. Because no two sessions write the same
file, a rebase has nothing to conflict over. A failed push leaves the commit
locally and the next SessionStart sends it.

**The hook holding up your terminal.** `SessionEnd` reads its input, spawns a
detached child and exits — summarising happens after your session is already gone.

**Two sessions writing at once on one machine.** A `mkdir`-based lock around the
git operations; stale locks older than 10 minutes are broken automatically.

**The summariser summarising itself.** The nested `claude -p` call runs with
`TM_IN_HOOK=1`, and both hooks exit immediately when they see it. Sessions whose
cwd is inside the vault itself are skipped too.

## Layout of this template

```
setup.sh                     install / --check / --uninstall
hooks/session_start.sh       context injection + background catch-up
hooks/session_end.sh         spawns the writer, exits immediately
hooks/write_session_note.sh  the real work
hooks/catch_up.sh            commit-and-sync for interrupted sessions
hooks/extract_transcript.py  transcript .jsonl → digest + facts
hooks/scrub_secrets.py       credential redaction (fail-closed)
hooks/lib.sh                 config, logging, locking, git retry
templates/                   note and index-line formats, plus a worked example
sessions/                    the vault itself (empty; notes land here)
sessions/index/              one index file per person, pre-created for the team
.claude/settings.json.example  the hook config, if you'd rather wire it by hand
```

## Trying it before you trust it

```bash
bash setup.sh --person you --repo ~/vaults/team-memory --no-push
```

Run a couple of real sessions, read what shows up in `sessions/`, then flip
`TEAM_MEMORY_PUSH=1` in `~/.claude/team-memory.env` when you are happy with what
it is writing about you.
