#!/usr/bin/env bash
# Brief helper-script preflight shared by bin/fm-spawn.sh.
#
# Usage after sourcing: fm_brief_refuse_missing_helper_scripts <brief> <worktree>
#
# A brief can outlive the checkout it was written for.  This detects helper
# references in executable instructions while leaving explicitly descriptive
# and prohibitive prose alone.  The parser recognizes bin/, ./bin/,
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

sub clause_prefix {
  my ($text, $start) = @_;
  my $prefix = substr($text, 0, $start);
  $prefix =~ s/^.*(?:[;!?]|\.\s+)\s*//s;
  $prefix =~ s/^\s*(?:(?:[-*+] | \d+[.)]\s+))//x;
  $prefix =~ s/^.*,\s*//s;
  return $prefix;
}

sub is_instruction {
  my ($text, $start, $in_fence) = @_;
  return 1 if $in_fence;
  my $prefix = clause_prefix($text, $start);
  $prefix =~ s/`+\s*$//;
  $prefix =~ s/^\s+|\s+$//g;
  return 1 if $prefix eq '' || $prefix =~ /^\$\s*$/;
  return 1 if $prefix =~ /\bdon['’]t\s+forget\b/i;
  return 0 if $prefix =~ /\b(?:do\s+not|don['’]t|must\s+not|must\s+never|should\s+not|never|avoid)\b/i;
  return 1 if $prefix =~ /\b(?:must|shall|should|need(?:s)?\s+to|required\s+to|have\s+to)\b/i;
  return 1 if $prefix =~ /\b(?:make\s+sure\s+to|ensure\s+you)\b/i;
  my $sequence = qr/(?:please|first|initially|next|then|subsequently|afterwards?|finally|lastly|instead)/i;
  my $verb = qr/[A-Za-z][A-Za-z0-9'’_-]*/;
  return 1 if $prefix =~ /^(?:$sequence\s+)*$verb(?:\s+(?:and|then)\s+$verb)*$/i;
  return 0;
}

sub emit_scripts {
  my ($text, $in_fence) = @_;
  while ($text =~ /$script/g) {
    my ($raw, $basename, $start) = ($1, $2, $-[1]);
    print "$raw\t$basename\n" if is_instruction($text, $start, $in_fence);
  }
}

my $in_fence = 0;
while (my $line = <$fh>) {
  emit_scripts($line, $in_fence);
  $in_fence = !$in_fence if $line =~ /^\s*```/;
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
