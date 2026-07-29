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
