import contextlib
from dataclasses import dataclass
import fcntl
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "bin" / "wg-healthcheck-setup"


def _load_setup():
    loader = importlib.machinery.SourceFileLoader(
        "wg_healthcheck_setup_apply", str(SETUP)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


setup = _load_setup()


@dataclass(frozen=True)
class ApplyPaths:
    """Deterministic live-layout substitute accepted by the Task 10 seam."""

    iface: str
    trusted_uid: int
    health_dir: Path
    health_config: Path
    credential: Path
    wireguard_dir: Path
    profile: Path
    pre_managed: Path
    backup: Path
    pending: Path
    safety: Path
    candidate: Path
    state_dir: Path
    api_state: Path
    runtime_dir: Path
    status: Path
    setup_guard: Path
    interface_lock: Path
    global_lock: Path
    timer_unit: str
    service_unit: str


def _make_paths(root: Path, iface: str = "wg0") -> ApplyPaths:
    health_dir = root / "etc/wireguard/healthcheck.d"
    wireguard_dir = root / "etc/wireguard"
    state_dir = root / "var/lib/wg-healthcheck"
    runtime_dir = root / "run/wg-healthcheck"
    for directory in (health_dir, wireguard_dir, state_dir, runtime_dir):
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o700)
    profile = wireguard_dir / f"{iface}.conf"
    return ApplyPaths(
        iface=iface,
        trusted_uid=os.geteuid(),
        health_dir=health_dir,
        health_config=health_dir / f"{iface}.conf",
        credential=health_dir / f"{iface}.api-key",
        wireguard_dir=wireguard_dir,
        profile=profile,
        pre_managed=wireguard_dir / f"{iface}.conf.pre-managed",
        backup=wireguard_dir / f"{iface}.conf.bak-healthcheck",
        pending=wireguard_dir / f"{iface}.conf.pending-healthcheck",
        safety=wireguard_dir / f"{iface}.conf.safety-healthcheck",
        candidate=wireguard_dir / f".{iface}.conf.managed-candidate",
        state_dir=state_dir,
        api_state=state_dir / f"{iface}.api-state",
        runtime_dir=runtime_dir,
        status=runtime_dir / f"{iface}.status",
        setup_guard=runtime_dir / f"{iface}.setup-guard",
        interface_lock=runtime_dir / f"{iface}.lock",
        global_lock=runtime_dir / "airvpn-api.lock",
        timer_unit=f"wg-healthcheck@{iface}.timer",
        service_unit=f"wg-healthcheck@{iface}.service",
    )


def _write_private(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o600)


def _replace_config_value(path: Path, key: str, value: str) -> None:
    lines = path.read_text(encoding="ascii").splitlines()
    prefix = f"{key}="
    replaced = False
    rendered = []
    for line in lines:
        if line.startswith(prefix):
            if replaced:
                raise AssertionError(f"duplicate test fixture key: {key}")
            rendered.append(f"{key}={value}")
            replaced = True
        else:
            rendered.append(line)
    if not replaced:
        rendered.append(f"{key}={value}")
    _write_private(path, ("\n".join(rendered) + "\n").encode("ascii"))


