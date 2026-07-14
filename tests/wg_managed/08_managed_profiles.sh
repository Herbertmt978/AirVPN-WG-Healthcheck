#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_generator_callback_handles_reserved_fd_collisions_and_clean_child_environment() {
  local supplied_fd rc args manifest
  setup_managed_journal_fixture || return 1
  AIRVPN_API_HELPER="$TEST_TMP/fake-airvpn-api"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -u' \
    '[[ -z "${AIRVPN_API_KEY+x}" ]] || exit 91' \
    'IFS= read -r key <&3 || exit 92' \
    '[[ "$key" == descriptor-only-test-record ]] || exit 93' \
    'printf "%s\n" "$@" > "${0}.args"' \
    'cat >&4 <<"PROFILE"' \
    '[Interface]' \
    'Address = 192.0.2.2/32' \
    'PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' \
    '[Peer]' \
    'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' \
    'PresharedKey = fixture-new-preshared-value' \
    'Endpoint = 198.51.100.20:1637' \
    'AllowedIPs = 0.0.0.0/0' \
    'PROFILE' \
    'printf "generated\\tCandidate\\t198.51.100.20:1637\\tpinned=1\\n"' > "$AIRVPN_API_HELPER"
  chmod 755 -- "$AIRVPN_API_HELPER"
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  MANAGED_PROFILE_SERVER=Candidate
  MANAGED_PROFILE_ENDPOINT=198.51.100.20:1637
  MANAGED_PROFILE_OPERATION=adopt
  MANAGED_PROFILE_PIN=1
  MANAGED_PROFILE_MANIFEST=''
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_TIMEOUT=20
  export AIRVPN_API_KEY=must-not-reach-child
  validate_secure_executable() { return 0; }
  managed_secure_sha256_stream() {
    local descriptor target
    for descriptor in "/proc/$BASHPID/fd/"*; do
      target="$(readlink -- "$descriptor")" || continue
      [[ "$target" != "$TEST_TMP/credential" && "$target" != "$MANAGED_CANDIDATE" ]] ||
        return 97
    done
    printf 'hasher-closed\n' >> "$TEST_TMP/fd-events"
    command sha256sum
  }
  managed_select_airvpn_candidate() {
    printf -v "$1" '%s' $'Candidate\t198.51.100.20:1637\tGB\tLondon\t10000\t10\t20'
  }
  eval "$(declare -f managed_validate_generator_paths_closed | sed '1s/managed_validate_generator_paths_closed/original_validate_generator_paths_closed/')"
  eval "$(declare -f managed_validate_open_candidate_closed | sed '1s/managed_validate_open_candidate_closed/original_validate_open_candidate_closed/')"
  eval "$(declare -f managed_finalize_generated_candidate_closed | sed '1s/managed_finalize_generated_candidate_closed/original_finalize_generated_candidate_closed/')"
  managed_validate_generator_paths_closed() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'paths-closed\n' >> "$TEST_TMP/fd-events"
    original_validate_generator_paths_closed
  }
  managed_validate_open_candidate_closed() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'inode-closed\n' >> "$TEST_TMP/fd-events"
    original_validate_open_candidate_closed "$@"
  }
  managed_finalize_generated_candidate_closed() {
    [[ ! -e "/proc/$BASHPID/fd/$PROBE_FD" ]] || return 1
    printf 'finalize-closed\n' >> "$TEST_TMP/fd-events"
    original_finalize_generated_candidate_closed
  }

  for supplied_fd in 3 4 5; do
    rm -f -- "$MANAGED_CANDIDATE" "${AIRVPN_API_HELPER}.args"
    : > "$TEST_TMP/fd-events"
    case "$supplied_fd" in
      3) exec 3<"$TEST_TMP/credential" ;;
      4) exec 4<"$TEST_TMP/credential" ;;
      5) exec 5<"$TEST_TMP/credential" ;;
    esac
    set +e
    PROBE_FD="$supplied_fd"
    run_with_private_fd_closed "$supplied_fd" managed_prepare_candidate_preflight 1000 &&
      managed_generate_candidate_provider "$supplied_fd"
    rc=$?
    set +e
    case "$supplied_fd" in
      3) exec 3<&- ;;
      4) exec 4<&- ;;
      5) exec 5<&- ;;
    esac
    assert_eq 0 "$rc" "generator must safely remap supplied descriptor $supplied_fd" || return 1
    manifest="$MANAGED_PROFILE_MANIFEST"
    assert_eq $'generated\tCandidate\t198.51.100.20:1637\tpinned=1' "$manifest" \
      "generator manifest must remain redacted" || return 1
    args="$(<"${AIRVPN_API_HELPER}.args")"
    assert_not_contains descriptor-only-test-record "$args$manifest" \
      "credential must never enter helper argv or output" || return 1
    assert_contains generate-profile "$args" "generator must use the fixed provider subcommand" || return 1
    [[ -f "$MANAGED_CANDIDATE" ]] || fail "generator must write only through candidate fd 4" || return 1
    assert_eq $'paths-closed\ninode-closed\nhasher-closed\nhasher-closed\nfinalize-closed' \
      "$(<"$TEST_TMP/fd-events")" \
      "all non-provider stages must run with credential and candidate descriptors closed" || return 1
  done
  unset AIRVPN_API_KEY
}

