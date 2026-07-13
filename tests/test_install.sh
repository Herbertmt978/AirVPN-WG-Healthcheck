#!/usr/bin/env bash

# Sourced-installer fixtures intentionally modify dynamically scoped globals only inside
# subshell test cases; later top-level assertions continue using the original values.
# shellcheck disable=SC2031
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
RELEASE_NOTES_FILE="$ROOT/docs/releases/v1.0.0.md"
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

test_default_staged_install_from_unrelated_cwd() {
  local stage
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1

  run_staged "$stage" >"$TEST_TMP/default.out" 2>"$TEST_TMP/default.err" ||
    fail "default staged install failed"

  assert_file "$stage/usr/local/sbin/wg-healthcheck" || return 1
  assert_file "$stage/usr/local/libexec/wg-healthcheck/airvpn-api" || return 1
  assert_file "$stage/etc/systemd/system/wg-healthcheck@.service" || return 1
  assert_file "$stage/etc/systemd/system/wg-healthcheck@.timer" || return 1
  assert_file "$stage/etc/wireguard/healthcheck.d/wg0.conf" || return 1
  assert_absent "$stage/etc/wireguard/airvpn-healthcheck.env" || return 1

  assert_same_bytes "$SOURCE_MAIN" "$stage/usr/local/sbin/wg-healthcheck" || return 1
  assert_same_bytes "$SOURCE_HELPER" "$stage/usr/local/libexec/wg-healthcheck/airvpn-api" || return 1
  assert_same_bytes "$SOURCE_SERVICE" "$stage/etc/systemd/system/wg-healthcheck@.service" || return 1
  assert_same_bytes "$SOURCE_TIMER" "$stage/etc/systemd/system/wg-healthcheck@.timer" || return 1
  assert_same_bytes "$SOURCE_CONFIG" "$stage/etc/wireguard/healthcheck.d/wg0.conf" || return 1

  assert_dir "$stage/usr/local/libexec/wg-healthcheck" || return 1
  assert_dir "$stage/etc/wireguard/healthcheck.d" || return 1
  assert_mode 755 "$stage/usr/local/sbin/wg-healthcheck" || return 1
  assert_mode 755 "$stage/usr/local/libexec/wg-healthcheck/airvpn-api" || return 1
  assert_mode 755 "$stage/usr/local/libexec/wg-healthcheck" || return 1
  assert_mode 644 "$stage/etc/systemd/system/wg-healthcheck@.service" || return 1
  assert_mode 644 "$stage/etc/systemd/system/wg-healthcheck@.timer" || return 1
  assert_mode 700 "$stage/etc/wireguard/healthcheck.d" || return 1
  assert_mode 600 "$stage/etc/wireguard/healthcheck.d/wg0.conf" || return 1
}

test_staged_managed_profile_artifacts_have_exact_content_and_modes() {
  local stage source relative target
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1

  run_staged "$stage" wg0 >/dev/null 2>&1 || { fail 'staged managed-profile install failed'; return 1; }

  assert_file "$stage/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed" || return 1
  assert_same_bytes "$SOURCE_MANAGED_MODULE" \
    "$stage/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed" || return 1
  assert_mode 644 "$stage/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed" || return 1

  assert_file "$stage/usr/local/sbin/wg-healthcheck-setup" || return 1
  assert_same_bytes "$SOURCE_SETUP" "$stage/usr/local/sbin/wg-healthcheck-setup" || return 1
  assert_mode 755 "$stage/usr/local/sbin/wg-healthcheck-setup" || return 1

  assert_dir "$stage/usr/local/libexec/wg-healthcheck/wg_healthcheck_setup" || return 1
  while IFS= read -r source; do
    relative="${source#"$SOURCE_SETUP_PACKAGE"/}"
    target="$stage/usr/local/libexec/wg-healthcheck/wg_healthcheck_setup/$relative"
    assert_file "$target" || return 1
    assert_same_bytes "$source" "$target" || return 1
    assert_mode 644 "$target" || return 1
  done < <(find "$SOURCE_SETUP_PACKAGE" -type f -name '*.py' -print | sort)

  assert_dir "$stage/var/lib/wg-healthcheck" || return 1
  assert_mode 700 "$stage/var/lib/wg-healthcheck"
}

test_new_sources_and_targets_are_preflighted_before_staging_mutation() {
  local copy_root stage rc outside target before after
  local -a missing_sources=(
    'libexec/wg-healthcheck-managed'
    'bin/wg-healthcheck-setup'
    'libexec/wg_healthcheck_setup/__init__.py'
  )

  copy_root="$TEST_TMP/installer-managed-sources"
  mkdir -p -- "$copy_root"
  cp -- "$INSTALLER" "$copy_root/install.sh"
  cp -a -- "$ROOT/bin" "$ROOT/libexec" "$ROOT/systemd" "$ROOT/config" "$copy_root/"

  for target in "${missing_sources[@]}"; do
    rm -f -- "$copy_root/$target"
    stage="$(new_stage)" || return 1
    (
      cd -- "$UNRELATED_CWD" || exit 1
      DESTDIR="$stage" "$BASH" "$copy_root/install.sh" wg0
    ) >/dev/null 2>"$TEST_TMP/missing-managed-source.err"
    rc=$?
    [[ $rc -ne 0 ]] || { fail "install accepted missing managed source: $target"; return 1; }
    [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] || {
      fail "missing managed source mutated staging tree: $target"
      return 1
    }
    cp -- "$ROOT/$target" "$copy_root/$target"
  done

  outside="$TEST_TMP/preflight-outside"
  printf 'outside sentinel\n' >"$outside"
  for target in \
    'usr/local/libexec/wg-healthcheck/wg-healthcheck-managed' \
    'usr/local/sbin/wg-healthcheck-setup' \
    'usr/local/libexec/wg-healthcheck/wg_healthcheck_setup' \
    'var/lib/wg-healthcheck'; do
    stage="$(new_stage)" || return 1
    target="$stage/$target"
    mkdir -p -- "${target%/*}"
    if ! ln -s -- "$outside" "$target" 2>/dev/null || [[ ! -L "$target" ]]; then
      skip 'new managed-target symlink preflight (symlinks unavailable)'
      return 77
    fi
    before="$(find "$stage" -mindepth 1 -printf '%P\n' | sort)"
    run_staged "$stage" wg0 >/dev/null 2>"$TEST_TMP/managed-target-preflight.err"
    rc=$?
    after="$(find "$stage" -mindepth 1 -printf '%P\n' | sort)"
    [[ $rc -ne 0 ]] || { fail "managed target symlink was accepted: $target"; return 1; }
    [[ "$after" == "$before" ]] || {
      fail "new target preflight partially mutated staging tree: $target"
      return 1
    }
    [[ "$(cat "$outside")" == 'outside sentinel' ]] || {
      fail "new target preflight modified symlink destination: $target"
      return 1
    }
  done
}

test_installer_preserves_api_credential_pre_managed_snapshot_and_state() {
  local stage key snapshot state key_copy snapshot_copy state_copy
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1
  key="$stage/etc/wireguard/healthcheck.d/wg0.api-key"
  snapshot="$stage/etc/wireguard/wg0.conf.pre-managed"
  state="$stage/var/lib/wg-healthcheck/wg0.api-state"
  mkdir -p -- "${key%/*}" "${state%/*}"
  printf 'operator-credential-placeholder\n' >"$key"
  printf 'operator-pre-managed-profile\n' >"$snapshot"
  printf 'operator-api-state\n' >"$state"
  chmod 0600 -- "$key" "$snapshot" "$state"
  key_copy="$TEST_TMP/preserved-key"
  snapshot_copy="$TEST_TMP/preserved-snapshot"
  state_copy="$TEST_TMP/preserved-state"
  cp -- "$key" "$key_copy"
  cp -- "$snapshot" "$snapshot_copy"
  cp -- "$state" "$state_copy"

  run_staged "$stage" wg0 >/dev/null 2>&1 || { fail 'staged reinstall with operator state failed'; return 1; }
  assert_same_bytes "$key_copy" "$key" || return 1
  assert_same_bytes "$snapshot_copy" "$snapshot" || return 1
  assert_same_bytes "$state_copy" "$state" || return 1
  assert_mode 600 "$key" || return 1
  assert_mode 600 "$snapshot" || return 1
  assert_mode 600 "$state" || return 1
  assert_dir "$stage/var/lib/wg-healthcheck"
}

test_zero_args_and_explicit_wg0_are_compatible() {
  local default_stage explicit_stage
  require_posix_modes || return $?
  default_stage="$(new_stage)" || return 1
  explicit_stage="$(new_stage)" || return 1

  run_staged "$default_stage" >/dev/null 2>&1 || { fail "zero-argument install failed"; return 1; }
  run_staged "$explicit_stage" wg0 >/dev/null 2>&1 || { fail "explicit wg0 install failed"; return 1; }

  assert_same_bytes \
    "$default_stage/etc/wireguard/healthcheck.d/wg0.conf" \
    "$explicit_stage/etc/wireguard/healthcheck.d/wg0.conf"
}

test_custom_interface_uses_an_exact_filename() {
  local stage
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1
  run_staged "$stage" wg-test.1 >/dev/null 2>&1 || { fail "custom interface install failed"; return 1; }
  assert_file "$stage/etc/wireguard/healthcheck.d/wg-test.1.conf" || return 1
  assert_absent "$stage/etc/wireguard/healthcheck.d/wg0.conf"
}

test_invalid_cli_is_rejected_before_writes() {
  local stage rc arg
  # These are literal hostile inputs; expansion would invalidate the test.
  # shellcheck disable=SC2016
  local -a invalid=(
    --help -wg0 ../wg0 wg/0 'wg 0' 'wg0;touch' 'wg0$(id)' abcdefghijklmnop
  )

  for arg in "${invalid[@]}"; do
    stage="$(new_stage)" || return 1
    run_staged "$stage" "$arg" >"$TEST_TMP/invalid.out" 2>"$TEST_TMP/invalid.err"
    rc=$?
    [[ $rc -ne 0 ]] || { fail "accepted invalid interface: $arg"; return 1; }
    [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] ||
      { fail "invalid interface wrote into staging root: $arg"; return 1; }
  done

  stage="$(new_stage)" || return 1
  run_staged "$stage" --bogus wg0 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'accepted unknown option'; return 1; }
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] || { fail 'unknown option wrote files'; return 1; }

  stage="$(new_stage)" || return 1
  run_staged "$stage" --enable --enable >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'accepted duplicate --enable'; return 1; }
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] || { fail 'duplicate option wrote files'; return 1; }

  stage="$(new_stage)" || return 1
  run_staged "$stage" wg0 extra >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'accepted extra positional argument'; return 1; }
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] || { fail 'extra argument wrote files'; return 1; }
}

test_live_install_requires_root() {
  local rc
  if (( EUID == 0 )); then
    skip 'root-requirement execution check (runner is root)'
    return 77
  fi
  installer_has_staging_guard || { fail 'installer does not have the safe preflight needed for this test'; return 1; }

  (
    cd -- "$UNRELATED_CWD" || exit 1
    "$BASH" "$INSTALLER" wg0
  ) >"$TEST_TMP/nonroot.out" 2>"$TEST_TMP/nonroot.err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'non-root live install succeeded'; return 1; }
  assert_contains 'must run as root' "$TEST_TMP/nonroot.err"
}

