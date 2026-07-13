from tests.airvpn_api_test_support import *

class ProfileParsingTests(unittest.TestCase):
    def _parse(self, payload, **kwargs):
        self.assertTrue(
            hasattr(airvpn_api, "parse_wireguard_profile"),
            "parse_wireguard_profile is not implemented",
        )
        return airvpn_api.parse_wireguard_profile(payload, **kwargs)

    def test_redacted_real_success_shape_parses(self):
        profile = self._parse(
            _wireguard_profile(line_ending="\r\n"),
            expected_endpoint="198.51.100.10:1637",
        )

        self.assertEqual(profile.address, ipaddress.IPv4Interface("10.20.30.40/32"))
        self.assertEqual(profile.private_key, _dummy_wireguard_key(1))
        self.assertEqual(profile.mtu, 1320)
        self.assertEqual(profile.dns, ("10.128.0.1", "1.1.1.1"))
        self.assertEqual(profile.table, "off")
        self.assertEqual(profile.public_key, _dummy_wireguard_key(2))
        self.assertEqual(profile.preshared_key, _dummy_wireguard_key(3))
        self.assertEqual(profile.endpoint, "198.51.100.10:1637")
        self.assertEqual(profile.allowed_ips, "0.0.0.0/0")
        self.assertEqual(profile.persistent_keepalive, 15)
        self.assertEqual(
            self._parse(_wireguard_profile(terminal_newline=False)),
            profile,
        )
        rendered_repr = repr(profile)
        for value in range(1, 4):
            self.assertNotIn(_dummy_wireguard_key(value), rendered_repr)
        with self.assertRaises(FrozenInstanceError):
            profile.endpoint = "198.51.100.11:1637"

    def test_duplicate_sections_fields_and_extra_peer_are_rejected(self):
        cases = {
            "duplicate interface": _wireguard_profile(trailer=("[Interface]",)),
            "duplicate field": _wireguard_profile(
                interface_extra=("Address = 10.20.30.41/32",)
            ),
            "extra peer": _wireguard_profile(trailer=("[Peer]",)),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self._parse(payload)

    def test_hooks_saveconfig_unknown_directives_and_shell_syntax_are_rejected(self):
        cases = {
            "SaveConfig": _wireguard_profile(interface_extra=("SaveConfig = true",)),
            "PreUp": _wireguard_profile(interface_extra=("PreUp = /usr/bin/true",)),
            "PostUp": _wireguard_profile(interface_extra=("PostUp = /usr/bin/true",)),
            "PreDown": _wireguard_profile(interface_extra=("PreDown = /usr/bin/true",)),
            "PostDown": _wireguard_profile(
                interface_extra=("PostDown = /usr/bin/true",)
            ),
            "unknown": _wireguard_profile(interface_extra=("Unknown = value",)),
            "shell syntax": _wireguard_profile(table="$(touch /tmp/provider-command)"),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self._parse(payload)

    def test_trusted_installed_post_hooks_are_preserved_in_order_and_redacted(self):
        hooks = (
            "  PostUp  = /usr/local/sbin/route-enable %i\\ ",
            "PostUp=/usr/local/sbin/route-confirm %i",
            "PostDown = /usr/local/sbin/route-remove %i",
        )
        payload = _wireguard_profile(interface_extra=hooks)

        self.assertTrue(
            hasattr(airvpn_api, "_parse_trusted_installed_profile"),
            "trusted installed-profile parser is not implemented",
        )
        installed = airvpn_api._parse_trusted_installed_profile(payload)

        self.assertEqual(installed.interface_hooks, hooks)
        self.assertEqual(
            installed.profile,
            self._parse(_wireguard_profile()),
        )
        for hook in hooks:
            self.assertNotIn(hook, repr(installed))

    def test_trusted_installed_parser_rejects_every_other_extra_directive(self):
        cases = {
            "PreUp": _wireguard_profile(interface_extra=("PreUp = /usr/bin/true",)),
            "PreDown": _wireguard_profile(
                interface_extra=("PreDown = /usr/bin/true",)
            ),
            "SaveConfig": _wireguard_profile(interface_extra=("SaveConfig = true",)),
            "unknown": _wireguard_profile(interface_extra=("Unknown = value",)),
            "peer hook": _wireguard_profile(peer_extra=("PostUp = /usr/bin/true",)),
            "empty hook": _wireguard_profile(interface_extra=("PostUp = ",)),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                airvpn_api._parse_trusted_installed_profile(payload)

    def test_noncanonical_or_zero_wireguard_keys_are_rejected(self):
        zero_key = base64.b64encode(bytes([0]) * 32).decode("ascii")
        short_key = base64.b64encode(bytes([4]) * 31).decode("ascii")
        cases = {
            "missing canonical padding": _wireguard_profile(
                private_key=_dummy_wireguard_key(1).rstrip("=")
            ),
            "wrong decoded length": _wireguard_profile(private_key=short_key),
            "zero private key": _wireguard_profile(private_key=zero_key),
            "zero public key": _wireguard_profile(public_key=zero_key),
            "zero preshared key": _wireguard_profile(preshared_key=zero_key),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self._parse(payload)

    def test_address_requires_one_ipv4_32(self):
        for address in (
            "10.20.30.40/24",
            "2001:db8::40/128",
            "10.20.30.40",
            "10.20.30.40/32, 10.20.30.41/32",
        ):
            with self.subTest(address=address), self.assertRaises(ValueError):
                self._parse(_wireguard_profile(address=address))

    def test_hostname_ipv6_and_wrong_endpoint_are_rejected(self):
        for endpoint in (
            "vpn.example.test:1637",
            "[2001:db8::10]:1637",
        ):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                self._parse(_wireguard_profile(endpoint=endpoint))

        with self.assertRaises(ValueError):
            self._parse(
                _wireguard_profile(),
                expected_endpoint="198.51.100.11:1637",
            )

    def test_mtu_keepalive_and_allowed_ips_are_exact(self):
        cases = {
            "wrong MTU": _wireguard_profile(mtu="1321"),
            "noncanonical MTU": _wireguard_profile(mtu="01320"),
            "wrong keepalive": _wireguard_profile(persistent_keepalive="14"),
            "noncanonical keepalive": _wireguard_profile(persistent_keepalive="015"),
            "additional route": _wireguard_profile(allowed_ips="0.0.0.0/0, ::/0"),
            "unexpected route": _wireguard_profile(allowed_ips="10.0.0.0/8"),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self._parse(payload)

    def test_control_non_utf8_bare_cr_long_line_and_oversize_are_rejected(self):
        valid = _wireguard_profile()
        cases = {
            "control byte": valid.replace(b"[Interface]", b"[Inter\x00face]"),
            "non-UTF-8": b"\xff" + valid,
            "bare CR": valid.replace(b"\n", b"\r", 1),
            "long line": b"#" + (b"x" * 1024) + b"\n" + valid,
            "too many lines": (b"# bounded\n" * 65) + valid,
            "oversize": b"x" * ((64 * 1024) + 1),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self._parse(payload)


class ProfileRenderingTests(unittest.TestCase):
    def _parse(self, payload):
        return airvpn_api.parse_wireguard_profile(payload)

    def _exception_chain_text(self, error):
        text = []
        seen = set()
        pending = [error]
        while pending:
            current = pending.pop()
            if current is None or id(current) in seen:
                continue
            seen.add(id(current))
            text.extend((repr(current), str(current)))
            pending.extend((current.__cause__, current.__context__))
        return "\n".join(text)

    def _assert_redacted_profile_error(self, operation, *profiles):
        caught = None
        try:
            operation()
        except Exception as error:
            caught = error
        if caught is None:
            self.fail("forged WireGuard profile was accepted")

        chain_text = self._exception_chain_text(caught)
        keys = {
            key
            for profile in profiles
            for key in (
                getattr(profile, "private_key", None),
                getattr(profile, "public_key", None),
                getattr(profile, "preshared_key", None),
            )
            if type(key) is str and key
        }
        self.assertFalse(
            any(key in chain_text for key in keys),
            "profile key material was retained by the exception chain",
        )
        self.assertTrue(
            isinstance(caught, airvpn_api.AirVPNAPIError),
            f"expected redacted AirVPNAPIError, got {type(caught).__name__}",
        )
        self.assertIsNone(caught.__cause__, "profile validation exposed a cause")
        self.assertIsNone(caught.__context__, "profile validation exposed context")
        return caught

    def _render(self, profile):
        self.assertTrue(
            hasattr(airvpn_api, "render_wireguard_profile"),
            "render_wireguard_profile is not implemented",
        )
        return airvpn_api.render_wireguard_profile(profile)

    def _compose(self, current, generated):
        self.assertTrue(
            hasattr(airvpn_api, "_compose_pinned_profile"),
            "_compose_pinned_profile is not implemented",
        )
        return airvpn_api._compose_pinned_profile(current, generated)

    def test_renderer_has_fixed_header_order_spacing_and_terminal_newline(self):
        profile = self._parse(_wireguard_profile())

        self.assertEqual(
            self._render(profile),
            (
                "# Generated by wg-healthcheck from validated AirVPN API data.\n"
                "[Interface]\n"
                "Address = 10.20.30.40/32\n"
                f"PrivateKey = {_dummy_wireguard_key(1)}\n"
                "MTU = 1320\n"
                "DNS = 10.128.0.1, 1.1.1.1\n"
                "Table = off\n"
                "\n"
                "[Peer]\n"
                f"PublicKey = {_dummy_wireguard_key(2)}\n"
                f"PresharedKey = {_dummy_wireguard_key(3)}\n"
                "Endpoint = 198.51.100.10:1637\n"
                "AllowedIPs = 0.0.0.0/0\n"
                "PersistentKeepalive = 15\n"
            ).encode("utf-8"),
        )

        forged_profiles = {
            "Address type": replace(profile, address=str(profile.address)),
            "MTU type": replace(profile, mtu="1320"),
            "DNS type": replace(profile, dns=list(profile.dns)),
            "DNS value": replace(profile, dns=("vpn.example.test",)),
            "Table type": replace(profile, table=123),
            "private key": replace(profile, private_key="not-a-key"),
            "public key": replace(profile, public_key="not-a-key"),
            "preshared key": replace(profile, preshared_key="not-a-key"),
            "Endpoint value": replace(
                profile,
                endpoint="198.51.100.10:1637\nPostUp = /usr/bin/id",
            ),
            "AllowedIPs type": replace(
                profile,
                allowed_ips=ipaddress.ip_network("0.0.0.0/0"),
            ),
            "keepalive type": replace(profile, persistent_keepalive="15"),
        }
        for label, forged in forged_profiles.items():
            with self.subTest(label=label):
                self._assert_redacted_profile_error(
                    lambda forged=forged: self._render(forged),
                    profile,
                    forged,
                )

    def test_parse_render_parse_is_stable(self):
        profile = self._parse(
            _wireguard_profile(
                dns=None,
                table=None,
                line_ending="\r\n",
                terminal_newline=False,
            )
        )

        rendered = self._render(profile)

        self.assertEqual(self._parse(rendered), profile)
        self.assertEqual(self._render(self._parse(rendered)), rendered)
        self.assertNotIn(b"DNS =", rendered)
        self.assertNotIn(b"Table =", rendered)

    def test_identity_compares_private_key_and_address_without_exposure(self):
        expected = self._parse(_wireguard_profile())
        peer_changed = self._parse(
            _wireguard_profile(
                dns=("9.9.9.9",),
                table="123",
                public_key=_dummy_wireguard_key(4),
                preshared_key=_dummy_wireguard_key(5),
                endpoint="198.51.100.11:47107",
            )
        )
        key_changed = self._parse(
            _wireguard_profile(private_key=_dummy_wireguard_key(6))
        )
        address_changed = self._parse(_wireguard_profile(address="10.20.30.41/32"))
        self.assertTrue(
            hasattr(airvpn_api, "profiles_have_same_identity"),
            "profiles_have_same_identity is not implemented",
        )
        original_compare_digest = airvpn_api.hmac.compare_digest
        compared_lengths = []

        def compare_digest_without_recording_keys(left, right):
            compared_lengths.append((len(left), len(right)))
            return original_compare_digest(left, right)

        with mock.patch.object(
            airvpn_api.hmac,
            "compare_digest",
            compare_digest_without_recording_keys,
        ):
            self.assertTrue(
                airvpn_api.profiles_have_same_identity(expected, peer_changed)
            )
            self.assertFalse(
                airvpn_api.profiles_have_same_identity(expected, key_changed)
            )
            self.assertFalse(
                airvpn_api.profiles_have_same_identity(expected, address_changed)
            )

        self.assertEqual(compared_lengths, [(44, 44), (44, 44), (44, 44)])

        private_key = expected.private_key

        class EvilAddress:
            def __eq__(self, _other):
                raise RuntimeError(f"address comparison retained {private_key}")

        oversized_key = _dummy_wireguard_key(9) * 2048
        forged_inputs = {
            "non-profile object": object(),
            "Address type": replace(expected, address=str(expected.address)),
            "raising Address equality": replace(expected, address=EvilAddress()),
            "private key type": replace(
                expected,
                private_key=expected.private_key.encode("ascii"),
            ),
            "MTU type": replace(expected, mtu="1320"),
            "DNS type": replace(expected, dns=list(expected.dns)),
            "oversized private key": replace(
                expected,
                private_key=oversized_key,
            ),
            "oversized public key": replace(
                expected,
                public_key=oversized_key,
            ),
            "oversized preshared key": replace(
                expected,
                preshared_key=oversized_key,
            ),
        }
        for label, forged in forged_inputs.items():
            operations = {
                "expected": lambda forged=forged: (
                    airvpn_api.profiles_have_same_identity(forged, expected)
                ),
                "candidate": lambda forged=forged: (
                    airvpn_api.profiles_have_same_identity(expected, forged)
                ),
            }
            for position, operation in operations.items():
                with self.subTest(label=label, position=position):
                    self._assert_redacted_profile_error(
                        operation,
                        expected,
                        forged,
                    )

    def test_identity_pinning_preserves_only_validated_table(self):
        current = self._parse(
            _wireguard_profile(
                dns=("9.9.9.9",),
                table="123",
                public_key=_dummy_wireguard_key(4),
                preshared_key=_dummy_wireguard_key(5),
                endpoint="198.51.100.9:1637",
            )
        )
        generated = self._parse(
            _wireguard_profile(
                dns=("10.128.0.1",),
                table="auto",
                public_key=_dummy_wireguard_key(6),
                preshared_key=_dummy_wireguard_key(7),
                endpoint="198.51.100.11:47107",
            )
        )

        pinned = self._compose(current, generated)

        self.assertEqual(pinned.address, current.address)
        self.assertEqual(pinned.private_key, current.private_key)
        self.assertEqual(pinned.table, "123")
        self.assertEqual(pinned.mtu, generated.mtu)
        self.assertEqual(pinned.dns, generated.dns)
        self.assertEqual(pinned.public_key, generated.public_key)
        self.assertEqual(pinned.preshared_key, generated.preshared_key)
        self.assertEqual(pinned.endpoint, generated.endpoint)
        self.assertEqual(pinned.allowed_ips, generated.allowed_ips)
        self.assertEqual(
            pinned.persistent_keepalive,
            generated.persistent_keepalive,
        )

        invalid_current_profiles = {
            "current Address type": replace(current, address=str(current.address)),
            "current private key": replace(current, private_key="not-a-key"),
            "current MTU type": replace(current, mtu="1320"),
            "current DNS type": replace(current, dns=list(current.dns)),
            "current Table value": replace(current, table="$(invalid)"),
            "current Table type": replace(current, table=123),
            "current public key": replace(current, public_key="not-a-key"),
            "current preshared key": replace(current, preshared_key="not-a-key"),
            "current Endpoint": replace(current, endpoint="vpn.example.test:1637"),
            "current AllowedIPs type": replace(
                current,
                allowed_ips=ipaddress.ip_network("0.0.0.0/0"),
            ),
            "current keepalive type": replace(
                current,
                persistent_keepalive="15",
            ),
        }
        for label, forged in invalid_current_profiles.items():
            with self.subTest(label=label):
                self._assert_redacted_profile_error(
                    lambda forged=forged: self._compose(forged, generated),
                    current,
                    generated,
                    forged,
                )

        invalid_generated_profiles = {
            "generated Address type": replace(
                generated,
                address=str(generated.address),
            ),
            "generated private key": replace(
                generated,
                private_key="not-a-key",
            ),
            "generated MTU type": replace(generated, mtu="1320"),
            "generated DNS type": replace(generated, dns=list(generated.dns)),
            "generated Table type": replace(generated, table=123),
            "generated public key": replace(generated, public_key="not-a-key"),
            "generated preshared key": replace(
                generated,
                preshared_key="not-a-key",
            ),
            "generated Endpoint": replace(
                generated,
                endpoint="vpn.example.test:47107",
            ),
            "generated AllowedIPs type": replace(
                generated,
                allowed_ips=ipaddress.ip_network("0.0.0.0/0"),
            ),
            "generated keepalive type": replace(
                generated,
                persistent_keepalive="15",
            ),
        }
        for label, forged in invalid_generated_profiles.items():
            with self.subTest(label=label):
                self._assert_redacted_profile_error(
                    lambda forged=forged: self._compose(current, forged),
                    current,
                    generated,
                    forged,
                )

    def test_pinning_renders_only_trusted_installed_hooks_with_repeats_and_order(self):
        hooks = (
            "  PostUp  = /usr/local/sbin/enable %i\\ ",
            "PostUp=/usr/local/sbin/confirm %i",
            "PostDown = /usr/local/sbin/remove %i",
        )
        installed = airvpn_api._parse_trusted_installed_profile(
            _wireguard_profile(
                table="123",
                interface_extra=hooks,
            )
        )
        generated = self._parse(
            _wireguard_profile(
                table="auto",
                public_key=_dummy_wireguard_key(4),
                preshared_key=_dummy_wireguard_key(5),
                endpoint="198.51.100.11:47107",
            )
        )

        self.assertTrue(
            hasattr(airvpn_api, "_render_trusted_pinned_profile"),
            "trusted pinned-profile renderer is not implemented",
        )
        pinned = self._compose(installed.profile, generated)
        rendered = airvpn_api._render_trusted_pinned_profile(installed, generated)

        expected_hook_lines = tuple(hook.encode("utf-8") for hook in hooks)
        rendered_hook_lines = tuple(
            line
            for line in rendered.splitlines()
            if line.strip().startswith((b"PostUp", b"PostDown"))
        )
        self.assertEqual(rendered_hook_lines, expected_hook_lines)
        reparsed = airvpn_api._parse_trusted_installed_profile(rendered)
        self.assertEqual(reparsed.profile, pinned)
        self.assertEqual(reparsed.interface_hooks, hooks)
        with self.assertRaises(airvpn_api.AirVPNAPIError):
            self._parse(rendered)

    def test_trusted_installed_hook_objects_are_strict_and_error_redacted(self):
        marker = "private-local-hook-marker"
        installed = airvpn_api._parse_trusted_installed_profile(
            _wireguard_profile(interface_extra=(f"PostUp = {marker}",))
        )
        generated = self._parse(_wireguard_profile())
        cases = {
            "hook collection type": replace(
                installed,
                interface_hooks=list(installed.interface_hooks),
            ),
            "hook line type": replace(
                installed,
                interface_hooks=(f"PostUp = {marker}".encode("ascii"),),
            ),
            "missing equals": replace(
                installed,
                interface_hooks=(f"PostUp {marker}",),
            ),
            "hook name": replace(
                installed,
                interface_hooks=(f"PreUp = {marker}",),
            ),
            "empty hook": replace(
                installed,
                interface_hooks=("PostUp = ",),
            ),
            "control character": replace(
                installed,
                interface_hooks=(f"PostDown = {marker}\n/usr/bin/id",),
            ),
            "oversized hook": replace(
                installed,
                interface_hooks=("PostUp = " + marker + ("x" * 1024),),
            ),
            "too many hooks": replace(
                installed,
                interface_hooks=tuple(f"PostUp = {marker}" for _ in range(64)),
            ),
            "profile type": replace(installed, profile=object()),
        }

        for label, forged in cases.items():
            with self.subTest(label=label):
                caught = self._assert_redacted_profile_error(
                    lambda forged=forged: airvpn_api._render_trusted_pinned_profile(
                        forged,
                        generated,
                    ),
                    installed.profile,
                    generated,
                )
                self.assertNotIn(marker, repr(forged))
                self.assertNotIn(marker, self._exception_chain_text(caught))

    def test_profile_and_manifest_repr_are_redacted(self):
        profile = self._parse(_wireguard_profile())
        safe_preview = {"status": "validated", "profile": profile}

        changed_identity = replace(
            profile,
            private_key=_dummy_wireguard_key(4),
        )
        caught = self._assert_redacted_profile_error(
            lambda: self._compose(profile, changed_identity),
            profile,
            changed_identity,
        )

        for secret in (
            profile.private_key,
            profile.preshared_key,
            _dummy_wireguard_key(4),
        ):
            self.assertNotIn(secret, repr(profile))
            self.assertNotIn(secret, repr(safe_preview))
            self.assertNotIn(secret, repr(caught))
            self.assertNotIn(secret, str(caught))

        surrogate_profile = replace(
            profile,
            endpoint=f"{profile.endpoint}\ud800",
        )
        self._assert_redacted_profile_error(
            lambda: self._render(surrogate_profile),
            profile,
            surrogate_profile,
        )
