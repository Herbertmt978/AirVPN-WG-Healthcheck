#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, and
# security-boundary function doubles.
# shellcheck disable=SC1090,SC2034,SC2064,SC2317,SC2329

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/wg-healthcheck"
MODULE="$ROOT/libexec/wg-healthcheck-managed"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
  local needle="$1" haystack="$2" message="${3:-text not found}"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing '$needle')"
}

assert_not_contains() {
  local needle="$1" haystack="$2" message="${3:-unexpected text found}"
  [[ "$haystack" != *"$needle"* ]] || fail "$message (found '$needle')"
}

require_task5_contract() {
  local function_name
  for function_name in \
      managed_api_state_defaults managed_api_state_load managed_api_state_write \
      managed_api_state_prune managed_api_state_add_exclusion \
      managed_api_exclusion_args managed_api_attempt_allowed \
      managed_api_record_attempt managed_api_record_outcome \
      managed_api_state_refresh_identity managed_compute_backoff \
      managed_admin_dry_run_bypass managed_global_api_lock_acquire \
      managed_global_api_lock_release managed_run_authenticated_attempt; do
    declare -F "$function_name" >/dev/null ||
      fail "managed module must export Task 5 function $function_name" || return 1
  done
}

setup_api_state_fixture() {
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_STATE_FILE="$TEST_TMP/var/lib/wg-healthcheck/wg0.api-state"
  AIRVPN_API_KEY_FILE="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.api-key"
  STATE_DIR="$TEST_TMP/run/wg-healthcheck"
  AIRVPN_API_LOCK="$STATE_DIR/airvpn-api.lock"
  mkdir -p -- "${AIRVPN_API_STATE_FILE%/*}" "${AIRVPN_API_KEY_FILE%/*}" "$STATE_DIR"
  chmod 700 -- "${AIRVPN_API_STATE_FILE%/*}" "${AIRVPN_API_KEY_FILE%/*}" "$STATE_DIR"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  chmod 600 -- "$AIRVPN_API_KEY_FILE"
  touch -d '@900' -- "$AIRVPN_API_KEY_FILE"
  : > "$TEST_TMP/sync-events"
  owner_mode() {
    local mode
    mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1
    printf '0:%s\n' "$mode"
  }
  if [[ "$(id -u)" != 0 ]]; then
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
  fi
  MANAGED_TEST_ATTEMPT_EPOCH=1000
  MANAGED_TEST_OUTCOME_EPOCH=1000
  managed_wall_clock_epoch() {
    case "${1-}" in
      attempt) printf '%s\n' "$MANAGED_TEST_ATTEMPT_EPOCH" ;;
      outcome) printf '%s\n' "$MANAGED_TEST_OUTCOME_EPOCH" ;;
      *) return 1 ;;
    esac
  }
  managed_sync_file() { printf 'file\n' >> "$TEST_TMP/sync-events"; }
  managed_sync_directory() { printf 'directory\n' >> "$TEST_TMP/sync-events"; }
  CONTEXT_LOCKED=1
  LOCK_FD=9
}

write_canonical_test_state() {
  local destination="$1" window_start="${2:-1000}" attempt_count="${3:-0}" \
    backoff_until="${4:-0}" failure_class="${5:-none}" extra="${6:-}"
  printf '%s\n' \
    'version=1' \
    "observed_at=$window_start" \
    "window_start=$window_start" \
    "attempt_count=$attempt_count" \
    "backoff_until=$backoff_until" \
    "failure_class=$failure_class" \
    'credential_device=11' \
    'credential_inode=22' \
    'credential_mtime=33' \
    'credential_size=65' \
    'configured_device=Device-One' \
    'exclude_count=0' > "$destination"
  [[ -z "$extra" ]] || printf '%b' "$extra" >> "$destination"
  chmod 600 -- "$destination"
}

write_valid_test_key() {
  printf '%064d\n' 0 > "$1"
}

count_open_descriptors_for_path() {
  local owner_pid="${1:?}" target="${2:?}" target_identity descriptor descriptor_identity count=0
  target_identity="$(stat -Lc '%d:%i' -- "$target" 2>/dev/null)" || return 1
  for descriptor in "/proc/$owner_pid/fd/"[0-9]*; do
    descriptor_identity="$(stat -Lc '%d:%i' -- "$descriptor" 2>/dev/null)" || continue
    [[ "$descriptor_identity" == "$target_identity" ]] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

source_managed_contract() {
  [[ -f "$MODULE" ]] || fail "managed module is missing" || return 1
  source "$SCRIPT"
  source "$MODULE"
}

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

test_fail_closed_dispatch_closes_credential_before_logging() {
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
  managed_dispatch_command provision dry-run 0 "$credential_fd"
  rc=$?
  set +e
  assert_eq 69 "$rc" "fail-closed managed command must retain its unavailable result" || return 1
  assert_eq closed-before-log "$(<"$TEST_TMP/events")" \
    "fail-closed dispatch must close the credential before any logger child" || return 1
  close_private_fd "$credential_fd" ||
    fail "main's final credential cleanup must remain safe after managed-owner closure" || return 1
  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "fail-closed managed dispatch must leave the credential descriptor closed"
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

test_authenticated_attempt_closes_supplied_credential_around_state_and_downstream() {
  local credential_fd rc
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  printf 'private-descriptor-sentinel\n' > "$TEST_TMP/proposed-key"
  exec {credential_fd}<"$TEST_TMP/proposed-key"
  PROBE_FD="$credential_fd"
  : > "$TEST_TMP/fd-events"
  managed_api_state_load() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
    managed_api_state_defaults "$1"
  }
  managed_api_state_refresh_identity() { return 0; }
  managed_api_attempt_allowed() { return 0; }
  managed_api_record_attempt() { return 0; }
  managed_api_record_outcome() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
  }
  lock_child_probe() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
  }
  managed_global_api_lock_acquire() {
    [[ "$1" == "$PROBE_FD" && -e "/proc/self/fd/$PROBE_FD" ]] || return 1
    run_with_private_fd_closed "$1" lock_child_probe || return 1
    MANAGED_API_LOCK_FD=99
  }
  managed_global_api_lock_release() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
    MANAGED_API_LOCK_FD=
  }
  provider_probe() {
    [[ "$1" == "$PROBE_FD" && -e "/proc/self/fd/$PROBE_FD" ]] || return 1
    printf 'provider\n' >> "$TEST_TMP/fd-events"
  }
  downstream_probe() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
    printf 'downstream\n' >> "$TEST_TMP/fd-events"
  }

  managed_run_authenticated_attempt 0 "$credential_fd" provider_probe downstream_probe || return 1
  assert_eq $'provider\ndownstream' "$(<"$TEST_TMP/fd-events")" \
    "only the authenticated provider callback may observe the supplied credential" || return 1
  set +e; IFS= read -r -u "$credential_fd" _ 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "managed attempt owner must close the supplied descriptor after provider use"
}

test_linux_global_lock_fd_never_aliases_supplied_credential() {
  local competitor_fd credential_fd lock_target rc
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  PROBE_FD="$credential_fd"
  owner_mode() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
    if [[ -d "$1" ]]; then printf '0:700\n'; else printf '0:600\n'; fi
  }
  managed_chmod_api_lock() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
    chmod 600 -- "$1"
  }
  managed_flock_api_lock() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
    flock -x "$1"
  }
  : > "$TEST_TMP/alias-events"
  provider_lock_probe() {
    [[ "$1" == "$credential_fd" ]] || return 1
    [[ "$MANAGED_API_LOCK_FD" != "$credential_fd" ]] || {
      printf 'alias\n' >> "$TEST_TMP/alias-events"
      return 1
    }
    lock_target="$(readlink -- "/proc/self/fd/$MANAGED_API_LOCK_FD")" || return 1
    [[ "$lock_target" == "$AIRVPN_API_LOCK" ]] || {
      printf 'wrong-target\n' >> "$TEST_TMP/alias-events"
      return 1
    }
    exec {competitor_fd}>"$AIRVPN_API_LOCK" || return 1
    if flock -n "$competitor_fd"; then
      printf 'competitor-acquired\n' >> "$TEST_TMP/alias-events"
      flock -u "$competitor_fd" || true
      exec {competitor_fd}>&-
      return 1
    fi
    exec {competitor_fd}>&-
    printf 'provider-locked\n' >> "$TEST_TMP/alias-events"
  }
  downstream_lock_probe() { printf 'downstream\n' >> "$TEST_TMP/alias-events"; }

  managed_run_authenticated_attempt 0 "$credential_fd" provider_lock_probe downstream_lock_probe || return 1
  assert_eq $'provider-locked\ndownstream' "$(<"$TEST_TMP/alias-events")" \
    "provider must retain the distinct global lock until its outcome is durable" || return 1
  [[ -z "${MANAGED_API_LOCK_FD:-}" ]] || fail "global lock descriptor must clear after release" || return 1
  exec {competitor_fd}>"$AIRVPN_API_LOCK" || return 1
  set +e; flock -n "$competitor_fd"; rc=$?; set +e
  assert_eq 0 "$rc" "global lock must be acquirable after managed release" || return 1
  flock -u "$competitor_fd" || return 1
  exec {competitor_fd}>&-
}

test_linux_credential_identity_uses_exact_provider_fd_across_replacement() {
  local first_fd first_inode replacement second_inode rc
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source_managed_contract || return 1
  require_task5_contract || return 1
  setup_api_state_fixture
  managed_global_api_lock_acquire() { MANAGED_API_LOCK_FD=99; }
  managed_global_api_lock_release() { MANAGED_API_LOCK_FD=; }
  first_inode="$(stat -c '%i' -- "$AIRVPN_API_KEY_FILE")" || return 1
  exec {first_fd}<"$AIRVPN_API_KEY_FILE"
  replacement="$AIRVPN_API_KEY_FILE.replacement"
  printf '1%063d\n' 0 > "$replacement"
  chmod 600 -- "$replacement"
  touch -d '@950' -- "$replacement"
  second_inode="$(stat -c '%i' -- "$replacement")" || return 1
  mv -f -- "$replacement" "$AIRVPN_API_KEY_FILE"
  : > "$TEST_TMP/identity-events"
  provider_old_auth() {
    [[ "$1" == "$first_fd" ]] || return 1
    [[ "$(stat -Lc '%i' -- "/proc/self/fd/$1")" == "$first_inode" ]] || return 1
    printf 'old-auth\n' >> "$TEST_TMP/identity-events"
    return 4
  }
  provider_new_success() {
    [[ -n "$1" && "$(stat -Lc '%i' -- "/proc/self/fd/$1")" == "$second_inode" ]] || return 1
    printf 'new-success\n' >> "$TEST_TMP/identity-events"
  }
  identity_downstream() { printf 'downstream\n' >> "$TEST_TMP/identity-events"; }

  set +e
  managed_run_authenticated_attempt 0 "$first_fd" provider_old_auth identity_downstream
  rc=$?
  set +e
  assert_eq 4 "$rc" "old exact credential must record its authentication result" || return 1
  assert_eq "$first_inode" "$MANAGED_API_CREDENTIAL_INODE" \
    "persisted identity must belong to the exact provider credential FD" || return 1
  assert_eq auth "$MANAGED_API_FAILURE_CLASS" "old credential must enter auth suppression" || return 1

  MANAGED_TEST_ATTEMPT_EPOCH=1001
  MANAGED_TEST_OUTCOME_EPOCH=1001
  managed_run_authenticated_attempt 0 '' provider_new_success identity_downstream || return 1
  assert_eq $'old-auth\nnew-success\ndownstream' "$(<"$TEST_TMP/identity-events")" \
    "atomic path replacement must reset auth suppression on the next exact-FD run" || return 1
  assert_eq "$second_inode" "$MANAGED_API_CREDENTIAL_INODE" \
    "replacement credential identity must be persisted after its run" || return 1
  assert_eq none "$MANAGED_API_FAILURE_CLASS" "replacement success must clear auth suppression"
}

test_linux_supplied_credential_fd_is_private_until_managed_owner() {
  local credential_fd events leaked='' rc read_rc sentinel=private-fd-sentinel
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf '%s\n' "$sentinel" > "$TEST_TMP/credential"
  exec {credential_fd}<"$TEST_TMP/credential"
  PROBE_FD="$credential_fd"
  : > "$TEST_TMP/events"

  probe_fd_closed_in_child() {
    local stage="$1"
    if ! bash -c '
      fd="$1"
      [[ ! -e "/proc/self/fd/$fd" ]] || exit 1
      if IFS= read -r -u "$fd" value 2>/dev/null; then exit 1; fi
    ' bash "$PROBE_FD"; then
      printf 'leaked:%s\n' "$stage" >> "$TEST_TMP/events"
      return 1
    fi
    printf 'closed:%s\n' "$stage" >> "$TEST_TMP/events"
  }

  derive_fixed_runtime_paths() {
    probe_fd_closed_in_child context || return 1
    CFG="$TEST_TMP/health.conf"
    WG_CONF="$TEST_TMP/wg0.conf"
    STATE_DIR="$TEST_TMP/state"
    LOCK="$STATE_DIR/wg0.lock"
    ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
    MANAGED_MODULE="$TEST_TMP/wg-healthcheck-managed"
  }
  sanitize_process_environment() { probe_fd_closed_in_child environment; }
  is_root() { probe_fd_closed_in_child root-check; }
  validate_secure_file() { probe_fd_closed_in_child stat; }
  parse_healthcheck_config() {
    probe_fd_closed_in_child config || return 1
    AIRVPN_PROFILE_SOURCE=api
    AIRVPN_DEVICE=default
  }
  validate_settings() { probe_fd_closed_in_child settings; }
  prepare_state_dir() { probe_fd_closed_in_child state-dir || return 1; mkdir -p -- "$STATE_DIR"; }
  flock() { probe_fd_closed_in_child lock; }
  log() { probe_fd_closed_in_child log; }
  classify_pending_marker() {
    probe_fd_closed_in_child marker || return 1
    log preflight || return 1
    PENDING_KIND=v1
  }
  reconcile_pending_rotation() {
    probe_fd_closed_in_child reconciliation || return 1
    RECONCILED_PENDING=1
  }
  load_managed_module() {
    probe_fd_closed_in_child module || return 1
    managed_dispatch_command() {
      local received_fd="$4" record
      [[ "$received_fd" == "$PROBE_FD" ]] || return 1
      [[ "$LOCK_FD" != "$received_fd" && -e "/proc/self/fd/$LOCK_FD" ]] || return 1
      IFS= read -r -u "$received_fd" record || return 1
      [[ "$record" == "$sentinel" ]] || return 1
      printf 'owner:%s\n' "$record" >> "$TEST_TMP/events"
    }
  }

  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd"
  rc=$?
  set +e
  events="$(<"$TEST_TMP/events")"
  assert_eq 0 "$rc" "private descriptor must reach the exact managed owner without preflight leakage" || return 1
  for stage in context environment root-check stat config settings state-dir lock marker log reconciliation module; do
    assert_contains "closed:$stage" "$events" "credential must be absent in $stage child" || return 1
  done
  assert_contains "owner:$sentinel" "$events" \
    "managed owner must receive the original unconsumed credential record" || return 1
  [[ "$events" != *leaked:* ]] || fail "no pre-provider child may inherit the credential descriptor" || return 1

  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "main must close the original credential descriptor before returning" || return 1
  bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$credential_fd" ||
    fail "subsequent children must not inherit the credential descriptor"
}

test_linux_module_owner_and_mode_semantics() {
  local rc
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  MANAGED_MODULE="$TEST_TMP/trusted/wg-healthcheck-managed"
  mkdir -p -- "${MANAGED_MODULE%/*}"
  printf 'LINUX_MODULE_SOURCED=1\n' > "$MANAGED_MODULE"
  chmod 755 -- "${MANAGED_MODULE%/*}"
  chmod 644 -- "$MANAGED_MODULE"

  MANAGED_MODULE_LOADED=0
  load_managed_module || fail "real root-owned 0644 module under 0755 parent must load" || return 1
  assert_eq 1 "${LINUX_MODULE_SOURCED:-0}" "real secure module must be sourced" || return 1

  MANAGED_MODULE_LOADED=0
  chmod 664 -- "$MANAGED_MODULE"
  set +e; load_managed_module >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real group-writable module must fail" || return 1
  chmod 644 -- "$MANAGED_MODULE"
  chown 1 -- "$MANAGED_MODULE"
  MANAGED_MODULE_LOADED=0
  set +e; load_managed_module >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root module must fail"
}

test_linux_installed_key_owner_and_mode_semantics() {
  local key_fd parent rc
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/healthcheck.d"
  AIRVPN_API_KEY_FILE="$parent/wg0.api-key"
  mkdir -p -- "$parent"
  chmod 700 -- "$parent"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  chmod 600 -- "$AIRVPN_API_KEY_FILE"

  open_installed_api_key key_fd || fail "real root-owned 0600 key under 0700 parent must open" || return 1
  exec {key_fd}<&-
  chmod 640 -- "$AIRVPN_API_KEY_FILE"
  set +e; open_installed_api_key key_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real wrong-mode key must fail" || return 1
  chmod 600 -- "$AIRVPN_API_KEY_FILE"
  chmod 750 -- "$parent"
  set +e; open_installed_api_key key_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-0700 credential parent must fail" || return 1
  chmod 700 -- "$parent"
  chown 1 -- "$AIRVPN_API_KEY_FILE"
  set +e; open_installed_api_key key_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root key must fail"
}

