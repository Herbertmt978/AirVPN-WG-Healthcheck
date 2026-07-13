from tests.airvpn_api_test_support import *

class CountryListingTests(unittest.TestCase):
    def _eligible(self, payload):
        self.assertTrue(
            hasattr(airvpn_api, "list_eligible_countries"),
            "list_eligible_countries is not implemented",
        )
        return airvpn_api.list_eligible_countries(payload)

    def test_list_countries_is_credential_free_and_sorted(self):
        payload = _status(
            _server(
                "NetherlandsOne",
                "198.51.100.21",
                country="nl",
                country_name="Netherlands",
            ),
            _server(
                "BritainOne",
                "198.51.100.22",
                country="GB",
                country_name="United\tKingdom",
            ),
            _server(
                "BritainTwo",
                "198.51.100.23",
                country="gb",
                country_name="United Kingdom",
            ),
            _server(
                "GermanyWarning",
                "198.51.100.24",
                country="DE",
                country_name="Germany",
                health="warning",
            ),
        )
        expected = [
            ("GB", "United Kingdom", "2"),
            ("NL", "Netherlands", "1"),
        ]

        self.assertEqual(self._eligible(payload), expected)

        response = io.BytesIO(json.dumps(payload).encode("utf-8"))
        opener = mock.Mock()
        opener.open.return_value = response
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch(
                "builtins.open", side_effect=AssertionError("credential opened")
            ),
            mock.patch.object(
                airvpn_api.urllib.request, "build_opener", return_value=opener
            ),
            mock.patch.object(sys, "stdout", stdout),
            mock.patch.object(sys, "stderr", stderr),
        ):
            return_code = airvpn_api.main(
                [
                    "list-countries",
                    "--url",
                    "https://status.example.test/api",
                    "--timeout",
                    "1",
                ]
            )

        self.assertEqual(return_code, 0, stderr.getvalue())
        self.assertEqual(
            stdout.getvalue(),
            "GB\tUnited Kingdom\t2\nNL\tNetherlands\t1\n",
        )
        request = opener.open.call_args.args[0]
        headers = {name.lower(): value for name, value in request.header_items()}
        self.assertNotIn("api-key", headers)

    def test_list_countries_requires_a_healthy_valid_ipv4_server(self):
        self.assertEqual(
            self._eligible(
                _status(
                    _server(
                        "WarningOnly",
                        "198.51.100.30",
                        country="GB",
                        country_name="United Kingdom",
                        health="warning",
                    )
                )
            ),
            [],
        )
        self.assertEqual(
            self._eligible(
                _status(
                    _server(
                        "Healthy",
                        "198.51.100.31",
                        country="GB",
                        country_name="United Kingdom",
                    )
                )
            ),
            [("GB", "United Kingdom", "1")],
        )
        for invalid_ip in ("not-an-ip", "2001:db8::31"):
            with self.subTest(ip=invalid_ip), self.assertRaises(ValueError):
                self._eligible(
                    _status(
                        _server(
                            "InvalidIPv4",
                            invalid_ip,
                            country="GB",
                            country_name="United Kingdom",
                        )
                    )
                )

    def test_list_countries_rejects_duplicate_conflicting_or_malformed_codes(self):
        with self.assertRaises(ValueError):
            self._eligible(
                _status(
                    _server(
                        "Britain",
                        "198.51.100.40",
                        country="gb",
                        country_name="United Kingdom",
                    ),
                    _server(
                        "Conflict",
                        "198.51.100.41",
                        country="GB",
                        country_name="Great Britain",
                    ),
                )
            )

        for country in ("G", "GBR", "G1", "G\x00", "\u00e9X", " GB "):
            with self.subTest(country=repr(country)), self.assertRaises(ValueError):
                self._eligible(
                    _status(
                        _server(
                            "MalformedCountry",
                            "198.51.100.42",
                            country=country,
                            country_name="United Kingdom",
                        )
                    )
                )

        for country_name in (None, "United\x00Kingdom"):
            with (
                self.subTest(country_name=repr(country_name)),
                self.assertRaises(ValueError),
            ):
                self._eligible(
                    _status(
                        _server(
                            "MalformedName",
                            "198.51.100.43",
                            country="GB",
                            country_name=country_name,
                        )
                    )
                )


