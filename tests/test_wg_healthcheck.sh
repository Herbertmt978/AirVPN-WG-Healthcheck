#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/wg-healthcheck"
VERSION_FILE="$ROOT/VERSION"

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

test_version_output_is_fixed_and_public() {
  local expected actual
  expected="$(<"$VERSION_FILE")"
  [[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not semantic" || return 1
  actual="$(WG_HEALTHCHECK_VERSION=9.9.9 bash "$SCRIPT" --version)" || return 1
  assert_eq "wg-healthcheck $expected" "$actual" "--version must match the tracked release version"
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

test_sourceable_without_executing_or_enabling_errexit() {
  local source_rc

  set +e
  if source "$SCRIPT"; then
    source_rc=0
  else
    source_rc=$?
  fi

  assert_eq 0 "$source_rc" "sourcing the orchestrator must succeed" || return 1
  local function_name
  for function_name in main rotate_airvpn restart_iface speed_check ensure_qbittorrent_binding \
      close_private_fd run_with_private_fd_closed; do
    declare -F "$function_name" >/dev/null || fail "sourcing must define $function_name" || return 1
  done
  [[ $- != *e* ]] || fail "sourcing must not enable errexit in the caller"
}

test_runtime_cli_preserves_legacy_version_and_rejects_unknown_forms() {
  local rc payload usage_text
  source "$SCRIPT"
  declare -F parse_cli >/dev/null || fail "strict runtime CLI parser is missing" || return 1

  parse_cli wg0 || return 1
  assert_eq check "$COMMAND" "legacy invocation must select the timer health command" || return 1
  assert_eq wg0 "$IFACE" "legacy invocation must retain the interface" || return 1
  assert_eq '' "$ACTION_MODE" "legacy invocation must not imply a mutation mode" || return 1
  assert_eq 1 "$LEGACY_INVOCATION" "single-interface syntax must retain benign timer contention semantics" || return 1

  parse_cli check wg0 || return 1
  assert_eq check "$COMMAND" "explicit check must select the health command" || return 1
  assert_eq 0 "$LEGACY_INVOCATION" "explicit check must remain distinguishable from the timer form" || return 1

  parse_cli --version || return 1
  assert_eq version "$COMMAND" "--version must remain a standalone command" || return 1
  usage_text="$(usage 2>&1)"
  assert_contains 'wg-healthcheck check <iface> [--setup-lease-fd N]' "$usage_text" \
    "usage must document setup-owned controlled checks" || return 1
  assert_contains 'wg-healthcheck provision <iface> --dry-run [--credential-fd N] [--settings-fd N]' "$usage_text" \
    "usage must document the provision dry-run settings override" || return 1
  assert_contains 'wg-healthcheck provision <iface> --apply [--credential-fd N]' "$usage_text" \
    "usage must keep provision apply credential-only" || return 1
  assert_contains 'wg-healthcheck adopt <iface> --dry-run [--credential-fd N] [--settings-fd N]' "$usage_text" \
    "usage must document the adopt dry-run settings override" || return 1
  assert_contains 'wg-healthcheck adopt <iface> --apply [--credential-fd N]' "$usage_text" \
    "usage must keep adopt apply credential-only" || return 1
  assert_contains 'wg-healthcheck cleanup-candidate <iface> --apply --setup-lease-fd N' "$usage_text" \
    "usage must document the setup-only orphan recovery command" || return 1

  for payload in '' '--version wg0' 'unknown wg0 --dry-run' 'wg0 extra' \
      'status --bad' 'rotate bad/interface --dry-run'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "strict CLI must reject '$payload'" || return 1
  done
}

test_setup_lease_cli_is_explicit_scoped_and_fd_distinct() {
  local command payload rc
  source "$SCRIPT"

  parse_cli check wg0 --setup-lease-fd 12 || return 1
  assert_eq 12 "$SETUP_LEASE_FD" "explicit check may reuse setup's exclusive lease" || return 1
  assert_eq 0 "$LEGACY_INVOCATION" "lease-bearing checks must never masquerade as timer runs" || return 1

  for command in provision adopt restore-static reset-api-state; do
    parse_cli "$command" wg0 --dry-run --setup-lease-fd 12 || return 1
    assert_eq 12 "$SETUP_LEASE_FD" "$command may reuse setup's exclusive lease" || return 1
  done

  parse_cli cleanup-candidate wg0 --apply --setup-lease-fd 12 || return 1
  assert_eq cleanup-candidate "$COMMAND" \
    "candidate cleanup must have an explicit administrative command" || return 1
  assert_eq apply "$ACTION_MODE" "candidate cleanup must be apply-only" || return 1
  assert_eq 12 "$SETUP_LEASE_FD" \
    "candidate cleanup must require setup's inherited lease" || return 1

  for payload in \
      'wg0 --setup-lease-fd 12' \
      'status wg0 --setup-lease-fd 12' \
      'rotate wg0 --dry-run --setup-lease-fd 12' \
      'cleanup-candidate wg0' \
      'cleanup-candidate wg0 --apply' \
      'cleanup-candidate wg0 --dry-run --setup-lease-fd 12' \
      'cleanup-candidate wg0 --apply --credential-fd 11 --setup-lease-fd 12' \
      'cleanup-candidate wg0 --apply --settings-fd 11 --setup-lease-fd 12' \
      'cleanup-candidate wg0 --apply --setup-lease-fd 12 --setup-lease-fd 13' \
      'check wg0 --dry-run' \
      'check wg0 --setup-lease-fd 2' \
      'check wg0 --setup-lease-fd 012' \
      'check wg0 --setup-lease-fd nope' \
      'check wg0 --setup-lease-fd 12 --setup-lease-fd 13' \
      'provision wg0 --dry-run --credential-fd 12 --setup-lease-fd 12' \
      'provision wg0 --dry-run --credential-fd 11 --settings-fd 12 --setup-lease-fd 12'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "setup lease grammar must reject '$payload'" || return 1
  done
}

test_mutating_cli_requires_exactly_one_mode_and_scopes_options() {
  local command rc payload
  source "$SCRIPT"
  declare -F parse_cli >/dev/null || fail "strict runtime CLI parser is missing" || return 1

  for command in provision adopt rotate restore-static reset-api-state; do
    parse_cli "$command" wg0 --dry-run || return 1
    assert_eq "$command" "$COMMAND" "$command must dispatch by name" || return 1
    assert_eq dry-run "$ACTION_MODE" "$command --dry-run must remain non-mutating" || return 1
    parse_cli "$command" wg0 --apply || return 1
    assert_eq apply "$ACTION_MODE" "$command --apply must be explicit" || return 1

    for payload in "$command wg0" "$command wg0 --dry-run --apply" \
        "$command wg0 --apply --apply" "$command wg0 --json"; do
      read -r -a argv <<< "$payload"
      set +e
      parse_cli "${argv[@]}" >/dev/null 2>&1
      rc=$?
      set +e
      assert_eq 64 "$rc" "mutating CLI must reject '$payload'" || return 1
    done
  done

  parse_cli provision wg0 --credential-fd 9 --dry-run || return 1
  assert_eq 9 "$CREDENTIAL_FD" "provision may accept a descriptor number" || return 1
  parse_cli adopt wg0 --apply --credential-fd 10 || return 1
  assert_eq 10 "$CREDENTIAL_FD" "adopt may accept a descriptor number" || return 1
  parse_cli provision wg0 --credential-fd 9 --settings-fd 10 --dry-run || return 1
  assert_eq 10 "$SETTINGS_FD" "provision dry-run may accept proposed settings" || return 1
  assert_eq 9 "$CREDENTIAL_FD" "proposed settings must preserve the credential descriptor" || return 1
  parse_cli adopt wg0 --dry-run --settings-fd 11 --credential-fd 10 || return 1
  assert_eq 11 "$SETTINGS_FD" "adopt dry-run may accept proposed settings in either option order" || return 1
  for payload in 'rotate wg0 --dry-run --credential-fd 9' \
      'restore-static wg0 --apply --credential-fd 9' \
      'provision wg0 --dry-run --credential-fd 2' \
      'provision wg0 --dry-run --credential-fd 09' \
      'adopt wg0 --apply --credential-fd nope' \
      'provision wg0 --dry-run --credential-fd 9 --credential-fd 10'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "credential descriptor grammar must reject '$payload'" || return 1
  done
  for payload in 'rotate wg0 --dry-run --settings-fd 9' \
      'restore-static wg0 --dry-run --settings-fd 9' \
      'provision wg0 --dry-run --settings-fd 9' \
      'provision wg0 --apply --settings-fd 9' \
      'adopt wg0 --apply --settings-fd 9' \
      'provision wg0 --dry-run --settings-fd 2' \
      'provision wg0 --dry-run --settings-fd 09' \
      'adopt wg0 --dry-run --settings-fd nope' \
      'provision wg0 --dry-run --settings-fd 10 --settings-fd 11' \
      'provision wg0 --dry-run --credential-fd 10 --settings-fd 10' \
      'provision wg0 --dry-run --settings-fd 10 --credential-fd 10'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "settings descriptor grammar must reject '$payload'" || return 1
  done

  parse_cli status wg0 || return 1
  assert_eq 0 "$STATUS_JSON" "status defaults to text" || return 1
  parse_cli status wg0 --json || return 1
  assert_eq 1 "$STATUS_JSON" "status alone may request JSON" || return 1
  set +e; parse_cli status wg0 --dry-run >/dev/null 2>&1; rc=$?; set +e
  assert_eq 64 "$rc" "status must reject mutation flags"
}

test_settings_descriptor_is_exact_stable_private_and_canonical() {
  local case_name metadata_case payload rc settings_fd credential_fd metadata_calls
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  COMMAND=provision
  ACTION_MODE=dry-run

  # Unit fixtures run as both root and a normal user. Preserve the real descriptor
  # identity/size while replacing only the owner field so this test exercises the
  # production parser rather than depending on the test runner's uid.
  if [[ "$(id -u)" != 0 ]]; then
    settings_fd_metadata() {
      local output_variable="${1:?}" descriptor="${2:?}" value
      value="$(stat -Lc '600|%s|%d|%i|%y|%z|regular file' -- \
        "/proc/$BASHPID/fd/$descriptor" {descriptor}<&- 2>/dev/null)" || return 1
      printf -v "$output_variable" '0|%s' "$value"
    }
  fi

  payload=$'version=1\ndevice=Device One\ncountries=GB NL\n'
  printf '%s' "$payload" > "$TEST_TMP/settings"
  chmod 600 -- "$TEST_TMP/settings"
  exec 3<"$TEST_TMP/credential"
  exec 4<"$TEST_TMP/settings"
  credential_fd=3
  settings_fd=4
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  capture_cli_settings_fd || return 1
  assert_eq '' "$SETTINGS_FD" "capture must close and clear the original settings descriptor" || return 1
  assert_eq 1 "$PROPOSED_SETTINGS_READY" "valid settings must arm the in-memory overlay" || return 1
  assert_eq 'Device One' "$PROPOSED_AIRVPN_DEVICE" "device must be captured exactly" || return 1
  assert_eq 'GB NL' "$PROPOSED_AIRVPN_COUNTRIES" "ordered country policy must be captured exactly" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] || fail "settings descriptor must be closed after capture" || return 1
  IFS= read -r -u "$credential_fd" _ || fail "capture must not consume the credential descriptor" || return 1
  exec {credential_fd}<&-

  printf '%s' $'version=1\ndevice=Device One\ncountries=ALL\n' > "$TEST_TMP/anonymous-settings"
  chmod 600 -- "$TEST_TMP/anonymous-settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/anonymous-settings"
  rm -f -- "$TEST_TMP/anonymous-settings"
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  capture_cli_settings_fd || return 1
  assert_eq '' "$PROPOSED_AIRVPN_COUNTRIES" \
    "ALL must map to the runtime's explicit empty all-country policy" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "capture must support and close an unlinked private temporary file" || return 1
  exec {credential_fd}<&-

  for case_name in missing_newline extra_field bad_version empty_device long_device \
      bad_device lower_country duplicate_country mixed_all double_space too_many_countries; do
    case "$case_name" in
      missing_newline) payload=$'version=1\ndevice=default\ncountries=GB' ;;
      extra_field) payload=$'version=1\ndevice=default\ncountries=GB\nextra=x\n' ;;
      bad_version) payload=$'version=01\ndevice=default\ncountries=GB\n' ;;
      empty_device) payload=$'version=1\ndevice=\ncountries=GB\n' ;;
      long_device) payload="version=1"$'\n'"device=$(printf '%065d' 0)"$'\n'"countries=GB"$'\n' ;;
      bad_device) payload=$'version=1\ndevice=-default\ncountries=GB\n' ;;
      lower_country) payload=$'version=1\ndevice=default\ncountries=gb\n' ;;
      duplicate_country) payload=$'version=1\ndevice=default\ncountries=GB GB\n' ;;
      mixed_all) payload=$'version=1\ndevice=default\ncountries=ALL GB\n' ;;
      double_space) payload=$'version=1\ndevice=default\ncountries=GB  NL\n' ;;
      too_many_countries) payload=$'version=1\ndevice=default\ncountries=AA AB AC AD AE AF AG AH AI AJ AK AL AM AN AO AP AQ AR AS AT AU AV AW AX AY AZ BA BB BC BD BE BF BG\n' ;;
    esac
    printf '%s' "$payload" > "$TEST_TMP/settings"
    exec {credential_fd}<"$TEST_TMP/credential"
    exec {settings_fd}<"$TEST_TMP/settings"
    SETTINGS_FD="$settings_fd"
    CREDENTIAL_FD="$credential_fd"
    PROPOSED_SETTINGS_READY=0
    set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name settings record must fail closed" || return 1
    assert_eq '' "$SETTINGS_FD" "$case_name refusal must still close the descriptor" || return 1
    assert_eq 0 "$PROPOSED_SETTINGS_READY" "$case_name refusal must not arm an overlay" || return 1
    [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] || fail "$case_name descriptor leaked" || return 1
    [[ ! -e "/proc/$BASHPID/fd/$credential_fd" ]] || fail "$case_name credential descriptor leaked" || return 1
  done

  payload=$'version=1\ndevice=default\ncountries=ALL\n'
  printf '%s' "$payload" > "$TEST_TMP/settings"
  for metadata_case in wrong_owner wrong_mode oversized nonregular; do
    exec {credential_fd}<"$TEST_TMP/credential"
    exec {settings_fd}<"$TEST_TMP/settings"
    SETTINGS_FD="$settings_fd"
    CREDENTIAL_FD="$credential_fd"
    SETTINGS_METADATA_CASE="$metadata_case"
    SETTINGS_METADATA_PROBE_FD="$settings_fd"
    settings_fd_metadata() {
      local output_variable="${1:?}" descriptor="${2:?}" base owner=0 mode=600 kind='regular file'
      base="$(stat -Lc '%s|%d|%i' -- "/proc/$BASHPID/fd/$descriptor" {descriptor}<&-)" || return 1
      if [[ "$descriptor" == "$SETTINGS_METADATA_PROBE_FD" ]]; then
        case "$SETTINGS_METADATA_CASE" in
          wrong_owner) owner=1 ;;
          wrong_mode) mode=640 ;;
          oversized) base="257|${base#*|}" ;;
          nonregular) kind='fifo' ;;
        esac
      fi
      printf -v "$output_variable" '%s|%s|%s|%s|%s|%s' \
        "$owner" "$mode" "$base" '2026-07-13 12:00:00.000000001 +0000' \
        '2026-07-13 12:00:00.000000001 +0000' "$kind"
    }
    set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$metadata_case settings metadata must fail closed" || return 1
    [[ ! -e "/proc/$BASHPID/fd/$credential_fd" && ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
      fail "$metadata_case refusal must close both private descriptors" || return 1
  done

  printf '%s' $'version=1\ndevice=default\ncountries=ALL\n' > "$TEST_TMP/settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  SETTINGS_FD="$settings_fd"
  CREDENTIAL_FD="$credential_fd"
  metadata_calls=0
  settings_fd_metadata() {
    local output_variable="${1:?}" descriptor="${2:?}" value
    metadata_calls=$((metadata_calls + 1))
    value="$(stat -Lc '0|600|%s|%d|%i' -- \
      "/proc/$BASHPID/fd/$descriptor" {descriptor}<&-)"
    value+='|2026-07-13 12:00:00.000000001 +0000|2026-07-13 12:00:00.000000001 +0000|regular file'
    if (( metadata_calls == 4 )); then
      value="${value/12:00:00.000000001 +0000|regular file/12:00:00.000000002 +0000|regular file}"
    fi
    printf -v "$output_variable" '%s' "$value"
  }
  set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "metadata drift during capture must fail closed" || return 1
  assert_eq '' "$SETTINGS_FD" "metadata drift must still close the settings descriptor" || return 1

  settings_fd_metadata() {
    local output_variable="${1:?}" descriptor="${2:?}" value
    value="$(stat -Lc '0|600|%s|%d|%i|%Y|%Z|regular file' -- \
      "/proc/$BASHPID/fd/$descriptor" {descriptor}<&-)" || return 1
    printf -v "$output_variable" '%s' "$value"
  }
  exec {credential_fd}<"$TEST_TMP/settings"
  exec {settings_fd}<"$TEST_TMP/settings"
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "different descriptor numbers for one inode must be rejected" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$credential_fd" && ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "same-inode refusal must close both descriptors"
}

test_main_captures_settings_before_context_and_overlays_only_memory() {
  local credential_fd settings_fd rc before_cfg events leaked=''
  new_main_fixture
  printf '%s\n' \
    'MAX_AGE=180' \
    'AIRVPN_PROFILE_SOURCE=static' \
    'AIRVPN_DEVICE=Installed-Device' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  before_cfg="$(<"$CFG")"
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  printf '%s' $'version=1\ndevice=Proposed Device\ncountries=NZ AU\n' > "$TEST_TMP/settings"
  chmod 600 -- "$TEST_TMP/settings"
  : > "$TEST_TMP/settings-events"
  events="$TEST_TMP/settings-events"
  settings_fd_metadata() {
    local output_variable="${1:?}" descriptor="${2:?}" value
    value="$(stat -Lc '0|600|%s|%d|%i|%Y|%Z|regular file' -- \
      "/proc/$BASHPID/fd/$descriptor" {descriptor}<&- 2>/dev/null)" || return 1
    printf -v "$output_variable" '%s' "$value"
  }
  load_managed_module() { :; }
  managed_dispatch_command() {
    [[ ! "$TEST_TMP/settings" -ef "/proc/$BASHPID/fd/$SETTINGS_PROBE_FD" ]] || return 91
    printf 'dispatch:%s:%s\n' "$AIRVPN_DEVICE" "$AIRVPN_COUNTRIES" >> "$events"
  }
  eval "$(declare -f load_command_context | sed '1s/load_command_context/original_load_command_context/')"
  load_command_context() {
    [[ ! "$TEST_TMP/settings" -ef "/proc/$BASHPID/fd/$SETTINGS_PROBE_FD" ]] || return 92
    [[ ! "$TEST_TMP/credential" -ef "/proc/$BASHPID/fd/$CREDENTIAL_PROBE_FD" ]] || return 93
    original_load_command_context || return 1
    printf 'context:%s:%s\n' "$AIRVPN_DEVICE" "$AIRVPN_COUNTRIES" >> "$events"
  }

  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  CREDENTIAL_PROBE_FD="$credential_fd"
  SETTINGS_PROBE_FD="$settings_fd"
  main provision wg0 --dry-run --credential-fd "$credential_fd" \
    --settings-fd "$settings_fd" || return 1
  assert_eq $'context:Proposed Device:NZ AU\ndispatch:Proposed Device:NZ AU' "$(<"$events")" \
    "proposed settings must be overlaid after parsing and before managed dry-run" || return 1
  assert_eq "$before_cfg" "$(<"$CFG")" "settings overlay must never rewrite installed config" || return 1
  [[ ! "$TEST_TMP/settings" -ef "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "settings descriptor reached a downstream child" || return 1

  : > "$events"
  printf '%s' $'version=1\ndevice=default\ncountries=gb\n' > "$TEST_TMP/settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  CREDENTIAL_PROBE_FD="$credential_fd"
  SETTINGS_PROBE_FD="$settings_fd"
  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" \
    --settings-fd "$settings_fd" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "invalid proposed settings must fail before context" || return 1
  assert_eq '' "$(<"$events")" "invalid settings must precede config, state, lock, and provider effects" || return 1
  set +e; IFS= read -r -u "$credential_fd" leaked 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "invalid settings must close the credential descriptor too" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] || fail "invalid settings descriptor leaked"
}

test_main_sanitizes_before_settings_metadata_children() {
  local credential_fd settings_fd rc events marker
  new_main_fixture
  events="$TEST_TMP/events"
  marker="$TEST_TMP/hostile-stat"
  : > "$events"
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  printf '%s' $'version=1\ndevice=default\ncountries=GB\n' > "$TEST_TMP/settings"
  chmod 600 -- "$TEST_TMP/settings"

  eval "$(declare -f sanitize_process_environment | sed \
    '1s/sanitize_process_environment/original_sanitize_process_environment/')"
  sanitize_process_environment() {
    printf 'sanitize\n' >> "$events"
    if ! /bin/bash -c '
      [[ ! -e "/proc/self/fd/$1" && ! -e "/proc/self/fd/$2" ]]
    ' bash "$credential_fd" "$settings_fd"; then
      printf 'private descriptor reached sanitizer child\n' >> "$marker"
    fi
    original_sanitize_process_environment
  }
  eval "$(declare -f capture_cli_settings_fd | sed \
    '1s/capture_cli_settings_fd/original_capture_cli_settings_fd/')"
  capture_cli_settings_fd() {
    printf 'capture\n' >> "$events"
    [[ "$PATH" == /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ]] || return 97
    [[ -z "${AIRVPN_API_KEY+x}" && -z "${LD_LIBRARY_PATH+x}" ]] || return 98
    original_capture_cli_settings_fd
  }
  load_command_context() { return 1; }
  stat() { printf 'hostile stat executed\n' >> "$marker"; return 99; }

  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  PATH="$TEST_TMP"
  AIRVPN_API_KEY='environment sentinel'
  LD_LIBRARY_PATH="$TEST_TMP"
  export PATH AIRVPN_API_KEY LD_LIBRARY_PATH
  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" \
    --settings-fd "$settings_fd" >/dev/null 2>&1
  rc=$?
  set +e

  assert_eq 1 "$rc" "the post-capture context refusal must remain visible" || return 1
  assert_eq $'sanitize\ncapture' "$(<"$events")" \
    "core suppression must be followed by environment sanitization before settings capture" || return 1
  [[ ! -e "$marker" ]] || fail "settings metadata must not resolve a hostile stat function" || return 1
  [[ -z "${AIRVPN_API_KEY+x}" && -z "${LD_LIBRARY_PATH+x}" ]] ||
    fail "settings metadata children must receive no inherited secret or loader environment" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$credential_fd" && ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "failed post-capture context must close both private descriptors"
}

test_second_sanitizer_failure_closes_restored_credential_fd() {
  local credential_fd rc read_rc leaked='' sanitizer_calls=0
  new_main_fixture
  printf 'credential sentinel\n' > "$TEST_TMP/credential"

  eval "$(declare -f sanitize_process_environment | sed \
    '1s/sanitize_process_environment/original_sanitize_process_environment/')"
  sanitize_process_environment() {
    sanitizer_calls=$((sanitizer_calls + 1))
    (( sanitizer_calls == 1 )) || return 88
    original_sanitize_process_environment
  }

  exec {credential_fd}<"$TEST_TMP/credential"
  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" >/dev/null 2>&1
  rc=$?
  set +e

  assert_eq 1 "$rc" "second sanitizer failure must fail closed" || return 1
  assert_eq 2 "$sanitizer_calls" "context loading must exercise the second sanitizer" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$credential_fd" ]] ||
    fail "restored credential descriptor leaked after second sanitizer failure" || return 1
  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "restored credential descriptor must be unreadable" || return 1
  assert_eq '' "$CREDENTIAL_FD" "failed main path must clear credential ownership"
}

test_runtime_defaults_and_fixed_paths_ignore_environment() {
  local key actual
  local -A expected=(
    [MAX_AGE]=180 [PING_TARGET]='' [PING_COUNT]=1 [PING_TIMEOUT]=2
    [REQUIRED_ROUTE]='' [REQUIRED_RULE]='' [COOLDOWN]=300 [RESTART_DELAY]=5
    [WG_DOWN_TIMEOUT]=20 [WG_UP_TIMEOUT]=30 [SPEED_CHECK_ENABLED]=0
    [SPEED_CHECK_INTERVAL]=900 [SPEED_CHECK_URL]='https://speed.cloudflare.com/__down?bytes=10000000'
    [SPEED_MIN_BPS]=2500000 [SPEED_TIMEOUT]=25 [SPEED_RETRY_DELAY]=5
    [AIRVPN_ROTATE_ENABLED]=0 [AIRVPN_PROFILE_SOURCE]=static [AIRVPN_DEVICE]=''
    [AIRVPN_COUNTRIES]='GB NL BE DE FR IE'
    [AIRVPN_WG_PORT]=1637 [AIRVPN_ROTATE_COOLDOWN]=1800
    [AIRVPN_STATUS_URL]='https://airvpn.org/api/status/?format=json'
    [AIRVPN_WHATISMYIP_URL]='https://airvpn.org/api/whatismyip/?format=json'
    [AIRVPN_API_TIMEOUT]=20 [QBITTORRENT_CONTAINER]='' [QBITTORRENT_LISTEN_IP]=''
    [QBITTORRENT_LISTEN_PORT]='' [QBITTORRENT_PROCESS_NAME]=qbittorrent-nox
    [QBITTORRENT_RESTART_DELAY]=5 [QBITTORRENT_RESTART_TIMEOUT]=60
  )

  source "$SCRIPT"
  declare -F reset_configurable_defaults >/dev/null || fail "configurable-default reset owner is missing" || return 1
  declare -F derive_fixed_runtime_paths >/dev/null || fail "fixed runtime-path owner is missing" || return 1
  for key in "${!expected[@]}"; do printf -v "$key" '%s' hostile; done
  reset_configurable_defaults
  for key in "${!expected[@]}"; do
    actual="${!key}"
    assert_eq "${expected[$key]}" "$actual" "$key must reset to its documented default" || return 1
  done

  IFACE=wg0
  for key in CFG WG_CONF STATE_DIR LOCK SETUP_GUARD RESTART_STAMP ROTATE_STAMP SPEED_STAMP STATUS_FILE \
      ROTATION_PENDING MANAGED_SAFETY AIRVPN_API_HELPER MANAGED_MODULE AIRVPN_API_KEY_FILE \
      AIRVPN_API_STATE_FILE AIRVPN_API_LOCK MANAGED_CANDIDATE PRE_MANAGED_CONF PATH; do
    printf -v "$key" '%s' "/tmp/hostile-$key"
  done
  derive_fixed_runtime_paths
  assert_eq '/etc/wireguard/healthcheck.d/wg0.conf' "$CFG" "CFG must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf' "$WG_CONF" "WG_CONF must be fixed" || return 1
  assert_eq '/run/wg-healthcheck' "$STATE_DIR" "STATE_DIR must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.lock' "$LOCK" "LOCK must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.setup-guard' "$SETUP_GUARD" "setup guard path must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_restart' "$RESTART_STAMP" "restart stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_rotate' "$ROTATE_STAMP" "rotation stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_speedcheck' "$SPEED_STAMP" "speed stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.status' "$STATUS_FILE" "status path must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.pending-healthcheck' "$ROTATION_PENDING" "pending marker must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.safety-healthcheck' "$MANAGED_SAFETY" "managed safety path must be fixed" || return 1
  assert_eq '/usr/local/libexec/wg-healthcheck/airvpn-api' "$AIRVPN_API_HELPER" "helper path must be fixed" || return 1
  assert_eq '/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed' "$MANAGED_MODULE" "managed module path must be fixed" || return 1
  assert_eq '/etc/wireguard/healthcheck.d/wg0.api-key' "$AIRVPN_API_KEY_FILE" "credential path must be fixed" || return 1
  assert_eq '/var/lib/wg-healthcheck/wg0.api-state' "$AIRVPN_API_STATE_FILE" "persistent API state path must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/airvpn-api.lock' "$AIRVPN_API_LOCK" "global API lock path must be fixed" || return 1
  assert_eq '/etc/wireguard/.wg0.conf.managed-candidate' "$MANAGED_CANDIDATE" "managed candidate path must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.pre-managed' "$PRE_MANAGED_CONF" "pre-managed snapshot path must be fixed" || return 1
  assert_eq '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$PATH" "PATH must be fixed"
}

test_process_environment_is_sanitized_for_child_commands() {
  local key exported
  local -a removed=(
    BASH_ENV ENV CDPATH GLOBIGNORE IFS PS4 PROMPT_COMMAND
    LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME AIRVPN_API_KEY
  )
  source "$SCRIPT"
  declare -F sanitize_process_environment >/dev/null || fail "process-environment sanitizer is missing" || return 1
  PATH=/tmp/hostile-bin
  LC_ALL=POSIX
  for key in "${removed[@]}"; do
    printf -v "$key" '%s' hostile
    export "$key"
  done
  export SHELLOPTS BASHOPTS 2>/dev/null || true

  sanitize_process_environment

  assert_eq '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$PATH" "sanitized PATH must be fixed" || return 1
  assert_eq C "$LC_ALL" "child locale must be deterministic" || return 1
  for key in "${removed[@]}"; do
    [[ -z "${!key+x}" ]] || fail "$key must be unset before child commands" || return 1
  done
  exported="$(export -p)"
  [[ "$exported" != *'SHELLOPTS'* && "$exported" != *'BASHOPTS'* ]] ||
    fail "readonly Bash option variables must not be exported to children"
}

test_hostile_internal_paths_cannot_redirect_main_or_truncate_lock_target() {
  local rc victim expected_cfg expected_wg calls
  new_main_fixture
  expected_cfg="$CFG"
  expected_wg="$WG_CONF"
  victim="$TEST_TMP/victim"
  printf 'do-not-truncate\n' > "$victim"
  CFG="$TEST_TMP/hostile.conf"
  WG_CONF="$TEST_TMP/hostile-wg.conf"
  STATE_DIR="$TEST_TMP/hostile-state"
  LOCK="$victim"
  SETUP_GUARD="$victim"
  RESTART_STAMP="$TEST_TMP/hostile-restart"
  ROTATE_STAMP="$TEST_TMP/hostile-rotate"
  SPEED_STAMP="$TEST_TMP/hostile-speed"
  STATUS_FILE="$TEST_TMP/hostile-status"
  ROTATION_PENDING="$TEST_TMP/hostile-pending"
  AIRVPN_API_HELPER="$TEST_TMP/hostile-helper"
  PATH="$TEST_TMP/hostile-path"
  : > "$TEST_TMP/validated"
  validate_secure_file() { printf '%s\n' "$1" >> "$TEST_TMP/validated"; return 0; }
  flock() { return 1; }

  set +e
  main wg0
  rc=$?
  set +e
  calls="$(<"$TEST_TMP/validated")"

  assert_eq 0 "$rc" "lock contention on the fixed lock must remain nonfatal" || return 1
  assert_file_equals 'do-not-truncate' "$victim" "hostile LOCK must never be opened" || return 1
  assert_eq "$expected_cfg" "$CFG" "main must replace hostile CFG through its source-only path seam" || return 1
  assert_eq "$expected_wg" "$WG_CONF" "main must replace hostile WG_CONF through its source-only path seam" || return 1
  assert_eq '' "$calls" "guard contention must precede every configuration validation" || return 1
  assert_eq "$TEST_TMP/state/wg0.setup-guard" "$SETUP_GUARD" "main must replace hostile setup-guard input"
}

test_main_validates_both_fixed_files_before_parsing_config() {
  local rc events expected
  new_main_fixture
  : > "$TEST_TMP/order"
  validate_secure_file() { printf 'validate:%s:%s:%s\n' "$1" "$2" "$3" >> "$TEST_TMP/order"; }
  parse_healthcheck_config() { printf 'parse:%s\n' "$1" >> "$TEST_TMP/order"; }
  validate_settings() { printf 'settings\n' >> "$TEST_TMP/order"; return 1; }
  prepare_state_dir() { mkdir -p -- "$STATE_DIR"; }

  set +e
  main wg0
  rc=$?
  set +e
  events="$(<"$TEST_TMP/order")"
  expected="validate:${CFG}:health-check configuration:600"$'\n'
  expected+="validate:${WG_CONF}:WireGuard configuration:600"$'\n'
  expected+="parse:${CFG}"$'\nsettings'

  assert_eq 1 "$rc" "fixture must stop after validation and parsing" || return 1
  assert_eq "$expected" "$events" "both fixed files must validate before CFG is parsed and semantically validated"
}

test_config_parser_accepts_template_and_whole_quoted_values() {
  local file
  source "$SCRIPT"
  declare -F parse_healthcheck_config >/dev/null || fail "strict config parser is missing" || return 1
  declare -F reset_configurable_defaults >/dev/null || return 1
  reset_configurable_defaults
  parse_healthcheck_config "$ROOT/config/wg0.conf.example" || fail "valid installed template must parse" || return 1
  assert_eq 2 "$PING_COUNT" "template numeric setting must apply" || return 1
  assert_eq static "$AIRVPN_PROFILE_SOURCE" "template must explicitly retain static mode" || return 1
  assert_eq '' "$AIRVPN_DEVICE" "static template must not invent a device" || return 1
  assert_eq 'GB NL BE DE FR IE' "$AIRVPN_COUNTRIES" "template quoted country list must apply" || return 1

  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  file="$TEST_TMP/valid.conf"
  printf '%s\n' \
    'PING_TARGET=' \
    'AIRVPN_COUNTRIES="GB NL"' \
    'REQUIRED_ROUTE="default dev wg0 table 40"' \
    "REQUIRED_RULE='from 10.0.0.2 lookup 40'" \
    'SPEED_CHECK_URL=https://speed.cloudflare.com/__down?bytes=10000000' > "$file"
  reset_configurable_defaults
  parse_healthcheck_config "$file" || return 1
  assert_eq '' "$PING_TARGET" "empty value must parse" || return 1
  assert_eq 'GB NL' "$AIRVPN_COUNTRIES" "whole double-quoted value must parse" || return 1
  assert_eq 'default dev wg0 table 40' "$REQUIRED_ROUTE" "quoted route must parse" || return 1
  assert_eq 'from 10.0.0.2 lookup 40' "$REQUIRED_RULE" "whole single-quoted value must parse"
}

test_config_parser_rejects_internal_unknown_duplicate_and_malformed_keys() {
  local payload rc file
  local -a payloads=(
    'LOCK=/tmp/victim' 'CFG=/tmp/config' 'ARBITRARY=value' 'BASH_ENV=/tmp/code'
    'PATH=/tmp/bin' 'LD_PRELOAD=/tmp/lib.so' $'MAX_AGE=10\nMAX_AGE=11'
    ' MAX_AGE=10' 'MAX_AGE =10' 'export MAX_AGE=10' 'MAX_AGE[0]=10' 'MAX_AGE'
  )
  source "$SCRIPT"
  declare -F parse_healthcheck_config >/dev/null || fail "strict config parser is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  file="$TEST_TMP/rejected.conf"
  log() { :; }
  for payload in "${payloads[@]}"; do
    printf '%s\n' "$payload" > "$file"
    set +e; parse_healthcheck_config "$file"; rc=$?; set +e
    assert_eq 1 "$rc" "parser must reject unsafe assignment: $payload" || return 1
  done
}

test_config_parser_rejects_ambiguous_syntax_without_execution_or_partial_apply() {
  local payload rc file marker
  local -a payloads=(
    'PING_TARGET="unterminated' 'PING_TARGET=bad\value' $'PING_TARGET=bad\tvalue'
    'PING_TARGET=`id`' 'PING_TARGET="ok"trailing'
  )
  source "$SCRIPT"
  declare -F parse_healthcheck_config >/dev/null || fail "strict config parser is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  file="$TEST_TMP/rejected.conf"
  marker="$TEST_TMP/executed"
  log() { :; }
  for payload in "${payloads[@]}"; do
    printf '%s\n' "$payload" > "$file"
    set +e; parse_healthcheck_config "$file"; rc=$?; set +e
    assert_eq 1 "$rc" "parser must reject ambiguous value syntax: $payload" || return 1
  done

  MAX_AGE=777
  printf '%s\n' 'MAX_AGE=10' "PING_TARGET=\$(touch $marker)" > "$file"
  set +e; parse_healthcheck_config "$file"; rc=$?; set +e
  assert_eq 1 "$rc" "command substitution syntax must be rejected" || return 1
  assert_eq 777 "$MAX_AGE" "a later parse failure must not partially apply earlier settings" || return 1
  assert_file_absent "$marker" "configuration parsing must never execute command substitution"
}

test_config_parser_rejects_oversized_file_and_line() {
  local rc file oversized i
  source "$SCRIPT"
  declare -F parse_healthcheck_config >/dev/null || fail "strict config parser is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  file="$TEST_TMP/oversized.conf"
  log() { :; }

  printf -v oversized '%*s' 5000 ''
  oversized="${oversized// /a}"
  printf 'PING_TARGET=%s\n' "$oversized" > "$file"
  set +e; parse_healthcheck_config "$file"; rc=$?; set +e
  assert_eq 1 "$rc" "oversized logical line must be rejected" || return 1

  : > "$file"
  for ((i = 0; i < 7000; i++)); do printf '# bounded comment\n' >> "$file"; done
  set +e; parse_healthcheck_config "$file"; rc=$?; set +e
  assert_eq 1 "$rc" "oversized configuration file must be rejected"
}

test_api_settings_require_device_allowed_port_and_normalize_countries() {
  local code count=0 first second rc too_many invalid_device invalid_countries invalid_port allowed_port
  source "$SCRIPT"
  declare -F normalize_api_countries >/dev/null || fail "API country normalizer is missing" || return 1
  log() { :; }

  reset_configurable_defaults
  AIRVPN_PROFILE_SOURCE=api
  AIRVPN_DEVICE='Device 1._-'
  AIRVPN_WG_PORT=47107
  AIRVPN_COUNTRIES='gb NL gb de nl'
  validate_secure_executable() { fail "API setting validation must not touch provider code before the credential boundary"; }
  validate_settings || return 1
  assert_eq 'GB NL DE' "$AIRVPN_COUNTRIES" "API countries must normalize uniquely in selected order" || return 1

  AIRVPN_COUNTRIES=
  validate_settings || return 1
  assert_eq '' "$AIRVPN_COUNTRIES" "an explicit empty API country list must retain ALL semantics" || return 1

  for invalid_device in '' '-leading' 'slash/name' $'line\nbreak' \
      "$(printf '%65s' '' | tr ' ' a)" $'d\303\251vice'; do
    reset_configurable_defaults
    AIRVPN_PROFILE_SOURCE=api
    AIRVPN_DEVICE="$invalid_device"
    set +e; validate_settings; rc=$?; set +e
    assert_eq 1 "$rc" "API mode must reject invalid device '$invalid_device'" || return 1
  done

  for invalid_port in 1 53 443 65535; do
    reset_configurable_defaults
    AIRVPN_PROFILE_SOURCE=api
    AIRVPN_DEVICE=default
    AIRVPN_WG_PORT="$invalid_port"
    set +e; validate_settings; rc=$?; set +e
    assert_eq 1 "$rc" "API mode must reject undocumented WireGuard port $invalid_port" || return 1
  done
  for allowed_port in 1637 47107 51820; do
    reset_configurable_defaults
    AIRVPN_PROFILE_SOURCE=api
    AIRVPN_DEVICE=default
    AIRVPN_WG_PORT="$allowed_port"
    validate_settings || fail "API mode must accept documented WireGuard port $allowed_port" || return 1
  done

  for invalid_countries in 'G' 'GBR' 'G1' 'GB,NL'; do
    reset_configurable_defaults
    AIRVPN_PROFILE_SOURCE=api
    AIRVPN_DEVICE=default
    AIRVPN_COUNTRIES="$invalid_countries"
    set +e; validate_settings; rc=$?; set +e
    assert_eq 1 "$rc" "API country grammar must reject '$invalid_countries'" || return 1
  done

  too_many=
  for first in A B; do
    for second in {A..Z}; do
      code="${first}${second}"
      too_many+="${too_many:+ }$code"
      count=$((count + 1))
      [[ "$count" -ge 33 ]] && break 2
    done
  done
  reset_configurable_defaults
  AIRVPN_PROFILE_SOURCE=api
  AIRVPN_DEVICE=default
  AIRVPN_COUNTRIES="$too_many"
  set +e; validate_settings; rc=$?; set +e
  assert_eq 1 "$rc" "API country allowlist must contain at most 32 unique codes" || return 1

  reset_configurable_defaults
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_WG_PORT=53
  AIRVPN_COUNTRIES='legacy selector text'
  validate_settings || fail "static mode must retain its broader legacy port and country contract" || return 1

  AIRVPN_PROFILE_SOURCE=managed
  set +e; validate_settings; rc=$?; set +e
  assert_eq 1 "$rc" "profile source must be exactly static or api"
}

test_managed_qb_container_name_rejects_exact_immutable_id_without_static_regression() {
  local ambiguous_name rc
  source "$SCRIPT"
  log() { :; }
  ambiguous_name=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  validate_container_name "$ambiguous_name" ||
    fail "the legacy Docker-name grammar must continue to accept a 64-hex name" || return 1

  reset_configurable_defaults
  AIRVPN_PROFILE_SOURCE=api
  AIRVPN_DEVICE=default
  QBITTORRENT_CONTAINER="$ambiguous_name"
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  set +e; validate_settings >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" \
    "managed mode must reject a Docker name that is indistinguishable from an immutable ID" ||
    return 1

  reset_configurable_defaults
  AIRVPN_PROFILE_SOURCE=static
  QBITTORRENT_CONTAINER="$ambiguous_name"
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  validate_settings ||
    fail "static mode must retain its existing broad Docker-name compatibility"
}

test_restart_cooldown_prevents_every_rotation_side_effect() {
  local tmp events original rc
  tmp="$(mktemp -d)"
  trap "rm -rf -- '$tmp'" EXIT
  events="$tmp/events"
  original=$'[Interface]\nPrivateKey = secret\n[Peer]\nEndpoint = 192.0.2.10:1637\n'
  printf '%s' "$original" > "$tmp/wg0.conf"
  : > "$events"

  source "$SCRIPT"
  IFACE=wg0
  WG_CONF="$tmp/wg0.conf"
  STATE_DIR="$tmp/state"
  RESTART_STAMP="$STATE_DIR/wg0.last_restart"
  ROTATE_STAMP="$STATE_DIR/wg0.last_rotate"
  STATUS_FILE="$STATE_DIR/wg0.status"
  COOLDOWN=300
  AIRVPN_ROTATE_COOLDOWN=1800
  AIRVPN_ROTATE_ENABLED=1
  mkdir -p "$STATE_DIR"
  printf '999\n' > "$RESTART_STAMP"

  current_epoch() { printf '1000\n'; }
  log() { :; }
  select_airvpn_candidate() {
    printf 'selection\n' >> "$events"
    printf 'Candidate\t198.51.100.20:1637\tGB\tLondon\t10000\t10\t20\n'
  }
  backup_config() { printf 'backup\n' >> "$events"; }
  set_config_endpoint() { printf 'set:%s\n' "$1" >> "$events"; }
  restart_iface() { printf 'down\nup\n' >> "$events"; }
  write_stamp() { printf 'stamp:%s\n' "$1" >> "$events"; }
  handshake_age() { printf '0\n'; }
  sleep() { :; }

  set +e
  rotate_airvpn "stale handshake"
  rc=$?
  set +e

  assert_eq 75 "$rc" "restart cooldown must have a distinct non-success status" || return 1
  assert_eq "" "$(<"$events")" "cooldown must prevent selection, backup, mutation, restart, and stamps" || return 1
  assert_eq "$original" "$(<"$WG_CONF")"$'\n' "cooldown must leave the WireGuard configuration byte-for-byte unchanged" || return 1
  assert_file_absent "$ROTATE_STAMP" "cooldown must not create the success stamp"
}

test_exact_endpoint_mismatch_rolls_back_and_verifies_qbittorrent() {
  local rc up_calls=0 qbit_checks=0
  new_recovery_fixture

  run_wg_quick_down() { printf 'down\n' >> "$TEST_EVENTS"; }
  run_wg_quick_up() {
    up_calls=$((up_calls + 1))
    printf 'up:%s\n' "$up_calls" >> "$TEST_EVENTS"
    if (( up_calls == 1 )); then
      RUNTIME_ENDPOINT='203.0.113.99:1637'
    else
      RUNTIME_ENDPOINT="$(configured_endpoint)"
    fi
  }
  ensure_qbittorrent_binding() {
    qbit_checks=$((qbit_checks + 1))
    printf 'qbit:%s\n' "$qbit_checks" >> "$TEST_EVENTS"
  }

  set +e
  rotate_airvpn 'stale handshake'
  rc=$?
  set +e

  assert_eq 1 "$rc" "an exact runtime endpoint mismatch must fail the rotation" || return 1
  assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" "rollback must restore the old endpoint" || return 1
  assert_eq '192.0.2.10:1637' "$RUNTIME_ENDPOINT" "rollback must verify the exact old runtime endpoint" || return 1
  assert_eq 2 "$up_calls" "rotation and rollback must each start the tunnel once" || return 1
  assert_eq 1 "$qbit_checks" "verified rollback must recheck qBittorrent" || return 1
  assert_file_absent "$ROTATE_STAMP" "a rolled-back rotation must not be stamped successful"
}

test_rotation_stamp_is_written_only_after_every_postcondition() {
  local rc events marker_line remove_line rotate_line qbit_line speed_line verify_line
  new_recovery_fixture

  write_stamp() {
    printf 'stamp:%s\n' "$1" >> "$TEST_EVENTS"
    printf '1000\n' > "$1"
  }
  run_wg_quick_down() {
    [[ -f "$ROTATION_PENDING" ]] && grep -qF '192.0.2.10:1637' "${WG_CONF}.bak-healthcheck" && printf 'marker-ready\n' >> "$TEST_EVENTS"
    printf 'down\n' >> "$TEST_EVENTS"
  }
  run_wg_quick_up() {
    printf 'up\n' >> "$TEST_EVENTS"
    RUNTIME_ENDPOINT="$(configured_endpoint)"
  }
  verify_tunnel() {
    printf 'verify:%s\n' "$1" >> "$TEST_EVENTS"
    [[ "$RUNTIME_ENDPOINT" == "$1" ]]
  }
  verify_post_rotation_speed() { printf 'speed\n' >> "$TEST_EVENTS"; }
  ensure_qbittorrent_binding() { printf 'qbit\n' >> "$TEST_EVENTS"; }
  remove_rotation_pending() {
    [[ -f "$ROTATE_STAMP" && -f "$STATUS_FILE" ]] || return 1
    printf 'remove-marker\n' >> "$TEST_EVENTS"
    rm -f "$ROTATION_PENDING"
  }

  rotate_airvpn 'stale handshake' 1
  rc=$?
  events="$(<"$TEST_EVENTS")"

  assert_eq 0 "$rc" "fully verified rotation must succeed" || return 1
  verify_line="$(grep -n '^verify:' "$TEST_EVENTS" | cut -d: -f1)"
  marker_line="$(grep -n '^marker-ready$' "$TEST_EVENTS" | cut -d: -f1)"
  speed_line="$(grep -n '^speed$' "$TEST_EVENTS" | cut -d: -f1)"
  qbit_line="$(grep -n '^qbit$' "$TEST_EVENTS" | cut -d: -f1)"
  rotate_line="$(grep -n "^stamp:${ROTATE_STAMP}$" "$TEST_EVENTS" | cut -d: -f1)"
  remove_line="$(grep -n '^remove-marker$' "$TEST_EVENTS" | cut -d: -f1)"
  [[ -n "$marker_line" && -n "$verify_line" && -n "$speed_line" && -n "$qbit_line" && -n "$rotate_line" && -n "$remove_line" ]] || fail "durable marker, restart postconditions, commit, and cleanup must occur" || return 1
  (( marker_line < verify_line && verify_line < speed_line && speed_line < qbit_line && qbit_line < rotate_line && rotate_line < remove_line )) || fail "transaction order must be marker, tunnel, speed, qBittorrent, commit, cleanup" || return 1
  assert_contains "stamp:${RESTART_STAMP}" "$events" "restart attempts must be stamped" || return 1
  assert_file_absent "$ROTATION_PENDING" "committed transaction must clear its marker"
}

test_two_peer_config_is_rejected_without_changes() {
  local before rc
  new_recovery_fixture
  printf '%s\n' \
    '[Interface]' \
    'PrivateKey = secret' \
    '[Peer]' \
    'PublicKey = one' \
    'Endpoint = 192.0.2.10:1637' \
    '[Peer]' \
    'PublicKey = two' > "$WG_CONF"
  before="$(<"$WG_CONF")"

  set +e
  set_config_endpoint '198.51.100.20:1637'
  rc=$?
  set +e

  assert_eq 1 "$rc" "multi-peer endpoint mutation must fail closed" || return 1
  assert_file_equals "$before" "$WG_CONF" "a rejected multi-peer file must remain byte-for-byte unchanged"
}

test_backup_path_is_stable_bounded_and_replaced_atomically() {
  local backup count rc
  new_recovery_fixture
  backup="${WG_CONF}.bak-healthcheck"

  backup_config
  rc=$?
  assert_eq 0 "$rc" "first known-good backup must succeed" || return 1
  printf '\n# immediately prior generation\n' >> "$WG_CONF"
  backup_config
  rc=$?

  assert_eq 0 "$rc" "replacing the known-good backup must succeed" || return 1
  count="$(find "$TEST_TMP" -maxdepth 1 -type f -name 'wg0.conf.bak-healthcheck*' | wc -l | tr -d ' ')"
  assert_eq 1 "$count" "backup retention must be bounded to one stable path" || return 1
  assert_contains '# immediately prior generation' "$(<"$backup")" "backup must contain the immediately prior full config"
}

test_first_slow_then_good_speed_sample_does_not_rotate() {
  local queue probes rotations
  new_recovery_fixture
  queue="$TEST_TMP/speeds"
  printf '1000000\n3000000\n' > "$queue"
  : > "$TEST_TMP/probes"
  : > "$TEST_TMP/rotations"
  measure_speed() {
    printf 'probe\n' >> "$TEST_TMP/probes"
    pop_speed_sample "$queue"
  }
  curl() {
    printf 'probe\n' >> "$TEST_TMP/probes"
    printf '200 %s\n' "$(pop_speed_sample "$queue")"
  }
  rotate_airvpn() { printf 'rotate\n' >> "$TEST_TMP/rotations"; }

  speed_check

  probes="$(wc -l < "$TEST_TMP/probes" | tr -d ' ')"
  rotations="$(wc -l < "$TEST_TMP/rotations" | tr -d ' ')"
  assert_eq 2 "$probes" "a first slow sample must be confirmed once" || return 1
  assert_eq 0 "$rotations" "a recovered confirmation sample must not rotate"
}

test_two_slow_speed_samples_rotate_exactly_once() {
  local queue probes rotations
  new_recovery_fixture
  queue="$TEST_TMP/speeds"
  printf '1000000\n2000000\n' > "$queue"
  : > "$TEST_TMP/probes"
  : > "$TEST_TMP/rotations"
  measure_speed() {
    printf 'probe\n' >> "$TEST_TMP/probes"
    pop_speed_sample "$queue"
  }
  curl() {
    printf 'probe\n' >> "$TEST_TMP/probes"
    printf '200 %s\n' "$(pop_speed_sample "$queue")"
  }
  rotate_airvpn() { printf 'rotate:%s:%s\n' "$1" "${2:-}" >> "$TEST_TMP/rotations"; }

  speed_check

  probes="$(wc -l < "$TEST_TMP/probes" | tr -d ' ')"
  rotations="$(wc -l < "$TEST_TMP/rotations" | tr -d ' ')"
  assert_eq 2 "$probes" "confirmed slowness must use exactly two pre-recovery probes" || return 1
  assert_eq 1 "$rotations" "two slow samples must trigger one rotation" || return 1
  assert_contains ':1' "$(<"$TEST_TMP/rotations")" "speed recovery must request a post-rotation speed verification"
}

test_qbittorrent_restart_rechecks_and_fails_when_socket_is_still_missing() {
  local rc checks=0 restarts=0
  new_recovery_fixture
  QBITTORRENT_LISTEN_IP='10.0.0.2'
  QBITTORRENT_LISTEN_PORT=13342
  QBITTORRENT_CONTAINER=qbittorrent
  docker() { :; }
  qbittorrent_binding_present() { checks=$((checks + 1)); return 1; }
  restart_qbittorrent_container() { restarts=$((restarts + 1)); return 0; }

  set +e
  ensure_qbittorrent_binding
  rc=$?
  set +e

  assert_eq 1 "$rc" "missing socket after Docker restart must fail recovery" || return 1
  assert_eq 1 "$restarts" "qBittorrent repair must restart the configured container once" || return 1
  assert_eq 2 "$checks" "qBittorrent binding must be checked before and after repair"
}

test_required_rule_is_a_mandatory_tunnel_postcondition() {
  local rc egress_checks=0
  new_recovery_fixture
  required_rule_present() { return 1; }
  verify_airvpn_egress() { egress_checks=$((egress_checks + 1)); return 0; }

  set +e
  verify_tunnel '192.0.2.10:1637'
  rc=$?
  set +e

  assert_eq 1 "$rc" "missing REQUIRED_RULE must fail tunnel verification" || return 1
  assert_eq 0 "$egress_checks" "verification should stop at the missing policy rule"
}

test_selector_failure_restarts_current_endpoint_but_returns_degraded() {
  local rc events
  new_recovery_fixture
  select_airvpn_candidate() { return 3; }
  restart_iface() {
    printf 'restart:%s:%s\n' "$1" "$2" >> "$TEST_EVENTS"
    return 0
  }
  backup_config() { printf 'unexpected-backup\n' >> "$TEST_EVENTS"; return 1; }
  set_config_endpoint() { printf 'unexpected-mutation\n' >> "$TEST_EVENTS"; return 1; }

  set +e
  rotate_airvpn 'stale handshake'
  rc=$?
  set +e
  events="$(<"$TEST_EVENTS")"

  assert_eq 2 "$rc" "selector failure must remain observable after protective restart" || return 1
  assert_contains 'restart:respect-cooldown:192.0.2.10:1637' "$events" "selector failure must restart and verify the current endpoint" || return 1
  [[ "$events" != *unexpected-* ]] || fail "selector failure must not back up or mutate config" || return 1
  assert_file_absent "$ROTATE_STAMP" "selector failure must not create a rotation success stamp"
}

test_selector_restart_failure_is_never_reported_as_success() {
  local rc
  new_recovery_fixture
  select_airvpn_candidate() { return 3; }
  restart_iface() { return 1; }

  set +e
  rotate_airvpn 'stale handshake'
  rc=$?
  set +e

  assert_eq 1 "$rc" "failed protective restart after selector failure must remain nonzero" || return 1
  assert_contains 'outcome=failed' "$(<"$STATUS_FILE")" "selector restart failure must write a failed status"
}

test_malformed_selector_contract_restarts_current_endpoint_degraded() {
  local rc events
  new_recovery_fixture
  select_airvpn_candidate() {
    printf 'Candidate\t198.51.100.20:1637\tGB\tLondon\t10000\t10\n'
  }
  restart_iface() {
    printf 'restart:%s:%s\n' "$1" "$2" >> "$TEST_EVENTS"
    return 0
  }

  set +e
  rotate_airvpn 'stale handshake'
  rc=$?
  set +e
  events="$(<"$TEST_EVENTS")"

  assert_eq 2 "$rc" "malformed selector output must be degraded" || return 1
  assert_contains 'restart:respect-cooldown:192.0.2.10:1637' "$events" "malformed selector output must trigger a protective current-endpoint restart"
}

test_rollback_up_failure_is_logged_and_nonzero() {
  local rc up_calls=0 status
  new_recovery_fixture
  run_wg_quick_down() { return 0; }
  run_wg_quick_up() {
    up_calls=$((up_calls + 1))
    return 1
  }

  set +e
  rotate_airvpn 'stale handshake'
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"

  assert_eq 1 "$rc" "rollback up failure must keep the transaction failed" || return 1
  assert_eq 2 "$up_calls" "rollback must attempt a forced up after candidate up failure" || return 1
  assert_contains 'outcome=failed' "$status" "rollback up failure must be observable" || return 1
  assert_contains 'reason=rollback_restart_failed' "$status" "rollback up failure must have an actionable reason" || return 1
  assert_file_absent "$ROTATE_STAMP" "rollback up failure must never create a success stamp"
}

test_failed_post_rotation_speed_probe_rolls_back_once() {
  local rc up_calls=0 probes
  new_recovery_fixture
  : > "$TEST_TMP/post-speed-probes"
  run_wg_quick_up() {
    up_calls=$((up_calls + 1))
    RUNTIME_ENDPOINT="$(configured_endpoint)"
  }
  ensure_qbittorrent_binding() { return 0; }
  measure_speed() {
    printf 'probe\n' >> "$TEST_TMP/post-speed-probes"
    printf '%s\n' "$((SPEED_MIN_BPS - 1))"
  }

  set +e
  rotate_airvpn confirmed_speed_failure 1
  rc=$?
  set +e
  probes="$(wc -l < "$TEST_TMP/post-speed-probes" | tr -d ' ')"

  assert_eq 1 "$rc" "slow post-rotation verification must fail and roll back" || return 1
  assert_eq 1 "$probes" "post-rotation speed must be measured exactly once without recursion" || return 1
  assert_eq 2 "$up_calls" "slow post-rotation verification must restore and restart the old endpoint" || return 1
  assert_eq 'Endpoint = 192.0.2.10:1637' "$(config_endpoint_line)" "speed rollback must restore the prior config" || return 1
  assert_file_absent "$ROTATE_STAMP" "failed post-rotation speed must not stamp success"
}

test_status_file_is_atomic_private_and_machine_readable() {
  local expected mode residue chmod_args
  new_recovery_fixture
  : > "$TEST_TMP/chmod-calls"
  chmod() {
    printf '%s\n' "$*" >> "$TEST_TMP/chmod-calls"
    command chmod "$@"
  }

  write_status healthy 'all checks passed'

  expected=$'outcome=healthy\nreason=all checks passed\ntimestamp=1000'
  assert_file_equals "$expected" "$STATUS_FILE" "status content must use stable outcome/reason fields" || return 1
  mode="$(stat -c '%a' "$STATUS_FILE")"
  if [[ "$(uname -s)" == MINGW* ]]; then
    chmod_args="$(head -n 1 "$TEST_TMP/chmod-calls" | cut -d' ' -f1-2)"
    assert_eq '600 --' "$chmod_args" "Git Bash must still request private mode on its noacl filesystem" || return 1
  else
    assert_eq 600 "$mode" "status file must be private" || return 1
  fi
  residue="$(find "$STATE_DIR" -maxdepth 1 -type f -name '.wg0.status.*' | wc -l | tr -d ' ')"
  assert_eq 0 "$residue" "atomic status writes must clean temporary files"
}

test_restart_attempt_stamp_precedes_fixed_down_and_up() {
  local rc events
  new_recovery_fixture
  run_wg_quick_down() {
    assert_file_equals 1000 "$RESTART_STAMP" "restart stamp must exist before down" || return 1
    printf 'down:%s\n' "$IFACE" >> "$TEST_EVENTS"
  }
  run_wg_quick_up() {
    assert_file_equals 1000 "$RESTART_STAMP" "restart stamp must exist before up" || return 1
    printf 'up:%s\n' "$IFACE" >> "$TEST_EVENTS"
    RUNTIME_ENDPOINT="$(configured_endpoint)"
  }
  ensure_qbittorrent_binding() { printf 'qbit\n' >> "$TEST_EVENTS"; }

  set +e
  restart_iface respect-cooldown '192.0.2.10:1637' false
  rc=$?
  set +e
  events="$(<"$TEST_EVENTS")"

  assert_eq 0 "$rc" "fixed restart with verified postconditions must succeed" || return 1
  assert_contains 'down:wg0' "$events" "restart must use fixed wg-quick down interface argument" || return 1
  assert_contains 'up:wg0' "$events" "restart must use fixed wg-quick up interface argument" || return 1
  assert_contains 'qbit' "$events" "restart must verify qBittorrent after tunnel recovery"
}

test_legacy_authenticated_telemetry_remains_retired() {
  local token
  for token in AIRVPN_API_ENV AIRVPN_USERINFO_URL airvpn_session_log Api-Key userinfo; do
    if grep -Fq -- "$token" "$SCRIPT"; then
      fail "retired authenticated telemetry token remains in production: $token"
      return 1
    fi
  done
  if grep -Eq 'import[[:space:]]+json|json[.]loads' "$SCRIPT"; then
    fail "the Bash owner must not embed an AirVPN JSON parser"
  fi
}

test_strict_ip_and_peer_section_validation() {
  local before rc
  new_recovery_fixture
  if [[ "$(uname -s)" == MINGW* ]]; then
    python3() { command python "$@"; }
  fi

  if validate_interface_name '--help'; then
    fail "an interface name passed in option position must not start with '-'"
    return 1
  fi
  validate_endpoint '[2001:db8::1]:51820' || fail "valid bracketed IPv6 endpoint must pass" || return 1
  if validate_endpoint '[1::2::3]:51820'; then
    fail "malformed multiple-compression IPv6 endpoint must fail"
    return 1
  fi

  printf '%s\n' \
    '[Interface]' \
    'PrivateKey = secret' \
    'Endpoint = 192.0.2.10:1637' \
    '[Peer]' \
    'PublicKey = peer' > "$WG_CONF"
  before="$(<"$WG_CONF")"
  set +e
  set_config_endpoint '198.51.100.20:1637'
  rc=$?
  set +e
  assert_eq 1 "$rc" "Endpoint outside the sole Peer section must be rejected" || return 1
  assert_file_equals "$before" "$WG_CONF" "section-invalid config must remain unchanged" || return 1

  QBITTORRENT_LISTEN_IP=deadbeef
  QBITTORRENT_LISTEN_PORT=13342
  AIRVPN_API_HELPER="$ROOT/libexec/airvpn-api"
  set +e
  validate_settings
  rc=$?
  set +e
  assert_eq 1 "$rc" "qBittorrent listen IP must be a real numeric IP address"
}

test_handshake_age_parses_wireguard_columns() (
  source "$SCRIPT"
  IFACE=wg0
  WG_HANDSHAKES=$'peer-one\t940'

  current_epoch() { printf '1000\n'; }
  wg() {
    [[ "$*" == 'show wg0 latest-handshakes' ]] || return 1
    printf '%s\n' "$WG_HANDSHAKES"
  }

  assert_eq 60 "$(handshake_age)" 'single WireGuard handshake row was not parsed' || return 1

  WG_HANDSHAKES=$'peer-one\t940\npeer-two\t950'
  if handshake_age >/dev/null 2>&1; then
    fail 'multiple WireGuard handshake rows must be rejected'
    return 1
  fi
)

test_three_state_cooldown_and_invalid_restart_state() {
  local rc status
  new_recovery_fixture
  COOLDOWN=300
  printf '999\n' > "$RESTART_STAMP"
  set +e
  cooldown_allows "$RESTART_STAMP" "$COOLDOWN"
  rc=$?
  set +e
  assert_eq 75 "$rc" "valid active cooldown must return 75" || return 1

  printf 'not-an-epoch\n' > "$RESTART_STAMP"
  : > "$TEST_EVENTS"
  : > "$TEST_TMP/commands"
  run_wg_quick_down() { printf 'down\n' >> "$TEST_TMP/commands"; }
  run_wg_quick_up() { printf 'up\n' >> "$TEST_TMP/commands"; }
  set +e
  restart_iface respect-cooldown '192.0.2.10:1637' false
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"
  assert_eq 1 "$rc" "malformed restart stamp must be a hard failure" || return 1
  assert_contains 'reason=invalid_restart_stamp' "$status" "invalid restart state must be actionable" || return 1
  assert_eq "" "$(<"$TEST_TMP/commands")" "invalid state must prevent restart commands"
}

test_rotation_cooldown_distinguishes_suppression_from_corruption() {
  local rc status
  new_recovery_fixture
  AIRVPN_ROTATE_COOLDOWN=300
  printf '999\n' > "$ROTATE_STAMP"
  set +e
  rotate_airvpn stale_handshake
  rc=$?
  set +e
  assert_eq 75 "$rc" "valid active rotation cooldown must be suppressed" || return 1
  assert_contains 'reason=rotation_cooldown' "$(<"$STATUS_FILE")" "rotation suppression must be explicit" || return 1

  printf '1001\n' > "$ROTATE_STAMP"
  rm -f "$STATUS_FILE"
  set +e
  rotate_airvpn stale_handshake
  rc=$?
  set +e
  status="$(file_text "$STATUS_FILE")"
  assert_eq 1 "$rc" "future rotation stamp must fail rather than suppress" || return 1
  assert_contains 'reason=invalid_rotation_stamp' "$status" "corrupt rotation state must be actionable"
}

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

seed_pending_rotation() {
  backup_config || return 1
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"
  chmod 600 "$ROTATION_PENDING"
  set_config_endpoint '198.51.100.20:1637' || return 1
  RUNTIME_ENDPOINT='198.51.100.20:1637'
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

  for case_name in secure symlink wrong_owner wrong_mode parent_owner parent_writable; do
    path_is_regular() { return 0; }
    path_is_directory() { return 0; }
    path_is_symlink() { [[ "$case_name" == symlink && "$1" == "$AIRVPN_API_HELPER" ]]; }
    owner_mode() {
      if [[ "$1" == "$AIRVPN_API_HELPER" ]]; then
        case "$case_name" in
          wrong_owner) printf '1000:755\n' ;;
          wrong_mode) printf '0:775\n' ;;
          *) printf '0:755\n' ;;
        esac
      else
        case "$case_name" in
          parent_owner) printf '1000:755\n' ;;
          parent_writable) printf '0:777\n' ;;
          *) printf '0:755\n' ;;
        esac
      fi
    }
    set +e
    validate_secure_executable "$AIRVPN_API_HELPER"
    rc=$?
    set +e
    if [[ "$case_name" == secure ]]; then
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

