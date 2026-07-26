#!/usr/bin/env node
/**
 * Sealed dispatch-envelope and report-only refill implementation.
 *
 * This file is an internal implementation detail of fm-dispatch-stage.sh and
 * fm-auto-dispatch-once.sh.
 * The shell entrypoints own the public command surface.
 */
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SOURCE_ROOT = resolve(SCRIPT_DIR, "..");
const MAX_BRIEF_BYTES = 1024 * 1024;
const MAX_COMMAND_BYTES = 1024 * 1024;
const MAX_TARGET_RUNNING = 64;
const MAX_TERMINAL_BUFFER = 64;
const MAX_LAUNCHES_PER_TICK = 16;
const DEFAULT_INTERVAL_SECONDS = 60;
const DEFAULT_SUPERVISION_GRACE_SECONDS = 300;
const MAX_EPISODE_KEYS = 64;
const VERIFIED_HARNESSES = new Set(["claude", "codex", "opencode", "grok", "kimi", "pi"]);
const SESSION_LOCK_LIB = join(SCRIPT_DIR, "fm-session-lock-lib.sh");

class DispatchError extends Error {
  constructor(message, code = "DISPATCH_INVALID") {
    super(message);
    this.code = code;
  }
}

function fail(message, code) {
  throw new DispatchError(message, code);
}

function sha256(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value !== null && typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      result[key] = canonicalize(value[key]);
    }
    return result;
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch {
    fail(`${label} is not valid JSON`);
  }
}

function safeRead(path, label, maxBytes = MAX_COMMAND_BYTES) {
  let info;
  try {
    info = lstatSync(path);
  } catch {
    fail(`${label} is missing`);
  }
  if (!info.isFile() || info.isSymbolicLink()) {
    fail(`${label} must be a regular non-symlink file`);
  }
  if (info.size > maxBytes) {
    fail(`${label} exceeds the ${maxBytes}-byte limit`);
  }
  return readFileSync(path);
}