test_generator_failure_cleanup_closes_reserved_credential_descriptors() {
  local supplied_fd failure_case expected_rc rc
  setup_managed_journal_fixture || return 1
  AIRVPN_API_HELPER="$TEST_TMP/fake-airvpn-api"
  printf '#!/bin/sh\nexit 1\n' > "$AIRVPN_API_HELPER"
  chmod 755 -- "$AIRVPN_API_HELPER"
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  MANAGED_PROFILE_SERVER=Candidate
  MANAGED_PROFILE_ENDPOINT=198.51.100.20:1637
  MANAGED_PROFILE_PIN=1
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_TIMEOUT=20
  validate_secure_executable() { return 0; }
  managed_invoke_generator_closed() {
    close_private_fd "$1" || return 1
    case "$FAILURE_CASE" in
      auth) return 4 ;;
      rate) return 5 ;;
      device) return 7 ;;
      transient) return 1 ;;
      manifest) printf 'generated\tWrong\t198.51.100.20:1637\tpinned=1\n' ;;
      *) return 1 ;;
    esac
  }
  managed_remove_generated_candidate() {
    if python3 - "$PROBE_FD" <<'PY'
import errno
import os
import sys

fd = int(sys.argv[1])
if os.path.exists(f"/proc/self/fd/{fd}"):
    raise SystemExit(1)
for operation in (lambda: os.lseek(fd, 0, os.SEEK_SET), lambda: os.read(fd, 1)):
    try:
        operation()
    except OSError as error:
        if error.errno != errno.EBADF:
            raise
    else:
        raise SystemExit(1)
PY
    then
      printf 'cleanup-closed:%s:%s\n' "$PROBE_FD" "$FAILURE_CASE" >> "$TEST_TMP/cleanup-events"
    else
      printf 'cleanup-leaked:%s:%s\n' "$PROBE_FD" "$FAILURE_CASE" >> "$TEST_TMP/cleanup-events"
    fi
    rm -f -- "$MANAGED_CANDIDATE"
  }

  for supplied_fd in 3 4 5; do
    for failure_case in auth rate device transient manifest; do
      FAILURE_CASE="$failure_case"
      PROBE_FD="$supplied_fd"
      : > "$TEST_TMP/cleanup-events"
      : > "$MANAGED_CANDIDATE"
      chmod 600 -- "$MANAGED_CANDIDATE"
      case "$supplied_fd" in
        3) exec 3<"$TEST_TMP/credential" ;;
        4) exec 4<"$TEST_TMP/credential" ;;
        5) exec 5<"$TEST_TMP/credential" ;;
      esac
      set +e; managed_generate_candidate_provider "$supplied_fd" >/dev/null 2>&1; rc=$?; set +e
      case "$supplied_fd" in
        3) exec 3<&- ;;
        4) exec 4<&- ;;
        5) exec 5<&- ;;
      esac
      case "$failure_case" in
        auth) expected_rc=4 ;;
        rate) expected_rc=5 ;;
        device) expected_rc=7 ;;
        transient|manifest) expected_rc=1 ;;
      esac
      assert_eq "$expected_rc" "$rc" "$failure_case provider result must be preserved" || return 1
      assert_eq "cleanup-closed:$supplied_fd:$failure_case" "$(<"$TEST_TMP/cleanup-events")" \
        "$failure_case cleanup child must not inherit supplied fd $supplied_fd" || return 1
    done
  done
}

