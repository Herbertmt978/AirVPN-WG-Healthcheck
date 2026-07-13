#!/bin/bash

# Securely sourced by bin/wg-healthcheck after fixed-path ownership and mode checks.
# Managed API state, journal, and full-profile transaction owners live here. Public
# lifecycle command wiring lands in its later approved slice.

managed_file_size() {
  stat -c '%s' -- "$1" 2>/dev/null
}

managed_credential_record_valid() {
  local path="${1:?}"
  LC_ALL=C command grep -aEq '^[0-9a-f]{64}$' -- "$path" 2>/dev/null
}

managed_output_variable_is_valid() {
  local wgmanaged_name="${1-}"
  [[ "$wgmanaged_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] &&
    [[ "$wgmanaged_name" != wgmanaged_* ]]
}

open_installed_api_key() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_parent wgmanaged_file_meta
  local wgmanaged_parent_meta wgmanaged_size wgmanaged_opened_fd
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  wgmanaged_parent="${AIRVPN_API_KEY_FILE%/*}"
  [[ "$wgmanaged_parent" != "$AIRVPN_API_KEY_FILE" ]] || return 1

  if ! path_is_directory "$wgmanaged_parent" || path_is_symlink "$wgmanaged_parent"; then
    log "API credential directory failed trust validation"
    return 1
  fi
  wgmanaged_parent_meta="$(owner_mode "$wgmanaged_parent")" || return 1
  if [[ "$wgmanaged_parent_meta" != 0:700 ]]; then
    log "API credential directory failed trust validation"
    return 1
  fi
  if ! path_is_regular "$AIRVPN_API_KEY_FILE" || path_is_symlink "$AIRVPN_API_KEY_FILE"; then
    log "Installed API credential failed trust validation"
    return 1
  fi
  wgmanaged_file_meta="$(owner_mode "$AIRVPN_API_KEY_FILE")" || return 1
  if [[ "$wgmanaged_file_meta" != 0:600 ]]; then
    log "Installed API credential failed trust validation"
    return 1
  fi
  wgmanaged_size="$(managed_file_size "$AIRVPN_API_KEY_FILE")" || return 1
  if [[ "$wgmanaged_size" != 65 ]] || ! managed_credential_record_valid "$AIRVPN_API_KEY_FILE"; then
    log "Installed API credential has an invalid record shape"
    return 1
  fi

  exec {wgmanaged_opened_fd}<"$AIRVPN_API_KEY_FILE" || return 1
  if ! printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_opened_fd"; then
    exec {wgmanaged_opened_fd}<&-
    return 1
  fi
}

managed_uint_is_canonical() {
  local value="${1-}" maximum="${2:?}" value_length maximum_length
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  value_length=${#value}
  maximum_length=${#maximum}
  (( value_length < maximum_length )) && return 0
  (( value_length > maximum_length )) && return 1
  [[ "$value" == "$maximum" || "$value" < "$maximum" ]]
}

managed_epoch_is_valid() {
  managed_uint_is_canonical "${1-}" 4294967295
}

managed_server_name_is_valid() {
  [[ "${1-}" =~ ^[A-Za-z0-9-]{1,64}$ ]]
}

managed_device_name_is_valid() {
  [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ ]]
}

managed_sync_file() {
  python3 -c 'import os,sys
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(sys.argv[1], flags)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1"
}

managed_sync_directory() {
  python3 -c 'import os,sys
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(sys.argv[1], flags)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1"
}

managed_sync_artifact_parent() {
  managed_sync_directory "${1:?}"
}

managed_sync_journal_parent() {
  managed_sync_directory "${1:?}"
}

managed_api_state_defaults() {
  local now="${1:?}"
  managed_epoch_is_valid "$now" || return 1
  MANAGED_API_STATE_NOW="$now"
  MANAGED_API_OBSERVED_AT="$now"
  MANAGED_API_WINDOW_START="$now"
  MANAGED_API_ATTEMPT_COUNT=0
  MANAGED_API_ATTEMPT_EPOCHS=()
  MANAGED_API_BACKOFF_UNTIL=0
  MANAGED_API_FAILURE_CLASS=none
  MANAGED_API_CREDENTIAL_DEVICE=0
  MANAGED_API_CREDENTIAL_INODE=0
  MANAGED_API_CREDENTIAL_MTIME=0
  MANAGED_API_CREDENTIAL_SIZE=0
  MANAGED_API_CONFIGURED_DEVICE=''
  MANAGED_API_EXCLUDE_NAMES=()
  MANAGED_API_EXCLUDE_EXPIRIES=()
}

managed_api_state_parent_is_secure() {
  local parent="${AIRVPN_API_STATE_FILE%/*}" metadata
  [[ -n "${AIRVPN_API_STATE_FILE:-}" && "$parent" != "$AIRVPN_API_STATE_FILE" ]] || return 1
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  metadata="$(owner_mode "$parent")" || return 1
  [[ "$metadata" == 0:700 ]]
}

managed_api_state_file_is_secure() {
  local metadata
  [[ -f "$AIRVPN_API_STATE_FILE" && ! -L "$AIRVPN_API_STATE_FILE" ]] || return 1
  metadata="$(owner_mode "$AIRVPN_API_STATE_FILE")" || return 1
  [[ "$metadata" == 0:600 ]]
}

managed_api_state_bytes_are_strict() {
  local path="${1:?}" bytes byte last='' count=0
  bytes="$(od -An -v -t u1 -- "$path" 2>/dev/null)" || return 1
  for byte in $bytes; do
    managed_uint_is_canonical "$byte" 255 || return 1
    if (( 10#$byte != 10 && (10#$byte < 32 || 10#$byte > 126) )); then
      return 1
    fi
    last="$byte"
    count=$((count + 1))
  done
  (( count > 0 )) && [[ "$last" == 10 ]]
}

managed_sha256_is_valid() {
  [[ "${1-}" =~ ^[0-9a-f]{64}$ ]]
}

managed_journal_clear() {
  MANAGED_JOURNAL_PHASE=''
  MANAGED_JOURNAL_BACKUP_SHA256=''
  MANAGED_JOURNAL_CANDIDATE_SHA256=''
  MANAGED_JOURNAL_OLD_ENDPOINT=''
  MANAGED_JOURNAL_CANDIDATE_ENDPOINT=''
  MANAGED_JOURNAL_QB_WAS_RUNNING=''
  MANAGED_JOURNAL_ACTIVE_CLASS=''
  MANAGED_JOURNAL_CANDIDATE_CLASS=''
}

managed_journal_paths_are_fixed() {
  local wgmanaged_parent wgmanaged_expected_candidate
  [[ -n "${WG_CONF:-}" && "$WG_CONF" == /* ]] || return 1
  wgmanaged_parent="${WG_CONF%/*}"
  [[ "$wgmanaged_parent" != "$WG_CONF" ]] || return 1
  wgmanaged_expected_candidate="$wgmanaged_parent/.${WG_CONF##*/}.managed-candidate"
  [[ -n "${ROTATION_PENDING:-}" &&
     "$ROTATION_PENDING" == "${WG_CONF}.pending-healthcheck" ]] || return 1
  [[ -n "${MANAGED_SAFETY:-}" &&
     "$MANAGED_SAFETY" == "${WG_CONF}.safety-healthcheck" ]] || return 1
  [[ -n "${MANAGED_CANDIDATE:-}" &&
     "$MANAGED_CANDIDATE" == "$wgmanaged_expected_candidate" ]] || return 1
}

managed_journal_parent_is_secure() {
  local wgmanaged_parent wgmanaged_metadata
  managed_journal_paths_are_fixed || return 1
  wgmanaged_parent="${ROTATION_PENDING%/*}"
  [[ -d "$wgmanaged_parent" && ! -L "$wgmanaged_parent" ]] || return 1
  wgmanaged_metadata="$(owner_mode "$wgmanaged_parent")" || return 1
  [[ "$wgmanaged_metadata" == 0:700 ]]
}

managed_journal_file_is_secure() {
  local wgmanaged_metadata
  [[ -f "$ROTATION_PENDING" && ! -L "$ROTATION_PENDING" ]] || return 1
  wgmanaged_metadata="$(owner_mode "$ROTATION_PENDING")" || return 1
  [[ "$wgmanaged_metadata" == 0:600 ]]
}

managed_profile_file_is_secure() {
  local wgmanaged_path="${1:?}" wgmanaged_metadata wgmanaged_size
  validate_secure_parent_directory "$wgmanaged_path" "WireGuard profile directory" 700 ||
    return 1
  [[ -f "$wgmanaged_path" && ! -L "$wgmanaged_path" ]] || return 1
  wgmanaged_metadata="$(owner_mode "$wgmanaged_path")" || return 1
  [[ "$wgmanaged_metadata" == 0:600 ]] || return 1
  wgmanaged_size="$(managed_file_size "$wgmanaged_path")" || return 1
  managed_uint_is_canonical "$wgmanaged_size" 65536 || return 1
  (( 10#$wgmanaged_size > 0 ))
}

# Compare only the private interface identity and return status. Private-key bytes remain
# inside this single awk process and are never emitted or passed as arguments.
managed_profiles_have_same_private_identity() {
  local wgmanaged_reference="${1-}"
  [[ $# == 1 ]] || return 1
  [[ "$wgmanaged_reference" == "$WG_CONF" ||
     "$wgmanaged_reference" == "${WG_CONF}.bak-healthcheck" ]] || return 1
  managed_journal_paths_are_fixed || return 1
  _managed_profiles_have_same_private_identity_pair "$wgmanaged_reference" "$MANAGED_CANDIDATE"
}

_managed_profiles_have_same_private_identity_pair() {
  local wgmanaged_reference="${1-}" wgmanaged_comparison="${2-}"
  [[ $# == 2 ]] || return 1
  managed_profile_file_is_secure "$wgmanaged_reference" || return 1
  managed_profile_file_is_secure "$wgmanaged_comparison" || return 1
  command awk '
    function reset_file() {
      interface_sections=0; in_interface=0; private_count=0; address_count=0
      table_count=0; private_value=""; address_value=""; table_value="-"
    }
    function valid_key(value, body, tail) {
      if (length(value) != 44 || substr(value, 44, 1) != "=") return 0
      body=substr(value, 1, 42); tail=substr(value, 43, 1)
      if (body !~ /^[A-Za-z0-9+\057]+$/ || tail !~ /^[AEIMQUYcgkosw048]$/) return 0
      return value != "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }
    function valid_ipv4_32(value, parts, octets, count, i, octet) {
      count=split(value, parts, "/")
      if (count != 2 || parts[2] != "32") return 0
      count=split(parts[1], octets, ".")
      if (count != 4) return 0
      for (i=1; i<=4; i++) {
        octet=octets[i]
        if (octet !~ /^[0-9]+$/ || length(octet) > 3) return 0
        if (length(octet) > 1 && substr(octet, 1, 1) == "0") return 0
        if ((octet + 0) > 255) return 0
      }
      return 1
    }
    function valid_table(value) {
      if (value == "auto" || value == "off") return 1
      if (value !~ /^[0-9]+$/ || value == "0" || length(value) > 10) return 0
      if (length(value) > 1 && substr(value, 1, 1) == "0") return 0
      return (value + 0) <= 4294967295
    }
    function finish_file() {
      if (interface_sections != 1 || private_count != 1 || address_count != 1 ||
          table_count > 1 || !valid_key(private_value) ||
          !valid_ipv4_32(address_value) ||
          (table_count == 1 && !valid_table(table_value))) {
        invalid=1
      }
      if (file_number == 1) {
        reference_private=private_value; reference_address=address_value
        reference_table_count=table_count; reference_table=table_value
      } else if (private_value != reference_private || address_value != reference_address ||
                 table_count != reference_table_count || table_value != reference_table) {
        invalid=1
      }
    }
    FNR == 1 {
      if (file_number > 0) finish_file()
      file_number++; reset_file()
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if ($0 ~ /^[[:space:]]*\[Interface\][[:space:]]*$/) {
        interface_sections++; in_interface=1
      } else {
        in_interface=0
      }
      next
    }
    /^[[:space:]]*(PrivateKey|Address|Table)[[:space:]]*=/ {
      line=$0; name=line; sub(/[[:space:]]*=.*/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      value=line; sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (!in_interface) { invalid=1; next }
      if (name == "PrivateKey") { private_count++; private_value=value }
      else if (name == "Address") { address_count++; address_value=value }
      else { table_count++; table_value=value }
      next
    }
    END {
      if (file_number > 0) finish_file()
      if (file_number != 2 || invalid) exit 1
    }
  ' "$wgmanaged_reference" "$wgmanaged_comparison" >/dev/null 2>&1
}

managed_profile_interface_ipv4() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_path="${2:?}"
  local wgmanaged_value
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  [[ "$wgmanaged_path" == "$WG_CONF" ||
     "$wgmanaged_path" == "${WG_CONF}.bak-healthcheck" ||
     "$wgmanaged_path" == "$MANAGED_CANDIDATE" ]] || return 1
  managed_profile_file_is_secure "$wgmanaged_path" || return 1
  wgmanaged_value="$(command awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      in_interface=($0 ~ /^[[:space:]]*\[Interface\][[:space:]]*$/); next
    }
    in_interface && /^[[:space:]]*Address[[:space:]]*=/ {
      value=$0; sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); count++
    }
    END { if (count != 1) exit 1; print value }
  ' "$wgmanaged_path")" || return 1
  [[ "$wgmanaged_value" == */32 ]] || return 1
  wgmanaged_value="${wgmanaged_value%/32}"
  validate_ip_address "$wgmanaged_value" || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_value"
}

managed_sha256_file_core() {
  local wgmanaged_path="${1:?}"
  local wgmanaged_result wgmanaged_digest
  [[ -v wgmanaged_sha256_carrier ]] || return 1
  [[ "$wgmanaged_path" != *$'\r'* && "$wgmanaged_path" != *$'\n'* ]] || return 1
  managed_profile_file_is_secure "$wgmanaged_path" || return 1
  wgmanaged_result="$(command sha256sum -- "$wgmanaged_path" 2>/dev/null)" || return 1
  (( ${#wgmanaged_result} >= 67 )) || return 1
  wgmanaged_digest="${wgmanaged_result:0:64}"
  managed_sha256_is_valid "$wgmanaged_digest" || return 1
  [[ "${wgmanaged_result:64:2}" == '  ' &&
     "${wgmanaged_result:66}" == "$wgmanaged_path" ]] || return 1
  wgmanaged_sha256_carrier="$wgmanaged_digest"
}

managed_sha256_file() {
  local wgmanaged_output_variable="${1:?}" wgmanaged_path="${2:?}"
  local wgmanaged_sha256_carrier=''
  managed_output_variable_is_valid "$wgmanaged_output_variable" || return 1
  managed_sha256_file_core "$wgmanaged_path" || return 1
  printf -v "$wgmanaged_output_variable" '%s' "$wgmanaged_sha256_carrier"
}
