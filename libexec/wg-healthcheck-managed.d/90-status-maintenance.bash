managed_systemctl() {
  systemctl "$@"
}

managed_status_timer() {
  local rc output
  if output="$(managed_systemctl is-enabled "wg-healthcheck@${IFACE}.timer" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" == 0 && "$output" == enabled ]]; then
    printf 'enabled\n'
  elif [[ "$rc" == 1 && "$output" == disabled ]]; then
    printf 'disabled\n'
  else
    printf 'unknown\n'
  fi
}

managed_status_observe_check() {
  local metadata observation
  if [[ ! -e "$STATUS_FILE" && ! -L "$STATUS_FILE" ]]; then printf 'none|0\n'; return; fi
  [[ -f "$STATUS_FILE" && ! -L "$STATUS_FILE" ]] || { printf 'invalid|0\n'; return; }
  metadata="$(owner_mode "$STATUS_FILE")" || { printf 'invalid|0\n'; return; }
  [[ "$metadata" == 0:600 ]] || { printf 'invalid|0\n'; return; }
  observation="$(command awk -F= '
    /^outcome=(healthy|recovered|suppressed|degraded|failed)$/ { outcomes++; outcome=substr($0,9) }
    /^reason=/ { reasons++ }
    /^timestamp=(0|[1-9][0-9]*)$/ { timestamps++; value=substr($0,11) }
    END {
      if (NR == 3 && outcomes == 1 && reasons == 1 && timestamps == 1 && length(value) <= 10)
        print outcome "|" value
      else print "invalid|0"
    }
  ' "$STATUS_FILE" 2>/dev/null)" || observation='invalid|0'
  [[ "$observation" =~ ^(healthy|recovered|suppressed|degraded|failed)\|[0-9]+$ ]] ||
    observation='invalid|0'
  printf '%s\n' "$observation"
}

managed_status_observe_rotation() {
  local metadata value
  if [[ ! -e "$ROTATE_STAMP" && ! -L "$ROTATE_STAMP" ]]; then printf 'none|0\n'; return; fi
  [[ -f "$ROTATE_STAMP" && ! -L "$ROTATE_STAMP" ]] || { printf 'invalid|0\n'; return; }
  metadata="$(owner_mode "$ROTATE_STAMP")" || { printf 'invalid|0\n'; return; }
  [[ "$metadata" == 0:600 ]] || { printf 'invalid|0\n'; return; }
  value="$(read_stamp "$ROTATE_STAMP" 2>/dev/null)" || { printf 'invalid|0\n'; return; }
  printf 'recorded|%s\n' "$value"
}

managed_status_credential_present() {
  local metadata size parent="${AIRVPN_API_KEY_FILE%/*}"
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  [[ "$(owner_mode "$parent")" == 0:700 ]] || return 1
  [[ -f "$AIRVPN_API_KEY_FILE" && ! -L "$AIRVPN_API_KEY_FILE" ]] || return 1
  metadata="$(owner_mode "$AIRVPN_API_KEY_FILE")" || return 1
  [[ "$metadata" == 0:600 ]] || return 1
  size="$(managed_file_size "$AIRVPN_API_KEY_FILE")" || return 1
  [[ "$size" == 65 ]]
}

managed_status_pending() {
  if [[ -e "$MANAGED_SAFETY" || -L "$MANAGED_SAFETY" ]]; then
    managed_safety_load >/dev/null 2>&1 || { printf 'invalid\n'; return; }
    case "$MANAGED_SAFETY_STATE" in
      pending)
        if [[ -e "$ROTATION_PENDING" || -L "$ROTATION_PENDING" ]]; then
          managed_journal_matches_safety >/dev/null 2>&1 || { printf 'invalid\n'; return; }
        fi
        printf 'managed-pending\n'
        ;;
      committed|finalizing)
        [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]] || {
          printf 'invalid\n'; return;
        }
        printf 'managed-%s\n' "$MANAGED_SAFETY_STATE"
        ;;
      *) printf 'invalid\n' ;;
    esac
    return
  fi
  if [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]]; then
    if [[ -e "$MANAGED_CANDIDATE" || -L "$MANAGED_CANDIDATE" ]]; then
      managed_orphan_candidate_is_safe >/dev/null 2>&1 &&
        printf 'orphan-candidate\n' || printf 'invalid\n'
    else
      printf 'none\n'
    fi
    return
  fi
  classify_pending_marker >/dev/null 2>&1 || true
  if [[ "$PENDING_KIND" == v1 ]]; then printf 'endpoint-v1\n'; return; fi
  managed_journal_load >/dev/null 2>&1 && printf 'orphan\n' || printf 'invalid\n'
}

