import ast
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADR = ROOT / "docs" / "aegis" / "adr" / "0001-dual-mode-profile-management.md"
MANAGED_ARTIFACT = Path("libexec/wg-healthcheck-managed")
MANAGED_FRAGMENTS = (
    "10-integrity.bash",
    "20-journal-transitions.bash",
    "30-api-state.bash",
    "40-provider-attempt.bash",
    "50-qb-containment.bash",
    "60-profile-effects.bash",
    "70-transaction-recovery.bash",
    "80-admin-commands.bash",
    "90-status-maintenance.bash",
)
REVIEW_LINE_LIMIT = 800
REVIEW_EXCEPTIONS = {
    Path("bin/wg-healthcheck"): 2214,
    Path("libexec/airvpn-api"): 1631,
    Path("install.sh"): 1154,
}
CODE_SUFFIXES = {".bash", ".py", ".sh"}
EXTENSIONLESS_CODE_OWNERS = {
    Path("bin/wg-healthcheck"),
    Path("bin/wg-healthcheck-setup"),
    Path("libexec/airvpn-api"),
    MANAGED_ARTIFACT,
}
REVIEW_BLOCK_LIMIT = 80
REVIEW_BLOCK_EXCEPTIONS = {
    (Path("bin/wg-healthcheck"), "parse_cli"): 131,
    (Path("bin/wg-healthcheck"), "parse_healthcheck_config"): 95,
    (Path("bin/wg-healthcheck"), "rotate_static_endpoint"): 88,
    (Path("bin/wg-healthcheck"), "main"): 136,
    (Path("libexec/airvpn-api"), "parse_wireguard_profile"): 83,
    (Path("libexec/airvpn-api"), "select_candidate"): 88,
    (Path("libexec/wg_healthcheck_setup/application.py"), "_apply_api"): 134,
    (Path("libexec/wg_healthcheck_setup/application.py"), "_apply_static"): 86,
    (Path("libexec/wg_healthcheck_setup/store.py"), "snapshot_file"): 94,
    (
        Path("libexec/wg-healthcheck-managed.d/30-api-state.bash"),
        "managed_api_state_load",
    ): 89,
    (
        Path("libexec/wg-healthcheck-managed.d/40-provider-attempt.bash"),
        "managed_run_authenticated_attempt",
    ): 132,
    (
        Path("libexec/wg-healthcheck-managed.d/60-profile-effects.bash"),
        "managed_rollback_profile_transaction",
    ): 155,
    (
        Path("libexec/wg-healthcheck-managed.d/70-transaction-recovery.bash"),
        "managed_profile_transaction",
    ): 172,
}
PYTHON_EXTENSIONLESS_OWNERS = {
    Path("bin/wg-healthcheck-setup"),
    Path("libexec/airvpn-api"),
}


def _builder_environment():
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "LC_ALL": "C",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TMPDIR": "/tmp",
    }


def _run_builder(root: Path, mode: str):
    return subprocess.run(
        ["bash", "scripts/build-managed-module.sh", mode],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
        env=_builder_environment(),
    )


def _line_count(path: Path) -> int:
    with path.open("rb") as stream:
        return sum(1 for _line in stream)


