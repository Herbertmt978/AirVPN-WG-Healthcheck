"""Crash-recoverable setup transactions and credential lifecycle."""

from __future__ import annotations

from dataclasses import replace
import subprocess
import time
from typing import Callable

from .apply_config import (
    DEVICE_PATTERN,
    MAX_CONFIG_BYTES,
    config_value as _config_value,
    country_values as _country_values,
    render_config as _render_config,
)
from .apply_journal import (
    SetupJournal,
    extra_path as _extra_path,
    path_exists as _exists,
    read_journal as _read_journal,
    render_journal as _render_journal,
)
from .apply_system import (
    ApplyPathSet,
    HealthProofStart,
    LiveApplyPaths,
    begin_health_proof,
    enable_timer_after_commit,
    exclusive_setup_lease,
    health_proof_is_complete,
    probe_runtime_lock,
    runtime_call,
    stop_units,
    validate_apply_paths,
    validate_with_lease,
    verify_health,
)
from .credential_state import (
    effective_credential as _effective_credential,
    installed_profile_source as _installed_profile_source,
    open_installed_credential as _open_installed_credential,
    precheck_api_credential as _precheck_api_credential,
)
from .credential_state import api_requires_proposed_credential  # noqa: F401
from .model import SetupError, SetupRequest
from .private_io import PrivateHandle
from .store import (
    atomic_write,
    copy_descriptor_atomic,
    discard_private_staging,
    durable_unlink,
    private_staging_path,
    secure_metadata,
    secure_read,
    snapshot_file,
    snapshot_staging_path,
    restore_snapshot,
)


MAX_PROFILE_BYTES = 1_048_576
_DEVICE = DEVICE_PATTERN


def _write_journal(
    paths: ApplyPathSet,
    *,
    operation: str,
    phase: str,
    had_key: bool,
    had_pre_managed: bool,
    key_changed: bool = True,
    verify_started: int = 0,
    status_before_dev: int = 0,
    status_before_ino: int = 0,
) -> None:
    payload = _render_journal(
        SetupJournal(
            operation,
            phase,
            had_key,
            had_pre_managed,
            key_changed,
            verify_started,
            status_before_dev,
            status_before_ino,
        )
    )
    atomic_write(_extra_path(paths, "journal"), payload, paths.trusted_uid)


def _persist_journal(paths: ApplyPathSet, journal: SetupJournal) -> None:
    _write_journal(
        paths,
        operation=journal.operation,
        phase=journal.phase,
        had_key=journal.had_key,
        had_pre_managed=journal.had_pre_managed,
        key_changed=journal.key_changed,
        verify_started=journal.verify_started,
        status_before_dev=journal.status_before_dev,
        status_before_ino=journal.status_before_ino,
    )


def _cleanup_transaction(paths: ApplyPathSet) -> None:
    for kind in ("config-previous", "credential-previous"):
        durable_unlink(_extra_path(paths, kind), paths.trusted_uid, required=False)
    durable_unlink(_extra_path(paths, "journal"), paths.trusted_uid, required=False)


def _rolled_back(journal: SetupJournal) -> SetupJournal:
    return replace(
        journal,
        phase="rolled-back",
        verify_started=0,
        status_before_dev=0,
        status_before_ino=0,
    )


def _assert_runtime_artifacts_clear(paths: ApplyPathSet) -> None:
    if any(_exists(path) for path in (paths.pending, paths.safety, paths.candidate)):
        raise SetupError("runtime recovery state must be resolved before setup")


def _assert_setup_artifacts_clear(paths: ApplyPathSet) -> None:
    snapshots = tuple(
        _extra_path(paths, kind) for kind in ("config-previous", "credential-previous")
    )
    private_targets = (
        _extra_path(paths, "journal"),
        paths.health_config,
        paths.credential,
    )
    artifacts = (
        _extra_path(paths, "journal"),
        *snapshots,
        *(snapshot_staging_path(path) for path in snapshots),
        *(private_staging_path(path) for path in private_targets),
    )
    if any(_exists(path) for path in artifacts):
        raise SetupError("a previous setup transaction requires recovery")


