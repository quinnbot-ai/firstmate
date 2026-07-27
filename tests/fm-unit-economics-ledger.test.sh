#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-unit-economics-ledger)
BIN="$ROOT/bin/fm-unit-economics-ledger.mjs"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

write_source() {
  local path=$1 payload=$2
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$payload'" > "$path"
  chmod +x "$path"
}

write_live_source() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JS'
#!/usr/bin/env node
setTimeout(() => {
  process.stdout.write(`${JSON.stringify({
    observedAt: new Date().toISOString(),
    currency: 'USD',
    metrics: {
      pipeline_cost: { amount: 4, unit: 'USD', status: 'measured' },
      realized_revenue: { amount: 8, unit: 'USD', status: 'measured' },
    },
  })}\n`);
}, 25);
JS
  chmod +x "$path"
}

write_delayed_source() {
  local path=$1 delay_ms=$2
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<JS
#!/usr/bin/env node
setTimeout(() => {
  process.stdout.write(JSON.stringify({
    observedAt: new Date().toISOString(),
    currency: 'USD',
    metrics: {},
  }) + '\\n');
}, $delay_ms);
JS
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
  write_source "$path" "{\"generatedAt\":\"$generated\",\"providers\":[{\"provider\":\"claude\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$generated\"},\"windows\":[{\"percentRemaining\":80}]},{\"provider\":\"codex\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$generated\"},\"windows\":[{\"percentRemaining\":60}]}]}"
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
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"; printf 'old\n' > "$out"; printf 'old\n' > "${out%.json}.md"; chmod 0644 "$out" "${out%.json}.md"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '[.lanes[].id] | length == 5 and index("weho") and index("fleet_operations")' "$out" >/dev/null || fail "all lanes did not render"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable" and .source_freshness=="source configuration absent" and .unavailable_reason=="source configuration absent")' "$out" >/dev/null || fail "missing source configuration was not identified"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="claude_quota_window" and .amount==80 and .unit=="percent")' "$out" >/dev/null || fail "available lane did not render beside unavailable lanes"
  [ -f "${out%.json}.md" ] || fail "captain-readable companion artifact was not written"
  [ "$(file_mode "$out")" = 600 ] && [ "$(file_mode "${out%.json}.md")" = 600 ] || fail "existing ledger artifacts were not made private"
  pass "unavailable sources and partial lane rendering stay honest"
}

test_stale_and_failed_cross_check_are_refused() {
  local old='2000-01-01T00:00:00Z' one="$TMP_ROOT/refusal/one" two="$TMP_ROOT/refusal/two" config="$TMP_ROOT/refusal/config.json" out="$TMP_ROOT/refusal/out.json" quota="$TMP_ROOT/refusal/quota"
  write_source "$one" "{\"observedAt\":\"$old\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":3,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "$one" "$two"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="stale source refused" and .unavailable_reason=="stale source refused")' "$out" >/dev/null || fail "stale financial source was not refused"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho" and .source_freshness=="fresh") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="fresh" and .cross_check=="failed")' "$out" >/dev/null || fail "failed cross-check was presented as fact or reported as a freshness failure"
  pass "stale and disagreeing financial sources are refused"
}

test_currency_and_units_are_preserved() {
  local one="$TMP_ROOT/units/one" two="$TMP_ROOT/units/two" config="$TMP_ROOT/units/config.json" out="$TMP_ROOT/units/out.json" quota="$TMP_ROOT/units/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"cost_per_post\":{\"amount\":2.5,\"unit\":\"USD\",\"status\":\"measured\"},\"posts_per_day\":{\"amount\":3,\"unit\":\"posts/day\",\"status\":\"measured\"},\"adsense_revenue\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"},\"performance_bonus_revenue\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"cost_per_post\":{\"amount\":2.5,\"unit\":\"USD\",\"status\":\"measured\"},\"posts_per_day\":{\"amount\":3,\"unit\":\"posts/day\",\"status\":\"measured\"},\"adsense_revenue\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"},\"performance_bonus_revenue\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"}}}"
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

test_daily_fleet_line_requires_readable_sources() {
  local config="$TMP_ROOT/daily-unavailable/config.json" out="$TMP_ROOT/daily-unavailable/out.json" quota="$TMP_ROOT/daily-unavailable/quota" date
  date=$(date -u +%Y-%m-%d)
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e --arg date "$date" '(.schema == "fleet-unit-economics-ledger.v3") and ([.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.date==$date and .session_cost.amount==null and .session_cost.status=="unavailable" and .validation_run_volume.amount==null and .validation_run_volume.status=="unavailable")] | length == 1)' "$out" >/dev/null || fail "missing daily sources were rendered as a number instead of unavailable"
  grep -F 'unavailable (source configuration absent)' "${out%.json}.md" >/dev/null || fail "daily Markdown line hid the unavailable source"
  pass "daily fleet line renders missing sources as unavailable rather than zero"
}

