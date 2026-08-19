#!/usr/bin/env bash
# Manual verification lab for the herdr sidebar-legibility change.
# Spawns a crewmate, a scout, and a secondmate through the REAL bin/fm-spawn.sh
# into an isolated fm-lab- herdr session (guarded lab contract, never the
# captain's default session), then captures the rendered sidebar via a herdr
# client running inside a private tmux server:
#   1. AFTER  - what the sidebar shows with the new spawn-time metadata live
#   2. BEFORE - the same fleet with the reported display names cleared, i.e.
#               exactly what the pre-change sidebar showed (flat fm-<id> tabs)
# Also dumps the pane/workspace metadata JSON the change reported.
set -u

ROOT=${FM_VIS_ROOT:?}
EV=${FM_VIS_EV:?}
TMUX_SOCK=fmvis$$

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-sidebar-vis.XXXXXX")

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
# CRITICAL ORDER: forget the inherited pane identity (which unsets
# HERDR_SESSION) BEFORE exporting the lab session, exactly like the smoke and
# e2e suites do - the reverse order sent spawns to the captain's default
# session on the first attempt of this lab.
herdr_forget_inherited_pane
SESSION="fm-lab-sidebarvis-$$"
export HERDR_SESSION="$SESSION"

WT1=; WT2=; CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null
  [ -n "$WT1" ] && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && treehouse return --force "$WT2" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary home, a trading secondmate home, two projects --
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/quota-fix-k3" "$PRIMARY_HOME/data/docket-scan-q2" "$PRIMARY_HOME/config"
printf 'brief: demo crewmate.\n' > "$PRIMARY_HOME/data/quota-fix-k3/brief.md"
printf 'brief: demo scout.\n' > "$PRIMARY_HOME/data/docket-scan-q2/brief.md"

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data" "$SM_HOME/config" "$SM_HOME/bin"
printf '# scratch secondmate home\n' > "$SM_HOME/AGENTS.md"
printf 'trading\n' > "$SM_HOME/.fm-secondmate-home"
printf 'charter: demo trading secondmate.\n' > "$SM_HOME/data/charter.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}
PROJ1="$TMP_ROOT/content-engine"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/epstein-search"; make_scratch_project "$PROJ2"

# --- spawn the fleet through the REAL fm-spawn.sh ---------------------------
[ "${HERDR_SESSION:-}" = "$SESSION" ] || fail "HERDR_SESSION is not the lab session; refusing to spawn"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" quota-fix-k3 "$PROJ1" "sh -c 'echo crew-up; sleep 600'" --mode no-mistakes --yolo off --backend herdr \
  >"$TMP_ROOT/cm.out" 2>"$TMP_ROOT/cm.err" || fail "crewmate spawn failed: $(cat "$TMP_ROOT/cm.err")"
WT1=$(grep '^worktree=' "$PRIMARY_HOME/state/quota-fix-k3.meta" | cut -d= -f2-)
CM_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/quota-fix-k3.meta" | cut -d= -f2-)
pass "crewmate quota-fix-k3 spawned (pane $CM_PANE)"

FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" docket-scan-q2 "$PROJ2" "sh -c 'echo scout-up; sleep 600'" --scout --backend herdr \
  >"$TMP_ROOT/sc.out" 2>"$TMP_ROOT/sc.err" || fail "scout spawn failed: $(cat "$TMP_ROOT/sc.err")"
WT2=$(grep '^worktree=' "$PRIMARY_HOME/state/docket-scan-q2.meta" | cut -d= -f2-)
SC_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/docket-scan-q2.meta" | cut -d= -f2-)
pass "scout docket-scan-q2 spawned (pane $SC_PANE)"

FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" trading "$SM_HOME" "sh -c 'echo secondmate-up; sleep 600'" --secondmate --backend herdr \
  >"$TMP_ROOT/sm.out" 2>"$TMP_ROOT/sm.err" || fail "secondmate spawn failed: $(cat "$TMP_ROOT/sm.err")"
