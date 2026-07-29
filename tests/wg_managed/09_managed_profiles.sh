#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_managed_attempt_stages_close_key_everywhere_except_exact_provider() {
  local credential_fd rc
  source_managed_contract || return 1
  setup_api_state_fixture
  : > "$TEST_TMP/fd-stage-events"
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  PROBE_FD="$credential_fd"
  managed_profile_attempt_precheck() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'command-precheck-closed\n' >> "$TEST_TMP/fd-stage-events"
    return 1
  }
  set +e; managed_run_profile_attempt provision dry-run "$credential_fd" reason 0; rc=$?; set +e
  assert_eq 1 "$rc" "precheck probe must stop the command" || return 1
  assert_eq command-precheck-closed "$(<"$TEST_TMP/fd-stage-events")" \
    "command prechecks must run with the key closed" || return 1

  : > "$TEST_TMP/fd-stage-events"
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  PROBE_FD="$credential_fd"
  managed_global_api_lock_acquire() { MANAGED_API_LOCK_FD=99; }
  managed_capture_wall_clock_epoch_closed() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf -v wgmanaged_clock_epoch_carrier '%s' "$([[ "$1" == attempt ]] && printf 1000 || printf 1001)"
  }
  managed_api_state_load() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    managed_api_state_defaults "$1"
  }
  managed_api_state_refresh_identity() {
    [[ -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    MANAGED_API_CREDENTIAL_DEVICE=1 MANAGED_API_CREDENTIAL_INODE=2
    MANAGED_API_CREDENTIAL_MTIME=3 MANAGED_API_CREDENTIAL_SIZE=65
    MANAGED_API_CONFIGURED_DEVICE=Device-One
  }
  managed_api_gate_before_preflight() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'gate-closed\n' >> "$TEST_TMP/fd-stage-events"
  }
  managed_api_record_attempt() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'record-closed\n' >> "$TEST_TMP/fd-stage-events"
  }
  fd_stage_preflight() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'preflight-closed\n' >> "$TEST_TMP/fd-stage-events"
  }
  fd_stage_cleanup() { return 0; }
  fd_stage_provider() {
    [[ -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'provider-open\n' >> "$TEST_TMP/fd-stage-events"
  }
  managed_api_record_outcome() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'outcome-closed\n' >> "$TEST_TMP/fd-stage-events"
  }
  managed_global_api_lock_release() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    MANAGED_API_LOCK_FD=''
  }
  fd_stage_downstream() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'downstream-closed\n' >> "$TEST_TMP/fd-stage-events"
  }
  managed_run_authenticated_attempt 0 "$credential_fd" fd_stage_provider fd_stage_downstream \
    fd_stage_preflight fd_stage_cleanup || return 1
  assert_eq $'gate-closed\npreflight-closed\nrecord-closed\nprovider-open\noutcome-closed\ndownstream-closed' \
    "$(<"$TEST_TMP/fd-stage-events")" \
    "only the exact authenticated provider may observe the key descriptor"
}

test_transient_failure_phase_requires_durable_outcome_and_lock_release() {
  local credential_fd failure_case output rc
  source_managed_contract || return 1
  setup_api_state_fixture
  managed_global_api_lock_acquire() { MANAGED_API_LOCK_FD=99; }
  managed_capture_wall_clock_epoch_closed() {
    printf -v wgmanaged_clock_epoch_carrier '%s' \
      "$([[ "$1" == attempt ]] && printf 1000 || printf 1001)"
  }
  managed_api_state_load() { managed_api_state_defaults "$1"; }
  managed_api_state_refresh_identity() { return 0; }
  managed_api_gate_before_preflight() { return 0; }
  managed_api_record_attempt() { return 0; }
  phase_provider() {
    MANAGED_API_PROVIDER_FAILURE_PHASE=response
    MANAGED_API_PROVIDER_FAILURE_REASON=media_missing
    MANAGED_API_PROVIDER_FAILED_SERVER=Candidate
    return 1
  }
  phase_downstream() { printf 'unexpected-downstream\n' >> "$TEST_TMP/phase-events"; }
  managed_api_record_outcome() {
    printf 'outcome\n' >> "$TEST_TMP/phase-events"
    [[ "$FAILURE_CASE" != outcome ]]
  }
  managed_global_api_lock_release() {
    printf 'release\n' >> "$TEST_TMP/phase-events"
    MANAGED_API_LOCK_FD=''
    [[ "$FAILURE_CASE" != release ]]
  }

  for failure_case in none outcome release; do
    FAILURE_CASE="$failure_case"
    : > "$TEST_TMP/phase-events"
    exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
    set +e
    output="$(managed_run_authenticated_attempt \
      0 "$credential_fd" phase_provider phase_downstream)"
    rc=$?
    set +e
    assert_eq 1 "$rc" "$failure_case transient provider result must remain nonzero" || return 1
    assert_eq $'outcome\nrelease' "$(<"$TEST_TMP/phase-events")" \
      "$failure_case path must attempt outcome persistence before lock release" || return 1
    if [[ "$failure_case" == none ]]; then
      assert_eq $'failure\ttransient\tphase=response\treason=media_missing' "$output" \
        "durably recorded transient diagnostic must surface after lock release" || return 1
    else
      assert_eq '' "$output" \
        "$failure_case failure must suppress provider phase attribution" || return 1
    fi
  done
}

