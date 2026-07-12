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
  : > "$TEST_TMP/sync-events"
  owner_mode() {
    if [[ -d "$1" ]]; then printf '0:700\n'; else printf '0:600\n'; fi
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

select_with_persisted_exclusions() {
  python3 - "$ROOT/libexec/airvpn-api" "$@" <<'PYTHON'
import importlib.machinery
import importlib.util
import sys

path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("task5_airvpn_api", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
loader.exec_module(module)
arguments = module._build_parser().parse_args(["select", *sys.argv[2:]])

def server(name, address, load):
    return {
        "public_name": name,
        "country_code": "GB",
        "location": "London",
        "bw_max": 10000,
        "currentload": load,
        "users": 1,
        "health": "ok",
        "ip_v4_in1": address,
    }

payload = {
    "result": "ok",
    "servers": [
        server("Alpha-1", "198.51.100.10", 0),
        server("Bravo-2", "198.51.100.11", 50),
    ],
}
candidate = module.select_candidate(
    payload,
    ["GB"],
    1637,
    "",
    arguments.exclude_server,
)
if candidate is None:
    raise SystemExit("selector returned no candidate")
print(candidate[0])
PYTHON
}

write_valid_test_key() {
  printf '%064d\n' 0 > "$1"
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

  managed_api_state_defaults 1000 || return 1
  MANAGED_API_WINDOW_START=1000
  MANAGED_API_ATTEMPT_COUNT=2
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
  assert_eq $'version=1\nwindow_start=1000\nattempt_count=2\nbackoff_until=1300\nfailure_class=transient\ncredential_device=11\ncredential_inode=22\ncredential_mtime=33\ncredential_size=65\nconfigured_device=Device-One\nexclude_count=2\nexclude_01=Alpha-1,1200\nexclude_02=Bravo-2,1300' \
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
  managed_api_state_load 1000 || return 1
  assert_eq 2 "$MANAGED_API_ATTEMPT_COUNT" "state attempt count must round trip" || return 1
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
      future_backoff future_exclusion duplicate_server gap count_mismatch oversized; do
    case "$case_name" in
      unknown) printf '%s\nunknown_field=1\n' "$base" > "$AIRVPN_API_STATE_FILE" ;;
      duplicate) printf '%s\nattempt_count=1\n' "$base" > "$AIRVPN_API_STATE_FILE" ;;
      out_of_order)
        printf '%s\n' "$base" | sed 's/window_start=1000/attempt_count=0/;s/attempt_count=0/window_start=1000/2' > "$AIRVPN_API_STATE_FILE"
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
  local attempt rc
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

  for attempt in 1 2 3 4 5 6; do
    managed_api_record_attempt 1000 0 || return 1
    assert_eq "$attempt" "$MANAGED_API_ATTEMPT_COUNT" "attempt must be durably counted" || return 1
  done
  set +e; managed_api_record_attempt 1000 0; rc=$?; set +e
  assert_eq 75 "$rc" "seventh daily attempt must be suppressed" || return 1
  set +e; managed_api_record_attempt 1000 1; rc=$?; set +e
  assert_eq 75 "$rc" "administrative bypass must not bypass daily limit" || return 1

  managed_api_record_attempt 87400 0 || return 1
  assert_eq 1 "$MANAGED_API_ATTEMPT_COUNT" "elapsed 24-hour window must reset attempt count" || return 1
  assert_eq 87400 "$MANAGED_API_WINDOW_START" "new rolling window must start at the next attempt"
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
  mv -f -- "$replacement" "$AIRVPN_API_KEY_FILE"
  managed_api_state_refresh_identity 1100 || return 1
  assert_eq none "$MANAGED_API_FAILURE_CLASS" "credential replacement must clear authentication suppression" || return 1

  MANAGED_API_FAILURE_CLASS=rate
  MANAGED_API_BACKOFF_UNTIL=2000
  replacement="$AIRVPN_API_KEY_FILE.replacement"
  printf '2%063d\n' 0 > "$replacement"
  chmod 600 -- "$replacement"
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
      zero_metadata empty_device; do
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
    esac
    chmod 600 -- "$AIRVPN_API_STATE_FILE"
    set +e; managed_api_state_load 1000 >/dev/null 2>&1; rc=$?; set +e
    [[ "$rc" != 0 ]] || fail "$case_name metadata/class must fail closed" || return 1
  done
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

test_linux_persisted_exclusion_selects_alternate_then_reeligible_server() {
  local selected
  local -a args=()
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
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
  selected="$(select_with_persisted_exclusions "${args[@]}")" || return 1
  assert_eq Bravo-2 "$selected" \
    "persisted failure must drive actual selection to the alternate server" || return 1

  managed_api_state_defaults 1 || return 1
  managed_api_state_load 22600 || return 1
  managed_api_exclusion_args args 22600 || return 1
  selected="$(select_with_persisted_exclusions "${args[@]}")" || return 1
  assert_eq Alpha-1 "$selected" \
    "expired persisted exclusion must restore the preferred server to eligibility"
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
  managed_run_authenticated_attempt 1000 0 '' provider_probe downstream_probe
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
IFACE="$1"
AIRVPN_DEVICE=Device-One
STATE_DIR="$TEST_ROOT/run"
AIRVPN_API_LOCK="$STATE_DIR/airvpn-api.lock"
AIRVPN_API_STATE_FILE="$TEST_ROOT/var/$IFACE.api-state"
AIRVPN_API_KEY_FILE="$TEST_ROOT/etc/$IFACE.api-key"
LOCK="$STATE_DIR/$IFACE.lock"
printf '%064d\n' 0 > "$AIRVPN_API_KEY_FILE"
chmod 600 -- "$AIRVPN_API_KEY_FILE"
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
managed_run_authenticated_attempt 1000 0 '' provider_probe downstream_probe
WORKER
  chmod 700 -- "$script_path"

  CONTEXT_LOCKED=0
  AIRVPN_API_LOCK="$TEST_TMP/run/airvpn-api.lock"
  set +e; managed_global_api_lock_acquire; worker=$?; set +e
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
  managed_global_api_lock_acquire() {
    bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$PROBE_FD" || return 1
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

  managed_run_authenticated_attempt 1000 0 "$credential_fd" provider_probe downstream_probe || return 1
  assert_eq $'provider\ndownstream' "$(<"$TEST_TMP/fd-events")" \
    "only the authenticated provider callback may observe the supplied credential" || return 1
  set +e; IFS= read -r -u "$credential_fd" _ 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "managed attempt owner must close the supplied descriptor after provider use"
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
  test_api_state_backoff_is_exponential_jitter_bounded_and_retry_after_capped
  test_api_state_auth_device_reset_only_on_identity_change
  test_api_state_exclusions_are_unique_bounded_and_expire
  test_api_state_rejects_noncanonical_failure_classes_and_metadata
  test_api_state_admin_bypass_outcomes_and_timer_suppression
  test_api_state_failed_server_persists_then_expires_into_selector_argv
  test_linux_persisted_exclusion_selects_alternate_then_reeligible_server
  test_api_state_corruption_blocks_authenticated_and_downstream_callbacks
  test_api_global_lock_requires_interface_lock_and_releases_before_downstream
  test_authenticated_attempt_closes_supplied_credential_around_state_and_downstream
  test_linux_supplied_credential_fd_is_private_until_managed_owner
  test_linux_module_owner_and_mode_semantics
  test_linux_installed_key_owner_and_mode_semantics
  test_linux_api_state_parent_file_owner_mode_and_symlink_semantics
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