test_linux_api_state_parent_file_owner_mode_and_symlink_semantics() {
  local parent rc
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/var/lib/wg-healthcheck"
  AIRVPN_API_STATE_FILE="$parent/wg0.api-state"
  mkdir -p -- "$parent"
  chmod 700 -- "$parent"
  write_canonical_test_state "$AIRVPN_API_STATE_FILE"
  managed_api_state_load 1000 || fail "secure persisted state must load" || return 1

  chmod 750 -- "$parent"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-0700 state parent must fail" || return 1
  chmod 700 -- "$parent"
  chown 1 -- "$parent"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-root state parent must fail" || return 1
  chown 0 -- "$parent"

  chmod 640 -- "$AIRVPN_API_STATE_FILE"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-0600 state file must fail" || return 1
  chmod 600 -- "$AIRVPN_API_STATE_FILE"
  chown 1 -- "$AIRVPN_API_STATE_FILE"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-root state file must fail" || return 1
  chown 0 -- "$AIRVPN_API_STATE_FILE"

  rm -f -- "$AIRVPN_API_STATE_FILE"
  ln -s -- "$TEST_TMP/elsewhere" "$AIRVPN_API_STATE_FILE"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "symlink state file must fail" || return 1

  rm -f -- "$AIRVPN_API_STATE_FILE"
  write_canonical_test_state "$AIRVPN_API_STATE_FILE"
  mv -- "$parent" "$parent.real"
  ln -s -- "$parent.real" "$parent"
  set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "symlink state parent must fail"
}

require_task6_contract() {
  local function_name
  for function_name in \
      managed_sha256_is_valid managed_sha256_file \
      managed_journal_load managed_journal_prepare managed_journal_transition \
      managed_classify_active_profile managed_classify_candidate_profile \
      managed_verify_journal_phase managed_reconcile_pending; do
    declare -F "$function_name" >/dev/null ||
      fail "managed module must export Task 6 function $function_name" || return 1
  done
}

require_task7_contract() {
  local function_name
  for function_name in \
      managed_qbittorrent_state managed_qbittorrent_ensure_stopped \
      managed_qbittorrent_restore_state managed_verify_live_profile_identity \
      managed_install_profile_atomically managed_profile_transaction \
      managed_rollback_profile_transaction managed_api_state_remove_exclusion; do
    declare -F "$function_name" >/dev/null ||
      fail "managed module must export Task 7 function $function_name" || return 1
  done
}

require_amended_task7_contract() {
  local function_name
  for function_name in \
      managed_profiles_have_same_private_identity managed_safety_load \
      managed_safety_prepare managed_safety_transition \
      managed_qb_snapshot managed_qb_containment_checkpoint \
      managed_qb_restore_recorded_intent managed_finalize_committed_transaction; do
    declare -F "$function_name" >/dev/null ||
      fail "managed module must export amended Task 7 function $function_name" || return 1
  done
}

write_managed_candidate_fixture() {
  local endpoint="${1:-198.51.100.20:1637}"
  printf '%s\n' \
    '[Interface]' \
    'Address = 192.0.2.2/32' \
    'PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' \
    '[Peer]' \
    'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' \
    'PresharedKey = fixture-new-preshared-value' \
    "Endpoint = $endpoint" \
    'AllowedIPs = 0.0.0.0/0' > "$MANAGED_CANDIDATE"
  chmod 600 -- "$MANAGED_CANDIDATE"
}

setup_managed_journal_fixture() {
  source_managed_contract || return 1
  require_task6_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  WG_CONF="$TEST_TMP/etc/wireguard/wg0.conf"
  ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
  MANAGED_SAFETY="${WG_CONF}.safety-healthcheck"
  MANAGED_CANDIDATE="${WG_CONF%/*}/.${WG_CONF##*/}.managed-candidate"
  STATUS_FILE="$TEST_TMP/run/wg-healthcheck/wg0.status"
  mkdir -p -- "${WG_CONF%/*}" "${STATUS_FILE%/*}"
  chmod 700 -- "${WG_CONF%/*}" "${STATUS_FILE%/*}"
  printf '%s\n' \
    '[Interface]' \
    'Address = 192.0.2.2/32' \
    'PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' \
    '[Peer]' \
    'PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
    'PresharedKey = fixture-old-preshared-value' \
    'Endpoint = 192.0.2.10:1637' \
    'AllowedIPs = 0.0.0.0/0' > "$WG_CONF"
  cp -- "$WG_CONF" "${WG_CONF}.bak-healthcheck"
  write_managed_candidate_fixture
  chmod 600 -- "$WG_CONF" "${WG_CONF}.bak-healthcheck"
  CONTEXT_LOCKED=1
  JOURNAL_TEST_FORCED_OWNER=''
  owner_mode() {
    local mode
    mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1
    if [[ -n "$JOURNAL_TEST_FORCED_OWNER" && "$1" == "$ROTATION_PENDING" ]]; then
      printf '%s:%s\n' "$JOURNAL_TEST_FORCED_OWNER" "$mode"
    else
      printf '0:%s\n' "$mode"
    fi
  }
  log() { printf 'log:%s\n' "$*" >> "$TEST_TMP/journal-events"; }
  write_status() { printf '%s:%s\n' "$1" "$2" >> "$TEST_TMP/journal-events"; }
  : > "$TEST_TMP/journal-events"
}

managed_journal_fixture_digests() {
  managed_sha256_file JOURNAL_TEST_BACKUP_SHA "${WG_CONF}.bak-healthcheck" || return 1
  managed_sha256_file JOURNAL_TEST_CANDIDATE_SHA "$MANAGED_CANDIDATE"
}

write_raw_managed_journal() {
  local phase="${1:?}" backup_sha="${2:?}" candidate_sha="${3:?}"
  local old_endpoint="${4:-192.0.2.10:1637}"
  local candidate_endpoint="${5:-198.51.100.20:1637}" qb_was_running="${6:-1}"
  printf '%s\n' \
    'version=2' \
    'transaction=managed-profile' \
    "phase=$phase" \
    "backup_sha256=$backup_sha" \
    "candidate_sha256=$candidate_sha" \
    "old_endpoint=$old_endpoint" \
    "candidate_endpoint=$candidate_endpoint" \
    "qb_was_running=$qb_was_running" > "$ROTATION_PENDING"
  chmod 600 -- "$ROTATION_PENDING"
}

write_raw_managed_safety() {
  local state="${1:?}" backup_sha="${2:?}" candidate_sha="${3:?}"
  local intent="${4:-running}"
  local container=qbittorrent container_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local process=qbittorrent-nox listen_ipv4=192.0.2.2 listen_port=6881
  if [[ "$intent" == unmanaged ]]; then
    container=- container_id=- process=- listen_ipv4=- listen_port=0
  fi
  printf '%s\n' \
    'version=1' \
    'record=managed-profile-safety' \
    "state=$state" \
    "backup_sha256=$backup_sha" \
    "candidate_sha256=$candidate_sha" \
    'old_endpoint=192.0.2.10:1637' \
    'candidate_endpoint=198.51.100.20:1637' \
    "qb_intent=$intent" \
    "qb_container=$container" \
    "qb_container_id=$container_id" \
    "qb_process=$process" \
    "qb_listen_ipv4=$listen_ipv4" \
    "qb_listen_port=$listen_port" > "$MANAGED_SAFETY"
  chmod 600 -- "$MANAGED_SAFETY"
}

test_managed_journal_round_trip_is_exact_and_rejects_noop_transactions() {
  local expected rc
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1

  managed_journal_prepare 1 || return 1
  expected="$(printf '%s\n' \
    'version=2' \
    'transaction=managed-profile' \
    'phase=prepared' \
    "backup_sha256=$JOURNAL_TEST_BACKUP_SHA" \
    "candidate_sha256=$JOURNAL_TEST_CANDIDATE_SHA" \
    'old_endpoint=192.0.2.10:1637' \
    'candidate_endpoint=198.51.100.20:1637' \
    'qb_was_running=1')"
  assert_eq "$expected" "$(<"$ROTATION_PENDING")" \
    "v2 journal bytes must use the exact canonical field order" || return 1
  managed_journal_load || return 1
  assert_eq prepared "$MANAGED_JOURNAL_PHASE" "journal phase must round-trip" || return 1
  assert_eq 1 "$MANAGED_JOURNAL_QB_WAS_RUNNING" "qB mode must round-trip" || return 1

  rm -f -- "$ROTATION_PENDING"
  cp -- "${WG_CONF}.bak-healthcheck" "$MANAGED_CANDIDATE"
  chmod 600 -- "$MANAGED_CANDIDATE"
  set +e
  managed_journal_prepare 0 >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "equal profile digests must be rejected as ambiguous" || return 1
  [[ ! -e "$ROTATION_PENDING" ]] || fail "ambiguous prepare must not create a marker" || return 1

  write_managed_candidate_fixture '192.0.2.10:1637'
  set +e
  managed_journal_prepare 0 >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "equal endpoints must be rejected as a no-op transaction" || return 1
  [[ ! -e "$ROTATION_PENDING" ]] || fail "no-op prepare must not create a marker" || return 1

  write_managed_candidate_fixture
  eval "$(declare -f managed_sha256_file | sed '1s/managed_sha256_file/managed_sha256_file_before_stability_probe/')"
  JOURNAL_TEST_CANDIDATE_READS=0
  managed_sha256_file() {
    managed_sha256_file_before_stability_probe "$@" || return 1
    if [[ "$2" == "$MANAGED_CANDIDATE" ]]; then
      JOURNAL_TEST_CANDIDATE_READS=$((JOURNAL_TEST_CANDIDATE_READS + 1))
      if (( JOURNAL_TEST_CANDIDATE_READS == 1 )); then
        printf '# changed after first digest\n' >> "$MANAGED_CANDIDATE"
      fi
    fi
  }
  set +e; managed_journal_prepare 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "prepare must reject artifacts that change between digest reads" || return 1
  (( JOURNAL_TEST_CANDIDATE_READS >= 2 )) ||
    fail "prepare must double-read the staged candidate" || return 1
  [[ ! -e "$ROTATION_PENDING" ]] || fail "unstable prepare must not create a marker"
}

test_managed_journal_rejects_noncanonical_bytes_fields_and_security_shapes() {
  local case_name rc parent canonical
  local -a lines=()
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1
  write_raw_managed_journal prepared "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA"
  canonical="$(<"$ROTATION_PENDING")"

  for case_name in duplicate unknown missing out_of_order bad_version bad_transaction \
      bad_phase uppercase_digest short_digest equal_digest noncanonical_old equal_endpoint bad_qb \
      control_byte missing_newline oversized; do
    printf '%s\n' "$canonical" > "$ROTATION_PENDING"
    chmod 600 -- "$ROTATION_PENDING"
    mapfile -t lines < "$ROTATION_PENDING"
    case "$case_name" in
      duplicate) printf '%s\n' "${lines[@]:0:3}" "${lines[2]}" "${lines[@]:3}" > "$ROTATION_PENDING" ;;
      unknown) lines[2]='unknown=value'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      missing) printf '%s\n' "${lines[@]:0:7}" > "$ROTATION_PENDING" ;;
      out_of_order)
        local swap="${lines[3]}"; lines[3]="${lines[4]}"; lines[4]="$swap"
        printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING"
        ;;
      bad_version) lines[0]='version=02'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      bad_transaction) lines[1]='transaction=endpoint'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      bad_phase) lines[2]='phase=rollback'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      uppercase_digest) lines[3]="backup_sha256=${JOURNAL_TEST_BACKUP_SHA^^}"; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      short_digest) lines[4]="candidate_sha256=${JOURNAL_TEST_CANDIDATE_SHA:0:63}"; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      equal_digest) lines[4]="candidate_sha256=$JOURNAL_TEST_BACKUP_SHA"; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      noncanonical_old) lines[5]='old_endpoint=192.0.2.010:1637'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      equal_endpoint) lines[6]='candidate_endpoint=192.0.2.10:1637'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      bad_qb) lines[7]='qb_was_running=true'; printf '%s\n' "${lines[@]}" > "$ROTATION_PENDING" ;;
      control_byte) printf '\001' >> "$ROTATION_PENDING" ;;
      missing_newline) printf '%s' "$canonical" > "$ROTATION_PENDING" ;;
      oversized) printf '%4097s' '' | tr ' ' x >> "$ROTATION_PENDING" ;;
    esac
    MANAGED_JOURNAL_PHASE=stale
    MANAGED_JOURNAL_BACKUP_SHA256=stale
    set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name journal shape must fail closed" || return 1
    assert_eq '' "${MANAGED_JOURNAL_PHASE-}" "$case_name parse failure must clear prior phase globals" || return 1
    assert_eq '' "${MANAGED_JOURNAL_BACKUP_SHA256-}" "$case_name parse failure must clear prior digest globals" || return 1
  done

  printf '%s\n' "$canonical" > "$ROTATION_PENDING"
  chmod 640 -- "$ROTATION_PENDING"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-0600 journal must fail" || return 1
  chmod 600 -- "$ROTATION_PENDING"
  JOURNAL_TEST_FORCED_OWNER=1
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  JOURNAL_TEST_FORCED_OWNER=''
  assert_eq 1 "$rc" "non-root journal must fail" || return 1

  parent="${ROTATION_PENDING%/*}"
  chmod 750 -- "$parent"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "non-0700 journal parent must fail" || return 1
  chmod 700 -- "$parent"
  rm -f -- "$ROTATION_PENDING"
  ln -s -- "$WG_CONF" "$ROTATION_PENDING"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "symlink journal must fail" || return 1
  rm -f -- "$ROTATION_PENDING"
  printf '%s\n' "$canonical" > "$ROTATION_PENDING"
  chmod 600 -- "$ROTATION_PENDING"
  mv -- "$parent" "$parent.real"
  ln -s -- "$parent.real" "$parent"
  set +e; managed_journal_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "symlink journal parent must fail"
}

test_managed_journal_write_is_same_directory_atomic_and_fully_durable() {
  local parent temporary tab marker_before rc leftovers
  local -a events=()
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1
  parent="${ROTATION_PENDING%/*}"
  : > "$TEST_TMP/sync-events"
  managed_sync_file() {
    printf 'file\t%s\t%s\n' "$1" "$(stat -c '%a' -- "$1")" >> "$TEST_TMP/sync-events"
  }
  managed_journal_move() {
    printf 'move\t%s\t%s\n' "$1" "$2" >> "$TEST_TMP/sync-events"
    command mv -fT -- "$1" "$2"
  }
  managed_sync_artifact_parent() {
    printf 'artifact-directory\t%s\t%s\n' "$1" "$(stat -c '%a' -- "$1")" >> "$TEST_TMP/sync-events"
  }
  managed_sync_journal_parent() {
    printf 'journal-directory\t%s\t%s\n' "$1" "$(stat -c '%a' -- "$1")" >> "$TEST_TMP/sync-events"
  }
  managed_sync_directory() {
    printf 'ambiguous-directory\t%s\t%s\n' "$1" "$(stat -c '%a' -- "$1")" >> "$TEST_TMP/sync-events"
  }

  managed_journal_prepare 0 || return 1
  mapfile -t events < "$TEST_TMP/sync-events"
  assert_eq 7 "${#events[@]}" "artifact and journal commit must expose seven ordered durability steps" || return 1
  IFS=$'\t' read -r _ temporary _ <<< "${events[3]}"
  tab=$'\t'
  [[ "${temporary%/*}" == "$parent" && "$temporary" == "$parent/.${ROTATION_PENDING##*/}.tmp."* ]] ||
    fail "journal temporary must be created beside the target" || return 1
  assert_eq "file${tab}${WG_CONF}.bak-healthcheck${tab}600" "${events[0]}" \
    "backup artifact must be synced first" || return 1
  assert_eq "file${tab}${MANAGED_CANDIDATE}${tab}600" "${events[1]}" \
    "candidate artifact must be synced second" || return 1
  assert_eq "artifact-directory${tab}${parent}${tab}700" "${events[2]}" \
    "shared artifact parent must be synced before the journal" || return 1
  assert_eq "file${tab}${temporary}${tab}600" "${events[3]}" \
    "journal temporary must be 0600 and synced after artifacts" || return 1
  assert_eq "move${tab}${temporary}${tab}${ROTATION_PENDING}" "${events[4]}" \
    "rename must follow temporary sync" || return 1
  assert_eq "file${tab}${ROTATION_PENDING}${tab}600" "${events[5]}" \
    "renamed journal must be synced" || return 1
  assert_eq "journal-directory${tab}${parent}${tab}700" "${events[6]}" \
    "journal parent barrier must be explicit and last" || return 1

  marker_before="$(<"$ROTATION_PENDING")"
  managed_sync_file() { return 1; }
  managed_journal_move() { command mv -fT -- "$1" "$2"; }
  managed_sync_journal_parent() { return 0; }
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "pre-rename sync failure must fail the transition" || return 1
  assert_eq "$marker_before" "$(<"$ROTATION_PENDING")" "pre-rename failure must preserve prior journal bytes" || return 1
  leftovers="$(find "$parent" -maxdepth 1 -name ".${ROTATION_PENDING##*/}.tmp.*" -print -quit)"
  assert_eq '' "$leftovers" "pre-rename failure must remove its private temporary" || return 1

  managed_sync_file() { [[ "$1" != "$ROTATION_PENDING" ]]; }
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-rename final-file sync failure must surface" || return 1
  managed_journal_load || return 1
  assert_eq client-stopped "$MANAGED_JOURNAL_PHASE" \
    "post-rename failure must leave the new canonical marker available for recovery"
}

test_managed_journal_artifacts_are_durable_before_first_digest() {
  local tab
  local -a events=()
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1
  : > "$TEST_TMP/order-events"
  eval "$(declare -f managed_sha256_file | sed '1s/managed_sha256_file/managed_sha256_file_before_order_probe/')"
  managed_sync_file() { printf 'sync-file\t%s\n' "$1" >> "$TEST_TMP/order-events"; }
  managed_sync_artifact_parent() { printf 'artifact-parent\t%s\n' "$1" >> "$TEST_TMP/order-events"; }
  managed_sync_journal_parent() { printf 'journal-parent\t%s\n' "$1" >> "$TEST_TMP/order-events"; }
  managed_sha256_file() {
    printf 'digest\t%s\n' "$2" >> "$TEST_TMP/order-events"
    managed_sha256_file_before_order_probe "$@"
  }

  managed_journal_prepare 0 || return 1
  mapfile -t events < "$TEST_TMP/order-events"
  tab=$'\t'
  assert_eq "sync-file${tab}${WG_CONF}.bak-healthcheck" "${events[0]-}" \
    "backup fsync must precede every content digest" || return 1
  assert_eq "sync-file${tab}${MANAGED_CANDIDATE}" "${events[1]-}" \
    "candidate fsync must precede every content digest" || return 1
  assert_eq "artifact-parent${tab}${WG_CONF%/*}" "${events[2]-}" \
    "artifact-parent fsync must precede every content digest" || return 1
  assert_eq "digest${tab}${WG_CONF}.bak-healthcheck" "${events[3]-}" \
    "first content digest must occur only after all artifact barriers"
}

test_managed_journal_artifact_barrier_failures_leave_no_journal_or_mutation() {
  local case_name rc parent leftovers events
  for case_name in backup candidate artifact-parent; do
    (
      setup_managed_journal_fixture || exit 1
      parent="${WG_CONF%/*}"
      cp -- "$WG_CONF" "$TEST_TMP/active.before"
      cp -- "${WG_CONF}.bak-healthcheck" "$TEST_TMP/backup.before"
      cp -- "$MANAGED_CANDIDATE" "$TEST_TMP/candidate.before"
      : > "$TEST_TMP/barrier-events"
      managed_sync_file() {
        printf 'artifact-file:%s\n' "$1" >> "$TEST_TMP/barrier-events"
        case "$case_name:$1" in
          "backup:${WG_CONF}.bak-healthcheck"|"candidate:${MANAGED_CANDIDATE}") return 1 ;;
          *) return 0 ;;
        esac
      }
      managed_sync_artifact_parent() {
        printf 'artifact-parent:%s\n' "$1" >> "$TEST_TMP/barrier-events"
        [[ "$case_name" != artifact-parent ]]
      }
      managed_sync_journal_parent() {
        printf 'unexpected-journal-parent\n' >> "$TEST_TMP/barrier-events"
        return 0
      }
      managed_journal_move() {
        printf 'unexpected-journal-move\n' >> "$TEST_TMP/barrier-events"
        command mv -fT -- "$1" "$2"
      }

      set +e; managed_journal_prepare 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name artifact barrier failure must fail prepare" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]] ||
        fail "$case_name artifact barrier failure must not create a marker" || exit 1
      leftovers="$(find "$parent" -maxdepth 1 -name ".${ROTATION_PENDING##*/}.tmp.*" -print -quit)"
      assert_eq '' "$leftovers" "$case_name artifact barrier failure must leave no journal temporary" || exit 1
      cmp -s -- "$TEST_TMP/active.before" "$WG_CONF" ||
        fail "$case_name artifact barrier failure changed active bytes" || exit 1
      cmp -s -- "$TEST_TMP/backup.before" "${WG_CONF}.bak-healthcheck" ||
        fail "$case_name artifact barrier failure changed backup bytes" || exit 1
      cmp -s -- "$TEST_TMP/candidate.before" "$MANAGED_CANDIDATE" ||
        fail "$case_name artifact barrier failure changed candidate bytes" || exit 1
      events="$(<"$TEST_TMP/barrier-events")"
      [[ "$events" != *unexpected-journal* ]] ||
        fail "$case_name artifact failure must precede every journal action" || exit 1
    ) || return 1
  done
}

