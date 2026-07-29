#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_pending_rollback_never_writes_or_removes_rotation_success_stamp() {
  local rc original_mtime
  for stamp_shape in absent existing; do
    (
      setup_managed_transaction_fixture || exit 1
      if [[ "$stamp_shape" == existing ]]; then
        printf 'historic-stamp\n' > "$ROTATE_STAMP"
        touch -d '@500' "$ROTATE_STAMP"
        original_mtime="$(stat -c '%Y' "$ROTATE_STAMP")" || exit 1
      fi
      TRANSACTION_FAIL_ACTION=marker-delete
      TRANSACTION_FAIL_REMAINING=1
      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$stamp_shape precommit failure must roll back" || exit 1
      if [[ "$stamp_shape" == absent ]]; then
        [[ ! -e "$ROTATE_STAMP" ]] ||
          fail "rollback must not create a rotation-success stamp" || exit 1
      else
        assert_eq historic-stamp "$(<"$ROTATE_STAMP")" \
          "rollback must preserve existing stamp bytes" || exit 1
        assert_eq "$original_mtime" "$(stat -c '%Y' "$ROTATE_STAMP")" \
          "rollback must preserve existing stamp mtime" || exit 1
      fi
    ) || return 1
  done
}

test_rollback_status_seam_cannot_reopen_qb_before_safety_removal() {
  local rc
  setup_amended_recovery_shape pending absent candidate present stopped || return 1
  write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" stopped
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  ROLLBACK_STATUS_SAFETY_STATE=''
  write_status() {
    if [[ "${1-}" == recovered && "${2-}" == managed_profile_rollback_verified ]]; then
      ROLLBACK_STATUS_SAFETY_STATE=absent
      [[ ! -f "$MANAGED_SAFETY" ]] ||
        ROLLBACK_STATUS_SAFETY_STATE="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
      printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
    fi
    return 0
  }

  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "external restart from the rollback status seam must fail contained" || return 1
  assert_eq pending "$ROLLBACK_STATUS_SAFETY_STATE" \
    "best-effort rollback status must run while pending safety still owns final proof" || return 1
  [[ -f "$MANAGED_SAFETY" ]] || fail "failed final qB proof must retain pending safety" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "status-seam restart must be contained before safety removal" || return 1
  [[ ! -e "$ROTATE_STAMP" ]] || fail "failed rollback proof must not create a success stamp"
}

