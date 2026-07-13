managed_preexclude_candidate() {
  local wgmanaged_server="${1:?}" wgmanaged_now
  wgmanaged_now="$(current_epoch)" || return 1
  managed_epoch_is_valid "$wgmanaged_now" || return 1
  managed_api_state_add_exclusion "$wgmanaged_server" "$wgmanaged_now" || return 1
  managed_api_state_write
}

managed_refresh_exclusion_and_rollback() {
  local wgmanaged_server="${1:?}" wgmanaged_now wgmanaged_durable=1
  wgmanaged_now="$(current_epoch)" || wgmanaged_durable=0
  if (( wgmanaged_durable == 1 )); then
    managed_epoch_is_valid "$wgmanaged_now" || wgmanaged_durable=0
  fi
  if (( wgmanaged_durable == 1 )); then
    managed_api_state_add_exclusion "$wgmanaged_server" "$wgmanaged_now" ||
      wgmanaged_durable=0
  fi
  if (( wgmanaged_durable == 1 )); then
    managed_api_state_write || wgmanaged_durable=0
  fi
  managed_rollback_profile_transaction "$wgmanaged_durable" || true
  return 1
}

managed_abort_profile_transaction() {
  local wgmanaged_candidate_failure="${1:?}" wgmanaged_server="${2-}"
  [[ $# == 2 ]] || return 1
  if [[ "$wgmanaged_candidate_failure" == 1 && -n "$wgmanaged_server" ]]; then
    managed_refresh_exclusion_and_rollback "$wgmanaged_server"
  else
    managed_rollback_profile_transaction 1 || true
    return 1
  fi
}

managed_postcommit_bookkeeping() {
  local wgmanaged_server="${1-}" wgmanaged_now
  [[ $# -le 1 ]] || return 1
  write_status recovered managed_profile_rotation_verified ||
    log "Committed candidate success status could not be updated"
  write_stamp "$ROTATE_STAMP" ||
    log "Committed candidate rotation cooldown could not be updated"
  if [[ -n "$wgmanaged_server" ]]; then
    if ! managed_server_name_is_valid "$wgmanaged_server"; then
      return 1
    fi
    wgmanaged_now="$(current_epoch)" || wgmanaged_now=''
    if [[ -n "$wgmanaged_now" ]] && managed_epoch_is_valid "$wgmanaged_now"; then
      managed_api_state_remove_exclusion "$wgmanaged_server" "$wgmanaged_now" ||
        log "Committed candidate remains conservatively excluded until expiry"
    else
      log "Committed candidate remains conservatively excluded until expiry"
    fi
  fi
}

managed_qb_ensure_recorded_intent() {
  local qb_inspection qb_observed_id qb_observed_state
  # Consumed dynamically by the Docker inspection/containment seams.
  # shellcheck disable=SC2034
  MANAGED_QB_CHECKPOINT=finalizing
  case "${MANAGED_SAFETY_QB_INTENT-}" in
    unmanaged|stopped)
      managed_qb_verify_recorded_intent finalizing
      ;;
    running)
      managed_qb_current_tuple_matches_record || {
        managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
        return 1
      }
      managed_docker_inspect_name qb_inspection "$MANAGED_SAFETY_QB_CONTAINER" || {
        managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
        return 1
      }
      managed_qb_parse_inspection qb_observed_id qb_observed_state "$qb_inspection" || {
        managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
        return 1
      }
      [[ "$qb_observed_id" == "$MANAGED_SAFETY_QB_CONTAINER_ID" ]] || {
        managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
        return 1
      }
      case "$qb_observed_state" in
        running) managed_qb_verify_recorded_intent finalizing ;;
        stopped)
          managed_qb_restore_recorded_intent &&
            managed_qb_verify_recorded_intent finalizing
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

managed_finalize_committed_transaction() {
  local wgmanaged_server="${1-}"
  [[ $# -le 1 ]] || return 1
  managed_transaction_context_is_safe || return 1
  managed_safety_load || return 1
  case "$MANAGED_SAFETY_STATE" in committed|finalizing) ;; *) return 1 ;; esac
  [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]] || {
    managed_rollback_failure managed_rotation_impossible_committed_marker
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" 0 || {
    managed_rollback_failure managed_rotation_committed_network_failed
    return 1
  }
  managed_qb_ensure_recorded_intent || {
    managed_rollback_failure managed_rotation_committed_qb_failed
    return 1
  }
  if [[ "$MANAGED_SAFETY_STATE" == committed ]]; then
    managed_postcommit_bookkeeping "$wgmanaged_server" || true
    if ! managed_safety_transition finalizing; then
      if ! managed_safety_load; then
        managed_rollback_failure managed_rotation_finalizing_state_invalid
        return 1
      fi
      [[ "$MANAGED_SAFETY_STATE" == finalizing ]] || {
        log "Committed candidate remains owned for a later finalization retry"
        return 1
      }
    fi
  fi
  managed_verify_profile_binding "$WG_CONF" \
    "$MANAGED_SAFETY_CANDIDATE_SHA256" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" || {
    managed_rollback_failure managed_rotation_final_candidate_changed
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" 0 || {
    managed_rollback_failure managed_rotation_final_network_failed
    return 1
  }
  managed_qb_verify_recorded_intent finalizing || {
    managed_rollback_failure managed_rotation_final_qb_failed
    return 1
  }
  managed_remove_safety_durable || {
    log "Committed candidate remains safe but final safety cleanup is incomplete"
    return 1
  }
  RECONCILED_PENDING=1
}

