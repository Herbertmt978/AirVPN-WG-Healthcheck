#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_managed_module_exports_minimal_task4_contract() {
  local function_name
  source_managed_contract || return 1
  for function_name in open_installed_api_key managed_dispatch_command managed_reconcile_pending; do
    declare -F "$function_name" >/dev/null || fail "managed module must export $function_name" || return 1
  done
}

test_managed_module_validation_requires_root_owned_0644_trusted_source() {
  local case_name rc
  source "$SCRIPT"
  declare -F load_managed_module >/dev/null || fail "secure managed-module loader is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  MANAGED_MODULE="$TEST_TMP/libexec/wg-healthcheck/wg-healthcheck-managed"
  mkdir -p -- "${MANAGED_MODULE%/*}"
  printf 'TEST_MODULE_SOURCED=1\n' > "$MANAGED_MODULE"

  for case_name in secure source_symlink source_owner source_writable source_executable \
      parent_symlink parent_owner parent_writable; do
    unset TEST_MODULE_SOURCED
    MANAGED_MODULE_LOADED=0
    path_is_regular() { [[ "$case_name" != source_symlink ]]; }
    path_is_directory() { return 0; }
    path_is_symlink() {
      [[ "$case_name" == source_symlink && "$1" == "$MANAGED_MODULE" ]] ||
        [[ "$case_name" == parent_symlink && "$1" == "${MANAGED_MODULE%/*}" ]]
    }
    owner_mode() {
      if [[ "$1" == "$MANAGED_MODULE" ]]; then
        case "$case_name" in
          source_owner) printf '1000:644\n' ;;
          source_writable) printf '0:664\n' ;;
          source_executable) printf '0:744\n' ;;
          *) printf '0:644\n' ;;
        esac
      else
        case "$case_name" in
          parent_owner) printf '1000:755\n' ;;
          parent_writable) printf '0:775\n' ;;
          *) printf '0:755\n' ;;
        esac
      fi
    }

    set +e; load_managed_module >/dev/null 2>&1; rc=$?; set +e
    if [[ "$case_name" == secure ]]; then
      assert_eq 0 "$rc" "secure managed module must load" || return 1
      assert_eq 1 "${TEST_MODULE_SOURCED:-0}" "secure module must be sourced" || return 1
    else
      assert_eq 1 "$rc" "$case_name managed module must be rejected" || return 1
      assert_eq 0 "${TEST_MODULE_SOURCED:-0}" "rejected module must never be sourced" || return 1
    fi
  done
}

test_installed_key_rejects_every_unsafe_shape_before_downstream_events() {
  local case_name key_fd rc events parent
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/healthcheck.d"
  AIRVPN_API_KEY_FILE="$parent/wg0.api-key"
  mkdir -p -- "$parent"

  for case_name in missing symlink oversized multiline non_ascii wrong_owner wrong_mode unsafe_parent; do
    rm -f -- "$AIRVPN_API_KEY_FILE"
    case "$case_name" in
      missing) ;;
      oversized)
        printf '%065d\n' 0 > "$AIRVPN_API_KEY_FILE"
        ;;
      multiline)
        { printf '%031d\n' 0; printf '%032d\n' 0; } > "$AIRVPN_API_KEY_FILE"
        ;;
      non_ascii)
        { printf '\303\251'; printf '%062d\n' 0; } > "$AIRVPN_API_KEY_FILE"
        ;;
      *) write_valid_test_key "$AIRVPN_API_KEY_FILE" ;;
    esac
    : > "$TEST_TMP/events"
    path_is_regular() { [[ "$case_name" != missing ]]; }
    path_is_directory() { return 0; }
    path_is_symlink() { [[ "$case_name" == symlink && "$1" == "$AIRVPN_API_KEY_FILE" ]]; }
    owner_mode() {
      if [[ "$1" == "$AIRVPN_API_KEY_FILE" ]]; then
        case "$case_name" in
          wrong_owner) printf '1000:600\n' ;;
          wrong_mode) printf '0:640\n' ;;
          *) printf '0:600\n' ;;
        esac
      else
        case "$case_name" in
          unsafe_parent) printf '0:750\n' ;;
          *) printf '0:700\n' ;;
        esac
      fi
    }
    log() { :; }

    key_fd=
    set +e
    if open_installed_api_key key_fd; then
      printf '%s\n' provider candidate docker network >> "$TEST_TMP/events"
      rc=0
      exec {key_fd}<&-
    else
      rc=$?
    fi
    set +e
    events="$(<"$TEST_TMP/events")"
    assert_eq 1 "$rc" "$case_name installed key must fail closed" || return 1
    assert_eq '' "$events" "$case_name key failure must precede provider/candidate/Docker/network actions" || return 1
  done
}