test_rotate_dry_run_apply_and_static_restore_use_explicit_safe_ordering() {
  local rc
  setup_managed_transaction_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'MAX_AGE=180' 'AIRVPN_PROFILE_SOURCE=api' 'AIRVPN_DEVICE=Device-One' > "$CFG"
  chmod 600 -- "$CFG"
  : > "$TRANSACTION_EVENTS"
  managed_finish_rotate dry-run Candidate 0 || return 1
  assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "rotate dry-run must not mutate Docker or network" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "rotate dry-run must remove candidate" || return 1

  write_managed_candidate_fixture
  managed_finish_rotate apply Candidate 0 || return 1
  assert_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "rotate apply must enter the crash-safe transaction" || return 1
  assert_eq '198.51.100.20:1637' "$(configured_endpoint "$WG_CONF")" \
    "rotate apply must install the verified candidate" || return 1

  cp -- "${WG_CONF}.bak-healthcheck" "$PRE_MANAGED_CONF"
  chmod 600 -- "$PRE_MANAGED_CONF"
  : > "$TRANSACTION_EVENTS"
  managed_rewrite_profile_source() {
    printf 'mode:%s\n' "$1" >> "$TRANSACTION_EVENTS"
    AIRVPN_PROFILE_SOURCE="$1"
  }
  managed_stage_pre_managed_candidate() {
    printf 'stage\n' >> "$TRANSACTION_EVENTS"
    cp -- "$PRE_MANAGED_CONF" "$MANAGED_CANDIDATE"
    chmod 600 -- "$MANAGED_CANDIDATE"
  }
  managed_profile_transaction() {
    printf 'transaction:%s:%s\n' "$1" "$2" >> "$TRANSACTION_EVENTS"
  }
  managed_command_restore_static dry-run || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" "restore dry-run must be observational" || return 1
  managed_command_restore_static apply || return 1
  assert_eq $'mode:static\nstage\ntransaction::0' "$(<"$TRANSACTION_EVENTS")" \
    "restore must select static mode before entering snapshot transaction" || return 1

  : > "$TRANSACTION_EVENTS"
  managed_profile_transaction() { printf 'transaction\n' >> "$TRANSACTION_EVENTS"; return 1; }
  set +e; managed_command_restore_static apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "restore transaction failure must remain nonzero" || return 1
  assert_eq static "$AIRVPN_PROFILE_SOURCE" \
    "failed restore must remain in safe static mode for reconciliation"
}

