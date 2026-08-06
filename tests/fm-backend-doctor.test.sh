#!/usr/bin/env bash
# tests/fm-backend-doctor.test.sh - fixture-driven read-only backend doctor
# contract coverage.  The fakes model only non-mutating version and
# control-plane probes, then record every invocation so this suite can prove
# the doctor did not take a spawn, lifecycle, or state-writing path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-doctor)
NODE_BIN=$(dirname "$(command -v node)")

setup_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKE_BIN="$CASE/fakebin"
  LOG="$CASE/commands.log"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$FAKE_BIN"
  printf 'unchanged\n' > "$HOME_DIR/state/sentinel"

  cat > "$FAKE_BIN/treehouse" <<'SH'
#!/bin/sh
printf 'treehouse %s\n' "$*" >> "${FM_DOCTOR_LOG:?}"
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf 'usage: treehouse get --lease\n'
fi
SH
  cat > "$FAKE_BIN/tmux" <<'SH'
#!/bin/sh
printf 'tmux %s\n' "$*" >> "${FM_DOCTOR_LOG:?}"
case "${1:-}" in
  -V) printf 'tmux 3.5\n' ;;
  has-session) [ "${FM_FAKE_TMUX_SESSION:-present}" = present ] ;;
  display-message) [ "${FM_FAKE_TMUX_CURRENT:-reachable}" = reachable ] && printf 'firstmate\n' ;;
esac
SH
  cat > "$FAKE_BIN/herdr" <<'SH'
#!/bin/sh
printf 'herdr %s\n' "$*" >> "${FM_DOCTOR_LOG:?}"
case " $* " in
  *' status --json '*)
    [ -z "${HERDR_SESSION:-}" ] || [ "${FM_FAKE_HERDR_REACHABLE:-yes}" = yes ] || exit 1
    printf '{"client":{"protocol":14,"version":"0.7.1"},"server":{"running":%s}}\n' "${FM_FAKE_HERDR_RUNNING:-true}"
    ;;
  *) printf 'herdr %s\n' "${FM_FAKE_HERDR_VERSION:-0.7.1}" ;;
esac
SH
  cat > "$FAKE_BIN/zellij" <<'SH'
#!/bin/sh
printf 'zellij %s\n' "$*" >> "${FM_DOCTOR_LOG:?}"
case "${1:-}" in
  --version) printf 'zellij %s\n' "${FM_FAKE_ZELLIJ_VERSION:-0.44.2}" ;;
  list-sessions)
    [ "${FM_FAKE_ZELLIJ_REACHABLE:-yes}" = yes ] || exit 1
    [ "${FM_FAKE_ZELLIJ_SESSION:-missing}" = present ] && printf '%s\n' "${FM_ZELLIJ_SESSION:-firstmate}"
    exit 0
    ;;
esac
SH
  cat > "$FAKE_BIN/orca" <<'SH'
#!/bin/sh
printf 'orca %s\n' "$*" >> "${FM_DOCTOR_LOG:?}"
case "${1:-}" in
  status)
    [ "${FM_FAKE_ORCA_READY:-yes}" = yes ] || exit 1
    printf '{"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    ;;
esac
SH
  cat > "$FAKE_BIN/cmux" <<'SH'
#!/bin/sh
printf 'cmux %s password=%s\n' "$*" "${CMUX_SOCKET_PASSWORD:+set}" >> "${FM_DOCTOR_LOG:?}"
case "${1:-}" in
  version) printf 'cmux %s\n' "${FM_FAKE_CMUX_VERSION:-0.64.17}" ;;
  ping)
    printf '%s\n' "${FM_FAKE_CMUX_PING:-PONG}"
    ;;
esac
SH
  cat > "$FAKE_BIN/jq" <<'SH'
