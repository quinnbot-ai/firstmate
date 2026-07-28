#!/usr/bin/env bash
# fm-link-intake.sh - idempotently store validated, private Firstmate link-intake records.
#
# Usage:
#   bin/fm-link-intake.sh upsert --url URL --source-type TYPE --title TITLE --summary SUMMARY --terms TERMS --claim TEXT [--claim TEXT ...] [--canonical-url URL] [--retrieved-at YYYY-MM-DD] [--transcript-file PATH | --transcript-unavailable REASON] [--failure REASON]
#   bin/fm-link-intake.sh validate <URL>
#   bin/fm-link-intake.sh validate --all
#   bin/fm-link-intake.sh --help
#
# Records and the searchable index live only in $FM_HOME/data/link-intake/.
# The helper owns their exact Markdown and TSV formats, canonicalization, validation,
# history snapshots, and atomic publication.
# It never retrieves pages, downloads media, authenticates, or makes external changes.
# A caller supplies only normalized public or otherwise authorized metadata after using
# the appropriate existing browser or media tool.
# Video and audio require either a transcript file to retain privately or an explicit
# unavailable reason, unless the retrieval itself failed, in which case that failure is
# recorded as the transcript reason too.
# Bash 3.2 compatible.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
LINK_ROOT="$FM_HOME/data/link-intake"
RECORDS_DIR="$LINK_ROOT/records"
TRANSCRIPTS_DIR="$LINK_ROOT/transcripts"
HISTORY_DIR="$LINK_ROOT/history"
INDEX_FILE="$LINK_ROOT/index.tsv"
LOCK_DIR="$LINK_ROOT/.update-lock"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage:
  bin/fm-link-intake.sh upsert --url URL --source-type TYPE --title TITLE --summary SUMMARY --terms TERMS --claim TEXT [--claim TEXT ...] [--canonical-url URL] [--retrieved-at YYYY-MM-DD] [--transcript-file PATH | --transcript-unavailable REASON] [--failure REASON]
  bin/fm-link-intake.sh validate <URL>
  bin/fm-link-intake.sh validate --all

Source types: article, web, video, audio, document, image, other.

`upsert` preserves every supplied original URL, snapshots a replaced record under
data/link-intake/history/, and prints the current record path.
`--failure` creates a visible inaccessible record when title, summary, claims, and
terms cannot be obtained.
For video or audio, provide a legally accessible `--transcript-file` or explain why
it is unavailable with `--transcript-unavailable`.
EOF
}

require_one_line() {  # <field> <value>
  local field=$1 value=$2
  [ -n "$value" ] || die "$field is required"
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "$field must be one line without tabs" ;;
  esac
}

sha256() {  # stdin -> hexadecimal digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    die 'shasum or sha256sum is required'
  fi
}

canonicalize_url() {  # <url> -> canonical URL
  local input=$1 without_fragment scheme rest authority suffix lowered_authority
  require_one_line URL "$input"
  without_fragment=${input%%#*}
  scheme=${without_fragment%%://*}
  case "$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')" in
    http|https) ;;
    *) die 'URL must use http or https' ;;
  esac
  rest=${without_fragment#*://}
  case "$rest" in
    */*)
      authority=${rest%%/*}
      suffix=/${rest#*/}
      ;;
    *\?*)
      authority=${rest%%\?*}
      suffix=?${rest#*\?}
      ;;
    *)
      authority=$rest
      suffix=''
      ;;
  esac
  [ -n "$authority" ] || die 'URL must include a host'
  case "$authority" in
    *@*|*' '*|*\\*) die 'URL authority is not accepted' ;;
  esac
  scheme=$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')
  lowered_authority=$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')
  case "$scheme:$lowered_authority" in
    http:*:80) lowered_authority=${lowered_authority%:80} ;;
    https:*:443) lowered_authority=${lowered_authority%:443} ;;
  esac
  printf '%s://%s%s\n' "$scheme" "$lowered_authority" "$suffix"
}

