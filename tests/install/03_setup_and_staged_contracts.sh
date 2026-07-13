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
