# Read-only backend readiness doctor proposal

Audience: maintainer architecture.

This is decision input for a future `bin/fm-backend-doctor.sh`, not an implementation decision.
The proposed doctor reports readiness from safe observations only.
It must not create or restart sessions, launch or stop agents, repair configuration, read credentials, write Firstmate state, or fall back to another backend.
Any action that changes a backend belongs in a separate repair-tool proposal.

## Decision requested

Please choose the contract for each of these three boundaries before implementation begins.
The recommendations are advice for the captain and Kun, not choices made by this paper.

1. Should Zellij session names be constrained to a safe atom, or preserved as exact opaque text through the adapter and endpoint representation?
2. How should the doctor's result records preserve embedded control bytes without delimiter collisions or normalization?
3. How should a no-side-effect validator represent a fact it cannot establish without performing a privileged or mutating check?

The retired local-only lane at `ae79ebc7` is evidence, not an implementation base and must not be revived or pushed.
This proposal instead reflects the current backend owner, including its exact `list-sessions --short --no-formatting` membership check, first-colon Zellij target parser, and binary `fm_backend_validate_spawn` gate.

## What the retired lane established

The retired doctor usefully separated tool availability, version compatibility, reachability, configuration, and a next action in a stable result row.
Its reviews also exposed three contracts that should not be inherited accidentally.
It normalized newline, carriage return, tab, and unit-separator bytes before rendering a unit-separator-delimited row, so its structured output was not lossless.
Its Zellij work repeatedly had to preserve names containing spaces and text that resembled human inventory decorations.
A later socket-proxy probe created temporary directories and sockets to infer more Zellij state, which is outside this doctor's read-only boundary.
Its `yes` or `no` spawn conclusion also could not honestly describe checks intentionally unable to read a configured secret.

## Choice 1: Zellij session-name semantics

The current adapter treats a configured session as an exact line when it checks `list-sessions`, but its durable endpoint validator accepts only a restricted atom and `fm_backend_zellij_parse_target` splits `session:pane` at the first colon.
The choice therefore governs the whole endpoint contract, not just the doctor.
No option authorizes a readiness probe to attach, resurrect, proxy, or create a session.

| Option | Contract | Consequence |
| --- | --- | --- |
| A. Constrain names | Accept only the existing endpoint-safe atom, and reject every other configured session before spawn or doctor use. | Keeps line metadata and `session:pane` simple, but deliberately rejects Zellij-valid names with spaces, colons, or other punctuation. |
| B. Preserve opaque text | Preserve every nonempty session value that can cross the shell and OS argument boundary, excluding NUL, and carry it as a distinct field. | Retains existing valid-looking names exactly, requires a lossless metadata representation, and changes target parsing to split from the final numeric pane suffix rather than the first colon. |
| C. Best-effort compatibility | Continue accepting broad configuration but classify values outside the endpoint atom as malformed or partial only when a later path encounters them. | Minimizes immediate edits, but leaves setup, doctor output, spawn, and cleanup with incompatible meanings for the same name. |

Recommendation: choose B, with an explicit byte boundary of every non-NUL value the process can pass unchanged, no trimming or delimiter rewriting, and a final-`:<decimal-pane-id>` target grammar.
It matches the adapter's existing exact inventory comparison and avoids silently changing a user's configured Zellij name.
The doctor should report only what passive inventory establishes: the configured name is listed, absent, or unreadable.
It must not infer liveness by creating a socket mirror or any other probing infrastructure.

The case against B is real: it expands the endpoint representation and requires coordinated migration of metadata readers, tests, and the raw operator target syntax.
Choose A instead if the maintainers prefer a deliberately smaller supported-name set and are willing to reject those existing configurations at selection time with a documented migration path.
Choose C only as a time-bounded compatibility bridge with a removal date, because it preserves an unsafe ambiguity rather than a contract.

## Choice 2: Lossless doctor-record encoding

This choice is about the doctor's result records, not the existing `state/<id>.meta` endpoint-file format.
The retired implementation assembled nine fields into one unit-separator string and normalized control bytes before its Node renderer split the string again.
That loses information and makes the separator itself an unrepresentable value.
Changing `state/<id>.meta` is a separate endpoint-metadata proposal, unless Choice 1 explicitly requires that wider migration.

