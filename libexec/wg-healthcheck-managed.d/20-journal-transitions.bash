managed_journal_memory_is_valid() {
  local wgmanaged_old wgmanaged_candidate
  case "${MANAGED_JOURNAL_PHASE-}" in
    prepared|client-stopped|tunnel-down|candidate-installed|candidate-up|verified) ;;
    *) return 1 ;;
  esac
  managed_sha256_is_valid "${MANAGED_JOURNAL_BACKUP_SHA256-}" || return 1
  managed_sha256_is_valid "${MANAGED_JOURNAL_CANDIDATE_SHA256-}" || return 1
  [[ "$MANAGED_JOURNAL_BACKUP_SHA256" != "$MANAGED_JOURNAL_CANDIDATE_SHA256" ]] ||
    return 1
  wgmanaged_old="$(canonicalize_endpoint "${MANAGED_JOURNAL_OLD_ENDPOINT-}")" || return 1
  wgmanaged_candidate="$(canonicalize_endpoint "${MANAGED_JOURNAL_CANDIDATE_ENDPOINT-}")" ||
    return 1
  [[ "$wgmanaged_old" == "$MANAGED_JOURNAL_OLD_ENDPOINT" &&
     "$wgmanaged_candidate" == "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" ]] || return 1
  [[ "${MANAGED_JOURNAL_QB_WAS_RUNNING-}" == 0 ||
     "${MANAGED_JOURNAL_QB_WAS_RUNNING-}" == 1 ]]
}

managed_journal_load() {
  local wgmanaged_size wgmanaged_phase wgmanaged_backup wgmanaged_candidate
  local wgmanaged_old wgmanaged_new wgmanaged_qb wgmanaged_canonical
  local -a wgmanaged_lines=()
  managed_journal_clear
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  managed_journal_parent_is_secure || return 1
  managed_journal_file_is_secure || return 1
  wgmanaged_size="$(managed_file_size "$ROTATION_PENDING")" || return 1
  managed_uint_is_canonical "$wgmanaged_size" 4096 || return 1
  (( 10#$wgmanaged_size > 0 )) || return 1
  managed_api_state_bytes_are_strict "$ROTATION_PENDING" || return 1
  mapfile -t wgmanaged_lines < "$ROTATION_PENDING" || return 1
  (( ${#wgmanaged_lines[@]} == 8 )) || return 1
  [[ "${wgmanaged_lines[0]}" == version=2 ]] || return 1
  [[ "${wgmanaged_lines[1]}" == transaction=managed-profile ]] || return 1
  [[ "${wgmanaged_lines[2]}" =~ ^phase=(prepared|client-stopped|tunnel-down|candidate-installed|candidate-up|verified)$ ]] ||
    return 1
  wgmanaged_phase="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[3]}" =~ ^backup_sha256=([0-9a-f]{64})$ ]] || return 1
  wgmanaged_backup="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[4]}" =~ ^candidate_sha256=([0-9a-f]{64})$ ]] || return 1
  wgmanaged_candidate="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[5]}" =~ ^old_endpoint=(.+)$ ]] || return 1
  wgmanaged_old="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[6]}" =~ ^candidate_endpoint=(.+)$ ]] || return 1
  wgmanaged_new="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[7]}" =~ ^qb_was_running=([01])$ ]] || return 1
  wgmanaged_qb="${BASH_REMATCH[1]}"
  wgmanaged_canonical="$(canonicalize_endpoint "$wgmanaged_old")" || return 1
  [[ "$wgmanaged_canonical" == "$wgmanaged_old" ]] || return 1
  wgmanaged_canonical="$(canonicalize_endpoint "$wgmanaged_new")" || return 1
  [[ "$wgmanaged_canonical" == "$wgmanaged_new" ]] || return 1

  MANAGED_JOURNAL_PHASE="$wgmanaged_phase"
  MANAGED_JOURNAL_BACKUP_SHA256="$wgmanaged_backup"
  MANAGED_JOURNAL_CANDIDATE_SHA256="$wgmanaged_candidate"
  MANAGED_JOURNAL_OLD_ENDPOINT="$wgmanaged_old"
  MANAGED_JOURNAL_CANDIDATE_ENDPOINT="$wgmanaged_new"
  MANAGED_JOURNAL_QB_WAS_RUNNING="$wgmanaged_qb"
  if ! managed_journal_memory_is_valid; then
    managed_journal_clear
    return 1
  fi
}

