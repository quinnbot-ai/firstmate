#!/usr/bin/env bash
# fm-backend-doctor.sh - read-only runtime-backend readiness diagnostic.
#
# Usage:
#   fm-backend-doctor.sh [--backend <name>]... [--json|--human]
#
# With no --backend, inspect the backend selected for this home by the same
# precedence as a new spawn.  Repeat --backend to inspect exactly those named
# backends instead.  Default output is TOON; --json is the parity
# machine-readable form and --human is a concise operator rendering.
#
# This command is read-only.  It does not acquire locks, write state, launch
# sessions or agents, stop processes, read credentials, or fall back between
# backends.  It reuses the existing backend adapters for dependency, version,
# and control-plane probes wherever they are safe to call without mutation.
#
# Output schema: fm-backend-doctor.v1
# Each backend has one typed status: ready, unavailable, unsupported,
# unreachable, malformed, or partial.  Partial means a safe spawn-time
# provisioner can establish the missing session, or a required secret was
# intentionally not read.  See docs/configuration.md "Runtime backend" for
# backend selection and backend-specific setup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  cat <<'EOF'
usage: fm-backend-doctor.sh [--backend <name>]... [--json|--human]

Read-only readiness diagnostic for Firstmate runtime backends.

Without --backend, inspect the home-selected backend.
Repeat --backend to inspect named backends without changing selection.
Default output is TOON, --json is the stable parity form, and --human is concise.
EOF
}

FORMAT=toon
FORMAT_EXPLICIT=0
REQUESTED_BACKENDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend)
      [ "$#" -gt 1 ] && [ -n "$2" ] || { usage >&2; exit 2; }
      REQUESTED_BACKENDS+=("$2")
      shift 2
      ;;
    --backend=*)
      [ -n "${1#--backend=}" ] || { usage >&2; exit 2; }
      REQUESTED_BACKENDS+=("${1#--backend=}")
      shift
      ;;
    --json)
      [ "$FORMAT_EXPLICIT" -eq 0 ] || { usage >&2; exit 2; }
      FORMAT=json
      FORMAT_EXPLICIT=1
      shift
      ;;
    --human)
      [ "$FORMAT_EXPLICIT" -eq 0 ] || { usage >&2; exit 2; }
      FORMAT=human
      FORMAT_EXPLICIT=1
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || {
  printf 'error: fm-backend-doctor.sh requires node to render structured output\n' >&2
  exit 1
}

# Records use ASCII unit separators so the Node renderer can safely preserve
# shell argument boundaries while normalizing any dependency diagnostic text.
US=$'\037'
RECORDS=()

normalize_scalar() {
  printf '%s' "$1" | tr '\n\r\t\037' '    ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

append_record() {  # <backend> <source> <status> <spawn> <tools> <version> <reachability> <configuration> <next>
  local field row="" first=1
  for field in "$@"; do
    field=$(normalize_scalar "$field")
    if [ "$first" -eq 1 ]; then
      row=$field
      first=0
    else
      row="$row$US$field"
    fi
  done
  RECORDS+=("$row")
}

required_tools_ready() {  # <backend>
  local backend=$1 tool tools
  tools=$(fm_backend_required_tools "$backend") || return 1
  for tool in $tools; do
    fm_backend_required_tool_available "$backend" "$tool" || return 1
  done
  if fm_backend_list_contains "$tools" treehouse; then
    fm_backend_treehouse_lease_capable || return 1
  fi
}

diagnose_tmux() {
  local reach=ready status=ready next='No action required.'
  tmux -V >/dev/null 2>&1 || {
    append_record tmux "$1" unavailable yes ready unavailable not_checked ready 'Repair the tmux installation, then rerun fm-backend-doctor.sh.'
    return
  }
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S' >/dev/null 2>&1 || {
      reach=unreachable
      status=unreachable
      next='Restore access to the current tmux server, then rerun fm-backend-doctor.sh.'
    }
  elif ! tmux has-session -t firstmate 2>/dev/null; then
    reach=provisionable
    status=partial
    next='A spawn will create the detached tmux session; rerun after it exists to confirm reachability.'
  fi
  append_record tmux "$1" "$status" yes ready compatible "$reach" ready "$next"
}

