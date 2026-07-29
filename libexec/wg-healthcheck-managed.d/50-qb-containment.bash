managed_transaction_context_is_safe() {
  (( ${CONTEXT_LOCKED:-0} == 1 )) && [[ -z "${MANAGED_API_LOCK_FD-}" ]]
}

managed_docker_available() {
  command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1
}

managed_docker_command() {
  local wgmanaged_action="${1-}"
  [[ $# == 1 ]] || return 1
  validate_managed_container_name "${QBITTORRENT_CONTAINER-}" || return 1
  managed_uint_is_canonical "${QBITTORRENT_RESTART_TIMEOUT-}" 300 || return 1
  (( 10#$QBITTORRENT_RESTART_TIMEOUT >= 1 )) || return 1
  managed_docker_available || return 1
  case "$wgmanaged_action" in
    inspect)
      timeout "$QBITTORRENT_RESTART_TIMEOUT" docker container inspect \
        --format '{{.State.Running}}' "$QBITTORRENT_CONTAINER" 2>/dev/null
      ;;
    stop)
      timeout "$QBITTORRENT_RESTART_TIMEOUT" docker container stop \
        "$QBITTORRENT_CONTAINER" >/dev/null 2>&1
      ;;
    start)
      timeout "$QBITTORRENT_RESTART_TIMEOUT" docker container start \
        "$QBITTORRENT_CONTAINER" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

managed_docker_target_is_valid() {
  [[ "${1-}" =~ ^[0-9a-f]{64}$ ]] || validate_managed_container_name "${1-}"
}

managed_docker_container_id_is_valid() {
  [[ "${1-}" =~ ^[0-9a-f]{64}$ ]]
}

managed_docker_inspect_identity() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_target="${2:?}"
  local wgmanaged_result
  [[ $# == 2 ]] || return 1
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  managed_docker_target_is_valid "$wgmanaged_target" || return 1
  managed_docker_available || return 1
  wgmanaged_result="$(timeout "$QBITTORRENT_RESTART_TIMEOUT" docker container inspect \
    --format '{{.Id}}|{{.State.Running}}' "$wgmanaged_target" 2>/dev/null)" || return 1
  [[ -n "$wgmanaged_result" && "$wgmanaged_result" != *$'\r'* &&
     "$wgmanaged_result" != *$'\n'* ]] || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_result"
}

managed_docker_stop_target() {
  local wgmanaged_target="${1:?}"
  managed_docker_target_is_valid "$wgmanaged_target" || return 1
  managed_docker_available || return 1
  timeout "$QBITTORRENT_RESTART_TIMEOUT" docker container stop "$wgmanaged_target" \
    >/dev/null 2>&1
}

managed_docker_start_target() {
  local wgmanaged_target="${1:?}"
  managed_docker_target_is_valid "$wgmanaged_target" || return 1
  managed_docker_available || return 1
  timeout "$QBITTORRENT_RESTART_TIMEOUT" docker container start "$wgmanaged_target" \
    >/dev/null 2>&1
}

managed_docker_inspect_name() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_name="${2:?}"
  validate_managed_container_name "$wgmanaged_name" || return 1
  managed_docker_inspect_identity "$wgmanaged_output_variable" "$wgmanaged_name"
}

managed_docker_inspect_id() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_id="${2:?}"
  managed_docker_container_id_is_valid "$wgmanaged_id" || return 1
  managed_docker_inspect_identity "$wgmanaged_output_variable" "$wgmanaged_id"
}

managed_docker_stop_name() {
  local wgmanaged_name="${1:?}"
  validate_managed_container_name "$wgmanaged_name" || return 1
  managed_docker_stop_target "$wgmanaged_name"
}

managed_docker_stop_id() {
  local wgmanaged_id="${1:?}"
  managed_docker_container_id_is_valid "$wgmanaged_id" || return 1
  managed_docker_stop_target "$wgmanaged_id"
}

managed_docker_start_id() {
  local wgmanaged_id="${1:?}"
  managed_docker_container_id_is_valid "$wgmanaged_id" || return 1
  managed_docker_start_target "$wgmanaged_id"
}

managed_qb_parse_inspection() {
  local wgmanaged_output_id="${1:?}" wgmanaged_output_state="${2:?}"
  local wgmanaged_inspection="${3-}" wgmanaged_id wgmanaged_state
  local LC_ALL=C
  managed_output_variable_is_valid "$wgmanaged_output_id" || return 1
  managed_output_variable_is_valid "$wgmanaged_output_state" || return 1
  [[ "$wgmanaged_output_id" != "$wgmanaged_output_state" ]] || return 1
  [[ "$wgmanaged_inspection" =~ ^([0-9a-f]{64})[|](true|false)$ ]] || return 1
  wgmanaged_id="${BASH_REMATCH[1]}"
  wgmanaged_state="${BASH_REMATCH[2]}"
  case "$wgmanaged_state" in
    true) wgmanaged_state=running ;;
    false) wgmanaged_state=stopped ;;
    *) return 1 ;;
  esac
  printf -v "$wgmanaged_output_id" '%s' "$wgmanaged_id"
  printf -v "$wgmanaged_output_state" '%s' "$wgmanaged_state"
}

