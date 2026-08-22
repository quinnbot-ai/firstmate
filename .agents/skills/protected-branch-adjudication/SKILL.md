---
name: protected-branch-adjudication
description: >-
  Agent-only procedure for deciding the preservation, supersession, or retirement of protected refs and their associated records.
  Use before deciding whether protected refs or their associated records can be retained, superseded, or retired.
  Requires a complete supervisor-supplied preservation inventory and keeps forge activity separate from abandonment evidence.
user-invocable: false
metadata:
  internal: true
---

# protected-branch-adjudication

Use this procedure before deciding whether protected refs or their associated records can be retained, superseded, or retired.

## Required preservation inventory

Obtain the complete preservation inventory from the supervising firstmate before making a disposition.
The inventory must declare that it is complete for the decision batch and name every protected ref by full refname and immutable tip commit.
For each ref, it must name every associated task, report, isolated copy, PR or other forge record known to the supervisor, plus the requested disposition and the current owner proposed to preserve its behavior.
An absent, partial, contradictory, or unverifiable inventory means no disposition is authorized.
Leave every affected ref and record preserved while the inventory is incomplete, and report the gap instead of reconstructing completeness from search results.

## Evidence boundary

Read protected refs, reports, worktrees, task records, and forge records without changing them.
Forge activity, an open or failed PR, a stopped worker, an unreachable endpoint, a stale isolated copy, or missing recent status is evidence about delivery state only.
None of those observations proves abandonment, authorizes discard, or substitutes for the supervisor's inventory.
Do not infer a missing preservation item from a branch name, PR state, worktree path, or copied record.

## Disposition

Retain by default until the complete inventory provides an explicit disposition and evidence identifies the exact current owner, commit, and verification that preserves or supersedes each protected behavior.
For a supersession, inspect the current owner and its behavioral verification rather than treating a copied patch or a landed-looking commit as proof.
For a record whose isolated-copy pointer may be stale, run `bin/fm-reconcile-worktree-pointers.sh --dry-run` first and act only on its positively bound result.
Do not hand-edit a stale pointer around unlanded work, and do not change, move, close, delete, force-push, reset, clean, return, reuse, merge, or discard a protected artifact during adjudication.
If later retirement is authorized, hand it to the ordinary lifecycle owner after this procedure identifies the preserved successor; this procedure never performs retirement itself.
