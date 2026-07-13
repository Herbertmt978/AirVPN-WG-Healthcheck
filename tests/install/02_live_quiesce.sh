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

test_upgrade_locks_migrate_only_safe_empty_legacy_mode() (
  local stage runtime rc holder ready attempt

  require_posix_modes || return $?
  stage="$(new_stage)" || return 1
  runtime="$stage/run/wg-healthcheck"
  mkdir -p -- "$runtime"
  chmod 0700 -- "$runtime"
  : >"$runtime/wg1.lock"
  chmod 0644 -- "$runtime/wg1.lock"

  # shellcheck source=install.sh
  source "$INSTALLER"
  IFACE=wg1
  DESTDIR="$stage"
  LIVE_INSTALL=1
  INSTALL_OWNER_ARGS=()
  initialize_paths
  systemctl_exec() {
    case "$1" in
      is-enabled) printf 'enabled\n'; return 0 ;;
      is-active) return 3 ;;
      list-units) return 0 ;;
      *) return 0 ;;
    esac
  }

  prepare_live_upgrade 0 wg1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'ordinary upgrade migrated a legacy lock'
    return 1
  }
  assert_mode 644 "$LIVE_INTERFACE_LOCK" || return 1

  prepare_live_upgrade 1 wg1 || {
    fail 'safe empty root-owned legacy lock was not migrated'
    return 1
  }
  assert_mode 600 "$LIVE_INTERFACE_LOCK" || return 1
  release_upgrade_locks || return 1

  printf 'nonempty\n' >"$LIVE_INTERFACE_LOCK"
  chmod 0644 -- "$LIVE_INTERFACE_LOCK"
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'nonempty legacy lock was migrated'
    return 1
  }

  : >"$LIVE_INTERFACE_LOCK"
  chmod 0664 -- "$LIVE_INTERFACE_LOCK"
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'legacy lock with an unapproved mode was migrated'
    return 1
  }

  : >"$LIVE_INTERFACE_LOCK"
  chmod 0644 -- "$LIVE_INTERFACE_LOCK"
  ready="$runtime/legacy-holder-ready"
  (
    exec 7<>"$LIVE_INTERFACE_LOCK"
    command flock -x 7
    : >"$ready"
    sleep 1
  ) &
  holder=$!
  for attempt in $(seq 1 100); do
    [[ -e "$ready" ]] && break
    sleep 0.01
  done
  [[ -e "$ready" ]] || {
    wait "$holder" || true
    fail 'legacy lock holder did not become ready'
    return 1
  }
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  wait "$holder" || true
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'held legacy lock was migrated'
    return 1
  }
  assert_mode 644 "$LIVE_INTERFACE_LOCK" || return 1

  ln -- "$LIVE_INTERFACE_LOCK" "$runtime/legacy-lock-alias"
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'multiply linked legacy lock was migrated'
    return 1
  }
  assert_mode 644 "$LIVE_INTERFACE_LOCK" || return 1

  rm -- "$runtime/legacy-lock-alias"
  chmod 0600 -- "$LIVE_INTERFACE_LOCK"
  : >"$runtime/wg2.lock"
  chmod 0644 -- "$runtime/wg2.lock"
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'quiesced selected-interface gate migrated another interface lock'
    return 1
  }
  assert_mode 644 "$runtime/wg2.lock" || return 1

  rm -- "$runtime/wg2.lock" "$LIVE_SETUP_GUARD"
  : >"$LIVE_SETUP_GUARD"
  chmod 0644 -- "$LIVE_SETUP_GUARD"
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'selected-interface gate migrated a legacy setup guard'
    return 1
  }
  assert_mode 644 "$LIVE_SETUP_GUARD" || return 1

  chmod 0600 -- "$LIVE_SETUP_GUARD"
  rm -- "$LIVE_INTERFACE_LOCK"
  : >"$runtime/legacy-symlink-target"
  chmod 0644 -- "$runtime/legacy-symlink-target"
  ln -s -- "$runtime/legacy-symlink-target" "$LIVE_INTERFACE_LOCK"
  acquire_upgrade_locks 1 >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 ]] || {
    release_upgrade_locks >/dev/null 2>&1 || true
    fail 'legacy lock symlink was migrated'
    return 1
  }
  assert_mode 644 "$runtime/legacy-symlink-target" || return 1

  if (( EUID == 0 )); then
    rm -- "$LIVE_INTERFACE_LOCK"
    : >"$LIVE_INTERFACE_LOCK"
    chmod 0644 -- "$LIVE_INTERFACE_LOCK"
    chown 65534 -- "$LIVE_INTERFACE_LOCK"
    acquire_upgrade_locks 1 >/dev/null 2>&1
    rc=$?
    [[ $rc -ne 0 ]] || {
      release_upgrade_locks >/dev/null 2>&1 || true
      fail 'wrong-owner legacy lock was migrated'
      return 1
    }
    [[ "$(stat -c '%u' -- "$LIVE_INTERFACE_LOCK")" == 65534 ]] ||
      fail 'wrong-owner legacy lock ownership changed'
  fi
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