managed_qb_snapshot() {
  local qb_inspection qb_observed_id qb_observed_state qb_profile_ipv4
  if [[ -z "${QBITTORRENT_CONTAINER-}" ]]; then
    MANAGED_QB_INTENT=unmanaged
    MANAGED_QB_CONTAINER=-
    MANAGED_QB_CONTAINER_ID=-
    MANAGED_QB_PROCESS=-
    MANAGED_QB_LISTEN_IPV4=-
    MANAGED_QB_LISTEN_PORT=0
  else
    validate_managed_container_name "$QBITTORRENT_CONTAINER" || return 1
    validate_process_name "${QBITTORRENT_PROCESS_NAME-}" || return 1
    validate_ip_address "${QBITTORRENT_LISTEN_IP-}" || return 1
    managed_uint_is_canonical "${QBITTORRENT_LISTEN_PORT-}" 65535 || return 1
    (( 10#$QBITTORRENT_LISTEN_PORT >= 1 )) || return 1
    managed_profile_interface_ipv4 qb_profile_ipv4 "$WG_CONF" || return 1
    [[ "$qb_profile_ipv4" == "$QBITTORRENT_LISTEN_IP" ]] || return 1
    managed_docker_inspect_name qb_inspection "$QBITTORRENT_CONTAINER" || return 1
    managed_qb_parse_inspection qb_observed_id qb_observed_state "$qb_inspection" || return 1
    MANAGED_QB_INTENT="$qb_observed_state"
    MANAGED_QB_CONTAINER="$QBITTORRENT_CONTAINER"
    MANAGED_QB_CONTAINER_ID="$qb_observed_id"
    MANAGED_QB_PROCESS="$QBITTORRENT_PROCESS_NAME"
    MANAGED_QB_LISTEN_IPV4="$QBITTORRENT_LISTEN_IP"
    MANAGED_QB_LISTEN_PORT="$QBITTORRENT_LISTEN_PORT"
  fi
  # The pending safety writer consumes this snapshot; publishing the same values here also
  # makes the strict checkpoint owner usable before the first on-disk re-read.
  MANAGED_SAFETY_QB_INTENT="$MANAGED_QB_INTENT"
  MANAGED_SAFETY_QB_CONTAINER="$MANAGED_QB_CONTAINER"
  MANAGED_SAFETY_QB_CONTAINER_ID="$MANAGED_QB_CONTAINER_ID"
  MANAGED_SAFETY_QB_PROCESS="$MANAGED_QB_PROCESS"
  MANAGED_SAFETY_QB_LISTEN_IPV4="$MANAGED_QB_LISTEN_IPV4"
  MANAGED_SAFETY_QB_LISTEN_PORT="$MANAGED_QB_LISTEN_PORT"
}

managed_qb_current_tuple_matches_record() {
  case "${MANAGED_SAFETY_QB_INTENT-}" in
    unmanaged) [[ -z "${QBITTORRENT_CONTAINER-}" ]] ;;
    running|stopped)
      [[ "${QBITTORRENT_CONTAINER-}" == "$MANAGED_SAFETY_QB_CONTAINER" &&
         "${QBITTORRENT_PROCESS_NAME-}" == "$MANAGED_SAFETY_QB_PROCESS" &&
         "${QBITTORRENT_LISTEN_IP-}" == "$MANAGED_SAFETY_QB_LISTEN_IPV4" &&
         "${QBITTORRENT_LISTEN_PORT-}" == "$MANAGED_SAFETY_QB_LISTEN_PORT" ]]
      ;;
    *) return 1 ;;
  esac
}

managed_qb_inspect_name_matches() {
  local wgmanaged_target="${1:?}" wgmanaged_expected_id="${2:?}"
  local wgmanaged_expected_state="${3:?}" qb_inspection qb_observed_id qb_observed_state
  managed_docker_inspect_name qb_inspection "$wgmanaged_target" || return 1
  managed_qb_parse_inspection qb_observed_id qb_observed_state "$qb_inspection" || return 1
  [[ "$qb_observed_id" == "$wgmanaged_expected_id" &&
     "$qb_observed_state" == "$wgmanaged_expected_state" ]]
}