function atomicWrite(path, value, mode = 0o600) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.tmp.${process.pid}.${randomBytes(6).toString("hex")}`;
  let fd;
  try {
    fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, mode);
    writeFileSync(fd, value);
    closeSync(fd);
    fd = undefined;
    chmodSync(temporary, mode);
    renameSync(temporary, path);
  } finally {
    if (fd !== undefined) {
      closeSync(fd);
    }
    rmSync(temporary, { force: true });
  }
}

function resolveContext() {
  const rootInput = process.env.FM_ROOT_OVERRIDE || SOURCE_ROOT;
  const homeInput = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || SOURCE_ROOT;
  let root;
  let home;
  try {
    root = realpathSync(rootInput);
    home = realpathSync(homeInput);
  } catch {
    fail("FM_ROOT and FM_HOME must resolve to existing directories");
  }
  return {
    root,
    home,
    data: join(home, "data"),
    state: join(home, "state"),
    config: join(home, "config"),
    backlog: join(home, "data", "backlog.md"),
  };
}

function parseOptions(args, allowedValueFlags, allowedBoolFlags = []) {
  const options = {};
  const positionals = [];
  const valueFlags = new Set(allowedValueFlags);
  const boolFlags = new Set(allowedBoolFlags);
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith("--")) {
      positionals.push(arg);
      continue;
    }
    if (boolFlags.has(arg)) {
      options[arg.slice(2)] = true;
      continue;
    }
    if (!valueFlags.has(arg)) {
      fail(`unknown flag: ${arg}`);
    }
    const value = args[index + 1];
    if (value === undefined || value.startsWith("--")) {
      fail(`${arg} requires a value`);
    }
    options[arg.slice(2)] = value;
    index += 1;
  }
  return { options, positionals };
}

function requireString(value, label) {
  if (typeof value !== "string" || value.trim() === "" || /[\r\n\0]/.test(value)) {
    fail(`${label} must be a non-empty single-line string`);
  }
  return value;
}

function validateId(value) {
  requireString(value, "task id");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)) {
    fail("task id contains unsupported characters");
  }
  return value;
}

function runResult(command, args, context) {
  const result = spawnSync(command, args, {
    cwd: context.home,
    encoding: "utf8",
    maxBuffer: MAX_COMMAND_BYTES,
    timeout: 15000,
    env: process.env,
  });
  if (result.error) {
    fail(`${command} failed: ${result.error.message}`, "COMMAND_FAILED");
  }
  return result;
}

function run(command, args, context, acceptedStatuses = [0]) {
  const result = runResult(command, args, context);
  if (!acceptedStatuses.includes(result.status)) {
    const detail = (result.stderr || result.stdout || `exit ${result.status}`).trim();
    fail(`${command} ${args[0] || ""} failed: ${detail}`, "COMMAND_FAILED");
  }
  return result.stdout;
}

function tasksAxiSupportsMachineClaim(context) {
  const readyHelp = run("tasks-axi", ["ready", "--help"], context);
  const claimHelp = run("tasks-axi", ["claim", "--help"], context, [0, 1, 2]);
  return readyHelp.includes("--json")
    && claimHelp.includes("--if-ready")
    && claimHelp.includes("--json");
}

function requireMachineQueue(context) {
  const backendFile = join(context.config, "backlog-backend");
  if (existsSync(backendFile)) {
    const backend = safeRead(backendFile, "config/backlog-backend", 128).toString("utf8").trim() || "tasks-axi";
    if (backend === "manual") {
      fail("manual backlog mode does not provide atomic ready claims", "QUEUE_UNSUPPORTED");
    }
    if (backend !== "tasks-axi") {
      fail(`unsupported backlog backend: ${backend}`, "QUEUE_UNSUPPORTED");
    }
  }
  if (!tasksAxiSupportsMachineClaim(context)) {
    fail("tasks-axi must provide ready --json and claim --if-ready --json", "QUEUE_UNSUPPORTED");
  }
}

function readyTasks(context) {
  requireMachineQueue(context);
  const output = run(
    "tasks-axi",
    ["ready", "--file", context.backlog, "--json"],
    context,
  );
  const payload = parseJson(output, "tasks-axi ready output");
  if (payload?.ok !== true || payload?.action !== "ready" || !Array.isArray(payload.ready)) {
    fail("tasks-axi ready JSON does not match the required machine contract", "QUEUE_UNSUPPORTED");
  }
  if (payload.count !== undefined && payload.count !== payload.ready.length) {
    fail("tasks-axi ready JSON count is inconsistent", "QUEUE_UNSUPPORTED");
  }
  const seen = new Set();
  for (const task of payload.ready) {
    const id = validateReadyTaskSchema(task);
    if (seen.has(id)) {
      fail(`tasks-axi ready JSON repeats task ${id}`, "QUEUE_UNSUPPORTED");
    }
    seen.add(id);
  }
  return payload.ready;
}

/**
 * Structural schema only: a violation means the backend broke its machine
 * contract, which is a hard stop. Per-task eligibility is a separate,
 * per-candidate decision owned by readyTaskIneligibility.
 */
function validateReadyTaskSchema(task) {
  if (task === null || typeof task !== "object" || Array.isArray(task)) {
    fail("ready task must be a JSON object", "QUEUE_UNSUPPORTED");
  }
  if (typeof task.id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(task.id)) {
    fail("ready task id is missing or contains unsupported characters", "QUEUE_UNSUPPORTED");
  }
  const id = task.id;
  for (const field of ["state", "title", "repo"]) {
    const value = task[field];
    if (typeof value !== "string" || value.trim() === "" || /[\r\n\0]/.test(value)) {
      fail(`task ${id} ${field} must be a non-empty single-line string`, "QUEUE_UNSUPPORTED");
    }
  }
  if (task.body !== null && task.body !== undefined && typeof task.body !== "string") {
    fail(`task ${id} body must be a string or null`, "QUEUE_UNSUPPORTED");
  }
  if (task.kind !== null && task.kind !== undefined && typeof task.kind !== "string") {
    fail(`task ${id} kind must be a string or null`, "QUEUE_UNSUPPORTED");
  }
  if (!Array.isArray(task.deps)) {
    fail(`task ${id} deps must be an array`, "QUEUE_UNSUPPORTED");
  }
  if (typeof task.blocked !== "boolean" || typeof task.held !== "boolean") {
    fail(`task ${id} blocked and held must be booleans`, "QUEUE_UNSUPPORTED");
  }
  if (!Array.isArray(task.blocked_by)) {
    fail(`task ${id} blocked_by must be an array`, "QUEUE_UNSUPPORTED");
  }
  return id;
}

/**
 * Null when the task may be dispatched, otherwise the concrete reason it is
 * not eligible right now. Ineligibility is ordinary queue state, never a
 * malformed contract, so a caller iterating candidates skips and continues.
 */
function readyTaskIneligibility(task, expectedState = "queued") {
  const id = validateReadyTaskSchema(task);
  if (task.state !== expectedState) {
    return `task ${id} is ${task.state}, not ${expectedState}`;
  }
  if (task.kind === "public-followup" || task.public_followup != null) {
    return `task ${id} is a public-followup`;
  }
  if (task.blocked !== false || task.held !== false) {
    return `task ${id} is blocked or held`;
  }
  if (task.hold !== null && task.hold !== undefined) {
    return `task ${id} has a dispatch hold`;
  }
  if (task.blocked_by.length !== 0) {
    return `task ${id} has active blockers`;
  }
  return null;
}

function requireEligibleReadyTask(task, expectedState = "queued") {
  const reason = readyTaskIneligibility(task, expectedState);
  if (reason !== null) {
    fail(reason, "TASK_NOT_READY");
  }
  return task.id;
}

function taskFingerprint(task) {
  validateReadyTaskSchema(task);
  return sha256(canonicalJson({
    id: task.id,
    title: task.title,
    body: task.body ?? null,
    repo: task.repo,
    kind: task.kind ?? null,
    deps: task.deps,
    hold: task.hold ?? null,
    blocked: task.blocked,
    blocked_by: task.blocked_by,
    held: task.held,
  }));
}

function tryParseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/**
 * Returns the claimed task, or null when the backend's conditional gate
 * unambiguously reports that another queue writer won the ready-to-claim race.
 * Losing that race is the benign outcome --if-ready exists to produce, so it
 * skips the candidate; every other claim failure is still a hard stop.
 */
function claimTask(context, id) {
  const result = runResult(
    "tasks-axi",
    ["claim", id, "--if-ready", "--file", context.backlog, "--json"],
    context,
  );
  if (result.status !== 0) {
    const payload = tryParseJson(result.stdout ?? "") ?? tryParseJson(result.stderr ?? "");
    if (payload?.ok === false && payload?.error === "not-ready") {
      return null;
    }
    const detail = (result.stderr || result.stdout || `exit ${result.status}`).trim();
    fail(`tasks-axi claim failed: ${detail}`, "COMMAND_FAILED");
  }
  const payload = parseJson(result.stdout, "tasks-axi claim output");
  if (payload?.ok !== true || payload?.action !== "claim" || payload?.task?.id !== id) {
    fail("tasks-axi claim JSON does not match the required machine contract", "QUEUE_UNSUPPORTED");
  }
  validateReadyTaskSchema(payload.task);
  if (payload.task.state !== "in_flight") {
    fail(`tasks-axi claim left ${id} in state ${payload.task.state}`, "QUEUE_UNSUPPORTED");
  }
  return payload.task;
}

function reopenTask(context, id) {
  const output = run(
    "tasks-axi",
    ["reopen", id, "--file", context.backlog, "--json"],
    context,
  );
  const payload = parseJson(output, "tasks-axi reopen output");
  if (payload?.ok !== true || payload?.action !== "reopen" || payload?.task?.id !== id || payload.task.state !== "queued") {
    fail(`tasks-axi did not reopen claimed task ${id}`, "CLAIM_STRANDED");
  }
}

/**
 * bin/fm-session-lock-lib.sh is the ONE owner of verified-harness identity and
 * ancestry. Calling it keeps this consumer from drifting into a second, subtly
 * different definition of the same decision.
 */
function sessionLockHelper(fn, args = []) {
  return spawnSync(
    "bash",
    ["-c", `. "$1" || exit 1; shift; ${fn} "$@"`, "_", SESSION_LOCK_LIB, ...args],
    { encoding: "utf8", maxBuffer: 65536, env: process.env },
  );
}

function isAliveHarness(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) {
    return false;
  }
  return sessionLockHelper("fm_harness_pid_alive", [String(pid)]).status === 0;
}

/**
 * Walks from this process's parent, never from this process: a staging call
 * carries the requested harness name in its own argv, which would otherwise
 * match the ancestry rule against itself.
 */
function harnessAncestryPid() {
  const result = sessionLockHelper("fm_harness_ancestry_pid", [String(process.ppid)]);
  const value = result.stdout?.trim() ?? "";
  return result.status === 0 && /^[0-9]+$/.test(value) ? Number(value) : null;
}

function requireOwningFirstmate(context) {
  const raw = safeRead(join(context.state, ".lock"), "firstmate session lock", 64).toString("utf8").trim();
  if (!/^[0-9]+$/.test(raw)) {
    fail("firstmate session lock has no valid owner", "OWNERSHIP_CHANGED");
  }
  const owner = Number(raw);
  if (!isAliveHarness(owner)) {
    fail("firstmate session lock owner is not a live verified harness", "OWNERSHIP_CHANGED");
  }
  const ancestor = harnessAncestryPid();
  if (ancestor === null) {
    fail("dispatch staging has no verified firstmate ancestor", "AUTHOR_UNAUTHORIZED");
  }
  if (ancestor !== owner) {
    fail("dispatch staging was not invoked by the lock-owning firstmate", "AUTHOR_UNAUTHORIZED");
  }
}

function readSealKey(context, create) {
  const keyPath = join(context.state, ".auto-dispatch-seal.key");
  mkdirSync(context.state, { recursive: true, mode: 0o700 });
  if (!existsSync(keyPath) && create) {
    let fd;
    try {
      fd = openSync(keyPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      writeFileSync(fd, randomBytes(32).toString("hex"));
      closeSync(fd);
      fd = undefined;
    } catch (error) {
      if (error?.code !== "EEXIST") {
        throw error;
      }
    } finally {
      if (fd !== undefined) {
        closeSync(fd);
      }
    }
  }
  if (!existsSync(keyPath)) {
    fail("auto-dispatch seal key is missing, so no envelope can be verified", "SEAL_INVALID");
  }
  const key = safeRead(keyPath, "auto-dispatch seal key", 128);
  const info = statSync(keyPath);
  if ((info.mode & 0o077) !== 0) {
    fail("auto-dispatch seal key must not be group or world accessible", "SEAL_INVALID");
  }
  if (!/^[0-9a-f]{64}$/.test(key.toString("utf8"))) {
    fail("auto-dispatch seal key is malformed", "SEAL_INVALID");
  }
  return Buffer.from(key.toString("utf8"), "hex");
}

function sealEnvelope(envelope, key) {
  return createHmac("sha256", key).update(canonicalJson(envelope)).digest("hex");
}

function verifyEnvelopeSeal(manifest, context) {
  if (manifest?.seal?.algorithm !== "hmac-sha256" || !/^[0-9a-f]{64}$/.test(manifest?.seal?.value || "")) {
    fail("dispatch envelope has no valid seal", "SEAL_INVALID");
  }
  const unsigned = { ...manifest };
  delete unsigned.seal;
  const actual = Buffer.from(manifest.seal.value, "hex");
  const expected = Buffer.from(sealEnvelope(unsigned, readSealKey(context, false)), "hex");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    fail("dispatch envelope seal does not verify", "SEAL_INVALID");
  }
}

function configFingerprint(context) {
  const path = join(context.config, "crew-dispatch.json");
  if (!existsSync(path)) {
    return sha256("absent");
  }
  return sha256(safeRead(path, "config/crew-dispatch.json"));
}

function projectMode(context, repo) {
  const registry = safeRead(join(context.data, "projects.md"), "data/projects.md").toString("utf8");
  const registered = registry.split(/\r?\n/).some((line) => {
    const match = line.match(/^\s*-\s+(\S+)(?:\s+\[[^\]]+\])?\s+-\s+/);
    return match?.[1] === repo;
  });
  if (!registered) {
    fail(`project ${repo} is not registered in this home`, "PROJECT_INVALID");
  }
  const output = run(join(context.root, "bin", "fm-project-mode.sh"), [repo], context).trim();
  const match = output.match(/^(no-mistakes|direct-PR|local-only) (on|off)$/);
  if (!match) {
    fail(`project mode for ${repo} is indeterminate`, "PROJECT_INVALID");
  }
  return { mode: match[1], yolo: match[2] };
}

function briefPath(context, id) {
  const taskDir = join(context.data, id);
  let resolvedDir;
  try {
    resolvedDir = realpathSync(taskDir);
  } catch {
    fail(`task directory data/${id} is missing`, "BRIEF_INVALID");
  }
  if (resolvedDir !== taskDir) {
    fail("task directory must resolve inside the exact owning home", "BRIEF_INVALID");
  }
  const path = join(taskDir, "brief.md");
  let resolvedBrief;
  try {
    resolvedBrief = realpathSync(path);
  } catch {
    fail(`brief for ${id} is missing`, "BRIEF_INVALID");
  }
  if (resolvedBrief !== path) {
    fail("brief path must be the exact non-symlink task brief", "BRIEF_INVALID");
  }
  return path;
}

function validateBrief(context, id, repo, kind, mode, herdrLifecycle) {
  const path = briefPath(context, id);
  const bytes = safeRead(path, `brief for ${id}`, MAX_BRIEF_BYTES);
  const text = bytes.toString("utf8");
  if (text.includes("\0")) {
    fail("brief contains a NUL byte", "BRIEF_INVALID");
  }
  if (text.includes("{TASK}")) {
    fail("brief still contains the literal {TASK} placeholder", "BRIEF_INVALID");
  }
  const taskHeading = text.match(/^# Task[ \t]*\r?$/m);
  if (!taskHeading) {
    fail("brief has no # Task section", "BRIEF_INVALID");
  }
  const afterHeading = text.slice(taskHeading.index + taskHeading[0].length);
  const nextHeading = afterHeading.search(/\r?\n#\s+/);
  const taskBody = (nextHeading === -1 ? afterHeading : afterHeading.slice(0, nextHeading)).trim();
  if (taskBody === "") {
    fail("brief has an empty # Task section", "BRIEF_INVALID");
  }
  if (!text.includes(`You are in a disposable git worktree of ${repo},`)) {
    fail("brief project does not match the staged project", "BRIEF_INVALID");
  }
  if (kind === "scout") {
    if (!text.includes("This is a SCOUT task:")) {
      fail("scout brief is missing its scout contract", "BRIEF_INVALID");
    }
    if (!text.includes(`${context.data}/${id}/report.md`)) {
      fail("scout brief report path does not match the owning home", "BRIEF_INVALID");
    }
  } else if (kind === "ship") {
    if (!text.includes("**Verify isolation before anything else.**")
      || !text.includes(`git checkout -b fm/${id}`)) {
      fail("ship brief is missing its worktree-isolation contract", "BRIEF_INVALID");
    }
    const modeMarker = {
      "no-mistakes": "Firstmate will then instruct you to run /no-mistakes",
      "direct-PR": "This project ships **direct-PR**",
      "local-only": "This project ships **local-only**",
    }[mode.mode];
    if (!text.includes(modeMarker)) {
      fail("ship brief delivery contract does not match the project mode", "BRIEF_INVALID");
    }
  } else {
    fail(`unsupported dispatch kind: ${kind}`, "BRIEF_INVALID");
  }
  const guarded = text.includes("# Herdr isolation - HARD SAFETY CONTRACT");
  const unguarded = text.includes("# Herdr lifecycle declaration - NOT ENABLED");
  if (herdrLifecycle === "guarded" && (!guarded || unguarded)) {
    fail("guarded Herdr attestation does not match the brief", "BRIEF_INVALID");
  }
  if (herdrLifecycle === "none" && (!unguarded || guarded)) {
    fail("non-Herdr attestation does not match the brief", "BRIEF_INVALID");
  }
  return { path, sha: sha256(bytes) };
}

function parseManifest(path, context) {
  const manifest = parseJson(safeRead(path, "dispatch envelope").toString("utf8"), "dispatch envelope");
  verifyEnvelopeSeal(manifest, context);
  if (manifest.schema !== "fm-dispatch.v1") {
    fail("dispatch envelope schema is unsupported", "ENVELOPE_STALE");
  }
  return manifest;
}

function verifyManifest(context, task, path) {
  const manifest = parseManifest(path, context);
  const id = validateReadyTaskSchema(task);
  if (manifest.id !== id || manifest.home !== context.home || manifest.repo !== task.repo) {
    fail(`dispatch envelope identity is stale for ${id}`, "ENVELOPE_STALE");
  }
  if (!["ship", "scout"].includes(manifest.kind)) {
    fail(`dispatch envelope kind is invalid for ${id}`, "ENVELOPE_STALE");
  }
  if (manifest.staged_by !== "firstmate" || typeof manifest.staged_at !== "string") {
    fail(`dispatch envelope provenance is invalid for ${id}`, "ENVELOPE_STALE");
  }
  if (manifest.task_fingerprint !== taskFingerprint(task)) {
    fail(`task ${id} changed after staging`, "ENVELOPE_STALE");
  }
  const mode = projectMode(context, manifest.repo);
  if (manifest.project_mode !== mode.mode || manifest.project_yolo !== mode.yolo) {
    fail(`project mode for ${id} changed after staging`, "ENVELOPE_STALE");
  }
  if (manifest.dispatch_config_sha256 !== configFingerprint(context)) {
    fail(`dispatch profile configuration for ${id} changed after staging`, "ENVELOPE_STALE");
  }
  const brief = validateBrief(
    context,
    id,
    manifest.repo,
    manifest.kind,
    mode,
    manifest.herdr_lifecycle,
  );
  if (manifest.brief_sha256 !== brief.sha) {
    fail(`brief for ${id} changed after staging`, "ENVELOPE_STALE");
  }
  requireString(manifest.launch_profile?.harness, `launch profile harness for ${id}`);
  for (const axis of ["model", "effort"]) {
    if (manifest.launch_profile?.[axis] !== undefined) {
      requireString(manifest.launch_profile[axis], `launch profile ${axis} for ${id}`);
    }
  }
  return manifest;
}

function stage(args) {
  const context = resolveContext();
  const { options, positionals } = parseOptions(
    args,
    ["--repo", "--kind", "--harness", "--model", "--effort", "--herdr-lifecycle"],
  );
  if (positionals.length !== 1) {
    fail("usage: fm-dispatch-stage.sh <id> --repo <repo> --kind <ship|scout> --harness <harness> [--model <model>] [--effort <effort>] --herdr-lifecycle <none|guarded>");
  }
  const id = validateId(positionals[0]);
  const repo = requireString(options.repo, "--repo");
  const kind = requireString(options.kind, "--kind");
  const harness = requireString(options.harness, "--harness");
  const herdrLifecycle = requireString(options["herdr-lifecycle"], "--herdr-lifecycle");
  if (!["ship", "scout"].includes(kind)) {
    fail("--kind must be ship or scout");
  }
  if (!["none", "guarded"].includes(herdrLifecycle)) {
    fail("--herdr-lifecycle must be none or guarded");
  }
  if (!VERIFIED_HARNESSES.has(harness)) {
    fail("--harness must name a verified firstmate harness");
  }
  requireOwningFirstmate(context);
  const receiptPath = join(context.state, "auto-dispatch-receipts", `${id}.json`);
  if (existsSync(receiptPath)) {
    fail(
      `task ${id} already has an auto-dispatch report receipt at ${receiptPath}; refill will keep skipping ${id} until that receipt is retired`,
      "RECEIPT_PRESENT",
    );
  }
  const tasks = readyTasks(context);
  const task = tasks.find((candidate) => candidate.id === id);
  if (!task) {
    fail(`task ${id} is not currently ready in this home`, "TASK_NOT_READY");
  }
  requireEligibleReadyTask(task);
  if (task.repo !== repo) {
    fail(`task ${id} belongs to ${task.repo}, not ${repo}`, "TASK_NOT_READY");
  }
  const mode = projectMode(context, repo);
  const brief = validateBrief(context, id, repo, kind, mode, herdrLifecycle);
  const profile = { harness };
  if (options.model !== undefined) {
    profile.model = requireString(options.model, "--model");
  }
  if (options.effort !== undefined) {
    profile.effort = requireString(options.effort, "--effort");
  }
  const envelope = {
    schema: "fm-dispatch.v1",
    id,
    home: context.home,
    repo,
    kind,
    task_fingerprint: taskFingerprint(task),
    brief_sha256: brief.sha,
    project_mode: mode.mode,
    project_yolo: mode.yolo,
    launch_profile: profile,
    dispatch_config_sha256: configFingerprint(context),
    herdr_lifecycle: herdrLifecycle,
    staged_by: "firstmate",
    staged_at: new Date().toISOString(),
  };
  const key = readSealKey(context, true);
  const manifest = {
    ...envelope,
    seal: {
      algorithm: "hmac-sha256",
      value: sealEnvelope(envelope, key),
    },
  };
  const outputPath = join(context.data, id, "dispatch.json");
  atomicWrite(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, 0o400);
  process.stdout.write(`${JSON.stringify({ ok: true, action: "stage", envelope: outputPath, manifest }, null, 2)}\n`);
}

function positiveInteger(value, label, maximum) {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    fail(`${label} must be an integer from 1 through ${maximum}`, "CAP_INDETERMINATE");
  }
  return value;
}

function nonNegativeInteger(value, label, maximum) {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
    fail(`${label} must be an integer from 0 through ${maximum}`, "CAP_INDETERMINATE");
  }
  return value;
}

function readAutoDispatchConfig(context) {
  const path = join(context.config, "auto-dispatch.json");
  if (!existsSync(path)) {
    return null;
  }
  const config = parseJson(safeRead(path, "config/auto-dispatch.json", 65536).toString("utf8"), "config/auto-dispatch.json");
  if (config === null || typeof config !== "object" || Array.isArray(config)) {
    fail("config/auto-dispatch.json must contain an object", "CAP_INDETERMINATE");
  }
  const allowed = new Set([
    "enabled",
    "mode",
    "target_running",
    "terminal_buffer",
    "max_launches_per_tick",
    "interval_seconds",
  ]);
  const unknown = Object.keys(config).filter((key) => !allowed.has(key));
  if (unknown.length > 0) {
    fail(`auto-dispatch config has unknown field: ${unknown[0]}`, "CAP_INDETERMINATE");
  }
  if (config.enabled === false) {
    return null;
  }
  if (config.enabled !== true) {
    fail("auto-dispatch enabled must be true or false", "CAP_INDETERMINATE");
  }
  if (config.mode !== "report-only") {
    fail("auto-dispatch mode must be report-only in this release", "CAP_INDETERMINATE");
  }
  const targetRunning = positiveInteger(config.target_running, "target_running", MAX_TARGET_RUNNING);
  const terminalBuffer = config.terminal_buffer === undefined
    ? targetRunning
    : nonNegativeInteger(config.terminal_buffer, "terminal_buffer", MAX_TERMINAL_BUFFER);
  const maxLaunches = config.max_launches_per_tick === undefined
    ? 1
    : positiveInteger(config.max_launches_per_tick, "max_launches_per_tick", MAX_LAUNCHES_PER_TICK);
  const interval = config.interval_seconds === undefined
    ? DEFAULT_INTERVAL_SECONDS
    : positiveInteger(config.interval_seconds, "interval_seconds", 3600);
  const maxOpen = targetRunning + terminalBuffer;
  if (!Number.isSafeInteger(maxOpen) || maxOpen < targetRunning) {
    fail("max_open cannot be determined safely", "CAP_INDETERMINATE");
  }
  return {
    targetRunning,
    terminalBuffer,
    maxOpen,
    maxLaunches,
    interval,
  };
}

function pidIdentity(pid) {
  if (process.platform === "linux") {
    try {
      const statLine = readFileSync(`/proc/${pid}/stat`, "utf8");
      const close = statLine.lastIndexOf(")");
      const fields = statLine.slice(close + 1).trim().split(/\s+/);
      const starttime = fields[19];
      const command = readFileSync(`/proc/${pid}/cmdline`).toString("hex");
      if (!/^[0-9]+$/.test(starttime) || command === "") {
        return null;
      }
      return `linux-starttime=${starttime} cmdline-hex=${command}`;
    } catch {
      return null;
    }
  }
  const result = spawnSync("ps", ["-p", String(pid), "-o", "lstart=", "-o", "command="], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
  });
  return result.status === 0 && result.stdout.trim() !== "" ? result.stdout.trim() : null;
}

function fileAgeSeconds(path) {
  try {
    return Math.max(0, Math.floor(Date.now() / 1000) - Math.floor(statSync(path).mtimeMs / 1000));
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function assertRuntimeOwnership(context, grace) {
  const sessionRaw = safeRead(join(context.state, ".lock"), "firstmate session lock", 64).toString("utf8").trim();
  if (!/^[0-9]+$/.test(sessionRaw) || !isAliveHarness(Number(sessionRaw))) {
    fail("the exact home has no live owning firstmate session", "OWNERSHIP_CHANGED");
  }
  const watchLock = join(context.state, ".watch.lock");
  const watcherRaw = safeRead(join(watchLock, "pid"), "watcher lock pid", 64).toString("utf8").trim();
  if (!/^[0-9]+$/.test(watcherRaw)) {
    fail("watcher lock has no valid owner", "SUPERVISION_UNHEALTHY");
  }
  const watcherPid = Number(watcherRaw);
  const expectedHome = safeRead(join(watchLock, "fm-home"), "watcher home binding", 4096).toString("utf8").trim();
  const expectedPath = safeRead(join(watchLock, "watcher-path"), "watcher path binding", 4096).toString("utf8").trim();
  const recordedIdentity = safeRead(join(watchLock, "pid-identity"), "watcher identity", 65536).toString("utf8").trim();
  const currentIdentity = pidIdentity(watcherPid);
  if (expectedHome !== context.home
    || expectedPath !== join(context.root, "bin", "fm-watch.sh")
    || currentIdentity === null
    || recordedIdentity !== currentIdentity
    || fileAgeSeconds(join(context.state, ".last-watcher-beat")) >= grace) {
    fail("the exact home's supervision loop is not healthy", "SUPERVISION_UNHEALTHY");
  }
}

/**
 * Report-only claim journals that outlived their pass. A process killed between
 * the atomic claim and the compensating reopen leaves the task in_flight with no
 * worker metadata, which is exactly what invalidates the main inventory, so the
 * journal names the ids to reconcile.
 */
function strandedClaimIds(context) {
  try {
    return readdirSync(join(context.state, "auto-dispatch-claims"))
      .filter((name) => name.endsWith(".json"))
      .map((name) => name.slice(0, -".json".length))
      .sort();
  } catch {
    return [];
  }
}

function snapshot(context) {
  const output = run(join(context.root, "bin", "fm-fleet-snapshot.sh"), ["--json"], context);
  const value = parseJson(output, "fleet snapshot");
  if (value?.schema !== "fm-fleet-snapshot.v1" || !Array.isArray(value?.tasks)) {
    fail("fleet snapshot does not match the fm-fleet-snapshot.v1 contract", "FLEET_INVALID");
  }
  if (value.fm_home !== context.home) {
    fail(`fleet snapshot reports home ${String(value.fm_home)} instead of ${context.home}`, "FLEET_INVALID");
  }
  if (value.main_inventory?.valid !== true) {
    const raw = value.main_inventory?.reason;
    const reason = typeof raw === "string" && raw.trim() !== ""
      ? raw.trim()
      : "fm-fleet-snapshot.sh reported no reason";
    const stranded = strandedClaimIds(context);
    const recovery = stranded.length > 0
      ? `; state/auto-dispatch-claims still holds a report-only claim journal for ${stranded.join(", ")}, so reopen those task ids and remove each journal file`
      : "";
    fail(`fleet main inventory is invalid: ${reason}${recovery}`, "FLEET_INVALID");
  }
  return value;
}

function fleetCapacity(snapshotValue, config) {
  const ordinary = snapshotValue.tasks.filter((task) => task?.kind !== "secondmate");
  let running = 0;
  for (const task of ordinary) {
    const id = validateId(task?.id);
    const state = task?.current_state?.state;
    if (typeof state !== "string" || state === "unknown") {
      fail(`fleet state for ${id} is unknown`, "FLEET_INVALID");
    }
    if (task?.hints?.pending_decision === true
      || task?.hints?.blocked_event === true
      || ["blocked", "parked", "failed"].includes(state)) {
      fail(`fleet task ${id} requires supervision before refill`, "FLEET_BLOCKED");
    }
    if (task?.endpoint?.exists === false && state !== "done") {
      fail(`fleet task ${id} has an unexpectedly dead endpoint`, "FLEET_INVALID");
    }
    if (state === "working") {
      running += 1;
    }
  }
  const open = ordinary.length;
  if (!Number.isSafeInteger(open) || !Number.isSafeInteger(running)) {
    fail("fleet capacity cannot be determined safely", "CAP_INDETERMINATE");
  }
  if (open > config.maxOpen) {
    fail(`open worker count ${open} exceeds hard cap ${config.maxOpen}`, "CAP_EXCEEDED");
  }
  return { running, open };
}

/**
 * Failure notices dedup per episode, not forever: a repeat inside one unbroken
 * run of failing passes is suppressed, a pass that stops reporting a condition
 * clears it, and a later recurrence reports again. The active key set is one
 * bounded file, so marker storage cannot grow without bound.
 */
function episodePath(context) {
  return join(context.state, ".auto-dispatch-episode.json");
}

function beginNoticeEpisode(context) {
  let active = [];
  try {
    const value = JSON.parse(readFileSync(episodePath(context), "utf8"));
    active = Array.isArray(value?.active) ? value.active.filter((key) => typeof key === "string") : [];
  } catch {
    active = [];
  }
  context.previousEpisode = new Set(active);
  context.currentEpisode = new Set();
}

function endNoticeEpisode(context) {
  if (context.currentEpisode === undefined) {
    return;
  }
  const active = [...context.currentEpisode].slice(-MAX_EPISODE_KEYS);
  if (active.length === 0) {
    rmSync(episodePath(context), { force: true });
    return;
  }
  atomicWrite(
    episodePath(context),
    `${JSON.stringify({ schema: "fm-auto-dispatch-episode.v1", active }, null, 2)}\n`,
    0o600,
  );
}

function appendNotice(context, state, message) {
  const key = createHash("sha256").update(`${state}\0${message}`).digest("hex");
  // A would-dispatch report is a one-time event guarded by its own receipt, so
  // only failure notices participate in episode dedup.
  if (state !== "done") {
    context.currentEpisode?.add(key);
    if (context.previousEpisode?.has(key)) {
      return false;
    }
  }
  mkdirSync(context.state, { recursive: true, mode: 0o700 });
  writeFileSync(join(context.state, "auto-dispatch.status"), `${state}: ${message}\n`, { flag: "a", mode: 0o600 });
  return true;
}

/**
 * A fleet already at supervision capacity is a routine steady state the watcher
 * surfaces on its own, so it is recorded with a non-captain-actionable verb
 * instead of waking firstmate once per blocked task id.
 */
function reportFailure(context, error) {
  if (!(error instanceof DispatchError)) {
    return;
  }
  if (error.code === "FLEET_BLOCKED") {
    appendNotice(context, "working", `auto-dispatch is waiting on supervision capacity: ${error.message}`);
    return;
  }
  appendNotice(context, "blocked", `auto-dispatch stopped: ${error.message}`);
}

function due(context, interval, force) {
  if (force) {
    return true;
  }
  return fileAgeSeconds(join(context.state, ".last-auto-dispatch-refill")) >= interval;
}

function markRun(context) {
  atomicWrite(join(context.state, ".last-auto-dispatch-refill"), `${new Date().toISOString()}\n`, 0o600);
}

function once(args) {
  const context = resolveContext();
  const { options, positionals } = parseOptions(args, [], ["--force"]);
  if (positionals.length !== 0) {
    fail("usage: fm-auto-dispatch-once.sh [--force]");
  }
  beginNoticeEpisode(context);
  let config;
  try {
    config = readAutoDispatchConfig(context);
  } catch (error) {
    reportFailure(context, error);
    endNoticeEpisode(context);
    throw error;
  }
  if (config === null || !due(context, config.interval, options.force === true)) {
    return;
  }
  // Mark the attempt before the gate checks. A home whose ownership, fleet, or
  // capacity state keeps failing must back off to interval_seconds rather than
  // re-running the expensive fleet snapshot on every watcher poll.
  markRun(context);
  try {
    assertRuntimeOwnership(context, DEFAULT_SUPERVISION_GRACE_SECONDS);
    const snapshotValue = snapshot(context);
    const capacity = fleetCapacity(snapshotValue, config);
    const available = Math.min(
      config.targetRunning - capacity.running,
      config.maxOpen - capacity.open,
      config.maxLaunches,
    );
    if (available <= 0) {
      return;
    }
    const tasks = readyTasks(context);
    let reported = 0;
    for (const task of tasks) {
      if (reported >= available) {
        break;
      }
      const id = task.id;
      // Ordinary queue-level ineligibility belongs to this one candidate.
      // Skipping it keeps an unrelated held or public-followup item from
      // aborting refill for every other staged task in the home.
      if (readyTaskIneligibility(task) !== null) {
        continue;
      }
      const manifestPath = join(context.data, id, "dispatch.json");
      const receiptPath = join(context.state, "auto-dispatch-receipts", `${id}.json`);
      if (!existsSync(manifestPath) || existsSync(receiptPath) || existsSync(join(context.state, `${id}.meta`))) {
        continue;
      }
      let manifest;
      try {
        manifest = verifyManifest(context, task, manifestPath);
      } catch (error) {
        if (error instanceof DispatchError) {
          // Staleness is the expected restaging signal, but a broken seal is a
          // tamper or key-loss finding that nobody learns about unless it is
          // reported before the candidate is skipped.
          if (error.code === "SEAL_INVALID") {
            appendNotice(
              context,
              "blocked",
              `auto-dispatch refused the dispatch envelope for ${id}: ${error.message}`,
            );
          }
          continue;
        }
        throw error;
      }
      const claimedTask = claimTask(context, id);
      if (claimedTask === null) {
        continue;
      }
      const claimJournal = join(context.state, "auto-dispatch-claims", `${id}.json`);
      atomicWrite(claimJournal, `${JSON.stringify({
        schema: "fm-dispatch-claim.v1",
        id,
        task_fingerprint: taskFingerprint(claimedTask),
        claimed_at: new Date().toISOString(),
      }, null, 2)}\n`);
      try {
        if (taskFingerprint(claimedTask) !== manifest.task_fingerprint) {
          fail(`task ${id} changed during its atomic claim`, "ENVELOPE_STALE");
        }
        verifyManifest(context, { ...claimedTask, state: "queued" }, manifestPath);
        if (existsSync(join(context.state, `${id}.meta`))) {
          fail(`task ${id} acquired worker metadata during report-only claim`, "FLEET_INVALID");
        }
      } catch (error) {
        reopenTask(context, id);
        rmSync(claimJournal, { force: true });
        throw error;
      }
      reopenTask(context, id);
      rmSync(claimJournal, { force: true });
      mkdirSync(dirname(receiptPath), { recursive: true, mode: 0o700 });
      const consumedManifest = join(dirname(receiptPath), `${id}.dispatch.json`);
      renameSync(manifestPath, consumedManifest);
      atomicWrite(receiptPath, `${JSON.stringify({
        schema: "fm-auto-dispatch-report.v1",
        id,
        home: context.home,
        reported_at: new Date().toISOString(),
        launch_profile: manifest.launch_profile,
        envelope: consumedManifest,
        outcome: "would-dispatch",
      }, null, 2)}\n`);
      appendNotice(
        context,
        "done",
        `auto-dispatch would dispatch ${id} with ${manifest.launch_profile.harness}; no worker was spawned`,
      );
      process.stdout.write(`${JSON.stringify({
        ok: true,
        action: "would-dispatch",
        id,
        launch_profile: manifest.launch_profile,
      })}\n`);
      reported += 1;
    }
  } catch (error) {
    reportFailure(context, error);
    throw error;
  } finally {
    endNoticeEpisode(context);
  }
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === "stage") {
    stage(args);
    return;
  }
  if (command === "once") {
    once(args);
    return;
  }
  fail("internal usage: fm-auto-dispatch.mjs <stage|once> ...");
}

try {
  main();
} catch (error) {
  if (error instanceof DispatchError) {
    process.stderr.write(`auto-dispatch: ${error.message}\n`);
    process.exitCode = 1;
  } else {
    throw error;
  }
}
