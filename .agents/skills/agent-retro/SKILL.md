---
name: agent-retro
description: >-
  Produce an evidence-backed, read-only retrospective of bounded recent Firstmate agent work.
  Use when the captain invokes /agent-retro or asks for a retrospective of recent agent failures, task mix, or improvement evidence.
user-invocable: true
metadata:
  internal: true
---

# agent-retro

Run `bin/fm-agent-retro.sh` for the default bounded local-only report.
Use `bin/fm-agent-retro.sh --window <1-100>` only when the captain explicitly wants a different recent sample size.
Treat its source coverage, confidence, and limitations as part of the result.

The report is read-only and redacted.
It never exports raw transcripts, prompts, paths, commands, tokens, or status text.
It does not rank model quality unless its controlled-sample rule is met.
Every suggested instruction or test change is a proposal requiring captain approval.
Do not edit instructions, skills, tests, backlog, task state, hooks, or source records from this skill.