test_managed_journal_classifiers_are_collision_safe_and_failure_atomic() {
  local case_name expected rc journal_actual_digest wgmanaged_reserved_destination
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1
  for case_name in active candidate; do
    journal_actual_digest=sentinel
    if [[ "$case_name" == active ]]; then
      managed_classify_active_profile journal_actual_digest \
        "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA" || return 1
      expected=backup
    else
      managed_classify_candidate_profile journal_actual_digest \
        "$JOURNAL_TEST_CANDIDATE_SHA" || return 1
      expected=present
    fi
    assert_eq "$expected" "$journal_actual_digest" \
      "$case_name classifier must replace a collision-prone caller destination" || return 1

    journal_actual_digest=sentinel
    if [[ "$case_name" == active ]]; then
      set +e; managed_classify_active_profile journal_actual_digest invalid \
        "$JOURNAL_TEST_CANDIDATE_SHA" >/dev/null 2>&1; rc=$?; set +e
    else
      set +e; managed_classify_candidate_profile journal_actual_digest invalid \
        >/dev/null 2>&1; rc=$?; set +e
    fi
    assert_eq 1 "$rc" "$case_name classifier must reject an invalid digest" || return 1
    assert_eq sentinel "$journal_actual_digest" \
      "$case_name classifier failure must not mutate the caller destination" || return 1

    wgmanaged_reserved_destination=sentinel
    if [[ "$case_name" == active ]]; then
      set +e; managed_classify_active_profile wgmanaged_reserved_destination \
        "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA" >/dev/null 2>&1; rc=$?; set +e
    else
      set +e; managed_classify_candidate_profile wgmanaged_reserved_destination \
        "$JOURNAL_TEST_CANDIDATE_SHA" >/dev/null 2>&1; rc=$?; set +e
    fi
    assert_eq 1 "$rc" "$case_name classifier must reject reserved output names" || return 1
    assert_eq sentinel "$wgmanaged_reserved_destination" \
      "$case_name reserved-name failure must not mutate the caller destination" || return 1
  done
}

test_managed_journal_phase_transitions_revalidate_all_digests_and_classify_factually() {
  local active_class candidate_class rc marker_before
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1
  managed_sha256_is_valid "$JOURNAL_TEST_BACKUP_SHA" || return 1
  set +e; managed_sha256_is_valid "${JOURNAL_TEST_BACKUP_SHA^^}"; rc=$?; set +e
  assert_eq 1 "$rc" "SHA-256 grammar must accept lowercase only" || return 1

  managed_journal_prepare 1 || return 1
  managed_classify_active_profile active_class "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA" || return 1
  managed_classify_candidate_profile candidate_class "$JOURNAL_TEST_CANDIDATE_SHA" || return 1
  assert_eq backup "$active_class" "prepared active file must classify as backup" || return 1
  assert_eq present "$candidate_class" "staged candidate must classify as present" || return 1
  managed_journal_transition client-stopped || return 1
  managed_journal_transition tunnel-down || return 1
  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  managed_classify_active_profile active_class "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA" || return 1
  assert_eq candidate "$active_class" "installed active file must classify as candidate" || return 1
  managed_journal_transition candidate-installed || return 1
  managed_journal_transition candidate-up || return 1
  managed_journal_transition verified || return 1
  managed_journal_load || return 1
  assert_eq verified "$MANAGED_JOURNAL_PHASE" "exact legal chain must reach verified" || return 1

  rm -f -- "$ROTATION_PENDING"
  cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  managed_journal_prepare 0 || return 1
  marker_before="$(<"$ROTATION_PENDING")"
  set +e; managed_journal_transition tunnel-down >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "phase jumps must be rejected" || return 1
  assert_eq "$marker_before" "$(<"$ROTATION_PENDING")" "illegal transition must not rewrite journal" || return 1

  printf 'tamper\n' >> "$MANAGED_CANDIDATE"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "candidate digest mismatch must block every forward transition" || return 1
  assert_eq "$marker_before" "$(<"$ROTATION_PENDING")" "candidate mismatch must retain exact marker" || return 1
  write_managed_candidate_fixture
  printf 'tamper\n' >> "${WG_CONF}.bak-healthcheck"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "backup digest mismatch must block every forward transition" || return 1

  cp -- "$WG_CONF" "${WG_CONF}.bak-healthcheck"
  chmod 600 -- "${WG_CONF}.bak-healthcheck"
  printf 'unknown-active\n' > "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "unknown active digest must block a phase transition" || return 1

  cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  managed_classify_active_profile active_class "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_BACKUP_SHA" || return 1
  assert_eq ambiguous "$active_class" "equal recorded digests must classify factually as ambiguous"
}

test_managed_journal_rejects_digest_bound_false_endpoints_before_transition_or_recovery() {
  local case_name wrong_old wrong_candidate rc marker_before events
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1

  for case_name in backup candidate; do
    wrong_old='192.0.2.10:1637'
    wrong_candidate='198.51.100.20:1637'
    if [[ "$case_name" == backup ]]; then
      wrong_old='203.0.113.50:1637'
    else
      wrong_candidate='203.0.113.51:1637'
    fi
    write_raw_managed_journal prepared "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" "$wrong_old" "$wrong_candidate" 0
    write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" unmanaged
    marker_before="$(<"$ROTATION_PENDING")"
    managed_journal_load || fail "$case_name forged journal remains syntactically canonical" || return 1

    set +e; managed_verify_journal_phase prepared >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name recorded endpoint must be bound to its digest artifact" || return 1
    set +e; managed_journal_transition client-stopped >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name endpoint disagreement must block transition" || return 1
    assert_eq "$marker_before" "$(<"$ROTATION_PENDING")" \
      "$case_name endpoint disagreement must retain exact journal bytes" || return 1

    : > "$TEST_TMP/journal-events"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    events="$(<"$TEST_TMP/journal-events")"
    assert_eq 1 "$rc" "$case_name endpoint disagreement must fail reconciliation" || return 1
    assert_contains managed_rotation_digest_or_artifact_mismatch "$events" \
      "$case_name endpoint disagreement must surface as an artifact mismatch" || return 1
    [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
      fail "$case_name endpoint mismatch must retain marker and candidate" || return 1
  done
}

write_private_identity_profile() {
  local destination="${1:?}" private_key="${2:?}" address="${3:?}"
  local table="${4:--}"
  {
    printf '%s\n' \
      '[Interface]' \
      "Address = $address" \
      "PrivateKey = $private_key"
    [[ "$table" == - ]] || printf 'Table = %s\n' "$table"
    printf '%s\n' \
      '[Peer]' \
      'PublicKey = AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=' \
      'PresharedKey = BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=' \
      'Endpoint = 198.51.100.20:1637' \
      'AllowedIPs = 0.0.0.0/0'
  } > "$destination"
  chmod 600 -- "$destination"
}

test_private_identity_comparator_is_status_only_strict_and_secret_safe() {
  local rc trace_fd captured case_name
  local key_one='AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE='
  local key_two='AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI='
  local zero_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
  setup_managed_journal_fixture || return 1
  declare -F managed_profiles_have_same_private_identity >/dev/null ||
    fail "amended Task 7 secret-safe identity comparator is missing" || return 1

  write_private_identity_profile "$WG_CONF" "$key_one" 192.0.2.2/32 -
  write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 -
  managed_profiles_have_same_private_identity "$WG_CONF" ||
    fail "matching nonzero private identity must pass" || return 1

  for case_name in private-key address ipv6 prefix leading-zero table-presence \
      duplicate-key duplicate-address duplicate-table invalid-table-zero \
      invalid-table-leading-zero invalid-table-high zero-key duplicate-interface \
      outside-field multiple-address prefix-032 octet-high table-case; do
    write_private_identity_profile "$WG_CONF" "$key_one" 192.0.2.2/32 -
    write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 -
    case "$case_name" in
      private-key) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_two" 192.0.2.2/32 - ;;
      address) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.3/32 - ;;
      ipv6) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 2001:db8::2/32 - ;;
      prefix) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/24 - ;;
      leading-zero) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.002.2/32 - ;;
      table-presence) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 auto ;;
      duplicate-key) sed -i '/^\[Peer\]/i PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' "$MANAGED_CANDIDATE" ;;
      duplicate-address) sed -i '/^\[Peer\]/i Address = 192.0.2.2/32' "$MANAGED_CANDIDATE" ;;
      duplicate-table)
        write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 auto
        sed -i '/^\[Peer\]/i Table = auto' "$MANAGED_CANDIDATE"
        ;;
      invalid-table-zero) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 0 ;;
      invalid-table-leading-zero) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 01 ;;
      invalid-table-high) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 4294967296 ;;
      zero-key)
        write_private_identity_profile "$WG_CONF" "$zero_key" 192.0.2.2/32 -
        write_private_identity_profile "$MANAGED_CANDIDATE" "$zero_key" 192.0.2.2/32 -
        ;;
      duplicate-interface) sed -i '1i [Interface]' "$MANAGED_CANDIDATE" ;;
      outside-field) sed -i '1i PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' "$MANAGED_CANDIDATE" ;;
      multiple-address) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" '192.0.2.2/32,192.0.2.3/32' - ;;
      prefix-032) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/032 - ;;
      octet-high) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.256/32 - ;;
      table-case) write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 Auto ;;
    esac
    set +e
    managed_profiles_have_same_private_identity "$WG_CONF" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 1 "$rc" "$case_name identity shape must fail closed" || return 1
  done

  for captured in auto off 1 4294967295; do
    write_private_identity_profile "$WG_CONF" "$key_one" 192.0.2.2/32 "$captured"
    write_private_identity_profile "$MANAGED_CANDIDATE" "$key_one" 192.0.2.2/32 "$captured"
    managed_profiles_have_same_private_identity "$WG_CONF" ||
      fail "canonical matching Table=$captured must pass" || return 1
  done

  cp -- "$WG_CONF" "$TEST_TMP/arbitrary-reference"
  chmod 600 -- "$TEST_TMP/arbitrary-reference"
  set +e; managed_profiles_have_same_private_identity "$TEST_TMP/arbitrary-reference" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "identity reference path must be fixed" || return 1
  set +e; managed_profiles_have_same_private_identity "$WG_CONF" "$MANAGED_CANDIDATE" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "identity comparator must reject a caller-selected candidate path" || return 1

  write_private_identity_profile "$WG_CONF" "$key_two" 192.0.2.2/32 off
  write_private_identity_profile "$MANAGED_CANDIDATE" "$key_two" 192.0.2.2/32 off
  : > "$TEST_TMP/identity-output"
  : > "$TEST_TMP/identity-errors"
  : > "$TEST_TMP/identity-trace"
  exec {trace_fd}>"$TEST_TMP/identity-trace" || return 1
  BASH_XTRACEFD=$trace_fd
  set -x
  managed_profiles_have_same_private_identity "$WG_CONF" \
    >"$TEST_TMP/identity-output" 2>"$TEST_TMP/identity-errors"
  rc=$?
  set +x
  exec {trace_fd}>&-
  unset BASH_XTRACEFD
  assert_eq 0 "$rc" "status-only comparator must succeed without output" || return 1
  captured="$(find "$TEST_TMP" -maxdepth 1 -type f \
    \( -name 'identity-*' -o -name 'journal-events' \) -exec sed -n '1,$p' {} + 2>/dev/null)"
  assert_not_contains "$key_two" "$captured" \
    "private-key canary must not enter output, errors, logs, or xtrace" || return 1
  assert_eq '' "$(<"$TEST_TMP/identity-output")" "identity comparator stdout must remain empty" || return 1
  assert_eq '' "$(<"$TEST_TMP/identity-errors")" "identity comparator stderr must remain empty"
}