managed_journal_move() {
  command mv -fT -- "${1:?}" "${2:?}"
}

_managed_journal_commit() {
  local wgmanaged_parent wgmanaged_base wgmanaged_temporary wgmanaged_metadata
  managed_journal_memory_is_valid || return 1
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  managed_journal_parent_is_secure || return 1
  if [[ -e "$ROTATION_PENDING" || -L "$ROTATION_PENDING" ]]; then
    managed_journal_file_is_secure || return 1
  fi
  wgmanaged_parent="${ROTATION_PENDING%/*}"
  wgmanaged_base="${ROTATION_PENDING##*/}"
  wgmanaged_temporary="$(mktemp "$wgmanaged_parent/.${wgmanaged_base}.tmp.XXXXXX")" ||
    return 1
  if ! chmod 600 -- "$wgmanaged_temporary"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  wgmanaged_metadata="$(owner_mode "$wgmanaged_temporary")" || {
    rm -f -- "$wgmanaged_temporary"
    return 1
  }
  if [[ "$wgmanaged_metadata" != 0:600 ]]; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  if ! {
    printf '%s\n' \
      'version=2' \
      'transaction=managed-profile' \
      "phase=$MANAGED_JOURNAL_PHASE" \
      "backup_sha256=$MANAGED_JOURNAL_BACKUP_SHA256" \
      "candidate_sha256=$MANAGED_JOURNAL_CANDIDATE_SHA256" \
      "old_endpoint=$MANAGED_JOURNAL_OLD_ENDPOINT" \
      "candidate_endpoint=$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" \
      "qb_was_running=$MANAGED_JOURNAL_QB_WAS_RUNNING"
  } > "$wgmanaged_temporary"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  if ! managed_sync_file "$wgmanaged_temporary"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  if ! managed_journal_move "$wgmanaged_temporary" "$ROTATION_PENDING"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  managed_journal_file_is_secure || return 1
  managed_sync_file "$ROTATION_PENDING" || return 1
  managed_sync_journal_parent "$wgmanaged_parent"
}

managed_classify_active_profile() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_backup="${2:?}"
  local wgmanaged_candidate="${3:?}" wgmanaged_class wgmanaged_sha256_carrier=''
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  managed_sha256_is_valid "$wgmanaged_backup" || return 1
  managed_sha256_is_valid "$wgmanaged_candidate" || return 1
  if [[ "$wgmanaged_backup" == "$wgmanaged_candidate" ]]; then
    wgmanaged_class=ambiguous
  elif ! managed_sha256_file_core "$WG_CONF"; then
    wgmanaged_class=unknown
  elif [[ "$wgmanaged_sha256_carrier" == "$wgmanaged_backup" ]]; then
    wgmanaged_class=backup
  elif [[ "$wgmanaged_sha256_carrier" == "$wgmanaged_candidate" ]]; then
    wgmanaged_class=candidate
  else
    wgmanaged_class=unknown
  fi
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_class"
}

managed_classify_candidate_profile() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_expected="${2:?}"
  local wgmanaged_class wgmanaged_sha256_carrier=''
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  managed_sha256_is_valid "$wgmanaged_expected" || return 1
  if [[ ! -e "$MANAGED_CANDIDATE" && ! -L "$MANAGED_CANDIDATE" ]]; then
    wgmanaged_class=missing
  elif ! managed_sha256_file_core "$MANAGED_CANDIDATE"; then
    wgmanaged_class=mismatch
  elif [[ "$wgmanaged_sha256_carrier" == "$wgmanaged_expected" ]]; then
    wgmanaged_class=present
  else
    wgmanaged_class=mismatch
  fi
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_class"
}

