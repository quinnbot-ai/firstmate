#!/usr/bin/env bash
# Behavior tests for the rendered visual usability check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-visual-usability-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-visual-usability-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

make_browser() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  open) exit 0 ;;
  eval) cat "${FM_VISUAL_CHECK_RESULT:?}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$1"
}

write_result() {
  node -e 'console.log(`result: ${JSON.stringify(process.argv[1])}`)' "$2" > "$1"
}

run_check() {
  FM_VISUAL_CHECK_BROWSER="$TMP_ROOT/browser" FM_VISUAL_CHECK_RESULT="$1" \
    "$CHECK" https://visual.example.test --source "$2"
}

make_browser "$TMP_ROOT/browser"

test_hidden_or_inert_control_fails() {
  local source="$TMP_ROOT/control.html" result="$TMP_ROOT/control.result" out status
  printf '<button>Continue</button>\n' > "$source"
  write_result "$result" '[{"label":"button#continue","width":120,"height":40,"clientRects":1,"hiddenBy":"its computed style","interactive":true,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source" 2>&1); status=$?
  expect_code 1 "$status" "a hidden control must fail"
  assert_contains "$out" 'button#continue: hidden by its computed style' "hidden control failure was not reported"
  pass "visual usability check rejects hidden controls"
}

test_zero_sized_media_fails() {
  local source="$TMP_ROOT/media.html" result="$TMP_ROOT/media.result" out status
  printf '<audio></audio>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":0,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source" 2>&1); status=$?
  expect_code 1 "$status" "zero-sized media must fail"
  assert_contains "$out" 'audio#bed: rendered dimensions are 318x0' "zero-sized media failure was not reported"
  pass "visual usability check rejects zero-sized media"
}

test_usable_visual_elements_pass() {
  local source="$TMP_ROOT/usable.html" result="$TMP_ROOT/usable.result" out
  printf '<audio></audio><button>Continue</button>\n' > "$source"
  write_result "$result" '[{"label":"audio#bed","width":318,"height":54,"clientRects":1,"hiddenBy":"","interactive":false,"disabled":false,"pointerEvents":"auto"},{"label":"button#continue","width":120,"height":40,"clientRects":1,"hiddenBy":"","interactive":true,"disabled":false,"pointerEvents":"auto"}]'
  out=$(run_check "$result" "$source")
  assert_contains "$out" 'ok - rendered media and interactive elements have usable dimensions and visibility' "usable visual elements did not pass"
  pass "visual usability check accepts visible media and controls"
}

test_hidden_or_inert_control_fails
test_zero_sized_media_fails
test_usable_visual_elements_pass

echo '# all fm-visual-usability-check tests passed'