test_installed_key_opens_one_valid_record_on_a_private_descriptor() {
  local count key_fd parent
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/healthcheck.d"
  AIRVPN_API_KEY_FILE="$parent/wg0.api-key"
  mkdir -p -- "$parent"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  path_is_regular() { return 0; }
  path_is_directory() { return 0; }
  path_is_symlink() { return 1; }
  owner_mode() { [[ "$1" == "$AIRVPN_API_KEY_FILE" ]] && printf '0:600\n' || printf '0:700\n'; }
  open_installed_api_key key_fd || return 1
  [[ "$key_fd" =~ ^[0-9]+$ ]] || fail "opened credential descriptor must be numeric" || return 1
  count="$(wc -c <&"$key_fd")"
  exec {key_fd}<&-
  assert_eq 65 "$count" "private descriptor must reference the exact one-record credential"
}

test_unknown_dispatch_closes_credential_before_logging() {
  local credential_fd leaked='' rc read_rc
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf 'managed-dispatch-sentinel\n' > "$TEST_TMP/credential"
  exec {credential_fd}<"$TEST_TMP/credential"
  : > "$TEST_TMP/events"
  log() {
    if IFS= read -r -u "$credential_fd" leaked 2>/dev/null; then
      printf 'leaked:%s\n' "$leaked" >> "$TEST_TMP/events"
      return 1
    fi
    printf 'closed-before-log\n' >> "$TEST_TMP/events"
  }

  set +e
  managed_dispatch_command unsupported-command dry-run 0 "$credential_fd"
  rc=$?
  set +e
  assert_eq 64 "$rc" "unknown managed command must retain its usage result" || return 1
  assert_eq closed-before-log "$(<"$TEST_TMP/events")" \
    "unknown-command dispatch must close the credential before any logger child" || return 1
  close_private_fd "$credential_fd" ||
    fail "main's final credential cleanup must remain safe after managed-owner closure" || return 1
  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "unknown managed dispatch must leave the credential descriptor closed"
}

test_api_state_exports_complete_task5_contract() {
  source_managed_contract || return 1
  require_task5_contract
}

