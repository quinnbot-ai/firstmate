# Link intake

When the captain sends one or more meaningful URLs, the active Firstmate inspects every link and retains a private searchable record for each result.
Records live under `FM_HOME/data/link-intake/`, which remains gitignored with the rest of `data/`.
The record keeps the canonical URL, every supplied original URL, title, retrieval date, source type, summary, claims or takeaways, searchable terms, transcript outcome, and a visible failure reason when retrieval is unavailable.

The active agent uses the existing browser or media tool suitable for the source, then gives the normalized result to [`bin/fm-link-intake.sh`](scripts.md#the-bin-toolbelt).
The helper's header and `--help` own the record format, exact flags, canonicalization, validation, history snapshots, and atomic-write behavior.
Repeated intake of a canonical URL updates one current record while retaining original URLs and preserving the replaced record as private history.

Video and audio intake retains a legally and technically accessible transcript under the same private location or records why no transcript can be obtained.
An inaccessible, private, deleted, or otherwise unreadable source still receives a visible record with its failure reason.
Link intake preserves attribution and verification evidence only.
It never authorizes publishing, messaging, buying, sensitive-account login, or any other external mutation.

Run `bin/fm-link-intake.sh validate --all` to verify the current records and index.
[`verification/link-intake.md`](verification/link-intake.md) carries the active maintainer evidence.