managed_resolve_commit_transition_error() {
  local wgmanaged_visible_state
  if ! managed_safety_load_record; then
    managed_contain_configured_qb >/dev/null 2>&1 || true
    write_status failed managed_rotation_commit_state_invalid || true
    return 1
  fi
  wgmanaged_visible_state="$MANAGED_SAFETY_STATE"
  case "$wgmanaged_visible_state" in
    pending)
      managed_reconcile_pending >/dev/null 2>&1 || true
      return 1
      ;;
    committed|finalizing)
      managed_reconcile_pending
      ;;
    *)
      managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
      return 1
      ;;
  esac
}

managed_profile_transaction() {
  local wgmanaged_server="${1-}" wgmanaged_verify_speed="${2-}"
  local transaction_qb_was_running transaction_candidate_digest
  local transaction_candidate_endpoint
  [[ $# == 2 ]] || return 1
  [[ -z "$wgmanaged_server" ]] || managed_server_name_is_valid "$wgmanaged_server" || return 1
  [[ "$wgmanaged_verify_speed" == 0 || "$wgmanaged_verify_speed" == 1 ]] || return 1
  managed_transaction_context_is_safe || return 1
  managed_sha256_file transaction_candidate_digest "$MANAGED_CANDIDATE" || return 1
  transaction_candidate_endpoint="$(configured_endpoint "$MANAGED_CANDIDATE")" || return 1
  managed_verify_profile_binding "$MANAGED_CANDIDATE" "$transaction_candidate_digest" \
    "$transaction_candidate_endpoint" || return 1
  managed_profiles_have_same_private_identity "$WG_CONF" || return 1
  managed_qb_snapshot || return 1
  managed_prepare_profile_backup || return 1
  managed_profiles_have_same_private_identity "${WG_CONF}.bak-healthcheck" || return 1
  if [[ -n "$wgmanaged_server" ]]; then
    managed_preexclude_candidate "$wgmanaged_server" || return 1
  fi
  if ! managed_safety_prepare; then
    if [[ -e "$MANAGED_SAFETY" || -L "$MANAGED_SAFETY" ]]; then
      managed_reconcile_pending >/dev/null 2>&1 || true
    fi
    return 1
  fi
  case "$MANAGED_SAFETY_QB_INTENT" in
    running) transaction_qb_was_running=1 ;;
    stopped|unmanaged) transaction_qb_was_running=0 ;;
    *) managed_abort_profile_transaction 0 "$wgmanaged_server"; return 1 ;;
  esac
  if ! managed_journal_prepare "$transaction_qb_was_running"; then
    managed_reconcile_pending >/dev/null 2>&1 || true
    return 1
  fi
  managed_journal_matches_safety || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  if [[ "$MANAGED_SAFETY_QB_INTENT" == running ]]; then
    managed_docker_stop_id "$MANAGED_SAFETY_QB_CONTAINER_ID" || {
      managed_abort_profile_transaction 0 "$wgmanaged_server"
      return 1
    }
  fi
  managed_qb_containment_checkpoint after-stop || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_journal_transition client-stopped || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_binding "$WG_CONF" "$MANAGED_JOURNAL_BACKUP_SHA256" \
    "$MANAGED_JOURNAL_OLD_ENDPOINT" || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint before-down || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_ensure_interface_down || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint after-down || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_journal_transition tunnel-down || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint before-install || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_binding "$MANAGED_CANDIDATE" \
    "$MANAGED_JOURNAL_CANDIDATE_SHA256" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_install_profile_atomically "$MANAGED_CANDIDATE" "$WG_CONF" \
    "$MANAGED_JOURNAL_CANDIDATE_SHA256" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint after-install || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_journal_transition candidate-installed || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint before-up || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_ensure_interface_up || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint after-up || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_journal_transition candidate-up || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint before-network || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" \
    "$wgmanaged_verify_speed" || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_containment_checkpoint after-network || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_restore_recorded_intent || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_journal_transition verified || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_binding "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_SHA256" \
    "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" 0 || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_qb_verify_recorded_intent pre-cleanup || {
    managed_abort_profile_transaction 1 "$wgmanaged_server"
    return 1
  }
  managed_remove_safety_candidate_durable || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_remove_pending_journal_durable || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_binding "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_SHA256" \
    "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" 0 || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  managed_qb_verify_recorded_intent post-cleanup || {
    managed_abort_profile_transaction 0 "$wgmanaged_server"
    return 1
  }
  if ! managed_safety_transition committed; then
    managed_resolve_commit_transition_error
    return
  fi
  managed_finalize_committed_transaction "$wgmanaged_server"
}

