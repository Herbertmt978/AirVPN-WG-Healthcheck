managed_noclobber_paths_are_fixed() {
  local source="${1:?}" destination="${2:?}"
  [[ "$source" == "$MANAGED_CANDIDATE" && "$destination" == "$WG_CONF" ]] && return 0
  [[ "$source" == "$WG_CONF" && "$destination" == "$PRE_MANAGED_CONF" ]] && return 0
  [[ "$source" == "$PRE_MANAGED_CONF" && "$destination" == "$MANAGED_CANDIDATE" ]]
}

managed_install_profile_noclobber() {
  local source="${1:?}" destination="${2:?}" expected_digest="${3:?}"
  local expected_endpoint="${4:?}" parent base temporary metadata
  [[ $# == 4 ]] || return 1
  managed_transaction_context_is_safe || return 1
  managed_noclobber_paths_are_fixed "$source" "$destination" || return 1
  managed_journal_parent_is_secure || return 1
  parent="${WG_CONF%/*}"
  [[ "${source%/*}" == "$parent" && "${destination%/*}" == "$parent" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  managed_verify_profile_binding "$source" "$expected_digest" "$expected_endpoint" || return 1
  base="${destination##*/}"
  umask 077
  temporary="$(mktemp "$parent/.${base}.profile.XXXXXX")" || return 1
  if ! chmod 600 -- "$temporary" ||
      ! { (( EUID != 0 )) || chown 0:0 -- "$temporary"; } ||
      ! managed_copy_profile_bytes "$source" "$temporary" ||
      ! chmod 600 -- "$temporary" ||
      ! { (( EUID != 0 )) || chown 0:0 -- "$temporary"; }; then
    rm -f -- "$temporary"
    return 1
  fi
  metadata="$(owner_mode "$temporary")" || {
    rm -f -- "$temporary"
    return 1
  }
  if [[ "$metadata" != 0:600 ]] ||
      ! managed_verify_profile_binding "$temporary" "$expected_digest" "$expected_endpoint" ||
      ! managed_sync_file "$temporary" ||
      ! managed_profile_move_noclobber "$temporary" "$destination" ||
      [[ -e "$temporary" || -L "$temporary" ]]; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! managed_verify_profile_binding "$destination" "$expected_digest" "$expected_endpoint" ||
      ! managed_profiles_are_identical "$source" "$destination" ||
      ! managed_sync_file "$destination" ||
      ! managed_sync_artifact_parent "$parent" ||
      ! managed_verify_profile_binding "$destination" "$expected_digest" "$expected_endpoint" ||
      ! managed_profiles_are_identical "$source" "$destination"; then
    return 1
  fi
}

managed_remove_generated_candidate() {
  local parent="${WG_CONF%/*}" metadata size
  managed_journal_paths_are_fixed || return 1
  if [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]]; then return 0; fi
  [[ -f "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] || return 1
  metadata="$(owner_mode "$MANAGED_CANDIDATE")" || return 1
  [[ "$metadata" == 0:600 ]] || return 1
  size="$(managed_file_size "$MANAGED_CANDIDATE")" || return 1
  managed_uint_is_canonical "$size" 65536 || return 1
  managed_unlink_path "$MANAGED_CANDIDATE" || return 1
  managed_sync_artifact_parent "$parent"
}

managed_orphan_candidate_is_safe() {
  local metadata size
  managed_journal_paths_are_fixed || return 1
  managed_journal_parent_is_secure || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" &&
     ! -e "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" ]] || return 1
  [[ -f "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] || return 1
  metadata="$(owner_mode "$MANAGED_CANDIDATE")" || return 1
  [[ "$metadata" == 0:600 ]] || return 1
  size="$(managed_file_size "$MANAGED_CANDIDATE")" || return 1
  managed_uint_is_canonical "$size" 65536
}

managed_cleanup_orphan_candidate() {
  if [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]]; then return 0; fi
  managed_orphan_candidate_is_safe || return 1
  managed_unlink_path "$MANAGED_CANDIDATE" || return 1
  managed_sync_artifact_parent "${WG_CONF%/*}"
}

managed_command_cleanup_candidate() {
  local action="${1:-}"
  [[ "$action" == apply ]] || return 1
  [[ "${SETUP_LEASE_ADOPTED:-0}" == 1 && "${GUARD_LOCKED:-0}" == 1 &&
     "${CONTEXT_LOCKED:-0}" == 1 ]] || return 1
  managed_cleanup_orphan_candidate || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]]
}

managed_create_pre_managed_snapshot() {
  local digest endpoint
  managed_journal_paths_are_fixed || return 1
  managed_journal_parent_is_secure || return 1
  managed_profile_file_is_secure "$WG_CONF" || return 1
  if [[ -e "$PRE_MANAGED_CONF" || -L "$PRE_MANAGED_CONF" ]]; then
    managed_profile_file_is_secure "$PRE_MANAGED_CONF" || return 1
    managed_profiles_are_identical "$WG_CONF" "$PRE_MANAGED_CONF" || return 1
    managed_sync_file "$PRE_MANAGED_CONF" || return 1
    managed_sync_artifact_parent "${PRE_MANAGED_CONF%/*}" || return 1
    managed_journal_parent_is_secure || return 1
    managed_profile_file_is_secure "$PRE_MANAGED_CONF" || return 1
    managed_profiles_are_identical "$WG_CONF" "$PRE_MANAGED_CONF"
    return
  fi
  managed_sha256_file digest "$WG_CONF" || return 1
  endpoint="$(configured_endpoint "$WG_CONF")" || return 1
  managed_install_profile_noclobber "$WG_CONF" "$PRE_MANAGED_CONF" "$digest" "$endpoint" ||
    return 1
  managed_profiles_are_identical "$WG_CONF" "$PRE_MANAGED_CONF"
}

managed_pre_managed_identity_matches() {
  managed_journal_paths_are_fixed || return 1
  [[ "$PRE_MANAGED_CONF" == "${WG_CONF}.pre-managed" ]] || return 1
  _managed_profiles_have_same_private_identity_pair "$WG_CONF" "$PRE_MANAGED_CONF"
}

managed_stage_pre_managed_candidate() {
  local digest endpoint
  managed_profile_file_is_secure "$PRE_MANAGED_CONF" || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] || return 1
  managed_sha256_file digest "$PRE_MANAGED_CONF" || return 1
  endpoint="$(configured_endpoint "$PRE_MANAGED_CONF")" || return 1
  managed_install_profile_noclobber "$PRE_MANAGED_CONF" "$MANAGED_CANDIDATE" \
    "$digest" "$endpoint"
}

managed_rewrite_profile_source() {
  local new_source="${1:?}" parent base temporary metadata
  [[ "$new_source" == static || "$new_source" == api ]] || return 1
  validate_secure_parent_directory "$CFG" "health-check configuration directory" 700 ||
    return 1
  managed_profile_file_is_secure "$CFG" || return 1
  parent="${CFG%/*}"; base="${CFG##*/}"
  umask 077
  temporary="$(mktemp "$parent/.${base}.rewrite.XXXXXX")" || return 1
  if ! command awk -v source="$new_source" '
      BEGIN { found=0 }
      /^[[:space:]]*AIRVPN_PROFILE_SOURCE[[:space:]]*=/ {
        found++
        if (found > 1) exit 2
        print "AIRVPN_PROFILE_SOURCE=" source
        next
      }
      { print }
      END { if (found == 0) print "AIRVPN_PROFILE_SOURCE=" source }
    ' "$CFG" > "$temporary" ||
      ! chmod 600 -- "$temporary" ||
      ! { (( EUID != 0 )) || chown 0:0 -- "$temporary"; }; then
    rm -f -- "$temporary"
    return 1
  fi
  metadata="$(owner_mode "$temporary")" || {
    rm -f -- "$temporary"
    return 1
  }
  if [[ "$metadata" != 0:600 ]] ||
      ! managed_sync_file "$temporary" ||
      ! validate_secure_parent_directory "$CFG" \
          "health-check configuration directory" 700 ||
      ! command mv -fT -- "$temporary" "$CFG"; then
    rm -f -- "$temporary"
    return 1
  fi
  managed_profile_file_is_secure "$CFG" || return 1
  managed_sync_file "$CFG" || return 1
  managed_sync_directory "$parent" || return 1
  validate_secure_parent_directory "$CFG" "health-check configuration directory" 700 ||
    return 1
  managed_profile_file_is_secure "$CFG"
}

managed_open_candidate_exclusive() {
  local output_variable="${1:?}" opened_candidate_fd had_noclobber=0 metadata
  managed_output_variable_is_valid "$output_variable" || return 1
  managed_journal_paths_are_fixed || return 1
  managed_journal_parent_is_secure || return 1
  [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] || return 1
  [[ -o noclobber ]] && had_noclobber=1
  umask 077
  set -o noclobber
  if ! exec {opened_candidate_fd}>"$MANAGED_CANDIDATE"; then
    (( had_noclobber )) || set +o noclobber
    return 1
  fi
  (( had_noclobber )) || set +o noclobber
  if ! chmod 600 -- "$MANAGED_CANDIDATE" ||
      ! { (( EUID != 0 )) || chown 0:0 -- "$MANAGED_CANDIDATE"; }; then
    exec {opened_candidate_fd}>&-
    rm -f -- "$MANAGED_CANDIDATE"
    return 1
  fi
  metadata="$(owner_mode "$MANAGED_CANDIDATE")" || {
    exec {opened_candidate_fd}>&-
    rm -f -- "$MANAGED_CANDIDATE"
    return 1
  }
  [[ "$metadata" == 0:600 ]] || {
    exec {opened_candidate_fd}>&-
    rm -f -- "$MANAGED_CANDIDATE"
    return 1
  }
  printf -v "$output_variable" '%s' "$opened_candidate_fd"
}

managed_invoke_generator_closed() {
  local original_fd="${1:?}" key_fd="${2:?}" output_fd="${3:?}" pin="${4:?}"
  local -a pin_args=()
  close_private_fd "$original_fd" || return 1
  exec 3<&"$key_fd" 4>&"$output_fd" || return 1
  if [[ "$pin" == 1 ]]; then exec 5<"$WG_CONF" || return 1; else exec 5<&-; fi
  exec {key_fd}<&- {output_fd}>&-
  [[ "$pin" == 1 ]] && pin_args=(--pin-identity)
  env -i PATH="$PATH" LC_ALL=C "$AIRVPN_API_HELPER" generate-profile \
    --server "$MANAGED_PROFILE_SERVER" \
    --device "$AIRVPN_DEVICE" \
    --expected-endpoint "$MANAGED_PROFILE_ENDPOINT" \
    --timeout "$AIRVPN_API_TIMEOUT" \
    "${pin_args[@]}"
}

managed_prepare_candidate_preflight() {
  local now="${1:?}" selection current_endpoint='' staged_fd
  [[ $# == 1 ]] || return 1
  managed_epoch_is_valid "$now" || return 1
  validate_secure_executable "$AIRVPN_API_HELPER" || return 1
  case "${MANAGED_PROFILE_OPERATION-}" in
    provision|adopt) ;;
    rotate) current_endpoint="$(configured_endpoint "$WG_CONF")" || return 1 ;;
    *) return 1 ;;
  esac
  managed_open_candidate_exclusive staged_fd || return 1
  exec {staged_fd}>&-
  if ! managed_select_airvpn_candidate selection "$now" '' "$current_endpoint" ||
      ! parse_candidate "$selection"; then
    managed_record_preflight_backoff "$now" || return 1
    return 1
  fi
  MANAGED_PROFILE_SERVER="$CANDIDATE_NAME"
  MANAGED_PROFILE_ENDPOINT="$CANDIDATE_ENDPOINT"
  MANAGED_API_PROVIDER_FAILED_SERVER="$CANDIDATE_NAME"
  if [[ "$MANAGED_PROFILE_OPERATION" == provision ]]; then
    MANAGED_PROFILE_PIN=0
  else
    MANAGED_PROFILE_PIN=1
  fi
}

