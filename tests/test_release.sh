#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGER="$ROOT/scripts/package-release.sh"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
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
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'unexpected release version: %s\n' "$version" >&2
  exit 1
}

first="$tmp/first"
second="$tmp/second"
"$PACKAGER" --ref "$REF" --output "$first" >/dev/null
sleep 1
"$PACKAGER" --ref "$REF" --output "$second" >/dev/null

base="airvpn-wg-healthcheck-${version}"
tar_name="${base}.tar.gz"
zip_name="${base}.zip"
for name in "$tar_name" "$zip_name" SHA256SUMS; do
  cmp -s -- "$first/$name" "$second/$name" || {
    printf 'release output is not reproducible: %s\n' "$name" >&2
    exit 1
  }
done

(
  cd -- "$first"
  sha256sum -c SHA256SUMS >/dev/null
)

python3 - "$first/$tar_name" "$first/$zip_name" "$base" <<'PY'
import pathlib
import sys
import tarfile
import zipfile

tar_path = pathlib.Path(sys.argv[1])
zip_path = pathlib.Path(sys.argv[2])
prefix = sys.argv[3]
release_notes = f"docs/releases/v{prefix.rsplit('-', 1)[1]}.md"
relative_files = {
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "README.md",
    "SECURITY.md",
    "VERSION",
    "bin/wg-healthcheck",
    "config/wg0.conf.example",
    release_notes,
    "install.sh",
    "libexec/airvpn-api",
    "systemd/wg-healthcheck@.service",
    "systemd/wg-healthcheck@.timer",
}
expected = {f"{prefix}/{name}" for name in relative_files}
executables = {
    f"{prefix}/bin/wg-healthcheck",
    f"{prefix}/install.sh",
    f"{prefix}/libexec/airvpn-api",
}

with tarfile.open(tar_path, "r:gz") as archive:
    members = {member.name: member for member in archive.getmembers() if member.isfile()}
    if set(members) != expected:
        raise SystemExit(f"unexpected tar contents: {sorted(set(members) ^ expected)}")
    if any(member.issym() or member.islnk() for member in archive.getmembers()):
        raise SystemExit("release tar contains a link")
    for name in executables:
        if members[name].mode & 0o111 == 0:
            raise SystemExit(f"release executable lost its mode: {name}")
    tar_bytes = {name: archive.extractfile(member).read() for name, member in members.items()}

with zipfile.ZipFile(zip_path) as archive:
    names = {name for name in archive.namelist() if not name.endswith("/")}
    if names != expected:
        raise SystemExit(f"unexpected zip contents: {sorted(names ^ expected)}")
    for name in executables:
        if (archive.getinfo(name).external_attr >> 16) & 0o111 == 0:
            raise SystemExit(f"release ZIP executable lost its mode: {name}")
    for name in expected:
        if archive.read(name) != tar_bytes[name]:
            raise SystemExit(f"archive payloads differ: {name}")

for name in expected:
    lowered = name.lower()
    if "/.git" in lowered or "/tests/" in lowered or lowered.endswith((".env", ".bak", ".tmp")):
        raise SystemExit(f"unsafe release path: {name}")

print(f"release archives verified: {len(expected)} files")
PY

tar_extract="$tmp/tar-extract"
stage="$tmp/stage"
mkdir -m 0700 -- "$tar_extract" "$stage"
tar -xzf "$first/$tar_name" -C "$tar_extract"
DESTDIR="$stage" bash -p "$tar_extract/$base/install.sh" wg-release >/dev/null
cmp -s -- "$tar_extract/$base/bin/wg-healthcheck" "$stage/usr/local/sbin/wg-healthcheck"
cmp -s -- "$tar_extract/$base/libexec/airvpn-api" "$stage/usr/local/libexec/wg-healthcheck/airvpn-api"
cmp -s -- "$tar_extract/$base/config/wg0.conf.example" "$stage/etc/wireguard/healthcheck.d/wg-release.conf"

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