test_api_state_round_trip_is_canonical_bounded_and_durable() {
  local content state_mode
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture

  managed_api_state_defaults 1100 || return 1
  MANAGED_API_OBSERVED_AT=1100
  MANAGED_API_WINDOW_START=1000
  MANAGED_API_ATTEMPT_COUNT=2
  MANAGED_API_ATTEMPT_EPOCHS=(1000 1100)
  MANAGED_API_BACKOFF_UNTIL=1300
  MANAGED_API_FAILURE_CLASS=transient
  MANAGED_API_CREDENTIAL_DEVICE=11
  MANAGED_API_CREDENTIAL_INODE=22
  MANAGED_API_CREDENTIAL_MTIME=33
  MANAGED_API_CREDENTIAL_SIZE=65
  MANAGED_API_CONFIGURED_DEVICE=Device-One
  MANAGED_API_EXCLUDE_NAMES=(Alpha-1 Bravo-2)
  MANAGED_API_EXCLUDE_EXPIRIES=(1200 1300)

  managed_api_state_write || return 1
  content="$(<"$AIRVPN_API_STATE_FILE")"
  assert_eq $'version=1\nobserved_at=1100\nwindow_start=1000\nattempt_count=2\nattempt_01=1000\nattempt_02=1100\nbackoff_until=1300\nfailure_class=transient\ncredential_device=11\ncredential_inode=22\ncredential_mtime=33\ncredential_size=65\nconfigured_device=Device-One\nexclude_count=2\nexclude_01=Alpha-1,1200\nexclude_02=Bravo-2,1300' \
    "$content" "state writer must use the canonical ordered v1 schema" || return 1
  state_mode="$(stat -c '%a' -- "$AIRVPN_API_STATE_FILE")" || return 1
  assert_eq 600 "$state_mode" "state file must be mode 0600" || return 1
  assert_eq $'file\nfile\ndirectory' "$(<"$TEST_TMP/sync-events")" \
    "atomic state write must sync temporary/final file and parent directory" || return 1
  for forbidden in digest private_key profile address endpoint; do
    assert_not_contains "$forbidden" "$content" "state must not retain private profile data" || return 1
  done
  assert_not_contains "$(printf '%064d' 0)" "$content" \
    "state must not retain the credential record" || return 1

  managed_api_state_defaults 1 || return 1
  managed_api_state_load 1100 || return 1
  assert_eq 2 "$MANAGED_API_ATTEMPT_COUNT" "state attempt count must round trip" || return 1
  assert_eq '1000 1100' "${MANAGED_API_ATTEMPT_EPOCHS[*]}" \
    "bounded attempt epochs must round trip in order" || return 1
  assert_eq transient "$MANAGED_API_FAILURE_CLASS" "state failure class must round trip" || return 1
  assert_eq 'Alpha-1 Bravo-2' "${MANAGED_API_EXCLUDE_NAMES[*]}" \
    "state exclusions must round trip in order"
}

test_api_state_defaults_are_memory_only_until_identity_refresh() {
  local rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1

  set +e; managed_api_state_write; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "zero identity defaults must never be persisted" || return 1
  [[ ! -e "$AIRVPN_API_STATE_FILE" ]] || fail "rejected defaults must leave no state file" || return 1
  MANAGED_API_CREDENTIAL_DEVICE=11
  MANAGED_API_CREDENTIAL_INODE=22
  MANAGED_API_CREDENTIAL_MTIME=33
  MANAGED_API_CREDENTIAL_SIZE=65
  set +e; managed_api_state_write; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "empty configured device must never be persisted" || return 1
  [[ ! -e "$AIRVPN_API_STATE_FILE" ]] || fail "rejected incomplete identity must leave no state file" || return 1

  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  managed_api_state_write || fail "refreshed credential/device identity must become persistable"
}

