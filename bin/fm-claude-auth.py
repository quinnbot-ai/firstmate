#!/usr/bin/env python3
"""Attest and enforce the account identity of an isolated Claude crew home.

The profile-local .firstmate-account.json stores only a digest of the intended
Claude.ai email and organization identifier observed during explicit operator
attestation.
Verification runs `claude auth status --json` with the exact config directory
and with ambient authentication and alternate-provider environment variables
removed.
Status output is bounded, parsed in memory, and never relayed.
The login action starts the operator's explicit profile provisioning flow under
that same scrubbed environment.
The exec action repeats verification immediately before replacing itself with
the worker or quota command.
"""

import argparse
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys

MANIFEST = ".firstmate-account.json"
MANIFEST_VERSION = 1
MAX_STATUS_BYTES = 64 * 1024
MAX_MANIFEST_BYTES = 4096
AUTH_TIMEOUT_SECONDS = 15

# Claude authentication may be supplied by any of these ambient variables
# without using the task-private configuration directory.
# Removing the complete alternate-provider surface makes a successful status
# check evidence about the managed home rather than the launching shell.
AMBIENT_AUTH_VARIABLES = {
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_AWS_API_KEY",
    "ANTHROPIC_AWS_BASE_URL",
    "ANTHROPIC_AWS_WORKSPACE_ID",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_BEDROCK_BASE_URL",
    "ANTHROPIC_BEDROCK_MANTLE_BASE_URL",
    "ANTHROPIC_CUSTOM_HEADERS",
    "ANTHROPIC_ENVIRONMENT_KEY",
    "ANTHROPIC_FEDERATION_RULE_ID",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "ANTHROPIC_FOUNDRY_AUTH_TOKEN",
    "ANTHROPIC_FOUNDRY_BASE_URL",
    "ANTHROPIC_FOUNDRY_RESOURCE",
    "ANTHROPIC_GOOGLE_CLOUD_BASE_URL",
    "ANTHROPIC_GOOGLE_CLOUD_WORKSPACE_ID",
    "ANTHROPIC_IDENTITY_TOKEN",
    "ANTHROPIC_IDENTITY_TOKEN_FILE",
    "ANTHROPIC_ORGANIZATION_ID",
    "ANTHROPIC_PROFILE",
    "ANTHROPIC_VERTEX_BASE_URL",
    "ANTHROPIC_VERTEX_PROJECT_ID",
    "ANTHROPIC_WORKSPACE_ID",
    "CCR_OAUTH_TOKEN_FILE",
    "CLAUDE_CODE_API_BASE_URL",
    "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    "CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL",
    "CLAUDE_CODE_CUSTOM_OAUTH_URL",
    "CLAUDE_CODE_ENABLE_PROXY_AUTH_HELPER",
    "CLAUDE_CODE_GB_BASE_URL",
    "CLAUDE_CODE_HFI_BEARER_TOKEN",
    "CLAUDE_CODE_HOST_AUTH_ENV_VAR",
    "CLAUDE_CODE_HOST_CREDS_FILE",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
    "CLAUDE_CODE_ORGANIZATION_UUID",
    "CLAUDE_CODE_PROFILE_QUERY",
    "CLAUDE_CODE_PROFILE_STARTUP",
    "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST",
    "CLAUDE_CODE_PROXY_AUTHENTICATE",
    "CLAUDE_CODE_PROXY_HOST",
    "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH",
    "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH",
    "CLAUDE_CODE_SESSION_ACCESS_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_GATEWAY",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR",
}


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def open_directory(path, label):
    try:
        fd = os.open(
            os.path.abspath(path),
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        )
    except OSError:
        die(f"{label} is unavailable or unsafe")
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        die(f"{label} is unavailable or unsafe")
    return fd


def scrubbed_environment(home):
    environment = os.environ.copy()
    for name in AMBIENT_AUTH_VARIABLES:
        environment.pop(name, None)
    environment["CLAUDE_CONFIG_DIR"] = os.path.realpath(home)
    return environment


def claude_cli():
    return os.environ.get("FM_CLAUDE_CREW_CLI", "claude")


