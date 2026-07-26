#!/usr/bin/env bash
# Verify that a rendered visual deliverable exposes usable media and controls.
#
# This intentionally reuses chrome-devtools-axi instead of adding a browser-test
# dependency.  It opens the supplied rendered URL, measures each media or
# interactive element's layout and computed visibility, and rejects the known
# CSS reset that gives the audio element type height:auto.  Every local HTML and
# CSS source file that contributes to the render must be passed with --source so
# the source-level audio-reset rule remains enforceable.
#
# Exit 0 passes, exit 1 reports findings, and exit 2 means the check could not
# run: bad arguments, a missing browser or node, an unreadable source, or an
# unexpected browser result.  A tool failure never reads as a deliverable
# failure.
#
# It drives a per-run named browser session, on its own bridge and port, so it
# neither navigates nor is disturbed by a page the caller or a concurrent
# crewmate has open, and it stops that session and removes its state directory
# when it finishes.
#
# Usage:
#   fm-visual-deliverable-check.sh <url> --source <html-or-css> [--source <html-or-css> ...]
#   The URL must be http(s); serve local artifacts instead of passing file:// URLs.
#
# Finding no measurable media or interactive element is a failure, not a pass.
#
# Zero-dimension and hidden elements fail by default.  An element that is
# deliberately not presented opts out one element at a time with the
# rendered-markup attribute data-fm-visual-check="intentionally-hidden" on that
# element itself, and never on a container that stands in for it.  The marker
# is never inherited from an ancestor, so there is no page-level or global
# suppression, every use of it is reported, and a render whose every matched
# element carries it still fails.  The marker waives only the dimension,
# visibility, and pointer-events findings; a disabled control still fails.
#
# The check verifies rendered dimensions and CSS visibility only.  It cannot
# prove that media can play or be heard, that a control has useful behavior, or
# that another element does not cover it.
set -u

BROWSER=${FM_VISUAL_CHECK_BROWSER:-chrome-devtools-axi}

BROWSER_SESSION="fm-visual-check-$$"
export CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION"
unset CHROME_DEVTOOLS_AXI_PORT
if [ -n "${HOME:-}" ]; then
  BROWSER_SESSION_STATE_DIR="$HOME/.chrome-devtools-axi/sessions/$BROWSER_SESSION"
else
  BROWSER_SESSION_STATE_DIR=
fi

release_browser_session() {
  "$BROWSER" stop >/dev/null 2>&1 || true
  case "$BROWSER_SESSION_STATE_DIR" in
    */.chrome-devtools-axi/sessions/fm-visual-check-[0-9]*)
      rm -rf "$BROWSER_SESSION_STATE_DIR"
      ;;
  esac
}

usage() {
  awk '
    /^# Usage:/ { emit = 1 }
    emit && !/^#/ { exit }
    emit { sub(/^# ?/, ""); print }
  ' "$0"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

URL=${1:-}
[ -n "$URL" ] || { usage >&2; exit 2; }
shift

case "$URL" in
  http://*|https://*) ;;
  file://*)
    echo 'fm-visual-deliverable-check: file:// URLs are unsupported; serve the local artifact over http(s).' >&2
    exit 2
    ;;
  *)
    echo 'fm-visual-deliverable-check: URL must use http:// or https://.' >&2
    exit 2
    ;;
esac

SOURCES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || { echo 'fm-visual-deliverable-check: --source requires a path.' >&2; exit 2; }
      SOURCES+=("$2")
      shift 2
      ;;
    --source=*)
      SOURCES+=("${1#--source=}")
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[ "${#SOURCES[@]}" -gt 0 ] || {
  echo 'fm-visual-deliverable-check: pass every contributing local HTML and CSS file with --source.' >&2
  exit 2
}

command -v "$BROWSER" >/dev/null 2>&1 || {
  echo "fm-visual-deliverable-check: required browser command is unavailable: $BROWSER" >&2
  exit 2
}

command -v node >/dev/null 2>&1 || {
  echo 'fm-visual-deliverable-check: required command is unavailable: node' >&2
  exit 2
}

for source in "${SOURCES[@]}"; do
  [ -f "$source" ] || {
    echo "fm-visual-deliverable-check: source file does not exist: $source" >&2
    exit 2
  }
  case "$source" in
    *.css|*.htm|*.html) ;;
    *)
      echo "fm-visual-deliverable-check: source must be a local .css, .htm, or .html file: $source" >&2
      exit 2
      ;;
  esac
