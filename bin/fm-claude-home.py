#!/usr/bin/env python3
"""Manage a firstmate-owned private Claude home for one ship or scout task.

The callers are fm-spawn.sh (create, abort cleanup), fm-teardown.sh
(teardown removal), and fm-claude-crew-lib.sh's readiness probe.
It creates a mode-0700 directory below data/claude-crewmate.
It copies the captain-populated persistent profile at
data/claude-crewmate/profile, skipping any customization-surface entries
(settings, hooks, MCP config, plugins, skills, commands, agents) and
stripping every mcpServers section (user scope and per-project) from the
copied .claude.json so the task-private copy carries completed
onboarding and nothing else.
No credential file is ever copied: an entry named .credentials.json, or
anything derived from that name, is skipped at every depth of the tree,
so the only credential transfer surface is the Keychain.
The macOS Keychain is therefore a hard requirement rather than a
platform branch. Any other host refuses with the missing requirement
named, because degrading to a credential file on disk is exactly the
exposure this helper exists to remove.
It clones only the managed profile's per-config-dir Keychain credential
into the new home's derived Keychain service, and removes that service
entry on abort cleanup and teardown, even when the home directory itself
is already gone.
Both the clone and the removal disable Keychain authentication UI and
are confirmed by reading the target entry back, so an empty, truncated,
or leftover credential, or an item that would need interactive
authorization, fails instead of producing a home that cannot
authenticate or an unattended task that waits on a prompt.
Nothing here reads a runtime flag, environment variable, or argument
that could select a fake, relax a check, or reach a disk fallback; a
test injects its fakes into an imported module instead.
It never reads or copies anything from the captain's own ~/.claude or
CLAUDE_CONFIG_DIR - the persistent profile is populated only by the
captain's explicit provisioning flow in docs/configuration.md.
It removes only a validated managed home during abort cleanup or teardown.
Secondmate Claude launches do not use this helper.
"""

import argparse
import ctypes
import hashlib
import json
import os
import platform
import pwd
import secrets
import stat
import sys

# Profile entries that carry customization surface (global MCP servers,
# plugins, skills, hooks, commands, agents) rather than auth. Excluded from
# every task-private copy so a crew launch can never inherit them, even if
# the persistent profile is someday touched by more than a bare login.
EXCLUDED_ENTRIES = {
    ".firstmate-account.json",
    "settings.json",
    "settings.local.json",
    ".mcp.json",
    "CLAUDE.md",
    "commands",
    "agents",
    "hooks",
    "plugins",
    "skills",
}

# Claude Code's own credential file and anything it derives from that name.
# Never copied at any depth: the Keychain is the only credential surface, so a
# task home that cannot get its credential there must fail rather than fall
# back to plaintext on disk.
CREDENTIAL_ENTRY_PREFIX = ".credentials.json"


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_macos():
    if platform.system() != "Darwin":
        die(
            "isolated Claude homes require the macOS Keychain; this host has no "
            "supported credential store and firstmate will not write Claude "
            "credentials to disk"
        )


def keychain_service(home, legacy=False):
    digest = hashlib.sha256(os.path.realpath(home).encode()).hexdigest()[:8]
    prefix = "Claude Code" if legacy else "Claude Code-credentials"
    return f"{prefix}-{digest}"


def keychain_operation_failed(operation, service, status, detail=None):
    message = (
        f"Keychain {operation} failed for service {service} with OSStatus {status}"
    )
    if status == MacOSKeychain.INTERACTION_NOT_ALLOWED:
        detail = (
            "interactive authorization is disabled; run the documented "
            "profile provisioning flow"
        )
    if detail:
        message += f": {detail}"
    die(message)


