# Pull request check-set gate verification

Audience: maintainer verification.

This record supports two guarantees: the merge refusal in `bin/fm-pr-merge.sh` (verdict owned by `bin/fm-pr-verify-lib.sh`), and the `unverified` CI classification in `bin/fm-crew-state.sh`.
It records the mechanism by which a pull request can record zero checks forever, because that mechanism is what makes an absent check set a real hazard rather than a cosmetic one.
Task chronology and delivery evidence stay in the private task report and PR evidence.

## Why an absent check set is not "no CI configured"

GitHub Actions schedules a `pull_request` workflow against the pull request's merge ref, `refs/pull/<number>/merge`.
When the head conflicts with the base, GitHub cannot build that merge commit, the merge ref does not exist, and no workflow run is ever created.
The result is not a failing check and not a queued check: it is the complete absence of a check set, which reads in every UI and API as "no CI checks configured".
Nothing about that state is self-correcting, and nothing about it distinguishes a repository that genuinely has no CI from a pull request whose CI can never run.

## Evidence

Verified 2026-08-20 against `quinnbot-ai/firstmate`, whose `.github/workflows/ci.yml` and `.github/workflows/no-mistakes-required.yml` both trigger on `pull_request` with `branches: [main]` and carry no path filters.
Both workflow files were byte-identical at the affected head, at an unaffected sibling head, and on `main`, so workflow configuration is excluded as a cause.

Pull request 148 (`fm/fm-brief-script-reference-preflight`) was open with zero workflow runs; pull requests 151 and 154 were open with checks.

```
$ git ls-remote https://github.com/quinnbot-ai/firstmate.git 'refs/pull/148/*' 'refs/pull/151/*' 'refs/pull/154/*'
fa0c7644b2244481e65bd9539cbf3278fd41575f	refs/pull/148/head
74e6bf42719b18046f6bb7afc3f668a89f779741	refs/pull/151/head
7b026ab24c2c0765163f21b6cfd0d898af8f0f12	refs/pull/151/merge
b553350e0b5cb8c870f6b1d5ded65e7e164c4f99	refs/pull/154/head
b1340d2a16ae5cb8dd105806d3bb7bea7c91af54	refs/pull/154/merge
```

The pull request with no runs is exactly the one with no merge ref.
The API agrees on the cause, and the conflict reproduces locally:

```
$ gh-axi api /repos/quinnbot-ai/firstmate/pulls/148 --jq '.mergeable_state'
dirty
$ git merge-tree --write-tree --name-only refs/fmdiag/main refs/fmdiag/pr148
e925436dce1d0137c8258b3756e90ebddbf2db72
bin/fm-spawn.sh

Auto-merging bin/fm-spawn.sh
CONFLICT (content): Merge conflict in bin/fm-spawn.sh
```

Event delivery is excluded independently.
Third-party check suites were created on the same head commit that GitHub Actions ignored, so the push was received and processed:

```
$ gh-axi api /repos/quinnbot-ai/firstmate/commits/fa0c7644.../check-suites --jq '.check_suites[] | "\(.app.slug) \(.status) \(.created_at)"'
xcode-cloud queued 2026-08-20T16:44:47Z
cursor queued 2026-08-20T16:44:48Z
```

A check suite is not a check set: that same head reports `total_count` 0 for both `/check-runs` and `/status`, which is why the gate reads those two counts and not the suite list.

The 2026-08-20 control that separates the conflict from every other variable is pull request 147, which conflicted in the same file, sat at zero runs for 32 minutes, and began producing runs within 16 seconds of the force-push at 16:37:45 that rebased the conflict away.
Two interventions that do not resolve a conflict produced nothing on 148: a close-and-reopen, and a real head-advancing commit.

## Gate behavior against the live evidence

Verified 2026-08-20 by sourcing the lib and calling the verdict directly.

```
$ bash -c '. bin/fm-pr-verify-lib.sh; fm_pr_check_set_verdict quinnbot-ai firstmate 148; echo "$FM_PR_VERIFY_VERDICT"'
unverified
$ bash -c '. bin/fm-pr-verify-lib.sh; fm_pr_check_set_verdict quinnbot-ai firstmate 154; echo "$FM_PR_VERIFY_VERDICT"'
verified
```

The verdict for 148 names the conflict as the cause; 154 reported 13 check runs and 151 reported 14.

## Why the gate does not adjudicate red

The check-set gate answers only "does this head carry a check set at all", because red versus green is a different state that is already visible to whoever is merging, and `AGENTS.md` section 7's "never merge a red PR" rule keeps owning that judgment.

That division of labour was originally forced rather than chosen.
Until 2026-08-20 this repository carried a check that failed by design on every direct-PR delivery: `PR must be raised via no-mistakes` accepted only the signature the no-mistakes pipeline writes, which a direct-PR delivery legitimately never has.
On 2026-08-20 head `b553350e` reported 13 check runs of which three concluded `failure`, and pull requests in that state were merged deliberately; PR #152 merged with that check red twice and every other check green.
A gate that refused red would have blocked every direct-PR merge.

That permanent false red is retired.
`bin/fm-pr-body-compliance.sh` now accepts either the pipeline signature or a maintainer-declared bypass, so a red `PR must be raised via no-mistakes` again means an undeclared pipeline bypass rather than routine correct work.
No check in this repository is expected to be red on a healthy delivery, and a red one is a stop-and-read result rather than a documented exception to skim past.

## Regression coverage

`tests/fm-pr-merge.test.sh` covers the merge refusal for an absent check set, the same refusal for an unreadable one, and the explicit `--allow-unverified` override.
`tests/fm-crew-state.test.sh` covers the `unverified` classification, including the case where the worker's own status line claims checks are green while the CI log reports none.
`tests/fm-pr-body-compliance.test.sh` covers the delivery-path compliance verdict that retired the permanent false red, including the refusal of an undeclared bypass by a maintainer and of a declaration by an author without write access.
All three suites run under `bin/fm-test-run.sh`.
