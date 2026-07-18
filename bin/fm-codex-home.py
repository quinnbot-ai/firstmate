#!/usr/bin/env python3
"""Manage a firstmate-owned private Codex home for one ship or scout task.

fm-spawn.sh is the sole caller.
It creates a mode-0700 directory below data/codex-crewmate.
It copies only the captain's auth.json and models_cache.json.
It writes a no-plugin and no-MCP configuration.
It launches Codex through an open directory descriptor.
It removes only a validated managed home during abort cleanup or teardown.
Secondmate Codex launches do not use this helper.
"""

import argparse
import os
import secrets
import signal
import stat
import sys
import time


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


def write_file(directory_fd, name, content):
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory_fd,
    )
    try:
        write_all(fd, content)
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


def copy_regular_file(source, directory_fd, name):
    try:
        source_fd = os.open(os.path.join(source, name), os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            die(f"Codex source file is not regular: {os.path.join(source, name)}")
        target_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=directory_fd,
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


def remove_tree(directory_fd, name):
    try:
        child_fd = open_directory(name, directory_fd)
    except FileNotFoundError:
        return
    try:
        opened_stat = os.fstat(child_fd)
        for child in os.listdir(child_fd):
            child_stat = os.stat(child, dir_fd=child_fd, follow_symlinks=False)
            if stat.S_ISDIR(child_stat.st_mode):
                remove_tree(child_fd, child)
            else:
                os.unlink(child, dir_fd=child_fd)
    finally:
        os.close(child_fd)
    current_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (current_stat.st_dev, current_stat.st_ino) != (
        opened_stat.st_dev,
        opened_stat.st_ino,
    ):
        raise OSError("managed Codex home changed during removal")
    os.rmdir(name, dir_fd=directory_fd)


def toml_basic_string(value):
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        die("Codex worktree path contains a TOML control character")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data")
    parser.add_argument("--state")
    parser.add_argument("--source")
    parser.add_argument("--profile")
    parser.add_argument("--worktree")
    parser.add_argument("--new-home-name", action="store_true")
    parser.add_argument("--new-result-token", action="store_true")
    parser.add_argument("--create-activate", action="store_true")
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--read-activation-result", action="store_true")
    parser.add_argument("--remove-activation-result", action="store_true")
    parser.add_argument("--home")
    parser.add_argument("--task-id")
    parser.add_argument("--result-token")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def managed_home_name(home):
    name = os.path.basename(home or "")
    if not name.startswith(".fm-codex-home.") or len(name) <= len(".fm-codex-home."):
        die("isolated Codex home name is unsafe")
    return name


def removal_home_path(args, base_fd):
    name = managed_home_name(args.home)
    base = directory_path(
        base_fd, os.path.join(os.path.abspath(args.data), "codex-crewmate")
    )
    expected = os.path.join(base, name)
    if os.path.realpath(args.home) != expected:
        die("isolated Codex home path is unsafe")
    return expected


def require_unreferenced_home(args, expected):
    task_id_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    if not args.task_id or any(
        char not in task_id_chars for char in args.task_id
    ):
        die("isolated Codex home removal requires a safe task id")
    try:
        state_fd = open_directory(os.path.abspath(args.state))
    except OSError as error:
        die(
            "could not inspect task metadata before isolated Codex home removal: "
            f"{error.strerror}"
        )
    try:
        require_directory(state_fd, "firstmate state")
        for entry in os.scandir(state_fd):
            if entry.name == f"{args.task_id}.meta" or not entry.name.endswith(".meta"):
                continue
            try:
                meta_fd = os.open(
                    entry.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=state_fd
                )
            except OSError as error:
                die(
                    "could not inspect task metadata before isolated Codex home removal: "
                    f"{error.strerror}"
                )
            try:
                meta_stat = os.fstat(meta_fd)
                if not stat.S_ISREG(meta_stat.st_mode):
                    die("task metadata is unsafe before isolated Codex home removal")
                content = os.read(meta_fd, 1024 * 1024 + 1)
                if len(content) > 1024 * 1024:
                    die("task metadata is unsafe before isolated Codex home removal")
            finally:
                os.close(meta_fd)
            try:
                lines = content.decode().splitlines()
            except UnicodeDecodeError:
                die("task metadata is unsafe before isolated Codex home removal")
            for line in lines:
                if line.startswith("codex_crewmate_home=") and os.path.realpath(
                    line.partition("=")[2]
                ) == expected:
                    die("isolated Codex home is referenced by another active task")
    finally:
        os.close(state_fd)


def require_task_profile(args, base_fd):
    name = managed_home_name(args.home)
    profile = f"fm-crewmate-{args.task_id}.config.toml"
    try:
        home_fd = open_directory(name, base_fd)
    except FileNotFoundError:
        return False
    try:
        try:
            profile_fd = os.open(
                profile, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=home_fd
            )
        except OSError as error:
            die(
                f"isolated Codex home does not belong to task {args.task_id}: "
                f"{error.strerror}"
            )
        try:
            if not stat.S_ISREG(os.fstat(profile_fd).st_mode):
                die(f"isolated Codex home does not belong to task {args.task_id}")
        finally:
            os.close(profile_fd)
    finally:
        os.close(home_fd)
    return True


def launch_command(args):
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        die("Codex home activation requires a command")
    return command


def result_token(args):
    token = args.result_token or ""
    if len(token) != 64 or any(char not in "0123456789abcdef" for char in token):
        die("isolated Codex home activation token is unsafe")
    return token.encode()


def activation_result_name(args):
    return ".fm-codex-activation." + managed_home_name(args.home)


def activation_result_fd(args, base_fd):
    try:
        fd = os.open(
            activation_result_name(args),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=base_fd,
        )
        os.fchmod(fd, 0o600)
        return fd
    except OSError as error:
        die(f"could not record isolated Codex home activation: {error.strerror}")


def finish_activation_result_with_token(fd, result, token):
    try:
        write_all(fd, result + b" " + token + b"\n")
    finally:
        os.close(fd)


def read_activation_result(args):
    token = result_token(args)
    try:
        data_fd = open_directory(os.path.abspath(args.data))
        try:
            require_directory(data_fd, "firstmate data")
            base_fd = open_directory("codex-crewmate", data_fd)
        finally:
            os.close(data_fd)
        try:
            require_directory(base_fd, "isolated Codex home")
            try:
                fd = os.open(
                    activation_result_name(args),
                    os.O_RDONLY | os.O_NOFOLLOW,
                    dir_fd=base_fd,
                )
            except FileNotFoundError:
                print("pending")
                return 3
        finally:
            os.close(base_fd)
    except FileNotFoundError:
        print("pending")
        return 3
    except OSError as error:
        die(f"isolated Codex home activation result is unsafe: {error.strerror}")
    try:
        file_stat = os.fstat(fd)
        if (
            not stat.S_ISREG(file_stat.st_mode)
            or file_stat.st_uid != os.geteuid()
            or file_stat.st_nlink != 1
            or stat.S_IMODE(file_stat.st_mode) != 0o600
        ):
            die("isolated Codex home activation result is unsafe")
        content = os.read(fd, 256)
        if os.read(fd, 1):
            die("isolated Codex home activation result is unsafe")
    finally:
        os.close(fd)
    for state in (b"ready", b"failed"):
        if content == state + b" " + token + b"\n":
            print(state.decode())
            return 0
    die("isolated Codex home activation result is unsafe")


def remove_activation_result(args):
    try:
        data_fd = open_directory(os.path.abspath(args.data))
        try:
            require_directory(data_fd, "firstmate data")
            base_fd = open_directory("codex-crewmate", data_fd)
        finally:
            os.close(data_fd)
        try:
            require_directory(base_fd, "isolated Codex home")
            try:
                os.unlink(activation_result_name(args), dir_fd=base_fd)
            except FileNotFoundError:
                pass
        finally:
            os.close(base_fd)
    except FileNotFoundError:
        pass
    except OSError as error:
        die(f"could not remove isolated Codex home activation result: {error.strerror}")


class ActivationExecError(Exception):
    pass


def activate_command(args, home_fd, command, result_fd, token):
    read_fd, write_fd = os.pipe()
    os.set_inheritable(read_fd, False)
    os.set_inheritable(write_fd, False)
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        try:
            os.set_inheritable(home_fd, True)
            environment = os.environ.copy()
            # macOS devfs cannot open /dev/fd/<fd> as a directory, so Codex
            # rejects an fd-shaped CODEX_HOME there; resolve the descriptor to
            # its real path (F_GETPATH on macOS, /proc on Linux) and fall back
            # to the fd path only when no resolution is possible.
            environment["CODEX_HOME"] = directory_path(
                home_fd, args.home or f"/dev/fd/{home_fd}"
            )
            os.execvpe(command[0], command, environment)
        except BaseException:
            try:
                write_all(write_fd, b"failed\n")
            finally:
                os._exit(1)
    os.close(write_fd)
    try:
        outcome = os.read(read_fd, 64)
    finally:
        os.close(read_fd)
    if outcome:
        _, status = os.waitpid(pid, 0)
        finish_activation_result_with_token(result_fd, b"failed", token)
        raise ActivationExecError("could not execute isolated Codex launch")
    time.sleep(0.1)
    exited_pid, status = os.waitpid(pid, os.WNOHANG)
    if exited_pid:
        raise ActivationExecError("isolated Codex launch exited during activation")
    try:
        finish_activation_result_with_token(result_fd, b"ready", token)
    except BaseException:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
        raise
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


def validate_data_root(data):
    if not data:
        die("isolated Codex home requires --data")
    data_fd = open_directory(os.path.abspath(data))
    try:
        require_directory(data_fd, "firstmate data")
        try:
            base_fd = open_directory("codex-crewmate", data_fd)
        except FileNotFoundError:
            return
        try:
            require_directory(base_fd, "isolated Codex home")
        finally:
            os.close(base_fd)
    finally:
        os.close(data_fd)


def remove_home(args):
    if args.create_activate or not args.home:
        die("Codex home removal requires --home")
    if not args.data or not args.state:
        die("Codex home removal requires --data and --state")
    data_fd = open_directory(os.path.abspath(args.data))
    try:
        require_directory(data_fd, "firstmate data")
        try:
            base_fd = open_directory("codex-crewmate", data_fd)
        except FileNotFoundError:
            return
    finally:
        os.close(data_fd)
    try:
        require_directory(base_fd, "isolated Codex home")
        expected = removal_home_path(args, base_fd)
        require_unreferenced_home(args, expected)
        if not require_task_profile(args, base_fd):
            return
        remove_tree(base_fd, managed_home_name(args.home))
    except FileNotFoundError:
        pass
    finally:
        os.close(base_fd)


def create_home(args, command=None):
    if not args.source or not args.profile or args.worktree is None:
        die("Codex home creation requires --source, --profile, and --worktree")
    if not args.data:
        die("Codex home creation requires --data")
    if not args.profile or any(
        char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        for char in args.profile
    ):
        die("isolated Codex profile name is unsafe")
    worktree = toml_basic_string(args.worktree)
    try:
        data = os.path.abspath(args.data)
        data_fd = open_directory(data)
        require_directory(data_fd, "firstmate data")
        data = directory_path(data_fd, data)
        try:
            try:
                os.mkdir("codex-crewmate", 0o700, dir_fd=data_fd)
            except FileExistsError:
                pass
            base_fd = open_directory("codex-crewmate", data_fd)
            require_directory(base_fd, "isolated Codex home")
            os.fchmod(base_fd, 0o700)
            try:
                activation_fd = None
                activation_token = None
                home_created = False
                if command:
                    activation_fd = activation_result_fd(args, base_fd)
                    activation_token = result_token(args)
                while True:
                    name = (
                        managed_home_name(args.home)
                        if args.home
                        else ".fm-codex-home." + secrets.token_hex(16)
                    )
                    try:
                        os.mkdir(name, 0o700, dir_fd=base_fd)
                        home_created = True
                        break
                    except FileExistsError:
                        if args.home:
                            die("isolated Codex home already exists")
                        continue
                home_fd = open_directory(name, base_fd)
                try:
                    require_directory(home_fd, "isolated Codex home")
                    os.fchmod(home_fd, 0o700)
                    base_config = (
                        '# Firstmate Codex crewmate home.\n[features]\nplugins = false\n[projects."%s"]\ntrust_level = "untrusted"\n'
                        % worktree
                    )
                    write_file(home_fd, "config.toml", base_config.encode())
                    copy_regular_file(args.source, home_fd, "auth.json")
                    copy_regular_file(args.source, home_fd, "models_cache.json")
                    profile = (
                        '# Firstmate Codex crewmate profile.\n[projects."%s"]\ntrust_level = "untrusted"\n'
                        % worktree
                    )
                    write_file(home_fd, args.profile + ".config.toml", profile.encode())
                    if command:
                        return activate_command(
                            args, home_fd, command, activation_fd, activation_token
                        )
                finally:
                    os.close(home_fd)
                print(os.path.join(data, "codex-crewmate", name))
            except BaseException:
                if activation_fd is not None:
                    try:
                        finish_activation_result_with_token(
                            activation_fd, b"failed", activation_token
                        )
                    except OSError:
                        pass
                if home_created:
                    try:
                        remove_tree(base_fd, name)
                    except OSError:
                        pass
                raise
            finally:
                os.close(base_fd)
        finally:
            os.close(data_fd)
    except OSError as error:
        die(f"could not prepare isolated Codex home: {error.strerror}")


def main():
    args = parse_args()
    if args.new_result_token:
        if (
            args.new_home_name
            or args.remove
            or args.create_activate
            or args.read_activation_result
            or args.remove_activation_result
            or args.home
            or args.result_token
            or args.command
        ):
            die("isolated Codex home result token generation accepts no other action")
        print(secrets.token_hex(32))
        return
    if args.new_home_name:
        if (
            args.remove
            or args.create_activate
            or args.read_activation_result
            or args.remove_activation_result
            or args.home
            or args.result_token
            or args.command
        ):
            die("isolated Codex home name generation accepts no other action")
        try:
            validate_data_root(args.data)
        except OSError as error:
            die(f"could not prepare isolated Codex home: {error.strerror}")
        print(".fm-codex-home." + secrets.token_hex(16))
        return
    if args.read_activation_result:
        if (
            args.remove
            or args.create_activate
            or args.remove_activation_result
            or not args.home
            or not args.data
            or args.source
            or args.profile
            or args.worktree is not None
            or args.command
        ):
            die(
                "isolated Codex home activation result read requires data, home, and result arguments"
            )
        raise SystemExit(read_activation_result(args))
    if args.remove_activation_result:
        if (
            args.remove
            or args.create_activate
            or args.read_activation_result
            or not args.home
            or not args.data
            or args.source
            or args.profile
            or args.worktree is not None
            or args.command
        ):
            die("isolated Codex home activation result removal requires data and home")
        remove_activation_result(args)
        return
    if args.remove:
        remove_home(args)
        return
    if args.create_activate:
        if not args.home:
            die("Codex home activation requires --home")
        if not args.data:
            die("Codex home activation requires --data")
        result_token(args)
        try:
            exit_code = create_home(args, launch_command(args))
        except BaseException:
            raise
        raise SystemExit(exit_code)
        return
    create_home(args)


if __name__ == "__main__":
    main()
