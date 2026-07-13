from unittest import mock

from tests.setup_apply_support import (
    ApplyFixture,
    _replace_config_value,
    _request,
    _snapshot,
    _write_private,
    setup,
)


class SetupApplyMaintenanceTests(ApplyFixture):
    def run_static_dry_run(self, request):
        setup.preview_maintenance(request, paths=self.paths, run=self.runner)
        return self.runner.events

    def test_reset_api_state_dry_run_routes_to_runtime_owner(self):
        calls = self.run_static_dry_run(
            _request(mode="static", action="dry-run", reset_api_state=True)
        )

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0][:4],
            (setup.RUNTIME, "reset-api-state", "wg0", "--dry-run"),
        )
        self.assertIn("--setup-lease-fd", calls[0])

    def test_restore_pre_managed_dry_run_routes_to_runtime_owner(self):
        calls = self.run_static_dry_run(
            _request(mode="static", action="dry-run", restore_pre_managed=True)
        )

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0][:4],
            (setup.RUNTIME, "restore-static", "wg0", "--dry-run"),
        )
        self.assertIn("--setup-lease-fd", calls[0])

    def test_reset_is_an_explicit_post_health_commit(self):
        self.install_active_api_fixture()
        _write_private(self.paths.api_state, b"api-state-unit-test-sentinel\n")

        self.apply(_request(mode="static", reset_api_state=True))

        check_index = next(
            index
            for index, event in enumerate(self.runner.events)
            if event[0:2] == (self.runner.runtime, "check")
        )
        reset = next(
            event
            for event in self.runner.events
            if event[0:2] == (self.runner.runtime, "reset-api-state")
        )
        reset_index = self.runner.events.index(reset)
        self.assertLess(check_index, reset_index)
        self.assertFalse(self.paths.api_state.exists())
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=static\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )

    def test_failed_post_health_reset_keeps_verified_static_commit(self):
        self.install_active_api_fixture()
        _write_private(self.paths.api_state, b"api-state-unit-test-sentinel\n")
        self.runner.fail_reset = True

        with self.assertRaises(setup.SetupError):
            self.apply(_request(mode="static", reset_api_state=True))

        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=static\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assertTrue(self.paths.api_state.exists())
        check_events = [
            event
            for event in self.runner.events
            if event[0:2] == (self.runner.runtime, "check")
        ]
        self.assertEqual(len(check_events), 1)
        reset = next(
            event
            for event in self.runner.events
            if event[0:2] == (self.runner.runtime, "reset-api-state")
        )
        self.assertLess(
            self.runner.events.index(check_events[0]), self.runner.events.index(reset)
        )
        self.assert_no_setup_artifacts()
        self.assert_timer_disabled()

    def test_api_mode_reset_is_not_accepted_then_ignored(self):
        self.install_active_api_fixture()
        _write_private(self.paths.api_state, b"api-state-unit-test-sentinel\n")

        try:
            self.apply(_request(mode="api", reset_api_state=True), None)
        except Exception as error:
            self.fail(f"active API reuse/reset did not complete: {error}")

        self.assertFalse(self.paths.api_state.exists())
        self.assertTrue(
            any(
                event[0:2] == (self.runner.runtime, "reset-api-state")
                and "--apply" in event
                for event in self.runner.events
            )
        )

    def test_active_api_without_replace_reuses_installed_credential(self):
        self.install_active_api_fixture()

        try:
            self.apply(_request(mode="api"), None)
        except Exception as error:
            self.fail(f"active API setup did not reuse its installed key: {error}")

        self.assertEqual(self.paths.credential.read_bytes(), self.OLD_CREDENTIAL)
        self.assertFalse(
            any(
                event[0:2] == (self.runner.runtime, "adopt") and "--apply" in event
                for event in self.runner.events
            ),
            "active API settings/key validation must never call adopt --apply",
        )
        rendered = self.paths.health_config.read_text(encoding="ascii")
        self.assertIn("AIRVPN_PROFILE_SOURCE=api\n", rendered)
        self.assertIn('AIRVPN_DEVICE="Proposed Device"\n', rendered)
        self.assertIn('AIRVPN_COUNTRIES="GB NL"\n', rendered)

    def test_static_entry_requires_proposal_and_reuses_only_an_exact_retained_key(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)

        self.assertTrue(
            setup.api_requires_proposed_credential(
                _request(mode="api"), paths=self.paths
            )
        )
        self.runner.credential_before_validation = self.OLD_CREDENTIAL
        with self.proposed_credential(self.OLD_CREDENTIAL) as credential:
            self.apply(_request(mode="api"), credential)

        self.assertEqual(self.paths.credential.read_bytes(), self.OLD_CREDENTIAL)
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )

    def test_static_entry_rejects_a_different_retained_key_without_replace(self):
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        before = _snapshot(self.paths)

        with self.proposed_credential() as credential:
            with self.assertRaisesRegex(setup.SetupError, "differs from the retained"):
                self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assert_timer_disabled()

    def test_interrupted_first_provision_requires_a_new_proposal_before_recovery(self):
        journal, config_previous, _credential_previous = self.setup_artifacts()
        _write_private(config_previous, self.ORIGINAL_CONFIG)
        _write_private(self.paths.credential, self.PROPOSED_CREDENTIAL)
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

        self.assertTrue(
            setup.api_requires_proposed_credential(
                _request(mode="api"), paths=self.paths
            )
        )

    def test_interrupted_static_change_from_api_reuses_recovered_key(self):
        self.install_active_api_fixture()
        journal, config_previous, _credential_previous = self.setup_artifacts()
        _write_private(config_previous, self.paths.health_config.read_bytes())
        _replace_config_value(
            self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "static"
        )
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=static\n"
                b"phase=prepared\n"
                b"had_key=1\n"
                b"had_pre_managed=1\n"
                b"key_changed=0\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )

        self.assertFalse(
            setup.api_requires_proposed_credential(
                _request(mode="api"), paths=self.paths
            )
        )
        self.apply(_request(mode="api"), None)

        self.assertEqual(self.paths.credential.read_bytes(), self.OLD_CREDENTIAL)
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assert_no_setup_artifacts()

    def test_ambiguous_static_recovery_accepts_only_the_exact_restored_key(self):
        self.install_active_api_fixture()
        journal, config_previous, _credential_previous = self.setup_artifacts()
        _write_private(config_previous, self.paths.health_config.read_bytes())
        _replace_config_value(
            self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "static"
        )
        _write_private(
            journal,
            (
                b"version=3\n"
                b"operation=static\n"
                b"phase=activated\n"
                b"had_key=1\n"
                b"had_pre_managed=1\n"
                b"key_changed=0\n"
                b"verify_started=0\n"
                b"status_before_dev=0\n"
                b"status_before_ino=0\n"
            ),
        )
        checks = 0

        def fail_recovery_then_pass_new_apply(phase):
            nonlocal checks
            if phase == "verification-start":
                checks += 1
                self.runner.status_outcome = "failed" if checks == 1 else "healthy"

        self.runner.phase_hook = fail_recovery_then_pass_new_apply
        self.assertTrue(
            setup.api_requires_proposed_credential(
                _request(mode="api"), paths=self.paths
            )
        )

        with self.proposed_credential(self.OLD_CREDENTIAL) as credential:
            self.apply(_request(mode="api"), credential)

        self.assertEqual(checks, 2)
        self.assertEqual(self.paths.credential.read_bytes(), self.OLD_CREDENTIAL)
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assert_no_setup_artifacts()

    def test_static_or_missing_profile_api_entry_requires_proposed_descriptor(self):
        before = _snapshot(self.paths)

        with self.assertRaises(setup.SetupError):
            self.apply(_request(mode="api"), None)

        self.assertEqual(_snapshot(self.paths), before)
        self.assertEqual(self.runner.events, [])

    def test_active_api_rejects_supplied_credential_without_replace_flag(self):
        self.install_active_api_fixture()
        before = _snapshot(self.paths)

        with self.proposed_credential() as credential:
            with self.assertRaises(setup.SetupError):
                self.apply(_request(mode="api"), credential)

        self.assertEqual(_snapshot(self.paths), before)
        self.assertEqual(self.runner.events, [])

    def test_active_api_replace_flag_requires_a_proposed_descriptor(self):
        self.install_active_api_fixture()
        before = _snapshot(self.paths)

        with self.assertRaises(setup.SetupError):
            self.apply(_request(mode="api", replace_credential=True), None)

        self.assertEqual(_snapshot(self.paths), before)
        self.assertEqual(self.runner.events, [])

    def test_active_api_replace_flag_revalidates_and_swaps_without_adopt_apply(self):
        self.install_active_api_fixture()

        with self.proposed_credential() as credential:
            self.apply(_request(mode="api", replace_credential=True), credential)

        self.assertEqual(self.paths.credential.read_bytes(), self.PROPOSED_CREDENTIAL)
        self.assertEqual(self.runner.validation_calls, 2)
        self.assertFalse(
            any(
                event[0:2] == (self.runner.runtime, "adopt") and "--apply" in event
                for event in self.runner.events
            )
        )
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=api\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )

    def test_failed_post_commit_removal_reports_prior_reset_and_keeps_commit(self):
        self.install_active_api_fixture()
        _write_private(self.paths.api_state, b"api-state-unit-test-sentinel\n")
        real_unlink = setup.application.durable_unlink

        def fail_credential_removal(path, trusted_uid, *, required=False):
            if path == self.paths.credential:
                raise setup.SetupError("injected credential unlink failure")
            return real_unlink(path, trusted_uid, required=required)

        with mock.patch.object(
            setup.application,
            "durable_unlink",
            side_effect=fail_credential_removal,
        ):
            with self.assertRaises(setup.SetupError) as captured:
                self.apply(
                    _request(
                        mode="static",
                        remove_credential=True,
                        reset_api_state=True,
                    )
                )

        message = str(captured.exception).lower()
        self.assertIn("verified and committed", message)
        self.assertIn("after the api-state reset", message)
        self.assertIn("incomplete", message)
        self.assertIn(
            "AIRVPN_PROFILE_SOURCE=static\n",
            self.paths.health_config.read_text(encoding="ascii"),
        )
        self.assertFalse(self.paths.api_state.exists())
        self.assertEqual(self.paths.credential.read_bytes(), self.OLD_CREDENTIAL)
        self.assert_no_setup_artifacts()

    def test_timer_enable_containment_failure_is_reported_without_false_safety_claim(
        self,
    ):
        self.runner.fail_enable = True
        self.runner.partial_enable_failure = True
        self.runner.fail_containment_disable = True

        with self.assertRaises(setup.SetupError) as captured:
            self.apply(_request(mode="static", timer="enable"))

        enable = (
            self.runner.systemctl,
            "enable",
            "--now",
            self.paths.timer_unit,
        )
        enable_index = self.runner.events.index(enable)
        post_enable = self.runner.events[enable_index + 1 :]
        self.assertIn(
            (self.runner.systemctl, "disable", "--now", self.paths.timer_unit),
            post_enable,
        )
        self.assertIn(
            (self.runner.systemctl, "stop", self.paths.service_unit), post_enable
        )
        self.assertIn(
            (self.runner.systemctl, "is-active", "--quiet", self.paths.timer_unit),
            post_enable,
        )
        self.assertIn(
            (self.runner.systemctl, "is-active", "--quiet", self.paths.service_unit),
            post_enable,
        )
        message = str(captured.exception).lower()
        self.assertIn("containment could not be proven", message)
        self.assertNotIn("it remains disabled", message)


if __name__ == "__main__":
    import unittest

    unittest.main()
