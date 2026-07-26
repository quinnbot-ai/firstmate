#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Each new hold also carries a required
# repo-scoped decision topic, which is the cross-origin identity for one underlying
# captain choice. Repeating `hold` with the same identity is idempotent. A different
# decision key creates a different backlog identity only when its decision topic is
# not already open or resolved in that repository.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> --topic <topic> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh audit
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

task_ids_in_file() {  # <backlog-or-archive-path>
  [ -f "$1" ] || return 0
  awk '/^- \[[ x]\] / { sub(/^- \[[ x]\] /, ""); print $1 }' "$1"
}

# tasks-axi renders a body as one quoted line whose newlines are the literal two
# characters \n, so a topic ends at that escape or at the closing quote. Matching
# the terminator keeps topic `sample` from matching topic `sample.route`.
body_has_topic() {  # <body> <topic>
  case "$1" in
    *"Decision topic: $2."'\n'*|*"Decision topic: $2."'"') return 0 ;;
  esac
  return 1
}

# tasks-axi show reads only the live backlog, so an archived decision has to be
# matched by parsing its archive entry, which keeps the same escaped body text.
archive_topic_hold() {  # <self-id> <repo> <topic>
  local self=$1 repo=$2 topic=$3 path="$DATA/done-archive.md" match
  [ -f "$path" ] || return 1
  match=$(awk -v self="$self" -v repo="$repo" -v topic="$topic" '
    function ends_with(s, suffix) {
      return length(s) >= length(suffix) \
        && substr(s, length(s) - length(suffix) + 1) == suffix
    }
    function flush(  needle) {
      if (found || id == "" || id == self) { reset(); return }
      needle = "Decision topic: " topic "."
      if (index(header, "(kind: captain)") > 0 \
        && index(header, "(repo: " repo ")") > 0 \
        && (index(body, needle "\\n") > 0 || ends_with(body, needle))) {
        print id
        found = 1
      }
      reset()
    }
    function reset() { id = ""; header = ""; body = "" }
    /^- \[[ x]\] / {
      flush()
      header = $0
      line = $0
      sub(/^- \[[ x]\] /, "", line)
      split(line, fields, " ")
      id = fields[1]
      next
    }
    /^  / {
      body = body (body == "" ? "" : "\\n") substr($0, 3)
      next
    }
    { flush() }
    END { flush() }
  ' "$path")
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
}

same_topic_hold() {  # <self-id> <repo> <topic>
  local self=$1 repo=$2 topic=$3 candidate show candidate_repo body
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$self" ] || continue
    show=$(task_show "$candidate") || continue
    [ "$(show_field "$show" kind)" = captain ] || continue
    candidate_repo=$(show_field "$show" repo)
    [ "$candidate_repo" = "$repo" ] || continue
    body=$(show_field "$show" body)
    if body_has_topic "$body" "$topic"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(task_ids_in_file "$DATA/backlog.md")
EOF
  archive_topic_hold "$self" "$repo" "$topic"
}

same_legacy_title_hold() {  # <self-id> <repo> <title>
  local self=$1 repo=$2 title=$3 candidate show candidate_repo body state
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$self" ] || continue
    show=$(task_show "$candidate") || continue
    [ "$(show_field "$show" state)" = queued ] || continue
    [ "$(show_field "$show" held)" = yes ] || continue
    [ "$(show_field "$show" kind)" = captain ] || continue
    [ "$(show_field "$show" hold_kind)" = captain ] || continue
    candidate_repo=$(show_field "$show" repo)
    [ "$candidate_repo" = "$repo" ] || continue
    [ "$(show_field "$show" title)" = "$title" ] || continue
    body=$(show_field "$show" body)
    case "$body" in *"Decision topic: "*) continue ;; esac
    printf '%s\n' "$candidate"
    return 0
  done <<EOF
$(task_ids_in_file "$DATA/backlog.md")
EOF
  return 1
}

reason_records_answer() {  # <hold-reason>
  local reason
  reason=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  printf '%s\n' "$reason" | grep -Eq \
    '(^|[^[:alnum:]])(answer|answered|decision)[[:space:]]*[:=]|captain[[:space:]]+(answered|chose|selected|decided|approved|said)'
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' topic='' repo='' id show state kind existing_title body duplicate
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --topic) shift; topic=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  validate_slug decision-topic "$topic"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
    body=$(show_field "$show" body)
    if [ -n "$body" ] && ! body_has_topic "$body" "$topic"; then
      case "$body" in
        *"Decision topic: "*) fail "existing captain hold $id has a different decision topic" ;;
      esac
    fi
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    if duplicate=$(same_topic_hold "$id" "$repo" "$topic"); then
      if show=$(task_show "$duplicate"); then
        state=$(show_field "$show" state)
      else
        state="done"
      fi
      case "$state" in
        done) fail "captain decision topic $repo/$topic is already resolved as $duplicate; inspect and route that recorded answer instead of minting a duplicate" ;;
        *) fail "captain decision topic $repo/$topic is already tracked as $duplicate; do not mint a duplicate under $origin" ;;
      esac
    elif duplicate=$(same_legacy_title_hold "$id" "$repo" "$title"); then
      fail "possible duplicate captain decision $id shares the exact repository and title of untagged legacy hold $duplicate; inspect that hold and assign its topic before creating another"
    fi
    body=$(printf 'Origin: %s\nDecision key: %s\nDecision topic: %s.\nState: awaiting captain decision.' "$origin" "$key" "$topic")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_audit() {
  local candidate show state held kind hold_kind reason found=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_tasks_axi
  # Only active holds can still be re-asked, so the archive is out of scope.
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    show=$(task_show "$candidate") || continue
    state=$(show_field "$show" state)
    held=$(show_field "$show" held)
    kind=$(show_field "$show" kind)
    hold_kind=$(show_field "$show" hold_kind)
    [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ] || continue
    reason=$(show_field "$show" hold_reason)
    reason_records_answer "$reason" || continue
    printf 'answered-open: %s: %s\n' "$candidate" "$reason"
    found=1
  done <<EOF
$(task_ids_in_file "$DATA/backlog.md")
EOF
  [ "$found" = 1 ] || printf 'answered-open: none\n'
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  audit) shift; command_audit "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