managed_record_preflight_backoff() {
  local now="${1:?}"
  managed_epoch_is_valid "$now" || return 1
  MANAGED_API_STATE_NOW="$now"
  MANAGED_API_OBSERVED_AT="$now"
  MANAGED_API_FAILURE_CLASS=transient
  MANAGED_API_BACKOFF_UNTIL=$((10#$now + 300))
  managed_api_state_write
}

managed_preflight_candidate_cleanup() {
  managed_remove_generated_candidate
}

managed_validate_generator_paths_closed() {
  local metadata size
  validate_secure_executable "$AIRVPN_API_HELPER" || return 1
  [[ -f "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]] || return 1
  metadata="$(owner_mode "$MANAGED_CANDIDATE")" || return 1
  size="$(managed_file_size "$MANAGED_CANDIDATE")" || return 1
  [[ "$metadata" == 0:600 && "$size" == 0 ]]
}

managed_validate_open_candidate_closed() {
  local candidate_fd="${1:?}" fd_identity path_identity metadata size
  [[ ! -L "$MANAGED_CANDIDATE" && -f "$MANAGED_CANDIDATE" ]] || return 1
  fd_identity="$(managed_candidate_fd_identity "$candidate_fd")" || return 1
  path_identity="$(stat -Lc '%d:%i' -- "$MANAGED_CANDIDATE" 2>/dev/null)" || return 1
  metadata="$(owner_mode "$MANAGED_CANDIDATE")" || return 1
  size="$(managed_file_size "$MANAGED_CANDIDATE")" || return 1
  [[ "$fd_identity" == "$path_identity" && "$metadata" == 0:600 && "$size" == 0 ]]
}

managed_finalize_generated_candidate_closed() {
  managed_profile_file_is_secure "$MANAGED_CANDIDATE" || return 1
  managed_sync_file "$MANAGED_CANDIDATE" || return 1
  managed_sync_artifact_parent "${WG_CONF%/*}"
}

managed_duplicate_credential_fd() {
  local output_variable="${1:?}" source_fd="${2:?}" duplicated_fd
  managed_output_variable_is_valid "$output_variable" || return 1
  validate_credential_fd_number "$source_fd" || return 1
  exec {duplicated_fd}<&"$source_fd" || return 1
  printf -v "$output_variable" '%s' "$duplicated_fd"
}

managed_generate_candidate_provider() {
  local credential_fd="${1:?}" candidate_fd key_fd
  local manifest provider_rc expected_pin
  validate_credential_fd_number "$credential_fd" || return 1
  managed_call_without_private_fd "$credential_fd" managed_validate_generator_paths_closed ||
    return 1
  exec {candidate_fd}<>"$MANAGED_CANDIDATE" || return 1
  managed_call_without_private_fd "$credential_fd" \
    managed_validate_open_candidate_closed "$candidate_fd" || {
    exec {candidate_fd}>&-
    return 1
  }
  managed_duplicate_credential_fd key_fd "$credential_fd" || {
    exec {candidate_fd}>&-
    managed_call_without_private_fd "$credential_fd" \
      managed_remove_generated_candidate >/dev/null 2>&1 || true
    return 1
  }
  if manifest="$(managed_invoke_generator_closed "$credential_fd" "$key_fd" "$candidate_fd" \
      "$MANAGED_PROFILE_PIN" 2>/dev/null)"; then
    provider_rc=0
  else
    provider_rc=$?
  fi
  exec {key_fd}<&- {candidate_fd}>&-
  if (( provider_rc != 0 )); then
    managed_call_without_private_fd "$credential_fd" \
      managed_remove_generated_candidate >/dev/null 2>&1 || true
    case "$provider_rc" in
      4) MANAGED_API_PROVIDER_FAILURE_CLASS=auth; return 4 ;;
      5) return 5 ;;
      7) MANAGED_API_PROVIDER_FAILURE_CLASS=device; return 7 ;;
      *)
        MANAGED_API_PROVIDER_FAILED_SERVER="$MANAGED_PROFILE_SERVER"
        return 1
        ;;
    esac
  fi
  expected_pin="$MANAGED_PROFILE_PIN"
  [[ "$manifest" == $'generated\t'"$MANAGED_PROFILE_SERVER"$'\t'"$MANAGED_PROFILE_ENDPOINT"$'\tpinned='"$expected_pin" ]] || {
    managed_call_without_private_fd "$credential_fd" \
      managed_remove_generated_candidate >/dev/null 2>&1 || true
    return 1
  }
  managed_call_without_private_fd "$credential_fd" managed_finalize_generated_candidate_closed ||
    return 1
  MANAGED_PROFILE_MANIFEST="$manifest"
}

