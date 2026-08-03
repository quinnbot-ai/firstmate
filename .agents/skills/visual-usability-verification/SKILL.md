---
name: visual-usability-verification
description: >-
  Verify that rendered visual deliverables expose visible, usable media and interactive controls before reporting completion.
user-invocable: false
metadata:
  internal: true
---

# visual-usability-verification

Load this before reporting a rendered visual deliverable complete.

Run the rendered check with every local HTML or CSS source that contributes to the deliverable.

```sh
bin/fm-visual-usability-check.sh <rendered-url> --source <artifact.html> --source <stylesheet.css>
```

The browser probe rejects zero-sized or hidden media and controls, plus disabled or pointer-inert controls.

It does not prove media playback, keyboard behavior, semantic correctness, or that another element is not covering a visible control.
Use a targeted manual review whenever one of those limits matters.
