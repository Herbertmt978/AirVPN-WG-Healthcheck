import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec" / "airvpn-api"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_SERVERS = 1000
MAX_NUMERIC_TEXT_CHARS = 64
MAX_DISPLAY_FIELD_CHARS = 256


def _load_helper():
    loader = importlib.machinery.SourceFileLoader("airvpn_api", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


airvpn_api = _load_helper()


def _server(
    name,
    ip,
    *,
    country="GB",
    location="London",
    bw_max=10000,
    load=10,
    users=20,
    health="ok",
    **extra,
):
    server = {
        "public_name": name,
        "country_code": country,
        "location": location,
        "bw_max": bw_max,
        "currentload": load,
        "users": users,
        "health": health,
        "ip_v4_in1": ip,
    }
    server.update(extra)
    return server


def _status(*servers):
    return {"result": "ok", "servers": list(servers)}


class StatusValidationTests(unittest.TestCase):
    def test_scalar_result_with_empty_servers_is_valid_and_has_no_candidate(self):
        payload = {"result": "ok", "servers": []}

        self.assertEqual(airvpn_api.validate_status_payload(payload), [])
        self.assertIsNone(
            airvpn_api.select_candidate(payload, ["GB"], 1637, "")
        )

    def test_malformed_result_and_server_list_are_rejected(self):
        cases = (
            (
                {"result": {"servers": []}, "servers": []},
                "result must be 'ok'",
            ),
            ({"result": "ok", "servers": {}}, "servers must be a list"),
            ({"result": "ok", "servers": ["not-an-object"]}, "server 0"),
        )

        for payload, message in cases:
            with self.subTest(payload=payload):
                with self.assertRaisesRegex(ValueError, message):
                    airvpn_api.validate_status_payload(payload)

    def test_server_list_over_reasonable_limit_is_rejected(self):
        payload = {"result": "ok", "servers": [{}] * (MAX_SERVERS + 1)}

        with self.assertRaisesRegex(ValueError, "more than 1000 servers"):
            airvpn_api.validate_status_payload(payload)


class EndpointParsingTests(unittest.TestCase):
    def test_ipv4_and_bracketed_ipv6_endpoints_are_parsed_safely(self):
        self.assertEqual(
            airvpn_api.parse_endpoint_ip("198.51.100.8:1637"),
            "198.51.100.8",
        )
        self.assertEqual(
            airvpn_api.parse_endpoint_ip("[2001:db8::8]:1637"),
            "2001:db8::8",
        )

    def test_invalid_ports_are_rejected(self):
        for port in (0, 65536):
            with self.subTest(port=port):
                with self.assertRaisesRegex(ValueError, "port.*1.*65535"):
                    airvpn_api.select_candidate(_status(), ["GB"], port, "")

        with self.assertRaisesRegex(ValueError, "port.*1.*65535"):
            airvpn_api.parse_endpoint_ip("198.51.100.8:65536")


class CandidateSelectionTests(unittest.TestCase):
    def test_tied_numeric_ranks_use_deterministic_scalar_tiebreakers(self):
        alpha = _server("Alpha", "198.51.100.20")
        zulu = _server("Zulu", "198.51.100.10")

        first = airvpn_api.select_candidate(
            _status(zulu, alpha), ["GB"], 1637, ""
        )
        second = airvpn_api.select_candidate(
            _status(alpha, zulu), ["GB"], 1637, ""
        )

        self.assertEqual(first[0], "Alpha")
        self.assertEqual(second, first)

    def test_zero_load_and_users_are_preserved_and_win(self):
        zero = _server("Zero", "198.51.100.10", load=0, users=0)
        nonzero = _server("Nonzero", "198.51.100.11", load=1, users=1)

        candidate = airvpn_api.select_candidate(
            _status(nonzero, zero), ["GB"], 1637, ""
        )

        self.assertEqual(
            candidate,
            (
                "Zero",
                "198.51.100.10:1637",
                "GB",
                "London",
                "10000",
                "0",
                "0",
            ),
        )

    def test_warning_health_is_skipped(self):
        warning = _server(
            "Warning", "198.51.100.10", load=0, users=0, health="warning"
        )
        healthy = _server(
            "Healthy", "198.51.100.11", load=50, users=100, health="ok"
        )

        candidate = airvpn_api.select_candidate(
            _status(warning, healthy), ["GB"], 1637, ""
        )

        self.assertEqual(candidate[0], "Healthy")

    def test_health_case_variants_are_not_eligible(self):
        for health in ("OK", "Ok"):
            with self.subTest(health=health):
                candidate = airvpn_api.select_candidate(
                    _status(
                        _server(
                            "CaseVariant",
                            "198.51.100.12",
                            load=0,
                            users=0,
                            health=health,
                        )
                    ),
                    ["GB"],
                    1637,
                    "",
                )

                self.assertIsNone(candidate)

    def test_users_divided_by_100_changes_the_winner(self):
        balanced = _server(
            "BalancedUsers", "198.51.100.20", bw_max=0, load=0.4, users=50
        )
        no_users = _server(
            "NoUsers", "198.51.100.21", bw_max=0, load=0.91, users=0
        )
        low_load = _server(
            "LowLoad", "198.51.100.22", bw_max=0, load=0, users=100
        )

        candidate = airvpn_api.select_candidate(
            _status(no_users, low_load, balanced), ["GB"], 1637, ""
        )

        self.assertEqual(candidate[0], "BalancedUsers")

    def test_country_index_penalty_of_point_25_changes_the_winner(self):
        preferred = _server(
            "PreferredCountry",
            "198.51.100.30",
            country="GB",
            bw_max=0,
            load=0.66,
            users=0,
        )
        middle = _server(
            "MiddlePenalty",
            "198.51.100.31",
            country="NL",
            bw_max=0,
            load=0.4,
            users=0,
        )
        later = _server(
            "LaterCountry",
            "198.51.100.32",
            country="DE",
            bw_max=0,
            load=0.17,
            users=0,
        )

        candidate = airvpn_api.select_candidate(
            _status(preferred, middle, later), ["GB", "NL", "DE"], 1637, ""
        )

        self.assertEqual(candidate[0], "MiddlePenalty")

    def test_bandwidth_bonus_coefficient_and_cap_change_the_winner(self):
        at_cap = _server(
            "AtCap", "198.51.100.40", bw_max=20000, load=0.15, users=0
        )
        over_cap = _server(
            "OverCap", "198.51.100.41", bw_max=40000, load=0.16, users=0
        )
        no_bandwidth = _server(
            "NoBandwidth", "198.51.100.42", bw_max=0, load=0, users=0
        )

        candidate = airvpn_api.select_candidate(
            _status(no_bandwidth, over_cap, at_cap), ["GB"], 1637, ""
        )

        self.assertEqual(candidate[0], "AtCap")

    def test_current_server_is_excluded_when_an_alternate_entry_ip_matches(self):
        current = _server(
            "Current",
            "198.51.100.10",
            load=0,
            users=0,
            ip_v4_in3="198.51.100.99",
        )
        other = _server("Other", "198.51.100.11", load=80, users=500)

        candidate = airvpn_api.select_candidate(
            _status(current, other),
            ["GB"],
            1637,
            "198.51.100.99:1637",
        )

        self.assertEqual(candidate[0], "Other")


class NumericValidationTests(unittest.TestCase):
    def test_extreme_negative_exponent_is_rejected_before_formatting(self):
        payload = _status(
            _server("TinyLoad", "198.51.100.50", load="1e-10000")
        )

        with self.assertRaisesRegex(ValueError, "exponent or scale"):
            airvpn_api.select_candidate(payload, ["GB"], 1637, "")

    def test_unreasonable_numeric_magnitude_is_rejected(self):
        payload = _status(
            _server("HugeBandwidth", "198.51.100.51", bw_max="1000000001")
        )

        with self.assertRaisesRegex(ValueError, "magnitude"):
            airvpn_api.select_candidate(payload, ["GB"], 1637, "")

    def test_overlong_numeric_text_is_rejected_before_decimal_parsing(self):
        overlong_zero = "0" * (MAX_NUMERIC_TEXT_CHARS + 1)
        payload = _status(
            _server("LongUsers", "198.51.100.52", users=overlong_zero)
        )

        with self.assertRaisesRegex(ValueError, "at most 64 characters"):
            airvpn_api.select_candidate(payload, ["GB"], 1637, "")

    def test_normal_integer_decimal_and_zero_text_are_preserved(self):
        payload = _status(
            _server(
                "NormalNumbers",
                "198.51.100.53",
                bw_max="20000.5",
                load="0.125",
                users="0",
            )
        )

        candidate = airvpn_api.select_candidate(payload, ["GB"], 1637, "")

        self.assertEqual(candidate[4:], ("20000.5", "0.125", "0"))


class EgressValidationTests(unittest.TestCase):
    def test_non_airvpn_egress_is_rejected(self):
        payload = {
            "result": "ok",
            "airvpn": False,
            "server_name": "Outside",
            "geo": {"name": "Elsewhere", "code": "ZZ"},
        }

        with self.assertRaisesRegex(ValueError, "airvpn must be true"):
            airvpn_api.validate_egress(payload)

    def test_valid_egress_display_fields_are_tsv_sanitized(self):
        payload = {
            "result": "ok",
            "airvpn": True,
            "server_name": "Exit\tOne\n",
            "geo": {"name": "United\r\nKingdom", "code": "GB"},
        }

        self.assertEqual(
            airvpn_api.validate_egress(payload),
            ("Exit One", "United Kingdom"),
        )

    def test_overlong_display_field_is_rejected(self):
        payload = {
            "result": "ok",
            "airvpn": True,
            "server_name": "x" * (MAX_DISPLAY_FIELD_CHARS + 1),
            "geo": {"name": "United Kingdom", "code": "GB"},
        }

        with self.assertRaisesRegex(ValueError, "display field.*256"):
            airvpn_api.validate_egress(payload)


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
        with mock.patch.object(airvpn_api.urllib.request, "build_opener") as build_opener:
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
                with mock.patch.object(
                    airvpn_api,
                    "validate_egress",
                    side_effect=error_type("programmer defect"),
                ), mock.patch.object(sys, "stdin", io.StringIO("{}")), mock.patch.object(
                    sys, "stderr", stderr
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
            with self.subTest(command=argv[0]), boundary_patch, mock.patch.object(
                sys, "stderr", stderr
            ):
                return_code = airvpn_api.main(argv)

            self.assertEqual(return_code, 2)
            self.assertRegex(stderr.getvalue(), r"^ERROR:")
            self.assertNotIn("Traceback", stderr.getvalue())


class CliTests(unittest.TestCase):
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
        with mock.patch.object(airvpn_api, "_fetch_json", return_value=payload), mock.patch.object(
            sys, "stdout", stdout
        ), mock.patch.object(sys, "stderr", stderr):
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


if __name__ == "__main__":
    unittest.main()