def _discard_setup_staging(paths: ApplyPathSet) -> None:
    for target in (
        _extra_path(paths, "journal"),
        paths.health_config,
        paths.credential,
    ):
        discard_private_staging(target, paths.trusted_uid)


def _reconcile_runtime_for_recovery(
    paths: ApplyPathSet, lease_fd: int, *, run: Callable
) -> None:
    if _exists(paths.pending) or _exists(paths.safety):
        completed = runtime_call("check", paths, lease_fd, run=run)
        if completed.returncode != 0:
            raise SetupError(
                "runtime could not reconcile an interrupted profile change"
            )
    if _exists(paths.candidate):
        cleaned = runtime_call("cleanup-candidate", paths, lease_fd, "--apply", run=run)
        if cleaned.returncode != 0:
            raise SetupError(
                "runtime could not reconcile an interrupted profile candidate"
            )
    _assert_runtime_artifacts_clear(paths)


def _rollback_api(
    paths: ApplyPathSet,
    lease_fd: int,
    journal: SetupJournal,
    *,
    run: Callable,
) -> None:
    _reconcile_runtime_for_recovery(paths, lease_fd, run=run)
    if (
        journal.operation == "adopt"
        and not journal.had_pre_managed
        and _exists(paths.pre_managed)
    ):
        restored = runtime_call("restore-static", paths, lease_fd, "--apply", run=run)
        if restored.returncode != 0:
            raise SetupError("runtime could not restore the pre-adoption profile")
    config_previous = _extra_path(paths, "config-previous")
    if _exists(config_previous):
        restore_snapshot(config_previous, paths.health_config, paths.trusted_uid)
    elif journal.phase != "prepared":
        raise SetupError("the previous configuration snapshot is missing")
    credential_previous = _extra_path(paths, "credential-previous")
    if journal.key_changed:
        if journal.had_key:
            if _exists(credential_previous):
                restore_snapshot(
                    credential_previous, paths.credential, paths.trusted_uid
                )
            elif journal.phase != "prepared":
                raise SetupError("the previous credential snapshot is missing")
        else:
            durable_unlink(paths.credential, paths.trusted_uid, required=False)
    elif _exists(credential_previous):
        raise SetupError("an unexpected credential snapshot requires inspection")
    if journal.operation == "adopt" and not journal.had_pre_managed:
        durable_unlink(paths.pre_managed, paths.trusted_uid, required=False)
    _persist_journal(paths, _rolled_back(journal))
    _cleanup_transaction(paths)


def _rollback_static(paths: ApplyPathSet, journal: SetupJournal) -> None:
    config_previous = _extra_path(paths, "config-previous")
    if _exists(config_previous):
        restore_snapshot(config_previous, paths.health_config, paths.trusted_uid)
    elif journal.phase != "prepared":
        raise SetupError("the previous configuration snapshot is missing")
    _persist_journal(paths, _rolled_back(journal))
    _cleanup_transaction(paths)


def _journal_health_proof(journal: SetupJournal) -> HealthProofStart:
    before = None
    if journal.status_before_dev != 0:
        before = (
            journal.status_before_dev,
            journal.status_before_ino,
            0,
            0,
        )
    return HealthProofStart(before, journal.verify_started)


def _begin_journaled_health_proof(
    paths: ApplyPathSet,
    journal: SetupJournal,
    *,
    now: Callable[[], int],
) -> tuple[SetupJournal, HealthProofStart]:
    proof = begin_health_proof(paths, now=now)
    before_dev = proof.before[0] if proof.before is not None else 0
    before_ino = proof.before[1] if proof.before is not None else 0
    updated = replace(
        journal,
        phase="verifying",
        verify_started=proof.started,
        status_before_dev=before_dev,
        status_before_ino=before_ino,
    )
    _persist_journal(paths, updated)
    return updated, proof


