#!/usr/bin/env bash
# Tests for the rendered visual deliverable usability check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-visual-deliverable-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-visual-deliverable-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

make_browser() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  open) printf 'page opened\n' ;;
  eval) cat "${FM_VISUAL_CHECK_RESULT:?}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$path"
}

write_result() {  # <path> <json-array>
  local path=$1 result=$2
  node -e 'console.log(`result: ${JSON.stringify(process.argv[1])}`)' "$result" > "$path"
}

run_check() {  # <result-file> <source>...
  local result=$1
  shift
  local -a args
  args=(https://visual.example.test)
  for source in "$@"; do
    args+=(--source "$source")
  done
  FM_VISUAL_CHECK_BROWSER="$TMP_ROOT/browser" FM_VISUAL_CHECK_RESULT="$result" "$CHECK" "${args[@]}"
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

test_zero_height_audio_fails
test_hidden_interactive_control_fails
test_audio_auto_height_reset_fails
test_usable_elements_pass