class MacOSKeychain:
    """Minimal generic-password access through Security.framework.

    Credential bytes stay in this process. They are never encoded as text or
    passed through a child process's argv, environment, stdin, or output.
    Every lookup, creation, and removal disables authentication UI, so
    an operation that would need authorization fails the unattended task
    instead of raising a Keychain prompt or blocking on one.
    """

    SUCCESS = 0
    ITEM_NOT_FOUND = -25300
    INTERACTION_NOT_ALLOWED = -25308
    UTF8 = 0x08000100

    def __init__(self):
        self.security = ctypes.CDLL(
            "/System/Library/Frameworks/Security.framework/Security"
        )
        self.core = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        self.security.SecItemCopyMatching.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self.security.SecItemCopyMatching.restype = ctypes.c_int32
        self.security.SecItemAdd.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self.security.SecItemAdd.restype = ctypes.c_int32
        self.security.SecItemDelete.argtypes = [ctypes.c_void_p]
        self.security.SecItemDelete.restype = ctypes.c_int32
        self.core.CFDictionaryCreateMutable.argtypes = [
            ctypes.c_void_p,
            ctypes.c_long,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self.core.CFDictionaryCreateMutable.restype = ctypes.c_void_p
        self.core.CFDictionarySetValue.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self.core.CFStringCreateWithCString.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_uint32,
        ]
        self.core.CFStringCreateWithCString.restype = ctypes.c_void_p
        self.core.CFDataCreate.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_ubyte),
            ctypes.c_long,
        ]
        self.core.CFDataCreate.restype = ctypes.c_void_p
        self.core.CFDataGetLength.argtypes = [ctypes.c_void_p]
        self.core.CFDataGetLength.restype = ctypes.c_long
        self.core.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
        self.core.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_ubyte)
        self.core.CFRelease.argtypes = [ctypes.c_void_p]
        self.constants = {
            name: ctypes.c_void_p.in_dll(self.security, name).value
            for name in (
                "kSecClass",
                "kSecClassGenericPassword",
                "kSecAttrAccount",
                "kSecAttrService",
                "kSecReturnData",
                "kSecMatchLimit",
                "kSecMatchLimitOne",
                "kSecValueData",
                "kSecUseAuthenticationUI",
                "kSecUseAuthenticationUIFail",
            )
        }
        self.true = ctypes.c_void_p.in_dll(self.core, "kCFBooleanTrue").value

    def release(self, value):
        if value:
            self.core.CFRelease(value)

    def string(self, value):
        result = self.core.CFStringCreateWithCString(None, value.encode(), self.UTF8)
        if not result:
            die("could not encode isolated Claude Keychain attributes")
        return result

    def data(self, value):
        if not value:
            die("managed Claude Keychain credential is empty")
        buffer = (ctypes.c_ubyte * len(value)).from_buffer_copy(value)
        result = self.core.CFDataCreate(None, buffer, len(value))
        if not result:
            die("could not prepare isolated Claude Keychain credential")
        return result

    def dictionary(self, values):
        result = self.core.CFDictionaryCreateMutable(None, 0, None, None)
        if not result:
            die("could not prepare isolated Claude Keychain request")
        for key, value in values:
            self.core.CFDictionarySetValue(result, key, value)
        return result

    def attributes(self, service, include_data=False):
        account = self.string(pwd.getpwuid(os.getuid()).pw_name)
        service_value = self.string(service)
        values = [
            (self.constants["kSecClass"], self.constants["kSecClassGenericPassword"]),
            (self.constants["kSecAttrAccount"], account),
            (self.constants["kSecAttrService"], service_value),
            (
                self.constants["kSecUseAuthenticationUI"],
                self.constants["kSecUseAuthenticationUIFail"],
            ),
        ]
        if include_data:
            values.extend(
                (
                    (self.constants["kSecReturnData"], self.true),
                    (
                        self.constants["kSecMatchLimit"],
                        self.constants["kSecMatchLimitOne"],
                    ),
                )
            )
        return self.dictionary(values), account, service_value

    def operation_failed(self, operation, service, status, detail=None):
        keychain_operation_failed(operation, service, status, detail)

    def read(self, service):
        query, account, service_value = self.attributes(service, include_data=True)
        result = ctypes.c_void_p()
        try:
            status = self.security.SecItemCopyMatching(query, ctypes.byref(result))
            if status == self.ITEM_NOT_FOUND:
                return None
            if status != self.SUCCESS:
                self.operation_failed("SecItemCopyMatching", service, status)
            if not result.value:
                self.operation_failed(
                    "SecItemCopyMatching",
                    service,
                    status,
                    "no credential data was returned",
                )
            length = self.core.CFDataGetLength(result)
            if length <= 0:
                self.operation_failed(
                    "SecItemCopyMatching",
                    service,
                    status,
                    "the credential is empty",
                )
            pointer = self.core.CFDataGetBytePtr(result)
            if not pointer:
                self.operation_failed(
                    "SecItemCopyMatching",
                    service,
                    status,
                    "the credential data is unreadable",
                )
            return ctypes.string_at(pointer, length)
        finally:
            self.release(result.value)
            self.release(query)
            self.release(account)
            self.release(service_value)

    def write(self, service, value):
        query, account, service_value = self.attributes(service)
        secret = self.data(value)
        try:
            # A target service belongs to a newly created home and must not
            # already exist. Updating or accepting a duplicate would claim a
            # credential this creation attempt did not create.
            self.core.CFDictionarySetValue(
                query, self.constants["kSecValueData"], secret
            )
            status = self.security.SecItemAdd(query, None)
            if status != self.SUCCESS:
                self.operation_failed("SecItemAdd", service, status)
        finally:
            self.release(secret)
            self.release(query)
            self.release(account)
            self.release(service_value)

    def delete(self, service):
        query, account, service_value = self.attributes(service)
        try:
            status = self.security.SecItemDelete(query)
            if status not in (self.SUCCESS, self.ITEM_NOT_FOUND):
                self.operation_failed("SecItemDelete", service, status)
        finally:
            self.release(query)
            self.release(account)
            self.release(service_value)


