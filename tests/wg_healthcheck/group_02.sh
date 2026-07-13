#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

# wg-healthcheck test group 02; function bodies preserved from legacy suite.

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