test_admin_commands_refuse_pending_state_without_reconciliation_effects() {
  local command marker_kind rc
  new_main_fixture
  IFACE=wg0
  derive_fixed_runtime_paths
  : > "$TEST_TMP/admin-events"
  load_managed_module() { MANAGED_MODULE_LOADED=1; }
  managed_reconcile_pending() { printf 'reconcile\n' >> "$TEST_TMP/admin-events"; }
  managed_dispatch_command() { :; }

  for marker_kind in v1 v2 safety; do
    rm -f -- "$ROTATION_PENDING" "$MANAGED_SAFETY"
    case "$marker_kind" in
      v1) printf '192.0.2.10:1637\n' > "$ROTATION_PENDING" ;;
      v2) printf 'version=2\n' > "$ROTATION_PENDING" ;;
      safety) printf 'version=1\n' > "$MANAGED_SAFETY" ;;
    esac
    for command in provision adopt rotate restore-static reset-api-state; do
      COMMAND="$command"
      AIRVPN_PROFILE_SOURCE=api
      DISPATCH_READY=0
      : > "$TEST_TMP/admin-events"
      set +e; prepare_command_dispatch >/dev/null 2>&1; rc=$?; set +e
      assert_eq 75 "$rc" "$command must refuse unresolved $marker_kind recovery state" || return 1
      assert_eq '' "$(<"$TEST_TMP/admin-events")" \
        "$command refusal must not reconcile Docker or network state" || return 1
      assert_eq 0 "$DISPATCH_READY" "$command must not reach managed dispatch" || return 1
    done

    COMMAND=status
    DISPATCH_READY=0
    : > "$TEST_TMP/admin-events"
    prepare_command_dispatch || return 1
    assert_eq '' "$(<"$TEST_TMP/admin-events")" \
      "status must observe $marker_kind without reconciliation" || return 1
    assert_eq 1 "$DISPATCH_READY" "status must reach its observational renderer"
  done
}