def _static_restore_is_visible(paths: ApplyPathSet) -> bool:
    config = secure_read(
        paths.health_config,
        paths.trusted_uid,
        maximum=MAX_CONFIG_BYTES,
        required=True,
    )
    if config is None or _config_value(config, "AIRVPN_PROFILE_SOURCE") != "static":
        return False
    profile = secure_read(
        paths.profile,
        paths.trusted_uid,
        maximum=MAX_PROFILE_BYTES,
        required=True,
    )
    pre_managed = secure_read(
        paths.pre_managed,
        paths.trusted_uid,
        maximum=MAX_PROFILE_BYTES,
        required=True,
    )
    return profile is not None and profile == pre_managed


def _recover_setup_transaction(
    paths: ApplyPathSet,
    lease_fd: int,
    *,
    run: Callable,
    now: Callable[[], int],
) -> None:
    _discard_setup_staging(paths)
    journal_path = _extra_path(paths, "journal")
    if not _exists(journal_path):
        _assert_setup_artifacts_clear(paths)
        return
    journal = _read_journal(paths)
    _reconcile_runtime_for_recovery(paths, lease_fd, run=run)
    if journal.phase in {"verified", "rolled-back"}:
        _cleanup_transaction(paths)
        return
    if (
        journal.operation == "static-restore"
        and journal.phase in {"activating", "activated", "verifying"}
        and _static_restore_is_visible(paths)
    ):
        _cleanup_transaction(paths)
        return
    if journal.phase == "verifying" and journal.verify_started > 0:
        if health_proof_is_complete(paths, _journal_health_proof(journal), now=now):
            _persist_journal(paths, replace(journal, phase="verified"))
            _cleanup_transaction(paths)
            return
    if journal.phase == "activated" and journal.operation in {"api-update", "static"}:
        journal, proof = _begin_journaled_health_proof(paths, journal, now=now)
        try:
            verify_health(paths, lease_fd, run=run, now=now, proof=proof)
        except SetupError:
            pass
        else:
            _persist_journal(paths, replace(journal, phase="verified"))
            _cleanup_transaction(paths)
            return
    if journal.operation in {"provision", "adopt", "api-update"}:
        _rollback_api(paths, lease_fd, journal, run=run)
    else:
        _rollback_static(paths, journal)


def _finalize_verified(paths: ApplyPathSet, journal: SetupJournal) -> None:
    try:
        _persist_journal(paths, replace(journal, phase="verified"))
        _cleanup_transaction(paths)
    except SetupError as error:
        raise SetupError(
            "setup is verified and committed, but transaction finalization is incomplete"
        ) from error


def _run_post_commit_actions(
    request: SetupRequest,
    paths: ApplyPathSet,
    lease_fd: int,
    *,
    run: Callable,
) -> None:
    if request.reset_api_state:
        reset = runtime_call("reset-api-state", paths, lease_fd, "--apply", run=run)
        if reset.returncode != 0:
            raise SetupError(
                "setup is verified and committed, but the requested API-state reset failed"
            )
    if request.mode == "static" and request.remove_credential:
        try:
            durable_unlink(paths.credential, paths.trusted_uid, required=False)
        except SetupError as error:
            detail = " after the API-state reset" if request.reset_api_state else ""
            raise SetupError(
                "setup is verified and committed, but credential removal"
                f"{detail} is incomplete"
            ) from error
    if request.timer == "enable":
        enable_timer_after_commit(paths, run=run)