managed_candidate_fd_identity() {
  stat -Lc '%d:%i' -- "/proc/$BASHPID/fd/${1:?}" 2>/dev/null
}

managed_emit_profile_manifest() {
  [[ "${MANAGED_PROFILE_EMIT_MANIFEST:-1}" == 1 ]] || return 0
  [[ -n "${MANAGED_PROFILE_MANIFEST-}" ]] || return 0
  printf '%s\n' "$MANAGED_PROFILE_MANIFEST"
}

managed_finish_provision() {
  local action="${1:?}" digest endpoint
  [[ "$action" == dry-run || "$action" == apply ]] || return 1
  managed_profile_file_is_secure "$MANAGED_CANDIDATE" || return 1
  managed_sha256_file digest "$MANAGED_CANDIDATE" || return 1
  endpoint="$(configured_endpoint "$MANAGED_CANDIDATE")" || return 1
  if [[ "$action" == dry-run ]]; then
    managed_remove_generated_candidate || return 1
  else
    [[ ! -e "$WG_CONF" && ! -L "$WG_CONF" ]] || return 1
    managed_install_profile_noclobber "$MANAGED_CANDIDATE" "$WG_CONF" "$digest" "$endpoint" ||
      return 1
    managed_remove_generated_candidate || return 1
    managed_rewrite_profile_source api || return 1
    AIRVPN_PROFILE_SOURCE=api
  fi
  managed_emit_profile_manifest
}