managed_verify_profile_binding() {
  local wgmanaged_path="${1:?}" wgmanaged_expected_digest="${2:?}"
  local wgmanaged_expected_endpoint="${3:?}" wgmanaged_actual_endpoint
  local wgmanaged_canonical_endpoint
  local journal_first_digest journal_second_digest
  managed_sha256_is_valid "$wgmanaged_expected_digest" || return 1
  wgmanaged_canonical_endpoint="$(canonicalize_endpoint "$wgmanaged_expected_endpoint")" ||
    return 1
  [[ "$wgmanaged_canonical_endpoint" == "$wgmanaged_expected_endpoint" ]] || return 1
  managed_sha256_file journal_first_digest "$wgmanaged_path" || return 1
  [[ "$journal_first_digest" == "$wgmanaged_expected_digest" ]] || return 1
  wgmanaged_actual_endpoint="$(configured_endpoint "$wgmanaged_path")" || return 1
  managed_sha256_file journal_second_digest "$wgmanaged_path" || return 1
  [[ "$journal_first_digest" == "$journal_second_digest" &&
     "$wgmanaged_actual_endpoint" == "$wgmanaged_expected_endpoint" ]]
}

managed_safety_clear() {
  MANAGED_SAFETY_STATE=''
  MANAGED_SAFETY_BACKUP_SHA256=''
  MANAGED_SAFETY_CANDIDATE_SHA256=''
  MANAGED_SAFETY_OLD_ENDPOINT=''
  MANAGED_SAFETY_CANDIDATE_ENDPOINT=''
  MANAGED_SAFETY_QB_INTENT=''
  MANAGED_SAFETY_QB_CONTAINER=''
  MANAGED_SAFETY_QB_CONTAINER_ID=''
  MANAGED_SAFETY_QB_PROCESS=''
  MANAGED_SAFETY_QB_LISTEN_IPV4=''
  MANAGED_SAFETY_QB_LISTEN_PORT=''
}

managed_safety_path_is_fixed() {
  managed_journal_paths_are_fixed &&
    [[ "$MANAGED_SAFETY" == "${WG_CONF}.safety-healthcheck" ]]
}

managed_safety_parent_is_secure() {
  local wgmanaged_parent wgmanaged_metadata
  managed_safety_path_is_fixed || return 1
  wgmanaged_parent="${MANAGED_SAFETY%/*}"
  [[ -d "$wgmanaged_parent" && ! -L "$wgmanaged_parent" ]] || return 1
  wgmanaged_metadata="$(owner_mode "$wgmanaged_parent")" || return 1
  [[ "$wgmanaged_metadata" == 0:700 ]]
}

managed_safety_file_is_secure() {
  local wgmanaged_metadata
  [[ -f "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" ]] || return 1
  wgmanaged_metadata="$(owner_mode "$MANAGED_SAFETY")" || return 1
  [[ "$wgmanaged_metadata" == 0:600 ]]
}

managed_ipv4_endpoint_is_canonical() {
  local wgmanaged_endpoint="${1-}" wgmanaged_host wgmanaged_canonical
  [[ "$wgmanaged_endpoint" =~ ^([0-9.]+):([0-9]+)$ ]] || return 1
  wgmanaged_host="${BASH_REMATCH[1]}"
  validate_ip_address "$wgmanaged_host" || return 1
  wgmanaged_canonical="$(canonicalize_endpoint "$wgmanaged_endpoint")" || return 1
  [[ "$wgmanaged_canonical" == "$wgmanaged_endpoint" ]]
}