test_generator_transient_failure_manifest_is_exact_and_secret_safe() {
  local hasher_case malformed_case output rc
  setup_managed_journal_fixture || return 1
  AIRVPN_API_HELPER="$TEST_TMP/fake-airvpn-api"
  printf '#!/bin/sh\nexit 1\n' > "$AIRVPN_API_HELPER"
  chmod 755 -- "$AIRVPN_API_HELPER"
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  MANAGED_PROFILE_SERVER=Candidate
  MANAGED_PROFILE_ENDPOINT=198.51.100.20:1637
  MANAGED_PROFILE_PIN=1
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_TIMEOUT=20
  validate_secure_executable() { return 0; }
  managed_remove_generated_candidate() { rm -f -- "$MANAGED_CANDIDATE"; }

  managed_invoke_generator_closed() {
    close_private_fd "$1" || return 1
    printf 'failure\ttransient\tphase=response\treason=media_missing\n'
    return 6
  }
  : > "$MANAGED_CANDIDATE"
  chmod 600 -- "$MANAGED_CANDIDATE"
  exec 3<"$TEST_TMP/credential"
  set +e
  managed_generate_candidate_provider 3 > "$TEST_TMP/phase-output"
  rc=$?
  set +e
  exec 3<&-
  output="$(<"$TEST_TMP/phase-output")"
  assert_eq 1 "$rc" "transient provider failure must remain nonzero" || return 1
  assert_eq '' "$output" \
    "provider callback must defer the safe phase until outcome persistence" || return 1
  assert_eq response "$MANAGED_API_PROVIDER_FAILURE_PHASE" \
    "provider callback must retain only the canonical safe phase enum" || return 1
  assert_eq media_missing "$MANAGED_API_PROVIDER_FAILURE_REASON" \
    "provider callback must retain only the canonical safe response reason" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "transient failure must remove the generated candidate" || return 1
  managed_invoke_generator_closed() {
    close_private_fd "$1" || return 1
    case "$MALFORMED_MANIFEST_CASE" in
      extra-line) printf 'failure\ttransient\tphase=response\n\n' ;;
      nul) printf 'failure\ttransient\tphase=response\n\000' ;;
      secret) printf 'failure\ttransient\tphase=response\n%s\n' 'descriptor-only-test-record' ;;
      unknown-reason) printf 'failure\ttransient\tphase=response\treason=remote-detail\n' ;;
      generic-media) printf 'failure\ttransient\tphase=response\treason=media\n' ;;
      *) return 1 ;;
    esac
    return 6
  }
  for malformed_case in extra-line nul secret unknown-reason generic-media; do
    MALFORMED_MANIFEST_CASE="$malformed_case"
    : > "$MANAGED_CANDIDATE"
    chmod 600 -- "$MANAGED_CANDIDATE"
    exec 3<"$TEST_TMP/credential"
    set +e
    managed_generate_candidate_provider 3 > "$TEST_TMP/phase-output" 2>/dev/null
    rc=$?
    set +e
    exec 3<&-
    output="$(<"$TEST_TMP/phase-output")"
    assert_eq 1 "$rc" "$malformed_case transient output must remain nonzero" || return 1
    assert_eq '' "$output" "$malformed_case helper output must be discarded" || return 1
    assert_eq '' "$MANAGED_API_PROVIDER_FAILURE_PHASE" \
      "$malformed_case helper output must not retain a provider phase" || return 1
    assert_eq '' "$MANAGED_API_PROVIDER_FAILURE_REASON" \
      "$malformed_case helper output must not retain a provider reason" || return 1
    [[ ! -e "$MANAGED_CANDIDATE" ]] ||
      fail "$malformed_case transient failure must remove the generated candidate" || return 1
  done

  managed_invoke_generator_closed() {
    close_private_fd "$1" || return 1
    printf 'failure\ttransient\tphase=response\treason=media_missing\n'
    return 6
  }
  managed_secure_sha256_stream() {
    command sha256sum >/dev/null
    [[ "$HASHER_CASE" == malformed ]] && { printf 'not-a-digest\n'; return 0; }
    return 9
  }
  for hasher_case in malformed failed; do
    HASHER_CASE="$hasher_case"
    : > "$MANAGED_CANDIDATE"
    chmod 600 -- "$MANAGED_CANDIDATE"
    exec 3<"$TEST_TMP/credential"
    set +e
    managed_generate_candidate_provider 3 > "$TEST_TMP/phase-output" 2>/dev/null
    rc=$?
    set +e
    exec 3<&-
    assert_eq 1 "$rc" "$hasher_case hasher result must fail closed" || return 1
    assert_eq '' "$(<"$TEST_TMP/phase-output")" "$hasher_case hasher output must be suppressed" || return 1
    assert_eq '' "$MANAGED_API_PROVIDER_FAILURE_PHASE" \
      "$hasher_case hasher result must suppress provider attribution" || return 1
    assert_eq '' "$MANAGED_API_PROVIDER_FAILURE_REASON" \
      "$hasher_case hasher result must suppress provider reason attribution" || return 1
    [[ ! -e "$MANAGED_CANDIDATE" ]] || return 1
  done
}