diagnose_herdr() {
  local source=$1 session out running status=ready reach=ready next='No action required.'
  fm_backend_source herdr >/dev/null 2>&1 || {
    append_record herdr "$source" unavailable yes unavailable not_checked not_checked ready 'Repair the Herdr adapter installation, then rerun fm-backend-doctor.sh.'
    return
  }
  fm_backend_herdr_version_check >/dev/null 2>&1 || {
    append_record herdr "$source" unavailable yes ready unavailable not_checked ready 'Install a compatible Herdr client and required tools, then rerun fm-backend-doctor.sh.'
    return
  }
  session=$(fm_backend_herdr_session)
  out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null) || {
    append_record herdr "$source" unreachable yes ready compatible unreachable ready 'Restore access to the configured Herdr session, then rerun fm-backend-doctor.sh.'
    return
  }
  running=$(printf '%s' "$out" | jq -r '.server.running // empty' 2>/dev/null) || running=
  if [ "$running" != true ]; then
    status=partial
    reach=provisionable
    next='A spawn can start the configured Herdr session; rerun after it reports running to confirm reachability.'
  fi
  append_record herdr "$source" "$status" yes ready compatible "$reach" ready "$next"
}

diagnose_zellij() {
  local source=$1 session sessions status=ready reach=ready next='No action required.'
  fm_backend_source zellij >/dev/null 2>&1 || {
    append_record zellij "$source" unavailable yes unavailable not_checked not_checked ready 'Repair the Zellij adapter installation, then rerun fm-backend-doctor.sh.'
    return
  }
  fm_backend_zellij_version_check >/dev/null 2>&1 || {
    append_record zellij "$source" unavailable yes ready unavailable not_checked ready 'Install a compatible Zellij client and required tools, then rerun fm-backend-doctor.sh.'
    return
  }
  session=$(fm_backend_zellij_session)
  sessions=$(zellij list-sessions --short --no-formatting 2>/dev/null) || {
    append_record zellij "$source" unreachable yes ready compatible unreachable ready 'Restore access to the configured Zellij server, then rerun fm-backend-doctor.sh.'
    return
  }
  if ! printf '%s\n' "$sessions" | grep -qxF "$session"; then
    status=partial
    reach=provisionable
    next='A spawn can create the configured Zellij session; rerun after it exists to confirm reachability.'
  fi
  append_record zellij "$source" "$status" yes ready compatible "$reach" ready "$next"
}

diagnose_orca() {
  local source=$1
  fm_backend_source orca >/dev/null 2>&1 || {
    append_record orca "$source" unavailable yes unavailable not_checked not_checked ready 'Repair the Orca adapter installation, then rerun fm-backend-doctor.sh.'
    return
  }
  fm_backend_orca_tool_check >/dev/null 2>&1 || {
    append_record orca "$source" unavailable yes unavailable unavailable not_checked ready 'Install the Orca CLI, then rerun fm-backend-doctor.sh.'
    return
  }
  fm_backend_orca_runtime_check >/dev/null 2>&1 || {
    append_record orca "$source" unreachable yes ready not_applicable unreachable ready 'Start or repair the Orca runtime, then rerun fm-backend-doctor.sh.'
    return
  }
  append_record orca "$source" ready yes ready not_applicable ready ready 'No action required.'
}