managed_qb_inspect_id_matches() {
  local wgmanaged_expected_id="${1:?}" wgmanaged_expected_state="${2:?}"
  local qb_inspection qb_observed_id qb_observed_state
  managed_docker_inspect_id qb_inspection "$wgmanaged_expected_id" || return 1
  managed_qb_parse_inspection qb_observed_id qb_observed_state "$qb_inspection" || return 1
  [[ "$qb_observed_id" == "$wgmanaged_expected_id" &&
     "$qb_observed_state" == "$wgmanaged_expected_state" ]]
}

managed_qb_contain_recorded_and_current() {
  local wgmanaged_rc=0 wgmanaged_current="${QBITTORRENT_CONTAINER-}"
  local wgmanaged_recorded="${MANAGED_SAFETY_QB_CONTAINER_ID-}"
  if managed_docker_container_id_is_valid "$wgmanaged_recorded"; then
    managed_docker_stop_id "$wgmanaged_recorded" || wgmanaged_rc=1
  fi
  if [[ -n "$wgmanaged_current" ]]; then
    if validate_managed_container_name "$wgmanaged_current"; then
      managed_docker_stop_name "$wgmanaged_current" || wgmanaged_rc=1
    else
      wgmanaged_rc=1
    fi
  fi
  if managed_docker_container_id_is_valid "$wgmanaged_recorded"; then
    managed_qb_inspect_id_matches "$wgmanaged_recorded" stopped ||
      wgmanaged_rc=1
  fi
  if [[ -n "$wgmanaged_current" ]] &&
      validate_managed_container_name "$wgmanaged_current"; then
    local qb_inspection qb_current_id qb_current_state
    if managed_docker_inspect_name qb_inspection "$wgmanaged_current" &&
        managed_qb_parse_inspection qb_current_id qb_current_state "$qb_inspection" &&
        [[ -n "$qb_current_id" && "$qb_current_state" == stopped ]]; then
      :
    else
      wgmanaged_rc=1
    fi
  fi
  return "$wgmanaged_rc"
}

managed_qb_rollback_containment_checkpoint() {
  local wgmanaged_current="${QBITTORRENT_CONTAINER-}" wgmanaged_rc=0
  case "${MANAGED_SAFETY_QB_INTENT-}" in
    unmanaged) ;;
    running|stopped)
      managed_qb_inspect_id_matches "${MANAGED_SAFETY_QB_CONTAINER_ID-}" stopped ||
        wgmanaged_rc=1
      ;;
    *) wgmanaged_rc=1 ;;
  esac
  if [[ -n "$wgmanaged_current" ]]; then
    if validate_managed_container_name "$wgmanaged_current"; then
      local qb_inspection qb_current_id qb_current_state
      if ! managed_docker_inspect_name qb_inspection "$wgmanaged_current" ||
          ! managed_qb_parse_inspection qb_current_id qb_current_state "$qb_inspection" ||
          [[ -z "$qb_current_id" || "$qb_current_state" != stopped ]]; then
        wgmanaged_rc=1
      fi
    else
      wgmanaged_rc=1
    fi
  fi
  if (( wgmanaged_rc != 0 )); then
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
    return 1
  fi
}

managed_qb_containment_checkpoint() {
  local wgmanaged_checkpoint="${1-}"
  [[ $# == 1 && "$wgmanaged_checkpoint" =~ ^[a-z0-9-]{1,40}$ ]] || return 1
  MANAGED_QB_CHECKPOINT="$wgmanaged_checkpoint"
  if [[ "$wgmanaged_checkpoint" == rollback-* ]]; then
    managed_qb_rollback_containment_checkpoint
    return
  fi
  if [[ "${MANAGED_SAFETY_QB_INTENT-}" == unmanaged ]]; then
    if managed_qb_current_tuple_matches_record; then
      return 0
    fi
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
    return 1
  fi
  if ! managed_qb_current_tuple_matches_record ||
      ! managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
        "$MANAGED_SAFETY_QB_CONTAINER_ID" stopped; then
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
    return 1
  fi
}

managed_qb_restore_recorded_intent() {
  MANAGED_QB_CHECKPOINT=restore
  case "${MANAGED_SAFETY_QB_INTENT-}" in
    unmanaged)
      if managed_qb_current_tuple_matches_record; then return 0; fi
      managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
      return 1
      ;;
    stopped)
      managed_qb_containment_checkpoint restore-stopped
      return
      ;;
    running) ;;
    *) return 1 ;;
  esac
  MANAGED_QB_CHECKPOINT=restore
  if ! managed_qb_current_tuple_matches_record ||
      ! managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
        "$MANAGED_SAFETY_QB_CONTAINER_ID" stopped; then
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
    return 1
  fi
  if ! managed_docker_start_id "$MANAGED_SAFETY_QB_CONTAINER_ID" ||
      ! managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
        "$MANAGED_SAFETY_QB_CONTAINER_ID" running ||
      ! managed_wait_for_qbittorrent ||
      ! qbittorrent_binding_present ||
      ! managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
        "$MANAGED_SAFETY_QB_CONTAINER_ID" running; then
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
    return 1
  fi
}

