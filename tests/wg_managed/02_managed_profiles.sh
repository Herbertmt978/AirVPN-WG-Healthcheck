#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_api_state_admin_bypass_outcomes_and_timer_suppression() {
  local rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  managed_api_record_outcome 1000 auth '' '' 0 || return 1

  set +e; managed_api_attempt_allowed 1001 0; rc=$?; set +e
  assert_eq 75 "$rc" "timer path must not bypass authentication suppression" || return 1
  managed_api_attempt_allowed 1001 1 ||
    fail "explicit administrative dry run may bypass authentication suppression" || return 1
  managed_api_record_attempt 1001 1 || return 1
  assert_eq 1 "$MANAGED_API_ATTEMPT_COUNT" "bypassed validation must still count an authenticated attempt" || return 1

  managed_api_record_outcome 1001 transient '' '' 0 || return 1
  assert_eq transient "$MANAGED_API_FAILURE_CLASS" "failed validation must reclassify suppression" || return 1
  set +e; managed_api_attempt_allowed 1002 1; rc=$?; set +e
  assert_eq 75 "$rc" "administrative bypass must retain transient backoff" || return 1
  managed_api_record_outcome 1002 rate 600 '' 0 || return 1
  set +e; managed_api_attempt_allowed 1003 1; rc=$?; set +e
  assert_eq 75 "$rc" "administrative bypass must retain rate-limit backoff" || return 1

  managed_api_record_outcome 1003 none '' '' 0 || return 1
  assert_eq none "$MANAGED_API_FAILURE_CLASS" "successful validation must clear suppression" || return 1
  assert_eq 0 "$MANAGED_API_BACKOFF_UNTIL" "successful validation must clear backoff" || return 1
  managed_api_attempt_allowed 1004 0 || return 1

  managed_admin_dry_run_bypass provision dry-run ||
    fail "provision dry run must opt into the narrow bypass" || return 1
  managed_admin_dry_run_bypass adopt dry-run ||
    fail "adopt dry run must opt into the narrow bypass" || return 1
  managed_admin_dry_run_bypass rotate dry-run ||
    fail "rotate dry run must opt into the narrow bypass" || return 1
  set +e; managed_admin_dry_run_bypass rotate apply; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "apply must never receive the dry-run bypass" || return 1
  set +e; managed_admin_dry_run_bypass check ''; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "timer checks must never receive the dry-run bypass"
}

test_api_state_failed_server_persists_then_expires_into_selector_argv() {
  local rc
  local -a args=()
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  managed_api_record_attempt 1000 0 || return 1
  managed_api_record_outcome 1000 transient '' Alpha-1 0 || return 1

  managed_api_state_defaults 1 || return 1
  managed_api_state_load 1001 || return 1
  managed_api_exclusion_args args 1001 || return 1
  assert_eq '--exclude-server Alpha-1' "${args[*]}" \
    "failed candidate must persist into the next fixed selector argv" || return 1

  managed_api_state_defaults 1 || return 1
  managed_api_state_load 22600 || return 1
  managed_api_exclusion_args args 22600 || return 1
  assert_eq 0 "${#args[@]}" "six-hour expiry must make the failed candidate eligible again" || return 1
  set +e; managed_api_state_load 999 >/dev/null 2>&1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "backward clock movement must block authenticated selection"
}