test_status_main_path_is_observational_and_creates_no_runtime_files() {
  local output rc
  new_main_fixture
  rm -rf -- "$STATE_DIR"
  : > "$TEST_TMP/status-events"
  prepare_state_dir() { printf 'prepare-state\n' >> "$TEST_TMP/status-events"; return 1; }
  load_managed_module() { MANAGED_MODULE_LOADED=1; }
  managed_dispatch_command() {
    printf 'mode=static\ntimer=unknown\ntunnel=down\nlast_check=0\nlast_rotation=0\ncredential_present=false\npending=none\nqbittorrent=unmanaged\n'
  }
  set +e; output="$(main status wg0)"; rc=$?; set +e
  assert_eq 0 "$rc" "status must work without a pre-existing runtime state directory" || return 1
  assert_contains 'mode=static' "$output" "status output must reach the observational owner" || return 1
  assert_eq '' "$(<"$TEST_TMP/status-events")" "status must not prepare or chmod runtime state" || return 1
  [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] ||
    fail "status must not create the runtime state directory" || return 1
  [[ ! -e "$LOCK" && ! -L "$LOCK" ]] || fail "status must not create the interface lock"
  [[ ! -e "$SETUP_GUARD" && ! -L "$SETUP_GUARD" ]] || fail "status must not create the setup guard"
}

