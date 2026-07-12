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

write_managed_candidate_fixture() {
  local endpoint="${1:-198.51.100.20:1637}"
  printf '%s\n' \
    '[Interface]' \
    'Address = 192.0.2.2/32' \
    'PrivateKey = fixture-old-interface-value' \
    '[Peer]' \
    'PublicKey = fixture-new-peer-value' \
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
  MANAGED_CANDIDATE="${WG_CONF%/*}/.${WG_CONF##*/}.managed-candidate"
  STATUS_FILE="$TEST_TMP/run/wg-healthcheck/wg0.status"
  mkdir -p -- "${WG_CONF%/*}" "${STATUS_FILE%/*}"
  chmod 700 -- "${WG_CONF%/*}" "${STATUS_FILE%/*}"
  printf '%s\n' \
    '[Interface]' \
    'Address = 192.0.2.2/32' \
    'PrivateKey = fixture-old-interface-value' \
    '[Peer]' \
    'PublicKey = fixture-old-peer-value' \
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
      "$JOURNAL_TEST_CANDIDATE_SHA" "$wrong_old" "$wrong_candidate" 1
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

test_managed_reconciliation_retains_every_unresolved_v2_shape_for_task7() {
  local rc active_before candidate_before
  setup_managed_journal_fixture || return 1
  managed_journal_fixture_digests || return 1
  managed_journal_prepare 1 || return 1
  active_before="$(<"$WG_CONF")"
  candidate_before="$(<"$MANAGED_CANDIDATE")"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "Task 6 must fail closed until Task 7 owns verified rollback" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "unresolved reconciliation must retain marker and candidate" || return 1
  assert_eq "$active_before" "$(<"$WG_CONF")" "reconciliation seam must not guess or restore active bytes" || return 1
  assert_eq "$candidate_before" "$(<"$MANAGED_CANDIDATE")" "reconciliation seam must not delete candidate bytes" || return 1
  assert_contains 'failed:' "$(<"$TEST_TMP/journal-events")" "fail-closed reconciliation must publish redacted status" || return 1

  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  managed_journal_load || return 1
  MANAGED_JOURNAL_PHASE=tunnel-down
  write_raw_managed_journal tunnel-down "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "phase lag with candidate active must remain factual and unresolved" || return 1
  assert_eq candidate "$MANAGED_JOURNAL_ACTIVE_CLASS" \
    "recovery classifier must report candidate-active despite a lagging phase" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "phase-lag marker must remain" || return 1

  cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  write_raw_managed_journal candidate-up "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "later phase with rollback-started backup active must stay unresolved" || return 1
  assert_eq backup "$MANAGED_JOURNAL_ACTIVE_CLASS" \
    "recovery classifier must report backup-active despite an advanced phase" || return 1

  write_raw_managed_journal tunnel-down "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA"
  rm -f -- "$MANAGED_CANDIDATE"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "candidate may not be missing before verified" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "early missing-candidate marker must remain" || return 1

  write_raw_managed_journal verified "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA"
  write_managed_candidate_fixture
  cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  rm -f -- "$MANAGED_CANDIDATE"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "verified candidate cleanup crash still requires Task 7 finalization" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "verified cleanup marker must remain" || return 1

  cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
  chmod 600 -- "$WG_CONF"
  write_raw_managed_journal candidate-up "$JOURNAL_TEST_BACKUP_SHA" "$JOURNAL_TEST_CANDIDATE_SHA"
  : > "$TEST_TMP/journal-events"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "missing candidate with backup active must not be falsely finalized" || return 1
  assert_eq backup "$MANAGED_JOURNAL_ACTIVE_CLASS" \
    "rollback-cleanup crash must classify its active backup factually" || return 1
  assert_eq missing "$MANAGED_JOURNAL_CANDIDATE_CLASS" \
    "rollback-cleanup crash must classify its removed candidate factually" || return 1
  assert_contains managed_rotation_requires_verified_rollback "$(<"$TEST_TMP/journal-events")" \
    "backup-active cleanup crash must remain a safe Task 7 recovery seam" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "ambiguous rollback-cleanup marker must remain"
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
  test_managed_reconciliation_retains_every_unresolved_v2_shape_for_task7
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
