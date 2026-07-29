#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

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
