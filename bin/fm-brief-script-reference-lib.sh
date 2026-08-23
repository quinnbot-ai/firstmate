#!/usr/bin/env bash
# Brief helper-script preflight shared by bin/fm-spawn.sh.
#
# Usage after sourcing: fm_brief_refuse_missing_helper_scripts <brief> <worktree>
#
# A brief can outlive the checkout it was written for.  This detects every
# syntactic bin/fm-*.sh helper reference rather than interpreting open-ended
# natural language to decide which mentions are executable.  The parser
# recognizes bin/, ./bin/,
# $FM_ROOT/bin, and ${FM_ROOT}/bin forms, then resolves every reference to the
# task worktree's bin/ directory.  A helper basename spans from fm- through the
# last .sh before a slash, whitespace, NUL, quote, or backtick delimiter.  It
# never evaluates arbitrary brief text as shell code.

fm_brief_helper_script_references() {  # <brief> -> "raw-reference<TAB>basename" lines
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $brief = shift;
open my $fh, '<', $brief or die "$brief: $!\n";
my $script = qr{
  (?<![A-Za-z0-9_.-])
  (
    (?:
      \$FM_ROOT/ |
      \$\{FM_ROOT\}/ |
      \./ |
      (?:\.\./)+ |
      /[^\s`'"]*/
    )?
    bin/
    (fm-[^/\s\x00`'"]*\.sh)
  )
}x;

sub emit_scripts {
  my ($text) = @_;
  while ($text =~ /$script/g) {
    print "$1\t$2\n";
  }
}

while (my $line = <$fh>) {
  emit_scripts($line);
}
PERL
}

fm_brief_refuse_missing_helper_scripts() {  # <brief> <task-worktree>
  local brief=$1 worktree=$2 references raw basename resolved missing=0 seen=$'\n'
  if ! references=$(fm_brief_helper_script_references "$brief"); then
    printf 'error: could not inspect brief helper references in %s; refusing dispatch\n' "$brief" >&2
    return 1
  fi
  [ -n "$references" ] || return 0
  while IFS=$'\t' read -r raw basename; do
    [ -n "$basename" ] || continue
    case "$seen" in
      *$'\n'"$basename"$'\n'*) continue ;;
    esac
    seen="${seen}${basename}"$'\n'
    resolved="$worktree/bin/$basename"
    if [ ! -f "$resolved" ]; then
      printf 'error: brief helper reference %s resolves in this task worktree to %s, but that script is absent; refusing dispatch\n' \
        "$raw" "$resolved" >&2
      missing=1
    fi
  done <<< "$references"
  return "$missing"
}
