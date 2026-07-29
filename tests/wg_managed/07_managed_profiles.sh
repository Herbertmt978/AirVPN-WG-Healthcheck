#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_managed_reconciliation_rolls_back_every_factual_crash_shape() {
  local shape phase active candidate runtime qb rc events checkpoint
  local -a shapes=(
    'prepared backup present old 1'
    'client-stopped backup present old 1'
    'tunnel-down backup present down 1'
    'candidate-installed candidate present down 1'
    'candidate-up candidate present candidate 1'
    'verified candidate present candidate 1'
    'verified candidate missing candidate 1'
    'candidate-up backup missing old 1'
    'candidate-up backup present old 0'
  )
  for shape in "${shapes[@]}"; do
    read -r phase active candidate runtime qb <<< "$shape"
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape "$phase" "$active" "$candidate" "$runtime" "$qb" || exit 1
      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      assert_eq 0 "$rc" "$shape must reconcile by verified rollback" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$shape successful recovery must remove candidate and marker" || exit 1
      cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
        fail "$shape must restore byte-for-byte backup content" || exit 1
      assert_eq 600 "$(stat -c '%a' "$WG_CONF")" "$shape restore must be mode 0600" || exit 1
      if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]]; then
        assert_eq 0 "$(stat -c '%u' "$WG_CONF")" "$shape restore must be root-owned" || exit 1
      fi
      assert_eq 192.0.2.10:1637 "$TRANSACTION_RUNTIME_ENDPOINT" \
        "$shape must restore and verify the old tunnel" || exit 1
      if [[ "$qb" == 1 ]]; then
        assert_eq running "$TRANSACTION_QB_STATE" "$shape must restore prior qB running intent" || exit 1
        events="$(<"$TRANSACTION_EVENTS")"
        assert_event_before 'identity:' 'qb-start:' \
          "$shape must prove old live identity before qB restore" || exit 1
        assert_event_before 'network:' 'qb-start:' \
          "$shape must prove old network before qB restore" || exit 1
        assert_event_before 'qb-start:' 'binding:' \
          "$shape must prove TCP/UDP ownership after qB starts" || exit 1
        for checkpoint in rollback-before-down rollback-after-down rollback-before-install \
            rollback-after-install rollback-before-up rollback-after-up rollback-before-network \
            rollback-after-network rollback-pre-cleanup rollback-post-cleanup; do
          assert_contains "qb-inspect:$checkpoint:" "$events" \
            "$shape must execute rollback containment checkpoint $checkpoint" || exit 1
        done
      else
        assert_eq stopped "$TRANSACTION_QB_STATE" "$shape must preserve prior stopped intent" || exit 1
      fi
    ) || return 1
  done
}

test_managed_unknown_or_mismatched_recovery_stops_qb_without_network_guessing() {
  local case_name rc events
  for case_name in active-unknown candidate-mismatch backup-mismatch invalid-journal; do
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape candidate-up candidate present candidate 1 || exit 1
      # This fixture state is intentionally local to the per-case recovery subshell.
      # shellcheck disable=SC2030
      TRANSACTION_QB_STATE=running
      case "$case_name" in
        active-unknown) printf '# active drift\n' >> "$WG_CONF" ;;
        candidate-mismatch) printf '# staged drift\n' >> "$MANAGED_CANDIDATE" ;;
        backup-mismatch) printf '# backup drift\n' >> "${WG_CONF}.bak-healthcheck" ;;
        invalid-journal) printf 'unknown=field\n' >> "$ROTATION_PENDING" ;;
      esac
      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name recovery must fail closed" || exit 1
      events="$(<"$TRANSACTION_EVENTS")"
      assert_contains 'qb-stop:' "$events" "$case_name must stop configured qB" || exit 1
      assert_eq stopped "$TRANSACTION_QB_STATE" "$case_name must prove qB stopped" || exit 1
      assert_not_contains 'wg-down:' "$events" "$case_name must not guess at tunnel mutation" || exit 1
      assert_not_contains 'profile-move:' "$events" "$case_name must not guess at profile restore" || exit 1
      [[ -f "$ROTATION_PENDING" ]] || fail "$case_name must retain its marker" || exit 1
      [[ -f "$MANAGED_CANDIDATE" ]] || fail "$case_name must retain its candidate" || exit 1
    ) || return 1
  done
}

