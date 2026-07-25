#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-unit-economics-kdp-source)
BIN="$ROOT/bin/fm-unit-economics-kdp-source.mjs"

write_fixture() {
  local root=$1
  mkdir -p "$root/monthly"
  cat > "$root/kdp-current.json" <<'JSON'
{"ts":"2026-07-25T13:40:02+00:00","payment_summary":{"status":"LIVE","lifetime_confirmed_usd":29.28}}
JSON
  cat > "$root/monthly/monthly-2026-04.md" <<'MD'
### Revenue
| Stream | April 2026 | Notes |
| KDP / Amazon | **$6.14** | confirmed |
### Expenses
MD
  cat > "$root/monthly/monthly-2026-05.md" <<'MD'
### Revenue
| Stream | May 2026 | Notes |
| KDP / Amazon | **$23.14** | confirmed |
### Expenses
MD
  cat > "$root/monthly/monthly-2026-06.md" <<'MD'
### Revenue
| Stream | June 2026 | Notes |
| KDP / Amazon | **$0.00** (unconfirmed) | no deposit found |
### Expenses
MD
}

test_artifact_source() {
  local root="$TMP_ROOT/artifact"
  write_fixture "$root"
  node "$BIN" artifact --current "$root/kdp-current.json" | jq -e '
    .observedAt == "2026-07-25T13:40:02+00:00"
    and .metrics.royalties.amount == 29.28
    and .metrics.royalties.status == "measured"
  ' >/dev/null || fail "artifact source did not preserve the confirmed royalty total"
  pass "artifact source emits the current confirmed royalty total"
}

test_finance_report_source() {
  local root="$TMP_ROOT/finance"
  write_fixture "$root"
  node "$BIN" finance-reports --finance-vault "$root" | jq -e '
    .currency == "USD"
    and .metrics.royalties.amount == 29.28
    and .metrics.royalties.unit == "USD"
  ' >/dev/null || fail "finance-report source did not independently total confirmed revenue rows"
  pass "finance-report source excludes unconfirmed zero rows"
}

test_artifact_source
test_finance_report_source