test_api_state_rejects_unknown_duplicate_malformed_control_and_future_data() {
  local base case_name rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  write_canonical_test_state "$AIRVPN_API_STATE_FILE"
  base="$(<"$AIRVPN_API_STATE_FILE")"

  for case_name in unknown duplicate out_of_order malformed control clock_regression \
      future_backoff future_exclusion duplicate_server gap count_mismatch \
      attempt_gap attempt_duplicate attempt_order attempt_future attempt_window_mismatch \
      attempt_over_limit \
      oversized; do
    case "$case_name" in
      unknown) printf '%s\nunknown_field=1\n' "$base" > "$AIRVPN_API_STATE_FILE" ;;
      duplicate) printf '%s\nattempt_count=1\n' "$base" > "$AIRVPN_API_STATE_FILE" ;;
      out_of_order)
        printf '%s\n' "$base" | sed 's/observed_at=1000/window_start=1000/;s/window_start=1000/observed_at=1000/2' > "$AIRVPN_API_STATE_FILE"
        ;;
      malformed) printf '%s\n' "${base/attempt_count=0/attempt_count=-1}" > "$AIRVPN_API_STATE_FILE" ;;
      control) printf '%s\n' "${base/configured_device=Device-One/$'configured_device=Device\rOne'}" > "$AIRVPN_API_STATE_FILE" ;;
      clock_regression) printf '%s\n' "${base/window_start=1000/window_start=1001}" > "$AIRVPN_API_STATE_FILE" ;;
      future_backoff) printf '%s\n' "${base/backoff_until=0/backoff_until=87401}" > "$AIRVPN_API_STATE_FILE" ;;
      future_exclusion)
        printf '%s\n' "${base/exclude_count=0/exclude_count=1}" 'exclude_01=Alpha,22601' > "$AIRVPN_API_STATE_FILE"
        ;;
      duplicate_server)
        printf '%s\n' "${base/exclude_count=0/exclude_count=2}" \
          'exclude_01=Alpha,2000' 'exclude_02=Alpha,2100' > "$AIRVPN_API_STATE_FILE"
        ;;
      gap)
        printf '%s\n' "${base/exclude_count=0/exclude_count=1}" 'exclude_02=Alpha,2000' > "$AIRVPN_API_STATE_FILE"
        ;;
      count_mismatch)
        printf '%s\n' "${base/exclude_count=0/exclude_count=2}" 'exclude_01=Alpha,2000' > "$AIRVPN_API_STATE_FILE"
        ;;
      attempt_gap)
        printf '%s\n' "${base/attempt_count=0/$'attempt_count=1\nattempt_02=900'}" > "$AIRVPN_API_STATE_FILE"
        ;;
      attempt_duplicate)
        printf '%s\n' "${base/attempt_count=0/$'attempt_count=2\nattempt_01=900\nattempt_01=950'}" > "$AIRVPN_API_STATE_FILE"
        ;;
      attempt_order)
        printf '%s\n' "${base/attempt_count=0/$'attempt_count=2\nattempt_01=1000\nattempt_02=900'}" > "$AIRVPN_API_STATE_FILE"
        ;;
      attempt_future)
        printf '%s\n' "${base/attempt_count=0/$'attempt_count=1\nattempt_01=1001'}" | \
          sed 's/window_start=1000/window_start=1001/' > "$AIRVPN_API_STATE_FILE"
        ;;
      attempt_window_mismatch)
        printf '%s\n' "${base/attempt_count=0/$'attempt_count=1\nattempt_01=900'}" | \
          sed 's/window_start=1000/window_start=901/' > "$AIRVPN_API_STATE_FILE"
        ;;
      attempt_over_limit)
        printf '%s\n' "${base/attempt_count=0/attempt_count=7}" > "$AIRVPN_API_STATE_FILE"
        ;;
      oversized) { printf '%s\n' "$base"; head -c 4096 /dev/zero | tr '\0' x; } > "$AIRVPN_API_STATE_FILE" ;;
    esac
    chmod 600 -- "$AIRVPN_API_STATE_FILE"
    set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
    [[ "$rc" != 0 ]] || fail "$case_name state must fail closed" || return 1
  done

  ln -sf -- "$TEST_TMP/not-state" "$AIRVPN_API_STATE_FILE"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "symlink state must fail closed"
}

test_api_state_rolling_attempt_cap_and_window_reset() {
  local attempt_epoch rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  MANAGED_API_CREDENTIAL_DEVICE=11
  MANAGED_API_CREDENTIAL_INODE=22
  MANAGED_API_CREDENTIAL_MTIME=33
  MANAGED_API_CREDENTIAL_SIZE=65
  MANAGED_API_CONFIGURED_DEVICE=Device-One
  managed_api_state_write || return 1

  managed_api_record_attempt 1000 0 || return 1
  for attempt_epoch in 87395 87396 87397 87398 87399; do
    managed_api_record_attempt "$attempt_epoch" 0 || return 1
  done
  managed_api_record_attempt 87400 0 || return 1
  assert_eq 6 "$MANAGED_API_ATTEMPT_COUNT" \
    "only the one epoch exactly outside the trailing day may be pruned" || return 1
  assert_eq '87395 87396 87397 87398 87399 87400' "${MANAGED_API_ATTEMPT_EPOCHS[*]}" \
    "recent pre-boundary attempts must survive the rolling-window boundary" || return 1
  assert_eq 87395 "$MANAGED_API_WINDOW_START" \
    "window start must track the oldest retained attempt" || return 1
  set +e; managed_api_record_attempt 87400 0; rc=$?; set +e
  assert_eq 75 "$rc" "boundary burst must not create a seventh trailing-day attempt" || return 1
  set +e; managed_api_record_attempt 87400 1; rc=$?; set +e
  assert_eq 75 "$rc" "administrative bypass must not bypass the exact rolling limit"
}