done

SOURCE_FAILURES=$(node - "${SOURCES[@]}" <<'NODE' 2>/dev/null
const fs = require('fs');
let failures = 0;

// Match audio only as a type selector, in any compound or list position, so a
// wrapper id, class, or attribute value merely named "audio" never trips the
// reset rule.
const selectsAudioType = (selector) => {
  const stripped = selector
    .replace(/\[[^\]]*\]/g, ' ')
    .replace(/[()]/g, ' ');
  return /(^|[\s>+~,])audio(?=$|[\s>+~,.:#[])/i.test(stripped);
};

for (const source of process.argv.slice(2)) {
  let contents;
  try {
    contents = fs.readFileSync(source, 'utf8');
  } catch (error) {
    console.log(`fm-visual-deliverable-check: could not read source ${source}.`);
    process.exit(2);
  }
  const css = /\.html?$/i.test(source)
    ? [...contents.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi)].map((match) => match[1]).join('\n')
    : contents;
  const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = withoutComments.matchAll(/([^{}]+)\{([^{}]*)\}/g);

  for (const rule of rules) {
    const selector = rule[1].trim().replace(/\s+/g, ' ');
    const declarations = rule[2];
    const selectsAudio = selectsAudioType(selector);
    const givesAutoHeight = /(?:^|;)\s*height\s*:\s*auto\s*(?:!important\s*)?(?:;|$)/i.test(declarations);
    if (selectsAudio && givesAutoHeight) {
      console.log(`FAIL - CSS source ${source}: selector "${selector}" gives audio height:auto.`);
      failures += 1;
    }
  }
}

process.exitCode = failures === 0 ? 0 : 1;
NODE
)
SOURCE_RC=$?
if [ "$SOURCE_RC" -ne 0 ] && [ "$SOURCE_RC" -ne 1 ]; then
  if [ -n "$SOURCE_FAILURES" ]; then
    printf '%s\n' "$SOURCE_FAILURES" >&2
  fi
  echo 'fm-visual-deliverable-check: could not scan the --source files for the audio reset rule.' >&2
  exit 2
fi
if [ "$SOURCE_RC" -eq 1 ] && [ -z "$SOURCE_FAILURES" ]; then
  echo 'fm-visual-deliverable-check: could not scan the --source files for the audio reset rule.' >&2
  exit 2
fi
if [ -n "$SOURCE_FAILURES" ]; then
  printf '%s\n' "$SOURCE_FAILURES"
fi

trap release_browser_session EXIT

if ! BROWSER_OPEN=$("$BROWSER" open "$URL" 2>&1); then
  printf '%s\n' "$BROWSER_OPEN" >&2
  echo "fm-visual-deliverable-check: browser could not open $URL" >&2
  exit 2
fi

READ_RENDERED_ELEMENTS='() => { const INTERACTIVE = "button, input:not([type=hidden]), select, textarea, a[href], [role=button], [role=link], [contenteditable=true], [tabindex]:not([tabindex=\"-1\"])"; return [...document.querySelectorAll("audio, video, " + INTERACTIVE)].map((element) => { const rect = element.getBoundingClientRect(); const label = element.tagName.toLowerCase() + (element.id ? "#" + element.id : ""); const interactive = element.matches(INTERACTIVE); let hiddenBy = ""; for (let node = element; node; node = node.parentElement) { const style = getComputedStyle(node); if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" || style.contentVisibility === "hidden" || Number(style.opacity) === 0) { hiddenBy = node === element ? "its computed style" : "an ancestor\u0027s computed style"; break; } } const style = getComputedStyle(element); return { label, width: rect.width, height: rect.height, clientRects: element.getClientRects().length, hiddenBy, interactive, disabled: interactive && (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true"), pointerEvents: style.pointerEvents, exempt: element.getAttribute("data-fm-visual-check") === "intentionally-hidden" }; }); }'

