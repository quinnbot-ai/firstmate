---
name: visual-deliverable-usability
description: >-
  Verify that captain-facing rendered visual deliverables expose usable media and interactive controls before they are reported complete.
user-invocable: false
metadata:
  internal: true
---

# visual-deliverable-usability

Run this check before reporting a captain-facing rendered visual deliverable complete.

Use the existing browser tooling instead of adding a browser-test framework.

```sh
bin/fm-visual-deliverable-check.sh <rendered-url> \
  --source <artifact.html> \
  --source <stylesheet.css>
```

Serve a local artifact over `http(s)` before running the check because `file://` URLs are deliberately unsupported.

Pass every local HTML and CSS source that contributes to the rendered deliverable.

The rendered probe is the primary check because markup presence cannot establish usability.

It measures media and interactive elements in the rendered page and rejects zero dimensions, CSS-hidden elements, disabled controls, and controls with pointer events disabled.

Finding no measurable media or interactive element is its own loud failure, because a 404, a broken script, or a control that never rendered must never read as a pass.

Exit `1` means the check ran and reported findings, while exit `2` means it could not run at all - a rejected URL, a missing or non-source `--source`, an unavailable browser or `node`, an unreadable source, or an unexpected browser result - and neither exit ever counts as a pass.

An element that is deliberately not presented - a collapsed panel, a closed dialog, an entrance that starts at `opacity:0` - opts out one element at a time with `data-fm-visual-check="intentionally-hidden"` on that element itself in the rendered markup.

The marker is per element and never inherited from an ancestor, so there is no page-level or global suppression, every use of it is reported on stdout, and a render whose every matched element carries it still fails.

It waives only the dimension, visibility, and pointer-events findings for that one element; a disabled control still fails.

Mark the narrowest element that is genuinely meant to be unseen, and fix the CSS instead whenever the element is meant to be visible.

The source scan also rejects any supplied CSS rule whose selector matches the `audio` element type - alone, in a list, or in a compound or descendant selector - and sets `height:auto`, so the known reset cannot recur even if a separate declaration happens to mask it in one render.

A wrapper id, class, or attribute value merely named `audio`, such as `#audio` or `[data-role="audio"]`, does not select the element type and is not a finding.

Do not put `audio` in a blanket `height:auto` reset such as `video,audio,img{max-width:100%;height:auto}`.

The check does not prove that media plays or is audible, that a control performs the intended action, that keyboard interaction works, or that another element does not cover a visible control.

Use a targeted manual review when one of those limits matters to the deliverable.