def macos_keychain():
    try:
        return MacOSKeychain()
    except (AttributeError, OSError, ValueError):
        die("macOS Security.framework is unavailable for isolated Claude auth")


def clone_keychain_credential(data, source, home):
    managed_profile = os.path.join(os.path.realpath(data), "claude-crewmate", "profile")
    if os.path.realpath(source) != managed_profile:
        die("isolated Claude homes require the managed Claude crewmate profile")
    keychain = macos_keychain()
    for legacy in (False, True):
        source_secret = keychain.read(keychain_service(source, legacy))
        if source_secret is None:
            continue
        target_service = keychain_service(home)
        keychain.write(target_service, source_secret)
        try:
            target_secret = keychain.read(target_service)
            if target_secret is None:
                keychain_operation_failed(
                    "SecItemCopyMatching",
                    target_service,
                    MacOSKeychain.ITEM_NOT_FOUND,
                    "the newly created credential was not found during verification",
                )
            if target_secret != source_secret:
                die("isolated Claude Keychain credential did not match its source")
        except BaseException:
            try:
                keychain.delete(target_service)
                if keychain.read(target_service) is not None:
                    die("could not verify isolated Claude Keychain credential removal")
            except (OSError, SystemExit):
                pass
            raise
        return target_service
    die(
        "managed Claude profile has no path-bound Keychain credential; "
        "run the documented profile provisioning flow"
    )


def remove_keychain_credential(home):
    service = keychain_service(home)
    keychain = macos_keychain()
    keychain.delete(service)
    if keychain.read(service) is not None:
        die("could not verify isolated Claude Keychain credential removal")


def open_directory(name, directory_fd=None):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    return os.open(name, flags, dir_fd=directory_fd)


def require_directory(fd, label):
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        die(f"{label} must be a directory")


