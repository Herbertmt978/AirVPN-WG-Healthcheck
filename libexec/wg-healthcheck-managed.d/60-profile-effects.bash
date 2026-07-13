managed_live_interface_address() {
  local wgmanaged_raw wgmanaged_addresses
  wgmanaged_raw="$(ip -o -4 address show dev "$IFACE" scope global 2>/dev/null)" || return 1
  wgmanaged_addresses="$(awk '$3 == "inet" {print $4}' <<< "$wgmanaged_raw")" || return 1
  [[ -n "$wgmanaged_addresses" &&
     "$wgmanaged_addresses" != *$'\r'* &&
     "$wgmanaged_addresses" != *$'\n'* ]] || return 1
  printf '%s\n' "$wgmanaged_addresses"
}

managed_live_peer_public_key() {
  local wgmanaged_peer
  wgmanaged_peer="$(wg show "$IFACE" peers 2>/dev/null)" || return 1
  [[ "$wgmanaged_peer" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  printf '%s\n' "$wgmanaged_peer"
}

managed_verify_live_profile_identity() {
  local wgmanaged_path="${1:?}" wgmanaged_expected wgmanaged_address
  local wgmanaged_peer wgmanaged_live_address wgmanaged_live_peer
  [[ $# == 1 ]] || return 1
  managed_profile_file_is_secure "$wgmanaged_path" || return 1
  wgmanaged_expected="$(awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      interface_section=($0 ~ /^[[:space:]]*\[Interface\][[:space:]]*$/)
      peer_section=($0 ~ /^[[:space:]]*\[Peer\][[:space:]]*$/)
      next
    }
    interface_section && /^[[:space:]]*Address[[:space:]]*=/ {
      address=$0; sub(/^[^=]*=/, "", address)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", address); address_count++
    }
    peer_section && /^[[:space:]]*PublicKey[[:space:]]*=/ {
      peer=$0; sub(/^[^=]*=/, "", peer)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", peer); peer_count++
    }
    END {
      if (address_count != 1 || peer_count != 1) exit 1
      printf "%s\t%s\n", address, peer
    }
  ' "$wgmanaged_path")" || return 1
  [[ -n "$wgmanaged_expected" &&
     "$wgmanaged_expected" != *$'\r'* &&
     "$wgmanaged_expected" != *$'\n'* ]] || return 1
  IFS=$'\t' read -r wgmanaged_address wgmanaged_peer <<< "$wgmanaged_expected" || return 1
  [[ "$wgmanaged_address" == */32 &&
     "$wgmanaged_peer" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  validate_ip_address "${wgmanaged_address%/32}" || return 1
  wgmanaged_live_address="$(managed_live_interface_address)" || return 1
  wgmanaged_live_peer="$(managed_live_peer_public_key)" || return 1
  [[ "$wgmanaged_live_address" == "$wgmanaged_address" &&
     "$wgmanaged_live_peer" == "$wgmanaged_peer" ]]
}

managed_profile_move() {
  command mv -fT -- "${1:?}" "${2:?}"
}

managed_profile_move_noclobber() {
  command mv -nT -- "${1:?}" "${2:?}"
}

managed_copy_profile_bytes() {
  command cp -- "${1:?}" "${2:?}"
}

managed_profile_copy_paths_are_fixed() {
  local wgmanaged_source="${1:?}" wgmanaged_destination="${2:?}"
  local wgmanaged_backup="${WG_CONF}.bak-healthcheck"
  if [[ "$wgmanaged_source" == "$WG_CONF" &&
        "$wgmanaged_destination" == "$wgmanaged_backup" ]]; then
    return 0
  fi
  if [[ "$wgmanaged_source" == "$wgmanaged_backup" &&
        "$wgmanaged_destination" == "$WG_CONF" ]]; then
    return 0
  fi
  [[ "$wgmanaged_source" == "$MANAGED_CANDIDATE" &&
     "$wgmanaged_destination" == "$WG_CONF" ]]
}

managed_install_profile_atomically() {
  local wgmanaged_source="${1:?}" wgmanaged_destination="${2:?}"
  local wgmanaged_expected_digest="${3:?}" wgmanaged_expected_endpoint="${4:?}"
  local wgmanaged_parent wgmanaged_base wgmanaged_temporary wgmanaged_metadata
  [[ $# == 4 ]] || return 1
  managed_transaction_context_is_safe || return 1
  managed_profile_copy_paths_are_fixed "$wgmanaged_source" "$wgmanaged_destination" ||
    return 1
  managed_journal_parent_is_secure || return 1
  wgmanaged_parent="${WG_CONF%/*}"
  [[ "${wgmanaged_source%/*}" == "$wgmanaged_parent" &&
     "${wgmanaged_destination%/*}" == "$wgmanaged_parent" ]] || return 1
  managed_verify_profile_binding "$wgmanaged_source" "$wgmanaged_expected_digest" \
    "$wgmanaged_expected_endpoint" || return 1
  if [[ -e "$wgmanaged_destination" || -L "$wgmanaged_destination" ]]; then
    managed_profile_file_is_secure "$wgmanaged_destination" || return 1
  fi
  wgmanaged_base="${wgmanaged_destination##*/}"
  wgmanaged_temporary="$(mktemp "$wgmanaged_parent/.${wgmanaged_base}.profile.XXXXXX")" ||
    return 1
  if ! chmod 600 -- "$wgmanaged_temporary" ||
      ! { (( EUID != 0 )) || chown 0:0 -- "$wgmanaged_temporary"; } ||
      ! managed_copy_profile_bytes "$wgmanaged_source" "$wgmanaged_temporary" ||
      ! chmod 600 -- "$wgmanaged_temporary" ||
      ! { (( EUID != 0 )) || chown 0:0 -- "$wgmanaged_temporary"; }; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  wgmanaged_metadata="$(owner_mode "$wgmanaged_temporary")" || {
    rm -f -- "$wgmanaged_temporary"
    return 1
  }
  if [[ "$wgmanaged_metadata" != 0:600 ]] ||
      ! managed_verify_profile_binding "$wgmanaged_temporary" \
        "$wgmanaged_expected_digest" "$wgmanaged_expected_endpoint" ||
      ! managed_sync_file "$wgmanaged_temporary" ||
      ! managed_profile_move "$wgmanaged_temporary" "$wgmanaged_destination"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  wgmanaged_temporary=''
  managed_verify_profile_binding "$wgmanaged_destination" \
    "$wgmanaged_expected_digest" "$wgmanaged_expected_endpoint" || return 1
  managed_sync_file "$wgmanaged_destination" || return 1
  managed_sync_artifact_parent "$wgmanaged_parent"
}

managed_profiles_are_identical() {
  local wgmanaged_first="${1:?}" wgmanaged_second="${2:?}"
  managed_profile_file_is_secure "$wgmanaged_first" || return 1
  managed_profile_file_is_secure "$wgmanaged_second" || return 1
  command cmp -s -- "$wgmanaged_first" "$wgmanaged_second"
}

managed_prepare_profile_backup() {
  local transaction_active_digest transaction_active_digest_again transaction_old_endpoint
  local wgmanaged_backup="${WG_CONF}.bak-healthcheck"
  managed_sha256_file transaction_active_digest "$WG_CONF" || return 1
  transaction_old_endpoint="$(configured_endpoint "$WG_CONF")" || return 1
  managed_sha256_file transaction_active_digest_again "$WG_CONF" || return 1
  [[ "$transaction_active_digest" == "$transaction_active_digest_again" ]] || return 1
  managed_install_profile_atomically "$WG_CONF" "$wgmanaged_backup" \
    "$transaction_active_digest" "$transaction_old_endpoint" || return 1
  managed_profiles_are_identical "$WG_CONF" "$wgmanaged_backup"
}

managed_ensure_interface_down() {
  if interface_exists; then
    run_wg_quick_down || return 1
    ! interface_exists
  fi
}

managed_ensure_interface_up() {
  ! interface_exists || return 1
  run_wg_quick_up || return 1
  interface_exists
}

managed_verify_profile_network() {
  local wgmanaged_path="${1:?}" wgmanaged_endpoint="${2:?}"
  local wgmanaged_verify_speed="${3:-0}"
  [[ $# == 3 && ( "$wgmanaged_verify_speed" == 0 || "$wgmanaged_verify_speed" == 1 ) ]] ||
    return 1
  managed_verify_live_profile_identity "$wgmanaged_path" || return 1
  verify_tunnel "$wgmanaged_endpoint" || return 1
  [[ "$wgmanaged_verify_speed" == 0 ]] || verify_post_rotation_speed
}

managed_unlink_path() {
  command rm -f -- "${1:?}"
}

managed_remove_candidate_durable() {
  local transaction_candidate_class wgmanaged_parent="${WG_CONF%/*}"
  managed_classify_candidate_profile transaction_candidate_class \
    "$MANAGED_JOURNAL_CANDIDATE_SHA256" || return 1
  case "$transaction_candidate_class" in
    missing) return 0 ;;
    present)
      managed_verify_profile_binding "$MANAGED_CANDIDATE" \
        "$MANAGED_JOURNAL_CANDIDATE_SHA256" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" ||
        return 1
      managed_unlink_path "$MANAGED_CANDIDATE" || return 1
      managed_sync_artifact_parent "$wgmanaged_parent"
      ;;
    *) return 1 ;;
  esac
}

managed_remove_pending_journal_durable() {
  local wgmanaged_parent
  if [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]]; then
    return 0
  fi
  managed_journal_load || return 1
  wgmanaged_parent="${ROTATION_PENDING%/*}"
  managed_unlink_path "$ROTATION_PENDING" || return 1
  managed_sync_journal_parent "$wgmanaged_parent"
}

managed_remove_safety_candidate_durable() {
  local transaction_candidate_class wgmanaged_parent="${WG_CONF%/*}"
  managed_classify_candidate_profile transaction_candidate_class \
    "$MANAGED_SAFETY_CANDIDATE_SHA256" || return 1
  case "$transaction_candidate_class" in
    missing) return 0 ;;
    present)
      managed_verify_profile_binding "$MANAGED_CANDIDATE" \
        "$MANAGED_SAFETY_CANDIDATE_SHA256" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" ||
        return 1
      managed_unlink_path "$MANAGED_CANDIDATE" || return 1
      managed_sync_artifact_parent "$wgmanaged_parent"
      ;;
    *) return 1 ;;
  esac
}

managed_remove_safety_durable() {
  local wgmanaged_parent="${MANAGED_SAFETY%/*}"
  if [[ ! -e "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" ]]; then
    return 0
  fi
  managed_safety_file_is_secure || return 1
  managed_unlink_path "$MANAGED_SAFETY" || return 1
  managed_sync_safety_parent "$wgmanaged_parent"
}

managed_journal_matches_safety() {
  local wgmanaged_expected_qb
  managed_journal_load || return 1
  case "$MANAGED_SAFETY_QB_INTENT" in
    running) wgmanaged_expected_qb=1 ;;
    stopped|unmanaged) wgmanaged_expected_qb=0 ;;
    *) return 1 ;;
  esac
  [[ "$MANAGED_JOURNAL_BACKUP_SHA256" == "$MANAGED_SAFETY_BACKUP_SHA256" &&
     "$MANAGED_JOURNAL_CANDIDATE_SHA256" == "$MANAGED_SAFETY_CANDIDATE_SHA256" &&
     "$MANAGED_JOURNAL_OLD_ENDPOINT" == "$MANAGED_SAFETY_OLD_ENDPOINT" &&
     "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" == "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" &&
     "$MANAGED_JOURNAL_QB_WAS_RUNNING" == "$wgmanaged_expected_qb" ]] || return 1
  _managed_journal_recovery_state_is_consistent
}

