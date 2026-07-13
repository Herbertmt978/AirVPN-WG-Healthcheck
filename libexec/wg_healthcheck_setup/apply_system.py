"""Fixed-path system boundary for transactional setup operations."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import os
from pathlib import Path
import re
import subprocess
from typing import Callable, Iterator, Protocol

from .clients import _run_fixed
from .model import RUNTIME, SetupError, parse_runtime_manifest
from .private_io import PrivateHandle, settings_from_values
from .store import (
    ensure_private_directory,
    file_identity,
    secure_metadata,
    secure_read,
    validate_directory,
)


SYSTEMCTL = "/usr/bin/systemctl"
MAX_STATUS_BYTES = 512


class ApplyPathSet(Protocol):
    iface: str
    trusted_uid: int
    health_dir: Path
    health_config: Path
    credential: Path
    wireguard_dir: Path
    profile: Path
    pre_managed: Path
    backup: Path
    pending: Path
    safety: Path
    candidate: Path
    state_dir: Path
    api_state: Path
    runtime_dir: Path
    status: Path
    setup_guard: Path
    interface_lock: Path
    global_lock: Path
    timer_unit: str
    service_unit: str


@dataclass(frozen=True)
class LiveApplyPaths:
    iface: str
    trusted_uid: int
    health_dir: Path
    health_config: Path
    credential: Path
    wireguard_dir: Path
    profile: Path
    pre_managed: Path
    backup: Path
    pending: Path
    safety: Path
    candidate: Path
    state_dir: Path
    api_state: Path
    runtime_dir: Path
    status: Path
    setup_guard: Path
    interface_lock: Path
    global_lock: Path
    timer_unit: str
    service_unit: str

    @classmethod
    def for_interface(cls, iface: str) -> "LiveApplyPaths":
        health_dir = Path("/etc/wireguard/healthcheck.d")
        wireguard_dir = Path("/etc/wireguard")
        runtime_dir = Path("/run/wg-healthcheck")
        state_dir = Path("/var/lib/wg-healthcheck")
        profile = wireguard_dir / f"{iface}.conf"
        return cls(
            iface=iface,
            trusted_uid=0,
            health_dir=health_dir,
            health_config=health_dir / f"{iface}.conf",
            credential=health_dir / f"{iface}.api-key",
            wireguard_dir=wireguard_dir,
            profile=profile,
            pre_managed=wireguard_dir / f"{iface}.conf.pre-managed",
            backup=wireguard_dir / f"{iface}.conf.bak-healthcheck",
            pending=wireguard_dir / f"{iface}.conf.pending-healthcheck",
            safety=wireguard_dir / f"{iface}.conf.safety-healthcheck",
            candidate=wireguard_dir / f".{iface}.conf.managed-candidate",
            state_dir=state_dir,
            api_state=state_dir / f"{iface}.api-state",
            runtime_dir=runtime_dir,
            status=runtime_dir / f"{iface}.status",
            setup_guard=runtime_dir / f"{iface}.setup-guard",
            interface_lock=runtime_dir / f"{iface}.lock",
            global_lock=runtime_dir / "airvpn-api.lock",
            timer_unit=f"wg-healthcheck@{iface}.timer",
            service_unit=f"wg-healthcheck@{iface}.service",
        )


@dataclass(frozen=True)
class HealthProofStart:
    before: tuple[int, int, int, int] | None
    started: int


def validate_apply_paths(paths: ApplyPathSet, iface: str) -> None:
    if paths.iface != iface:
        raise SetupError("setup paths do not match the requested interface")
    for directory in (paths.health_dir, paths.wireguard_dir, paths.state_dir):
        validate_directory(directory, paths.trusted_uid)


def _ensure_guard_file(paths: ApplyPathSet) -> None:
    validate_directory(paths.runtime_dir, paths.trusted_uid)
    try:
        descriptor = os.open(
            paths.setup_guard,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
    except FileExistsError:
        secure_metadata(paths.setup_guard, paths.trusted_uid)
        return
    except OSError as error:
        raise SetupError("the setup guard could not be created safely") from error
    try:
        os.fchmod(descriptor, 0o600)
        if os.geteuid() == 0:
            os.fchown(descriptor, paths.trusted_uid, 0)
        os.fsync(descriptor)
        directory_fd = os.open(
            paths.runtime_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        )
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        raise SetupError("the setup guard could not be committed safely") from error
    finally:
        os.close(descriptor)


@contextmanager
def exclusive_setup_lease(paths: ApplyPathSet) -> Iterator[int]:
    ensure_private_directory(paths.runtime_dir, paths.trusted_uid)
    _ensure_guard_file(paths)
    try:
        descriptor = os.open(
            paths.setup_guard,
            os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
    except OSError as error:
        raise SetupError("the setup guard could not be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        expected = secure_metadata(paths.setup_guard, paths.trusted_uid)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            raise SetupError("the setup guard changed while it was opened")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SetupError(
                "another healthcheck or setup operation is active"
            ) from error
        yield descriptor
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def probe_runtime_lock(path: Path, paths: ApplyPathSet) -> None:
    metadata = secure_metadata(path, paths.trusted_uid, required=False)
    if metadata is None:
        return
    try:
        descriptor = os.open(
            path, os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        )
    except OSError as error:
        raise SetupError("a runtime lock could not be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise SetupError("a runtime lock changed while it was opened")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SetupError("a runtime lock is active") from error
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            except OSError:
                pass
    finally:
        os.close(descriptor)


def systemctl(arguments: list[str], *, run: Callable) -> subprocess.CompletedProcess:
    return _run_fixed([SYSTEMCTL, *arguments], pass_fds=(), run=run)


def stop_units(paths: ApplyPathSet, *, run: Callable) -> None:
    if systemctl(["disable", "--now", paths.timer_unit], run=run).returncode != 0:
        raise SetupError("the healthcheck timer could not be disabled")
    if systemctl(["stop", paths.service_unit], run=run).returncode != 0:
        raise SetupError("the healthcheck worker could not be stopped")
    prove_units_inactive(paths, run=run)


def prove_units_inactive(paths: ApplyPathSet, *, run: Callable) -> None:
    inactive = True
    for unit in (paths.timer_unit, paths.service_unit):
        observed = systemctl(["is-active", "--quiet", unit], run=run)
        if observed.returncode != 3:
            inactive = False
    if not inactive:
        raise SetupError("a healthcheck unit did not become inactive")


def runtime_argv(
    command: str, paths: ApplyPathSet, lease_fd: int, *arguments: str
) -> list[str]:
    return [
        RUNTIME,
        command,
        paths.iface,
        *arguments,
        "--setup-lease-fd",
        str(lease_fd),
    ]


def runtime_call(
    command: str,
    paths: ApplyPathSet,
    lease_fd: int,
    *arguments: str,
    pass_fds: tuple[int, ...] = (),
    run: Callable,
) -> subprocess.CompletedProcess:
    inherited = (lease_fd, *pass_fds)
    if len(inherited) != len(set(inherited)):
        raise SetupError("setup private descriptors are not distinct")
    return _run_fixed(
        runtime_argv(command, paths, lease_fd, *arguments),
        pass_fds=inherited,
        run=run,
    )


def validate_with_lease(
    paths: ApplyPathSet,
    operation: str,
    lease_fd: int,
    credential: PrivateHandle,
    device: str,
    settings_countries: str,
    *,
    run: Callable,
) -> None:
    os.lseek(credential.fd, 0, os.SEEK_SET)
    with settings_from_values(device, settings_countries) as settings:
        completed = runtime_call(
            operation,
            paths,
            lease_fd,
            "--dry-run",
            "--credential-fd",
            str(credential.fd),
            "--settings-fd",
            str(settings.fd),
            pass_fds=(credential.fd, settings.fd),
            run=run,
        )
        if completed.returncode != 0 or completed.stderr:
            raise SetupError(
                "authenticated runtime validation failed; no changes were made"
            )
        parse_runtime_manifest(completed.stdout, operation)
    os.lseek(credential.fd, 0, os.SEEK_SET)


def _status_is_fresh_success(
    paths: ApplyPathSet,
    before: tuple[int, int, int, int] | None,
    started: int,
    finished: int,
) -> bool:
    after = file_identity(paths.status, paths.trusted_uid)
    if (
        after is None
        or after == before
        or (before is not None and after[:2] == before[:2])
    ):
        return False
    payload = secure_read(
        paths.status, paths.trusted_uid, maximum=MAX_STATUS_BYTES, required=True
    )
    if payload is None or not payload.endswith(b"\n"):
        return False
    try:
        lines = payload.decode("ascii", "strict").splitlines()
    except UnicodeError:
        return False
    if len(lines) != 3 or lines[0] not in {"outcome=healthy", "outcome=recovered"}:
        return False
    if not lines[1].startswith("reason=") or any(
        ord(character) < 32 or ord(character) == 127 for character in lines[1][7:]
    ):
        return False
    if not re.fullmatch(r"timestamp=(0|[1-9][0-9]{0,10})", lines[2]):
        return False
    timestamp = int(lines[2][10:], 10)
    return started <= timestamp <= finished + 5


def begin_health_proof(
    paths: ApplyPathSet, *, now: Callable[[], int]
) -> HealthProofStart:
    return HealthProofStart(file_identity(paths.status, paths.trusted_uid), int(now()))


def health_proof_is_complete(
    paths: ApplyPathSet,
    proof: HealthProofStart,
    *,
    now: Callable[[], int],
) -> bool:
    return _status_is_fresh_success(paths, proof.before, proof.started, int(now()))


def verify_health(
    paths: ApplyPathSet,
    lease_fd: int,
    *,
    run: Callable,
    now: Callable[[], int],
    proof: HealthProofStart | None = None,
) -> None:
    proof = proof or begin_health_proof(paths, now=now)
    completed = runtime_call("check", paths, lease_fd, run=run)
    if completed.returncode != 0 or not health_proof_is_complete(paths, proof, now=now):
        raise SetupError("the installed setup did not produce a fresh healthy status")


def enable_timer_after_commit(paths: ApplyPathSet, *, run: Callable) -> None:
    enabled = systemctl(["enable", "--now", paths.timer_unit], run=run)
    if enabled.returncode == 0:
        return
    disabled = systemctl(["disable", "--now", paths.timer_unit], run=run)
    stopped = systemctl(["stop", paths.service_unit], run=run)
    try:
        prove_units_inactive(paths, run=run)
    except SetupError as error:
        raise SetupError(
            "setup is verified and committed, but timer activation failed and "
            "fail-closed containment could not be proven"
        ) from error
    if disabled.returncode != 0 or stopped.returncode != 0:
        raise SetupError(
            "setup is verified and committed; units are inactive, but timer "
            "containment reported an administrative failure"
        )
    raise SetupError(
        "setup is verified and committed, but the timer could not be enabled; "
        "the timer and worker are disabled"
    )