test_managed_safety_contract_is_strict_and_exact() {
  local backup_digest candidate_digest expected case_name rc
  setup_managed_journal_fixture || return 1
  declare -F managed_safety_prepare >/dev/null ||
    fail "amended Task 7 safety-record owner is missing" || return 1
  declare -F managed_safety_load >/dev/null ||
    fail "amended Task 7 safety-record parser is missing" || return 1
  declare -F managed_safety_transition >/dev/null ||
    fail "amended Task 7 safety-record transition owner is missing" || return 1
  managed_sha256_file backup_digest "${WG_CONF}.bak-healthcheck" || return 1
  managed_sha256_file candidate_digest "$MANAGED_CANDIDATE" || return 1
  MANAGED_QB_INTENT=running
  MANAGED_QB_CONTAINER=qbittorrent
  MANAGED_QB_CONTAINER_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  MANAGED_QB_PROCESS=qbittorrent-nox
  MANAGED_QB_LISTEN_IPV4=192.0.2.2
  MANAGED_QB_LISTEN_PORT=6881
  managed_safety_prepare || return 1
  expected="$(printf '%s\n' \
    'version=1' \
    'record=managed-profile-safety' \
    'state=pending' \
    "backup_sha256=$backup_digest" \
    "candidate_sha256=$candidate_digest" \
    'old_endpoint=192.0.2.10:1637' \
    'candidate_endpoint=198.51.100.20:1637' \
    'qb_intent=running' \
    'qb_container=qbittorrent' \
    'qb_container_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'qb_process=qbittorrent-nox' \
    'qb_listen_ipv4=192.0.2.2' \
    'qb_listen_port=6881')"
  assert_eq "$expected" "$(<"$MANAGED_SAFETY")" \
    "safety record must use the exact canonical 13-line schema" || return 1
  managed_safety_load || return 1
  assert_eq pending "$MANAGED_SAFETY_STATE" "pending state must round-trip" || return 1
  assert_eq running "$MANAGED_SAFETY_QB_INTENT" "qB intent must round-trip" || return 1
  assert_eq "$MANAGED_QB_CONTAINER_ID" "$MANAGED_SAFETY_QB_CONTAINER_ID" \
    "immutable container ID must round-trip" || return 1
  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  rm -f -- "$MANAGED_CANDIDATE"
  managed_safety_transition committed || return 1
  managed_safety_load || return 1
  assert_eq committed "$MANAGED_SAFETY_STATE" "pending must transition to committed" || return 1
  managed_safety_transition finalizing || return 1
  managed_safety_load || return 1
  assert_eq finalizing "$MANAGED_SAFETY_STATE" "committed must transition to finalizing" || return 1
  set +e; managed_safety_transition pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "safety state transitions must never move backward" || return 1

  cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  write_managed_candidate_fixture

  for case_name in unknown duplicate bad-state equal-digest equal-endpoint bad-id \
      partial-unmanaged partial-running bad-listen bad-port control no-final-lf; do
    printf '%s\n' "$expected" > "$MANAGED_SAFETY"
    case "$case_name" in
      unknown) printf 'unknown=value\n' >> "$MANAGED_SAFETY" ;;
      duplicate) printf 'state=pending\n' >> "$MANAGED_SAFETY" ;;
      bad-state) sed -i 's/^state=pending$/state=rollback/' "$MANAGED_SAFETY" ;;
      equal-digest) sed -i "s/^candidate_sha256=.*/candidate_sha256=$backup_digest/" "$MANAGED_SAFETY" ;;
      equal-endpoint) sed -i 's/^candidate_endpoint=.*/candidate_endpoint=192.0.2.10:1637/' "$MANAGED_SAFETY" ;;
      bad-id) sed -i 's/^qb_container_id=.*/qb_container_id=AAAA/' "$MANAGED_SAFETY" ;;
      partial-unmanaged)
        sed -i 's/^qb_intent=.*/qb_intent=unmanaged/' "$MANAGED_SAFETY"
        ;;
      partial-running) sed -i 's/^qb_process=.*/qb_process=-/' "$MANAGED_SAFETY" ;;
      bad-listen) sed -i 's/^qb_listen_ipv4=.*/qb_listen_ipv4=192.0.002.2/' "$MANAGED_SAFETY" ;;
      bad-port) sed -i 's/^qb_listen_port=.*/qb_listen_port=0/' "$MANAGED_SAFETY" ;;
      control) printf '\001' >> "$MANAGED_SAFETY" ;;
      no-final-lf) truncate -s -1 "$MANAGED_SAFETY" ;;
    esac
    chmod 600 -- "$MANAGED_SAFETY"
    set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name safety shape must fail closed" || return 1
  done

  printf '%s\n' "$expected" > "$MANAGED_SAFETY"
  chmod 640 -- "$MANAGED_SAFETY"
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "wrong-mode safety record must fail" || return 1
  chmod 600 -- "$MANAGED_SAFETY"
  printf '%s\n' "$expected" > "$TEST_TMP/safety-real"
  rm -f -- "$MANAGED_SAFETY"
  ln -s -- "$TEST_TMP/safety-real" "$MANAGED_SAFETY"
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "safety symlink must fail" || return 1
  rm -f -- "$MANAGED_SAFETY"
  { printf '%s\n' "$expected"; head -c 4096 /dev/zero | tr '\0' X; } > "$MANAGED_SAFETY"
  chmod 600 -- "$MANAGED_SAFETY"
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "oversized safety record must fail" || return 1
  printf '%s\r\n' "$expected" > "$MANAGED_SAFETY"
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "CRLF safety record must fail" || return 1
  printf '%s\n' "$expected" > "$MANAGED_SAFETY"
  sed -i '4{h;d};5{G;}' "$MANAGED_SAFETY"
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "reordered safety fields must fail" || return 1

  rm -f -- "$MANAGED_SAFETY"
  MANAGED_QB_INTENT=stopped
  managed_safety_prepare || return 1
  managed_safety_load || return 1
  assert_eq stopped "$MANAGED_SAFETY_QB_INTENT" "stopped safety intent must round-trip" || return 1
  rm -f -- "$MANAGED_SAFETY"
  MANAGED_QB_INTENT=unmanaged
  MANAGED_QB_CONTAINER=-
  MANAGED_QB_CONTAINER_ID=-
  MANAGED_QB_PROCESS=-
  MANAGED_QB_LISTEN_IPV4=-
  MANAGED_QB_LISTEN_PORT=0
  managed_safety_prepare || return 1
  managed_safety_load || return 1
  assert_eq unmanaged "$MANAGED_SAFETY_QB_INTENT" "unmanaged safety intent must round-trip" || return 1

  rm -f -- "$MANAGED_SAFETY"
  MANAGED_QB_INTENT=running
  MANAGED_QB_CONTAINER=qbittorrent
  MANAGED_QB_CONTAINER_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  MANAGED_QB_PROCESS=qbittorrent-nox
  MANAGED_QB_LISTEN_IPV4=192.0.2.2
  MANAGED_QB_LISTEN_PORT=6881
  managed_safety_prepare || return 1
  write_private_identity_profile "$MANAGED_CANDIDATE" \
    'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' 192.0.2.3/32 -
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "pending safety listen IPv4 must bind to staged candidate identity" || return 1

  write_managed_candidate_fixture
  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  rm -f -- "$MANAGED_CANDIDATE"
  sed -i 's/^state=pending$/state=committed/' "$MANAGED_SAFETY"
  sed -i 's/^Address = .*/Address = 192.0.2.3\/32/' "$WG_CONF"
  set +e; managed_safety_load >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "committed safety listen IPv4 must bind to active candidate identity"
}

transaction_phase() {
  local phase
  if [[ ! -f "${ROTATION_PENDING:-}" ]]; then
    printf 'none\n'
    return 0
  fi
  phase="$(sed -n 's/^phase=//p' "$ROTATION_PENDING")" || return 1
  [[ -n "$phase" && "$phase" != *$'\n'* ]] || return 1
  printf '%s\n' "$phase"
}

transaction_event() {
  printf '%s\n' "$1" >> "$TRANSACTION_EVENTS"
}

transaction_should_fail() {
  local action="${1:?}"
  [[ "${TRANSACTION_FAIL_ACTION:-}" == "$action" ]] || return 1
  if [[ "${TRANSACTION_FAIL_REMAINING:-1}" == -1 ]]; then
    return 0
  fi
  (( TRANSACTION_FAIL_REMAINING > 0 )) || return 1
  TRANSACTION_FAIL_REMAINING=$((TRANSACTION_FAIL_REMAINING - 1))
}

event_line_number() {
  local needle="${1:?}" line
  line="$(grep -n -m1 -F -- "$needle" "$TRANSACTION_EVENTS" 2>/dev/null)" || return 1
  printf '%s\n' "${line%%:*}"
}

assert_event_before() {
  local first="${1:?}" second="${2:?}" message="${3:-events are out of order}"
  local first_line second_line
  first_line="$(event_line_number "$first")" || fail "$message (missing '$first')" || return 1
  second_line="$(event_line_number "$second")" || fail "$message (missing '$second')" || return 1
  (( 10#$first_line < 10#$second_line )) ||
    fail "$message ('$first' at $first_line, '$second' at $second_line)"
}

setup_managed_transaction_fixture() {
  setup_managed_journal_fixture || return 1
  require_task7_contract || return 1
  TRANSACTION_EVENTS="$TEST_TMP/transaction-events"
  : > "$TRANSACTION_EVENTS"
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10
  ROTATE_STAMP="$TEST_TMP/run/wg-healthcheck/wg0.last_rotate"
  MANAGED_API_LOCK_FD=''
  TRANSACTION_QB_STATE=running
  TRANSACTION_RUNTIME_ENDPOINT=192.0.2.10:1637
  TRANSACTION_FAIL_ACTION=''
  TRANSACTION_FAIL_REMAINING=1
  TRANSACTION_EXCLUSION_DURABLE=1

  managed_docker_available() { return 0; }
  TRANSACTION_QB_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  managed_docker_inspect_identity() {
    local output_variable="${1:?}" target="${2:?}" docker_state
    transaction_event "qb-inspect:${MANAGED_QB_CHECKPOINT:-$(transaction_phase)}:$TRANSACTION_QB_STATE"
    transaction_should_fail inspect && return 1
    [[ "$target" == "$QBITTORRENT_CONTAINER" || "$target" == "$TRANSACTION_QB_ID" ]] || return 1
    case "$TRANSACTION_QB_STATE" in
      running) docker_state=true ;;
      stopped) docker_state=false ;;
      *) return 1 ;;
    esac
    printf -v "$output_variable" '%s|%s' "$TRANSACTION_QB_ID" "$docker_state"
  }
  managed_docker_stop_target() {
    local target="${1:?}" checkpoint="${MANAGED_QB_CHECKPOINT:-}"
    [[ -n "$checkpoint" && "$checkpoint" != restore ]] || checkpoint="$(transaction_phase)"
    transaction_event "qb-stop:$checkpoint"
    transaction_should_fail stop && return 1
    [[ "$target" == "$QBITTORRENT_CONTAINER" || "$target" == "$TRANSACTION_QB_ID" ]] || return 1
    TRANSACTION_QB_STATE=stopped
  }
  managed_docker_start_target() {
    local target="${1:?}" checkpoint="${MANAGED_QB_CHECKPOINT:-}"
    [[ -n "$checkpoint" && "$checkpoint" != restore ]] || checkpoint="$(transaction_phase)"
    transaction_event "qb-start:$checkpoint"
    transaction_should_fail start && return 1
    [[ "$target" == "$TRANSACTION_QB_ID" ]] || return 1
    TRANSACTION_QB_STATE=running
  }
  managed_docker_command() {
    local action="${1:?}"
    case "$action" in
      inspect)
        transaction_event "qb-inspect:$(transaction_phase):$TRANSACTION_QB_STATE"
        transaction_should_fail inspect && return 1
        case "$TRANSACTION_QB_STATE" in
          running) printf 'true\n' ;;
          stopped) printf 'false\n' ;;
          *) return 1 ;;
        esac
        ;;
      stop)
        transaction_event "qb-stop:$(transaction_phase)"
        transaction_should_fail stop && return 1
        TRANSACTION_QB_STATE=stopped
        ;;
      start)
        transaction_event "qb-start:$(transaction_phase)"
        transaction_should_fail start && return 1
        TRANSACTION_QB_STATE=running
        ;;
      *) return 1 ;;
    esac
  }
  managed_wait_for_qbittorrent() { return 0; }
  interface_exists() { [[ -n "$TRANSACTION_RUNTIME_ENDPOINT" ]]; }
  run_wg_quick_down() {
    transaction_event "wg-down:$(transaction_phase):$(configured_endpoint "$WG_CONF")"
    transaction_should_fail down && return 1
    TRANSACTION_RUNTIME_ENDPOINT=''
  }
  run_wg_quick_up() {
    local configured
    configured="$(configured_endpoint "$WG_CONF")" || return 1
    transaction_event "wg-up:$(transaction_phase):$configured"
    if [[ "$configured" == 192.0.2.10:1637 ]]; then
      transaction_should_fail rollback-up && return 1
    else
      transaction_should_fail up && return 1
    fi
    TRANSACTION_RUNTIME_ENDPOINT="$configured"
  }
  managed_verify_live_profile_identity() {
    local endpoint
    endpoint="$(configured_endpoint "${1:?}")" || return 1
    transaction_event "identity:$(transaction_phase):$endpoint"
    if [[ "$endpoint" == 192.0.2.10:1637 ]]; then
      transaction_should_fail rollback-identity && return 1
    else
      transaction_should_fail identity && return 1
    fi
    [[ "$TRANSACTION_RUNTIME_ENDPOINT" == "$endpoint" ]]
  }
  verify_tunnel() {
    local expected="${1:?}"
    transaction_event "network:$(transaction_phase):$expected"
    if [[ "$expected" == 192.0.2.10:1637 ]]; then
      transaction_should_fail rollback-network && return 1
    else
      transaction_should_fail network && return 1
    fi
    [[ "$TRANSACTION_RUNTIME_ENDPOINT" == "$expected" ]]
  }
  verify_post_rotation_speed() {
    transaction_event "speed:$(transaction_phase)"
    ! transaction_should_fail speed
  }
  qbittorrent_binding_present() {
    transaction_event "binding:$(transaction_phase):$TRANSACTION_QB_STATE:$TRANSACTION_RUNTIME_ENDPOINT"
    transaction_should_fail binding && return 1
    [[ "$TRANSACTION_QB_STATE" == running && -n "$TRANSACTION_RUNTIME_ENDPOINT" ]]
  }
  managed_profile_move() {
    local source="${1:?}" destination="${2:?}"
    if [[ "$destination" == "$WG_CONF" ]]; then
      transaction_event "profile-move:$(transaction_phase):$(configured_endpoint "$source")"
      transaction_should_fail install && return 1
    fi
    command mv -fT -- "$source" "$destination"
  }
  managed_journal_move() {
    local source="${1:?}" destination="${2:?}" phase
    phase="$(sed -n 's/^phase=//p' "$source")" || return 1
    transaction_event "journal:$phase"
    transaction_should_fail "journal-$phase" && return 1
    command mv -fT -- "$source" "$destination"
  }
  managed_unlink_path() {
    local path="${1:?}"
    if [[ "$path" == "$MANAGED_CANDIDATE" ]]; then
      transaction_event "candidate-delete:$(transaction_phase)"
      transaction_should_fail candidate-delete && return 1
    elif [[ "$path" == "$ROTATION_PENDING" ]]; then
      transaction_event "marker-delete:$(transaction_phase)"
      transaction_should_fail marker-delete && return 1
    fi
    command rm -f -- "$path"
  }
  write_stamp() {
    transaction_event "stamp:$(transaction_phase)"
    transaction_should_fail stamp && return 1
    printf '1000\n' > "${1:?}"
  }
  write_status() {
    transaction_event "status:$(transaction_phase):${1:?}:${2-}"
    transaction_should_fail status && return 1
    return 0
  }
  current_epoch() { printf '1000\n'; }
  managed_api_state_add_exclusion() {
    transaction_event "exclude-add:${1:?}:${2:?}"
    (( TRANSACTION_EXCLUSION_DURABLE == 1 ))
  }
  managed_api_state_write() {
    transaction_event 'exclude-write'
    (( TRANSACTION_EXCLUSION_DURABLE == 1 ))
  }
  managed_api_state_remove_exclusion_core() {
    transaction_event "exclude-remove:${1:?}:${2:?}"
    return 0
  }
}

setup_immutable_docker_fake() {
  DOCKER_FAKE_DIR="$TEST_TMP/docker-fake"
  DOCKER_FAKE_EVENTS="$TEST_TMP/docker-fake-events"
  mkdir -p -- "$DOCKER_FAKE_DIR/names" "$DOCKER_FAKE_DIR/states"
  : > "$DOCKER_FAKE_EVENTS"
  DOCKER_ID_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  DOCKER_ID_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  printf '%s\n' "$DOCKER_ID_A" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/other-client"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  DOCKER_FAKE_INSPECT_MODE=normal

  docker_fake_resolve() {
    local target="${1:?}"
    if [[ "$target" =~ ^[0-9a-f]{64}$ ]]; then
      [[ -f "$DOCKER_FAKE_DIR/states/$target" ]] || return 1
      printf '%s\n' "$target"
    else
      [[ -f "$DOCKER_FAKE_DIR/names/$target" ]] || return 1
      command sed -n '1p' "$DOCKER_FAKE_DIR/names/$target"
    fi
  }
  managed_docker_inspect_identity() {
    local output_variable="${1:?}" target="${2:?}" id state docker_state
    printf 'inspect:%s:%s\n' "${MANAGED_QB_CHECKPOINT:-none}" "$target" >> "$DOCKER_FAKE_EVENTS"
    case "$DOCKER_FAKE_INSPECT_MODE" in
      failure) return 1 ;;
      malformed)
        printf -v "$output_variable" '%s' 'malformed'
        return 0
        ;;
    esac
    id="$(docker_fake_resolve "$target")" || return 1
    state="$(<"$DOCKER_FAKE_DIR/states/$id")" || return 1
    case "$state" in
      running) docker_state=true ;;
      stopped) docker_state=false ;;
      *) return 1 ;;
    esac
    printf -v "$output_variable" '%s|%s' "$id" "$docker_state"
  }
  managed_docker_stop_target() {
    local target="${1:?}" id
    printf 'stop:%s:%s\n' "${MANAGED_QB_CHECKPOINT:-none}" "$target" >> "$DOCKER_FAKE_EVENTS"
    id="$(docker_fake_resolve "$target")" || return 1
    printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$id"
  }
  managed_docker_start_target() {
    local target="${1:?}" id
    printf 'start:%s:%s\n' "${MANAGED_QB_CHECKPOINT:-none}" "$target" >> "$DOCKER_FAKE_EVENTS"
    id="$(docker_fake_resolve "$target")" || return 1
    printf 'running\n' > "$DOCKER_FAKE_DIR/states/$id"
  }
  managed_wait_for_qbittorrent() { return 0; }
  qbittorrent_binding_present() {
    local current_id expected_id
    printf 'binding:%s:%s:%s:%s\n' "$QBITTORRENT_CONTAINER" \
      "$QBITTORRENT_PROCESS_NAME" "$QBITTORRENT_LISTEN_IP" "$QBITTORRENT_LISTEN_PORT" \
      >> "$DOCKER_FAKE_EVENTS"
    current_id="$(docker_fake_resolve "$QBITTORRENT_CONTAINER")" || return 1
    expected_id="${MANAGED_SAFETY_QB_CONTAINER_ID:-${MANAGED_QB_CONTAINER_ID:-$current_id}}"
    [[ "$current_id" == "$expected_id" &&
       "$(<"$DOCKER_FAKE_DIR/states/$current_id")" == running ]]
  }
}

test_managed_docker_identity_inspect_uses_an_unambiguous_template() {
  local inspection expected_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  setup_managed_journal_fixture || return 1
  QBITTORRENT_RESTART_TIMEOUT=10
  managed_docker_available() { return 0; }
  timeout() {
    [[ "$1" == 10 && "$2" == docker && "$3" == container && "$4" == inspect &&
       "$5" == --format && "$7" == qbittorrent ]] || return 1
    printf '%s\n' "$6" > "$TEST_TMP/docker-format"
    printf '%s|true\n' "$expected_id"
  }

  managed_docker_inspect_identity inspection qbittorrent || return 1
  assert_eq "$expected_id|true" "$inspection" \
    "Docker identity inspection must return one strict delimited tuple" || return 1
  assert_eq '{{.Id}}|{{.State.Running}}' "$(<"$TEST_TMP/docker-format")" \
    "Docker template must use an unambiguous literal delimiter"
}

test_managed_qb_inspection_parser_requires_exact_docker_boolean_tuple() {
  local bad rc parsed_id parsed_state
  local id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  source_managed_contract || return 1

  for bad in "$id|true|" "$id|true||" '|running|stopped' \
      "$id|running" "$id|stopped"; do
    parsed_id='sentinel-id'
    parsed_state='sentinel-state'
    set +e
    managed_qb_parse_inspection parsed_id parsed_state "$bad" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 1 "$rc" "Docker inspection tuple '$bad' must be rejected exactly" || return 1
    assert_eq sentinel-id "$parsed_id" "rejected inspection must not overwrite the ID" || return 1
    assert_eq sentinel-state "$parsed_state" \
      "rejected inspection must not overwrite the state" || return 1
  done
}