test_api_state_rejects_post_write_clock_regression() {
  local rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  managed_api_record_attempt 1000 0 || return 1
  managed_api_state_prune 2000 || return 1
  managed_api_state_write || return 1

  managed_api_state_defaults 1 || return 1
  set +e; managed_api_state_load 1500 >/dev/null 2>&1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "load must reject time before the last durable observation" || return 1
  managed_api_state_load 2000 || return 1
  assert_eq 2000 "$MANAGED_API_OBSERVED_AT" "non-regressed observation must load"
}

test_api_state_backoff_is_exponential_jitter_bounded_and_retry_after_capped() {
  local delay rc
  source_managed_contract || return 1
  require_task5_contract || return 1

  managed_compute_backoff delay 1 30 '' || return 1
  assert_eq 330 "$delay" "first transient delay must start at five minutes plus bounded jitter" || return 1
  managed_compute_backoff delay 2 60 '' || return 1
  assert_eq 660 "$delay" "second transient delay must double" || return 1
  managed_compute_backoff delay 20 2160 '' || return 1
  assert_eq 21600 "$delay" "transient delay including jitter must cap at six hours" || return 1
  managed_compute_backoff delay 1 0 86400 || return 1
  assert_eq 86400 "$delay" "valid Retry-After may extend backoff to 24 hours" || return 1
  set +e; managed_compute_backoff delay 1 31 ''; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "jitter above ten percent must be rejected" || return 1
  set +e; managed_compute_backoff delay 1 0 86401; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "Retry-After above 24 hours must be rejected"
}

test_output_variable_helpers_replace_collision_sentinels_and_reject_reserved_names() {
  local opened_fd=sentinel index=sentinel computed=sentinel captured_metadata=sentinel
  local credential_fd expected_metadata before_count after_count rc
  local wgmanaged_rejected=sentinel helper_case
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  setup_api_state_fixture
  # Exercise the production metadata helper even when generic state fixtures inject
  # root ownership for a normal-user run.
  source "$MODULE"

  before_count="$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" || return 1
  open_installed_api_key opened_fd || return 1
  [[ "$opened_fd" =~ ^[0-9]+$ && -e "/proc/$BASHPID/fd/$opened_fd" ]] ||
    fail "credential output named opened_fd must replace its caller sentinel" || return 1
  after_count="$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" || return 1
  assert_eq "$((before_count + 1))" "$after_count" \
    "credential success must expose exactly the one returned descriptor" || return 1
  exec {opened_fd}<&-
  assert_eq "$before_count" \
    "$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" \
    "closing the returned descriptor must restore the credential FD baseline" || return 1

  managed_api_state_defaults 1000 || return 1
  managed_api_state_add_exclusion Alpha-1 1000 || return 1
  managed_api_exclusion_args index 1000 || return 1
  assert_eq '--exclude-server Alpha-1' "${index[*]}" \
    "exclusion output named index must replace its caller sentinel" || return 1
  managed_compute_backoff computed 1 0 '' || return 1
  assert_eq 300 "$computed" "backoff output named computed must replace its caller sentinel" || return 1

  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  expected_metadata="$(
    stat -Lc '%d %i %Y %s %u %a' -- "/proc/$BASHPID/fd/$credential_fd" 2>/dev/null
  )" || return 1
  managed_api_credential_fd_metadata captured_metadata "$credential_fd" || return 1
  assert_eq "$expected_metadata" "$captured_metadata" \
    "credential metadata output named captured_metadata must replace its sentinel" || return 1
  captured_metadata=sentinel
  managed_capture_owner_mode captured_metadata "$AIRVPN_API_KEY_FILE" || return 1
  assert_eq "$(owner_mode "$AIRVPN_API_KEY_FILE")" "$captured_metadata" \
    "owner output named captured_metadata must replace its sentinel" || return 1

  before_count="$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" || return 1
  set +e
  open_installed_api_key wgmanaged_rejected
  rc=$?
  set +e
  [[ "$rc" != 0 ]] || fail "credential output names using the reserved prefix must fail" || return 1
  assert_eq sentinel "$wgmanaged_rejected" "rejected credential output must remain unchanged" || return 1
  after_count="$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" || return 1
  assert_eq "$before_count" "$after_count" \
    "rejected credential output must not leave an extra live key descriptor" || return 1

  for helper_case in exclusions backoff credential_metadata owner_metadata; do
    wgmanaged_rejected=sentinel
    set +e
    case "$helper_case" in
      exclusions) managed_api_exclusion_args wgmanaged_rejected 1000 ;;
      backoff) managed_compute_backoff wgmanaged_rejected 1 0 '' ;;
      credential_metadata)
        managed_api_credential_fd_metadata wgmanaged_rejected "$credential_fd"
        ;;
      owner_metadata)
        managed_capture_owner_mode wgmanaged_rejected "$AIRVPN_API_KEY_FILE"
        ;;
    esac
    rc=$?
    set +e
    [[ "$rc" != 0 ]] || fail "$helper_case must reject the reserved output prefix" || return 1
    assert_eq sentinel "$wgmanaged_rejected" \
      "$helper_case reserved output must remain unchanged" || return 1
  done
  exec {credential_fd}<&-
}