class StatusValidationTests(unittest.TestCase):
    def test_scalar_result_with_empty_servers_is_valid_and_has_no_candidate(self):
        payload = {"result": "ok", "servers": []}

        self.assertEqual(airvpn_api.validate_status_payload(payload), [])
        self.assertIsNone(airvpn_api.select_candidate(payload, ["GB"], 1637, ""))

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
    def assert_exclusion_contract_exists(self):
        self.assertIn(
            "excluded_servers",
            inspect.signature(airvpn_api.select_candidate).parameters,
            "select_candidate must expose the Task 5 exclusion collection",
        )

    def test_empty_exclusions_preserve_legacy_selection(self):
        self.assert_exclusion_contract_exists()
        payload = _status(
            _server("Alpha", "198.51.100.20"),
            _server("Zulu", "198.51.100.21"),
        )

        legacy = airvpn_api.select_candidate(payload, ["GB"], 1637, "")
        explicitly_empty = airvpn_api.select_candidate(payload, ["GB"], 1637, "", [])

        self.assertEqual(explicitly_empty, legacy)

    def test_exclusions_are_applied_before_current_and_score_validation(self):
        self.assert_exclusion_contract_exists()
        excluded = _server("Broken-First", "198.51.100.20")
        excluded.update(
            {
                "country_code": object(),
                "ip_v4_in1": "not-an-address",
                "currentload": "not-a-number",
            }
        )
        alternate = _server("Safe-Alternate", "198.51.100.21", load=90)

        candidate = airvpn_api.select_candidate(
            _status(excluded, alternate),
            ["GB"],
            1637,
            "198.51.100.99:1637",
            ["Broken-First"],
        )

        self.assertEqual(candidate[0], "Safe-Alternate")

        excluded_fallback = _server("Broken-Fallback", "198.51.100.22")
        excluded_fallback.update(
            {
                "public_name": "",
                "name": "Broken-Fallback",
                "country_code": object(),
                "ip_v4_in1": "not-an-address",
            }
        )
        candidate = airvpn_api.select_candidate(
            _status(excluded_fallback, alternate),
            ["GB"],
            1637,
            "",
            ["Broken-Fallback"],
        )
        self.assertEqual(candidate[0], "Safe-Alternate")

    def test_exclusions_reject_invalid_duplicate_and_over_limit_names(self):
        self.assert_exclusion_contract_exists()
        payload = _status(_server("Safe", "198.51.100.21"))
        invalid_sets = (
            [""],
            ["_invalid"],
            ["space invalid"],
            ["a" * 65],
            ["Mensa", "Mensa"],
            [f"Server-{index}" for index in range(17)],
        )

        for exclusions in invalid_sets:
            with self.subTest(exclusions=exclusions):
                with self.assertRaisesRegex(
                    ValueError, "exclude|exclusion|server name"
                ):
                    airvpn_api.select_candidate(payload, ["GB"], 1637, "", exclusions)

        sixteen = [f"Server-{index}" for index in range(16)]
        self.assertEqual(
            airvpn_api.select_candidate(payload, ["GB"], 1637, "", sixteen)[0],
            "Safe",
        )

    def test_tied_numeric_ranks_use_deterministic_scalar_tiebreakers(self):
        alpha = _server("Alpha", "198.51.100.20")
        zulu = _server("Zulu", "198.51.100.10")

        first = airvpn_api.select_candidate(_status(zulu, alpha), ["GB"], 1637, "")
        second = airvpn_api.select_candidate(_status(alpha, zulu), ["GB"], 1637, "")

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
        warning = _server("Warning", "198.51.100.10", load=0, users=0, health="warning")
        healthy = _server("Healthy", "198.51.100.11", load=50, users=100, health="ok")

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
        no_users = _server("NoUsers", "198.51.100.21", bw_max=0, load=0.91, users=0)
        low_load = _server("LowLoad", "198.51.100.22", bw_max=0, load=0, users=100)

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
        at_cap = _server("AtCap", "198.51.100.40", bw_max=20000, load=0.15, users=0)
        over_cap = _server("OverCap", "198.51.100.41", bw_max=40000, load=0.16, users=0)
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
        payload = _status(_server("TinyLoad", "198.51.100.50", load="1e-10000"))

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
        payload = _status(_server("LongUsers", "198.51.100.52", users=overlong_zero))

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
