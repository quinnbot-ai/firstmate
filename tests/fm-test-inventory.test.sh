#!/usr/bin/env bash
# Behavior tests for literal-source test-inventory receipts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVENTORY="$ROOT/bin/fm-test-inventory.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-inventory)

make_project() {
  local name=$1 project
  project=$TMP_ROOT/$name
  mkdir -p "$project/.firstmate" "$project/tests"
  cat > "$project/.firstmate/test-inventory.json" <<'EOF'
{
  "schema_version": 1,
  "status": "test-bearing",
  "baseline": {"version": 1, "declarations": 2, "test_files": 1},
  "maximum_unreviewed_deletion": 0
}
EOF
  cat > "$project/tests/test_literal.py" <<'EOF'
def test_one():
    pass

class TestLiteral:
    def test_two(self):
        pass
EOF
  printf '%s\n' "$project"
}

test_collect_and_check_never_execute_candidate_code() {
  local project
  project=$(make_project literal-only)
  cat > "$project/conftest.py" <<'EOF'
raise RuntimeError("candidate conftest must never run")
EOF
  "$INVENTORY" collect "$project" >/dev/null || fail "literal-source collection should not execute conftest.py"
  "$INVENTORY" check "$project" >/dev/null || fail "literal-source check should not execute conftest.py"
  grep -q 'literal_declarations_sha256' "$project/.firstmate/test-inventory-receipt.json" \
    || fail "receipt did not bind literal declarations"
  pass "inventory counts literal declarations without importing candidate conftest.py"
}

test_dynamic_runtime_tests_do_not_satisfy_literal_inventory() {
  local project out rc
  project=$(make_project dynamic-only)
  rm "$project/tests/test_literal.py"
  cat > "$project/tests/test_dynamic.py" <<'EOF'
globals()["test_generated"] = lambda: None
EOF
  set +e
  out=$("$INVENTORY" collect "$project" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "dynamic runtime tests must not count as literal declarations"
  printf '%s\n' "$out" | grep -q 'no literal Python test declarations' \
    || fail "dynamic-only refusal did not explain the literal-source boundary"
  pass "inventory excludes dynamically generated runtime tests"
}

test_collect_and_check_never_execute_candidate_code
test_dynamic_runtime_tests_do_not_satisfy_literal_inventory
