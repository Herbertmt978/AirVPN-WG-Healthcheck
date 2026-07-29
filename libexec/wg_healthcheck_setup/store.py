"""Secure, durable filesystem primitives for setup transactions."""

from __future__ import annotations

import errno
import os
from pathlib import Path
import stat

from .model import SetupError


def _metadata_tuple(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_size,
        value.st_nlink,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def validate_directory(path: Path, trusted_uid: int, mode: int = 0o700) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise SetupError("a required private directory is unavailable") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != mode
        or metadata.st_uid != trusted_uid
    ):
        raise SetupError("a required private directory has unsafe metadata")


def ensure_private_directory(path: Path, trusted_uid: int) -> None:
    try:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.chmod(0o700)
    except OSError as error:
        raise SetupError(
            "a required private directory could not be prepared"
        ) from error
    validate_directory(path, trusted_uid)


def secure_metadata(
    path: Path,
    trusted_uid: int,
    *,
    required: bool = True,
    mode: int = 0o600,
) -> os.stat_result | None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if not required:
            return None
        raise SetupError("a required private file is missing") from None
    except OSError as error:
        raise SetupError("a required private file is unavailable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != mode
        or metadata.st_uid != trusted_uid
        or metadata.st_nlink != 1
    ):
        raise SetupError("a private file has unsafe metadata")
    return metadata


