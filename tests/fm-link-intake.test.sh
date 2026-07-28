#!/usr/bin/env bash
# Behavior tests for durable, private, idempotent link-intake records.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-link-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-link-intake)
REAL_MV=$(command -v mv)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

run_intake() {  # <home> <arguments...>
  local home=$1
  shift
  FM_HOME="$home" "$INTAKE" "$@"
}

make_failing_mv() {  # <home>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
destination=
for argument in "$@"; do
  destination=$argument
done
if [ "$destination" = "${FM_FAIL_MOVE_DEST:-}" ] && [ ! -e "${FM_FAIL_MOVE_ONCE:?}" ]; then
  : > "$FM_FAIL_MOVE_ONCE"
  exit 1
fi
if [ "$destination" = "${FM_SIGNAL_MOVE_DEST:-}" ] && [ ! -e "${FM_SIGNAL_MOVE_ONCE:?}" ]; then
  : > "$FM_SIGNAL_MOVE_ONCE"
  "${FM_REAL_MV:?}" "$@"
  status=$?
  kill -TERM "$PPID"
  exit "$status"
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$fakebin/mv"
  printf '%s\n' "$fakebin"
}

record_for() {  # <home> <url>
  local home=$1 url=$2
  run_intake "$home" validate "$url" >/dev/null || fail 'expected record did not validate'
  find "$home/data/link-intake/records" -type f -name '*.md' | head -1
}