test_same_endpoint_different_peer_uses_full_transaction_commit_rollback_and_recovery() {
  local rc
  setup_managed_transaction_fixture || return 1
  write_managed_candidate_fixture '192.0.2.10:1637'
  : > "$TRANSACTION_EVENTS"
  managed_profile_transaction '' 0 || return 1
  assert_contains 'qb-stop:' "$(<"$TRANSACTION_EVENTS")" \
    "same-endpoint peer restore must contain qBittorrent" || return 1
  assert_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "same-endpoint peer restore must bring the old runtime down" || return 1
  assert_contains 'wg-up:' "$(<"$TRANSACTION_EVENTS")" \
    "same-endpoint peer restore must load and verify restored peer material" || return 1
  assert_contains 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' "$(<"$WG_CONF")" \
    "committed restore must install the different peer" || return 1
  assert_not_contains 'exclude-add:' "$(<"$TRANSACTION_EVENTS")" \
    "static restore must not mutate provider exclusion state" || return 1

  setup_managed_transaction_fixture || return 1
  write_managed_candidate_fixture '192.0.2.10:1637'
  TRANSACTION_FAIL_ACTION=speed
  set +e; managed_profile_transaction '' 1 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "failed same-endpoint peer verification must roll back" || return 1
  cmp -s -- "$WG_CONF" "${WG_CONF}.bak-healthcheck" ||
    fail "same-endpoint failure must restore exact old profile bytes" || return 1
  assert_eq running "$TRANSACTION_QB_STATE" "rollback must restore recorded qB intent" || return 1

  setup_managed_transaction_fixture || return 1
  write_managed_candidate_fixture '192.0.2.10:1637'
  managed_qb_snapshot || return 1
  managed_prepare_profile_backup || return 1
  managed_safety_prepare || return 1
  managed_journal_prepare 1 || return 1
  : > "$TRANSACTION_EVENTS"
  managed_reconcile_pending || return 1
  assert_contains 'qb-stop:' "$(<"$TRANSACTION_EVENTS")" \
    "same-endpoint prepared crash recovery must contain qB first" || return 1
  assert_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "same-endpoint prepared crash must use rollback owner" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "verified same-endpoint recovery must clear its owners"
}

test_restore_retry_recovers_safe_staged_orphan_before_mode_and_transaction() {
  local candidate_before
  setup_managed_transaction_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=api' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  chmod 600 -- "$CFG"
  cp -- "${WG_CONF}.bak-healthcheck" "$PRE_MANAGED_CONF"
  chmod 600 -- "$PRE_MANAGED_CONF"
  candidate_before="$(<"$MANAGED_CANDIDATE")"
  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  TRANSACTION_RUNTIME_ENDPOINT=198.51.100.20:1637
  AIRVPN_PROFILE_SOURCE=api
  managed_command_restore_static dry-run || return 1
  assert_eq api "$AIRVPN_PROFILE_SOURCE" "restore dry-run must not change mode" || return 1
  assert_eq "$candidate_before" "$(<"$MANAGED_CANDIDATE")" \
    "restore dry-run must not delete a safe staged orphan" || return 1
  : > "$TRANSACTION_EVENTS"
  managed_command_restore_static apply || return 1
  assert_eq static "$AIRVPN_PROFILE_SOURCE" "restore retry must select static mode" || return 1
  assert_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "restore retry must enter the full transaction after orphan cleanup" || return 1
  cmp -s -- "$WG_CONF" "$PRE_MANAGED_CONF" ||
    fail "restore retry must finish with exact pre-managed bytes"
}

test_managed_status_is_stat_only_redacted_deterministic_and_valid_json() {
  local text json calls
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  AIRVPN_PROFILE_SOURCE=api
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_KEY_FILE="$TEST_TMP/wg0.api-key"
  AIRVPN_API_STATE_FILE="$TEST_TMP/wg0.api-state"
  STATUS_FILE="$TEST_TMP/wg0.status"
  ROTATE_STAMP="$TEST_TMP/wg0.last_rotate"
  ROTATION_PENDING="$TEST_TMP/wg0.conf.pending-healthcheck"
  MANAGED_SAFETY="$TEST_TMP/wg0.conf.safety-healthcheck"
  printf '%064d\n' 0 > "$AIRVPN_API_KEY_FILE"
  chmod 600 -- "$AIRVPN_API_KEY_FILE"
  printf 'outcome=healthy\nreason=endpoint_198.51.100.20_private\ntimestamp=1234\n' > "$STATUS_FILE"
  printf '1200\n' > "$ROTATE_STAMP"
  chmod 600 -- "$STATUS_FILE" "$ROTATE_STAMP"
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  : > "$TEST_TMP/calls"
  managed_credential_record_valid() { printf 'opened\n' >> "$TEST_TMP/calls"; return 1; }
  managed_systemctl() {
    if [[ "$1 $2" == 'is-enabled wg-healthcheck@wg0.timer' ]]; then printf 'enabled\n'; return 0; fi
    return 4
  }
  interface_exists() { return 0; }
  qbittorrent_binding_present() { return 0; }
  owner_mode() { printf '0:%s\n' "$(stat -c '%a' -- "$1")"; }
  text="$(managed_render_status 0)" || return 1
  json="$(managed_render_status 1)" || return 1
  calls="$(<"$TEST_TMP/calls")"
  assert_eq '' "$calls" "status must determine credential presence by metadata only" || return 1
  assert_eq $'mode=api\ntimer=enabled\ntunnel=up\nlast_check=healthy\nlast_check_timestamp=1234\nlast_rotation=recorded\nlast_rotation_timestamp=1200\ncredential_present=true\npending=none\nqbittorrent=proved' \
    "$text" "text status schema must be fixed and deterministic" || return 1
  printf '%s\n' "$json" | python3 -m json.tool >/dev/null ||
    fail "JSON status must parse with the standard library" || return 1
  assert_eq '{"mode":"api","timer":"enabled","tunnel":"up","last_check":"healthy","last_check_timestamp":1234,"last_rotation":"recorded","last_rotation_timestamp":1200,"credential_present":true,"pending":"none","qbittorrent":"proved"}' \
    "$json" "JSON status schema must be fixed and deterministic" || return 1
  for forbidden in Device-One 192.0.2.2 198.51.100.20 private_key profile endpoint; do
    assert_not_contains "$forbidden" "$text$json" "status must redact $forbidden" || return 1
  done
}