test_managed_recovery_contains_qb_before_journal_or_digest_reads() {
  local case_name rc
  for case_name in valid malformed digest-mismatch; do
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape candidate-up candidate present candidate 1 || exit 1
      # This fixture state is intentionally local to the per-case recovery subshell.
      # shellcheck disable=SC2030
      TRANSACTION_QB_STATE=running
      eval "$(declare -f managed_journal_load | sed '1s/managed_journal_load/transaction_original_journal_load/')"
      eval "$(declare -f _managed_journal_recovery_state_is_consistent | sed '1s/_managed_journal_recovery_state_is_consistent/transaction_original_recovery_classifier/')"
      managed_journal_load() {
        transaction_event 'journal-load'
        transaction_original_journal_load
      }
      _managed_journal_recovery_state_is_consistent() {
        transaction_event 'digest-classify'
        transaction_original_recovery_classifier
      }
      case "$case_name" in
        valid) ;;
        malformed) printf 'unknown=field\n' >> "$ROTATION_PENDING" ;;
        digest-mismatch) printf '# drift\n' >> "${WG_CONF}.bak-healthcheck" ;;
      esac
      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      if [[ "$case_name" == valid ]]; then
        assert_eq 0 "$rc" "valid marker must still roll back" || exit 1
      else
        assert_eq 1 "$rc" "$case_name marker must fail closed" || exit 1
        [[ -f "$ROTATION_PENDING" ]] || fail "$case_name marker must be retained" || exit 1
      fi
      if [[ "$case_name" != digest-mismatch ]]; then
        assert_event_before 'qb-stop:' 'journal-load' \
          "$case_name recovery must stop and reinspect qB before parsing" || exit 1
      else
        assert_contains 'qb-stop:' "$(<"$TRANSACTION_EVENTS")" \
          "digest mismatch recovery must contain qB before safety artifact validation" || exit 1
        assert_not_contains 'journal-load' "$(<"$TRANSACTION_EVENTS")" \
          "safety artifact mismatch must fail before parsing the secondary journal" || exit 1
      fi
      if [[ "$case_name" == valid ]]; then
        assert_event_before 'qb-stop:' 'digest-classify' \
          "$case_name recovery must contain qB before artifact hashing" || exit 1
      fi
      if [[ "$case_name" == valid ]]; then
        assert_eq running "$TRANSACTION_QB_STATE" \
          "valid recovery may restore qB only after old network proof" || exit 1
      else
        assert_eq stopped "$TRANSACTION_QB_STATE" \
          "$case_name recovery must leave qB stopped"
      fi
    ) || return 1
  done
}

test_managed_reconciliation_is_idempotent_across_cleanup_crash() {
  local rc first_events
  setup_managed_transaction_fixture || return 1
  setup_managed_crash_shape candidate-up candidate present candidate 1 || return 1
  TRANSACTION_FAIL_ACTION=marker-delete
  TRANSACTION_FAIL_REMAINING=1
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "first cleanup interruption must remain pending" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "cleanup interruption must preserve the marker" || return 1
  # Independent tests rebuild this global fixture; the earlier subshell assignment cannot leak here.
  # shellcheck disable=SC2031
  assert_eq stopped "$TRANSACTION_QB_STATE" "failure after qB restore must stop it again" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
    fail "first reconciliation must already restore exact old bytes" || return 1
  first_events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'candidate-delete:' "$first_events" "first reconciliation reaches candidate cleanup" || return 1

  TRANSACTION_FAIL_ACTION=''
  : > "$TRANSACTION_EVENTS"
  managed_reconcile_pending || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "second reconciliation must finish cleanup idempotently" || return 1
  # See the intentional fixture-scope note above.
  # shellcheck disable=SC2031
  assert_eq running "$TRANSACTION_QB_STATE" "second reconciliation must restore qB intent" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
}