test_interface_lock_open_is_nofollow_private_and_never_truncates_symlink_target() {
  local rc lock_fd='' victim
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  STATE_DIR="$TEST_TMP/state"
  IFACE=wg0
  LOCK="$STATE_DIR/wg0.lock"
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  victim="$TEST_TMP/victim"
  printf 'do-not-truncate\n' > "$victim"
  ln -s -- "$victim" "$LOCK"
  set +e; open_interface_lock lock_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "interface lock symlink must be rejected" || return 1
  assert_eq do-not-truncate "$(<"$victim")" "lock validation must never follow or truncate a symlink" || return 1
  rm -f -- "$LOCK"
  owner_mode() { printf '0:600\n'; }
  interface_lock_fd_identity() { stat -Lc '%d:%i' -- "$LOCK"; }
  open_interface_lock lock_fd || return 1
  [[ "$lock_fd" =~ ^[0-9]+$ ]] || fail "interface lock owner must return a numeric descriptor" || return 1
  if [[ "$(uname -s)" == Linux ]]; then
    assert_eq 600 "$(stat -c '%a' -- "$LOCK")" "created interface lock must be private" || return 1
  fi
  exec {lock_fd}>&-
}

test_core_dump_suppression_precedes_context_and_closes_credential_on_failure() {
  local rc leaked
  new_main_fixture
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  exec 9<"$TEST_TMP/credential"
  : > "$TEST_TMP/core-events"
  disable_core_dumps() { printf 'core\n' >> "$TEST_TMP/core-events"; return 1; }
  load_command_context() { printf 'context\n' >> "$TEST_TMP/core-events"; return 1; }
  managed_dispatch_command() { printf 'provider\n' >> "$TEST_TMP/core-events"; }
  set +e; main provision wg0 --dry-run --credential-fd 9 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "core-limit failure must fail before credential use" || return 1
  assert_eq core "$(<"$TEST_TMP/core-events")" \
    "core suppression must precede context, provider, and every child" || return 1
  set +e; IFS= read -r -u 9 leaked 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "core-limit failure must close the supplied credential descriptor" || return 1

  : > "$TEST_TMP/core-events"
  disable_core_dumps() { printf 'core\n' >> "$TEST_TMP/core-events"; }
  load_command_context() { printf 'context\n' >> "$TEST_TMP/core-events"; return 1; }
  set +e; main wg0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "ordering fixture must stop in context" || return 1
  assert_eq $'core\ncontext' "$(<"$TEST_TMP/core-events")" \
    "core suppression must be established before runtime context"
}