test_generator_dup_failure_cleanup_closes_reserved_credential_descriptors() {
  local supplied_fd rc
  setup_managed_journal_fixture || return 1
  declare -F managed_duplicate_credential_fd >/dev/null ||
    fail "generator credential duplication seam is missing" || return 1
  AIRVPN_API_HELPER="$TEST_TMP/fake-airvpn-api"
  printf '#!/bin/sh\nexit 1\n' > "$AIRVPN_API_HELPER"
  chmod 755 -- "$AIRVPN_API_HELPER"
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  MANAGED_PROFILE_SERVER=Candidate
  MANAGED_PROFILE_ENDPOINT=198.51.100.20:1637
  MANAGED_PROFILE_PIN=1
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_TIMEOUT=20
  validate_secure_executable() { return 0; }
  managed_duplicate_credential_fd() { return 1; }
  managed_invoke_generator_closed() {
    printf 'unexpected-provider\n' >> "$TEST_TMP/cleanup-events"
    return 1
  }
  managed_remove_generated_candidate() {
    if python3 - "$PROBE_FD" <<'PY'
import errno
import os
import sys

fd = int(sys.argv[1])
if os.path.exists(f"/proc/self/fd/{fd}"):
    raise SystemExit(1)
for operation in (lambda: os.lseek(fd, 0, os.SEEK_SET), lambda: os.read(fd, 1)):
    try:
        operation()
    except OSError as error:
        if error.errno != errno.EBADF:
            raise
    else:
        raise SystemExit(1)
PY
    then
      printf 'cleanup-closed:%s:dup\n' "$PROBE_FD" >> "$TEST_TMP/cleanup-events"
    else
      printf 'cleanup-leaked:%s:dup\n' "$PROBE_FD" >> "$TEST_TMP/cleanup-events"
    fi
    rm -f -- "$MANAGED_CANDIDATE"
  }

  for supplied_fd in 3 4 5; do
    PROBE_FD="$supplied_fd"
    : > "$TEST_TMP/cleanup-events"
    : > "$MANAGED_CANDIDATE"
    chmod 600 -- "$MANAGED_CANDIDATE"
    case "$supplied_fd" in
      3) exec 3<"$TEST_TMP/credential" ;;
      4) exec 4<"$TEST_TMP/credential" ;;
      5) exec 5<"$TEST_TMP/credential" ;;
    esac
    set +e; managed_generate_candidate_provider "$supplied_fd" >/dev/null 2>&1; rc=$?; set +e
    case "$supplied_fd" in
      3) exec 3<&- ;;
      4) exec 4<&- ;;
      5) exec 5<&- ;;
    esac
    assert_eq 1 "$rc" "credential duplication failure must remain nonzero" || return 1
    assert_eq "cleanup-closed:$supplied_fd:dup" "$(<"$TEST_TMP/cleanup-events")" \
      "dup cleanup child must not inherit supplied fd $supplied_fd" || return 1
  done
}

test_api_administration_requires_explicit_country_policy_before_provider() {
  local credential_fd rc
  setup_managed_journal_fixture || return 1
  rm -f -- "$WG_CONF" "$MANAGED_CANDIDATE"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' > "$CFG"
  chmod 600 -- "$CFG"
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_DEVICE=Device-One
  AIRVPN_COUNTRIES='GB NL'
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  : > "$TEST_TMP/provider-events"
  managed_run_authenticated_attempt() { printf 'provider\n' >> "$TEST_TMP/provider-events"; }
  exec {credential_fd}<"$TEST_TMP/credential"
  set +e; managed_command_provision dry-run "$credential_fd" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "omitted API country policy must fail closed" || return 1
  assert_eq '' "$(<"$TEST_TMP/provider-events")" \
    "omitted countries must fail before authenticated provider access" || return 1

  printf 'AIRVPN_COUNTRIES=\n' >> "$CFG"
  AIRVPN_COUNTRIES=''
  managed_command_provision dry-run '' || return 1
  assert_eq provider "$(<"$TEST_TMP/provider-events")" \
    "an explicit empty country value must represent ALL" || return 1
  : > "$TEST_TMP/provider-events"
  sed -i 's/^AIRVPN_COUNTRIES=.*/AIRVPN_COUNTRIES=nl GB nl DE/' "$CFG"
  AIRVPN_COUNTRIES='nl GB nl DE'
  managed_command_provision dry-run '' || return 1
  assert_eq 'NL GB DE' "$AIRVPN_COUNTRIES" \
    "country allowlist must preserve normalized first-choice order"
}

test_apply_requires_installed_credential_and_override_identity_match() {
  local credential_fd rc
  setup_managed_journal_fixture || return 1
  rm -f -- "$WG_CONF" "$MANAGED_CANDIDATE"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  AIRVPN_API_KEY_FILE="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.api-key"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  chmod 600 -- "$CFG"
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_DEVICE=Device-One
  AIRVPN_COUNTRIES=GB
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  : > "$TEST_TMP/provider-events"
  managed_run_authenticated_attempt() { printf 'provider\n' >> "$TEST_TMP/provider-events"; }

  set +e; managed_command_provision apply '' >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "apply must refuse a missing installed credential" || return 1
  assert_eq '' "$(<"$TEST_TMP/provider-events")" "missing installed key must precede provider" || return 1
  [[ ! -e "$WG_CONF" ]] || fail "missing key must not provision a profile" || return 1

  write_valid_test_key "$AIRVPN_API_KEY_FILE"; chmod 600 -- "$AIRVPN_API_KEY_FILE"
  printf '%064d\n' 1 > "$TEST_TMP/proposed-key"; chmod 600 -- "$TEST_TMP/proposed-key"
  exec {credential_fd}<"$TEST_TMP/proposed-key"
  set +e; managed_command_provision apply "$credential_fd" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "apply override must be the installed credential inode" || return 1
  assert_eq '' "$(<"$TEST_TMP/provider-events")" "mismatched override must precede provider" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=static' "$(<"$CFG")" \
    "mismatched override must not enable API mode" || return 1

  managed_command_provision apply '' || return 1
  assert_eq provider "$(<"$TEST_TMP/provider-events")" \
    "apply may proceed after the fixed installed key is validated"
}