test_canonical_duplicate_converges_and_preserves_evidence() {
  local home first second record history count
  home=$(make_home duplicate)
  first=$(run_intake "$home" upsert --url 'HTTPS://Example.com:443/watch?b=2#chapter' --source-type web --title 'First title' --summary 'A searchable first summary.' --terms 'first,example' --claim 'First claim.') \
    || fail 'first URL intake failed'
  second=$(run_intake "$home" upsert --url 'https://example.com/watch?b=2' --source-type web --title 'Updated title' --summary 'A newer searchable summary.' --terms 'updated,example' --claim 'Updated claim.') \
    || fail 'duplicate URL intake failed'
  [ "$first" = "$second" ] || fail 'canonical duplicate created a second record path'
  count=$(find "$home/data/link-intake/records" -type f -name '*.md' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail 'canonical duplicate created multiple records'
  record=$second
  assert_grep 'Canonical URL: https://example.com/watch?b=2' "$record" 'canonical URL was not normalized'
  assert_grep '- HTTPS://Example.com:443/watch?b=2#chapter' "$record" 'first original URL was not retained'
  assert_grep '- https://example.com/watch?b=2' "$record" 'second original URL was not retained'
  assert_grep 'Updated title' "$record" 'current title was not updated'
  history=$(find "$home/data/link-intake/history" -type f -name '*.md' | head -1)
  assert_present "$history" 'replaced record did not retain an immutable history snapshot'
  assert_grep 'First title' "$history" 'history snapshot lost prior evidence'
  pass 'canonical duplicate convergence retains original URLs and prior evidence'
}

test_titles_summaries_claims_and_terms_are_searchable() {
  local home record index
  home=$(make_home searchable)
  run_intake "$home" upsert --url 'https://example.org/research' --source-type article --title 'Research Title' --summary 'Concise searchable summary of the research.' --terms 'research,searchable,summary' --claim 'The source makes a testable claim.' >/dev/null \
    || fail 'searchable intake failed'
  record=$(record_for "$home" 'https://example.org/research')
  index="$home/data/link-intake/index.tsv"
  assert_grep 'Title: Research Title' "$record" 'record title is missing'
  assert_grep 'Summary: Concise searchable summary of the research.' "$record" 'record summary is missing'
  assert_grep '- The source makes a testable claim.' "$record" 'record claim is missing'
  assert_grep 'Search terms: research,searchable,summary' "$record" 'record terms are missing'
  assert_grep 'research,searchable,summary' "$index" 'searchable terms are absent from index'
  pass 'titles, summaries, claims, and terms are durably searchable'
}

test_inaccessible_links_remain_visible_and_valid() {
  local home record
  home=$(make_home inaccessible)
  run_intake "$home" upsert --url 'https://private.example.test/item' --source-type document --failure 'HTTP 403 private source' >/dev/null \
    || fail 'inaccessible intake failed'
  record=$(record_for "$home" 'https://private.example.test/item')
  assert_grep 'Retrieval status: inaccessible' "$record" 'inaccessible status is missing'
  assert_grep 'Title: Unavailable' "$record" 'inaccessible record lacks a visible title outcome'
  assert_grep 'Failure: HTTP 403 private source' "$record" 'inaccessible reason is missing'
  assert_grep 'Canonical URL: https://private.example.test/item' "$record" 'inaccessible original was not retained'
  pass 'inaccessible links retain a validated visible failure record'
}

test_video_transcript_metadata_is_durable() {
  local home transcript record transcript_path
  home=$(make_home transcript)
  transcript="$home/source-transcript.txt"
  printf 'A legally accessible transcript.\n' > "$transcript"
  run_intake "$home" upsert --url 'https://video.example.test/watch?v=42' --source-type video --title 'Video title' --summary 'A short video summary.' --terms 'video,transcript' --claim 'The video makes a claim.' --transcript-file "$transcript" >/dev/null \
    || fail 'video transcript intake failed'
  record=$(record_for "$home" 'https://video.example.test/watch?v=42')
  transcript_path=$(sed -n 's/^Transcript: stored at //p' "$record")
  [ -n "$transcript_path" ] || fail 'record did not store transcript metadata'
  assert_present "$home/data/link-intake/$transcript_path" 'durable transcript path is missing'
  assert_grep 'A legally accessible transcript.' "$home/data/link-intake/$transcript_path" 'durable transcript body is wrong'
  rm "$home/data/link-intake/$transcript_path"
  if run_intake "$home" validate 'https://video.example.test/watch?v=42' > "$home/missing-path.out" 2> "$home/missing-path.err"; then
    fail 'validation accepted missing durable transcript content'
  fi
  assert_grep 'record transcript path is absent' "$home/missing-path.err" 'missing transcript path failure was not visible'
  if run_intake "$home" upsert --url 'https://video.example.test/no-transcript' --source-type video --title 'Video without transcript' --summary 'No transcript is accessible.' --terms 'video,unavailable' --claim 'Transcript is unavailable.' > "$home/missing.out" 2> "$home/missing.err"; then
    fail 'video intake accepted missing transcript metadata'
  fi
  assert_grep 'transcript-unavailable reason is required' "$home/missing.err" 'missing transcript failure was not visible'
  pass 'video records retain transcripts and reject silent omissions'
}

test_atomic_updates_restore_record_and_index_on_publication_failure() {
  local home record index fakebin before_record before_index after_record after_index failure_marker rc=0
  home=$(make_home atomic)
  run_intake "$home" upsert --url 'https://atomic.example.test/page' --source-type web --title 'Atomic title' --summary 'Initial complete summary.' --terms 'atomic,initial' --claim 'Initial claim.' >/dev/null \
    || fail 'initial atomic intake failed'
  record=$(record_for "$home" 'https://atomic.example.test/page')
  index="$home/data/link-intake/index.tsv"
  fakebin=$(make_failing_mv "$home")
  before_record=$(shasum -a 256 "$record" | awk '{print $1}')
  before_index=$(shasum -a 256 "$index" | awk '{print $1}')
  failure_marker="$home/record-move-failed"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" \
    FM_FAIL_MOVE_DEST="$record" FM_FAIL_MOVE_ONCE="$failure_marker" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type web --title 'Record failure' --summary 'Valid update that cannot publish.' --terms 'atomic,record' --claim 'Record move fails.' > "$home/record-failure.out" 2> "$home/record-failure.err"; then
    fail 'record publication failure unexpectedly succeeded'
  fi
  after_record=$(shasum -a 256 "$record" | awk '{print $1}')
  after_index=$(shasum -a 256 "$index" | awk '{print $1}')
  [ "$before_record" = "$after_record" ] || fail 'record publication failure changed the prior record'
  [ "$before_index" = "$after_index" ] || fail 'record publication failure changed the prior index'
  failure_marker="$home/index-move-failed"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" \
    FM_FAIL_MOVE_DEST="$index" FM_FAIL_MOVE_ONCE="$failure_marker" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type web --title 'Index failure' --summary 'Valid update that must roll back.' --terms 'atomic,index' --claim 'Index move fails.' > "$home/index-failure.out" 2> "$home/index-failure.err"; then
    fail 'index publication failure unexpectedly succeeded'
  fi
  after_record=$(shasum -a 256 "$record" | awk '{print $1}')
  after_index=$(shasum -a 256 "$index" | awk '{print $1}')
  [ "$before_record" = "$after_record" ] || fail 'index publication failure did not restore the prior record'
  [ "$before_index" = "$after_index" ] || fail 'index publication failure did not preserve the prior index'
  failure_marker="$home/record-move-signaled"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" \
    FM_SIGNAL_MOVE_DEST="$record" FM_SIGNAL_MOVE_ONCE="$failure_marker" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type web --title 'Interrupted update' --summary 'Valid update interrupted during publication.' --terms 'atomic,signal' --claim 'The signal terminates publication.' > "$home/signal.out" 2> "$home/signal.err" || rc=$?
  [ "$rc" = 143 ] || fail "TERM during publication should exit 143, got $rc"
  after_record=$(shasum -a 256 "$record" | awk '{print $1}')
  after_index=$(shasum -a 256 "$index" | awk '{print $1}')
  [ "$before_record" = "$after_record" ] || fail 'TERM during publication did not restore the prior record'
  [ "$before_index" = "$after_index" ] || fail 'TERM during publication changed the prior index'
  [ ! -d "$home/data/link-intake/.update-lock" ] || fail 'TERM left the update lock held'
  ! find "$home/data/link-intake" \( -name '.record.*' -o -name '.index.*' -o -name '*-backup.*' \) | grep . >/dev/null \
    || fail 'publication rollback left transaction files'
  run_intake "$home" validate --all >/dev/null || fail 'restored state failed validation'
  pass 'record and index publication failures restore the prior state'
}

test_validation_rejects_bidirectional_divergence() {
  local home other record orphan
  home=$(make_home divergence)
  other=$(make_home divergence-other)
  run_intake "$home" upsert --url 'https://consistent.example.test/page' --source-type web --title 'Consistent' --summary 'Initially consistent state.' --terms 'consistent' --claim 'The state starts consistent.' >/dev/null \
    || fail 'consistent intake failed'
  run_intake "$other" upsert --url 'https://orphan.example.test/page' --source-type web --title 'Orphan' --summary 'Record not present in the first index.' --terms 'orphan' --claim 'The copied record is unindexed.' >/dev/null \
    || fail 'orphan fixture intake failed'
  orphan=$(find "$other/data/link-intake/records" -type f -name '*.md' | head -1)
  cp "$orphan" "$home/data/link-intake/records/"
  if run_intake "$home" validate --all > "$home/orphan.out" 2> "$home/orphan.err"; then
    fail 'validation accepted a record absent from the index'
  fi
  assert_grep 'record is absent from index' "$home/orphan.err" 'orphan record failure was not visible'
  rm "$home/data/link-intake/records/${orphan##*/}"
  record=$(record_for "$home" 'https://consistent.example.test/page')
  rm "$record"
  if run_intake "$home" validate --all > "$home/missing-record.out" 2> "$home/missing-record.err"; then
    fail 'validation accepted an index entry without its record'
  fi
  assert_grep 'record is absent' "$home/missing-record.err" 'missing indexed record failure was not visible'
  pass 'validation rejects divergence in both index-to-record directions'
}

test_odd_urls_never_control_filenames_or_shell() {
  local home record files
  home=$(make_home odd-url)
  run_intake "$home" upsert --url 'https://EXAMPLE.test/a/../../%24%28touch%20nope%29?x=%3B%26' --source-type web --title 'Odd URL title' --summary 'Odd but valid URL summary.' --terms 'odd,url' --claim 'Odd URL remains data.' >/dev/null \
    || fail 'odd URL intake failed'
  record=$(record_for "$home" 'https://example.test/a/../../%24%28touch%20nope%29?x=%3B%26')
  files=$(find "$home/data/link-intake/records" -type f -name '*.md' -exec basename {} \;)
  case "$files" in [0-9a-f][0-9a-f]*) ;; *) fail 'record filename is not a deterministic hexadecimal digest' ;; esac
  assert_grep 'Canonical URL: https://example.test/a/../../%24%28touch%20nope%29?x=%3B%26' "$record" 'odd URL was not retained as data'
  if run_intake "$home" upsert --url 'https://example.test/@unsafe' --canonical-url 'file:///tmp/nope' --source-type web --title 'Bad canonical' --summary 'Should reject.' --terms 'bad' --claim 'Bad.' > "$home/bad.out" 2> "$home/bad.err"; then
    fail 'non-HTTP canonical URL was accepted'
  fi
  assert_grep 'URL must use http or https' "$home/bad.err" 'unsafe canonical URL failure was not visible'
  pass 'odd URLs use digest paths and unsafe URL schemes are refused'
}

test_agents_trigger_is_concise_and_agent_agnostic() {
  local line
  line=$(grep -F 'Link intake:' "$ROOT/AGENTS.md" || true)
  [ -n "$line" ] || fail 'AGENTS link-intake trigger is absent'
  assert_contains "$line" 'captain sends meaningful URL input' 'trigger does not cover meaningful captain URLs'
  assert_contains "$line" 'bin/fm-link-intake.sh' 'trigger does not name the authoritative helper'
  [ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ] || fail 'AGENTS link-intake trigger is not one concise line'
  assert_not_contains "$line" 'Claude' 'trigger is not agent-agnostic'
  pass 'AGENTS has one concise agent-agnostic link-intake trigger'
}

test_canonical_duplicate_converges_and_preserves_evidence
test_titles_summaries_claims_and_terms_are_searchable
test_inaccessible_links_remain_visible_and_valid
test_video_transcript_metadata_is_durable
test_atomic_updates_restore_record_and_index_on_publication_failure
test_validation_rejects_bidirectional_divergence
test_odd_urls_never_control_filenames_or_shell
test_agents_trigger_is_concise_and_agent_agnostic
