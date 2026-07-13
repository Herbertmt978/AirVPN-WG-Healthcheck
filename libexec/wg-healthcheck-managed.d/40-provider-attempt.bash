managed_admin_dry_run_bypass() {
  local command="${1-}" action_mode="${2-}"
  [[ "$action_mode" == dry-run ]] || return 1
  case "$command" in provision|adopt|rotate) return 0 ;; *) return 1 ;; esac
}

managed_capture_owner_mode() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_path="${2:?}"
  local wgmanaged_captured_metadata
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  wgmanaged_captured_metadata="$(owner_mode "$wgmanaged_path")" || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_captured_metadata"
}

managed_chmod_api_lock() { chmod 600 -- "$1"; }
managed_flock_api_lock() { flock -x "$1"; }

managed_global_api_lock_acquire() {
  local credential_fd="${1-}" parent metadata
  if [[ -n "$credential_fd" ]]; then validate_credential_fd_number "$credential_fd" || return 1; fi
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  [[ "${LOCK_FD-}" =~ ^[0-9]+$ ]] || return 1
  [[ -z "${MANAGED_API_LOCK_FD-}" ]] || return 1
  [[ -n "${AIRVPN_API_LOCK:-}" && "$AIRVPN_API_LOCK" == "${STATE_DIR%/}/airvpn-api.lock" ]] || return 1
  parent="${AIRVPN_API_LOCK%/*}"
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  managed_call_without_private_fd "$credential_fd" managed_capture_owner_mode metadata "$parent" || return 1
  [[ "$metadata" == 0:700 ]] || return 1
  if [[ -e "$AIRVPN_API_LOCK" || -L "$AIRVPN_API_LOCK" ]]; then
    [[ -f "$AIRVPN_API_LOCK" && ! -L "$AIRVPN_API_LOCK" ]] || return 1
  fi
  MANAGED_API_LOCK_FD=''
  exec {MANAGED_API_LOCK_FD}>"$AIRVPN_API_LOCK" || return 1
  if ! managed_call_without_private_fd "$credential_fd" managed_chmod_api_lock "$AIRVPN_API_LOCK"; then
    exec {MANAGED_API_LOCK_FD}>&-
    MANAGED_API_LOCK_FD=''
    return 1
  fi
  managed_call_without_private_fd "$credential_fd" managed_capture_owner_mode metadata "$AIRVPN_API_LOCK" || {
    exec {MANAGED_API_LOCK_FD}>&-
    MANAGED_API_LOCK_FD=''
    return 1
  }
  [[ "$metadata" == 0:600 ]] || {
    exec {MANAGED_API_LOCK_FD}>&-
    MANAGED_API_LOCK_FD=''
    return 1
  }
  managed_call_without_private_fd "$credential_fd" managed_flock_api_lock "$MANAGED_API_LOCK_FD" || {
    exec {MANAGED_API_LOCK_FD}>&-
    MANAGED_API_LOCK_FD=''
    return 1
  }
}