test_unreadable_malformed_and_unmapped_sources_stay_unavailable() {
  local good="$TMP_ROOT/source-diagnosis/good" bad="$TMP_ROOT/source-diagnosis/bad" config="$TMP_ROOT/source-diagnosis/config.json" out="$TMP_ROOT/source-diagnosis/out.json" quota="$TMP_ROOT/source-diagnosis/quota"
  write_source "$good" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "$TMP_ROOT/source-diagnosis/missing" "$good"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="source unreadable")' "$out" >/dev/null || fail "an unreadable helper was not identified"
  write_source "$bad" 'not-json'
  write_config "$config" weho "$bad" "$good"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="source malformed")' "$out" >/dev/null || fail "malformed helper output was not identified"
  write_source "$bad" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "$bad" "$good"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="source metric missing")' "$out" >/dev/null || fail "an unmapped metric was not identified"
  write_source "$bad" '{"currency":"USD","metrics":{"pipeline_cost":{"amount":4,"unit":"USD","status":"measured"},"realized_revenue":{"amount":8,"unit":"USD","status":"measured"}}}'
  write_config "$config" weho "$bad" "$good"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="source malformed")' "$out" >/dev/null || fail "helper output without a parsable observedAt was not identified as malformed"
  pass "unreadable malformed and unmapped sources remain unavailable with reasons"
}

test_source_configuration_and_count_failures_are_named() {
  local one="$TMP_ROOT/source-contract/one" config="$TMP_ROOT/source-contract/config.json" out="$TMP_ROOT/source-contract/out.json" quota="$TMP_ROOT/source-contract/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"weho":{"sources":[{"command":["$one"]}]},"trading":{"sources":[{"command":"$one"}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="single-source refused" and .unavailable_reason=="single-source refused")' "$out" >/dev/null || fail "a single configured helper was not named a single-source refusal"
  jq -e '.lanes[] | select(.id=="trading") | .metrics[] | select(.name=="realized_pnl" and .amount==null and .source_freshness=="source configuration malformed")' "$out" >/dev/null || fail "a malformed source entry was not named malformed configuration"
  printf '%s\n' '{"lanes":{"weho":{"sources":{}}}}' > "$config"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="source configuration malformed")' "$out" >/dev/null || fail "a malformed sources container was not named malformed configuration"
  pass "malformed source configuration and insufficient source counts are named"
}

test_daily_fleet_line_names_helper_failures_before_source_count() {
  local one="$TMP_ROOT/daily-diagnosis/one" two="$TMP_ROOT/daily-diagnosis/two" missing="$TMP_ROOT/daily-diagnosis/missing"
  local config="$TMP_ROOT/daily-diagnosis/config.json" out="$TMP_ROOT/daily-diagnosis/out.json" quota="$TMP_ROOT/daily-diagnosis/quota" date past
  date=$(date -u +%Y-%m-%d); past=$(node -p 'new Date(Date.now() - 86400000).toISOString().slice(0, 10)')
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$missing"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .source_freshness=="source unreadable")' "$out" >/dev/null || fail "a single unreadable daily helper was reported as an insufficient source count"
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[]}"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]}]}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .source_freshness=="single-source refused")' "$out" >/dev/null || fail "a single readable daily helper was not named a single-source refusal"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[]}"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  FM_UNIT_ECONOMICS_LEDGER_DATE="$past" FM_UNIT_ECONOMICS_QUOTA_AXI="$quota" node "$BIN" --config "$config" --output "$out" --format json >/dev/null
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .source_freshness=="ledger date not covered")' "$out" >/dev/null || fail "a backfilled date no helper covers was reported as malformed helper output"
  grep -F 'unavailable (ledger date not covered)' "${out%.json}.md" >/dev/null || fail "the uncovered ledger date was hidden in Markdown"
  pass "daily helper failures are diagnosed ahead of the single-source refusal"
}