managed_safety_memory_is_valid() {
  case "${MANAGED_SAFETY_STATE-}" in pending|committed|finalizing) ;; *) return 1 ;; esac
  managed_sha256_is_valid "${MANAGED_SAFETY_BACKUP_SHA256-}" || return 1
  managed_sha256_is_valid "${MANAGED_SAFETY_CANDIDATE_SHA256-}" || return 1
  [[ "$MANAGED_SAFETY_BACKUP_SHA256" != "$MANAGED_SAFETY_CANDIDATE_SHA256" ]] ||
    return 1
  managed_ipv4_endpoint_is_canonical "${MANAGED_SAFETY_OLD_ENDPOINT-}" || return 1
  managed_ipv4_endpoint_is_canonical "${MANAGED_SAFETY_CANDIDATE_ENDPOINT-}" || return 1
  case "${MANAGED_SAFETY_QB_INTENT-}" in
    unmanaged)
      [[ "${MANAGED_SAFETY_QB_CONTAINER-}" == - &&
         "${MANAGED_SAFETY_QB_CONTAINER_ID-}" == - &&
         "${MANAGED_SAFETY_QB_PROCESS-}" == - &&
         "${MANAGED_SAFETY_QB_LISTEN_IPV4-}" == - &&
         "${MANAGED_SAFETY_QB_LISTEN_PORT-}" == 0 ]] || return 1
      ;;
    running|stopped)
      validate_managed_container_name "${MANAGED_SAFETY_QB_CONTAINER-}" || return 1
      [[ "${MANAGED_SAFETY_QB_CONTAINER_ID-}" =~ ^[0-9a-f]{64}$ ]] || return 1
      validate_process_name "${MANAGED_SAFETY_QB_PROCESS-}" || return 1
      validate_ip_address "${MANAGED_SAFETY_QB_LISTEN_IPV4-}" || return 1
      [[ "${MANAGED_SAFETY_QB_LISTEN_IPV4-}" != *:* ]] || return 1
      managed_uint_is_canonical "${MANAGED_SAFETY_QB_LISTEN_PORT-}" 65535 || return 1
      (( 10#$MANAGED_SAFETY_QB_LISTEN_PORT >= 1 )) || return 1
      ;;
    *) return 1 ;;
  esac
}

managed_safety_artifacts_are_valid() {
  local safety_backup_ipv4 safety_candidate_ipv4 safety_active_class safety_candidate_class
  managed_verify_profile_binding "${WG_CONF}.bak-healthcheck" \
    "$MANAGED_SAFETY_BACKUP_SHA256" "$MANAGED_SAFETY_OLD_ENDPOINT" || return 1
  managed_profile_interface_ipv4 safety_backup_ipv4 "${WG_CONF}.bak-healthcheck" || return 1
  if [[ "$MANAGED_SAFETY_QB_INTENT" != unmanaged &&
        "$safety_backup_ipv4" != "$MANAGED_SAFETY_QB_LISTEN_IPV4" ]]; then
    return 1
  fi
  managed_classify_active_profile safety_active_class "$MANAGED_SAFETY_BACKUP_SHA256" \
    "$MANAGED_SAFETY_CANDIDATE_SHA256" || return 1
  case "$MANAGED_SAFETY_STATE" in
    pending)
      case "$safety_active_class" in backup|candidate) ;; *) return 1 ;; esac
      managed_classify_candidate_profile safety_candidate_class \
        "$MANAGED_SAFETY_CANDIDATE_SHA256" || return 1
      case "$safety_candidate_class" in
        present)
          managed_verify_profile_binding "$MANAGED_CANDIDATE" \
            "$MANAGED_SAFETY_CANDIDATE_SHA256" "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" ||
            return 1
          managed_profile_interface_ipv4 safety_candidate_ipv4 "$MANAGED_CANDIDATE" ||
            return 1
          ;;
        missing)
          if [[ "$safety_active_class" == candidate ]]; then
            managed_profile_interface_ipv4 safety_candidate_ipv4 "$WG_CONF" || return 1
          else
            safety_candidate_ipv4="$safety_backup_ipv4"
          fi
          ;;
        *) return 1 ;;
      esac
      ;;
    committed|finalizing)
      [[ "$safety_active_class" == candidate ]] || return 1
      managed_classify_candidate_profile safety_candidate_class \
        "$MANAGED_SAFETY_CANDIDATE_SHA256" || return 1
      [[ "$safety_candidate_class" == missing ]] || return 1
      managed_verify_profile_binding "$WG_CONF" "$MANAGED_SAFETY_CANDIDATE_SHA256" \
        "$MANAGED_SAFETY_CANDIDATE_ENDPOINT" || return 1
      managed_profile_interface_ipv4 safety_candidate_ipv4 "$WG_CONF" || return 1
      ;;
    *) return 1 ;;
  esac
  if [[ "$MANAGED_SAFETY_QB_INTENT" != unmanaged &&
        "$safety_candidate_ipv4" != "$MANAGED_SAFETY_QB_LISTEN_IPV4" ]]; then
    return 1
  fi
}