def directory_path(fd, fallback):
    try:
        import fcntl

        getpath = getattr(fcntl, "F_GETPATH", None)
        if getpath is not None:
            path = fcntl.fcntl(fd, getpath, bytes(1024)).split(b"\0", 1)[0]
            if path:
                return os.fsdecode(path)
    except (AttributeError, OSError):
        pass
    for directory in ("/proc/self/fd", "/dev/fd"):
        try:
            path = os.readlink(os.path.join(directory, str(fd)))
            if os.path.isabs(path):
                return path
        except OSError:
            pass
    return fallback


def write_all(fd, content):
    while content:
        written = os.write(fd, content)
        content = content[written:]


def write_file(directory_fd, name, content, mode=0o600):
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        mode,
        dir_fd=directory_fd,
    )
    try:
        write_all(fd, content)
        os.fchmod(fd, mode)
    finally:
        os.close(fd)


def remove_mcp_servers(value):
    if isinstance(value, dict):
        value.pop("mcpServers", None)
        for child in value.values():
            remove_mcp_servers(child)
    elif isinstance(value, list):
        for child in value:
            remove_mcp_servers(child)


def sanitized_claude_json(content):
    try:
        config = json.loads(content.decode())
    except (UnicodeDecodeError, ValueError):
        config = None
    if not isinstance(config, dict):
        die("Claude profile .claude.json is not a JSON object")
    remove_mcp_servers(config)
    return (json.dumps(config, separators=(",", ":")) + "\n").encode()


def read_regular_file(source_dir_fd, name):
    source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_dir_fd)
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            die(f"Claude profile source entry is not regular: {name}")
        chunks = []
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(source_fd)


def copy_regular_file(source_dir_fd, name, target_dir_fd):
    source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_dir_fd)
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            die(f"Claude profile source entry is not regular: {name}")
        target_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=target_dir_fd,
        )
        try:
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                write_all(target_fd, chunk)
            os.fchmod(target_fd, 0o600)
        finally:
            os.close(target_fd)
    finally:
        os.close(source_fd)


def copy_tree(source_dir_fd, target_dir_fd, top_level):
    for entry in os.listdir(source_dir_fd):
        if entry.startswith(CREDENTIAL_ENTRY_PREFIX):
            continue
        if top_level and entry in EXCLUDED_ENTRIES:
            continue
        entry_stat = os.stat(entry, dir_fd=source_dir_fd, follow_symlinks=False)
        if stat.S_ISDIR(entry_stat.st_mode):
            os.mkdir(entry, 0o700, dir_fd=target_dir_fd)
            child_source_fd = open_directory(entry, source_dir_fd)
            try:
                child_target_fd = open_directory(entry, target_dir_fd)
                try:
                    copy_tree(child_source_fd, child_target_fd, top_level=False)
                finally:
                    os.close(child_target_fd)
            finally:
                os.close(child_source_fd)
        elif stat.S_ISREG(entry_stat.st_mode):
            if top_level and entry == ".claude.json":
                write_file(
                    target_dir_fd,
                    entry,
                    sanitized_claude_json(read_regular_file(source_dir_fd, entry)),
                )
            else:
                copy_regular_file(source_dir_fd, entry, target_dir_fd)
        else:
            die(f"Claude profile source entry is not a file or directory: {entry}")


def remove_tree(directory_fd, name, expected_identity=None):
    try:
        child_fd = open_directory(name, directory_fd)
    except FileNotFoundError:
        return
    try:
        opened_stat = os.fstat(child_fd)
        opened_identity = (opened_stat.st_dev, opened_stat.st_ino)
        if expected_identity is not None and opened_identity != expected_identity:
            raise OSError("validated managed Claude home changed before removal")
        for child in os.listdir(child_fd):
            child_stat = os.stat(child, dir_fd=child_fd, follow_symlinks=False)
            if stat.S_ISDIR(child_stat.st_mode):
                remove_tree(child_fd, child)
            else:
                os.unlink(child, dir_fd=child_fd)
    finally:
        os.close(child_fd)
    current_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (current_stat.st_dev, current_stat.st_ino) != opened_identity:
        raise OSError("managed Claude home changed during removal")
    os.rmdir(name, dir_fd=directory_fd)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data")
    parser.add_argument("--state")
    parser.add_argument("--source")
    parser.add_argument("--task-id")
    parser.add_argument("--home")
    parser.add_argument("--create", action="store_true")
    parser.add_argument("--remove", action="store_true")
    return parser.parse_args()