managed_global_api_lock_release() {
  local lock_fd="${MANAGED_API_LOCK_FD-}" rc=0
  [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 1
  flock -u "$lock_fd" || rc=1
  exec {lock_fd}>&- || rc=1
  MANAGED_API_LOCK_FD=''
  return "$rc"
}

managed_call_without_private_fd() {
  local private_fd="${1-}"
  shift || return 1
  if [[ -z "$private_fd" ]]; then
    "$@"
  else
    run_with_private_fd_closed "$private_fd" "$@"
  fi
}

managed_wall_clock_epoch() {
  local wgmanaged_phase="${1-}"
  [[ $# == 1 && ( "$wgmanaged_phase" == attempt || "$wgmanaged_phase" == outcome ) ]] ||
    return 1
  current_epoch
}

managed_capture_wall_clock_epoch_closed() {
  local wgmanaged_phase="${1:?}" wgmanaged_epoch
  [[ -v wgmanaged_clock_epoch_carrier ]] || return 1
  wgmanaged_epoch="$(managed_wall_clock_epoch "$wgmanaged_phase")" || return 1
  managed_epoch_is_valid "$wgmanaged_epoch" || return 1
  wgmanaged_clock_epoch_carrier="$wgmanaged_epoch"
}

managed_select_airvpn_candidate_closed() {
  local wgmanaged_now="${1:?}" wgmanaged_current_endpoint="${2-}"
  local wgmanaged_candidate_output
  local -a wgmanaged_exclusion_args_carrier=()
  [[ -v wgmanaged_selection_result_carrier ]] || return 1
  managed_api_exclusion_args_core "$wgmanaged_now" || return 1
  validate_secure_executable "$AIRVPN_API_HELPER" || return 1
  wgmanaged_candidate_output="$(
    "$AIRVPN_API_HELPER" select \
      --url "$AIRVPN_STATUS_URL" \
      --countries "$AIRVPN_COUNTRIES" \
      --port "$AIRVPN_WG_PORT" \
      --current-endpoint "$wgmanaged_current_endpoint" \
      --timeout "$AIRVPN_API_TIMEOUT" \
      "${wgmanaged_exclusion_args_carrier[@]}"
  )" || return 1
  [[ -n "$wgmanaged_candidate_output" &&
     "$wgmanaged_candidate_output" != *$'\r'* &&
     "$wgmanaged_candidate_output" != *$'\n'* ]] || return 1
  wgmanaged_selection_result_carrier="$wgmanaged_candidate_output"
}

managed_select_airvpn_candidate() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_now="${2:?}"
  local wgmanaged_credential_fd="${3-}" wgmanaged_current_endpoint="${4-}"
  local wgmanaged_selection_result_carrier=''
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  if [[ -n "$wgmanaged_credential_fd" ]]; then
    validate_credential_fd_number "$wgmanaged_credential_fd" || return 1
  fi
  managed_call_without_private_fd "$wgmanaged_credential_fd" \
    managed_select_airvpn_candidate_closed "$wgmanaged_now" "$wgmanaged_current_endpoint" ||
    return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_selection_result_carrier"
}

managed_fail_candidate_before_rollback() {
  local now="${1:?}" server="${2:?}" rollback_callback="${3:?}"
  local persistence_rc=0 rollback_rc=0
  shift 3 || return 1
  [[ "$rollback_callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  declare -F "$rollback_callback" >/dev/null || return 1
  if managed_api_state_add_exclusion "$server" "$now"; then
    managed_api_state_write || persistence_rc=1
  else
    persistence_rc=1
  fi
  "$rollback_callback" "$@" || rollback_rc=1
  (( persistence_rc == 0 && rollback_rc == 0 ))
}

# Provider callbacks receive only the private credential descriptor number and may set
# the four MANAGED_API_PROVIDER_* result fields. Downstream is invoked only after the
# authenticated outcome is durable and this process has released the global API lock.
managed_run_authenticated_attempt() {
  local wgmanaged_administrative_bypass="${1:-0}" wgmanaged_credential_fd="${2-}"
  local wgmanaged_provider_callback="${3:?}" wgmanaged_downstream_callback="${4:?}"
  local wgmanaged_preflight_callback="${5-}" wgmanaged_preflight_cleanup="${6-}"
  local active_credential_fd="$wgmanaged_credential_fd"
  local wgmanaged_attempt_now wgmanaged_outcome_now wgmanaged_provider_rc wgmanaged_outcome
  local wgmanaged_outcome_rc wgmanaged_release_rc wgmanaged_clock_epoch_carrier=''
  local wgmanaged_preflight_started=0
  [[ $# == 4 || $# == 6 ]] || return 1
  [[ "$wgmanaged_provider_callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "$wgmanaged_downstream_callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  declare -F "$wgmanaged_provider_callback" >/dev/null || return 1
  declare -F "$wgmanaged_downstream_callback" >/dev/null || return 1
  if [[ -n "$wgmanaged_preflight_callback" ]]; then
    [[ "$wgmanaged_preflight_callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$wgmanaged_preflight_cleanup" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    declare -F "$wgmanaged_preflight_callback" >/dev/null || return 1
    declare -F "$wgmanaged_preflight_cleanup" >/dev/null || return 1
  fi
  if [[ -n "$wgmanaged_credential_fd" ]]; then
    validate_credential_fd_number "$wgmanaged_credential_fd" || return 1
  fi

  if ! managed_global_api_lock_acquire "$wgmanaged_credential_fd"; then
    [[ -z "$wgmanaged_credential_fd" ]] || close_private_fd "$wgmanaged_credential_fd" ||
      return 1
    return 1
  fi

  managed_call_without_private_fd "$wgmanaged_credential_fd" \
    managed_capture_wall_clock_epoch_closed attempt
  wgmanaged_outcome_rc=$?
  if (( wgmanaged_outcome_rc == 0 )); then
    wgmanaged_attempt_now="$wgmanaged_clock_epoch_carrier"
    managed_call_without_private_fd "$wgmanaged_credential_fd" \
      managed_api_state_load "$wgmanaged_attempt_now"
    wgmanaged_outcome_rc=$?
  fi
  if (( wgmanaged_outcome_rc == 0 )); then
    if [[ -z "$active_credential_fd" ]]; then
      open_installed_api_key active_credential_fd
      wgmanaged_outcome_rc=$?
    fi
  fi
  if (( wgmanaged_outcome_rc == 0 )); then
    managed_api_state_refresh_identity \
      "$wgmanaged_attempt_now" "$active_credential_fd"
    wgmanaged_outcome_rc=$?
  fi
  if (( wgmanaged_outcome_rc == 0 )); then
    managed_call_without_private_fd "$active_credential_fd" \
      managed_api_gate_before_preflight "$wgmanaged_attempt_now" "$wgmanaged_administrative_bypass"
    wgmanaged_outcome_rc=$?
  fi
  if (( wgmanaged_outcome_rc == 0 )); then
    if [[ -n "$wgmanaged_preflight_callback" ]]; then
      wgmanaged_preflight_started=1
      managed_call_without_private_fd "$active_credential_fd" "$wgmanaged_preflight_callback" \
        "$wgmanaged_attempt_now"
      wgmanaged_outcome_rc=$?
    fi
  fi
  if (( wgmanaged_outcome_rc == 0 )); then
    managed_call_without_private_fd "$active_credential_fd" \
      managed_api_record_attempt "$wgmanaged_attempt_now" "$wgmanaged_administrative_bypass"
    wgmanaged_outcome_rc=$?
  fi
  if (( wgmanaged_outcome_rc != 0 )); then
    if (( wgmanaged_preflight_started )) && [[ -n "$wgmanaged_preflight_cleanup" ]]; then
      managed_call_without_private_fd "$active_credential_fd" \
        "$wgmanaged_preflight_cleanup" >/dev/null 2>&1 || true
    fi
    managed_call_without_private_fd "$active_credential_fd" \
      managed_global_api_lock_release || wgmanaged_outcome_rc=1
    [[ -z "$active_credential_fd" ]] ||
      close_private_fd "$active_credential_fd" || wgmanaged_outcome_rc=1
    return "$wgmanaged_outcome_rc"
  fi

  MANAGED_API_PROVIDER_FAILURE_CLASS=''
  MANAGED_API_PROVIDER_RETRY_AFTER=''
  MANAGED_API_PROVIDER_FAILED_SERVER=''
  MANAGED_API_PROVIDER_JITTER=''
  if "$wgmanaged_provider_callback" "$active_credential_fd"; then
    wgmanaged_provider_rc=0
  else
    wgmanaged_provider_rc=$?
  fi
  [[ -z "$active_credential_fd" ]] ||
    close_private_fd "$active_credential_fd" || wgmanaged_provider_rc=1

  wgmanaged_clock_epoch_carrier=''
  if managed_call_without_private_fd "$active_credential_fd" \
      managed_capture_wall_clock_epoch_closed outcome; then
    wgmanaged_outcome_now="$wgmanaged_clock_epoch_carrier"
    wgmanaged_outcome_rc=0
  else
    wgmanaged_outcome_rc=1
  fi

  case "$wgmanaged_provider_rc" in
    0) wgmanaged_outcome=none ;;
    4)
      case "$MANAGED_API_PROVIDER_FAILURE_CLASS" in
        ''|auth) wgmanaged_outcome=auth ;;
        device) wgmanaged_outcome=device ;;
        *) wgmanaged_outcome=transient ;;
      esac
      ;;
    5) wgmanaged_outcome=rate ;;
    7) wgmanaged_outcome=device ;;
    *) wgmanaged_outcome=transient ;;
  esac
  if (( wgmanaged_outcome_rc == 0 )); then
    if [[ "$wgmanaged_outcome" == none ]]; then
      managed_api_record_outcome "$wgmanaged_outcome_now" none '' '' 0
    else
      managed_api_record_outcome "$wgmanaged_outcome_now" "$wgmanaged_outcome" \
        "$MANAGED_API_PROVIDER_RETRY_AFTER" "$MANAGED_API_PROVIDER_FAILED_SERVER" \
        "$MANAGED_API_PROVIDER_JITTER"
    fi
    wgmanaged_outcome_rc=$?
  fi
  if managed_global_api_lock_release; then
    wgmanaged_release_rc=0
  else
    wgmanaged_release_rc=$?
  fi
  (( wgmanaged_outcome_rc == 0 && wgmanaged_release_rc == 0 )) || return 1
  (( wgmanaged_provider_rc == 0 )) || return "$wgmanaged_provider_rc"
  "$wgmanaged_downstream_callback"
}