test_unsafe_destdir_values_are_rejected() {
  local rc real link unsafe
  installer_has_staging_guard || { fail 'installer does not validate DESTDIR'; return 1; }

  DESTDIR=relative "$BASH" "$INSTALLER" wg0 >/dev/null 2>"$TEST_TMP/relative.err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'relative DESTDIR was accepted'; return 1; }

  DESTDIR=/ "$BASH" "$INSTALLER" wg0 >/dev/null 2>"$TEST_TMP/root-destdir.err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'DESTDIR=/ was accepted'; return 1; }

  if (( MODE_TESTS_SUPPORTED )); then
    unsafe="$(new_stage)" || return 1
    chmod 0777 "$unsafe"
    DESTDIR="$unsafe" "$BASH" "$INSTALLER" wg0 >/dev/null 2>"$TEST_TMP/unsafe-mode.err"
    rc=$?
    [[ $rc -ne 0 ]] || { fail 'group/world-writable staging root was accepted'; return 1; }
  fi

  real="$(new_stage)" || return 1
  link="$TEST_TMP/stage-link"
  if ! ln -s -- "$real" "$link" 2>/dev/null || [[ ! -L "$link" ]]; then
    printf 'NOTE: staging-root symlink assertion unavailable on this host\n'
    return 0
  fi
  DESTDIR="$link" "$BASH" "$INSTALLER" wg0 >/dev/null 2>"$TEST_TMP/symlink-root.err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'symlinked staging root was accepted'; return 1; }
}

test_missing_sources_fail_before_staging_mutation() {
  local copy_dir stage rc
  copy_dir="$TEST_TMP/installer-only"
  mkdir -p -- "$copy_dir"
  cp -- "$INSTALLER" "$copy_dir/install.sh"
  stage="$(new_stage)" || return 1

  (
    cd -- "$UNRELATED_CWD" || exit 1
    DESTDIR="$stage" "$BASH" "$copy_dir/install.sh" wg0
  ) >/dev/null 2>"$TEST_TMP/missing-source.err"
  rc=$?

  [[ $rc -ne 0 ]] || { fail 'install succeeded without source artifacts'; return 1; }
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] ||
    fail 'missing-source preflight mutated the staging tree'
}

test_existing_healthcheck_config_is_preserved_and_tightened() {
  local stage config snapshot
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1
  run_staged "$stage" wg0 >/dev/null 2>&1 || { fail 'initial install failed'; return 1; }
  config="$stage/etc/wireguard/healthcheck.d/wg0.conf"
  snapshot="$TEST_TMP/existing-config.snapshot"
  printf 'SPEED_CHECK_ENABLED=0\nLOCAL_NOTE=preserve-these-bytes\n' >"$config"
  cp -- "$config" "$snapshot"
  chmod 0644 "$config"

  run_staged "$stage" wg0 >/dev/null 2>&1 || { fail 'reinstall with existing config failed'; return 1; }
  assert_same_bytes "$snapshot" "$config" || return 1
  assert_mode 600 "$config"
}

test_existing_wireguard_config_is_never_overwritten() {
  local stage wireguard snapshot
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1
  mkdir -p -- "$stage/etc/wireguard"
  wireguard="$stage/etc/wireguard/wg0.conf"
  snapshot="$TEST_TMP/wireguard.snapshot"
  printf '[Interface]\nPrivateKey = never-touch-this\n' >"$wireguard"
  cp -- "$wireguard" "$snapshot"

  run_staged "$stage" wg0 >/dev/null 2>&1 || { fail 'staged install failed'; return 1; }
  assert_same_bytes "$snapshot" "$wireguard"
}

test_writable_existing_config_is_rejected_without_changes() {
  local stage config snapshot rc
  if (( ! MODE_TESTS_SUPPORTED )); then
    skip 'writable-config mode check (filesystem has no POSIX mode fidelity)'
    return 77
  fi
  stage="$(new_stage)" || return 1
  run_staged "$stage" wg0 >/dev/null 2>&1 || { fail 'initial install failed'; return 1; }
  config="$stage/etc/wireguard/healthcheck.d/wg0.conf"
  snapshot="$TEST_TMP/writable-config.snapshot"
  printf 'LOCAL_NOTE=unsafe-but-preserve\n' >"$config"
  cp -- "$config" "$snapshot"
  chmod 0666 "$config"

  run_staged "$stage" wg0 >/dev/null 2>"$TEST_TMP/writable-config.err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'group/world-writable config was accepted'; return 1; }
  assert_same_bytes "$snapshot" "$config" || return 1
  assert_mode 666 "$config"
}

test_managed_symlink_target_is_rejected_and_untouched() {
  local stage outside target rc
  stage="$(new_stage)" || return 1
  outside="$TEST_TMP/outside-managed-file"
  printf 'outside-sentinel\n' >"$outside"
  mkdir -p -- "$stage/usr/local/sbin"
  target="$stage/usr/local/sbin/wg-healthcheck"
  if ! ln -s -- "$outside" "$target" 2>/dev/null || [[ ! -L "$target" ]]; then
    skip 'managed-target symlink check (symlinks unavailable)'
    return 77
  fi

  run_staged "$stage" wg0 >/dev/null 2>"$TEST_TMP/managed-symlink.err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'managed symlink target was accepted'; return 1; }
  [[ "$(cat "$outside")" == outside-sentinel ]] || { fail 'symlink target was modified'; return 1; }
}

test_nonregular_managed_target_is_rejected_before_mutation() {
  local stage target before after rc
  stage="$(new_stage)" || return 1
  target="$stage/usr/local/sbin/wg-healthcheck"
  mkdir -p -- "$target"
  before="$(find "$stage" -mindepth 1 -printf '%P\n' | sort)"

  run_staged "$stage" wg0 >/dev/null 2>"$TEST_TMP/nonregular-target.err"
  rc=$?
  after="$(find "$stage" -mindepth 1 -printf '%P\n' | sort)"
  [[ $rc -ne 0 ]] || { fail 'directory at managed-file target was accepted'; return 1; }
  [[ "$after" == "$before" ]] || { fail 'preflight failure partially mutated staging tree'; return 1; }
}

test_atomic_replacement_failure_preserves_old_file() {
  local dir source target rc residue
  grep -F 'atomic_install_file' "$INSTALLER" >/dev/null || { fail 'atomic install helper is missing'; return 1; }

  # shellcheck source=install.sh
  source "$INSTALLER"
  dir="$TEST_TMP/atomic"
  mkdir -p -- "$dir"
  source="$dir/source"
  target="$dir/target"
  printf 'new-content\n' >"$source"
  printf 'old-content\n' >"$target"
  LIVE_INSTALL=0
  # Called indirectly by atomic_install_file from the sourced installer.
  # shellcheck disable=SC2329
  move_into_place() { return 1; }

  atomic_install_file "$source" "$target" 0755 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'injected atomic rename failure succeeded'; return 1; }
  [[ "$(cat "$target")" == old-content ]] || { fail 'old managed file was replaced'; return 1; }
  residue="$(find "$dir" -maxdepth 1 -name '.target.tmp.*' -print -quit)"
  [[ -z "$residue" ]] || fail "atomic temp residue remains: $residue"
}

test_atomic_interruption_cleans_temp_without_leaking_traps() {
  local dir source target rc residue before_trap after_trap

  # shellcheck source=install.sh
  source "$INSTALLER"
  dir="$TEST_TMP/atomic-interrupt"
  mkdir -p -- "$dir"
  source="$dir/source"
  target="$dir/target"
  printf 'new-content\n' >"$source"
  printf 'old-content\n' >"$target"
  LIVE_INSTALL=0
  INSTALL_OWNER_ARGS=()
  before_trap="$(trap -p EXIT)"

  # Called inside atomic_install_file after its temporary file is populated.
  # shellcheck disable=SC2329
  move_into_place() { kill -TERM "$BASHPID"; }

  ( atomic_install_file "$source" "$target" 0644 >/dev/null 2>&1 )
  rc=$?
  after_trap="$(trap -p EXIT)"
  [[ $rc -ne 0 ]] || { fail 'interrupted atomic replacement succeeded'; return 1; }
  [[ "$(cat "$target")" == old-content ]] || { fail 'interruption replaced the old target'; return 1; }
  residue="$(find "$dir" -maxdepth 1 -name '.target.tmp.*' -print -quit)"
  [[ -z "$residue" ]] || { fail "interruption left temporary residue: $residue"; return 1; }
  [[ "$after_trap" == "$before_trap" ]] || fail 'atomic helper leaked a trap into its caller'
}

test_artifact_failure_is_ordered_and_safely_retryable() (
  local rc actual expected log="$TEST_TMP/artifact-order"

  # shellcheck source=install.sh
  source "$INSTALLER"
  local SOURCE_MAIN='source-main' SOURCE_HELPER='source-helper'
  local SOURCE_MANAGED_MODULE='source-managed-module' SOURCE_SETUP='source-setup'
  local SOURCE_SERVICE='source-service' SOURCE_TIMER='source-timer'
  local SOURCE_CONFIG='source-config' TARGET_MAIN='target-main'
  local TARGET_HELPER='target-helper' TARGET_MANAGED_MODULE='target-managed-module'
  local TARGET_SETUP='target-setup' TARGET_SERVICE='target-service'
  local TARGET_TIMER='target-timer' TARGET_CONFIG='target-config'
  local LIVE_INSTALL=0
  : >"$log"

  # Called indirectly by install_guarded_artifacts from the sourced installer.
  # shellcheck disable=SC2329
  atomic_install_file() {
    printf '%s\n' "$2" >>"$log"
    [[ "$2" != "$TARGET_SERVICE" ]]
  }
  # Called indirectly by install_artifacts from the sourced installer.
  # shellcheck disable=SC2329
  install_setup_package() {
    printf '%s\n' target-setup-package >>"$log"
  }
  # Called indirectly by install_artifacts from the sourced installer.
  # shellcheck disable=SC2317,SC2329
  publish_setup_upgrade_guard() {
    printf '%s\n' target-setup-guard >>"$log"
  }
  create_layout() { return 0; }

  install_guarded_artifacts
  rc=$?
  actual="$(cat "$log")"
  expected=$'target-helper\ntarget-managed-module\ntarget-setup-package\ntarget-service'
  [[ $rc -ne 0 ]] || { fail 'later artifact failure was ignored'; return 1; }
  [[ "$actual" == "$expected" ]] ||
    fail "unsafe artifact order or work continued after failure: $actual"
)

test_managed_artifact_install_order_is_dependency_safe() (
  local rc actual expected log="$TEST_TMP/managed-artifact-order"

  # shellcheck source=install.sh
  source "$INSTALLER"
  local SOURCE_MAIN='source-main' SOURCE_HELPER='source-helper'
  local SOURCE_MANAGED_MODULE='source-managed-module' SOURCE_SETUP='source-setup'
  local SOURCE_SERVICE='source-service' SOURCE_TIMER='source-timer'
  local SOURCE_CONFIG='source-config' TARGET_MAIN='target-main'
  local TARGET_HELPER='target-helper' TARGET_MANAGED_MODULE='target-managed-module'
  local TARGET_SETUP='target-setup' TARGET_SERVICE='target-service'
  local TARGET_TIMER='target-timer' TARGET_CONFIG='target-config'
  local LIVE_INSTALL=0
  : >"$log"

  # Called indirectly by install_guarded_artifacts from the sourced installer.
  # shellcheck disable=SC2329
  atomic_install_file() {
    printf '%s\n' "$2" >>"$log"
  }
  # Setup code must be in place before the launcher's atomic publication.
  # shellcheck disable=SC2329
  install_setup_package() {
    printf '%s\n' target-setup-package >>"$log"
  }
  # Called indirectly by install_artifacts from the sourced installer.
  # shellcheck disable=SC2317,SC2329
  publish_setup_upgrade_guard() {
    printf '%s\n' target-setup-guard >>"$log"
  }
  create_layout() { return 0; }

  install_guarded_artifacts
  rc=$?
  actual="$(cat "$log")"
  expected=$'target-helper\ntarget-managed-module\ntarget-setup-package\ntarget-service\ntarget-timer\ntarget-config'
  [[ $rc -eq 0 ]] || { fail 'managed artifact install did not complete'; return 1; }
  [[ "$actual" == "$expected" ]] ||
    fail "managed artifacts were not atomically published in dependency-safe order: $actual"
)

