#!/usr/bin/env python3
import argparse
import os
import secrets
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
        for child in os.listdir(child_fd):
            child_stat = os.stat(child, dir_fd=child_fd, follow_symlinks=False)
            if stat.S_ISDIR(child_stat.st_mode):
                remove_tree(child_fd, child)
            else:
                os.unlink(child, dir_fd=child_fd)
    finally:
        os.close(child_fd)
    os.rmdir(name, dir_fd=directory_fd)


def toml_basic_string(value):
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        die("Codex worktree path contains a TOML control character")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--worktree", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
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
                    name = ".fm-codex-home." + secrets.token_hex(16)
                    try:
                        os.mkdir(name, 0o700, dir_fd=base_fd)
                        home_created = True
                        break
                    except FileExistsError:
                        continue
                home_fd = open_directory(name, base_fd)
                try:
                    require_directory(home_fd, "isolated Codex home")
                    os.fchmod(home_fd, 0o700)
                    write_file(home_fd, "config.toml", b"# Firstmate Codex crewmate home.\n")
                    copy_regular_file(args.source, home_fd, "auth.json")
                    copy_regular_file(args.source, home_fd, "models_cache.json")
                    profile = "# Firstmate Codex crewmate profile.\n[projects.\"%s\"]\ntrust_level = \"untrusted\"\n" % worktree
                    write_file(home_fd, args.profile + ".config.toml", profile.encode())
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


if __name__ == "__main__":
    main()
