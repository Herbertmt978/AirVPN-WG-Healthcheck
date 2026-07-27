#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALLER="$ROOT/install.sh"
SOURCE_MAIN="$ROOT/bin/wg-healthcheck"
SOURCE_HELPER="$ROOT/libexec/airvpn-api"
SOURCE_SERVICE="$ROOT/systemd/wg-healthcheck@.service"
SOURCE_TIMER="$ROOT/systemd/wg-healthcheck@.timer"
SOURCE_CONFIG="$ROOT/config/wg0.conf.example"
README_FILE="$ROOT/README.md"
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

read_readme_section() {
  local start="$1" end="$2"
  awk -v start="$start" -v end="$end" '
    $0 == start { inside=1; next }
    inside && $0 == end { exit }
    inside { print }
  ' "$README_FILE"
}

assert_ordered_text() {
  local remaining="$1" needle
  shift
  for needle in "$@"; do
    [[ "$remaining" == *"$needle"* ]] || {
      fail "missing or out-of-order README text: $needle"
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
  SOURCE_MAIN='source-main'
  SOURCE_HELPER='source-helper'
  SOURCE_SERVICE='source-service'
  SOURCE_TIMER='source-timer'
  SOURCE_CONFIG='source-config'
  TARGET_MAIN='target-main'
  TARGET_HELPER='target-helper'
  TARGET_SERVICE='target-service'
  TARGET_TIMER='target-timer'
  TARGET_CONFIG='target-config'
  LIVE_INSTALL=0
  : >"$log"

  # Called indirectly by install_artifacts from the sourced installer.
  # shellcheck disable=SC2329
  atomic_install_file() {
    printf '%s\n' "$2" >>"$log"
    [[ "$2" != "$TARGET_SERVICE" ]]
  }

  install_artifacts
  rc=$?
  actual="$(cat "$log")"
  expected=$'target-helper\ntarget-main\ntarget-service'
  [[ $rc -ne 0 ]] || { fail 'later artifact failure was ignored'; return 1; }
  [[ "$actual" == "$expected" ]] ||
    fail "unsafe artifact order or work continued after failure: $actual"
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
  run_live_systemctl 0 wg0 || return 1
  [[ "$(cat "$log")" == daemon-reload ]] ||
    { fail "default action was not exactly daemon-reload: $(cat "$log")"; return 1; }

  : >"$log"
  run_live_systemctl 1 wg0 || return 1
  [[ "$(cat "$log")" == $'daemon-reload\nenable --now wg-healthcheck@wg0.timer' ]] ||
    fail "--enable actions were not exact: $(cat "$log")"
}

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

  if grep -En '\$\(|`|(^|[^#]);|&&|\|\|' "$SOURCE_CONFIG" >/dev/null; then
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

test_readme_documents_safe_operator_lifecycle() {
  local expected
  # These are literal Markdown excerpts, not expandable shell expressions.
  # shellcheck disable=SC2016
  local -a required=(
    'Speed checks and AirVPN rotation are disabled by default.'
    'exact configured endpoint'
    'exactly one `[Peer]` section and one `Endpoint`'
    'numeric IPv4 or bracketed IPv6 address'
    'independent firewall kill switch'
    'Docker socket is root-equivalent'
    '`iputils-ping` when `PING_TARGET` is configured'
    'root-owned regular files with mode `0600`'
    'sudo ./install.sh wg0'
    'does not enable or start the timer'
    'sudoedit /etc/wireguard/healthcheck.d/wg0.conf'
    'sudo systemctl start wg-healthcheck@wg0.service'
    'sudo cat /run/wg-healthcheck/wg0.status'
    'sudo systemctl enable --now wg-healthcheck@wg0.timer'
    'sudo ./install.sh --enable wg0'
    'already-reviewed configuration'
    'Existing per-interface configuration is preserved'
    'helper, then main script, then units'
    'daemon-reload runs only after all managed files are installed successfully'
    'may leave earlier compatible replacements in place'
    'keep the timer stopped and rerun the installer'
    'data, not shell code'
    'Unknown keys and duplicate keys are rejected'
    'No `export`, command substitution, variable expansion, or shell commands are accepted.'
    'RESTART_CMD_UP'
    'RESTART_CMD_DOWN'
    'POST_RESTART_CMD'
    'AIRVPN_USERINFO_URL'
    'AIRVPN_API_ENV'
    '/etc/wireguard/airvpn-healthcheck.env'
    'default dev wg0 table 100'
    'from 192.0.2.2 lookup 100'
    '/run/wg-healthcheck/<iface>.status'
    '/etc/wireguard/<iface>.conf.bak-healthcheck'
    '/etc/wireguard/<iface>.conf.pending-healthcheck'
    'Never delete the pending marker manually.'
    '`suppressed` and `degraded` are intentionally nonzero'
    'Repository rollback'
    '## Uninstall'
    '## Security'
    'No license is currently granted'
  )

  assert_file "$README_FILE" || return 1
  for expected in "${required[@]}"; do
    assert_contains "$expected" "$README_FILE" || return 1
  done
}

test_readme_migration_quiesces_writers_before_pending_check() {
  local section
  section="$(read_readme_section '## Migrating an existing deployment' '## State and recovery transaction')"
  [[ -n "$section" ]] || { fail 'README migration section is missing'; return 1; }

  # Literal README shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck' \
    'sudo ./install.sh wg0' \
    'sudoedit /etc/wireguard/healthcheck.d/wg0.conf' || return 1

  [[ "$section" == *'Stopping the service waits for or cancels any active oneshot and returns only after the unit is inactive.'* ]] ||
    { fail 'migration does not explain active-oneshot quiescence'; return 1; }
  [[ "$section" == *'The pending-marker check must exit zero before you install or edit.'* ]] ||
    { fail 'migration does not make the pending check a precondition'; return 1; }
  [[ "$section" == *'If it fails, do not install or edit anything; reconcile the pending rotation with the current version or troubleshoot it first.'* ]] ||
    fail 'migration does not stop on pending recovery state'
}

test_readme_package_uninstall_quiesces_every_instance() {
  local section
  section="$(read_readme_section '## Uninstall' '## FAQ')"
  [[ -n "$section" ]] || { fail 'README uninstall section is missing'; return 1; }

  # Literal README shell snippets; expansion would invalidate the assertions.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    '### Disable one interface' \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck' \
    '### Remove the package' \
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

test_readme_rollback_masks_legacy_auto_enable_until_validation() {
  local section
  section="$(read_readme_section '### Repository rollback' '## Development checks')"
  [[ -n "$section" ]] || { fail 'README rollback section is missing'; return 1; }

  assert_ordered_text "$section" \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck' \
    'sudo systemctl mask wg-healthcheck@wg0.timer' \
    'git switch --detach <known-good-commit>' \
    'sudo ./install.sh wg0' \
    'installer_rc=$?' \
    'sudo systemctl is-enabled wg-healthcheck@wg0.timer' \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl start wg-healthcheck@wg0.service' \
    'sudo cat /run/wg-healthcheck/wg0.status' \
    'sudo systemctl unmask wg-healthcheck@wg0.timer' \
    'sudo systemctl enable --now wg-healthcheck@wg0.timer' || return 1

  [[ "$section" == *"A legacy installer may unconditionally run \`enable --now\`."* ]] ||
    { fail 'rollback does not identify the legacy auto-enable hazard'; return 1; }
  [[ "$section" == *'Do not ignore a nonzero installer result.'* ]] ||
    { fail 'rollback permits blind installer-error suppression'; return 1; }
  [[ "$section" == *'Continue only if its output proves the only failure was the final masked-enable attempt.'* ]] ||
    { fail 'rollback does not bound the expected masked installer failure'; return 1; }
  [[ "$section" == *"Review the target revision's README, configuration template, and required files before running its service."* ]] ||
    { fail 'rollback omits target-revision configuration compatibility'; return 1; }
  [[ "$section" == *'The timer must remain masked throughout the one-shot validation.'* ]] ||
    fail 'rollback unmasks the timer before validation is complete'
}

test_readme_retired_credential_deletion_is_reference_gated() {
  local section delete_count
  section="$(read_readme_section '## Migrating an existing deployment' '## State and recovery transaction')"
  [[ -n "$section" ]] || { fail 'README migration section is missing'; return 1; }

  for expected in \
    "--exclude='airvpn-healthcheck.env'" \
    '/etc/systemd/system' \
    '/run/systemd/system' \
    '/usr/lib/systemd/system' \
    '/lib/systemd/system' \
    '/etc/wireguard' \
    '/usr/local'; do
    [[ "$section" == *"$expected"* ]] || {
      fail "credential reference scan omits: $expected"
      return 1
    }
  done

  # Literal README shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    'grep_rc=0' \
    'case "$grep_rc" in' \
    '0)' \
    'Still referenced; do not delete:' \
    '1)' \
    'sudo rm -f -- /etc/wireguard/airvpn-healthcheck.env' \
    '*)' \
    'Reference scan failed' \
    'esac' || return 1

  delete_count="$(grep -Fxc -- '    sudo rm -f -- /etc/wireguard/airvpn-healthcheck.env' <<<"$section")"
  [[ "$delete_count" == 1 ]] || fail 'credential deletion must appear exactly once in the no-reference branch'
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
  assert_file "$SECURITY_FILE" || return 1
  assert_file "$CONTRIBUTING_FILE" || return 1
  assert_file "$CHANGELOG_FILE" || return 1
  assert_file "$VERSION_FILE" || return 1
  assert_file "$RELEASE_NOTES_FILE" || return 1
  command cat -- \
    "$README_FILE" \
    "$SOURCE_CONFIG" \
    "$SECURITY_FILE" \
    "$CONTRIBUTING_FILE" \
    "$CHANGELOG_FILE" \
    "$VERSION_FILE" \
    "$RELEASE_NOTES_FILE" > "$combined_file" || return 1

  # Literal README shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  for required in \
    'not affiliated with or endorsed by AirVPN' \
    'DESTDIR="$stage" ./install.sh wg0' \
    '## Uninstall' \
    'complete uninstall' \
    'Active health-check instances remain; package removal stopped.' \
    'A pending recovery transaction exists; package removal stopped.' \
    '## Security' \
    '## Releases and versioning' \
    'airvpn-wg-healthcheck-${version}.tar.gz' \
    'SHA256SUMS' \
    'wg-healthcheck --version' \
    '## Support' \
    'No license is currently granted' \
    '| `1.0.x` | Yes |' \
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
    'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
    'persist-credentials: false'
    'uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0'
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
run_test existing_managed_file_owner_is_not_blessed test_existing_managed_file_owner_is_not_blessed
run_test systemctl_behavior_is_explicit_and_exact test_systemctl_behavior_is_explicit_and_exact
run_test staged_enable_never_calls_host_systemctl test_staged_enable_never_calls_host_systemctl
run_test safe_inert_environment_template test_safe_inert_environment_template
run_test installer_declares_exact_mode_contract test_installer_declares_exact_mode_contract
run_test authenticated_telemetry_and_command_hooks_are_retired test_authenticated_telemetry_and_command_hooks_are_retired
run_test service_environment_and_hardening_contract test_service_environment_and_hardening_contract
run_test readme_documents_safe_operator_lifecycle test_readme_documents_safe_operator_lifecycle
run_test readme_migration_quiesces_writers_before_pending_check test_readme_migration_quiesces_writers_before_pending_check
run_test readme_package_uninstall_quiesces_every_instance test_readme_package_uninstall_quiesces_every_instance
run_test readme_rollback_masks_legacy_auto_enable_until_validation test_readme_rollback_masks_legacy_auto_enable_until_validation
run_test readme_retired_credential_deletion_is_reference_gated test_readme_retired_credential_deletion_is_reference_gated
run_test python_bytecode_is_ignored test_python_bytecode_is_ignored
run_test repository_text_uses_lf_on_every_platform test_repository_text_uses_lf_on_every_platform
run_test public_repository_docs_are_sanitized_and_complete test_public_repository_docs_are_sanitized_and_complete
run_test ci_workflow_is_deterministic_and_smoke_isolated test_ci_workflow_is_deterministic_and_smoke_isolated

printf '\nInstaller tests: %d passed, %d skipped, %d failed\n' "$passes" "$skips" "$failures"
(( failures == 0 ))