test_existing_managed_file_owner_is_not_blessed() {
  local file="$TEST_TMP/untrusted-owner" fake_owner rc
  grep -F 'validate_managed_file_target' "$INSTALLER" >/dev/null || {
    fail 'managed-file validation helper is missing'
    return 1
  }
  printf 'existing-content\n' >"$file"
  fake_owner=$((EUID + 1))

  (
    # shellcheck source=install.sh
    source "$INSTALLER"
    # Read indirectly by validate_managed_file_target from the sourced installer.
    # shellcheck disable=SC2034
    LIVE_INSTALL=0
    # Called indirectly by validate_managed_file_target from the sourced installer.
    # shellcheck disable=SC2329
    stat() {
      if [[ "${1:-}" == -c && "${2:-}" == %u ]]; then
        printf '%s\n' "$fake_owner"
      else
        command stat "$@"
      fi
    }
    validate_managed_file_target "$file"
  ) >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'unexpectedly owned managed file was accepted'; return 1; }
}

test_systemctl_behavior_is_explicit_and_exact() {
  local log="$TEST_TMP/systemctl.log"
  grep -F 'run_live_systemctl' "$INSTALLER" >/dev/null || { fail 'sourceable systemctl seam is missing'; return 1; }

  # shellcheck source=install.sh
  source "$INSTALLER"
  # Called indirectly by run_live_systemctl from the sourced installer.
  # shellcheck disable=SC2329
  systemctl_exec() { printf '%s\n' "$*" >>"$log"; }

  : >"$log"
  run_live_systemctl reload wg0 || return 1
  [[ "$(cat "$log")" == daemon-reload ]] ||
    { fail "default action was not exactly daemon-reload: $(cat "$log")"; return 1; }

  : >"$log"
  run_live_systemctl enable wg0 || return 1
  [[ "$(cat "$log")" == 'enable --now wg-healthcheck@wg0.timer' ]] ||
    fail "--enable actions were not exact: $(cat "$log")"

  if run_live_systemctl invalid wg0 >/dev/null 2>&1; then
    fail 'invalid live-systemctl action was accepted'
  fi
}

test_quiesce_argument_matrix_is_explicit_and_staging_is_rejected() (
  local stage rc

  # shellcheck source=install.sh
  source "$INSTALLER"
  declare -F prepare_live_upgrade >/dev/null || {
    fail 'installer does not expose the live-upgrade preflight seam'
    return 1
  }

  parse_arguments --quiesce wg0 || { fail '--quiesce wg0 was rejected'; return 1; }
  parse_arguments --quiesce >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail '--quiesce accepted a missing interface'; return 1; }
  parse_arguments --quiesce --enable wg0 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail '--quiesce accepted --enable'; return 1; }
  parse_arguments --enable --quiesce wg0 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail '--enable accepted --quiesce'; return 1; }

  stage="$(new_stage)" || return 1
  DESTDIR="$stage" "$BASH" "$INSTALLER" --quiesce wg0 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail '--quiesce was accepted with DESTDIR staging'; return 1; }
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] ||
    fail '--quiesce with DESTDIR mutated the staging tree'
)

test_ordinary_live_upgrade_refuses_an_active_worker_before_mutation() (
  local stage log="$TEST_TMP/ordinary-active-worker.log" rc actual
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  declare -F prepare_live_upgrade >/dev/null || {
    fail 'installer does not expose the live-upgrade preflight seam'
    return 1
  }
  : >"$log"
  systemctl_exec() {
    printf 'systemctl %s\n' "$*" >>"$log"
    case "$*" in
      'is-active --quiet wg-healthcheck@wg0.timer') return 3 ;;
      'is-active --quiet wg-healthcheck@wg0.service') return 0 ;;
    esac
    return 0
  }
  flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }
  sleep_exec() { printf 'sleep %s\n' "$*" >>"$log"; return 0; }

  prepare_live_upgrade 0 wg0 2>"$TEST_TMP/ordinary-active-worker.err"
  rc=$?
  actual="$(cat "$log")"
  [[ $rc -ne 0 ]] || { fail 'ordinary install accepted an active worker'; return 1; }
  [[ "$actual" == $'systemctl is-active --quiet wg-healthcheck@wg0.timer\nsystemctl is-active --quiet wg-healthcheck@wg0.service' ]] ||
    fail "ordinary active-worker refusal did not stop at the worker probe: $actual"
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] ||
    fail 'ordinary active-worker refusal mutated the live-layout fixture'
)

test_ordinary_live_upgrade_refuses_an_active_timer_before_mutation() (
  local stage log="$TEST_TMP/ordinary-active-timer.log" rc actual
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  declare -F prepare_live_upgrade >/dev/null || {
    fail 'installer does not expose the live-upgrade preflight seam'
    return 1
  }
  : >"$log"
  systemctl_exec() {
    printf 'systemctl %s\n' "$*" >>"$log"
    [[ "$*" == 'is-active --quiet wg-healthcheck@wg0.timer' ]] && return 0
    return 3
  }
  flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }
  sleep_exec() { printf 'sleep %s\n' "$*" >>"$log"; return 0; }

  prepare_live_upgrade 0 wg0 2>"$TEST_TMP/ordinary-active-timer.err"
  rc=$?
  actual="$(cat "$log")"
  [[ $rc -ne 0 ]] || { fail 'ordinary install accepted an active timer'; return 1; }
  [[ "$actual" == 'systemctl is-active --quiet wg-healthcheck@wg0.timer' ]] ||
    fail "ordinary active-timer refusal continued past the timer probe: $actual"
  [[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]] ||
    fail 'ordinary active-timer refusal mutated the live-layout fixture'
)

test_ordinary_live_upgrade_refuses_a_held_interface_lock() (
  local stage log="$TEST_TMP/ordinary-held-lock.log" rc actual
  stage="$(new_stage)" || return 1
  mkdir -p -- "$stage/run/wg-healthcheck"
  chmod 0700 -- "$stage/run/wg-healthcheck"
  : >"$stage/run/wg-healthcheck/wg0.lock"
  chmod 0600 -- "$stage/run/wg-healthcheck/wg0.lock"

  # shellcheck source=install.sh
  source "$INSTALLER"
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  declare -F prepare_live_upgrade >/dev/null || {
    fail 'installer does not expose the live-upgrade preflight seam'
    return 1
  }
  : >"$log"
  systemctl_exec() {
    printf 'systemctl %s\n' "$*" >>"$log"
    [[ "$1" == is-active ]] && return 3
    return 0
  }
  flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 1; }
  sleep_exec() { printf 'sleep %s\n' "$*" >>"$log"; return 0; }

  prepare_live_upgrade 0 wg0 2>"$TEST_TMP/ordinary-held-lock.err"
  rc=$?
  actual="$(cat "$log")"
  [[ $rc -ne 0 ]] || { fail 'ordinary install accepted a held interface lock'; return 1; }
  assert_ordered_text "$actual" \
    'systemctl is-active --quiet wg-healthcheck@wg0.timer' \
    'systemctl is-active --quiet wg-healthcheck@wg0.service' \
    'flock ' || return 1
  [[ "$actual" != *'disable --now'* && "$actual" != *'stop '* ]] ||
    fail 'ordinary held-lock refusal changed unit state'
)

test_live_upgrade_refuses_pending_journal_or_safety_record() (
  local stage log="$TEST_TMP/live-recovery-artifacts.log" artifact artifact_path rc actual
  local -a artifacts=(
    'wg0.conf.pending-healthcheck'
    'wg0.conf.safety-healthcheck'
    'healthcheck.d/wg0.setup-transaction'
  )

  for artifact in "${artifacts[@]}"; do
    stage="$(new_stage)" || return 1
    artifact_path="$stage/etc/wireguard/$artifact"
    mkdir -p -- "${artifact_path%/*}" "$stage/run/wg-healthcheck"
    chmod 0700 -- "$stage/run/wg-healthcheck"
    : >"$stage/run/wg-healthcheck/wg0.lock"
    chmod 0600 -- "$stage/run/wg-healthcheck/wg0.lock"
    printf 'incomplete recovery evidence\n' >"$artifact_path"
    : >"$log"

    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    declare -F prepare_live_upgrade >/dev/null || {
      fail 'installer does not expose the live-upgrade preflight seam'
      return 1
    }
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      [[ "$1" == is-active ]] && return 3
      return 0
    }
    flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }
    sleep_exec() { printf 'sleep %s\n' "$*" >>"$log"; return 0; }

    prepare_live_upgrade 0 wg0 2>"$TEST_TMP/recovery-artifact.err"
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "ordinary install accepted recovery artifact: $artifact"; return 1; }
    assert_ordered_text "$actual" \
      'systemctl is-active --quiet wg-healthcheck@wg0.timer' \
      'systemctl is-active --quiet wg-healthcheck@wg0.service' \
      'flock ' || return 1
  done
)

test_quiesce_stops_waits_checks_and_leaves_timer_disabled() (
  local stage log="$TEST_TMP/quiesce.log" rc actual
  stage="$(new_stage)" || return 1
  mkdir -p -- "$stage/run/wg-healthcheck"
  chmod 0700 -- "$stage/run/wg-healthcheck"
  : >"$stage/run/wg-healthcheck/wg0.lock"
  chmod 0600 -- "$stage/run/wg-healthcheck/wg0.lock"

  # shellcheck source=install.sh
  source "$INSTALLER"
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  declare -F prepare_live_upgrade >/dev/null || {
    fail 'installer does not expose the live-upgrade preflight seam'
    return 1
  }
  : >"$log"
  systemctl_exec() {
    printf 'systemctl %s\n' "$*" >>"$log"
    if [[ "$1" == is-enabled ]]; then
      printf 'enabled\n'
      return 0
    fi
    [[ "$1" == is-active ]] && return 3
    [[ "$1" == enable ]] && return 99
    return 0
  }
  wait_for_instance_inactive() { printf 'wait %s\n' "$*" >>"$log"; return 0; }
  flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }

  prepare_live_upgrade 1 wg0
  rc=$?
  actual="$(cat "$log")"
  [[ $rc -eq 0 ]] || { fail 'quiesced live upgrade did not complete its safety preflight'; return 1; }
  assert_ordered_text "$actual" \
    'systemctl is-enabled wg-healthcheck@wg0.timer' \
    'systemctl disable --now wg-healthcheck@wg0.timer' \
    'systemctl stop wg-healthcheck@wg0.service' \
    'wait wg0' \
    'flock ' || return 1
  [[ "$actual" != *'systemctl enable '* ]] || fail 'quiesced upgrade re-enabled the timer'
)

test_systemctl_inactive_query_errors_fail_closed() (
  local stage log="$TEST_TMP/systemctl-query-error.log" query_rc rc actual

  for query_rc in 1 2; do
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    : >"$log"
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      [[ "$1" == is-active ]] && return "$query_rc"
      return 0
    }
    flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }
    sleep_exec() { printf 'sleep %s\n' "$*" >>"$log"; return 0; }

    prepare_live_upgrade 0 wg0 >/dev/null 2>&1
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "ordinary install accepted is-active query rc $query_rc"; return 1; }
    [[ "$actual" == 'systemctl is-active --quiet wg-healthcheck@wg0.timer' ]] || {
      fail "ordinary query error continued beyond the first failed query: $actual"
      return 1
    }

    : >"$log"
    wait_for_instance_inactive wg0 >/dev/null 2>&1
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "wait accepted is-active query rc $query_rc"; return 1; }
    [[ "$actual" == 'systemctl is-active --quiet wg-healthcheck@wg0.timer' ]] || {
      fail "wait query error slept or continued after an unknown unit state: $actual"
      return 1
    }
  done
)