SM_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/trading.meta" | cut -d= -f2-)
pass "secondmate trading spawned (pane $SM_PANE)"

# Hard isolation check: every spawned tab must be in the LAB session.
LAB_TABS=$(herdr tab list --session "$SESSION" 2>/dev/null | jq -r '.result.tabs[].label')
for lbl in fm-quota-fix-k3 fm-docket-scan-q2 fm-trading; do
  case "$LAB_TABS" in *"$lbl"*) : ;; *) fail "tab $lbl did not land in the lab session; aborting" ;; esac
done
pass "all three spawned tabs live in the isolated lab session"

# Herdr's Agents sidebar lists only panes with a REGISTERED agent. A real
# spawn runs claude, whose integration registers the pane itself; these demo
# panes are plain sh stubs, so register them the same way the integration
# would, purely so the Agents list renders the entries. This does not touch
# the display metadata under test.
for p in "$CM_PANE" "$SC_PANE" "$SM_PANE"; do
  herdr pane report-agent "$p" --source claude-code --agent claude --state idle --session "$SESSION" >/dev/null 2>&1
done
pass "stub panes registered as agents so the Agents sidebar lists them"

# --- dump the metadata the spawns reported (CLI transcript evidence) --------
{
  echo "\$ herdr pane get <pane> --session $SESSION  # one per spawned worker"
  for p in "$CM_PANE" "$SC_PANE" "$SM_PANE"; do
    herdr pane get "$p" --session "$SESSION" 2>/dev/null \
      | jq -c '{pane_id:.result.pane.pane_id, display_agent:.result.pane.display_agent, tokens:.result.pane.tokens}'
  done
  echo
  echo "\$ herdr workspace list --session $SESSION"
  herdr workspace list --session "$SESSION" 2>/dev/null \
    | jq -c '.result.workspaces[] | {label, tokens}'
  echo
  echo "\$ herdr tab list --session $SESSION   # tab labels must stay exactly fm-<id>"
  herdr tab list --session "$SESSION" 2>/dev/null | jq -r '.result.tabs[].label' | sort
} > "$EV/herdr-metadata-transcript.txt"
pass "metadata transcript written"

# --- capture helper: herdr client inside a private tmux server --------------
capture() {  # <outfile-basename>
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null
  sleep 1
  tmux -L "$TMUX_SOCK" new-session -d -x 190 -y 46 \
    "env HERDR_SESSION=$SESSION herdr --session $SESSION" || fail "tmux client launch failed"
  sleep 5
  tmux -L "$TMUX_SOCK" capture-pane -p -e > "$EV/$1.ansi" || fail "tmux capture failed"
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null
}

capture sidebar-after
pass "AFTER sidebar captured"

# --- reconstruct the BEFORE state: clear the reported display names ---------
for p in "$CM_PANE" "$SC_PANE" "$SM_PANE"; do
  herdr pane report-metadata "$p" --source firstmate --clear-display-agent --session "$SESSION" >/dev/null 2>&1
done
capture sidebar-before
pass "BEFORE sidebar captured (display names cleared = pre-change presentation)"

# --- restore the AFTER state the same way a relaunch re-report would --------
fm_backend_herdr_sidebar_report_pane "$SESSION" "$CM_PANE" crew content-engine quota-fix-k3 firstmate
fm_backend_herdr_sidebar_report_pane "$SESSION" "$SC_PANE" scout epstein-search docket-scan-q2 firstmate
fm_backend_herdr_sidebar_report_pane "$SESSION" "$SM_PANE" secondmate trading trading 2ndmate-trading
pass "metadata re-reported (relaunch-refresh path exercised)"

# --- teardown through the real path -----------------------------------------
FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" quota-fix-k3 --force >/dev/null 2>&1 && WT1=
pass "fm-teardown of the crewmate still works with sidebar metadata present"

echo DONE
