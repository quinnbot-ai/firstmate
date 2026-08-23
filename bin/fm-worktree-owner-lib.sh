#!/usr/bin/env bash
# Who owns a recorded task copy RIGHT NOW, including copies that carry no
# ownership binding at all.
#
# THE FAILURE THIS EXISTS FOR. bin/fm-worktree-binding-lib.sh stamps the current
# owner inside a freshly assigned copy's private Git directory, and teardown
# reads it before touching anything. That protects every copy assigned after the
# binding existed. It deliberately does nothing for the collisions that already
# exist: a lane recorded before the binding, pointing at a copy that also
# predates it, has no binding to read, so teardown behaves exactly as it did
# before and the stale pointer stays both unrefused and unretirable.
#
# Those collisions are not a backlog that drains. A lane that is preserved
# instead of torn down - a captain-gated long-term pause - keeps its recorded
# pointer for as long as it stays preserved, the pool hands the slot to someone
# else, and nothing refuses. The count of stale pointers in a home therefore
# grows with the number of protected lanes, and every protected lane is by
# construction one that will never be cleaned up on its own.
#
# THE SECOND PROOF. When no binding can be read, ownership requires an active
# endpoint whose durable task metadata points at the copy and whose live,
# read-only current-path query resolves to that same copy. A checked-out branch
# is mutable task content and remains diagnostic context only. The endpoint and
# record agreement is independent of that content, which is the whole point: a
# recorded path and branch name are allocations and workspace state, never proof
# of ownership.
#
# THREE CONDITIONS KEEP IT QUIET. A wrong "this copy was reassigned" verdict is
# as damaging as the missing one, because it retires a live pointer and refuses
# a legitimate cleanup, so the endpoint proof fires only when all three hold:
#
#   1. The binding wins whenever it is readable. Endpoint fallback is consulted
#      only when the private marker is definitely absent.
#   2. A claimant must have exact endpoint metadata and an active record for the
#      copy, and a read-only runtime query must return that exact physical path.
#   3. Exactly one pool-wide claimant may prove the path automatically. Zero or
#      multiple claimants leave ownership unresolved and preserve every record
#      and copy unless reconciliation receives an explicit owner identity.
#
# Usage: . bin/fm-worktree-owner-lib.sh
#   (after bin/fm-backend.sh and bin/fm-worktree-binding-lib.sh)
#
# Public entry points:
#   fm_worktree_owner_resolve <worktree> <state-dir> [<asserted-state> <asserted-task>]
#     Sets FM_WORKTREE_OWNER_STATE / _TASK_ID / _METHOD
#     (binding|endpoint|asserted-endpoint) / _BRANCH and
#     returns 0 when the copy's current owner is proven. Returns non-zero with
#     FM_WORKTREE_OWNER_DETAIL when it is not; unprovable is never a verdict.
#   fm_worktree_owner_bind_resolved_legacy <worktree>
#     Converts the latest endpoint proof into an authoritative binding and
#     revalidates the exact state/task owner. Callers hold pool/transition locks.
#   fm_worktree_owner_retire_pointer <meta-file> <owner-state> <owner-task-id>
#     Writes the durable owner state and task identity into one task record and
#     KEEPS the stale `worktree=` value as history. Callers own the meta lock;
#     this function does not take one.

FM_WORKTREE_OWNER_TASK_ID=
FM_WORKTREE_OWNER_STATE=
FM_WORKTREE_OWNER_METHOD=
FM_WORKTREE_OWNER_BRANCH=
FM_WORKTREE_OWNER_DETAIL=
FM_WORKTREE_OWNER_INVENTORY_SEEN=

FM_WORKTREE_OWNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F fm_backend_validate_task_endpoint >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$FM_WORKTREE_OWNER_LIB_DIR/fm-backend.sh"
fi
if ! declare -F fm_worktree_record_resolve >/dev/null 2>&1; then
  # shellcheck source=bin/fm-worktree-binding-lib.sh
  . "$FM_WORKTREE_OWNER_LIB_DIR/fm-worktree-binding-lib.sh"
fi
if ! declare -F secondmate_registry_parse_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$FM_WORKTREE_OWNER_LIB_DIR/fm-secondmate-registry-lib.sh"
fi
if ! declare -F fm_secondmate_parent_record_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$FM_WORKTREE_OWNER_LIB_DIR/fm-secondmate-parent-lib.sh"
fi

