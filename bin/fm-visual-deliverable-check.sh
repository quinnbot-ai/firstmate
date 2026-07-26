#!/usr/bin/env bash
# Verify that a rendered visual deliverable exposes usable media and controls.
#
# This intentionally reuses chrome-devtools-axi instead of adding a browser-test
# dependency.  It opens the supplied rendered URL, measures each media or
# interactive element's layout and computed visibility, and rejects the known
# CSS reset that gives audio elements height:auto.  Every local HTML and CSS
# source file that contributes to the render must be passed with --source so
# the source-level audio-reset rule remains enforceable.
#
# Usage:
#   fm-visual-deliverable-check.sh <url> --source <html-or-css> [--source <html-or-css> ...]
#
# The check verifies rendered dimensions and CSS visibility only.  It cannot
# prove that media can play or be heard, that a control has useful behavior, or
# that another element does not cover it.
set -u

BROWSER=${FM_VISUAL_CHECK_BROWSER:-chrome-devtools-axi}

usage() {
  sed -n '10,16{s/^# \{0,1\}//;p;}' "$0"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

URL=${1:-}
[ -n "$URL" ] || { usage >&2; exit 2; }
shift

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

SOURCE_FAILURES=$(node - "${SOURCES[@]}" <<'NODE'
const fs = require('fs');
let failures = 0;

for (const source of process.argv.slice(2)) {
  const contents = fs.readFileSync(source, 'utf8');
  const css = /\.html?$/i.test(source)
    ? [...contents.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi)].map((match) => match[1]).join('\n')
    : contents;
  const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = withoutComments.matchAll(/([^{}]+)\{([^{}]*)\}/g);

  for (const rule of rules) {
    const selector = rule[1].trim().replace(/\s+/g, ' ');
    const declarations = rule[2];
    const selectsAudio = /(^|[^a-z0-9_-])audio(?=$|[^a-z0-9_-])/i.test(selector);
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
if [ -n "$SOURCE_FAILURES" ]; then
  printf '%s\n' "$SOURCE_FAILURES"
fi

if ! BROWSER_OPEN=$($BROWSER open "$URL" 2>&1); then
  printf '%s\n' "$BROWSER_OPEN" >&2
  echo "fm-visual-deliverable-check: browser could not open $URL" >&2
  exit 2
fi

READ_RENDERED_ELEMENTS='() => JSON.stringify([...document.querySelectorAll("audio, video, button, input:not([type=hidden]), select, textarea, a[href], [role=button], [role=link], [contenteditable=true], [tabindex]:not([tabindex=\"-1\"])" )].map((element) => { const rect = element.getBoundingClientRect(); const label = element.tagName.toLowerCase() + (element.id ? "#" + element.id : ""); const interactive = element.matches("button, input:not([type=hidden]), select, textarea, a[href], [role=button], [role=link], [contenteditable=true], [tabindex]:not([tabindex=\"-1\"])"); let hiddenBy = ""; for (let node = element; node; node = node.parentElement) { const style = getComputedStyle(node); if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" || style.contentVisibility === "hidden" || Number(style.opacity) === 0) { hiddenBy = node === element ? "its computed style" : "an ancestor\u0027s computed style"; break; } } const style = getComputedStyle(element); return { label, width: rect.width, height: rect.height, clientRects: element.getClientRects().length, hiddenBy, interactive, disabled: interactive && (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true"), pointerEvents: style.pointerEvents }; }))'

if ! BROWSER_RESULT=$($BROWSER eval "$READ_RENDERED_ELEMENTS" 2>&1); then
  printf '%s\n' "$BROWSER_RESULT" >&2
  echo "fm-visual-deliverable-check: browser could not inspect rendered elements at $URL" >&2
  exit 2
fi

RENDER_FAILURES=$(printf '%s\n' "$BROWSER_RESULT" | node -e '
const fs = require("fs");
const output = fs.readFileSync(0, "utf8");
const resultLine = output.split(/\r?\n/).find((line) => line.startsWith("result:"));
if (!resultLine) {
  throw new Error("chrome-devtools-axi returned no result line");
}
let value = JSON.parse(resultLine.slice("result:".length).trim());
if (typeof value === "string") value = JSON.parse(value);
if (!Array.isArray(value)) throw new Error("browser result was not an element list");
let failures = 0;
for (const element of value) {
  const dimensions = `${element.width}x${element.height}`;
  if (!(element.width > 0) || !(element.height > 0) || element.clientRects === 0) {
    console.log(`FAIL - ${element.label}: rendered dimensions are ${dimensions}.`);
    failures += 1;
  }
  if (element.hiddenBy) {
    console.log(`FAIL - ${element.label}: hidden by ${element.hiddenBy}.`);
    failures += 1;
  }
  if (element.interactive && element.disabled) {
    console.log(`FAIL - ${element.label}: disabled interactive control.`);
    failures += 1;
  }
  if (element.interactive && element.pointerEvents === "none") {
    console.log(`FAIL - ${element.label}: pointer events are disabled.`);
    failures += 1;
  }
}
process.exitCode = failures === 0 ? 0 : 1;
')
RENDER_RC=$?
if [ -n "$RENDER_FAILURES" ]; then
  printf '%s\n' "$RENDER_FAILURES"
fi

if [ "$SOURCE_RC" -ne 0 ] || [ "$RENDER_RC" -ne 0 ]; then
  exit 1
fi

echo 'ok - rendered media and interactive elements have usable dimensions and visibility'