test_reset_context_allows_genuinely_missing_profile_but_not_symlink() {
  local rc
  new_main_fixture
  COMMAND=reset-api-state
  IFACE=wg0
  rm -f -- "$WG_CONF"
  load_command_context || fail "state reset must remain usable when the profile is absent" || return 1
  [[ "$(uname -s)" == MINGW* ]] && return 0
  new_main_fixture
  COMMAND=reset-api-state
  IFACE=wg0
  rm -f -- "$WG_CONF"
  command mkdir -p -- "${WG_CONF%/*}" || return 1
  printf 'target\n' > "$TEST_TMP/missing-profile"
  command ln -s -- "$TEST_TMP/missing-profile" "$WG_CONF" || return 1
  validate_secure_file() {
    [[ "$1" != "$WG_CONF" || ! -L "$WG_CONF" ]]
  }
  set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "state reset must still refuse a profile symlink"
}

test_status_context_validates_existing_state_directory_without_repair() {
  local rc before_mode
  new_main_fixture
  COMMAND=status
  IFACE=wg0
  derive_fixed_runtime_paths
  chmod 755 -- "$STATE_DIR"
  before_mode="$(stat -c '%a' -- "$STATE_DIR")"
  set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "status must refuse an existing insecure runtime state directory" || return 1
  assert_eq "$before_mode" "$(stat -c '%a' -- "$STATE_DIR")" \
    "observational status must never chmod or repair state"
}

