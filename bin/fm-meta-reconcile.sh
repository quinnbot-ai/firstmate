#!/usr/bin/env bash
# Reconcile explicit legacy detached task metadata after independently proving
# the task landed and its recorded endpoint is confidently gone.
#
# Usage: fm-meta-reconcile.sh [--apply] [task-id ...]
#
# Without --apply this is a read-only dry run.  It considers only legacy records
# with exactly one landed_<date>= marker and exactly one window_detached_<date>=
# endpoint record.  Every candidate must have a missing or dead endpoint and be
# proven landed through its recorded merged PR or a task branch contained in the
# project's local default branch.  It never weakens fm-teardown.sh's normal
# cleanup guard.  A lease is returned only when its worktree still proves it is
# the exact task branch; a reallocated slot is reported and left untouched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
APPLY=0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-teardown-landed-lib.sh
. "$SCRIPT_DIR/fm-teardown-landed-lib.sh"

usage() {
  printf '%s\n' 'usage: fm-meta-reconcile.sh [--apply] [task-id ...]' >&2
}

if [ "${1:-}" = --apply ]; then
  APPLY=1
  shift
fi
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
for ID in "$@"; do
  fm_task_id_path_safe "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }
done
fm_refuse_if_gate_agent

if [ "$APPLY" -eq 1 ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
fi

TMP_META=
cleanup_tmp() {
  [ -z "$TMP_META" ] && return 0
  rm -f -- "$TMP_META" || return 1
  TMP_META=
}
trap cleanup_tmp EXIT

legacy_detached_window() {  # <meta>
  local meta=$1 lines line value
  lines=$(grep '^window_detached_' "$meta" 2>/dev/null || true)
  [ "$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d '[:space:]')" = 1 ] || return 1
  line=$(printf '%s\n' "$lines" | sed -n '1p')
  printf '%s\n' "$line" | grep -Eq '^window_detached_[0-9]{8}=' || return 1
  value=${line#*=}
  value=${value%%'  #' *}
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

legacy_endpoint_state() {  # <meta> <task-id>
  local meta=$1 id=$2 target tmp_line
  [ "$(grep -c '^window=' "$meta" 2>/dev/null || true)" -eq 0 ] || return 1
  target=$(legacy_detached_window "$meta") || return 1
  cleanup_tmp || return 1
  TMP_META=$(mktemp "${TMPDIR:-/tmp}/fm-meta-reconcile.XXXXXX") || return 1
  while IFS= read -r tmp_line || [ -n "$tmp_line" ]; do
    case "$tmp_line" in
      window=*|window_detached_*=*) ;;
      *) printf '%s\n' "$tmp_line" >> "$TMP_META" ;;
    esac
  done < "$meta"
  printf 'window=%s\n' "$target" >> "$TMP_META"
  if ! fm_backend_validate_task_endpoint "$TMP_META" "$id" >/dev/null 2>&1; then
    cleanup_tmp || true
    return 1
  fi
  LEGACY_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  LEGACY_TARGET=$FM_BACKEND_VALIDATED_TARGET
  cleanup_tmp || return 1
  LEGACY_ENDPOINT_STATE=$(fm_backend_agent_state "$LEGACY_BACKEND" "$LEGACY_TARGET" 2>/dev/null || true)
  case "$LEGACY_ENDPOINT_STATE" in
    dead|missing) return 0 ;;
    *) return 1 ;;
  esac
}

safe_cleanup_artifacts() {  # <task-id>
  local id=$1 path artifact quarantine
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  for artifact in "$id.status" "$id.turn-ended" "$id.check.sh" "$id.check-trust" \
    "$id.pr-poll" "$id.pr-poll-registration" "$id.pr-poll-retirement"; do
    path="$STATE/$artifact"
    [ ! -e "$path" ] && [ ! -L "$path" ] && continue
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  done
  quarantine="$STATE/.pr-check-quarantine"
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] && return 0
  [ -d "$quarantine" ] && [ ! -L "$quarantine" ] || return 1
  for path in "$quarantine/$id."*; do
    [ ! -e "$path" ] && [ ! -L "$path" ] && continue
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  done
}

remove_cleanup_artifacts() {  # <task-id>
  local id=$1 path quarantine
  rm -f -- "$STATE/$id.status" "$STATE/$id.turn-ended" "$STATE/$id.check.sh" \
    "$STATE/$id.check-trust" "$STATE/$id.pr-poll" "$STATE/$id.pr-poll-registration" \
    "$STATE/$id.pr-poll-retirement" || return 1
  quarantine="$STATE/.pr-check-quarantine"
  if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
    for path in "$quarantine/$id."*; do
      [ ! -e "$path" ] && [ ! -L "$path" ] && continue
      rm -f -- "$path" || return 1
    done
    rmdir "$quarantine" 2>/dev/null || true
  fi
}

registered_task_worktree() {  # <task-id> <project>
  local id=$1 project=$2 listed line entry='' found=''
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *) entry=${line#worktree } ;;
      "branch refs/heads/fm/$id")
        [ -z "$found" ] || return 1
        found=$entry
        ;;
    esac
  done <<EOF
$listed
EOF
  printf '%s' "$found"
}

