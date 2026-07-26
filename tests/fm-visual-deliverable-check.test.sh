#!/usr/bin/env bash
# Tests for the rendered visual deliverable usability check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-visual-deliverable-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-visual-deliverable-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

EVAL_LOG="$TMP_ROOT/eval.invocation"

make_browser() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  open)
    if [ -n "${FM_VISUAL_CHECK_STATE_LOG:-}" ] && [ -n "${HOME:-}" ]; then
      state_dir="$HOME/.chrome-devtools-axi/sessions/${CHROME_DEVTOOLS_AXI_SESSION:-default}"
      mkdir -p "$state_dir"
      printf '%s\n' "$$" > "$state_dir/bridge.pid"
      printf '%s\n' "$state_dir" > "$FM_VISUAL_CHECK_STATE_LOG"
    fi
    printf 'page opened\n'
    ;;
  eval)
    if [ -n "${FM_VISUAL_CHECK_EVAL_LOG:-}" ]; then
      printf 'argv: %s\nsession: %s\nport: %s\n' \
        "$*" "${CHROME_DEVTOOLS_AXI_SESSION:-unset}" "${CHROME_DEVTOOLS_AXI_PORT:-unset}" \
        > "$FM_VISUAL_CHECK_EVAL_LOG"
    fi
    cat "${FM_VISUAL_CHECK_RESULT:?}"
    ;;
  stop) printf 'bridge stopped\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$path"
}

encode_result() {  # <encoding-depth> <json-array>
  node -e '
let text = process.argv[2];
for (let depth = 0; depth < Number(process.argv[1]); depth += 1) text = JSON.stringify(text);
console.log(`result: ${text}`);
' "$1" "$2"
}

# The bridge serializes the probe's returned array and then escapes that string
# once more, so a real result needs two parses.
write_result() {  # <path> <json-array>
  local path=$1 result=$2
  encode_result 1 "$result" > "$path"
}

write_doubly_encoded_result() {  # <path> <json-array>
  local path=$1 result=$2
  encode_result 2 "$result" > "$path"
}

