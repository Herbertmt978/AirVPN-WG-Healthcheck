#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

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
  interface_lock_create_noclobber() {
    probe_fd_closed_in_child lock-create || return 1
    ( set -o noclobber; umask 077; : > "$LOCK" ) 2>/dev/null
  }
  interface_lock_chmod_private() {
    probe_fd_closed_in_child lock-chmod || return 1
    chmod 600 -- "$LOCK"
  }
  owner_mode() {
    local mode
    probe_fd_closed_in_child lock-metadata || return 1
    mode="$(stat -c '%a' -- "$1")" || return 1
    printf '0:%s\n' "$mode"
  }
  setup_guard_metadata_child() {
    probe_fd_closed_in_child guard-metadata
  }
  interface_lock_fd_identity() {
    probe_fd_closed_in_child lock-fd || return 1
    stat -Lc '%d:%i' -- "/proc/$BASHPID/fd/$1"
  }
  interface_lock_path_identity() {
    probe_fd_closed_in_child lock-path || return 1
    stat -Lc '%d:%i' -- "$LOCK"
  }
  flock() { probe_fd_closed_in_child lock; }
  log() { probe_fd_closed_in_child log; }
  classify_pending_marker() {
    probe_fd_closed_in_child marker || return 1
    log preflight || return 1
    PENDING_KIND=none
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
  for stage in context environment root-check stat config settings state-dir guard-metadata \
      lock-create lock-chmod lock-metadata lock-fd lock-path lock marker log module; do
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
  managed_journal_prepare 0 || return 1
  managed_journal_load || return 1
  assert_eq '192.0.2.10:1637' "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" \
    "different profile digests may retain the same canonical endpoint" || return 1
  rm -f -- "$ROTATION_PENDING"

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
      bad_phase uppercase_digest short_digest equal_digest noncanonical_old bad_qb \
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
