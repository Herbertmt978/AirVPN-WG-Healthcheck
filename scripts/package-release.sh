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

for command_name in git gzip install mktemp sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'package-release.sh: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

git -C "$ROOT" rev-parse --verify --quiet "$REF^{tree}" >/dev/null || {
  printf 'package-release.sh: invalid Git ref: %s\n' "$REF" >&2
  exit 1
}

version="$(git -C "$ROOT" show "$REF:VERSION")" || {
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
  README.md
  SECURITY.md
  VERSION
  bin/wg-healthcheck
  config/wg0.conf.example
  "$release_notes"
  install.sh
  libexec/airvpn-api
  systemd/wg-healthcheck@.service
  systemd/wg-healthcheck@.timer
)

for path in "${files[@]}"; do
  git -C "$ROOT" cat-file -e "$REF:$path" 2>/dev/null || {
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

if commit="$(git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null)"; then
  archive_time="$(git -C "$ROOT" show -s --format=%cI "$commit")"
else
  archive_time='2000-01-01T00:00:00Z'
fi

git -C "$ROOT" archive \
  --format=tar \
  --mtime="$archive_time" \
  --prefix="$prefix/" \
  "$REF" -- "${files[@]}" > "$tmp/${prefix}.tar"
gzip -n -9 < "$tmp/${prefix}.tar" > "$tmp/$tar_name"

git -C "$ROOT" archive \
  --format=zip \
  -9 \
  --mtime="$archive_time" \
  --prefix="$prefix/" \
  --output="$tmp/$zip_name" \
  "$REF" -- "${files[@]}"

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