managed_render_status() {
  local json="${1:-0}" mode timer tunnel check_observation rotation_observation
  local last_check last_check_timestamp last_rotation last_rotation_timestamp credential pending qb
  [[ "$json" == 0 || "$json" == 1 ]] || return 1
  mode="$AIRVPN_PROFILE_SOURCE"
  timer="$(managed_status_timer)" || timer=unknown
  if interface_exists; then tunnel=up; else tunnel=down; fi
  check_observation="$(managed_status_observe_check)"
  IFS='|' read -r last_check last_check_timestamp <<< "$check_observation"
  rotation_observation="$(managed_status_observe_rotation)"
  IFS='|' read -r last_rotation last_rotation_timestamp <<< "$rotation_observation"
  if managed_status_credential_present; then credential=true; else credential=false; fi
  pending="$(managed_status_pending)"
  if [[ -z "$QBITTORRENT_CONTAINER" ]]; then
    qb=unmanaged
  elif qbittorrent_binding_present >/dev/null 2>&1; then
    qb=proved
  else
    qb=failed
  fi
  if [[ "$json" == 1 ]]; then
    printf '{"mode":"%s","timer":"%s","tunnel":"%s","last_check":"%s","last_check_timestamp":%s,"last_rotation":"%s","last_rotation_timestamp":%s,"credential_present":%s,"pending":"%s","qbittorrent":"%s"}\n' \
      "$mode" "$timer" "$tunnel" "$last_check" "$last_check_timestamp" \
      "$last_rotation" "$last_rotation_timestamp" "$credential" "$pending" "$qb"
  else
    printf 'mode=%s\ntimer=%s\ntunnel=%s\nlast_check=%s\nlast_check_timestamp=%s\nlast_rotation=%s\nlast_rotation_timestamp=%s\ncredential_present=%s\npending=%s\nqbittorrent=%s\n' \
      "$mode" "$timer" "$tunnel" "$last_check" "$last_check_timestamp" \
      "$last_rotation" "$last_rotation_timestamp" "$credential" "$pending" "$qb"
  fi
}

managed_units_are_inactive() {
  local unit rc
  for unit in "wg-healthcheck@${IFACE}.timer" "wg-healthcheck@${IFACE}.service"; do
    if managed_systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      3) ;;
      0) return 75 ;;
      *) return 1 ;;
    esac
  done
}

managed_reset_global_lock_acquire() {
  local action="${1:-apply}" metadata fd_metadata path_metadata created=0
  managed_transaction_context_is_safe || return 1
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || return 1
  [[ "$AIRVPN_API_LOCK" == "$STATE_DIR/airvpn-api.lock" ]] || return 1
  [[ "$(owner_mode "$STATE_DIR")" == 0:700 ]] || return 1
  if [[ -e "$AIRVPN_API_LOCK" || -L "$AIRVPN_API_LOCK" ]]; then
    [[ -f "$AIRVPN_API_LOCK" && ! -L "$AIRVPN_API_LOCK" ]] || return 1
  else
    if [[ "$action" == dry-run ]]; then
      MANAGED_RESET_LOCK_FD=absent
      return 0
    fi
    ( set -o noclobber; umask 077; : > "$AIRVPN_API_LOCK" ) 2>/dev/null ||
      { [[ -f "$AIRVPN_API_LOCK" && ! -L "$AIRVPN_API_LOCK" ]] || return 1; }
    created=1
  fi
  if (( created )); then chmod 600 -- "$AIRVPN_API_LOCK" || return 1; fi
  metadata="$(owner_mode "$AIRVPN_API_LOCK")" || return 1
  [[ "$metadata" == 0:600 ]] || return 1
  exec {MANAGED_RESET_LOCK_FD}<>"$AIRVPN_API_LOCK" || return 1
  if [[ ! -f "$AIRVPN_API_LOCK" || -L "$AIRVPN_API_LOCK" ]]; then
    exec {MANAGED_RESET_LOCK_FD}>&-
    MANAGED_RESET_LOCK_FD=''
    return 1
  fi
  fd_metadata="$(managed_reset_lock_fd_identity "$MANAGED_RESET_LOCK_FD")" || {
    exec {MANAGED_RESET_LOCK_FD}>&-
    MANAGED_RESET_LOCK_FD=''
    return 1
  }
  path_metadata="$(stat -Lc '%d:%i' -- "$AIRVPN_API_LOCK" 2>/dev/null)" || {
    exec {MANAGED_RESET_LOCK_FD}>&-
    MANAGED_RESET_LOCK_FD=''
    return 1
  }
  if [[ "$fd_metadata" != "$path_metadata" || "$(owner_mode "$AIRVPN_API_LOCK")" != 0:600 ]]; then
    exec {MANAGED_RESET_LOCK_FD}>&-
    MANAGED_RESET_LOCK_FD=''
    return 1
  fi
  flock -n "$MANAGED_RESET_LOCK_FD" || {
    exec {MANAGED_RESET_LOCK_FD}>&-
    MANAGED_RESET_LOCK_FD=''
    return 75
  }
}

