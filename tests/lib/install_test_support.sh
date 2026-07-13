#!/usr/bin/env bash

# Sourced-installer fixtures intentionally modify dynamically scoped globals only inside
# subshell test cases; later top-level assertions continue using the original values.
# shellcheck disable=SC2031
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
INSTALLER="$ROOT/install.sh"
SOURCE_MAIN="$ROOT/bin/wg-healthcheck"
SOURCE_HELPER="$ROOT/libexec/airvpn-api"
SOURCE_MANAGED_MODULE="$ROOT/libexec/wg-healthcheck-managed"
SOURCE_SETUP="$ROOT/bin/wg-healthcheck-setup"
SOURCE_SETUP_PACKAGE="$ROOT/libexec/wg_healthcheck_setup"
SOURCE_SERVICE="$ROOT/systemd/wg-healthcheck@.service"
SOURCE_TIMER="$ROOT/systemd/wg-healthcheck@.timer"
SOURCE_CONFIG="$ROOT/config/wg0.conf.example"
README_FILE="$ROOT/README.md"
OPERATIONS_FILE="$ROOT/docs/operations.md"
LICENSE_FILE="$ROOT/LICENSE"
GITIGNORE_FILE="$ROOT/.gitignore"
GITATTRIBUTES_FILE="$ROOT/.gitattributes"
SECURITY_FILE="$ROOT/SECURITY.md"
CONTRIBUTING_FILE="$ROOT/CONTRIBUTING.md"
CHANGELOG_FILE="$ROOT/CHANGELOG.md"
VERSION_FILE="$ROOT/VERSION"
RELEASE_NOTES_FILE="$ROOT/docs/releases/v1.1.0.md"
CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wg-healthcheck-install.XXXXXX")" || exit 1
UNRELATED_CWD="$TEST_TMP/unrelated"
mkdir -p -- "$UNRELATED_CWD"

MODE_TESTS_SUPPORTED=0
printf 'mode-probe\n' >"$TEST_TMP/mode-probe"
mkdir -- "$TEST_TMP/mode-probe-dir"
if chmod 0600 "$TEST_TMP/mode-probe" 2>/dev/null &&
   [[ "$(stat -c '%a' -- "$TEST_TMP/mode-probe" 2>/dev/null)" == 600 ]] &&
   chmod 0700 "$TEST_TMP/mode-probe-dir" 2>/dev/null &&
   [[ "$(stat -c '%a' -- "$TEST_TMP/mode-probe-dir" 2>/dev/null)" == 700 ]]; then
  MODE_TESTS_SUPPORTED=1
fi
rm -f -- "$TEST_TMP/mode-probe"
rmdir -- "$TEST_TMP/mode-probe-dir"

passes=0
failures=0
skips=0

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/wg-healthcheck-install.*)
      rm -rf -- "$TEST_TMP"
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

skip() {
  printf 'SKIP: %s\n' "$*"
  return 77
}

assert_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "expected regular file: $1"
}

assert_dir() {
  [[ -d "$1" && ! -L "$1" ]] || fail "expected directory: $1"
}

assert_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "expected path to be absent: $1"
}

assert_mode() {
  local expected="$1" path="$2" actual
  if (( ! MODE_TESTS_SUPPORTED )); then
    return 0
  fi
  actual="$(stat -c '%a' -- "$path")" || return 1
  [[ "$actual" == "$expected" ]] || fail "expected mode $expected for $path, got $actual"
}

assert_same_bytes() {
  cmp -s -- "$1" "$2" || fail "files differ: $1 $2"
}

assert_contains() {
  local needle="$1" file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "missing '$needle' in $file"
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -F -- "$needle" "$file" >/dev/null; then
    fail "unexpected '$needle' in $file"
  fi
}

read_markdown_section() {
  local file="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    $0 == start { inside=1; next }
    inside && $0 == end { exit }
    inside { print }
  ' "$file"
}

assert_ordered_text() {
  local remaining="$1" needle
  shift
  for needle in "$@"; do
    [[ "$remaining" == *"$needle"* ]] || {
      fail "missing or out-of-order documentation text: $needle"
      return 1
    }
    remaining="${remaining#*"$needle"}"
  done
}

new_stage() {
  mktemp -d "$TEST_TMP/stage.XXXXXX"
}

require_posix_modes() {
  if (( ! MODE_TESTS_SUPPORTED )); then
    skip 'staged integration (filesystem has no POSIX mode fidelity)'
    return 77
  fi
}

installer_has_staging_guard() {
  grep -F 'DESTDIR' "$INSTALLER" >/dev/null
}

run_staged() {
  local stage="$1"
  shift
  if ! installer_has_staging_guard; then
    printf 'installer does not implement DESTDIR staging\n' >&2
    return 125
  fi
  (
    cd -- "$UNRELATED_CWD" || exit 1
    DESTDIR="$stage" "$BASH" "$INSTALLER" "$@"
  )
}
