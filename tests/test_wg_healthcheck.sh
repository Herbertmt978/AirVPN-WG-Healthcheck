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
    ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
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

  parse_cli --version || return 1
  assert_eq version "$COMMAND" "--version must remain a standalone command" || return 1
  usage_text="$(usage 2>&1)"
  assert_contains 'wg-healthcheck provision <iface> --dry-run|--apply [--credential-fd N]' "$usage_text" \
    "usage must document the provision descriptor override" || return 1
  assert_contains 'wg-healthcheck adopt <iface> --dry-run|--apply [--credential-fd N]' "$usage_text" \
    "usage must document the adopt descriptor override" || return 1

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

  parse_cli status wg0 || return 1
  assert_eq 0 "$STATUS_JSON" "status defaults to text" || return 1
  parse_cli status wg0 --json || return 1
  assert_eq 1 "$STATUS_JSON" "status alone may request JSON" || return 1
  set +e; parse_cli status wg0 --dry-run >/dev/null 2>&1; rc=$?; set +e
  assert_eq 64 "$rc" "status must reject mutation flags"
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
  for key in CFG WG_CONF STATE_DIR LOCK RESTART_STAMP ROTATE_STAMP SPEED_STAMP STATUS_FILE \
      ROTATION_PENDING AIRVPN_API_HELPER MANAGED_MODULE AIRVPN_API_KEY_FILE \
      AIRVPN_API_STATE_FILE AIRVPN_API_LOCK MANAGED_CANDIDATE PRE_MANAGED_CONF PATH; do
    printf -v "$key" '%s' "/tmp/hostile-$key"
  done
  derive_fixed_runtime_paths
  assert_eq '/etc/wireguard/healthcheck.d/wg0.conf' "$CFG" "CFG must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf' "$WG_CONF" "WG_CONF must be fixed" || return 1
  assert_eq '/run/wg-healthcheck' "$STATE_DIR" "STATE_DIR must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.lock' "$LOCK" "LOCK must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_restart' "$RESTART_STAMP" "restart stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_rotate' "$ROTATE_STAMP" "rotation stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_speedcheck' "$SPEED_STAMP" "speed stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.status' "$STATUS_FILE" "status path must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.pending-healthcheck' "$ROTATION_PENDING" "pending marker must be fixed" || return 1
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
    LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME
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
  assert_eq "$expected_cfg" "${calls%%$'\n'*}" "the derived CFG must be the first file validated" || return 1
  assert_contains "$expected_wg" "$calls" "the derived WG_CONF must be validated"
}