def _snapshot(paths: ApplyPaths) -> dict[str, tuple[bool, bytes | None, int | None]]:
    result = {}
    for name in (
        "health_config",
        "credential",
        "profile",
        "pre_managed",
        "backup",
        "pending",
        "safety",
        "candidate",
        "api_state",
    ):
        path = getattr(paths, name)
        if path.exists() and not path.is_symlink():
            result[name] = (True, path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
        else:
            result[name] = (False, None, None)
    return result


def _request(
    *,
    mode: str,
    action: str = "apply",
    timer: str = "disabled",
    replace_credential: bool = False,
    remove_credential: bool = False,
    restore_pre_managed: bool = False,
    reset_api_state: bool = False,
) -> object:
    api = mode == "api"
    return setup.SetupRequest(
        iface="wg0",
        mode=mode,
        action=action,
        timer=timer,
        device="Proposed Device" if api else None,
        countries_text="GB NL" if api else None,
        credential_file=None,
        non_interactive=False,
        restore_pre_managed=restore_pre_managed,
        replace_credential=replace_credential,
        remove_credential=remove_credential,
        reset_api_state=reset_api_state,
        country_selection=(setup.CountrySelection(("GB", "NL")) if api else None),
    )


class BlockingSharedLeaseProbe:
    """Observe when a competing ordinary-runtime lease can enter."""

    def __init__(self, path: Path, capture):
        self.path = path
        self.capture = capture
        self.attempting = threading.Event()
        self.acquired = threading.Event()
        self.finished = threading.Event()
        self.observation = None
        self.error: BaseException | None = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        fd = -1
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
            self.attempting.set()
            fcntl.flock(fd, fcntl.LOCK_SH)
            self.observation = self.capture()
            self.acquired.set()
            fcntl.flock(fd, fcntl.LOCK_UN)
        except BaseException as error:  # surfaced by the owning test thread
            self.error = error
        finally:
            if fd >= 0:
                os.close(fd)
            self.finished.set()

    def start_and_assert_blocked(self, case: unittest.TestCase, phase: str) -> None:
        self.thread.start()
        case.assertTrue(
            self.attempting.wait(1),
            f"shared setup-guard probe did not start during {phase}: {self.error!r}",
        )
        case.assertFalse(
            self.acquired.wait(0.05),
            f"shared setup-guard lease entered during {phase}",
        )

    def assert_still_blocked(self, case: unittest.TestCase, phase: str) -> None:
        case.assertFalse(
            self.acquired.wait(0.05),
            f"shared setup-guard lease entered before {phase} completed",
        )

    def finish(self, case: unittest.TestCase):
        case.assertTrue(
            self.acquired.wait(1),
            f"shared setup-guard lease was not released: {self.error!r}",
        )
        case.assertTrue(
            self.finished.wait(1), "shared setup-guard probe did not finish"
        )
        self.thread.join(timeout=0)
        if self.error is not None:
            raise self.error
        return self.observation


class FixedCommandDouble:
    """Subprocess-compatible double for runtime and systemd orchestration."""

    runtime = "/usr/local/sbin/wg-healthcheck"
    systemctl = "/usr/bin/systemctl"

    def __init__(self, case: unittest.TestCase, paths: ApplyPaths, now: int):
        self.case = case
        self.paths = paths
        self.now = now
        self.events: list[tuple[str, ...]] = []
        self.timer_active = True
        self.worker_active = True
        self.fail_stop_unit: str | None = None
        self.fail_first_validation = False
        self.validation_failure_stdout = ""
        self.fail_runtime_apply = False
        self.install_profile_before_apply_failure = False
        self.create_snapshot_before_apply_failure = False
        self.status_outcome: str | None = "healthy"
        self.status_timestamp = now
        self.fail_enable = False
        self.partial_enable_failure = False
        self.fail_containment_disable = False
        self.fail_containment_stop = False
        self.enable_attempted = False
        self.disable_calls = 0
        self.fail_reset = False
        self.fail_candidate_cleanup = False
        self.validation_calls = 0
        self.credential_before_validation: bytes | None = None
        self.phase_hook = None
        self.runtime_fd_contracts: list[tuple[str, str, int]] = []

    def _completed(self, argv, returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess(list(argv), returncode, stdout, stderr)

    def _assert_subprocess_boundary(self, kwargs) -> None:
        self.case.assertIs(kwargs.get("shell"), False)
        self.case.assertTrue(kwargs.get("close_fds"))
        self.case.assertEqual(kwargs.get("env", {}).get("LC_ALL"), "C")

    def _phase(self, name: str) -> None:
        if self.phase_hook is not None:
            self.phase_hook(name)

    @staticmethod
    def _descriptor_argument(argv: tuple[str, ...], option: str) -> int | None:
        count = argv.count(option)
        if count == 0:
            return None
        if count != 1:
            raise AssertionError(f"duplicate private descriptor option: {option}")
        index = argv.index(option)
        if index + 1 >= len(argv):
            raise AssertionError(f"missing private descriptor value: {option}")
        try:
            return int(argv[index + 1], 10)
        except ValueError as error:
            raise AssertionError(
                f"non-integer private descriptor value: {option}"
            ) from error

    def _assert_runtime_lease(self, argv: tuple[str, ...], kwargs) -> None:
        lease_fd = self._descriptor_argument(argv, "--setup-lease-fd")
        self.case.assertIsNotNone(
            lease_fd, "every setup-owned runtime child must reuse the setup lease"
        )
        private_fds = [lease_fd]
        for option in ("--credential-fd", "--settings-fd"):
            descriptor = self._descriptor_argument(argv, option)
            if descriptor is not None:
                private_fds.append(descriptor)
        self.case.assertEqual(
            len(private_fds),
            len(set(private_fds)),
            "lease, credential, and settings descriptors must be distinct",
        )

        inherited = kwargs.get("pass_fds")
        self.case.assertIsInstance(inherited, tuple)
        self.case.assertEqual(
            len(inherited),
            len(private_fds),
            "runtime child inherited an undeclared or duplicate descriptor",
        )
        self.case.assertEqual(
            set(inherited),
            set(private_fds),
            "runtime child descriptor inheritance did not match its fixed argv",
        )

        guard_metadata = os.stat(self.paths.setup_guard, follow_symlinks=False)
        lease_metadata = os.fstat(lease_fd)
        self.case.assertTrue(stat.S_ISREG(guard_metadata.st_mode))
        self.case.assertEqual(stat.S_IMODE(guard_metadata.st_mode), 0o600)
        self.case.assertEqual(guard_metadata.st_uid, self.paths.trusted_uid)
        self.case.assertEqual(
            (lease_metadata.st_dev, lease_metadata.st_ino),
            (guard_metadata.st_dev, guard_metadata.st_ino),
            "--setup-lease-fd must name the fixed per-interface guard",
        )

        probe_fd = os.open(
            self.paths.setup_guard, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
        try:
            try:
                fcntl.flock(probe_fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                fcntl.flock(probe_fd, fcntl.LOCK_UN)
                self.case.fail(
                    "setup-owned runtime child was invoked without an exclusive lease"
                )
        finally:
            os.close(probe_fd)

        if "--dry-run" in argv:
            action = "dry-run"
        elif "--apply" in argv:
            action = "apply"
        else:
            action = argv[1]
        self.runtime_fd_contracts.append((argv[1], action, len(inherited)))

    def _write_status(self) -> None:
        if self.status_outcome is None:
            return
        replacement = self.paths.status.with_name(
            f".{self.paths.status.name}.unit-test"
        )
        _write_private(
            replacement,
            (
                f"outcome={self.status_outcome}\n"
                "reason=unit-test-status\n"
                f"timestamp={self.status_timestamp}\n"
            ).encode("ascii"),
        )
        os.replace(replacement, self.paths.status)

    def _simulate_runtime_apply(self, operation: str) -> None:
        if operation == "provision":
            _write_private(
                self.paths.profile, b"generated-profile-unit-test-sentinel\n"
            )
        elif operation == "adopt" and not self.paths.pre_managed.exists():
            _write_private(self.paths.pre_managed, self.paths.profile.read_bytes())
        _replace_config_value(self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "api")

    def __call__(self, argv, **kwargs):
        argv = tuple(str(value) for value in argv)
        self.events.append(argv)
        self._assert_subprocess_boundary(kwargs)

        if argv[0] == self.systemctl:
            self.case.assertEqual(
                kwargs.get("pass_fds"),
                (),
                "systemctl must not inherit private descriptors",
            )
            args = argv[1:]
            if args == ("disable", "--now", self.paths.timer_unit):
                self.disable_calls += 1
                if self.fail_stop_unit == self.paths.timer_unit:
                    return self._completed(argv, 1, stderr="timer stop failed")
                if self.enable_attempted and self.fail_containment_disable:
                    return self._completed(argv, 1, stderr="timer containment failed")
                self.timer_active = False
                return self._completed(argv)
            if args == ("stop", self.paths.service_unit):
                if self.fail_stop_unit == self.paths.service_unit:
                    return self._completed(argv, 1, stderr="worker stop failed")
                if self.enable_attempted and self.fail_containment_stop:
                    return self._completed(argv, 1, stderr="worker containment failed")
                self.worker_active = False
                return self._completed(argv)
            if args == ("is-active", "--quiet", self.paths.timer_unit):
                return self._completed(argv, 0 if self.timer_active else 3)
            if args == ("is-active", "--quiet", self.paths.service_unit):
                return self._completed(argv, 0 if self.worker_active else 3)
            if args == ("enable", "--now", self.paths.timer_unit):
                self.enable_attempted = True
                self._phase("timer-enable")
                if self.fail_enable:
                    self.timer_active = self.partial_enable_failure
                    self.worker_active = self.partial_enable_failure
                    return self._completed(argv, 1, stderr="timer enable failed")
                self.timer_active = True
                return self._completed(argv)
            self.case.fail(f"unexpected systemctl argv: {argv!r}")

        if argv[0] != self.runtime:
            self.case.fail(f"unexpected executable: {argv!r}")

        self._assert_runtime_lease(argv, kwargs)

        command = argv[1]
        if command == "check":
            self._phase("verification-start")
            self._write_status()
            return self._completed(argv, stdout="checked\n")

        if command in {"provision", "adopt"} and "--dry-run" in argv:
            self.validation_calls += 1
            if self.validation_calls == 1:
                if self.credential_before_validation is None:
                    self.case.assertFalse(
                        self.paths.credential.exists(),
                        "the proposed key must validate before installed-key persistence",
                    )
                else:
                    self.case.assertEqual(
                        self.paths.credential.read_bytes(),
                        self.credential_before_validation,
                        "the proposed key must validate before replacing the installed key",
                    )
                if self.fail_first_validation:
                    return self._completed(
                        argv,
                        1,
                        stdout=self.validation_failure_stdout,
                        stderr="redacted validation failure",
                    )
            return self._completed(
                argv,
                stdout=(
                    "generated\tUnit-Test-Server\t192.0.2.10:1637\t"
                    f"pinned={1 if command == 'adopt' else 0}\n"
                ),
            )

        if command in {"provision", "adopt"} and "--apply" in argv:
            self.case.assertFalse(self.timer_active)
            self.case.assertFalse(self.worker_active)
            staged = self.paths.health_config.read_text(encoding="ascii")
            self.case.assertIn("AIRVPN_PROFILE_SOURCE=static\n", staged)
            self.case.assertIn('AIRVPN_DEVICE="Proposed Device"\n', staged)
            self.case.assertIn('AIRVPN_COUNTRIES="GB NL"\n', staged)
            self.case.assertTrue(self.paths.credential.exists())
            if self.install_profile_before_apply_failure and command == "provision":
                _write_private(
                    self.paths.profile, b"generated-profile-unit-test-sentinel\n"
                )
            if self.create_snapshot_before_apply_failure and command == "adopt":
                _write_private(self.paths.pre_managed, self.paths.profile.read_bytes())
            if self.fail_runtime_apply:
                self._phase("runtime-apply-failure")
                return self._completed(argv, 1, stderr="redacted apply failure")
            self._simulate_runtime_apply(command)
            return self._completed(argv, stdout="applied\n")

        if command == "restore-static":
            if "--dry-run" in argv:
                return self._completed(argv, stdout="restore-static-plan\n")
            if "--apply" in argv:
                if self.paths.pre_managed.exists():
                    _write_private(
                        self.paths.profile, self.paths.pre_managed.read_bytes()
                    )
                _replace_config_value(
                    self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "static"
                )
                return self._completed(argv, stdout="restored-static\n")

        if command == "reset-api-state":
            if self.fail_reset:
                return self._completed(argv, 1, stderr="reset failed")
            if "--apply" in argv and self.paths.api_state.exists():
                self.paths.api_state.unlink()
            return self._completed(argv, stdout="reset-api-state\n")

        if command == "cleanup-candidate":
            self.case.assertIn("--apply", argv)
            if self.fail_candidate_cleanup:
                return self._completed(argv, 1, stderr="candidate cleanup failed")
            if self.paths.candidate.exists() and not self.paths.candidate.is_symlink():
                self.paths.candidate.unlink()
            if self.paths.candidate.exists() or self.paths.candidate.is_symlink():
                return self._completed(argv, 1, stderr="candidate remains")
            return self._completed(argv, stdout="candidate-cleaned\n")

        self.case.fail(f"unexpected runtime argv: {argv!r}")


class ApplyFixture(unittest.TestCase):
    """Shared deterministic filesystem and command boundary for Task 10 tests."""

    NOW = 2_000_000_000
    ORIGINAL_CONFIG = (
        b"# operator comment\n"
        b"MAX_AGE=222\n"
        b'REQUIRED_ROUTE="default dev wg0"\n'
        b"AIRVPN_PROFILE_SOURCE=static\n"
        b'AIRVPN_DEVICE="Installed Device"\n'
        b"AIRVPN_COUNTRIES=SE\n"
    )
    OLD_CREDENTIAL = b"0" * 64 + b"\n"
    PROPOSED_CREDENTIAL = b"1" * 64 + b"\n"
    NEXT_CREDENTIAL = b"2" * 64 + b"\n"
    PROFILE = b"existing-profile-unit-test-sentinel\n"
    PRE_MANAGED = b"pre-managed-profile-unit-test-sentinel\n"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.paths = _make_paths(Path(self.temporary.name))
        _write_private(self.paths.health_config, self.ORIGINAL_CONFIG)
        self.runner = FixedCommandDouble(self, self.paths, self.NOW)

    @contextlib.contextmanager
    def proposed_credential(self, value: bytes | None = None):
        source = Path(self.temporary.name) / "proposed-credential"
        _write_private(source, value or self.PROPOSED_CREDENTIAL)
        fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with setup.PrivateHandle(fd) as handle:
            yield handle

    def apply(self, request, credential=None):
        return setup.apply_setup_request(
            request,
            credential,
            paths=self.paths,
            run=self.runner,
            now=lambda: self.NOW,
        )

    def setup_artifacts(self) -> tuple[Path, Path, Path]:
        return (
            self.paths.health_dir / f"{self.paths.iface}.setup-transaction",
            self.paths.health_dir / f".{self.paths.iface}.conf.setup-previous",
            self.paths.health_dir / f".{self.paths.iface}.api-key.setup-previous",
        )

    def assert_no_setup_artifacts(self) -> None:
        journal, config_previous, credential_previous = self.setup_artifacts()
        artifacts = (
            journal,
            config_previous,
            credential_previous,
            setup.store.snapshot_staging_path(config_previous),
            setup.store.snapshot_staging_path(credential_previous),
            setup.store.private_staging_path(journal),
            setup.store.private_staging_path(self.paths.health_config),
            setup.store.private_staging_path(self.paths.credential),
        )
        for artifact in artifacts:
            self.assertFalse(
                artifact.exists() or artifact.is_symlink(),
                f"unresolved setup artifact: {artifact.name}",
            )

    def install_active_api_fixture(self) -> None:
        _write_private(self.paths.profile, self.PROFILE)
        _write_private(self.paths.pre_managed, self.PRE_MANAGED)
        _write_private(self.paths.credential, self.OLD_CREDENTIAL)
        _replace_config_value(self.paths.health_config, "AIRVPN_PROFILE_SOURCE", "api")
        self.runner.credential_before_validation = self.OLD_CREDENTIAL

    def assert_timer_disabled(self) -> None:
        self.assertFalse(self.runner.timer_active)