test_failed_candidate_always_attempts_exactly_one_ordered_rollback() {
  local case_name rc expected_events
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  declare -F managed_fail_candidate_before_rollback >/dev/null ||
    fail "record-before-rollback seam is missing" || return 1

  managed_api_state_add_exclusion() {
    printf 'add\n' >> "$TEST_TMP/rollback-events"
    (( ROLLBACK_ADD_FAIL == 0 ))
  }
  managed_api_state_write() {
    printf 'write\n' >> "$TEST_TMP/rollback-events"
    (( ROLLBACK_WRITE_FAIL == 0 ))
  }
  rollback_probe() {
    printf 'rollback\n' >> "$TEST_TMP/rollback-events"
    ROLLBACK_CALLS=$((ROLLBACK_CALLS + 1))
    if (( ROLLBACK_CALLBACK_FAIL )); then return 1; fi
    QBITTORRENT_TEST_STATE=running
  }

  for case_name in success add-failure write-failure rollback-failure combined-failure; do
    ROLLBACK_ADD_FAIL=0
    ROLLBACK_WRITE_FAIL=0
    ROLLBACK_CALLBACK_FAIL=0
    ROLLBACK_CALLS=0
    QBITTORRENT_TEST_STATE=stopped
    : > "$TEST_TMP/rollback-events"
    case "$case_name" in
      success) expected_events=$'add\nwrite\nrollback' ;;
      add-failure)
        ROLLBACK_ADD_FAIL=1
        expected_events=$'add\nrollback'
        ;;
      write-failure)
        ROLLBACK_WRITE_FAIL=1
        expected_events=$'add\nwrite\nrollback'
        ;;
      rollback-failure)
        ROLLBACK_CALLBACK_FAIL=1
        expected_events=$'add\nwrite\nrollback'
        ;;
      combined-failure)
        ROLLBACK_WRITE_FAIL=1
        ROLLBACK_CALLBACK_FAIL=1
        expected_events=$'add\nwrite\nrollback'
        ;;
    esac

    set +e
    managed_fail_candidate_before_rollback 1000 Alpha-1 rollback_probe
    rc=$?
    set +e
    assert_eq "$expected_events" "$(<"$TEST_TMP/rollback-events")" \
      "$case_name must persist first and invoke rollback exactly once" || return 1
    assert_eq 1 "$ROLLBACK_CALLS" "$case_name must invoke exactly one rollback callback" || return 1
    if [[ "$case_name" == success ]]; then
      assert_eq 0 "$rc" "successful persistence and rollback must succeed" || return 1
      assert_eq running "$QBITTORRENT_TEST_STATE" \
        "successful rollback may re-enable qBittorrent" || return 1
    else
      [[ "$rc" != 0 ]] || fail "$case_name must return failure" || return 1
    fi
    if (( ROLLBACK_CALLBACK_FAIL )); then
      assert_eq stopped "$QBITTORRENT_TEST_STATE" \
        "$case_name must leave qBittorrent stopped when rollback cannot complete" || return 1
    fi
  done
}

test_suppressed_attempts_persist_pruned_high_water_and_surface_write_failure() {
  local attempt_epoch rc persisted_before_failure
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  for attempt_epoch in 1000 1001 1002 1003 1004 1005; do
    managed_api_record_attempt "$attempt_epoch" 0 || return 1
  done

  managed_api_state_defaults 1 || return 1
  managed_api_state_load 1005 || return 1
  set +e
  managed_api_record_attempt 2000 0
  rc=$?
  set +e
  assert_eq 75 "$rc" "daily-cap suppression must retain the normal suppression status" || return 1
  grep -Fx 'observed_at=2000' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "daily-cap suppression must durably advance observed_at" || return 1
  grep -Fx 'attempt_count=6' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "daily-cap suppression must not append a seventh attempt" || return 1
  managed_api_state_defaults 1 || return 1
  set +e; managed_api_state_load 1500 >/dev/null 2>&1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "restart must reject time before a suppressed daily high-water" || return 1

  managed_api_state_defaults 3000 || return 1
  managed_api_state_refresh_identity 3000 || return 1
  managed_api_record_attempt 3000 0 || return 1
  managed_api_record_outcome 3000 transient '' Alpha-1 0 || return 1
  managed_api_state_defaults 1 || return 1
  managed_api_state_load 3000 || return 1
  set +e
  managed_api_record_attempt 3100 0
  rc=$?
  set +e
  assert_eq 75 "$rc" "backoff suppression must retain the normal suppression status" || return 1
  grep -Fx 'observed_at=3100' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "backoff suppression must durably advance observed_at" || return 1
  managed_api_state_defaults 1 || return 1
  set +e; managed_api_state_load 3050 >/dev/null 2>&1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "restart must reject time before a suppressed backoff high-water" || return 1

  managed_api_state_load 3100 || return 1
  persisted_before_failure="$(<"$AIRVPN_API_STATE_FILE")"
  managed_api_state_write() { return 1; }
  set +e
  managed_api_record_attempt 3200 0
  rc=$?
  set +e
  assert_eq 1 "$rc" "suppression persistence failure must not masquerade as rc75" || return 1
  assert_eq "$persisted_before_failure" "$(<"$AIRVPN_API_STATE_FILE")" \
    "failed suppression persistence must not corrupt the last durable state"
}