test_pending_safety_creation_barriers_reclassify_the_visible_owner() {
  local barrier rc
  for barrier in temp-sync move final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_safety_move | sed '1s/managed_safety_move/transaction_original_safety_move/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      SAFETY_BARRIER_USED=0
      managed_sync_file() {
        local path="${1:?}" state=''
        [[ ! -f "$path" ]] || state="$(sed -n 's/^state=//p' "$path")"
        if (( SAFETY_BARRIER_USED == 0 )) && {
          [[ "$barrier" == temp-sync && "$path" == *'.safety-healthcheck.tmp.'* && "$state" == pending ]] ||
          [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" && "$state" == pending ]]
        }; then
          SAFETY_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_file "$path"
      }
      managed_safety_move() {
        local source="${1:?}" destination="${2:?}" state
        state="$(sed -n 's/^state=//p' "$source")" || return 1
        if [[ "$barrier" == move && "$state" == pending && "$SAFETY_BARRIER_USED" == 0 ]]; then
          SAFETY_BARRIER_USED=1
          return 1
        fi
        transaction_original_safety_move "$source" "$destination"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}" state=''
        [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
        if [[ "$barrier" == parent-sync && "$state" == pending && "$SAFETY_BARRIER_USED" == 0 ]]; then
          SAFETY_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$barrier pending safety barrier must fail the candidate transaction" || exit 1
      assert_eq 1 "$SAFETY_BARRIER_USED" "$barrier safety barrier must be exercised exactly once" || exit 1
      assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
        "$barrier safety failure must retain or restore the old profile" || exit 1
      [[ ! -e "$ROTATION_PENDING" ]] || fail "$barrier safety failure must not leave an orphan journal" || exit 1
      [[ ! -e "$ROTATE_STAMP" ]] || fail "$barrier pending failure must not write a success stamp" || exit 1
      if [[ "$barrier" == temp-sync || "$barrier" == move ]]; then
        [[ ! -e "$MANAGED_SAFETY" && -f "$MANAGED_CANDIDATE" ]] ||
          fail "$barrier must fail before exposing a safety owner or consuming the staged candidate" || exit 1
      else
        [[ ! -e "$MANAGED_SAFETY" && ! -e "$MANAGED_CANDIDATE" ]] ||
          fail "$barrier visible pending owner must drive complete rollback cleanup" || exit 1
      fi
      assert_eq running "$TRANSACTION_QB_STATE" \
        "$barrier pre-mutation failure or verified rollback must preserve running intent"
    ) || return 1
  done
}

test_visible_pending_safety_requires_successful_rebarrier_before_recovery_effects() {
  local barrier rc
  for barrier in final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      setup_managed_crash_shape verified candidate present candidate 1 || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      PERSISTENT_BARRIER_CALLS=0
      managed_sync_file() {
        local path="${1:?}"
        transaction_original_sync_file "$path" || return 1
        if [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" &&
              "$(sed -n 's/^state=//p' "$path")" == pending ]]; then
          PERSISTENT_BARRIER_CALLS=$((PERSISTENT_BARRIER_CALLS + 1))
          return 1
        fi
      }
      managed_sync_safety_parent() {
        local parent="${1:?}"
        transaction_original_sync_safety_parent "$parent" || return 1
        if [[ "$barrier" == parent-sync && -f "$MANAGED_SAFETY" &&
              "$(sed -n 's/^state=//p' "$MANAGED_SAFETY")" == pending ]]; then
          PERSISTENT_BARRIER_CALLS=$((PERSISTENT_BARRIER_CALLS + 1))
          return 1
        fi
      }
      : > "$TRANSACTION_EVENTS"

      set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$barrier persistent failure must fail closed" || exit 1
      (( PERSISTENT_BARRIER_CALLS >= 1 )) ||
        fail "$barrier pending owner must be re-barriered" || exit 1
      [[ -f "$MANAGED_SAFETY" ]] || fail "$barrier must retain visible safety evidence" || exit 1
      assert_eq pending "$(sed -n 's/^state=//p' "$MANAGED_SAFETY")" \
        "$barrier must retain the strict pending owner" || exit 1
      [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
        fail "$barrier must retain journal and candidate recovery evidence" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "$barrier failure must not guess at profile restoration" || exit 1
      assert_eq stopped "$TRANSACTION_QB_STATE" \
        "$barrier failure must contain qB before returning" || exit 1
      assert_contains 'qb-stop:' "$(<"$TRANSACTION_EVENTS")" \
        "$barrier failure must stop the recorded and configured qB target" || exit 1
      assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
        "$barrier must fail before network mutation" || exit 1
      assert_not_contains 'profile-move:' "$(<"$TRANSACTION_EVENTS")" \
        "$barrier must fail before profile mutation" || exit 1
    ) || return 1
  done
}

