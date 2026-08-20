#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only>
#          [--push-remote <name>] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --report <key>=<text> records a REPORTING OBLIGATION (repeatable; ship and
#   scout only). A brief can state a reporting requirement and a worker can
#   deliver good work while silently omitting it, and nothing notices except a
#   supervisor who still remembers what the brief asked. An obligation recorded
#   here outlives that memory: it is written to data/<task-id>/obligations.tsv,
#   the brief carries the exact one-line command that satisfies it, and
#   bin/fm-teardown.sh refuses cleanup while it is neither reported nor waived.
#   bin/fm-obligations.sh owns the record, the satisfaction shape, and the gate.
#   --source-instruction <path|-> records the ORIGINATING instruction verbatim at
#   data/<task-id>/source-instruction.md and points the worker at it (ship and
#   scout only). A brief is a narrowing of the instruction that prompted it, and
#   that narrowing is a decision: the worker who hits a wall can then read what
#   was originally offered instead of reporting blocked against an alternative it
#   was never told existed.
#   --excluded <text> records one alternative or requirement the originating
#   instruction offered that this brief deliberately does NOT carry (repeatable),
#   or the single literal `none` to state that the brief carries the instruction
#   whole. It is REQUIRED alongside --source-instruction: recording the source is
#   the act of admitting the brief narrows it, so the narrowing must be named
#   rather than left silent. No check compares the two texts - the semantic
#   comparison is the author's judgement, and this flag only forces that
#   judgement to be written down where the worker and a later reader can see it.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
#   --push-remote names the remote a direct-PR worker pushes to, overriding the
#   resolution below. It applies only to --mode direct-PR, because that is the
#   only mode whose worker pushes.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns approval decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# A direct-PR brief must NAME its push target instead of letting the worker fall
# back to git's default of `origin`: in a fork-based checkout `origin` is the
# upstream, so that default push is denied and reads to the worker like a
# permissions wall rather than a wrong remote. The generated DOD therefore
# always carries a fixed machine-readable "Push target: " line, which
# bin/fm-spawn.sh checks before dispatch.
# The remote is resolved from the project clone at scaffold time, in order:
# an explicit --push-remote; the repo's own `remote.pushDefault`; a remote named
# `fork`; `origin`; the first configured remote. When no clone can be inspected
# the line instead tells the worker to resolve the remote in its own worktree,
# which is always better than an unstated `origin` default. A forge-style remote
# URL also yields the explicit `--repo <owner>/<name>` for the PR command.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
MODE=
MODE_SET=0
SOURCE_INSTRUCTION=
SOURCE_INSTRUCTION_SET=0
REPORTS=()
EXCLUDED=()
PUSH_REMOTE=
PUSH_REMOTE_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      report) REPORTS+=("$a") ;;
      source-instruction) SOURCE_INSTRUCTION=$a; SOURCE_INSTRUCTION_SET=1 ;;
      excluded) EXCLUDED+=("$a") ;;
      push-remote) PUSH_REMOTE=$a; PUSH_REMOTE_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --report) want_value=report ;;
    --report=*) REPORTS+=("${a#--report=}") ;;
    --source-instruction) want_value=source-instruction ;;
    --source-instruction=*) SOURCE_INSTRUCTION=${a#--source-instruction=}; SOURCE_INSTRUCTION_SET=1 ;;
    --excluded) want_value=excluded ;;
    --excluded=*) EXCLUDED+=("${a#--excluded=}") ;;
    --push-remote) want_value=push-remote ;;
    --push-remote=*) PUSH_REMOTE=${a#--push-remote=}; PUSH_REMOTE_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's approval authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's approval posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi

# Only a direct-PR worker pushes, so naming a remote anywhere else would look
# recorded and change nothing. Refuse rather than drop it silently.
if [ "$PUSH_REMOTE_SET" -eq 1 ]; then
  [ "$MODE" = direct-PR ] || {
    echo "error: --push-remote applies only to --mode direct-PR; no other brief has the worker push" >&2
    exit 1
  }
  case "$PUSH_REMOTE" in
    '' ) echo "error: --push-remote requires a remote name" >&2; exit 1 ;;
    -*) echo "error: --push-remote must be a remote name, not an option ('$PUSH_REMOTE')" >&2; exit 1 ;;
    *[[:space:]]*) echo "error: --push-remote must be a single remote name (got '$PUSH_REMOTE')" >&2; exit 1 ;;
  esac