test_inactive_status_with_stderr_diagnostic_fails_closed() (
  local stage log="$TEST_TMP/inactive-diagnostic.log" err="$TEST_TMP/inactive-diagnostic.err"
  local inactive_rc rc actual

  for inactive_rc in 3 4; do
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    : >"$log"
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      if [[ "$1" == is-active ]]; then
        printf 'transport diagnostic\n' >&2
        return "$inactive_rc"
      fi
      return 0
    }
    flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }
    sleep_exec() { printf 'sleep %s\n' "$*" >>"$log"; return 0; }

    prepare_live_upgrade 0 wg0 >/dev/null 2>"$err"
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "ordinary install accepted rc $inactive_rc with diagnostics"; return 1; }
    [[ "$actual" == 'systemctl is-active --quiet wg-healthcheck@wg0.timer' ]] || {
      fail "ordinary diagnostic status continued beyond the timer check: $actual"
      return 1
    }

    : >"$log"
    wait_for_instance_inactive wg0 >/dev/null 2>"$err"
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "wait accepted rc $inactive_rc with diagnostics"; return 1; }
    [[ "$actual" == 'systemctl is-active --quiet wg-healthcheck@wg0.timer' ]] || {
      fail "wait diagnostic status slept or continued: $actual"
      return 1
    }
  done
)

test_quiesce_timer_enable_state_is_exact_and_fail_closed() (
  local stage log="$TEST_TMP/quiesce-enable-state.log" out="$TEST_TMP/quiesce-enable-state.out"
  local record rc expected actual response response_rc expected_enabled
  local -a accepted=(
    'enabled:0:1'
    'enabled-runtime:0:1'
    'disabled:1:0'
    'static:0:0'
    'masked:1:0'
    'not-found:1:0'
  )
  local -a rejected=(
    'enabled\ :0'
    'unknown:0'
    ':0'
    'enabled:2'
  )

  for record in "${accepted[@]}"; do
    IFS=: read -r response response_rc expected_enabled <<<"$record"
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    : >"$log"
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      if [[ "$1" == is-enabled ]]; then
        [[ -z "$response" ]] || printf '%s\n' "$response"
        return "$response_rc"
      fi
      [[ "$1" == is-active ]] && return 3
      return 0
    }
    wait_for_instance_inactive() { return 0; }
    probe_existing_interface_lock() { return 0; }
    refuse_recovery_artifacts() { return 0; }

    prepare_live_upgrade 1 wg0 >"$out" 2>&1
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -eq 0 ]] || { fail "quiesce rejected documented timer state: $record"; return 1; }
    [[ "$TIMER_WAS_ENABLED" == "$expected_enabled" ]] || {
      fail "quiesce recorded the wrong enabled state for: $record"
      return 1
    }
    [[ -z "$(cat "$out")" ]] || { fail 'timer-state query leaked stdout or stderr'; return 1; }
    [[ "$actual" == *'systemctl is-enabled wg-healthcheck@wg0.timer'* &&
       "$actual" != *'is-enabled --quiet'* ]] || {
      fail "timer state query was not the required non-quiet command: $actual"
      return 1
    }
  done

  for record in "${rejected[@]}"; do
    IFS=: read -r response response_rc <<<"$record"
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    : >"$log"
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      if [[ "$1" == is-enabled ]]; then
        [[ -z "$response" ]] || printf '%s\n' "$response"
        return "$response_rc"
      fi
      [[ "$1" == is-active ]] && return 3
      return 0
    }
    wait_for_instance_inactive() { return 0; }
    probe_existing_interface_lock() { return 0; }
    refuse_recovery_artifacts() { return 0; }

    prepare_live_upgrade 1 wg0 >"$out" 2>&1
    rc=$?
    [[ $rc -ne 0 ]] || { fail "quiesce accepted ambiguous timer state: $record"; return 1; }
    assert_not_contains 'disable --now' "$log" || return 1
  done
)

test_quiesce_rejects_enabled_state_with_stderr_diagnostic_before_disable() (
  local stage log="$TEST_TMP/enable-diagnostic.log" err="$TEST_TMP/enable-diagnostic.err" rc
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  : >"$log"
  systemctl_exec() {
    printf 'systemctl %s\n' "$*" >>"$log"
    if [[ "$1" == is-enabled ]]; then
      printf 'enabled\n'
      printf 'state-query diagnostic\n' >&2
      return 0
    fi
    return 0
  }

  prepare_live_upgrade 1 wg0 >/dev/null 2>"$err"
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'quiesce accepted enabled state with stderr diagnostics'; return 1; }
  assert_not_contains 'disable --now' "$log" || return 1
)

test_live_upgrade_refuses_active_or_unqueryable_shared_instances() (
  local stage log="$TEST_TMP/shared-unit.log" kind result rc actual
  local -a cases=(
    'timer:wg-healthcheck@wg1.timer active'
    'service:query-error'
  )

  for result in "${cases[@]}"; do
    IFS=: read -r kind result <<<"$result"
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    : >"$log"
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      [[ "$1" == is-active ]] && return 3
      if [[ "$1" == list-units && "$*" == *"--type=$kind"* ]]; then
        [[ "$result" == query-error ]] && return 1
        printf '%s\n' "$result"
        return 0
      fi
      return 0
    }
    flock_exec() { printf 'flock %s\n' "$*" >>"$log"; return 0; }

    prepare_live_upgrade 0 wg0 >/dev/null 2>&1
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "live upgrade accepted shared $kind result: $result"; return 1; }
    assert_contains "list-units --type=$kind --state=active,activating,deactivating,reloading --no-legend --plain --full --no-pager wg-healthcheck@*.$kind" "$log" || return 1
    assert_not_contains 'flock ' "$log" || return 1
  done
)

test_upgrade_locks_are_retained_and_released_for_the_selected_interface() (
  local stage runtime rc
  stage="$(new_stage)" || return 1
  runtime="$stage/run/wg-healthcheck"

  # shellcheck source=install.sh
  source "$INSTALLER"
  IFACE=wg1
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  declare -F acquire_upgrade_locks >/dev/null || {
    fail 'installer does not expose upgrade-lock acquisition'
    return 1
  }
  declare -F release_upgrade_locks >/dev/null || {
    fail 'installer does not expose upgrade-lock release'
    return 1
  }
  [[ -n "${LIVE_SETUP_GUARD:-}" ]] || {
    fail 'installer does not derive the shared setup-guard path'
    return 1
  }
  systemctl_exec() {
    [[ "$1" == is-active ]] && return 3
    [[ "$1" == list-units ]] && return 0
    return 0
  }

  prepare_live_upgrade 0 wg1 || { fail 'safe wg1 upgrade preflight failed'; return 1; }
  assert_dir "$runtime" || return 1
  assert_mode 700 "$runtime" || return 1
  assert_file "$LIVE_SETUP_GUARD" || return 1
  assert_file "$LIVE_INTERFACE_LOCK" || return 1
  assert_mode 600 "$LIVE_SETUP_GUARD" || return 1
  assert_mode 600 "$LIVE_INTERFACE_LOCK" || return 1
  [[ "$(stat -c '%u' -- "$LIVE_SETUP_GUARD")" == "$EUID" ]] ||
    { fail 'setup guard owner is not the invoking root/EUID'; return 1; }
  [[ "$(stat -c '%u' -- "$LIVE_INTERFACE_LOCK")" == "$EUID" ]] ||
    { fail 'interface lock owner is not the invoking root/EUID'; return 1; }

  command flock -n "$LIVE_SETUP_GUARD" -c true >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'competing installer acquired the retained setup guard'; return 1; }
  command flock -n "$LIVE_INTERFACE_LOCK" -c true >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'competing installer acquired the retained wg1 lock'; return 1; }

  release_upgrade_locks || { fail 'upgrade-lock release failed'; return 1; }
  command flock -n "$LIVE_SETUP_GUARD" -c true >/dev/null 2>&1 ||
    { fail 'setup guard remained held after release'; return 1; }
  command flock -n "$LIVE_INTERFACE_LOCK" -c true >/dev/null 2>&1 ||
    fail 'wg1 lock remained held after release'
)

test_upgrade_locks_refuse_held_wg1_lock_or_unsafe_setup_guard() (
  local stage runtime outside rc

  stage="$(new_stage)" || return 1
  runtime="$stage/run/wg-healthcheck"
  mkdir -p -- "$runtime"
  chmod 0700 -- "$runtime"
  : >"$runtime/wg1.lock"
  chmod 0600 -- "$runtime/wg1.lock"
  command flock -x "$runtime/wg1.lock" -c 'sleep 1' &
  local holder=$!

  # shellcheck source=install.sh
  source "$INSTALLER"
  IFACE=wg1
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  declare -F acquire_upgrade_locks >/dev/null || {
    wait "$holder" || true
    fail 'installer does not expose upgrade-lock acquisition'
    return 1
  }
  acquire_upgrade_locks >/dev/null 2>&1
  rc=$?
  wait "$holder" || true
  [[ $rc -ne 0 ]] || { fail 'acquired a wg1 lock already held by another process'; return 1; }

  outside="$TEST_TMP/setup-guard-outside"
  printf 'outside sentinel\n' >"$outside"
  rm -f -- "$LIVE_SETUP_GUARD"
  ln -s -- "$outside" "$LIVE_SETUP_GUARD" || { skip 'setup-guard symlink test (symlinks unavailable)'; return 77; }
  acquire_upgrade_locks >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'unsafe setup-guard symlink was accepted'; return 1; }
  [[ "$(cat "$outside")" == 'outside sentinel' ]] || fail 'unsafe setup-guard target was overwritten'
)

test_quiesce_partial_failure_keeps_timer_disabled_and_reports_it() (
  local stage log="$TEST_TMP/quiesce-partial.log" err="$TEST_TMP/quiesce-partial.err"
  local phase rc actual
  local -a phases=(stop wait shared lock artifacts)

  for phase in "${phases[@]}"; do
    stage="$(new_stage)" || return 1
    rc=0
    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    : >"$log"
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      case "$1" in
        is-enabled) printf 'enabled\n'; return 0 ;;
        disable) return 0 ;;
        stop) [[ "$phase" == stop ]] && return 1; return 0 ;;
        is-active) return 3 ;;
        list-units) [[ "$phase" == shared ]] && return 1; return 0 ;;
        enable) return 99 ;;
      esac
      return 0
    }
    wait_for_instance_inactive() { [[ "$phase" == wait ]] && return 1; return 0; }
    probe_existing_interface_lock() { [[ "$phase" == lock ]] && return 1; return 0; }
    refuse_recovery_artifacts() { [[ "$phase" == artifacts ]] && return 1; return 0; }

    prepare_live_upgrade 1 wg0 >/dev/null 2>"$err"
    rc=$?
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "quiesce accepted a $phase failure after disable"; return 1; }
    assert_contains 'disable --now wg-healthcheck@wg0.timer' "$log" || return 1
    assert_contains 'timer remains disabled' "$err" || return 1
    assert_not_contains 'enable ' "$log" || return 1
  done
)