test_selector_and_candidate_staging_failures_do_not_consume_authenticated_attempts() {
  local case_name rc
  source_managed_contract || return 1
  setup_api_state_fixture
  : > "$TEST_TMP/preflight-events"
  provider_after_preflight() { printf 'provider\n' >> "$TEST_TMP/preflight-events"; }
  downstream_after_preflight() { printf 'downstream\n' >> "$TEST_TMP/preflight-events"; }
  cleanup_after_preflight() { printf 'cleanup\n' >> "$TEST_TMP/preflight-events"; }
  for case_name in no-candidate selector-contract staging; do
    rm -f -- "$AIRVPN_API_STATE_FILE"
    : > "$TEST_TMP/preflight-events"
    preflight_failure() { printf '%s\n' "$case_name" >> "$TEST_TMP/preflight-events"; return 1; }
    set +e
    managed_run_authenticated_attempt 0 '' provider_after_preflight downstream_after_preflight \
      preflight_failure cleanup_after_preflight
    rc=$?
    set +e
    assert_eq 1 "$rc" "$case_name preflight must fail" || return 1
    assert_not_contains provider "$(<"$TEST_TMP/preflight-events")" \
      "$case_name failure must precede authenticated generation" || return 1
    [[ ! -e "$AIRVPN_API_STATE_FILE" ]] ||
      fail "$case_name failure must not write or consume an authenticated attempt" || return 1
  done
}

test_orphan_candidate_recovery_is_durable_bounded_and_symlink_safe() {
  local rc victim
  setup_managed_journal_fixture || return 1
  rm -f -- "$ROTATION_PENDING" "$MANAGED_SAFETY"
  : > "$TEST_TMP/orphan-sync"
  managed_sync_artifact_parent() { printf 'directory\n' >> "$TEST_TMP/orphan-sync"; }
  : > "$MANAGED_CANDIDATE"; chmod 600 -- "$MANAGED_CANDIDATE"
  managed_cleanup_orphan_candidate || return 1
  [[ ! -e "$MANAGED_CANDIDATE" ]] || fail "empty preflight orphan must be removed" || return 1
  assert_eq directory "$(<"$TEST_TMP/orphan-sync")" "orphan cleanup must sync its parent" || return 1

  write_managed_candidate_fixture
  managed_cleanup_orphan_candidate || return 1
  [[ ! -e "$MANAGED_CANDIDATE" ]] || fail "generated-profile orphan must be removed" || return 1

  victim="$TEST_TMP/orphan-canary"
  printf 'do-not-delete\n' > "$victim"
  ln -s -- "$victim" "$MANAGED_CANDIDATE"
  set +e; managed_cleanup_orphan_candidate >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "orphan candidate symlink must fail closed" || return 1
  assert_eq do-not-delete "$(<"$victim")" "orphan cleanup must never follow a symlink" || return 1
  assert_eq invalid "$(managed_status_pending)" "unsafe candidate must be observationally invalid" || return 1
  rm -f -- "$MANAGED_CANDIDATE"

  head -c 65537 /dev/zero > "$MANAGED_CANDIDATE"; chmod 600 -- "$MANAGED_CANDIDATE"
  set +e; managed_cleanup_orphan_candidate >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "oversized orphan candidate must be retained for repair" || return 1
  [[ -f "$MANAGED_CANDIDATE" ]] || fail "oversized orphan evidence must not be deleted" || return 1
  rm -f -- "$MANAGED_CANDIDATE"
  write_managed_candidate_fixture
  assert_eq orphan-candidate "$(managed_status_pending)" \
    "safe unowned candidate must be visible without exposing profile fields"
}

