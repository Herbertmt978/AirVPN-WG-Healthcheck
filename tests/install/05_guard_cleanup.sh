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