run_check() {  # <result-file> <source>...
  local result=$1
  shift
  local -a args
  args=(https://visual.example.test)
  for source in "$@"; do
    args+=(--source "$source")
  done
  CHROME_DEVTOOLS_AXI_SESSION=crewmate-in-flight CHROME_DEVTOOLS_AXI_PORT=9224 \
    HOME="${FM_TEST_HOME:-$HOME}" \
    FM_VISUAL_CHECK_BROWSER="$TMP_ROOT/browser" FM_VISUAL_CHECK_RESULT="$result" \
    FM_VISUAL_CHECK_EVAL_LOG="$EVAL_LOG" \
    FM_VISUAL_CHECK_STATE_LOG="${FM_TEST_STATE_LOG:-}" "$CHECK" "${args[@]}"
}

make_browser "$TMP_ROOT/browser"

test_zero_height_audio_fails() {
  local source="$TMP_ROOT/zero-height.html" result="$TMP_ROOT/zero-height.result" out rc
  printf '<style>audio { width: 318px; }</style>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":0,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 1 "$rc" "zero-height audio must fail"
  assert_contains "$out" 'audio#bed: rendered dimensions are 318x0' "zero-height audio failure was not reported"
  pass "visual deliverable check rejects a rendered zero-height audio control"
}

test_hidden_interactive_control_fails() {
  local source="$TMP_ROOT/hidden.html" result="$TMP_ROOT/hidden.result" out rc
  printf '<button>Continue</button>\n' > "$source"
  write_result "$result" '[{"label":"button#continue","width":120,"height":40,"clientRects":1,"hiddenBy":"its computed style","interactive":true,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 1 "$rc" "hidden button must fail"
  assert_contains "$out" 'button#continue: hidden by its computed style' "hidden button failure was not reported"
  pass "visual deliverable check rejects a CSS-hidden interactive control"
}

test_audio_auto_height_reset_fails() {
  local source="$TMP_ROOT/reset.css" result="$TMP_ROOT/reset.result" out rc
  printf 'video,audio,img{max-width:100%%;height:auto}\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":54,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 1 "$rc" "audio height:auto reset must fail even if current rendering has height"
  assert_contains "$out" 'selector "video,audio,img" gives audio height:auto' "audio reset failure was not reported"
  pass "visual deliverable check enforces the audio reset rule"
}

test_usable_elements_pass() {
  local source="$TMP_ROOT/usable.html" result="$TMP_ROOT/usable.result" out
  printf '<style>audio { width: 318px; min-height: 54px; }</style>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":54,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto"},{"label":"button#continue","width":120,"height":40,"clientRects":1,"hiddenBy":"","interactive":true,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source")
  assert_contains "$out" 'ok - rendered media and interactive elements have usable dimensions and visibility' "usable elements did not pass"
  pass "visual deliverable check accepts visible nonzero media and controls"
}

test_zero_matched_elements_fails() {
  local source="$TMP_ROOT/empty.html" result="$TMP_ROOT/empty.result" out rc
  printf '<style>audio { width: 318px; }</style>\n' > "$source"
  write_result "$result" '[]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 1 "$rc" "a render with nothing to measure must fail"
  assert_contains "$out" 'no media or interactive element was found in the rendered page' "zero matches were not reported as a distinct failure"
  assert_not_contains "$out" 'ok - rendered media' "zero matches passed as a no-op"
  pass "visual deliverable check fails loudly when no element could be measured"
}

test_marked_hidden_control_is_exempt() {
  local source="$TMP_ROOT/marked.html" result="$TMP_ROOT/marked.result" out rc
  printf '<audio controls></audio>\n<button data-fm-visual-check="intentionally-hidden">Later</button>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":54,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto","exempt":false},{"label":"button#later","width":0,"height":0,"clientRects":0,"hiddenBy":"an ancestor'"'"'s computed style","interactive":true,"disabled":false,"pointerEvents":"none","exempt":true}]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 0 "$rc" "an explicitly marked hidden control must not fail the check"
  assert_contains "$out" 'note - button#later: presentation findings waived by the data-fm-visual-check=intentionally-hidden marker' "the waiver was applied silently"
  assert_contains "$out" 'ok - rendered media and interactive elements have usable dimensions and visibility' "marked exemption did not pass"
  pass "visual deliverable check exempts one explicitly marked hidden control and reports the waiver"
}

test_every_element_marked_still_fails() {
  local source="$TMP_ROOT/all-marked.html" result="$TMP_ROOT/all-marked.result" out rc
  printf '<button data-fm-visual-check="intentionally-hidden">Later</button>\n' > "$source"
  write_result "$result" '[{"label":"button#later","width":0,"height":0,"clientRects":0,"hiddenBy":"its computed style","interactive":true,"disabled":false,"pointerEvents":"none","exempt":true}]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 1 "$rc" "marking every element must not suppress the whole gate"
  assert_contains "$out" 'every matched element carries the data-fm-visual-check=intentionally-hidden marker' "blanket marking was not rejected"
  pass "visual deliverable check rejects a render whose every element is marked"
}

test_render_probe_is_isolated_and_untruncated() {
  local source="$TMP_ROOT/probe.html" result="$TMP_ROOT/probe.result" log
  printf '<audio controls></audio>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":54,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto","exempt":false}]'
  run_check "$result" "$source" >/dev/null 2>&1
  log=$(cat "$EVAL_LOG")
  assert_contains "$log" '--full' "the render probe did not request untruncated browser output"
  assert_not_contains "$log" 'session: crewmate-in-flight' "the check reused the caller's browser session"
  assert_contains "$log" 'session: fm-visual-check-' "the check did not run in its own browser session"
  assert_contains "$log" 'port: unset' "an inherited explicit port defeated the session isolation"
  pass "visual deliverable check probes an isolated session with untruncated output"
}

test_doubly_encoded_result_is_measured() {
  local source="$TMP_ROOT/deep.html" result="$TMP_ROOT/deep.result" out rc
  printf '<audio controls></audio>\n' > "$source"
  write_doubly_encoded_result "$result" '[{"label":"audio#bed","width":318,"height":0,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto","exempt":false}]'
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 1 "$rc" "a more deeply encoded browser result must still be measured"
  assert_contains "$out" 'audio#bed: rendered dimensions are 318x0' "a more deeply encoded result was not measured"
  pass "visual deliverable check measures either browser result encoding depth"
}

test_probe_returns_an_unstringified_array() {
  assert_grep 'return [...document.querySelectorAll(' "$CHECK" "the render probe no longer returns the element array directly"
  assert_no_grep 'JSON.stringify([...document.querySelectorAll(' "$CHECK" "the render probe re-stringifies a result the bridge already serializes"
  pass "visual deliverable check probe leaves serialization to the browser bridge"
}

test_session_state_dir_is_removed() {
  local source="$TMP_ROOT/state.html" result="$TMP_ROOT/state.result" created
  local FM_TEST_HOME="$TMP_ROOT/home" FM_TEST_STATE_LOG="$TMP_ROOT/state.dir"
  printf '<audio controls></audio>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":54,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto","exempt":false}]'
  mkdir -p "$FM_TEST_HOME/.chrome-devtools-axi/sessions/keep-me"
  run_check "$result" "$source" >/dev/null 2>&1
  created=$(cat "$FM_TEST_STATE_LOG")
  assert_contains "$created" "$FM_TEST_HOME/.chrome-devtools-axi/sessions/fm-visual-check-" "the bridge stand-in did not create a per-run session state directory to clean up"
  assert_absent "$created" "the per-run browser session state directory was left behind"
  assert_present "$FM_TEST_HOME/.chrome-devtools-axi/sessions/keep-me" "session cleanup removed a directory belonging to another session"
  pass "visual deliverable check removes its own browser session state directory"
}

test_unexpected_browser_result_fails_cleanly() {
  local source="$TMP_ROOT/unexpected.html" result="$TMP_ROOT/unexpected.result" out rc
  printf '<audio controls></audio>\n' > "$source"
  printf 'result: "not an element list"\n' > "$result"
  out=$(run_check "$result" "$source" 2>&1); rc=$?
  expect_code 2 "$rc" "unexpected browser result must be a measurement failure"
  assert_contains "$out" 'could not measure rendered elements at https://visual.example.test' "measurement failure did not name the URL"
  assert_not_contains "$out" 'Error: browser result was not an element list' "measurement failure leaked a Node stack trace"
  pass "visual deliverable check reports an unexpected browser result cleanly"
}

test_file_url_is_refused_cleanly() {
  local source="$TMP_ROOT/local.html" out rc
  printf '<audio controls></audio>\n' > "$source"
  out=$(FM_VISUAL_CHECK_BROWSER="$TMP_ROOT/browser" "$CHECK" "file://$source" --source "$source" 2>&1); rc=$?
  expect_code 2 "$rc" "file URL must be refused before browser measurement"
  assert_contains "$out" 'file:// URLs are unsupported; serve the local artifact over http(s)' "file URL refusal did not explain the supported transport"
  assert_not_contains "$out" 'browser result was not an element list' "file URL refusal leaked the browser parser failure"
  pass "visual deliverable check refuses file URLs cleanly"
}

test_help_states_file_url_contract() {
  local out
  out=$("$CHECK" --help)
  assert_contains "$out" 'serve local artifacts instead of passing file:// URLs' "usage did not state the file URL contract"
  pass "visual deliverable check usage states the file URL contract"
}

test_zero_height_audio_fails
test_hidden_interactive_control_fails
test_audio_auto_height_reset_fails
test_usable_elements_pass
test_zero_matched_elements_fails
test_marked_hidden_control_is_exempt
test_every_element_marked_still_fails
test_render_probe_is_isolated_and_untruncated
test_probe_returns_an_unstringified_array
test_session_state_dir_is_removed
test_doubly_encoded_result_is_measured
test_unexpected_browser_result_fails_cleanly
test_file_url_is_refused_cleanly
test_help_states_file_url_contract
