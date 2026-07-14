#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REF=HEAD

if (( $# )); then
  if [[ $# -ne 2 || "$1" != --ref ]]; then
    printf 'usage: %s [--ref <git-ref>]\n' "${0##*/}" >&2
    exit 64
  fi
  REF="$2"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/wg-healthcheck-release-test.XXXXXX")"
cleanup() {
  case "$tmp" in
    "${TMPDIR:-/tmp}"/wg-healthcheck-release-test.*) rm -rf -- "$tmp" ;;
  esac
}
trap cleanup EXIT

version="$(git -C "$ROOT" show "$REF:VERSION")"
[[ "$version" == '1.1.0' ]] || {
  printf 'release VERSION must be exactly 1.1.0: %s\n' "$version" >&2
  exit 1
}

runtime_version="$(git -C "$ROOT" show "$REF:bin/wg-healthcheck" |
  sed -n "s/^WG_HEALTHCHECK_VERSION='\([^']*\)'$/\1/p")"
[[ "$runtime_version" == "$version" ]] || {
  printf 'wg-healthcheck version is not synchronized with VERSION: %s\n' "$runtime_version" >&2
  exit 1
}

for release_path in \
  'CHANGELOG.md' \
  'docs/releases/v1.1.0.md' \
  '.github/ISSUE_TEMPLATE/bug_report.yml' \
  '.github/workflows/ci.yml' \
  '.github/workflows/release.yml'; do
  git -C "$ROOT" cat-file -e "$REF:$release_path" 2>/dev/null || {
    printf 'release source is missing: %s\n' "$release_path" >&2
    exit 1
  }
done

changelog="$(git -C "$ROOT" show "$REF:CHANGELOG.md")"
release_notes="$(git -C "$ROOT" show "$REF:docs/releases/v1.1.0.md")"
bug_report="$(git -C "$ROOT" show "$REF:.github/ISSUE_TEMPLATE/bug_report.yml")"
package_source="$(git -C "$ROOT" show "$REF:scripts/package-release.sh")"
test_source="$(git -C "$ROOT" show "$REF:tests/test_release.sh")"
[[ "$(<"$ROOT/scripts/package-release.sh")" == "$package_source" ]] || {
  printf 'checked-out packager does not match the requested release ref\n' >&2
  exit 1
}
[[ "$(<"$ROOT/tests/test_release.sh")" == "$test_source" ]] || {
  printf 'checked-out release test does not match the requested release ref\n' >&2
  exit 1
}
# The assertion intentionally searches the packager source for this literal expression.
# shellcheck disable=SC2016
grep -F -- '"$REF^{commit}"' <<<"$package_source" >/dev/null || {
  printf 'packager does not pin the release ref to one commit\n' >&2
  exit 1
}
[[ "$package_source" != *'--mtime='* ]] || {
  printf 'packager depends on a post-Ubuntu-22.04 git archive option\n' >&2
  exit 1
}
grep -F -- '## [1.1.0]' <<<"$changelog" >/dev/null || {
  printf 'CHANGELOG.md has no 1.1.0 release section\n' >&2
  exit 1
}
grep -F -- 'v1.1.0' <<<"$release_notes" >/dev/null || {
  printf 'v1.1.0 release notes do not identify the release\n' >&2
  exit 1
}
shopt -s nocasematch
for required in 'wg-healthcheck 1.1.0' 'API key' 'generated profile' 'redact'; do
  [[ "$bug_report" == *"$required"* ]] || {
    printf 'bug report template is missing 1.1 redaction guidance: %s\n' "$required" >&2
    exit 1
  }
done
shopt -u nocasematch
for required in \
  'LICENSE' \
  'docs/operations.md' \
  'bin/wg-healthcheck-setup' \
  'libexec/wg-healthcheck-managed' \
  'libexec/wg_healthcheck_setup'; do
  grep -F -- "$required" <<<"$package_source" >/dev/null || {
    printf 'packaging source does not include the 1.1 release owner: %s\n' "$required" >&2
    exit 1
  }
done

first="$tmp/first"
second="$tmp/second"
tagged="$tmp/tagged"
"$ROOT/scripts/package-release.sh" --ref "$REF" --output "$first" >/dev/null
sleep 1
"$ROOT/scripts/package-release.sh" --ref "$REF" --output "$second" >/dev/null

commit="$(git -C "$ROOT" rev-parse --verify "$REF^{commit}")"
tag_object="$(
  printf '%s\n' \
    "object $commit" \
    'type commit' \
    'tag release-portability-test' \
    'tagger Release Test <release-test@example.invalid> 946684800 +0000' \
    '' \
    'Release portability test.' |
    git -C "$ROOT" mktag
)"
"$ROOT/scripts/package-release.sh" --ref "$tag_object" --output "$tagged" >/dev/null

base="airvpn-wg-healthcheck-${version}"
tar_name="${base}.tar.gz"
zip_name="${base}.zip"
for name in "$tar_name" "$zip_name" SHA256SUMS; do
  cmp -s -- "$first/$name" "$second/$name" || {
    printf 'release output is not reproducible: %s\n' "$name" >&2
    exit 1
  }
  cmp -s -- "$first/$name" "$tagged/$name" || {
    printf 'annotated-tag release output differs: %s\n' "$name" >&2
    exit 1
  }
done

(
  cd -- "$first"
  sha256sum -c SHA256SUMS >/dev/null
)

commit_epoch="$(git -C "$ROOT" show -s --format=%ct "$commit")"
python3 - "$first/$tar_name" "$first/$zip_name" "$base" "$commit_epoch" <<'PY'
import datetime
import pathlib
import re
import stat
import sys
import tarfile
import zipfile

tar_path = pathlib.Path(sys.argv[1])
zip_path = pathlib.Path(sys.argv[2])
prefix = sys.argv[3]
commit_epoch = int(sys.argv[4])
commit_time = datetime.datetime.fromtimestamp(commit_epoch, datetime.timezone.utc)
expected_zip_time = (
    commit_time.year,
    commit_time.month,
    commit_time.day,
    commit_time.hour,
    commit_time.minute,
    commit_time.second - commit_time.second % 2,
)
release_notes = f"docs/releases/v{prefix.rsplit('-', 1)[1]}.md"
relative_files = {
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "VERSION",
    "bin/wg-healthcheck",
    "bin/wg-healthcheck-setup",
    "config/wg0.conf.example",
    "docs/operations.md",
    release_notes,
    "install.sh",
    "libexec/airvpn-api",
    "libexec/wg-healthcheck-managed",
    "systemd/wg-healthcheck@.service",
    "systemd/wg-healthcheck@.timer",
}
relative_files.update(
    f"libexec/wg_healthcheck_setup/{name}.py"
    for name in (
        "__init__",
        "application",
        "apply_config",
        "apply_journal",
        "apply_system",
        "cli",
        "clients",
        "credential_state",
        "model",
        "private_io",
        "store",
    )
)
expected = {f"{prefix}/{name}" for name in relative_files}
executables = {
    f"{prefix}/bin/wg-healthcheck",
    f"{prefix}/bin/wg-healthcheck-setup",
    f"{prefix}/install.sh",
    f"{prefix}/libexec/airvpn-api",
}
expected_modes = {
    name: 0o755 if name in executables else 0o644
    for name in expected
}
forbidden_path = re.compile(
    r"(?:^|/)(?:[^/]+[.](?:api-key|candidate|pending-healthcheck|"
    r"safety-healthcheck|setup-transaction|api-state)|[^/]+[.]conf[.]pre-managed)$",
    re.IGNORECASE,
)
forbidden_payload = re.compile(
    rb"(?m)^\s*(?:PrivateKey|PresharedKey|AIRVPN_API_KEY)\s*=\s*\S+",
)
raw_api_key_payload = re.compile(rb"(?m)^[0-9A-Fa-f]{64}\r?$")
host_identifier_payload = re.compile(
    rb"(?m)^(?:HOSTNAME|HOST_ID|VM_ID|MACHINE_ID)="
    rb"[A-Za-z0-9][A-Za-z0-9._:-]{3,}$",
)


def check_archive_names(names):
    if names != expected:
        raise SystemExit(f"unexpected archive contents: {sorted(names ^ expected)}")
    for name in names:
        relative = name.removeprefix(f"{prefix}/")
        if forbidden_path.search(relative):
            raise SystemExit(f"release archive contains runtime/private artifact: {relative}")


with tarfile.open(tar_path, "r:gz") as archive:
    archive_members = archive.getmembers()
    normalized_names = [
        member.name.rstrip("/") if member.isdir() else member.name
        for member in archive_members
    ]
    if len(normalized_names) != len(set(normalized_names)):
        raise SystemExit("release tar contains duplicate members")
    unsupported = [
        member.name
        for member in archive_members
        if not member.isfile() and not member.isdir()
    ]
    if unsupported:
        raise SystemExit(f"release tar contains unsupported members: {unsupported}")
    incorrect_mtimes = [
        member.name for member in archive_members if member.mtime != commit_epoch
    ]
    if incorrect_mtimes:
        raise SystemExit(f"release tar has non-commit mtimes: {incorrect_mtimes}")
    members = {member.name: member for member in archive_members if member.isfile()}
    check_archive_names(set(members))
    expected_directories = {prefix}
    for name in expected:
        parent = pathlib.PurePosixPath(name).parent
        while str(parent) not in ("", "."):
            expected_directories.add(str(parent))
            parent = parent.parent
    directories = {
        member.name.rstrip("/") for member in archive_members if member.isdir()
    }
    if directories != expected_directories:
        raise SystemExit(
            f"unexpected tar directories: {sorted(directories ^ expected_directories)}"
        )
    for name, expected_mode in expected_modes.items():
        if members[name].mode & 0o777 != expected_mode:
            raise SystemExit(f"release tar has incorrect mode for {name}: {members[name].mode:o}")
    tar_bytes = {name: archive.extractfile(member).read() for name, member in members.items()}

with zipfile.ZipFile(zip_path) as archive:
    infos = archive.infolist()
    archive_names = [info.filename for info in infos]
    if len(archive_names) != len(set(archive_names)):
        raise SystemExit("release ZIP contains duplicate members")
    if any(info.is_dir() for info in infos):
        raise SystemExit("release ZIP contains unexpected directory members")
    names = set(archive_names)
    check_archive_names(names)
    for name, expected_mode in expected_modes.items():
        info = archive.getinfo(name)
        if info.date_time != expected_zip_time:
            raise SystemExit(f"release ZIP has non-commit timestamp for {name}")
        mode = (info.external_attr >> 16) & 0o777
        if stat.S_ISLNK(info.external_attr >> 16):
            raise SystemExit(f"release ZIP contains a link: {name}")
        if mode != expected_mode:
            raise SystemExit(f"release ZIP has incorrect mode for {name}: {mode:o}")
    for name in expected:
        if archive.read(name) != tar_bytes[name]:
            raise SystemExit(f"archive payloads differ: {name}")

for name in expected:
    lowered = name.lower()
    if "/.git" in lowered or "/tests/" in lowered or lowered.endswith((".env", ".bak", ".tmp")):
        raise SystemExit(f"unsafe release path: {name}")
    if forbidden_payload.search(tar_bytes[name]):
        raise SystemExit(f"release payload contains a credential or WireGuard profile: {name}")
    if raw_api_key_payload.search(tar_bytes[name]):
        raise SystemExit(f"release payload contains a bare API-key record: {name}")
    if host_identifier_payload.search(tar_bytes[name]):
        raise SystemExit(f"release payload contains a host identifier: {name}")

print(f"release archives verified: {len(expected)} files")
PY

tar_extract="$tmp/tar-extract"
zip_extract="$tmp/zip-extract"
tar_stage="$tmp/tar-stage"
zip_stage="$tmp/zip-stage"
mkdir -m 0700 -- "$tar_extract" "$zip_extract" "$tar_stage" "$zip_stage"
tar -xzf "$first/$tar_name" -C "$tar_extract"
python3 - "$first/$zip_name" "$zip_extract" <<'PY'
import pathlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(pathlib.Path(sys.argv[2]))
PY

install_from_archive() {
  local archive_root="$1" stage_root="$2" setup_module

  DESTDIR="$stage_root" bash -p "$archive_root/install.sh" wg-release >/dev/null
  cmp -s -- "$archive_root/bin/wg-healthcheck" "$stage_root/usr/local/sbin/wg-healthcheck"
  cmp -s -- "$archive_root/bin/wg-healthcheck-setup" "$stage_root/usr/local/sbin/wg-healthcheck-setup"
  cmp -s -- "$archive_root/libexec/airvpn-api" "$stage_root/usr/local/libexec/wg-healthcheck/airvpn-api"
  cmp -s -- "$archive_root/libexec/wg-healthcheck-managed" "$stage_root/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed"
  cmp -s -- "$archive_root/systemd/wg-healthcheck@.service" "$stage_root/etc/systemd/system/wg-healthcheck@.service"
  cmp -s -- "$archive_root/systemd/wg-healthcheck@.timer" "$stage_root/etc/systemd/system/wg-healthcheck@.timer"
  cmp -s -- "$archive_root/config/wg0.conf.example" "$stage_root/etc/wireguard/healthcheck.d/wg-release.conf"
  [[ "$(stat -c '%a' -- "$stage_root/usr/local/sbin/wg-healthcheck")" == 755 ]]
  [[ "$(stat -c '%a' -- "$stage_root/usr/local/sbin/wg-healthcheck-setup")" == 755 ]]
  [[ "$(stat -c '%a' -- "$stage_root/usr/local/libexec/wg-healthcheck/airvpn-api")" == 755 ]]
  [[ "$(stat -c '%a' -- "$stage_root/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed")" == 644 ]]
  [[ "$(stat -c '%a' -- "$stage_root/etc/systemd/system/wg-healthcheck@.service")" == 644 ]]
  [[ "$(stat -c '%a' -- "$stage_root/etc/systemd/system/wg-healthcheck@.timer")" == 644 ]]
  [[ "$(stat -c '%a' -- "$stage_root/etc/wireguard/healthcheck.d/wg-release.conf")" == 600 ]]
  [[ "$(stat -c '%a' -- "$stage_root/usr/local/libexec/wg-healthcheck/wg_healthcheck_setup")" == 755 ]]
  [[ "$(stat -c '%a' -- "$stage_root/etc/wireguard/healthcheck.d")" == 700 ]]
  [[ "$(stat -c '%a' -- "$stage_root/var/lib/wg-healthcheck")" == 700 ]]
  for setup_module in "$archive_root"/libexec/wg_healthcheck_setup/*.py; do
    cmp -s -- "$setup_module" "$stage_root/usr/local/libexec/wg-healthcheck/wg_healthcheck_setup/${setup_module##*/}"
    [[ "$(stat -c '%a' -- "$stage_root/usr/local/libexec/wg-healthcheck/wg_healthcheck_setup/${setup_module##*/}")" == 644 ]]
  done
  [[ "$(bash -p "$archive_root/bin/wg-healthcheck" --version)" == 'wg-healthcheck 1.1.0' ]]
  python3 "$archive_root/bin/wg-healthcheck-setup" --help >/dev/null
  python3 "$archive_root/libexec/airvpn-api" --help >/dev/null
  python3 - "$archive_root/libexec/airvpn-api" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("release_airvpn_api", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
payload = {
    "result": "ok",
    "servers": [
        {
            "public_name": "BritainOne",
            "country_code": "GB",
            "country_name": "United Kingdom",
            "location": "London",
            "bw_max": 10000,
            "currentload": 10,
            "users": 20,
            "health": "ok",
            "ip_v4_in1": "198.51.100.22",
        },
        {
            "public_name": "NetherlandsOne",
            "country_code": "NL",
            "country_name": "Netherlands",
            "location": "Amsterdam",
            "bw_max": 10000,
            "currentload": 10,
            "users": 20,
            "health": "ok",
            "ip_v4_in1": "198.51.100.21",
        },
    ],
}
assert module.list_eligible_countries(payload) == [
    ("GB", "United Kingdom", "1"),
    ("NL", "Netherlands", "1"),
]
assert module.select_candidate(payload, ["NL"], 1637, "")[:3] == (
    "NetherlandsOne",
    "198.51.100.21:1637",
    "NL",
)
PY
  grep -Fx -- 'AIRVPN_PROFILE_SOURCE=static' "$archive_root/config/wg0.conf.example" >/dev/null
}

install_from_archive "$tar_extract/$base" "$tar_stage"
install_from_archive "$zip_extract/$base" "$zip_stage"

CI_WORKFLOW="$tmp/ci.yml"
RELEASE_WORKFLOW="$tmp/release.yml"
git -C "$ROOT" show "$REF:.github/workflows/ci.yml" >"$CI_WORKFLOW"
git -C "$ROOT" show "$REF:.github/workflows/release.yml" >"$RELEASE_WORKFLOW"

python3 - "$CI_WORKFLOW" "$RELEASE_WORKFLOW" <<'PY'
import pathlib
import re
import sys

ci = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
release = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")


def require(text, needle, message):
    if needle not in text:
        raise SystemExit(f"{message}: {needle}")


def require_pattern(text, pattern, message):
    if not re.search(pattern, text, re.MULTILINE):
        raise SystemExit(message)


require(ci, "runs-on: ubuntu-${{ matrix.ubuntu }}", "CI does not use the Ubuntu matrix")
if not re.search(r"(?m)^\s*ubuntu:\s*\[.*22[.]04.*24[.]04.*\]", ci):
    raise SystemExit("CI matrix must cover Ubuntu 22.04 and 24.04")

ci_concurrency = re.search(r"(?ms)^concurrency:\s*\n(?P<body>.*?)(?=^[^ ]|\Z)", ci)
if ci_concurrency is None:
    raise SystemExit("CI branch concurrency is missing")
require(ci_concurrency.group("body"), "github.ref", "CI concurrency is not branch-scoped")
require_pattern(ci_concurrency.group("body"), r"cancel-in-progress:\s*true", "CI branch concurrency must cancel stale runs")

for required in (
    'PYTHON_BIN="${pythonLocation:?}/bin/python"',
    '"$PYTHON_BIN" -m unittest discover -s tests -p \'test_*.py\' -v',
    "bash scripts/build-managed-module.sh --check",
    "bash -n bin/wg-healthcheck libexec/wg-healthcheck-managed libexec/wg-healthcheck-managed.d/*.bash install.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/install/*.sh tests/wg_healthcheck/*.sh tests/wg_managed/*.sh",
    "shellcheck -s bash -x -S style bin/wg-healthcheck libexec/wg-healthcheck-managed install.sh scripts/*.sh tests/*.sh tests/lib/wg_healthcheck_test_support.sh tests/lib/wg_managed_test_support.sh tests/wg_healthcheck/*.sh tests/wg_managed/*.sh",
    "shellcheck -s bash -x -S style -e SC2034 libexec/wg-healthcheck-managed.d/*.bash",
    "sudo install -D -m 0755 bin/wg-healthcheck-setup /usr/local/sbin/wg-healthcheck-setup",
    "sudo install -D -m 0644 libexec/wg-healthcheck-managed /usr/local/libexec/wg-healthcheck/wg-healthcheck-managed",
    "sudo install -D -m 0644 libexec/wg_healthcheck_setup/*.py /usr/local/libexec/wg-healthcheck/wg_healthcheck_setup/",
    "systemd-analyze verify systemd/wg-healthcheck@.service systemd/wg-healthcheck@.timer",
):
    require(ci, required, "CI omits managed release verification")

for suite in (
    "tests/test_wg_healthcheck.sh",
    "tests/test_wg_managed_profiles.sh",
    "tests/test_install.sh",
):
    if ci.count(suite) < 2:
        raise SystemExit(f"CI must run root and non-root variants: {suite}")
for forbidden in ("sudo -E", "sudo --preserve-env", "pull_request_target", "secrets."):
    if forbidden in ci:
        raise SystemExit(f"CI contains unsafe privilege/secret behavior: {forbidden}")

smoke_match = re.search(r"(?ms)^  airvpn-api-smoke:.*?(?=^  \S|\Z)", ci)
if smoke_match is None:
    raise SystemExit("credential-free public API smoke job is missing")
smoke = smoke_match.group(0)
for required in (
    "python3 libexec/airvpn-api select",
    "https://airvpn.org/api/status/?format=json",
    "--timeout 20",
):
    require(smoke, required, "credential-free smoke is incomplete")
for forbidden in (
    "secrets.",
    "AIRVPN_API_KEY",
    "--api-key",
    "--credential-file",
    "sudo",
    "docker",
    "wg-quick",
):
    if forbidden.casefold() in smoke.casefold():
        raise SystemExit(f"credential-free smoke contains forbidden dependency: {forbidden}")

release_concurrency = re.search(r"(?ms)^concurrency:\s*\n(?P<body>.*?)(?=^[^ ]|\Z)", release)
if release_concurrency is None:
    raise SystemExit("release concurrency is missing")
require(release_concurrency.group("body"), "github.ref", "release concurrency is not tag-scoped")
require_pattern(
    release_concurrency.group("body"),
    r"cancel-in-progress:\s*false",
    "release concurrency must not cancel an in-progress publication",
)

for required in (
    "fetch-depth: 0",
    "git /repo --redact=100 --no-banner --no-color",
    "tar -xzf \"dist/airvpn-wg-healthcheck-${version}.tar.gz\" -C release-audit/tar",
    "unzip -q \"dist/airvpn-wg-healthcheck-${version}.zip\" -d release-audit/zip",
    "dir /scan/tar --redact=100 --no-banner --no-color",
    "dir /scan/zip --redact=100 --no-banner --no-color",
):
    require(release, required, "release workflow omits required redacted secret scan")

for suite in (
    "tests/test_wg_healthcheck.sh",
    "tests/test_wg_managed_profiles.sh",
    "tests/test_install.sh",
):
    if release.count(suite) < 2:
        raise SystemExit(f"release verification must run root and non-root variants: {suite}")
PY

# Literal workflow expressions must not expand in the test process.
# shellcheck disable=SC2016
for expected in \
  "tags:" \
  "'v[0-9]+.[0-9]+.[0-9]+'" \
  'contents: read' \
  'contents: write' \
  'persist-credentials: false' \
  'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
  'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1' \
  'test "$(git cat-file -t "$GITHUB_REF_NAME")" = tag' \
  'bash tests/test_release.sh --ref "$GITHUB_REF_NAME"' \
  'zricethezav/gitleaks:v8.30.1@sha256:' \
  'gh release create "$GITHUB_REF_NAME"' \
  '--draft' \
  '--verify-tag' \
  '--draft=false --latest' \
  '--notes-file "release-input/docs/releases/${GITHUB_REF_NAME}.md"'; do
  grep -F -- "$expected" "$RELEASE_WORKFLOW" >/dev/null || {
    printf 'release workflow is missing: %s\n' "$expected" >&2
    exit 1
  }
done

for forbidden in pull_request_target 'secrets.' 'persist-credentials: true'; do
  if grep -F -- "$forbidden" "$RELEASE_WORKFLOW" >/dev/null; then
    printf 'release workflow contains forbidden text: %s\n' "$forbidden" >&2
    exit 1
  fi
done

printf 'Release package checks passed\n'