test_daily_fleet_line_cross_checks_per_crew_cost_and_validation_runs() {
  local one="$TMP_ROOT/daily/one" two="$TMP_ROOT/daily/two" config="$TMP_ROOT/daily/config.json" out="$TMP_ROOT/daily/out.json" quota="$TMP_ROOT/daily/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}},{\"crew\":\"bravo\",\"sessionCost\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":0,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}},{\"crew\":\"bravo\",\"sessionCost\":{\"amount\":0,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":0,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==2 and .validation_run_volume.amount==3 and .sources == ["billing-export", "run-audit"]) | .crew_sessions[] | select(.crew=="bravo" and .session_cost.amount==0 and .validation_runs.amount==0 and .session_cost.status=="independently_cross_checked")] | length == 1' "$out" >/dev/null || fail "daily per-crew figures were not independently cross-checked"
  pass "daily fleet line preserves explicit cross-checked zeroes"
}

test_live_helper_timestamps_are_fresh() {
  local one="$TMP_ROOT/live/one" two="$TMP_ROOT/live/two" config="$TMP_ROOT/live/config.json" out="$TMP_ROOT/live/out.json" quota="$TMP_ROOT/live/quota"
  write_live_source "$one"; write_live_source "$two"; write_config "$config" weho "$one" "$two"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==8 and .source_freshness=="fresh")' "$out" >/dev/null || fail "live helper timestamp was rejected as future"
  pass "live helper timestamps are compared after invocation"
}

test_untrusted_metric_states_and_duplicate_sources_are_refused() {
  local one="$TMP_ROOT/source-integrity/one" two="$TMP_ROOT/source-integrity/two" config="$TMP_ROOT/source-integrity/config.json" out="$TMP_ROOT/source-integrity/out.json" quota="$TMP_ROOT/source-integrity/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"unavailable\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"unavailable\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"stale\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"stale\"}}}"
  write_config "$config" weho "$one" "$two"; write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable" and .source_freshness=="source metric untrusted")' "$out" >/dev/null || fail "a present but untrusted metric was published or reported as a missing metric"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "$one" "$one"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .cross_check=="unavailable" and .source_freshness=="single-source refused")' "$out" >/dev/null || fail "duplicate command arrays satisfied independent corroboration"
  pass "metric states and source identity gate corroboration"
}

test_stale_quota_provider_state_is_refused() {
  local old='2000-01-01T00:00:00Z' config="$TMP_ROOT/quota-state/config.json" out="$TMP_ROOT/quota-state/out.json" quota="$TMP_ROOT/quota-state/quota"
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"
  write_source "$quota" "{\"generatedAt\":\"$NOW\",\"providers\":[{\"provider\":\"claude\",\"state\":{\"status\":\"stale\",\"stale\":true,\"refreshedAt\":\"$NOW\"},\"windows\":[{\"percentRemaining\":80}]},{\"provider\":\"codex\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$old\"},\"windows\":[{\"percentRemaining\":60}]}]}"
  run_ledger "$config" "$out" "$quota"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .metrics[] | select((.name=="claude_quota_window" or .name=="codex_quota_window") and .amount==null and .source_freshness=="stale source refused")] | length==2' "$out" >/dev/null || fail "stale provider state or refresh time was published"
  pass "quota provider state and refresh time must be fresh"
}

test_stale_third_provider_window_reaches_the_lane_header() {
  local old='2000-01-01T00:00:00Z' cost_one="$TMP_ROOT/quota-third/cost-one" cost_two="$TMP_ROOT/quota-third/cost-two"
  local daily_one="$TMP_ROOT/quota-third/daily-one" daily_two="$TMP_ROOT/quota-third/daily-two"
  local config="$TMP_ROOT/quota-third/config.json" out="$TMP_ROOT/quota-third/out.json" quota="$TMP_ROOT/quota-third/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$cost_one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"attributable_crew_session_cost\":{\"amount\":7,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$cost_two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"attributable_crew_session_cost\":{\"amount\":7,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$daily_one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[]}"
  write_source "$daily_two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"cost_sources":[{"command":["$cost_one"]},{"command":["$cost_two"]}],"daily_sources":[{"command":["$daily_one"]},{"command":["$daily_two"]}]}}}
JSON
  write_source "$quota" "{\"generatedAt\":\"$NOW\",\"providers\":[{\"provider\":\"claude\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$NOW\"},\"windows\":[{\"percentRemaining\":80}]},{\"provider\":\"codex\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$NOW\"},\"windows\":[{\"percentRemaining\":60}]},{\"provider\":\"gemini\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$old\"},\"windows\":[{\"percentRemaining\":40}]}]}"
  run_ledger "$config" "$out" "$quota"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.source_freshness=="fresh")] | length == 3' "$out" >/dev/null || fail "the fleet metrics were not all fresh before the quota-window check"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line.quota_windows[] | select(.provider=="gemini" and .status=="unavailable" and .source_freshness=="stale source refused")] | length == 1' "$out" >/dev/null || fail "a stale third-provider window was published as a measurement"
  jq -e '.lanes[] | select(.id=="fleet_operations" and .source_freshness=="stale source refused")' "$out" >/dev/null || fail "the fleet lane header read fresh over a refused quota window"
  pass "a refused quota window outside the named pair reaches the lane header"
}