managed_reconcile_pending() {
  # Sourced runtime consumes this reconciliation signal after managed dispatch returns.
  # shellcheck disable=SC2034
  RECONCILED_PENDING=0
  managed_transaction_context_is_safe || return 1
  if [[ ! -e "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" ]]; then
    if [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]]; then
      return 0
    fi
    managed_contain_configured_qb >/dev/null 2>&1 || true
    write_status failed orphan_managed_rotation_journal || true
    return 1
  fi
  if ! managed_safety_load_record; then
    managed_contain_configured_qb >/dev/null 2>&1 || true
    write_status failed invalid_managed_rotation_safety_or_permissions || true
    return 1
  fi
  if ! managed_qb_contain_recorded_and_current; then
    managed_rollback_failure managed_rotation_qb_stop_failed
    return 1
  fi
  if [[ "$MANAGED_SAFETY_STATE" == pending ]] &&
      ! managed_safety_rebarrier_pending; then
    write_status failed managed_rotation_pending_safety_not_durable || true
    return 1
  fi
  if ! managed_safety_artifacts_are_valid; then
    managed_rollback_failure managed_rotation_digest_or_artifact_mismatch
    return 1
  fi
  case "$MANAGED_SAFETY_STATE" in
    pending)
      if [[ -e "$ROTATION_PENDING" || -L "$ROTATION_PENDING" ]]; then
        managed_journal_matches_safety || {
          managed_rollback_failure managed_rotation_digest_or_artifact_mismatch
          return 1
        }
      fi
      managed_rollback_profile_transaction 1
      ;;
    committed|finalizing)
      if [[ -e "$ROTATION_PENDING" || -L "$ROTATION_PENDING" ]]; then
        managed_rollback_failure managed_rotation_impossible_committed_marker
        return 1
      fi
      managed_finalize_committed_transaction
      ;;
    *)
      managed_rollback_failure invalid_managed_rotation_safety_or_permissions
      return 1
      ;;
  esac
}