fm_worktree_owner_record_confirms() {  # <state-dir> <task-id> <worktree>
  local state=${1-} id=${2-} worktree=${3-} state_real meta
  state_real=$(fm_worktree_binding_state_resolve "$state" 2>/dev/null) || return 1
  meta="$state_real/$id.meta"
  [ -f "$meta" ] || return 1
  fm_worktree_record_resolve "$meta" || return 1
  [ "$FM_WORKTREE_RECORD_ACTIVE_PATH" = "$worktree" ]
}

fm_worktree_owner_endpoint_current_path() {  # <meta-file> <task-id>
  local meta=${1-} id=${2-} backend target
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in
    tmux|herdr)
      fm_backend_source "$backend" >/dev/null 2>&1 || return 1
      "fm_backend_${backend}_current_path" "$target"
      ;;
    zellij|cmux)
      fm_backend_source "$backend" >/dev/null 2>&1 || return 1
      "fm_backend_${backend}_current_path" "$target" "fm-$id"
      ;;
    *) return 1 ;;
  esac
}

fm_worktree_owner_inventory_walk() {  # <home>
  local home=$1 home_real state_real reg line child child_real parent_real
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  case "$FM_WORKTREE_OWNER_INVENTORY_SEEN" in
    *$'\n'"$home_real"$'\n'*) return 0 ;;
  esac
  FM_WORKTREE_OWNER_INVENTORY_SEEN="$FM_WORKTREE_OWNER_INVENTORY_SEEN$home_real