if ! BROWSER_RESULT=$("$BROWSER" eval "$READ_RENDERED_ELEMENTS" --full 2>&1); then
  printf '%s\n' "$BROWSER_RESULT" >&2
  echo "fm-visual-deliverable-check: browser could not inspect rendered elements at $URL" >&2
  exit 2
fi

# shellcheck disable=SC2016  # single quotes are deliberate: the Node program's ${...} template literals must reach node verbatim, not expand in the shell.
RENDER_REPORT=$(printf '%s\n' "$BROWSER_RESULT" | node -e '
const fs = require("fs");
const output = fs.readFileSync(0, "utf8");
const resultLine = output.split(/\r?\n/).find((line) => line.startsWith("result:"));
if (!resultLine) process.exit(2);
let value;
try {
  value = JSON.parse(resultLine.slice("result:".length).trim());
} catch (_) {
  process.exit(2);
}
for (let depth = 0; typeof value === "string" && depth < 4; depth += 1) {
  try {
    value = JSON.parse(value);
  } catch (_) {
    process.exit(2);
  }
}
if (!Array.isArray(value)) process.exit(2);
let failures = 0;
let measured = 0;
const MARKER = "data-fm-visual-check=intentionally-hidden";
for (const element of value) {
  if (element.exempt === true) {
    console.log(`note - ${element.label}: presentation findings waived by the ${MARKER} marker.`);
  } else {
    measured += 1;
    const dimensions = `${element.width}x${element.height}`;
    if (!(element.width > 0) || !(element.height > 0) || element.clientRects === 0) {
      console.log(`FAIL - ${element.label}: rendered dimensions are ${dimensions}.`);
      failures += 1;
    }
    if (element.hiddenBy) {
      console.log(`FAIL - ${element.label}: hidden by ${element.hiddenBy}.`);
      failures += 1;
    }
    if (element.interactive && element.pointerEvents === "none") {
      console.log(`FAIL - ${element.label}: pointer events are disabled.`);
      failures += 1;
    }
  }
  if (element.interactive && element.disabled) {
    console.log(`FAIL - ${element.label}: disabled interactive control.`);
    failures += 1;
  }
}
if (value.length === 0) {
  console.log(`FAIL - no media or interactive element was found in the rendered page, so nothing could be measured.`);
  failures += 1;
} else if (measured === 0) {
  console.log(`FAIL - every matched element carries the ${MARKER} marker, so nothing could be measured.`);
  failures += 1;
}
process.exitCode = failures === 0 ? 0 : 1;
') 2>/dev/null
RENDER_RC=$?
if [ "$RENDER_RC" -eq 2 ]; then
  echo "fm-visual-deliverable-check: could not measure rendered elements at $URL because the browser returned an unexpected element result." >&2
  exit 2
fi
if [ "$RENDER_RC" -ne 0 ] && [ "$RENDER_RC" -ne 1 ]; then
  echo "fm-visual-deliverable-check: could not measure rendered elements at $URL." >&2
  exit 2
fi
if [ "$RENDER_RC" -eq 1 ] && [ -z "$RENDER_REPORT" ]; then
  echo "fm-visual-deliverable-check: could not measure rendered elements at $URL." >&2
  exit 2
fi
if [ -n "$RENDER_REPORT" ]; then
  printf '%s\n' "$RENDER_REPORT"
fi

if [ "$SOURCE_RC" -ne 0 ] || [ "$RENDER_RC" -ne 0 ]; then
  exit 1
fi

echo 'ok - rendered media and interactive elements have usable dimensions and visibility'