test_malformed_source_containers_render_unavailable() {
  local config="$TMP_ROOT/malformed/config.json" out="$TMP_ROOT/malformed/out.json" quota="$TMP_ROOT/malformed/quota"
  mkdir -p "$(dirname "$config")"
  printf '%s\n' '{"lanes":{"weho":{"sources":{}},"fleet_operations":{"cost_sources":"invalid"}}}' > "$config"
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null)' "$out" >/dev/null || fail "malformed lane sources prevented unavailable rendering"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="attributable_crew_session_cost" and .amount==null and .source_freshness=="source configuration malformed")' "$out" >/dev/null || fail "malformed cost sources prevented unavailable rendering"
  jq -e '.lanes[] | select(.id=="fleet_operations" and .source_freshness=="source configuration malformed")' "$out" >/dev/null || fail "the fleet lane header read fresh over a malformed cost source"
  jq -e '.lanes[] | select(.id=="weho" and .source_freshness=="source configuration malformed")' "$out" >/dev/null || fail "the financial lane header read fresh over a malformed source container"
  pass "malformed source containers render unavailable"
}

test_observations_are_rechecked_at_publication() {
  local one="$TMP_ROOT/publication/one" two="$TMP_ROOT/publication/two" slow_one="$TMP_ROOT/publication/slow-one" slow_two="$TMP_ROOT/publication/slow-two"
  local config="$TMP_ROOT/publication/config.json" out="$TMP_ROOT/publication/out.json" quota="$TMP_ROOT/publication/quota" started_ms generated_at
  write_live_source "$one"; write_live_source "$two"; write_delayed_source "$slow_one" 150; write_delayed_source "$slow_two" 150
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":0.2,"lanes":{"weho":{"sources":[{"command":["$one"]},{"command":["$two"]}]},"content_accounts":{"sources":[{"command":["$slow_one"]},{"command":["$slow_two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; started_ms=$(node -p 'Date.now()'); run_ledger "$config" "$out" "$quota"; generated_at=$(jq -r .generated_at "$out")
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="stale source refused")' "$out" >/dev/null || fail "early observation remained fresh at publication"
  node -e 'if (Date.parse(process.argv[1]) - Number(process.argv[2]) < 250) process.exit(1)' "$generated_at" "$started_ms" || fail "generated_at was captured before source collection completed"
  pass "observations are rechecked at publication time"
}

test_quota_percentages_must_be_in_range() {
  local config="$TMP_ROOT/quota-range/config.json" out="$TMP_ROOT/quota-range/out.json" quota="$TMP_ROOT/quota-range/quota"
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"
  write_source "$quota" "{\"generatedAt\":\"$NOW\",\"providers\":[{\"provider\":\"claude\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$NOW\"},\"windows\":[{\"percentRemaining\":-1},{\"percentRemaining\":101}]},{\"provider\":\"codex\",\"state\":{\"status\":\"fresh\",\"stale\":false,\"refreshedAt\":\"$NOW\"},\"windows\":[{\"percentRemaining\":-1},{\"percentRemaining\":75},{\"percentRemaining\":101}]}]}"
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="claude_quota_window" and .amount==null and .status=="unavailable")' "$out" >/dev/null || fail "out-of-range quota percentages were published"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="codex_quota_window" and .amount==75 and .status=="measured")' "$out" >/dev/null || fail "valid quota percentage was lost beside invalid windows"
  pass "quota percentages must be between zero and one hundred"
}

test_malformed_source_timeouts_render_unavailable() {
  local one="$TMP_ROOT/timeout/one" two="$TMP_ROOT/timeout/two" config="$TMP_ROOT/timeout/config.json" out="$TMP_ROOT/timeout/out.json" quota="$TMP_ROOT/timeout/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"lanes":{"weho":{"sources":[{"command":["$one"],"timeoutMs":"invalid"},{"command":["$two"],"timeoutMs":-1}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable" and .source_freshness=="source configuration malformed")' "$out" >/dev/null || fail "malformed source timeouts were not rendered unavailable"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="claude_quota_window" and .amount==80 and .status=="measured")' "$out" >/dev/null || fail "malformed source timeout prevented partial rendering"
  [ -f "${out%.json}.md" ] || fail "malformed source timeout prevented artifact publication"
  pass "malformed source timeouts render unavailable"
}