test_context_refuses_untrusted_config_parent_before_file_or_parse() {
  local case_name rc real_parent
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  real_parent="$TEST_TMP/healthcheck.d"
  mkdir -p -- "$real_parent"
  chmod 700 -- "$real_parent"
  CFG="$real_parent/wg0.conf"
  WG_CONF="$TEST_TMP/wg0.conf"
  STATE_DIR="$TEST_TMP/state"
  printf 'AIRVPN_PROFILE_SOURCE=static\n' > "$CFG"
  printf '%s\n' '[Interface]' '[Peer]' 'Endpoint = 192.0.2.10:1637' > "$WG_CONF"
  chmod 600 -- "$CFG" "$WG_CONF"
  derive_fixed_runtime_paths() { :; }
  sanitize_process_environment() { :; }
  is_root() { return 0; }
  log() { :; }
  validate_secure_file() { printf 'file-validation\n' >> "$TEST_TMP/context-events"; }
  parse_healthcheck_config() { printf 'parse\n' >> "$TEST_TMP/context-events"; }
  validate_settings() { printf 'settings\n' >> "$TEST_TMP/context-events"; }
  prepare_state_dir() { printf 'state\n' >> "$TEST_TMP/context-events"; }

  for case_name in mode_0755 mode_0770 wrong_owner symlink; do
    CFG="$real_parent/wg0.conf"
    CONFIG_PARENT_CASE="$case_name"
    if [[ "$case_name" == symlink ]]; then
      ln -s -- "$real_parent" "$TEST_TMP/linked-healthcheck.d"
      CFG="$TEST_TMP/linked-healthcheck.d/wg0.conf"
    fi
    owner_mode() {
      if [[ "$1" == "${CFG%/*}" ]]; then
        case "$CONFIG_PARENT_CASE" in
          mode_0755) printf '0:755\n' ;;
          mode_0770) printf '0:770\n' ;;
          wrong_owner) printf '65534:700\n' ;;
          *) printf '0:700\n' ;;
        esac
      else
        printf '0:600\n'
      fi
    }
    : > "$TEST_TMP/context-events"
    COMMAND=check
    set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name config parent must fail closed" || return 1
    assert_eq '' "$(<"$TEST_TMP/context-events")" \
      "$case_name config parent refusal must precede file validation and parsing" || return 1
    rm -f -- "$TEST_TMP/linked-healthcheck.d"
  done
}

