#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, including resolved records
# retained in the configured Done archive after pruning, records completion
# attestation in the originating task's metadata, and closes a hold only after a
# durable decision record has been linked to existing dependent work.
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
# A resolved hold pruned from the live backlog is proved from the configured Done
# archive. When a pre-archive legacy resolution is absent from both the live
# backlog and that archive, its originating keyed status resolution, or a
# decision artifact that names that exact hold identity or decision key, remains
# a compatibility fallback until that record can be migrated to the archive.
# Evidence that names no hold never verifies a decision.
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

# A body is one escaped line whose newlines are the literal two characters \n, in
# both `tasks-axi show` output and the backlog file. A topic therefore ends at that
# escape, at the closing quote show adds, or at end of body. Matching the
# terminator keeps topic `sample` from matching topic `sample.route`.
body_has_topic() {  # <body> <topic>
  local needle="Decision topic: $2."
  case "$1" in
    *"$needle"'\n'*|*"$needle"'"'|*"$needle") return 0 ;;
  esac
  return 1
}

# The resolution record replaces the whole hold body, so the topic must survive
# into it or an answered decision would become invisible to the duplicate guard
# once it leaves the live backlog.
body_topic() {  # <body>
  local rest=$1
  case "$rest" in
    *"Decision topic: "*) rest=${rest#*"Decision topic: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%\"}
  rest=${rest%.}
  [ -n "$rest" ] || return 1
  printf '%s\n' "$rest"
}