managed_finish_adopt() {
  local action="${1:?}"
  [[ "$action" == dry-run || "$action" == apply ]] || return 1
  managed_profiles_have_same_private_identity "$WG_CONF" || return 1
  if [[ "$action" == dry-run ]]; then
    managed_remove_generated_candidate || return 1
  else
    managed_create_pre_managed_snapshot || return 1
    managed_profiles_have_same_private_identity "$WG_CONF" || return 1
    managed_profiles_are_identical "$WG_CONF" "$PRE_MANAGED_CONF" || return 1
    managed_remove_generated_candidate || return 1
    managed_rewrite_profile_source api || return 1
    AIRVPN_PROFILE_SOURCE=api
  fi
  managed_emit_profile_manifest
}

managed_finish_rotate() {
  local action="${1:?}" server="${2:?}" verify_speed="${3:?}"
  [[ "$action" == dry-run || "$action" == apply ]] || return 1
  if [[ "$action" == dry-run ]]; then
    managed_remove_generated_candidate || return 1
  else
    managed_profile_transaction "$server" "$verify_speed" || return 1
  fi
  managed_emit_profile_manifest
}

managed_profile_attempt_downstream() {
  case "$MANAGED_PROFILE_OPERATION" in
    provision) managed_finish_provision "$MANAGED_PROFILE_ACTION" ;;
    adopt) managed_finish_adopt "$MANAGED_PROFILE_ACTION" ;;
    rotate) managed_finish_rotate "$MANAGED_PROFILE_ACTION" "$MANAGED_PROFILE_SERVER" \
      "$MANAGED_PROFILE_VERIFY_SPEED" ;;
    *) return 1 ;;
  esac
}