managed_safety_load_record() {
  local wgmanaged_size
  local -a wgmanaged_lines=()
  managed_safety_clear
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  managed_safety_parent_is_secure || return 1
  managed_safety_file_is_secure || return 1
  wgmanaged_size="$(managed_file_size "$MANAGED_SAFETY")" || return 1
  managed_uint_is_canonical "$wgmanaged_size" 4096 || return 1
  (( 10#$wgmanaged_size > 0 )) || return 1
  managed_api_state_bytes_are_strict "$MANAGED_SAFETY" || return 1
  mapfile -t wgmanaged_lines < "$MANAGED_SAFETY" || return 1
  (( ${#wgmanaged_lines[@]} == 13 )) || return 1
  [[ "${wgmanaged_lines[0]}" == version=1 ]] || return 1
  [[ "${wgmanaged_lines[1]}" == record=managed-profile-safety ]] || return 1
  [[ "${wgmanaged_lines[2]}" =~ ^state=(pending|committed|finalizing)$ ]] || return 1
  MANAGED_SAFETY_STATE="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[3]}" =~ ^backup_sha256=([0-9a-f]{64})$ ]] || return 1
  MANAGED_SAFETY_BACKUP_SHA256="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[4]}" =~ ^candidate_sha256=([0-9a-f]{64})$ ]] || return 1
  MANAGED_SAFETY_CANDIDATE_SHA256="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[5]}" =~ ^old_endpoint=(.+)$ ]] || return 1
  MANAGED_SAFETY_OLD_ENDPOINT="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[6]}" =~ ^candidate_endpoint=(.+)$ ]] || return 1
  MANAGED_SAFETY_CANDIDATE_ENDPOINT="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[7]}" =~ ^qb_intent=(unmanaged|running|stopped)$ ]] || return 1
  MANAGED_SAFETY_QB_INTENT="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[8]}" =~ ^qb_container=(.+)$ ]] || return 1
  MANAGED_SAFETY_QB_CONTAINER="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[9]}" =~ ^qb_container_id=(.+)$ ]] || return 1
  MANAGED_SAFETY_QB_CONTAINER_ID="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[10]}" =~ ^qb_process=(.+)$ ]] || return 1
  MANAGED_SAFETY_QB_PROCESS="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[11]}" =~ ^qb_listen_ipv4=(.+)$ ]] || return 1
  MANAGED_SAFETY_QB_LISTEN_IPV4="${BASH_REMATCH[1]}"
  [[ "${wgmanaged_lines[12]}" =~ ^qb_listen_port=(.+)$ ]] || return 1
  MANAGED_SAFETY_QB_LISTEN_PORT="${BASH_REMATCH[1]}"
  if ! managed_safety_memory_is_valid; then
    managed_safety_clear
    return 1
  fi
}

managed_safety_load() {
  managed_safety_load_record || return 1
  if ! managed_safety_artifacts_are_valid; then
    managed_safety_clear
    return 1
  fi
}

managed_safety_rebarrier_pending() {
  local wgmanaged_parent
  [[ "${MANAGED_SAFETY_STATE-}" == pending ]] || return 1
  managed_safety_memory_is_valid || return 1
  managed_safety_parent_is_secure || return 1
  managed_safety_file_is_secure || return 1
  wgmanaged_parent="${MANAGED_SAFETY%/*}"
  managed_sync_file "$MANAGED_SAFETY" || return 1
  managed_sync_safety_parent "$wgmanaged_parent" || return 1
  managed_safety_load_record || return 1
  [[ "$MANAGED_SAFETY_STATE" == pending ]]
}

managed_safety_move() {
  command mv -fT -- "${1:?}" "${2:?}"
}

managed_sync_safety_parent() {
  managed_sync_directory "${1:?}"
}