test_managed_qb_rejects_ambiguous_configured_name_before_every_effect() {
  local active_before backup_before rc
  setup_managed_transaction_fixture || return 1
  QBITTORRENT_CONTAINER="$TRANSACTION_QB_ID"
  active_before="$(sha256sum "$WG_CONF")" || return 1
  backup_before="$(sha256sum "${WG_CONF}.bak-healthcheck")" || return 1
  : > "$TRANSACTION_EVENTS"

  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an ID-shaped managed Docker name must fail closed" || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" \
    "ambiguous managed Docker configuration must fail before qB, backup, exclusion, journal, or network effects" ||
    return 1
  assert_eq "$active_before" "$(sha256sum "$WG_CONF")" \
    "ambiguous managed Docker configuration must preserve active bytes" || return 1
  assert_eq "$backup_before" "$(sha256sum "${WG_CONF}.bak-healthcheck")" \
    "ambiguous managed Docker configuration must preserve backup bytes" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "ambiguous managed Docker configuration must not create recovery state"
}

test_managed_safety_rejects_ambiguous_recorded_name_without_network_guess() {
  local load_rc rc events
  setup_managed_transaction_fixture || return 1
  setup_managed_crash_shape candidate-up candidate present candidate 1 || return 1
  sed -i "s/^qb_container=.*/qb_container=$TRANSACTION_QB_ID/" "$MANAGED_SAFETY"
  : > "$TRANSACTION_EVENTS"

  set +e; managed_safety_load_record >/dev/null 2>&1; load_rc=$?; set +e
  assert_eq 1 "$load_rc" "an ID-shaped recorded Docker name must fail strict parsing" || return 1
  assert_eq '' "${MANAGED_SAFETY_STATE-}" \
    "ambiguous recorded Docker parsing must clear every in-memory safety field" || return 1

  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an ID-shaped recorded Docker name must invalidate pending safety" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'wg-down:' "$events" \
    "ambiguous recorded Docker identity must fail before network recovery" || return 1
  assert_not_contains 'profile-move:' "$events" \
    "ambiguous recorded Docker identity must not guess at profile restoration" || return 1
  [[ -f "$MANAGED_SAFETY" && -f "$ROTATION_PENDING" ]] ||
    fail "ambiguous recorded evidence must remain available for operator repair"
}

test_managed_containment_never_treats_ambiguous_current_name_as_an_id() {
  local events rc
  setup_managed_journal_fixture || return 1
  setup_immutable_docker_fake
  QBITTORRENT_RESTART_TIMEOUT=10
  QBITTORRENT_CONTAINER="$DOCKER_ID_B"
  MANAGED_SAFETY_QB_INTENT=running
  MANAGED_SAFETY_QB_CONTAINER=qbittorrent
  MANAGED_SAFETY_QB_CONTAINER_ID="$DOCKER_ID_A"
  MANAGED_SAFETY_QB_PROCESS=qbittorrent-nox
  MANAGED_SAFETY_QB_LISTEN_IPV4=192.0.2.2
  MANAGED_SAFETY_QB_LISTEN_PORT=6881
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  : > "$DOCKER_FAKE_EVENTS"

  set +e; managed_qb_contain_recorded_and_current >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "ambiguous current name must make containment incomplete" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "the recorded immutable ID must still be contained" || return 1
  assert_eq running "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "an ID-shaped current name must never be interpreted as an immutable-ID target" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_not_contains "stop:none:$DOCKER_ID_B" "$events" \
    "containment must not issue a Docker mutation for an ambiguous current name"
}

test_managed_qb_immutable_identity_checkpoints_and_exact_restore() {
  local rc events start_count checkpoint parsed_id=sentinel parsed_state=sentinel inspection
  setup_managed_journal_fixture || return 1
  declare -F managed_qb_snapshot >/dev/null ||
    fail "amended Task 7 immutable qB snapshot owner is missing" || return 1
  declare -F managed_qb_containment_checkpoint >/dev/null ||
    fail "amended Task 7 qB containment checkpoint owner is missing" || return 1
  declare -F managed_qb_restore_recorded_intent >/dev/null ||
    fail "amended Task 7 exact qB restore owner is missing" || return 1
  setup_immutable_docker_fake
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10

  inspection="$DOCKER_ID_A|false"
  managed_qb_parse_inspection parsed_id parsed_state "$inspection" || return 1
  assert_eq "$DOCKER_ID_A" "$parsed_id" "inspection parser must replace caller ID output" || return 1
  assert_eq stopped "$parsed_state" "inspection parser must replace caller state output" || return 1
  set +e; managed_qb_parse_inspection parsed_id parsed_id "$inspection" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "inspection parser must reject aliased output variables" || return 1
  set +e; managed_qb_parse_inspection wgmanaged_id parsed_state "$inspection" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "inspection parser must reject internal-name collisions" || return 1

  managed_qb_snapshot || return 1
  assert_eq running "$MANAGED_QB_INTENT" "running intent must be snapshotted" || return 1
  assert_eq "$DOCKER_ID_A" "$MANAGED_QB_CONTAINER_ID" \
    "snapshot must capture the immutable container ID" || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  managed_qb_containment_checkpoint after-stop || return 1

  for checkpoint in after-stop before-down after-down before-install after-install \
      before-up after-up before-network after-network rollback-before-down \
      rollback-after-down rollback-before-install rollback-after-install rollback-before-up \
      rollback-after-up rollback-before-network rollback-after-network rollback-pre-cleanup \
      rollback-post-cleanup; do
    printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
    set +e; managed_qb_containment_checkpoint "$checkpoint" >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "external restart at $checkpoint must fail" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "external restart at $checkpoint must be contained" || return 1
  done

  printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  set +e; managed_qb_containment_checkpoint after-install >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "same-name container recreation must fail" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "recorded immutable target must remain stopped" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "replacement target must be stopped" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_contains "stop:after-install:$DOCKER_ID_A" "$events" \
    "recreation containment must target the recorded immutable ID" || return 1
  assert_contains 'stop:after-install:qbittorrent' "$events" \
    "recreation containment must also target the current configured name" || return 1

  printf '%s\n' "$DOCKER_ID_A" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  QBITTORRENT_LISTEN_PORT=6999
  set +e; managed_qb_containment_checkpoint config-drift >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "configured tuple drift must fail closed" || return 1
  QBITTORRENT_LISTEN_PORT=6881

  DOCKER_FAKE_INSPECT_MODE=malformed
  set +e; managed_qb_containment_checkpoint malformed-inspect >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "malformed inspect must contain and fail" || return 1
  DOCKER_FAKE_INSPECT_MODE=failure
  set +e; managed_qb_containment_checkpoint failed-inspect >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "inspect hard failure must contain and fail" || return 1
  DOCKER_FAKE_INSPECT_MODE=normal
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  : > "$DOCKER_FAKE_EVENTS"
  managed_qb_restore_recorded_intent || return 1
  start_count="$(grep -cFx "start:restore:$DOCKER_ID_A" "$DOCKER_FAKE_EVENTS" || true)"
  assert_eq 1 "$start_count" "running intent restore must own exactly one immutable-ID start" || return 1
  assert_eq running "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "running intent must finish running" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_contains 'binding:qbittorrent:qbittorrent-nox:192.0.2.2:6881' "$events" \
    "restore must prove the recorded TCP/UDP tuple" || return 1

  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  : > "$DOCKER_FAKE_EVENTS"
  set +e; managed_qb_restore_recorded_intent >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "already-running restore target must not be accepted" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "already-running restore target must be contained" || return 1
  assert_not_contains 'start:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "already-running target must never receive a transaction start" || return 1

  rm -f -- "$MANAGED_SAFETY"
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  managed_qb_snapshot || return 1
  assert_eq stopped "$MANAGED_QB_INTENT" "stopped intent must be snapshotted" || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  : > "$DOCKER_FAKE_EVENTS"
  set +e; managed_qb_restore_recorded_intent >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "recorded-stopped client must not become running" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "recorded-stopped external restart must be contained" || return 1
  assert_not_contains 'start:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "stopped intent must never receive a transaction start" || return 1

  rm -f -- "$MANAGED_SAFETY"
  QBITTORRENT_CONTAINER=''
  managed_qb_snapshot || return 1
  assert_eq unmanaged "$MANAGED_QB_INTENT" "empty container config must snapshot unmanaged" || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  managed_qb_restore_recorded_intent || return 1
  QBITTORRENT_CONTAINER=other-client
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  set +e; managed_qb_restore_recorded_intent >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "unmanaged intent must reject a newly configured target" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "new target under unmanaged intent must be contained" || return 1

  rm -f -- "$MANAGED_SAFETY"
  QBITTORRENT_CONTAINER=qbittorrent
  printf '%s\n' "$DOCKER_ID_A" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  managed_qb_snapshot || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  qbittorrent_binding_present() {
    printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/qbittorrent"
    printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
    return 0
  }
  : > "$DOCKER_FAKE_EVENTS"
  set +e; managed_qb_verify_recorded_intent final-check >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "ID replacement during binding proof must fail final proof" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "ID replacement must stop the recorded target" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "ID replacement must stop the current target" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_contains "stop:final-check:$DOCKER_ID_A" "$events" \
    "final containment must address the immutable ID" || return 1
  assert_contains 'stop:final-check:qbittorrent' "$events" \
    "final containment must address the configured name"
}

test_managed_qbittorrent_state_is_exact_and_fail_closed() {
  local state rc
  source_managed_contract || return 1
  require_task7_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  QBITTORRENT_RESTART_TIMEOUT=10
  QBITTORRENT_CONTAINER=''
  managed_docker_available() { printf 'unexpected\n' >> "$TEST_TMP/docker-events"; return 0; }
  managed_docker_command() { printf 'unexpected\n' >> "$TEST_TMP/docker-events"; return 1; }
  : > "$TEST_TMP/docker-events"
  managed_qbittorrent_state state || return 1
  assert_eq unconfigured "$state" "empty qB configuration must be explicit" || return 1
  assert_eq '' "$(<"$TEST_TMP/docker-events")" "unconfigured qB must not invoke Docker" || return 1

  QBITTORRENT_CONTAINER=qbittorrent
  validate_container_name "$QBITTORRENT_CONTAINER" || return 1
  managed_docker_available() { return 0; }
  managed_docker_command() {
    case "${QB_INSPECT_RESULT:?}" in
      true|false) printf '%s\n' "$QB_INSPECT_RESULT" ;;
      multiline) printf 'true\nfalse\n' ;;
      whitespace) printf ' true\n' ;;
      missing) return 1 ;;
    esac
  }
  QB_INSPECT_RESULT=true
  managed_qbittorrent_state state || return 1
  assert_eq running "$state" "Docker true must map to running" || return 1
  QB_INSPECT_RESULT=false
  managed_qbittorrent_state state || return 1
  assert_eq stopped "$state" "Docker false must map to stopped" || return 1
  for QB_INSPECT_RESULT in multiline whitespace missing; do
    state=sentinel
    set +e; managed_qbittorrent_state state >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$QB_INSPECT_RESULT inspect shape must fail closed" || return 1
    assert_eq sentinel "$state" "failed inspect must not overwrite the caller output" || return 1
  done
}

test_managed_live_identity_requires_exact_address_and_peer_key() {
  local rc
  setup_managed_journal_fixture || return 1
  require_task7_contract || return 1
  LIVE_ADDRESS=192.0.2.2/32
  LIVE_PEER=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
  managed_live_interface_address() { printf '%s\n' "$LIVE_ADDRESS"; }
  managed_live_peer_public_key() { printf '%s\n' "$LIVE_PEER"; }
  managed_verify_live_profile_identity "$MANAGED_CANDIDATE" ||
    fail "matching live identity must pass" || return 1

  LIVE_ADDRESS=192.0.2.3/32
  set +e; managed_verify_live_profile_identity "$MANAGED_CANDIDATE" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "changed live interface address must fail" || return 1
  LIVE_ADDRESS=192.0.2.2/32
  LIVE_PEER=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
  set +e; managed_verify_live_profile_identity "$MANAGED_CANDIDATE" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "changed live peer key must fail"
}

test_managed_atomic_profile_install_is_digest_bound_and_durable() {
  local digest endpoint rc actual_mode actual_owner
  local -a events=()
  setup_managed_journal_fixture || return 1
  require_task7_contract || return 1
  managed_sha256_file digest "$MANAGED_CANDIDATE" || return 1
  endpoint="$(configured_endpoint "$MANAGED_CANDIDATE")" || return 1
  : > "$TEST_TMP/install-events"
  managed_copy_profile_bytes() {
    printf 'copy:%s:%s\n' "$1" "$2" >> "$TEST_TMP/install-events"
    command cp -- "$1" "$2"
  }
  managed_sync_file() { printf 'sync:%s:%s\n' "$1" "$(stat -c '%a' "$1")" >> "$TEST_TMP/install-events"; }
  managed_profile_move() { printf 'move:%s:%s\n' "$1" "$2" >> "$TEST_TMP/install-events"; command mv -fT -- "$1" "$2"; }
  managed_sync_artifact_parent() { printf 'directory:%s\n' "$1" >> "$TEST_TMP/install-events"; }

  managed_install_profile_atomically "$MANAGED_CANDIDATE" "$WG_CONF" "$digest" "$endpoint" || return 1
  mapfile -t events < "$TEST_TMP/install-events"
  assert_eq 5 "${#events[@]}" "install must expose five ordered copy/durability effects" || return 1
  assert_contains 'copy:' "${events[0]}" "install must copy into a private temporary first" || return 1
  assert_contains 'sync:' "${events[1]}" "temporary must be synced before rename" || return 1
  assert_contains ':600' "${events[1]}" "temporary must be mode 0600 before sync" || return 1
  assert_contains 'move:' "${events[2]}" "atomic rename must follow temporary verification" || return 1
  assert_eq "sync:$WG_CONF:600" "${events[3]}" "installed active profile must be synced" || return 1
  assert_eq "directory:${WG_CONF%/*}" "${events[4]}" "profile parent must be synced last" || return 1
  managed_verify_profile_binding "$WG_CONF" "$digest" "$endpoint" || return 1
  cmp -s -- "$MANAGED_CANDIDATE" "$WG_CONF" || fail "candidate install must preserve exact bytes" || return 1
  actual_mode="$(stat -c '%a' "$WG_CONF")" || return 1
  assert_eq 600 "$actual_mode" "installed profile must be mode 0600" || return 1
  if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]]; then
    actual_owner="$(stat -c '%u' "$WG_CONF")" || return 1
    assert_eq 0 "$actual_owner" "installed profile must be root-owned" || return 1
  fi

  write_managed_candidate_fixture 203.0.113.20:1637
  chmod 600 -- "$MANAGED_CANDIDATE"
  set +e
  managed_install_profile_atomically "$MANAGED_CANDIDATE" "$WG_CONF" "$digest" "$endpoint" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "changed staged candidate must fail immediately before install" || return 1
  managed_verify_profile_binding "$WG_CONF" "$digest" "$endpoint"
}

test_managed_profile_transaction_orders_every_qb_and_tunnel_effect() {
  local candidate_digest events
  setup_managed_transaction_fixture || return 1
  managed_sha256_file candidate_digest "$MANAGED_CANDIDATE" || return 1
  managed_profile_transaction Alpha-1 1 || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_event_before 'exclude-write' 'journal:prepared' "candidate exclusion must be durable before prepared" || return 1
  assert_event_before 'journal:prepared' 'qb-stop:prepared' "prepared must precede qB stop" || return 1
  assert_event_before 'qb-stop:prepared' 'journal:client-stopped' "qB stop must precede client-stopped" || return 1
  assert_event_before 'journal:client-stopped' 'wg-down:client-stopped:192.0.2.10:1637' "old profile must remain installed for down" || return 1
  assert_event_before 'wg-down:client-stopped:192.0.2.10:1637' 'journal:tunnel-down' "down must precede tunnel-down" || return 1
  assert_event_before 'journal:tunnel-down' 'profile-move:tunnel-down:198.51.100.20:1637' "candidate install must follow tunnel-down" || return 1
  assert_event_before 'profile-move:tunnel-down:198.51.100.20:1637' 'journal:candidate-installed' "durable install must precede candidate-installed" || return 1
  assert_event_before 'journal:candidate-installed' 'wg-up:candidate-installed:198.51.100.20:1637' "candidate-installed must precede up" || return 1
  assert_event_before 'wg-up:candidate-installed:198.51.100.20:1637' 'journal:candidate-up' "up must precede candidate-up" || return 1
  assert_event_before 'journal:candidate-up' 'identity:candidate-up:198.51.100.20:1637' "live identity must follow candidate-up" || return 1
  assert_event_before 'identity:candidate-up:198.51.100.20:1637' 'network:candidate-up:198.51.100.20:1637' "identity must precede tunnel/egress verification" || return 1
  assert_event_before 'network:candidate-up:198.51.100.20:1637' 'speed:candidate-up' "network must precede optional speed" || return 1
  assert_event_before 'speed:candidate-up' 'qb-start:candidate-up' "qB must start only after all network checks" || return 1
  assert_event_before 'qb-start:candidate-up' 'binding:candidate-up:running:198.51.100.20:1637' "running state must precede TCP/UDP ownership proof" || return 1
  assert_event_before 'binding:candidate-up:running:198.51.100.20:1637' 'journal:verified' "binding proof must precede verified" || return 1
  assert_event_before 'journal:verified' 'candidate-delete:verified' "verified must precede candidate cleanup" || return 1
  assert_event_before 'candidate-delete:verified' 'marker-delete:verified' \
    "journal cleanup must follow candidate cleanup" || return 1
  assert_event_before 'marker-delete:verified' 'status:none:recovered:managed_profile_rotation_verified' \
    "success status must follow the safety commit point" || return 1
  assert_event_before 'status:none:recovered:managed_profile_rotation_verified' 'stamp:none' \
    "cooldown follows postcommit status" || return 1
  assert_event_before 'stamp:none' 'exclude-remove:Alpha-1:1000' \
    "pre-exclusion clears only after candidate commit" || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" && ! -e "$MANAGED_SAFETY" ]] ||
    fail "successful transaction must clean candidate, marker, and safety owner" || return 1
  managed_verify_profile_binding "$WG_CONF" "$candidate_digest" 198.51.100.20:1637 || return 1
  assert_eq running "$TRANSACTION_QB_STATE" "previously running qB must be restored" || return 1

  setup_managed_transaction_fixture || return 1
  TRANSACTION_QB_STATE=stopped
  managed_profile_transaction Alpha-1 0 || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'qb-stop:' "$events" "previously stopped qB must not be stopped redundantly" || return 1
  assert_not_contains 'qb-start:' "$events" "previously stopped qB must remain stopped" || return 1
  assert_not_contains 'binding:' "$events" "previously stopped qB needs no listener ownership proof" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" "stopped intent must be preserved" || return 1

  setup_managed_transaction_fixture || return 1
  QBITTORRENT_CONTAINER=''
  TRANSACTION_QB_STATE=stopped
  managed_profile_transaction Alpha-1 0 || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'qb-' "$events" "unconfigured qB must have no Docker effects"
}