managed_profile_admin_config_is_valid() {
  local line country_keys=0
  declare -F validate_prospective_api_settings >/dev/null || return 1
  validate_prospective_api_settings || return 1
  validate_secure_parent_directory "$CFG" "health-check configuration directory" 700 ||
    return 1
  [[ -f "$CFG" && ! -L "$CFG" ]] || return 1
  if [[ "${PROPOSED_SETTINGS_READY:-0}" != 1 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*AIRVPN_COUNTRIES[[:space:]]*= ]] &&
        country_keys=$((country_keys + 1))
    done < "$CFG"
    (( country_keys == 1 )) || return 1
  fi
}

managed_profile_attempt_precheck() {
  local operation="${1:?}" action="${2:?}" supplied_credential="${3:?}" rc
  [[ "$action" == dry-run || "$action" == apply ]] || return 1
  [[ "$supplied_credential" == 0 || "$supplied_credential" == 1 ]] || return 1
  managed_profile_admin_config_is_valid || return 1
  if [[ -e "$MANAGED_CANDIDATE" || -L "$MANAGED_CANDIDATE" ]]; then
    if [[ "$action" == dry-run ]]; then
      if managed_orphan_candidate_is_safe; then
        log "Managed candidate recovery requires an apply operation"
      else
        log "Managed candidate is unsafe and requires operator repair"
      fi
      return 1
    fi
    managed_cleanup_orphan_candidate || return 1
  fi
  case "$operation" in
    provision) [[ ! -e "$WG_CONF" && ! -L "$WG_CONF" ]] ;;
    adopt)
      managed_profile_file_is_secure "$WG_CONF" || return 1
      if [[ "$action" == dry-run ]]; then
        [[ "$AIRVPN_PROFILE_SOURCE" == static ||
           ( "$AIRVPN_PROFILE_SOURCE" == api && "$supplied_credential" == 1 &&
             "${PROPOSED_SETTINGS_READY:-0}" == 1 ) ]]
      else
        [[ "$AIRVPN_PROFILE_SOURCE" == static ]]
      fi
      ;;
    rotate)
      [[ "$AIRVPN_PROFILE_SOURCE" == api ]] && managed_profile_file_is_secure "$WG_CONF" ||
        return 1
      if cooldown_allows "$ROTATE_STAMP" "$AIRVPN_ROTATE_COOLDOWN"; then return 0; fi
      rc=$?
      return "$rc"
      ;;
    *) return 1 ;;
  esac
}