url_host() {  # <canonical URL> -> host-like searchable term
  local rest authority
  rest=${1#*://}
  authority=${rest%%/*}
  authority=${authority%%\?*}
  printf '%s\n' "${authority%%:*}"
}

record_id_for() {  # <canonical URL> -> deterministic safe ID
  printf '%s' "$1" | sha256
}

record_path_for() {  # <canonical URL> -> path
  local id
  id=$(record_id_for "$1")
  printf '%s/%s.md\n' "$RECORDS_DIR" "$id"
}

with_lock() {
  mkdir -p "$RECORDS_DIR" "$TRANSCRIPTS_DIR" "$HISTORY_DIR" || die 'could not initialize link-intake storage'
  mkdir "$LOCK_DIR" 2>/dev/null || die 'another link-intake update is in progress'
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT HUP INT TERM
}

existing_original_urls() {  # <record> -> original URLs without Markdown prefix
  awk '
    /^Original URLs:$/ { seen=1; next }
    seen && /^- / { sub(/^- /, ""); print; next }
    seen { exit }
  ' "$1"
}

unique_original_urls() {  # <existing record or empty> <new URL> -> sorted URLs
  local existing=$1 original=$2
  {
    [ -n "$existing" ] && [ -f "$existing" ] && existing_original_urls "$existing"
    printf '%s\n' "$original"
  } | LC_ALL=C sort -u
}

validate_record() {  # <record path> <expected canonical URL or empty>
  local record=$1 expected=${2:-} canonical source title summary terms transcript status originals claims failure retrieved original
  [ -f "$record" ] || die "record is absent: $record"
  canonical=$(sed -n 's/^Canonical URL: //p' "$record" | head -1)
  source=$(sed -n 's/^Source type: //p' "$record" | head -1)
  title=$(sed -n 's/^Title: //p' "$record" | head -1)
  summary=$(sed -n 's/^Summary: //p' "$record" | head -1)
  terms=$(sed -n 's/^Search terms: //p' "$record" | head -1)
  transcript=$(sed -n 's/^Transcript: //p' "$record" | head -1)
  status=$(sed -n 's/^Retrieval status: //p' "$record" | head -1)
  failure=$(sed -n 's/^Failure: //p' "$record" | head -1)
  retrieved=$(sed -n 's/^Retrieved at: //p' "$record" | head -1)
  [ -n "$canonical" ] || die "record is missing canonical URL: $record"
  [ -z "$expected" ] || [ "$canonical" = "$expected" ] || die "record canonical URL does not match: $record"
  canonicalize_url "$canonical" >/dev/null
  case "$source" in article|web|video|audio|document|image|other) ;; *) die "record source type is invalid: $record" ;; esac
  case "$status" in captured|inaccessible) ;; *) die "record status is invalid: $record" ;; esac
  require_one_line 'record title' "$title"
  require_one_line 'record summary' "$summary"
  require_one_line 'record search terms' "$terms"
  case "$retrieved" in ????-??-??) ;; *) die "record retrieval date is invalid: $record" ;; esac
  [ -n "$transcript" ] || die "record is missing transcript metadata: $record"
  originals=$(existing_original_urls "$record")
  [ -n "$originals" ] || die "record has no original URL: $record"
  while IFS= read -r original; do
    canonicalize_url "$original" >/dev/null
  done <<EOF
$originals
EOF
  claims=$(awk '/^## Key claims or takeaways$/{seen=1; next} seen && /^- /{print; next} seen{exit}' "$record")
  [ -n "$claims" ] || die "record has no claims or takeaways: $record"
  case "$transcript" in
    'not applicable'|unavailable:*) ;;
    'stored at transcripts/'*) [ -f "$LINK_ROOT/${transcript#stored at }" ] || die "record transcript path is absent: $record" ;;
    *) die "record transcript metadata is invalid: $record" ;;
  esac
  case "$source" in
    video|audio)
      case "$transcript" in 'stored at transcripts/'*|unavailable:*) ;; *) die "media record has no transcript outcome: $record" ;; esac
      ;;
    *) [ "$transcript" = 'not applicable' ] || die "non-media record has transcript metadata: $record" ;;
  esac
  if [ "$status" = inaccessible ]; then
    [ -n "$failure" ] || die "inaccessible record has no failure reason: $record"
  fi
}

write_index() {  # <canonical> <id> <retrieved-at> <source> <title> <status> <terms>
  local canonical=$1 id=$2 retrieved=$3 source=$4 title=$5 status=$6 terms=$7 tmp
  tmp=$(mktemp "$LINK_ROOT/.index.XXXXXX") || die 'could not create index update'
  {
    printf 'canonical_url\trecord_id\tretrieved_at\tsource_type\ttitle\tstatus\tsearch_terms\n'
    if [ -f "$INDEX_FILE" ]; then
      awk -F '\t' -v id="$id" 'NR > 1 && $2 != id { print }' "$INDEX_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$canonical" "$id" "$retrieved" "$source" "$title" "$status" "$terms"
  } > "$tmp" || { rm -f "$tmp"; die 'could not write index update'; }
  mv "$tmp" "$INDEX_FILE" || { rm -f "$tmp"; die 'could not publish index update'; }
}

snapshot_existing_record() {  # <record> <id> <retrieved date>
  local record=$1 id=$2 retrieved=$3 digest destination tmp
  [ -f "$record" ] || return 0
  digest=$(sha256 < "$record")
  destination="$HISTORY_DIR/$id/${retrieved}-${digest}.md"
  [ -f "$destination" ] && return 0
  mkdir -p "$HISTORY_DIR/$id" || die 'could not initialize record history'
  tmp=$(mktemp "$HISTORY_DIR/$id/.snapshot.XXXXXX") || die 'could not create record history snapshot'
  cp "$record" "$tmp" && mv "$tmp" "$destination" || { rm -f "$tmp"; die 'could not publish record history snapshot'; }
}

copy_transcript() {  # <source> <id> -> durable relative transcript path
  local source=$1 id=$2 digest directory destination tmp
  [ -f "$source" ] || die "transcript file is absent: $source"
  digest=$(sha256 < "$source")
  directory="$TRANSCRIPTS_DIR/$id"
  destination="$directory/$digest.txt"
  if [ ! -f "$destination" ]; then
    mkdir -p "$directory" || die 'could not initialize transcript storage'
    tmp=$(mktemp "$directory/.transcript.XXXXXX") || die 'could not create transcript update'
    cp "$source" "$tmp" && mv "$tmp" "$destination" || { rm -f "$tmp"; die 'could not publish transcript'; }
  fi
  printf 'transcripts/%s/%s.txt\n' "$id" "$digest"
}

command_upsert() {
  local original='' canonical='' canonical_input='' source='' title='' summary='' terms='' retrieved='' transcript_file='' transcript_unavailable='' failure='' argument claim
  local claims='' id record existing tmp transcript note status host
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) shift; original=${1:-} ;;
      --canonical-url) shift; canonical_input=${1:-} ;;
      --source-type) shift; source=${1:-} ;;
      --title) shift; title=${1:-} ;;
      --summary) shift; summary=${1:-} ;;
      --terms) shift; terms=${1:-} ;;
      --claim) shift; claim=${1:-}; require_one_line claim "$claim"; claims="${claims}${claims:+$'\n'}$claim" ;;
      --retrieved-at) shift; retrieved=${1:-} ;;
      --transcript-file) shift; transcript_file=${1:-} ;;
      --transcript-unavailable) shift; transcript_unavailable=${1:-} ;;
      --failure) shift; failure=${1:-} ;;
      -h|--help|help) usage; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    [ "$#" -gt 0 ] || die "missing value for option"
    shift
  done
  require_one_line URL "$original"
  canonical=$(canonicalize_url "${canonical_input:-$original}") || return $?
  [ -z "$canonical_input" ] || require_one_line 'canonical URL' "$canonical_input"
  case "$source" in article|web|video|audio|document|image|other) ;; *) die 'source type must be article, web, video, audio, document, image, or other' ;; esac
  if [ -n "$retrieved" ]; then
    case "$retrieved" in ????-??-??) ;; *) die 'retrieved-at must use YYYY-MM-DD' ;; esac
  else
    retrieved=$(date -u +%F)
  fi
  require_one_line 'retrieved-at' "$retrieved"
  if [ -n "$failure" ]; then
    require_one_line failure "$failure"
    status=inaccessible
    [ -n "$title" ] || title=Unavailable
    [ -n "$summary" ] || summary="Retrieval failed: $failure"
    [ -n "$claims" ] || claims="Could not retrieve the source: $failure"
    [ -n "$terms" ] || { host=$(url_host "$canonical"); terms="inaccessible,$host"; }
  else
    status=captured
  fi
  require_one_line title "$title"
  require_one_line summary "$summary"
  require_one_line 'search terms' "$terms"
  [ -n "$claims" ] || die 'at least one --claim is required unless --failure is given'
  [ -z "$transcript_file" ] || [ -z "$transcript_unavailable" ] || die 'provide either transcript-file or transcript-unavailable, not both'
  id=$(record_id_for "$canonical")
  case "$source" in
    video|audio)
      if [ -n "$transcript_file" ]; then
        transcript=$(copy_transcript "$transcript_file" "$id") || return $?
        note="stored at $transcript"
      else
        if [ -z "$transcript_unavailable" ] && [ -n "$failure" ]; then
          transcript_unavailable=$failure
        fi
        require_one_line 'transcript-unavailable reason' "$transcript_unavailable"
        note="unavailable: $transcript_unavailable"
      fi
      ;;
    *)
      [ -z "$transcript_file" ] || die 'transcript-file is only supported for video or audio records'
      [ -z "$transcript_unavailable" ] || die 'transcript-unavailable is only supported for video or audio records'
      note='not applicable'
      ;;
  esac
  with_lock
  record="$RECORDS_DIR/$id.md"
  existing=$record
  tmp=$(mktemp "$RECORDS_DIR/.record.XXXXXX") || die 'could not create record update'
  {
    printf '# Link intake record\n\n'
    printf 'Record ID: %s\n' "$id"
    printf 'Canonical URL: %s\n' "$canonical"
    printf 'Original URLs:\n'
    unique_original_urls "$existing" "$original" | while IFS= read -r argument; do printf '%s\n' "- $argument"; done
    printf 'Retrieved at: %s\n' "$retrieved"
    printf 'Retrieval status: %s\n' "$status"
    printf 'Source type: %s\n' "$source"
    printf 'Title: %s\n' "$title"
    printf 'Summary: %s\n' "$summary"
    printf 'Search terms: %s\n' "$terms"
    printf 'Transcript: %s\n' "$note"
    printf 'Failure: %s\n\n' "${failure:-none}"
    printf '## Key claims or takeaways\n'
    printf '%s\n' "$claims" | while IFS= read -r argument; do printf '%s\n' "- $argument"; done
  } > "$tmp" || { rm -f "$tmp"; die 'could not write record update'; }
  validate_record "$tmp" "$canonical"
  if [ -f "$record" ] && ! cmp -s "$record" "$tmp"; then
    snapshot_existing_record "$record" "$id" "$retrieved"
  fi
  mv "$tmp" "$record" || { rm -f "$tmp"; die 'could not publish record update'; }
  write_index "$canonical" "$id" "$retrieved" "$source" "$title" "$status" "$terms"
  printf '%s\n' "$record"
}

command_validate() {
  local target=${1:-} canonical record path count=0
  [ "$#" -eq 1 ] || die 'validate accepts one URL or --all'
  if [ "$target" = --all ]; then
    [ -f "$INDEX_FILE" ] || die 'link-intake index is absent'
    while IFS=$'\t' read -r canonical _; do
      [ "$canonical" = canonical_url ] && continue
      path=$(record_path_for "$canonical")
      validate_record "$path" "$canonical"
      count=$((count + 1))
    done < "$INDEX_FILE"
    [ "$count" -gt 0 ] || die 'link-intake index has no records'
    printf 'valid: %s records\n' "$count"
    return 0
  fi
  canonical=$(canonicalize_url "$target") || return $?
  record=$(record_path_for "$canonical")
  validate_record "$record" "$canonical"
  printf 'valid: %s\n' "$record"
}

main() {
  case "${1:-}" in
    upsert) shift; command_upsert "$@" ;;
    validate) shift; command_validate "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
