import base64
from dataclasses import FrozenInstanceError, replace
import importlib.machinery
import importlib.util
import io
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.error
import urllib.request


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


def _dummy_wireguard_key(value):
    return base64.b64encode(bytes([value]) * 32).decode("ascii")


def _wireguard_profile(
    *,
    address="10.20.30.40/32",
    private_key=None,
    mtu="1320",
    dns=("10.128.0.1", "1.1.1.1"),
    table="off",
    public_key=None,
    preshared_key=None,
    endpoint="198.51.100.10:1637",
    allowed_ips="0.0.0.0/0",
    persistent_keepalive="15",
    interface_extra=(),
    peer_extra=(),
    trailer=(),
    line_ending="\n",
    terminal_newline=True,
):
    private_key = private_key or _dummy_wireguard_key(1)
    public_key = public_key or _dummy_wireguard_key(2)
    preshared_key = preshared_key or _dummy_wireguard_key(3)
    lines = [
        "# Redacted provider-success shape",
        "[Interface]",
        f"Address = {address}",
        f"PrivateKey = {private_key}",
        f"MTU = {mtu}",
    ]
    if dns is not None:
        lines.append(f"DNS = {', '.join(dns)}")
    if table is not None:
        lines.append(f"Table = {table}")
    lines.extend(interface_extra)
    lines.extend(
        [
            "",
            "[Peer]",
            f"PublicKey = {public_key}",
            f"PresharedKey = {preshared_key}",
            f"Endpoint = {endpoint}",
            f"AllowedIPs = {allowed_ips}",
            f"PersistentKeepalive = {persistent_keepalive}",
        ]
    )
    lines.extend(peer_extra)
    lines.extend(trailer)
    text = line_ending.join(lines)
    if terminal_newline:
        text += line_ending
    return text.encode("utf-8")


def _random_wireguard_key():
    value = bytearray(secrets.token_bytes(32))
    if not any(value):
        value[0] = 1
    return base64.b64encode(value).decode("ascii")


def _generator_profile(**overrides):
    values = {
        "private_key": _random_wireguard_key(),
        "public_key": _random_wireguard_key(),
        "preshared_key": _random_wireguard_key(),
    }
    values.update(overrides)
    return _wireguard_profile(**values)


class _TrackedBytesIO(io.BytesIO):
    def __init__(self, value=b""):
        super().__init__(value)
        self.read_calls = []
        self.write_calls = []
        self.snapshot = value

    def read(self, size=-1):
        self.read_calls.append(size)
        return super().read(size)

    def write(self, value):
        self.write_calls.append(bytes(value))
        return super().write(value)

    def close(self):
        if not self.closed:
            self.snapshot = self.getvalue()
        super().close()