_managed_safety_commit() {
  local wgmanaged_parent wgmanaged_base wgmanaged_temporary wgmanaged_metadata
  managed_safety_memory_is_valid || return 1
  managed_safety_artifacts_are_valid || return 1
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  managed_safety_parent_is_secure || return 1
  if [[ -e "$MANAGED_SAFETY" || -L "$MANAGED_SAFETY" ]]; then
    managed_safety_file_is_secure || return 1
  fi
  wgmanaged_parent="${MANAGED_SAFETY%/*}"
  wgmanaged_base="${MANAGED_SAFETY##*/}"
  wgmanaged_temporary="$(mktemp "$wgmanaged_parent/.${wgmanaged_base}.tmp.XXXXXX")" ||
    return 1
  if ! chmod 600 -- "$wgmanaged_temporary"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  wgmanaged_metadata="$(owner_mode "$wgmanaged_temporary")" || {
    rm -f -- "$wgmanaged_temporary"
    return 1
  }
  if [[ "$wgmanaged_metadata" != 0:600 ]] || ! {
    printf '%s\n' \
      'version=1' \
      'record=managed-profile-safety' \
      "state=$MANAGED_SAFETY_STATE" \
      "backup_sha256=$MANAGED_SAFETY_BACKUP_SHA256" \
      "candidate_sha256=$MANAGED_SAFETY_CANDIDATE_SHA256" \
      "old_endpoint=$MANAGED_SAFETY_OLD_ENDPOINT" \
      "candidate_endpoint=$MANAGED_SAFETY_CANDIDATE_ENDPOINT" \
      "qb_intent=$MANAGED_SAFETY_QB_INTENT" \
      "qb_container=$MANAGED_SAFETY_QB_CONTAINER" \
      "qb_container_id=$MANAGED_SAFETY_QB_CONTAINER_ID" \
      "qb_process=$MANAGED_SAFETY_QB_PROCESS" \
      "qb_listen_ipv4=$MANAGED_SAFETY_QB_LISTEN_IPV4" \
      "qb_listen_port=$MANAGED_SAFETY_QB_LISTEN_PORT"
  } > "$wgmanaged_temporary"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  if ! managed_sync_file "$wgmanaged_temporary" ||
      ! managed_safety_move "$wgmanaged_temporary" "$MANAGED_SAFETY"; then
    rm -f -- "$wgmanaged_temporary"
    return 1
  fi
  managed_safety_file_is_secure || return 1
  managed_sync_file "$MANAGED_SAFETY" || return 1
  managed_sync_safety_parent "$wgmanaged_parent"
}

managed_safety_prepare() {
  local safety_backup_digest safety_candidate_digest safety_old_endpoint safety_new_endpoint
  [[ ! -e "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" ]] || return 1
  managed_safety_clear
  managed_sha256_file safety_backup_digest "${WG_CONF}.bak-healthcheck" || return 1
  managed_sha256_file safety_candidate_digest "$MANAGED_CANDIDATE" || return 1
  safety_old_endpoint="$(configured_endpoint "${WG_CONF}.bak-healthcheck")" || return 1
  safety_new_endpoint="$(configured_endpoint "$MANAGED_CANDIDATE")" || return 1
  managed_verify_profile_binding "${WG_CONF}.bak-healthcheck" "$safety_backup_digest" \
    "$safety_old_endpoint" || return 1
  managed_verify_profile_binding "$MANAGED_CANDIDATE" "$safety_candidate_digest" \
    "$safety_new_endpoint" || return 1
  MANAGED_SAFETY_STATE=pending
  MANAGED_SAFETY_BACKUP_SHA256="$safety_backup_digest"
  MANAGED_SAFETY_CANDIDATE_SHA256="$safety_candidate_digest"
  MANAGED_SAFETY_OLD_ENDPOINT="$safety_old_endpoint"
  MANAGED_SAFETY_CANDIDATE_ENDPOINT="$safety_new_endpoint"
  MANAGED_SAFETY_QB_INTENT="${MANAGED_QB_INTENT-}"
  MANAGED_SAFETY_QB_CONTAINER="${MANAGED_QB_CONTAINER-}"
  MANAGED_SAFETY_QB_CONTAINER_ID="${MANAGED_QB_CONTAINER_ID-}"
  MANAGED_SAFETY_QB_PROCESS="${MANAGED_QB_PROCESS-}"
  MANAGED_SAFETY_QB_LISTEN_IPV4="${MANAGED_QB_LISTEN_IPV4-}"
  MANAGED_SAFETY_QB_LISTEN_PORT="${MANAGED_QB_LISTEN_PORT-}"
  _managed_safety_commit
}

