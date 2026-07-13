#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

# Shared fixtures, assertions, and helper functions for wg-healthcheck tests.
# Test runner variables (ROOT, SCRIPT, VERSION_FILE) are initialized by the runner.

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}
assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}
assert_file_absent() {
  local path="$1" message="${2:-file must be absent}"
  [[ ! -e "$path" ]] || fail "$message ($path exists)"
}
assert_contains() {
  local needle="$1" haystack="$2" message="${3:-text not found}"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing '$needle')"
}
assert_file_equals() {
  local expected="$1" path="$2" message="${3:-file content differs}"
  local actual
  actual="$(<"$path")"
  assert_eq "$expected" "$actual" "$message"
}
file_text() {
  if [[ -f "$1" ]]; then
    command cat -- "$1"
  fi
}
new_recovery_fixture() {
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  TEST_EVENTS="$TEST_TMP/events"
  : > "$TEST_EVENTS"
  TEST_SYNC_EVENTS="$TEST_TMP/sync-events"
  : > "$TEST_SYNC_EVENTS"

  source "$SCRIPT"
  IFACE=wg0
  WG_CONF="$TEST_TMP/wg0.conf"
  STATE_DIR="$TEST_TMP/state"
  RESTART_STAMP="$STATE_DIR/wg0.last_restart"
  ROTATE_STAMP="$STATE_DIR/wg0.last_rotate"
  SPEED_STAMP="$STATE_DIR/wg0.last_speedcheck"
  STATUS_FILE="$STATE_DIR/wg0.status"
  SETUP_GUARD="$STATE_DIR/wg0.setup-guard"
  ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
  LOCK="$STATE_DIR/wg0.lock"
  mkdir -p "$STATE_DIR"
  printf '%s\n' \
    '[Interface]' \
    'PrivateKey = secret' \
    '[Peer]' \
    'PublicKey = peer' \
    'Endpoint = 192.0.2.10:1637' > "$WG_CONF"
  chmod 600 "$WG_CONF"

  MAX_AGE=180
  REQUIRED_ROUTE='default dev wg0 table 40'
  REQUIRED_RULE='100: from 10.0.0.2 lookup 40'
  COOLDOWN=0
  AIRVPN_ROTATE_COOLDOWN=0
  AIRVPN_ROTATE_ENABLED=1
  AIRVPN_WG_PORT=1637
  SPEED_MIN_BPS=2500000
  SPEED_RETRY_DELAY=0
  RESTART_DELAY=0
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_LISTEN_IP=
  QBITTORRENT_LISTEN_PORT=
  QBITTORRENT_CONTAINER=
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  RUNTIME_ENDPOINT='192.0.2.10:1637'
  SYNC_FAIL_TARGET=
  SYNC_MATCHES_TO_SKIP=0
  SYNC_FAILURES_REMAINING=0

  current_epoch() { printf '1000\n'; }
  date() { printf '1000\n'; }
  sleep() { :; }
  sync() {
    local arg target="${!#}"
    {
      printf 'sync'
      for arg in "$@"; do printf '\t%s' "$arg"; done
      printf '\n'
    } >> "$TEST_SYNC_EVENTS"
    if [[ -n "$SYNC_FAIL_TARGET" && "$target" == "$SYNC_FAIL_TARGET" ]]; then
      if [[ "$SYNC_MATCHES_TO_SKIP" -gt 0 ]]; then
        SYNC_MATCHES_TO_SKIP=$((SYNC_MATCHES_TO_SKIP - 1))
      elif [[ "$SYNC_FAILURES_REMAINING" -gt 0 ]]; then
        SYNC_FAILURES_REMAINING=$((SYNC_FAILURES_REMAINING - 1))
        return 1
      fi
    fi
    return 0
  }
  log() { printf 'log:%s\n' "$*" >> "$TEST_EVENTS"; }
  select_airvpn_candidate() {
    printf 'Candidate\t198.51.100.20:1637\tGB\tLondon\t10000\t10\t20\n'
  }
  runtime_endpoint() { printf '%s\n' "$RUNTIME_ENDPOINT"; }
  handshake_age() { printf '0\n'; }
  interface_exists() { return 0; }
  wireguard_responds() { return 0; }
  required_route_present() { return 0; }
  required_rule_present() { return 0; }
  verify_airvpn_egress() { return 0; }
  run_wg_quick_down() { return 0; }
  run_wg_quick_up() {
    RUNTIME_ENDPOINT="$(configured_endpoint)"
    return 0
  }
}
new_main_fixture() {
  new_recovery_fixture
  CFG="$TEST_TMP/health.conf"
  printf 'MAX_AGE=180\n' > "$CFG"
  chmod 600 "$CFG"
  derive_fixed_runtime_paths() {
    CFG="$TEST_TMP/health.conf"
    WG_CONF="$TEST_TMP/wg0.conf"
    STATE_DIR="$TEST_TMP/state"
    LOCK="$STATE_DIR/wg0.lock"
    RESTART_STAMP="$STATE_DIR/wg0.last_restart"
    ROTATE_STAMP="$STATE_DIR/wg0.last_rotate"
    SPEED_STAMP="$STATE_DIR/wg0.last_speedcheck"
    STATUS_FILE="$STATE_DIR/wg0.status"
    SETUP_GUARD="$STATE_DIR/wg0.setup-guard"
    ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
    MANAGED_SAFETY="${WG_CONF}.safety-healthcheck"
    AIRVPN_API_HELPER="$ROOT/libexec/airvpn-api"
    MANAGED_MODULE="$ROOT/libexec/wg-healthcheck-managed"
    AIRVPN_API_KEY_FILE="$TEST_TMP/healthcheck.d/wg0.api-key"
    AIRVPN_API_STATE_FILE="$TEST_TMP/persistent/wg0.api-state"
    AIRVPN_API_LOCK="$STATE_DIR/airvpn-api.lock"
    MANAGED_CANDIDATE="$TEST_TMP/.wg0.conf.managed-candidate"
    PRE_MANAGED_CONF="$TEST_TMP/wg0.conf.pre-managed"
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  }
  is_root() { return 0; }
  owner_mode() { printf '0:%s\n' "$(stat -c '%a' -- "$1")"; }
  setup_guard_metadata_matches() {
    local inspected_fd="${1:?}"
    [[ -f "$SETUP_GUARD" && ! -L "$SETUP_GUARD" &&
       -e "/proc/$BASHPID/fd/$inspected_fd" &&
       "/proc/$BASHPID/fd/$inspected_fd" -ef "$SETUP_GUARD" ]]
  }
  interface_lock_fd_identity() { stat -Lc '%d:%i' -- "$LOCK"; }
  validate_secure_executable() { return 0; }
  validate_secure_file() { return 0; }
  prepare_state_dir() { mkdir -p "$STATE_DIR"; }
  flock() { return 0; }
}
config_endpoint_line() {
  grep -E '^Endpoint[[:space:]]*=' "$WG_CONF"
}
pop_speed_sample() {
  local queue="$1" sample remainder
  sample="$(head -n 1 "$queue")"
  remainder="$(tail -n +2 "$queue")"
  printf '%s' "$remainder" > "$queue"
  [[ -z "$remainder" ]] || printf '\n' >> "$queue"
  printf '%s\n' "$sample"
}
seed_pending_rotation() {
  backup_config || return 1
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"
  chmod 600 "$ROTATION_PENDING"
  set_config_endpoint '198.51.100.20:1637' || return 1
  RUNTIME_ENDPOINT='198.51.100.20:1637'
}
