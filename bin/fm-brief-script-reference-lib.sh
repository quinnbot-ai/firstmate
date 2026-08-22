#!/usr/bin/env bash
# Brief helper-script preflight shared by bin/fm-spawn.sh.
#
# Usage after sourcing: fm_brief_refuse_missing_helper_scripts <brief> <worktree>
#
# A brief can outlive the checkout it was written for.  This detects only helper
# scripts the worker is directed to execute: any bin/fm-*.sh path in a fenced
# code block, or one on an inline command-style line beginning with run, call,
# use, invoke, execute, source, or start.  Plain descriptive mentions
# deliberately do not block dispatch, because a false refusal is worse than an
# advisory historical reference.  The parser recognizes bin/, ./bin/,
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

  next unless $line =~ /^\s*(?:[-*+]\s+|\d+[.)]\s+)?(?:please\s+)?(?:(?:then|next)\s+)?(?:run|call|use|invoke|execute|source|start)\b/i;
  next if $line =~ /^\s*(?:[-*+]\s+|\d+[.)]\s+)?(?:please\s+)?(?:do\s+not|don't|never)\s+(?:run|call|use|invoke|execute|source|start)\b/i;
  while ($line =~ /`([^`]+)`/g) {
    emit_scripts($1);
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
