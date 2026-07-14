#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
REF=HEAD
OUTPUT="$ROOT/dist"

usage() {
  printf 'usage: %s [--ref <git-ref>] [--output <directory>]\n' "${0##*/}" >&2
}

while (( $# )); do
  case "$1" in
    --ref)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      REF="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

for command_name in git gzip install mktemp python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'package-release.sh: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

commit="$(git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null)" || {
  printf 'package-release.sh: Git ref must resolve to a commit: %s\n' "$REF" >&2
  exit 1
}

version="$(git -C "$ROOT" show "$commit:VERSION")" || {
  printf 'package-release.sh: VERSION is missing from %s\n' "$REF" >&2
  exit 1
}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'package-release.sh: invalid release version: %s\n' "$version" >&2
  exit 1
}

release_notes="docs/releases/v${version}.md"
files=(
  CHANGELOG.md
  CONTRIBUTING.md
  LICENSE
  README.md
  SECURITY.md
  VERSION
  bin/wg-healthcheck
  bin/wg-healthcheck-setup
  config/wg0.conf.example
  docs/operations.md
  "$release_notes"
  install.sh
  libexec/airvpn-api
  libexec/wg-healthcheck-managed
  libexec/wg_healthcheck_setup/__init__.py
  libexec/wg_healthcheck_setup/application.py
  libexec/wg_healthcheck_setup/apply_config.py
  libexec/wg_healthcheck_setup/apply_journal.py
  libexec/wg_healthcheck_setup/apply_system.py
  libexec/wg_healthcheck_setup/cli.py
  libexec/wg_healthcheck_setup/clients.py
  libexec/wg_healthcheck_setup/credential_state.py
  libexec/wg_healthcheck_setup/model.py
  libexec/wg_healthcheck_setup/private_io.py
  libexec/wg_healthcheck_setup/store.py
  systemd/wg-healthcheck@.service
  systemd/wg-healthcheck@.timer
)

for path in "${files[@]}"; do
  git -C "$ROOT" cat-file -e "$commit:$path" 2>/dev/null || {
    printf 'package-release.sh: required release path is missing from %s: %s\n' "$REF" "$path" >&2
    exit 1
  }
done

mkdir -p -- "$OUTPUT"
[[ -d "$OUTPUT" && ! -L "$OUTPUT" ]] || {
  printf 'package-release.sh: output must be a non-symlink directory\n' >&2
  exit 1
}
OUTPUT="$(cd -- "$OUTPUT" && pwd -P)"
[[ "$OUTPUT" != / ]] || {
  printf 'package-release.sh: refusing to use / as the output directory\n' >&2
  exit 1
}

prefix="airvpn-wg-healthcheck-${version}"
tar_name="${prefix}.tar.gz"
zip_name="${prefix}.zip"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/airvpn-wg-healthcheck-release.XXXXXX")"
cleanup() {
  case "$tmp" in
    "${TMPDIR:-/tmp}"/airvpn-wg-healthcheck-release.*) rm -rf -- "$tmp" ;;
  esac
}
trap cleanup EXIT

archive_time="$(git -C "$ROOT" show -s --format=%cI "$commit")"

git -c tar.umask=0022 -C "$ROOT" archive \
  --format=tar \
  --prefix="$prefix/" \
  "$commit" -- "${files[@]}" > "$tmp/${prefix}.tar"
gzip -n -9 < "$tmp/${prefix}.tar" > "$tmp/$tar_name"

python3 - "$tmp/${prefix}.tar" "$tmp/$zip_name" "$archive_time" <<'PY'
import datetime
import stat
import sys
import tarfile
import zipfile

tar_path, zip_path, archive_time = sys.argv[1:]
timestamp = datetime.datetime.fromisoformat(archive_time.replace("Z", "+00:00"))
timestamp = timestamp.astimezone(datetime.timezone.utc)
year = min(max(timestamp.year, 1980), 2107)
zip_time = (year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second)

with tarfile.open(tar_path, "r:") as source, zipfile.ZipFile(
    zip_path,
    "w",
    compression=zipfile.ZIP_DEFLATED,
    compresslevel=9,
) as destination:
    for member in sorted(source.getmembers(), key=lambda item: item.name):
        if not member.isfile():
            continue
        payload = source.extractfile(member)
        if payload is None:
            raise SystemExit(f"could not read archived file: {member.name}")
        info = zipfile.ZipInfo(member.name, zip_time)
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (stat.S_IFREG | (member.mode & 0o777)) << 16
        destination.writestr(info, payload.read(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
PY

for target in "$OUTPUT/$tar_name" "$OUTPUT/$zip_name" "$OUTPUT/SHA256SUMS"; do
  [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || {
    printf 'package-release.sh: refusing unsafe output target: %s\n' "$target" >&2
    exit 1
  }
done

install -m 0644 "$tmp/$tar_name" "$OUTPUT/$tar_name"
install -m 0644 "$tmp/$zip_name" "$OUTPUT/$zip_name"
(
  cd -- "$OUTPUT"
  sha256sum "$tar_name" "$zip_name" > "$tmp/SHA256SUMS"
)
install -m 0644 "$tmp/SHA256SUMS" "$OUTPUT/SHA256SUMS"

printf '%s\n' "$OUTPUT/$tar_name" "$OUTPUT/$zip_name" "$OUTPUT/SHA256SUMS"