test_state_directory_creation_failure_aborts_layout() (
  local stage log="$TEST_TMP/state-layout.log" rc
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  DESTDIR="$stage"
  LIVE_INSTALL=0
  INSTALL_OWNER_ARGS=()
  initialize_paths
  : >"$log"
  ensure_directory() {
    printf '%s\n' "$1" >>"$log"
    [[ "$1" != "$TARGET_STATE_DIR" ]]
  }

  create_layout
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'layout continued after persistent-state directory creation failed'; return 1; }
  [[ "$(tail -n 1 -- "$log")" == "$TARGET_STATE_DIR" ]] ||
    fail 'state directory was not a required layout owner'
)

test_setup_package_manifest_rejects_unexpected_entries_and_links() (
  local stage source_package target_package source_file target_file rc case_name
  local -a cases=(
    missing-source-py unexpected-source-py unexpected-source-dir source-symlink
    target-py target-dir target-symlink target-pycache
  )

  for case_name in "${cases[@]}"; do
    stage="$(new_stage)" || return 1
    source_package="$stage/source-package"
    target_package="$stage/target-package"
    mkdir -p -- "$source_package" "$target_package"

    # shellcheck source=install.sh
    source "$INSTALLER"
    DESTDIR="$stage"
    LIVE_INSTALL=0
    INSTALL_OWNER_ARGS=()
    initialize_paths
    declare -F validate_setup_package_manifest >/dev/null || {
      fail 'installer does not expose setup-package manifest validation'
      return 1
    }
    SOURCE_SETUP_PACKAGE="$source_package"
    TARGET_SETUP_PACKAGE="$target_package"
    SOURCE_SETUP_PACKAGE_FILES=()
    TARGET_SETUP_PACKAGE_FILES=()
    for source_file in "$ROOT/libexec/wg_healthcheck_setup"/*.py; do
      target_file="${source_file##*/}"
      cp -- "$source_file" "$source_package/$target_file"
      SOURCE_SETUP_PACKAGE_FILES+=("$source_package/$target_file")
      TARGET_SETUP_PACKAGE_FILES+=("$target_package/$target_file")
    done

    validate_setup_package_manifest || { fail 'exact setup-package source manifest was rejected'; return 1; }
    case "$case_name" in
      missing-source-py)
        rm -f -- "$source_package/application.py"
        ;;
      unexpected-source-py)
        printf 'unexpected\n' >"$source_package/unexpected.py"
        ;;
      unexpected-source-dir)
        mkdir -- "$source_package/unexpected-dir"
        ;;
      source-symlink)
        if ! ln -s -- "$source_package/__init__.py" "$source_package/link.py"; then
          skip 'setup-package source symlink test (symlinks unavailable)'
          return 77
        fi
        ;;
      target-py)
        printf 'unexpected\n' >"$target_package/unexpected.py"
        ;;
      target-dir)
        mkdir -- "$target_package/unexpected-dir"
        ;;
      target-symlink)
        if ! ln -s -- "$source_package/__init__.py" "$target_package/link.py"; then
          skip 'setup-package target symlink test (symlinks unavailable)'
          return 77
        fi
        ;;
      target-pycache)
        mkdir -- "$target_package/__pycache__"
        ;;
    esac
    validate_setup_package_manifest >/dev/null 2>&1
    rc=$?
    [[ $rc -ne 0 ]] || { fail "setup-package manifest accepted $case_name"; return 1; }
  done
)

test_setup_upgrade_guard_is_published_before_package_and_retained_on_failure() (
  local stage log="$TEST_TMP/setup-guard.log" rc
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  SOURCE_MAIN='source-main'
  SOURCE_HELPER='source-helper'
  SOURCE_MANAGED_MODULE='source-managed-module'
  SOURCE_SETUP='source-setup'
  SOURCE_SERVICE='source-service'
  SOURCE_TIMER='source-timer'
  SOURCE_CONFIG='source-config'
  TARGET_MAIN='target-main'
  TARGET_HELPER='target-helper'
  TARGET_MANAGED_MODULE='target-managed-module'
  TARGET_MAIN="$stage/wg-healthcheck"
  TARGET_SETUP="$stage/wg-healthcheck-setup"
  TARGET_SERVICE='target-service'
  TARGET_TIMER='target-timer'
  TARGET_CONFIG='target-config'
  LIVE_INSTALL=0
  : >"$log"
  printf '#!/bin/sh\nexit 0\n' >"$TARGET_MAIN"
  printf '#!/bin/sh\nexit 0\n' >"$TARGET_SETUP"
  chmod 0755 -- "$TARGET_MAIN" "$TARGET_SETUP"
  declare -F publish_runtime_upgrade_guard >/dev/null || {
    fail 'installer does not expose runtime-upgrade guard publication'
    return 1
  }
  declare -F publish_setup_upgrade_guard >/dev/null || {
    fail 'installer does not expose setup-upgrade guard publication'
    return 1
  }
  publish_runtime_upgrade_guard || { fail 'runtime-upgrade guard publication failed'; return 1; }
  "$TARGET_MAIN" >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 75 ]] || { fail "runtime guard did not exit inertly with 75: $rc"; return 1; }
  publish_setup_upgrade_guard || { fail 'setup-upgrade guard publication failed'; return 1; }
  "$TARGET_SETUP" >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 75 ]] || { fail "setup guard did not exit inertly with 75: $rc"; return 1; }

  : >"$log"
  atomic_install_file() { printf '%s\n' "$2" >>"$log"; }
  install_setup_package() { printf '%s\n' target-setup-package >>"$log"; return 1; }
  create_layout() { return 0; }
  install_guarded_artifacts
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'install continued after setup-package publication failed'; return 1; }
  [[ "$(cat "$log")" == $'target-helper\ntarget-managed-module\ntarget-setup-package' ]] ||
    fail "setup package failure published a launcher or later artifacts: $(cat "$log")"
  "$TARGET_SETUP" >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 75 ]] || { fail "real setup launcher replaced the guard after package failure: $rc"; return 1; }
  "$TARGET_MAIN" >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 75 ]] || fail "real runtime launcher replaced the guard after package failure: $rc"
)

test_staged_enable_never_calls_host_systemctl() {
  local stage
  require_posix_modes || return $?
  stage="$(new_stage)" || return 1
  run_staged "$stage" --enable wg0 >"$TEST_TMP/staged-enable.out" 2>"$TEST_TMP/staged-enable.err" ||
    fail 'staged --enable install failed'
  assert_file "$stage/etc/systemd/system/wg-healthcheck@.timer"
}

test_safe_inert_environment_template() {
  local line
  assert_contains 'validated and parsed as data by wg-healthcheck' "$SOURCE_CONFIG" || return 1
  assert_contains 'SPEED_CHECK_ENABLED=0' "$SOURCE_CONFIG" || return 1
  assert_contains 'AIRVPN_ROTATE_ENABLED=0' "$SOURCE_CONFIG" || return 1
  assert_contains 'QBITTORRENT_CONTAINER=' "$SOURCE_CONFIG" || return 1
  assert_contains 'QBITTORRENT_LISTEN_IP=' "$SOURCE_CONFIG" || return 1
  assert_contains 'QBITTORRENT_LISTEN_PORT=' "$SOURCE_CONFIG" || return 1
  assert_contains 'QBITTORRENT_PROCESS_NAME=qbittorrent-nox' "$SOURCE_CONFIG" || return 1
  assert_contains 'REQUIRED_ROUTE=' "$SOURCE_CONFIG" || return 1
  assert_contains 'REQUIRED_RULE=' "$SOURCE_CONFIG" || return 1
  assert_contains '# REQUIRED_ROUTE="default dev wg0 table 100"' "$SOURCE_CONFIG" || return 1
  assert_contains '# REQUIRED_RULE="from 192.0.2.2 lookup 100"' "$SOURCE_CONFIG" || return 1
  assert_contains 'https://airvpn.org/api/status/?format=json' "$SOURCE_CONFIG" || return 1
  assert_contains 'https://airvpn.org/api/whatismyip/?format=json' "$SOURCE_CONFIG" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* || "$line" =~ ^[A-Z][A-Z0-9_]*=.*$ ]] ||
      { fail "not a strict health-check data assignment: $line"; return 1; }
  done <"$SOURCE_CONFIG"

  if grep -Ev '^[[:space:]]*(#|$)' "$SOURCE_CONFIG" |
     grep -En '\$\(|`|;|&&|\|\|' >/dev/null; then
    fail 'configuration template contains shell execution syntax'
  fi
}


test_installer_declares_exact_mode_contract() {
  local expected
  # These are source-code literals, not expandable shell expressions.
  # shellcheck disable=SC2016
  local -a expected_lines=(
    'ensure_directory "$TARGET_HELPER_DIR" 0755 1'
    'ensure_directory "$TARGET_CONFIG_DIR" 0700 1'
    'atomic_install_file "$SOURCE_MAIN" "$TARGET_MAIN" 0755'
    'atomic_install_file "$SOURCE_HELPER" "$TARGET_HELPER" 0755'
    'atomic_install_file "$SOURCE_SERVICE" "$TARGET_SERVICE" 0644'
    'atomic_install_file "$SOURCE_TIMER" "$TARGET_TIMER" 0644'
    'chmod 0600 -- "$TARGET_CONFIG"'
    'atomic_install_file "$SOURCE_CONFIG" "$TARGET_CONFIG" 0600'
  )
  for expected in "${expected_lines[@]}"; do
    assert_contains "$expected" "$INSTALLER" || return 1
  done
}

test_authenticated_telemetry_and_command_hooks_are_retired() {
  local file token
  local -a files=("$INSTALLER" "$SOURCE_SERVICE" "$SOURCE_TIMER" "$SOURCE_CONFIG")
  local -a tokens=(
    AIRVPN_API_KEY AIRVPN_API_ENV AIRVPN_USERINFO_URL USERINFO
    airvpn-healthcheck.env RESTART_CMD_UP RESTART_CMD_DOWN POST_RESTART_CMD
  )

  assert_absent "$ROOT/config/airvpn-healthcheck.env.example" || return 1
  for file in "${files[@]}"; do
    for token in "${tokens[@]}"; do
      assert_not_contains "$token" "$file" || return 1
    done
  done
}

test_service_environment_and_hardening_contract() {
  local directive forbidden
  local -a required=(
    'ExecStart=/usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/bash --noprofile --norc /usr/local/sbin/wg-healthcheck %i'
    'UnsetEnvironment=PATH BASH_ENV ENV SHELLOPTS BASHOPTS CDPATH GLOBIGNORE IFS PS4 PROMPT_COMMAND LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME'
    'UMask=0077'
    'RuntimeDirectory=wg-healthcheck'
    'RuntimeDirectoryMode=0700'
    'RuntimeDirectoryPreserve=yes'
    'TimeoutStartSec=180s'
    'LimitCORE=0'
    'NoNewPrivileges=yes'
    'PrivateTmp=yes'
    'ProtectHome=yes'
    'ProtectControlGroups=yes'
    'RestrictSUIDSGID=yes'
    'LockPersonality=yes'
    'MemoryDenyWriteExecute=yes'
    'RestrictRealtime=yes'
    'SystemCallArchitectures=native'
    'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK'
  )
  local -a forbidden_directives=(
    EnvironmentFile
    PrivateNetwork PrivateDevices ProtectSystem ProtectKernelTunables
    ProtectKernelModules CapabilityBoundingSet SystemCallFilter
  )

  for directive in "${required[@]}"; do
    grep -Fx -- "$directive" "$SOURCE_SERVICE" >/dev/null ||
      { fail "missing systemd directive: $directive"; return 1; }
  done
  for forbidden in "${forbidden_directives[@]}"; do
    if grep -E "^${forbidden}=" "$SOURCE_SERVICE" >/dev/null; then
      { fail "incompatible systemd directive present: $forbidden"; return 1; }
    fi
  done
  [[ "$(head -n 1 -- "$SOURCE_MAIN")" == '#!/bin/bash -p' ]] ||
    fail 'privileged runtime must use the fixed privileged-mode /bin/bash shebang'
  [[ "$(head -n 1 -- "$INSTALLER")" == '#!/bin/bash -p' ]] ||
    fail 'privileged installer must use the fixed privileged-mode /bin/bash shebang'
}