# The backlog and the archive share one entry format that already carries every
# field these scans filter on, so a single awk pass replaces one `tasks-axi show`
# subprocess per entry. `tasks-axi show` reads only the live backlog anyway, so
# this is also the only way to see archived decisions. It stays the authority for
# the free-text title and hold reason, which are re-read for surviving candidates
# alone. Fields are id, state, kind, repo, held, hold_kind, body. Tab is IFS
# whitespace, so consecutive tabs would collapse and shift every later field left;
# every field except the trailing body therefore emits `-` when it is absent.
#
# The row, metadata-group, and body grammar mirrors `row_match`, `structured_row`,
# and `metadata` in bin/fm-fleet-snapshot.sh, which is the canonical backlog parser:
# a key opens a group with `(` or continues one after `, `, its value ends at the
# next `,` or `)`, ids may be bulleted with `-` or `*` and written as `**id**` or
# behind a `[ ]`/`[x]`/`[X]` marker, and any indented line continues the record.
# A blank line inside a body is part of that body rather than the end of the
# record, so a resolution record whose captain decision follows an empty line stays
# whole. Requiring `(` or `, ` immediately before the key is also what keeps
# `hold-kind` from being read as `kind`.
scan_hold_entries() {  # <backlog-or-archive-path>
  [ -f "$1" ] || return 0
  awk '
    function reset() {
      id = ""; state = "-"; kind = "-"; repo = "-"; held = "no"; hold_kind = "-"
      body = ""; body_lines = 0; pending_blanks = 0
    }
    function trim_ws(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function group_re(key) {
      return "(\\(|,[[:space:]]*)" key ":"
    }
    function has_group(line, key) {
      return match(line, group_re(key)) > 0
    }
    function last_group(line, key,   re, rest, out) {
      re = group_re(key) "[[:space:]]*"
      out = ""
      rest = line
      while (match(rest, re)) {
        rest = substr(rest, RSTART + RLENGTH)
        if (match(rest, /[,)]/)) out = substr(rest, 1, RSTART - 1)
        else out = rest
        out = trim_ws(out)
      }
      return out
    }
    function row_id(line,   s) {
      if (line ~ /^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+/) {
        s = line
        sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", s)
        sub(/[[:space:]].*$/, "", s)
        return s
      }
      if (line ~ /^[-*][[:space:]]+\*\*[^*]+\*\*[[:space:]]+-[[:space:]]+/) {
        s = line
        sub(/^[-*][[:space:]]+\*\*/, "", s)
        sub(/\*\*.*$/, "", s)
        return trim_ws(s)
      }
      return ""
    }
    function add_body(text) {
      body = body (body_lines == 0 ? "" : "\\n") text
      body_lines++
    }
    function emit() {
      if (id != "") {
        print id "\t" state "\t" kind "\t" repo "\t" held "\t" hold_kind "\t" body
      }
      reset()
    }
    BEGIN { reset(); section = "" }
    {
      if ($0 ~ /^##[[:space:]]/) {
        emit()
        if ($0 ~ /^##[[:space:]]+In flight/) section = "in_flight"
        else if ($0 ~ /^##[[:space:]]+Queued/) section = "queued"
        else if ($0 ~ /^##[[:space:]]+Done/ || $0 ~ /^##[[:space:]]+Archived/) section = "done"
        else section = ""
        next
      }
      rid = row_id($0)
      if (rid != "") {
        emit()
        id = rid
        state = section
        if (state == "") state = "-"
        kind = last_group($0, "kind")
        if (kind == "") kind = "-"
        repo = last_group($0, "repo")
        if (repo == "") repo = "-"
        hold_kind = last_group($0, "hold-kind")
        if (hold_kind == "") hold_kind = "-"
        held = has_group($0, "hold") ? "yes" : "no"
        next
      }
      if ($0 ~ /^[[:space:]]*$/) {
        # Held back rather than appended, so trailing separator blank lines before
        # the next section never grow the body they do not belong to.
        if (id != "") pending_blanks++
        next
      }
      if ($0 ~ /^[[:space:]]/) {
        if (id == "") next
        while (pending_blanks > 0) { add_body(""); pending_blanks-- }
        line = $0
        if (substr(line, 1, 2) == "  ") line = substr(line, 3)
        else sub(/^[[:space:]]+/, "", line)
        add_body(line)
        next
      }
      emit()
    }
    END { emit() }
  ' "$1"
}

# Both scanners are consulted only once the identity itself is absent from the
# live backlog, so a candidate that carries the new hold's own id can only be an
# archived record of the same decision, and refusing it is always correct.
same_topic_hold() {  # <repo> <topic>
  local repo=$1 topic=$2 path cid _cstate ckind crepo _cheld _chold_kind cbody
  for path in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    while IFS=$'\t' read -r cid _cstate ckind crepo _cheld _chold_kind cbody; do
      [ -n "$cid" ] || continue
      [ "$ckind" = captain ] || continue
      [ "$crepo" = "$repo" ] || continue
      if body_has_topic "$cbody" "$topic"; then
        printf '%s\n' "$cid"
        return 0
      fi
    done <<EOF
$(scan_hold_entries "$path")
EOF
  done
  return 1
}

same_legacy_title_hold() {  # <repo> <title>
  local repo=$1 title=$2 cid cstate ckind crepo cheld chold_kind cbody show
  while IFS=$'\t' read -r cid cstate ckind crepo cheld chold_kind cbody; do
    [ -n "$cid" ] || continue
    [ "$cstate" = queued ] || continue
    [ "$cheld" = yes ] || continue
    [ "$ckind" = captain ] || continue
    [ "$chold_kind" = captain ] || continue
    [ "$crepo" = "$repo" ] || continue
    case "$cbody" in *"Decision topic: "*) continue ;; esac
    show=$(task_show "$cid") || continue
    [ "$(show_field "$show" title)" = "$title" ] || continue
    printf '%s\n' "$cid"
    return 0
  done <<EOF
$(scan_hold_entries "$DATA/backlog.md")
EOF
  return 1
}

# A marker must be the past-tense `answered` form and must carry a value, because
# a pending question labels itself just as naturally as `decision: north or
# coastal` or `captain answer: needed`, and a recurring false flag would train the
# reader to skim the one section that exists to stop a re-ask.
reason_records_answer() {  # <hold-reason>
  local reason
  reason=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  printf '%s\n' "$reason" | grep -Eq \
    '(^|[^[:alnum:]])answered[[:space:]]*[:=][[:space:]]*[^[:space:]]|captain[[:space:]]+(answered|chose|selected|decided|approved|said)'
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
  local id=$1 show
  show=$(task_show "$id") || return 1
  hold_show_is_resolved "$show"
}

hold_show_is_resolved() {  # <tasks-axi-show-output>
  local show=$1 state kind body
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

text_has_key_token() {  # <text> <decision-key>
  local key=$2
  awk -v key="$key" '
    function boundary(c) { return c == "" || c !~ /[A-Za-z0-9]/ }
    {
      line = $0
      start = 1
      while ((pos = index(substr(line, start), key)) > 0) {
        at = start + pos - 1
        if (boundary(at == 1 ? "" : substr(line, at - 1, 1)) &&
          boundary(substr(line, at + length(key), 1))) {
          found = 1
          exit
        }
        start = at + 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<EOF
$1
EOF
}

# A pre-archive artifact is evidence only for the exact hold it names, so one
# resolved decision can never stand in for a different unrecorded decision.
decision_artifact_evidence() {  # <origin-id> <decision-key> <hold-id>
  local origin=$1 key=$2 id=$3 dir artifact base
  dir="$DATA/$origin"
  [ -d "$dir" ] || return 1
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    base=${artifact##*/}
    case "$base" in
      *"$id"*) return 0 ;;
    esac
    text_has_key_token "$base" "$key" && return 0
    grep -F -q -e "$id" -e "[key=$key]" "$artifact" 2>/dev/null && return 0
  done <<EOF
$(find "$dir" -type f \( -iname '*decision*' -o -iname '*resolution*' \) 2>/dev/null || true)
EOF
  return 1
}

same_task_resolution_evidence() {  # <origin-id> <decision-key> <hold-id>
  local origin=$1 key=$2 id=$3 status_file
  status_file="$STATE/$origin.status"
  if [ -f "$status_file" ] && awk -v id="$id" -v key="$key" '
    $0 == "resolved: " id || index($0, "resolved: " id " -> ") == 1 { found = 1 }
    index($0, "resolved [key=" key "]:") == 1 { found = 1 }
    key == "default" && index($0, "resolved:") == 1 { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$status_file"; then
    return 0
  fi
  decision_artifact_evidence "$origin" "$key" "$id"
}

verify_hold_durable() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 id show archive_show state held kind hold_kind
  id=$(hold_id "$origin" "$key")
  if ! show=$(task_show "$id"); then
    if archive_show=$(fm_tasks_axi_archive_show "$FM_HOME" "$id"); then
      hold_show_is_resolved "$archive_show" \
        || fail "archived captain decision $id is not durably resolved"
      return 0
    fi
    if same_task_resolution_evidence "$origin" "$key" "$id"; then
      return 0
    fi
    fail "captain decision $id is absent from the live backlog and authoritative archive"
  fi
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if hold_show_is_resolved "$show"; then
    return 0
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
    if duplicate=$(same_topic_hold "$repo" "$topic"); then
      if show=$(task_show "$duplicate"); then
        state=$(show_field "$show" state)
      else
        state="done"
      fi
      case "$state" in
        done) fail "captain decision topic $repo/$topic is already resolved as $duplicate; inspect and route that recorded answer instead of minting a duplicate" ;;
        *) fail "captain decision topic $repo/$topic is already tracked as $duplicate; do not mint a duplicate under $origin" ;;
      esac
    elif duplicate=$(same_legacy_title_hold "$repo" "$title"); then
      fail "possible duplicate captain decision $id shares the exact repository and title of untagged legacy hold $duplicate; if it is the same decision, route $duplicate after adding a 'Decision topic: $topic.' line to its body with tasks-axi update, and otherwise give this decision a title that distinguishes it"
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
  local cid cstate ckind _crepo cheld chold_kind _cbody show reason found=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_tasks_axi
  # Only active holds can still be re-asked, so the archive is out of scope.
  while IFS=$'\t' read -r cid cstate ckind _crepo cheld chold_kind _cbody; do
    [ -n "$cid" ] || continue
    [ "$cstate" = queued ] && [ "$cheld" = yes ] && [ "$ckind" = captain ] && [ "$chold_kind" = captain ] || continue
    show=$(task_show "$cid") || continue
    reason=$(show_field "$show" hold_reason)
    reason_records_answer "$reason" || continue
    printf 'answered-open: %s: %s\n' "$cid" "$reason"
    found=1
  done <<EOF
$(scan_hold_entries "$DATA/backlog.md")
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
      verify_hold_durable "$origin" "$key"
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
      verify_hold_durable "$origin" "$key"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$origin" "$key"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body topic topic_line='' resolution_recorded=0
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

  topic=$(body_topic "$hold_body") || topic=''
  [ -z "$topic" ] || topic_line="Decision topic: ${topic}."$'\n'
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n%s\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$topic_line" "$decision")
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
