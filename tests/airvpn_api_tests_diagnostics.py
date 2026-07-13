"""Adversarial tests for secret-free transient generator diagnostics."""

from tests.airvpn_api_test_support import *
import tests.airvpn_api_tests_generator as _generator


class _GeneratorHarness:
    """Reuse generator descriptor fixtures without inheriting its test methods."""

    API_KEY = _generator.GeneratorBoundaryTests.API_KEY
    BASE_ARGS = _generator.GeneratorBoundaryTests.BASE_ARGS
    _run_generator = _generator.GeneratorBoundaryTests._run_generator
    _direct_generator_error = _generator.GeneratorBoundaryTests._direct_generator_error


class GeneratorDiagnosticsTests(_GeneratorHarness, unittest.TestCase):
    def test_transient_phase_manifest_is_allowlisted_and_secret_free(self):
        marker = "raw-provider-detail-should-never-cross"
        cases = (
            ("transport", dict(opener_error=urllib.error.URLError(marker))),
            (
                "response",
                dict(
                    response=_Response(
                        b"{" + marker.encode("ascii"),
                        content_type="application/json",
                    )
                ),
            ),
            (
                "profile",
                dict(
                    response=_Response(
                        b"not-a-wireguard-profile-" + marker.encode("ascii")
                    )
                ),
            ),
        )
        for phase, kwargs in cases:
            with self.subTest(phase=phase):
                result = self._run_generator(**kwargs)
                self.assertEqual(result.return_code, 6)
                self.assertEqual(
                    result.stdout,
                    f"failure\ttransient\tphase={phase}\n",
                )
                self.assertEqual(
                    result.stderr,
                    "ERROR: authenticated provider request failed\n",
                )
                self.assertNotIn(marker, result.stdout)
                self.assertNotIn(marker, result.stderr)

        with mock.patch.object(
            airvpn_api,
            "_generate_profile_secret_body",
            side_effect=RuntimeError(marker),
        ):
            result = self._run_generator()
        self.assertEqual(result.return_code, 6)
        self.assertEqual(result.stdout, "failure\ttransient\tphase=internal\n")
        self.assertEqual(
            result.stderr,
            "ERROR: authenticated provider request failed\n",
        )
        self.assertNotIn(marker, result.stdout)
        self.assertNotIn(marker, result.stderr)

        error, _opener, _streams = self._direct_generator_error(
            opener_error=urllib.error.URLError(marker)
        )
        self.assertEqual(error.phase, airvpn_api.GeneratorTransientPhase.TRANSPORT)
        self.assertNotIn(marker, repr(error))
        self.assertNotIn(marker, str(error))
        self.assertNotIn(marker, repr(vars(error)))

    def test_generated_profile_contract_failure_is_profile_phase(self):
        marker = "generated-profile-contract-marker"
        with mock.patch.object(
            airvpn_api,
            "render_wireguard_profile",
            side_effect=airvpn_api.AirVPNAPIError(marker),
        ):
            result = self._run_generator(response=_Response(_generator_profile()))
        self.assertEqual(result.return_code, 6)
        self.assertEqual(result.stdout, "failure\ttransient\tphase=profile\n")
        self.assertEqual(
            result.stderr,
            "ERROR: authenticated provider request failed\n",
        )
        self.assertNotIn(marker, result.stderr)
