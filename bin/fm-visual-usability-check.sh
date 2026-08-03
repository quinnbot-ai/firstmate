#!/usr/bin/env bash
# Verify that a rendered visual deliverable exposes usable media and controls.
#
# Usage:
#   fm-visual-usability-check.sh <url> --source <html-or-css> [--source <html-or-css> ...]
#
# The check opens the rendered URL with chrome-devtools-axi and rejects media or
# interactive controls that are zero-sized, hidden, disabled, or non-clickable.
# Every local source file contributing to the deliverable is named explicitly so
# the check result remains tied to a reviewable artifact.
set -u

BROWSER=${FM_VISUAL_CHECK_BROWSER:-chrome-devtools-axi}

usage() {
  sed -n '4,9{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

URL=${1:-}
[ -n "$URL" ] || { usage >&2; exit 2; }
shift

SOURCES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || { echo 'fm-visual-usability-check: --source requires a path.' >&2; exit 2; }
      SOURCES+=("$2")
      shift 2
      ;;
    --source=*)
      SOURCES+=("${1#--source=}")
      shift
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ "${#SOURCES[@]}" -gt 0 ] || {
  echo 'fm-visual-usability-check: pass every contributing local HTML or CSS file with --source.' >&2
  exit 2
}
command -v "$BROWSER" >/dev/null 2>&1 || {
  echo "fm-visual-usability-check: required browser command is unavailable: $BROWSER" >&2
  exit 2
}
for source in "${SOURCES[@]}"; do
  [ -f "$source" ] || {
    echo "fm-visual-usability-check: source file does not exist: $source" >&2
    exit 2
  }
  case "$source" in *.css|*.htm|*.html) ;; *)
    echo "fm-visual-usability-check: source must be a local .css, .htm, or .html file: $source" >&2
    exit 2
    ;;
  esac
done

if ! "$BROWSER" open "$URL" >/dev/null 2>&1; then
  echo "fm-visual-usability-check: browser could not open $URL" >&2
  exit 2
fi

READ_RENDERED_ELEMENTS='() => JSON.stringify([...document.querySelectorAll("audio, video, img, canvas, svg, button, input:not([type=hidden]), select, textarea, a[href], [role=button], [role=link], [contenteditable=true], [tabindex]:not([tabindex=\"-1\")]" )].map((element) => { const rect = element.getBoundingClientRect(); const style = getComputedStyle(element); const interactive = element.matches("button, input:not([type=hidden]), select, textarea, a[href], [role=button], [role=link], [contenteditable=true], [tabindex]:not([tabindex=\"-1\"])"); let hiddenBy = ""; for (let node = element; node; node = node.parentElement) { const nodeStyle = getComputedStyle(node); if (nodeStyle.display === "none" || nodeStyle.visibility === "hidden" || nodeStyle.visibility === "collapse" || nodeStyle.contentVisibility === "hidden" || Number(nodeStyle.opacity) === 0) { hiddenBy = node === element ? "its computed style" : "an ancestor\u0027s computed style"; break; } } return { label: element.tagName.toLowerCase() + (element.id ? "#" + element.id : ""), width: rect.width, height: rect.height, clientRects: element.getClientRects().length, hiddenBy, interactive, disabled: interactive && (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true"), pointerEvents: style.pointerEvents }; }))'

if ! BROWSER_RESULT=$("$BROWSER" eval "$READ_RENDERED_ELEMENTS" 2>&1); then
  printf '%s\n' "$BROWSER_RESULT" >&2
  echo "fm-visual-usability-check: browser could not inspect rendered elements at $URL" >&2
  exit 2
fi

if ! RENDER_FAILURES=$(printf '%s\n' "$BROWSER_RESULT" | node -e '
const output = require("fs").readFileSync(0, "utf8");
const line = output.split(/\r?\n/).find((value) => value.startsWith("result:"));
if (!line) throw new Error("chrome-devtools-axi returned no result line");
let values = JSON.parse(line.slice("result:".length).trim());
if (typeof values === "string") values = JSON.parse(values);
if (!Array.isArray(values)) throw new Error("browser result was not an element list");
let failures = 0;
for (const value of values) {
  const dimensions = `${value.width}x${value.height}`;
  if (!(value.width > 0) || !(value.height > 0) || value.clientRects === 0) {
    console.log(`FAIL - ${value.label}: rendered dimensions are ${dimensions}.`); failures += 1;
  }
  if (value.hiddenBy) { console.log(`FAIL - ${value.label}: hidden by ${value.hiddenBy}.`); failures += 1; }
  if (value.interactive && value.disabled) { console.log(`FAIL - ${value.label}: disabled interactive control.`); failures += 1; }
  if (value.interactive && value.pointerEvents === "none") { console.log(`FAIL - ${value.label}: pointer events are disabled.`); failures += 1; }
}
process.exitCode = failures === 0 ? 0 : 1;
'); then
  printf '%s\n' "$RENDER_FAILURES"
  exit 1
fi

echo 'ok - rendered media and interactive elements have usable dimensions and visibility'