managed_qb_verify_recorded_intent() {
  MANAGED_QB_CHECKPOINT="${1:-final-proof}"
  case "${MANAGED_SAFETY_QB_INTENT-}" in
    unmanaged) managed_qb_current_tuple_matches_record ;;
    stopped)
      managed_qb_current_tuple_matches_record &&
        managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
          "$MANAGED_SAFETY_QB_CONTAINER_ID" stopped
      ;;
    running)
      managed_qb_current_tuple_matches_record &&
        managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
          "$MANAGED_SAFETY_QB_CONTAINER_ID" running &&
        qbittorrent_binding_present &&
        managed_qb_inspect_name_matches "$MANAGED_SAFETY_QB_CONTAINER" \
          "$MANAGED_SAFETY_QB_CONTAINER_ID" running
      ;;
    *) return 1 ;;
  esac || {
    managed_qb_contain_recorded_and_current >/dev/null 2>&1 || true
    return 1
  }
}

managed_qbittorrent_state_core() {
  local wgmanaged_inspected
  [[ -v wgmanaged_qb_state_carrier ]] || return 1
  if [[ -z "${QBITTORRENT_CONTAINER-}" ]]; then
    wgmanaged_qb_state_carrier=unconfigured
    return 0
  fi
  validate_managed_container_name "$QBITTORRENT_CONTAINER" || return 1
  wgmanaged_inspected="$(managed_docker_command inspect)" || return 1
  [[ -n "$wgmanaged_inspected" &&
     "$wgmanaged_inspected" != *$'\r'* &&
     "$wgmanaged_inspected" != *$'\n'* ]] || return 1
  case "$wgmanaged_inspected" in
    true) wgmanaged_qb_state_carrier=running ;;
    false) wgmanaged_qb_state_carrier=stopped ;;
    *) return 1 ;;
  esac
}

managed_qbittorrent_state() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_qb_state_carrier=''
  [[ $# == 1 ]] || return 1
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  managed_qbittorrent_state_core || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_qb_state_carrier"
}

managed_qbittorrent_ensure_stopped() {
  local transaction_qb_state=''
  if ! managed_qbittorrent_state transaction_qb_state; then
    if [[ -n "${QBITTORRENT_CONTAINER-}" ]] &&
        validate_managed_container_name "$QBITTORRENT_CONTAINER"; then
      managed_docker_command stop >/dev/null 2>&1 || return 1
      managed_qbittorrent_state transaction_qb_state || return 1
      [[ "$transaction_qb_state" == stopped ]]
      return
    fi
    return 1
  fi
  case "$transaction_qb_state" in
    unconfigured|stopped) return 0 ;;
    running)
      managed_docker_command stop || return 1
      managed_qbittorrent_state transaction_qb_state || return 1
      [[ "$transaction_qb_state" == stopped ]]
      ;;
    *) return 1 ;;
  esac
}

managed_wait_for_qbittorrent() {
  managed_uint_is_canonical "${QBITTORRENT_RESTART_DELAY-}" 300 || return 1
  sleep "$QBITTORRENT_RESTART_DELAY"
}

managed_qbittorrent_restore_state() {
  local wgmanaged_was_running="${1-}" transaction_qb_state=''
  [[ $# == 1 && ( "$wgmanaged_was_running" == 0 || "$wgmanaged_was_running" == 1 ) ]] ||
    return 1
  if [[ "$wgmanaged_was_running" == 0 ]]; then
    managed_qbittorrent_ensure_stopped
    return
  fi
  if ! managed_qbittorrent_state transaction_qb_state; then
    managed_qbittorrent_ensure_stopped >/dev/null 2>&1 || true
    return 1
  fi
  case "$transaction_qb_state" in
    stopped)
      if ! managed_docker_command start; then
        managed_qbittorrent_ensure_stopped >/dev/null 2>&1 || true
        return 1
      fi
      ;;
    running) ;;
    *)
      managed_qbittorrent_ensure_stopped >/dev/null 2>&1 || true
      return 1
      ;;
  esac
  if ! managed_qbittorrent_state transaction_qb_state ||
      [[ "$transaction_qb_state" != running ]] ||
      ! managed_wait_for_qbittorrent ||
      ! qbittorrent_binding_present; then
    managed_qbittorrent_ensure_stopped >/dev/null 2>&1 || true
    return 1
  fi
}