def account_digest(status):
    if not isinstance(status, dict):
        return None
    if (
        status.get("loggedIn") is not True
        or status.get("authMethod") != "claude.ai"
        or status.get("apiProvider") != "firstParty"
    ):
        return None
    email = status.get("email")
    organization = status.get("orgId")
    if (
        not isinstance(email, str)
        or not email.strip()
        or not isinstance(organization, str)
        or not organization.strip()
    ):
        return None
    identity = json.dumps(
        {"email": email, "orgId": organization},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(identity).hexdigest()


def authenticated_account(home, worktree):
    environment = scrubbed_environment(home)
    try:
        result = subprocess.run(
            [claude_cli(), "auth", "status", "--json"],
            cwd=os.path.realpath(worktree),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=AUTH_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        die("Claude account identity could not be attested")
    if (
        result.returncode != 0
        or len(result.stdout) > MAX_STATUS_BYTES
        or len(result.stderr) > MAX_STATUS_BYTES
    ):
        die("Claude account identity could not be attested")
    try:
        status = json.loads(result.stdout.decode())
    except (UnicodeDecodeError, ValueError):
        die("Claude account identity could not be attested")
    digest = account_digest(status)
    if digest is None:
        die("Claude account identity could not be attested")
    return digest


def read_manifest(profile):
    profile_fd = open_directory(profile, "Claude crewmate profile")
    try:
        try:
            fd = os.open(
                MANIFEST,
                os.O_RDONLY | os.O_NOFOLLOW,
                dir_fd=profile_fd,
            )
        except OSError:
            die("Claude crewmate profile has no usable account attestation")
        try:
            metadata = os.fstat(fd)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_mode & 0o077
                or metadata.st_size > MAX_MANIFEST_BYTES
            ):
                die("Claude crewmate profile account attestation is unsafe")
            content = os.read(fd, MAX_MANIFEST_BYTES + 1)
        finally:
            os.close(fd)
    finally:
        os.close(profile_fd)
    try:
        manifest = json.loads(content.decode())
    except (UnicodeDecodeError, ValueError):
        die("Claude crewmate profile account attestation is invalid")
    if (
        not isinstance(manifest, dict)
        or manifest.get("version") != MANIFEST_VERSION
        or set(manifest) != {"version", "account_sha256"}
        or not isinstance(manifest.get("account_sha256"), str)
        or len(manifest["account_sha256"]) != 64
        or any(
            character not in "0123456789abcdef"
            for character in manifest["account_sha256"]
        )
    ):
        die("Claude crewmate profile account attestation is invalid")
    return manifest["account_sha256"]


def write_manifest(profile, digest):
    profile_fd = open_directory(profile, "Claude crewmate profile")
    temporary = f".firstmate-account.{secrets.token_hex(16)}"
    content = (
        json.dumps(
            {"version": MANIFEST_VERSION, "account_sha256": digest},
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode()
    temporary_fd = None
    try:
        try:
            existing = os.stat(MANIFEST, dir_fd=profile_fd, follow_symlinks=False)
            if not stat.S_ISREG(existing.st_mode):
                die("Claude crewmate profile account attestation is unsafe")
        except FileNotFoundError:
            pass
        temporary_fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=profile_fd,
        )
        offset = 0
        while offset < len(content):
            offset += os.write(temporary_fd, content[offset:])
        os.fchmod(temporary_fd, 0o600)
        os.fsync(temporary_fd)
        os.close(temporary_fd)
        temporary_fd = None
        os.replace(
            temporary,
            MANIFEST,
            src_dir_fd=profile_fd,
            dst_dir_fd=profile_fd,
        )
        os.fsync(profile_fd)
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        try:
            os.unlink(temporary, dir_fd=profile_fd)
        except FileNotFoundError:
            pass
        os.close(profile_fd)


def verify(profile, home, worktree):
    expected = read_manifest(profile)
    if authenticated_account(profile, worktree) != expected:
        die("Claude crewmate profile resolved to a different account")
    if os.path.realpath(home) != os.path.realpath(profile):
        if authenticated_account(home, worktree) != expected:
            die("task-private Claude home resolved to a different account")
    return expected


def parse_args():
    parser = argparse.ArgumentParser()
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--login", action="store_true")
    actions.add_argument("--attest", action="store_true")
    actions.add_argument("--verify", action="store_true")
    actions.add_argument("--verify-exec", action="store_true")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--home")
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--replace-attestation", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def main():
    args = parse_args()
    profile = os.path.realpath(args.profile)
    worktree = os.path.realpath(args.worktree)
    worktree_fd = open_directory(worktree, "Claude verification worktree")
    os.close(worktree_fd)
    if args.login:
        profile_fd = open_directory(profile, "Claude crewmate profile")
        os.close(profile_fd)
        if args.home or args.replace_attestation or args.command:
            die("Claude profile login accepts only --profile and --worktree")
        environment = scrubbed_environment(profile)
        login_command = claude_cli()
        environment.pop("FM_CLAUDE_CREW_CLI", None)
        os.chdir(worktree)
        try:
            os.execvpe(
                login_command,
                [login_command, "auth", "login"],
                environment,
            )
        except OSError:
            die("could not start Claude profile login")
    if args.attest:
        digest = authenticated_account(profile, worktree)
        if os.path.lexists(os.path.join(profile, MANIFEST)):
            existing = read_manifest(profile)
            if existing != digest and not args.replace_attestation:
                die(
                    "Claude crewmate profile resolved to a different account; "
                    "refusing to replace its attestation"
                )
        write_manifest(profile, digest)
        print("Claude crewmate account attestation recorded")
        return
    if args.replace_attestation:
        die("--replace-attestation requires --attest")
    if not args.home:
        die("Claude verification requires --home")
    home = os.path.realpath(args.home)
    home_fd = open_directory(home, "task-private Claude home")
    os.close(home_fd)
    verify(profile, home, worktree)
    if args.verify:
        return
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        die("Claude verified exec requires a command")
    environment = scrubbed_environment(home)
    environment.pop("FM_CLAUDE_CREW_CLI", None)
    os.chdir(worktree)
    try:
        os.execvpe(command[0], command, environment)
    except OSError:
        die("could not start the verified Claude command")


if __name__ == "__main__":
    main()