def _apply_api(
    request: SetupRequest,
    supplied: PrivateHandle | None,
    paths: ApplyPathSet,
    lease_fd: int,
    *,
    run: Callable,
    now: Callable[[], int],
    allow_matching_supplied: bool = False,
) -> None:
    if not request.device or not _DEVICE.fullmatch(request.device):
        raise SetupError("API setup requires a valid device")
    if request.timer == "enable" and request.reset_api_state:
        raise SetupError("API-state reset cannot enable the timer")
    settings_countries, config_countries = _country_values(request)
    profile_before = secure_metadata(paths.profile, paths.trusted_uid, required=False)
    operation = "adopt" if profile_before is not None else "provision"
    config_payload = secure_read(
        paths.health_config,
        paths.trusted_uid,
        maximum=MAX_CONFIG_BYTES,
        required=True,
    )
    assert config_payload is not None
    prior_source = _config_value(config_payload, "AIRVPN_PROFILE_SOURCE") or "static"
    if prior_source not in {"static", "api"}:
        raise SetupError("the installed profile source is invalid")
    if prior_source == "api" and operation != "adopt":
        raise SetupError("API mode requires an existing managed profile")
    transaction_operation = "api-update" if prior_source == "api" else operation
    had_pre_managed = (
        secure_metadata(paths.pre_managed, paths.trusted_uid, required=False)
        is not None
    )

    with _effective_credential(
        request,
        supplied,
        paths,
        prior_source,
        allow_matching_supplied=allow_matching_supplied,
    ) as (
        credential,
        key_changed,
        had_key,
    ):
        validate_with_lease(
            paths,
            operation,
            lease_fd,
            credential,
            request.device,
            settings_countries,
            run=run,
        )
        journal = SetupJournal(
            transaction_operation, "prepared", had_key, had_pre_managed, key_changed
        )
        try:
            _persist_journal(paths, journal)
            snapshot_file(
                paths.health_config,
                _extra_path(paths, "config-previous"),
                paths.trusted_uid,
                maximum=MAX_CONFIG_BYTES,
            )
            if key_changed and had_key:
                snapshot_file(
                    paths.credential,
                    _extra_path(paths, "credential-previous"),
                    paths.trusted_uid,
                    maximum=65,
                )
            atomic_write(
                paths.health_config,
                _render_config(
                    config_payload,
                    {
                        "AIRVPN_PROFILE_SOURCE": prior_source,
                        "AIRVPN_DEVICE": request.device,
                        "AIRVPN_COUNTRIES": config_countries,
                    },
                ),
                paths.trusted_uid,
            )
            journal = replace(journal, phase="config")
            _persist_journal(paths, journal)
            if key_changed:
                copy_descriptor_atomic(
                    credential.fd,
                    paths.credential,
                    paths.trusted_uid,
                    expected_size=65,
                )
                journal = replace(journal, phase="credential")
                _persist_journal(paths, journal)
                with _open_installed_credential(paths) as installed:
                    validate_with_lease(
                        paths,
                        operation,
                        lease_fd,
                        installed,
                        request.device,
                        settings_countries,
                        run=run,
                    )
            if prior_source == "static":
                applied = runtime_call(operation, paths, lease_fd, "--apply", run=run)
                if applied.returncode != 0:
                    raise SetupError(
                        "runtime could not activate the validated API setup"
                    )
            journal = replace(journal, phase="activated")
            _persist_journal(paths, journal)
            journal, proof = _begin_journaled_health_proof(paths, journal, now=now)
            verify_health(paths, lease_fd, run=run, now=now, proof=proof)
        except BaseException as error:
            try:
                if _exists(_extra_path(paths, "journal")):
                    _rollback_api(paths, lease_fd, journal, run=run)
                else:
                    _assert_setup_artifacts_clear(paths)
            except SetupError as rollback_error:
                raise SetupError(
                    "setup failed and automatic rollback is incomplete; the timer remains disabled"
                ) from rollback_error
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            if isinstance(error, SetupError):
                raise
            raise SetupError("setup was interrupted and rolled back") from error

    _finalize_verified(paths, journal)
    _run_post_commit_actions(request, paths, lease_fd, run=run)