managed_safety_transition() {
  local wgmanaged_next="${1-}" wgmanaged_current wgmanaged_rc
  [[ $# == 1 ]] || return 1
  managed_safety_load || return 1
  wgmanaged_current="$MANAGED_SAFETY_STATE"
  case "$wgmanaged_current:$wgmanaged_next" in
    pending:committed|committed:finalizing) ;;
    *) return 1 ;;
  esac
  MANAGED_SAFETY_STATE="$wgmanaged_next"
  if _managed_safety_commit; then
    return 0
  else
    wgmanaged_rc=$?
  fi
  managed_safety_load >/dev/null 2>&1 || managed_safety_clear
  return "$wgmanaged_rc"
}

managed_verify_journal_phase() {
  local wgmanaged_phase="${1:-${MANAGED_JOURNAL_PHASE-}}"
  local wgmanaged_expected_active journal_active_class journal_candidate_class
  managed_journal_memory_is_valid || return 1
  case "$wgmanaged_phase" in
    prepared|client-stopped|tunnel-down) wgmanaged_expected_active=backup ;;
    candidate-installed|candidate-up|verified) wgmanaged_expected_active=candidate ;;
    *) return 1 ;;
  esac
  managed_verify_profile_binding "${WG_CONF}.bak-healthcheck" \
    "$MANAGED_JOURNAL_BACKUP_SHA256" "$MANAGED_JOURNAL_OLD_ENDPOINT" || return 1
  managed_classify_candidate_profile journal_candidate_class \
    "$MANAGED_JOURNAL_CANDIDATE_SHA256" || return 1
  [[ "$journal_candidate_class" == present ]] || return 1
  managed_verify_profile_binding "$MANAGED_CANDIDATE" \
    "$MANAGED_JOURNAL_CANDIDATE_SHA256" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT" ||
    return 1
  managed_classify_active_profile journal_active_class \
    "$MANAGED_JOURNAL_BACKUP_SHA256" "$MANAGED_JOURNAL_CANDIDATE_SHA256" || return 1
  [[ "$journal_active_class" == "$wgmanaged_expected_active" ]]
}

managed_journal_prepare() {
  local wgmanaged_qb="${1-}" journal_backup_first journal_candidate_first
  local journal_backup_second journal_candidate_second wgmanaged_old wgmanaged_new
  local wgmanaged_parent wgmanaged_backup_path
  [[ $# == 1 && ( "$wgmanaged_qb" == 0 || "$wgmanaged_qb" == 1 ) ]] || return 1
  managed_journal_clear
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  managed_journal_parent_is_secure || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]] || return 1
  wgmanaged_parent="${WG_CONF%/*}"
  wgmanaged_backup_path="${WG_CONF}.bak-healthcheck"
  [[ "${wgmanaged_backup_path%/*}" == "$wgmanaged_parent" &&
     "${MANAGED_CANDIDATE%/*}" == "$wgmanaged_parent" ]] || return 1
  managed_profile_file_is_secure "$wgmanaged_backup_path" || return 1
  managed_sync_file "$wgmanaged_backup_path" || return 1
  managed_profile_file_is_secure "$MANAGED_CANDIDATE" || return 1
  managed_sync_file "$MANAGED_CANDIDATE" || return 1
  managed_sync_artifact_parent "$wgmanaged_parent" || return 1
  managed_sha256_file journal_backup_first "$wgmanaged_backup_path" || return 1
  managed_sha256_file journal_candidate_first "$MANAGED_CANDIDATE" || return 1
  wgmanaged_old="$(configured_endpoint "$wgmanaged_backup_path")" || return 1
  wgmanaged_new="$(configured_endpoint "$MANAGED_CANDIDATE")" || return 1
  managed_sha256_file journal_backup_second "$wgmanaged_backup_path" || return 1
  managed_sha256_file journal_candidate_second "$MANAGED_CANDIDATE" || return 1
  [[ "$journal_backup_first" == "$journal_backup_second" &&
     "$journal_candidate_first" == "$journal_candidate_second" ]] || return 1

  MANAGED_JOURNAL_PHASE=prepared
  MANAGED_JOURNAL_BACKUP_SHA256="$journal_backup_first"
  MANAGED_JOURNAL_CANDIDATE_SHA256="$journal_candidate_first"
  MANAGED_JOURNAL_OLD_ENDPOINT="$wgmanaged_old"
  MANAGED_JOURNAL_CANDIDATE_ENDPOINT="$wgmanaged_new"
  MANAGED_JOURNAL_QB_WAS_RUNNING="$wgmanaged_qb"
  if ! managed_journal_memory_is_valid || ! managed_verify_journal_phase prepared; then
    managed_journal_clear
    return 1
  fi
  _managed_journal_commit
}

