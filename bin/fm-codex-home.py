#!/usr/bin/env python3
import argparse
import os
import secrets
import signal
import stat
import sys


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
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
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
        target_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
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
    if (current_stat.st_dev, current_stat.st_ino) != (opened_stat.st_dev, opened_stat.st_ino):
        raise OSError("managed Codex home changed during removal")
    os.rmdir(name, dir_fd=directory_fd)


def toml_basic_string(value):
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        die("Codex worktree path contains a TOML control character")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data")
    parser.add_argument("--source")
    parser.add_argument("--profile")
    parser.add_argument("--worktree")
    parser.add_argument("--new-home-name", action="store_true")
    parser.add_argument("--new-result-token", action="store_true")
    parser.add_argument("--create-activate", action="store_true")
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--read-activation-result", action="store_true")
    parser.add_argument("--home")
    parser.add_argument("--result-file")
    parser.add_argument("--result-token")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def managed_home_name(home):
    name = os.path.basename(home or "")
    if not name.startswith(".fm-codex-home.") or len(name) <= len(".fm-codex-home."):
        die("isolated Codex home name is unsafe")
    return name


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


def write_activation_result(args, result):
    if not args.result_file:
        return False
    try:
        fd = os.open(args.result_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            write_all(fd, result + b" " + result_token(args) + b"\n")
            os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
    except OSError:
        return False
    return True


def activation_result_fd(args):
    try:
        fd = os.open(args.result_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
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
    if not args.result_file:
        die("Codex home activation result requires --result-file")
    token = result_token(args)
    try:
        fd = os.open(args.result_file, os.O_RDONLY | os.O_NOFOLLOW)
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


class ActivationExecError(Exception):
    pass


def activate_command(args, home_fd, command):
    result_fd = activation_result_fd(args)
    token = result_token(args)
    read_fd, write_fd = os.pipe()
    os.set_inheritable(read_fd, False)
    os.set_inheritable(write_fd, False)
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        try:
            os.set_inheritable(home_fd, True)
            environment = os.environ.copy()
            environment["CODEX_HOME"] = f"/dev/fd/{home_fd}"
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
    if not args.data:
        die("Codex home removal requires --data")
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
    if not args.profile or any(char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" for char in args.profile):
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
                home_created = False
                while True:
                    name = managed_home_name(args.home) if args.home else ".fm-codex-home." + secrets.token_hex(16)
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
                    base_config = "# Firstmate Codex crewmate home.\n[features]\nplugins = false\n[projects.\"%s\"]\ntrust_level = \"untrusted\"\n" % worktree
                    write_file(home_fd, "config.toml", base_config.encode())
                    copy_regular_file(args.source, home_fd, "auth.json")
                    copy_regular_file(args.source, home_fd, "models_cache.json")
                    profile = "# Firstmate Codex crewmate profile.\n[projects.\"%s\"]\ntrust_level = \"untrusted\"\n" % worktree
                    write_file(home_fd, args.profile + ".config.toml", profile.encode())
                    if command:
                        return activate_command(args, home_fd, command)
                finally:
                    os.close(home_fd)
                print(os.path.join(data, "codex-crewmate", name))
            except BaseException:
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
        if args.new_home_name or args.remove or args.create_activate or args.read_activation_result or args.home or args.result_file or args.result_token or args.command:
            die("isolated Codex home result token generation accepts no other action")
        print(secrets.token_hex(32))
        return
    if args.new_home_name:
        if args.remove or args.create_activate or args.read_activation_result or args.home or args.result_file or args.result_token or args.command:
            die("isolated Codex home name generation accepts no other action")
        try:
            validate_data_root(args.data)
        except OSError as error:
            die(f"could not prepare isolated Codex home: {error.strerror}")
        print(".fm-codex-home." + secrets.token_hex(16))
        return
    if args.read_activation_result:
        if args.remove or args.create_activate or args.home or args.source or args.profile or args.worktree is not None or args.command:
            die("isolated Codex home activation result read accepts only result arguments")
        raise SystemExit(read_activation_result(args))
    if args.remove:
        remove_home(args)
        return
    if args.create_activate:
        if not args.home:
            die("Codex home activation requires --home")
        if not args.result_file:
            die("Codex home activation requires --result-file")
        result_token(args)
        try:
            exit_code = create_home(args, launch_command(args))
        except BaseException:
            write_activation_result(args, b"failed")
            raise
        raise SystemExit(exit_code)
        return
    if args.result_file:
        die("Codex home result files are only valid for activation")
    create_home(args)


if __name__ == "__main__":
    main()
