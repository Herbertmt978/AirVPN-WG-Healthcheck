from tests.setup_apply_support import ApplyFixture, _write_private, setup


class SetupJournalGrammarTests(ApplyFixture):
    def journal_path(self):
        return self.setup_artifacts()[0]

    def read(self, payload: bytes):
        _write_private(self.journal_path(), payload)
        return setup.application._read_journal(self.paths)

    @staticmethod
    def legacy_payload(
        version: int,
        operation: str,
        phase: str,
        *,
        had_key: int = 1,
        key_changed: int | None = None,
    ) -> bytes:
        fields = [
            f"version={version}",
            f"operation={operation}",
            f"phase={phase}",
            f"had_key={had_key}",
            "had_pre_managed=1",
        ]
        if version == 2:
            fields.append(f"key_changed={0 if key_changed is None else key_changed}")
        return ("\n".join(fields) + "\n").encode("ascii")

    @staticmethod
    def v3_payload(
        operation: str,
        phase: str,
        *,
        had_key: int = 1,
        key_changed: int = 0,
        verify_started: int = 0,
        status_before_dev: int = 0,
        status_before_ino: int = 0,
    ) -> bytes:
        return (
            "version=3\n"
            f"operation={operation}\n"
            f"phase={phase}\n"
            f"had_key={had_key}\n"
            "had_pre_managed=1\n"
            f"key_changed={key_changed}\n"
            f"verify_started={verify_started}\n"
            f"status_before_dev={status_before_dev}\n"
            f"status_before_ino={status_before_ino}\n"
        ).encode("ascii")

    def assert_invalid(self, payload: bytes):
        with self.assertRaisesRegex(setup.SetupError, "transaction record is invalid"):
            self.read(payload)

    def test_v1_and_v2_canonical_records_remain_compatible(self):
        for version in (1, 2):
            with self.subTest(version=version):
                journal = self.read(
                    self.legacy_payload(version, "api-update", "activated")
                )
                self.assertEqual(journal.operation, "api-update")
                self.assertEqual(journal.phase, "activated")
                self.assertEqual(journal.key_changed, version == 1)
                self.assertEqual(journal.verify_started, 0)

    def test_legacy_versions_reject_v3_only_recovery_phases(self):
        for version in (1, 2):
            for phase in ("verifying", "rolled-back"):
                with self.subTest(version=version, phase=phase):
                    self.assert_invalid(
                        self.legacy_payload(version, "api-update", phase)
                    )

    def test_line_grammar_accepts_only_canonical_lf_records(self):
        canonical = self.legacy_payload(1, "adopt", "activated")
        variants = (
            canonical.replace(b"\n", b"\r\n"),
            canonical.replace(b"\n", b"\x0b", 1),
            canonical.replace(b"\n", b"\x0c", 1),
            canonical[:-1] + b"\n\n",
            canonical.replace(
                b"operation=adopt\nphase=activated\n",
                b"phase=activated\noperation=adopt\n",
            ),
        )
        for payload in variants:
            with self.subTest(payload=payload):
                self.assert_invalid(payload)

    def test_operation_phase_matrix_rejects_impossible_records(self):
        invalid = (
            self.legacy_payload(1, "provision", "activating"),
            # Legacy v1 implies key_changed=1; static operations never touch a key.
            self.legacy_payload(1, "static", "prepared"),
            self.legacy_payload(1, "static-restore", "prepared"),
            self.legacy_payload(2, "static", "prepared", key_changed=1),
            self.legacy_payload(2, "static-restore", "prepared", key_changed=1),
            self.legacy_payload(2, "static", "credential"),
            self.v3_payload("static", "config"),
            self.v3_payload("static-restore", "credential"),
            self.v3_payload("api-update", "activating"),
        )
        for payload in invalid:
            with self.subTest(payload=payload):
                self.assert_invalid(payload)

    def test_key_change_semantics_reject_impossible_records(self):
        invalid = [
            self.v3_payload("static", "prepared", key_changed=1),
            self.v3_payload("static-restore", "prepared", key_changed=1),
            self.v3_payload("api-update", "prepared", had_key=0, key_changed=0),
            self.v3_payload("provision", "prepared", had_key=0, key_changed=0),
            self.v3_payload("adopt", "prepared", had_key=0, key_changed=0),
        ]
        for operation in ("api-update", "provision", "adopt"):
            invalid.append(
                self.legacy_payload(2, operation, "prepared", had_key=0, key_changed=0)
            )
        for payload in invalid:
            with self.subTest(payload=payload):
                self.assert_invalid(payload)

    def test_v3_verifying_and_verified_require_persisted_proof_start(self):
        for phase in ("verifying", "verified"):
            with self.subTest(phase=phase):
                self.assert_invalid(self.v3_payload("api-update", phase))
                parsed = self.read(
                    self.v3_payload("api-update", phase, verify_started=self.NOW)
                )
                self.assertEqual(parsed.verify_started, self.NOW)

    def test_v3_nonproof_phases_require_zero_proof_fields(self):
        for phase in ("prepared", "config", "credential", "activated", "rolled-back"):
            with self.subTest(phase=phase):
                self.assert_invalid(
                    self.v3_payload("api-update", phase, verify_started=self.NOW)
                )

    def test_v3_proof_identity_is_absent_or_a_complete_pair(self):
        self.assert_invalid(
            self.v3_payload(
                "api-update",
                "verifying",
                verify_started=self.NOW,
                status_before_dev=7,
            )
        )
        parsed = self.read(
            self.v3_payload(
                "api-update",
                "verified",
                verify_started=self.NOW,
                status_before_dev=7,
                status_before_ino=11,
            )
        )
        self.assertEqual((parsed.status_before_dev, parsed.status_before_ino), (7, 11))


if __name__ == "__main__":
    import unittest

    unittest.main()