def _apply_static(
    request: SetupRequest,
    paths: ApplyPathSet,
    lease_fd: int,
    *,
    run: Callable,
    now: Callable[[], int],
) -> None:
    if request.timer == "enable" and request.reset_api_state:
        raise SetupError("API-state reset cannot enable the timer")
    config_payload = secure_read(
        paths.health_config,
        paths.trusted_uid,
        maximum=MAX_CONFIG_BYTES,
        required=True,
    )
    assert config_payload is not None
    operation = "static-restore" if request.restore_pre_managed else "static"
    journal = SetupJournal(
        operation,
        "prepared",
        secure_metadata(paths.credential, paths.trusted_uid, required=False)
        is not None,
        secure_metadata(paths.pre_managed, paths.trusted_uid, required=False)
        is not None,
        False,
    )
    restore_committed = False
    try:
        _persist_journal(paths, journal)
        snapshot_file(
            paths.health_config,
            _extra_path(paths, "config-previous"),
            paths.trusted_uid,
            maximum=MAX_CONFIG_BYTES,
        )
        if request.restore_pre_managed:
            journal = replace(journal, phase="activating")
            _persist_journal(paths, journal)
            restored = runtime_call(
                "restore-static", paths, lease_fd, "--apply", run=run
            )
            if restored.returncode != 0:
                raise SetupError("runtime could not restore the pre-managed profile")
            # restore-static is itself a verified profile/qB transaction. Once it
            # returns success, keeping its exact static result is safer than pairing
            # that profile with a rolled-back API source after a later reporting fault.
            restore_committed = True
        else:
            atomic_write(
                paths.health_config,
                _render_config(config_payload, {"AIRVPN_PROFILE_SOURCE": "static"}),
                paths.trusted_uid,
            )
        journal = replace(journal, phase="activated")
        _persist_journal(paths, journal)
        journal, proof = _begin_journaled_health_proof(paths, journal, now=now)
        verify_health(paths, lease_fd, run=run, now=now, proof=proof)
    except BaseException as error:
        if restore_committed:
            try:
                _cleanup_transaction(paths)
            except SetupError as cleanup_error:
                raise SetupError(
                    "the static profile is committed, but setup finalization is incomplete"
                ) from cleanup_error
            raise SetupError(
                "the restored static profile is committed, but the additional health proof failed"
            ) from error
        try:
            if _exists(_extra_path(paths, "journal")):
                _rollback_static(paths, journal)
            else:
                _assert_setup_artifacts_clear(paths)
        except SetupError as rollback_error:
            raise SetupError(
                "static setup failed and rollback is incomplete; the timer remains disabled"
            ) from rollback_error
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        if isinstance(error, SetupError):
            raise
        raise SetupError("static setup was interrupted and rolled back") from error

    _finalize_verified(paths, journal)
    _run_post_commit_actions(request, paths, lease_fd, run=run)


def _preview_maintenance_under_lease(
    request: SetupRequest,
    paths: ApplyPathSet,
    lease_fd: int,
    *,
    run: Callable,
) -> None:
    if request.restore_pre_managed:
        restored = runtime_call("restore-static", paths, lease_fd, "--dry-run", run=run)
        if restored.returncode != 0:
            raise SetupError("runtime refused the static-restoration dry run")
    if request.reset_api_state:
        reset = runtime_call("reset-api-state", paths, lease_fd, "--dry-run", run=run)
        if reset.returncode != 0:
            raise SetupError("runtime refused the API-state reset dry run")