test_managed_qb_config_drift_restores_network_but_retains_safety() {
  local rc events
  setup_amended_recovery_shape pending matching candidate present running || return 1
  QBITTORRENT_CONTAINER=changed-container
  QBITTORRENT_LISTEN_PORT=6999
  printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/changed-container"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  : > "$DOCKER_FAKE_EVENTS"
  : > "$TRANSACTION_EVENTS"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "changed qB tuple must retain safety until operator repair" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'wg-down:' "$events" \
    "rollback-only checkpoints must permit exact old-network restoration after containment" || return 1
  assert_contains 'network:' "$events" \
    "tuple drift rollback must verify the restored old network" || return 1
  assert_eq 192.0.2.10:1637 "$TRANSACTION_RUNTIME_ENDPOINT" \
    "tuple drift rollback must restore the old runtime endpoint" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
    fail "tuple drift rollback must restore exact backup bytes" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "recorded qB container must remain stopped" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "safely identifiable current qB container must remain stopped" || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "verified drift rollback must clean candidate and journal evidence" || return 1
  [[ -f "$MANAGED_SAFETY" ]] ||
    fail "tuple drift must retain safety until the recorded intent can be restored" || return 1
  assert_not_contains 'start:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "tuple drift must never restart a container" || return 1
  assert_not_contains 'binding:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "tuple drift must not trust a listener binding probe"
}

test_managed_provision_install_is_atomic_durable_and_no_clobber() {
  local candidate_digest case_name rc original
  setup_managed_journal_fixture || return 1
  managed_sha256_file candidate_digest "$MANAGED_CANDIDATE" || return 1
  rm -f -- "$WG_CONF"
  : > "$TEST_TMP/install-sync"
  managed_sync_file() { printf 'file:%s\n' "$1" >> "$TEST_TMP/install-sync"; }
  managed_sync_artifact_parent() { printf 'dir:%s\n' "$1" >> "$TEST_TMP/install-sync"; }
  managed_install_profile_noclobber "$MANAGED_CANDIDATE" "$WG_CONF" \
    "$candidate_digest" '198.51.100.20:1637' || return 1
  cmp -s -- "$MANAGED_CANDIDATE" "$WG_CONF" ||
    fail "first provision must install exact canonical candidate bytes" || return 1
  assert_eq 600 "$(stat -c '%a' -- "$WG_CONF")" "provisioned profile must be mode 0600" || return 1
  assert_contains "file:$WG_CONF" "$(<"$TEST_TMP/install-sync")" \
    "provision must sync the installed profile" || return 1
  assert_contains "dir:${WG_CONF%/*}" "$(<"$TEST_TMP/install-sync")" \
    "provision must sync the WireGuard directory" || return 1

  original="$(<"$WG_CONF")"
  for case_name in regular directory; do
    rm -rf -- "$WG_CONF"
    if [[ "$case_name" == regular ]]; then printf 'operator-data\n' > "$WG_CONF"; else mkdir "$WG_CONF"; fi
    set +e
    managed_install_profile_noclobber "$MANAGED_CANDIDATE" "$WG_CONF" \
      "$candidate_digest" '198.51.100.20:1637' >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 1 "$rc" "provision must refuse existing $case_name destination" || return 1
    if [[ "$case_name" == regular ]]; then
      assert_eq operator-data "$(<"$WG_CONF")" "existing profile bytes must not be overwritten" || return 1
    else
      [[ -d "$WG_CONF" ]] || fail "existing destination directory must survive"
    fi
  done
  rm -rf -- "$WG_CONF"

  if [[ "$(uname -s)" == Linux ]]; then
    mkfifo "$WG_CONF"
    set +e; managed_install_profile_noclobber "$MANAGED_CANDIDATE" "$WG_CONF" \
      "$candidate_digest" '198.51.100.20:1637' >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "provision must refuse a FIFO destination" || return 1
    [[ -p "$WG_CONF" ]] || fail "destination FIFO must survive" || return 1
    rm -f -- "$WG_CONF"
    ln -s -- "$TEST_TMP/missing" "$WG_CONF"
    set +e; managed_install_profile_noclobber "$MANAGED_CANDIDATE" "$WG_CONF" \
      "$candidate_digest" '198.51.100.20:1637' >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "provision must refuse a dangling destination symlink" || return 1
    [[ -L "$WG_CONF" ]] || fail "dangling destination symlink must survive" || return 1
    rm -f -- "$WG_CONF"
  fi

  managed_profile_move_noclobber() {
    printf 'racer-data\n' > "$2"
    command mv -nT -- "$1" "$2"
  }
  set +e
  managed_install_profile_noclobber "$MANAGED_CANDIDATE" "$WG_CONF" \
    "$candidate_digest" '198.51.100.20:1637' >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "injected destination race must fail closed" || return 1
  assert_eq racer-data "$(<"$WG_CONF")" "no-clobber move must not replace the race winner" || return 1
  assert_not_contains "$original" "$(<"$WG_CONF")" "candidate bytes must not overwrite a raced path"
}