test_readme_documents_dual_mode_quick_paths_and_manual_timer_decision() {
  local expected
  # These are literal Markdown excerpts, not expandable shell expressions.
  # shellcheck disable=SC2016
  local -a required=(
    'MIT License'
    '## Choose a mode'
    'Static profile mode'
    'API-managed profile mode'
    'Default; credential-free.'
    'Explicit opt-in; API key required.'
    '### Static quick start'
    'sudo ./install.sh wg0'
    'sudo wg-healthcheck-setup --mode static wg0'
    '### API-managed quick start'
    'sudo wg-healthcheck-setup --mode api wg0'
    'hidden terminal prompt'
    'After either path'
    'explicitly decide whether to enable the timer'
    'sudo wg-healthcheck status wg0'
    'sudo systemctl start wg-healthcheck@wg0.service'
    'sudo systemctl enable --now wg-healthcheck@wg0.timer'
    'Leave the timer disabled if the manual result is not healthy or recovered.'
    '[operator guide](docs/operations.md)'
    'independent firewall kill switch'
  )

  assert_file "$README_FILE" || return 1
  for expected in "${required[@]}"; do
    assert_contains "$expected" "$README_FILE" || return 1
  done
}

test_operations_upgrade_quiesces_before_install_and_preserves_recovery_state() {
  local section
  section="$(read_markdown_section "$OPERATIONS_FILE" '## Upgrade and rollback' '## State repair and return to static mode')"
  [[ -n "$section" ]] || { fail 'operations upgrade section is missing'; return 1; }

  # Literal operator-guide shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    'sudo ./install.sh --quiesce wg0' \
    'Then rerun the quiesced installer' \
    'check `wg-healthcheck status wg0`' \
    'run the manual service check' \
    'make a fresh timer decision' || return 1

  [[ "$section" == *'stops the selected timer and worker'* ]] ||
    { fail 'upgrade instructions do not quiesce the selected timer and worker'; return 1; }
  [[ "$section" == *'active shared instances, locks, pending transactions, and safety records'* ]] ||
    { fail 'upgrade instructions do not check shared activity, locks, and recovery state'; return 1; }
  [[ "$section" == *'leaves the timer disabled'* ]] ||
    { fail 'upgrade instructions do not require a disabled timer after quiesce'; return 1; }
  # Literal Markdown contains backticks and is intentionally not expanded.
  # shellcheck disable=SC2016
  [[ "$section" == *'Do not combine `--quiesce` with `--enable`'* && "$section" == *'`DESTDIR` staging'* ]] ||
    fail 'upgrade instructions do not state the quiesce mode exclusions'
  [[ "$section" == *'do not delete a pending or safety marker to force an upgrade'* ]] ||
    fail 'upgrade instructions permit forcing past recovery state'
}

test_operations_package_uninstall_quiesces_every_instance_and_preserves_pending_state() {
  local section
  section="$(read_markdown_section "$OPERATIONS_FILE" '## Disable and uninstall' '## Useful status commands')"
  [[ -n "$section" ]] || { fail 'operations uninstall section is missing'; return 1; }

  # Literal operator-guide shell snippets; expansion would invalidate the assertions.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'mapfile -t timers' \
    "systemctl list-unit-files --type=timer --no-legend --plain 'wg-healthcheck@*.timer'" \
    'mapfile -t services' \
    'sudo systemctl disable --now "${timers[@]}"' \
    'sudo systemctl stop "${services[@]}"' \
    'active="$(systemctl list-units' \
    'Active health-check instances remain; package removal stopped.' \
    'pending="$(sudo find /etc/wireguard' \
    'A pending recovery transaction exists; package removal stopped.' \
    '/etc/systemd/system/wg-healthcheck@.service' \
    '/usr/local/sbin/wg-healthcheck' \
    'sudo systemctl daemon-reload' || return 1

  [[ "$section" == *'never delete a pending marker to force uninstall'* ]] ||
    fail 'uninstall does not preserve pending recovery state'
}

test_operations_rollback_masks_legacy_auto_enable_until_validation() {
  local section
  section="$(read_markdown_section "$OPERATIONS_FILE" '## Upgrade and rollback' '## State repair and return to static mode')"
  [[ -n "$section" ]] || { fail 'operations rollback section is missing'; return 1; }

  assert_ordered_text "$section" \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'sudo systemctl mask --runtime wg-healthcheck@wg0.timer' \
    'if ! sudo ./install.sh wg0; then' \
    'Rollback installer failed; timer remains runtime-masked.' \
    'exit 1' \
    'sudo systemctl start wg-healthcheck@wg0.service' \
    'sudo cat /run/wg-healthcheck/wg0.status' \
    'sudo systemctl unmask --runtime wg-healthcheck@wg0.timer' \
    'sudo systemctl enable --now wg-healthcheck@wg0.timer' || return 1

  [[ "$section" == *'Older installers can enable a timer automatically'* ]] ||
    { fail 'rollback does not identify the legacy auto-enable hazard'; return 1; }
  [[ "$section" == *'reviewed compatible revision'* ]] ||
    { fail 'rollback omits target-revision configuration compatibility'; return 1; }
  [[ "$section" == *'Never continue past a nonzero installer result.'* ]] ||
    { fail 'rollback permits execution after installer failure'; return 1; }
  [[ "$section" == *'keep the timer runtime-masked until the manual health check succeeds'* ]] ||
    fail 'rollback unmasks the timer before validation is complete'
}

test_operations_credential_removal_is_explicit_and_uninstall_preserves_recovery_data() {
  local credential_section uninstall_section
  credential_section="$(read_markdown_section "$OPERATIONS_FILE" '## Credential lifecycle' '## Upgrade and rollback')"
  uninstall_section="$(read_markdown_section "$OPERATIONS_FILE" '## Disable and uninstall' '## Useful status commands')"
  [[ -n "$credential_section" ]] || { fail 'operations credential lifecycle section is missing'; return 1; }
  [[ -n "$uninstall_section" ]] || { fail 'operations uninstall section is missing'; return 1; }

  [[ "$credential_section" == *'--remove-credential --apply'* ]] ||
    fail 'credential removal is not an explicit applied static-mode operation'
  [[ "$credential_section" == *'Normal package removal intentionally preserves the credential and persistent API state'* ]] ||
    fail 'credential lifecycle does not preserve data during ordinary removal'
  [[ "$uninstall_section" == *'Package removal does not remove the WireGuard profile, health-check configuration, credential, pre-managed snapshot, or persistent API state.'* ]] ||
    fail 'uninstall instructions do not preserve operator and API recovery data'
}

test_python_bytecode_is_ignored() {
  assert_file "$GITIGNORE_FILE" || return 1
  grep -Fx -- '__pycache__/' "$GITIGNORE_FILE" >/dev/null ||
    { fail 'Python __pycache__ directories are not ignored'; return 1; }
  grep -Fx -- '*.py[cod]' "$GITIGNORE_FILE" >/dev/null ||
    fail 'Python bytecode files are not ignored'
}

test_repository_text_uses_lf_on_every_platform() {
  assert_file "$GITATTRIBUTES_FILE" || return 1
  grep -Fx -- '* text=auto eol=lf' "$GITATTRIBUTES_FILE" >/dev/null ||
    fail 'repository text does not have a platform-independent LF contract'
}

test_public_repository_docs_are_sanitized_and_complete() {
  local combined_file="$TEST_TMP/public-repository-docs" forbidden required

  assert_file "$README_FILE" || return 1
  assert_file "$OPERATIONS_FILE" || return 1
  assert_file "$LICENSE_FILE" || return 1
  assert_file "$SECURITY_FILE" || return 1
  assert_file "$CONTRIBUTING_FILE" || return 1
  assert_file "$CHANGELOG_FILE" || return 1
  assert_file "$VERSION_FILE" || return 1
  assert_file "$RELEASE_NOTES_FILE" || return 1
  command cat -- \
    "$README_FILE" \
    "$OPERATIONS_FILE" \
    "$LICENSE_FILE" \
    "$SOURCE_CONFIG" \
    "$SECURITY_FILE" \
    "$CONTRIBUTING_FILE" \
    "$CHANGELOG_FILE" \
    "$VERSION_FILE" \
    "$RELEASE_NOTES_FILE" > "$combined_file" || return 1

  # Literal public-documentation shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  for required in \
    'not affiliated with or endorsed by AirVPN' \
    '## Choose a mode' \
    'Static profile mode' \
    'API-managed profile mode' \
    'sudo wg-healthcheck-setup --mode static wg0' \
    'sudo wg-healthcheck-setup --mode api wg0' \
    'Leave the timer disabled if the manual result is not healthy or recovered.' \
    '## Upgrade and rollback' \
    '## Disable and uninstall' \
    'MIT License' \
    '## Security' \
    '| `1.1.x` | Yes |' \
    'private vulnerability-reporting flow' \
    'Never submit WireGuard private keys'; do
    assert_contains "$required" "$combined_file" || return 1
  done

  for forbidden in \
    'Deployment status:' \
    'docs/aegis/'; do
    assert_not_contains "$forbidden" "$combined_file" || return 1
  done

  if grep -Eq '(^|[^0-9])(10\.[0-9]{1,3}(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})([^0-9]|$)' "$combined_file"; then
    fail 'public documentation contains an RFC1918 address'
    return 1
  fi
  if grep -Eq '([A-Za-z]:\\Users\\|/Users/[^/[:space:]]+|/home/[^/[:space:]]+)' "$combined_file"; then
    fail 'public documentation contains a user-home path'
    return 1
  fi
}

test_ci_workflow_is_deterministic_and_smoke_isolated() {
  local expected forbidden smoke
  local -a required=(
    'push:'
    'pull_request:'
    'workflow_dispatch:'
    'schedule:'
    'permissions:'
    'contents: read'
    'runs-on: ubuntu-24.04'
    'timeout-minutes:'
    "if: github.event_name != 'schedule'"
    "if: github.event_name == 'schedule'"
    'continue-on-error: true'
    'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0'
    'persist-credentials: false'
    'uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 # v6.3.0'
    "python3 -m unittest discover -s tests -p 'test_*.py' -v"
    'bash tests/test_wg_healthcheck.sh'
    'bash tests/test_install.sh'
    'bash tests/test_release.sh'
    'bash -n bin/wg-healthcheck install.sh scripts/*.sh tests/*.sh'
    'shellcheck -x -S style bin/wg-healthcheck install.sh scripts/*.sh tests/*.sh'
    'sudo install -D -m 0755 bin/wg-healthcheck /usr/local/sbin/wg-healthcheck'
    'sudo install -D -m 0755 libexec/airvpn-api /usr/local/libexec/wg-healthcheck/airvpn-api'
    'systemd-analyze verify systemd/wg-healthcheck@.service systemd/wg-healthcheck@.timer'
    'timeout --signal=TERM 45s python3 libexec/airvpn-api select'
    "--url 'https://airvpn.org/api/status/?format=json'"
    '--port 1637'
    '--timeout 20'
  )

  assert_file "$CI_WORKFLOW" || return 1
  for expected in "${required[@]}"; do
    assert_contains "$expected" "$CI_WORKFLOW" || return 1
  done

  for forbidden in pull_request_target 'secrets.' AIRVPN_API_KEY AIRVPN_USERINFO_URL AIRVPN_API_ENV; do
    assert_not_contains "$forbidden" "$CI_WORKFLOW" || return 1
  done

  smoke="$(sed -n '/^  airvpn-api-smoke:/,$p' "$CI_WORKFLOW")"
  [[ -n "$smoke" ]] || { fail 'scheduled smoke job block is missing'; return 1; }
  for forbidden in sudo docker wg-quick --interface; do
    if grep -F -- "$forbidden" <<<"$smoke" >/dev/null; then
      fail "scheduled smoke job contains privileged/runtime dependency: $forbidden"
      return 1
    fi
  done
}

