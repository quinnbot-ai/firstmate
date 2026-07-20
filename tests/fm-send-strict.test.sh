#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-codex}"; exit 0 ;;
      esac
    done
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '\xe2\x94\x82 \xe2\x94\x82\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

make_herdr_unknown_submit_stub() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
count_file=${FM_HERDR_AGENT_GET_COUNT:?}
case "${1:-}:${2:-}" in
  status:--json)
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  pane:get)
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    ;;
  agent:get)
    count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" = 3 ]; then
      exit 1
    fi
    printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    ;;
esac
SH
  chmod +x "$1/herdr"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_explicit_target_requires_live_harness_agent() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit-agent"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home dead-explicit-agent); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_SEND_SETTLE=0 \
    "$SEND" sess:live "must not reach the shell" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send must reject an explicit target whose harness has exited"
  assert_contains "$(cat "$err")" "harness agent is dead" "explicit target refusal should explain the liveness verdict"
  [ ! -s "$log" ] || fail "fm-send typed into an explicit dead agent shell"$'\n'"$(cat "$log")"
  pass "fm-send strict: explicit targets require a live harness agent before typing"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_metadata_target_requires_live_harness_agent() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-agent"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home dead-agent); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/dead-agent.meta" "window=sess:fm-dead-agent" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_SEND_SETTLE=0 \
    "$SEND" dead-agent "must not reach the shell" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send must reject a metadata target whose harness has exited"
  assert_contains "$(cat "$err")" "harness agent is dead" "dead-agent refusal should explain the liveness verdict"
  [ ! -s "$log" ] || fail "fm-send typed into a dead agent's shell"$'\n'"$(cat "$log")"
  pass "fm-send strict: metadata target requires a live harness agent before typing"
}

test_metadata_target_requires_confirmed_harness_agent() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unknown-agent"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unknown-agent); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/unknown-agent.meta" "window=sess:fm-unknown-agent" "kind=ship" "harness=pi"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CURRENT_COMMAND=node FM_SEND_SETTLE=0 \
    "$SEND" unknown-agent "must not reach an indeterminate endpoint" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send must reject a metadata target with indeterminate agent liveness"
  assert_contains "$(cat "$err")" "harness agent is unknown" "unknown-agent refusal should explain the liveness verdict"
  [ ! -s "$log" ] || fail "fm-send typed into an indeterminate endpoint"$'\n'"$(cat "$log")"
  pass "fm-send strict: metadata target requires confirmed harness liveness before typing"
}

test_isolated_codex_python_wrapper_requires_confirmed_agent() {
  local dir fb home err log rc
  dir="$TMP_ROOT/isolated-codex"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home isolated-codex); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/isolated-codex.meta" \
    "window=sess:fm-isolated-codex" "kind=ship" "harness=codex" "codex_crewmate_home=$home/codex-home"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CURRENT_COMMAND=python3 FM_SEND_SETTLE=0 \
    "$SEND" isolated-codex "hello from the coordinator" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send must reject an isolated Codex target when only a generic Python process is observable"
  assert_contains "$(cat "$err")" "harness agent is unknown" "isolated Codex Python refusal should explain the liveness verdict"
  [ ! -s "$log" ] || fail "fm-send typed into an unverified isolated Codex Python process"$'\n'"$(cat "$log")"
  pass "fm-send strict: isolated Codex Python wrappers require confirmed agent liveness"
}

test_herdr_unknown_submit_confirmation_fails() {
  local dir fb home err rc
  dir="$TMP_ROOT/herdr-unknown-submit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); make_herdr_unknown_submit_stub "$fb"
  home=$(setup_home herdr-unknown-submit); err="$dir/send.err"
  : > "$dir/agent-get-count"
  fm_write_meta "$home/state/herdr-submit.meta" \
    "window=default:w1:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_AGENT_GET_COUNT="$dir/agent-get-count" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    "$SEND" herdr-submit "hello captain" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send must fail when Herdr cannot confirm the post-Enter submission"
  assert_contains "$(cat "$err")" "could not be confirmed" "unknown Herdr submit confirmation should report a fail-closed diagnostic"
  pass "fm-send strict: unknown Herdr submit confirmation fails closed"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_explicit_target_requires_live_harness_agent
test_healthy_fm_id_send_still_works
test_metadata_target_requires_live_harness_agent
test_metadata_target_requires_confirmed_harness_agent
test_isolated_codex_python_wrapper_requires_confirmed_agent
test_herdr_unknown_submit_confirmation_fails