TASK_ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"


def require_safe_task_id(task_id):
    if not task_id or any(char not in TASK_ID_CHARS for char in task_id):
        die("isolated Claude home requires a safe task id")
    return task_id


def managed_home_name(home):
    name = os.path.basename(home or "")
    if not name.startswith(".fm-claude-home.") or len(name) <= len(".fm-claude-home."):
        die("isolated Claude home name is unsafe")
    return name


def ownership_marker_name(task_id):
    return ".fm-claude-crew-home." + task_id


def base_directory(data):
    if not data:
        die("isolated Claude home requires --data")
    data_fd = open_directory(os.path.abspath(data))
    try:
        require_directory(data_fd, "firstmate data")
        try:
            os.mkdir("claude-crewmate", 0o700, dir_fd=data_fd)
        except FileExistsError:
            pass
        base_fd = open_directory("claude-crewmate", data_fd)
        require_directory(base_fd, "isolated Claude home")
        os.fchmod(base_fd, 0o700)
        return base_fd
    finally:
        os.close(data_fd)


def open_base_directory_if_present(data):
    data_fd = open_directory(os.path.abspath(data))
    try:
        require_directory(data_fd, "firstmate data")
        try:
            return open_directory("claude-crewmate", data_fd)
        except FileNotFoundError:
            return None
    finally:
        os.close(data_fd)


def create_home(args):
    task_id = require_safe_task_id(args.task_id)
    if not args.source:
        die("Claude home creation requires --source")
    try:
        source_fd = open_directory(os.path.abspath(args.source))
    except OSError as error:
        die(f"could not open Claude crewmate profile: {error.strerror}")
    try:
        require_directory(source_fd, "Claude crewmate profile")
        try:
            base_fd = base_directory(args.data)
        except OSError as error:
            die(f"could not prepare isolated Claude home: {error.strerror}")
        try:
            home_created = False
            credential_service = None
            name = None
            home_path = None
            try:
                while True:
                    name = ".fm-claude-home." + secrets.token_hex(16)
                    try:
                        os.mkdir(name, 0o700, dir_fd=base_fd)
                        home_created = True
                        home_path = os.path.join(
                            directory_path(
                                base_fd,
                                os.path.join(
                                    os.path.abspath(args.data), "claude-crewmate"
                                ),
                            ),
                            name,
                        )
                        break
                    except FileExistsError:
                        continue
                home_fd = open_directory(name, base_fd)
                try:
                    require_directory(home_fd, "isolated Claude home")
                    os.fchmod(home_fd, 0o700)
                    copy_tree(source_fd, home_fd, top_level=True)
                    credential_service = clone_keychain_credential(
                        args.data, args.source, home_path
                    )
                    write_file(home_fd, ownership_marker_name(task_id), b"")
                finally:
                    os.close(home_fd)
                print(home_path)
            except BaseException:
                if home_created:
                    try:
                        if (
                            credential_service is not None
                            and home_path is not None
                        ):
                            remove_keychain_credential(home_path)
                    except (OSError, SystemExit):
                        pass
                    try:
                        remove_tree(base_fd, name)
                    except OSError:
                        pass
                raise
        finally:
            os.close(base_fd)
    except OSError as error:
        die(f"could not prepare isolated Claude home: {error.strerror}")
    finally:
        os.close(source_fd)