diagnose_cmux() {
  local source=$1 ping
  fm_backend_source cmux >/dev/null 2>&1 || {
    append_record cmux "$source" unavailable yes unavailable not_checked not_checked ready 'Repair the cmux adapter installation, then rerun fm-backend-doctor.sh.'
    return
  }
  fm_backend_cmux_version_check >/dev/null 2>&1 || {
    append_record cmux "$source" unavailable yes ready unavailable not_checked ready 'Install a compatible cmux client and required tools, then rerun fm-backend-doctor.sh.'
    return
  }
  ping=$(fm_backend_cmux_ping_state_without_credentials) || ping=error
  case "$ping" in
    ok)
      append_record cmux "$source" ready yes ready compatible ready ready 'No action required.'
      ;;
    unauth)
      append_record cmux "$source" partial yes ready compatible unauthenticated secret_not_inspected 'Provide the configured cmux socket credential through the normal spawn path, then rerun fm-backend-doctor.sh.'
      ;;
    denied)
      append_record cmux "$source" unreachable yes ready compatible denied ready 'Allow Firstmate to reach the cmux control socket, then rerun fm-backend-doctor.sh.'
      ;;
    down|error)
      append_record cmux "$source" unreachable yes ready compatible "$ping" ready 'Start cmux and make its control socket reachable, then rerun fm-backend-doctor.sh.'
      ;;
  esac
}

diagnose_backend() {  # <backend> <source>
  local backend=$1 source=$2
  if ! fm_backend_is_known "$backend"; then
    if [ "$source" = env ] || [ "$source" = config ]; then
      append_record "$backend" "$source" malformed unknown not_checked not_checked not_checked malformed 'Set the selected backend to a supported value, then rerun fm-backend-doctor.sh.'
    else
      append_record "$backend" "$source" unsupported no not_checked not_checked not_checked ready 'Select a supported runtime backend, then rerun fm-backend-doctor.sh.'
    fi
    return
  fi
  if ! fm_backend_validate_spawn "$backend" >/dev/null 2>&1; then
    append_record "$backend" "$source" unsupported no not_checked not_checked not_checked ready 'Select a spawn-capable runtime backend, then rerun fm-backend-doctor.sh.'
    return
  fi
  if ! required_tools_ready "$backend"; then
    append_record "$backend" "$source" unavailable yes unavailable not_checked not_checked ready 'Install the backend-required tools and compatibility support, then rerun fm-backend-doctor.sh.'
    return
  fi
  case "$backend" in
    tmux) diagnose_tmux "$source" ;;
    herdr) diagnose_herdr "$source" ;;
    zellij) diagnose_zellij "$source" ;;
    orca) diagnose_orca "$source" ;;
    cmux) diagnose_cmux "$source" ;;
  esac
}

if [ "${#REQUESTED_BACKENDS[@]}" -eq 0 ]; then
  fm_backend_selection || exit 1
  diagnose_backend "$FM_BACKEND_SELECTION_VALUE" "$FM_BACKEND_SELECTION_SOURCE"
else
  for backend in "${REQUESTED_BACKENDS[@]}"; do
    diagnose_backend "$backend" explicit
  done
fi

node - "$FORMAT" "${RECORDS[@]}" <<'NODE'
const format = process.argv[2];
const fields = ["backend", "source", "status", "spawn_capable", "tools", "version", "reachability", "configuration", "next_action"];
const rows = process.argv.slice(3).map((record) => {
  const values = record.split("\x1f");
  return Object.fromEntries(fields.map((field, index) => [field, values[index] || ""]));
});
const model = { schema: "fm-backend-doctor.v1", backends: rows };
if (format === "json") {
  process.stdout.write(`${JSON.stringify(model, null, 2)}\n`);
} else if (format === "human") {
  for (const row of rows) {
    process.stdout.write(`${row.backend}: ${row.status} (spawn=${row.spawn_capable}; tools=${row.tools}; version=${row.version}; reachability=${row.reachability})\n`);
    process.stdout.write(`  next: ${row.next_action}\n`);
  }
} else {
  const quote = (value) => JSON.stringify(String(value));
  process.stdout.write(`schema: ${quote(model.schema)}\n`);
  process.stdout.write(`backends[${rows.length}]{${fields.join(",")}:\n`);
  for (const row of rows) {
    process.stdout.write(`${fields.map((field) => quote(row[field])).join(",")}\n`);
  }
}
NODE
