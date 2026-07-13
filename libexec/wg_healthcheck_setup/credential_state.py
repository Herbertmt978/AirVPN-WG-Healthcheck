"""Credential selection and safe descriptor handling for setup transactions."""

from __future__ import annotations

from contextlib import contextmanager
import hmac
import os
from typing import Iterator

from .apply_config import MAX_CONFIG_BYTES, config_value
from .apply_journal import SetupJournal, extra_path, path_exists, read_journal
from .apply_system import ApplyPathSet, LiveApplyPaths, validate_apply_paths
from .model import SetupError, SetupRequest
from .private_io import (
    PrivateHandle,
    _credential_metadata,
    _validate_credential_bytes,
    _validate_private_fd_range,
)
from .store import secure_metadata, secure_read


@contextmanager
def open_installed_credential(paths: ApplyPathSet) -> Iterator[PrivateHandle]:
    """Open the installed credential while detecting path or descriptor replacement."""

    expected = secure_metadata(paths.credential, paths.trusted_uid, required=True)
    if expected is None or expected.st_size != 65:
        raise SetupError("the installed API credential is invalid")
    try:
        descriptor = os.open(
            paths.credential,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
    except OSError as error:
        raise SetupError(
            "the installed API credential could not be opened safely"
        ) from error
    try:
        _validate_private_fd_range(descriptor)
        opened = os.fstat(descriptor)
        if _credential_metadata(opened) != _credential_metadata(expected):
            raise SetupError("the installed API credential changed while it was opened")
        value = os.pread(descriptor, 66, 0)
        if _credential_metadata(os.fstat(descriptor)) != _credential_metadata(opened):
            raise SetupError("the installed API credential changed while it was read")
        _validate_credential_bytes(value)
        os.lseek(descriptor, 0, os.SEEK_SET)
        with PrivateHandle(descriptor) as handle:
            descriptor = -1
            yield handle
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def installed_profile_source(paths: ApplyPathSet) -> str:
    """Return the source recorded in the installed health configuration."""

    return profile_source_from_path(paths.health_config, paths)


def profile_source_from_path(path, paths: ApplyPathSet) -> str:
    """Read and validate a profile-source value from a trusted configuration file."""

    payload = secure_read(
        path,
        paths.trusted_uid,
        maximum=MAX_CONFIG_BYTES,
        required=True,
    )
    assert payload is not None
    source = config_value(payload, "AIRVPN_PROFILE_SOURCE") or "static"
    if source not in {"static", "api"}:
        raise SetupError("the installed profile source is invalid")
    return source


def credential_state_after_recovery(
    paths: ApplyPathSet, journal: SetupJournal
) -> tuple[str, bool]:
    """Determine the committed credential state an interrupted setup will recover."""

    if journal.phase in {"verified", "rolled-back"}:
        source = installed_profile_source(paths)
        present = (
            secure_metadata(paths.credential, paths.trusted_uid, required=False)
            is not None
        )
        return source, present
    if journal.phase in {"activated", "verifying"}:
        if journal.operation == "api-update":
            return "api", journal.had_key
        # Provision/adoption and either static transition can still commit or roll
        # back during recovery. Require a proposal so either result can proceed in
        # this invocation; an exact restored API key is accepted only after recovery.
        return "static", journal.had_key
    previous = extra_path(paths, "config-previous")
    if path_exists(previous):
        return profile_source_from_path(previous, paths), journal.had_key
    if journal.phase == "prepared":
        return installed_profile_source(paths), journal.had_key
    raise SetupError("the previous configuration snapshot is missing")


def api_requires_proposed_credential(
    request: SetupRequest, *, paths: ApplyPathSet | None = None
) -> bool:
    """Return whether this API request must obtain a new private credential."""

    if request.mode != "api":
        raise SetupError("credential selection requires API mode")
    paths = paths or LiveApplyPaths.for_interface(request.iface)
    validate_apply_paths(paths, request.iface)
    if path_exists(extra_path(paths, "journal")):
        journal = read_journal(paths)
        prior_source, present = credential_state_after_recovery(paths, journal)
        if request.replace_credential and not present:
            raise SetupError("the interrupted setup had no prior credential to replace")
        return request.replace_credential or not present or prior_source != "api"
    present = (
        secure_metadata(paths.credential, paths.trusted_uid, required=False) is not None
    )
    if request.replace_credential and not present:
        raise SetupError("--replace-credential requires an installed API credential")
    return (
        request.replace_credential
        or not present
        or installed_profile_source(paths) != "api"
    )


def credential_bytes(handle: PrivateHandle) -> bytes:
    """Read a proposed credential and reject descriptor replacement during the read."""

    try:
        before = os.fstat(handle.fd)
        value = os.pread(handle.fd, 66, 0)
        after = os.fstat(handle.fd)
    except OSError as error:
        raise SetupError(
            "a credential descriptor could not be compared safely"
        ) from error
    if _credential_metadata(before) != _credential_metadata(after):
        raise SetupError("a credential descriptor changed while it was compared")
    _validate_credential_bytes(value)
    os.lseek(handle.fd, 0, os.SEEK_SET)
    return value


@contextmanager
def effective_credential(
    request: SetupRequest,
    supplied: PrivateHandle | None,
    paths: ApplyPathSet,
    prior_source: str,
    *,
    allow_matching_supplied: bool = False,
) -> Iterator[tuple[PrivateHandle, bool, bool]]:
    """Select the reusable or proposed credential for one API transition."""

    had_key = (
        secure_metadata(paths.credential, paths.trusted_uid, required=False) is not None
    )
    if prior_source == "api" and had_key:
        if request.replace_credential:
            if supplied is None:
                raise SetupError(
                    "credential replacement requires a proposed descriptor"
                )
            yield supplied, True, True
            return
        if supplied is not None:
            if not allow_matching_supplied:
                raise SetupError(
                    "an installed credential is reused unless --replace-credential is explicit"
                )
            with open_installed_credential(paths) as installed:
                if not hmac.compare_digest(
                    credential_bytes(supplied), credential_bytes(installed)
                ):
                    raise SetupError(
                        "the proposed key differs from the recovered installed key; use "
                        "--replace-credential explicitly"
                    )
                yield installed, False, True
            return
        with open_installed_credential(paths) as installed:
            yield installed, False, True
        return
    if supplied is None:
        raise SetupError(
            "entering API mode from static requires a proposed credential descriptor"
        )
    if had_key:
        if request.replace_credential:
            yield supplied, True, True
            return
        with open_installed_credential(paths) as installed:
            if not hmac.compare_digest(
                credential_bytes(supplied), credential_bytes(installed)
            ):
                raise SetupError(
                    "the proposed key differs from the retained key; use "
                    "--replace-credential explicitly"
                )
        yield supplied, False, True
        return
    if request.replace_credential:
        raise SetupError("--replace-credential requires an installed API credential")
    yield supplied, True, False


def precheck_api_credential(
    request: SetupRequest,
    supplied: PrivateHandle | None,
    paths: ApplyPathSet,
    *,
    allow_matching_supplied: bool = False,
) -> None:
    """Reject impossible API credential choices before any setup mutation."""

    present = (
        secure_metadata(paths.credential, paths.trusted_uid, required=False) is not None
    )
    prior_source = installed_profile_source(paths)
    if prior_source == "api" and present:
        if supplied is not None and not request.replace_credential:
            if not allow_matching_supplied:
                raise SetupError(
                    "an installed credential is reused unless --replace-credential is explicit"
                )
            with open_installed_credential(paths) as installed:
                if not hmac.compare_digest(
                    credential_bytes(supplied), credential_bytes(installed)
                ):
                    raise SetupError(
                        "the proposed key differs from the recovered installed key; use "
                        "--replace-credential explicitly"
                    )
        if request.replace_credential and supplied is None:
            raise SetupError("credential replacement requires a proposed descriptor")
        return
    if supplied is None:
        raise SetupError(
            "entering API mode from static requires a proposed credential descriptor"
        )
    if request.replace_credential and not present:
        raise SetupError("--replace-credential requires an installed API credential")
