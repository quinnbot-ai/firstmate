#!/usr/bin/env bash
# Brief helper-script preflight shared by bin/fm-spawn.sh.
#
# Usage after sourcing: fm_brief_refuse_missing_helper_scripts <brief> <worktree>
#
# A brief can outlive the checkout it was written for.  This detects only helper
# scripts the worker is directed to execute: any bin/fm-*.sh path in a fenced
# code block or an affirmative directive clause.  Explicitly negated,
# conditional, and descriptive mentions remain advisory rather than blocking
# dispatch.  The parser recognizes bin/, ./bin/,
# $FM_ROOT/bin, and ${FM_ROOT}/bin forms, then resolves every reference to the
# task worktree's bin/ directory.  It never evaluates arbitrary brief text as
# shell code.

fm_brief_helper_script_references() {  # <brief> -> "raw-reference<TAB>basename" lines
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $brief = shift;
open my $fh, '<', $brief or die "$brief: $!\n";
my $fence = '';
my $script = qr{
  (
    (?:
      \$FM_ROOT/ |
      \$\{FM_ROOT\}/ |
      \./ |
      (?:\.\./)+ |
      /[^\s`'"]*/
    )?
    bin/
    (fm-[A-Za-z0-9][A-Za-z0-9_-]*\.sh)
  )
}x;

sub emit_scripts {
  my ($text) = @_;
  while ($text =~ /$script/g) {
    print "$1\t$2\n";
  }
}

while (my $line = <$fh>) {
  if ($fence ne '') {
    if ($line =~ /^\s*\Q$fence\E/) {
      $fence = '';
    } else {
      emit_scripts($line);
    }
    next;
  }
  if ($line =~ /^\s*(`{3,}|~{3,})/) {
    $fence = $1;
    next;
  }

  my $lead = qr/^\s*(?:[-*+]\s+|\d+[.)]\s+)?/;
  for my $clause (split /\s*(?:;|\b(?:and|but|first|then|next|finally|instead)\b|[.!?]+(?=\s|$))\s*/i, $line) {
    while ($clause =~ /$script/g) {
      my ($raw, $basename, $reference_start) = ($1, $2, $-[1]);
      my $prefix = substr($clause, 0, $reference_start);
      $prefix =~ s/$lead//;
      next if $prefix =~ /\b(?:do\s+not|don't|never|not\s+to)\b/i;
      next if $prefix =~ /^\s*(?:if|when|whenever|whether)\b[^,:]*$/i;
      next if $prefix =~ /^\s*(?:the|a|an|this|that|these|those|it|he|she|they|we|i)\b/i;
      next if $prefix =~ /^\s*(?:for\s+example|e\.g\.|historically|in\s+(?:older|previous)\s+releases?)\b/i;
      print "$raw\t$basename\n";
    }
  }
}
PERL
}

fm_brief_refuse_missing_helper_scripts() {  # <brief> <task-worktree>
  local brief=$1 worktree=$2 raw basename resolved missing=0 seen=$'\n'
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
  done < <(fm_brief_helper_script_references "$brief")
  return "$missing"
}
