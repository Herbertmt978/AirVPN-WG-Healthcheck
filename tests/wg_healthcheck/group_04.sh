#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

# wg-healthcheck test group 04; function bodies preserved from legacy suite.

test_each_rotation_postcondition_failure_rolls_back() {
  local failure
  for failure in interface wg endpoint handshake route rule egress speed qbit; do
    (
      local rc status require_speed=0 up_phase=0
      new_recovery_fixture
      : > "$TEST_EVENTS"
      [[ "$failure" == speed ]] && require_speed=1
      run_wg_quick_down() { printf 'down:%s\n' "$up_phase" >> "$TEST_EVENTS"; }
      run_wg_quick_up() {
        up_phase=$((up_phase + 1))
        RUNTIME_ENDPOINT="$(configured_endpoint)"
        printf 'up:%s\n' "$up_phase" >> "$TEST_EVENTS"
      }
      interface_exists() { [[ "$up_phase" != 1 || "$failure" != interface ]]; }
      wireguard_responds() { [[ "$up_phase" != 1 || "$failure" != wg ]]; }
      runtime_endpoint() {
        if [[ "$up_phase" == 1 && "$failure" == endpoint ]]; then
          printf '203.0.113.99:1637\n'
        else
          printf '%s\n' "$RUNTIME_ENDPOINT"
        fi
      }
      handshake_age() {
        if [[ "$up_phase" == 1 && "$failure" == handshake ]]; then printf '181\n'; else printf '0\n'; fi
      }
      required_route_present() { [[ "$up_phase" != 1 || "$failure" != route ]]; }
      required_rule_present() { [[ "$up_phase" != 1 || "$failure" != rule ]]; }
      verify_airvpn_egress() { [[ "$up_phase" != 1 || "$failure" != egress ]]; }
      verify_post_rotation_speed() { [[ "$up_phase" != 1 || "$failure" != speed ]]; }
      ensure_qbittorrent_binding() {
        printf 'qbit:%s\n' "$up_phase" >> "$TEST_EVENTS"
        [[ "$up_phase" != 1 || "$failure" != qbit ]]
      }

      set +e
      rotate_airvpn "postcondition_${failure}" "$require_speed"
      rc=$?
      set +e
      status="$(file_text "$STATUS_FILE")"

      assert_eq 1 "$rc" "$failure postcondition failure must fail rotation" || exit 1
      assert_eq 2 "$up_phase" "$failure failure must force one rollback restart" || exit 1
      assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" "$failure rollback must restore old config" || exit 1
      assert_contains 'qbit:2' "$(<"$TEST_EVENTS")" "$failure rollback must verify qBittorrent" || exit 1
      assert_contains 'outcome=failed' "$status" "$failure rollback status must remain failed" || exit 1
      assert_file_absent "$ROTATE_STAMP" "$failure failure must not commit a rotation stamp" || exit 1
    ) || return 1
  done
}
test_pending_rotation_is_reconciled_before_health_checks() {
  local rc status
  new_recovery_fixture
  declare -F reconcile_pending_rotation >/dev/null || fail "pending reconciliation owner is missing" || return 1
  seed_pending_rotation || return 1
  run_wg_quick_up() { RUNTIME_ENDPOINT="$(configured_endpoint)"; }
  ensure_qbittorrent_binding() { printf 'qbit\n' >> "$TEST_EVENTS"; }

  set +e
  reconcile_pending_rotation
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"

  assert_eq 0 "$rc" "valid pending transaction must reconcile" || return 1
  assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" "reconciliation must restore the known-good config" || return 1
  assert_eq '192.0.2.10:1637' "$RUNTIME_ENDPOINT" "reconciliation must verify the old runtime endpoint" || return 1
  assert_contains qbit "$(<"$TEST_EVENTS")" "reconciliation must verify qBittorrent" || return 1
  assert_contains 'reason=pending_rotation_reconciled' "$status" "reconciliation status must be actionable" || return 1
  assert_file_absent "$ROTATION_PENDING" "verified reconciliation must remove the marker"
}
test_failed_pending_reconciliation_retains_marker() {
  local rc status
  new_recovery_fixture
  declare -F reconcile_pending_rotation >/dev/null || fail "pending reconciliation owner is missing" || return 1
  seed_pending_rotation || return 1
  run_wg_quick_up() { return 1; }

  set +e
  reconcile_pending_rotation
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"

  assert_eq 1 "$rc" "failed reconciliation must fail closed" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "failed reconciliation must retain its marker" || return 1
  assert_contains 'outcome=failed' "$status" "failed reconciliation must remain visible"
}
test_rollback_rotate_stamp_removal_failure_retains_pending_state() {
  local rc status
  new_recovery_fixture
  seed_pending_rotation || return 1
  printf '1000\n' > "$ROTATE_STAMP"
  rm() {
    if (( $# == 3 )) && [[ "$1" == -f && "$2" == -- && "$3" == "$ROTATE_STAMP" ]]; then
      return 1
    fi
    command rm "$@"
  }

  set +e
  rollback_rotation '192.0.2.10:1637' injected_failure
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"

  assert_eq 1 "$rc" "rollback must fail when its rotation stamp cannot be removed" || return 1
  assert_contains 'reason=rollback_rotation_stamp_cleanup_failed' "$status" "rollback stamp cleanup failure must be actionable" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "rollback stamp cleanup failure must retain the pending marker" || return 1
  [[ -f "$ROTATE_STAMP" ]] || fail "failed rotation stamp deletion must remain observable"
}
test_reconciliation_rotate_stamp_removal_failure_retains_pending_state() {
  local rc status
  new_recovery_fixture
  seed_pending_rotation || return 1
  printf '1000\n' > "$ROTATE_STAMP"
  rm() {
    if (( $# == 3 )) && [[ "$1" == -f && "$2" == -- && "$3" == "$ROTATE_STAMP" ]]; then
      return 1
    fi
    command rm "$@"
  }

  set +e
  reconcile_pending_rotation
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"

  assert_eq 1 "$rc" "startup reconciliation must fail when its rotation stamp cannot be removed" || return 1
  assert_contains 'reason=pending_rotation_stamp_cleanup_failed' "$status" "reconciliation stamp cleanup failure must be actionable" || return 1
  assert_eq 0 "$RECONCILED_PENDING" "failed stamp cleanup must not report reconciliation complete" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "reconciliation stamp cleanup failure must retain the pending marker" || return 1
  [[ -f "$ROTATE_STAMP" ]] || fail "failed rotation stamp deletion must remain observable"
}
test_pending_marker_prevents_backup_overwrite() {
  local before rc
  new_recovery_fixture
  seed_pending_rotation || return 1
  before="$(<"${WG_CONF}.bak-healthcheck")"

  set +e
  backup_config
  rc=$?
  set +e

  assert_eq 1 "$rc" "backup must not be replaced while a transaction marker exists" || return 1
  assert_file_equals "$before" "${WG_CONF}.bak-healthcheck" "pending transaction must retain the original recovery target"
}
test_main_reconciles_pending_state_before_normal_health() {
  local rc calls
  new_main_fixture
  : > "$TEST_TMP/calls"
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"
  reconcile_pending_rotation() { printf 'reconcile\n' >> "$TEST_TMP/calls"; return 1; }
  fast_tunnel_health() { printf 'unexpected-health\n' >> "$TEST_TMP/calls"; return 0; }

  set +e
  main wg0
  rc=$?
  set +e
  calls="$(<"$TEST_TMP/calls")"

  assert_eq 1 "$rc" "failed startup reconciliation must stop main" || return 1
  assert_contains reconcile "$calls" "main must reconcile after locking" || return 1
  [[ "$calls" != *unexpected-health* ]] || fail "main must not run health checks with a pending transaction"
}
test_interruption_handler_retains_marker_and_installs_traps() {
  local traps
  new_recovery_fixture
  declare -F record_rotation_interruption >/dev/null || fail "interruption recorder is missing" || return 1
  declare -F install_signal_handlers >/dev/null || fail "signal handler installer is missing" || return 1
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"

  record_rotation_interruption TERM
  install_signal_handlers
  traps="$(trap -p TERM HUP INT)"

  [[ -f "$ROTATION_PENDING" ]] || fail "interruption must retain the transaction marker" || return 1
  assert_file_absent "$STATUS_FILE" "the child-free signal path must not attempt a status write" || return 1
  assert_contains record_rotation_interruption "$traps" "TERM/HUP/INT traps must use the interruption recorder"
}
test_interruption_handler_is_child_free_with_untracked_private_descriptors() {
  local credential_fd settings_fd setup_fd guard_fd interface_fd key_fd candidate_fd tracked_fd
  new_recovery_fixture
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  printf 'settings sentinel\n' > "$TEST_TMP/settings"
  printf 'credential duplicate sentinel\n' > "$TEST_TMP/key-duplicate"
  printf 'private profile sentinel\n' > "$TEST_TMP/candidate"
  printf 'setup lease sentinel\n' > "$TEST_TMP/setup-lease"
  printf 'guard sentinel\n' > "$TEST_TMP/guard"
  printf 'interface lock sentinel\n' > "$TEST_TMP/interface-lock"
  : > "$TEST_TMP/private-fd-leak"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  exec {key_fd}<"$TEST_TMP/key-duplicate"
  exec {candidate_fd}<"$TEST_TMP/candidate"
  exec {setup_fd}<>"$TEST_TMP/setup-lease"
  exec {guard_fd}<>"$TEST_TMP/guard"
  exec {interface_fd}<>"$TEST_TMP/interface-lock"
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  SETUP_LEASE_FD="$setup_fd"
  GUARD_FD="$guard_fd"
  GUARD_LOCKED=1
  LOCK_FD="$interface_fd"
  CONTEXT_LOCKED=1
  write_status() {
    (
      if [[ -e "/proc/$BASHPID/fd/$credential_fd" ||
            -e "/proc/$BASHPID/fd/$settings_fd" ||
            -e "/proc/$BASHPID/fd/$key_fd" ||
            -e "/proc/$BASHPID/fd/$candidate_fd" ]]; then
        printf 'private descriptor inherited\n' >> "$TEST_TMP/private-fd-leak"
      fi
      printf 'status helper called\n' >> "$TEST_TMP/private-fd-leak"
    )
  }

  record_rotation_interruption TERM

  assert_eq '' "$(<"$TEST_TMP/private-fd-leak")" \
    "signal handling must launch no helper while any private descriptor can exist" || return 1
  assert_eq '' "$CREDENTIAL_FD" "signal handling must clear the credential descriptor owner" || return 1
  assert_eq '' "$SETTINGS_FD" "signal handling must clear the settings descriptor owner" || return 1
  assert_eq '' "$SETUP_LEASE_FD" "signal handling must clear an unadopted setup descriptor" || return 1
  assert_eq '' "$GUARD_FD" "signal handling must clear the active setup guard owner" || return 1
  assert_eq '' "$LOCK_FD" "signal handling must clear the interface lock owner" || return 1
  assert_eq 0 "$GUARD_LOCKED" "signal handling must clear setup guard state" || return 1
  assert_eq 0 "$CONTEXT_LOCKED" "signal handling must clear interface lock state" || return 1
  for tracked_fd in "$credential_fd" "$settings_fd" "$setup_fd" "$guard_fd" "$interface_fd"; do
    [[ ! -e "/proc/$BASHPID/fd/$tracked_fd" ]] ||
      fail "signal handling retained tracked descriptor $tracked_fd" || return 1
  done
  exec {key_fd}<&-
  exec {candidate_fd}<&-
}
test_durability_barriers_cover_transaction_and_cleanup_order() {
  local backup expected actual
  new_recovery_fixture
  backup="${WG_CONF}.bak-healthcheck"

  begin_rotation_transaction '192.0.2.10:1637' || return 1
  set_config_endpoint '198.51.100.20:1637' || return 1
  remove_rotation_pending || return 1

  expected=$'sync\t-f\t--\t'"$backup"$'\n'
  expected+=$'sync\t-f\t--\t'"$TEST_TMP"$'\n'
  expected+=$'sync\t-f\t--\t'"$ROTATION_PENDING"$'\n'
  expected+=$'sync\t-f\t--\t'"$TEST_TMP"$'\n'
  expected+=$'sync\t-f\t--\t'"$WG_CONF"$'\n'
  expected+=$'sync\t-f\t--\t'"$TEST_TMP"$'\n'
  expected+=$'sync\t-f\t--\t'"$TEST_TMP"
  actual="$(<"$TEST_SYNC_EVENTS")"

  assert_eq "$expected" "$actual" "backup, marker, config, and marker removal must have exact ordered sync barriers" || return 1
  assert_contains 'Endpoint = 192.0.2.10:1637' "$(<"$backup")" "durable backup must contain the old endpoint" || return 1
  assert_eq 'Endpoint = 198.51.100.20:1637' "$(config_endpoint_line)" "config mutation must complete after its marker is durable" || return 1
  assert_file_absent "$ROTATION_PENDING" "durable cleanup must remove the marker"
}
test_backup_barrier_failure_prevents_unmarked_mutation() {
  local before rc backup
  new_recovery_fixture
  before="$(<"$WG_CONF")"
  backup="${WG_CONF}.bak-healthcheck"
  SYNC_FAIL_TARGET="$backup"
  SYNC_FAILURES_REMAINING=1

  set +e
  rotate_airvpn backup_barrier_failure
  rc=$?
  set +e

  assert_eq 1 "$rc" "backup barrier failure must fail rotation" || return 1
  assert_file_equals "$before" "$WG_CONF" "backup barrier failure must not mutate an unmarked config" || return 1
  assert_file_absent "$ROTATION_PENDING" "backup barrier failure must not create a transaction marker" || return 1
  [[ -f "$backup" ]] || fail "completed backup rename may remain as the next bounded backup target"
}
test_marker_barrier_failure_retains_recovery_state() {
  local before rc pending
  new_recovery_fixture
  before="$(<"$WG_CONF")"
  SYNC_FAIL_TARGET="$ROTATION_PENDING"
  SYNC_FAILURES_REMAINING=1

  set +e
  rotate_airvpn marker_barrier_failure
  rc=$?
  set +e
  pending="$(read_rotation_pending)" || return 1

  assert_eq 1 "$rc" "marker barrier failure must fail rotation" || return 1
  assert_file_equals "$before" "$WG_CONF" "marker barrier failure must not mutate config" || return 1
  assert_eq '192.0.2.10:1637' "$pending" "marker barrier failure must retain deterministic recovery state" || return 1
  [[ -f "${WG_CONF}.bak-healthcheck" ]] || fail "marker barrier failure must retain its known-good backup"
}
test_config_barrier_failure_performs_verified_rollback() {
  local rc up_calls=0 qbit_checks=0
  new_recovery_fixture
  SYNC_FAIL_TARGET="$WG_CONF"
  SYNC_FAILURES_REMAINING=1
  run_wg_quick_up() {
    up_calls=$((up_calls + 1))
    RUNTIME_ENDPOINT="$(configured_endpoint)"
  }
  ensure_qbittorrent_binding() { qbit_checks=$((qbit_checks + 1)); }

  set +e
  rotate_airvpn config_barrier_failure
  rc=$?
  set +e

  assert_eq 1 "$rc" "config barrier failure must fail rotation" || return 1
  assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" "config barrier failure must restore the durable backup" || return 1
  assert_eq '192.0.2.10:1637' "$RUNTIME_ENDPOINT" "config barrier failure must verify the restored runtime endpoint" || return 1
  assert_eq 1 "$up_calls" "config barrier failure must perform one forced rollback restart" || return 1
  assert_eq 1 "$qbit_checks" "config barrier failure must verify qBittorrent after rollback" || return 1
  assert_file_absent "$ROTATION_PENDING" "verified rollback may safely clear the marker"
}
test_marker_cleanup_barrier_failure_recreates_recovery_marker() {
  local rc status
  new_recovery_fixture
  SYNC_FAIL_TARGET="$TEST_TMP"
  SYNC_MATCHES_TO_SKIP=3
  SYNC_FAILURES_REMAINING=1

  set +e
  rotate_airvpn cleanup_barrier_failure
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"

  assert_eq 1 "$rc" "marker cleanup barrier failure must remain observable" || return 1
  assert_contains 'reason=rotation_marker_cleanup_failed' "$status" "cleanup barrier failure must be actionable" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "failed durable cleanup must recreate the recovery marker" || return 1

  SYNC_FAIL_TARGET=
  reconcile_pending_rotation || return 1
  assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" "startup reconciliation must recover after cleanup barrier failure" || return 1
  assert_file_absent "$ROTATION_PENDING" "verified reconciliation must durably remove the recreated marker"
}
test_secure_helper_and_parent_validation() {
  local case_name rc
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  AIRVPN_API_HELPER="$TEST_TMP/helper-dir/airvpn-api"
  mkdir -p "${AIRVPN_API_HELPER%/*}"
  printf '#!/bin/sh\n' > "$AIRVPN_API_HELPER"
  declare -F validate_secure_executable >/dev/null || fail "secure executable validator is missing" || return 1

  for case_name in secure symlink parent_symlink ancestor_symlink wrong_owner wrong_mode \
      parent_owner parent_writable ancestor_owner ancestor_writable ancestor_sticky; do
    path_is_regular() { return 0; }
    path_is_directory() { return 0; }
    path_is_symlink() {
      [[ "$case_name" == symlink && "$1" == "$AIRVPN_API_HELPER" ]] ||
        [[ "$case_name" == parent_symlink && "$1" == "${AIRVPN_API_HELPER%/*}" ]] ||
        [[ "$case_name" == ancestor_symlink && "$1" == "$TEST_TMP" ]]
    }
    owner_mode() {
      if [[ "$1" == "$AIRVPN_API_HELPER" ]]; then
        case "$case_name" in
          wrong_owner) printf '1000:755\n' ;;
          wrong_mode) printf '0:775\n' ;;
          *) printf '0:755\n' ;;
        esac
      elif [[ "$1" == "${AIRVPN_API_HELPER%/*}" ]]; then
        case "$case_name" in
          parent_owner) printf '1000:755\n' ;;
          parent_writable) printf '0:777\n' ;;
          *) printf '0:755\n' ;;
        esac
      elif [[ "$1" == "$TEST_TMP" ]]; then
        case "$case_name" in
          ancestor_owner) printf '1000:700\n' ;;
          ancestor_writable) printf '0:777\n' ;;
          ancestor_sticky) printf '0:1777\n' ;;
          *) printf '0:700\n' ;;
        esac
      else
        printf '0:755\n'
      fi
    }
    set +e
    validate_secure_executable "$AIRVPN_API_HELPER"
    rc=$?
    set +e
    if [[ "$case_name" == secure || "$case_name" == ancestor_sticky ]]; then
      assert_eq 0 "$rc" "secure helper must pass" || return 1
    else
      assert_eq 1 "$rc" "$case_name helper boundary must fail" || return 1
    fi
  done
}
test_static_settings_do_not_touch_provider_helper() {
  local rc calls
  new_recovery_fixture
  : > "$TEST_TMP/calls"
  AIRVPN_PROFILE_SOURCE=static
  validate_secure_executable() { printf '%s\n' "$1" >> "$TEST_TMP/calls"; return 1; }
  AIRVPN_API_HELPER="$TEST_TMP/airvpn-api"

  set +e
  validate_settings
  rc=$?
  set +e
  calls="$(file_text "$TEST_TMP/calls")"

  assert_eq 0 "$rc" "static settings must remain independent of provider installation" || return 1
  assert_eq '' "$calls" "static settings must not stat provider code"
}
test_route_and_rule_checks_consume_large_producer_output() {
  local index
  source "$SCRIPT"
  IFACE=wg0
  REQUIRED_ROUTE='required-route-marker'
  REQUIRED_RULE='required-rule-marker'
  ip() {
    if [[ "$1" == route ]]; then printf '%s\n' "$REQUIRED_ROUTE"; else printf '%s\n' "$REQUIRED_RULE"; fi
    for ((index=0; index<20000; index++)); do printf 'padding-%05d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$index"; done
  }
  set -o pipefail

  required_route_present || fail "large route output with an early match must succeed" || return 1
  required_rule_present || fail "large rule output with an early match must succeed"
}
test_canonical_endpoint_equivalence_is_used_everywhere() {
  local canonical rc
  new_recovery_fixture
  if [[ "$(uname -s)" == MINGW* ]]; then python3() { command python "$@"; }; fi
  declare -F canonicalize_endpoint >/dev/null || fail "endpoint canonicalizer is missing" || return 1

  canonical="$(canonicalize_endpoint '[2001:0db8:0:0::1]:51820')"
  assert_eq '[2001:db8::1]:51820' "$canonical" "IPv6 endpoint must use compressed canonical form" || return 1
  runtime_endpoint() { printf '[2001:db8::1]:51820\n'; }
  set +e
  verify_tunnel '[2001:0db8:0:0::1]:51820'
  rc=$?
  set +e
  assert_eq 0 "$rc" "equivalent IPv6 endpoint representations must verify" || return 1

  parse_candidate $'Candidate\t[2001:0db8:0:0::1]:51820\tGB\tLondon\t10000\t10\t20' || return 1
  assert_eq '[2001:db8::1]:51820' "$CANDIDATE_ENDPOINT" "candidate endpoint must be canonical"
}
test_qbittorrent_binding_requires_tcp_udp_process_and_container_pid() {
  local rc tcp udp multi_tcp_first multi_udp_first multi_tcp_last multi_udp_last false_tcp false_udp
  source "$SCRIPT"
  IFACE=wg0
  QBITTORRENT_LISTEN_IP=10.0.0.2
  QBITTORRENT_LISTEN_PORT=13342
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_CONTAINER=
  log() { :; }
  tcp='tcp LISTEN 0 4096 10.0.0.2%wg0:13342 0.0.0.0:* users:(("qbittorrent-nox",pid=1234,fd=20))'
  udp='udp UNCONN 0 0 10.0.0.2%wg0:13342 0.0.0.0:* users:(("qbittorrent-nox",pid=1234,fd=21))'
  timeout() { shift; "$@"; }
  docker() { printf 'PID COMMAND\n%s qbittorrent-nox\n' "${DOCKER_PID:-1234}"; }
  ss() { printf '%s\n' "$SS_OUTPUT"; }

  SS_OUTPUT="$tcp"$'\n'"$udp"
  qbittorrent_binding_present || fail "matching TCP+UDP qBittorrent sockets must pass" || return 1
  for SS_OUTPUT in "$tcp" "$udp" "${tcp//qbittorrent-nox/other-process}"$'\n'"${udp//qbittorrent-nox/other-process}"; do
    set +e; qbittorrent_binding_present; rc=$?; set +e
    assert_eq 1 "$rc" "partial or unrelated socket ownership must fail" || return 1
  done

  multi_tcp_first='tcp LISTEN 0 4096 10.0.0.2%wg0:13342 0.0.0.0:* users:(("unrelated",pid=7001,fd=9),("qbittorrent-nox",pid=1234,fd=20))'
  multi_udp_first='udp UNCONN 0 0 10.0.0.2%wg0:13342 0.0.0.0:* users:(("unrelated",pid=7002,fd=10),("qbittorrent-nox",pid=1234,fd=21))'
  multi_tcp_last='tcp LISTEN 0 4096 10.0.0.2%wg0:13342 0.0.0.0:* users:(("qbittorrent-nox",pid=1234,fd=20),("unrelated",pid=7001,fd=9))'
  multi_udp_last='udp UNCONN 0 0 10.0.0.2%wg0:13342 0.0.0.0:* users:(("qbittorrent-nox",pid=1234,fd=21),("unrelated",pid=7002,fd=10))'
  for SS_OUTPUT in "$multi_tcp_first"$'\n'"$multi_udp_first" "$multi_tcp_last"$'\n'"$multi_udp_last"; do
    qbittorrent_binding_present || fail "matching qBittorrent owner pairs must pass regardless of owner order" || return 1
  done

  false_tcp='tcp LISTEN 0 4096 10.0.0.2%wg0:13342 0.0.0.0:* users:(("unrelated",pid=9000,fd=9),("qbittorrent-nox",pid=1111,fd=20))'
  false_udp='udp UNCONN 0 0 10.0.0.2%wg0:13342 0.0.0.0:* users:(("unrelated",pid=9000,fd=10),("qbittorrent-nox",pid=2222,fd=21))'
  SS_OUTPUT="$false_tcp"$'\n'"$false_udp"
  set +e; qbittorrent_binding_present; rc=$?; set +e
  assert_eq 1 "$rc" "an unrelated shared PID must not hide different qBittorrent TCP and UDP PIDs" || return 1

  QBITTORRENT_CONTAINER=qbittorrent
  SS_OUTPUT="$multi_tcp_first"$'\n'"$multi_udp_first"
  DOCKER_PID=1234
  qbittorrent_binding_present || fail "container PID matching the exact qBittorrent owner pair must pass" || return 1
  DOCKER_PID=9000
  SS_OUTPUT="$false_tcp"$'\n'"$false_udp"
  set +e; qbittorrent_binding_present; rc=$?; set +e
  assert_eq 1 "$rc" "an unrelated container PID must not be attributed to qBittorrent" || return 1
  DOCKER_PID=9999
  SS_OUTPUT="$tcp"$'\n'"$udp"
  set +e; qbittorrent_binding_present; rc=$?; set +e
  assert_eq 1 "$rc" "correct process name with wrong container PID must fail" || return 1

  validate_secure_executable() { return 0; }
  QBITTORRENT_PROCESS_NAME='bad/name'
  AIRVPN_API_HELPER="$ROOT/libexec/airvpn-api"
  set +e; validate_settings; rc=$?; set +e
  assert_eq 1 "$rc" "invalid process name configuration must fail"
}
test_https_curl_policy_and_egress_cleanup() {
  local rc args residue speed
  new_recovery_fixture
  source "$SCRIPT"
  IFACE=wg0
  STATE_DIR="$TEST_TMP/state"
  log() { :; }
  validate_secure_executable() { return 0; }
  set +e; validate_url TEST_URL 'http://example.test/file'; rc=$?; set +e
  assert_eq 1 "$rc" "HTTP URL must be rejected" || return 1

  : > "$TEST_TMP/curl-events"
  curl_egress() { printf 'egress:%s\n' "$*" >> "$TEST_TMP/curl-events"; return 143; }
  curl() { printf 'raw:%s\n' "$*" >> "$TEST_TMP/curl-events"; return 1; }
  set +e; verify_airvpn_egress; rc=$?; set +e
  assert_eq 1 "$rc" "signal-like egress failure must propagate" || return 1
  args="$(<"$TEST_TMP/curl-events")"
  assert_contains 'egress:' "$args" "egress must use its scoped curl seam" || return 1
  [[ "$args" != *raw:* ]] || fail "egress must not bypass its scoped curl seam" || return 1
  residue="$(find "$STATE_DIR" -maxdepth 1 -type f -name '.egress.*' | wc -l | tr -d ' ')"
  assert_eq 0 "$residue" "egress temporary file must be cleaned on failure" || return 1

  source "$SCRIPT"
  IFACE=wg0
  : > "$TEST_TMP/curl-events"
  curl() { printf '%s\n' "$*" > "$TEST_TMP/curl-events"; return 1; }
  set +e; curl_egress "$TEST_TMP/egress.json"; rc=$?; set +e
  args="$(<"$TEST_TMP/curl-events")"
  assert_eq 1 "$rc" "egress curl fixture must fail" || return 1
  [[ "$args" == '--disable '* ]] || fail "egress curl must disable curlrc as its first option" || return 1
  assert_contains '--proto =https' "$args" "egress curl must restrict initial protocol" || return 1
  assert_contains '--proto-redir =https' "$args" "egress redirects must remain HTTPS" || return 1
  assert_contains '--max-redirs 3' "$args" "egress redirects must be bounded" || return 1

  : > "$TEST_TMP/curl-events"
  curl() { printf '%s\n' "$*" > "$TEST_TMP/curl-events"; printf '200\t3000000'; }
  speed="$(measure_speed)"
  assert_eq 3000000 "$speed" "HTTPS speed fixture must parse" || return 1
  args="$(<"$TEST_TMP/curl-events")"
  [[ "$args" == '--disable '* ]] || fail "speed curl must disable curlrc as its first option" || return 1
  assert_contains '--proto =https' "$args" "speed curl must restrict initial protocol" || return 1
  assert_contains '--proto-redir =https' "$args" "speed redirects must remain HTTPS" || return 1
  assert_contains '--max-redirs 3' "$args" "speed redirects must be bounded"
}
test_speed_failure_reason_is_truthful() {
  local call=0 reason
  new_recovery_fixture
  measure_speed() {
    call=$((call + 1))
    if (( call == 1 )); then return 1; fi
    printf '1000000\n'
  }
  rotate_airvpn() { printf '%s\n' "$1" > "$TEST_TMP/reason"; }
  speed_check
  reason="$(<"$TEST_TMP/reason")"
  assert_eq confirmed_speed_unhealthy "$reason" "transport failure must not be described as measured slowness" || return 1

  call=0
  measure_speed() { call=$((call + 1)); printf '1000000\n'; }
  speed_check
  reason="$(<"$TEST_TMP/reason")"
  assert_eq "confirmed_speed_below_${SPEED_MIN_BPS}_Bps" "$reason" "two measured-slow probes should retain the threshold reason"
}
test_selector_failures_use_one_protective_restart_owner() {
  local rc status
  new_recovery_fixture
  declare -F protective_restart_degraded >/dev/null || fail "selector protective-restart owner is missing" || return 1
  restart_iface() { return 0; }
  set +e
  protective_restart_degraded selector_failed '192.0.2.10:1637'
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"
  assert_eq 2 "$rc" "successful protective restart must remain degraded" || return 1
  assert_contains 'reason=selector_failed' "$status" "shared protective owner must write its reason"
}
test_timer_health_speed_and_qb_failures_dispatch_managed_rotation_in_api_mode() {
  local events
  new_recovery_fixture
  AIRVPN_PROFILE_SOURCE=api
  AIRVPN_ROTATE_ENABLED=1
  : > "$TEST_TMP/dispatch-events"
  managed_rotate_profile() {
    printf 'managed:%s:%s\n' "$1" "$2" >> "$TEST_TMP/dispatch-events"
  }
  rotate_static_endpoint() {
    printf 'static:%s:%s\n' "$1" "$2" >> "$TEST_TMP/dispatch-events"
    return 1
  }
  configured_endpoint() { printf '192.0.2.10:1637\n'; }
  fast_tunnel_health() { HEALTH_REASON=handshake_stale; return 1; }
  run_healthcheck || return 1

  fast_tunnel_health() { return 0; }
  SPEED_CHECK_ENABLED=1
  cooldown_allows() { return 0; }
  write_stamp() { return 0; }
  measure_speed() { return 1; }
  ensure_qbittorrent_binding() { return 0; }
  run_healthcheck || return 1

  SPEED_CHECK_ENABLED=0
  ensure_qbittorrent_binding() { return 1; }
  run_healthcheck || return 1
  events="$(<"$TEST_TMP/dispatch-events")"
  assert_eq $'managed:handshake_stale:0\nmanaged:confirmed_speed_unhealthy:1\nmanaged:qbittorrent_binding_failed:0' \
    "$events" "all timer recovery call sites must use managed rotation in API mode" || return 1
  [[ "$events" != *static:* ]] ||
    fail "API-managed recovery must never fall back to endpoint-only mutation"
}
test_timer_failures_keep_static_endpoint_dispatch_in_static_mode() {
  local events
  new_recovery_fixture
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_ROTATE_ENABLED=1
  : > "$TEST_TMP/dispatch-events"
  managed_rotate_profile() {
    printf 'managed:%s:%s\n' "$1" "$2" >> "$TEST_TMP/dispatch-events"
    return 1
  }
  rotate_static_endpoint() {
    printf 'static:%s:%s\n' "$1" "$2" >> "$TEST_TMP/dispatch-events"
  }
  configured_endpoint() { printf '192.0.2.10:1637\n'; }
  fast_tunnel_health() { HEALTH_REASON=handshake_stale; return 1; }
  run_healthcheck || return 1
  fast_tunnel_health() { return 0; }
  SPEED_CHECK_ENABLED=0
  ensure_qbittorrent_binding() { return 1; }
  run_healthcheck || return 1
  events="$(<"$TEST_TMP/dispatch-events")"
  assert_eq $'static:handshake_stale:0\nstatic:qbittorrent_binding_failed:0' "$events" \
    "static timer failures must retain the endpoint-only owner" || return 1
  [[ "$events" != *managed:* ]] || fail "static mode must never enter managed rotation"
}
test_api_rotation_disabled_is_restart_only_and_managed_failure_never_falls_through() {
  local rc events
  new_recovery_fixture
  AIRVPN_PROFILE_SOURCE=api
  : > "$TEST_TMP/dispatch-events"
  managed_rotate_profile() { printf 'managed\n' >> "$TEST_TMP/dispatch-events"; return 5; }
  rotate_static_endpoint() { printf 'static:%s:%s\n' "$1" "$2" >> "$TEST_TMP/dispatch-events"; }

  AIRVPN_ROTATE_ENABLED=0
  rotate_airvpn health_failed 0 || return 1
  events="$(<"$TEST_TMP/dispatch-events")"
  assert_eq 'static:health_failed:0' "$events" \
    "API mode with rotation disabled must use restart-only recovery without credentials" || return 1

  : > "$TEST_TMP/dispatch-events"
  AIRVPN_ROTATE_ENABLED=1
  set +e; rotate_airvpn health_failed 0; rc=$?; set +e
  assert_eq 5 "$rc" "managed provider failures must propagate exactly" || return 1
  assert_eq managed "$(<"$TEST_TMP/dispatch-events")" \
    "managed failure must never fall through to static endpoint mutation"
}