"
  state_real=$(fm_worktree_binding_state_resolve "$home_real/state" 2>/dev/null) || return 1
  printf '%s\n' "$state_real"
  reg="$home_real/data/secondmates.md"
  if [ -e "$reg" ] || [ -L "$reg" ]; then
    [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '- '*)
          secondmate_registry_parse_line "$line" || return 1
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$SECONDMATE_REGISTRY_HOME
          case "$child" in /*) ;; *) return 1 ;; esac
          child_real=$(CDPATH='' cd -- "$child" 2>/dev/null && pwd -P) || return 1
          fm_secondmate_parent_record_parse "$child_real/.fm-secondmate-parent" || return 1
          [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
          parent_real=$(CDPATH='' cd -- "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || return 1
          [ "$parent_real" = "$home_real" ] || return 1
          fm_worktree_owner_inventory_walk "$child_real" || return 1
          ;;
      esac
    done < "$reg"
  fi
}

fm_worktree_owner_state_inventory() {  # <state-dir>
  local state_real home parent marker parent_real seen=$'\n'
  state_real=$(fm_worktree_binding_state_resolve "$1" 2>/dev/null) || return 1
  home=${state_real%/state}
  [ "$home" != "$state_real" ] || return 1
  while :; do
    case "$seen" in
      *$'\n'"$home"$'\n'*) return 1 ;;
    esac
    seen="${seen}${home}"$'\n'
    marker="$home/.fm-secondmate-parent"
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
      break
    fi
    fm_secondmate_parent_record_parse "$marker" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || break
    parent=$FM_SECONDMATE_PARENT_HOME
    parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
    home=$parent_real
  done
  FM_WORKTREE_OWNER_INVENTORY_SEEN=$'\n'
  fm_worktree_owner_inventory_walk "$home"
}

# These result globals are read by the caller after this sourced helper returns.
# shellcheck disable=SC2034
fm_worktree_owner_resolve() {  # <worktree> <state-dir> [<asserted-state> <asserted-task>]
  local worktree=${1-} state=${2-} asserted_state=${3-} asserted_task=${4-}
  local state_real worktree_real branch meta id declared inventory inventory_state inventory_ok=0 caller_inventory_ok=0
  local active_real current current_real candidate= candidate_state= candidate_count=0 claimant_count=0 asserted_candidate_count=0
  FM_WORKTREE_OWNER_TASK_ID=
  FM_WORKTREE_OWNER_STATE=
  FM_WORKTREE_OWNER_METHOD=
  FM_WORKTREE_OWNER_BRANCH=
  FM_WORKTREE_OWNER_DETAIL=
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    FM_WORKTREE_OWNER_DETAIL="no copy at ${worktree:-<empty>} to read current ownership from"
    return 1
  fi
  state_real=$(fm_worktree_binding_state_resolve "$state" 2>/dev/null) || {
    FM_WORKTREE_OWNER_DETAIL="cannot establish the calling home's state identity"
    return 1
  }
  # Condition 1: a binding is authoritative only while its active record agrees.
  if fm_worktree_binding_read "$worktree"; then
    if ! fm_worktree_owner_record_confirms "$FM_WORKTREE_BINDING_STATE" "$FM_WORKTREE_BINDING_TASK_ID" "$worktree"; then
      FM_WORKTREE_OWNER_DETAIL="the copy at $worktree is bound to task $FM_WORKTREE_BINDING_TASK_ID in $FM_WORKTREE_BINDING_STATE, but that task has no active record holding this copy"
      return 1
    fi
    FM_WORKTREE_OWNER_STATE=$FM_WORKTREE_BINDING_STATE
    FM_WORKTREE_OWNER_TASK_ID=$FM_WORKTREE_BINDING_TASK_ID
    FM_WORKTREE_OWNER_METHOD=binding
    FM_WORKTREE_OWNER_BRANCH=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    return 0
  fi
  if ! fm_worktree_binding_is_absent "$worktree"; then
    FM_WORKTREE_OWNER_DETAIL=$(fm_worktree_binding_detail)
    return 1
  fi
  worktree_real=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || {
    FM_WORKTREE_OWNER_DETAIL="cannot resolve the physical path of the copy at $worktree"
    return 1
  }
  branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  FM_WORKTREE_OWNER_BRANCH=$branch
  inventory=$(fm_worktree_owner_state_inventory "$state_real") || {
    FM_WORKTREE_OWNER_DETAIL="cannot establish a complete local Firstmate-home inventory for the shared pool"
    return 1
  }
  if [ -n "$asserted_state" ] || [ -n "$asserted_task" ]; then
    [ -n "$asserted_state" ] && fm_worktree_binding_task_id_valid "$asserted_task" || {
      FM_WORKTREE_OWNER_DETAIL="the asserted legacy owner identity is incomplete or invalid"
      return 1
    }
    asserted_state=$(fm_worktree_binding_state_resolve "$asserted_state" 2>/dev/null) || {
      FM_WORKTREE_OWNER_DETAIL="the asserted legacy owner state cannot be resolved"
      return 1
    }
  fi
  while IFS= read -r inventory_state; do
    [ -n "$inventory_state" ] || continue
    [ "$inventory_state" = "$state_real" ] && caller_inventory_ok=1
    [ "$inventory_state" = "$asserted_state" ] && inventory_ok=1
    for meta in "$inventory_state"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      fm_worktree_binding_task_id_valid "$id" || continue
      fm_worktree_record_resolve "$meta" || continue
      [ -d "$FM_WORKTREE_RECORD_ACTIVE_PATH" ] || continue
      active_real=$(CDPATH='' cd -- "$FM_WORKTREE_RECORD_ACTIVE_PATH" 2>/dev/null && pwd -P) || continue
      [ "$active_real" = "$worktree_real" ] || continue
      claimant_count=$((claimant_count + 1))
      declared=$(fm_meta_get "$meta" worktree_binding)
      [ -z "$declared" ] || continue
      current=$(fm_worktree_owner_endpoint_current_path "$meta" "$id" 2>/dev/null || true)
      [ -n "$current" ] && [ -d "$current" ] || continue
      current_real=$(CDPATH='' cd -- "$current" 2>/dev/null && pwd -P) || continue
      [ "$current_real" = "$worktree_real" ] || continue
      candidate=$id
      candidate_state=$inventory_state
      candidate_count=$((candidate_count + 1))
      if [ "$inventory_state" = "$asserted_state" ] && [ "$id" = "$asserted_task" ]; then
        asserted_candidate_count=$((asserted_candidate_count + 1))
      fi
    done
  done <<FMEOF
$inventory
FMEOF
  [ "$caller_inventory_ok" -eq 1 ] || {
    FM_WORKTREE_OWNER_DETAIL="the calling home is outside the complete local pool inventory"
    return 1
  }
  if [ -n "$asserted_state" ]; then
    [ "$inventory_ok" -eq 1 ] || {
      FM_WORKTREE_OWNER_DETAIL="the asserted legacy owner state is outside the complete local pool inventory"
      return 1
    }
    if [ "$asserted_candidate_count" -ne 1 ]; then
      FM_WORKTREE_OWNER_DETAIL="the asserted legacy owner does not have the single live endpoint currently proving this copy"
      return 1
    fi
    FM_WORKTREE_OWNER_STATE=$asserted_state
    FM_WORKTREE_OWNER_TASK_ID=$asserted_task
    FM_WORKTREE_OWNER_METHOD=asserted-endpoint
    return 0
  fi
  if [ "$candidate_count" -eq 0 ]; then
    FM_WORKTREE_OWNER_DETAIL="the unbound copy at $worktree has no single active task endpoint proving its current physical path"
    return 1
  fi
  if [ "$candidate_count" -ne 1 ] || [ "$claimant_count" -ne 1 ]; then
    FM_WORKTREE_OWNER_DETAIL="the unbound copy at $worktree has multiple active task records claiming its current physical path"
    return 1
  fi
  FM_WORKTREE_OWNER_STATE=$candidate_state
  FM_WORKTREE_OWNER_TASK_ID=$candidate
  FM_WORKTREE_OWNER_METHOD=endpoint
  return 0
}

fm_worktree_owner_bind_resolved_legacy() {  # <worktree>
  local worktree=${1-} expected_state expected_task expected_method
  expected_state=$FM_WORKTREE_OWNER_STATE
  expected_task=$FM_WORKTREE_OWNER_TASK_ID
  expected_method=$FM_WORKTREE_OWNER_METHOD
  case "$expected_method" in
    binding) return 0 ;;
    endpoint|asserted-endpoint) ;;
    *)
      FM_WORKTREE_OWNER_DETAIL="no endpoint-proven legacy owner is available to bind"
      return 1
      ;;
  esac
  if fm_worktree_binding_write "$worktree" "$expected_state" "$expected_task" \
     && fm_worktree_owner_resolve "$worktree" "$expected_state" \
     && [ "$FM_WORKTREE_OWNER_STATE" = "$expected_state" ] \
     && [ "$FM_WORKTREE_OWNER_TASK_ID" = "$expected_task" ] \
     && [ "$FM_WORKTREE_OWNER_METHOD" = binding ]; then
    return 0
  fi
  fm_worktree_binding_clear "$worktree" "$expected_state" "$expected_task" 2>/dev/null || true
  FM_WORKTREE_OWNER_STATE=$expected_state
  FM_WORKTREE_OWNER_TASK_ID=$expected_task
  FM_WORKTREE_OWNER_METHOD=$expected_method
  FM_WORKTREE_OWNER_DETAIL="the endpoint-proven legacy owner could not be durably bound and revalidated"
  return 1
}

# Retire one stale pointer, record-only. The stale worktree= value is KEPT: it is
# the honest history of what the lane was allocated, and bin/fm-backend.sh's
# endpoint validation needs it, so deleting it would make the record permanently
# un-tearable. The added line names the task proven to own the path instead, and
# it is durable, so a failed later step is re-run idempotently.
fm_worktree_owner_retire_pointer() {  # <meta-file> <owner-state> <owner-task-id>
  local meta=${1-} owner_state=${2-} owner=${3-} owner_state_real tmp
  [ -f "$meta" ] || {
    echo "error: no task record at ${meta:-<empty>} to retire a copy pointer in" >&2
    return 1
  }
  fm_worktree_binding_task_id_valid "$owner" || {
    echo "error: refusing to retire a copy pointer to an invalid owning task id" >&2
    return 1
  }
  owner_state_real=$(fm_worktree_binding_state_resolve "$owner_state" 2>/dev/null) || {
    echo "error: refusing to retire a copy pointer to an invalid owning state" >&2
    return 1
  }
  tmp="$meta.forget.$$"
  if ! {
    awk '!/^worktree_retired(_state)?=/' "$meta"
    printf 'worktree_retired_state=%s\n' "$owner_state_real"
    printf 'worktree_retired=%s\n' "$owner"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "error: could not rewrite $meta to retire its stale copy pointer" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$meta"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "error: could not publish the retired copy pointer to $meta" >&2
    return 1
  fi
  return 0
}