fi
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

# Reporting obligations and originating-instruction fidelity are per-task brief
# material: they are enforced at teardown, and a persistent charter is never torn
# down as finished work. Refuse them on a charter rather than writing records
# nothing will ever check.
if [ "$KIND" = secondmate ]; then
  [ "${#REPORTS[@]}" -eq 0 ] || {
    echo "error: --report applies only to crewmate ship or scout briefs" >&2; exit 1; }
  [ "$SOURCE_INSTRUCTION_SET" -eq 0 ] || {
    echo "error: --source-instruction applies only to crewmate ship or scout briefs" >&2; exit 1; }
  [ "${#EXCLUDED[@]}" -eq 0 ] || {
    echo "error: --excluded applies only to crewmate ship or scout briefs" >&2; exit 1; }
fi

# Recording the originating instruction is the act of admitting this brief is a
# narrowing of it. Nothing here can compare the two texts - that judgement is the
# brief author's - so the one thing this scaffold CAN do is refuse to let the
# narrowing stay silent: name what the instruction offered and this brief drops,
# or state `none` and mean it. Same fail-closed discipline as --mode.
if [ "$SOURCE_INSTRUCTION_SET" -eq 1 ] && [ "${#EXCLUDED[@]}" -eq 0 ]; then
  echo "error: --source-instruction requires at least one --excluded <text>, or --excluded none" >&2
  echo "A brief that narrows its originating instruction is making a decision; record what it drops." >&2
  exit 1
fi

# `none` is an explicit whole-instruction attestation, so it cannot be one item
# in a list of exclusions - that would be a contradiction recorded as fact.
if [ "${#EXCLUDED[@]}" -gt 1 ]; then
  for e in "${EXCLUDED[@]}"; do
    [ "$e" = none ] || continue
    echo "error: --excluded none states the brief drops nothing; it cannot be combined with other --excluded entries" >&2
    exit 1
  done
fi