test_empty_quota_provider_list_is_unavailable() {
  local config="$TMP_ROOT/quota-empty/config.json" out="$TMP_ROOT/quota-empty/out.json" quota="$TMP_ROOT/quota-empty/quota"
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"
  write_source "$quota" "{\"generatedAt\":\"$NOW\",\"providers\":[]}"
  run_ledger "$config" "$out" "$quota"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line.quota_windows[] | select(.provider=="quota-axi" and .status=="unavailable" and .source_freshness=="source unavailable")] | length == 1' "$out" >/dev/null || fail "an empty quota provider list was not marked unavailable"
  grep -F 'quota-axi: unavailable (source unavailable)' "${out%.json}.md" >/dev/null || fail "empty quota provider list rendered a blank Markdown cell"
  pass "an empty quota provider list renders unavailable rather than blank"
}

test_quota_provider_without_refresh_time_is_unavailable() {
  local config="$TMP_ROOT/quota-no-refresh/config.json" out="$TMP_ROOT/quota-no-refresh/out.json" quota="$TMP_ROOT/quota-no-refresh/quota"
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"
  write_source "$quota" "{\"generatedAt\":\"$NOW\",\"providers\":[{\"provider\":\"claude\",\"state\":{\"status\":\"fresh\",\"stale\":false},\"windows\":[{\"percentRemaining\":80}]}]}"
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="claude_quota_window" and .amount==null and .source_freshness=="source unavailable")' "$out" >/dev/null || fail "a provider without a refresh time published a measured percentage"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line.quota_windows[] | select(.provider=="claude" and .status=="unavailable" and .source_freshness=="source unavailable")] | length == 1' "$out" >/dev/null || fail "the lane metric and the daily window disagreed about the same provider"
  pass "a quota provider without a refresh time is unavailable in both views"
}

test_daily_fleet_line_refuses_currency_disagreement() {
  local one="$TMP_ROOT/daily-currency/one" two="$TMP_ROOT/daily-currency/two" config="$TMP_ROOT/daily-currency/config.json" out="$TMP_ROOT/daily-currency/out.json" quota="$TMP_ROOT/daily-currency/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"EUR\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .session_cost.status=="unavailable" and .source_freshness=="source disagreement refused")' "$out" >/dev/null || fail "disagreeing currencies were published as a cross-checked USD figure"
  pass "daily helpers disagreeing on currency render unavailable"
}

test_daily_fleet_line_refuses_roster_disagreement() {
  local one="$TMP_ROOT/daily-roster/one" two="$TMP_ROOT/daily-roster/two" config="$TMP_ROOT/daily-roster/config.json" out="$TMP_ROOT/daily-roster/out.json" quota="$TMP_ROOT/daily-roster/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}},{\"crew\":\"bravo\",\"sessionCost\":{\"amount\":1,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":1,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .session_cost.status=="unavailable" and .source_freshness=="source disagreement refused")' "$out" >/dev/null || fail "a crew-roster disagreement was not named a source disagreement"
  grep -F 'unavailable (source disagreement refused)' "${out%.json}.md" >/dev/null || fail "the roster disagreement was hidden in Markdown"
  pass "daily helpers disagreeing on the crew roster render a named disagreement"
}

test_daily_fleet_line_renders_corroborated_empty_roster_as_zero() {
  local one="$TMP_ROOT/daily-empty/one" two="$TMP_ROOT/daily-empty/two" config="$TMP_ROOT/daily-empty/config.json" out="$TMP_ROOT/daily-empty/out.json" quota="$TMP_ROOT/daily-empty/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.name=="daily_attributable_crew_session_cost" and .session_cost.amount==0 and .session_cost.status=="independently_cross_checked")' "$out" >/dev/null || fail "a corroborated empty roster was not an explicit cross-checked zero"
  grep -F '0 USD (independently_cross_checked); no crews reported' "${out%.json}.md" >/dev/null || fail "a corroborated empty roster was rendered as unavailable in Markdown"
  pass "a corroborated empty roster renders as an explicit zero"
}