test_authenticated_suppression_persists_before_releasing_global_lock() {
  local attempt_epoch rc expected_events
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture

  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  for attempt_epoch in 1000 1001 1002 1003 1004 1005; do
    managed_api_record_attempt "$attempt_epoch" 0 || return 1
  done
  cp -- "$AIRVPN_API_STATE_FILE" "$TEST_TMP/daily-state"

  managed_api_state_defaults 3000 || return 1
  managed_api_state_refresh_identity 3000 || return 1
  managed_api_record_attempt 3000 0 || return 1
  managed_api_record_outcome 3000 auth '' Alpha-1 0 || return 1
  cp -- "$AIRVPN_API_STATE_FILE" "$TEST_TMP/backoff-state"

  : > "$TEST_TMP/suppression-lock-events"
  SUPPRESSION_WRITE_FAIL=0
  managed_global_api_lock_acquire() {
    printf 'lock-acquired\n' >> "$TEST_TMP/suppression-lock-events"
    MANAGED_API_LOCK_FD=99
  }
  managed_global_api_lock_release() {
    printf 'lock-released\n' >> "$TEST_TMP/suppression-lock-events"
    MANAGED_API_LOCK_FD=
  }
  managed_sync_file() {
    [[ "${MANAGED_API_LOCK_FD:-}" == 99 ]] || {
      printf 'sync-outside-lock\n' >> "$TEST_TMP/suppression-lock-events"
      return 1
    }
    printf 'sync-file\n' >> "$TEST_TMP/suppression-lock-events"
    (( SUPPRESSION_WRITE_FAIL == 0 ))
  }
  managed_sync_directory() {
    [[ "${MANAGED_API_LOCK_FD:-}" == 99 ]] || {
      printf 'sync-outside-lock\n' >> "$TEST_TMP/suppression-lock-events"
      return 1
    }
    printf 'sync-directory\n' >> "$TEST_TMP/suppression-lock-events"
  }
  suppressed_provider_probe() {
    printf 'unexpected-provider\n' >> "$TEST_TMP/suppression-lock-events"
    return 1
  }
  suppressed_downstream_probe() {
    printf 'unexpected-downstream\n' >> "$TEST_TMP/suppression-lock-events"
    return 1
  }

  cp -- "$TEST_TMP/daily-state" "$AIRVPN_API_STATE_FILE"
  chmod 600 -- "$AIRVPN_API_STATE_FILE"
  MANAGED_TEST_ATTEMPT_EPOCH=2000
  set +e
  managed_run_authenticated_attempt 0 '' suppressed_provider_probe suppressed_downstream_probe
  rc=$?
  set +e
  assert_eq 75 "$rc" "daily suppression must return rc75 through the locked wrapper" || return 1
  expected_events=$'lock-acquired\nsync-file\nsync-file\nsync-directory\nlock-released'
  assert_eq "$expected_events" "$(<"$TEST_TMP/suppression-lock-events")" \
    "daily suppression must become durable before releasing the global lock" || return 1
  grep -Fx 'observed_at=2000' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "locked daily suppression must persist its high-water" || return 1

  cp -- "$TEST_TMP/backoff-state" "$AIRVPN_API_STATE_FILE"
  chmod 600 -- "$AIRVPN_API_STATE_FILE"
  : > "$TEST_TMP/suppression-lock-events"
  MANAGED_TEST_ATTEMPT_EPOCH=30000
  set +e
  managed_run_authenticated_attempt 0 '' suppressed_provider_probe suppressed_downstream_probe
  rc=$?
  set +e
  assert_eq 75 "$rc" "backoff suppression must return rc75 through the locked wrapper" || return 1
  assert_eq "$expected_events" "$(<"$TEST_TMP/suppression-lock-events")" \
    "backoff suppression must prune and persist before releasing the global lock" || return 1
  grep -Fx 'observed_at=30000' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "locked backoff suppression must persist its high-water" || return 1
  grep -Fx 'exclude_count=0' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "locked backoff suppression must durably prune expired exclusions" || return 1

  : > "$TEST_TMP/suppression-lock-events"
  SUPPRESSION_WRITE_FAIL=1
  MANAGED_TEST_ATTEMPT_EPOCH=31000
  set +e
  managed_run_authenticated_attempt 0 '' suppressed_provider_probe suppressed_downstream_probe
  rc=$?
  set +e
  assert_eq 1 "$rc" "locked suppression write failure must return rc1" || return 1
  assert_eq $'lock-acquired\nsync-file\nlock-released' \
    "$(<"$TEST_TMP/suppression-lock-events")" \
    "suppression write failure must release the lock without reaching provider work" || return 1
  grep -Fx 'observed_at=30000' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "failed locked suppression write must retain the last durable high-water"
}