test_failed_credential_output_assignment_closes_new_descriptor() {
  local -r read_only_output=sentinel
  local before_count after_count rc
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  setup_api_state_fixture
  before_count="$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" || return 1
  set +e
  open_installed_api_key read_only_output 2>/dev/null
  rc=$?
  set +e
  [[ "$rc" != 0 ]] || fail "assignment into a read-only credential output must fail" || return 1
  after_count="$(count_open_descriptors_for_path "$BASHPID" "$AIRVPN_API_KEY_FILE")" || return 1
  assert_eq "$before_count" "$after_count" \
    "failed credential output assignment must close its newly opened key descriptor"
}

test_managed_selector_replaces_every_collision_name_with_and_without_credential() {
  local selector_fd='' helper_parent destination mode rc actual
  local expected=$'Bravo-2\t198.51.100.11:1637\tGB\tLondon\t10000\t50\t1'
  local candidate_output=sentinel output_variable=sentinel now=sentinel credential_fd=sentinel
  local current_endpoint=sentinel private_fd=sentinel exclusion_arguments=sentinel
  local selection_result_reference=sentinel wgmanaged_rejected=sentinel
  local -a collision_names=(
    candidate_output output_variable now credential_fd current_endpoint private_fd
    exclusion_arguments selection_result_reference
  )
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  helper_parent="$TEST_TMP/trusted"
  AIRVPN_API_HELPER="$helper_parent/airvpn-api"
  AIRVPN_STATUS_URL='https://airvpn.org/api/status/?format=json'
  AIRVPN_COUNTRIES='GB NL'
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  mkdir -p -- "$helper_parent"
  chmod 755 -- "$helper_parent"
  cat > "$AIRVPN_API_HELPER" <<'SELECTOR_COLLISION'
#!/usr/bin/env bash
set -u
if [[ -n "${PROBE_FD:-}" && -e "/proc/self/fd/$PROBE_FD" ]]; then
  printf 'credential-leaked\n' >> "$SELECTOR_EVENTS"
  exit 91
fi
printf 'called\n' >> "$SELECTOR_EVENTS"
printf 'Bravo-2\t198.51.100.11:1637\tGB\tLondon\t10000\t50\t1\n'
SELECTOR_COLLISION
  chmod 755 -- "$AIRVPN_API_HELPER"
  SELECTOR_EVENTS="$TEST_TMP/selector-collision.events"
  export SELECTOR_EVENTS

  for mode in without-credential with-credential; do
    selector_fd=''
    PROBE_FD=''
    if [[ "$mode" == with-credential ]]; then
      exec {selector_fd}<"$AIRVPN_API_KEY_FILE"
      PROBE_FD="$selector_fd"
    fi
    export PROBE_FD
    : > "$SELECTOR_EVENTS"
    for destination in "${collision_names[@]}"; do
      printf -v "$destination" '%s' sentinel
      managed_select_airvpn_candidate \
        "$destination" 1000 "$selector_fd" '198.51.100.99:1637' || return 1
      actual="${!destination}"
      assert_eq "$expected" "$actual" \
        "selector output $destination must replace its sentinel $mode" || return 1
    done
    assert_not_contains credential-leaked "$(<"$SELECTOR_EVENTS")" \
      "selector helper must not inherit the supplied credential descriptor" || return 1
    if [[ -n "$selector_fd" ]]; then
      [[ -e "/proc/$BASHPID/fd/$selector_fd" ]] ||
        fail "selector output handling must not consume the supplied credential" || return 1
      exec {selector_fd}<&-
    fi
  done

  exec {selector_fd}<"$AIRVPN_API_KEY_FILE"
  PROBE_FD="$selector_fd"
  export PROBE_FD
  set +e
  managed_select_airvpn_candidate \
    wgmanaged_rejected 1000 "$selector_fd" '198.51.100.99:1637'
  rc=$?
  set +e
  [[ "$rc" != 0 ]] || fail "selector must reject the reserved output prefix" || return 1
  assert_eq sentinel "$wgmanaged_rejected" "rejected selector output must remain unchanged" || return 1
  [[ -e "/proc/$BASHPID/fd/$selector_fd" ]] ||
    fail "rejected selector output must not consume the supplied credential" || return 1
  exec {selector_fd}<&-
}