managed_apply_credential_ready() {
  local supplied_fd="${1-}"
  if [[ -n "$supplied_fd" ]]; then
    validate_credential_fd_number "$supplied_fd" || return 1
    run_with_private_fd_closed "$supplied_fd" managed_validate_installed_key_closed ||
      return 1
    [[ "$AIRVPN_API_KEY_FILE" -ef "/proc/$BASHPID/fd/$supplied_fd" ]] || return 1
  else
    managed_validate_installed_key_closed || return 1
  fi
}

managed_validate_installed_key_closed() {
  local installed_fd=''
  open_installed_api_key installed_fd || return 1
  close_private_fd "$installed_fd"
}

managed_run_profile_attempt() {
  local operation="${1:?}" action="${2:?}" credential_fd="${3-}"
  local verify_speed="${5:-0}" bypass=0 supplied_credential=0 rc
  [[ $# == 5 && ( "$action" == dry-run || "$action" == apply ) ]] || return 1
  [[ "$verify_speed" == 0 || "$verify_speed" == 1 ]] || return 1
  [[ -z "$credential_fd" ]] || validate_credential_fd_number "$credential_fd" || return 1
  [[ -z "$credential_fd" ]] || supplied_credential=1
  if [[ "$action" == apply && ( "$operation" == provision || "$operation" == adopt ) ]]; then
    if ! managed_apply_credential_ready "$credential_fd"; then
      [[ -z "$credential_fd" ]] || close_private_fd "$credential_fd"
      return 1
    fi
  fi
  if managed_call_without_private_fd "$credential_fd" \
      managed_profile_attempt_precheck "$operation" "$action" "$supplied_credential"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc != 0 )); then
    [[ -z "$credential_fd" ]] || close_private_fd "$credential_fd"
    return "$rc"
  fi
  [[ "$action" == dry-run ]] && bypass=1
  MANAGED_PROFILE_OPERATION="$operation"
  MANAGED_PROFILE_ACTION="$action"
  MANAGED_PROFILE_VERIFY_SPEED="$verify_speed"
  MANAGED_PROFILE_SERVER=''
  MANAGED_PROFILE_ENDPOINT=''
  MANAGED_PROFILE_MANIFEST=''
  managed_run_authenticated_attempt "$bypass" "$credential_fd" \
    managed_generate_candidate_provider managed_profile_attempt_downstream \
    managed_prepare_candidate_preflight managed_preflight_candidate_cleanup
  rc=$?
  if (( rc != 0 )) && [[ -e "$MANAGED_CANDIDATE" || -L "$MANAGED_CANDIDATE" ]] &&
      [[ ! -e "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" &&
         ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]]; then
    managed_remove_generated_candidate >/dev/null 2>&1 || true
  fi
  return "$rc"
}