def _bash_function_spans(path: Path):
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\(\) ([{(])", line)
        if not match:
            continue
        closer = "}" if match.group(2) == "{" else ")"
        for end in range(index + 1, len(lines)):
            if lines[end] == closer:
                yield match.group(1), end - index + 1
                break
        else:
            raise AssertionError(f"unterminated top-level Bash function: {path}:{index + 1}")


def _python_function_spans(path: Path):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=path.as_posix())

    def walk(nodes, prefix=""):
        for node in nodes:
            if isinstance(node, ast.ClassDef):
                yield from walk(node.body, f"{prefix}{node.name}.")
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                yield f"{prefix}{node.name}", node.end_lineno - node.lineno + 1
                yield from walk(node.body, f"{prefix}{node.name}.")

    yield from walk(tree.body)


def _code_owners():
    yield Path("install.sh")
    for directory in ("bin", "libexec", "scripts", "tests"):
        for path in sorted((ROOT / directory).rglob("*")):
            if not path.is_file() or "__pycache__" in path.parts:
                continue
            yield path.relative_to(ROOT)


class ArchitectureContractTests(unittest.TestCase):
    def test_accepted_adr_records_the_dual_mode_ownership_decision(self):
        text = ADR.read_text(encoding="utf-8")
        for required in (
            "Status: Accepted",
            "## Context",
            "## Decision",
            "## Consequences",
            "Static compatibility",
            "Device lifecycle",
            "Rejected alternatives",
            "libexec/airvpn-api",
            "bin/wg-healthcheck",
            "libexec/wg-healthcheck-managed",
            "wg-healthcheck-setup",
            "review-size exception",
            "full fixed-path ancestor chain",
            "observational `status`",
            "### Block-level review",
            "persistent record version",
            "provider transport",
            "installer artifact",
        ):
            self.assertIn(required, text)

    def test_architecture_index_links_the_accepted_adr(self):
        index = (ROOT / "docs" / "aegis" / "INDEX.md").read_text(encoding="utf-8")
        self.assertIn(
            "adr/0001-dual-mode-profile-management.md",
            index,
        )
        self.assertNotIn("No ADRs have been accepted yet", index)

    def test_non_generated_code_owners_are_bounded_or_frozen_exceptions(self):
        failures = []
        for relative in _code_owners():
            count = _line_count(ROOT / relative)
            if relative == MANAGED_ARTIFACT:
                continue
            if relative in REVIEW_EXCEPTIONS:
                ceiling = REVIEW_EXCEPTIONS[relative]
                if count > ceiling:
                    failures.append(f"{relative}: {count} > frozen exception {ceiling}")
            elif count > REVIEW_LINE_LIMIT:
                failures.append(f"{relative}: {count} > {REVIEW_LINE_LIMIT}")
        self.assertEqual([], failures, "oversized review owners:\n" + "\n".join(failures))

    def test_code_owner_types_and_links_are_explicit(self):
        failures = []
        for directory in ("bin", "libexec", "scripts", "tests"):
            code_root = ROOT / directory
            if code_root.is_symlink():
                failures.append(f"{directory}: symbolic-link code root")
            for path in code_root.rglob("*"):
                if "__pycache__" not in path.parts and path.is_symlink():
                    failures.append(
                        f"{path.relative_to(ROOT)}: symbolic-link code-tree entry"
                    )
        for relative in _code_owners():
            path = ROOT / relative
            data = path.read_bytes()
            if path.suffix not in CODE_SUFFIXES and relative not in EXTENSIONLESS_CODE_OWNERS:
                failures.append(f"{relative}: unmanifested code-owner type")
            if data.startswith(b"\xef\xbb\xbf"):
                failures.append(f"{relative}: UTF-8 byte-order mark")
            try:
                data.decode("utf-8")
            except UnicodeDecodeError:
                failures.append(f"{relative}: not UTF-8 text")
        self.assertEqual([], failures, "unexpected code owners:\n" + "\n".join(failures))

    def test_production_blocks_are_bounded_or_exact_frozen_exceptions(self):
        failures = []
        observed_exceptions = set()
        for relative in _code_owners():
            if relative.parts[0] == "tests" or relative == MANAGED_ARTIFACT:
                continue
            path = ROOT / relative
            if path.suffix == ".py" or relative in PYTHON_EXTENSIONLESS_OWNERS:
                spans = _python_function_spans(path)
            elif path.suffix in {".bash", ".sh"} or relative == Path("bin/wg-healthcheck"):
                spans = _bash_function_spans(path)
            else:
                continue
            for name, span in spans:
                key = (relative, name)
                ceiling = REVIEW_BLOCK_EXCEPTIONS.get(key)
                if span > REVIEW_BLOCK_LIMIT:
                    if ceiling is None:
                        failures.append(f"{relative}:{name}: {span} > {REVIEW_BLOCK_LIMIT}")
                    elif span != ceiling:
                        failures.append(f"{relative}:{name}: {span} != frozen {ceiling}")
                    else:
                        observed_exceptions.add(key)
        missing = set(REVIEW_BLOCK_EXCEPTIONS) - observed_exceptions
        failures.extend(
            f"{relative}:{name}: frozen exception is stale"
            for relative, name in sorted(missing)
        )
        self.assertEqual([], failures, "oversized production blocks:\n" + "\n".join(failures))

    def test_managed_source_manifest_is_fixed_and_complete(self):
        fragment_root = ROOT / "libexec" / "wg-healthcheck-managed.d"
        actual_paths = tuple(sorted(fragment_root.iterdir()))
        actual = tuple(path.name for path in actual_paths)
        self.assertEqual(MANAGED_FRAGMENTS, actual)
        for path in actual_paths:
            self.assertTrue(path.is_file(), path)
            self.assertFalse(path.is_symlink(), path)
        builder = (ROOT / "scripts" / "build-managed-module.sh").read_text(
            encoding="utf-8"
        )
        manifest_match = re.search(
            r"(?ms)^readonly -a FRAGMENT_MANIFEST=\(\n(?P<body>.*?)^\)\n",
            builder,
        )
        self.assertIsNotNone(manifest_match)
        manifest = tuple(
            re.findall(r"^  '([^']+)'$", manifest_match.group("body"), re.MULTILINE)
        )
        self.assertEqual(MANAGED_FRAGMENTS, manifest)
        for fragment in MANAGED_FRAGMENTS:
            self.assertEqual(1, builder.count(fragment), fragment)
        self.assertNotIn("wg-healthcheck-managed.d/*", builder)
        generate_match = re.search(
            r"(?ms)^generate\(\) \{\n(?P<body>.*?)^\}\n",
            builder,
        )
        self.assertIsNotNone(generate_match)
        generate = generate_match.group("body")
        self.assertEqual(1, generate.count('for fragment in "${FRAGMENT_MANIFEST[@]}"'))
        self.assertEqual(
            1,
            generate.count('cat -- "$FRAGMENT_DIR/$fragment" >> "$output_path"'),
        )
        self.assertEqual(1, generate.count('printf \'%s\' "$separator" >> "$output_path"'))
        self.assertEqual(1, generate.count("separator=$'\\n'"))
        for forbidden in ("find ", "sort ", "glob", '"$FRAGMENT_DIR"/*'):
            self.assertNotIn(forbidden, generate)

    def test_generated_managed_module_matches_its_canonical_sources(self):
        result = _run_builder(ROOT, "--check")
        self.assertEqual(0, result.returncode, result.stderr)
        mode_result = subprocess.run(
            ["git", "ls-files", "--stage", "--", MANAGED_ARTIFACT.as_posix()],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        if mode_result.returncode == 0:
            self.assertEqual("100644", mode_result.stdout.split(maxsplit=1)[0])
        else:
            # A Windows-created linked worktree stores a drive-letter gitdir that WSL's
            # Git cannot resolve, while DrvFs exposes every file as 0777. Canonical Linux
            # checkouts take the tracked-mode branch above; install/release tests also
            # prove the deployed and archived artifact is 0644.
            self.assertRegex(ROOT.as_posix(), r"^/mnt/[a-z]/")
            self.assertEqual(0o777, (ROOT / MANAGED_ARTIFACT).stat().st_mode & 0o777)

    def test_managed_builder_rejects_drift_extra_sources_and_unsafe_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "scripts").mkdir()
            (root / "libexec").mkdir()
            shutil.copy2(
                ROOT / "scripts" / "build-managed-module.sh",
                root / "scripts" / "build-managed-module.sh",
            )
            shutil.copy2(
                ROOT / MANAGED_ARTIFACT,
                root / MANAGED_ARTIFACT,
            )
            shutil.copytree(
                ROOT / "libexec" / "wg-healthcheck-managed.d",
                root / "libexec" / "wg-healthcheck-managed.d",
            )

            self.assertEqual(0, _run_builder(root, "--check").returncode)

            fragment = root / "libexec" / "wg-healthcheck-managed.d" / MANAGED_FRAGMENTS[0]
            original_fragment = fragment.read_bytes()
            fragment.write_bytes(original_fragment + b"\n")
            self.assertNotEqual(0, _run_builder(root, "--check").returncode)
            fragment.write_bytes(original_fragment)

            unexpected = root / "libexec" / "wg-healthcheck-managed.d" / "99-unexpected.bash"
            unexpected.write_text("# unexpected\n", encoding="utf-8")
            self.assertNotEqual(0, _run_builder(root, "--check").returncode)
            unexpected.unlink()

            runtime = root / MANAGED_ARTIFACT
            runtime.unlink()
            runtime.mkdir()
            write_result = _run_builder(root, "--write")
            self.assertNotEqual(0, write_result.returncode)
            self.assertEqual([], list(runtime.iterdir()))

    def test_runtime_and_distribution_keep_one_managed_admission_boundary(self):
        runtime = (ROOT / "bin" / "wg-healthcheck").read_text(encoding="utf-8")
        installer = (ROOT / "install.sh").read_text(encoding="utf-8")
        packager = (ROOT / "scripts" / "package-release.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "MANAGED_MODULE=/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed",
            runtime,
        )
        for owner in (runtime, installer, packager):
            self.assertNotIn("wg-healthcheck-managed.d", owner)
            self.assertNotIn("build-managed-module.sh", owner)

    def test_shell_test_runners_use_only_explicit_review_units(self):
        splits = (
            (
                "tests/test_wg_healthcheck.sh",
                "tests/lib/wg_healthcheck_test_support.sh",
                "tests/wg_healthcheck",
                "WG_HEALTHCHECK_TEST_ONLY",
            ),
            (
                "tests/test_wg_managed_profiles.sh",
                "tests/lib/wg_managed_test_support.sh",
                "tests/wg_managed",
                "WG_MANAGED_TEST_ONLY",
            ),
            (
                "tests/test_install.sh",
                "tests/lib/install_test_support.sh",
                "tests/install",
                None,
            ),
        )
        for runner_name, support_name, group_name, filter_name in splits:
            runner = (ROOT / runner_name).read_text(encoding="utf-8")
            support = Path(support_name)
            groups = tuple(
                path.relative_to(ROOT)
                for path in sorted((ROOT / group_name).iterdir())
            )
            self.assertGreaterEqual(len(groups), 2, runner_name)
            for relative in (support, *groups):
                self.assertEqual(
                    1,
                    runner.count(f'source "$ROOT/{relative.as_posix()}"'),
                    f"{runner_name}: {relative.as_posix()}",
                )
                self.assertTrue((ROOT / relative).is_file(), relative.as_posix())
                self.assertFalse((ROOT / relative).is_symlink(), relative.as_posix())
            self.assertNotIn(f"{group_name}/*", runner)
            if filter_name is not None:
                self.assertIn(filter_name, runner)

            definition_pattern = re.compile(
                r"^(test_[a-z0-9_]+)\(\)\s*(?:\{|\()",
                re.MULTILINE,
            )
            self.assertEqual(
                [],
                definition_pattern.findall((ROOT / support).read_text(encoding="utf-8")),
                support.as_posix(),
            )
            definitions = []
            for relative in groups:
                definitions.extend(
                    definition_pattern.findall(
                        (ROOT / relative).read_text(encoding="utf-8")
                    )
                )
            self.assertEqual(len(definitions), len(set(definitions)), runner_name)

            if runner_name == "tests/test_install.sh":
                registrations = re.findall(
                    r"^run_test\s+([a-z0-9_]+)\s+(test_[a-z0-9_]+)$",
                    runner,
                    re.MULTILINE,
                )
                for label, function_name in registrations:
                    self.assertEqual(function_name.removeprefix("test_"), label)
                registry = [function_name for _label, function_name in registrations]
            else:
                registry_match = re.search(
                    r"(?ms)^tests=\(\n(?P<body>.*?)^\)\n",
                    runner,
                )
                self.assertIsNotNone(registry_match, runner_name)
                registry = re.findall(
                    r"^  (test_[a-z0-9_]+)$",
                    registry_match.group("body"),
                    re.MULTILINE,
                )
            self.assertEqual(len(registry), len(set(registry)), runner_name)
            self.assertCountEqual(definitions, registry, runner_name)

    def test_provider_compatibility_loader_has_a_fixed_split_manifest(self):
        loader = (ROOT / "tests" / "test_airvpn_api.py").read_text(encoding="utf-8")
        expected = (
            "airvpn_api_tests_cli.py",
            "airvpn_api_tests_diagnostics.py",
            "airvpn_api_tests_generator.py",
            "airvpn_api_tests_profiles.py",
            "airvpn_api_tests_selection.py",
        )
        actual = tuple(
            path.name for path in sorted((ROOT / "tests").glob("airvpn_api_tests_*.py"))
        )
        self.assertEqual(expected, actual)
        for filename in expected:
            module = Path(filename).stem
            self.assertEqual(1, loader.count(f"from tests.{module} import"), module)
        self.assertIn("def load_tests(", loader)
        self.assertNotIn("importlib", loader)
        self.assertNotIn("glob(", loader)

        defined_classes = []
        for filename in expected:
            tree = ast.parse(
                (ROOT / "tests" / filename).read_text(encoding="utf-8"),
                filename=filename,
            )
            for node in tree.body:
                if not isinstance(node, ast.ClassDef):
                    continue
                methods = [
                    child.name
                    for child in node.body
                    if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                    and child.name.startswith("test_")
                ]
                if not methods:
                    continue
                self.assertEqual(len(methods), len(set(methods)), node.name)
                defined_classes.append(node.name)

        registry = None
        loader_tree = ast.parse(loader, filename="test_airvpn_api.py")
        for node in loader_tree.body:
            if not isinstance(node, ast.Assign):
                continue
            if not any(
                isinstance(target, ast.Name) and target.id == "_TEST_CLASSES"
                for target in node.targets
            ):
                continue
            self.assertIsInstance(node.value, (ast.Tuple, ast.List))
            registry = [
                item.id for item in node.value.elts if isinstance(item, ast.Name)
            ]
            self.assertEqual(len(node.value.elts), len(registry))
        self.assertIsNotNone(registry)
        self.assertEqual(len(registry), len(set(registry)))
        self.assertCountEqual(defined_classes, registry)


if __name__ == "__main__":
    unittest.main()