test_api_state_auth_device_reset_only_on_identity_change() {
  local replacement rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  managed_api_state_refresh_identity 1000 || return 1
  MANAGED_API_FAILURE_CLASS=auth
  MANAGED_API_BACKOFF_UNTIL=87400
  managed_api_state_write || return 1

  set +e; managed_api_attempt_allowed 1100 0; rc=$?; set +e
  assert_eq 75 "$rc" "timer must remain suppressed for unchanged authentication failure" || return 1
  managed_api_state_refresh_identity 1100 || return 1
  assert_eq auth "$MANAGED_API_FAILURE_CLASS" "unchanged identity must not clear authentication suppression" || return 1

  AIRVPN_DEVICE=Device-Two
  managed_api_state_refresh_identity 1100 || return 1
  assert_eq none "$MANAGED_API_FAILURE_CLASS" "device change must clear authentication suppression" || return 1
  assert_eq 0 "$MANAGED_API_BACKOFF_UNTIL" "device change must clear authentication backoff" || return 1

  MANAGED_API_FAILURE_CLASS=auth
  MANAGED_API_BACKOFF_UNTIL=2000
  replacement="$AIRVPN_API_KEY_FILE.replacement"
  printf '1%063d\n' 0 > "$replacement"
  chmod 600 -- "$replacement"
  touch -d '@1050' -- "$replacement"
  mv -f -- "$replacement" "$AIRVPN_API_KEY_FILE"
  managed_api_state_refresh_identity 1100 || return 1
  assert_eq none "$MANAGED_API_FAILURE_CLASS" "credential replacement must clear authentication suppression" || return 1

  MANAGED_API_FAILURE_CLASS=rate
  MANAGED_API_BACKOFF_UNTIL=2000
  replacement="$AIRVPN_API_KEY_FILE.replacement"
  printf '2%063d\n' 0 > "$replacement"
  chmod 600 -- "$replacement"
  touch -d '@1050' -- "$replacement"
  mv -f -- "$replacement" "$AIRVPN_API_KEY_FILE"
  managed_api_state_refresh_identity 1100 || return 1
  assert_eq rate "$MANAGED_API_FAILURE_CLASS" "credential change must not clear rate suppression"
}

test_api_state_exclusions_are_unique_bounded_and_expire() {
  local index rc
  local -a args=()
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1

  for index in {0..15}; do
    managed_api_state_add_exclusion "Server-$index" $((1000 + index)) || return 1
  done
  assert_eq 16 "${#MANAGED_API_EXCLUDE_NAMES[@]}" "state must retain at most sixteen exclusions" || return 1
  managed_api_state_add_exclusion Server-16 1100 || return 1
  assert_eq 16 "${#MANAGED_API_EXCLUDE_NAMES[@]}" "seventeenth failure must evict one bounded entry" || return 1
  [[ " ${MANAGED_API_EXCLUDE_NAMES[*]} " != *' Server-0 '* ]] ||
    fail "oldest exclusion must be evicted deterministically" || return 1
  managed_api_state_add_exclusion Server-16 1200 || return 1
  assert_eq 16 "${#MANAGED_API_EXCLUDE_NAMES[@]}" "duplicate failed server must update, not duplicate" || return 1
  set +e; managed_api_state_add_exclusion 'bad/name' 1200; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "invalid failed-server name must be rejected" || return 1

  managed_api_exclusion_args args 1200 || return 1
  assert_eq 32 "${#args[@]}" "each live exclusion must become one fixed argv pair" || return 1
  managed_api_state_prune 22800 || return 1
  managed_api_exclusion_args args 22800 || return 1
  assert_eq 0 "${#args[@]}" "expired failed servers must become eligible again"
}

