import contextlib
import fcntl
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

from tests.setup_apply_support import (
    BlockingSharedLeaseProbe,
    FixedCommandDouble,
    _make_paths,
    _request,
    _snapshot,
    _write_private,
    setup,
)


class SetupApplyTests(unittest.TestCase):
    NOW = 2_000_000_000
    ORIGINAL_CONFIG = (
        b"# operator comment\n"
        b"MAX_AGE=222\n"
        b'REQUIRED_ROUTE="default dev wg0"\n'
        b"AIRVPN_PROFILE_SOURCE=static\n"
        b'AIRVPN_DEVICE="Installed Device"\n'
        b"AIRVPN_COUNTRIES=SE\n"
    )
    OLD_CREDENTIAL = b"0" * 64 + b"\n"
    PROPOSED_CREDENTIAL = b"1" * 64 + b"\n"
    PROFILE = b"existing-profile-unit-test-sentinel\n"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.paths = _make_paths(Path(self.temporary.name))
        _write_private(self.paths.health_config, self.ORIGINAL_CONFIG)
        self.runner = FixedCommandDouble(self, self.paths, self.NOW)

    @contextlib.contextmanager
    def proposed_credential(self):
        source = Path(self.temporary.name) / "proposed-credential"
        _write_private(source, self.PROPOSED_CREDENTIAL)
        fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with setup.PrivateHandle(fd) as handle:
            yield handle

    def apply(self, request, credential=None):
        apply_function = getattr(setup, "apply_setup_request", None)
        self.assertIsNotNone(
            apply_function,
            "Task 10 requires apply_setup_request(request, credential, *, paths, run, now)",
        )
        return apply_function(
            request,
            credential,
            paths=self.paths,
            run=self.runner,
            now=lambda: self.NOW,
        )

    def assert_timer_disabled(self):
        self.assertFalse(self.runner.timer_active)
        self.assertNotIn(
            (self.runner.systemctl, "enable", "--now", self.paths.timer_unit),
            self.runner.events,
        )

    def test_quiescence_stop_failure_refuses_before_any_persistence(self):
        _write_private(self.paths.profile, self.PROFILE)
        before = _snapshot(self.paths)
        self.runner.fail_stop_unit = self.paths.service_unit

        with self.proposed_credential() as credential:
            with self.assertRaises(setup.SetupError):
                self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assertFalse(self.paths.credential.exists())
        self.assertFalse(
            any(
                event[0:2] == (self.runner.runtime, "adopt") and "--apply" in event
                for event in self.runner.events
            )
        )

    def test_exclusive_setup_lease_precedes_lock_probe_and_persistence(self):
        _write_private(self.paths.setup_guard, b"")
        _write_private(self.paths.interface_lock, b"")
        before = _snapshot(self.paths)
        held_fd = os.open(self.paths.interface_lock, os.O_RDWR | os.O_CLOEXEC)
        real_flock = fcntl.flock
        real_flock(held_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquisition_order: list[str] = []

        def descriptor_name(fd: int) -> str:
            metadata = os.fstat(fd)
            for name, path in (
                ("setup-guard", self.paths.setup_guard),
                ("interface-lock", self.paths.interface_lock),
                ("global-lock", self.paths.global_lock),
            ):
                if not path.exists():
                    continue
                expected = os.stat(path, follow_symlinks=False)
                if (metadata.st_dev, metadata.st_ino) == (
                    expected.st_dev,
                    expected.st_ino,
                ):
                    return name
            return "other"

        def recording_flock(fd: int, operation: int):
            name = descriptor_name(fd)
            if operation & fcntl.LOCK_EX:
                acquisition_order.append(name)
            if name == "interface-lock" and operation & fcntl.LOCK_EX:
                competing_fd = os.open(
                    self.paths.setup_guard,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                )
                try:
                    try:
                        real_flock(competing_fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except BlockingIOError:
                        pass
                    else:
                        real_flock(competing_fd, fcntl.LOCK_UN)
                        self.fail(
                            "interface lock was probed before the exclusive setup lease"
                        )
                finally:
                    os.close(competing_fd)
            return real_flock(fd, operation)

        flock_module = getattr(setup, "fcntl", fcntl)
        try:
            with mock.patch.object(flock_module, "flock", side_effect=recording_flock):
                with self.assertRaises(setup.SetupError):
                    self.apply(_request(mode="static"))
        finally:
            real_flock(held_fd, fcntl.LOCK_UN)
            os.close(held_fd)

        self.assertEqual(acquisition_order[:2], ["setup-guard", "interface-lock"])
        self.assertEqual(_snapshot(self.paths), before)

    def test_held_interface_or_global_lock_refuses_without_mutation(self):
        _write_private(self.paths.profile, self.PROFILE)
        for lock_path in (self.paths.interface_lock, self.paths.global_lock):
            with self.subTest(lock=lock_path.name):
                _write_private(lock_path, b"")
                before = _snapshot(self.paths)
                lock_fd = os.open(lock_path, os.O_RDWR | os.O_CLOEXEC)
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with self.proposed_credential() as credential:
                        with self.assertRaises(setup.SetupError):
                            self.apply(_request(mode="api"), credential)
                finally:
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
                    os.close(lock_fd)
                self.assertEqual(_snapshot(self.paths), before)
                lock_path.unlink()
                self.runner = FixedCommandDouble(self, self.paths, self.NOW)

    def test_recovery_artifacts_refuse_apply_without_cleanup_or_mutation(self):
        _write_private(self.paths.profile, self.PROFILE)
        for artifact in (self.paths.pending, self.paths.safety, self.paths.candidate):
            with self.subTest(artifact=artifact.name):
                _write_private(artifact, b"recovery-artifact-unit-test-sentinel\n")
                before = _snapshot(self.paths)

                with self.assertRaises(setup.SetupError):
                    self.apply(_request(mode="static"))

                self.assertEqual(_snapshot(self.paths), before)
                artifact.unlink()
                self.runner = FixedCommandDouble(self, self.paths, self.NOW)

    def test_authenticated_validation_failure_follows_quiescence_but_precedes_persistence(
        self,
    ):
        before = _snapshot(self.paths)
        self.runner.fail_first_validation = True

        with self.proposed_credential() as credential:
            with self.assertRaises(setup.SetupError):
                self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assertFalse(self.paths.credential.exists())
        self.assertFalse(self.runner.timer_active)
        self.assertFalse(self.runner.worker_active)
        self.assertFalse(
            any(
                event[0:2]
                in {
                    (self.runner.runtime, "provision"),
                    (self.runner.runtime, "adopt"),
                }
                and "--apply" in event
                for event in self.runner.events
            ),
            "a rejected proposal must not reach runtime apply",
        )

    def test_failed_adoption_restores_exact_config_credential_and_snapshot_state(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        before = _snapshot(self.paths)
        self.runner.fail_runtime_apply = True
        self.runner.create_snapshot_before_apply_failure = True
        self.runner.credential_before_validation = self.OLD_CREDENTIAL
        probe = BlockingSharedLeaseProbe(
            self.paths.setup_guard, lambda: _snapshot(self.paths)
        )

        def phase_hook(phase: str) -> None:
            if phase == "runtime-apply-failure":
                probe.start_and_assert_blocked(self, "runtime apply rollback")

        self.runner.phase_hook = phase_hook

        with self.proposed_credential() as credential:
            with self.assertRaises(setup.SetupError):
                self.apply(_request(mode="api", replace_credential=True), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assertEqual(probe.finish(self), before)
        self.assert_timer_disabled()

    def test_success_preserves_unrelated_health_configuration(self):
        _write_private(self.paths.profile, self.PROFILE)

        with self.proposed_credential() as credential:
            self.apply(_request(mode="api"), credential)

        rendered = self.paths.health_config.read_text(encoding="ascii")
        self.assertIn("# operator comment\n", rendered)
        self.assertIn("MAX_AGE=222\n", rendered)
        self.assertIn('REQUIRED_ROUTE="default dev wg0"\n', rendered)
        self.assertIn("AIRVPN_PROFILE_SOURCE=api\n", rendered)
        self.assertIn('AIRVPN_DEVICE="Proposed Device"\n', rendered)
        self.assertIn('AIRVPN_COUNTRIES="GB NL"\n', rendered)
        self.assertEqual(stat.S_IMODE(self.paths.health_config.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.paths.credential.stat().st_mode), 0o600)
        self.assert_timer_disabled()

    def test_runtime_children_inherit_only_their_declared_private_descriptors(self):
        _write_private(self.paths.profile, self.PROFILE)

        with self.proposed_credential() as credential:
            self.apply(_request(mode="api"), credential)

        self.assertEqual(
            self.runner.runtime_fd_contracts[0],
            ("adopt", "dry-run", 3),
        )
        self.assertIn(("adopt", "apply", 1), self.runner.runtime_fd_contracts)
        self.assertIn(("check", "check", 1), self.runner.runtime_fd_contracts)

    def test_static_credential_removal_never_opens_key_and_syncs_directory(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        opened_credential = []
        synced_directory = []
        real_open = setup.os.open
        real_fsync = setup.os.fsync

        def recording_open(path, flags, *args, **kwargs):
            try:
                candidate = Path(path)
            except TypeError:
                candidate = None
            if candidate == self.paths.credential:
                opened_credential.append(candidate)
            return real_open(path, flags, *args, **kwargs)

        def recording_fsync(fd):
            metadata = os.fstat(fd)
            health_metadata = os.stat(self.paths.health_dir)
            if (
                stat.S_ISDIR(metadata.st_mode)
                and (metadata.st_dev, metadata.st_ino)
                == (health_metadata.st_dev, health_metadata.st_ino)
                and not self.paths.credential.exists()
            ):
                synced_directory.append(fd)
            return real_fsync(fd)

        with (
            mock.patch.object(setup.os, "open", side_effect=recording_open),
            mock.patch.object(setup.os, "fsync", side_effect=recording_fsync),
        ):
            self.apply(_request(mode="static", remove_credential=True))

        self.assertFalse(self.paths.credential.exists())
        self.assertEqual(opened_credential, [])
        self.assertTrue(synced_directory, "credential removal must sync its directory")
        self.assert_timer_disabled()

    def test_combined_static_reset_purge_preserves_pre_managed_snapshot(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.pre_managed, b"pre-managed-unit-test-sentinel\n")
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        _write_private(self.paths.api_state, b"api-state-unit-test-sentinel\n")
        expected_snapshot = self.paths.pre_managed.read_bytes()

        self.apply(
            _request(mode="static", remove_credential=True, reset_api_state=True)
        )

        self.assertFalse(self.paths.credential.exists())
        self.assertFalse(self.paths.api_state.exists())
        self.assertEqual(self.paths.pre_managed.read_bytes(), expected_snapshot)
        self.assertTrue(
            any(
                event[:4] == (self.runner.runtime, "reset-api-state", "wg0", "--apply")
                and "--setup-lease-fd" in event
                for event in self.runner.events
            )
        )
        self.assert_timer_disabled()

    def test_stale_success_status_never_enables_timer(self):
        _write_private(
            self.paths.status,
            (f"outcome=healthy\nreason=old-run\ntimestamp={self.NOW - 1}\n").encode(
                "ascii"
            ),
        )
        self.runner.status_outcome = None

        with self.assertRaises(setup.SetupError):
            self.apply(_request(mode="static", timer="enable"))

        self.assert_timer_disabled()

    def test_fresh_recovered_status_precedes_timer_enable(self):
        _write_private(
            self.paths.status,
            (f"outcome=healthy\nreason=old-run\ntimestamp={self.NOW - 1}\n").encode(
                "ascii"
            ),
        )
        stale_inode = self.paths.status.stat().st_ino
        self.runner.status_outcome = "recovered"
        self.runner.status_timestamp = self.NOW
        probe = BlockingSharedLeaseProbe(
            self.paths.setup_guard, lambda: tuple(self.runner.events)
        )

        def phase_hook(phase: str) -> None:
            if phase == "verification-start":
                probe.start_and_assert_blocked(self, "fresh health verification")
            elif phase == "timer-enable":
                probe.assert_still_blocked(self, "timer enable decision")

        self.runner.phase_hook = phase_hook

        self.apply(_request(mode="static", timer="enable"))

        checks = [
            event
            for event in self.runner.events
            if event[0:2] == (self.runner.runtime, "check")
        ]
        enable = (
            self.runner.systemctl,
            "enable",
            "--now",
            self.paths.timer_unit,
        )
        self.assertEqual(len(checks), 1)
        self.assertIn(enable, self.runner.events)
        self.assertLess(
            self.runner.events.index(checks[0]), self.runner.events.index(enable)
        )
        self.assertNotEqual(self.paths.status.stat().st_ino, stale_inode)
        self.assertIn(enable, probe.finish(self))
        self.assertTrue(self.runner.timer_active)

    def test_timer_enable_failure_keeps_freshly_verified_api_commit(self):
        _write_private(self.paths.profile, self.PROFILE)
        self.runner.fail_enable = True

        with self.proposed_credential() as credential:
            with self.assertRaises(setup.SetupError):
                self.apply(_request(mode="api", timer="enable"), credential)

        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assertEqual(self.paths.credential.read_bytes(), self.PROPOSED_CREDENTIAL)
        self.assertEqual(self.paths.pre_managed.read_bytes(), self.PROFILE)
        enable = (
            self.runner.systemctl,
            "enable",
            "--now",
            self.paths.timer_unit,
        )
        disable = (
            self.runner.systemctl,
            "disable",
            "--now",
            self.paths.timer_unit,
        )
        enable_index = self.runner.events.index(enable)
        self.assertTrue(
            any(
                event == disable and index > enable_index
                for index, event in enumerate(self.runner.events)
            ),
            "failed timer enable must be followed by a fail-closed disable",
        )
        check_index = next(
            index
            for index, event in enumerate(self.runner.events)
            if event[0:2] == (self.runner.runtime, "check")
        )
        self.assertLess(check_index, enable_index)
        self.assertFalse(self.runner.timer_active)

    def test_first_provision_failure_retains_only_inert_static_profile_then_retries_as_adopt(
        self,
    ):
        before_config = self.paths.health_config.read_bytes()
        self.runner.fail_runtime_apply = True
        self.runner.install_profile_before_apply_failure = True

        with self.proposed_credential() as credential:
            with self.assertRaises(setup.SetupError):
                self.apply(_request(mode="api"), credential)

        self.assertEqual(self.paths.health_config.read_bytes(), before_config)
        self.assertFalse(self.paths.credential.exists())
        self.assertTrue(self.paths.profile.is_file())
        self.assertEqual(stat.S_IMODE(self.paths.profile.stat().st_mode), 0o600)
        for artifact in (self.paths.pending, self.paths.safety, self.paths.candidate):
            self.assertFalse(artifact.exists())
        self.assert_timer_disabled()

        self.runner = FixedCommandDouble(self, self.paths, self.NOW)
        with self.proposed_credential() as credential:
            self.apply(_request(mode="api"), credential)

        self.assertTrue(
            any(
                event[0:2] == (self.runner.runtime, "adopt") and "--dry-run" in event
                for event in self.runner.events
            )
        )
        self.assertTrue(
            any(
                event[0:2] == (self.runner.runtime, "adopt") and "--apply" in event
                for event in self.runner.events
            )
        )
        self.assertEqual(
            self.paths.pre_managed.read_bytes(), self.paths.profile.read_bytes()
        )


if __name__ == "__main__":
    unittest.main()