| Option | Contract | Consequence |
| --- | --- | --- |
| A. Normalize or reject controls | Keep a delimiter-based row and replace or reject newline, tab, carriage return, and delimiter bytes. | Easy to render, but result JSON and TOON no longer faithfully describe observed values. |
| B. Escape one delimiter | Retain a line or unit-separator record with a custom escaping rule. | Can be lossless if every writer and reader follows the rule, but duplicates serialization logic and makes malformed escapes another protocol state. |
| C. Structured field vector | Keep every scalar as its own shell argument through the final Node renderer, then form objects directly and let JSON and TOON escape presentation. | Removes the record delimiter entirely and preserves every shell and argv representable byte except NUL, which no argv or shell variable can contain. |

Recommendation: choose C.
The doctor already needs Node for structured rendering, so a fixed-width field vector is smaller and easier to test than inventing an escaping protocol.
The renderer can reject an incomplete field group and JSON-escape values only at the presentation boundary.

The case against C is that it couples the shell collector to a fixed field count and does not transport NUL, so future variable-shaped result records need a deliberate schema revision.
Choose B if result rows must cross an intermediate text-only transport that cannot preserve argument boundaries.
Choose A only if the product contract explicitly says control-containing observations are invalid and a lossy diagnostic is acceptable.

## Choice 3: Typed validator uncertainty

The current spawn validator is a binary gate, while a readiness doctor must sometimes avoid the very action or credential read that would settle a question.
For example, an uninspected cmux socket password can make a normal spawn plausibly capable without allowing a read-only doctor to prove it.
Treating that as success would overpromise, and treating it as failure would confuse deliberately protected configuration with a broken backend.

| Option | Contract | Consequence |
| --- | --- | --- |
| A. Binary fail-closed | Return `yes` only for proven readiness and collapse every unproved fact into `no`. | Safest for an automatic launcher, but the doctor reports protected or unreachable evidence as a definite defect. |
| B. Binary optimistic | Return `yes` when configuration plausibly permits a spawn and reserve `no` for contradictions. | Reduces apparent failures, but can make a readiness report look actionable when the actual spawn will refuse. |
| C. Typed evidence | Give each validator `pass`, `fail`, `unknown`, or `not_applicable`, and derive `spawn_capable` as `yes`, `no`, or `unknown`. | Preserves the no-side-effect boundary and makes uncertainty visible, but adds schema and consumer discipline. |

Recommendation: choose C.
`unknown` must never contribute to an overall `ready` status or authorize a spawn.
The existing spawn path remains the authoritative binary gate when it is actually asked to launch work.
The doctor only reports why a safe preflight could not establish that gate.

The case against C is its added vocabulary and aggregation rules, which can confuse consumers that only need a launch decision.
Choose A if the doctor will never inspect protected configuration and has no audience for the distinction between unknown and false.
Do not choose B for a readiness claim unless a later, explicitly authorized spawn-time validator converts the claim to proof.

## Focused acceptance proof after the decisions

- Add a targeted doctor regression that asserts its command log contains only declared passive probes and no session creation, attachment, restart, repair, credential read, or state write.
- Cover a Zellij name with spaces, colons, and inventory-looking text, and prove the passive membership check and final-pane parsing retain it exactly.
- Cover unit separator, newline, carriage return, and tab in every doctor result scalar, then compare the decoded JSON values and the TOON rendering without a shifted field boundary.
- Cover a proven available backend, a concrete contradiction, and a secret-free uncertainty, and assert `yes`, `no`, and `unknown` are distinct while only the proven case is `ready`.
- Run the focused backend-doctor and Zellij tests plus `bin/fm-doc-audience-check.sh`, rather than the full script suite.

## Non-decision implementation sequence

After the three choices are made, implement the selected contracts against the current backend owner in one bounded change.
Add the proposed doctor and its focused tests without porting files from `ae79ebc7`.
If Choice 1 requires endpoint-format migration, split that migration from the doctor unless the decision explicitly keeps both changes inseparable.
Document the resulting current operator behavior only after the code and targeted proof establish it.
Do not add repair flags, auto-provisioning, session resurrection, or fallback behavior to this doctor.