test_amended_transaction_keeps_a_durable_owner_through_commit_and_finalization() {
  local docker_events
  setup_managed_transaction_fixture || return 1
  setup_immutable_docker_fake
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10
  managed_safety_move() {
    local state
    state="$(sed -n 's/^state=//p' "${1:?}")" || return 1
    transaction_event "safety:$state"
    command mv -fT -- "$1" "${2:?}"
  }
  managed_unlink_path() {
    local path="${1:?}" safety_state=absent
    [[ ! -f "$MANAGED_SAFETY" ]] || safety_state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
    case "$path" in
      "$MANAGED_CANDIDATE") transaction_event "candidate-delete:safety-$safety_state" ;;
      "$ROTATION_PENDING") transaction_event "marker-delete:safety-$safety_state" ;;
      "$MANAGED_SAFETY") transaction_event "safety-delete:$safety_state" ;;
    esac
    command rm -f -- "$path"
  }

  managed_profile_transaction Alpha-1 0 || return 1
  assert_event_before 'safety:pending' 'journal:prepared' \
    "pending safety must own the transaction before the journal" || return 1
  assert_event_before 'journal:verified' 'candidate-delete:safety-pending' \
    "verified candidate cleanup must remain pending-owned" || return 1
  assert_event_before 'candidate-delete:safety-pending' 'marker-delete:safety-pending' \
    "candidate cleanup must precede journal cleanup" || return 1
  assert_event_before 'marker-delete:safety-pending' 'safety:committed' \
    "safety commit must follow journal cleanup and post-cleanup proof" || return 1
  assert_event_before 'safety:committed' 'status:none:recovered:managed_profile_rotation_verified' \
    "success status must be postcommit bookkeeping" || return 1
  assert_event_before 'safety:committed' 'stamp:none' \
    "rotation cooldown must be postcommit bookkeeping" || return 1
  assert_event_before 'safety:committed' 'safety:finalizing' \
    "committed safety must transition to finalizing" || return 1
  assert_event_before 'safety:finalizing' 'safety-delete:finalizing' \
    "final safety unlink must be the last commit-owner effect" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "successful finalization must clear every transaction artifact" || return 1
  docker_events="$(<"$DOCKER_FAKE_EVENTS")"
  for checkpoint in after-stop before-down after-down before-install after-install \
      before-up after-up before-network after-network pre-cleanup post-cleanup finalizing; do
    assert_contains "inspect:$checkpoint:qbittorrent" "$docker_events" \
      "checkpoint $checkpoint must inspect immutable qB state" || return 1
  done
}

test_managed_candidate_exclusion_removal_is_exact_and_durable() {
  local key_fd
  source_managed_contract || return 1
  require_task7_contract || return 1
  setup_api_state_fixture || return 1
  managed_api_state_defaults 1000 || return 1
  exec {key_fd}<"$AIRVPN_API_KEY_FILE" || return 1
  managed_api_state_refresh_identity 1000 "$key_fd" || { exec {key_fd}<&-; return 1; }
  exec {key_fd}<&-
  managed_api_state_add_exclusion Alpha-1 1000 || return 1
  managed_api_state_add_exclusion Beta-2 1000 || return 1
  managed_api_state_write || return 1
  managed_api_state_remove_exclusion Alpha-1 1001 || return 1
  managed_api_state_load 1001 || return 1
  assert_eq 1 "${#MANAGED_API_EXCLUDE_NAMES[@]}" "remove must retain unrelated exclusions" || return 1
  assert_eq Beta-2 "${MANAGED_API_EXCLUDE_NAMES[0]}" "remove must delete only the exact server" || return 1
  if grep -F 'Alpha-1' "$AIRVPN_API_STATE_FILE" >/dev/null; then
    fail "removed exclusion must not remain in durable state" || return 1
  fi
  grep -Fx 'exclude_01=Beta-2,22600' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "unrelated exclusion must remain durable"
}

test_managed_transaction_context_and_preexclusion_fail_before_mutation() {
  local rc events backup_before
  setup_managed_transaction_fixture || return 1
  backup_before="$(sha256sum "${WG_CONF}.bak-healthcheck")" || return 1
  CONTEXT_LOCKED=0
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "transaction must require the interface lock" || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" "missing interface lock must precede every effect" || return 1

  CONTEXT_LOCKED=1
  MANAGED_API_LOCK_FD=11
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "transaction must require the global API lock to be released" || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" "held global API lock must precede every effect" || return 1

  MANAGED_API_LOCK_FD=''
  managed_api_state_write() {
    transaction_event 'exclude-write'
    return 1
  }
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "pre-exclusion persistence failure must abort" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_eq $'qb-inspect:none:running\nexclude-add:Alpha-1:1000\nexclude-write' "$events" \
    "pre-exclusion failure may follow only validation and the immutable read-only snapshot" || return 1
  [[ ! -e "$ROTATION_PENDING" ]] || fail "pre-exclusion failure must not create a journal" || return 1
  assert_eq "$backup_before" "$(sha256sum "${WG_CONF}.bak-healthcheck")" \
    "pre-exclusion failure must not rewrite the backup" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "pre-exclusion failure must not mutate the active profile"
}

test_managed_transaction_identity_ordering_precedes_every_effect() {
  local backup_before case_name events rc
  for case_name in private-key address table; do
    (
      setup_managed_transaction_fixture || exit 1
      case "$case_name" in
        private-key)
          sed -i 's/^PrivateKey = .*/PrivateKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=/' \
            "$MANAGED_CANDIDATE"
          ;;
        address) sed -i 's/^Address = .*/Address = 192.0.2.3\/32/' "$MANAGED_CANDIDATE" ;;
        table) sed -i '/^\[Peer\]/i Table = off' "$MANAGED_CANDIDATE" ;;
      esac
      backup_before="$(sha256sum "${WG_CONF}.bak-healthcheck")" || exit 1
      : > "$TRANSACTION_EVENTS"
      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name identity mismatch must fail the transaction" || exit 1
      assert_eq '' "$(<"$TRANSACTION_EVENTS")" \
        "$case_name identity mismatch must precede snapshot, backup, exclusion, safety, journal, Docker, and network effects" ||
        exit 1
      assert_eq "$backup_before" "$(sha256sum "${WG_CONF}.bak-healthcheck")" \
        "$case_name identity mismatch must preserve backup bytes" || exit 1
      [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
        fail "$case_name identity mismatch must not create recovery state" || exit 1
    ) || return 1
  done
}

test_managed_transaction_rechecks_backup_identity_before_preexclusion() {
  local events rc
  setup_managed_transaction_fixture || return 1
  eval "$(declare -f managed_prepare_profile_backup | sed '1s/managed_prepare_profile_backup/transaction_original_prepare_profile_backup/')"
  managed_prepare_profile_backup() {
    transaction_original_prepare_profile_backup || return 1
    sed -i 's/^Address = .*/Address = 192.0.2.3\/32/' "${WG_CONF}.bak-healthcheck"
  }
  : > "$TRANSACTION_EVENTS"

  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-backup identity mutation must fail the transaction" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'qb-inspect:' "$events" \
    "the permitted read-only qB snapshot must occur before durable backup creation" || return 1
  assert_not_contains 'exclude-' "$events" \
    "backup identity recheck must precede candidate pre-exclusion" || return 1
  assert_not_contains 'journal:' "$events" \
    "backup identity recheck must precede the journal" || return 1
  assert_not_contains 'qb-stop:' "$events" \
    "backup identity recheck must precede qB mutation" || return 1
  assert_not_contains 'wg-down:' "$events" \
    "backup identity recheck must precede network mutation" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "backup identity recheck failure must not create recovery state"
}

test_managed_stop_failure_aborts_before_tunnel_downtime() {
  local rc events
  setup_managed_transaction_fixture || return 1
  TRANSACTION_FAIL_ACTION=stop
  TRANSACTION_FAIL_REMAINING=-1
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "qB stop failure must fail the candidate transaction" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'qb-stop:prepared' "$events" "running qB must be stopped after prepared" || return 1
  assert_not_contains 'wg-down:' "$events" "qB stop failure must precede all tunnel downtime" || return 1
  assert_not_contains 'profile-move:' "$events" "qB stop failure must precede candidate install" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "qB stop failure must retain the old active profile"
}

test_managed_every_phase_failure_rolls_back_exact_old_profile() {
  local case_name rc events
  local -a cases=(
    journal-client-stopped down journal-tunnel-down install journal-candidate-installed
    up journal-candidate-up identity network speed start binding journal-verified
    candidate-delete marker-delete
  )
  for case_name in "${cases[@]}"; do
    (
      setup_managed_transaction_fixture || exit 1
      TRANSACTION_FAIL_ACTION="$case_name"
      TRANSACTION_FAIL_REMAINING=1
      set +e; managed_profile_transaction Alpha-1 1 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name failure must fail the candidate transaction" || exit 1
      managed_verify_profile_binding "$WG_CONF" \
        "$(sha256sum "${WG_CONF}.bak-healthcheck" | awk '{print $1}')" \
        192.0.2.10:1637 || fail "$case_name must restore the exact old profile" || exit 1
      cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
        fail "$case_name rollback must be byte-for-byte" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$case_name successful rollback must clean its marker and candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" \
        "$case_name successful rollback must restore prior qB running intent" || exit 1
      events="$(<"$TRANSACTION_EVENTS")"
      assert_not_contains 'exclude-remove:' "$events" \
        "$case_name rollback must retain the failed candidate exclusion" || exit 1
    ) || return 1
  done
}

test_pending_rollback_never_writes_or_removes_rotation_success_stamp() {
  local rc original_mtime
  for stamp_shape in absent existing; do
    (
      setup_managed_transaction_fixture || exit 1
      if [[ "$stamp_shape" == existing ]]; then
        printf 'historic-stamp\n' > "$ROTATE_STAMP"
        touch -d '@500' "$ROTATE_STAMP"
        original_mtime="$(stat -c '%Y' "$ROTATE_STAMP")" || exit 1
      fi
      TRANSACTION_FAIL_ACTION=marker-delete
      TRANSACTION_FAIL_REMAINING=1
      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$stamp_shape precommit failure must roll back" || exit 1
      if [[ "$stamp_shape" == absent ]]; then
        [[ ! -e "$ROTATE_STAMP" ]] ||
          fail "rollback must not create a rotation-success stamp" || exit 1
      else
        assert_eq historic-stamp "$(<"$ROTATE_STAMP")" \
          "rollback must preserve existing stamp bytes" || exit 1
        assert_eq "$original_mtime" "$(stat -c '%Y' "$ROTATE_STAMP")" \
          "rollback must preserve existing stamp mtime" || exit 1
      fi
    ) || return 1
  done
}

test_rollback_status_seam_cannot_reopen_qb_before_safety_removal() {
  local rc
  setup_amended_recovery_shape pending absent candidate present stopped || return 1
  write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" stopped
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  ROLLBACK_STATUS_SAFETY_STATE=''
  write_status() {
    if [[ "${1-}" == recovered && "${2-}" == managed_profile_rollback_verified ]]; then
      ROLLBACK_STATUS_SAFETY_STATE=absent
      [[ ! -f "$MANAGED_SAFETY" ]] ||
        ROLLBACK_STATUS_SAFETY_STATE="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
      printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
    fi
    return 0
  }

  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "external restart from the rollback status seam must fail contained" || return 1
  assert_eq pending "$ROLLBACK_STATUS_SAFETY_STATE" \
    "best-effort rollback status must run while pending safety still owns final proof" || return 1
  [[ -f "$MANAGED_SAFETY" ]] || fail "failed final qB proof must retain pending safety" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "status-seam restart must be contained before safety removal" || return 1
  [[ ! -e "$ROTATE_STAMP" ]] || fail "failed rollback proof must not create a success stamp"
}

test_pending_safety_creation_barriers_reclassify_the_visible_owner() {
  local barrier rc
  for barrier in temp-sync move final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_safety_move | sed '1s/managed_safety_move/transaction_original_safety_move/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      SAFETY_BARRIER_USED=0
      managed_sync_file() {
        local path="${1:?}" state=''
        [[ ! -f "$path" ]] || state="$(sed -n 's/^state=//p' "$path")"
        if (( SAFETY_BARRIER_USED == 0 )) && {
          [[ "$barrier" == temp-sync && "$path" == *'.safety-healthcheck.tmp.'* && "$state" == pending ]] ||
          [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" && "$state" == pending ]]
        }; then
          SAFETY_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_file "$path"
      }
      managed_safety_move() {
        local source="${1:?}" destination="${2:?}" state
        state="$(sed -n 's/^state=//p' "$source")" || return 1
        if [[ "$barrier" == move && "$state" == pending && "$SAFETY_BARRIER_USED" == 0 ]]; then
          SAFETY_BARRIER_USED=1
          return 1
        fi
        transaction_original_safety_move "$source" "$destination"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}" state=''
        [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
        if [[ "$barrier" == parent-sync && "$state" == pending && "$SAFETY_BARRIER_USED" == 0 ]]; then
          SAFETY_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$barrier pending safety barrier must fail the candidate transaction" || exit 1
      assert_eq 1 "$SAFETY_BARRIER_USED" "$barrier safety barrier must be exercised exactly once" || exit 1
      assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
        "$barrier safety failure must retain or restore the old profile" || exit 1
      [[ ! -e "$ROTATION_PENDING" ]] || fail "$barrier safety failure must not leave an orphan journal" || exit 1
      [[ ! -e "$ROTATE_STAMP" ]] || fail "$barrier pending failure must not write a success stamp" || exit 1
      if [[ "$barrier" == temp-sync || "$barrier" == move ]]; then
        [[ ! -e "$MANAGED_SAFETY" && -f "$MANAGED_CANDIDATE" ]] ||
          fail "$barrier must fail before exposing a safety owner or consuming the staged candidate" || exit 1
      else
        [[ ! -e "$MANAGED_SAFETY" && ! -e "$MANAGED_CANDIDATE" ]] ||
          fail "$barrier visible pending owner must drive complete rollback cleanup" || exit 1
      fi
      assert_eq running "$TRANSACTION_QB_STATE" \
        "$barrier pre-mutation failure or verified rollback must preserve running intent"
    ) || return 1
  done
}

test_visible_pending_safety_requires_successful_rebarrier_before_recovery_effects() {
  local barrier rc
  for barrier in final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      PERSISTENT_BARRIER_CALLS=0
      managed_sync_file() {
        local path="${1:?}"
        transaction_original_sync_file "$path" || return 1
        if [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" &&
              "$(sed -n 's/^state=//p' "$path")" == pending ]]; then
          PERSISTENT_BARRIER_CALLS=$((PERSISTENT_BARRIER_CALLS + 1))
          return 1
        fi
      }
      managed_sync_safety_parent() {
        local parent="${1:?}"
        transaction_original_sync_safety_parent "$parent" || return 1
        if [[ "$barrier" == parent-sync && -f "$MANAGED_SAFETY" &&
              "$(sed -n 's/^state=//p' "$MANAGED_SAFETY")" == pending ]]; then
          PERSISTENT_BARRIER_CALLS=$((PERSISTENT_BARRIER_CALLS + 1))
          return 1
        fi
      }
      : > "$TRANSACTION_EVENTS"

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$barrier persistent failure must fail closed" || exit 1
      (( PERSISTENT_BARRIER_CALLS >= 2 )) ||
        fail "$barrier must be retried before reconciliation is allowed" || exit 1
      [[ -f "$MANAGED_SAFETY" ]] || fail "$barrier must retain visible safety evidence" || exit 1
      assert_eq pending "$(sed -n 's/^state=//p' "$MANAGED_SAFETY")" \
        "$barrier must retain the strict pending owner" || exit 1
      [[ ! -e "$ROTATION_PENDING" ]] || fail "$barrier must fail before journal creation" || exit 1
      assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
        "$barrier must leave the old active profile untouched" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" \
        "$barrier must leave the pre-transaction qB state untouched" || exit 1
      assert_not_contains 'qb-stop:' "$(<"$TRANSACTION_EVENTS")" \
        "$barrier must fail before qB mutation" || exit 1
      assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
        "$barrier must fail before network mutation" || exit 1
    ) || return 1
  done
}