test_journal_unlink_parent_sync_failure_never_recreates_v2_marker() {
  local rc verified_writes
  setup_managed_transaction_fixture || return 1
  eval "$(declare -f managed_sync_journal_parent | sed '1s/managed_sync_journal_parent/transaction_original_sync_journal_parent/')"
  JOURNAL_UNLINK_SYNC_FAILED=0
  managed_sync_journal_parent() {
    local parent="${1:?}" state=absent
    [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
    if [[ ! -e "$ROTATION_PENDING" && "$JOURNAL_UNLINK_SYNC_FAILED" == 0 ]]; then
      JOURNAL_UNLINK_SYNC_FAILED=1
      transaction_event "marker-parent-sync-failed:safety-$state"
      return 1
    fi
    transaction_original_sync_journal_parent "$parent"
  }

  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "journal unlink parent-sync failure must fail before candidate commit" || return 1
  assert_eq 1 "$JOURNAL_UNLINK_SYNC_FAILED" "journal unlink parent-sync failure must be injected" || return 1
  assert_contains 'marker-parent-sync-failed:safety-pending' "$(<"$TRANSACTION_EVENTS")" \
    "pending safety must still own a failed journal directory sync" || return 1
  verified_writes="$(grep -cFx 'journal:verified' "$TRANSACTION_EVENTS" || true)"
  assert_eq 1 "$verified_writes" "deleted v2 marker must never be reconstructed" || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_SAFETY" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "safety-owned rollback must finish without recreating the journal" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "journal sync failure must roll back the candidate" || return 1
  assert_eq running "$TRANSACTION_QB_STATE" "verified rollback must restore qB intent" || return 1
  [[ ! -e "$ROTATE_STAMP" ]] || fail "journal sync rollback must not write a success stamp"
}

test_commit_transition_durability_reclassifies_pending_vs_committed() {
  local barrier rc
  for barrier in temp-sync final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      COMMIT_BARRIER_USED=0
      managed_sync_file() {
        local path="${1:?}" state=''
        [[ ! -f "$path" ]] || state="$(sed -n 's/^state=//p' "$path")"
        if (( COMMIT_BARRIER_USED == 0 )) && {
          [[ "$barrier" == temp-sync && "$path" == *'.safety-healthcheck.tmp.'* && "$state" == committed ]] ||
          [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" && "$state" == committed ]]
        }; then
          COMMIT_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_file "$path"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}" state=''
        [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
        if [[ "$barrier" == parent-sync && "$state" == committed && "$COMMIT_BARRIER_USED" == 0 ]]; then
          COMMIT_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$COMMIT_BARRIER_USED" "$barrier commit barrier must be exercised" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_SAFETY" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$barrier visible state must be reconciled to a complete outcome" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" "$barrier outcome must restore exact qB intent" || exit 1
      if [[ "$barrier" == temp-sync ]]; then
        assert_eq 1 "$rc" "pre-rename commit failure must remain a failed, rolled-back attempt" || exit 1
        assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
          "visible pending state must roll back" || exit 1
        [[ ! -e "$ROTATE_STAMP" ]] || fail "pending rollback must not create a success stamp" || exit 1
      else
        assert_eq 0 "$rc" "post-rename $barrier failure must finalize visible committed state" || exit 1
        assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
          "visible committed state must never roll back" || exit 1
        [[ -f "$ROTATE_STAMP" ]] || fail "committed recovery must write best-effort cooldown" || exit 1
      fi
    ) || return 1
  done
}

test_finalizing_transition_durability_never_rolls_back_committed_candidate() {
  local barrier rc
  for barrier in temp-sync final-sync parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_sync_file | sed '1s/managed_sync_file/transaction_original_sync_file/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      FINALIZING_BARRIER_USED=0
      managed_sync_file() {
        local path="${1:?}" state=''
        [[ ! -f "$path" ]] || state="$(sed -n 's/^state=//p' "$path")"
        if (( FINALIZING_BARRIER_USED == 0 )) && {
          [[ "$barrier" == temp-sync && "$path" == *'.safety-healthcheck.tmp.'* && "$state" == finalizing ]] ||
          [[ "$barrier" == final-sync && "$path" == "$MANAGED_SAFETY" && "$state" == finalizing ]]
        }; then
          FINALIZING_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_file "$path"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}" state=''
        [[ ! -f "$MANAGED_SAFETY" ]] || state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
        if [[ "$barrier" == parent-sync && "$state" == finalizing && "$FINALIZING_BARRIER_USED" == 0 ]]; then
          FINALIZING_BARRIER_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$FINALIZING_BARRIER_USED" "$barrier finalizing barrier must be exercised" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "$barrier finalizing failure must retain the committed candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" "$barrier finalizing outcome must retain qB intent" || exit 1
      [[ -f "$ROTATE_STAMP" ]] || fail "$barrier finalizing failure occurs after commit bookkeeping" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$barrier finalizing failure must not recreate precommit artifacts" || exit 1
      if [[ "$barrier" == temp-sync ]]; then
        assert_eq 1 "$rc" "pre-rename finalizing failure must retain committed owner for retry" || exit 1
        managed_safety_load || exit 1
        assert_eq committed "$MANAGED_SAFETY_STATE" \
          "pre-rename finalizing failure must leave visible committed state" || exit 1
        : > "$TRANSACTION_EVENTS"
        managed_reconcile_pending || fail "visible committed state must finalize on retry" || exit 1
        assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
          "committed retry must never enter rollback sequencing" || exit 1
      else
        assert_eq 0 "$rc" "post-rename finalizing $barrier failure must complete from visible finalizing" || exit 1
      fi
      [[ ! -e "$MANAGED_SAFETY" ]] || fail "$barrier finalizing outcome must eventually clear safety"
    ) || return 1
  done
}

test_final_safety_unlink_and_parent_sync_are_reboot_idempotent() {
  local failure rc safety_copy
  for failure in unlink parent-sync; do
    (
      setup_managed_transaction_fixture || exit 1
      eval "$(declare -f managed_unlink_path | sed '1s/managed_unlink_path/transaction_original_unlink_path/')"
      eval "$(declare -f managed_sync_safety_parent | sed '1s/managed_sync_safety_parent/transaction_original_sync_safety_parent/')"
      FINAL_SAFETY_FAILURE_USED=0
      safety_copy="$TEST_TMP/finalizing-safety-copy"
      managed_unlink_path() {
        local path="${1:?}"
        if [[ "$path" == "$MANAGED_SAFETY" ]]; then
          cp -- "$MANAGED_SAFETY" "$safety_copy" || return 1
          if [[ "$failure" == unlink && "$FINAL_SAFETY_FAILURE_USED" == 0 ]]; then
            FINAL_SAFETY_FAILURE_USED=1
            return 1
          fi
        fi
        transaction_original_unlink_path "$path"
      }
      managed_sync_safety_parent() {
        local parent="${1:?}"
        if [[ "$failure" == parent-sync && ! -e "$MANAGED_SAFETY" && "$FINAL_SAFETY_FAILURE_USED" == 0 ]]; then
          FINAL_SAFETY_FAILURE_USED=1
          return 1
        fi
        transaction_original_sync_safety_parent "$parent"
      }

      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "final safety $failure failure must report incomplete cleanup" || exit 1
      assert_eq 1 "$FINAL_SAFETY_FAILURE_USED" "final safety $failure failure must be injected" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "final safety $failure failure must retain the committed candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" \
        "final safety $failure failure must retain verified qB intent" || exit 1
      [[ -f "$ROTATE_STAMP" ]] || fail "final safety $failure occurs only after commit bookkeeping" || exit 1
      if [[ "$failure" == unlink ]]; then
        [[ -f "$MANAGED_SAFETY" ]] || fail "failed unlink must retain finalizing evidence" || exit 1
      else
        [[ ! -e "$MANAGED_SAFETY" ]] || fail "post-unlink sync failure exposes the absent outcome" || exit 1
        managed_reconcile_pending || exit 1
        cp -- "$safety_copy" "$MANAGED_SAFETY"
        chmod 600 -- "$MANAGED_SAFETY"
      fi
      : > "$TRANSACTION_EVENTS"
      managed_reconcile_pending || fail "reappeared finalizing owner must be harmlessly repeatable" || exit 1
      [[ ! -e "$MANAGED_SAFETY" ]] || fail "repeated finalization must clear the safety owner" || exit 1
      assert_eq 198.51.100.20:1637 "$(configured_endpoint "$WG_CONF")" \
        "repeated finalization must not roll back the candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" "repeated finalization must restore qB intent" || exit 1
      assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
        "committed finalization must never enter rollback network sequencing"
    ) || return 1
  done
}

test_managed_staged_digest_mismatch_is_never_installed_or_guessed() {
  local rc events
  setup_managed_transaction_fixture || return 1
  run_wg_quick_down() {
    transaction_event "wg-down:$(transaction_phase):$(configured_endpoint "$WG_CONF")"
    TRANSACTION_RUNTIME_ENDPOINT=''
    printf '# changed after tunnel-down\n' >> "$MANAGED_CANDIDATE"
  }
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-journal candidate mutation must fail" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'profile-move:' "$events" "mismatched candidate must never be installed" || return 1
  assert_event_before 'exclude-write' 'wg-down:client-stopped:192.0.2.10:1637' \
    "pre-exclusion must be durable before downtime" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "candidate mismatch must retain journal and artifact" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" "candidate mismatch must leave qB stopped" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "candidate mismatch must not guess at an active-profile mutation"
}

test_managed_rollback_failure_retains_marker_candidate_and_stopped_qb() {
  local rc events
  setup_managed_transaction_fixture || return 1
  verify_tunnel() {
    local expected="${1:?}"
    transaction_event "network:$(transaction_phase):$expected"
    if [[ "$expected" == 198.51.100.20:1637 ]]; then
      TRANSACTION_FAIL_ACTION=rollback-up
      TRANSACTION_FAIL_REMAINING=-1
      return 1
    fi
    [[ "$TRANSACTION_RUNTIME_ENDPOINT" == "$expected" ]]
  }
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "candidate and rollback failure must fail closed" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_event_before 'exclude-write' 'wg-down:candidate-up:198.51.100.20:1637' \
    "failure exclusion refresh must precede the first rollback network effect" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "rollback failure must retain marker and candidate" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" "rollback failure must leave qB stopped" || return 1
  assert_not_contains 'marker-delete:' "$events" "failed rollback must not expose a commit"
}

test_managed_exclusion_refresh_failure_rolls_back_but_preserves_pending_state() {
  local rc write_count=0 events
  setup_managed_transaction_fixture || return 1
  managed_api_state_write() {
    write_count=$((write_count + 1))
    transaction_event "exclude-write:$write_count"
    (( write_count == 1 ))
  }
  TRANSACTION_FAIL_ACTION=network
  TRANSACTION_FAIL_REMAINING=1
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "exclusion refresh failure must remain failed" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'exclude-write:2' "$events" "candidate failure must refresh its exclusion" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "safety rollback must still restore the old profile" || return 1
  [[ -f "$ROTATION_PENDING" && -f "$MANAGED_CANDIDATE" ]] ||
    fail "failed exclusion refresh must preserve pending cleanup" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" \
    "failed exclusion refresh must not restart qB while pending remains" || return 1
  assert_not_contains 'marker-delete:' "$events" "failed exclusion refresh must forbid cleanup"
}

setup_managed_crash_shape() {
  local phase="${1:?}" active_class="${2:?}" candidate_class="${3:?}"
  local runtime_class="${4:?}" qb_was_running="${5:-1}"
  managed_journal_fixture_digests || return 1
  write_raw_managed_journal "$phase" "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" 192.0.2.10:1637 198.51.100.20:1637 "$qb_was_running"
  if [[ "$qb_was_running" == 1 ]]; then
    write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" running
  else
    write_raw_managed_safety pending "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" stopped
  fi
  case "$active_class" in
    backup) command cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ;;
    candidate) command cp -- "$MANAGED_CANDIDATE" "$WG_CONF" ;;
    unknown) printf '# unknown active\n' >> "$WG_CONF" ;;
    *) return 1 ;;
  esac
  chmod 600 -- "$WG_CONF"
  case "$candidate_class" in
    present) ;;
    missing) command rm -f -- "$MANAGED_CANDIDATE" ;;
    mismatch) printf '# mismatch\n' >> "$MANAGED_CANDIDATE" ;;
    *) return 1 ;;
  esac
  case "$runtime_class" in
    old) TRANSACTION_RUNTIME_ENDPOINT=192.0.2.10:1637 ;;
    candidate) TRANSACTION_RUNTIME_ENDPOINT=198.51.100.20:1637 ;;
    down) TRANSACTION_RUNTIME_ENDPOINT='' ;;
    *) return 1 ;;
  esac
  if [[ "$qb_was_running" == 1 ]]; then
    case "$phase:$runtime_class" in
      prepared:old|verified:candidate) TRANSACTION_QB_STATE=running ;;
      *) TRANSACTION_QB_STATE=stopped ;;
    esac
  else
    TRANSACTION_QB_STATE=stopped
  fi
}