managed_command_provision() {
  MANAGED_PROFILE_EMIT_MANIFEST=1
  managed_run_profile_attempt provision "${1:?}" "${2-}" provision 0
}

managed_command_adopt() {
  MANAGED_PROFILE_EMIT_MANIFEST=1
  managed_run_profile_attempt adopt "${1:?}" "${2-}" adopt 0
}

managed_command_rotate() {
  [[ "$AIRVPN_PROFILE_SOURCE" == api ]] || return 1
  MANAGED_PROFILE_EMIT_MANIFEST=1
  managed_run_profile_attempt rotate "${1:?}" '' manual_rotation 0
}

managed_rotate_profile() {
  local reason="${1:?}" verify_speed="${2:?}"
  [[ "$AIRVPN_PROFILE_SOURCE" == api ]] || return 1
  truthy "$AIRVPN_ROTATE_ENABLED" || return 1
  MANAGED_PROFILE_EMIT_MANIFEST=0
  managed_run_profile_attempt rotate apply '' "$reason" "$verify_speed"
}

managed_command_restore_static() {
  local action="${1:?}"
  [[ "$action" == dry-run || "$action" == apply ]] || return 1
  managed_profile_file_is_secure "$WG_CONF" || return 1
  managed_profile_file_is_secure "$PRE_MANAGED_CONF" || return 1
  configured_endpoint "$WG_CONF" >/dev/null || return 1
  configured_endpoint "$PRE_MANAGED_CONF" >/dev/null || return 1
  managed_pre_managed_identity_matches || return 1
  if [[ -e "$MANAGED_CANDIDATE" || -L "$MANAGED_CANDIDATE" ]]; then
    managed_orphan_candidate_is_safe || return 1
  fi
  if [[ "$action" == dry-run ]]; then return 0; fi
  managed_cleanup_orphan_candidate || return 1
  managed_rewrite_profile_source static || return 1
  AIRVPN_PROFILE_SOURCE=static
  if managed_profiles_are_identical "$WG_CONF" "$PRE_MANAGED_CONF"; then return 0; fi
  managed_stage_pre_managed_candidate || return 1
  managed_profiles_have_same_private_identity "$WG_CONF" || return 1
  managed_profile_transaction '' 0
}
