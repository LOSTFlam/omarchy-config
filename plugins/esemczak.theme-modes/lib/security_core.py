#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import os
import select
import stat
import subprocess
import sys
import time


READ_CHUNK = 65536
IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "gif", "bmp", "webp"}


class SecurityError(Exception):
    pass


def _uid() -> int:
    return os.getuid()


def _fd_path(fd: int) -> str:
    return os.readlink(f"/proc/self/fd/{fd}")


def _path_under_root(resolved: str, root: str) -> bool:
    root = os.path.realpath(root)
    resolved = os.path.realpath(resolved)
    return resolved == root or resolved.startswith(root + os.sep)


def open_private_directory(dirpath: str) -> int:
    dirpath = os.path.abspath(os.path.expanduser(dirpath))
    os.makedirs(dirpath, mode=0o700, exist_ok=True)
    fd = os.open(dirpath, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise SecurityError("not a directory")
        if st.st_uid != _uid():
            raise SecurityError("wrong owner")
        mode = st.st_mode & 0o777
        if mode & 0o077:
            os.fchmod(fd, 0o700)
        return fd
    except Exception:
        os.close(fd)
        raise


def ensure_private_directory(dirpath: str) -> str:
    fd = open_private_directory(dirpath)
    os.close(fd)
    return os.path.abspath(os.path.expanduser(dirpath))


def read_fd_bounded(fd: int, max_bytes: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        to_read = min(READ_CHUNK, max_bytes - total + 1)
        if to_read <= 0:
            raise SecurityError("too large")
        chunk = os.read(fd, to_read)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise SecurityError("too large")
        chunks.append(chunk)
    return b"".join(chunks)


def read_regular_file(path: str, max_bytes: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise SecurityError("not regular")
        if st.st_size > max_bytes:
            raise SecurityError("too large")
        return read_fd_bounded(fd, max_bytes)
    finally:
        os.close(fd)


def write_regular_file(path: str, max_bytes: int, data: bytes) -> None:
    if len(data) > max_bytes:
        raise SecurityError("too large")

    dirpath = os.path.dirname(path) or "."
    filename = os.path.basename(path)
    if not filename or filename in {".", ".."}:
        raise SecurityError("invalid filename")

    dir_fd = open_private_directory(dirpath)
    try:
        try:
            st = os.stat(filename, dir_fd=dir_fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
                raise SecurityError("invalid target")
        except FileNotFoundError:
            pass

        tmp_name = f".theme-modes.{os.getpid()}.{os.urandom(8).hex()}.tmp"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        tmp_fd = os.open(tmp_name, flags, 0o600, dir_fd=dir_fd)
        try:
            written = 0
            while written < len(data):
                written += os.write(tmp_fd, data[written:])
            os.fsync(tmp_fd)
        finally:
            os.close(tmp_fd)

        os.replace(tmp_name, filename, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    finally:
        os.close(dir_fd)


def _image_extension(path: str) -> str:
    ext = os.path.splitext(path)[1].lstrip(".").lower()
    if ext not in IMAGE_EXTENSIONS:
        raise SecurityError("invalid image extension")
    return ext


def _open_source_path(path: str) -> int:
    if os.path.islink(path):
        link_dir = os.path.dirname(os.path.abspath(path))
        target = os.readlink(path)
        if target.startswith("/"):
            candidate = os.path.abspath(target)
        else:
            candidate = os.path.abspath(os.path.join(link_dir, target))
        return os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    return os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)


def materialize_verified_image(source_path: str, root_path: str, max_bytes: int, cache_dir: str) -> str:
    root_path = os.path.abspath(os.path.expanduser(root_path))
    source_path = os.path.abspath(os.path.expanduser(source_path))
    _image_extension(source_path)

    src_fd = _open_source_path(source_path)
    try:
        st = os.fstat(src_fd)
        if not stat.S_ISREG(st.st_mode):
            raise SecurityError("not regular")
        if st.st_size > max_bytes:
            raise SecurityError("too large")

        resolved = _fd_path(src_fd)
        if not _path_under_root(resolved, root_path):
            raise SecurityError("outside root")

        data = read_fd_bounded(src_fd, max_bytes)
        ext = _image_extension(resolved)
        digest = hashlib.sha256(
            f"{st.st_dev}:{st.st_ino}:{st.st_size}:{st.st_mtime_ns}:{st.st_ctime_ns}".encode()
        ).hexdigest()
        cache_name = f"{digest}.{ext}"
        cache_dir = ensure_private_directory(cache_dir)
        cache_path = os.path.join(cache_dir, cache_name)

        if os.path.isfile(cache_path) and not os.path.islink(cache_path):
            try:
                cst = os.stat(cache_path, follow_symlinks=False)
                if stat.S_ISREG(cst.st_mode) and cst.st_size == len(data):
                    return cache_path
            except OSError:
                pass

        write_regular_file(cache_path, max_bytes, data)
        return cache_path
    finally:
        os.close(src_fd)


def bounded_command_lines(
    argv: list[str],
    max_lines: int,
    max_line_bytes: int,
    timeout_sec: float,
    max_total_bytes: int,
) -> list[str]:
    start = time.monotonic()
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    assert proc.stdout is not None
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)

    buf = b""
    total = 0
    lines: list[str] = []

    def kill_proc() -> None:
        if proc.poll() is None:
            proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)

    try:
        while len(lines) < max_lines:
            remaining = timeout_sec - (time.monotonic() - start)
            if remaining <= 0:
                kill_proc()
                break

            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                kill_proc()
                break

            try:
                chunk = os.read(fd, READ_CHUNK)
            except BlockingIOError:
                continue

            if not chunk:
                if proc.poll() is None:
                    continue
                break

            total += len(chunk)
            if total > max_total_bytes:
                kill_proc()
                break

            buf += chunk
            while b"\n" in buf and len(lines) < max_lines:
                line, _, buf = buf.partition(b"\n")
                if len(line) > max_line_bytes:
                    line = line[:max_line_bytes]
                text = line.decode("utf-8", errors="ignore").strip()
                if text:
                    lines.append(text)

        if buf and len(lines) < max_lines:
            if len(buf) > max_line_bytes:
                buf = buf[:max_line_bytes]
            text = buf.decode("utf-8", errors="ignore").strip()
            if text:
                lines.append(text)

        if proc.poll() is None:
            kill_proc()
    finally:
        proc.stdout.close()

    return lines[:max_lines]


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""

    try:
        if cmd == "read-regular":
            path = sys.argv[2]
            max_bytes = int(sys.argv[3])
            sys.stdout.buffer.write(read_regular_file(path, max_bytes))
            return 0

        if cmd == "write-regular":
            path = sys.argv[2]
            max_bytes = int(sys.argv[3])
            data = sys.stdin.buffer.read(max_bytes + 1)
            if len(data) > max_bytes:
                raise SecurityError("too large")
            write_regular_file(path, max_bytes, data)
            return 0

        if cmd == "ensure-dir":
            print(ensure_private_directory(sys.argv[2]))
            return 0

        if cmd == "materialize-image":
            cache = materialize_verified_image(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5])
            print(cache)
            return 0

        if cmd == "bounded-theme-names":
            max_lines = int(sys.argv[2])
            max_line_bytes = int(sys.argv[3])
            timeout_sec = float(sys.argv[4])
            max_total_bytes = int(sys.argv[5])
            for line in bounded_command_lines(
                ["omarchy", "theme", "list"],
                max_lines,
                max_line_bytes,
                timeout_sec,
                max_total_bytes,
            ):
                print(line)
            return 0

        raise SecurityError(f"unknown command: {cmd}")
    except (SecurityError, OSError, ValueError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