test_malformed_ledger_date_is_refused() {
  local config="$TMP_ROOT/bad-date/config.json" out="$TMP_ROOT/bad-date/out.json" quota="$TMP_ROOT/bad-date/quota" status=0
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"; write_quota "$quota" "$NOW"
  FM_UNIT_ECONOMICS_LEDGER_DATE='../escape' FM_UNIT_ECONOMICS_QUOTA_AXI="$quota" node "$BIN" --config "$config" --output "$out" --format json >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "a malformed ledger date was accepted"
  [ ! -f "$out" ] || fail "a malformed ledger date still wrote a ledger"
  status=0
  FM_UNIT_ECONOMICS_LEDGER_DATE='2026-02-30' FM_UNIT_ECONOMICS_QUOTA_AXI="$quota" node "$BIN" --config "$config" --output "$out" --format json >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "a non-existent calendar date was accepted"
  pass "a malformed ledger date fails fast before writing"
}

test_backfilled_ledger_date_refuses_quota_windows() {
  local config="$TMP_ROOT/backfill/config.json" out="$TMP_ROOT/backfill/out.json" quota="$TMP_ROOT/backfill/quota" past
  past=$(node -p 'new Date(Date.now() - 86400000).toISOString().slice(0, 10)')
  mkdir -p "$(dirname "$config")"; printf '{}\n' > "$config"; write_quota "$quota" "$NOW"
  FM_UNIT_ECONOMICS_LEDGER_DATE="$past" FM_UNIT_ECONOMICS_QUOTA_AXI="$quota" node "$BIN" --config "$config" --output "$out" --format json >/dev/null
  jq -e --arg date "$past" '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.date==$date) | [.quota_windows[] | select(.status=="unavailable" and .source_freshness=="backfilled window refused")] | length == 1' "$out" >/dev/null || fail "a backfilled ledger date published present-day quota windows"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .metrics[] | select((.name=="claude_quota_window" or .name=="codex_quota_window") and .amount==null and .source_freshness=="backfilled window refused")] | length==2' "$out" >/dev/null || fail "a backfilled ledger date published present-day quota metrics"
  grep -F 'backfilled window refused' "${out%.json}.md" >/dev/null || fail "the backfilled window refusal was hidden in Markdown"
  pass "a backfilled ledger date refuses present-day quota windows"
}

test_daily_fleet_line_refuses_unsupported_currency() {
  local one="$TMP_ROOT/daily-eur/one" two="$TMP_ROOT/daily-eur/two" config="$TMP_ROOT/daily-eur/config.json" out="$TMP_ROOT/daily-eur/out.json" quota="$TMP_ROOT/daily-eur/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"EUR\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"EUR\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .source_freshness=="unsupported currency refused")' "$out" >/dev/null || fail "a readable non-USD source was reported as a missing source"
  grep -F 'unavailable (unsupported currency refused)' "${out%.json}.md" >/dev/null || fail "the unsupported-currency refusal was hidden in Markdown"
  pass "a readable non-USD daily source is refused as an unsupported currency"
}

test_daily_fleet_line_publishes_mixed_labels_as_estimated() {
  local one="$TMP_ROOT/daily-estimated/one" two="$TMP_ROOT/daily-estimated/two" config="$TMP_ROOT/daily-estimated/config.json" out="$TMP_ROOT/daily-estimated/out.json" quota="$TMP_ROOT/daily-estimated/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"estimated\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"]},{"command":["$two"]}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==2 and .session_cost.status=="estimated" and .validation_run_volume.amount==3 and .validation_run_volume.status=="independently_cross_checked")' "$out" >/dev/null || fail "an agreed amount with one estimating helper was refused instead of labeled estimated"
  jq -e '[.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line.crew_sessions[] | select(.crew=="alpha" and .session_cost.status=="estimated" and .validation_runs.status=="independently_cross_checked")] | length == 1' "$out" >/dev/null || fail "the weakest per-crew label did not govern"
  pass "corroborated amounts with a mixed label publish as estimated"
}

test_relative_source_commands_resolve_against_fm_home() {
  local home="$TMP_ROOT/fm-home" config="$TMP_ROOT/fm-home/config.json" out="$TMP_ROOT/fm-home/out.json" quota="$TMP_ROOT/fm-home/quota"
  write_source "$home/bin/weho-one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$home/bin/weho-two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "bin/weho-one" "bin/weho-two"
  write_quota "$quota" "$NOW"
  (cd "$TMP_ROOT" && FM_HOME="$home" FM_UNIT_ECONOMICS_QUOTA_AXI="$quota" node "$BIN" --config "$config" --output "$out" --format json >/dev/null)
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==8 and .cross_check=="passed")' "$out" >/dev/null || fail "relative source commands did not resolve against FM_HOME"
  pass "relative source commands resolve against FM_HOME, not the invoking cwd"
}

