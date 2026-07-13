from tests.airvpn_api_test_support import *

class GeneratorBoundaryTests(unittest.TestCase):
    API_KEY = ("a" * 64 + "\n").encode("ascii")
    BASE_ARGS = (
        "generate-profile",
        "--server",
        "Mensa-1",
        "--device",
        "My Device_1.0",
        "--expected-endpoint",
        "198.51.100.10:1637",
        "--timeout",
        "1",
    )

    def _run_generator(
        self,
        *,
        args=None,
        key=None,
        response=None,
        opener_error=None,
        installed_profile=None,
        output_stream=None,
    ):
        key_stream = _TrackedBytesIO(self.API_KEY if key is None else key)
        output_stream = output_stream or _TrackedBytesIO()
        streams = {3: key_stream, 4: output_stream}
        if installed_profile is not None:
            streams[5] = _TrackedBytesIO(installed_profile)
        fdopen_calls = []

        def fake_fdopen(fd, mode, *args, closefd=True, **kwargs):
            fdopen_calls.append((fd, mode, closefd))
            if fd not in streams:
                raise OSError("descriptor unavailable")
            return streams[fd]

        opener = mock.Mock()
        if opener_error is not None:
            opener.open.side_effect = opener_error
        else:
            opener.open.return_value = response or _Response(_generator_profile())

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(airvpn_api, "os", wraps=os, create=True) as helper_os,
            mock.patch.object(
                airvpn_api.urllib.request, "build_opener", return_value=opener
            ) as build_opener,
            mock.patch.object(sys, "stdout", stdout),
            mock.patch.object(sys, "stderr", stderr),
        ):
            helper_os.fdopen.side_effect = fake_fdopen
            return_code = airvpn_api.main(list(args or self.BASE_ARGS))

        return SimpleNamespace(
            return_code=return_code,
            stdout=stdout.getvalue(),
            stderr=stderr.getvalue(),
            opener=opener,
            build_opener=build_opener,
            fdopen_calls=fdopen_calls,
            key_stream=key_stream,
            output_stream=output_stream,
            installed_stream=streams.get(5),
        )

    def _direct_generator_error(
        self,
        *,
        key=None,
        installed_profile=None,
        opener_error=None,
        response=None,
    ):
        streams = {
            3: _TrackedBytesIO(self.API_KEY if key is None else key),
            4: _TrackedBytesIO(),
        }
        if installed_profile is not None:
            streams[5] = _TrackedBytesIO(installed_profile)

        def fake_fdopen(fd, mode, *args, closefd=True, **kwargs):
            return streams[fd]

        opener = mock.Mock()
        if opener_error is not None:
            opener.open.side_effect = opener_error
        else:
            opener.open.return_value = response or _Response(_generator_profile())

        caught = None
        with (
            mock.patch.object(airvpn_api, "os", wraps=os, create=True) as helper_os,
            mock.patch.object(
                airvpn_api.urllib.request, "build_opener", return_value=opener
            ),
        ):
            helper_os.fdopen.side_effect = fake_fdopen
            try:
                airvpn_api.generate_profile(
                    "Mensa-1",
                    "Device",
                    "198.51.100.10:1637",
                    1,
                    installed_profile is not None,
                )
            except Exception as error:
                caught = error
        self.assertIsNotNone(caught, "generator unexpectedly succeeded")
        return caught, opener, streams

    def _assert_module_error_graph_redacted(self, error, *markers):
        self.assertIsNone(error.__cause__)
        self.assertIsNone(error.__context__)
        values = []
        seen_values = set()

        def collect(value, depth=0):
            if depth > 6 or id(value) in seen_values:
                return
            seen_values.add(id(value))
            if isinstance(value, bytes):
                values.append(value.decode("latin-1"))
                return
            if isinstance(value, str):
                values.append(value)
                return
            if isinstance(value, urllib.request.Request):
                values.append(value.full_url)
                for name, header_value in value.header_items():
                    collect(name, depth + 1)
                    collect(header_value, depth + 1)
                return
            if isinstance(value, dict):
                for key, item in value.items():
                    collect(key, depth + 1)
                    collect(item, depth + 1)
                return
            if isinstance(value, (tuple, list, set, frozenset)):
                for item in value:
                    collect(item, depth + 1)
                return
            if isinstance(value, _TrackedBytesIO):
                collect(value.snapshot, depth + 1)
                return
            namespace = getattr(value, "__dict__", None)
            if isinstance(namespace, dict):
                collect(namespace, depth + 1)

        pending = [error]
        seen_errors = set()
        while pending:
            current = pending.pop()
            if current is None or id(current) in seen_errors:
                continue
            seen_errors.add(id(current))
            collect(repr(current))
            collect(str(current))
            traceback = current.__traceback__
            while traceback is not None:
                frame = traceback.tb_frame
                if frame.f_globals.get("__name__") == airvpn_api.__name__:
                    collect(frame.f_locals)
                traceback = traceback.tb_next
            pending.extend((current.__cause__, current.__context__))

        reachable = "\n".join(values)
        for marker in markers:
            if isinstance(marker, bytes):
                marker = marker.decode("latin-1")
            self.assertNotIn(marker, reachable)

    def test_generate_profile_uses_exact_fixed_request_and_safe_manifest(self):
        profile = _generator_profile(endpoint="198.51.100.10:1637")
        response = _Response(profile, content_type="text/plain")

        result = self._run_generator(response=response)

        self.assertEqual(result.return_code, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "generated\tMensa-1\t198.51.100.10:1637\tpinned=0\n",
        )
        self.assertEqual(result.stderr, "")
        request = result.opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(
            request.full_url,
            "https://airvpn.org/api/generator/"
            "?system=other"
            "&protocols=wireguard_1_udp_1637"
            "&servers=Mensa-1"
            "&device=My%20Device_1.0"
            "&resolve=on"
            "&iplayer_entry=ipv4"
            "&iplayer_exit=ipv4"
            "&wireguard_mtu=1320"
            "&wireguard_persistent_keepalive=15",
        )
        headers = {name.lower(): value for name, value in request.header_items()}
        self.assertEqual(headers["api-key"], self.API_KEY[:-1].decode("ascii"))
        self.assertEqual(headers["user-agent"], "wg-healthcheck/airvpn")
        self.assertEqual(result.opener.open.call_args.kwargs, {"timeout": 1.0})
        self.assertEqual(len(result.build_opener.call_args.args), 1)
        redirect_handler = result.build_opener.call_args.args[0]
        self.assertIsNone(
            redirect_handler.redirect_request(
                request,
                None,
                302,
                "redirect",
                {},
                "https://airvpn.org/elsewhere",
            )
        )
        self.assertEqual(response.read_calls, [(64 * 1024) + 1])
        self.assertTrue(response.closed)
        self.assertEqual(result.key_stream.read_calls, [66])
        self.assertEqual(
            result.output_stream.write_calls,
            [
                airvpn_api.render_wireguard_profile(
                    airvpn_api.parse_wireguard_profile(
                        profile,
                        expected_endpoint="198.51.100.10:1637",
                    )
                )
            ],
        )
        self.assertEqual(result.fdopen_calls, [(3, "rb", True), (4, "wb", True)])
        self.assertTrue(result.key_stream.closed)
        self.assertTrue(result.output_stream.closed)

    def test_generator_accepts_only_documented_ports_and_bounded_names(self):
        valid_cases = (
            (
                "1637",
                "Server-1",
                "Device 1._-",
            ),
            ("47107", "Server2", "D"),
            ("51820", "S" * 64, "D" * 64),
        )
        for port, server, device in valid_cases:
            args = (
                "generate-profile",
                "--server",
                server,
                "--device",
                device,
                "--expected-endpoint",
                f"198.51.100.10:{port}",
            )
            with self.subTest(port=port, server=server, device=device):
                result = self._run_generator(
                    args=args,
                    response=_Response(
                        _generator_profile(endpoint=f"198.51.100.10:{port}")
                    ),
                )
                self.assertEqual(result.return_code, 0, result.stderr)

        invalid_cases = (
            ("", "Device", "198.51.100.10:1637"),
            ("Server/1", "Device", "198.51.100.10:1637"),
            ("S" * 65, "Device", "198.51.100.10:1637"),
            ("Server", " device", "198.51.100.10:1637"),
            ("Server", "Device/1", "198.51.100.10:1637"),
            ("Server", "D" * 65, "198.51.100.10:1637"),
            ("Server", "DÃ©vice", "198.51.100.10:1637"),
            ("Server", "Device", "198.51.100.10:443"),
            ("Server", "Device", "198.51.100.10:01637"),
            ("Server", "Device", "vpn.example.test:1637"),
            ("Server", "Device", "[2001:db8::1]:1637"),
        )
        for server, device, endpoint in invalid_cases:
            args = (
                "generate-profile",
                "--server",
                server,
                "--device",
                device,
                "--expected-endpoint",
                endpoint,
            )
            with self.subTest(server=server, device=device, endpoint=endpoint):
                result = self._run_generator(args=args)
                self.assertEqual(result.return_code, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.fdopen_calls, [])
                result.opener.open.assert_not_called()

    def test_api_key_is_exact_lowercase_hex_line_and_never_echoed(self):
        invalid_keys = (
            b"a" * 63 + b"\n",
            b"A" * 64 + b"\n",
            b"g" * 64 + b"\n",
            b"a" * 64,
            b"a" * 64 + b"\r\n",
            b"a" * 64 + b"\nextra\n",
            b"\xff" * 64 + b"\n",
        )
        for key in invalid_keys:
            with self.subTest(length=len(key), prefix=key[:1]):
                result = self._run_generator(key=key)
                self.assertEqual(result.return_code, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.output_stream.write_calls, [])
                result.opener.open.assert_not_called()
                self.assertTrue(result.key_stream.closed)
                self.assertTrue(result.output_stream.closed)
                try:
                    secret_text = key.decode("ascii").strip()
                except UnicodeDecodeError:
                    secret_text = ""
                if secret_text:
                    self.assertNotIn(secret_text, result.stderr)

    def test_json_error_on_http_200_is_classified_without_remote_text(self):
        remote_secret = "provider-secret-detail-should-not-escape"
        payload = json.dumps(
            {"result": "error", "error": remote_secret, "device": "missing"}
        ).encode("utf-8")
        for content_type in ("application/json", "text/plain"):
            with self.subTest(content_type=content_type):
                result = self._run_generator(
                    response=_Response(payload, content_type=content_type)
                )
                self.assertEqual(result.return_code, 4)
                self.assertEqual(result.stdout, "")
                self.assertNotIn(remote_secret, result.stderr)
                self.assertEqual(result.output_stream.write_calls, [])

    def test_http_and_timeout_failures_have_stable_exit_classes(self):
        cases = (
            (302, 6),
            (408, 6),
            (401, 4),
            (403, 4),
            (404, 4),
            (429, 5),
            (500, 6),
            (503, 6),
        )
        for status, expected_exit in cases:
            body = _TrackedBytesIO(b"remote-body-must-not-escape")
            error = urllib.error.HTTPError(
                "https://airvpn.org/api/generator/",
                status,
                "remote-reason-must-not-escape",
                {},
                body,
            )
            with self.subTest(status=status):
                result = self._run_generator(opener_error=error)
                self.assertEqual(result.return_code, expected_exit)
                expected_stdout = (
                    "failure\ttransient\tphase=transport\n"
                    if expected_exit == 6
                    else ""
                )
                self.assertEqual(result.stdout, expected_stdout)
                self.assertNotIn("remote", result.stderr)
                self.assertEqual(result.output_stream.write_calls, [])
                self.assertTrue(body.closed)

        for error in (
            TimeoutError("sentinel timeout detail"),
            socket.timeout("sentinel timeout detail"),
            urllib.error.URLError(socket.timeout("sentinel timeout detail")),
        ):
            with self.subTest(error=type(error).__name__):
                result = self._run_generator(opener_error=error)
                self.assertEqual(result.return_code, 6)
                self.assertEqual(result.stdout, "failure\ttransient\tphase=transport\n")
                self.assertNotIn("sentinel", result.stderr)
                self.assertEqual(result.output_stream.write_calls, [])

    def test_http_protocol_json_depth_and_close_failures_are_transient(self):
        marker = b"http-partial-private-marker"
        cases = (
            ({"opener_error": http.client.BadStatusLine(marker.decode("ascii"))}, "transport"),
            ({"response": _IncompleteReadResponse(marker)}, "protocol"),
            ({"response": _CloseFailureResponse(marker)}, "protocol"),
            (
                {
                    "response": _Response(
                        (b"[" * 2000) + b"0" + (b"]" * 2000),
                        content_type="application/json",
                    )
                },
                "json",
            ),
        )
        for case, reason in cases:
            with self.subTest(case=tuple(case)):
                result = self._run_generator(**case)
                self.assertEqual(result.return_code, 6)
                phase = "transport" if "opener_error" in case else "response"
                expected = f"failure\ttransient\tphase={phase}\n"
                if phase == "response":
                    expected = f"{expected[:-1]}\treason={reason}\n"
                self.assertEqual(result.stdout, expected)
                self.assertNotIn(marker.decode("ascii"), result.stderr)
                self.assertEqual(result.output_stream.write_calls, [])

    def test_timeout_and_missing_pin_descriptor_fail_before_request(self):
        for timeout in ("0", "60.1", "nan", "inf", "not-a-timeout"):
            args = self.BASE_ARGS[:-1] + (timeout,)
            with self.subTest(timeout=timeout):
                result = self._run_generator(args=args)
                self.assertEqual(result.return_code, 2)
                self.assertEqual(result.fdopen_calls, [])
                result.opener.open.assert_not_called()

        result = self._run_generator(args=self.BASE_ARGS + ("--pin-identity",))
        self.assertEqual(result.return_code, 2)
        self.assertEqual(result.stdout, "")
        result.opener.open.assert_not_called()
        self.assertTrue(result.key_stream.closed)
        self.assertTrue(result.output_stream.closed)

    def test_retry_after_accepts_only_canonical_decimal_day_bound(self):
        for value in ("0", "1", "86400"):
            error = urllib.error.HTTPError(
                "https://airvpn.org/api/generator/",
                429,
                "limited",
                {"Retry-After": value},
                _TrackedBytesIO(),
            )
            with self.subTest(valid=value):
                result = self._run_generator(opener_error=error)
                self.assertEqual(result.return_code, 5)
                self.assertIn(f"retry_after={value}", result.stderr)

        for value in (
            "00",
            "01",
            "+1",
            "-1",
            "1.0",
            " 1 ",
            "86401",
            "Wed, 21 Oct 2015 07:28:00 GMT",
        ):
            error = urllib.error.HTTPError(
                "https://airvpn.org/api/generator/",
                429,
                "limited",
                {"Retry-After": value},
                _TrackedBytesIO(),
            )
            with self.subTest(invalid=value):
                result = self._run_generator(opener_error=error)
                self.assertEqual(result.return_code, 5)
                self.assertNotIn("retry_after=", result.stderr)
                self.assertNotIn(value, result.stderr)

        huge_value = "9" * 100000
        error = urllib.error.HTTPError(
            "https://airvpn.org/api/generator/",
            429,
            "limited",
            {"Retry-After": huge_value},
            _TrackedBytesIO(),
        )
        result = self._run_generator(opener_error=error)
        self.assertEqual(result.return_code, 5)
        self.assertNotIn("retry_after=", result.stderr)
        self.assertNotIn(huge_value, result.stderr)

    def test_pin_identity_reads_fd5_and_preserves_local_table_and_post_hooks(self):
        private_key = _random_wireguard_key()
        address = "10.20.30.40/32"
        hooks = (
            "  PostUp  = /usr/local/sbin/route-enable %i\\ ",
            "PostUp=/usr/local/sbin/route-confirm %i",
            "PostDown = /usr/local/sbin/route-remove %i",
        )
        generated = _generator_profile(
            private_key=private_key,
            address=address,
            table="auto",
            endpoint="198.51.100.10:1637",
        )
        installed = _generator_profile(
            private_key=private_key,
            address=address,
            table="123",
            endpoint="198.51.100.9:1637",
            interface_extra=hooks,
        )
        args = self.BASE_ARGS + ("--pin-identity",)

        result = self._run_generator(
            args=args,
            response=_Response(generated),
            installed_profile=installed,
        )

        self.assertEqual(result.return_code, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "generated\tMensa-1\t198.51.100.10:1637\tpinned=1\n",
        )
        rendered = airvpn_api._parse_trusted_installed_profile(result.output_stream.snapshot)
        self.assertEqual(rendered.profile.private_key, private_key)
        self.assertEqual(str(rendered.profile.address), address)
        self.assertEqual(rendered.profile.table, "123")
        self.assertEqual(rendered.interface_hooks, hooks)
        with self.assertRaises(airvpn_api.AirVPNAPIError):
            airvpn_api.parse_wireguard_profile(result.output_stream.snapshot)
        self.assertEqual(result.installed_stream.read_calls, [(64 * 1024) + 1])
        self.assertTrue(result.installed_stream.closed)
        self.assertEqual(
            result.fdopen_calls,
            [(3, "rb", True), (4, "wb", True), (5, "rb", True)],
        )

    def test_identity_mismatch_never_writes_candidate_and_returns_seven(self):
        hook_marker = "mismatched-fd5-hook-marker"
        generated = _generator_profile(endpoint="198.51.100.10:1637")
        installed = _generator_profile(
            endpoint="198.51.100.9:1637",
            interface_extra=(f"PostUp = {hook_marker}",),
        )
        result = self._run_generator(
            args=self.BASE_ARGS + ("--pin-identity",),
            response=_Response(generated),
            installed_profile=installed,
        )

        self.assertEqual(result.return_code, 7)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.output_stream.write_calls, [])
        self.assertTrue(result.key_stream.closed)
        self.assertTrue(result.output_stream.closed)
        self.assertTrue(result.installed_stream.closed)
        self.assertNotIn(hook_marker, result.stderr)
        for parsed in (
            airvpn_api.parse_wireguard_profile(generated),
            airvpn_api._parse_trusted_installed_profile(installed).profile,
        ):
            for secret in (
                parsed.private_key,
                parsed.public_key,
                parsed.preshared_key,
            ):
                self.assertNotIn(secret, result.stderr)

    def test_validation_failure_writes_no_partial_candidate_or_secret_output(self):
        strict_profile = _generator_profile(endpoint="198.51.100.10:1637")
        profile = strict_profile.replace(
            b"\n\n[Peer]",
            b"\nPostUp = provider-hook-must-not-run\n\n[Peer]",
        )
        sentinel = self.API_KEY[:-1].decode("ascii")
        result = self._run_generator(response=_Response(profile))

        self.assertEqual(result.return_code, 6)
        self.assertEqual(result.stdout, "failure\ttransient\tphase=profile\n")
        self.assertEqual(result.output_stream.write_calls, [])
        self.assertEqual(result.output_stream.snapshot, b"")
        self.assertNotIn(sentinel, result.stderr)
        for secret in (
            airvpn_api.parse_wireguard_profile(strict_profile).private_key,
            airvpn_api.parse_wireguard_profile(strict_profile).public_key,
            airvpn_api.parse_wireguard_profile(strict_profile).preshared_key,
        ):
            self.assertNotIn(secret, result.stderr)

    def test_secret_failures_raise_only_from_secret_free_module_frames(self):
        payload_marker = b"fd5-invalid-payload-marker"
        hook_marker = b"fd5-private-hook-marker"
        installed = _wireguard_profile(
            interface_extra=(
                f"PostUp = {hook_marker.decode('ascii')}",
                f"Unknown = {payload_marker.decode('ascii')}",
            )
        )
        profile_keys = tuple(_dummy_wireguard_key(value) for value in range(1, 4))

        caught, opener, _streams = self._direct_generator_error(
            installed_profile=installed
        )

        self.assertIs(type(caught), airvpn_api.AirVPNAPIError)
        opener.open.assert_not_called()
        self._assert_module_error_graph_redacted(
            caught,
            payload_marker,
            hook_marker,
            *profile_keys,
        )

        api_key = ("c" * 64 + "\n").encode("ascii")
        caught, _opener, _streams = self._direct_generator_error(
            key=api_key,
            opener_error=urllib.error.URLError(
                f"network failure carrying {api_key[:-1].decode('ascii')}"
            ),
        )
        self.assertIsInstance(caught, airvpn_api.GeneratorTransientError)
        self._assert_module_error_graph_redacted(caught, api_key[:-1])

        caught, _opener, _streams = self._direct_generator_error(
            key=api_key,
            opener_error=RuntimeError(
                f"unexpected failure carrying {api_key[:-1].decode('ascii')}"
            ),
        )
        self.assertIsInstance(caught, airvpn_api.GeneratorTransientError)
        self._assert_module_error_graph_redacted(caught, api_key[:-1])

    def test_fd4_must_stage_and_is_emptied_after_write_or_flush_failure(self):
        nonseekable = _NonSeekableOutput()
        result = self._run_generator(output_stream=nonseekable)
        self.assertEqual(result.return_code, 2)
        result.opener.open.assert_not_called()
        self.assertEqual(nonseekable.snapshot, b"")

        for output in (_ShortWriteOutput(), _FlushFailureOutput()):
            with self.subTest(output=type(output).__name__):
                result = self._run_generator(output_stream=output)
                self.assertEqual(result.return_code, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(output.snapshot, b"")

        stale = _TrackedBytesIO(b"x" * 100000)
        result = self._run_generator(output_stream=stale)
        self.assertEqual(result.return_code, 0, result.stderr)
        self.assertEqual(
            stale.snapshot,
            result.output_stream.write_calls[0],
        )

    def test_classified_exception_chain_does_not_retain_secret_detail(self):
        sentinel = "b" * 64
        request = urllib.request.Request(
            "https://airvpn.org/api/generator/?system=other",
            headers={"API-KEY": sentinel},
        )
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.URLError(
            f"network detail containing {sentinel}"
        )

        caught = None
        with mock.patch.object(
            airvpn_api.urllib.request, "build_opener", return_value=opener
        ):
            try:
                airvpn_api._open_generator_response(request, 1.0)
            except Exception as error:
                caught = error

        self.assertIsInstance(caught, airvpn_api.GeneratorTransientError)
        pending = [caught]
        seen = set()
        text = []
        while pending:
            error = pending.pop()
            if error is None or id(error) in seen:
                continue
            seen.add(id(error))
            text.extend((repr(error), str(error)))
            pending.extend((error.__cause__, error.__context__))
        self.assertNotIn(sentinel, "\n".join(text))

    @unittest.skipUnless(
        os.name == "posix" and Path("/proc/self/cmdline").exists(),
        "Linux /proc descriptor-sentinel proof",
    )
    def test_sentinel_key_is_absent_from_process_surfaces(self):
        sentinel = ("d" * 64 + "\n").encode("ascii")
        key_read, key_write = os.pipe()
        profile_file = tempfile.TemporaryFile()
        parent_socket, child_socket = socket.socketpair()
        targets = {
            3: key_read,
            4: profile_file.fileno(),
            6: child_socket.fileno(),
        }

        wrapper = (
            "import fcntl,importlib.machinery,importlib.util,os,sys;"
            f"src={tuple(targets.values())!r};dst={tuple(targets)!r};"
            "copies=[fcntl.fcntl(fd,fcntl.F_DUPFD,10) for fd in src];"
            "[(os.dup2(fd,target,inheritable=True)) "
            "for fd,target in zip(copies,dst)];"
            f"p={str(HELPER)!r};"
            "l=importlib.machinery.SourceFileLoader('airvpn_api_proc',p);"
            "s=importlib.util.spec_from_loader(l.name,l);"
            "m=importlib.util.module_from_spec(s);l.exec_module(m);"
            "O=type('O',(),{'open':lambda self,*a,**k:"
            "(os.write(6,b'R'),os.read(6,1),(_ for _ in ()).throw(TimeoutError()))[-1]});"
            "m.urllib.request.build_opener=lambda *a:O();"
            "sys.exit(m.main(['generate-profile','--server','Mensa-1',"
            "'--device','Device','--expected-endpoint','198.51.100.10:1637']))"
        )
        process = None
        try:
            process = subprocess.Popen(
                [sys.executable, "-c", wrapper],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pass_fds=tuple(targets.values()),
            )
            os.close(key_read)
            key_read = -1
            child_socket.close()
            os.write(key_write, sentinel)
            os.close(key_write)
            key_write = -1
            parent_socket.settimeout(5)
            ready = parent_socket.recv(1)
            if ready != b"R":
                stdout, stderr = process.communicate(timeout=5)
                self.fail(
                    "sentinel child did not reach request boundary: "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )

            cmdline = Path(f"/proc/{process.pid}/cmdline").read_bytes()
            environ = Path(f"/proc/{process.pid}/environ").read_bytes()
            self.assertNotIn(sentinel[:-1], cmdline)
            self.assertNotIn(sentinel[:-1], environ)
            self.assertNotIn(sentinel[:-1], wrapper.encode("utf-8"))

            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertNotIn(sentinel[:-1], stdout)
            self.assertNotIn(sentinel[:-1], stderr)
            profile_file.seek(0)
            self.assertEqual(profile_file.read((64 * 1024) + 1), b"")
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate()
            for descriptor in (key_read, key_write):
                if descriptor >= 0:
                    os.close(descriptor)
            profile_file.close()
            parent_socket.close()
            child_socket.close()
