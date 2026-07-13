#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

# wg-healthcheck test group 03; function bodies preserved from legacy suite.

test_rotation_disabled_speed_restart_and_failure_status() {
  local rc args status
  new_recovery_fixture
  AIRVPN_ROTATE_ENABLED=0
  restart_iface() {
    printf '%s\n' "$*" > "$TEST_TMP/restart-args"
    return 1
  }
  set +e
  rotate_airvpn confirmed_speed_failure 1
  rc=$?
  set +e
  args="$(<"$TEST_TMP/restart-args")"
  status="$(file_text "$STATUS_FILE")"
  assert_eq 1 "$rc" "rotation-disabled restart failure must propagate" || return 1
  assert_eq 'respect-cooldown 192.0.2.10:1637 true' "$args" "speed verification mode must reach rotation-disabled restart" || return 1
  assert_contains 'reason=restart_failed' "$status" "rotation-disabled failure needs precise status"
}
test_fixed_command_wrappers_pass_exact_argv() {
  local events
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  WG_DOWN_TIMEOUT=20
  WG_UP_TIMEOUT=30
  QBITTORRENT_RESTART_TIMEOUT=60
  QBITTORRENT_CONTAINER=qbittorrent
  timeout() { printf '%s\n' "$*" >> "$TEST_TMP/calls"; return 0; }

  run_wg_quick_down
  run_wg_quick_up
  restart_qbittorrent_container
  events="$(<"$TEST_TMP/calls")"

  assert_eq $'20 wg-quick down wg0\n30 wg-quick up wg0\n60 docker restart qbittorrent' "$events" "fixed wrappers must pass exact non-shell argv"
}
test_main_uses_root_seam_and_validates_both_files() {
  local rc calls
  new_main_fixture
  : > "$TEST_TMP/calls"
  is_root() { printf 'root\n' >> "$TEST_TMP/calls"; return 0; }
  validate_secure_file() {
    printf 'file:%s:%s:%s\n' "$1" "$2" "$3" >> "$TEST_TMP/calls"
    [[ "$1" == "$CFG" ]]
  }

  set +e
  main wg0
  rc=$?
  set +e
  calls="$(<"$TEST_TMP/calls")"

  assert_eq 1 "$rc" "failed WG_CONF validation must stop main" || return 1
  assert_contains 'root' "$calls" "main must use the root-check seam" || return 1
  assert_contains "file:${WG_CONF}:WireGuard configuration:600" "$calls" "main must validate WG_CONF" || return 1
  assert_contains "file:${CFG}:health-check configuration:600" "$calls" "main must validate CFG"
}
test_setup_guard_precedes_context_and_stale_context_is_never_loaded_on_contention() {
  local guard_fd captured_guard_fd captured_interface_fd expected_rc invocation rc events
  local -a argv=()
  new_main_fixture
  : > "$TEST_TMP/guard-order"
  acquire_runtime_guard() {
    printf 'guard\n' >> "$TEST_TMP/guard-order"
    exec {GUARD_FD}<>"$TEST_TMP/held-guard"
    guard_fd="$GUARD_FD"
    GUARD_LOCKED=1
  }
  load_command_context() {
    printf 'context\n' >> "$TEST_TMP/guard-order"
    return 1
  }

  set +e; main check wg0 >/dev/null 2>&1; rc=$?; set +e
  events="$(<"$TEST_TMP/guard-order")"
  assert_eq 1 "$rc" "context failure must remain visible after guard acquisition" || return 1
  assert_eq $'guard\ncontext' "$events" "setup guard must precede every configuration read" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$guard_fd" ]] ||
    fail "context failure must close the shared setup guard descriptor" || return 1
  assert_eq '' "$GUARD_FD" "context failure must clear guard ownership" || return 1

  for invocation in legacy explicit administrative; do
    new_main_fixture
    : > "$TEST_TMP/guard-order"
    acquire_runtime_guard() {
      printf 'guard-contended\n' >> "$TEST_TMP/guard-order"
      GUARD_LOCKED=0
      return 0
    }
    load_command_context() {
      printf 'stale-context-loaded\n' >> "$TEST_TMP/guard-order"
      return 1
    }
    case "$invocation" in
      legacy) argv=(wg0); expected_rc=0 ;;
      explicit) argv=(check wg0); expected_rc=75 ;;
      administrative) argv=(reset-api-state wg0 --dry-run); expected_rc=75 ;;
    esac
    set +e; main "${argv[@]}" >/dev/null 2>&1; rc=$?; set +e
    assert_eq "$expected_rc" "$rc" "$invocation guard contention must retain its command semantics" || return 1
    assert_file_equals guard-contended "$TEST_TMP/guard-order" \
      "$invocation guard contention must prevent stale configuration and all later locks" || return 1
  done

  new_main_fixture
  : > "$TEST_TMP/guard-order"
  acquire_runtime_guard() {
    printf 'guard\n' >> "$TEST_TMP/guard-order"
    exec {GUARD_FD}<>"$TEST_TMP/held-guard"
    captured_guard_fd="$GUARD_FD"
    GUARD_LOCKED=1
  }
  load_command_context() { printf 'context\n' >> "$TEST_TMP/guard-order"; }
  open_interface_lock() {
    local output_variable="${1:?}" opened_fd=''
    printf 'interface\n' >> "$TEST_TMP/guard-order"
    exec {opened_fd}<>"$TEST_TMP/held-interface"
    captured_interface_fd="$opened_fd"
    printf -v "$output_variable" '%s' "$opened_fd"
  }
  acquire_command_lock() { CONTEXT_LOCKED=1; }
  dispatch_command() { printf 'global-dispatch\n' >> "$TEST_TMP/guard-order"; return 42; }
  set +e; main reset-api-state wg0 --dry-run >/dev/null 2>&1; rc=$?; set +e
  assert_eq 42 "$rc" "dispatch failure must remain visible after all locks are acquired" || return 1
  assert_file_equals $'guard\ncontext\ninterface\nglobal-dispatch' "$TEST_TMP/guard-order" \
    "runtime lock order must remain guard then interface then managed global dispatch" || return 1
  for guard_fd in "$captured_guard_fd" "$captured_interface_fd"; do
    [[ ! -e "/proc/$BASHPID/fd/$guard_fd" ]] ||
      fail "dispatch error retained runtime lock descriptor $guard_fd" || return 1
  done
}
test_main_keeps_credential_private_during_pre_guard_context() {
  local credential_fd rc events
  new_main_fixture
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  exec {credential_fd}<"$TEST_TMP/credential"
  PROBE_FD="$credential_fd"
  events="$TEST_TMP/private-preflight.events"
  : > "$events"

  eval "$(declare -f derive_fixed_runtime_paths | sed \
    '1s/derive_fixed_runtime_paths/fixture_derive_fixed_runtime_paths/')"
  probe_private_preflight() {
    local stage="${1:?}"
    if bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD"; then
      printf 'closed:%s\n' "$stage" >> "$events"
    else
      printf 'leaked:%s\n' "$stage" >> "$events"
    fi
    return 0
  }
  derive_fixed_runtime_paths() {
    probe_private_preflight fixed-paths
    fixture_derive_fixed_runtime_paths
    SETUP_GUARD=
  }
  is_root() { probe_private_preflight root-check; }
  load_command_context() {
    probe_private_preflight context
    return 1
  }

  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" >/dev/null 2>&1
  rc=$?
  set +e
  events="$(<"$events")"
  assert_eq 1 "$rc" "context fixture must stop the private-FD preflight" || return 1
  assert_contains closed:fixed-paths "$events" \
    "fixed path derivation must not expose the credential to a child" || return 1
  assert_contains closed:root-check "$events" \
    "root validation must not expose the credential to a child" || return 1
  assert_contains closed:context "$events" \
    "guarded context loading must not expose the credential to a child" || return 1
  [[ "$events" != *leaked:* ]] || fail "no pre-provider stage may leak the credential descriptor"
}
test_setup_guard_is_private_nofollow_and_validates_exclusive_inherited_lease() {
  local guard_fd='' lease_fd='' other_fd='' rc victim
  source "$SCRIPT"
  command -v flock >/dev/null 2>&1 || return 0
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  STATE_DIR="$TEST_TMP/state"
  SETUP_GUARD="$STATE_DIR/wg0.setup-guard"
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  victim="$TEST_TMP/victim"
  printf 'do-not-truncate\n' > "$victim"
  ln -s -- "$victim" "$SETUP_GUARD"
  if (( EUID != 0 )); then
    setup_guard_metadata_matches() {
      local inspected_fd="${1:?}"
      [[ -f "$SETUP_GUARD" && ! -L "$SETUP_GUARD" &&
         -e "/proc/$BASHPID/fd/$inspected_fd" &&
         "/proc/$BASHPID/fd/$inspected_fd" -ef "$SETUP_GUARD" ]]
    }
  fi

  set +e; open_setup_guard guard_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "setup guard symlink must be rejected" || return 1
  assert_eq do-not-truncate "$(<"$victim")" "guard validation must never truncate a symlink target" || return 1

  rm -f -- "$SETUP_GUARD"
  open_setup_guard guard_fd || return 1
  assert_eq 600 "$(stat -c '%a' -- "$SETUP_GUARD")" "created setup guard must be mode 0600" || return 1
  if (( EUID == 0 )); then
    chmod 640 -- "$SETUP_GUARD"
    set +e; setup_guard_metadata_matches "$guard_fd" >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "guard metadata validation must reject a non-0600 inode" || return 1
    chmod 600 -- "$SETUP_GUARD"
    setup_guard_metadata_matches "$guard_fd" || return 1
    chown 1 -- "$SETUP_GUARD"
    set +e; setup_guard_metadata_matches "$guard_fd" >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "guard metadata validation must reject a non-root inode" || return 1
    chown 0 -- "$SETUP_GUARD"
    setup_guard_metadata_matches "$guard_fd" || return 1
  fi
  exec {guard_fd}>&-

  exec {lease_fd}<>"$SETUP_GUARD"
  command flock -n -x "$lease_fd" || return 1
  SETUP_LEASE_FD=
  CREDENTIAL_FD=
  SETTINGS_FD=
  GUARD_FD=
  GUARD_LOCKED=0
  acquire_runtime_guard || return 1
  assert_eq 0 "$GUARD_LOCKED" "ordinary shared acquisition must observe setup's exclusive lease" || return 1
  assert_eq '' "$GUARD_FD" "shared contention must close the losing guard descriptor" || return 1
  assert_eq 0 "${SETUP_LEASE_ADOPTED:-0}" \
    "ordinary shared acquisition must not authorize setup-only commands" || return 1
  SETUP_LEASE_FD="$lease_fd"
  acquire_runtime_guard || return 1
  assert_eq 1 "$GUARD_LOCKED" "validated inherited lease must retain exclusive ownership" || return 1
  assert_eq "$lease_fd" "$GUARD_FD" "runtime must reuse the exact inherited open file description" || return 1
  assert_eq '' "$SETUP_LEASE_FD" "validated lease ownership must transfer to guard cleanup" || return 1
  assert_eq 1 "${SETUP_LEASE_ADOPTED:-0}" \
    "only the validated inherited exclusive lease may authorize setup-only commands" || return 1
  cleanup_runtime_fds || return 1
  assert_eq 0 "${SETUP_LEASE_ADOPTED:-0}" \
    "guard cleanup must revoke setup-only command authorization" || return 1

  exec {lease_fd}<>"$SETUP_GUARD"
  SETUP_LEASE_FD="$lease_fd"
  set +e; acquire_runtime_guard >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an unlocked descriptor must never self-authorize as a setup lease" || return 1
  cleanup_runtime_fds || return 1

  printf 'other inode\n' > "$TEST_TMP/other"
  chmod 600 -- "$TEST_TMP/other"
  exec {other_fd}<>"$TEST_TMP/other"
  command flock -n -x "$other_fd" || return 1
  SETUP_LEASE_FD="$other_fd"
  set +e; acquire_runtime_guard >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "exclusive lease for a different inode must be rejected" || return 1
  cleanup_runtime_fds || return 1
}
test_setup_lease_validation_helpers_inherit_no_other_private_descriptors() {
  local credential_fd settings_fd lease_fd target_fd rc calls
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  STATE_DIR="$TEST_TMP/state"
  SETUP_GUARD="$STATE_DIR/wg0.setup-guard"
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  : > "$SETUP_GUARD"
  chmod 600 -- "$SETUP_GUARD"
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  printf 'settings sentinel\n' > "$TEST_TMP/settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  exec {lease_fd}<>"$SETUP_GUARD"
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  SETUP_LEASE_FD="$lease_fd"
  : > "$TEST_TMP/flock-calls"
  setup_guard_metadata_matches() {
    local inspected_fd="${1:?}"
    [[ "/proc/$BASHPID/fd/$inspected_fd" -ef "$SETUP_GUARD" ]]
  }
  flock() {
    target_fd="${!#}"
    if [[ -e "/proc/$BASHPID/fd/$credential_fd" ||
          -e "/proc/$BASHPID/fd/$settings_fd" ]]; then
      printf 'secret-fd-leak\n' >> "$TEST_TMP/flock-calls"
    fi
    if [[ "$2" == -s ]]; then
      [[ ! -e "/proc/$BASHPID/fd/$lease_fd" ]] || printf 'lease-fd-leak\n' >> "$TEST_TMP/flock-calls"
      printf 'probe\n' >> "$TEST_TMP/flock-calls"
      return 1
    fi
    printf 'lease\n' >> "$TEST_TMP/flock-calls"
    return 0
  }

  set +e; acquire_runtime_guard; rc=$?; set +e
  calls="$(<"$TEST_TMP/flock-calls")"
  assert_eq 0 "$rc" "exclusive validation fixture must succeed" || return 1
  assert_eq $'probe\nlease' "$calls" \
    "lease proof helpers must receive only their target descriptor" || return 1
  cleanup_runtime_fds || return 1
  for target_fd in "$credential_fd" "$settings_fd" "$lease_fd"; do
    [[ ! -e "/proc/$BASHPID/fd/$target_fd" ]] || fail "cleanup retained private descriptor $target_fd" || return 1
  done
}
test_main_lock_contention_is_nonblocking_and_side_effect_free() {
  local rc calls
  new_main_fixture
  : > "$TEST_TMP/calls"
  flock() { printf 'flock:%s\n' "$*" >> "$TEST_TMP/calls"; return 1; }
  fast_tunnel_health() { printf 'unexpected-health\n' >> "$TEST_TMP/calls"; return 0; }

  set +e
  main wg0
  rc=$?
  set +e
  calls="$(<"$TEST_TMP/calls")"

  assert_eq 0 "$rc" "lock contention must be benign" || return 1
  assert_contains 'flock:-n ' "$calls" "instance lock must be nonblocking" || return 1
  [[ "$calls" != *unexpected-* ]] || fail "lock contention must stop all health side effects" || return 1
  assert_file_absent "$STATUS_FILE" "lock loser must not overwrite owner status"
}
test_explicit_lock_contention_is_busy_and_closes_credential_descriptors() {
  local command
  for command in provision adopt rotate restore-static reset-api-state; do
    (
      local credential_fd='' leaked='' output rc read_rc
      local -a argv
      new_main_fixture
      : > "$TEST_TMP/events"
      flock() { return 1; }
      load_managed_module() { printf 'unexpected-dispatch\n' >> "$TEST_TMP/events"; return 1; }
      write_status() { printf 'unexpected-status\n' >> "$TEST_TMP/events"; return 1; }
      argv=("$command" wg0 --dry-run)
      if [[ "$command" == provision || "$command" == adopt ]]; then
        printf '%s\n' \
          'AIRVPN_DEVICE=Device-One' \
          'AIRVPN_COUNTRIES=GB' >> "$CFG"
        printf 'administrative-fd-sentinel\n' > "$TEST_TMP/credential"
        exec {credential_fd}<"$TEST_TMP/credential"
        argv+=(--credential-fd "$credential_fd")
      fi

      set +e
      main "${argv[@]}" > "$TEST_TMP/output" 2>&1
      rc=$?
      set +e
      output="$(file_text "$TEST_TMP/output")"
      assert_eq 75 "$rc" "$command lock contention must report temporary busy" || exit 1
      assert_eq '' "$output" "$command lock contention must not claim command success" || exit 1
      assert_file_equals '' "$TEST_TMP/events" "$command lock contention must not dispatch or write status" || exit 1
      if [[ -n "$credential_fd" ]]; then
        set +e
        IFS= read -r -u "$credential_fd" leaked 2>/dev/null
        read_rc=$?
        set +e
        assert_eq 1 "$read_rc" "$command lock contention must close the supplied credential descriptor" || exit 1
      fi
    ) || return 1
  done

  (
    local rc
    new_main_fixture
    flock() { return 1; }
    set +e; main wg0; rc=$?; set +e
    assert_eq 0 "$rc" "legacy timer lock contention must remain benign"
  ) || return 1

  (
    local credential_fd leaked='' rc read_rc
    new_main_fixture
    printf 'administrative-fd-sentinel\n' > "$TEST_TMP/credential"
    exec {credential_fd}<"$TEST_TMP/credential"
    is_root() { return 1; }
    set +e
    main provision wg0 --dry-run --credential-fd "$credential_fd" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 1 "$rc" "context failure must remain an error" || exit 1
    set +e
    IFS= read -r -u "$credential_fd" leaked 2>/dev/null
    read_rc=$?
    set +e
    assert_eq 1 "$read_rc" "context failure must close the supplied credential descriptor"
  ) || return 1

  (
    local credential_fd leaked='' rc read_rc
    source "$SCRIPT"
    TEST_TMP="$(mktemp -d)"
    trap "rm -rf -- '$TEST_TMP'" EXIT
    printf 'administrative-fd-sentinel\n' > "$TEST_TMP/credential"
    exec {credential_fd}<"$TEST_TMP/credential"
    set +e
    main provision wg0 --credential-fd "$credential_fd" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "CLI failure must retain its usage result" || exit 1
    set +e
    IFS= read -r -u "$credential_fd" leaked 2>/dev/null
    read_rc=$?
    set +e
    assert_eq 1 "$read_rc" "CLI failure must close a previously accepted credential descriptor"
  )
}
test_load_command_context_allows_profile_independent_commands_to_lack_profile() {
  local command rc
  source "$SCRIPT"
  declare -F load_command_context >/dev/null || fail "command-context loader is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  CFG="$TEST_TMP/wg0-health.conf"
  WG_CONF="$TEST_TMP/wg0.conf"
  STATE_DIR="$TEST_TMP/state"
  LOCK="$STATE_DIR/wg0.lock"
  printf '%s\n' \
    'AIRVPN_PROFILE_SOURCE=static' \
    'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  derive_fixed_runtime_paths() { :; }
  sanitize_process_environment() { :; }
  is_root() { return 0; }
  validate_secure_file() { [[ -f "$1" && ! -L "$1" ]]; }
  prepare_state_dir() { mkdir -p "$STATE_DIR" && chmod 700 -- "$STATE_DIR"; }
  owner_mode() {
    local mode
    mode="$(stat -c '%a' -- "$1")" || return 1
    printf '0:%s\n' "$mode"
  }
  flock() { return 0; }

  COMMAND=provision
  load_command_context || fail "provision alone must allow a genuinely missing profile" || return 1
  [[ -z "${LOCK_FD:-}" ]] || exec {LOCK_FD}>&-

  for command in check adopt rotate restore-static; do
    COMMAND="$command"
    set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$command must fail closed when the profile is missing" || return 1
  done

  COMMAND=status
  load_command_context || fail "observational status must allow a genuinely missing profile" || return 1
  COMMAND=reset-api-state
  load_command_context || fail "state reset must remain usable when the profile is missing" || return 1
  COMMAND=cleanup-candidate
  load_command_context || fail "setup-owned orphan cleanup must allow a genuinely missing profile" || return 1

  printf '%s\n' '[Interface]' '[Peer]' 'Endpoint = 192.0.2.1:1637' > "$WG_CONF"
  COMMAND=provision
  load_command_context || fail "provision context must securely validate an existing path before Task 8 refuses overwrite" || return 1
  [[ -z "${LOCK_FD:-}" ]] || exec {LOCK_FD}>&-
}
test_static_no_marker_never_touches_credential_provider_or_managed_code() {
  local rc calls
  new_main_fixture
  assert_eq 'MAX_AGE=180' "$(<"$CFG")" \
    "legacy static mode must remain valid without API device or country keys" || return 1
  : > "$TEST_TMP/boundary-calls"
  validate_secure_file() { printf 'file:%s\n' "$1" >> "$TEST_TMP/boundary-calls"; return 0; }
  validate_secure_executable() { printf 'provider:%s\n' "$1" >> "$TEST_TMP/boundary-calls"; return 1; }
  load_managed_module() { printf 'module:%s\n' "$MANAGED_MODULE" >> "$TEST_TMP/boundary-calls"; return 1; }
  open_installed_api_key() { printf 'credential:%s\n' "$AIRVPN_API_KEY_FILE" >> "$TEST_TMP/boundary-calls"; return 1; }
  fast_tunnel_health() { return 0; }
  ensure_qbittorrent_binding() { return 0; }
  write_status() { return 0; }

  set +e; main wg0; rc=$?; set +e
  calls="$(<"$TEST_TMP/boundary-calls")"
  assert_eq 0 "$rc" "healthy static mode must keep the legacy path" || return 1
  assert_eq $'file:'"$CFG"$'\nfile:'"$WG_CONF" "$calls" \
    "static/no-marker startup may validate only its configuration and profile"
}
test_static_selector_validates_provider_only_when_selection_is_needed() {
  local rc calls
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  : > "$TEST_TMP/calls"
  IFACE=wg0
  STATE_DIR="$TEST_TMP/state"
  AIRVPN_API_HELPER="$TEST_TMP/airvpn-api"
  AIRVPN_STATUS_URL='https://airvpn.org/api/status/?format=json'
  AIRVPN_COUNTRIES=GB
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  runtime_endpoint() { printf '192.0.2.1:1637\n'; }
  validate_secure_executable() { printf 'validate:%s\n' "$1" >> "$TEST_TMP/calls"; return 1; }
  log() { :; }

  set +e; select_airvpn_candidate >/dev/null 2>&1; rc=$?; set +e
  calls="$(<"$TEST_TMP/calls")"
  assert_eq 1 "$rc" "an untrusted selector helper must fail before execution" || return 1
  assert_eq "validate:$AIRVPN_API_HELPER" "$calls" "provider trust must be checked at the static selection boundary" || return 1

  : > "$TEST_TMP/calls"
  mkdir -p -- "$STATE_DIR"
  curl_egress() { printf 'curl\n' >> "$TEST_TMP/calls"; return 0; }
  set +e; verify_airvpn_egress >/dev/null 2>&1; rc=$?; set +e
  calls="$(<"$TEST_TMP/calls")"
  assert_eq 1 "$rc" "an untrusted egress helper must fail before execution" || return 1
  assert_eq "validate:$AIRVPN_API_HELPER" "$calls" \
    "egress verification must validate provider code before network or execution"
}
test_pending_marker_classification_loads_only_the_required_owner() {
  local events rc
  source "$SCRIPT"
  declare -F dispatch_command >/dev/null || fail "command dispatcher is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  WG_CONF="$TEST_TMP/wg0.conf"
  ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
  MANAGED_SAFETY="${WG_CONF}.safety-healthcheck"
  COMMAND=check
  validate_secure_file() { return 0; }
  run_healthcheck() { printf 'legacy\n' >> "$TEST_TMP/events"; }
  reconcile_pending_rotation() { printf 'builtin-v1\n' >> "$TEST_TMP/events"; RECONCILED_PENDING=1; }
  load_managed_module() {
    printf 'load-managed\n' >> "$TEST_TMP/events"
    managed_reconcile_pending() { printf 'managed-v2\n' >> "$TEST_TMP/events"; }
    managed_dispatch_command() { printf 'managed-dispatch:%s\n' "$1" >> "$TEST_TMP/events"; }
  }

  : > "$TEST_TMP/events"
  AIRVPN_PROFILE_SOURCE=static
  rm -f -- "$ROTATION_PENDING" "$MANAGED_SAFETY"
  dispatch_command || return 1
  assert_file_equals legacy "$TEST_TMP/events" "static/no-marker must remain pure legacy code" || return 1

  : > "$TEST_TMP/events"
  printf '%s\n' 'version=2' 'transaction=managed-profile' > "$ROTATION_PENDING"
  dispatch_command || return 1
  events="$(<"$TEST_TMP/events")"
  assert_eq $'load-managed\nmanaged-v2' "$events" \
    "static/v2 must load managed code solely for reconciliation" || return 1

  : > "$TEST_TMP/events"
  rm -f -- "$ROTATION_PENDING"
  printf 'invalid safety bytes\n' > "$MANAGED_SAFETY"
  dispatch_command || return 1
  events="$(<"$TEST_TMP/events")"
  assert_eq $'load-managed\nmanaged-v2' "$events" \
    "static/safety must load managed code solely for strict reconciliation" || return 1
  rm -f -- "$MANAGED_SAFETY"

  : > "$TEST_TMP/events"
  AIRVPN_PROFILE_SOURCE=static
  printf '192.0.2.1:1637\n' > "$ROTATION_PENDING"
  dispatch_command || return 1
  assert_file_equals builtin-v1 "$TEST_TMP/events" \
    "static/v1 must retain its recovery-only legacy behavior" || return 1

  : > "$TEST_TMP/events"
  AIRVPN_PROFILE_SOURCE=api
  printf '192.0.2.1:1637\n' > "$ROTATION_PENDING"
  dispatch_command || return 1
  events="$(<"$TEST_TMP/events")"
  assert_eq $'builtin-v1\nload-managed\nmanaged-dispatch:check' "$events" \
    "API/v1 must reconcile with the built-in owner before managed dispatch" || return 1

  : > "$TEST_TMP/events"
  printf '192.0.2.1:1637\n\n' > "$ROTATION_PENDING"
  dispatch_command || return 1
  assert_file_equals $'load-managed\nmanaged-v2' "$TEST_TMP/events" \
    "unknown pending data must reach the managed containment owner" || return 1

  : > "$TEST_TMP/events"
  rm -f -- "$ROTATION_PENDING"
  dispatch_command || return 1
  events="$(<"$TEST_TMP/events")"
  assert_eq $'load-managed\nmanaged-dispatch:check' "$events" \
    "API/no-marker must dispatch through the securely loaded managed owner"
}
test_v1_static_dispatch_reconciles_without_loading_managed_runtime() {
  local rc
  new_recovery_fixture
  seed_pending_rotation || return 1
  COMMAND=check
  AIRVPN_PROFILE_SOURCE=static
  validate_secure_file() { return 0; }
  run_wg_quick_up() { RUNTIME_ENDPOINT="$(configured_endpoint)"; }
  ensure_qbittorrent_binding() { printf 'qbit\n' >> "$TEST_EVENTS"; }
  load_managed_module() { printf 'unexpected-managed-load\n' >> "$TEST_EVENTS"; return 1; }

  set +e
  prepare_command_dispatch
  rc=$?
  set +e
  assert_eq 0 "$rc" "canonical v1 static marker must reconcile through the built-in owner" || return 1
  assert_eq 1 "$RECONCILED_PENDING" "v1 reconciliation must report completion" || return 1
  assert_file_absent "$ROTATION_PENDING" "v1 reconciliation must durably clear its marker" || return 1
  assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" \
    "v1 dispatch must restore the recorded backup endpoint" || return 1
  [[ "$(<"$TEST_EVENTS")" != *unexpected-managed-load* ]] ||
    fail "v1 static reconciliation must not load managed code"
}
test_main_propagates_route_rule_and_qbittorrent_failures() {
  local case_name rc reason
  for case_name in route rule qbit; do
    (
      new_main_fixture
      required_route_present() { [[ "$case_name" != route ]]; }
      required_rule_present() { [[ "$case_name" != rule ]]; }
      ensure_qbittorrent_binding() { [[ "$case_name" != qbit ]]; }
      rotate_airvpn() { printf '%s\n' "$1" > "$TEST_TMP/reason"; return 9; }
      set +e
      main wg0
      rc=$?
      set +e
      reason="$(file_text "$TEST_TMP/reason")"
      assert_eq 9 "$rc" "$case_name recovery failure must propagate" || exit 1
      case "$case_name" in
        route) assert_eq required_route_missing "$reason" "route reason must propagate" ;;
        rule) assert_eq required_rule_missing "$reason" "rule reason must propagate" ;;
        qbit) assert_eq qbittorrent_binding_failed "$reason" "qBittorrent reason must propagate" ;;
      esac
    ) || return 1
  done
}
test_main_rejects_invalid_speed_stamp() {
  local rc status
  new_main_fixture
  SPEED_CHECK_ENABLED=1
  printf 'SPEED_CHECK_ENABLED=1\n' >> "$CFG"
  fast_tunnel_health() { return 0; }
  printf 'broken\n' > "$SPEED_STAMP"
  set +e
  main wg0
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"
  assert_eq 1 "$rc" "invalid speed state must fail main" || return 1
  assert_contains 'reason=invalid_speed_stamp' "$status" "invalid speed state must be actionable"
}
test_restart_rejects_invalid_speed_mode_before_commands() {
  local rc
  new_recovery_fixture
  run_wg_quick_down() { printf 'unexpected-down\n' >> "$TEST_EVENTS"; }
  run_wg_quick_up() { printf 'unexpected-up\n' >> "$TEST_EVENTS"; }
  set +e
  restart_iface respect-cooldown '192.0.2.10:1637' sometimes
  rc=$?
  set +e
  assert_eq 1 "$rc" "restart speed mode must be a validated boolean" || return 1
  assert_eq "" "$(<"$TEST_EVENTS")" "invalid speed mode must prevent restart commands"
}