test_setup_owned_candidate_cleanup_requires_exclusive_lease_and_interface_lock() {
  local rc
  setup_managed_journal_fixture || return 1
  rm -f -- "$ROTATION_PENDING" "$MANAGED_SAFETY"
  : > "$TEST_TMP/setup-cleanup-sync"
  : > "$TEST_TMP/setup-cleanup-status"
  managed_sync_artifact_parent() { printf 'directory\n' >> "$TEST_TMP/setup-cleanup-sync"; }
  write_status() { printf '%s:%s\n' "$1" "$2" >> "$TEST_TMP/setup-cleanup-status"; }
  is_root() { return 0; }

  GUARD_LOCKED=1
  CONTEXT_LOCKED=1
  SETUP_LEASE_ADOPTED=0
  set +e; managed_dispatch_command cleanup-candidate apply 0 '' >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an ordinary shared runtime guard must not authorize cleanup" || return 1
  [[ -f "$MANAGED_CANDIDATE" ]] || fail "unauthorized cleanup must retain the candidate" || return 1

  SETUP_LEASE_ADOPTED=1
  GUARD_LOCKED=0
  set +e; managed_dispatch_command cleanup-candidate apply 0 '' >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "cleanup must retain the adopted exclusive guard" || return 1
  [[ -f "$MANAGED_CANDIDATE" ]] || fail "guardless cleanup must retain the candidate" || return 1

  GUARD_LOCKED=1
  CONTEXT_LOCKED=0
  set +e; managed_dispatch_command cleanup-candidate apply 0 '' >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "cleanup must run while holding the interface lock" || return 1
  [[ -f "$MANAGED_CANDIDATE" ]] || fail "interface-unlocked cleanup must retain the candidate" || return 1

  CONTEXT_LOCKED=1
  managed_dispatch_command cleanup-candidate apply 0 '' || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "authorized setup cleanup must remove the safe orphan candidate" || return 1
  assert_eq directory "$(<"$TEST_TMP/setup-cleanup-sync")" \
    "setup cleanup must retain the existing durable orphan-removal owner" || return 1
  assert_eq '' "$(<"$TEST_TMP/setup-cleanup-status")" \
    "candidate recovery must not overwrite health status" || return 1
  managed_dispatch_command cleanup-candidate apply 0 '' ||
    fail "authorized cleanup must be idempotent once the candidate is absent" || return 1

  write_managed_candidate_fixture
  : > "$TEST_TMP/setup-cleanup-owner-calls"
  managed_cleanup_orphan_candidate() {
    printf 'called\n' >> "$TEST_TMP/setup-cleanup-owner-calls"
    return 0
  }
  set +e; managed_dispatch_command cleanup-candidate apply 0 '' >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "cleanup must prove the candidate absent after its owner returns" || return 1
  assert_eq called "$(<"$TEST_TMP/setup-cleanup-owner-calls")" \
    "setup cleanup must call the existing safe orphan-cleanup owner" || return 1
  [[ -f "$MANAGED_CANDIDATE" ]] || fail "failed absence proof must retain visible evidence" || return 1
  assert_eq '' "$(<"$TEST_TMP/setup-cleanup-status")" \
    "failed candidate absence proof must remain status-neutral"
}

setup_profile_orphan_command_fixture() {
  setup_managed_journal_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  AIRVPN_API_KEY_FILE="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.api-key"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB NL' > "$CFG"
  chmod 600 -- "$CFG"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  chmod 600 -- "$AIRVPN_API_KEY_FILE"
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_DEVICE=Device-One
  AIRVPN_COUNTRIES='GB NL'
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  AIRVPN_ROTATE_ENABLED=1
  AIRVPN_ROTATE_COOLDOWN=0
  : > "$TEST_TMP/orphan-events"
  : > "$TEST_TMP/orphan-sync-events"
  managed_sync_artifact_parent() { printf 'sync\n' >> "$TEST_TMP/orphan-sync-events"; }
  managed_run_authenticated_attempt() {
    printf 'authenticated\n' >> "$TEST_TMP/orphan-events"
    [[ -z "${2-}" ]] || close_private_fd "$2"
    return 1
  }
  cooldown_allows() { return 0; }
}

