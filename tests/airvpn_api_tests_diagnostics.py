"""Adversarial tests for secret-free transient generator diagnostics."""

from tests.airvpn_api_test_support import *
import tests.airvpn_api_tests_generator as _generator


class _ReadFailureResponse(_Response):
    def read(self, size=-1):
        self.read_calls.append(size)
        raise OSError("read marker must not escape")


class _ExplodingHeaders:
    def __init__(self, marker):
        self.marker = marker

    def get_all(self, _name):
        raise RuntimeError(self.marker)


class _CloseFailureJsonResponse(_Response):
    def __init__(self, payload, marker):
        super().__init__(payload, content_type="application/json")
        self.marker = marker

    def close(self):
        super().close()
        raise http.client.BadStatusLine(self.marker)


class _GeneratorHarness:
    """Reuse generator descriptor fixtures without inheriting its test methods."""

    API_KEY = _generator.GeneratorBoundaryTests.API_KEY
    BASE_ARGS = _generator.GeneratorBoundaryTests.BASE_ARGS
    _run_generator = _generator.GeneratorBoundaryTests._run_generator
    _direct_generator_error = _generator.GeneratorBoundaryTests._direct_generator_error


class GeneratorDiagnosticsTests(_GeneratorHarness, unittest.TestCase):
    def test_duplicate_json_fields_are_transient_and_redacted(self):
        remote_secret = b"duplicate-provider-json-must-not-escape"
        payloads = (
            b'{"result":"ok","result":"' + remote_secret + b'"}',
            b'{"error":"first","error":"' + remote_secret + b'"}',
            b'{"result":"error","nested":{"field":1,"field":2}}',
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                result = self._run_generator(
                    response=_Response(payload, content_type="application/json")
                )
                self.assertEqual(result.return_code, 6)
                self.assertEqual(
                    result.stdout,
                    "failure\ttransient\tphase=response\treason=json\n",
                )
                self.assertNotIn(remote_secret.decode("ascii"), result.stdout)
                self.assertNotIn(remote_secret.decode("ascii"), result.stderr)
                self.assertEqual(result.output_stream.write_calls, [])

    def test_response_mime_encoding_status_and_size_are_fail_closed(self):
        for content_type in (
            "text/plain",
            "text/plain; charset=utf-8",
            "application/octet-stream",
        ):
            for content_encoding in (None, "identity"):
                with self.subTest(
                    content_type=content_type,
                    content_encoding=content_encoding,
                ):
                    result = self._run_generator(
                        response=_Response(
                            _generator_profile(),
                            content_type=content_type,
                            content_encoding=content_encoding,
                        )
                    )
                    self.assertEqual(result.return_code, 0, result.stderr)

        wrong_status = _Response(_generator_profile())
        wrong_status.status = 201
        transport_statuses = []
        for status in (302, 408, 500, 503):
            response = _Response(_generator_profile())
            response.status = status
            transport_statuses.append(response)
        rejected = (
            (_Response(_generator_profile(), content_type=None), "media"),
            (_Response(_generator_profile(), content_type="text/html"), "media"),
            (_Response(_generator_profile(), content_type="application/zip"), "media"),
            (
                _Response(
                    _generator_profile(),
                    content_type="text/plain",
                    content_encoding="gzip",
                ),
                "encoding",
            ),
            (_Response(b"x" * ((64 * 1024) + 1)), "size"),
            (wrong_status, "status"),
        )
        for response, reason in rejected:
            with self.subTest(headers=response.headers, status=response.status):
                result = self._run_generator(response=response)
                self.assertEqual(result.return_code, 6)
                self.assertEqual(
                    result.stdout,
                    f"failure\ttransient\tphase=response\treason={reason}\n",
                )
                self.assertEqual(result.output_stream.write_calls, [])
                self.assertTrue(response.closed)

        for response in transport_statuses:
            with self.subTest(status=response.status):
                result = self._run_generator(response=response)
                self.assertEqual(result.return_code, 6)
                self.assertEqual(result.stdout, "failure\ttransient\tphase=transport\n")

    def test_response_reason_enum_is_allowlisted_and_local(self):
        expected = {
            "status",
            "encoding",
            "media",
            "read",
            "size",
            "json",
            "protocol",
        }
        self.assertEqual(
            {reason.value for reason in airvpn_api.GeneratorTransientResponseReason},
            expected,
        )

        response = _Response(_generator_profile())
        response.status = 201
        error, _opener, _streams = self._direct_generator_error(response=response)
        self.assertIs(
            error.reason,
            airvpn_api.GeneratorTransientResponseReason.STATUS,
        )
        self.assertNotIn("201", repr(error))

        result = self._run_generator(response=_ReadFailureResponse(_generator_profile()))
        self.assertEqual(result.return_code, 6)
        self.assertEqual(
            result.stdout,
            "failure\ttransient\tphase=response\treason=read\n",
        )

        marker = "malformed-header-provider-marker"
        response = _Response(_generator_profile())
        response.headers = _ExplodingHeaders(marker)
        result = self._run_generator(response=response)
        self.assertEqual(
            result.stdout,
            "failure\ttransient\tphase=response\treason=protocol\n",
        )
        self.assertNotIn(marker, result.stdout)
        self.assertNotIn(marker, result.stderr)

        remote_marker = "provider-json-error-marker"
        payload = json.dumps({"result": "error", "error": remote_marker}).encode()
        result = self._run_generator(
            response=_CloseFailureJsonResponse(payload, remote_marker)
        )
        self.assertEqual(result.return_code, 4)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(remote_marker, result.stdout)
        self.assertNotIn(remote_marker, result.stderr)

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
                expected = f"failure\ttransient\tphase={phase}\n"
                if phase == "response":
                    expected = f"{expected[:-1]}\treason=json\n"
                self.assertEqual(result.stdout, expected)
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
