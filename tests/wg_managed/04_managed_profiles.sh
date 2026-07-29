#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

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
  local backup_digest candidate_digest equal_candidate_digest expected case_name rc
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
  write_managed_candidate_fixture 192.0.2.10:1637
  managed_sha256_file equal_candidate_digest "$MANAGED_CANDIDATE" || return 1

  printf '%s\n' "$expected" |
    sed -e "s/^candidate_sha256=.*/candidate_sha256=$equal_candidate_digest/" \
      -e 's/^candidate_endpoint=.*/candidate_endpoint=192.0.2.10:1637/' \
      > "$TEST_TMP/equal-endpoint-safety"
  mv -- "$TEST_TMP/equal-endpoint-safety" "$MANAGED_SAFETY"
  chmod 600 -- "$MANAGED_SAFETY"
  managed_safety_load || fail "distinct profile digests may share a canonical endpoint" || return 1
  write_managed_candidate_fixture

  for case_name in unknown duplicate bad-state equal-digest bad-id \
      partial-unmanaged partial-running bad-listen bad-port control no-final-lf; do
    printf '%s\n' "$expected" > "$MANAGED_SAFETY"
    case "$case_name" in
      unknown) printf 'unknown=value\n' >> "$MANAGED_SAFETY" ;;
      duplicate) printf 'state=pending\n' >> "$MANAGED_SAFETY" ;;
      bad-state) sed -i 's/^state=pending$/state=rollback/' "$MANAGED_SAFETY" ;;
      equal-digest) sed -i "s/^candidate_sha256=.*/candidate_sha256=$backup_digest/" "$MANAGED_SAFETY" ;;
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