test_api_state_rejects_noncanonical_failure_classes_and_metadata() {
  local base case_name rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  write_canonical_test_state "$AIRVPN_API_STATE_FILE"
  base="$(<"$AIRVPN_API_STATE_FILE")"

  for case_name in derived_daily derived_corrupt leading_zero size_mismatch huge_inode \
      zero_metadata empty_device future_credential_mtime nonnone_zero_backoff \
      none_nonzero_backoff; do
    case "$case_name" in
      derived_daily)
        printf '%s\n' "${base/failure_class=none/failure_class=daily}" > "$AIRVPN_API_STATE_FILE"
        ;;
      derived_corrupt)
        printf '%s\n' "${base/failure_class=none/failure_class=corrupt}" > "$AIRVPN_API_STATE_FILE"
        ;;
      leading_zero)
        printf '%s\n' "${base/credential_mtime=33/credential_mtime=033}" > "$AIRVPN_API_STATE_FILE"
        ;;
      size_mismatch)
        printf '%s\n' "${base/credential_size=65/credential_size=64}" > "$AIRVPN_API_STATE_FILE"
        ;;
      huge_inode)
        printf '%s\n' "${base/credential_inode=22/credential_inode=18446744073709551616}" > "$AIRVPN_API_STATE_FILE"
        ;;
      zero_metadata)
        printf '%s\n' "$base" | sed \
          -e 's/credential_device=11/credential_device=0/' \
          -e 's/credential_inode=22/credential_inode=0/' \
          -e 's/credential_mtime=33/credential_mtime=0/' \
          -e 's/credential_size=65/credential_size=0/' > "$AIRVPN_API_STATE_FILE"
        ;;
      empty_device)
        printf '%s\n' "${base/configured_device=Device-One/configured_device=}" > "$AIRVPN_API_STATE_FILE"
        ;;
      future_credential_mtime)
        printf '%s\n' "${base/credential_mtime=33/credential_mtime=1301}" > "$AIRVPN_API_STATE_FILE"
        ;;
      nonnone_zero_backoff)
        printf '%s\n' "${base/failure_class=none/failure_class=transient}" > "$AIRVPN_API_STATE_FILE"
        ;;
      none_nonzero_backoff)
        printf '%s\n' "${base/backoff_until=0/backoff_until=1}" > "$AIRVPN_API_STATE_FILE"
        ;;
    esac
    chmod 600 -- "$AIRVPN_API_STATE_FILE"
    set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
    [[ "$rc" != 0 ]] || fail "$case_name metadata/class must fail closed" || return 1
  done
}

test_api_state_memory_rejects_future_mtime_and_zero_failure_backoff() {
  local rc
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_api_state_defaults 1000 || return 1
  MANAGED_API_CREDENTIAL_DEVICE=11
  MANAGED_API_CREDENTIAL_INODE=22
  MANAGED_API_CREDENTIAL_MTIME=1301
  MANAGED_API_CREDENTIAL_SIZE=65
  MANAGED_API_CONFIGURED_DEVICE=Device-One
  set +e; managed_api_state_memory_is_valid 1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "implausibly future credential mtime must fail in memory" || return 1

  MANAGED_API_CREDENTIAL_MTIME=900
  MANAGED_API_FAILURE_CLASS=transient
  MANAGED_API_BACKOFF_UNTIL=0
  set +e; managed_api_state_memory_is_valid 1; rc=$?; set +e
  [[ "$rc" != 0 ]] || fail "non-none failure without backoff must fail in memory"
}
