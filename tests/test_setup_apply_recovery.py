from unittest import mock

from tests.setup_apply_support import (
    ApplyFixture,
    _replace_config_value,
    _request,
    _snapshot,
    _write_private,
    setup,
)


class SetupApplyRecoveryTests(ApplyFixture):
    def test_apply_discards_abandoned_fixed_staging_before_new_transaction(self):
        journal, _config_previous, _credential_previous = self.setup_artifacts()
        staged = (
            setup.store.private_staging_path(journal),
            setup.store.private_staging_path(self.paths.health_config),
            setup.store.private_staging_path(self.paths.credential),
        )
        for path in staged:
            _write_private(path, b"crashed-private-staging-sentinel\n")

        self.apply(_request(mode="static"))

        self.assert_no_setup_artifacts()
        self.assertTrue(all(not path.exists() for path in staged))

    def test_failed_fixed_staging_cleanup_retains_secret_and_disables_timer(self):
        staging = setup.store.private_staging_path(self.paths.credential)
        _write_private(staging, b"crashed-credential-secret-sentinel\n")
        real_discard = setup.application.discard_private_staging

        def fail_credential_cleanup(target, trusted_uid):
            if target == self.paths.credential:
                raise setup.SetupError("injected private staging cleanup failure")
            return real_discard(target, trusted_uid)

        with (
            mock.patch.object(
                setup.application,
                "discard_private_staging",
                side_effect=fail_credential_cleanup,
            ),
            self.assertRaisesRegex(setup.SetupError, "staging cleanup failure"),
        ):
            self.apply(_request(mode="static"))

        self.assertEqual(staging.read_bytes(), b"crashed-credential-secret-sentinel\n")
        self.assert_timer_disabled()

    def test_orphaned_snapshot_staging_without_journal_refuses_setup(self):
        _journal, config_previous, _credential_previous = self.setup_artifacts()
        staging = setup.store.snapshot_staging_path(config_previous)
        _write_private(staging, b"unowned-partial-snapshot\n")

        with self.assertRaisesRegex(setup.SetupError, "requires recovery"):
            self.apply(_request(mode="static"))

        self.assertTrue(staging.exists())
        self.assert_timer_disabled()

    def test_prepared_journal_discards_unpublished_snapshot_staging(self):
        journal, config_previous, _credential_previous = self.setup_artifacts()
        staging = setup.store.snapshot_staging_path(config_previous)
        _write_private(staging, b"unpublished-partial-snapshot\n")
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=provision\n"
                b"phase=prepared\n"
                b"had_key=0\n"
                b"had_pre_managed=0\n"
                b"key_changed=1\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )

        self.apply(_request(mode="static"))

        self.assertFalse(staging.exists() or staging.is_symlink())
        self.assert_no_setup_artifacts()

    def test_prepared_journal_is_removed_when_config_snapshot_fails(self):
        before = _snapshot(self.paths)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application,
                "snapshot_file",
                side_effect=setup.SetupError("injected config snapshot failure"),
            ):
                with self.assertRaises(setup.SetupError):
                    self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assert_no_setup_artifacts()

    def test_partial_snapshots_are_removed_when_credential_snapshot_fails(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        before = _snapshot(self.paths)
        self.runner.credential_before_validation = self.OLD_CREDENTIAL
        real_snapshot = setup.application.snapshot_file

        def fail_credential_snapshot(source, backup, trusted_uid, *, maximum):
            if source == self.paths.credential:
                raise setup.SetupError("injected credential snapshot failure")
            return real_snapshot(source, backup, trusted_uid, maximum=maximum)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application,
                "snapshot_file",
                side_effect=fail_credential_snapshot,
            ):
                with self.assertRaises(setup.SetupError):
                    self.apply(
                        _request(mode="api", replace_credential=True), credential
                    )

        self.assertEqual(_snapshot(self.paths), before)
        self.assert_no_setup_artifacts()

    def test_snapshots_and_journal_are_removed_when_config_commit_fails(self):
        _write_private(self.paths.profile, self.PROFILE)
        before = _snapshot(self.paths)
        real_atomic_write = setup.application.atomic_write

        def fail_config_write(path, payload, trusted_uid):
            if path == self.paths.health_config:
                raise setup.SetupError("injected config commit failure")
            return real_atomic_write(path, payload, trusted_uid)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application, "atomic_write", side_effect=fail_config_write
            ):
                with self.assertRaises(setup.SetupError):
                    self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assert_no_setup_artifacts()

    def test_config_is_restored_when_config_phase_journal_commit_fails(self):
        _write_private(self.paths.profile, self.PROFILE)
        before = _snapshot(self.paths)
        real_write_journal = setup.application._write_journal

        def fail_config_phase(*args, **kwargs):
            if kwargs.get("phase") == "config":
                raise setup.SetupError("injected phase journal failure")
            return real_write_journal(*args, **kwargs)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application, "_write_journal", side_effect=fail_config_phase
            ):
                with self.assertRaises(setup.SetupError):
                    self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assert_no_setup_artifacts()

    def test_interrupted_first_provision_recovers_inert_profile_then_adopts(self):
        journal, config_previous, _credential_previous = self.setup_artifacts()
        generated_profile = b"generated-profile-after-crash-unit-test-sentinel\n"
        _write_private(config_previous, self.ORIGINAL_CONFIG)
        _replace_config_value(self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "api")
        _replace_config_value(
            self.paths.health_config, "AIRVPN_DEVICE", "Proposed Device"
        )
        _replace_config_value(self.paths.health_config, "AIRVPN_COUNTRIES", "GB NL")
        _write_private(self.paths.credential, self.PROPOSED_CREDENTIAL)
        _write_private(self.paths.profile, generated_profile)
        _write_private(
            journal,
            (
                b"version=1\n"
                b"operation=provision\n"
                b"phase=activated\n"
                b"had_key=0\n"
                b"had_pre_managed=0\n"
            ),
        )

        try:
            with self.proposed_credential() as credential:
                self.apply(_request(mode="api"), credential)
        except Exception as error:
            self.fail(f"interrupted first provision was not recovered: {error}")

        self.assertEqual(self.paths.profile.read_bytes(), generated_profile)
        self.assertEqual(self.paths.pre_managed.read_bytes(), generated_profile)
        self.assertEqual(self.paths.credential.read_bytes(), self.PROPOSED_CREDENTIAL)
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assertTrue(
            any(
                event[0:2] == (self.runner.runtime, "adopt") and "--apply" in event
                for event in self.runner.events
            )
        )
        self.assert_no_setup_artifacts()

    def test_interrupted_first_provision_cleans_lone_candidate_then_adopts(self):
        journal, config_previous, _credential_previous = self.setup_artifacts()
        generated_profile = b"generated-profile-after-crash-unit-test-sentinel\n"
        _write_private(config_previous, self.ORIGINAL_CONFIG)
        _replace_config_value(
            self.paths.health_config, "AIRVPN_DEVICE", "Proposed Device"
        )
        _replace_config_value(self.paths.health_config, "AIRVPN_COUNTRIES", "GB NL")
        _write_private(self.paths.credential, self.PROPOSED_CREDENTIAL)
        _write_private(self.paths.profile, generated_profile)
        _write_private(self.paths.candidate, generated_profile)
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=provision\n"
                b"phase=credential\n"
                b"had_key=0\n"
                b"had_pre_managed=0\n"
                b"key_changed=1\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )

        with self.proposed_credential() as credential:
            self.apply(_request(mode="api"), credential)

        cleanup = next(
            event
            for event in self.runner.events
            if event[0:2] == (self.runner.runtime, "cleanup-candidate")
        )
        adopt_apply = next(
            event
            for event in self.runner.events
            if event[0:2] == (self.runner.runtime, "adopt") and "--apply" in event
        )
        self.assertLess(
            self.runner.events.index(cleanup), self.runner.events.index(adopt_apply)
        )
        self.assertFalse(
            self.paths.candidate.exists() or self.paths.candidate.is_symlink()
        )
        self.assertEqual(self.paths.profile.read_bytes(), generated_profile)
        self.assertEqual(self.paths.pre_managed.read_bytes(), generated_profile)
        self.assert_no_setup_artifacts()

    def test_failed_lone_candidate_cleanup_retains_all_recovery_evidence(self):
        journal, config_previous, _credential_previous = self.setup_artifacts()
        _write_private(config_previous, self.ORIGINAL_CONFIG)
        _write_private(self.paths.candidate, b"candidate-unit-test-sentinel\n")
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=provision\n"
                b"phase=prepared\n"
                b"had_key=0\n"
                b"had_pre_managed=0\n"
                b"key_changed=1\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )
        self.runner.fail_candidate_cleanup = True

        with self.assertRaisesRegex(setup.SetupError, "profile candidate"):
            self.apply(_request(mode="static"))

        self.assertTrue(journal.exists())
        self.assertTrue(config_previous.exists())
        self.assertTrue(self.paths.candidate.exists())
        self.assert_timer_disabled()

    def test_successful_runtime_restore_is_the_static_profile_commit_point(self):
        self.install_active_api_fixture()
        before = _snapshot(self.paths)
        self.runner.status_outcome = "failed"

        with self.assertRaises(setup.SetupError):
            self.apply(_request(mode="static", restore_pre_managed=True))

        self.assertEqual(self.paths.profile.read_bytes(), before["pre_managed"][1])
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=static\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assertEqual(self.paths.credential.read_bytes(), before["credential"][1])
        self.assert_no_setup_artifacts()
        self.assert_timer_disabled()

    def test_fresh_health_proof_recovers_a_failed_verified_journal_write(self):
        _write_private(self.paths.profile, self.PROFILE)
        real_write_journal = setup.application._write_journal

        def fail_verified_phase(*args, **kwargs):
            if kwargs.get("phase") == "verified":
                raise setup.SetupError("injected verified journal failure")
            return real_write_journal(*args, **kwargs)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application,
                "_write_journal",
                side_effect=fail_verified_phase,
            ):
                with self.assertRaisesRegex(setup.SetupError, "committed"):
                    self.apply(_request(mode="api"), credential)

        journal, _config_previous, _credential_previous = self.setup_artifacts()
        self.assertIn(b"phase=verifying\n", journal.read_bytes())
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )

        self.runner = type(self.runner)(self, self.paths, self.NOW)
        self.runner.credential_before_validation = self.PROPOSED_CREDENTIAL
        self.apply(_request(mode="api"), None)

        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assert_no_setup_artifacts()
        self.assertFalse(
            any(
                event[0:2] == (self.runner.runtime, "restore-static")
                and "--apply" in event
                for event in self.runner.events
            )
        )

    def test_activated_v3_recovery_persists_proof_before_health_check(self):
        self.install_active_api_fixture()
        journal, config_previous, _credential_previous = self.setup_artifacts()
        _write_private(config_previous, self.paths.health_config.read_bytes())
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=api-update\n"
                b"phase=activated\n"
                b"had_key=1\n"
                b"had_pre_managed=1\n"
                b"key_changed=0\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )
        journal_at_check = []

        def capture_first_check(phase):
            if phase == "verification-start" and not journal_at_check:
                journal_at_check.append(journal.read_bytes())

        self.runner.phase_hook = capture_first_check
        self.apply(_request(mode="static"))

        self.assertEqual(len(journal_at_check), 1)
        self.assertIn(b"phase=verifying\n", journal_at_check[0])
        self.assertIn(f"verify_started={self.NOW}\n".encode(), journal_at_check[0])
        self.assert_no_setup_artifacts()

    def test_rolled_back_v3_record_clears_abandoned_health_proof(self):
        _write_private(self.paths.profile, self.PROFILE)
        self.runner.status_outcome = "failed"
        journal, config_previous, _credential_previous = self.setup_artifacts()
        real_unlink = setup.application.durable_unlink
        injected = False

        def fail_after_config_cleanup(path, trusted_uid, *, required=False):
            nonlocal injected
            if path == config_previous and not injected:
                injected = True
                real_unlink(path, trusted_uid, required=required)
                raise setup.SetupError("injected rollback-cleanup crash")
            return real_unlink(path, trusted_uid, required=required)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application,
                "durable_unlink",
                side_effect=fail_after_config_cleanup,
            ):
                with self.assertRaisesRegex(setup.SetupError, "rollback is incomplete"):
                    self.apply(_request(mode="api"), credential)

        payload = journal.read_bytes()
        self.assertIn(b"phase=rolled-back\n", payload)
        self.assertIn(b"verify_started=0\n", payload)
        self.assertIn(b"status_before_dev=0\n", payload)
        self.assertIn(b"status_before_ino=0\n", payload)

    def test_interrupted_successful_static_restore_recovers_as_static(self):
        self.install_active_api_fixture()
        journal, config_previous, _credential_previous = self.setup_artifacts()
        _write_private(config_previous, self.paths.health_config.read_bytes())
        _write_private(self.paths.profile, self.paths.pre_managed.read_bytes())
        _replace_config_value(
            self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "static"
        )
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=static-restore\n"
                b"phase=activating\n"
                b"had_key=1\n"
                b"had_pre_managed=1\n"
                b"key_changed=0\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )

        self.apply(_request(mode="static"))

        self.assertEqual(
            self.paths.profile.read_bytes(), self.paths.pre_managed.read_bytes()
        )
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=static\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assert_no_setup_artifacts()

    def test_rollback_cleanup_crash_resumes_from_durable_phase(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        before = _snapshot(self.paths)
        self.runner.fail_runtime_apply = True
        self.runner.create_snapshot_before_apply_failure = True
        self.runner.credential_before_validation = self.OLD_CREDENTIAL
        journal, config_previous, credential_previous = self.setup_artifacts()
        real_unlink = setup.application.durable_unlink
        injected = False

        def fail_after_first_cleanup(path, trusted_uid, *, required=False):
            nonlocal injected
            if path == config_previous and not injected:
                injected = True
                real_unlink(path, trusted_uid, required=required)
                raise setup.SetupError("injected rollback-cleanup crash")
            return real_unlink(path, trusted_uid, required=required)

        with self.proposed_credential() as credential:
            with mock.patch.object(
                setup.application,
                "durable_unlink",
                side_effect=fail_after_first_cleanup,
            ):
                with self.assertRaisesRegex(setup.SetupError, "rollback is incomplete"):
                    self.apply(
                        _request(mode="api", replace_credential=True), credential
                    )

        self.assertTrue(journal.exists())
        self.assertIn(b"phase=rolled-back\n", journal.read_bytes())
        self.assertFalse(config_previous.exists())
        self.assertTrue(credential_previous.exists())
        self.assertEqual(_snapshot(self.paths), before)

        self.runner = type(self.runner)(self, self.paths, self.NOW)
        self.apply(_request(mode="static"))

        self.assertEqual(_snapshot(self.paths), before)
        self.assert_no_setup_artifacts()


if __name__ == "__main__":
    import unittest

    unittest.main()
