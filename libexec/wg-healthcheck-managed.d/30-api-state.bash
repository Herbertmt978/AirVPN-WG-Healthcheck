managed_api_metadata_is_valid() {
  local device="${1-}" inode="${2-}" mtime="${3-}" size="${4-}"
  managed_uint_is_canonical "$device" 18446744073709551615 || return 1
  managed_uint_is_canonical "$inode" 18446744073709551615 || return 1
  managed_uint_is_canonical "$mtime" 9223372036854775807 || return 1
  case "$size" in
    0) [[ "$device" == 0 && "$inode" == 0 && "$mtime" == 0 ]] ;;
    65) [[ "$inode" != 0 ]] ;;
    *) return 1 ;;
  esac
}

# Defaults exist only in memory. Passing 1 requires the complete identity that every
# durable v1 record must carry.
managed_api_state_memory_is_valid() {
  local persistent="${1:-0}" now="${MANAGED_API_STATE_NOW-}"
  local observed="${MANAGED_API_OBSERVED_AT-}" maximum_backoff maximum_exclusion
  local index name expiry previous_epoch=''
  local -A seen=()
  [[ "$persistent" == 0 || "$persistent" == 1 ]] || return 1
  managed_epoch_is_valid "$now" || return 1
  managed_epoch_is_valid "$observed" || return 1
  [[ "$now" == "$observed" ]] || return 1
  managed_epoch_is_valid "${MANAGED_API_WINDOW_START-}" || return 1
  managed_epoch_is_valid "${MANAGED_API_BACKOFF_UNTIL-}" || return 1
  (( 10#$MANAGED_API_WINDOW_START <= 10#$observed )) || return 1
  maximum_backoff=$((10#$observed + 86400))
  (( maximum_backoff <= 4294967295 )) || return 1
  (( 10#$MANAGED_API_BACKOFF_UNTIL <= maximum_backoff )) || return 1
  managed_uint_is_canonical "${MANAGED_API_ATTEMPT_COUNT-}" 6 || return 1
  (( 10#$MANAGED_API_ATTEMPT_COUNT == ${#MANAGED_API_ATTEMPT_EPOCHS[@]} )) || return 1
  if (( 10#$MANAGED_API_ATTEMPT_COUNT == 0 )); then
    [[ "$MANAGED_API_WINDOW_START" == "$observed" ]] || return 1
  else
    [[ "$MANAGED_API_WINDOW_START" == "${MANAGED_API_ATTEMPT_EPOCHS[0]}" ]] || return 1
  fi
  for ((index = 0; index < ${#MANAGED_API_ATTEMPT_EPOCHS[@]}; index++)); do
    managed_epoch_is_valid "${MANAGED_API_ATTEMPT_EPOCHS[$index]}" || return 1
    (( 10#${MANAGED_API_ATTEMPT_EPOCHS[$index]} <= 10#$observed )) || return 1
    (( 10#$observed - 10#${MANAGED_API_ATTEMPT_EPOCHS[$index]} < 86400 )) || return 1
    if [[ -n "$previous_epoch" ]]; then
      (( 10#${MANAGED_API_ATTEMPT_EPOCHS[$index]} >= 10#$previous_epoch )) || return 1
    fi
    previous_epoch="${MANAGED_API_ATTEMPT_EPOCHS[$index]}"
  done
  case "${MANAGED_API_FAILURE_CLASS-}" in
    none|auth|device|rate|transient) ;;
    *) return 1 ;;
  esac
  case "$MANAGED_API_FAILURE_CLASS" in
    none) [[ "$MANAGED_API_BACKOFF_UNTIL" == 0 ]] || return 1 ;;
    *) (( 10#$MANAGED_API_BACKOFF_UNTIL > 0 )) || return 1 ;;
  esac
  managed_api_metadata_is_valid \
    "${MANAGED_API_CREDENTIAL_DEVICE-}" \
    "${MANAGED_API_CREDENTIAL_INODE-}" \
    "${MANAGED_API_CREDENTIAL_MTIME-}" \
    "${MANAGED_API_CREDENTIAL_SIZE-}" || return 1
  if [[ "${MANAGED_API_CREDENTIAL_SIZE-}" == 65 ]]; then
    (( 10#$MANAGED_API_CREDENTIAL_MTIME <= 10#$observed + 300 )) || return 1
  fi
  if [[ -n "${MANAGED_API_CONFIGURED_DEVICE-}" ]]; then
    managed_device_name_is_valid "$MANAGED_API_CONFIGURED_DEVICE" || return 1
  fi
  if (( persistent )) && {
       [[ "$MANAGED_API_CREDENTIAL_SIZE" != 65 ]] ||
       [[ -z "$MANAGED_API_CONFIGURED_DEVICE" ]];
     }; then
    return 1
  fi
  (( ${#MANAGED_API_EXCLUDE_NAMES[@]} == ${#MANAGED_API_EXCLUDE_EXPIRIES[@]} )) || return 1
  (( ${#MANAGED_API_EXCLUDE_NAMES[@]} <= 16 )) || return 1
  maximum_exclusion=$((10#$observed + 21600))
  for ((index = 0; index < ${#MANAGED_API_EXCLUDE_NAMES[@]}; index++)); do
    name="${MANAGED_API_EXCLUDE_NAMES[$index]}"
    expiry="${MANAGED_API_EXCLUDE_EXPIRIES[$index]}"
    managed_server_name_is_valid "$name" || return 1
    [[ -z "${seen[$name]+present}" ]] || return 1
    seen["$name"]=1
    managed_epoch_is_valid "$expiry" || return 1
    (( 10#$expiry <= maximum_exclusion )) || return 1
  done
}

managed_api_state_load() {
  local now="${1:?}" size exclude_count attempt_count index expected_index offset
  local observed window backoff failure
  local credential_device credential_inode credential_mtime credential_size configured_device
  local line name expiry
  local -a lines=() attempt_epochs=() names=() expiries=()
  local -A seen=()
  managed_epoch_is_valid "$now" || return 1
  managed_api_state_parent_is_secure || return 1
  if [[ ! -e "$AIRVPN_API_STATE_FILE" && ! -L "$AIRVPN_API_STATE_FILE" ]]; then
    managed_api_state_defaults "$now"
    return $?
  fi
  managed_api_state_file_is_secure || return 1
  size="$(managed_file_size "$AIRVPN_API_STATE_FILE")" || return 1
  managed_uint_is_canonical "$size" 4096 || return 1
  (( 10#$size > 0 )) || return 1
  managed_api_state_bytes_are_strict "$AIRVPN_API_STATE_FILE" || return 1
  mapfile -t lines < "$AIRVPN_API_STATE_FILE" || return 1
  (( ${#lines[@]} >= 12 && ${#lines[@]} <= 34 )) || return 1
  for line in "${lines[@]}"; do (( ${#line} <= 256 )) || return 1; done

  [[ "${lines[0]}" == version=1 ]] || return 1
  [[ "${lines[1]}" =~ ^observed_at=(0|[1-9][0-9]*)$ ]] || return 1
  observed="${BASH_REMATCH[1]}"
  [[ "${lines[2]}" =~ ^window_start=(0|[1-9][0-9]*)$ ]] || return 1
  window="${BASH_REMATCH[1]}"
  [[ "${lines[3]}" =~ ^attempt_count=(0|[1-9][0-9]*)$ ]] || return 1
  attempt_count="${BASH_REMATCH[1]}"
  managed_uint_is_canonical "$attempt_count" 6 || return 1
  (( ${#lines[@]} >= 12 + 10#$attempt_count )) || return 1
  for ((index = 1; index <= 10#$attempt_count; index++)); do
    line="${lines[$((3 + index))]}"
    [[ "$line" =~ ^attempt_([0-9]{2})=(0|[1-9][0-9]*)$ ]] || return 1
    printf -v expected_index '%02d' "$index"
    [[ "${BASH_REMATCH[1]}" == "$expected_index" ]] || return 1
    attempt_epochs+=("${BASH_REMATCH[2]}")
  done
  offset=$((4 + 10#$attempt_count))
  [[ "${lines[$offset]}" =~ ^backoff_until=(0|[1-9][0-9]*)$ ]] || return 1
  backoff="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 1))]}" =~ ^failure_class=(none|auth|device|rate|transient)$ ]] || return 1
  failure="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 2))]}" =~ ^credential_device=(0|[1-9][0-9]*)$ ]] || return 1
  credential_device="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 3))]}" =~ ^credential_inode=(0|[1-9][0-9]*)$ ]] || return 1
  credential_inode="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 4))]}" =~ ^credential_mtime=(0|[1-9][0-9]*)$ ]] || return 1
  credential_mtime="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 5))]}" =~ ^credential_size=(0|[1-9][0-9]*)$ ]] || return 1
  credential_size="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 6))]}" =~ ^configured_device=(.*)$ ]] || return 1
  configured_device="${BASH_REMATCH[1]}"
  [[ "${lines[$((offset + 7))]}" =~ ^exclude_count=(0|[1-9][0-9]*)$ ]] || return 1
  exclude_count="${BASH_REMATCH[1]}"
  managed_uint_is_canonical "$exclude_count" 16 || return 1
  (( ${#lines[@]} == offset + 8 + 10#$exclude_count )) || return 1

  for ((index = 1; index <= 10#$exclude_count; index++)); do
    line="${lines[$((offset + 7 + index))]}"
    [[ "$line" =~ ^exclude_([0-9]{2})=([A-Za-z0-9-]{1,64}),(0|[1-9][0-9]*)$ ]] || return 1
    printf -v expected_index '%02d' "$index"
    [[ "${BASH_REMATCH[1]}" == "$expected_index" ]] || return 1
    name="${BASH_REMATCH[2]}"
    expiry="${BASH_REMATCH[3]}"
    [[ -z "${seen[$name]+present}" ]] || return 1
    seen["$name"]=1
    names+=("$name")
    expiries+=("$expiry")
  done

  MANAGED_API_STATE_NOW="$observed"
  MANAGED_API_OBSERVED_AT="$observed"
  MANAGED_API_WINDOW_START="$window"
  MANAGED_API_ATTEMPT_COUNT="$attempt_count"
  MANAGED_API_ATTEMPT_EPOCHS=("${attempt_epochs[@]}")
  MANAGED_API_BACKOFF_UNTIL="$backoff"
  MANAGED_API_FAILURE_CLASS="$failure"
  MANAGED_API_CREDENTIAL_DEVICE="$credential_device"
  MANAGED_API_CREDENTIAL_INODE="$credential_inode"
  MANAGED_API_CREDENTIAL_MTIME="$credential_mtime"
  MANAGED_API_CREDENTIAL_SIZE="$credential_size"
  MANAGED_API_CONFIGURED_DEVICE="$configured_device"
  MANAGED_API_EXCLUDE_NAMES=("${names[@]}")
  MANAGED_API_EXCLUDE_EXPIRIES=("${expiries[@]}")
  managed_api_state_memory_is_valid 1 || return 1
  (( 10#$now >= 10#$observed )) || return 1
  managed_api_state_prune "$now"
}

managed_api_state_write() {
  local parent base temporary index move_rc=0
  managed_api_state_memory_is_valid 1 || return 1
  (( ${CONTEXT_LOCKED:-0} == 1 )) || return 1
  managed_api_state_parent_is_secure || return 1
  if [[ -e "$AIRVPN_API_STATE_FILE" || -L "$AIRVPN_API_STATE_FILE" ]]; then
    managed_api_state_file_is_secure || return 1
  fi
  parent="${AIRVPN_API_STATE_FILE%/*}"
  base="${AIRVPN_API_STATE_FILE##*/}"
  temporary="$(mktemp "$parent/.${base}.tmp.XXXXXX")" || return 1
  chmod 600 -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  {
    printf '%s\n' \
      'version=1' \
      "observed_at=$MANAGED_API_OBSERVED_AT" \
      "window_start=$MANAGED_API_WINDOW_START" \
      "attempt_count=$MANAGED_API_ATTEMPT_COUNT"
    for ((index = 0; index < ${#MANAGED_API_ATTEMPT_EPOCHS[@]}; index++)); do
      printf 'attempt_%02d=%s\n' "$((index + 1))" "${MANAGED_API_ATTEMPT_EPOCHS[$index]}"
    done
    printf '%s\n' \
      "backoff_until=$MANAGED_API_BACKOFF_UNTIL" \
      "failure_class=$MANAGED_API_FAILURE_CLASS" \
      "credential_device=$MANAGED_API_CREDENTIAL_DEVICE" \
      "credential_inode=$MANAGED_API_CREDENTIAL_INODE" \
      "credential_mtime=$MANAGED_API_CREDENTIAL_MTIME" \
      "credential_size=$MANAGED_API_CREDENTIAL_SIZE" \
      "configured_device=$MANAGED_API_CONFIGURED_DEVICE" \
      "exclude_count=${#MANAGED_API_EXCLUDE_NAMES[@]}"
    for ((index = 0; index < ${#MANAGED_API_EXCLUDE_NAMES[@]}; index++)); do
      printf 'exclude_%02d=%s,%s\n' "$((index + 1))" \
        "${MANAGED_API_EXCLUDE_NAMES[$index]}" \
        "${MANAGED_API_EXCLUDE_EXPIRIES[$index]}"
    done
  } > "$temporary" || move_rc=1
  if (( move_rc == 0 )); then managed_sync_file "$temporary" || move_rc=1; fi
  if (( move_rc == 0 )); then mv -fT -- "$temporary" "$AIRVPN_API_STATE_FILE" || move_rc=1; fi
  if (( move_rc == 0 )); then managed_sync_file "$AIRVPN_API_STATE_FILE" || move_rc=1; fi
  if (( move_rc == 0 )); then managed_sync_directory "$parent" || move_rc=1; fi
  if (( move_rc != 0 )); then
    rm -f -- "$temporary"
    return 1
  fi
}

managed_api_state_prune() {
  local now="${1:?}" index
  local -a attempt_epochs=() names=() expiries=()
  managed_epoch_is_valid "$now" || return 1
  managed_epoch_is_valid "${MANAGED_API_OBSERVED_AT-}" || return 1
  (( 10#$now >= 10#$MANAGED_API_OBSERVED_AT )) || return 1
  for ((index = 0; index < ${#MANAGED_API_ATTEMPT_EPOCHS[@]}; index++)); do
    if (( 10#$now - 10#${MANAGED_API_ATTEMPT_EPOCHS[$index]} < 86400 )); then
      attempt_epochs+=("${MANAGED_API_ATTEMPT_EPOCHS[$index]}")
    fi
  done
  MANAGED_API_ATTEMPT_EPOCHS=("${attempt_epochs[@]}")
  MANAGED_API_ATTEMPT_COUNT="${#MANAGED_API_ATTEMPT_EPOCHS[@]}"
  if (( MANAGED_API_ATTEMPT_COUNT == 0 )); then
    MANAGED_API_WINDOW_START="$now"
  else
    MANAGED_API_WINDOW_START="${MANAGED_API_ATTEMPT_EPOCHS[0]}"
  fi
  for ((index = 0; index < ${#MANAGED_API_EXCLUDE_NAMES[@]}; index++)); do
    if (( 10#${MANAGED_API_EXCLUDE_EXPIRIES[$index]} > 10#$now )); then
      names+=("${MANAGED_API_EXCLUDE_NAMES[$index]}")
      expiries+=("${MANAGED_API_EXCLUDE_EXPIRIES[$index]}")
    fi
  done
  MANAGED_API_EXCLUDE_NAMES=("${names[@]}")
  MANAGED_API_EXCLUDE_EXPIRIES=("${expiries[@]}")
  MANAGED_API_STATE_NOW="$now"
  MANAGED_API_OBSERVED_AT="$now"
  managed_api_state_memory_is_valid
}

managed_api_state_add_exclusion() {
  local name="${1-}" now="${2-}" expiry index oldest_index=0 oldest_expiry
  managed_server_name_is_valid "$name" || return 1
  managed_epoch_is_valid "$now" || return 1
  managed_api_state_prune "$now" || return 1
  expiry=$((10#$now + 21600))
  (( expiry <= 4294967295 )) || return 1
  for ((index = 0; index < ${#MANAGED_API_EXCLUDE_NAMES[@]}; index++)); do
    if [[ "${MANAGED_API_EXCLUDE_NAMES[$index]}" == "$name" ]]; then
      MANAGED_API_EXCLUDE_EXPIRIES[index]="$expiry"
      return 0
    fi
  done
  if (( ${#MANAGED_API_EXCLUDE_NAMES[@]} >= 16 )); then
    oldest_expiry="${MANAGED_API_EXCLUDE_EXPIRIES[0]}"
    for ((index = 1; index < ${#MANAGED_API_EXCLUDE_NAMES[@]}; index++)); do
      if (( 10#${MANAGED_API_EXCLUDE_EXPIRIES[$index]} < 10#$oldest_expiry )); then
        oldest_index=$index
        oldest_expiry="${MANAGED_API_EXCLUDE_EXPIRIES[$index]}"
      fi
    done
    unset "MANAGED_API_EXCLUDE_NAMES[$oldest_index]"
    unset "MANAGED_API_EXCLUDE_EXPIRIES[$oldest_index]"
    MANAGED_API_EXCLUDE_NAMES=("${MANAGED_API_EXCLUDE_NAMES[@]}")
    MANAGED_API_EXCLUDE_EXPIRIES=("${MANAGED_API_EXCLUDE_EXPIRIES[@]}")
  fi
  MANAGED_API_EXCLUDE_NAMES+=("$name")
  MANAGED_API_EXCLUDE_EXPIRIES+=("$expiry")
}

managed_api_state_remove_exclusion_core() {
  local name="${1-}" now="${2-}" index found=-1
  managed_server_name_is_valid "$name" || return 1
  managed_epoch_is_valid "$now" || return 1
  managed_api_state_prune "$now" || return 1
  for ((index = 0; index < ${#MANAGED_API_EXCLUDE_NAMES[@]}; index++)); do
    if [[ "${MANAGED_API_EXCLUDE_NAMES[$index]}" == "$name" ]]; then
      found=$index
      break
    fi
  done
  (( found >= 0 )) || return 1
  unset "MANAGED_API_EXCLUDE_NAMES[$found]"
  unset "MANAGED_API_EXCLUDE_EXPIRIES[$found]"
  MANAGED_API_EXCLUDE_NAMES=("${MANAGED_API_EXCLUDE_NAMES[@]}")
  MANAGED_API_EXCLUDE_EXPIRIES=("${MANAGED_API_EXCLUDE_EXPIRIES[@]}")
  MANAGED_API_STATE_NOW="$now"
  MANAGED_API_OBSERVED_AT="$now"
  managed_api_state_write
}

managed_api_state_remove_exclusion() {
  [[ $# == 2 ]] || return 1
  managed_api_state_remove_exclusion_core "$1" "$2"
}

managed_api_exclusion_args_core() {
  local wgmanaged_now="${1:?}" wgmanaged_index
  managed_api_state_prune "$wgmanaged_now" || return 1
  wgmanaged_exclusion_args_carrier=()
  for ((wgmanaged_index = 0;
        wgmanaged_index < ${#MANAGED_API_EXCLUDE_NAMES[@]};
        wgmanaged_index++)); do
    wgmanaged_exclusion_args_carrier+=(
      --exclude-server "${MANAGED_API_EXCLUDE_NAMES[$wgmanaged_index]}"
    )
  done
}

managed_api_exclusion_args() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_now="${2:?}"
  local -a wgmanaged_exclusion_args_carrier=()
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  # Assignment through this validated caller-selected nameref is the public API.
  # shellcheck disable=SC2034
  local -n wgmanaged_output_reference="$wgmanaged_output_variable"
  managed_api_exclusion_args_core "$wgmanaged_now" || return 1
  # shellcheck disable=SC2034
  wgmanaged_output_reference=("${wgmanaged_exclusion_args_carrier[@]}")
}

managed_api_attempt_allowed() {
  local now="${1:?}" administrative_bypass="${2:-0}"
  [[ "$administrative_bypass" == 0 || "$administrative_bypass" == 1 ]] || return 1
  managed_api_state_prune "$now" || return 1
  (( 10#$MANAGED_API_ATTEMPT_COUNT < 6 )) || return 75
  if (( 10#$MANAGED_API_BACKOFF_UNTIL > 10#$now )); then
    case "$MANAGED_API_FAILURE_CLASS" in
      auth|device) (( administrative_bypass == 1 )) || return 75 ;;
      rate|transient) return 75 ;;
      none) return 1 ;;
      *) return 1 ;;
    esac
  fi
}

managed_api_record_attempt() {
  local now="${1:?}" administrative_bypass="${2:-0}" allowed_rc
  if managed_api_attempt_allowed "$now" "$administrative_bypass"; then
    allowed_rc=0
  else
    allowed_rc=$?
  fi
  if (( allowed_rc == 75 )); then
    managed_api_state_write || return 1
    return 75
  fi
  (( allowed_rc == 0 )) || return "$allowed_rc"
  MANAGED_API_ATTEMPT_EPOCHS+=("$now")
  MANAGED_API_ATTEMPT_COUNT="${#MANAGED_API_ATTEMPT_EPOCHS[@]}"
  MANAGED_API_WINDOW_START="${MANAGED_API_ATTEMPT_EPOCHS[0]}"
  MANAGED_API_STATE_NOW="$now"
  MANAGED_API_OBSERVED_AT="$now"
  managed_api_state_write
}

managed_api_gate_before_preflight() {
  local now="${1:?}" administrative_bypass="${2:-0}" rc
  if managed_api_attempt_allowed "$now" "$administrative_bypass"; then
    rc=0
  else
    rc=$?
  fi
  (( rc != 0 )) || return 0
  if (( rc == 75 )); then
    managed_api_state_write || return 1
  fi
  return "$rc"
}

managed_compute_backoff() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_attempt="${2:?}"
  local wgmanaged_jitter="${3-}" wgmanaged_retry_after="${4-}"
  local wgmanaged_base=300 wgmanaged_maximum_jitter wgmanaged_index wgmanaged_computed
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  managed_uint_is_canonical "$wgmanaged_attempt" 100 || return 1
  (( 10#$wgmanaged_attempt >= 1 )) || return 1
  for ((wgmanaged_index = 1;
        wgmanaged_index < 10#$wgmanaged_attempt && wgmanaged_base < 21600;
        wgmanaged_index++)); do
    wgmanaged_base=$((wgmanaged_base * 2))
    (( wgmanaged_base <= 21600 )) || wgmanaged_base=21600
  done
  wgmanaged_maximum_jitter=$((wgmanaged_base / 10))
  if [[ -z "$wgmanaged_jitter" ]]; then
    wgmanaged_jitter=$((RANDOM % (wgmanaged_maximum_jitter + 1)))
  fi
  managed_uint_is_canonical "$wgmanaged_jitter" "$wgmanaged_maximum_jitter" || return 1
  wgmanaged_computed=$((wgmanaged_base + 10#$wgmanaged_jitter))
  (( wgmanaged_computed <= 21600 )) || wgmanaged_computed=21600
  if [[ -n "$wgmanaged_retry_after" ]]; then
    managed_uint_is_canonical "$wgmanaged_retry_after" 86400 || return 1
    if (( 10#$wgmanaged_retry_after > wgmanaged_computed )); then
      wgmanaged_computed=$((10#$wgmanaged_retry_after))
    fi
  fi
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_computed"
}

managed_api_record_outcome() {
  local now="${1:?}" outcome="${2:?}" retry_after="${3-}" failed_server="${4-}" jitter="${5-}"
  local backoff
  managed_epoch_is_valid "$now" || return 1
  managed_api_state_prune "$now" || return 1
  case "$outcome" in
    none)
      [[ -z "$retry_after" && -z "$failed_server" ]] || return 1
      MANAGED_API_FAILURE_CLASS=none
      MANAGED_API_BACKOFF_UNTIL=0
      ;;
    auth|device)
      [[ -z "$retry_after" ]] || return 1
      MANAGED_API_FAILURE_CLASS="$outcome"
      MANAGED_API_BACKOFF_UNTIL=$((10#$now + 86400))
      ;;
    rate|transient)
      (( 10#$MANAGED_API_ATTEMPT_COUNT >= 1 )) || return 1
      managed_compute_backoff backoff "$MANAGED_API_ATTEMPT_COUNT" "$jitter" "$retry_after" || return 1
      MANAGED_API_FAILURE_CLASS="$outcome"
      MANAGED_API_BACKOFF_UNTIL=$((10#$now + 10#$backoff))
      ;;
    *) return 1 ;;
  esac
  if [[ -n "$failed_server" ]]; then
    managed_api_state_add_exclusion "$failed_server" "$now" || return 1
  fi
  managed_api_state_write
}

managed_api_credential_fd_metadata() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_credential_fd="${2:?}"
  local wgmanaged_owner_pid wgmanaged_captured_metadata
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  validate_credential_fd_number "$wgmanaged_credential_fd" || return 1
  wgmanaged_owner_pid=$BASHPID
  [[ -f "/proc/$wgmanaged_owner_pid/fd/$wgmanaged_credential_fd" ]] || return 1
  wgmanaged_captured_metadata="$(
    stat -Lc '%d %i %Y %s %u %a' -- "/proc/$wgmanaged_owner_pid/fd/$wgmanaged_credential_fd" \
      {wgmanaged_credential_fd}<&- 2>/dev/null
  )" || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_captured_metadata"
}

managed_api_state_refresh_identity() {
  local now="${1:?}" credential_fd="${2-}" locally_opened_fd='' close_after=0
  local metadata device inode mtime size uid mode changed=0
  managed_epoch_is_valid "$now" || return 1
  managed_device_name_is_valid "${AIRVPN_DEVICE-}" || return 1
  managed_api_state_prune "$now" || return 1
  if [[ -z "$credential_fd" ]]; then
    open_installed_api_key locally_opened_fd || return 1
    credential_fd="$locally_opened_fd"
    close_after=1
  else
    validate_credential_fd_number "$credential_fd" || return 1
  fi
  if ! managed_api_credential_fd_metadata metadata "$credential_fd"; then
    (( close_after == 0 )) || exec {locally_opened_fd}<&-
    return 1
  fi
  read -r device inode mtime size uid mode <<< "$metadata"
  if [[ "$metadata" != "$device $inode $mtime $size $uid $mode" ||
        "$uid" != 0 || "$mode" != 600 ]]; then
    (( close_after == 0 )) || exec {locally_opened_fd}<&-
    return 1
  fi
  if ! managed_api_metadata_is_valid "$device" "$inode" "$mtime" "$size"; then
    (( close_after == 0 )) || exec {locally_opened_fd}<&-
    return 1
  fi
  if [[ "$size" != 65 ]]; then
    (( close_after == 0 )) || exec {locally_opened_fd}<&-
    return 1
  fi
  (( close_after == 0 )) || exec {locally_opened_fd}<&-
  if [[ "$device" != "${MANAGED_API_CREDENTIAL_DEVICE-}" ||
        "$inode" != "${MANAGED_API_CREDENTIAL_INODE-}" ||
        "$mtime" != "${MANAGED_API_CREDENTIAL_MTIME-}" ||
        "$size" != "${MANAGED_API_CREDENTIAL_SIZE-}" ||
        "$AIRVPN_DEVICE" != "${MANAGED_API_CONFIGURED_DEVICE-}" ]]; then
    changed=1
  fi
  MANAGED_API_CREDENTIAL_DEVICE="$device"
  MANAGED_API_CREDENTIAL_INODE="$inode"
  MANAGED_API_CREDENTIAL_MTIME="$mtime"
  MANAGED_API_CREDENTIAL_SIZE="$size"
  MANAGED_API_CONFIGURED_DEVICE="$AIRVPN_DEVICE"
  if (( changed )) && [[ "$MANAGED_API_FAILURE_CLASS" == auth || "$MANAGED_API_FAILURE_CLASS" == device ]]; then
    MANAGED_API_FAILURE_CLASS=none
    MANAGED_API_BACKOFF_UNTIL=0
  fi
  managed_api_state_memory_is_valid
}