task_worktree_safe() {  # <task-id> <worktree> <project> <registered-worktree>
  local id=$1 worktree=$2 project=$3 registered=$4 top branch head ref_head worktree_real registered_real
  [ -n "$worktree" ] && [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  [ -n "$registered" ] && [ -d "$registered" ] && [ ! -L "$registered" ] || return 1
  worktree_real=$(cd "$worktree" && pwd -P) || return 1
  registered_real=$(cd "$registered" && pwd -P) || return 1
  [ "$worktree_real" = "$registered_real" ] || return 1
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$worktree_real" ] || return 1
  branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [ "$branch" = "fm/$id" ] || return 1
  head=$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null) || return 1
  ref_head=$(git -C "$project" rev-parse --verify "refs/heads/fm/$id" 2>/dev/null) || return 1
  [ "$head" = "$ref_head" ] || return 1
  [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$worktree" status --porcelain 2>/dev/null)" ] || return 1
}

archive_meta() {  # <meta> <task-id>
  local meta=$1 id=$2 day archive
  day=$(date +%F)
  archive="$STATE/meta-archive/$day"
  if [ -e "$archive" ] || [ -L "$archive" ]; then
    [ -d "$archive" ] && [ ! -L "$archive" ] || return 1
  else
    mkdir -p -- "$archive" || return 1
  fi
  [ ! -e "$archive/$id.meta" ] && [ ! -L "$archive/$id.meta" ] || return 1
  mv -- "$meta" "$archive/$id.meta"
}

reconcile_one() {  # <task-id>
  local id=$1 meta=$STATE/$1.meta marker_count worktree project registered lease proof=
  LEGACY_BACKEND=
  LEGACY_TARGET=
  LEGACY_ENDPOINT_STATE=
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf '%s: preserved: no safe metadata file\n' "$id"; return 0; }
  marker_count=$(grep -Ec '^landed_[0-9]{8}=' "$meta" 2>/dev/null || true)
  [ "$marker_count" -eq 1 ] || { printf '%s: preserved: not an explicit legacy landed record\n' "$id"; return 0; }
  if ! legacy_endpoint_state "$meta" "$id"; then
    printf '%s: preserved: endpoint is not confidently dead or missing\n' "$id"
    return 0
  fi
  worktree=$(fm_meta_get "$meta" worktree)
  project=$(fm_meta_get "$meta" project)
  PR_URL=$(fm_meta_get "$meta" pr)
  PROJ=$project
  WT=$worktree
  if [ ! -d "$PROJ" ] || ! git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s: preserved: project is not inspectable\n' "$id"
    return 0
  fi
  registered=$(registered_task_worktree "$id" "$project") || {
    printf '%s: preserved: task worktree ownership is ambiguous\n' "$id"
    return 0
  }
  if [ -n "$registered" ]; then
    if ! task_worktree_safe "$id" "$worktree" "$project" "$registered"; then
      printf '%s: preserved: task worktree is dirty, unlanded, or not owned by this project\n' "$id"
      return 0
    fi
  elif [ -e "$worktree" ] || [ -L "$worktree" ]; then
    printf '%s: preserved: recorded worktree is not owned by this project\n' "$id"
    return 0
  fi
  if fm_teardown_recorded_pr_contains_task_branch "$id"; then
    proof='merged-pr'
  elif fm_teardown_local_main_contains_task_branch "$id"; then
    proof=local-main
  else
    printf '%s: preserved: no merged-PR or local-main landed proof\n' "$id"
    return 0
  fi
  safe_cleanup_artifacts "$id" || { printf '%s: preserved: unsafe stale artifact path\n' "$id"; return 0; }
  lease=$(fm_meta_get "$meta" treehouse_lease)
  if [ -n "$lease" ] && [ "$lease" != 1 ]; then
    printf '%s: preserved: invalid lease marker\n' "$id"
    return 0
  fi
  if [ "$lease" = 1 ] && [ -z "$registered" ]; then
    printf '%s: preserved: held lease is not provably this task worktree\n' "$id"
    return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    printf '%s: would reconcile: endpoint=%s, proof=%s%s\n' "$id" "$LEGACY_ENDPOINT_STATE" "$proof" \
      "$( [ "$lease" = 1 ] && printf ', return lease' )"
    return 0
  fi
  if [ "$lease" = 1 ]; then
    (cd "$project" && treehouse return --force "$worktree") || {
      printf '%s: preserved: treehouse lease return failed\n' "$id"
      return 0
    }
  fi
  archive_meta "$meta" "$id" || { printf '%s: preserved: archive path is unsafe or occupied\n' "$id"; return 0; }
  remove_cleanup_artifacts "$id" || { printf '%s: archived: stale artifact cleanup failed\n' "$id"; return 1; }
  printf '%s: reconciled: endpoint=%s, proof=%s\n' "$id" "$LEGACY_ENDPOINT_STATE" "$proof"
}

if [ "$#" -eq 0 ]; then
  set --
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    grep -Eq '^landed_[0-9]{8}=' "$meta" 2>/dev/null || continue
    ID=$(basename "$meta" .meta)
    fm_task_id_path_safe "$ID" || continue
    set -- "$@" "$ID"
  done
fi

if [ "$APPLY" -eq 1 ]; then
  RECONCILE_LOCK="$STATE/.meta-reconcile.lock"
  fm_lock_acquire_wait "$RECONCILE_LOCK" || { echo 'error: cannot acquire reconciliation lock' >&2; exit 1; }
  trap 'fm_lock_release "$RECONCILE_LOCK"; cleanup_tmp' EXIT
fi

for ID in "$@"; do
  reconcile_one "$ID"
done
