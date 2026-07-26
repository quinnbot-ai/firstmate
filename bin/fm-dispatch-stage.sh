#!/usr/bin/env bash
# Seal one firstmate-authored, currently ready task for report-only dispatch.
#
# The caller must be a descendant of the verified harness that owns this exact
# home's firstmate session lock.
# Firstmate supplies a concrete launch profile already selected under AGENTS.md
# section 4; this helper never matches prose or interprets quota data.
# Usage:
#   fm-dispatch-stage.sh <id> --repo <repo> --kind <ship|scout> \
#     --harness <harness> [--model <model>] [--effort <effort>] \
#     --herdr-lifecycle <none|guarded>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-auto-dispatch.mjs" stage "$@"
