from tests.airvpn_api_test_support import *

class InputBoundaryTests(unittest.TestCase):
    def test_oversized_http_response_is_rejected_before_json_parsing(self):
        response = io.BytesIO(b" " * (MAX_JSON_BYTES + 1))
        opener = mock.Mock()
        opener.open.return_value = response

        with mock.patch.object(
            airvpn_api.urllib.request, "build_opener", return_value=opener
        ):
            with self.assertRaisesRegex(ValueError, "exceeds 4194304 bytes"):
                airvpn_api._fetch_json("https://example.test/status", 1)

    def test_non_https_status_urls_are_rejected_before_open(self):
        with mock.patch.object(
            airvpn_api.urllib.request, "build_opener"
        ) as build_opener:
            for url in (
                "http://example.test/status",
                "file:///tmp/status.json",
                "https://user:password@example.test/status",
                "https://example.test/status with-space",
            ):
                with self.subTest(url=url), self.assertRaisesRegex(ValueError, "HTTPS"):
                    airvpn_api._fetch_json(url, 1)

        build_opener.assert_not_called()

    def test_redirect_handler_rejects_https_downgrade(self):
        handler = airvpn_api._HTTPSOnlyRedirectHandler()
        request = urllib.request.Request("https://example.test/status")

        with self.assertRaisesRegex(ValueError, "HTTPS"):
            handler.redirect_request(
                request,
                None,
                302,
                "Found",
                {},
                "http://example.test/status",
            )

    def test_unexpected_runtime_and_type_errors_propagate_from_main(self):
        for error_type in (RuntimeError, TypeError):
            stderr = io.StringIO()
            with self.subTest(error_type=error_type.__name__):
                with (
                    mock.patch.object(
                        airvpn_api,
                        "validate_egress",
                        side_effect=error_type("programmer defect"),
                    ),
                    mock.patch.object(sys, "stdin", io.StringIO("{}")),
                    mock.patch.object(sys, "stderr", stderr),
                ):
                    with self.assertRaises(error_type):
                        airvpn_api.main(["verify-egress"])

                self.assertEqual(stderr.getvalue(), "")

    def test_expected_network_and_json_errors_remain_concise(self):
        cases = (
            (
                ["select"],
                mock.patch.object(
                    airvpn_api,
                    "_fetch_json",
                    side_effect=urllib.error.URLError("offline"),
                ),
                None,
            ),
            (
                ["verify-egress"],
                mock.patch.object(sys, "stdin", io.StringIO("{")),
                None,
            ),
        )

        for argv, boundary_patch, _unused in cases:
            stderr = io.StringIO()
            with (
                self.subTest(command=argv[0]),
                boundary_patch,
                mock.patch.object(sys, "stderr", stderr),
            ):
                return_code = airvpn_api.main(argv)

            self.assertEqual(return_code, 2)
            self.assertRegex(stderr.getvalue(), r"^ERROR:")
            self.assertNotIn("Traceback", stderr.getvalue())


class CliTests(unittest.TestCase):
    def test_select_accepts_repeated_exclusions_and_rejects_them_before_fetch(self):
        parser = airvpn_api._build_parser()
        select_parser = next(
            action.choices["select"]
            for action in parser._actions
            if isinstance(action, airvpn_api.argparse._SubParsersAction)
        )
        self.assertIn(
            "--exclude-server",
            select_parser.format_help(),
            "select CLI must publish the repeatable exclusion option",
        )
        payload = _status(
            _server("First", "198.51.100.10", load=0),
            _server("Second", "198.51.100.11", load=1),
            _server("Third", "198.51.100.12", load=2),
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(airvpn_api, "_fetch_json", return_value=payload) as fetch,
            mock.patch.object(sys, "stdout", stdout),
            mock.patch.object(sys, "stderr", stderr),
        ):
            return_code = airvpn_api.main(
                [
                    "select",
                    "--exclude-server",
                    "First",
                    "--exclude-server",
                    "Second",
                ]
            )

        self.assertEqual(return_code, 0, stderr.getvalue())
        self.assertEqual(stdout.getvalue().split("\t", 1)[0], "Third")
        fetch.assert_called_once()

        rejected = (
            ["Duplicate", "Duplicate"],
            [f"Server-{index}" for index in range(17)],
            ["bad/name"],
        )
        for exclusions in rejected:
            argv = ["select"]
            for name in exclusions:
                argv.extend(("--exclude-server", name))
            stderr = io.StringIO()
            with (
                self.subTest(exclusions=exclusions),
                mock.patch.object(airvpn_api, "_fetch_json") as fetch,
                mock.patch.object(sys, "stderr", stderr),
            ):
                return_code = airvpn_api.main(argv)
            self.assertEqual(return_code, 2)
            self.assertRegex(stderr.getvalue(), r"^ERROR:")
            fetch.assert_not_called()

    def test_verify_egress_reads_stdin_and_prints_safe_two_field_tsv(self):
        payload = {
            "result": "ok",
            "airvpn": True,
            "server_name": "Exit\tOne",
            "geo": {"name": "United\nKingdom", "code": "GB"},
        }

        completed = subprocess.run(
            [sys.executable, str(HELPER), "verify-egress"],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "Exit One\tUnited Kingdom\n")
        self.assertEqual(completed.stderr, "")

    def test_verify_egress_contract_failure_is_concise_without_traceback(self):
        completed = subprocess.run(
            [sys.executable, str(HELPER), "verify-egress"],
            input='{"result":"ok","airvpn":false}',
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertRegex(completed.stderr, r"^ERROR:")
        self.assertNotIn("Traceback", completed.stderr)

    def test_select_fetches_fixture_and_prints_exact_seven_field_tsv(self):
        payload = _status(
            _server(
                "Fixture\tServer",
                "198.51.100.30",
                country="NL",
                location="North\nHolland",
                bw_max=20000,
                load=0,
                users=0,
            )
        )

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(airvpn_api, "_fetch_json", return_value=payload),
            mock.patch.object(sys, "stdout", stdout),
            mock.patch.object(sys, "stderr", stderr),
        ):
            return_code = airvpn_api.main(
                [
                    "select",
                    "--url",
                    "https://example.test/status",
                    "--countries",
                    "GB NL",
                    "--port",
                    "51820",
                    "--current-endpoint",
                    "198.51.100.99:51820",
                    "--timeout",
                    "1",
                ]
            )

        self.assertEqual(return_code, 0, stderr.getvalue())
        self.assertEqual(
            stdout.getvalue(),
            "Fixture Server\t198.51.100.30:51820\tNL\tNorth Holland\t20000\t0\t0\n",
        )
        self.assertEqual(stderr.getvalue(), "")

    def test_oversized_stdin_is_rejected_with_a_concise_boundary_error(self):
        completed = subprocess.run(
            [sys.executable, str(HELPER), "verify-egress"],
            input=" " * (MAX_JSON_BYTES + 1),
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("exceeds 4194304 bytes", completed.stderr)
        self.assertRegex(completed.stderr, r"^ERROR:")
        self.assertNotIn("Traceback", completed.stderr)