test_authenticated_attempt_samples_private_fresh_time_after_lock_and_provider() {
  local case_name credential_fd rc expected_rc expected_backoff expected_events
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  : > "$TEST_TMP/clock-events"

  managed_global_api_lock_acquire() {
    [[ -n "$1" && -e "/proc/$BASHPID/fd/$1" ]] || return 1
    printf 'lock-acquired\n' >> "$TEST_TMP/clock-events"
    MANAGED_TEST_ATTEMPT_EPOCH=1100
    MANAGED_API_LOCK_FD=99
  }
  managed_global_api_lock_release() {
    [[ -z "${PROBE_FD:-}" || ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'lock-released\n' >> "$TEST_TMP/clock-events"
    MANAGED_API_LOCK_FD=
  }
  managed_wall_clock_epoch() {
    local phase="${1-}"
    [[ $# == 1 && ( "$phase" == attempt || "$phase" == outcome ) ]] || return 1
    if [[ -n "${PROBE_FD:-}" && -e "/proc/$BASHPID/fd/$PROBE_FD" ]]; then
      printf 'clock-credential-leaked:%s\n' "$phase" >> "$TEST_TMP/clock-events"
      return 1
    fi
    printf 'clock:%s:%s\n' "$phase" \
      "$([[ "$phase" == attempt ]] && printf '%s' "$MANAGED_TEST_ATTEMPT_EPOCH" || printf '%s' "$MANAGED_TEST_OUTCOME_EPOCH")" \
      >> "$TEST_TMP/clock-events"
    if [[ "$phase" == attempt ]]; then
      printf '%s\n' "$MANAGED_TEST_ATTEMPT_EPOCH"
    else
      printf '%s\n' "$MANAGED_TEST_OUTCOME_EPOCH"
    fi
  }
  timed_provider_probe() {
    printf 'provider:%s\n' "$CLOCK_CASE" >> "$TEST_TMP/clock-events"
    MANAGED_TEST_OUTCOME_EPOCH=1300
    MANAGED_API_PROVIDER_RETRY_AFTER=''
    MANAGED_API_PROVIDER_FAILED_SERVER=''
    MANAGED_API_PROVIDER_JITTER=0
    case "$CLOCK_CASE" in
      transient)
        MANAGED_API_PROVIDER_FAILED_SERVER=Alpha-1
        return 6
        ;;
      retry-after)
        MANAGED_API_PROVIDER_RETRY_AFTER=600
        return 5
        ;;
      auth)
        MANAGED_API_PROVIDER_FAILURE_CLASS=auth
        return 4
        ;;
      device) return 7 ;;
      regression)
        MANAGED_TEST_OUTCOME_EPOCH=1099
        return 6
        ;;
      *) return 1 ;;
    esac
  }
  timed_downstream_probe() {
    printf 'unexpected-downstream\n' >> "$TEST_TMP/clock-events"
    return 1
  }

  for case_name in transient retry-after auth device; do
    rm -f -- "$AIRVPN_API_STATE_FILE"
    : > "$TEST_TMP/clock-events"
    CLOCK_CASE="$case_name"
    MANAGED_TEST_ATTEMPT_EPOCH=1000
    MANAGED_TEST_OUTCOME_EPOCH=1000
    exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
    PROBE_FD="$credential_fd"
    case "$case_name" in
      transient)
        expected_rc=6
        expected_backoff=1600
        ;;
      retry-after)
        expected_rc=5
        expected_backoff=1900
        ;;
      auth)
        expected_rc=4
        expected_backoff=87700
        ;;
      device)
        expected_rc=7
        expected_backoff=87700
        ;;
    esac

    set +e
    managed_run_authenticated_attempt \
      0 "$credential_fd" timed_provider_probe timed_downstream_probe
    rc=$?
    set +e
    assert_eq "$expected_rc" "$rc" "$case_name must retain its provider status" || return 1
    expected_events=$'lock-acquired\nclock:attempt:1100\nprovider:'"$case_name"$'\nclock:outcome:1300\nlock-released'
    assert_eq "$expected_events" "$(<"$TEST_TMP/clock-events")" \
      "$case_name must sample after lock wait and provider completion" || return 1
    assert_eq 1100 "${MANAGED_API_ATTEMPT_EPOCHS[0]}" \
      "$case_name request accounting must use post-lock time" || return 1
    assert_eq 1300 "$MANAGED_API_OBSERVED_AT" \
      "$case_name outcome must use post-provider time" || return 1
    assert_eq "$expected_backoff" "$MANAGED_API_BACKOFF_UNTIL" \
      "$case_name backoff must be anchored to post-provider time" || return 1
    grep -Fx 'observed_at=1300' "$AIRVPN_API_STATE_FILE" >/dev/null ||
      fail "$case_name post-provider observation must be durable" || return 1
    if [[ "$case_name" == transient ]]; then
      assert_eq 22900 "${MANAGED_API_EXCLUDE_EXPIRIES[0]}" \
        "failed-server expiry must be anchored to post-provider time" || return 1
    fi
    [[ ! -e "/proc/$BASHPID/fd/$credential_fd" ]] ||
      fail "$case_name managed attempt must close its credential owner descriptor" || return 1
  done

  rm -f -- "$AIRVPN_API_STATE_FILE"
  : > "$TEST_TMP/clock-events"
  CLOCK_CASE=regression
  MANAGED_TEST_ATTEMPT_EPOCH=1000
  MANAGED_TEST_OUTCOME_EPOCH=1000
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  PROBE_FD="$credential_fd"
  set +e
  managed_run_authenticated_attempt \
    0 "$credential_fd" timed_provider_probe timed_downstream_probe
  rc=$?
  set +e
  assert_eq 1 "$rc" "post-provider clock regression must fail closed" || return 1
  expected_events=$'lock-acquired\nclock:attempt:1100\nprovider:regression\nclock:outcome:1099\nlock-released'
  assert_eq "$expected_events" "$(<"$TEST_TMP/clock-events")" \
    "clock regression must still release the global lock after outcome rejection" || return 1
  grep -Fx 'observed_at=1100' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "clock regression must retain the durable post-lock attempt high-water" || return 1
  grep -Fx 'failure_class=none' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "clock regression must not persist a backdated failure outcome" || return 1
  assert_not_contains unexpected-downstream "$(<"$TEST_TMP/clock-events")" \
    "clock regression must block downstream work"
}