# Each --report is "<key>=<text>": the key is the slug the worker states in its
# status line and the gate matches on, so it is validated here rather than at
# teardown, when the brief is long gone.
REPORT_KEYS=()
REPORT_TEXTS=()
if [ "${#REPORTS[@]}" -gt 0 ]; then
  for r in "${REPORTS[@]}"; do
    case "$r" in
      *=*) ;;
      *) echo "error: --report must be <key>=<text> (got '$r')" >&2; exit 1 ;;
    esac
    rkey=${r%%=*}
    rtext=${r#*=}
    _fm_decision_slug_ok "$rkey" || {
      echo "error: --report key must be a slug of A-Za-z0-9._- (got '$rkey')" >&2; exit 1; }
    [ -n "$rtext" ] || { echo "error: --report '$rkey' has empty text" >&2; exit 1; }
    for existing in ${REPORT_KEYS[@]+"${REPORT_KEYS[@]}"}; do
      [ "$existing" != "$rkey" ] || {
        echo "error: duplicate --report key '$rkey'" >&2; exit 1; }
    done
    REPORT_KEYS+=("$rkey")
    REPORT_TEXTS+=("$rtext")
  done
fi

# Read the originating instruction NOW, before anything is written, so an
# unreadable path fails the scaffold instead of producing a brief that points at
# a record that does not exist.
SOURCE_INSTRUCTION_TEXT=
if [ "$SOURCE_INSTRUCTION_SET" -eq 1 ]; then
  if [ "$SOURCE_INSTRUCTION" = "-" ]; then
    SOURCE_INSTRUCTION_TEXT=$(cat)
  else
    [ -f "$SOURCE_INSTRUCTION" ] && [ -r "$SOURCE_INSTRUCTION" ] || {
      echo "error: --source-instruction file cannot be read: $SOURCE_INSTRUCTION" >&2; exit 1; }
    SOURCE_INSTRUCTION_TEXT=$(cat -- "$SOURCE_INSTRUCTION")
  fi
  [ -n "$SOURCE_INSTRUCTION_TEXT" ] || {
    echo "error: --source-instruction content is empty" >&2; exit 1; }
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# Both sections below follow one whitespace convention so an unused section
# leaves the generated brief byte-identical to what it was before this flag
# existed: the variable is EMPTY when unused and occupies a heredoc line that
# was already blank, and when used it carries its own surrounding blank lines.
SOURCE_SECTION=
OBLIGATIONS_SECTION=

if [ "$SOURCE_INSTRUCTION_SET" -eq 1 ]; then
  SOURCE_RECORD="$DATA/$ID/source-instruction.md"
  [ -e "$SOURCE_RECORD" ] && {
    echo "error: $SOURCE_RECORD already exists" >&2; exit 1; }
  printf '%s\n' "$SOURCE_INSTRUCTION_TEXT" > "$SOURCE_RECORD"
  SOURCE_BODY="# Originating instruction
The instruction that prompted this task is recorded verbatim at \`$SOURCE_RECORD\`.
The \`# Task\` section above is this brief's reading of that instruction, not a copy of it.
If you hit a wall the Task section gives you no way around, READ that file before you report blocked: it may have offered an alternative this brief did not carry."
  if [ "${#EXCLUDED[@]}" -eq 1 ] && [ "${EXCLUDED[0]}" = none ]; then
    SOURCE_BODY="$SOURCE_BODY

The brief author states this brief carries that instruction whole and drops nothing from it.
If you find that is not true, say so - that is a finding about the instructions, and it is worth reporting."
  else
    SOURCE_BODY="$SOURCE_BODY

The brief author deliberately excluded the following from this task:"
    for e in "${EXCLUDED[@]}"; do
      SOURCE_BODY="$SOURCE_BODY
- $e"
    done
    SOURCE_BODY="$SOURCE_BODY

Those exclusions are decisions, not oversights. Work within them; if one of them is the only way past a wall, report that as a decision for firstmate rather than crossing it silently."
  fi
  SOURCE_SECTION="
$SOURCE_BODY
"
fi

if [ "${#REPORT_KEYS[@]}" -gt 0 ]; then
  OB_BODY="# Reporting obligations
This brief states reporting requirements that are recorded durably, not only written here.
Satisfy each one by appending exactly the line shown under it; cleanup of this task is refused while any of them is unreported, so an omission is visible rather than silent.
Append them before your terminal status line.
Each obligation asks you to STATE what you observed - it never asks for a particular result, and a result you did not expect is still a satisfied obligation."
  ob_idx=0
  while [ "$ob_idx" -lt "${#REPORT_KEYS[@]}" ]; do
    OB_BODY="$OB_BODY

- ${REPORT_TEXTS[$ob_idx]}
  \`echo \"note [key=${REPORT_KEYS[$ob_idx]}]: {what you observed}\" >> $STATUS_FILE\`"
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-obligations.sh" record "$ID" "${REPORT_KEYS[$ob_idx]}" \
      --text "${REPORT_TEXTS[$ob_idx]}" >/dev/null
    ob_idx=$((ob_idx + 1))
  done
  OBLIGATIONS_SECTION="
$OB_BODY
"
fi

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main firstmate's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main firstmate, append \`resolved: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}
$SOURCE_SECTION
$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
$OBLIGATIONS_SECTION
# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
If your deliverable is a visual artifact the captain will review and iterate on, you may host the Lavish review loop yourself (poll, revise, re-serve, staying alive) instead of handing it back to firstmate.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# --- direct-PR push target ---------------------------------------------------
# A direct-PR worker is the only one that pushes, and git's own default target is
# `origin`. In a fork-based checkout `origin` is the upstream nobody can push to,
# so an unnamed target turns a wrong-remote instruction into what reads like a
# permissions wall. Resolve the target here and name it in the brief.

PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

brief_repo_dir() {  # -> the project clone's own worktree top-level, or nothing
  local cand abs top top_real
  for cand in "$PROJECTS/$REPO" "$REPO"; do
    [ -d "$cand" ] || continue
    abs=$(CDPATH='' cd -- "$cand" 2>/dev/null && pwd -P) || continue
    top=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null) || continue
    top_real=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || continue
    # Require the candidate to BE the repository root: a non-repo directory that
    # merely sits inside one would otherwise borrow that ancestor's remotes.
    [ "$abs" = "$top_real" ] || continue
    printf '%s\n' "$abs"
    return 0
  done
  return 1
}

brief_resolve_push_remote() {  # <repo-dir> -> remote name, or nothing
  local dir=$1 configured candidate
  configured=$(git -C "$dir" config --get remote.pushDefault 2>/dev/null) || configured=
  if [ -n "$configured" ] && git -C "$dir" remote get-url "$configured" >/dev/null 2>&1; then
    printf '%s\n' "$configured"
    return 0
  fi
  # `fork` is the conventional name for the writable side of a triangular
  # workflow, which is exactly the case git's own default gets wrong.
  for candidate in fork origin; do
    if git -C "$dir" remote get-url "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  git -C "$dir" remote 2>/dev/null | head -n 1
}

brief_remote_slug() {  # <remote-url> -> owner/name for a forge URL, nothing otherwise
  local url=$1 path
  case "$url" in
    ''|file://*|/*|.*) return 0 ;;
    *://*)
      path=${url#*://}
      path=${path#*@}
      case "$path" in */*) path=${path#*/} ;; *) return 0 ;; esac
      ;;
    *:*/*) path=${url#*:} ;;
    *) return 0 ;;
  esac
  path=${path%.git}
  path=${path#/}
  # Keep only the final two segments, so a nested group path still yields the
  # owner/name pair every forge CLI expects.
  case "$path" in
    */*/*) path=${path#"${path%/*/*}/"} ;;
  esac
  case "$path" in
    */*/*|*/) return 0 ;;
    */*) printf '%s\n' "$path" ;;
  esac
}

# The generated line always begins with the fixed "Push target: " prefix that
# bin/fm-spawn.sh checks before dispatch.
brief_push_target_line() {
  local dir remote url slug push_cmd origin_url
  dir=$(brief_repo_dir) || dir=
  remote=$PUSH_REMOTE
  if [ -z "$remote" ] && [ -n "$dir" ]; then
    remote=$(brief_resolve_push_remote "$dir")
  fi
  if [ -z "$remote" ]; then
    printf '%s' "Push target: this scaffold could not resolve the project's push remote, so resolve it in your worktree before pushing: run \`git remote -v\` and push to the remote you can actually write to, then pass that remote's \`<owner>/<name>\` to every \`gh-axi\` call for this PR. Do not let git fall back to \`origin\`: it is often a read-only upstream, so a denied push there means the wrong remote, not a permissions problem."
    return 0
  fi
  url=
  slug=
  if [ -n "$dir" ]; then
    url=$(git -C "$dir" remote get-url --push "$remote" 2>/dev/null) || url=
    [ -z "$url" ] || slug=$(brief_remote_slug "$url")
  fi
  push_cmd="git push $remote HEAD:refs/heads/fm/$ID"
  printf '%s' "Push target: the \`$remote\` remote"
  [ -z "$url" ] || printf '%s' " ($url)"
  printf '%s' ". Push with \`$push_cmd\`"
  if [ -n "$slug" ]; then
    printf '%s' " and pass \`--repo $slug\` to every \`gh-axi\` call for this PR"
  else
    printf '%s' " and name the PR's target repository explicitly rather than letting the tool infer it"
  fi
  printf '%s' "."
  # Only warn about git's default when following it would actually land
  # somewhere else; an `origin` that already points at the same repository makes
  # the warning a false alarm.
  if [ "$remote" != origin ] && [ -n "$dir" ]; then
    origin_url=$(git -C "$dir" remote get-url --push origin 2>/dev/null) || origin_url=
    if [ -n "$origin_url" ] && [ "$origin_url" != "$url" ]; then
      printf '%s' " Do not let git fall back to \`origin\` ($origin_url): pushing there is denied because it is the wrong target, not because your permissions are wrong."
    fi
  fi
}

# Ship task: shape Setup / Rule 1 / Definition of done by this task's explicit
# delivery mode, validated above. The generated DOD opens with the fixed
# "Delivery contract: mode=<mode>" line that bin/fm-spawn.sh checks against its own
# explicit --mode before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    PUSH_TARGET=$(brief_push_target_line)
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
$PUSH_TARGET
When it is implemented and committed, push that branch to the target above and open the PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}
$SOURCE_SECTION
$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will apply the configured authority and reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.
$OBLIGATIONS_SECTION
$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