test_managed_status_handles_invalid_metadata_pending_and_malformed_observations() {
  local case_name output
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_API_KEY_FILE="$TEST_TMP/wg0.api-key"
  STATUS_FILE="$TEST_TMP/wg0.status"
  ROTATE_STAMP="$TEST_TMP/wg0.last_rotate"
  ROTATION_PENDING="$TEST_TMP/wg0.conf.pending-healthcheck"
  MANAGED_SAFETY="$TEST_TMP/wg0.conf.safety-healthcheck"
  QBITTORRENT_CONTAINER=''
  managed_systemctl() { return 4; }
  interface_exists() { return 1; }
  owner_mode() { printf '0:%s\n' "$(stat -c '%a' -- "$1")"; }
  validate_secure_file() {
    [[ -f "$1" && ! -L "$1" && "$(stat -c '%a' -- "$1")" == "${3:-600}" ]]
  }
  for case_name in absent wrong_mode symlink; do
    rm -f -- "$AIRVPN_API_KEY_FILE"
    case "$case_name" in
      absent) ;;
      wrong_mode) write_valid_test_key "$AIRVPN_API_KEY_FILE"; chmod 640 -- "$AIRVPN_API_KEY_FILE" ;;
      symlink) ln -s -- "$TEST_TMP/missing-key" "$AIRVPN_API_KEY_FILE" ;;
    esac
    printf 'not-a-status\n' > "$STATUS_FILE"
    printf 'not-a-stamp\n' > "$ROTATE_STAMP"
    output="$(managed_render_status 0)" || return 1
    assert_contains 'timer=unknown' "$output" "systemctl errors must map to unknown" || return 1
    assert_contains 'last_check=invalid' "$output" "malformed status must be explicit" || return 1
    assert_contains 'last_check_timestamp=0' "$output" "malformed status timestamp must not escape" || return 1
    assert_contains 'last_rotation=invalid' "$output" "malformed stamp must be explicit" || return 1
    assert_contains 'last_rotation_timestamp=0' "$output" "malformed stamp timestamp must not escape" || return 1
    assert_contains 'credential_present=false' "$output" \
      "$case_name credential metadata must not be reported present" || return 1
  done

  rm -f -- "$ROTATION_PENDING" "$MANAGED_SAFETY"
  managed_systemctl() { printf 'not-found\n'; return 1; }
  output="$(managed_render_status 0)" || return 1
  assert_contains 'timer=unknown' "$output" \
    "systemctl rc1 with non-disabled output must remain unknown" || return 1
  managed_systemctl() { return 4; }
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"
  chmod 600 -- "$ROTATION_PENDING"
  output="$(managed_render_status 0)" || return 1
  assert_contains 'pending=endpoint-v1' "$output" "status must identify a v1 marker without reconciling" || return 1
  printf 'version=2\n' > "$ROTATION_PENDING"
  output="$(managed_render_status 0)" || return 1
  assert_contains 'pending=invalid' "$output" "malformed v2 marker must be explicit" || return 1
  printf 'version=1\n' > "$MANAGED_SAFETY"
  output="$(managed_render_status 0)" || return 1
  assert_contains 'pending=invalid' "$output" "invalid safety metadata/schema must be explicit"
}

