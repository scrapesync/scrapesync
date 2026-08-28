#!/usr/bin/env python3
"""Redact credentials from text before it is committed to the shared vault.

Usage:
    scrub_secrets.py < input.txt > output.txt      # exit 0, redaction count on stderr
    scrub_secrets.py --check < input.txt           # exit 2 if anything would be redacted

Fail-closed by design: the hooks refuse to write a note if this script cannot run.
It is deliberately over-eager. A redacted false positive costs nothing; a leaked
key in a repo everyone clones costs a rotation.
"""
import re
import sys

REDACT = "[REDACTED:{}]"

# (name, compiled pattern, group index to redact -- 0 means the whole match)
PATTERNS = [
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}"), 0),
    ("openai-key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}"), 0),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}"), 0),
    ("github-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), 0),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), 0),
    ("google-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{30,}"), 0),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}"), 0),
    ("stripe-key", re.compile(r"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"), 0),
    ("hf-token", re.compile(r"\bhf_[A-Za-z0-9]{20,}"), 0),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"), 0),
    ("bearer-token", re.compile(r"(?i)\b(?:bearer|token)\s+([A-Za-z0-9._\-]{20,})"), 1),
    # KEY=value / "secret": "value" style assignments -- keep the name, drop the value.
    ("assigned-secret", re.compile(
        r"""(?ix)
        \b([A-Za-z0-9_.\-]*(?:api[_\-]?key|secret|passwd|password|token|credential|private[_\-]?key|access[_\-]?key)[A-Za-z0-9_.\-]*)
        \s*[:=]\s*
        ["']?([^\s"'`,;)]{8,})["']?
        """), 2),
    # Prose form: "the password is hunter2", "api key for staging is abc123".
    ("stated-secret", re.compile(
        r"(?i)\b(?:password|passphrase|api\s?key|secret|token|credential)s?\b[^.\n]{0,40}?\bis\s+([^\s.,;)]{6,})"), 1),
    # Credentials embedded in a connection string.
    ("url-credentials", re.compile(r"://[^/\s:@]{1,64}:([^/\s:@]{3,})@"), 1),
]

# Multi-line blocks: everything between the markers goes.
BLOCK = re.compile(
    r"-----BEGIN[A-Z ]*PRIVATE KEY-----.*?-----END[A-Z ]*PRIVATE KEY-----",
    re.DOTALL,
)

# Obvious placeholders we should not bother redacting.
PLACEHOLDER = re.compile(
    r"(?i)^(x{3,}|\*{3,}|<[^>]+>|\$\{?[a-z_][a-z0-9_]*\}?|your[_\-]?\w+|changeme|none|null|true|false|example.*|placeholder.*|redacted.*|\[redacted.*)$"
)


def scrub(text):
    count = 0

    def block_sub(_m):
        nonlocal count
        count += 1
        return REDACT.format("private-key")

    text = BLOCK.sub(block_sub, text)

    for name, pattern, group in PATTERNS:
        def sub(m, _name=name, _group=group):
            nonlocal count
            if _group == 0:
                count += 1
                return REDACT.format(_name)
            value = m.group(_group)
            if not value or PLACEHOLDER.match(value):
                return m.group(0)
            count += 1
            start, end = m.span(_group)
            s, e = m.start(), m.end()
            return m.group(0)[: start - s] + REDACT.format(_name) + m.group(0)[end - s :]

        text = pattern.sub(sub, text)
    return text, count


def main():
    check_only = "--check" in sys.argv[1:]
    raw = sys.stdin.read()
    cleaned, count = scrub(raw)
    if check_only:
        sys.stderr.write("{} secret(s) detected\n".format(count))
        sys.exit(2 if count else 0)
    sys.stdout.write(cleaned)
    sys.stderr.write("{} secret(s) redacted\n".format(count))


if __name__ == "__main__":
    main()