def require_unreferenced_home(state, task_id, expected):
    try:
        state_fd = open_directory(os.path.abspath(state))
    except OSError as error:
        die(
            "could not inspect task metadata before isolated Claude home removal: "
            f"{error.strerror}"
        )
    try:
        require_directory(state_fd, "firstmate state")
        for entry in os.scandir(state_fd):
            if entry.name == f"{task_id}.meta" or not entry.name.endswith(".meta"):
                continue
            try:
                meta_fd = os.open(
                    entry.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=state_fd
                )
            except OSError as error:
                die(
                    "could not inspect task metadata before isolated Claude home removal: "
                    f"{error.strerror}"
                )
            try:
                meta_stat = os.fstat(meta_fd)
                if not stat.S_ISREG(meta_stat.st_mode):
                    die("task metadata is unsafe before isolated Claude home removal")
                content = os.read(meta_fd, 1024 * 1024 + 1)
                if len(content) > 1024 * 1024:
                    die("task metadata is unsafe before isolated Claude home removal")
            finally:
                os.close(meta_fd)
            try:
                lines = content.decode().splitlines()
            except UnicodeDecodeError:
                die("task metadata is unsafe before isolated Claude home removal")
            for line in lines:
                if (
                    line.startswith("claude_crewmate_home=")
                    and os.path.realpath(line.partition("=")[2]) == expected
                ):
                    die("isolated Claude home is referenced by another active task")
    finally:
        os.close(state_fd)


def remove_home(args):
    if not args.home:
        die("Claude home removal requires --home")
    if not args.data or not args.state:
        die("Claude home removal requires --data and --state")
    task_id = require_safe_task_id(args.task_id)
    name = managed_home_name(args.home)
    try:
        base_fd = open_base_directory_if_present(args.data)
    except OSError as error:
        die(f"could not prepare isolated Claude home removal: {error.strerror}")
    if base_fd is None:
        expected = os.path.realpath(
            os.path.join(
                os.path.abspath(args.data),
                "claude-crewmate",
                name,
            )
        )
        if os.path.realpath(args.home) != expected:
            die("isolated Claude home path is unsafe")
        remove_keychain_credential(expected)
        return
    try:
        require_directory(base_fd, "isolated Claude home")
        base = directory_path(
            base_fd, os.path.join(os.path.abspath(args.data), "claude-crewmate")
        )
        expected = os.path.join(base, name)
        if os.path.realpath(args.home) != expected:
            die("isolated Claude home path is unsafe")
        require_unreferenced_home(args.state, task_id, expected)
        try:
            home_fd = open_directory(name, base_fd)
        except FileNotFoundError:
            remove_keychain_credential(expected)
            return
        try:
            try:
                marker_fd = os.open(
                    ownership_marker_name(task_id),
                    os.O_RDONLY | os.O_NOFOLLOW,
                    dir_fd=home_fd,
                )
            except OSError as error:
                die(
                    f"isolated Claude home does not belong to task {task_id}: "
                    f"{error.strerror}"
                )
            try:
                if not stat.S_ISREG(os.fstat(marker_fd).st_mode):
                    die(f"isolated Claude home does not belong to task {task_id}")
            finally:
                os.close(marker_fd)
            home_stat = os.fstat(home_fd)
            expected_identity = (home_stat.st_dev, home_stat.st_ino)
        finally:
            os.close(home_fd)
        remove_keychain_credential(expected)
        remove_tree(base_fd, name, expected_identity)
    except FileNotFoundError:
        pass
    except OSError as error:
        die(f"could not remove isolated Claude home: {error.strerror or str(error)}")
    finally:
        os.close(base_fd)


def main():
    args = parse_args()
    require_macos()
    if args.create and args.remove:
        die("Claude home management accepts exactly one action")
    if args.create:
        create_home(args)
        return
    if args.remove:
        remove_home(args)
        return
    die("Claude home management requires --create or --remove")


if __name__ == "__main__":
    main()