managed_journal_transition() {
  local wgmanaged_next="${1-}" wgmanaged_current wgmanaged_rc
  [[ $# == 1 ]] || return 1
  managed_journal_load || return 1
  wgmanaged_current="$MANAGED_JOURNAL_PHASE"
  case "$wgmanaged_current:$wgmanaged_next" in
    prepared:client-stopped|client-stopped:tunnel-down|\
    tunnel-down:candidate-installed|candidate-installed:candidate-up|candidate-up:verified) ;;
    *) return 1 ;;
  esac
  managed_verify_journal_phase "$wgmanaged_next" || return 1
  MANAGED_JOURNAL_PHASE="$wgmanaged_next"
  if _managed_journal_commit; then
    return 0
  else
    wgmanaged_rc=$?
  fi
  managed_journal_load >/dev/null 2>&1 || managed_journal_clear
  return "$wgmanaged_rc"
}

_managed_journal_recovery_state_is_consistent() {
  local journal_active_class journal_candidate_class
  managed_journal_memory_is_valid || return 1
  managed_verify_profile_binding "${WG_CONF}.bak-healthcheck" \
    "$MANAGED_JOURNAL_BACKUP_SHA256" "$MANAGED_JOURNAL_OLD_ENDPOINT" || return 1
  managed_classify_active_profile journal_active_class \
    "$MANAGED_JOURNAL_BACKUP_SHA256" "$MANAGED_JOURNAL_CANDIDATE_SHA256" || return 1
  managed_classify_candidate_profile journal_candidate_class \
    "$MANAGED_JOURNAL_CANDIDATE_SHA256" || return 1
  # Published for Task 7's idempotent recovery owner after factual classification.
  # shellcheck disable=SC2034
  MANAGED_JOURNAL_ACTIVE_CLASS="$journal_active_class"
  # shellcheck disable=SC2034
  MANAGED_JOURNAL_CANDIDATE_CLASS="$journal_candidate_class"
  case "$journal_active_class" in backup|candidate) ;; *) return 1 ;; esac
  case "$journal_candidate_class" in
    present)
      managed_verify_profile_binding "$MANAGED_CANDIDATE" \
        "$MANAGED_JOURNAL_CANDIDATE_SHA256" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT"
      ;;
    missing)
      if [[ "$journal_active_class" == backup ]]; then
        managed_verify_profile_binding "$WG_CONF" \
          "$MANAGED_JOURNAL_BACKUP_SHA256" "$MANAGED_JOURNAL_OLD_ENDPOINT"
      else
        [[ "$MANAGED_JOURNAL_PHASE" == verified ]] || return 1
        managed_verify_profile_binding "$WG_CONF" \
          "$MANAGED_JOURNAL_CANDIDATE_SHA256" "$MANAGED_JOURNAL_CANDIDATE_ENDPOINT"
      fi
      ;;
    *) return 1 ;;
  esac
}