test_reentrant_upgrade_lock_acquisition_preserves_the_first_lease() (
  local stage rc
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  IFACE=wg1
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  acquire_upgrade_locks || { fail 'initial upgrade-lock acquisition failed'; return 1; }
  acquire_upgrade_locks >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'reentrant upgrade-lock acquisition unexpectedly succeeded'; return 1; }

  command flock -n "$LIVE_SETUP_GUARD" -c true >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'reentrant acquisition lost the original setup guard'; return 1; }
  command flock -n "$LIVE_INTERFACE_LOCK" -c true >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'reentrant acquisition lost the original interface lock'; return 1; }

  release_upgrade_locks || { fail 'single release after reentrant failure failed'; return 1; }
  command flock -n "$LIVE_SETUP_GUARD" -c true >/dev/null 2>&1 ||
    { fail 'setup guard leaked after a single release'; return 1; }
  command flock -n "$LIVE_INTERFACE_LOCK" -c true >/dev/null 2>&1 ||
    fail 'interface lock leaked after a single release'
)

test_upgrade_runtime_directory_rejects_an_unsafe_destdir_run_parent() (
  local stage outside rc
  stage="$(new_stage)" || return 1
  outside="$TEST_TMP/unsafe-run-parent"
  mkdir -p -- "$outside"
  if ! ln -s -- "$outside" "$stage/run"; then
    skip 'unsafe DESTDIR run-parent symlink test (symlinks unavailable)'
    return 77
  fi

  # shellcheck source=install.sh
  source "$INSTALLER"
  IFACE=wg1
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  acquire_upgrade_locks >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || { fail 'upgrade locks accepted a symlinked DESTDIR/run parent'; return 1; }
  [[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]] ||
    fail 'upgrade locks created files through a symlinked DESTDIR/run parent'
)

test_main_quiesce_failure_after_preparation_keeps_timer_disabled_and_releases_locks() (
  local stage log="$TEST_TMP/main-quiesce-failure.log" err="$TEST_TMP/main-quiesce-failure.err"
  local phase rc
  local -a phases=(layout artifacts daemon_reload)

  for phase in "${phases[@]}"; do
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    : >"$log"
    require_commands() { return 0; }
    validate_destdir() {
      LIVE_INSTALL=1
      DESTDIR="$stage"
      INSTALL_OWNER_ARGS=()
    }
    preflight_sources() { return 0; }
    preflight_targets() { return 0; }
    require_live_commands() { return 0; }
    resolve_systemctl() { SYSTEMCTL_BIN=systemctl-double; }
    publish_runtime_upgrade_guard() { return 0; }
    publish_setup_upgrade_guard() { return 0; }
    stabilize_live_upgrade_after_guards() { return 0; }
    publish_final_launchers() { return 0; }
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      case "$1" in
        is-enabled) printf 'enabled\n'; return 0 ;;
        disable|stop) return 0 ;;
        is-active) return 3 ;;
        list-units) return 0 ;;
        daemon-reload) [[ "$phase" == daemon_reload ]] && return 1; return 0 ;;
        enable) return 99 ;;
      esac
      return 0
    }
    case "$phase" in
      layout)
        install_guarded_artifacts() { return 1; }
        ;;
      artifacts)
        install_guarded_artifacts() { return 1; }
        ;;
      daemon_reload)
        install_guarded_artifacts() { return 0; }
        ;;
    esac

    main --quiesce wg0 >/dev/null 2>"$err"
    rc=$?
    [[ $rc -ne 0 ]] || { fail "main accepted $phase failure after quiesce"; return 1; }
    assert_contains 'disable --now wg-healthcheck@wg0.timer' "$log" || return 1
    assert_contains 'timer remains disabled' "$err" || return 1
    assert_not_contains 'enable ' "$log" || return 1
    command flock -n "$LIVE_SETUP_GUARD" -c true >/dev/null 2>&1 ||
      { fail "setup guard remained held after $phase failure"; return 1; }
    command flock -n "$LIVE_INTERFACE_LOCK" -c true >/dev/null 2>&1 ||
      fail "interface lock remained held after $phase failure"
  done
)

test_dual_entrypoint_guards_publish_before_any_dependency_mutation() (
  local stage log="$TEST_TMP/dual-guard-order.log" rc actual
  stage="$(new_stage)" || return 1

  # shellcheck source=install.sh
  source "$INSTALLER"
  declare -F publish_runtime_upgrade_guard >/dev/null || {
    fail 'installer does not expose runtime-upgrade guard publication'
    return 1
  }
  declare -F publish_setup_upgrade_guard >/dev/null || {
    fail 'installer does not expose setup-upgrade guard publication'
    return 1
  }
  declare -F stabilize_live_upgrade_after_guards >/dev/null || {
    fail 'installer does not expose guarded live-upgrade stabilization'
    return 1
  }
  declare -F install_guarded_artifacts >/dev/null || {
    fail 'installer does not expose guarded artifact publication'
    return 1
  }
  declare -F publish_final_launchers >/dev/null || {
    fail 'installer does not expose final launcher publication'
    return 1
  }
  : >"$log"
  require_commands() { return 0; }
  validate_destdir() { LIVE_INSTALL=1; DESTDIR="$stage"; INSTALL_OWNER_ARGS=(); }
  initialize_paths() {
    TARGET_MAIN="$stage/wg-healthcheck"
    TARGET_SETUP="$stage/wg-healthcheck-setup"
    LIVE_SETUP_GUARD="$stage/setup.guard"
    LIVE_INTERFACE_LOCK="$stage/wg0.lock"
  }
  preflight_sources() { return 0; }
  preflight_targets() { return 0; }
  require_live_commands() { return 0; }
  resolve_systemctl() { SYSTEMCTL_BIN=systemctl-double; }
  prepare_live_upgrade() { printf 'prepare\n' >>"$log"; QUIESCE=1; QUIESCE_DISABLE_ATTEMPTED=1; QUIESCE_TIMER_DISABLED=1; }
  publish_runtime_upgrade_guard() { printf 'runtime-guard\n' >>"$log"; printf '#!/bin/sh\nexit 75\n' >"$TARGET_MAIN"; chmod 0755 "$TARGET_MAIN"; }
  publish_setup_upgrade_guard() { printf 'setup-guard\n' >>"$log"; printf '#!/bin/sh\nexit 75\n' >"$TARGET_SETUP"; chmod 0755 "$TARGET_SETUP"; }
  stabilize_live_upgrade_after_guards() { printf 'stabilize\n' >>"$log"; }
  install_guarded_artifacts() { printf 'dependencies\n' >>"$log"; }
  systemctl_exec() { printf 'systemctl %s\n' "$*" >>"$log"; return 0; }
  publish_final_launchers() {
    printf 'final-launchers\n' >>"$log"
    printf '#!/bin/sh\nexit 0\n' >"$TARGET_SETUP"
    printf '#!/bin/sh\nexit 0\n' >"$TARGET_MAIN"
    chmod 0755 "$TARGET_SETUP" "$TARGET_MAIN"
  }
  release_upgrade_locks() { printf 'release\n' >>"$log"; }

  main --quiesce wg0 >/dev/null 2>&1
  rc=$?
  actual="$(cat "$log")"
  [[ $rc -eq 0 ]] || { fail 'guarded live-upgrade orchestration failed'; return 1; }
  [[ "$actual" == $'prepare\nruntime-guard\nsetup-guard\nstabilize\ndependencies\nsystemctl daemon-reload\nfinal-launchers\nrelease' ]] ||
    fail "guarded publication order was unsafe: $actual"
  "$TARGET_MAIN" >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] || fail "runtime launcher did not become real only at final commit: $rc"
)

test_guarded_publication_failures_keep_runtime_guarded_and_stop_later_actions() (
  local stage log="$TEST_TMP/guarded-publication-failure.log" phase rc actual
  local -a phases=(runtime_guard setup_guard stabilize dependencies daemon_reload final_setup final_runtime)

  for phase in "${phases[@]}"; do
    stage="$(new_stage)" || return 1
    # shellcheck source=install.sh
    source "$INSTALLER"
    declare -F install_guarded_artifacts >/dev/null || {
      fail 'installer does not expose guarded artifact publication'
      return 1
    }
    : >"$log"
    TARGET_MAIN="$stage/wg-healthcheck"
    TARGET_SETUP="$stage/wg-healthcheck-setup"
    QUIESCE=1
    QUIESCE_DISABLE_ATTEMPTED=1
    QUIESCE_TIMER_DISABLED=1
    publish_runtime_upgrade_guard() {
      printf 'runtime-guard\n' >>"$log"
      printf '#!/bin/sh\nexit 75\n' >"$TARGET_MAIN"; chmod 0755 "$TARGET_MAIN"
      [[ "$phase" != runtime_guard ]]
    }
    publish_setup_upgrade_guard() {
      printf 'setup-guard\n' >>"$log"
      printf '#!/bin/sh\nexit 75\n' >"$TARGET_SETUP"; chmod 0755 "$TARGET_SETUP"
      [[ "$phase" != setup_guard ]]
    }
    stabilize_live_upgrade_after_guards() { printf 'stabilize\n' >>"$log"; [[ "$phase" != stabilize ]]; }
    install_guarded_artifacts() { printf 'dependencies\n' >>"$log"; [[ "$phase" != dependencies ]]; }
    systemctl_exec() {
      printf 'systemctl %s\n' "$*" >>"$log"
      [[ "$1" == daemon-reload && "$phase" == daemon_reload ]] && return 1
      [[ "$1" == enable ]] && return 99
      return 0
    }
    publish_final_launchers() {
      printf 'final-setup\n' >>"$log"
      [[ "$phase" != final_setup ]] || return 1
      printf '#!/bin/sh\nexit 0\n' >"$TARGET_SETUP"; chmod 0755 "$TARGET_SETUP"
      printf 'final-runtime\n' >>"$log"
      [[ "$phase" != final_runtime ]] || return 1
      printf '#!/bin/sh\nexit 0\n' >"$TARGET_MAIN"; chmod 0755 "$TARGET_MAIN"
    }

    publish_runtime_upgrade_guard || rc=$?
    rc=${rc:-0}
    if (( rc == 0 )); then publish_setup_upgrade_guard || rc=$?; fi
    if (( rc == 0 )); then stabilize_live_upgrade_after_guards || rc=$?; fi
    if (( rc == 0 )); then install_guarded_artifacts || rc=$?; fi
    if (( rc == 0 )); then systemctl_exec daemon-reload || rc=$?; fi
    if (( rc == 0 )); then publish_final_launchers || rc=$?; fi
    actual="$(cat "$log")"
    [[ $rc -ne 0 ]] || { fail "guarded publication accepted injected $phase failure"; return 1; }
    [[ "$actual" != *'enable '* ]] || { fail "guarded $phase failure enabled a timer"; return 1; }
    [[ -x "$TARGET_MAIN" ]] || { fail "runtime guard vanished after $phase failure"; return 1; }
    "$TARGET_MAIN" >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 75 ]] || { fail "runtime became callable before final commit after $phase failure"; return 1; }
  done
)