test_status_pending_enums_strictly_distinguish_owned_orphan_and_invalid_states() {
  local victim
  setup_managed_transaction_fixture || return 1
  managed_qb_snapshot || return 1
  managed_prepare_profile_backup || return 1
  managed_safety_prepare || return 1
  managed_journal_prepare 1 || return 1
  assert_eq managed-pending "$(managed_status_pending)" \
    "matching safety/journal state must report managed-pending" || return 1

  rm -f -- "$MANAGED_SAFETY"
  assert_eq orphan "$(managed_status_pending)" \
    "valid v2 journal without safety owner must report orphan" || return 1

  setup_managed_transaction_fixture || return 1
  managed_qb_snapshot || return 1
  managed_prepare_profile_backup || return 1
  managed_safety_prepare || return 1
  managed_journal_prepare 1 || return 1
  sed -i 's/^candidate_endpoint=.*/candidate_endpoint=198.51.100.21:1637/' "$ROTATION_PENDING"
  assert_eq invalid "$(managed_status_pending)" \
    "mismatched safety and journal must report invalid" || return 1

  rm -f -- "$MANAGED_SAFETY" "$ROTATION_PENDING"
  victim="$TEST_TMP/status-safety-canary"
  printf 'canary\n' > "$victim"
  ln -s -- "$victim" "$MANAGED_SAFETY"
  assert_eq invalid "$(managed_status_pending)" "safety symlink must report invalid" || return 1
  assert_eq canary "$(<"$victim")" "status must not mutate an invalid safety target" || return 1

  rm -f -- "$MANAGED_SAFETY"
  managed_qb_snapshot || return 1
  write_managed_candidate_fixture
  managed_prepare_profile_backup || return 1
  managed_safety_prepare || return 1
  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"; chmod 600 -- "$WG_CONF"
  rm -f -- "$MANAGED_CANDIDATE" "$ROTATION_PENDING"
  sed -i 's/^state=pending$/state=committed/' "$MANAGED_SAFETY"
  assert_eq managed-committed "$(managed_status_pending)" \
    "trusted committed owner must report managed-committed" || return 1
  sed -i 's/^state=committed$/state=finalizing/' "$MANAGED_SAFETY"
  assert_eq managed-finalizing "$(managed_status_pending)" \
    "trusted finalizing owner must report managed-finalizing"
}