#!/bin/sh
expr=$*
case "$expr" in
  *'.client.protocol'*) printf '%s\n' "${FM_FAKE_HERDR_PROTOCOL:-14}" ;;
  *'.client.version'*) printf '%s\n' "${FM_FAKE_HERDR_CLIENT_VERSION:-0.7.1}" ;;
  *'.server.running'*) printf '%s\n' "${FM_FAKE_HERDR_RUNNING:-true}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKE_BIN"/*
}

run_doctor() {  # <output-file> <doctor args...>
  local output=$1
  shift
  PATH="$FAKE_BIN:$NODE_BIN:/usr/bin:/bin" \
    FM_HOME="$HOME_DIR" \
    FM_DOCTOR_LOG="$LOG" \
    "$ROOT/bin/fm-backend-doctor.sh" "$@" > "$output"
}

assert_status() {  # <json-file> <backend> <status>
  local out=$1 backend=$2 status=$3
  node - "$out" "$backend" "$status" <<'NODE' || fail "doctor should classify $backend as $status"
const [file, backend, status] = process.argv.slice(2);
const result = JSON.parse(require("fs").readFileSync(file, "utf8"));
process.exit(result.backends.some((row) => row.backend === backend && row.status === status) ? 0 : 1);
NODE
}

test_all_typed_outcomes_and_multiple_backends() {
  local out="$CASE/out.json"
  printf 'local-secret\n' > "$HOME_DIR/config/cmux-socket-password"
  export FM_FAKE_TMUX_SESSION=present
  export FM_FAKE_HERDR_REACHABLE=no
  export FM_FAKE_ZELLIJ_SESSION=missing
  export FM_FAKE_CMUX_PING='Authentication required'
  export CMUX_SOCKET_PASSWORD=ambient-secret
  run_doctor "$out" --json --backend tmux --backend herdr --backend zellij --backend orca --backend cmux --backend unknown
  unset FM_FAKE_TMUX_SESSION FM_FAKE_HERDR_REACHABLE FM_FAKE_ZELLIJ_SESSION FM_FAKE_CMUX_PING CMUX_SOCKET_PASSWORD

  assert_status "$out" tmux ready
  assert_status "$out" herdr unreachable
  assert_status "$out" zellij partial
  assert_status "$out" orca ready
  assert_status "$out" cmux partial
  assert_status "$out" unknown unsupported
  assert_grep '"configuration": "secret_not_inspected"' "$out" 'cmux credentials should remain intentionally uninspected'
  assert_no_grep 'password=set' "$LOG" 'doctor must not forward an ambient cmux credential'
  assert_no_grep spawn "$LOG" 'doctor must not spawn a runtime endpoint'
  assert_no_grep new-session "$LOG" 'doctor must not create a session'
  assert_no_grep create "$LOG" 'doctor must not create a runtime resource'
  assert_no_grep kill "$LOG" 'doctor must not stop a runtime endpoint'
  assert_no_grep stop "$LOG" 'doctor must not stop a runtime endpoint'
  assert_grep 'unchanged' "$HOME_DIR/state/sentinel" 'doctor must leave state files unchanged'
  [ "$(find "$HOME_DIR/state" -type f | wc -l | tr -d ' ')" = 1 ] || fail 'doctor must not add runtime state files'
  pass 'doctor reports all primary typed outcomes across multiple backends without mutation'
}

test_malformed_config_and_stable_rendering() {
  local first="$CASE/first.toon" second="$CASE/second.toon" human="$CASE/human"
  printf 'not-a-backend\n' > "$HOME_DIR/config/backend"
  run_doctor "$first"
  run_doctor "$second"
  cmp -s "$first" "$second" || fail 'default machine-readable output must be stable'
  assert_contains "$(<"$first")" '"not-a-backend","config","malformed"' 'configured invalid backend should be malformed'
  run_doctor "$human" --human --backend unknown
  assert_contains "$(<"$human")" 'unknown: unsupported' 'human output should be concise and typed'
  pass 'doctor preserves malformed selection and stable output'
}

test_absent_optional_tool_and_unreachable_session() {
  local out="$CASE/out.json" mini="$CASE/minimal-bin"
  mkdir -p "$mini"
  ln -s /usr/bin/dirname "$mini/dirname"
  ln -s /usr/bin/tr "$mini/tr"
  ln -s /usr/bin/sed "$mini/sed"
  ln -s /usr/bin/grep "$mini/grep"
  ln -s /usr/bin/awk "$mini/awk"
  ln -s /usr/bin/env "$mini/env"
  rm "$FAKE_BIN/jq"
  PATH="$FAKE_BIN:$NODE_BIN:$mini:/bin" \
    FM_HOME="$HOME_DIR" \
    FM_DOCTOR_LOG="$LOG" \
    "$ROOT/bin/fm-backend-doctor.sh" --json --backend zellij > "$out"
  assert_status "$out" zellij unavailable
  assert_contains "$(<"$out")" '"tools": "unavailable"' 'absent optional jq should be explicit'

  export FM_FAKE_ZELLIJ_REACHABLE=no
  run_doctor "$out" --json --backend zellij
  assert_status "$out" zellij unreachable
  unset FM_FAKE_ZELLIJ_REACHABLE

  export FM_FAKE_ZELLIJ_VERSION=0.43.9
  run_doctor "$out" --json --backend zellij
  assert_status "$out" zellij unavailable
  assert_contains "$(<"$out")" '"version": "unavailable"' 'an incompatible adapter version should be explicit'
  unset FM_FAKE_ZELLIJ_VERSION
  pass 'doctor distinguishes an absent optional tool from an unreachable session'
}

setup_case typed
test_all_typed_outcomes_and_multiple_backends
setup_case malformed
test_malformed_config_and_stable_rendering
setup_case unavailable
test_absent_optional_tool_and_unreachable_session