tests=(
  test_version_output_is_fixed_and_public
  test_sourceable_without_executing_or_enabling_errexit
  test_runtime_cli_preserves_legacy_version_and_rejects_unknown_forms
  test_setup_lease_cli_is_explicit_scoped_and_fd_distinct
  test_mutating_cli_requires_exactly_one_mode_and_scopes_options
  test_settings_descriptor_is_exact_stable_private_and_canonical
  test_main_captures_settings_before_context_and_overlays_only_memory
  test_main_sanitizes_before_settings_metadata_children
  test_second_sanitizer_failure_closes_restored_credential_fd
  test_runtime_defaults_and_fixed_paths_ignore_environment
  test_process_environment_is_sanitized_for_child_commands
  test_hostile_internal_paths_cannot_redirect_main_or_truncate_lock_target
  test_main_validates_both_fixed_files_before_parsing_config
  test_config_parser_accepts_template_and_whole_quoted_values
  test_config_parser_rejects_internal_unknown_duplicate_and_malformed_keys
  test_config_parser_rejects_ambiguous_syntax_without_execution_or_partial_apply
  test_config_parser_rejects_oversized_file_and_line
  test_api_settings_require_device_allowed_port_and_normalize_countries
  test_managed_qb_container_name_rejects_exact_immutable_id_without_static_regression
  test_restart_cooldown_prevents_every_rotation_side_effect
  test_exact_endpoint_mismatch_rolls_back_and_verifies_qbittorrent
  test_rotation_stamp_is_written_only_after_every_postcondition
  test_two_peer_config_is_rejected_without_changes
  test_backup_path_is_stable_bounded_and_replaced_atomically
  test_first_slow_then_good_speed_sample_does_not_rotate
  test_two_slow_speed_samples_rotate_exactly_once
  test_qbittorrent_restart_rechecks_and_fails_when_socket_is_still_missing
  test_required_rule_is_a_mandatory_tunnel_postcondition
  test_selector_failure_restarts_current_endpoint_but_returns_degraded
  test_selector_restart_failure_is_never_reported_as_success
  test_malformed_selector_contract_restarts_current_endpoint_degraded
  test_rollback_up_failure_is_logged_and_nonzero
  test_failed_post_rotation_speed_probe_rolls_back_once
  test_status_file_is_atomic_private_and_machine_readable
  test_restart_attempt_stamp_precedes_fixed_down_and_up
  test_legacy_authenticated_telemetry_remains_retired
  test_strict_ip_and_peer_section_validation
  test_handshake_age_parses_wireguard_columns
  test_three_state_cooldown_and_invalid_restart_state
  test_rotation_cooldown_distinguishes_suppression_from_corruption
  test_rotation_disabled_speed_restart_and_failure_status
  test_fixed_command_wrappers_pass_exact_argv
  test_main_uses_root_seam_and_validates_both_files
  test_setup_guard_precedes_context_and_stale_context_is_never_loaded_on_contention
  test_main_keeps_credential_private_during_pre_guard_context
  test_setup_guard_is_private_nofollow_and_validates_exclusive_inherited_lease
  test_setup_lease_validation_helpers_inherit_no_other_private_descriptors
  test_main_lock_contention_is_nonblocking_and_side_effect_free
  test_explicit_lock_contention_is_busy_and_closes_credential_descriptors
  test_load_command_context_allows_profile_independent_commands_to_lack_profile
  test_static_no_marker_never_touches_credential_provider_or_managed_code
  test_static_selector_validates_provider_only_when_selection_is_needed
  test_pending_marker_classification_loads_only_the_required_owner
  test_v1_static_dispatch_reconciles_without_loading_managed_runtime
  test_main_propagates_route_rule_and_qbittorrent_failures
  test_main_rejects_invalid_speed_stamp
  test_restart_rejects_invalid_speed_mode_before_commands
  test_each_rotation_postcondition_failure_rolls_back
  test_pending_rotation_is_reconciled_before_health_checks
  test_failed_pending_reconciliation_retains_marker
  test_rollback_rotate_stamp_removal_failure_retains_pending_state
  test_reconciliation_rotate_stamp_removal_failure_retains_pending_state
  test_pending_marker_prevents_backup_overwrite
  test_main_reconciles_pending_state_before_normal_health
  test_interruption_handler_retains_marker_and_installs_traps
  test_interruption_handler_is_child_free_with_untracked_private_descriptors
  test_durability_barriers_cover_transaction_and_cleanup_order
  test_backup_barrier_failure_prevents_unmarked_mutation
  test_marker_barrier_failure_retains_recovery_state
  test_config_barrier_failure_performs_verified_rollback
  test_marker_cleanup_barrier_failure_recreates_recovery_marker
  test_secure_helper_and_parent_validation
  test_static_settings_do_not_touch_provider_helper
  test_route_and_rule_checks_consume_large_producer_output
  test_canonical_endpoint_equivalence_is_used_everywhere
  test_qbittorrent_binding_requires_tcp_udp_process_and_container_pid
  test_https_curl_policy_and_egress_cleanup
  test_speed_failure_reason_is_truthful
  test_selector_failures_use_one_protective_restart_owner
  test_timer_health_speed_and_qb_failures_dispatch_managed_rotation_in_api_mode
  test_timer_failures_keep_static_endpoint_dispatch_in_static_mode
  test_api_rotation_disabled_is_restart_only_and_managed_failure_never_falls_through
  test_admin_commands_refuse_pending_state_without_reconciliation_effects
  test_status_main_path_is_observational_and_creates_no_runtime_files
  test_interface_lock_open_is_nofollow_private_and_never_truncates_symlink_target
  test_core_dump_suppression_precedes_context_and_closes_credential_on_failure
  test_reset_context_allows_genuinely_missing_profile_but_not_symlink
  test_status_context_validates_existing_state_directory_without_repair
  test_context_refuses_untrusted_config_parent_before_file_or_parse
)

if [[ -n "${WG_HEALTHCHECK_TEST_ONLY:-}" ]]; then
  read -r -a tests <<< "$WG_HEALTHCHECK_TEST_ONLY"
fi

failures=0
for test_name in "${tests[@]}"; do
  if ("$test_name"); then
    printf 'ok - %s\n' "$test_name"
  else
    printf 'not ok - %s\n' "$test_name"
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '%d test(s) passed\n' "${#tests[@]}"
