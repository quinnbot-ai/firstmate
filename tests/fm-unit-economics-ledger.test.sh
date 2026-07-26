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
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable")' "$out" >/dev/null || fail "unavailable lane was not honest"
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
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .source_freshness=="stale source refused")' "$out" >/dev/null || fail "stale financial source was not refused"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":1,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":2,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .cross_check=="failed")' "$out" >/dev/null || fail "failed cross-check was presented as fact"
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
  jq -e --arg date "$date" '(.schema == "fleet-unit-economics-ledger.v2") and ([.lanes[] | select(.id=="fleet_operations") | .daily_fleet_line | select(.date==$date and .session_cost.amount==null and .session_cost.status=="unavailable" and .validation_run_volume.amount==null and .validation_run_volume.status=="unavailable")] | length == 1)' "$out" >/dev/null || fail "missing daily sources were rendered as a number instead of unavailable"
  grep -F 'unavailable (source unavailable)' "${out%.json}.md" >/dev/null || fail "daily Markdown line hid the unavailable source"
  pass "daily fleet line renders missing sources as unavailable rather than zero"
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
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable")' "$out" >/dev/null || fail "untrusted metric statuses were published"
  write_source "$one" "{\"observedAt\":\"$NOW\",\"currency\":\"USD\",\"metrics\":{\"pipeline_cost\":{\"amount\":4,\"unit\":\"USD\",\"status\":\"measured\"},\"realized_revenue\":{\"amount\":8,\"unit\":\"USD\",\"status\":\"measured\"}}}"
  write_config "$config" weho "$one" "$one"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .cross_check=="unavailable")' "$out" >/dev/null || fail "duplicate command arrays satisfied independent corroboration"
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

test_malformed_source_containers_render_unavailable() {
  local config="$TMP_ROOT/malformed/config.json" out="$TMP_ROOT/malformed/out.json" quota="$TMP_ROOT/malformed/quota"
  mkdir -p "$(dirname "$config")"
  printf '%s\n' '{"lanes":{"weho":{"sources":{}},"fleet_operations":{"cost_sources":"invalid"}}}' > "$config"
  write_quota "$quota" "$NOW"; run_ledger "$config" "$out" "$quota"
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null)' "$out" >/dev/null || fail "malformed lane sources prevented unavailable rendering"
  jq -e '.lanes[] | select(.id=="fleet_operations") | .metrics[] | select(.name=="attributable_crew_session_cost" and .amount==null)' "$out" >/dev/null || fail "malformed cost sources prevented unavailable rendering"
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
  jq -e '.lanes[] | select(.id=="weho") | .metrics[] | select(.name=="realized_revenue" and .amount==null and .status=="unavailable")' "$out" >/dev/null || fail "malformed source timeouts were not rendered unavailable"
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

test_zero_revenue_is_explicit_and_cross_checked
test_unavailable_and_partial_lanes_render
test_stale_and_failed_cross_check_are_refused
test_currency_and_units_are_preserved
test_fleet_cost_requires_independent_sources
test_daily_fleet_line_requires_readable_sources
test_daily_fleet_line_cross_checks_per_crew_cost_and_validation_runs
test_live_helper_timestamps_are_fresh
test_untrusted_metric_states_and_duplicate_sources_are_refused
test_stale_quota_provider_state_is_refused
test_malformed_source_containers_render_unavailable
test_observations_are_rechecked_at_publication
test_quota_percentages_must_be_in_range
test_malformed_source_timeouts_render_unavailable
test_empty_quota_provider_list_is_unavailable
test_quota_provider_without_refresh_time_is_unavailable
test_daily_fleet_line_refuses_currency_disagreement
test_daily_fleet_line_renders_corroborated_empty_roster_as_zero
test_malformed_ledger_date_is_refused
test_backfilled_ledger_date_refuses_quota_windows
test_daily_fleet_line_refuses_unsupported_currency
test_daily_fleet_line_publishes_mixed_labels_as_estimated