setup_amended_recovery_shape() {
  local safety_state="${1:?}" marker_shape="${2:?}" active_class="${3:?}"
  local candidate_class="${4:?}" qb_state="${5:-stopped}"
  setup_managed_transaction_fixture || return 1
  setup_immutable_docker_fake
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10
  managed_journal_fixture_digests || return 1
  write_raw_managed_safety "$safety_state" "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" running
  case "$active_class" in
    backup)
      cp -- "${WG_CONF}.bak-healthcheck" "$WG_CONF"
      TRANSACTION_RUNTIME_ENDPOINT=192.0.2.10:1637
      ;;
    candidate)
      cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
      TRANSACTION_RUNTIME_ENDPOINT=198.51.100.20:1637
      ;;
    unknown) printf '# unknown\n' >> "$WG_CONF" ;;
    *) return 1 ;;
  esac
  chmod 600 -- "$WG_CONF"
  case "$candidate_class" in
    present) ;;
    missing) rm -f -- "$MANAGED_CANDIDATE" ;;
    mismatch) printf '# mismatch\n' >> "$MANAGED_CANDIDATE" ;;
    *) return 1 ;;
  esac
  case "$marker_shape" in
    absent) rm -f -- "$ROTATION_PENDING" ;;
    matching)
      write_raw_managed_journal candidate-up "$JOURNAL_TEST_BACKUP_SHA" \
        "$JOURNAL_TEST_CANDIDATE_SHA" 192.0.2.10:1637 198.51.100.20:1637 1
      ;;
    invalid) printf 'invalid marker\n' > "$ROTATION_PENDING"; chmod 600 -- "$ROTATION_PENDING" ;;
    mismatched)
      write_raw_managed_journal candidate-up "$JOURNAL_TEST_CANDIDATE_SHA" \
        "$JOURNAL_TEST_BACKUP_SHA" 192.0.2.10:1637 198.51.100.20:1637 1
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$qb_state" > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
}