test_journal_unlink_parent_sync_failure_never_recreates_v2_marker() {
  local rc verified_writes
  setup_managed_transaction_fixture || return 1
  eval "$(declare -f managed_sync_journal_parent | sed '1s/managed_sync_journal_parent/transaction_original_sync_journal_parent/')"
  JOURNAL_UNLINK_SYNC_FAILED=0
  managed_sync_journal_parent() {
    local parent="${1:?}" state=absent
    [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
    if [[ ! -e "$ROTATION_PENDING" && "$JOURNAL_UNLINK_SYNC_FAILED" == 0 ]]; then
      JOURNAL_UNLINK_SYNC_FAILED=1
      transaction_event "marker-parent-sync-failed:safety-$state"
      return 1
    fi
    transaction_original_sync_journal_parent "$parent"
  }

  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "journal unlink parent-sync failure must fail before candidate commit" || return 1
  assert_eq 1 "$JOURNAL_UNLINK_SYNC_FAILED" "journal unlink parent-sync failure must be injected" || return 1
  assert_contains 'marker-parent-sync-failed:safety-pending' "$(<"$TRANSACTION_EVENTS")" \
    "pending safety must still own a failed journal directory sync" || return 1
  verified_writes="$(grep -cFx 'journal:verified' "$TRANSACTION_EVENTS" || true)"
  assert_eq 1 "$verified_writes" "deleted v2 marker must never be reconstructed" || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_SAFETY" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "safety-owned rollback must finish without recreating the journal" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "journal sync failure must roll back the candidate" || return 1
  assert_eq running "$TRANSACTION_QB_STATE" "verified rollback must restore qB intent" || return 1
  [[ ! -e "$ROTATE_STAMP" ]] || fail "journal sync rollback must not write a success stamp"
}

test_commit_transition_durability_reclassifies_pending_vs_committed() {
  local barrier rc
  for barrier in temp-sync final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      COMMIT_BARRIER_USED=0
      managed_sync_file() {
        local path="${1:?}" state=''
        [[ ! -f "$path" ]] || state="$(sed -n 's/^state=//p' "$path")"
        if (( COMMIT_BARRIER_USED == 0 )) && {
          [[ "$barrier" == temp-sync && "$path" == *'.safety-healthcheck.tmp.'* && "$state" == committed ]] ||
          [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" && "$state" == committed ]]
        }; then
          COMMIT_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_file "$path"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}" state=''
        [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
        if [[ "$barrier" == parent-sync && "$state" == committed && "$COMMIT_BARRIER_USED" == 0 ]]; then
          COMMIT_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$COMMIT_BARRIER_USED" "$barrier commit barrier must be exercised" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_SAFETY" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$barrier visible state must be reconciled to a complete outcome" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" "$barrier outcome must restore exact qB intent" || exit 1
      if [[ "$barrier" == temp-sync ]]; then
        assert_eq 1 "$rc" "pre-rename commit failure must remain a failed, rolled-back attempt" || exit 1
        assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
          "visible pending state must roll back" || exit 1
        [[ ! -e "$ROTATE_STAMP" ]] || fail "pending rollback must not create a success stamp" || exit 1
      else
        assert_eq 0 "$rc" "post-rename $barrier failure must finalize visible committed state" || exit 1
        assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
          "visible committed state must never roll back" || exit 1
        [[ -f "$ROTATE_STAMP" ]] || fail "committed recovery must write best-effort cooldown" || exit 1
      fi
    ) || return 1
  done
}

test_finalizing_transition_durability_never_rolls_back_committed_candidate() {
  local barrier rc
  for barrier in temp-sync final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      FINALIZING_BARRIER_USED=0
      managed_sync_file() {
        local path="${1:?}" state=''
        [[ ! -f "$path" ]] || state="$(sed -n 's/^state=//p' "$path")"
        if (( FINALIZING_BARRIER_USED == 0 )) && {
          [[ "$barrier" == temp-sync && "$path" == *'.safety-healthcheck.tmp.'* && "$state" == finalizing ]] ||
          [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" && "$state" == finalizing ]]
        }; then
          FINALIZING_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_file "$path"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}" state=''
        [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
        if [[ "$barrier" == parent-sync && "$state" == finalizing && "$FINALIZING_BARRIER_USED" == 0 ]]; then
          FINALIZING_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$FINALIZING_BARRIER_USED" "$barrier finalizing barrier must be exercised" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "$barrier finalizing failure must retain the committed candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" "$barrier finalizing outcome must retain qB intent" || exit 1
      [[ -f "$ROTATE_STAMP" ]] || fail "$barrier finalizing failure occurs after commit bookkeeping" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$barrier finalizing failure must not recreate precommit artifacts" || exit 1
      if [[ "$barrier" == temp-sync ]]; then
        assert_eq 1 "$rc" "pre-rename finalizing failure must retain committed owner for retry" || exit 1
        managed_safety_load || exit 1
        assert_eq committed "$MANAGED_SAFETY_STATE" \
          "pre-rename finalizing failure must leave visible committed state" || exit 1
        : > "$TRANSACTION_EVENTS"
        managed_reconcile_pending || fail "visible committed state must finalize on retry" || exit 1
        assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
          "committed retry must never enter rollback sequencing" || exit 1
      else
        assert_eq 0 "$rc" "post-rename finalizing $barrier failure must complete from visible finalizing" || exit 1
      fi
      [[ ! -e "$MANAGED_SAFETY" ]] || fail "$barrier finalizing outcome must eventually clear safety"
    ) || return 1
  done
}

test_final_safety_unlink_and_parent_sync_are_reboot_idempotent() {
  local failure rc safety_copy
  for failure in unlink parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_unlink_path | sed '1s/managed_unlink_path/transaction_original_unlink_path/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      FINAL_SAFETY_FAILURE_USED=0
      safety_copy="$TEST_TMP/finalizing-safety-copy"
      managed_unlink_path() {
        local path="${1:?}"
        if [[ "$path" == "$MANAGED_SAFETY" ]]; then
          cp -- "$MANAGED_SAFETY" "$safety_copy" || return 1
          if [[ "$failure" == unlink && "$FINAL_SAFETY_FAILURE_USED" == 0 ]]; then
            FINAL_SAFETY_FAILURE_USED=1
            return 1
          fi
        fi
        transaction_original_unlink_path "$path"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}"
        if [[ "$failure" == parent-sync && ! -e "$MANAGED_SAFETY" && "$FINAL_SAFETY_FAILURE_USED" == 0 ]]; then
          FINAL_SAFETY_FAILURE_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "final safety $failure failure must report incomplete cleanup" || exit 1
      assert_eq 1 "$FINAL_SAFETY_FAILURE_USED" "final safety $failure failure must be injected" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "final safety $failure failure must retain the committed candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" \
        "final safety $failure failure must retain verified qB intent" || exit 1
      [[ -f "$ROTATE_STAMP" ]] || fail "final safety $failure occurs only after commit bookkeeping" || exit 1
      if [[ "$failure" == unlink ]]; then
        [[ -f "$MANAGED_SAFETY" ]] || fail "failed unlink must retain finalizing evidence" || exit 1
      else
        [[ ! -e "$MANAGED_SAFETY" ]] || fail "post-unlink sync failure exposes the absent outcome" || exit 1
        managed_reconcile_pending || exit 1
        cp -- "$safety_copy" "$MANAGED_SAFETY"
        chmod 600 -- "$MANAGED_SAFETY"
      fi
      : > "$TRANSACTION_EVENTS"
      managed_reconcile_pending || fail "reappeared finalizing owner must be harmlessly repeatable" || exit 1
      [[ ! -e "$MANAGED_SAFETY" ]] || fail "repeated finalization must clear the safety owner" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "repeated finalization must not roll back the candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" "repeated finalization must restore qB intent" || exit 1
      assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
        "committed finalization must never enter rollback network sequencing"
    ) || return 1
  done
}

test_managed_staged_digest_mismatch_is_never_installed_or_guessed() {
  local rc events
  setup_managed_transaction_fixture || return 1
  run_wg_quick_down() {
    transaction_event "wg-down:$(transaction_phase):$(configured_endpoint "$WG_CONF")"
    TRANSACTION_RUNTIME_ENDPOINT=''
    printf '# changed after tunnel-down\n' >> "$MANAGED_CANDIDATE"
  }
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-journal candidate mutation must fail" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'profile-move:' "$events" "mismatched candidate must never be installed" || return 1
  assert_event_before 'exclude-write' 'wg-down:client-stopped:192.0.2.10:1637' \
    "pre-exclusion must be durable before downtime" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "candidate mismatch must retain journal and artifact" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" "candidate mismatch must leave qB stopped" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "candidate mismatch must not guess at an active-profile mutation"
}

test_managed_rollback_failure_retains_marker_candidate_and_stopped_qb() {
  local rc events
  setup_managed_transaction_fixture || return 1
  verify_tunnel() {
    local expected="${1:?}"
    transaction_event "network:$(transaction_phase):$expected"
    if [[ "$expected" == 198.51.100.20:1637 ]]; then
      TRANSACTION_FAIL_ACTION=rollback-up
      TRANSACTION_FAIL_REMAINING=-1
      return 1
    fi
    [[ "$TRANSACTION_RUNTIME_ENDPOINT" == "$expected" ]]
  }
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "candidate and rollback failure must fail closed" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_event_before 'exclude-write' 'wg-down:candidate-up:198.51.100.20:1637' \
    "failure exclusion refresh must precede the first rollback network effect" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "rollback failure must retain marker and candidate" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" "rollback failure must leave qB stopped" || return 1
  assert_not_contains 'marker-delete:' "$events" "failed rollback must not expose a commit"
}

test_managed_exclusion_refresh_failure_rolls_back_but_preserves_pending_state() {
  local rc write_count=0 events
  setup_managed_transaction_fixture || return 1
  managed_api_state_write() {
    write_count=$((write_count + 1))
    transaction_event "exclude-write:$write_count"
    (( write_count == 1 ))
  }
  TRANSACTION_FAIL_ACTION=network
  TRANSACTION_FAIL_REMAINING=1
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "exclusion refresh failure must remain failed" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'exclude-write:2' "$events" "candidate failure must refresh its exclusion" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "safety rollback must still restore the old profile" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "failed exclusion refresh must preserve pending cleanup" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" \
    "failed exclusion refresh must not restart qB while pending remains" || return 1
  assert_not_contains 'marker-delete:' "$events" "failed exclusion refresh must forbid cleanup"
}

setup_managed_crash_shape() {
  local phase="${1:?}" active_class="${2:?}" candidate_class="${3:?}"
  local runtime_class="${4:?}" qb_was_running="${5:-1}"
  managed_journal_fixture_digests || return 1
  write_raw_managed_journal "$phase" "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" 192.0.2.10:1637 198.51.100.20:1637 "$qb_was_running"
  if [[ "$qb_was_running" == 1 ]]; then
    write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" running
  else
    write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" stopped
  fi
  case "$active_class" in
    backup) command cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ;;
    candidate) command cp -- "$MANAGED_CANDIDATE" "$WG_CONF" ;;
    unknown) printf '# unknown active\n' >> "$WG_CONF" ;;
    *) return 1 ;;
  esac
  chmod 600 -- "$WG_CONF"
  case "$candidate_class" in
    present) ;;
    missing) command rm -f -- "$MANAGED_CANDIDATE" ;;
    mismatch) printf '# mismatch\n' >> "$MANAGED_CANDIDATE" ;;
    *) return 1 ;;
  esac
  case "$runtime_class" in
    old) TRANSACTION_RUNTIME_ENDPOINT=192.0.2.10:1637 ;;
    candidate) TRANSACTION_RUNTIME_ENDPOINT=198.51.100.20:1637 ;;
    down) TRANSACTION_RUNTIME_ENDPOINT='' ;;
    *) return 1 ;;
  esac
  if [[ "$qb_was_running" == 1 ]]; then
    case "$phase:$runtime_class" in
      prepared:old|verified:candidate) TRANSACTION_QB_STATE=running ;;
      *) TRANSACTION_QB_STATE=stopped ;;
    esac
  else
    TRANSACTION_QB_STATE=stopped
  fi
}

setup_amended_recovery_shape() {
  local safety_state="${1:?}" marker_shape="${2:?}" active_class="${3:?}"
  local candidate_class="${4:?}" qb_state="${5:-stopped}"
  setup_managed_transaction_fixture || return 1
  setup_immutable_docker_fake
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10
  managed_journal_fixture_digests || return 1
  write_raw_managed_safety "$safety_state" "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" running
  case "$active_class" in
    backup)
      cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
      TRANSACTION_RUNTIME_ENDPOINT=192.0.2.10:1637
      ;;
    candidate)
      cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
      TRANSACTION_RUNTIME_ENDPOINT=198.51.100.20:1637
      ;;
    unknown) printf '# unknown\n' >> "$WG_CONF" ;;
    *) return 1 ;;
  esac
  chmod 600 -- "$WG_CONF"
  case "$candidate_class" in
    present) ;;
    missing) rm -f -- "$MANAGED_CANDIDATE" ;;
    mismatch) printf '# mismatch\n' >> "$MANAGED_CANDIDATE" ;;
    *) return 1 ;;
  esac
  case "$marker_shape" in
    absent) rm -f -- "$ROTATION_PENDING" ;;
    matching)
      write_raw_managed_journal candidate-up "$JOURNAL_TEST_BACKUP_SHA" \
        "$JOURNAL_TEST_CANDIDATE_SHA" 192.0.2.10:1637 198.51.100.20:1637 1
      ;;
    invalid) printf 'invalid marker\n' > "$ROTATION_PENDING"; chmod 600 -- "$ROTATION_PENDING" ;;
    mismatched)
      write_raw_managed_journal candidate-up "$JOURNAL_TEST_CANDIDATE_SHA" \
        "$JOURNAL_TEST_BACKUP_SHA" 192.0.2.10:1637 198.51.100.20:1637 1
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$qb_state" > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
}

test_safety_record_drives_the_complete_recovery_classification_matrix() {
  local rc events
  setup_amended_recovery_shape pending absent candidate present stopped || return 1
  managed_reconcile_pending || fail "pending safety without journal must invoke safety-owned rollback" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "pending safety without journal must complete rollback" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
    fail "pending safety without journal must restore exact backup" || return 1

  setup_amended_recovery_shape pending matching candidate present stopped || return 1
  managed_reconcile_pending || fail "pending safety with matching journal must invoke rollback" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "pending safety with matching v2 must complete rollback" || return 1

  for marker_shape in invalid mismatched; do
    setup_amended_recovery_shape pending "$marker_shape" candidate present running || return 1
    : > "$TRANSACTION_EVENTS"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "pending safety plus $marker_shape journal must fail contained" || return 1
    [[ -f "$MANAGED_SAFETY" && -f "$ROTATION_PENDING" ]] ||
      fail "$marker_shape evidence must be retained" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "$marker_shape recovery must contain qB" || return 1
    events="$(<"$TRANSACTION_EVENTS")"
    assert_not_contains 'wg-down:' "$events" "$marker_shape evidence must block network guessing" || return 1
  done

  for committed_state in committed finalizing; do
    setup_amended_recovery_shape "$committed_state" absent candidate missing running || return 1
    managed_reconcile_pending || return 1
    [[ ! -e "$MANAGED_SAFETY" ]] ||
      fail "$committed_state safety must finalize idempotently" || return 1
    assert_eq 198.51.100.20:1637 "$TRANSACTION_RUNTIME_ENDPOINT" \
      "$committed_state must retain the committed candidate" || return 1

    setup_amended_recovery_shape "$committed_state" matching candidate missing running || return 1
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$committed_state plus marker must be impossible" || return 1
    [[ -f "$MANAGED_SAFETY" && -f "$ROTATION_PENDING" ]] ||
      fail "$committed_state impossible evidence must remain" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "$committed_state impossible state must contain qB" || return 1
  done

  setup_amended_recovery_shape pending absent candidate present running || return 1
  rm -f -- "$MANAGED_SAFETY"
  write_raw_managed_journal candidate-up "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" 192.0.2.10:1637 198.51.100.20:1637 1
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "orphan v2 without safety must fail" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "orphan v2 evidence must remain" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "orphan v2 must contain qB"

  setup_amended_recovery_shape pending absent candidate present running || return 1
  rm -f -- "$MANAGED_SAFETY"
  printf 'unknown marker bytes\n' > "$ROTATION_PENDING"
  chmod 600 -- "$ROTATION_PENDING"
  : > "$TRANSACTION_EVENTS"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "unknown marker without safety must fail contained" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "unknown orphan marker must remain" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "unknown orphan marker must contain configured qB" || return 1
  assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "unknown orphan marker must not mutate network" || return 1

  for invalid_marker in absent matching; do
    setup_amended_recovery_shape pending "$invalid_marker" candidate present running || return 1
    sed -i 's/^record=.*/record=invalid/' "$MANAGED_SAFETY"
    : > "$TRANSACTION_EVENTS"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "invalid safety plus $invalid_marker marker must fail" || return 1
    [[ -f "$MANAGED_SAFETY" ]] || fail "invalid safety evidence must remain" || return 1
    if [[ "$invalid_marker" == matching ]]; then
      [[ -f "$ROTATION_PENDING" ]] || fail "marker beside invalid safety must remain" || return 1
    fi
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "invalid safety must contain configured qB" || return 1
    assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
      "invalid safety must not mutate network" || return 1
  done

  for impossible_shape in backup-active unknown-active leftover-candidate; do
    case "$impossible_shape" in
      backup-active) setup_amended_recovery_shape committed absent backup missing running ;;
      unknown-active) setup_amended_recovery_shape committed absent unknown missing running ;;
      leftover-candidate) setup_amended_recovery_shape committed absent candidate present running ;;
    esac || return 1
    : > "$TRANSACTION_EVENTS"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$impossible_shape committed state must fail contained" || return 1
    [[ -f "$MANAGED_SAFETY" ]] || fail "$impossible_shape safety evidence must remain" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "$impossible_shape must contain qB" || return 1
    assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
      "$impossible_shape must not roll back or finalize by guessing" || return 1
  done
}

run_managed_recovery_in_fresh_process() {
  local runtime_file="${1:?}"
  # The quoted program is intentionally expanded only by the isolated child shell.
  # shellcheck disable=SC2016
  env -u BASH_ENV bash -c '
    set -u
    script=${1:?}; module=${2:?}; requested_wg_conf=${3:?}; runtime_file=${4:?}
    source "$script"
    source "$module"
    IFACE=wg0
    WG_CONF=$requested_wg_conf
    ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
    MANAGED_SAFETY="${WG_CONF}.safety-healthcheck"
    MANAGED_CANDIDATE="${WG_CONF%/*}/.${WG_CONF##*/}.managed-candidate"
    STATUS_FILE="${WG_CONF%/*}/wg0.status"
    ROTATE_STAMP="${WG_CONF%/*}/wg0.last_rotate"
    CONTEXT_LOCKED=1
    MANAGED_API_LOCK_FD=
    QBITTORRENT_CONTAINER=
    QBITTORRENT_PROCESS_NAME=qbittorrent-nox
    QBITTORRENT_LISTEN_IP=
    QBITTORRENT_LISTEN_PORT=
    QBITTORRENT_RESTART_DELAY=0
    QBITTORRENT_RESTART_TIMEOUT=10
    owner_mode() { printf "0:%s\n" "$(stat -c %a -- "$1")"; }
    log() { :; }
    write_status() { :; }
    write_stamp() { printf "1000\n" > "${1:?}"; }
    interface_exists() { [[ -s "$runtime_file" ]]; }
    run_wg_quick_down() { : > "$runtime_file"; }
    run_wg_quick_up() { configured_endpoint "$WG_CONF" > "$runtime_file"; }
    managed_verify_live_profile_identity() {
      [[ "$(<"$runtime_file")" == "$(configured_endpoint "${1:?}")" ]]
    }
    verify_tunnel() { [[ "$(<"$runtime_file")" == "${1:?}" ]]; }
    verify_post_rotation_speed() { return 0; }
    managed_reconcile_pending
  ' fresh-recovery "$SCRIPT" "$MODULE" "$WG_CONF" "$runtime_file"
}