def secure_read(
    path: Path,
    trusted_uid: int,
    *,
    maximum: int,
    required: bool = True,
) -> bytes | None:
    before = secure_metadata(path, trusted_uid, required=required)
    if before is None:
        return None
    if before.st_size > maximum:
        raise SetupError("a private file exceeds its bounded format")
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SetupError("a private file could not be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        if _metadata_tuple(opened) != _metadata_tuple(before):
            raise SetupError("a private file changed while it was opened")
        payload = os.pread(descriptor, maximum + 1, 0)
        after = os.fstat(descriptor)
        if _metadata_tuple(after) != _metadata_tuple(opened):
            raise SetupError("a private file changed while it was read")
        if len(payload) != opened.st_size or len(payload) > maximum:
            raise SetupError("a private file changed while it was read")
        return payload
    finally:
        os.close(descriptor)


def _open_directory(path: Path, trusted_uid: int) -> int:
    validate_directory(path, trusted_uid)
    try:
        descriptor = os.open(
            path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
    except OSError as error:
        raise SetupError("a private directory could not be opened safely") from error
    accepted = False
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o700
            or metadata.st_uid != trusted_uid
        ):
            raise SetupError("a private directory changed while it was opened")
        accepted = True
        return descriptor
    except OSError as error:
        raise SetupError("a private directory could not be inspected safely") from error
    finally:
        if not accepted:
            os.close(descriptor)


def private_staging_path(target: Path) -> Path:
    """Return the fixed same-directory staging path for an atomic private write."""

    return target.with_name(f".{target.name}.setup-staging")


def snapshot_staging_path(backup: Path) -> Path:
    """Return the fixed same-directory staging path for one recovery snapshot."""

    return backup.with_name(f".{backup.name}.snapshot-staging")


def _entry_exists(directory_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError as error:
        raise SetupError("a private staging entry could not be inspected") from error
    return True


def _remove_name_durably(directory_fd: int, name: str, message: str) -> None:
    try:
        os.unlink(name, dir_fd=directory_fd)
    except FileNotFoundError:
        pass
    except OSError as error:
        raise SetupError(message) from error
    try:
        os.fsync(directory_fd)
    except OSError as error:
        raise SetupError(f"{message} durably") from error


def discard_private_staging(target: Path, trusted_uid: int) -> None:
    """Durably discard an unpublished fixed staging entry during recovery."""

    staging = private_staging_path(target)
    directory_fd = _open_directory(target.parent, trusted_uid)
    try:
        if _entry_exists(directory_fd, staging.name):
            _remove_name_durably(
                directory_fd,
                staging.name,
                "an incomplete private staging file could not be removed",
            )
    finally:
        os.close(directory_fd)


def _clean_snapshot_staging(backup: Path, trusted_uid: int) -> None:
    staging = snapshot_staging_path(backup)
    if not staging.exists() and not staging.is_symlink():
        return
    directory_fd = _open_directory(backup.parent, trusted_uid)
    try:
        if not _entry_exists(directory_fd, staging.name):
            return
        try:
            backup_metadata = os.stat(
                backup.name, dir_fd=directory_fd, follow_symlinks=False
            )
        except FileNotFoundError:
            backup_metadata = None
        except OSError as error:
            raise SetupError(
                "a setup recovery snapshot could not be inspected"
            ) from error
        if backup_metadata is not None:
            try:
                staging_metadata = os.stat(
                    staging.name, dir_fd=directory_fd, follow_symlinks=False
                )
            except OSError as error:
                raise SetupError(
                    "a setup recovery snapshot staging entry could not be inspected"
                ) from error
            if (backup_metadata.st_dev, backup_metadata.st_ino) != (
                staging_metadata.st_dev,
                staging_metadata.st_ino,
            ):
                raise SetupError(
                    "a conflicting setup recovery snapshot staging entry requires inspection"
                )
        _remove_name_durably(
            directory_fd,
            staging.name,
            "an incomplete setup recovery snapshot could not be removed",
        )
    finally:
        os.close(directory_fd)


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError(errno.EIO, "short private-file write")
        offset += written


def atomic_write(path: Path, payload: bytes, trusted_uid: int) -> None:
    directory_fd = _open_directory(path.parent, trusted_uid)
    try:
        temporary = private_staging_path(path).name
        descriptor = -1
        temporary_created = False
        installed = False
        try:
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory_fd,
            )
            temporary_created = True
            os.fchmod(descriptor, 0o600)
            if os.geteuid() == 0:
                os.fchown(descriptor, trusted_uid, 0)
            _write_all(descriptor, payload)
            os.fsync(descriptor)
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_uid != trusted_uid
                or metadata.st_size != len(payload)
            ):
                raise SetupError("a staged private file has unsafe metadata")
            os.close(descriptor)
            descriptor = -1
            os.replace(
                temporary,
                path.name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            installed = True
            final_fd = os.open(
                path.name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=directory_fd,
            )
            try:
                os.fsync(final_fd)
            finally:
                os.close(final_fd)
            os.fsync(directory_fd)
        except SetupError:
            raise
        except OSError as error:
            raise SetupError("a private file could not be committed durably") from error
        finally:
            try:
                if descriptor >= 0:
                    os.close(descriptor)
            finally:
                if temporary_created and not installed:
                    _remove_name_durably(
                        directory_fd,
                        temporary,
                        "an incomplete private temporary file could not be removed",
                    )
    finally:
        os.close(directory_fd)


def _copy_exact(source_fd: int, destination_fd: int, length: int) -> None:
    offset = 0
    while offset < length:
        sent = os.sendfile(destination_fd, source_fd, offset, length - offset)
        if sent <= 0:
            raise OSError(errno.EIO, "short descriptor copy")
        offset += sent


def copy_descriptor_atomic(
    source_fd: int,
    path: Path,
    trusted_uid: int,
    *,
    expected_size: int,
) -> None:
    source_before = os.fstat(source_fd)
    if (
        not stat.S_ISREG(source_before.st_mode)
        or stat.S_IMODE(source_before.st_mode) != 0o600
        or source_before.st_uid != trusted_uid
        or source_before.st_size != expected_size
    ):
        raise SetupError("the credential descriptor has unsafe metadata")
    directory_fd = _open_directory(path.parent, trusted_uid)
    try:
        temporary = private_staging_path(path).name
        destination_fd = -1
        temporary_created = False
        installed = False
        try:
            destination_fd = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory_fd,
            )
            temporary_created = True
            os.fchmod(destination_fd, 0o600)
            if os.geteuid() == 0:
                os.fchown(destination_fd, trusted_uid, 0)
            _copy_exact(source_fd, destination_fd, expected_size)
            os.fsync(destination_fd)
            if _metadata_tuple(os.fstat(source_fd)) != _metadata_tuple(source_before):
                raise SetupError("the credential descriptor changed during persistence")
            os.close(destination_fd)
            destination_fd = -1
            os.replace(
                temporary,
                path.name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            installed = True
            final_fd = os.open(
                path.name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=directory_fd,
            )
            try:
                os.fsync(final_fd)
            finally:
                os.close(final_fd)
            os.fsync(directory_fd)
        except SetupError:
            raise
        except OSError as error:
            raise SetupError("the credential could not be installed durably") from error
        finally:
            try:
                if destination_fd >= 0:
                    os.close(destination_fd)
            finally:
                if temporary_created and not installed:
                    _remove_name_durably(
                        directory_fd,
                        temporary,
                        "an incomplete private temporary file could not be removed",
                    )
    finally:
        os.close(directory_fd)


def snapshot_file(
    source: Path, backup: Path, trusted_uid: int, *, maximum: int
) -> None:
    if backup.exists() or backup.is_symlink():
        raise SetupError("a prior setup recovery file is unresolved")
    staging = snapshot_staging_path(backup)
    try:
        source_fd = os.open(
            source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        )
    except OSError as error:
        raise SetupError("a setup source file could not be opened safely") from error
    try:
        directory_fd = _open_directory(backup.parent, trusted_uid)
        try:
            if _entry_exists(directory_fd, staging.name):
                _remove_name_durably(
                    directory_fd,
                    staging.name,
                    "an incomplete setup recovery snapshot could not be removed",
                )
            destination_fd = -1
            staging_created = False
            try:
                before = os.fstat(source_fd)
                if (
                    not stat.S_ISREG(before.st_mode)
                    or stat.S_IMODE(before.st_mode) != 0o600
                    or before.st_uid != trusted_uid
                    or before.st_size > maximum
                ):
                    raise SetupError("a setup source file has unsafe metadata")
                destination_fd = os.open(
                    staging.name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=directory_fd,
                )
                staging_created = True
                os.fchmod(destination_fd, 0o600)
                if os.geteuid() == 0:
                    os.fchown(destination_fd, trusted_uid, 0)
                _copy_exact(source_fd, destination_fd, before.st_size)
                os.fsync(destination_fd)
                staged = os.fstat(destination_fd)
                if (
                    not stat.S_ISREG(staged.st_mode)
                    or stat.S_IMODE(staged.st_mode) != 0o600
                    or staged.st_uid != trusted_uid
                    or staged.st_size != before.st_size
                    or staged.st_nlink != 1
                ):
                    raise SetupError(
                        "a staged setup recovery snapshot has unsafe metadata"
                    )
                if _metadata_tuple(os.fstat(source_fd)) != _metadata_tuple(before):
                    raise SetupError("a setup source file changed during snapshot")
                os.close(destination_fd)
                destination_fd = -1
                os.link(
                    staging.name,
                    backup.name,
                    src_dir_fd=directory_fd,
                    dst_dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                os.fsync(directory_fd)
                _remove_name_durably(
                    directory_fd,
                    staging.name,
                    "a published setup recovery snapshot staging entry could not be removed",
                )
                staging_created = False
            except SetupError:
                raise
            except OSError as error:
                raise SetupError(
                    "a setup recovery snapshot could not be created"
                ) from error
            finally:
                try:
                    if destination_fd >= 0:
                        os.close(destination_fd)
                finally:
                    if staging_created:
                        _remove_name_durably(
                            directory_fd,
                            staging.name,
                            "an incomplete setup recovery snapshot could not be removed",
                        )
        finally:
            os.close(directory_fd)
    finally:
        os.close(source_fd)


def restore_snapshot(backup: Path, target: Path, trusted_uid: int) -> None:
    _clean_snapshot_staging(backup, trusted_uid)
    payload = secure_read(backup, trusted_uid, maximum=1_048_576, required=True)
    if payload is None:
        raise SetupError("setup rollback snapshot is unavailable")
    # Keep the recovery copy until the owning journal is removed. A crash after
    # this atomic target rewrite can therefore repeat the same rollback exactly.
    atomic_write(target, payload, trusted_uid)


def durable_unlink(path: Path, trusted_uid: int, *, required: bool = False) -> None:
    _clean_snapshot_staging(path, trusted_uid)
    metadata = secure_metadata(path, trusted_uid, required=required)
    if metadata is None:
        return
    directory_fd = _open_directory(path.parent, trusted_uid)
    try:
        os.unlink(path.name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError as error:
        raise SetupError("a private file could not be removed durably") from error
    finally:
        os.close(directory_fd)


def file_identity(path: Path, trusted_uid: int) -> tuple[int, int, int, int] | None:
    metadata = secure_metadata(path, trusted_uid, required=False)
    if metadata is None:
        return None
    return (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_size)