test_metrics_use_individual_freshness_windows() {
  local one="$TMP_ROOT/metric-freshness/one" two="$TMP_ROOT/metric-freshness/two" config="$TMP_ROOT/metric-freshness/config.json" out="$TMP_ROOT/metric-freshness/out.json" quota="$TMP_ROOT/metric-freshness/quota" old
  old=$(node -p 'new Date(Date.now() - 600000).toISOString()')
  write_source "$one" "{\"observedAt\":\"$old\",\"currency\":\"USD\",\"metrics\":{\"royalties\":{\"amount\":31.25,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$old\",\"currency\":\"USD\",\"metrics\":{\"royalties\":{\"amount\":31.25,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":30,"lanes":{"kdp":{"sources":[{"command":["$one"]},{"command":["$two"]}],"metrics":{"royalties":{"maxAgeSeconds":3024000}}}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==31.25 and .status=="independently_cross_checked" and .max_age_seconds==3024000)' "$out" >/dev/null || fail "a slow-moving metric inherited the operational freshness window"
  cat > "$config" <<JSON
{"maxAgeSeconds":30,"lanes":{"kdp":{"sources":[{"command":["$one"]},{"command":["$two"]}],"metrics":{"royalties":{"maxAgeSeconds":60}}}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==null and .unavailable_reason=="stale source refused" and .max_age_seconds==60)' "$out" >/dev/null || fail "a metric-specific stale reading did not name its reason"
  grep -F 'stale source refused' "${out%.json}.md" >/dev/null || fail "the metric-specific stale reason was hidden in Markdown"
  pass "financial metrics use their own freshness windows"
}

test_shared_provenance_refuses_and_authorized_single_source_labels() {
  local one="$TMP_ROOT/provenance/one" two="$TMP_ROOT/provenance/two" config="$TMP_ROOT/provenance/config.json" out="$TMP_ROOT/provenance/out.json" quota="$TMP_ROOT/provenance/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"royalties\":{\"amount\":31.25,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"royalties\":{\"amount\":31.25,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"lanes":{"kdp":{"sources":[{"command":["$one"],"provenance":"monthly-report-feed"},{"command":["$two"],"provenance":"monthly-report-feed"}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==null and .unavailable_reason=="shared provenance refused")' "$out" >/dev/null || fail "shared provenance was accepted as corroboration"
  grep -F 'shared provenance refused' "${out%.json}.md" >/dev/null || fail "the shared-provenance refusal was hidden in Markdown"
  cat > "$config" <<JSON
{"lanes":{"kdp":{"sources":[{"command":["$one"],"provenance":"monthly-report-feed"}],"metrics":{"royalties":{"maxAgeSeconds":3024000,"allowSingleSource":true}}}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==31.25 and .status=="single_source_uncorroborated" and .cross_check=="single-source uncorroborated")' "$out" >/dev/null || fail "the authorized KDP-style single source was not visibly labeled in JSON"
  grep -F 'single_source_uncorroborated' "${out%.json}.md" >/dev/null || fail "the authorized single source was not visibly labeled in Markdown"
  grep -F 'single-source uncorroborated' "${out%.json}.md" >/dev/null || fail "Markdown hid the absence of corroboration"
  cat > "$config" <<JSON
{"lanes":{"kdp":{"sources":[{"command":["$one"],"provenance":"monthly-report-feed"}],"metrics":{"attributable_costs":{"allowSingleSource":true}}}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="attributable_costs" and .amount==null and .unavailable_reason=="single-source exemption unauthorized")' "$out" >/dev/null || fail "an unauthorized single-source exemption was honored"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==null and .unavailable_reason=="single-source refused")' "$out" >/dev/null || fail "an undeclared metric lost the default two-source rule"
  cat > "$config" <<JSON
{"lanes":{"trading":{"sources":[{"command":["$one"],"provenance":"broker-feed"}],"metrics":{"realized_pnl":{"allowSingleSource":true}}}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="trading") | .metrics[] | select(.name=="realized_pnl" and .amount==null and .unavailable_reason=="single-source exemption unauthorized")' "$out" >/dev/null || fail "a non-KDP lane declared its way out of corroboration"
  grep -F 'single-source exemption unauthorized' "${out%.json}.md" >/dev/null || fail "the unauthorized exemption was hidden in Markdown"
  pass "shared provenance is refused and only authorized single sources publish"
}

test_malformed_metric_declarations_are_named() {
  local one="$TMP_ROOT/metric-config/one" two="$TMP_ROOT/metric-config/two" config="$TMP_ROOT/metric-config/config.json" out="$TMP_ROOT/metric-config/out.json" quota="$TMP_ROOT/metric-config/quota"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"royalties\":{\"amount\":31.25,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_source "$two" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"royalties\":{\"amount\":31.25,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"lanes":{"kdp":{"sources":[{"command":["$one"]},{"command":["$two"]}],"metrics":{"royalties":{"maxAgeSeconds":"35d"}}}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==null and .unavailable_reason=="metric configuration malformed" and .max_age_seconds==null)' "$out" >/dev/null || fail "a non-numeric freshness window published or hid its cause"
  grep -F 'metric configuration malformed' "${out%.json}.md" >/dev/null || fail "the malformed metric declaration was hidden in Markdown"
  cat > "$config" <<JSON
{"lanes":{"kdp":{"sources":[{"command":["$one"]},{"command":["$two"]}],"metrics":[{"royalties":{}}]}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="kdp") | .metrics[] | select(.name=="royalties" and .amount==null and .unavailable_reason=="metric configuration malformed")' "$out" >/dev/null || fail "a malformed metrics container was not named"
  pass "malformed metric declarations refuse publication under a named reason"
}

test_daily_sources_require_independent_provenance() {
  local one="$TMP_ROOT/daily-provenance/one" two="$TMP_ROOT/daily-provenance/two" config="$TMP_ROOT/daily-provenance/config.json" out="$TMP_ROOT/daily-provenance/out.json" quota="$TMP_ROOT/daily-provenance/quota" date
  date=$(date -u +%Y-%m-%d)
  write_source "$one" "{\"source\":\"billing-export\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  write_source "$two" "{\"source\":\"run-audit\",\"observedAt\":\"$NOW\",\"date\":\"$date\",\"currency\":\"USD\",\"crewSessions\":[{\"crew\":\"alpha\",\"sessionCost\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"},\"validationRuns\":{\"amount\":3,\"unit\":\"runs\",\"status\":\"measured\"}}]}"
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"],"provenance":"monthly-report-feed"},{"command":["$two"],"provenance":"monthly-report-feed"}]}}}
JSON
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==null and .session_cost.unavailable_reason=="shared provenance refused" and .source_freshness=="shared provenance refused")' "$out" >/dev/null || fail "two daily helpers over one feed were accepted as corroboration"
  grep -F 'unavailable (shared provenance refused)' "${out%.json}.md" >/dev/null || fail "the daily shared-provenance refusal was hidden in Markdown"
  cat > "$config" <<JSON
{"maxAgeSeconds":900,"lanes":{"fleet_operations":{"daily_sources":[{"command":["$one"],"provenance":"billing-export"},{"command":["$two"],"provenance":"run-audit"}]}}}
JSON
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.session_cost.amount==2 and .session_cost.status=="independently_cross_checked")' "$out" >/dev/null || fail "independently sourced daily helpers were refused"
  pass "the daily fleet money line requires independent provenance"
}

test_zero_revenue_is_explicit_and_cross_checked
test_unavailable_and_partial_lanes_render
test_unreadable_malformed_and_unmapped_sources_stay_unavailable
test_source_configuration_and_count_failures_are_named
test_daily_fleet_line_names_helper_failures_before_source_count
test_relative_source_commands_resolve_against_fm_home
test_metrics_use_individual_freshness_windows
test_shared_provenance_refuses_and_authorized_single_source_labels
test_malformed_metric_declarations_are_named
test_daily_sources_require_independent_provenance
test_stale_and_failed_cross_check_are_refused
test_currency_and_units_are_preserved
test_fleet_cost_requires_independent_sources
test_daily_fleet_line_requires_readable_sources
test_daily_fleet_line_cross_checks_per_crew_cost_and_validation_runs
test_live_helper_timestamps_are_fresh
test_untrusted_metric_states_and_duplicate_sources_are_refused
test_stale_quota_provider_state_is_refused
test_malformed_source_containers_render_unavailable
test_stale_third_provider_window_reaches_the_lane_header
test_observations_are_rechecked_at_publication
test_quota_percentages_must_be_in_range
test_malformed_source_timeouts_render_unavailable
test_empty_quota_provider_list_is_unavailable
test_quota_provider_without_refresh_time_is_unavailable
test_daily_fleet_line_refuses_currency_disagreement
test_daily_fleet_line_refuses_roster_disagreement
test_daily_fleet_line_renders_corroborated_empty_roster_as_zero
test_malformed_ledger_date_is_refused
test_backfilled_ledger_date_refuses_quota_windows
test_daily_fleet_line_refuses_unsupported_currency
test_daily_fleet_line_publishes_mixed_labels_as_estimated