assert_profile_dry_run_preserves_orphan() {
  local operation="${1:?}" candidate_before rc
  setup_profile_orphan_command_fixture || return 1
  case "$operation" in
    provision) rm -f -- "$WG_CONF" ;;
    adopt) AIRVPN_PROFILE_SOURCE=static ;;
    rotate) AIRVPN_PROFILE_SOURCE=api ;;
    *) return 1 ;;
  esac
  candidate_before="$(<"$MANAGED_CANDIDATE")"
  case "$operation" in
    provision) set +e; managed_command_provision dry-run '' >/dev/null 2>&1; rc=$?; set +e ;;
    adopt) set +e; managed_command_adopt dry-run '' >/dev/null 2>&1; rc=$?; set +e ;;
    rotate) set +e; managed_command_rotate dry-run >/dev/null 2>&1; rc=$?; set +e ;;
  esac
  assert_eq 1 "$rc" "$operation dry-run must refuse a pre-existing safe candidate" || return 1
  assert_eq "$candidate_before" "$(<"$MANAGED_CANDIDATE")" \
    "$operation dry-run must preserve exact safe candidate bytes" || return 1
  assert_eq '' "$(<"$TEST_TMP/orphan-sync-events")" \
    "$operation dry-run must not sync candidate cleanup" || return 1
  assert_eq '' "$(<"$TEST_TMP/orphan-events")" \
    "$operation dry-run must refuse before authenticated accounting" || return 1

  chmod 640 -- "$MANAGED_CANDIDATE"
  case "$operation" in
    provision) set +e; managed_command_provision dry-run '' >/dev/null 2>&1; rc=$?; set +e ;;
    adopt) set +e; managed_command_adopt dry-run '' >/dev/null 2>&1; rc=$?; set +e ;;
    rotate) set +e; managed_command_rotate dry-run >/dev/null 2>&1; rc=$?; set +e ;;
  esac
  assert_eq 1 "$rc" "$operation dry-run must refuse an unsafe candidate" || return 1
  [[ -f "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "$operation dry-run must preserve unsafe candidate evidence" || return 1
  assert_eq 640 "$(stat -c '%a' -- "$MANAGED_CANDIDATE")" \
    "$operation dry-run must not repair unsafe candidate metadata" || return 1
  assert_eq '' "$(<"$TEST_TMP/orphan-sync-events")" \
    "$operation unsafe refusal must remain observational" || return 1
  assert_eq '' "$(<"$TEST_TMP/orphan-events")" \
    "$operation unsafe refusal must precede authenticated accounting"
}

test_provision_dry_run_preserves_preexisting_orphan_candidate() {
  assert_profile_dry_run_preserves_orphan provision
}

test_adopt_dry_run_preserves_preexisting_orphan_candidate() {
  assert_profile_dry_run_preserves_orphan adopt
}

test_rotate_dry_run_preserves_preexisting_orphan_candidate() {
  assert_profile_dry_run_preserves_orphan rotate
}

test_profile_apply_precheck_cleans_safe_orphan_before_accounting() {
  local credential_fd rc
  setup_profile_orphan_command_fixture || return 1
  rm -f -- "$WG_CONF"
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  set +e
  managed_command_provision apply "$credential_fd" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "apply cleanup fixture must stop in authenticated owner" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "apply precheck must bounded-clean a safe orphan candidate" || return 1
  assert_eq sync "$(<"$TEST_TMP/orphan-sync-events")" \
    "apply cleanup must sync the candidate parent" || return 1
  assert_eq authenticated "$(<"$TEST_TMP/orphan-events")" \
    "apply cleanup must then enter normal authenticated accounting"
}

test_timer_rotation_precheck_cleans_safe_orphan_before_accounting() {
  local rc
  setup_profile_orphan_command_fixture || return 1
  AIRVPN_PROFILE_SOURCE=api
  set +e; managed_rotate_profile timer_health_failure 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "timer cleanup fixture must stop in authenticated owner" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "timer precheck must bounded-clean a safe orphan candidate" || return 1
  assert_eq sync "$(<"$TEST_TMP/orphan-sync-events")" \
    "timer cleanup must sync the candidate parent" || return 1
  assert_eq authenticated "$(<"$TEST_TMP/orphan-events")" \
    "timer cleanup must preserve normal authenticated accounting"
}

test_generator_provider_preserves_caller_errexit_state() {
  local rc
  setup_managed_journal_fixture || return 1
  AIRVPN_API_HELPER="$TEST_TMP/fake-airvpn-api"
  printf '#!/bin/sh\nexit 1\n' > "$AIRVPN_API_HELPER"
  chmod 755 -- "$AIRVPN_API_HELPER"
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  : > "$MANAGED_CANDIDATE"
  chmod 600 -- "$MANAGED_CANDIDATE"
  MANAGED_PROFILE_SERVER=Candidate
  MANAGED_PROFILE_ENDPOINT=198.51.100.20:1637
  MANAGED_PROFILE_PIN=1
  AIRVPN_DEVICE=Device-One
  AIRVPN_API_TIMEOUT=20
  validate_secure_executable() { return 0; }
  managed_invoke_generator_closed() { close_private_fd "$1"; return 1; }
  for expected in on off; do
    : > "$MANAGED_CANDIDATE"
    exec 3<"$TEST_TMP/credential"
    if [[ "$expected" == on ]]; then set -e; else set +e; fi
    if managed_generate_candidate_provider 3 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    assert_eq 1 "$rc" "generator failure fixture must remain nonzero" || { set +e; return 1; }
    if [[ "$expected" == on ]]; then
      [[ "$-" == *e* ]] || { set +e; fail "generator must preserve enabled errexit"; return 1; }
    else
      [[ "$-" != *e* ]] || { set +e; fail "generator must preserve disabled errexit"; return 1; }
    fi
    exec 3<&-
  done
  set +e
}

test_status_timer_preserves_caller_errexit_state() {
  local expected
  source_managed_contract || return 1
  IFACE=wg0
  managed_systemctl() { return 4; }
  for expected in on off; do
    if [[ "$expected" == on ]]; then set -e; else set +e; fi
    managed_status_timer >/dev/null
    if [[ "$expected" == on ]]; then
      [[ "$-" == *e* ]] || { set +e; fail "status timer must preserve enabled errexit"; return 1; }
    else
      [[ "$-" != *e* ]] || { set +e; fail "status timer must preserve disabled errexit"; return 1; }
    fi
  done
  set +e
}

test_unit_inactivity_probe_preserves_caller_errexit_state() {
  local expected
  source_managed_contract || return 1
  IFACE=wg0
  managed_systemctl() { return 3; }
  for expected in on off; do
    if [[ "$expected" == on ]]; then set -e; else set +e; fi
    managed_units_are_inactive
    if [[ "$expected" == on ]]; then
      [[ "$-" == *e* ]] || { set +e; fail "unit probe must preserve enabled errexit"; return 1; }
    else
      [[ "$-" != *e* ]] || { set +e; fail "unit probe must preserve disabled errexit"; return 1; }
    fi
  done
  set +e
}

test_real_preflight_backoff_is_nonincrementing_and_local_staging_precedes_network() {
  local credential_fd rc state
  source_managed_contract || return 1
  setup_api_state_fixture
  WG_CONF="$TEST_TMP/etc/wireguard/wg0.conf"
  ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
  MANAGED_SAFETY="${WG_CONF}.safety-healthcheck"
  MANAGED_CANDIDATE="${WG_CONF%/*}/.${WG_CONF##*/}.managed-candidate"
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${WG_CONF%/*}"
  chmod 700 -- "${WG_CONF%/*}"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=api' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  chmod 600 -- "$CFG"
  AIRVPN_PROFILE_SOURCE=api
  AIRVPN_DEVICE=Device-One
  AIRVPN_COUNTRIES=GB
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  AIRVPN_API_HELPER="$TEST_TMP/provider-helper"
  printf '#!/bin/sh\nexit 1\n' > "$AIRVPN_API_HELPER"; chmod 755 -- "$AIRVPN_API_HELPER"
  MANAGED_PROFILE_OPERATION=provision
  validate_secure_executable() { return 0; }
  : > "$TEST_TMP/selector-events"
  managed_select_airvpn_candidate() { printf 'selector\n' >> "$TEST_TMP/selector-events"; return 1; }
  managed_api_state_defaults 1000 || return 1
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  managed_api_state_refresh_identity 1000 "$credential_fd" || return 1
  exec {credential_fd}<&-
  set +e; managed_prepare_candidate_preflight 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "selector/no-candidate preflight must fail" || return 1
  state="$(<"$AIRVPN_API_STATE_FILE")"
  assert_contains 'attempt_count=0' "$state" "public preflight failure must not consume auth budget" || return 1
  assert_contains 'failure_class=transient' "$state" "public preflight failure must persist transient suppression" || return 1
  assert_contains 'backoff_until=1300' "$state" "public preflight backoff must use the five-minute floor" || return 1
  managed_preflight_candidate_cleanup || return 1
  managed_api_state_load 1001 || return 1
  set +e; managed_api_gate_before_preflight 1001 0; rc=$?; set +e
  assert_eq 75 "$rc" "timer retry inside preflight backoff must be suppressed" || return 1

  rm -f -- "$AIRVPN_API_STATE_FILE" "$MANAGED_CANDIDATE"
  : > "$TEST_TMP/selector-events"
  managed_api_state_defaults 1000 || return 1
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  managed_api_state_refresh_identity 1000 "$credential_fd" || return 1
  exec {credential_fd}<&-
  ln -s -- "$TEST_TMP/staging-canary" "$MANAGED_CANDIDATE"
  set +e; managed_prepare_candidate_preflight 1000 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "local staging failure must fail closed" || return 1
  assert_eq '' "$(<"$TEST_TMP/selector-events")" \
    "local staging must be proven before any public network selection" || return 1
  [[ ! -e "$AIRVPN_API_STATE_FILE" ]] ||
    fail "local staging failure must not mutate persistent attempt/backoff state"
}

test_six_argument_attempt_uses_one_preflight_epoch_across_second_boundary() {
  local state
  source_managed_contract || return 1
  setup_api_state_fixture
  MANAGED_TEST_ATTEMPT_EPOCH=1000
  MANAGED_TEST_OUTCOME_EPOCH=1001
  : > "$TEST_TMP/epoch-events"
  epoch_preflight() { printf 'preflight:%s\n' "${1:?}" >> "$TEST_TMP/epoch-events"; }
  epoch_cleanup() { printf 'cleanup\n' >> "$TEST_TMP/epoch-events"; }
  epoch_provider() { printf 'provider\n' >> "$TEST_TMP/epoch-events"; }
  epoch_downstream() { printf 'downstream\n' >> "$TEST_TMP/epoch-events"; }
  managed_run_authenticated_attempt 0 '' epoch_provider epoch_downstream \
    epoch_preflight epoch_cleanup || return 1
  assert_eq $'preflight:1000\nprovider\ndownstream' "$(<"$TEST_TMP/epoch-events")" \
    "preflight must consume the wrapper's exact attempt epoch" || return 1
  state="$(<"$AIRVPN_API_STATE_FILE")"
  assert_contains 'attempt_01=1000' "$state" \
    "attempt record must reuse the preflight epoch across a one-second outcome boundary"
}
