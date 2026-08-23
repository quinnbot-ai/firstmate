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
  $prefix =~ s/\[([^\]\r\n]+)\]\([^\)\r\n]*\)/$1/g;
  $prefix =~ s{(`+)([^`\r\n]+)\1}{$2}g;
  $prefix =~ s{(\*{1,3})([^*\r\n]+)\1}{$2}g;
  $prefix =~ s{(_{1,3})([^_\r\n]+)\1}{$2}g;
  $prefix =~ s{(~~)([^~\r\n]+)\1}{$2}g;
  $prefix =~ s/\[([^\]\r\n]+)\]\(\s*$/$1/;
  $prefix =~ s/(?:\*\*|__|~~|\*|_)\s*$//;
  $prefix =~ s/^.*(?:[;!?]|\.\s+)\s*//s;
  $prefix =~ s/^\s*(?:(?:[-*+] | \d+[.)]\s+))//x;
  $prefix =~ s/^.*,\s*//s;
  return $prefix;
}

sub is_directive_prefix {
  my ($prefix) = @_;
  my $ordering = qr/(?:please|first|initially|next|then|subsequently|afterwards?|finally|lastly|instead)/i;
  my $word = qr/[A-Za-z][A-Za-z0-9'’_-]*/;
  my $link = qr/(?:and|then|by|to|ahead\s+and)/i;
  my $directed_subject = qr/(?:you|the\s+(?:agent|operator|worker))/i;
  my $commission = qr/(?:i|we)\s+(?:ask|expect|need|require|want)\s+$directed_subject\s+to/i;
  my $request = qr/(?:can|could|would|will)\s+$directed_subject(?:\s+please)?/i;
  my $assurance = qr/(?:(?:make|be)\s+(?:sure|certain)\s+to|ensure(?:\s+that)?(?:\s+you)?|remember\s+to)/i;
  my $directive_verb = qr/(?:apply|begin|call|check|complete|consult|deploy|execute|follow|inspect|invoke|launch|load|open|perform|read|reference|rerun|retry|review|run|source|start|use|validate|verify)/i;
  my $executable_object = qr/(?:(?:the|a|an|this|that)\s+)?(?:$word\s+)*(?:helper|script|command|tool|utility|preflight|check|workflow)/i;
  my $path_modifier = qr/(?:$word\s+)*(?:at|in|under|within|from)/i;
  return 1 if $prefix =~ /^(?:$ordering\s+)*$word(?:\s+$link\s+$word)*$/i;
  return 1 if $prefix =~ /^$assurance\s+$word(?:\s+$link\s+$word)*$/i;
  return 1 if $prefix =~ /^$directed_subject\s+(?:are|will\s+be)\s+to\s+$word(?:\s+$link\s+$word)*$/i;
  return 1 if $prefix =~ /^$commission\s+$directive_verb(?:\s+$link\s+$word)*$/i;
  return 1 if $prefix =~ /^$request\s+$directive_verb(?:\s+$link\s+$word)*$/i;
  return 1 if $prefix =~ /^$directed_subject\s+(?:are|will\s+be)\s+to\s+$directive_verb(?:\s+$link\s+$word)*\s+$executable_object(?:\s+$path_modifier)?\s*:?$/i;
  return 1 if $prefix =~ /^$commission\s+$directive_verb(?:\s+$link\s+$word)*\s+$executable_object(?:\s+$path_modifier)?\s*:?$/i;
  return 1 if $prefix =~ /^$request\s+$directive_verb(?:\s+$link\s+$word)*\s+$executable_object(?:\s+$path_modifier)?\s*:?$/i;
  return $prefix =~ /^(?:$ordering\s+)*$directive_verb(?:\s+$link\s+$word)*\s+$executable_object(?:\s+$path_modifier)?\s*:?$/i;
}

sub is_instruction {
  my ($text, $start, $in_fence) = @_;
  return 1 if $in_fence;
  my $prefix = clause_prefix($text, $start);
  $prefix =~ s/`+\s*$//;
  $prefix =~ s/^\s+|\s+$//g;
  $prefix =~ s/^(?:step|phase|stage|task|action|instruction)\s+[^:\s]+\s*:\s*//i;
  $prefix =~ s/^((?:please\s+)?(?:run|execute|launch|invoke|call|use|start|begin|check)):\s*$/$1/i;
  return 1 if $prefix eq '' || $prefix =~ /^\$\s*$/;
  return 1 if $prefix =~ /\bdon['’]t\s+forget\b/i;
  return 0 if $prefix =~ /\b(?:do\s+not|don['’]t|must\s+not|must\s+never|should\s+not|never|avoid)\b/i;
  return 1 if $prefix =~ /\b(?:must|shall|should|need(?:s)?\s+to|required\s+to|have\s+to)\b/i;
  return 1 if $prefix =~ /^(?:your|the)\s+(?:(?:first|next|initial|required)\s+)?(?:action|step|task|instruction)\s+(?:is|will\s+be|must\s+be)\s+to\s+\S+(?:\s+\S+)*$/i;
  return 1 if is_directive_prefix($prefix);
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