test_main_validates_both_fixed_files_before_parsing_config() {
  local rc events expected
  new_main_fixture
  : > "$TEST_TMP/order"
  validate_secure_file() { printf 'validate:%s:%s:%s\n' "$1" "$2" "$3" >> "$TEST_TMP/order"; }
  parse_healthcheck_config() { printf 'parse:%s\n' "$1" >> "$TEST_TMP/order"; }
  validate_settings() { printf 'settings\n' >> "$TEST_TMP/order"; }
  prepare_state_dir() { return 1; }

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
  for command in provision adopt rotate restore-static reset-api-state status; do
    (
      local credential_fd='' leaked='' output rc read_rc
      local -a argv
      new_main_fixture
      : > "$TEST_TMP/events"
      flock() { return 1; }
      load_managed_module() { printf 'unexpected-dispatch\n' >> "$TEST_TMP/events"; return 1; }
      write_status() { printf 'unexpected-status\n' >> "$TEST_TMP/events"; return 1; }
      if [[ "$command" == status ]]; then
        argv=(status wg0)
      else
        argv=("$command" wg0 --dry-run)
      fi
      if [[ "$command" == provision || "$command" == adopt ]]; then
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

test_load_command_context_allows_only_provision_to_lack_profile() {
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
  printf 'AIRVPN_PROFILE_SOURCE=static\n' > "$CFG"
  derive_fixed_runtime_paths() { :; }
  sanitize_process_environment() { :; }
  is_root() { return 0; }
  validate_secure_file() { [[ -f "$1" && ! -L "$1" ]]; }
  prepare_state_dir() { mkdir -p "$STATE_DIR"; }
  flock() { return 0; }

  COMMAND=provision
  load_command_context || fail "provision alone must allow a genuinely missing profile" || return 1
  [[ -z "${LOCK_FD:-}" ]] || exec {LOCK_FD}>&-

  for command in check adopt rotate restore-static reset-api-state status; do
    COMMAND="$command"
    set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$command must fail closed when the profile is missing" || return 1
  done

  printf '%s\n' '[Interface]' '[Peer]' 'Endpoint = 192.0.2.1:1637' > "$WG_CONF"
  COMMAND=provision
  load_command_context || fail "provision context must securely validate an existing path before Task 8 refuses overwrite" || return 1
  [[ -z "${LOCK_FD:-}" ]] || exec {LOCK_FD}>&-
}

test_static_no_marker_never_touches_credential_provider_or_managed_code() {
  local rc calls
  new_main_fixture
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
  rm -f -- "$ROTATION_PENDING"
  dispatch_command || return 1
  assert_file_equals legacy "$TEST_TMP/events" "static/no-marker must remain pure legacy code" || return 1

  : > "$TEST_TMP/events"
  printf '%s\n' 'version=2' 'transaction=managed-profile' > "$ROTATION_PENDING"
  dispatch_command || return 1
  events="$(<"$TEST_TMP/events")"
  assert_eq $'load-managed\nmanaged-v2' "$events" \
    "static/v2 must load managed code solely for reconciliation" || return 1

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
  set +e; dispatch_command >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "v1 classification must reject more than one newline-terminated record" || return 1
  assert_file_equals '' "$TEST_TMP/events" "invalid pending data must not reach either reconciliation owner" || return 1

  : > "$TEST_TMP/events"
  rm -f -- "$ROTATION_PENDING"
  dispatch_command || return 1
  events="$(<"$TEST_TMP/events")"
  assert_eq $'load-managed\nmanaged-dispatch:check' "$events" \
    "API/no-marker must dispatch through the securely loaded managed owner"
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
  local status traps
  new_recovery_fixture
  declare -F record_rotation_interruption >/dev/null || fail "interruption recorder is missing" || return 1
  declare -F install_signal_handlers >/dev/null || fail "signal handler installer is missing" || return 1
  printf '192.0.2.10:1637\n' > "$ROTATION_PENDING"

  record_rotation_interruption TERM
  install_signal_handlers
  status="$(file_text "$STATUS_FILE")"
  traps="$(trap -p TERM HUP INT)"

  [[ -f "$ROTATION_PENDING" ]] || fail "interruption must retain the transaction marker" || return 1
  assert_contains 'reason=rotation_interrupted_TERM' "$status" "interruption status must be explicit" || return 1
  assert_contains record_rotation_interruption "$traps" "TERM/HUP/INT traps must use the interruption recorder"
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

tests=(
  test_version_output_is_fixed_and_public
  test_sourceable_without_executing_or_enabling_errexit
  test_runtime_cli_preserves_legacy_version_and_rejects_unknown_forms
  test_mutating_cli_requires_exactly_one_mode_and_scopes_options
  test_runtime_defaults_and_fixed_paths_ignore_environment
  test_process_environment_is_sanitized_for_child_commands
  test_hostile_internal_paths_cannot_redirect_main_or_truncate_lock_target
  test_main_validates_both_fixed_files_before_parsing_config
  test_config_parser_accepts_template_and_whole_quoted_values
  test_config_parser_rejects_internal_unknown_duplicate_and_malformed_keys
  test_config_parser_rejects_ambiguous_syntax_without_execution_or_partial_apply
  test_config_parser_rejects_oversized_file_and_line
  test_api_settings_require_device_allowed_port_and_normalize_countries
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
  test_main_lock_contention_is_nonblocking_and_side_effect_free
  test_explicit_lock_contention_is_busy_and_closes_credential_descriptors
  test_load_command_context_allows_only_provision_to_lack_profile
  test_static_no_marker_never_touches_credential_provider_or_managed_code
  test_static_selector_validates_provider_only_when_selection_is_needed
  test_pending_marker_classification_loads_only_the_required_owner
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
