#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-unit-economics-ledger)
BIN="$ROOT/bin/fm-unit-economics-ledger.mjs"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_source() {
  local path=$1 payload=$2
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$payload'" > "$path"
  chmod +x "$path"
}

write_config() {
  local path=$1 lane=$2 first=$3 second=$4
  cat > "$path" <<JSON
{"maxAgeSeconds":900,"lanes":{"$lane":{"sources":[{"command":["$first"]},{"command":["$second"]}]}}}
JSON
}

write_quota() {
  local path=$1 generated=$2
  write_source "$path" "{\"generatedAt\":\"$generated\",\"providers\":[{\"provider\":\"claude\",\"windows\":[{\"percentRemaining\":80}]},{\"provider\":\"codex\",\"windows\":[{\"percentRemaining\":60}]}]}"
}

run_ledger() {
  local config=$1 output=$2 quota=$3
  FM_UNIT_ECONOMICS_QUOTA_AXI="$quota" node "$BIN" --config "$config" --output "$output" --format json >/dev/null
}

test_zero_revenue_is_explicit_and_cross_checked() {
  local one="$TMP_ROOT/zero/one" two="$TMP_ROOT/zero/two" config="$TMP_ROOT/zero/config.json" out="$TMP_ROOT/zero/out.json" quota="$TMP_ROOT/zero/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "$one" "$two"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==0 and .status=="independently_cross_checked")' "$out" >/dev/null || fail "zero revenue was not explicit and cross-checked"
  pass "zero revenue remains an explicit cross-checked zero"
}

test_unavailable_and_partial_lanes_render() {
  local config="$TMP_ROOT/unavailable/config.json" out="$TMP_ROOT/unavailable/out.json" quota="$TMP_ROOT/unavailable/quota"
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '[.lanes[].id] | length == 5 and index("weho") and index("fleet_operations")' "$out" >/dev/null || fail "all lanes did not render"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable")' "$out" >/dev/null || fail "unavailable lane was not honest"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="claude_quota_window" and .amount==80 and .unit=="percent")' "$out" >/dev/null || fail "available lane did not render beside unavailable lanes"
  [ -f "${out%.json}.md" ] || fail "captain-readable companion artifact was not written"
  pass "unavailable sources and partial lane rendering stay honest"
}

test_stale_and_failed_cross_check_are_refused() {
  local old='2000-01-01T00:00:00Z' one="$TMP_ROOT/refusal/one" two="$TMP_ROOT/refusal/two" config="$TMP_ROOT/refusal/config.json" out="$TMP_ROOT/refusal/out.json" quota="$TMP_ROOT/refusal/quota"
  write_source "$one" "{\"observedAt\":\"$old\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\"},\"realized_revenue\":{\"amount\":2,\"unit\":\"USD\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\"},\"realized_revenue\":{\"amount\":3,\"unit\":\"USD\"}}}"
  write_config "$config" weho "$one" "$two"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="stale source refused")' "$out" >/dev/null || fail "stale financial source was not refused"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\"},\"realized_revenue\":{\"amount\":2,\"unit\":\"USD\"}}}"
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .cross_check=="failed")' "$out" >/dev/null || fail "failed cross-check was presented as fact"
  pass "stale and disagreeing financial sources are refused"
}

test_currency_and_units_are_preserved() {
  local one="$TMP_ROOT/units/one" two="$TMP_ROOT/units/two" config="$TMP_ROOT/units/config.json" out="$TMP_ROOT/units/out.json" quota="$TMP_ROOT/units/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"cost_per_post\":{\"amount\":2.5,\"unit\":\"USD\"},\"posts_per_day\":{\"amount\":3,\"unit\":\"posts/day\"},\"adsense_revenue\":{\"amount\":0,\"unit\":\"USD\"},\"performance_bonus_revenue\":{\"amount\":0,\"unit\":\"USD\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"cost_per_post\":{\"amount\":2.5,\"unit\":\"USD\"},\"posts_per_day\":{\"amount\":3,\"unit\":\"posts/day\"},\"adsense_revenue\":{\"amount\":0,\"unit\":\"USD\"},\"performance_bonus_revenue\":{\"amount\":0,\"unit\":\"USD\"}}}"
  write_config "$config" content_accounts "$one" "$two"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="content_accounts") | .metrics[] | select(.name=="posts_per_day" and .unit=="posts/day" and .currency==null)' "$out" >/dev/null || fail "non-currency unit was lost"
  jq -e '.lanes[] | select(.id=="content_accounts") | .metrics[] | select(.name=="cost_per_post" and .currency=="USD")' "$out" >/dev/null || fail "currency was lost"
  pass "currency and non-financial units are preserved"
}

test_fleet_cost_requires_independent_sources() {
  local one="$TMP_ROOT/fleet/one" two="$TMP_ROOT/fleet/two" config="$TMP_ROOT/fleet/config.json" out="$TMP_ROOT/fleet/out.json" quota="$TMP_ROOT/fleet/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"attributable_crew_session_cost\":{\"amount\":7,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"attributable_crew_session_cost\":{\"amount\":7,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"cost_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="attributable_crew_session_cost" and .amount==7 and .status=="independently_cross_checked")' "$out" >/dev/null || fail "fleet cost was not independently cross-checked"
  pass "fleet cost requires independent sources"
}

test_zero_revenue_is_explicit_and_cross_checked
test_unavailable_and_partial_lanes_render
test_stale_and_failed_cross_check_are_refused
test_currency_and_units_are_preserved
test_fleet_cost_requires_independent_sources