test_safety_record_drives_the_complete_recovery_classification_matrix() {
  local rc events
  setup_amended_recovery_shape pending absent candidate present stopped || return 1
  managed_reconcile_pending || fail "pending safety without journal must invoke safety-owned rollback" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "pending safety without journal must complete rollback" || return 1
  cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
    fail "pending safety without journal must restore exact backup" || return 1

  setup_amended_recovery_shape pending matching candidate present stopped || return 1
  managed_reconcile_pending || fail "pending safety with matching journal must invoke rollback" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "pending safety with matching v2 must complete rollback" || return 1

  for marker_shape in invalid mismatched; do
    setup_amended_recovery_shape pending "$marker_shape" candidate present running || return 1
    : > "$TRANSACTION_EVENTS"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "pending safety plus $marker_shape journal must fail contained" || return 1
    [[ -f "$MANAGED_SAFETY" && -f "$ROTATION_PENDING" ]] ||
      fail "$marker_shape evidence must be retained" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "$marker_shape recovery must contain qB" || return 1
    events="$(<"$TRANSACTION_EVENTS")"
    assert_not_contains 'wg-down:' "$events" "$marker_shape evidence must block network guessing" || return 1
  done

  for committed_state in committed finalizing; do
    setup_amended_recovery_shape "$committed_state" absent candidate missing running || return 1
    managed_reconcile_pending || return 1
    [[ ! -e "$MANAGED_SAFETY" ]] ||
      fail "$committed_state safety must finalize idempotently" || return 1
    assert_eq 198.51.100.20:1637 "$TRANSACTION_RUNTIME_ENDPOINT" \
      "$committed_state must retain the committed candidate" || return 1

    setup_amended_recovery_shape "$committed_state" matching candidate missing running || return 1
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$committed_state plus marker must be impossible" || return 1
    [[ -f "$MANAGED_SAFETY" && -f "$ROTATION_PENDING" ]] ||
      fail "$committed_state impossible evidence must remain" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "$committed_state impossible state must contain qB" || return 1
  done

  setup_amended_recovery_shape pending absent candidate present running || return 1
  rm -f -- "$MANAGED_SAFETY"
  write_raw_managed_journal candidate-up "$JOURNAL_TEST_BACKUP_SHA" \
    "$JOURNAL_TEST_CANDIDATE_SHA" 192.0.2.10:1637 198.51.100.20:1637 1
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "orphan v2 without safety must fail" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "orphan v2 evidence must remain" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "orphan v2 must contain qB"

  setup_amended_recovery_shape pending absent candidate present running || return 1
  rm -f -- "$MANAGED_SAFETY"
  printf 'unknown marker bytes\n' > "$ROTATION_PENDING"
  chmod 600 -- "$ROTATION_PENDING"
  : > "$TRANSACTION_EVENTS"
  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "unknown marker without safety must fail contained" || return 1
  [[ -f "$ROTATION_PENDING" ]] || fail "unknown orphan marker must remain" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "unknown orphan marker must contain configured qB" || return 1
  assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
    "unknown orphan marker must not mutate network" || return 1

  for invalid_marker in absent matching; do
    setup_amended_recovery_shape pending "$invalid_marker" candidate present running || return 1
    sed -i 's/^record=.*/record=invalid/' "$MANAGED_SAFETY"
    : > "$TRANSACTION_EVENTS"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "invalid safety plus $invalid_marker marker must fail" || return 1
    [[ -f "$MANAGED_SAFETY" ]] || fail "invalid safety evidence must remain" || return 1
    if [[ "$invalid_marker" == matching ]]; then
      [[ -f "$ROTATION_PENDING" ]] || fail "marker beside invalid safety must remain" || return 1
    fi
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "invalid safety must contain configured qB" || return 1
    assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
      "invalid safety must not mutate network" || return 1
  done

  for impossible_shape in backup-active unknown-active leftover-candidate; do
    case "$impossible_shape" in
      backup-active) setup_amended_recovery_shape committed absent backup missing running ;;
      unknown-active) setup_amended_recovery_shape committed absent unknown missing running ;;
      leftover-candidate) setup_amended_recovery_shape committed absent candidate present running ;;
    esac || return 1
    : > "$TRANSACTION_EVENTS"
    set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$impossible_shape committed state must fail contained" || return 1
    [[ -f "$MANAGED_SAFETY" ]] || fail "$impossible_shape safety evidence must remain" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "$impossible_shape must contain qB" || return 1
    assert_not_contains 'wg-down:' "$(<"$TRANSACTION_EVENTS")" \
      "$impossible_shape must not roll back or finalize by guessing" || return 1
  done
}

