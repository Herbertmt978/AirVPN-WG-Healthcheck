"""Fixed, redacted subprocess clients used by guided setup."""

from __future__ import annotations

import subprocess
from typing import Callable

from .model import (
    AIRVPN_API_HELPER,
    CHILD_TIMEOUT_SECONDS,
    INTERFACE_PATTERN,
    RUNTIME,
    SAFE_PATH,
    Country,
    RuntimeManifest,
    SetupError,
    parse_country_inventory,
    parse_runtime_manifest,
    runtime_validation_failure_message,
)
from .private_io import PrivateHandle


def safe_child_environment() -> dict[str, str]:
    return {"PATH": SAFE_PATH, "LANG": "C", "LC_ALL": "C"}


def _run_fixed(
    argv: list[str],
    *,
    pass_fds: tuple[int, ...],
    run: Callable = subprocess.run,
) -> subprocess.CompletedProcess:
    try:
        return run(
            argv,
            shell=False,
            check=False,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=CHILD_TIMEOUT_SECONDS,
            close_fds=True,
            pass_fds=pass_fds,
            env=safe_child_environment(),
        )
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise SetupError("a fixed setup helper could not be executed") from error


def fetch_public_countries(*, run: Callable = subprocess.run) -> tuple[Country, ...]:
    completed = _run_fixed(
        [AIRVPN_API_HELPER, "list-countries"],
        pass_fds=(),
        run=run,
    )
    if completed.returncode != 0 or completed.stderr:
        raise SetupError("credential-free country discovery failed")
    return parse_country_inventory(completed.stdout)


def run_runtime_validation(
    iface: str,
    operation: str,
    credential: PrivateHandle,
    settings: PrivateHandle,
    *,
    run: Callable = subprocess.run,
) -> RuntimeManifest:
    if operation not in {"provision", "adopt"} or not INTERFACE_PATTERN.fullmatch(
        iface
    ):
        raise SetupError("runtime validation request is invalid")
    if credential.fd == settings.fd:
        raise SetupError(
            "credential and proposed settings descriptors must be distinct"
        )
    argv = [
        RUNTIME,
        operation,
        iface,
        "--dry-run",
        "--credential-fd",
        str(credential.fd),
        "--settings-fd",
        str(settings.fd),
    ]
    completed = _run_fixed(argv, pass_fds=(credential.fd, settings.fd), run=run)
    if completed.returncode != 0:
        raise SetupError(runtime_validation_failure_message(completed.stdout))
    if completed.stderr:
        raise SetupError("runtime returned an invalid redacted manifest")
    return parse_runtime_manifest(completed.stdout, operation)
