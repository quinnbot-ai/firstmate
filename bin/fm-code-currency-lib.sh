# shellcheck shell=bash
# Shared "landed is not running" check for a firstmate code root.
# Usage: . bin/fm-code-currency-lib.sh
#
# Firstmate never self-updates. A change merged to the default branch reaches a
# running home only when the captain runs /updatefirstmate (bin/fm-update.sh),
# so "merged" and "running here" are two different facts and nothing else in the
# session-start digest separates them. This library is the one place that does:
# it compares the commit actually checked out in a code root against the default
# branch that root follows, and reports the gap.
#
# The comparison is deliberately LOCAL and never fetches. It reads the
# already-present remote-tracking ref, so the reported gap is a FLOOR - the code
# root is at least that far behind, and possibly further if the ref itself is
# stale. A floor is the honest number here: it can understate the gap but never
# invent one, and it keeps the check free, offline-safe, and usable by a
# read-only session that holds no fleet lock.
#
# HEAD, not the default-branch ref, is the subject: HEAD is what the home is
# actually running. A primary checkout normally has them equal; a secondmate
# home sits at a detached HEAD; and a primary stranded on a feature branch
# (the tangle of fm-tangle-lib.sh) is still running that tree.
#
# This library only reports. It never fetches, updates, or fast-forwards
# anything - holding at an older commit is a captain decision, and a home may be
# pinned there on purpose.

# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tangle-lib.sh"

# Path globs whose changes are worth naming by file rather than leaving inside a
# commit count: the refusal machinery a reader is most likely to assume is
# already protecting them. The list widens attention and is never a guarantee -
# an unlisted path can still matter, and a listed one can change harmlessly. Its
# job is to turn "20 commits behind" into "the merge refusal and the teardown
# refusal are among what is not running here".
# It is an ARRAY, and each glob is quoted, because the patterns must survive to
# the match as patterns. A plain string expanded through word splitting is also
# pathname-expanded against the current directory first, which silently swaps
# these globs for whatever the CURRENT checkout happens to contain - and the
# files that matter most here are the ones a missing commit ADDS, which the
# current checkout does not have yet.
FM_CODE_CURRENCY_GUARD_PATTERNS=(
  'bin/*guard*'
  'bin/*lock*'
  'bin/*merge*'
  'bin/*teardown*'
  'bin/*verify*'
  'bin/*refuse*'
  'bin/*policy*'
  'bin/*pretool*'
  'bin/*isolation*'
  'bin/*obligations*'
  'bin/*binding*'
  'bin/*scope*'
  'bin/*spawn*'
  'bin/*trust*'
  'bin/*check-register*'
  '.github/workflows/*'
)

# How many guard paths to name before collapsing the rest into a count.
FM_CODE_CURRENCY_GUARD_SHOWN=4

# fm_code_currency_base_ref <root>
# Echo the remote-tracking ref the code at <root> follows ("origin/main"), or
# return 1 when there is nothing to compare against - no origin, a default
# branch that cannot be resolved, or a branch never fetched. Returning 1 is the
# quiet path on purpose: a standalone or never-fetched checkout has no evidence
# of being behind, and inventing a complaint from missing evidence is worse than
# saying nothing.
fm_code_currency_base_ref() {
  local root=$1 default
  default=$(fm_default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$default" >/dev/null 2>&1 || return 1
  printf 'origin/%s\n' "$default"
}

# fm_code_currency_guard_files <root> <base_ref>
# Echo, one per line, the guard paths (above) that differ between the commit at
# HEAD and <base_ref>, in git's own path order.
fm_code_currency_guard_files() {
  local root=$1 base=$2 path pat
  git -C "$root" diff --name-only "HEAD...$base" 2>/dev/null | while IFS= read -r path; do
    for pat in "${FM_CODE_CURRENCY_GUARD_PATTERNS[@]}"; do
      # shellcheck disable=SC2254  # unquoted here on purpose: $pat is the pattern
      case "$path" in
        $pat) printf '%s\n' "$path"; break ;;
      esac
    done
  done
}

# fm_code_currency_line <root>
# Echo the single CODE_STALE diagnostic line when the code checked out at <root>
# is behind the default branch it follows, and echo nothing (returning 1) for
# every other state: not a git work tree, nothing to compare against, already
# current, or ahead only. Silence is the common case and must stay cheap - a
# line that also appeared on a current home would train the reader to skim past
# the one case it exists for.
fm_code_currency_line() {
  local root=$1 base behind head_sha base_sha guard guard_count shown more guard_text
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  base=$(fm_code_currency_base_ref "$root") || return 1
  behind=$(git -C "$root" rev-list --count "HEAD..$base" 2>/dev/null) || return 1
  case "$behind" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$behind" -gt 0 ] || return 1
  head_sha=$(git -C "$root" rev-parse --short=7 HEAD 2>/dev/null) || return 1
  base_sha=$(git -C "$root" rev-parse --short=7 "$base" 2>/dev/null) || return 1

  guard=$(fm_code_currency_guard_files "$root" "$base")
  if [ -n "$guard" ]; then
    guard_count=$(printf '%s\n' "$guard" | wc -l | tr -d ' ')
    shown=$(printf '%s\n' "$guard" | head -n "$FM_CODE_CURRENCY_GUARD_SHOWN" | paste -sd, - | sed 's/,/, /g')
    more=$((guard_count - FM_CODE_CURRENCY_GUARD_SHOWN))
    if [ "$more" -gt 0 ]; then
      guard_text=", changing guard paths: $shown (+$more more)"
    else
      guard_text=", changing guard paths: $shown"
    fi
  else
    guard_text="; no guard path changes among them"
  fi

  printf 'CODE_STALE: running code (%s) is at least %s commit(s) behind %s (%s) as last fetched%s. Landed is not running - firstmate never updates itself, so those changes are inactive here until the captain approves an update.\n' \
    "$head_sha" "$behind" "$base" "$base_sha" "$guard_text"
}
