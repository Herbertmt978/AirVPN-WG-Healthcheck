import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "bin" / "wg-healthcheck-setup"
SENTINEL = "f" * 64


def _load_setup():
    loader = importlib.machinery.SourceFileLoader(
        "wg_healthcheck_setup_entrypoint", str(SETUP)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


setup = _load_setup()


def _countries():
    return (
        setup.Country("GB", "United Kingdom", 3),
        setup.Country("NL", "Netherlands", 2),
        setup.Country("SE", "Sweden", 1),
    )


class SetupCliTests(unittest.TestCase):
    def test_entrypoint_is_thin_source_relative_and_ignores_pythonpath(self):
        self.assertLessEqual(len(SETUP.read_text(encoding="utf-8").splitlines()), 80)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            package_parent = root / "libexec"
            hostile = root / "hostile"
            bin_dir.mkdir()
            package_parent.mkdir()
            hostile.mkdir()
            entrypoint = bin_dir / SETUP.name
            shutil.copy2(SETUP, entrypoint)
            shutil.copytree(
                ROOT / "libexec" / "wg_healthcheck_setup",
                package_parent / "wg_healthcheck_setup",
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )
            marker = root / "hostile-imported"
            (hostile / "wg_healthcheck_setup.py").write_text(
                "from pathlib import Path\n"
                f"Path({str(marker)!r}).write_text('imported', encoding='ascii')\n",
                encoding="ascii",
            )
            environment = {
                "PATH": os.environ.get("PATH", ""),
                "PYTHONPATH": str(hostile),
            }

            completed = subprocess.run(
                [sys.executable, str(entrypoint), "--help"],
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(
                (package_parent / "wg_healthcheck_setup" / "__pycache__").exists()
            )

    def test_main_disables_core_before_inspecting_secret_inputs(self):
        events = []

        class RecordingArguments:
            def __iter__(self):
                events.append("argv")
                return iter((f"--api-key={SENTINEL}", "wg0"))

        def disable():
            events.append("limit")

        def deny(_argv):
            events.append("deny")
            raise setup.SetupError("secret values are not accepted")

        stderr = io.StringIO()
        with (
            mock.patch.object(
                setup.cli.private_io, "disable_core_dumps", side_effect=disable
            ),
            mock.patch.object(setup.cli, "_deny_secret_inputs", side_effect=deny),
            contextlib.redirect_stderr(stderr),
        ):
            return_code = setup.main(RecordingArguments())

        self.assertEqual(return_code, 64)
        self.assertEqual(events, ["limit", "argv", "deny"])
        self.assertNotIn(SENTINEL, stderr.getvalue())

    def test_interactive_mode_menu_has_exactly_two_choices(self):
        output = io.StringIO()
        answers = iter(["2"])

        mode = setup.choose_interactive_mode(lambda _prompt: next(answers), output)

        self.assertEqual(mode, "api")
        rendered = output.getvalue()
        self.assertEqual(rendered.count("\n  "), 2)
        self.assertIn("1. Existing/static WireGuard profile", rendered)
        self.assertIn("2. AirVPN API-managed profile", rendered)

    def test_noninteractive_requires_explicit_mode_action_and_timer_decisions(self):
        cases = (
            (
                ["--non-interactive", "--dry-run", "--leave-timer-disabled", "wg0"],
                "mode",
            ),
            (
                [
                    "--non-interactive",
                    "--mode",
                    "static",
                    "--leave-timer-disabled",
                    "wg0",
                ],
                "dry-run or --apply",
            ),
            (["--non-interactive", "--mode", "static", "--dry-run", "wg0"], "timer"),
        )
        for argv, message in cases:
            with self.subTest(argv=argv):
                with self.assertRaisesRegex(setup.SetupError, message):
                    setup.resolve_request(setup.parse_args(argv))

    def test_noninteractive_api_requires_device_countries_and_replacement_file(self):
        base = [
            "--non-interactive",
            "--mode",
            "api",
            "--dry-run",
            "--leave-timer-disabled",
        ]
        cases = (
            (
                base + ["--countries", "GB", "--credential-file", "/run/key", "wg0"],
                "device",
            ),
            (
                base + ["--device", "default", "--credential-file", "/run/key", "wg0"],
                "countries",
            ),
            (
                base
                + [
                    "--device",
                    "default",
                    "--countries",
                    "GB",
                    "--replace-credential",
                    "wg0",
                ],
                "credential-file",
            ),
        )
        for argv, message in cases:
            with self.subTest(argv=argv):
                with self.assertRaisesRegex(setup.SetupError, message):
                    setup.resolve_request(setup.parse_args(argv))

        reusable = setup.resolve_request(
            setup.parse_args(base + ["--device", "default", "--countries", "GB", "wg0"])
        )
        self.assertIsNone(reusable.credential_file)

    def test_secret_environment_name_is_rejected_even_when_empty_without_echo(self):
        for value in ("", SENTINEL):
            with self.subTest(value_present=bool(value)):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with (
                    mock.patch.dict(os.environ, {"AIRVPN_API_KEY": value}, clear=False),
                    mock.patch.object(setup.subprocess, "run") as run,
                    contextlib.redirect_stdout(stdout),
                    contextlib.redirect_stderr(stderr),
                ):
                    return_code = setup.main(["--mode", "static", "wg0"])

                self.assertEqual(return_code, 64)
                self.assertNotIn(SENTINEL, stdout.getvalue() + stderr.getvalue())
                self.assertIn(
                    "AIRVPN_API_KEY environment input is not accepted",
                    stderr.getvalue(),
                )
                run.assert_not_called()

    def test_secret_argv_value_is_rejected_without_echo(self):
        for argv in (["--api-key", SENTINEL, "wg0"], [f"--api-key={SENTINEL}", "wg0"]):
            with self.subTest(argv_form=argv[0].split("=", 1)[0]):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with (
                    contextlib.redirect_stdout(stdout),
                    contextlib.redirect_stderr(stderr),
                ):
                    return_code = setup.main(argv)

                self.assertEqual(return_code, 64)
                self.assertNotIn(SENTINEL, stdout.getvalue() + stderr.getvalue())
                self.assertIn("secret values are not accepted", stderr.getvalue())

    def test_hidden_input_disables_core_dumps_before_secret_read(self):
        events = []
        controller, terminal = os.openpty()
        self.addCleanup(os.close, controller)
        self.addCleanup(os.close, terminal)

        def setrlimit(kind, value):
            events.append(("limit", kind, value))

        def getpass_fn(prompt):
            events.append(("prompt", prompt))
            return SENTINEL

        with (
            mock.patch.object(setup.resource, "setrlimit", side_effect=setrlimit),
            mock.patch.object(
                setup.private_io,
                "open_controlling_tty",
                side_effect=lambda: os.dup(terminal),
            ),
        ):
            with setup.read_hidden_credential(getpass_fn=getpass_fn) as credential:
                self.assertGreaterEqual(credential.fd, 3)
                self.assertEqual(
                    os.pread(credential.fd, 65, 0), (SENTINEL + "\n").encode("ascii")
                )

        self.assertEqual(events[0][0], "limit")
        self.assertEqual(events[1][0], "prompt")
        self.assertNotIn(SENTINEL, repr(events))

    def test_hidden_input_fails_closed_without_a_controlling_tty(self):
        getpass_fn = mock.Mock(return_value=SENTINEL)
        with mock.patch.object(setup.os, "open", side_effect=OSError("no tty")):
            with self.assertRaisesRegex(setup.SetupError, "controlling TTY"):
                setup.read_hidden_credential(getpass_fn=getpass_fn)
        getpass_fn.assert_not_called()

    def test_hidden_input_rejects_getpass_echo_fallback(self):
        controller, terminal = os.openpty()
        self.addCleanup(os.close, controller)
        self.addCleanup(os.close, terminal)
        with (
            mock.patch.object(
                setup.private_io,
                "open_controlling_tty",
                side_effect=lambda: os.dup(terminal),
            ),
            mock.patch.object(
                setup.getpass,
                "getpass",
                side_effect=setup.getpass.GetPassWarning("echo would be enabled"),
            ),
        ):
            with self.assertRaisesRegex(setup.SetupError, "hidden credential input"):
                setup.read_hidden_credential()

    def test_credential_file_must_be_absolute_root_owned_regular_mode_0600(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            good = root / "key"
            good.write_text(SENTINEL + "\n", encoding="ascii")
            good.chmod(0o600)

            with setup.open_credential_file(str(good)) as credential:
                self.assertTrue(stat.S_ISREG(os.fstat(credential.fd).st_mode))
                self.assertEqual(
                    os.pread(credential.fd, 65, 0), (SENTINEL + "\n").encode("ascii")
                )

            with mock.patch.object(
                setup.os, "stat", side_effect=AssertionError("path stat")
            ):
                with setup.open_credential_file(str(good)) as credential:
                    self.assertEqual(os.fstat(credential.fd).st_uid, 0)

            with self.assertRaisesRegex(setup.SetupError, "absolute"):
                setup.open_credential_file("relative-key")

            good.chmod(0o640)
            with self.assertRaisesRegex(setup.SetupError, "mode 0600"):
                setup.open_credential_file(str(good))
            good.chmod(0o600)

            link = root / "link"
            link.symlink_to(good)
            with self.assertRaisesRegex(setup.SetupError, "regular non-symlink"):
                setup.open_credential_file(str(link))

            real_fstat = os.fstat

            def wrong_owner(fd):
                value = real_fstat(fd)
                return SimpleNamespace(
                    st_mode=value.st_mode,
                    st_uid=1,
                    st_size=value.st_size,
                )

            with mock.patch.object(setup.os, "fstat", side_effect=wrong_owner):
                with self.assertRaisesRegex(setup.SetupError, "root-owned"):
                    setup.open_credential_file(str(good))

    def test_credential_file_rejects_untrusted_ancestors_metadata_drift_and_high_fd(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unsafe = root / "unsafe"
            unsafe.mkdir(mode=0o700)
            unsafe.chmod(0o777)
            unsafe_key = unsafe / "key"
            unsafe_key.write_text(SENTINEL + "\n", encoding="ascii")
            unsafe_key.chmod(0o600)
            with self.assertRaisesRegex(setup.SetupError, "directory"):
                setup.open_credential_file(str(unsafe_key))

            fifo = root / "fifo"
            os.mkfifo(fifo, mode=0o600)
            real_open = os.open
            final_flags = []

            def refuse_fifo_without_blocking(path, flags, *args, **kwargs):
                if path == "fifo":
                    final_flags.append(flags)
                    raise OSError("FIFO open refused by test double")
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(
                setup.os, "open", side_effect=refuse_fifo_without_blocking
            ):
                with self.assertRaises(setup.SetupError):
                    setup.open_credential_file(str(fifo))
            self.assertTrue(final_flags[0] & os.O_NONBLOCK)

            good = root / "key"
            good.write_text(SENTINEL + "\n", encoding="ascii")
            good.chmod(0o600)
            real_fstat = os.fstat
            regular_reads = 0

            def drifting_metadata(fd):
                nonlocal regular_reads
                value = real_fstat(fd)
                if stat.S_ISREG(value.st_mode):
                    regular_reads += 1
                    if regular_reads == 2:
                        return SimpleNamespace(
                            st_mode=value.st_mode,
                            st_uid=value.st_uid,
                            st_gid=value.st_gid,
                            st_size=value.st_size - 1,
                            st_dev=value.st_dev,
                            st_ino=value.st_ino,
                            st_nlink=value.st_nlink,
                            st_mtime_ns=value.st_mtime_ns,
                            st_ctime_ns=value.st_ctime_ns,
                        )
                return value

            with mock.patch.object(setup.os, "fstat", side_effect=drifting_metadata):
                with self.assertRaisesRegex(
                    setup.SetupError, "changed while being read"
                ):
                    setup.open_credential_file(str(good))

            base_fd = os.open(good, os.O_RDONLY | os.O_CLOEXEC)
            self.addCleanup(os.close, base_fd)
            high_fd = fcntl.fcntl(base_fd, fcntl.F_DUPFD_CLOEXEC, 1024)
            with mock.patch.object(
                setup.private_io, "_open_absolute_nofollow", return_value=high_fd
            ):
                with self.assertRaisesRegex(setup.SetupError, "descriptor range"):
                    setup.open_credential_file(str(good))

    def test_runtime_validation_uses_distinct_fixed_private_fds_and_no_shell(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(
                argv, 0, "generated\tMensa-1\t198.51.100.10:1637\tpinned=1\n", ""
            )

        with (
            setup.credential_from_bytes(
                (SENTINEL + "\n").encode("ascii")
            ) as credential,
            setup.settings_from_values("default", "GB NL") as settings,
        ):
            setup.run_runtime_validation("wg0", "adopt", credential, settings, run=run)
            credential_fd = credential.fd
            settings_fd = settings.fd

        self.assertEqual(
            calls[0][0],
            [
                setup.RUNTIME,
                "adopt",
                "wg0",
                "--dry-run",
                "--credential-fd",
                str(credential_fd),
                "--settings-fd",
                str(settings_fd),
            ],
        )
        self.assertNotEqual(credential_fd, settings_fd)
        self.assertIs(calls[0][1]["shell"], False)
        self.assertEqual(calls[0][1]["pass_fds"], (credential_fd, settings_fd))
        self.assertIs(calls[0][1]["capture_output"], True)
        self.assertIs(calls[0][1]["text"], True)
        self.assertEqual(calls[0][1]["env"], setup.safe_child_environment())
        self.assertNotIn("AIRVPN_API_KEY", calls[0][1]["env"])

    def test_settings_record_is_exact_private_bounded_and_canonical(self):
        cases = (("default", "GB NL"), ("Device One", "ALL"))
        for device, countries in cases:
            with self.subTest(countries=countries):
                with setup.settings_from_values(device, countries) as settings:
                    metadata = os.fstat(settings.fd)
                    expected = (
                        f"version=1\ndevice={device}\ncountries={countries}\n".encode(
                            "ascii"
                        )
                    )
                    self.assertEqual(os.pread(settings.fd, 257, 0), expected)
                    self.assertLessEqual(metadata.st_size, 256)
                    self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
                    self.assertEqual(metadata.st_uid, 0)

        for device, countries in (
            ("bad\nvalue", "GB"),
            ("default", "gb"),
            ("default", "GB  NL"),
        ):
            with self.subTest(device=device, countries=countries):
                with self.assertRaises(setup.SetupError):
                    setup.settings_from_values(device, countries)

    def test_dry_run_output_is_redacted_even_when_child_mentions_secret(self):
        def run(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 1, SENTINEL, SENTINEL)

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            setup.credential_from_bytes(
                (SENTINEL + "\n").encode("ascii")
            ) as credential,
            setup.settings_from_values("default", "GB") as settings,
        ):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                with self.assertRaisesRegex(setup.SetupError, "validation failed"):
                    setup.run_runtime_validation(
                        "wg0", "provision", credential, settings, run=run
                    )

        self.assertNotIn(SENTINEL, stdout.getvalue() + stderr.getvalue())

    def test_child_decode_failures_are_mapped_to_redacted_setup_errors(self):
        def run(_argv, **_kwargs):
            raise UnicodeDecodeError("utf-8", b"\xff", 0, 1, SENTINEL)

        with self.assertRaisesRegex(
            setup.SetupError, "could not be executed"
        ) as raised:
            setup.fetch_public_countries(run=run)
        self.assertNotIn(SENTINEL, str(raised.exception))

    def test_runtime_success_requires_exact_bounded_canonical_manifest(self):
        invalid = (
            "validated redacted\n",
            "generated\tMensa-1\t198.51.100.10:1637\tpinned=0\nextra\n",
            "generated\tMensa-1\texample.com:1637\tpinned=0\n",
            "X" * (setup.MAX_MANIFEST_BYTES + 1),
        )
        for child_output in invalid:
            with self.subTest(child_output=child_output[:40]):

                def run(argv, **_kwargs):
                    return subprocess.CompletedProcess(argv, 0, child_output, "")

                with (
                    setup.credential_from_bytes(
                        (SENTINEL + "\n").encode("ascii")
                    ) as credential,
                    setup.settings_from_values("default", "GB") as settings,
                ):
                    with self.assertRaisesRegex(
                        setup.SetupError, "invalid redacted manifest"
                    ):
                        setup.run_runtime_validation(
                            "wg0", "provision", credential, settings, run=run
                        )

    def test_country_menu_lists_only_public_healthy_choices(self):
        completed = subprocess.CompletedProcess(
            [setup.AIRVPN_API_HELPER, "list-countries"],
            0,
            "GB\tUnited Kingdom\t3\nNL\tNetherlands\t2\n",
            "",
        )
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            return completed

        countries = setup.fetch_public_countries(run=run)
        output = io.StringIO()
        setup.render_country_menu(countries, output)

        self.assertEqual([country.code for country in countries], ["GB", "NL"])
        self.assertNotIn("DE", output.getvalue())
        self.assertIn("1. GB  United Kingdom (3 healthy servers)", output.getvalue())
        self.assertIn("2. NL  Netherlands (2 healthy servers)", output.getvalue())
        self.assertEqual(calls[0][0], [setup.AIRVPN_API_HELPER, "list-countries"])
        self.assertIs(calls[0][1]["shell"], False)
        self.assertEqual(calls[0][1]["pass_fds"], ())
        self.assertEqual(calls[0][1]["env"], setup.safe_child_environment())

    def test_country_inventory_reparse_is_strict_bounded_unique_and_sorted(self):
        invalid = (
            "X" * (setup.MAX_COUNTRY_OUTPUT_BYTES + 1),
            "NL\tNetherlands\t1\nGB\tUnited Kingdom\t1\n",
            "GB\tUnited Kingdom\t1\nGB\tUnited Kingdom\t2\n",
            "GB\tUnited Kingdom\t0\n",
            "GB\tUnited\nKingdom\t1\n",
            "G1\tUnited Kingdom\t1\n",
            "GB\tUnited Kingdom\t01\n",
        )
        for payload in invalid:
            with self.subTest(payload=payload[:40]):
                with self.assertRaises(setup.SetupError):
                    setup.parse_country_inventory(payload)

    def test_country_menu_accepts_numbers_and_codes_preserving_order(self):
        selection = setup.normalize_country_selection("2 gb 2 NL se GB", _countries())

        self.assertFalse(selection.all_countries)
        self.assertEqual(selection.codes, ("NL", "GB", "SE"))

    def test_country_selection_is_bounded_before_integer_conversion_or_secret_read(
        self,
    ):
        many = tuple(
            setup.Country(f"{chr(65 + first)}{chr(65 + second)}", "Eligible", 1)
            for first in range(2)
            for second in range(17)
        )
        with self.assertRaisesRegex(setup.SetupError, "at most 32"):
            setup.normalize_country_selection(
                " ".join(country.code for country in many), many
            )

        with self.assertRaises(setup.SetupError):
            setup.normalize_country_selection("9" * 5000, _countries())

    def test_single_country_is_strict(self):
        selection = setup.normalize_country_selection("GB", _countries())

        self.assertFalse(selection.all_countries)
        self.assertEqual(selection.codes, ("GB",))
        self.assertEqual(setup.configured_country_value(selection), "GB")

    def test_all_requires_explicit_selection(self):
        with self.assertRaisesRegex(setup.SetupError, "explicitly select"):
            setup.normalize_country_selection("", _countries())

        selection = setup.normalize_country_selection("all", _countries())
        self.assertTrue(selection.all_countries)
        self.assertEqual(selection.codes, ())
        self.assertEqual(setup.configured_country_value(selection), "")

        with self.assertRaisesRegex(setup.SetupError, "ALL cannot be combined"):
            setup.normalize_country_selection("ALL GB", _countries())

    def test_noninteractive_countries_requires_codes_or_all(self):
        args = setup.parse_args(
            [
                "--non-interactive",
                "--mode",
                "api",
                "--dry-run",
                "--leave-timer-disabled",
                "--device",
                "default",
                "--credential-file",
                "/run/key",
                "wg0",
            ]
        )
        with self.assertRaisesRegex(setup.SetupError, "countries"):
            setup.resolve_request(args)

        for value in ("1", "GB,NL", "GB ALL"):
            with self.subTest(value=value):
                argv = [
                    "--non-interactive",
                    "--mode",
                    "api",
                    "--dry-run",
                    "--leave-timer-disabled",
                    "--device",
                    "default",
                    "--countries",
                    value,
                    "--credential-file",
                    "/run/key",
                    "wg0",
                ]
                with self.assertRaises(setup.SetupError):
                    setup.resolve_request(setup.parse_args(argv))

    def test_reset_api_state_requires_explicit_safety_action(self):
        args = setup.parse_args(
            [
                "--non-interactive",
                "--mode",
                "static",
                "--leave-timer-disabled",
                "--reset-api-state",
                "wg0",
            ]
        )
        with self.assertRaisesRegex(setup.SetupError, "dry-run or --apply"):
            setup.resolve_request(args)

    def test_reset_api_state_rejects_timer_enable(self):
        args = setup.parse_args(
            [
                "--non-interactive",
                "--mode",
                "static",
                "--dry-run",
                "--enable-timer",
                "--reset-api-state",
                "wg0",
            ]
        )
        with self.assertRaisesRegex(setup.SetupError, "cannot enable the timer"):
            setup.resolve_request(args)

    def test_explicit_static_combined_purge_preserves_pre_managed_snapshot(self):
        args = setup.parse_args(
            [
                "--non-interactive",
                "--mode",
                "static",
                "--apply",
                "--leave-timer-disabled",
                "--remove-credential",
                "--reset-api-state",
                "wg0",
            ]
        )

        request = setup.resolve_request(args)
        summary = setup.render_summary(request)

        self.assertTrue(request.remove_credential)
        self.assertTrue(request.reset_api_state)
        self.assertIn("pre-managed snapshot: preserved", summary)
        self.assertNotIn("pre-managed snapshot: remove", summary)

    def test_country_discovery_precedes_any_credential_read(self):
        events = []
        args = setup.parse_args(
            [
                "--mode",
                "api",
                "--dry-run",
                "--leave-timer-disabled",
                "--device",
                "default",
                "--countries",
                "GB",
                "wg0",
            ]
        )

        def fetch():
            events.append("countries")
            return _countries()

        @contextlib.contextmanager
        def credential():
            events.append("credential")
            with setup.credential_from_bytes(
                (SENTINEL + "\n").encode("ascii")
            ) as value:
                yield value

        with (
            mock.patch.object(
                setup.cli.clients, "fetch_public_countries", side_effect=fetch
            ),
            mock.patch.object(
                setup.cli.private_io, "read_hidden_credential", side_effect=credential
            ),
            mock.patch.object(
                setup.cli.application,
                "api_requires_proposed_credential",
                return_value=True,
            ),
            mock.patch.object(setup.cli.application, "preview_api_request"),
        ):
            setup.execute_request(
                setup.resolve_request(args), input_fn=lambda _prompt: ""
            )

        self.assertEqual(events, ["countries", "credential"])


if __name__ == "__main__":
    unittest.main()