class _Response(_TrackedBytesIO):
    def __init__(self, payload, *, content_type="text/plain", content_encoding=None):
        super().__init__(payload)
        self.status = 200
        self.headers = {}
        if content_type is not None:
            self.headers["Content-Type"] = content_type
        if content_encoding is not None:
            self.headers["Content-Encoding"] = content_encoding

    def getcode(self):
        return self.status

    def __enter__(self):
        return self

    def __exit__(self, _error_type, _error, _traceback):
        self.close()
        return False


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
    ):
        key_stream = _TrackedBytesIO(self.API_KEY if key is None else key)
        output_stream = _TrackedBytesIO()
        streams = {3: key_stream, 4: output_stream}
        if installed_profile is not None:
            streams[5] = _TrackedBytesIO(installed_profile)
        fdopen_calls = []

        def fake_fdopen(fd, mode, *, closefd=True):
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
        with mock.patch.object(
            airvpn_api, "os", wraps=os, create=True
        ) as helper_os, mock.patch.object(
            airvpn_api.urllib.request, "build_opener", return_value=opener
        ) as build_opener, mock.patch.object(
            sys, "stdout", stdout
        ), mock.patch.object(
            sys, "stderr", stderr
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
            "?system=linux"
            "&protocols=wireguard_1_udp_1637"
            "&servers=Mensa-1"
            "&device=My%20Device_1.0"
            "&resolve=on"
            "&iplayer_entry=ipv4"
            "&iplayer_exit=ipv4"
            "&wireguard_mtu=1320"
            "&wireguard_persistent_keepalive=15",
        )
        headers = {
            name.lower(): value for name, value in request.header_items()
        }
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
                        _generator_profile(
                            endpoint=f"198.51.100.10:{port}"
                        )
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
            ("Server", "Dévice", "198.51.100.10:1637"),
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

    def test_response_mime_encoding_status_and_size_are_fail_closed(self):
        for content_type in ("text/plain", "application/octet-stream"):
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
        rejected = (
            _Response(_generator_profile(), content_type=None),
            _Response(_generator_profile(), content_type="text/html"),
            _Response(_generator_profile(), content_type="application/zip"),
            _Response(
                _generator_profile(),
                content_type="text/plain",
                content_encoding="gzip",
            ),
            _Response(b"x" * ((64 * 1024) + 1)),
            wrong_status,
        )
        for response in rejected:
            with self.subTest(headers=response.headers, status=response.status):
                result = self._run_generator(response=response)
                self.assertEqual(result.return_code, 6)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.output_stream.write_calls, [])
                self.assertTrue(response.closed)

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
                self.assertEqual(result.stdout, "")
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
                self.assertNotIn("sentinel", result.stderr)
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

    def test_pin_identity_reads_fd5_and_preserves_only_local_table(self):
        private_key = _random_wireguard_key()
        address = "10.20.30.40/32"
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
        rendered = airvpn_api.parse_wireguard_profile(
            result.output_stream.snapshot,
            expected_endpoint="198.51.100.10:1637",
        )
        self.assertEqual(rendered.private_key, private_key)
        self.assertEqual(str(rendered.address), address)
        self.assertEqual(rendered.table, "123")
        self.assertEqual(result.installed_stream.read_calls, [(64 * 1024) + 1])
        self.assertTrue(result.installed_stream.closed)
        self.assertEqual(
            result.fdopen_calls,
            [(3, "rb", True), (4, "wb", True), (5, "rb", True)],
        )

    def test_identity_mismatch_never_writes_candidate_and_returns_seven(self):
        generated = _generator_profile(endpoint="198.51.100.10:1637")
        installed = _generator_profile(endpoint="198.51.100.9:1637")
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
        for profile in (generated, installed):
            parsed = airvpn_api.parse_wireguard_profile(profile)
            for secret in (
                parsed.private_key,
                parsed.public_key,
                parsed.preshared_key,
            ):
                self.assertNotIn(secret, result.stderr)

    def test_validation_failure_writes_no_partial_candidate_or_secret_output(self):
        profile = _generator_profile(endpoint="198.51.100.11:1637")
        sentinel = self.API_KEY[:-1].decode("ascii")
        result = self._run_generator(response=_Response(profile))

        self.assertEqual(result.return_code, 6)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.output_stream.write_calls, [])
        self.assertEqual(result.output_stream.snapshot, b"")
        self.assertNotIn(sentinel, result.stderr)
        for secret in (
            airvpn_api.parse_wireguard_profile(profile).private_key,
            airvpn_api.parse_wireguard_profile(profile).public_key,
            airvpn_api.parse_wireguard_profile(profile).preshared_key,
        ):
            self.assertNotIn(secret, result.stderr)

    def test_classified_exception_chain_does_not_retain_secret_detail(self):
        sentinel = "b" * 64
        request = urllib.request.Request(
            "https://airvpn.org/api/generator/?system=linux",
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
        profile_read, profile_write = os.pipe()
        parent_socket, child_socket = socket.socketpair()
        targets = {
            3: key_read,
            4: profile_write,
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
            os.close(profile_write)
            profile_write = -1
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
            self.assertEqual(os.read(profile_read, (64 * 1024) + 1), b"")
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate()
            for descriptor in (key_read, key_write, profile_read, profile_write):
                if descriptor >= 0:
                    os.close(descriptor)
            parent_socket.close()
            child_socket.close()


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
            "PostDown": _wireguard_profile(interface_extra=("PostDown = /usr/bin/true",)),
            "unknown": _wireguard_profile(interface_extra=("Unknown = value",)),
            "shell syntax": _wireguard_profile(table="$(touch /tmp/provider-command)"),
        }

        for label, payload in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self._parse(payload)

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
            "noncanonical keepalive": _wireguard_profile(
                persistent_keepalive="015"
            ),
            "additional route": _wireguard_profile(
                allowed_ips="0.0.0.0/0, ::/0"
            ),
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
        address_changed = self._parse(
            _wireguard_profile(address="10.20.30.41/32")
        )
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
        with mock.patch(
            "builtins.open", side_effect=AssertionError("credential opened")
        ), mock.patch.object(
            airvpn_api.urllib.request, "build_opener", return_value=opener
        ), mock.patch.object(sys, "stdout", stdout), mock.patch.object(
            sys, "stderr", stderr
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
            with self.subTest(country_name=repr(country_name)), self.assertRaises(
                ValueError
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