test_installer_exit_cleanup_releases_locks_preserves_signal_and_does_not_leak_traps() (
  local stage before_exit after_exit rc signal expected_rc
  before_exit="$(trap -p EXIT)"
  # shellcheck source=install.sh
  source "$INSTALLER"
  after_exit="$(trap -p EXIT)"
  [[ "$after_exit" == "$before_exit" ]] || { fail 'sourcing installer leaked an EXIT trap'; return 1; }
  declare -F installer_exit_cleanup >/dev/null || {
    fail 'installer does not expose scoped exit cleanup'
    return 1
  }

  stage="$(new_stage)" || return 1
  IFACE=wg0
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  acquire_upgrade_locks || { fail 'cleanup fixture could not acquire upgrade locks'; return 1; }
  QUIESCE=1
  QUIESCE_DISABLE_ATTEMPTED=1
  QUIESCE_TIMER_DISABLED=1
  QUIESCE_FAILURE_REPORTED=0
  installer_exit_cleanup 143 >/dev/null 2>"$TEST_TMP/cleanup.err"
  rc=$?
  [[ $rc -eq 143 ]] || { fail "cleanup did not preserve TERM status: $rc"; return 1; }
  assert_contains 'timer remains disabled' "$TEST_TMP/cleanup.err" || return 1
  installer_exit_cleanup 143 >/dev/null 2>>"$TEST_TMP/cleanup.err"
  [[ "$(grep -Fc 'timer remains disabled' "$TEST_TMP/cleanup.err")" == 1 ]] ||
    { fail 'cleanup emitted the disabled-timer diagnostic more than once'; return 1; }
  command flock -n "$LIVE_SETUP_GUARD" -c true >/dev/null 2>&1 ||
    { fail 'cleanup left the setup guard held'; return 1; }
  command flock -n "$LIVE_INTERFACE_LOCK" -c true >/dev/null 2>&1 ||
    { fail 'cleanup left the interface lock held'; return 1; }

  for signal in TERM INT; do
    case "$signal" in TERM) expected_rc=143 ;; INT) expected_rc=130 ;; esac
    (
      # shellcheck source=install.sh
      source "$INSTALLER"
      stage="$(new_stage)" || exit 1
      IFACE=wg0
      DESTDIR="$stage"
      LIVE_INSTALL=1
      INSTALL_OWNER_ARGS=()
      initialize_paths
      acquire_upgrade_locks || exit 1
      QUIESCE=1
      QUIESCE_DISABLE_ATTEMPTED=1
      QUIESCE_TIMER_DISABLED=1
      QUIESCE_FAILURE_REPORTED=0
      # The trap intentionally captures the fixed per-iteration signal status now.
      # shellcheck disable=SC2064
      trap "installer_exit_cleanup $expected_rc; exit $expected_rc" "$signal"
      kill -s "$signal" "$BASHPID"
    ) >/dev/null 2>>"$TEST_TMP/cleanup.err"
    rc=$?
    [[ $rc -eq $expected_rc ]] || {
      fail "scoped $signal cleanup did not preserve its signal status: $rc"
      return 1
    }
  done

  (
    # shellcheck source=install.sh
    source "$INSTALLER"
    stage="$(new_stage)" || exit 1
    IFACE=wg0
    DESTDIR="$stage"
    LIVE_INSTALL=1
    INSTALL_OWNER_ARGS=()
    initialize_paths
    acquire_upgrade_locks || exit 1
    QUIESCE=1
    QUIESCE_DISABLE_ATTEMPTED=1
    QUIESCE_TIMER_DISABLED=1
    QUIESCE_FAILURE_REPORTED=0
    trap 'installer_exit_cleanup 77' EXIT
    exit 77
  ) >/dev/null 2>>"$TEST_TMP/cleanup.err"
  rc=$?
  [[ $rc -eq 77 ]] || fail "scoped EXIT cleanup did not preserve its status: $rc"
)

run_test() {
  local name="$1" rc
  shift
  printf 'TEST %s ... ' "$name"
  "$@"
  rc=$?
  case "$rc" in
    0)
      passes=$((passes + 1))
      printf 'ok\n'
      ;;
    77)
      skips=$((skips + 1))
      printf 'skipped\n'
      ;;
    *)
      failures=$((failures + 1))
      printf 'not ok\n'
      ;;
  esac
}

run_test default_staged_install_from_unrelated_cwd test_default_staged_install_from_unrelated_cwd
run_test staged_managed_profile_artifacts_have_exact_content_and_modes test_staged_managed_profile_artifacts_have_exact_content_and_modes
run_test new_sources_and_targets_are_preflighted_before_staging_mutation test_new_sources_and_targets_are_preflighted_before_staging_mutation
run_test installer_preserves_api_credential_pre_managed_snapshot_and_state test_installer_preserves_api_credential_pre_managed_snapshot_and_state
run_test zero_args_and_explicit_wg0_are_compatible test_zero_args_and_explicit_wg0_are_compatible
run_test custom_interface_uses_an_exact_filename test_custom_interface_uses_an_exact_filename
run_test invalid_cli_is_rejected_before_writes test_invalid_cli_is_rejected_before_writes
run_test live_install_requires_root test_live_install_requires_root
run_test unsafe_destdir_values_are_rejected test_unsafe_destdir_values_are_rejected
run_test missing_sources_fail_before_staging_mutation test_missing_sources_fail_before_staging_mutation
run_test existing_healthcheck_config_is_preserved_and_tightened test_existing_healthcheck_config_is_preserved_and_tightened
run_test existing_wireguard_config_is_never_overwritten test_existing_wireguard_config_is_never_overwritten
run_test writable_existing_config_is_rejected_without_changes test_writable_existing_config_is_rejected_without_changes
run_test managed_symlink_target_is_rejected_and_untouched test_managed_symlink_target_is_rejected_and_untouched
run_test nonregular_managed_target_is_rejected_before_mutation test_nonregular_managed_target_is_rejected_before_mutation
run_test atomic_replacement_failure_preserves_old_file test_atomic_replacement_failure_preserves_old_file
run_test atomic_interruption_cleans_temp_without_leaking_traps test_atomic_interruption_cleans_temp_without_leaking_traps
run_test artifact_failure_is_ordered_and_safely_retryable test_artifact_failure_is_ordered_and_safely_retryable
run_test managed_artifact_install_order_is_dependency_safe test_managed_artifact_install_order_is_dependency_safe
run_test existing_managed_file_owner_is_not_blessed test_existing_managed_file_owner_is_not_blessed
run_test systemctl_behavior_is_explicit_and_exact test_systemctl_behavior_is_explicit_and_exact
run_test quiesce_argument_matrix_is_explicit_and_staging_is_rejected test_quiesce_argument_matrix_is_explicit_and_staging_is_rejected
run_test ordinary_live_upgrade_refuses_an_active_worker_before_mutation test_ordinary_live_upgrade_refuses_an_active_worker_before_mutation
run_test ordinary_live_upgrade_refuses_an_active_timer_before_mutation test_ordinary_live_upgrade_refuses_an_active_timer_before_mutation
run_test ordinary_live_upgrade_refuses_a_held_interface_lock test_ordinary_live_upgrade_refuses_a_held_interface_lock
run_test live_upgrade_refuses_pending_journal_or_safety_record test_live_upgrade_refuses_pending_journal_or_safety_record
run_test quiesce_stops_waits_checks_and_leaves_timer_disabled test_quiesce_stops_waits_checks_and_leaves_timer_disabled
run_test systemctl_inactive_query_errors_fail_closed test_systemctl_inactive_query_errors_fail_closed
run_test inactive_status_with_stderr_diagnostic_fails_closed test_inactive_status_with_stderr_diagnostic_fails_closed
run_test quiesce_timer_enable_state_is_exact_and_fail_closed test_quiesce_timer_enable_state_is_exact_and_fail_closed
run_test quiesce_rejects_enabled_state_with_stderr_diagnostic_before_disable test_quiesce_rejects_enabled_state_with_stderr_diagnostic_before_disable
run_test live_upgrade_refuses_active_or_unqueryable_shared_instances test_live_upgrade_refuses_active_or_unqueryable_shared_instances
run_test upgrade_locks_are_retained_and_released_for_the_selected_interface test_upgrade_locks_are_retained_and_released_for_the_selected_interface
run_test upgrade_locks_refuse_held_wg1_lock_or_unsafe_setup_guard test_upgrade_locks_refuse_held_wg1_lock_or_unsafe_setup_guard
run_test reentrant_upgrade_lock_acquisition_preserves_the_first_lease test_reentrant_upgrade_lock_acquisition_preserves_the_first_lease
run_test upgrade_runtime_directory_rejects_an_unsafe_destdir_run_parent test_upgrade_runtime_directory_rejects_an_unsafe_destdir_run_parent
run_test quiesce_partial_failure_keeps_timer_disabled_and_reports_it test_quiesce_partial_failure_keeps_timer_disabled_and_reports_it
run_test main_quiesce_failure_after_preparation_keeps_timer_disabled_and_releases_locks test_main_quiesce_failure_after_preparation_keeps_timer_disabled_and_releases_locks
run_test state_directory_creation_failure_aborts_layout test_state_directory_creation_failure_aborts_layout
run_test setup_package_manifest_rejects_unexpected_entries_and_links test_setup_package_manifest_rejects_unexpected_entries_and_links
run_test setup_upgrade_guard_is_published_before_package_and_retained_on_failure test_setup_upgrade_guard_is_published_before_package_and_retained_on_failure
run_test dual_entrypoint_guards_publish_before_any_dependency_mutation test_dual_entrypoint_guards_publish_before_any_dependency_mutation
run_test guarded_publication_failures_keep_runtime_guarded_and_stop_later_actions test_guarded_publication_failures_keep_runtime_guarded_and_stop_later_actions
run_test installer_exit_cleanup_releases_locks_preserves_signal_and_does_not_leak_traps test_installer_exit_cleanup_releases_locks_preserves_signal_and_does_not_leak_traps
run_test staged_enable_never_calls_host_systemctl test_staged_enable_never_calls_host_systemctl
run_test safe_inert_environment_template test_safe_inert_environment_template
run_test installer_declares_exact_mode_contract test_installer_declares_exact_mode_contract
run_test authenticated_telemetry_and_command_hooks_are_retired test_authenticated_telemetry_and_command_hooks_are_retired
run_test service_environment_and_hardening_contract test_service_environment_and_hardening_contract
run_test readme_documents_dual_mode_quick_paths_and_manual_timer_decision test_readme_documents_dual_mode_quick_paths_and_manual_timer_decision
run_test operations_upgrade_quiesces_before_install_and_preserves_recovery_state test_operations_upgrade_quiesces_before_install_and_preserves_recovery_state
run_test operations_package_uninstall_quiesces_every_instance_and_preserves_pending_state test_operations_package_uninstall_quiesces_every_instance_and_preserves_pending_state
run_test operations_rollback_masks_legacy_auto_enable_until_validation test_operations_rollback_masks_legacy_auto_enable_until_validation
run_test operations_credential_removal_is_explicit_and_uninstall_preserves_recovery_data test_operations_credential_removal_is_explicit_and_uninstall_preserves_recovery_data
run_test python_bytecode_is_ignored test_python_bytecode_is_ignored
run_test repository_text_uses_lf_on_every_platform test_repository_text_uses_lf_on_every_platform
run_test public_repository_docs_are_sanitized_and_complete test_public_repository_docs_are_sanitized_and_complete
run_test ci_workflow_is_deterministic_and_smoke_isolated test_ci_workflow_is_deterministic_and_smoke_isolated

printf '\nInstaller tests: %d passed, %d skipped, %d failed\n' "$passes" "$skips" "$failures"
(( failures == 0 ))