run_managed_recovery_in_fresh_process() {
  local runtime_file="${1:?}"
  # The quoted program is intentionally expanded only by the isolated child shell.
  # shellcheck disable=SC2016
  env -u BASH_ENV bash -c '
    set -u
    script=${1:?}; module=${2:?}; requested_wg_conf=${3:?}; runtime_file=${4:?}
    source "$script"
    source "$module"
    IFACE=wg0
    WG_CONF=$requested_wg_conf
    ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
    MANAGED_SAFETY="${WG_CONF}.safety-healthcheck"
    MANAGED_CANDIDATE="${WG_CONF%/*}/.${WG_CONF##*/}.managed-candidate"
    STATUS_FILE="${WG_CONF%/*}/wg0.status"
    ROTATE_STAMP="${WG_CONF%/*}/wg0.last_rotate"
    CONTEXT_LOCKED=1
    MANAGED_API_LOCK_FD=
    QBITTORRENT_CONTAINER=
    QBITTORRENT_PROCESS_NAME=qbittorrent-nox
    QBITTORRENT_LISTEN_IP=
    QBITTORRENT_LISTEN_PORT=
    QBITTORRENT_RESTART_DELAY=0
    QBITTORRENT_RESTART_TIMEOUT=10
    owner_mode() { printf "0:%s\n" "$(stat -c %a -- "$1")"; }
    log() { :; }
    write_status() { :; }
    write_stamp() { printf "1000\n" > "${1:?}"; }
    interface_exists() { [[ -s "$runtime_file" ]]; }
    run_wg_quick_down() { : > "$runtime_file"; }
    run_wg_quick_up() { configured_endpoint "$WG_CONF" > "$runtime_file"; }
    managed_verify_live_profile_identity() {
      [[ "$(<"$runtime_file")" == "$(configured_endpoint "${1:?}")" ]]
    }
    verify_tunnel() { [[ "$(<"$runtime_file")" == "${1:?}" ]]; }
    verify_post_rotation_speed() { return 0; }
    managed_reconcile_pending
  ' fresh-recovery "$SCRIPT" "$MODULE" "$WG_CONF" "$runtime_file"
}

