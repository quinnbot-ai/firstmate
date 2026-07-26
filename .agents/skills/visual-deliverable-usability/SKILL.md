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

Pass every local HTML and CSS source that contributes to the rendered deliverable.

The rendered probe is the primary check because markup presence cannot establish usability.

It measures media and interactive elements in the rendered page and rejects zero dimensions, CSS-hidden elements, disabled controls, and controls with pointer events disabled.

The source scan also rejects any supplied CSS rule that selects `audio` and sets `height:auto`, so the known reset cannot recur even if a separate declaration happens to mask it in one render.

Do not put `audio` in a blanket `height:auto` reset such as `video,audio,img{max-width:100%;height:auto}`.

The check does not prove that media plays or is audible, that a control performs the intended action, that keyboard interaction works, or that another element does not cover a visible control.

Use a targeted manual review when one of those limits matters to the deliverable.