test_pre_managed_snapshot_is_immutable_exact_and_durable_before_mode_change() {
  local snapshot rc
  setup_managed_journal_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'MAX_AGE=180' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB NL' > "$CFG"
  chmod 600 -- "$CFG"
  : > "$TEST_TMP/snapshot-sync"
  managed_sync_file() { printf 'file:%s\n' "$1" >> "$TEST_TMP/snapshot-sync"; }
  managed_sync_artifact_parent() { printf 'dir:%s\n' "$1" >> "$TEST_TMP/snapshot-sync"; }
  managed_create_pre_managed_snapshot || return 1
  snapshot="$(<"$PRE_MANAGED_CONF")"
  cmp -s -- "$WG_CONF" "$PRE_MANAGED_CONF" || fail "snapshot must preserve exact bytes" || return 1
  assert_eq 600 "$(stat -c '%a' -- "$PRE_MANAGED_CONF")" "snapshot must be mode 0600" || return 1
  assert_contains "file:$PRE_MANAGED_CONF" "$(<"$TEST_TMP/snapshot-sync")" \
    "snapshot must be reread and synced" || return 1
  assert_contains "dir:${PRE_MANAGED_CONF%/*}" "$(<"$TEST_TMP/snapshot-sync")" \
    "snapshot parent must be synced" || return 1

  printf '\n# changed after adoption\n' >> "$WG_CONF"
  set +e; managed_create_pre_managed_snapshot >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an existing snapshot must never be overwritten" || return 1
  assert_eq "$snapshot" "$(<"$PRE_MANAGED_CONF")" "immutable snapshot bytes must survive retries" || return 1
  rm -f -- "$PRE_MANAGED_CONF"
  ln -s -- "$WG_CONF" "$PRE_MANAGED_CONF"
  set +e; managed_create_pre_managed_snapshot >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "snapshot symlink must be refused" || return 1
  [[ -L "$PRE_MANAGED_CONF" ]] || fail "snapshot symlink must not be replaced"
}