managed_reset_lock_fd_identity() {
  stat -Lc '%d:%i' -- "/proc/$BASHPID/fd/${1:?}" 2>/dev/null
}

managed_reset_global_lock_release() {
  local fd="${MANAGED_RESET_LOCK_FD-}" rc=0
  [[ "$fd" == absent ]] && { MANAGED_RESET_LOCK_FD=''; return 0; }
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  flock -u "$fd" || rc=1
  exec {fd}>&- || rc=1
  MANAGED_RESET_LOCK_FD=''
  return "$rc"
}

managed_reset_api_state() {
  local action="${1:?}" rc=0 release_rc=0 parent metadata
  [[ "$action" == dry-run || "$action" == apply ]] || return 1
  [[ "$AIRVPN_API_STATE_FILE" == */"${IFACE}.api-state" ]] || return 1
  managed_api_state_parent_is_secure || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" &&
     ! -e "$MANAGED_SAFETY" && ! -L "$MANAGED_SAFETY" ]] || return 1
  managed_units_are_inactive || { rc=$?; [[ "$rc" == 0 ]] && rc=1; return "$rc"; }
  managed_reset_global_lock_acquire "$action" || return $?
  if ! managed_api_state_parent_is_secure || ! managed_units_are_inactive ||
      [[ -e "$ROTATION_PENDING" || -L "$ROTATION_PENDING" ||
         -e "$MANAGED_SAFETY" || -L "$MANAGED_SAFETY" ]]; then
    rc=1
  fi
  parent="${AIRVPN_API_STATE_FILE%/*}"
  if (( rc == 0 )) && [[ -e "$AIRVPN_API_STATE_FILE" || -L "$AIRVPN_API_STATE_FILE" ]]; then
    if [[ ! -f "$AIRVPN_API_STATE_FILE" || -L "$AIRVPN_API_STATE_FILE" ]]; then
      rc=1
    else
      metadata="$(owner_mode "$AIRVPN_API_STATE_FILE")" || rc=1
      [[ "$metadata" == 0:600 ]] || rc=1
    fi
  fi
  if (( rc == 0 )) && [[ "$action" == apply ]]; then
    if [[ -e "$AIRVPN_API_STATE_FILE" ]]; then
      managed_unlink_path "$AIRVPN_API_STATE_FILE" || rc=1
    fi
    (( rc != 0 )) || managed_sync_directory "$parent" || rc=1
  fi
  managed_reset_global_lock_release || release_rc=1
  (( rc == 0 && release_rc == 0 ))
}

managed_dispatch_command() {
  local command="${1:-}" action="${2:-}" status_json="${3:-0}" credential_fd="${4:-}"
  case "$command" in
    check|provision|adopt|rotate|restore-static|reset-api-state|cleanup-candidate|status) ;;
    *)
      [[ -z "$credential_fd" ]] || close_private_fd "$credential_fd" || return 1
      log "Unknown managed command"
      return 64
      ;;
  esac
  if [[ -n "$credential_fd" && "$command" != provision && "$command" != adopt ]]; then
    close_private_fd "$credential_fd" || return 1
    return 1
  fi
  if [[ "$command" != status && "$command" != check ]] && ! is_root; then
    [[ -z "$credential_fd" ]] || close_private_fd "$credential_fd" || return 1
    return 1
  fi
  case "$command" in
    check) run_healthcheck ;;
    provision) managed_command_provision "$action" "$credential_fd" ;;
    adopt) managed_command_adopt "$action" "$credential_fd" ;;
    rotate) managed_command_rotate "$action" ;;
    restore-static) managed_command_restore_static "$action" ;;
    reset-api-state) managed_reset_api_state "$action" ;;
    cleanup-candidate) managed_command_cleanup_candidate "$action" ;;
    status) managed_render_status "$status_json" ;;
  esac
}
