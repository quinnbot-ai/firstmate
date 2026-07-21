#!/usr/bin/env python3
"""Manage a firstmate-owned private Claude home for one ship or scout task.

fm-spawn.sh is the sole caller.
It creates a mode-0700 directory below data/claude-crewmate.
It copies the captain-populated persistent profile at
data/claude-crewmate/profile, skipping any customization-surface entries
(settings, hooks, MCP config, plugins, skills, commands, agents) so the
task-private copy carries auth and nothing else.
It never reads or copies anything from the captain's own ~/.claude or
CLAUDE_CONFIG_DIR - the persistent profile is populated only by the
captain's own `claude auth login` run against it directly.
It removes only a validated managed home during abort cleanup or teardown.
Secondmate Claude launches do not use this helper.
"""

import argparse
import os
import secrets
import stat
import sys

# Profile entries that carry customization surface (global MCP servers,
# plugins, skills, hooks, commands, agents) rather than auth. Excluded from
# every task-private copy so a crew launch can never inherit them, even if
# the persistent profile is someday touched by more than a bare login.
EXCLUDED_ENTRIES = {
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


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


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
            name = None
            try:
                while True:
                    name = ".fm-claude-home." + secrets.token_hex(16)
                    try:
                        os.mkdir(name, 0o700, dir_fd=base_fd)
                        home_created = True
                        break
                    except FileExistsError:
                        continue
                home_fd = open_directory(name, base_fd)
                try:
                    require_directory(home_fd, "isolated Claude home")
                    os.fchmod(home_fd, 0o700)
                    copy_tree(source_fd, home_fd, top_level=True)
                    write_file(home_fd, ownership_marker_name(task_id), b"")
                finally:
                    os.close(home_fd)
                data_real = directory_path(base_fd, os.path.join(os.path.abspath(args.data), "claude-crewmate"))
                print(os.path.join(data_real, name))
            except BaseException:
                if home_created:
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
                meta_fd = os.open(entry.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=state_fd)
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
                if line.startswith("claude_crewmate_home=") and os.path.realpath(
                    line.partition("=")[2]
                ) == expected:
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
        remove_tree(base_fd, name, expected_identity)
    except FileNotFoundError:
        pass
    except OSError as error:
        die(f"could not remove isolated Claude home: {error.strerror or str(error)}")
    finally:
        os.close(base_fd)


def main():
    args = parse_args()
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
