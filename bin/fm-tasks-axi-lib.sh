# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff, plus the exact-id reader for records
# the configured Done archive retains after retention pruning.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

# Print a completed archived task in the field shape consumed by callers' existing
# tasks-axi `show --full` parsers.
#
# tasks-axi deliberately has no archive-read command.
# Its markdown archive is the authoritative retained record after Done pruning,
# so this exact-id reader is the supported firstmate read path for that surface.
# It reads the active home's configured markdown archive and returns nonzero when
# the configuration, archive, or requested record is absent.
fm_tasks_axi_archive_show() {  # <home> <id>
  local home=$1 wanted=$2 config archive
  [ -n "$wanted" ] || return 1
  config="$home/.tasks.toml"
  [ -f "$config" ] || return 1
  archive=$(awk '
    /^\[markdown\][[:space:]]*$/ { markdown = 1; next }
    /^\[/ { markdown = 0 }
    markdown && /^[[:space:]]*archive[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*archive[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*(#.*)?$/, "", value)
      if (value ~ /^".*"$/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
      }
      print value
      exit
    }
  ' "$config")
  [ -n "$archive" ] || return 1
  case "$archive" in
    /*) ;;
    *) archive="$home/$archive" ;;
  esac
  [ -f "$archive" ] || return 1

  awk -v wanted="$wanted" '
    function group_value(line, key,   needle, rest, end, value) {
      needle = "(" key ": "
      rest = line
      while (index(rest, needle) > 0) {
        rest = substr(rest, index(rest, needle) + length(needle))
        end = index(rest, ")")
        if (end > 0) value = substr(rest, 1, end - 1)
      }
      return value
    }
    function emit() {
      if (id == wanted) {
        printf "task:\n  id: %s\n  state: done\n  kind: %s\n  body: %s\n", id, kind, body
        found = 1
      }
      id = ""
      kind = "-"
      body = ""
    }
    /^## Archived/ { emit(); archived = 1; next }
    /^## / { emit(); archived = 0; next }
    archived && /^- \[x\] / {
      emit()
      line = $0
      sub(/^- \[x\] /, "", line)
      split(line, fields, " - ")
      id = fields[1]
      kind = group_value($0, "kind")
      if (kind == "") kind = "-"
      next
    }
    archived && id != "" && /^  / {
      body = body (body == "" ? "" : "\\n") substr($0, 3)
      next
    }
    archived && id != "" && /^$/ {
      body = body "\\n"
      next
    }
    archived { emit() }
    END { emit(); exit(found ? 0 : 1) }
  ' "$archive"
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