test_linux_managed_selector_persists_failure_rotates_and_reenables() {
  local credential_fd expected selected helper_parent rc
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  require_task5_contract || return 1
  declare -F managed_select_airvpn_candidate >/dev/null ||
    fail "production managed selector is missing" || return 1
  declare -F managed_fail_candidate_before_rollback >/dev/null ||
    fail "record-before-rollback seam is missing" || return 1
  setup_api_state_fixture
  helper_parent="$TEST_TMP/trusted"
  AIRVPN_API_HELPER="$helper_parent/airvpn-api"
  AIRVPN_STATUS_URL='https://airvpn.org/api/status/?format=json'
  AIRVPN_COUNTRIES='GB NL'
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  mkdir -p -- "$helper_parent"
  chmod 755 -- "$helper_parent"
  cat > "$AIRVPN_API_HELPER" <<'SELECTOR'
#!/usr/bin/env bash
set -u
if [[ -n "${PROBE_FD:-}" && -e "/proc/self/fd/$PROBE_FD" ]]; then
  printf 'credential-leaked\n' >> "$SELECTOR_EVENTS"
  exit 91
fi
printf '%s\n' "$@" > "$SELECTOR_ARGV"
printf 'called\n' >> "$SELECTOR_EVENTS"
excluded=0
while (( $# > 0 )); do
  if [[ "$1" == --exclude-server && ${2-} == Alpha-1 ]]; then excluded=1; shift 2; else shift; fi
done
if (( excluded )); then
  printf 'Bravo-2\t198.51.100.11:1637\tGB\tLondon\t10000\t50\t1\n'
else
  printf 'Alpha-1\t198.51.100.10:1637\tGB\tLondon\t10000\t0\t1\n'
fi
SELECTOR
  chmod 755 -- "$AIRVPN_API_HELPER"
  SELECTOR_ARGV="$TEST_TMP/selector.argv"
  SELECTOR_EVENTS="$TEST_TMP/selector.events"
  export SELECTOR_ARGV SELECTOR_EVENTS
  : > "$SELECTOR_EVENTS"

  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  managed_api_state_write || return 1
  : > "$TEST_TMP/sync-events"
  rollback_probe() {
    grep -Fx 'exclude_01=Alpha-1,22600' "$AIRVPN_API_STATE_FILE" >/dev/null || return 1
    printf 'rollback\n' >> "$TEST_TMP/sync-events"
  }
  managed_fail_candidate_before_rollback 1000 Alpha-1 rollback_probe || return 1
  assert_eq $'file\nfile\ndirectory\nrollback' "$(<"$TEST_TMP/sync-events")" \
    "failed candidate must be durable before the rollback seam" || return 1

  managed_api_state_defaults 1 || return 1
  managed_api_state_load 1001 || return 1
  write_valid_test_key "$TEST_TMP/selector-credential"
  chmod 600 -- "$TEST_TMP/selector-credential"
  touch -d '@900' -- "$TEST_TMP/selector-credential"
  exec {credential_fd}<"$TEST_TMP/selector-credential"
  PROBE_FD="$credential_fd"
  export PROBE_FD
  managed_select_airvpn_candidate selected 1001 "$credential_fd" '198.51.100.99:1637' || return 1
  assert_eq Bravo-2 "${selected%%$'\t'*}" \
    "production managed selector must choose the persisted alternate" || return 1
  expected=$'select\n--url\nhttps://airvpn.org/api/status/?format=json\n--countries\nGB NL\n--port\n1637\n--current-endpoint\n198.51.100.99:1637\n--timeout\n20\n--exclude-server\nAlpha-1'
  assert_eq "$expected" "$(<"$SELECTOR_ARGV")" \
    "production selector must use fixed public arguments and every live exclusion" || return 1
  assert_not_contains credential-leaked "$(<"$SELECTOR_EVENTS")" \
    "public selector helper must not inherit the credential descriptor" || return 1
  [[ -e "/proc/self/fd/$credential_fd" ]] || fail "public selection must not consume the credential FD" || return 1

  managed_select_airvpn_candidate selected 22600 "$credential_fd" '198.51.100.99:1637' || return 1
  assert_eq Alpha-1 "${selected%%$'\t'*}" \
    "expired persisted exclusion must restore the preferred server" || return 1
  assert_not_contains --exclude-server "$(<"$SELECTOR_ARGV")" \
    "expired exclusions must be absent from the production selector argv" || return 1

  : > "$SELECTOR_EVENTS"
  chmod 775 -- "$helper_parent"
  set +e
  managed_select_airvpn_candidate selected 22601 "$credential_fd" '198.51.100.99:1637'
  rc=$?
  set +e
  [[ "$rc" != 0 ]] || fail "untrusted selector helper must fail closed" || return 1
  assert_eq '' "$(<"$SELECTOR_EVENTS")" \
    "trust validation failure must prevent helper execution" || return 1
  exec {credential_fd}<&-
}

test_api_state_corruption_blocks_authenticated_and_downstream_callbacks() {
  local rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  printf 'version=1\nunknown=unsafe\n' > "$AIRVPN_API_STATE_FILE"
  chmod 600 -- "$AIRVPN_API_STATE_FILE"
  provider_probe() { printf 'provider\n' >> "$TEST_TMP/events"; }
  downstream_probe() { printf 'downstream\n' >> "$TEST_TMP/events"; }
  managed_global_api_lock_acquire() { MANAGED_API_LOCK_FD=99; }
  managed_global_api_lock_release() { MANAGED_API_LOCK_FD=; }
  : > "$TEST_TMP/events"

  set +e
  managed_run_authenticated_attempt 0 '' provider_probe downstream_probe
  rc=$?
  set +e
  [[ "$rc" != 0 ]] || fail "corrupt state must block the authenticated attempt" || return 1
  assert_eq '' "$(<"$TEST_TMP/events")" \
    "corrupt state must block provider, candidate, Docker, and tunnel callbacks"
}

test_api_global_lock_requires_interface_lock_and_releases_before_downstream() {
  local first_worker second_worker script_path
  source_managed_contract || return 1
  require_task5_contract || return 1
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  mkdir -p -- "$TEST_TMP/run" "$TEST_TMP/var" "$TEST_TMP/etc"
  chmod 700 -- "$TEST_TMP/run" "$TEST_TMP/var" "$TEST_TMP/etc"
  : > "$TEST_TMP/events"
  script_path="$TEST_TMP/worker.sh"
  cp -- "$SCRIPT" "$TEST_TMP/wg-healthcheck"
  cp -- "$MODULE" "$TEST_TMP/wg-healthcheck-managed"
  cat > "$script_path" <<'WORKER'
#!/usr/bin/env bash
set -u
source "$TEST_ROOT/wg-healthcheck"
source "$TEST_ROOT/wg-healthcheck-managed"
owner_mode() {
  local mode
  mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1
  printf '0:%s\n' "$mode"
}
managed_api_credential_fd_metadata() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_credential_fd="${2:?}"
  local wgmanaged_owner_pid wgmanaged_captured_metadata
  [[ "$wgmanaged_output_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "$wgmanaged_output_variable" != wgmanaged_* ]] || return 1
  validate_credential_fd_number "$wgmanaged_credential_fd" || return 1
  wgmanaged_owner_pid=$BASHPID
  [[ -f "/proc/$wgmanaged_owner_pid/fd/$wgmanaged_credential_fd" ]] || return 1
  wgmanaged_captured_metadata="$(
    stat -Lc '%d %i %Y %s' -- "/proc/$wgmanaged_owner_pid/fd/$wgmanaged_credential_fd" \
      {wgmanaged_credential_fd}<&- 2>/dev/null
  )" || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_captured_metadata 0 600"
}
managed_wall_clock_epoch() {
  case "${1-}" in attempt|outcome) printf '1000\n' ;; *) return 1 ;; esac
}
IFACE="$1"
AIRVPN_DEVICE=Device-One
STATE_DIR="$TEST_ROOT/run"
AIRVPN_API_LOCK="$STATE_DIR/airvpn-api.lock"
AIRVPN_API_STATE_FILE="$TEST_ROOT/var/$IFACE.api-state"
AIRVPN_API_KEY_FILE="$TEST_ROOT/etc/$IFACE.api-key"
LOCK="$STATE_DIR/$IFACE.lock"
printf '%064d\n' 0 > "$AIRVPN_API_KEY_FILE"
chmod 600 -- "$AIRVPN_API_KEY_FILE"
touch -d '@900' -- "$AIRVPN_API_KEY_FILE"
exec {LOCK_FD}>"$LOCK"
flock "$LOCK_FD"
CONTEXT_LOCKED=1
provider_probe() {
  if ! mkdir -- "$TEST_ROOT/provider.active" 2>/dev/null; then
    printf 'overlap:%s\n' "$IFACE" >> "$TEST_ROOT/events"
    return 6
  fi
  printf 'provider-start:%s\n' "$IFACE" >> "$TEST_ROOT/events"
  sleep 0.25
  printf 'provider-end:%s\n' "$IFACE" >> "$TEST_ROOT/events"
  rmdir -- "$TEST_ROOT/provider.active"
}
downstream_probe() {
  local probe_fd
  [[ -z "${MANAGED_API_LOCK_FD:-}" ]] || {
    printf 'owned-downstream:%s\n' "$IFACE" >> "$TEST_ROOT/events"
    return 1
  }
  if [[ "${PROVE_GLOBAL_FREE:-0}" == 1 ]]; then
    exec {probe_fd}>"$AIRVPN_API_LOCK"
    if ! flock -n "$probe_fd"; then
      printf 'held-downstream:%s\n' "$IFACE" >> "$TEST_ROOT/events"
      exec {probe_fd}>&-
      return 1
    fi
    flock -u "$probe_fd"
    exec {probe_fd}>&-
  fi
  printf 'downstream:%s\n' "$IFACE" >> "$TEST_ROOT/events"
}
managed_run_authenticated_attempt 0 '' provider_probe downstream_probe
WORKER
  chmod 700 -- "$script_path"

  CONTEXT_LOCKED=0
  AIRVPN_API_LOCK="$TEST_TMP/run/airvpn-api.lock"
  set +e; managed_global_api_lock_acquire ''; worker=$?; set +e
  [[ "$worker" != 0 ]] || fail "global lock must refuse reverse order without the interface lock" || return 1
  [[ ! -e "$AIRVPN_API_LOCK" ]] || fail "lock-order refusal must happen before opening the global lock" || return 1

  PROVE_GLOBAL_FREE=1 TEST_ROOT="$TEST_TMP" bash "$script_path" solo || return 1
  assert_not_contains held-downstream "$(<"$TEST_TMP/events")" \
    "a single worker must release the global lock before downstream work" || return 1
  : > "$TEST_TMP/events"
  TEST_ROOT="$TEST_TMP" bash "$script_path" wg0 &
  first_worker=$!
  TEST_ROOT="$TEST_TMP" bash "$script_path" wg1 &
  second_worker=$!
  wait "$first_worker" || { printf 'first worker failed\n' >&2; return 1; }
  wait "$second_worker" || { printf 'second worker failed\n' >&2; return 1; }
  assert_not_contains overlap "$(<"$TEST_TMP/events")" \
    "two interfaces must never overlap authenticated generator calls" || return 1
  assert_not_contains owned-downstream "$(<"$TEST_TMP/events")" \
    "each worker must relinquish its global lock before downstream Docker/tunnel work" || return 1
  assert_eq 2 "$(grep -c '^provider-start:' "$TEST_TMP/events")" \
    "both interface workers must reach the serialized provider" || return 1
  assert_eq 2 "$(grep -c '^downstream:' "$TEST_TMP/events")" \
    "both interface workers must begin downstream work after lock release"
}
