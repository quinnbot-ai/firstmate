#!/usr/bin/env bash
# fm-skill-trigger-lint.sh - warn about skill descriptions used for routing.
#
# This advisory checker parses only SKILL.md frontmatter under the two canonical
# skill roots, prints deterministic path-owned findings, and never edits files.
# It returns zero for warnings; unsafe or unreadable roots are refused with 2.
# The bounded heuristics flag instruction dumps, missing trigger wording, and
# two-or-more distinctive words shared by adjacent skills.
#
# Usage:
#   fm-skill-trigger-lint.sh                 inspect .agents/skills and skills
#   fm-skill-trigger-lint.sh --root <path>   inspect one or more explicit roots
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SELF_DIR/fm-skill-trigger-lint.py" "$@"
