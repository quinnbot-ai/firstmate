#!/usr/bin/env bash
# fm-crew-claude-quota.sh - safely measure the configured Claude crew profile.
#
# Usage:
#   fm-crew-claude-quota.sh
#
# The configured profile is the first non-empty, non-comment line of
# config/crew-claude-profile under the effective firstmate config directory.
# This script passes that directory only to quota-axi through
# CLAUDE_CONFIG_DIR, never falls back to the seat's default profile, and gives
# quota-axi an ephemeral cache directory.  Its provider cache is otherwise
# keyed only by provider, so sharing it would permit a crew probe to reuse the
# seat's stale Claude result or overwrite the seat's cached result.
#
# stdout is exactly one redacted result:
#   status=healthy headroom_percent=<0-100>
#   status=exhausted headroom_percent=0
#   status=absent
#   status=unmeasurable
#
# absent means that the configured profile is not present or quota-axi reports
# that the profile has no usable Claude authentication.  unmeasurable covers
# denied Keychain access, a timeout, stale quota, malformed producer output,
# and every other result that cannot establish a fresh numeric headroom.  It is
# deliberately distinct from exhausted, which is a fresh measured zero.
#
# No raw quota-axi output reaches stdout, stderr, a log, a shell argument, or a
# persistent cache.  In particular, account identity and credential material
# are neither rendered nor retained by this wrapper.
#
# Environment:
#   FM_HOME                         firstmate home (defaults to this repo)
#   FM_ROOT_OVERRIDE                firstmate home fallback
#   FM_CONFIG_OVERRIDE              alternate config directory, mainly tests
#   FM_CREW_CLAUDE_QUOTA_TIMEOUT    positive command bound in seconds (default 75)
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROFILE_CONFIG="$CONFIG/crew-claude-profile"

usage() {
  cat <<'EOF'
fm-crew-claude-quota.sh - safely measure the configured Claude crew profile

Usage:
  fm-crew-claude-quota.sh

Prints exactly one sanitized result:
  status=healthy headroom_percent=<0-100>
  status=exhausted headroom_percent=0
  status=absent
  status=unmeasurable

The probe uses only config/crew-claude-profile and an ephemeral quota-axi
cache, so it cannot use or replace the seat's cached Claude reading.
EOF
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *)
    printf 'fm-crew-claude-quota: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

emit() {
  printf 'status=%s' "$1"
  if [ "$1" = healthy ] || [ "$1" = exhausted ]; then
    printf ' headroom_percent=%s' "$2"
  fi
  printf '\n'
  exit 0
}

# The runner is shared so this bounded probe has the same whole-process-group
# timeout semantics as the rest of the firstmate command surface.
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TIMEOUT=${FM_CREW_CLAUDE_QUOTA_TIMEOUT:-75}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=75 ;;
esac

# Do not use a data-directory fallback here.  A missing declaration must stay
# observable as absent rather than silently selecting a profile by convention.
[ -f "$PROFILE_CONFIG" ] && [ ! -L "$PROFILE_CONFIG" ] || emit absent
PROFILE=$(awk '!/^[[:space:]]*(#|$)/ { print; exit }' "$PROFILE_CONFIG" 2>/dev/null) || emit absent
[ -n "$PROFILE" ] || emit absent
case "$PROFILE" in
  /*) ;;
  *) PROFILE="$CONFIG/$PROFILE" ;;
esac
[ -d "$PROFILE" ] && [ ! -L "$PROFILE" ] || emit absent

# quota-axi's regular cache key is just "claude".  An ephemeral cache therefore
# prevents either account's response from becoming the other's stale fallback.
CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-claude-quota.XXXXXX" 2>/dev/null) || emit unmeasurable
# shellcheck disable=SC2329 # cleanup is invoked by the EXIT signal trap below.
cleanup() {
  rm -rf -- "$CACHE_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

RAW=
RAW=$(CLAUDE_CONFIG_DIR="$PROFILE" XDG_CACHE_HOME="$CACHE_DIR" \
  fm_run_timed "$TIMEOUT" quota-axi --provider claude --json --allow-keychain-prompt </dev/null 2>/dev/null) || :

# quota-axi returns non-zero for an all-failed provider request but can still
# render a structured auth-required report.  Classify valid JSON before using
# the command status, so an absent crew sign-in is named rather than opaque.
command -v jq >/dev/null 2>&1 || emit unmeasurable
PROVIDER=$(printf '%s' "$RAW" | jq -ce '[.providers[]? | select(.provider == "claude")] | if length == 1 then .[0] else empty end' 2>/dev/null) || emit unmeasurable
STATE=$(printf '%s' "$PROVIDER" | jq -r '.state.status // empty' 2>/dev/null) || emit unmeasurable
case "$STATE" in
  auth_required) emit absent ;;
  fresh) ;;
  *) emit unmeasurable ;;
esac

HEADROOM=$(printf '%s' "$PROVIDER" | jq -r '
  [ .quotaSemantics.effectiveAvailability[]?
    | select(.scope == "all_models" and .status == "known" and (.effectivePercentRemaining | type == "number"))
    | .effectivePercentRemaining
  ] | if length == 0 then empty else min end
' 2>/dev/null) || emit unmeasurable
case "$HEADROOM" in
  ''|*[!0-9.]*|.*.*) emit unmeasurable ;;
esac
jq -en --argjson value "$HEADROOM" '$value >= 0 and $value <= 100' >/dev/null 2>&1 || emit unmeasurable

if [ "$HEADROOM" = 0 ] || [ "$HEADROOM" = 0.0 ]; then
  emit exhausted 0
fi
emit healthy "$HEADROOM"
