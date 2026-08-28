#!/usr/bin/env python3
"""Condense a Claude Code transcript (.jsonl) into material a summary can be built from.

Usage: extract_transcript.py <transcript.jsonl> <outdir> [max_digest_chars]

Writes into <outdir>:
  digest.txt    chronological, trimmed conversation + tool calls (fed to `claude -p`)
  facts.env     shell-sourceable facts (TM_FACT_*)
  files.txt     files created/edited/read, most-touched first
  commands.txt  shell commands that were run
  prompts.txt   the user's prompts, verbatim

Everything written here is scrubbed downstream before it reaches the vault.
"""
import json
import os
import re
import sys
from collections import Counter

MAX_TEXT = 2000        # per assistant/user message in the digest
MAX_CMD = 400          # per command line
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
READ_TOOLS = {"Read", "Glob", "Grep"}


def text_of(content):
    """Flatten a message's content into (text, [tool_use dicts])."""
    if isinstance(content, str):
        return content, []
    parts, tools = [], []
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                parts.append(block.get("text", ""))
            elif btype == "thinking":
                continue
            elif btype == "tool_use":
                tools.append(block)
            elif btype == "tool_result":
                continue
    return "\n".join(p for p in parts if p), tools


def trim(s, n):
    s = (s or "").strip()
    if len(s) <= n:
        return s
    return s[:n] + "\n... [trimmed]"


def sh_quote(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: extract_transcript.py <transcript.jsonl> <outdir> [max_chars]\n")
        return 1
    path, outdir = sys.argv[1], sys.argv[2]
    max_chars = int(sys.argv[3]) if len(sys.argv) > 3 else 120000
    os.makedirs(outdir, exist_ok=True)

    lines = []
    if os.path.exists(path):
        with open(path, "r", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    lines.append(json.loads(raw))
                except Exception:
                    continue

    digest, prompts, commands, commits = [], [], [], []
    files = Counter()
    user_turns = 0
    first_ts = last_ts = ""
    cwd = branch = session_id = ""

    for entry in lines:
        if not isinstance(entry, dict):
            continue
        ts = entry.get("timestamp") or ""
        if ts:
            first_ts = first_ts or ts
            last_ts = ts
        cwd = entry.get("cwd") or cwd
        branch = entry.get("gitBranch") or branch
        session_id = entry.get("sessionId") or entry.get("session_id") or session_id

        etype = entry.get("type")
        message = entry.get("message") or {}
        if not isinstance(message, dict):
            continue
        body, tools = text_of(message.get("content"))

        if etype == "user":
            # Skip synthetic turns: tool results, hook feedback, system reminders.
            if not body.strip():
                continue
            if entry.get("isMeta") or body.lstrip().startswith("<"):
                continue
            user_turns += 1
            prompts.append(body.strip())
            digest.append("USER: " + trim(body, MAX_TEXT))
        elif etype == "assistant":
            if body.strip():
                digest.append("CLAUDE: " + trim(body, MAX_TEXT))
            for tool in tools:
                name = tool.get("name", "")
                args = tool.get("input") or {}
                if not isinstance(args, dict):
                    args = {}
                if name == "Bash":
                    cmd = trim(args.get("command", ""), MAX_CMD).replace("\n", " ")
                    if cmd:
                        commands.append(cmd)
                        if re.search(r"\bgit\s+commit\b", cmd):
                            commits.append(cmd)
                        digest.append("RAN: " + cmd)
                elif name in EDIT_TOOLS or name in READ_TOOLS:
                    fp = args.get("file_path") or args.get("path") or args.get("notebook_path") or ""
                    if fp:
                        if name in EDIT_TOOLS:
                            files[fp] += 3
                            digest.append("EDITED: " + fp)
                        else:
                            files[fp] += 1
                elif name:
                    digest.append("TOOL {}: {}".format(name, trim(json.dumps(args)[:300], 300)))

    body = "\n\n".join(digest)
    if len(body) > max_chars:
        head = int(max_chars * 0.35)
        tail = max_chars - head
        body = body[:head] + "\n\n... [middle of session trimmed] ...\n\n" + body[-tail:]

    def write(name, content):
        with open(os.path.join(outdir, name), "w") as fh:
            fh.write(content)

    write("digest.txt", body)
    write("prompts.txt", "\n\n---\n\n".join(prompts))
    write("commands.txt", "\n".join(commands))
    write("files.txt", "\n".join(f for f, _ in files.most_common(40)))

    duration = ""
    try:
        from datetime import datetime

        def parse(t):
            return datetime.fromisoformat(t.replace("Z", "+00:00"))

        if first_ts and last_ts:
            duration = str(max(0, int((parse(last_ts) - parse(first_ts)).total_seconds() // 60)))
    except Exception:
        duration = ""

    facts = {
        "TM_FACT_USER_TURNS": user_turns,
        "TM_FACT_DURATION_MIN": duration,
        "TM_FACT_STARTED": first_ts,
        "TM_FACT_ENDED": last_ts,
        "TM_FACT_CWD": cwd,
        "TM_FACT_BRANCH": branch,
        "TM_FACT_SESSION_ID": session_id,
        "TM_FACT_COMMIT_COUNT": len(commits),
        "TM_FACT_COMMAND_COUNT": len(commands),
        "TM_FACT_FILE_COUNT": len(files),
        "TM_FACT_FIRST_PROMPT": trim(prompts[0].replace("\n", " "), 300) if prompts else "",
    }
    write("facts.env", "\n".join("{}={}".format(k, sh_quote(v)) for k, v in facts.items()) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