test_adopt_retry_rebarriers_visible_snapshot_after_install_sync_failures() {
  local failure_case rc first_events
  for failure_case in destination_sync parent_sync; do
    setup_managed_journal_fixture || return 1
    PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
    CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
    mkdir -p -- "${CFG%/*}"
    chmod 700 -- "${CFG%/*}"
    printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
      'AIRVPN_COUNTRIES=GB' > "$CFG"
    chmod 600 -- "$CFG"
    AIRVPN_PROFILE_SOURCE=static
    : > "$TEST_TMP/snapshot-retry-events"
    SNAPSHOT_FAILURE_PENDING=1
    managed_sync_file() {
      printf 'file:%s\n' "$1" >> "$TEST_TMP/snapshot-retry-events"
      if [[ "$failure_case" == destination_sync && "$1" == "$PRE_MANAGED_CONF" &&
            "$SNAPSHOT_FAILURE_PENDING" == 1 ]]; then
        SNAPSHOT_FAILURE_PENDING=0
        return 1
      fi
    }
    managed_sync_artifact_parent() {
      printf 'parent:%s\n' "$1" >> "$TEST_TMP/snapshot-retry-events"
      if [[ "$failure_case" == parent_sync && "$1" == "${PRE_MANAGED_CONF%/*}" &&
            -f "$PRE_MANAGED_CONF" && "$SNAPSHOT_FAILURE_PENDING" == 1 ]]; then
        SNAPSHOT_FAILURE_PENDING=0
        return 1
      fi
    }
    managed_sync_directory() { :; }
    managed_unlink_path() {
      printf 'unlink:%s\n' "$1" >> "$TEST_TMP/snapshot-retry-events"
      rm -f -- "$1"
    }

    set +e; managed_finish_adopt apply >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$failure_case must fail the first adoption attempt" || return 1
    [[ -f "$PRE_MANAGED_CONF" && ! -L "$PRE_MANAGED_CONF" ]] ||
      fail "$failure_case must leave a visible regular snapshot for retry" || return 1
    cmp -s -- "$WG_CONF" "$PRE_MANAGED_CONF" ||
      fail "$failure_case visible snapshot must retain exact active bytes" || return 1
    [[ -f "$MANAGED_CANDIDATE" ]] ||
      fail "$failure_case must retain candidate until snapshot is durable" || return 1
    assert_contains 'AIRVPN_PROFILE_SOURCE=static' "$(<"$CFG")" \
      "$failure_case must retain static mode" || return 1

    : > "$TEST_TMP/snapshot-retry-events"
    managed_finish_adopt apply || return 1
    first_events="$(head -n 3 "$TEST_TMP/snapshot-retry-events")"
    assert_eq "file:$PRE_MANAGED_CONF
parent:${PRE_MANAGED_CONF%/*}
unlink:$MANAGED_CANDIDATE" "$first_events" \
      "$failure_case retry must re-barrier snapshot before candidate removal" || return 1
    [[ ! -e "$MANAGED_CANDIDATE" ]] ||
      fail "$failure_case retry must remove candidate only after barriers" || return 1
    assert_contains 'AIRVPN_PROFILE_SOURCE=api' "$(<"$CFG")" \
      "$failure_case retry may select API mode only after durable snapshot"
  done
}

test_adopt_retry_rereads_snapshot_after_rebarrier() {
  local rc
  setup_managed_journal_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  chmod 600 -- "$CFG"
  AIRVPN_PROFILE_SOURCE=static
  cp -- "$WG_CONF" "$PRE_MANAGED_CONF"
  chmod 600 -- "$PRE_MANAGED_CONF"
  managed_sync_file() { :; }
  managed_sync_artifact_parent() {
    printf '# post-barrier drift\n' >> "$PRE_MANAGED_CONF"
  }
  set +e; managed_finish_adopt apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-barrier snapshot drift must fail adoption retry" || return 1
  [[ -f "$MANAGED_CANDIDATE" ]] ||
    fail "post-barrier drift must preserve candidate evidence" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=static' "$(<"$CFG")" \
    "post-barrier drift must not select API mode"
}

test_managed_config_rewrite_preserves_unrelated_keys_and_is_durable() {
  local before rc
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  CFG="$TEST_TMP/wg0.conf"
  printf '%s\n' 'MAX_AGE=222' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'QBITTORRENT_CONTAINER=qbittorrent' > "$CFG"
  chmod 600 -- "$CFG"
  owner_mode() { printf '0:%s\n' "$(stat -c '%a' -- "$1")"; }
  managed_sync_file() { printf 'file\n' >> "$TEST_TMP/sync"; }
  managed_sync_directory() { printf 'directory\n' >> "$TEST_TMP/sync"; }
  : > "$TEST_TMP/sync"
  managed_rewrite_profile_source api || return 1
  assert_eq $'MAX_AGE=222\nAIRVPN_PROFILE_SOURCE=api\nAIRVPN_DEVICE=Device-One\nQBITTORRENT_CONTAINER=qbittorrent' \
    "$(<"$CFG")" "mode rewrite must preserve every unrelated valid setting" || return 1
  assert_eq $'file\nfile\ndirectory' "$(<"$TEST_TMP/sync")" \
    "mode rewrite must sync temporary/final bytes and parent" || return 1
  before="$(<"$CFG")"
  set +e; managed_rewrite_profile_source invalid >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "mode rewrite must reject unknown sources" || return 1
  assert_eq "$before" "$(<"$CFG")" "failed mode rewrite must preserve config"
}

test_config_rewrite_refuses_untrusted_parent_before_mutation() {
  local case_name rc before real_parent
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  real_parent="$TEST_TMP/healthcheck.d"
  mkdir -p -- "$real_parent"
  chmod 700 -- "$real_parent"
  CFG="$real_parent/wg0.conf"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_COUNTRIES=GB' > "$CFG"
  chmod 600 -- "$CFG"
  before="$(<"$CFG")"
  : > "$TEST_TMP/config-events"
  managed_sync_file() { printf 'sync-file\n' >> "$TEST_TMP/config-events"; }
  managed_sync_directory() { printf 'sync-parent\n' >> "$TEST_TMP/config-events"; }
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
        printf '0:%s\n' "$(stat -c '%a' -- "$1")"
      fi
    }
    : > "$TEST_TMP/config-events"
    set +e; managed_rewrite_profile_source api >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name config parent must be rejected" || return 1
    assert_eq "$before" "$(<"$real_parent/wg0.conf")" \
      "$case_name refusal must preserve config bytes" || return 1
    assert_eq '' "$(<"$TEST_TMP/config-events")" \
      "$case_name refusal must precede temporary/final sync" || return 1
    rm -f -- "$TEST_TMP/linked-healthcheck.d"
  done
}

test_config_rewrite_rechecks_parent_before_and_after_commit() {
  local rc
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  mkdir -p -- "$TEST_TMP/healthcheck.d"
  chmod 700 -- "$TEST_TMP/healthcheck.d"
  CFG="$TEST_TMP/healthcheck.d/wg0.conf"
  printf '%s\n' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_COUNTRIES=GB' > "$CFG"
  chmod 600 -- "$CFG"
  CONFIG_PARENT_UNSAFE=0
  owner_mode() {
    if [[ "$1" == "${CFG%/*}" ]]; then
      [[ "$CONFIG_PARENT_UNSAFE" == 0 ]] && printf '0:700\n' || printf '0:770\n'
    else
      printf '0:%s\n' "$(stat -c '%a' -- "$1")"
    fi
  }
  managed_sync_file() {
    [[ "$1" == "$CFG" ]] || CONFIG_PARENT_UNSAFE=1
  }
  managed_sync_directory() { :; }
  set +e; managed_rewrite_profile_source api >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "parent trust loss before rename must fail" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=static' "$(<"$CFG")" \
    "pre-rename trust loss must preserve original config" || return 1

  CONFIG_PARENT_UNSAFE=0
  managed_sync_file() { :; }
  managed_sync_directory() { CONFIG_PARENT_UNSAFE=1; }
  set +e; managed_rewrite_profile_source api >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "parent trust loss after final barrier must fail" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=api' "$(<"$CFG")" \
    "post-barrier trust loss occurs only after an atomic config commit"
}

test_adopt_dry_run_and_apply_pin_identity_snapshot_without_network_mutation() {
  local active_before cfg_before candidate_before rc
  setup_managed_journal_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'MAX_AGE=180' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB NL' > "$CFG"
  chmod 600 -- "$CFG"
  active_before="$(<"$WG_CONF")"; cfg_before="$(<"$CFG")"; candidate_before="$(<"$MANAGED_CANDIDATE")"
  : > "$TEST_TMP/local-effects"
  managed_docker_command() { printf 'docker\n' >> "$TEST_TMP/local-effects"; return 1; }
  run_wg_quick_down() { printf 'down\n' >> "$TEST_TMP/local-effects"; return 1; }
  run_wg_quick_up() { printf 'up\n' >> "$TEST_TMP/local-effects"; return 1; }
  managed_finish_adopt dry-run || return 1
  assert_eq "$active_before" "$(<"$WG_CONF")" "adopt dry-run must preserve active profile" || return 1
  assert_eq "$cfg_before" "$(<"$CFG")" "adopt dry-run must preserve mode config" || return 1
  [[ ! -e "$PRE_MANAGED_CONF" && ! -L "$PRE_MANAGED_CONF" ]] ||
    fail "adopt dry-run must not create a snapshot" || return 1
  assert_eq '' "$(<"$TEST_TMP/local-effects")" "adopt dry-run must have zero Docker/network effects" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "adopt dry-run must durably remove its generated candidate" || return 1

  write_managed_candidate_fixture
  managed_finish_adopt apply || return 1
  assert_eq "$active_before" "$(<"$WG_CONF")" "adoption must never install generated peer material" || return 1
  assert_eq "$active_before" "$(<"$PRE_MANAGED_CONF")" "adoption snapshot must be exact" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=api' "$(<"$CFG")" "adoption apply must enable API mode last" || return 1
  assert_eq '' "$(<"$TEST_TMP/local-effects")" "adoption apply must not bounce tunnel or Docker" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] ||
    fail "adoption apply must remove the generated candidate" || return 1

  printf '%s\n' "$candidate_before" > "$MANAGED_CANDIDATE"
  sed -i 's/AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=/AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=/' "$MANAGED_CANDIDATE"
  chmod 600 -- "$MANAGED_CANDIDATE"
  rm -f -- "$PRE_MANAGED_CONF"
  managed_rewrite_profile_source static || return 1
  set +e; managed_finish_adopt apply >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "adoption identity mismatch must fail" || return 1
  [[ ! -e "$PRE_MANAGED_CONF" ]] || fail "identity mismatch must not create a snapshot" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=static' "$(<"$CFG")" \
    "identity mismatch must leave static mode selected" || return 1
  assert_eq '' "$(<"$TEST_TMP/local-effects")" "identity mismatch must precede every local effect"
}

test_provision_and_adopt_commands_run_authenticated_redacted_flows() {
  local credential_fd output rc provider_calls
  setup_managed_journal_fixture || return 1
  PRE_MANAGED_CONF="${WG_CONF}.pre-managed"
  CFG="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' 'MAX_AGE=180' 'AIRVPN_PROFILE_SOURCE=static' 'AIRVPN_DEVICE=Device-One' \
    'AIRVPN_COUNTRIES=GB NL' > "$CFG"
  chmod 600 -- "$CFG"
  AIRVPN_PROFILE_SOURCE=static
  AIRVPN_DEVICE=Device-One
  AIRVPN_COUNTRIES='GB NL'
  AIRVPN_WG_PORT=1637
  AIRVPN_API_TIMEOUT=20
  AIRVPN_ROTATE_ENABLED=1
  AIRVPN_API_KEY_FILE="$TEST_TMP/etc/wireguard/healthcheck.d/wg0.api-key"
  mkdir -p -- "${AIRVPN_API_KEY_FILE%/*}"
  chmod 700 -- "${AIRVPN_API_KEY_FILE%/*}"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  chmod 600 -- "$AIRVPN_API_KEY_FILE"
  CREDENTIAL_FD=''
  : > "$TEST_TMP/provider-calls"
  managed_generate_candidate_provider() {
    local fd="${1:?}"
    printf 'provider:%s:%s:%s:%s\n' "$MANAGED_PROFILE_OPERATION" "$fd" \
      "$AIRVPN_DEVICE" "$AIRVPN_COUNTRIES" >> "$TEST_TMP/provider-calls"
    write_managed_candidate_fixture
    MANAGED_PROFILE_SERVER=Candidate
    MANAGED_PROFILE_ENDPOINT=198.51.100.20:1637
    MANAGED_PROFILE_MANIFEST=$'generated\tCandidate\t198.51.100.20:1637\tpinned=1'
  }
  managed_run_authenticated_attempt() {
    local callback="$3" downstream="$4" callback_rc
    "$callback" "$2"; callback_rc=$?
    [[ -z "$2" ]] || close_private_fd "$2"
    (( callback_rc == 0 )) || return "$callback_rc"
    "$downstream"
  }
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"

  rm -f -- "$WG_CONF" "$MANAGED_CANDIDATE"
  AIRVPN_DEVICE='Proposed Device'
  AIRVPN_COUNTRIES='NZ AU'
  exec {credential_fd}<"$TEST_TMP/credential"
  output="$(managed_command_provision dry-run "$credential_fd")" || return 1
  assert_eq $'generated\tCandidate\t198.51.100.20:1637\tpinned=1' "$output" \
    "provision dry-run must print only the provider's redacted manifest" || return 1
  [[ ! -e "$WG_CONF" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "provision dry-run must leave no profile or candidate" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=static' "$(<"$CFG")" \
    "provision dry-run must not change mode" || return 1
  assert_contains 'provider:provision:' "$(<"$TEST_TMP/provider-calls")" \
    "provision dry-run must reach the managed owner" || return 1
  assert_contains ':Proposed Device:NZ AU' "$(<"$TEST_TMP/provider-calls")" \
    "managed selection must consume the proposed in-memory device/country overlay" || return 1
  assert_contains 'AIRVPN_DEVICE=Device-One' "$(<"$CFG")" \
    "proposed device must never persist during validation" || return 1
  assert_contains 'AIRVPN_COUNTRIES=GB NL' "$(<"$CFG")" \
    "proposed country policy must never persist during validation" || return 1

  AIRVPN_DEVICE=Device-One
  AIRVPN_COUNTRIES='GB NL'
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  output="$(managed_command_provision apply "$credential_fd")" || return 1
  assert_contains 'generated' "$output" "provision apply may print only a redacted manifest" || return 1
  [[ -f "$WG_CONF" && ! -L "$WG_CONF" ]] || fail "provision apply must install a profile" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=api' "$(<"$CFG")" \
    "provision apply must select API mode after installation" || return 1
  [[ ! -e "$PRE_MANAGED_CONF" ]] || fail "first provision must never create an adoption snapshot" || return 1

  : > "$TEST_TMP/provider-calls"
  exec {credential_fd}<"$TEST_TMP/credential"
  set +e; managed_command_provision dry-run "$credential_fd" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "provision must refuse an existing profile before provider access" || return 1
  assert_eq '' "$(<"$TEST_TMP/provider-calls")" "existing profile refusal must precede provider" || return 1

  managed_rewrite_profile_source static || return 1
  AIRVPN_PROFILE_SOURCE=static
  : > "$TEST_TMP/provider-calls"
  exec {credential_fd}<"$TEST_TMP/credential"
  output="$(managed_command_adopt dry-run "$credential_fd")" || return 1
  assert_contains 'pinned=1' "$output" "adopt dry-run must require pinned generation" || return 1
  [[ ! -e "$PRE_MANAGED_CONF" ]] || fail "adopt dry-run must not snapshot" || return 1
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  managed_command_adopt apply "$credential_fd" >/dev/null || return 1
  [[ -f "$PRE_MANAGED_CONF" ]] || fail "adopt apply must create its immutable snapshot" || return 1
  assert_contains 'AIRVPN_PROFILE_SOURCE=api' "$(<"$CFG")" \
    "adopt apply must select API mode" || return 1

  : > "$TEST_TMP/provider-calls"
  AIRVPN_PROFILE_SOURCE=api
  PROPOSED_SETTINGS_READY=0
  exec {credential_fd}<"$TEST_TMP/credential"
  set +e
  managed_command_adopt dry-run "$credential_fd" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" \
    "API-mode adopt dry-run must require a validated settings override" || return 1
  PROPOSED_SETTINGS_READY=1
  set +e
  managed_command_adopt dry-run '' >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" \
    "API-mode adopt dry-run must require a supplied credential override" || return 1
  assert_eq '' "$(<"$TEST_TMP/provider-calls")" \
    "incomplete replacement validation must fail before provider access" || return 1
  exec {credential_fd}<"$TEST_TMP/credential"
  output="$(managed_command_adopt dry-run "$credential_fd")" || return 1
  assert_contains 'pinned=1' "$output" \
    "API-mode adopt dry-run must validate a proposed replacement credential" || return 1
  [[ -f "$PRE_MANAGED_CONF" ]] ||
    fail "replacement validation must preserve the existing pre-managed snapshot" || return 1
  exec {credential_fd}<"$AIRVPN_API_KEY_FILE"
  set +e
  managed_command_adopt apply "$credential_fd" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "API-mode adopt apply must remain forbidden" || return 1
  provider_calls="$(<"$TEST_TMP/provider-calls")"
  assert_eq 1 "$(wc -l < "$TEST_TMP/provider-calls")" \
    "forbidden API-mode adopt apply must fail before provider access" || return 1
  assert_contains 'provider:adopt:' "$provider_calls" \
    "adopt and replacement validation must run the authenticated owner"
}
