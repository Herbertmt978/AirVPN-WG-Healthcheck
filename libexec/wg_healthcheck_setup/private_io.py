"""Secret-safe descriptor handling for setup input and runtime records."""

from __future__ import annotations

import getpass
import os
from pathlib import Path
import re
import resource
import stat
import sys
import tempfile
from typing import Callable
import warnings

from .model import (
    COUNTRY_CODE_PATTERN,
    DEVICE_PATTERN,
    MAX_PRIVATE_FD,
    MAX_SETTINGS_BYTES,
    MIN_PRIVATE_FD,
    SetupError,
)


class PrivateHandle:
    """Own a private descriptor and close it exactly once."""

    def __init__(self, fd: int, owner=None):
        self.fd = fd
        self._owner = owner
        self._closed = False

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._owner is not None:
            self._owner.close()
        else:
            os.close(self.fd)

    def __enter__(self) -> "PrivateHandle":
        return self

    def __exit__(self, _error_type, _error, _traceback) -> None:
        self.close()


def disable_core_dumps() -> None:
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (OSError, ValueError) as error:
        raise SetupError("could not disable core dumps; no secret was read") from error


def _validate_credential_bytes(value: bytes) -> None:
    if not re.fullmatch(rb"[0-9a-f]{64}\n", value):
        raise SetupError(
            "AirVPN API credential must be one lowercase 64-hex-character line"
        )


def _validate_private_fd_range(fd: int) -> None:
    if not isinstance(fd, int) or fd < MIN_PRIVATE_FD or fd > MAX_PRIVATE_FD:
        raise SetupError("private file is outside the supported descriptor range")


def _credential_metadata(metadata) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_nlink,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _private_temporary(value: bytes) -> PrivateHandle:
    temporary = tempfile.TemporaryFile(mode="w+b")
    try:
        _validate_private_fd_range(temporary.fileno())
        os.fchmod(temporary.fileno(), 0o600)
        written = temporary.write(value)
        if written != len(value):
            raise OSError("short private temporary-file write")
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary.seek(0)
        metadata = os.fstat(temporary.fileno())
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_uid != 0
        ):
            raise SetupError(
                "private descriptor is not a root-owned mode-0600 regular file"
            )
        return PrivateHandle(temporary.fileno(), temporary)
    except Exception:
        temporary.close()
        raise


def credential_from_bytes(value: bytes) -> PrivateHandle:
    _validate_credential_bytes(value)
    return _private_temporary(value)


def open_controlling_tty() -> int:
    flags = os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        fd = os.open("/dev/tty", flags)
    except OSError as error:
        raise SetupError(
            "a controlling TTY is required for hidden credential input"
        ) from error
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISCHR(metadata.st_mode) or not os.isatty(fd):
            raise SetupError(
                "a controlling TTY is required for hidden credential input"
            )
        return fd
    except Exception:
        os.close(fd)
        raise


def read_hidden_credential(*, getpass_fn: Callable | None = None) -> PrivateHandle:
    disable_core_dumps()
    tty_fd = open_controlling_tty()
    try:
        if getpass_fn is None:
            input_stream = os.fdopen(
                os.dup(tty_fd), "r", encoding="utf-8", closefd=True
            )
            output_stream = os.fdopen(
                os.dup(tty_fd), "w", encoding="utf-8", closefd=True
            )
            try:
                previous_stdin = sys.stdin
                sys.stdin = input_stream
                try:
                    with warnings.catch_warnings():
                        warnings.simplefilter("error", getpass.GetPassWarning)
                        secret = getpass.getpass(
                            "AirVPN API key: ", stream=output_stream
                        )
                finally:
                    sys.stdin = previous_stdin
            finally:
                input_stream.close()
                output_stream.close()
        else:
            secret = getpass_fn("AirVPN API key: ")
    except (EOFError, KeyboardInterrupt, getpass.GetPassWarning) as error:
        raise SetupError("hidden credential input was cancelled") from error
    finally:
        os.close(tty_fd)

    try:
        encoded = secret.encode("ascii", "strict") + b"\n"
    except UnicodeError as error:
        raise SetupError("AirVPN API credential has an invalid shape") from error
    finally:
        secret = ""
    try:
        return credential_from_bytes(encoded)
    finally:
        encoded = b""


def _open_absolute_nofollow(path: str) -> int:
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        raise SetupError("--credential-file must be an absolute normalized path")
    components = Path(path).parts
    if (
        not components
        or components[0] != "/"
        or any(part in {"", ".", ".."} for part in components[1:])
    ):
        raise SetupError("--credential-file must be an absolute normalized path")

    def validate_directory(fd: int) -> None:
        metadata = os.fstat(fd)
        mode = stat.S_IMODE(metadata.st_mode)
        sticky_root_directory = metadata.st_uid == 0 and bool(
            metadata.st_mode & stat.S_ISVTX
        )
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != 0
            or ((mode & 0o022) and not sticky_root_directory)
        ):
            raise SetupError(
                "credential-file directory must be root-owned and not writable by others"
            )

    directory_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        validate_directory(directory_fd)
        for component in components[1:-1]:
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            try:
                validate_directory(next_fd)
            except Exception:
                os.close(next_fd)
                raise
            os.close(directory_fd)
            directory_fd = next_fd
        return os.open(
            components[-1],
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError as error:
        raise SetupError(
            "credential file and every path component must be regular non-symlink data"
        ) from error
    finally:
        os.close(directory_fd)


def open_credential_file(path: str) -> PrivateHandle:
    disable_core_dumps()
    fd = _open_absolute_nofollow(path)
    try:
        _validate_private_fd_range(fd)
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise SetupError("credential file must be regular non-symlink data")
        if metadata.st_uid != 0:
            raise SetupError("credential file must be root-owned")
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            raise SetupError("credential file must have exact mode 0600")
        if metadata.st_size != 65:
            raise SetupError("credential file has an invalid bounded record")
        value = os.pread(fd, 66, 0)
        final_metadata = os.fstat(fd)
        if _credential_metadata(metadata) != _credential_metadata(final_metadata):
            raise SetupError("credential file changed while being read")
        _validate_credential_bytes(value)
        os.lseek(fd, 0, os.SEEK_SET)
        return PrivateHandle(fd)
    except Exception:
        os.close(fd)
        raise


def settings_from_values(device: str, countries: str) -> PrivateHandle:
    if not DEVICE_PATTERN.fullmatch(device):
        raise SetupError("proposed AirVPN device is invalid")
    if countries == "ALL":
        pass
    else:
        tokens = countries.split(" ")
        if (
            not tokens
            or "" in tokens
            or len(tokens) > 32
            or len(set(tokens)) != len(tokens)
            or any(not COUNTRY_CODE_PATTERN.fullmatch(token) for token in tokens)
        ):
            raise SetupError("proposed country settings are not canonical")
    record = f"version=1\ndevice={device}\ncountries={countries}\n".encode(
        "ascii", "strict"
    )
    if len(record) > MAX_SETTINGS_BYTES:
        raise SetupError("proposed settings record exceeds 256 bytes")
    return _private_temporary(record)