managed_contain_configured_qb() {
  local qb_inspection qb_observed_id qb_observed_state
  [[ -n "${QBITTORRENT_CONTAINER-}" ]] || return 0
  validate_managed_container_name "$QBITTORRENT_CONTAINER" || return 1
  MANAGED_QB_CHECKPOINT=contain-current
  managed_docker_stop_name "$QBITTORRENT_CONTAINER" || return 1
  managed_docker_inspect_name qb_inspection "$QBITTORRENT_CONTAINER" || return 1
  managed_qb_parse_inspection qb_observed_id qb_observed_state "$qb_inspection" || return 1
  [[ "$qb_observed_state" == stopped ]]
}

managed_rollback_failure() {
  local wgmanaged_reason="${1:-managed_profile_rollback_failed}"
  if managed_safety_memory_is_valid >/dev/null 2>&1; then
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
  else
    managed_contain_configured_qb >/dev/null 2>&1 || true
  fi
  write_status failed "$wgmanaged_reason" || true
  log "Managed-profile rollback is incomplete; recovery state was retained"
  return 1
}

managed_rollback_profile_transaction() {
  local wgmanaged_cleanup_allowed="${1:-1}"
  [[ $# -le 1 && ( "$wgmanaged_cleanup_allowed" == 0 || "$wgmanaged_cleanup_allowed" == 1 ) ]] ||
    return 1
  managed_transaction_context_is_safe || return 1
  managed_safety_load_record || {
    managed_rollback_failure invalid_managed_rotation_safety_or_permissions
    return 1
  }
  [[ "$MANAGED_SAFETY_STATE" == pending ]] || {
    managed_rollback_failure managed_rotation_not_pending
    return 1
  }
  managed_qb_contain_recorded_and_current || {
    managed_rollback_failure managed_rotation_qb_stop_failed
    return 1
  }
  managed_safety_artifacts_are_valid || {
    managed_rollback_failure managed_rotation_digest_or_artifact_mismatch
    return 1
  }
  if [[ -e "$ROTATION_PENDING" || -L "$ROTATION_PENDING" ]]; then
    managed_journal_matches_safety || {
      managed_rollback_failure managed_rotation_digest_or_artifact_mismatch
      return 1
    }
  fi
  managed_verify_profile_binding "${WG_CONF}.bak-healthcheck" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || {
    managed_rollback_failure managed_rotation_backup_revalidation_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-before-down || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_ensure_interface_down || {
    managed_rollback_failure managed_rotation_candidate_down_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-after-down || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_verify_profile_binding "${WG_CONF}.bak-healthcheck" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || {
    managed_rollback_failure managed_rotation_backup_revalidation_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-before-install || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_install_profile_atomically "${WG_CONF}.bak-healthcheck" "$WG_CONF" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || {
    managed_rollback_failure managed_rotation_backup_restore_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-after-install || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_profiles_are_identical "${WG_CONF}.bak-healthcheck" "$WG_CONF" || {
    managed_rollback_failure managed_rotation_backup_byte_comparison_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-before-up || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_ensure_interface_up || {
    managed_rollback_failure managed_rotation_old_tunnel_start_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-after-up || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-before-network || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_OLD_ENDPOINT" 0 || {
    managed_rollback_failure managed_rotation_old_network_verification_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-after-network || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-pre-cleanup || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  if [[ "$wgmanaged_cleanup_allowed" == 0 ]]; then
    managed_rollback_failure managed_rotation_exclusion_not_durable
    return 1
  fi
  managed_verify_profile_binding "$WG_CONF" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || {
    managed_rollback_failure managed_rotation_restored_profile_changed
    return 1
  }
  managed_profiles_are_identical "${WG_CONF}.bak-healthcheck" "$WG_CONF" || {
    managed_rollback_failure managed_rotation_restored_bytes_changed
    return 1
  }
  managed_remove_safety_candidate_durable || {
    managed_rollback_failure managed_rotation_candidate_cleanup_failed
    return 1
  }
  managed_remove_pending_journal_durable || {
    managed_rollback_failure managed_rotation_marker_cleanup_failed
    return 1
  }
  managed_qb_containment_checkpoint rollback-post-cleanup || {
    managed_rollback_failure managed_rotation_qb_checkpoint_failed
    return 1
  }
  managed_verify_profile_binding "$WG_CONF" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || {
    managed_rollback_failure managed_rotation_restored_profile_changed
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_OLD_ENDPOINT" 0 || {
    managed_rollback_failure managed_rotation_old_network_verification_failed
    return 1
  }
  managed_qb_restore_recorded_intent || {
    managed_rollback_failure managed_rotation_qb_restore_or_binding_failed
    return 1
  }
  # Bookkeeping is deliberately outside the rollback commit boundary. Re-prove every
  # postcondition after it so no arbitrary status I/O sits between proof and safety unlink.
  write_status recovered managed_profile_rollback_verified || true
  managed_verify_profile_binding "$WG_CONF" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || {
    managed_rollback_failure managed_rotation_restored_profile_changed
    return 1
  }
  managed_verify_profile_network "$WG_CONF" "$MANAGED_SAFETY_OLD_ENDPOINT" 0 || {
    managed_rollback_failure managed_rotation_old_network_verification_failed
    return 1
  }
  managed_qb_verify_recorded_intent rollback-final-proof || {
    managed_rollback_failure managed_rotation_qb_restore_or_binding_failed
    return 1
  }
  managed_remove_safety_durable || {
    managed_rollback_failure managed_rotation_safety_cleanup_failed
    return 1
  }
  RECONCILED_PENDING=1
  log "Managed-profile rollback verified at $MANAGED_SAFETY_OLD_ENDPOINT"
}