test_fresh_process_recovery_uses_only_visible_safety_state() {
  local state runtime_file
  for state in pending committed finalizing; do
    setup_managed_journal_fixture || return 1
    managed_journal_fixture_digests || return 1
    runtime_file="$TEST_TMP/runtime-endpoint"
    cp -- "$MANAGED_CANDIDATE" "$WG_CONF"
    chmod 600 -- "$WG_CONF"
    printf '198.51.100.20:1637\n' > "$runtime_file"
    rm -f -- "$ROTATION_PENDING"
    if [[ "$state" != pending ]]; then
      rm -f -- "$MANAGED_CANDIDATE"
    fi
    write_raw_managed_safety "$state" "$JOURNAL_TEST_BACKUP_SHA" \
      "$JOURNAL_TEST_CANDIDATE_SHA" unmanaged

    run_managed_recovery_in_fresh_process "$runtime_file" ||
      fail "$state recovery must succeed after re-sourcing without inherited globals" || return 1
    [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
      fail "$state fresh-process recovery must clear its durable owner" || return 1
    if [[ "$state" == pending ]]; then
      cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
        fail "fresh pending recovery must restore the exact backup" || return 1
      assert_eq 192.0.2.10:1637 "$(<"$runtime_file")" \
        "fresh pending recovery must restore the old tunnel" || return 1
    else
      assert_eq 198.51.100.20:1637 "$(<"$runtime_file")" \
        "fresh $state recovery must retain the committed candidate" || return 1
    fi
  done
}