test_reset_api_state_is_quiesced_exact_durable_and_preserves_every_other_artifact() {
  local before_profile before_snapshot before_key rc
  setup_managed_journal_fixture || return 1
  AIRVPN_API_STATE_FILE="$TEST_TMP/var/lib/wg-healthcheck/wg0.api-state"
  AIRVPN_API_KEY_FILE="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.api-key"
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  ROTATE_STAMP="$TEST_TMP/run/wg-healthcheck/wg0.last_rotate"
  mkdir -p -- "${AIRVPN_API_STATE_FILE%/*}" "${AIRVPN_API_KEY_FILE%/*}"
  chmod 700 -- "${AIRVPN_API_STATE_FILE%/*}" "${AIRVPN_API_KEY_FILE%/*}"
  printf 'corrupt-state\n' > "$AIRVPN_API_STATE_FILE"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  cp -- "$WG_CONF" "$PRE_MANAGED_CONF"
  printf '1000\n' > "$ROTATE_STAMP"
  chmod 600 -- "$AIRVPN_API_STATE_FILE" "$AIRVPN_API_KEY_FILE" "$PRE_MANAGED_CONF" "$ROTATE_STAMP"
  before_profile="$(<"$WG_CONF")"; before_snapshot="$(<"$PRE_MANAGED_CONF")"; before_key="$(<"$AIRVPN_API_KEY_FILE")"
  managed_systemctl() { return 3; }
  managed_reset_global_lock_acquire() { MANAGED_RESET_LOCK_FD=19; }
  managed_reset_global_lock_release() { MANAGED_RESET_LOCK_FD=''; }
  managed_sync_directory() { printf 'directory\n' >> "$TEST_TMP/reset-sync"; }
  : > "$TEST_TMP/reset-sync"
  managed_reset_api_state dry-run || return 1
  [[ -f "$AIRVPN_API_STATE_FILE" ]] || fail "reset dry-run must preserve corrupt state" || return 1
  managed_reset_api_state apply || return 1
  [[ ! -e "$AIRVPN_API_STATE_FILE" && ! -L "$AIRVPN_API_STATE_FILE" ]] ||
    fail "reset apply must remove only API state" || return 1
  assert_eq directory "$(<"$TEST_TMP/reset-sync")" "reset must sync the state directory" || return 1
  assert_eq "$before_profile" "$(<"$WG_CONF")" "reset must preserve active profile" || return 1
  assert_eq "$before_snapshot" "$(<"$PRE_MANAGED_CONF")" "reset must preserve recovery snapshot" || return 1
  assert_eq "$before_key" "$(<"$AIRVPN_API_KEY_FILE")" "reset must preserve credential" || return 1
  [[ -f "$ROTATE_STAMP" && -f "${WG_CONF}.bak-healthcheck" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "reset must preserve stamps, backup, and candidate" || return 1

  printf 'corrupt-state\n' > "$AIRVPN_API_STATE_FILE"; chmod 600 -- "$AIRVPN_API_STATE_FILE"
  printf 'version=2\n' > "$ROTATION_PENDING"; chmod 600 -- "$ROTATION_PENDING"
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "reset must refuse every pending marker" || return 1
  [[ -f "$AIRVPN_API_STATE_FILE" ]] || fail "pending refusal must preserve state" || return 1
  rm -f -- "$ROTATION_PENDING"
  managed_reset_global_lock_acquire() { return 75; }
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 75 "$rc" "global API lock contention must fail promptly" || return 1
  [[ -f "$AIRVPN_API_STATE_FILE" ]] || fail "lock contention must preserve state" || return 1
  managed_reset_global_lock_acquire() { MANAGED_RESET_LOCK_FD=19; }
  managed_systemctl() { [[ "$1" == is-active ]]; }
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 75 "$rc" "active timer or worker must block reset" || return 1
  [[ -f "$AIRVPN_API_STATE_FILE" ]] || fail "activity refusal must preserve state"
}

test_reset_api_state_rejects_unknown_units_and_unsafe_state_metadata_but_absent_is_idempotent() {
  local rc case_name
  setup_managed_journal_fixture || return 1
  AIRVPN_API_STATE_FILE="$TEST_TMP/var/lib/wg-healthcheck/wg0.api-state"
  mkdir -p -- "${AIRVPN_API_STATE_FILE%/*}"
  chmod 700 -- "${AIRVPN_API_STATE_FILE%/*}"
  managed_reset_global_lock_acquire() { MANAGED_RESET_LOCK_FD=19; }
  managed_reset_global_lock_release() { MANAGED_RESET_LOCK_FD=''; }
  managed_sync_directory() { :; }
  managed_systemctl() { return 3; }
  managed_reset_api_state apply || return 1

  printf 'corrupt\n' > "$AIRVPN_API_STATE_FILE"; chmod 600 -- "$AIRVPN_API_STATE_FILE"
  managed_systemctl() { return 4; }
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "unknown/error systemd state must be unsafe for reset" || return 1
  [[ -f "$AIRVPN_API_STATE_FILE" ]] || fail "unknown unit result must preserve state" || return 1
  managed_systemctl() { return 3; }

  for case_name in wrong_mode symlink; do
    rm -f -- "$AIRVPN_API_STATE_FILE"
    if [[ "$case_name" == wrong_mode ]]; then
      printf 'corrupt\n' > "$AIRVPN_API_STATE_FILE"; chmod 640 -- "$AIRVPN_API_STATE_FILE"
    else
      ln -s -- "$TEST_TMP/missing-state" "$AIRVPN_API_STATE_FILE"
    fi
    set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name persistent state must be refused" || return 1
    [[ -e "$AIRVPN_API_STATE_FILE" || -L "$AIRVPN_API_STATE_FILE" ]] ||
      fail "$case_name persistent state must not be removed" || return 1
  done
}

test_reset_apply_retry_syncs_parent_after_unlink_sync_failure() {
  local rc
  setup_managed_journal_fixture || return 1
  AIRVPN_API_STATE_FILE="$TEST_TMP/var/lib/wg-healthcheck/wg0.api-state"
  mkdir -p -- "${AIRVPN_API_STATE_FILE%/*}"
  chmod 700 -- "${AIRVPN_API_STATE_FILE%/*}"
  printf 'corrupt\n' > "$AIRVPN_API_STATE_FILE"
  chmod 600 -- "$AIRVPN_API_STATE_FILE"
  managed_systemctl() { return 3; }
  managed_reset_global_lock_acquire() { MANAGED_RESET_LOCK_FD=19; }
  managed_reset_global_lock_release() { MANAGED_RESET_LOCK_FD=''; }
  managed_unlink_path() {
    printf 'unlink:%s\n' "$1" >> "$TEST_TMP/reset-retry-events"
    rm -f -- "$1"
  }
  RESET_SYNC_FAILURE_PENDING=1
  managed_sync_directory() {
    printf 'sync:%s\n' "$1" >> "$TEST_TMP/reset-retry-events"
    if [[ "$RESET_SYNC_FAILURE_PENDING" == 1 ]]; then
      RESET_SYNC_FAILURE_PENDING=0
      return 1
    fi
  }
  : > "$TEST_TMP/reset-retry-events"
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-unlink parent-sync failure must remain nonzero" || return 1
  [[ ! -e "$AIRVPN_API_STATE_FILE" && ! -L "$AIRVPN_API_STATE_FILE" ]] ||
    fail "successful unlink must leave state visibly absent" || return 1

  : > "$TEST_TMP/reset-retry-events"
  managed_reset_api_state apply || return 1
  assert_eq "sync:${AIRVPN_API_STATE_FILE%/*}" "$(<"$TEST_TMP/reset-retry-events")" \
    "apply retry must sync trusted state parent even when state is absent" || return 1

  : > "$TEST_TMP/reset-retry-events"
  managed_reset_api_state dry-run || return 1
  assert_eq '' "$(<"$TEST_TMP/reset-retry-events")" \
    "reset dry-run must not sync or mutate an absent state path"
}

test_reset_rejects_unsafe_state_parent_and_global_lock_swap_without_mutation() {
  local rc victim real_parent
  setup_managed_journal_fixture || return 1
  STATE_DIR="$TEST_TMP/run/wg-healthcheck"
  AIRVPN_API_LOCK="$STATE_DIR/airvpn-api.lock"
  AIRVPN_API_STATE_FILE="$TEST_TMP/var/lib/wg-healthcheck/wg0.api-state"
  mkdir -p -- "$STATE_DIR" "${AIRVPN_API_STATE_FILE%/*}"
  chmod 700 -- "$STATE_DIR" "${AIRVPN_API_STATE_FILE%/*}"
  printf 'corrupt\n' > "$AIRVPN_API_STATE_FILE"
  chmod 600 -- "$AIRVPN_API_STATE_FILE"
  managed_systemctl() { return 3; }
  managed_reset_lock_fd_identity() {
    local fd="${1:?}"
    rm -f -- "$AIRVPN_API_LOCK"
    ln -s -- "$victim" "$AIRVPN_API_LOCK"
    stat -Lc '%d:%i' -- "/proc/$BASHPID/fd/$fd"
  }
  chmod 750 -- "${AIRVPN_API_STATE_FILE%/*}"
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "wrong-mode state parent must block reset" || return 1
  [[ -f "$AIRVPN_API_STATE_FILE" ]] || fail "unsafe parent refusal must preserve state" || return 1

  real_parent="$TEST_TMP/real-state-parent"
  mv -- "${AIRVPN_API_STATE_FILE%/*}" "$real_parent"
  ln -s -- "$real_parent" "${AIRVPN_API_STATE_FILE%/*}"
  set +e; managed_reset_api_state apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "symlink state parent must block reset" || return 1
  [[ -f "$real_parent/wg0.api-state" ]] || fail "symlink parent refusal must preserve state" || return 1

  rm -f -- "${AIRVPN_API_STATE_FILE%/*}"
  mv -- "$real_parent" "${AIRVPN_API_STATE_FILE%/*}"
  chmod 700 -- "${AIRVPN_API_STATE_FILE%/*}"
  victim="$TEST_TMP/lock-swap-victim"
  printf 'do-not-truncate\n' > "$victim"
  printf 'lock\n' > "$AIRVPN_API_LOCK"
  chmod 600 -- "$AIRVPN_API_LOCK"
  MANAGED_RESET_LOCK_FD=''
  set +e; managed_reset_global_lock_acquire apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "global lock inode/symlink swap must fail" || return 1
  assert_eq do-not-truncate "$(<"$victim")" "lock swap must not truncate its target" || return 1
  assert_eq '' "${MANAGED_RESET_LOCK_FD-}" "failed lock proof must close and clear its descriptor"
}

test_managed_dispatch_keeps_supplied_credential_private_and_refuses_nonroot_mutation() {
  local credential_fd rc
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  exec {credential_fd}<"$TEST_TMP/credential"
  : > "$TEST_TMP/events"
  is_root() { return 0; }
  managed_command_provision() {
    local mode="$1" fd="$2" value
    IFS= read -r -u "$fd" value || return 1
    printf '%s:%s\n' "$mode" "$value" > "$TEST_TMP/events"
    close_private_fd "$fd"
  }
  managed_dispatch_command provision dry-run 0 "$credential_fd" || return 1
  assert_eq 'dry-run:descriptor-only-test-record' "$(<"$TEST_TMP/events")" \
    "supplied credential must reach only its authenticated command owner" || return 1

  exec {credential_fd}<"$TEST_TMP/credential"
  is_root() { return 1; }
  : > "$TEST_TMP/events"
  set +e; managed_dispatch_command adopt apply 0 "$credential_fd" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-root mutation must be refused" || return 1
  assert_eq '' "$(<"$TEST_TMP/events")" "non-root refusal must happen before command mutation" || return 1
  set +e; IFS= read -r -u "$credential_fd" _ 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "refused credential descriptor must be closed before logging"
}

test_unexpected_credential_fd_is_closed_before_noncredential_dispatch() {
  local command credential_fd rc leaked
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  : > "$TEST_TMP/dispatch-events"
  is_root() { return 0; }
  run_healthcheck() { printf 'check\n' >> "$TEST_TMP/dispatch-events"; }
  managed_command_rotate() { printf 'rotate\n' >> "$TEST_TMP/dispatch-events"; }
  managed_command_restore_static() { printf 'restore\n' >> "$TEST_TMP/dispatch-events"; }
  managed_reset_api_state() { printf 'reset\n' >> "$TEST_TMP/dispatch-events"; }
  managed_command_cleanup_candidate() { printf 'cleanup\n' >> "$TEST_TMP/dispatch-events"; }
  managed_render_status() { printf 'status\n' >> "$TEST_TMP/dispatch-events"; }
  for command in check rotate restore-static reset-api-state cleanup-candidate status; do
    exec {credential_fd}<"$TEST_TMP/credential"
    set +e; managed_dispatch_command "$command" dry-run 0 "$credential_fd" >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$command must refuse an unexpected credential descriptor" || return 1
    set +e; IFS= read -r -u "$credential_fd" leaked 2>/dev/null; rc=$?; set +e
    assert_eq 1 "$rc" "$command refusal must close the unexpected descriptor" || return 1
  done
  assert_eq '' "$(<"$TEST_TMP/dispatch-events")" \
    "unexpected descriptor refusal must precede every command action"
}

test_linux_managed_journal_real_owner_mode_and_symlink_semantics() {
  local rc parent active_real candidate_real
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  setup_managed_journal_fixture || return 1
  owner_mode() { stat -c '%u:%a' -- "$1" 2>/dev/null; }
  managed_journal_prepare 0 || return 1
  managed_journal_load || fail "real root-owned 0600 journal under 0700 parent must load" || return 1

  chmod 640 -- "$ROTATION_PENDING"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real wrong-mode journal must fail" || return 1
  chmod 600 -- "$ROTATION_PENDING"
  chown 1 -- "$ROTATION_PENDING"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root journal must fail" || return 1
  chown 0 -- "$ROTATION_PENDING"

  chmod 640 -- "$MANAGED_CANDIDATE"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real wrong-mode candidate must block phase advance" || return 1
  chmod 600 -- "$MANAGED_CANDIDATE"
  chown 1 -- "${WG_CONF}.bak-healthcheck"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root backup must block phase advance" || return 1
  chown 0 -- "${WG_CONF}.bak-healthcheck"

  active_real="${WG_CONF}.real"
  mv -- "$WG_CONF" "$active_real"
  ln -s -- "$active_real" "$WG_CONF"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "active profile symlink must block phase advance" || return 1
  rm -f -- "$WG_CONF"
  mv -- "$active_real" "$WG_CONF"

  candidate_real="${MANAGED_CANDIDATE}.real"
  mv -- "$MANAGED_CANDIDATE" "$candidate_real"
  ln -s -- "$candidate_real" "$MANAGED_CANDIDATE"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "candidate profile symlink must block phase advance" || return 1
  rm -f -- "$MANAGED_CANDIDATE"
  mv -- "$candidate_real" "$MANAGED_CANDIDATE"

  parent="${ROTATION_PENDING%/*}"
  chmod 750 -- "$parent"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-0700 journal parent must fail" || return 1
  chmod 700 -- "$parent"
  chown 1 -- "$parent"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root journal parent must fail" || return 1
  chown 0 -- "$parent"

  rm -f -- "$ROTATION_PENDING"
  ln -s -- "$WG_CONF" "$ROTATION_PENDING"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real journal symlink must fail"
}
