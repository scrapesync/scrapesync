---
date: 2026-08-27
time: "14:30"
person: faheem
topic: labeling-retry
repo: scrapesync/scrapesync
branch: feature/label-pipeline
session_id: example-note-not-a-real-session
duration_min: 42
end_reason: clear
summary: "Made the labeling pipeline retry on 429s; 3 flaky fixtures still fail."
tags: [session, faheem, scrapesync]
---

# 2026-08-27 — labeling-retry

## Summary

The labeling pipeline was dropping rows when the upstream API returned 429. Added
exponential backoff around the batch call and a dead-letter file for rows that
still fail after four attempts. Ran the fixture suite: 3 of 41 cases still fail,
all of them fixtures recorded before the schema change in June.

## What changed

- `pipeline/label.py`: backoff wrapper around `submit_batch`, max 4 attempts.
- `pipeline/deadletter.py`: new, appends unlabeled rows as JSONL.
- `tests/fixtures/`: no changes — the stale fixtures are the next job.

## Decisions

- Dead-letter to a file rather than a queue: the volume is a handful of rows a day
  and nobody wants another piece of infrastructure to run.
- Cap at 4 attempts, not unlimited: a run has to finish inside the nightly window.

## Open threads

- 3 fixtures predate the June schema change and need re-recording.
- Backoff is untested against a real 429 — only simulated in tests.

## Session facts

- Turns: 18 · Commands: 24 · Files touched: 6 · Commits: 2
- Files:
  - `pipeline/label.py`
  - `pipeline/deadletter.py`
