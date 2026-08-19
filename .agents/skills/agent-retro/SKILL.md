---
name: agent-retro
description: >-
  Produce a bounded, read-only retrospective of this home's recent agent work from its own durable task records.
  Use when the captain invokes /agent-retro or asks what recent work failed, what the recent task mix looks like, or what the evidence suggests changing.
user-invocable: true
metadata:
  internal: true
---

# agent-retro

Report what this home's own recent task records actually show, so the captain can decide what to change next.
This skill is operationally read-only: it never steers a worker, tears down a task, merges, dispatches, answers a decision, or writes any file.

## What it does

1. **Read the bounded sample with one command.**
   Run `bin/fm-agent-retro.sh` and read its output.
   It is the single source for this report; its header and `--help` own the exact sources, bounds, normalization, and output contract.
   Pass `--window <1-100>` only when the captain asks for a different recent sample size.
   Do not add a second reader, parse task records yourself, or open transcripts, panes, worktrees, or project files to enrich the sample.
2. **Relay the result in the captain's nouns.**
   Lead with what the recent work produced and what went wrong, then the mix it came from.
   Report the sample's coverage and confidence as part of the finding, never as a footnote: a small or thin sample is a weak finding, and say so.
3. **Keep every proposal a proposal.**
   The report's suggestions are candidates for the captain, not decisions.
   Do not edit instructions, skills, tests, backlog, task state, or any project because of this report.
   When the captain accepts a proposal, that change becomes ordinary work with its own task and delivery path.

## What it does not support

- It attributes no cause: recorded outcome counts are evidence that something failed, never why.
- It ranks no harness, model, worker, or project, and a count difference in this sample is not a quality verdict.
- It describes only this home's own records, so it says nothing about another home's work unless that home runs its own retrospective.
