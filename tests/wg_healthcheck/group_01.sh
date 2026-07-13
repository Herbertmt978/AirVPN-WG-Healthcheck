#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

# wg-healthcheck test group 01; function bodies preserved from legacy suite.

test_version_output_is_fixed_and_public() {
  local expected actual
  expected="$(<"$VERSION_FILE")"
  [[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not semantic" || return 1
  actual="$(WG_HEALTHCHECK_VERSION=9.9.9 bash "$SCRIPT" --version)" || return 1
  assert_eq "wg-healthcheck $expected" "$actual" "--version must match the tracked release version"
}
test_sourceable_without_executing_or_enabling_errexit() {
  local source_rc

  set +e
  if source "$SCRIPT"; then
    source_rc=0
  else
    source_rc=$?
  fi

  assert_eq 0 "$source_rc" "sourcing the orchestrator must succeed" || return 1
  local function_name
  for function_name in main rotate_airvpn restart_iface speed_check ensure_qbittorrent_binding \
      close_private_fd run_with_private_fd_closed; do
    declare -F "$function_name" >/dev/null || fail "sourcing must define $function_name" || return 1
  done
  [[ $- != *e* ]] || fail "sourcing must not enable errexit in the caller"
}
test_runtime_cli_preserves_legacy_version_and_rejects_unknown_forms() {
  local rc payload usage_text
  source "$SCRIPT"
  declare -F parse_cli >/dev/null || fail "strict runtime CLI parser is missing" || return 1

  parse_cli wg0 || return 1
  assert_eq check "$COMMAND" "legacy invocation must select the timer health command" || return 1
  assert_eq wg0 "$IFACE" "legacy invocation must retain the interface" || return 1
  assert_eq '' "$ACTION_MODE" "legacy invocation must not imply a mutation mode" || return 1
  assert_eq 1 "$LEGACY_INVOCATION" "single-interface syntax must retain benign timer contention semantics" || return 1

  parse_cli check wg0 || return 1
  assert_eq check "$COMMAND" "explicit check must select the health command" || return 1
  assert_eq 0 "$LEGACY_INVOCATION" "explicit check must remain distinguishable from the timer form" || return 1

  parse_cli --version || return 1
  assert_eq version "$COMMAND" "--version must remain a standalone command" || return 1
  usage_text="$(usage 2>&1)"
  assert_contains 'wg-healthcheck check <iface> [--setup-lease-fd N]' "$usage_text" \
    "usage must document setup-owned controlled checks" || return 1
  assert_contains 'wg-healthcheck provision <iface> --dry-run [--credential-fd N] [--settings-fd N]' "$usage_text" \
    "usage must document the provision dry-run settings override" || return 1
  assert_contains 'wg-healthcheck provision <iface> --apply [--credential-fd N]' "$usage_text" \
    "usage must keep provision apply credential-only" || return 1
  assert_contains 'wg-healthcheck adopt <iface> --dry-run [--credential-fd N] [--settings-fd N]' "$usage_text" \
    "usage must document the adopt dry-run settings override" || return 1
  assert_contains 'wg-healthcheck adopt <iface> --apply [--credential-fd N]' "$usage_text" \
    "usage must keep adopt apply credential-only" || return 1
  assert_contains 'wg-healthcheck cleanup-candidate <iface> --apply --setup-lease-fd N' "$usage_text" \
    "usage must document the setup-only orphan recovery command" || return 1

  for payload in '' '--version wg0' 'unknown wg0 --dry-run' 'wg0 extra' \
      'status --bad' 'rotate bad/interface --dry-run'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "strict CLI must reject '$payload'" || return 1
  done
}
test_setup_lease_cli_is_explicit_scoped_and_fd_distinct() {
  local command payload rc
  source "$SCRIPT"

  parse_cli check wg0 --setup-lease-fd 12 || return 1
  assert_eq 12 "$SETUP_LEASE_FD" "explicit check may reuse setup's exclusive lease" || return 1
  assert_eq 0 "$LEGACY_INVOCATION" "lease-bearing checks must never masquerade as timer runs" || return 1

  for command in provision adopt restore-static reset-api-state; do
    parse_cli "$command" wg0 --dry-run --setup-lease-fd 12 || return 1
    assert_eq 12 "$SETUP_LEASE_FD" "$command may reuse setup's exclusive lease" || return 1
  done

  parse_cli cleanup-candidate wg0 --apply --setup-lease-fd 12 || return 1
  assert_eq cleanup-candidate "$COMMAND" \
    "candidate cleanup must have an explicit administrative command" || return 1
  assert_eq apply "$ACTION_MODE" "candidate cleanup must be apply-only" || return 1
  assert_eq 12 "$SETUP_LEASE_FD" \
    "candidate cleanup must require setup's inherited lease" || return 1

  for payload in \
      'wg0 --setup-lease-fd 12' \
      'status wg0 --setup-lease-fd 12' \
      'rotate wg0 --dry-run --setup-lease-fd 12' \
      'cleanup-candidate wg0' \
      'cleanup-candidate wg0 --apply' \
      'cleanup-candidate wg0 --dry-run --setup-lease-fd 12' \
      'cleanup-candidate wg0 --apply --credential-fd 11 --setup-lease-fd 12' \
      'cleanup-candidate wg0 --apply --settings-fd 11 --setup-lease-fd 12' \
      'cleanup-candidate wg0 --apply --setup-lease-fd 12 --setup-lease-fd 13' \
      'check wg0 --dry-run' \
      'check wg0 --setup-lease-fd 2' \
      'check wg0 --setup-lease-fd 012' \
      'check wg0 --setup-lease-fd nope' \
      'check wg0 --setup-lease-fd 12 --setup-lease-fd 13' \
      'provision wg0 --dry-run --credential-fd 12 --setup-lease-fd 12' \
      'provision wg0 --dry-run --credential-fd 11 --settings-fd 12 --setup-lease-fd 12'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "setup lease grammar must reject '$payload'" || return 1
  done
}
test_mutating_cli_requires_exactly_one_mode_and_scopes_options() {
  local command rc payload
  source "$SCRIPT"
  declare -F parse_cli >/dev/null || fail "strict runtime CLI parser is missing" || return 1

  for command in provision adopt rotate restore-static reset-api-state; do
    parse_cli "$command" wg0 --dry-run || return 1
    assert_eq "$command" "$COMMAND" "$command must dispatch by name" || return 1
    assert_eq dry-run "$ACTION_MODE" "$command --dry-run must remain non-mutating" || return 1
    parse_cli "$command" wg0 --apply || return 1
    assert_eq apply "$ACTION_MODE" "$command --apply must be explicit" || return 1

    for payload in "$command wg0" "$command wg0 --dry-run --apply" \
        "$command wg0 --apply --apply" "$command wg0 --json"; do
      read -r -a argv <<< "$payload"
      set +e
      parse_cli "${argv[@]}" >/dev/null 2>&1
      rc=$?
      set +e
      assert_eq 64 "$rc" "mutating CLI must reject '$payload'" || return 1
    done
  done

  parse_cli provision wg0 --credential-fd 9 --dry-run || return 1
  assert_eq 9 "$CREDENTIAL_FD" "provision may accept a descriptor number" || return 1
  parse_cli adopt wg0 --apply --credential-fd 10 || return 1
  assert_eq 10 "$CREDENTIAL_FD" "adopt may accept a descriptor number" || return 1
  parse_cli provision wg0 --credential-fd 9 --settings-fd 10 --dry-run || return 1
  assert_eq 10 "$SETTINGS_FD" "provision dry-run may accept proposed settings" || return 1
  assert_eq 9 "$CREDENTIAL_FD" "proposed settings must preserve the credential descriptor" || return 1
  parse_cli adopt wg0 --dry-run --settings-fd 11 --credential-fd 10 || return 1
  assert_eq 11 "$SETTINGS_FD" "adopt dry-run may accept proposed settings in either option order" || return 1
  for payload in 'rotate wg0 --dry-run --credential-fd 9' \
      'restore-static wg0 --apply --credential-fd 9' \
      'provision wg0 --dry-run --credential-fd 2' \
      'provision wg0 --dry-run --credential-fd 09' \
      'adopt wg0 --apply --credential-fd nope' \
      'provision wg0 --dry-run --credential-fd 9 --credential-fd 10'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "credential descriptor grammar must reject '$payload'" || return 1
  done
  for payload in 'rotate wg0 --dry-run --settings-fd 9' \
      'restore-static wg0 --dry-run --settings-fd 9' \
      'provision wg0 --dry-run --settings-fd 9' \
      'provision wg0 --apply --settings-fd 9' \
      'adopt wg0 --apply --settings-fd 9' \
      'provision wg0 --dry-run --settings-fd 2' \
      'provision wg0 --dry-run --settings-fd 09' \
      'adopt wg0 --dry-run --settings-fd nope' \
      'provision wg0 --dry-run --settings-fd 10 --settings-fd 11' \
      'provision wg0 --dry-run --credential-fd 10 --settings-fd 10' \
      'provision wg0 --dry-run --settings-fd 10 --credential-fd 10'; do
    read -r -a argv <<< "$payload"
    set +e
    parse_cli "${argv[@]}" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 64 "$rc" "settings descriptor grammar must reject '$payload'" || return 1
  done

  parse_cli status wg0 || return 1
  assert_eq 0 "$STATUS_JSON" "status defaults to text" || return 1
  parse_cli status wg0 --json || return 1
  assert_eq 1 "$STATUS_JSON" "status alone may request JSON" || return 1
  set +e; parse_cli status wg0 --dry-run >/dev/null 2>&1; rc=$?; set +e
  assert_eq 64 "$rc" "status must reject mutation flags"
}
test_settings_descriptor_is_exact_stable_private_and_canonical() {
  local case_name metadata_case payload rc settings_fd credential_fd metadata_calls
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  COMMAND=provision
  ACTION_MODE=dry-run

  # Unit fixtures run as both root and a normal user. Preserve the real descriptor
  # identity/size while replacing only the owner field so this test exercises the
  # production parser rather than depending on the test runner's uid.
  if [[ "$(id -u)" != 0 ]]; then
    settings_fd_metadata() {
      local output_variable="${1:?}" descriptor="${2:?}" value
      value="$(stat -Lc '600|%s|%d|%i|%y|%z|regular file' -- \
        "/proc/$BASHPID/fd/$descriptor" {descriptor}<&- 2>/dev/null)" || return 1
      printf -v "$output_variable" '0|%s' "$value"
    }
  fi

  payload=$'version=1\ndevice=Device One\ncountries=GB NL\n'
  printf '%s' "$payload" > "$TEST_TMP/settings"
  chmod 600 -- "$TEST_TMP/settings"
  exec 3<"$TEST_TMP/credential"
  exec 4<"$TEST_TMP/settings"
  credential_fd=3
  settings_fd=4
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  capture_cli_settings_fd || return 1
  assert_eq '' "$SETTINGS_FD" "capture must close and clear the original settings descriptor" || return 1
  assert_eq 1 "$PROPOSED_SETTINGS_READY" "valid settings must arm the in-memory overlay" || return 1
  assert_eq 'Device One' "$PROPOSED_AIRVPN_DEVICE" "device must be captured exactly" || return 1
  assert_eq 'GB NL' "$PROPOSED_AIRVPN_COUNTRIES" "ordered country policy must be captured exactly" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] || fail "settings descriptor must be closed after capture" || return 1
  IFS= read -r -u "$credential_fd" _ || fail "capture must not consume the credential descriptor" || return 1
  exec {credential_fd}<&-

  printf '%s' $'version=1\ndevice=Device One\ncountries=ALL\n' > "$TEST_TMP/anonymous-settings"
  chmod 600 -- "$TEST_TMP/anonymous-settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/anonymous-settings"
  rm -f -- "$TEST_TMP/anonymous-settings"
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  capture_cli_settings_fd || return 1
  assert_eq '' "$PROPOSED_AIRVPN_COUNTRIES" \
    "ALL must map to the runtime's explicit empty all-country policy" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "capture must support and close an unlinked private temporary file" || return 1
  exec {credential_fd}<&-

  for case_name in missing_newline extra_field bad_version empty_device long_device \
      bad_device lower_country duplicate_country mixed_all double_space too_many_countries; do
    case "$case_name" in
      missing_newline) payload=$'version=1\ndevice=default\ncountries=GB' ;;
      extra_field) payload=$'version=1\ndevice=default\ncountries=GB\nextra=x\n' ;;
      bad_version) payload=$'version=01\ndevice=default\ncountries=GB\n' ;;
      empty_device) payload=$'version=1\ndevice=\ncountries=GB\n' ;;
      long_device) payload="version=1"$'\n'"device=$(printf '%065d' 0)"$'\n'"countries=GB"$'\n' ;;
      bad_device) payload=$'version=1\ndevice=-default\ncountries=GB\n' ;;
      lower_country) payload=$'version=1\ndevice=default\ncountries=gb\n' ;;
      duplicate_country) payload=$'version=1\ndevice=default\ncountries=GB GB\n' ;;
      mixed_all) payload=$'version=1\ndevice=default\ncountries=ALL GB\n' ;;
      double_space) payload=$'version=1\ndevice=default\ncountries=GB  NL\n' ;;
      too_many_countries) payload=$'version=1\ndevice=default\ncountries=AA AB AC AD AE AF AG AH AI AJ AK AL AM AN AO AP AQ AR AS AT AU AV AW AX AY AZ BA BB BC BD BE BF BG\n' ;;
    esac
    printf '%s' "$payload" > "$TEST_TMP/settings"
    exec {credential_fd}<"$TEST_TMP/credential"
    exec {settings_fd}<"$TEST_TMP/settings"
    SETTINGS_FD="$settings_fd"
    CREDENTIAL_FD="$credential_fd"
    PROPOSED_SETTINGS_READY=0
    set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name settings record must fail closed" || return 1
    assert_eq '' "$SETTINGS_FD" "$case_name refusal must still close the descriptor" || return 1
    assert_eq 0 "$PROPOSED_SETTINGS_READY" "$case_name refusal must not arm an overlay" || return 1
    [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] || fail "$case_name descriptor leaked" || return 1
    [[ ! -e "/proc/$BASHPID/fd/$credential_fd" ]] || fail "$case_name credential descriptor leaked" || return 1
  done

  payload=$'version=1\ndevice=default\ncountries=ALL\n'
  printf '%s' "$payload" > "$TEST_TMP/settings"
  for metadata_case in wrong_owner wrong_mode oversized nonregular; do
    exec {credential_fd}<"$TEST_TMP/credential"
    exec {settings_fd}<"$TEST_TMP/settings"
    SETTINGS_FD="$settings_fd"
    CREDENTIAL_FD="$credential_fd"
    SETTINGS_METADATA_CASE="$metadata_case"
    SETTINGS_METADATA_PROBE_FD="$settings_fd"
    settings_fd_metadata() {
      local output_variable="${1:?}" descriptor="${2:?}" base owner=0 mode=600 kind='regular file'
      base="$(stat -Lc '%s|%d|%i' -- "/proc/$BASHPID/fd/$descriptor" {descriptor}<&-)" || return 1
      if [[ "$descriptor" == "$SETTINGS_METADATA_PROBE_FD" ]]; then
        case "$SETTINGS_METADATA_CASE" in
          wrong_owner) owner=1 ;;
          wrong_mode) mode=640 ;;
          oversized) base="257|${base#*|}" ;;
          nonregular) kind='fifo' ;;
        esac
      fi
      printf -v "$output_variable" '%s|%s|%s|%s|%s|%s' \
        "$owner" "$mode" "$base" '2026-07-13 12:00:00.000000001 +0000' \
        '2026-07-13 12:00:00.000000001 +0000' "$kind"
    }
    set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$metadata_case settings metadata must fail closed" || return 1
    [[ ! -e "/proc/$BASHPID/fd/$credential_fd" && ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
      fail "$metadata_case refusal must close both private descriptors" || return 1
  done

  printf '%s' $'version=1\ndevice=default\ncountries=ALL\n' > "$TEST_TMP/settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  SETTINGS_FD="$settings_fd"
  CREDENTIAL_FD="$credential_fd"
  metadata_calls=0
  settings_fd_metadata() {
    local output_variable="${1:?}" descriptor="${2:?}" value
    metadata_calls=$((metadata_calls + 1))
    value="$(stat -Lc '0|600|%s|%d|%i' -- \
      "/proc/$BASHPID/fd/$descriptor" {descriptor}<&-)"
    value+='|2026-07-13 12:00:00.000000001 +0000|2026-07-13 12:00:00.000000001 +0000|regular file'
    if (( metadata_calls == 4 )); then
      value="${value/12:00:00.000000001 +0000|regular file/12:00:00.000000002 +0000|regular file}"
    fi
    printf -v "$output_variable" '%s' "$value"
  }
  set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "metadata drift during capture must fail closed" || return 1
  assert_eq '' "$SETTINGS_FD" "metadata drift must still close the settings descriptor" || return 1

  settings_fd_metadata() {
    local output_variable="${1:?}" descriptor="${2:?}" value
    value="$(stat -Lc '0|600|%s|%d|%i|%Y|%Z|regular file' -- \
      "/proc/$BASHPID/fd/$descriptor" {descriptor}<&-)" || return 1
    printf -v "$output_variable" '%s' "$value"
  }
  exec {credential_fd}<"$TEST_TMP/settings"
  exec {settings_fd}<"$TEST_TMP/settings"
  CREDENTIAL_FD="$credential_fd"
  SETTINGS_FD="$settings_fd"
  set +e; capture_cli_settings_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "different descriptor numbers for one inode must be rejected" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$credential_fd" && ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "same-inode refusal must close both descriptors"
}
test_main_captures_settings_before_context_and_overlays_only_memory() {
  local credential_fd settings_fd rc before_cfg events leaked=''
  new_main_fixture
  printf '%s\n' \
    'MAX_AGE=180' \
    'AIRVPN_PROFILE_SOURCE=static' \
    'AIRVPN_DEVICE=Installed-Device' \
    'AIRVPN_COUNTRIES=GB' > "$CFG"
  before_cfg="$(<"$CFG")"
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  printf '%s' $'version=1\ndevice=Proposed Device\ncountries=NZ AU\n' > "$TEST_TMP/settings"
  chmod 600 -- "$TEST_TMP/settings"
  : > "$TEST_TMP/settings-events"
  events="$TEST_TMP/settings-events"
  settings_fd_metadata() {
    local output_variable="${1:?}" descriptor="${2:?}" value
    value="$(stat -Lc '0|600|%s|%d|%i|%Y|%Z|regular file' -- \
      "/proc/$BASHPID/fd/$descriptor" {descriptor}<&- 2>/dev/null)" || return 1
    printf -v "$output_variable" '%s' "$value"
  }
  load_managed_module() { :; }
  managed_dispatch_command() {
    [[ ! "$TEST_TMP/settings" -ef "/proc/$BASHPID/fd/$SETTINGS_PROBE_FD" ]] || return 91
    printf 'dispatch:%s:%s\n' "$AIRVPN_DEVICE" "$AIRVPN_COUNTRIES" >> "$events"
  }
  eval "$(declare -f load_command_context | sed '1s/load_command_context/original_load_command_context/')"
  load_command_context() {
    [[ ! "$TEST_TMP/settings" -ef "/proc/$BASHPID/fd/$SETTINGS_PROBE_FD" ]] || return 92
    [[ ! "$TEST_TMP/credential" -ef "/proc/$BASHPID/fd/$CREDENTIAL_PROBE_FD" ]] || return 93
    original_load_command_context || return 1
    printf 'context:%s:%s\n' "$AIRVPN_DEVICE" "$AIRVPN_COUNTRIES" >> "$events"
  }

  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  CREDENTIAL_PROBE_FD="$credential_fd"
  SETTINGS_PROBE_FD="$settings_fd"
  main provision wg0 --dry-run --credential-fd "$credential_fd" \
    --settings-fd "$settings_fd" || return 1
  assert_eq $'context:Proposed Device:NZ AU\ndispatch:Proposed Device:NZ AU' "$(<"$events")" \
    "proposed settings must be overlaid after parsing and before managed dry-run" || return 1
  assert_eq "$before_cfg" "$(<"$CFG")" "settings overlay must never rewrite installed config" || return 1
  [[ ! "$TEST_TMP/settings" -ef "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "settings descriptor reached a downstream child" || return 1

  : > "$events"
  printf '%s' $'version=1\ndevice=default\ncountries=gb\n' > "$TEST_TMP/settings"
  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  CREDENTIAL_PROBE_FD="$credential_fd"
  SETTINGS_PROBE_FD="$settings_fd"
  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" \
    --settings-fd "$settings_fd" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "invalid proposed settings must fail before context" || return 1
  assert_eq '' "$(<"$events")" "invalid settings must precede config, state, lock, and provider effects" || return 1
  set +e; IFS= read -r -u "$credential_fd" leaked 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "invalid settings must close the credential descriptor too" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$settings_fd" ]] || fail "invalid settings descriptor leaked"
}
test_main_sanitizes_before_settings_metadata_children() {
  local credential_fd settings_fd rc events marker
  new_main_fixture
  events="$TEST_TMP/events"
  marker="$TEST_TMP/hostile-stat"
  : > "$events"
  printf 'credential sentinel\n' > "$TEST_TMP/credential"
  printf '%s' $'version=1\ndevice=default\ncountries=GB\n' > "$TEST_TMP/settings"
  chmod 600 -- "$TEST_TMP/settings"

  eval "$(declare -f sanitize_process_environment | sed \
    '1s/sanitize_process_environment/original_sanitize_process_environment/')"
  sanitize_process_environment() {
    printf 'sanitize\n' >> "$events"
    if ! /bin/bash -c '
      [[ ! -e "/proc/self/fd/$1" && ! -e "/proc/self/fd/$2" ]]
    ' bash "$credential_fd" "$settings_fd"; then
      printf 'private descriptor reached sanitizer child\n' >> "$marker"
    fi
    original_sanitize_process_environment
  }
  eval "$(declare -f capture_cli_settings_fd | sed \
    '1s/capture_cli_settings_fd/original_capture_cli_settings_fd/')"
  capture_cli_settings_fd() {
    printf 'capture\n' >> "$events"
    [[ "$PATH" == /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ]] || return 97
    [[ -z "${AIRVPN_API_KEY+x}" && -z "${LD_LIBRARY_PATH+x}" ]] || return 98
    original_capture_cli_settings_fd
  }
  load_command_context() { return 1; }
  stat() { printf 'hostile stat executed\n' >> "$marker"; return 99; }

  exec {credential_fd}<"$TEST_TMP/credential"
  exec {settings_fd}<"$TEST_TMP/settings"
  PATH="$TEST_TMP"
  AIRVPN_API_KEY='environment sentinel'
  LD_LIBRARY_PATH="$TEST_TMP"
  export PATH AIRVPN_API_KEY LD_LIBRARY_PATH
  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" \
    --settings-fd "$settings_fd" >/dev/null 2>&1
  rc=$?
  set +e

  assert_eq 1 "$rc" "the post-capture context refusal must remain visible" || return 1
  assert_eq $'sanitize\ncapture' "$(<"$events")" \
    "core suppression must be followed by environment sanitization before settings capture" || return 1
  [[ ! -e "$marker" ]] || fail "settings metadata must not resolve a hostile stat function" || return 1
  [[ -z "${AIRVPN_API_KEY+x}" && -z "${LD_LIBRARY_PATH+x}" ]] ||
    fail "settings metadata children must receive no inherited secret or loader environment" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$credential_fd" && ! -e "/proc/$BASHPID/fd/$settings_fd" ]] ||
    fail "failed post-capture context must close both private descriptors"
}
test_second_sanitizer_failure_closes_restored_credential_fd() {
  local credential_fd rc read_rc leaked='' sanitizer_calls=0
  new_main_fixture
  printf 'credential sentinel\n' > "$TEST_TMP/credential"

  eval "$(declare -f sanitize_process_environment | sed \
    '1s/sanitize_process_environment/original_sanitize_process_environment/')"
  sanitize_process_environment() {
    sanitizer_calls=$((sanitizer_calls + 1))
    (( sanitizer_calls == 1 )) || return 88
    original_sanitize_process_environment
  }

  exec {credential_fd}<"$TEST_TMP/credential"
  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd" >/dev/null 2>&1
  rc=$?
  set +e

  assert_eq 1 "$rc" "second sanitizer failure must fail closed" || return 1
  assert_eq 2 "$sanitizer_calls" "context loading must exercise the second sanitizer" || return 1
  [[ ! -e "/proc/$BASHPID/fd/$credential_fd" ]] ||
    fail "restored credential descriptor leaked after second sanitizer failure" || return 1
  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "restored credential descriptor must be unreadable" || return 1
  assert_eq '' "$CREDENTIAL_FD" "failed main path must clear credential ownership"
}
test_runtime_defaults_and_fixed_paths_ignore_environment() {
  local key actual
  local -A expected=(
    [MAX_AGE]=180 [PING_TARGET]='' [PING_COUNT]=1 [PING_TIMEOUT]=2
    [REQUIRED_ROUTE]='' [REQUIRED_RULE]='' [COOLDOWN]=300 [RESTART_DELAY]=5
    [WG_DOWN_TIMEOUT]=20 [WG_UP_TIMEOUT]=30 [SPEED_CHECK_ENABLED]=0
    [SPEED_CHECK_INTERVAL]=900 [SPEED_CHECK_URL]='https://speed.cloudflare.com/__down?bytes=10000000'
    [SPEED_MIN_BPS]=2500000 [SPEED_TIMEOUT]=25 [SPEED_RETRY_DELAY]=5
    [AIRVPN_ROTATE_ENABLED]=0 [AIRVPN_PROFILE_SOURCE]=static [AIRVPN_DEVICE]=''
    [AIRVPN_COUNTRIES]='GB NL BE DE FR IE'
    [AIRVPN_WG_PORT]=1637 [AIRVPN_ROTATE_COOLDOWN]=1800
    [AIRVPN_STATUS_URL]='https://airvpn.org/api/status/?format=json'
    [AIRVPN_WHATISMYIP_URL]='https://airvpn.org/api/whatismyip/?format=json'
    [AIRVPN_API_TIMEOUT]=20 [QBITTORRENT_CONTAINER]='' [QBITTORRENT_LISTEN_IP]=''
    [QBITTORRENT_LISTEN_PORT]='' [QBITTORRENT_PROCESS_NAME]=qbittorrent-nox
    [QBITTORRENT_RESTART_DELAY]=5 [QBITTORRENT_RESTART_TIMEOUT]=60
  )

  source "$SCRIPT"
  declare -F reset_configurable_defaults >/dev/null || fail "configurable-default reset owner is missing" || return 1
  declare -F derive_fixed_runtime_paths >/dev/null || fail "fixed runtime-path owner is missing" || return 1
  for key in "${!expected[@]}"; do printf -v "$key" '%s' hostile; done
  reset_configurable_defaults
  for key in "${!expected[@]}"; do
    actual="${!key}"
    assert_eq "${expected[$key]}" "$actual" "$key must reset to its documented default" || return 1
  done

  IFACE=wg0
  for key in CFG WG_CONF STATE_DIR LOCK SETUP_GUARD RESTART_STAMP ROTATE_STAMP SPEED_STAMP STATUS_FILE \
      ROTATION_PENDING MANAGED_SAFETY AIRVPN_API_HELPER MANAGED_MODULE AIRVPN_API_KEY_FILE \
      AIRVPN_API_STATE_FILE AIRVPN_API_LOCK MANAGED_CANDIDATE PRE_MANAGED_CONF PATH; do
    printf -v "$key" '%s' "/tmp/hostile-$key"
  done
  derive_fixed_runtime_paths
  assert_eq '/etc/wireguard/healthcheck.d/wg0.conf' "$CFG" "CFG must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf' "$WG_CONF" "WG_CONF must be fixed" || return 1
  assert_eq '/run/wg-healthcheck' "$STATE_DIR" "STATE_DIR must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.lock' "$LOCK" "LOCK must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.setup-guard' "$SETUP_GUARD" "setup guard path must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_restart' "$RESTART_STAMP" "restart stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_rotate' "$ROTATE_STAMP" "rotation stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.last_speedcheck' "$SPEED_STAMP" "speed stamp must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/wg0.status' "$STATUS_FILE" "status path must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.pending-healthcheck' "$ROTATION_PENDING" "pending marker must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.safety-healthcheck' "$MANAGED_SAFETY" "managed safety path must be fixed" || return 1
  assert_eq '/usr/local/libexec/wg-healthcheck/airvpn-api' "$AIRVPN_API_HELPER" "helper path must be fixed" || return 1
  assert_eq '/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed' "$MANAGED_MODULE" "managed module path must be fixed" || return 1
  assert_eq '/etc/wireguard/healthcheck.d/wg0.api-key' "$AIRVPN_API_KEY_FILE" "credential path must be fixed" || return 1
  assert_eq '/var/lib/wg-healthcheck/wg0.api-state' "$AIRVPN_API_STATE_FILE" "persistent API state path must be fixed" || return 1
  assert_eq '/run/wg-healthcheck/airvpn-api.lock' "$AIRVPN_API_LOCK" "global API lock path must be fixed" || return 1
  assert_eq '/etc/wireguard/.wg0.conf.managed-candidate' "$MANAGED_CANDIDATE" "managed candidate path must be fixed" || return 1
  assert_eq '/etc/wireguard/wg0.conf.pre-managed' "$PRE_MANAGED_CONF" "pre-managed snapshot path must be fixed" || return 1
  assert_eq '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$PATH" "PATH must be fixed"
}
test_process_environment_is_sanitized_for_child_commands() {
  local key exported
  local -a removed=(
    BASH_ENV ENV CDPATH GLOBIGNORE IFS PS4 PROMPT_COMMAND
    LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME AIRVPN_API_KEY
  )
  source "$SCRIPT"
  declare -F sanitize_process_environment >/dev/null || fail "process-environment sanitizer is missing" || return 1
  PATH=/tmp/hostile-bin
  LC_ALL=POSIX
  for key in "${removed[@]}"; do
    printf -v "$key" '%s' hostile
    export "$key"
  done
  export SHELLOPTS BASHOPTS 2>/dev/null || true

  sanitize_process_environment

  assert_eq '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$PATH" "sanitized PATH must be fixed" || return 1
  assert_eq C "$LC_ALL" "child locale must be deterministic" || return 1
  for key in "${removed[@]}"; do
    [[ -z "${!key+x}" ]] || fail "$key must be unset before child commands" || return 1
  done
  exported="$(export -p)"
  [[ "$exported" != *'SHELLOPTS'* && "$exported" != *'BASHOPTS'* ]] ||
    fail "readonly Bash option variables must not be exported to children"
}
test_hostile_internal_paths_cannot_redirect_main_or_truncate_lock_target() {
  local rc victim expected_cfg expected_wg calls
  new_main_fixture
  expected_cfg="$CFG"
  expected_wg="$WG_CONF"
  victim="$TEST_TMP/victim"
  printf 'do-not-truncate\n' > "$victim"
  CFG="$TEST_TMP/hostile.conf"
  WG_CONF="$TEST_TMP/hostile-wg.conf"
  STATE_DIR="$TEST_TMP/hostile-state"
  LOCK="$victim"
  SETUP_GUARD="$victim"
  RESTART_STAMP="$TEST_TMP/hostile-restart"
  ROTATE_STAMP="$TEST_TMP/hostile-rotate"
  SPEED_STAMP="$TEST_TMP/hostile-speed"
  STATUS_FILE="$TEST_TMP/hostile-status"
  ROTATION_PENDING="$TEST_TMP/hostile-pending"
  AIRVPN_API_HELPER="$TEST_TMP/hostile-helper"
  PATH="$TEST_TMP/hostile-path"
  : > "$TEST_TMP/validated"
  validate_secure_file() { printf '%s\n' "$1" >> "$TEST_TMP/validated"; return 0; }
  flock() { return 1; }

  set +e
  main wg0
  rc=$?
  set +e
  calls="$(<"$TEST_TMP/validated")"

  assert_eq 0 "$rc" "lock contention on the fixed lock must remain nonfatal" || return 1
  assert_file_equals 'do-not-truncate' "$victim" "hostile LOCK must never be opened" || return 1
  assert_eq "$expected_cfg" "$CFG" "main must replace hostile CFG through its source-only path seam" || return 1
  assert_eq "$expected_wg" "$WG_CONF" "main must replace hostile WG_CONF through its source-only path seam" || return 1
  assert_eq '' "$calls" "guard contention must precede every configuration validation" || return 1
  assert_eq "$TEST_TMP/state/wg0.setup-guard" "$SETUP_GUARD" "main must replace hostile setup-guard input"
}
test_main_validates_both_fixed_files_before_parsing_config() {
  local rc events expected
  new_main_fixture
  : > "$TEST_TMP/order"
  validate_secure_file() { printf 'validate:%s:%s:%s\n' "$1" "$2" "$3" >> "$TEST_TMP/order"; }
  parse_healthcheck_config() { printf 'parse:%s\n' "$1" >> "$TEST_TMP/order"; }
  validate_settings() { printf 'settings\n' >> "$TEST_TMP/order"; return 1; }
  prepare_state_dir() { mkdir -p -- "$STATE_DIR"; }

  set +e
  main wg0
  rc=$?
  set +e
  events="$(<"$TEST_TMP/order")"
  expected="validate:${CFG}:health-check configuration:600"$'\n'
  expected+="validate:${WG_CONF}:WireGuard configuration:600"$'\n'
  expected+="parse:${CFG}"$'\nsettings'

  assert_eq 1 "$rc" "fixture must stop after validation and parsing" || return 1
  assert_eq "$expected" "$events" "both fixed files must validate before CFG is parsed and semantically validated"
}
test_config_parser_accepts_template_and_whole_quoted_values() {
  local file
  source "$SCRIPT"
  declare -F parse_healthcheck_config >/dev/null || fail "strict config parser is missing" || return 1
  declare -F reset_configurable_defaults >/dev/null || return 1
  reset_configurable_defaults
  parse_healthcheck_config "$ROOT/config/wg0.conf.example" || fail "valid installed template must parse" || return 1
  assert_eq 2 "$PING_COUNT" "template numeric setting must apply" || return 1
  assert_eq static "$AIRVPN_PROFILE_SOURCE" "template must explicitly retain static mode" || return 1
  assert_eq '' "$AIRVPN_DEVICE" "static template must not invent a device" || return 1
  assert_eq 'GB NL BE DE FR IE' "$AIRVPN_COUNTRIES" "template quoted country list must apply" || return 1

  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  file="$TEST_TMP/valid.conf"
  printf '%s\n' \
    'PING_TARGET=' \
    'AIRVPN_COUNTRIES="GB NL"' \
    'REQUIRED_ROUTE="default dev wg0 table 40"' \
    "REQUIRED_RULE='from 10.0.0.2 lookup 40'" \
    'SPEED_CHECK_URL=https://speed.cloudflare.com/__down?bytes=10000000' > "$file"
  reset_configurable_defaults
  parse_healthcheck_config "$file" || return 1
  assert_eq '' "$PING_TARGET" "empty value must parse" || return 1
  assert_eq 'GB NL' "$AIRVPN_COUNTRIES" "whole double-quoted value must parse" || return 1
  assert_eq 'default dev wg0 table 40' "$REQUIRED_ROUTE" "quoted route must parse" || return 1
  assert_eq 'from 10.0.0.2 lookup 40' "$REQUIRED_RULE" "whole single-quoted value must parse"
}
test_config_parser_rejects_internal_unknown_duplicate_and_malformed_keys() {
  local payload rc file
  local -a payloads=(
    'LOCK=/tmp/victim' 'CFG=/tmp/config' 'ARBITRARY=value' 'BASH_ENV=/tmp/code'
    'PATH=/tmp/bin' 'LD_PRELOAD=/tmp/lib.so' $'MAX_AGE=10\nMAX_AGE=11'
    ' MAX_AGE=10' 'MAX_AGE =10' 'export MAX_AGE=10' 'MAX_AGE[0]=10' 'MAX_AGE'
  )
  source "$SCRIPT"
  declare -F parse_healthcheck_config >/dev/null || fail "strict config parser is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  file="$TEST_TMP/rejected.conf"
  log() { :; }
  for payload in "${payloads[@]}"; do
    printf '%s\n' "$payload" > "$file"
    set +e; parse_healthcheck_config "$file"; rc=$?; set +e
    assert_eq 1 "$rc" "parser must reject unsafe assignment: $payload" || return 1
  done
}