test_fresh_process_recovery_uses_only_visible_safety_state() {
  local state runtime_file
  for state in pending committed finalizing; do
    setup_managed_journal_fixture || return 1
    managed_journal_fixture_digests || return 1
    runtime_file="$TEST_TMP/runtime-endpoint"
    cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
    chmod 600 -- "$WG_CONF"
    printf '198.51.100.20:1637\n' > "$runtime_file"
    rm -f -- "$ROTATION_PENDING"
    if [[ "$state" != pending ]]; then
      rm -f -- "$MANAGED_CANDIDATE"
    fi
    write_raw_managed_safety "$state" "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" unmanaged

    run_managed_recovery_in_fresh_process "$runtime_file" ||
      fail "$state recovery must succeed after re-sourcing without inherited globals" || return 1
    [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
      fail "$state fresh-process recovery must clear its durable owner" || return 1
    if [[ "$state" == pending ]]; then
      cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
        fail "fresh pending recovery must restore the exact backup" || return 1
      assert_eq 192.0.2.10:1637 "$(<"$runtime_file")" \
        "fresh pending recovery must restore the old tunnel" || return 1
    else
      assert_eq 198.51.100.20:1637 "$(<"$runtime_file")" \
        "fresh $state recovery must retain the committed candidate" || return 1
    fi
  done
}

test_managed_reconciliation_rolls_back_every_factual_crash_shape() {
  local shape phase active candidate runtime qb rc events checkpoint
  local -a shapes=(
    'prepared backup present old 1'
    'client-stopped backup present old 1'
    'tunnel-down backup present down 1'
    'candidate-installed candidate present down 1'
    'candidate-up candidate present candidate 1'
    'verified candidate present candidate 1'
    'verified candidate missing candidate 1'
    'candidate-up backup missing old 1'
    'candidate-up backup present old 0'
  )
  for shape in "${shapes[@]}"; do
    read -r phase active candidate runtime qb <<< "$shape"
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape "$phase" "$active" "$candidate" "$runtime" "$qb" || exit 1
      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      assert_eq 0 "$rc" "$shape must reconcile by verified rollback" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$shape successful recovery must remove candidate and marker" || exit 1
      cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
        fail "$shape must restore byte-for-byte backup content" || exit 1
      assert_eq 600 "$(stat -c '%a' "$WG_CONF")" "$shape restore must be mode 0600" || exit 1
      if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]]; then
        assert_eq 0 "$(stat -c '%u' "$WG_CONF")" "$shape restore must be root-owned" || exit 1
      fi
      assert_eq 192.0.2.10:1637 "$TRANSACTION_RUNTIME_ENDPOINT" \
        "$shape must restore and verify the old tunnel" || exit 1
      if [[ "$qb" == 1 ]]; then
        assert_eq running "$TRANSACTION_QB_STATE" "$shape must restore prior qB running intent" || exit 1
        events="$(<"$TRANSACTION_EVENTS")"
        assert_event_before 'identity:' 'qb-start:' \
          "$shape must prove old live identity before qB restore" || exit 1
        assert_event_before 'network:' 'qb-start:' \
          "$shape must prove old network before qB restore" || exit 1
        assert_event_before 'qb-start:' 'binding:' \
          "$shape must prove TCP/UDP ownership after qB starts" || exit 1
        for checkpoint in rollback-before-down rollback-after-down rollback-before-install \
            rollback-after-install rollback-before-up rollback-after-up rollback-before-network \
            rollback-after-network rollback-pre-cleanup rollback-post-cleanup; do
          assert_contains "qb-inspect:$checkpoint:" "$events" \
            "$shape must execute rollback containment checkpoint $checkpoint" || exit 1
        done
      else
        assert_eq stopped "$TRANSACTION_QB_STATE" "$shape must preserve prior stopped intent" || exit 1
      fi
    ) || return 1
  done
}

test_managed_unknown_or_mismatched_recovery_stops_qb_without_network_guessing() {
  local case_name rc events
  for case_name in active-unknown candidate-mismatch backup-mismatch invalid-journal; do
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape candidate-up candidate present candidate 1 || exit 1
      # This fixture state is intentionally local to the per-case recovery subshell.
      # shellcheck disable=SC2030
      TRANSACTION_QB_STATE=running
      case "$case_name" in
        active-unknown) printf '# active drift\n' >> "$WG_CONF" ;;
        candidate-mismatch) printf '# staged drift\n' >> "$MANAGED_CANDIDATE" ;;
        backup-mismatch) printf '# backup drift\n' >> "${WG_CONF}.bak-healthcheck" ;;
        invalid-journal) printf 'unknown=field\n' >> "$ROTATION_PENDING" ;;
      esac
      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name recovery must fail closed" || exit 1
      events="$(<"$TRANSACTION_EVENTS")"
      assert_contains 'qb-stop:' "$events" "$case_name must stop configured qB" || exit 1
      assert_eq stopped "$TRANSACTION_QB_STATE" "$case_name must prove qB stopped" || exit 1
      assert_not_contains 'wg-down:' "$events" "$case_name must not guess at tunnel mutation" || exit 1
      assert_not_contains 'profile-move:' "$events" "$case_name must not guess at profile restore" || exit 1
      [[ -f "$ROTATION_PENDING" ]] || fail "$case_name must retain its marker" || exit 1
      [[ -f "$MANAGED_CANDIDATE" ]] || fail "$case_name must retain its candidate" || exit 1
    ) || return 1
  done
}

test_managed_recovery_contains_qb_before_journal_or_digest_reads() {
  local case_name rc
  for case_name in valid malformed digest-mismatch; do
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape candidate-up candidate present candidate 1 || exit 1
      # This fixture state is intentionally local to the per-case recovery subshell.
      # shellcheck disable=SC2030
      TRANSACTION_QB_STATE=running
      eval "$(declare -f managed_journal_load | sed '1s/managed_journal_load/transaction_original_journal_load/')"
      eval "$(declare -f _managed_journal_recovery_state_is_consistent | sed '1s/_managed_journal_recovery_state_is_consistent/transaction_original_recovery_classifier/')"
      managed_journal_load() {
        transaction_event 'journal-load'
        transaction_original_journal_load
      }
      _managed_journal_recovery_state_is_consistent() {
        transaction_event 'digest-classify'
        transaction_original_recovery_classifier
      }
      case "$case_name" in
        valid) ;;
        malformed) printf 'unknown=field\n' >> "$ROTATION_PENDING" ;;
        digest-mismatch) printf '# drift\n' >> "${WG_CONF}.bak-healthcheck" ;;
      esac
      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      if [[ "$case_name" == valid ]]; then
        assert_eq 0 "$rc" "valid marker must still roll back" || exit 1
      else
        assert_eq 1 "$rc" "$case_name marker must fail closed" || exit 1
        [[ -f "$ROTATION_PENDING" ]] || fail "$case_name marker must be retained" || exit 1
      fi
      if [[ "$case_name" != digest-mismatch ]]; then
        assert_event_before 'qb-stop:' 'journal-load' \
          "$case_name recovery must stop and reinspect qB before parsing" || exit 1
      else
        assert_contains 'qb-stop:' "$(<"$TRANSACTION_EVENTS")" \
          "digest mismatch recovery must contain qB before safety artifact validation" || exit 1
        assert_not_contains 'journal-load' "$(<"$TRANSACTION_EVENTS")" \
          "safety artifact mismatch must fail before parsing the secondary journal" || exit 1
      fi
      if [[ "$case_name" == valid ]]; then
        assert_event_before 'qb-stop:' 'digest-classify' \
          "$case_name recovery must contain qB before artifact hashing" || exit 1
      fi
      if [[ "$case_name" == valid ]]; then
        assert_eq running "$TRANSACTION_QB_STATE" \
          "valid recovery may restore qB only after old network proof" || exit 1
      else
        assert_eq stopped "$TRANSACTION_QB_STATE" \
          "$case_name recovery must leave qB stopped"
      fi
    ) || return 1
  done
}

test_managed_reconciliation_is_idempotent_across_cleanup_crash() {
  local rc first_events
  setup_managed_transaction_fixture || return 1
  setup_managed_crash_shape candidate-up candidate present candidate 1 || return 1
  TRANSACTION_FAIL_ACTION=marker-delete
  TRANSACTION_FAIL_REMAINING=1
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "first cleanup interruption must remain pending" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "cleanup interruption must preserve the marker" || return 1
  # Independent tests rebuild this global fixture; the earlier subshell assignment cannot leak here.
  # shellcheck disable=SC2031
  assert_eq stopped "$TRANSACTION_QB_STATE" "failure after qB restore must stop it again" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
    fail "first reconciliation must already restore exact old bytes" || return 1
  first_events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'candidate-delete:' "$first_events" "first reconciliation reaches candidate cleanup" || return 1

  TRANSACTION_FAIL_ACTION=''
  : > "$TRANSACTION_EVENTS"
  managed_reconcile_pending || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "second reconciliation must finish cleanup idempotently" || return 1
  # See the intentional fixture-scope note above.
  # shellcheck disable=SC2031
  assert_eq running "$TRANSACTION_QB_STATE" "second reconciliation must restore qB intent" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
}

test_managed_qb_config_drift_restores_network_but_retains_safety() {
  local rc events
  setup_amended_recovery_shape pending matching candidate present running || return 1
  QBITTORRENT_CONTAINER=changed-container
  QBITTORRENT_LISTEN_PORT=6999
  printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/changed-container"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  : > "$DOCKER_FAKE_EVENTS"
  : > "$TRANSACTION_EVENTS"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "changed qB tuple must retain safety until operator repair" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'wg-down:' "$events" \
    "rollback-only checkpoints must permit exact old-network restoration after containment" || return 1
  assert_contains 'network:' "$events" \
    "tuple drift rollback must verify the restored old network" || return 1
  assert_eq 192.0.2.10:1637 "$TRANSACTION_RUNTIME_ENDPOINT" \
    "tuple drift rollback must restore the old runtime endpoint" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
    fail "tuple drift rollback must restore exact backup bytes" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "recorded qB container must remain stopped" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "safely identifiable current qB container must remain stopped" || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "verified drift rollback must clean candidate and journal evidence" || return 1
  [[ -f "$MANAGED_SAFETY" ]] ||
    fail "tuple drift must retain safety until the recorded intent can be restored" || return 1
  assert_not_contains 'start:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "tuple drift must never restart a container" || return 1
  assert_not_contains 'binding:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "tuple drift must not trust a listener binding probe"
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

tests=(
  test_managed_module_exports_minimal_task4_contract
  test_managed_module_validation_requires_root_owned_0644_trusted_source
  test_installed_key_rejects_every_unsafe_shape_before_downstream_events
  test_installed_key_opens_one_valid_record_on_a_private_descriptor
  test_fail_closed_dispatch_closes_credential_before_logging
  test_api_state_exports_complete_task5_contract
  test_api_state_round_trip_is_canonical_bounded_and_durable
  test_api_state_defaults_are_memory_only_until_identity_refresh
  test_api_state_rejects_unknown_duplicate_malformed_control_and_future_data
  test_api_state_rolling_attempt_cap_and_window_reset
  test_api_state_rejects_post_write_clock_regression
  test_api_state_backoff_is_exponential_jitter_bounded_and_retry_after_capped
  test_output_variable_helpers_replace_collision_sentinels_and_reject_reserved_names
  test_failed_credential_output_assignment_closes_new_descriptor
  test_managed_selector_replaces_every_collision_name_with_and_without_credential
  test_api_state_auth_device_reset_only_on_identity_change
  test_api_state_exclusions_are_unique_bounded_and_expire
  test_api_state_rejects_noncanonical_failure_classes_and_metadata
  test_api_state_memory_rejects_future_mtime_and_zero_failure_backoff
  test_api_state_admin_bypass_outcomes_and_timer_suppression
  test_api_state_failed_server_persists_then_expires_into_selector_argv
  test_failed_candidate_always_attempts_exactly_one_ordered_rollback
  test_suppressed_attempts_persist_pruned_high_water_and_surface_write_failure
  test_authenticated_suppression_persists_before_releasing_global_lock
  test_authenticated_attempt_samples_private_fresh_time_after_lock_and_provider
  test_linux_managed_selector_persists_failure_rotates_and_reenables
  test_api_state_corruption_blocks_authenticated_and_downstream_callbacks
  test_api_global_lock_requires_interface_lock_and_releases_before_downstream
  test_authenticated_attempt_closes_supplied_credential_around_state_and_downstream
  test_linux_global_lock_fd_never_aliases_supplied_credential
  test_linux_credential_identity_uses_exact_provider_fd_across_replacement
  test_linux_supplied_credential_fd_is_private_until_managed_owner
  test_linux_module_owner_and_mode_semantics
  test_linux_installed_key_owner_and_mode_semantics
  test_linux_api_state_parent_file_owner_mode_and_symlink_semantics
  test_managed_journal_round_trip_is_exact_and_rejects_noop_transactions
  test_managed_journal_rejects_noncanonical_bytes_fields_and_security_shapes
  test_managed_journal_write_is_same_directory_atomic_and_fully_durable
  test_managed_journal_artifacts_are_durable_before_first_digest
  test_managed_journal_artifact_barrier_failures_leave_no_journal_or_mutation
  test_managed_journal_classifiers_are_collision_safe_and_failure_atomic
  test_managed_journal_phase_transitions_revalidate_all_digests_and_classify_factually
  test_managed_journal_rejects_digest_bound_false_endpoints_before_transition_or_recovery
  test_private_identity_comparator_is_status_only_strict_and_secret_safe
  test_managed_safety_contract_is_strict_and_exact
  test_managed_docker_identity_inspect_uses_an_unambiguous_template
  test_managed_qb_inspection_parser_requires_exact_docker_boolean_tuple
  test_managed_qb_rejects_ambiguous_configured_name_before_every_effect
  test_managed_safety_rejects_ambiguous_recorded_name_without_network_guess
  test_managed_containment_never_treats_ambiguous_current_name_as_an_id
  test_managed_qb_immutable_identity_checkpoints_and_exact_restore
  test_managed_qbittorrent_state_is_exact_and_fail_closed
  test_managed_live_identity_requires_exact_address_and_peer_key
  test_managed_atomic_profile_install_is_digest_bound_and_durable
  test_managed_profile_transaction_orders_every_qb_and_tunnel_effect
  test_amended_transaction_keeps_a_durable_owner_through_commit_and_finalization
  test_managed_candidate_exclusion_removal_is_exact_and_durable
  test_managed_transaction_context_and_preexclusion_fail_before_mutation
  test_managed_transaction_identity_ordering_precedes_every_effect
  test_managed_transaction_rechecks_backup_identity_before_preexclusion
  test_managed_stop_failure_aborts_before_tunnel_downtime
  test_managed_every_phase_failure_rolls_back_exact_old_profile
  test_pending_rollback_never_writes_or_removes_rotation_success_stamp
  test_rollback_status_seam_cannot_reopen_qb_before_safety_removal
  test_pending_safety_creation_barriers_reclassify_the_visible_owner
  test_visible_pending_safety_requires_successful_rebarrier_before_recovery_effects
  test_journal_unlink_parent_sync_failure_never_recreates_v2_marker
  test_commit_transition_durability_reclassifies_pending_vs_committed
  test_finalizing_transition_durability_never_rolls_back_committed_candidate
  test_final_safety_unlink_and_parent_sync_are_reboot_idempotent
  test_managed_staged_digest_mismatch_is_never_installed_or_guessed
  test_managed_rollback_failure_retains_marker_candidate_and_stopped_qb
  test_managed_exclusion_refresh_failure_rolls_back_but_preserves_pending_state
  test_managed_reconciliation_rolls_back_every_factual_crash_shape
  test_safety_record_drives_the_complete_recovery_classification_matrix
  test_fresh_process_recovery_uses_only_visible_safety_state
  test_managed_unknown_or_mismatched_recovery_stops_qb_without_network_guessing
  test_managed_recovery_contains_qb_before_journal_or_digest_reads
  test_managed_reconciliation_is_idempotent_across_cleanup_crash
  test_managed_qb_config_drift_restores_network_but_retains_safety
  test_linux_managed_journal_real_owner_mode_and_symlink_semantics
)

if [[ -n "${WG_MANAGED_TEST_ONLY:-}" ]]; then
  read -r -a tests <<< "$WG_MANAGED_TEST_ONLY"
fi

failures=0
passes=0
skips=0
for test_name in "${tests[@]}"; do
  ("$test_name")
  rc=$?
  case "$rc" in
    0)
      printf 'ok - %s\n' "$test_name"
      passes=$((passes + 1))
      ;;
    77)
      printf 'ok - %s # SKIP requires Linux root ownership semantics\n' "$test_name"
      skips=$((skips + 1))
      ;;
    *)
      printf 'not ok - %s\n' "$test_name"
      failures=$((failures + 1))
      ;;
  esac
done

if (( failures > 0 )); then
  printf '%d test(s) failed; %d passed; %d skipped\n' "$failures" "$passes" "$skips" >&2
  exit 1
fi

printf '%d test(s) passed; %d skipped\n' "$passes" "$skips"