def preview_maintenance(
    request: SetupRequest,
    *,
    paths: ApplyPathSet | None = None,
    run: Callable = subprocess.run,
) -> None:
    if request.action != "dry-run" or not (
        request.restore_pre_managed or request.reset_api_state
    ):
        raise SetupError("maintenance preview requires an explicit dry-run action")
    paths = paths or LiveApplyPaths.for_interface(request.iface)
    validate_apply_paths(paths, request.iface)
    with exclusive_setup_lease(paths) as lease_fd:
        probe_runtime_lock(paths.interface_lock, paths)
        probe_runtime_lock(paths.global_lock, paths)
        _assert_runtime_artifacts_clear(paths)
        _assert_setup_artifacts_clear(paths)
        _preview_maintenance_under_lease(request, paths, lease_fd, run=run)


def preview_api_state_reset(
    request: SetupRequest,
    *,
    paths: ApplyPathSet | None = None,
    run: Callable = subprocess.run,
) -> None:
    """Compatibility wrapper for the public reset dry-run seam."""

    if not request.reset_api_state:
        raise SetupError("API-state preview requires an explicit reset dry run")
    preview_maintenance(request, paths=paths, run=run)


def preview_api_request(
    request: SetupRequest,
    credential: PrivateHandle | None,
    *,
    paths: ApplyPathSet | None = None,
    run: Callable = subprocess.run,
) -> None:
    if request.mode != "api" or request.action != "dry-run":
        raise SetupError("API preview requires explicit API dry-run mode")
    if not request.device or not _DEVICE.fullmatch(request.device):
        raise SetupError("API setup requires a valid device")
    settings_countries, _ = _country_values(request)
    paths = paths or LiveApplyPaths.for_interface(request.iface)
    validate_apply_paths(paths, request.iface)
    operation = (
        "adopt"
        if secure_metadata(paths.profile, paths.trusted_uid, required=False) is not None
        else "provision"
    )
    prior_source = _installed_profile_source(paths)
    with exclusive_setup_lease(paths) as lease_fd:
        _assert_runtime_artifacts_clear(paths)
        _assert_setup_artifacts_clear(paths)
        with _effective_credential(request, credential, paths, prior_source) as (
            effective,
            _,
            _,
        ):
            validate_with_lease(
                paths,
                operation,
                lease_fd,
                effective,
                request.device,
                settings_countries,
                run=run,
            )
        _preview_maintenance_under_lease(request, paths, lease_fd, run=run)


def apply_setup_request(
    request: SetupRequest,
    credential: PrivateHandle | None,
    *,
    paths: ApplyPathSet | None = None,
    run: Callable = subprocess.run,
    now: Callable[[], int] = lambda: int(time.time()),
) -> None:
    """Apply one request under an exclusive lease and recover prior setup crashes."""

    if request.action != "apply" or request.mode not in {"static", "api"}:
        raise SetupError("transactional application requires an explicit apply mode")
    if request.mode == "static" and credential is not None:
        raise SetupError("static setup must not receive or open a credential")
    paths = paths or LiveApplyPaths.for_interface(request.iface)
    validate_apply_paths(paths, request.iface)

    # Reject ordinary descriptor-selection mistakes before persistent unit-state
    # changes. An interrupted transaction is recovered first because it may remove
    # an uncommitted installed key and turn the same proposal into a valid retry.
    recovering = _exists(_extra_path(paths, "journal"))
    if request.mode == "api" and not recovering:
        _precheck_api_credential(request, credential, paths)

    with exclusive_setup_lease(paths) as lease_fd:
        stop_units(paths, run=run)
        probe_runtime_lock(paths.interface_lock, paths)
        probe_runtime_lock(paths.global_lock, paths)
        _recover_setup_transaction(paths, lease_fd, run=run, now=now)
        _assert_runtime_artifacts_clear(paths)
        _assert_setup_artifacts_clear(paths)
        if request.mode == "api":
            _precheck_api_credential(
                request,
                credential,
                paths,
                allow_matching_supplied=recovering,
            )
            _apply_api(
                request,
                credential,
                paths,
                lease_fd,
                run=run,
                now=now,
                allow_matching_supplied=recovering,
            )
        else:
            _apply_static(request, paths, lease_fd, run=run, now=now)
