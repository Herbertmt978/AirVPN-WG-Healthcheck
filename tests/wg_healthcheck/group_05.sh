#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, hostile
# PATH/export fixtures, literal attack payloads, and function doubles.
# shellcheck disable=SC1090,SC2016,SC2034,SC2064,SC2123,SC2153,SC2163,SC2317,SC2329

# wg-healthcheck test group 05; function bodies preserved from legacy suite.

test_admin_commands_refuse_pending_state_without_reconciliation_effects() {
  local command marker_kind rc
  new_main_fixture
  IFACE=wg0
  derive_fixed_runtime_paths
  : > "$TEST_TMP/admin-events"
  load_managed_module() { MANAGED_MODULE_LOADED=1; }
  managed_reconcile_pending() { printf 'reconcile\n' >> "$TEST_TMP/admin-events"; }
  managed_dispatch_command() { :; }

  for marker_kind in v1 v2 safety; do
    rm -f -- "$ROTATION_PENDING" "$MANAGED_SAFETY"
    case "$marker_kind" in
      v1) printf '192.0.2.10:1637\n' > "$ROTATION_PENDING" ;;
      v2) printf 'version=2\n' > "$ROTATION_PENDING" ;;
      safety) printf 'version=1\n' > "$MANAGED_SAFETY" ;;
    esac
    for command in provision adopt rotate restore-static reset-api-state; do
      COMMAND="$command"
      AIRVPN_PROFILE_SOURCE=api
      DISPATCH_READY=0
      : > "$TEST_TMP/admin-events"
      set +e; prepare_command_dispatch >/dev/null 2>&1; rc=$?; set +e
      assert_eq 75 "$rc" "$command must refuse unresolved $marker_kind recovery state" || return 1
      assert_eq '' "$(<"$TEST_TMP/admin-events")" \
        "$command refusal must not reconcile Docker or network state" || return 1
      assert_eq 0 "$DISPATCH_READY" "$command must not reach managed dispatch" || return 1
    done

    COMMAND=status
    DISPATCH_READY=0
    : > "$TEST_TMP/admin-events"
    prepare_command_dispatch || return 1
    assert_eq '' "$(<"$TEST_TMP/admin-events")" \
      "status must observe $marker_kind without reconciliation" || return 1
    assert_eq 1 "$DISPATCH_READY" "status must reach its observational renderer"
  done
}
test_status_main_path_is_observational_and_creates_no_runtime_files() {
  local output rc
  new_main_fixture
  rm -rf -- "$STATE_DIR"
  : > "$TEST_TMP/status-events"
  prepare_state_dir() { printf 'prepare-state\n' >> "$TEST_TMP/status-events"; return 1; }
  load_managed_module() { MANAGED_MODULE_LOADED=1; }
  managed_dispatch_command() {
    printf 'mode=static\ntimer=unknown\ntunnel=down\nlast_check=0\nlast_rotation=0\ncredential_present=false\npending=none\nqbittorrent=unmanaged\n'
  }
  set +e; output="$(main status wg0)"; rc=$?; set +e
  assert_eq 0 "$rc" "status must work without a pre-existing runtime state directory" || return 1
  assert_contains 'mode=static' "$output" "status output must reach the observational owner" || return 1
  assert_eq '' "$(<"$TEST_TMP/status-events")" "status must not prepare or chmod runtime state" || return 1
  [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] ||
    fail "status must not create the runtime state directory" || return 1
  [[ ! -e "$LOCK" && ! -L "$LOCK" ]] || fail "status must not create the interface lock"
  [[ ! -e "$SETUP_GUARD" && ! -L "$SETUP_GUARD" ]] || fail "status must not create the setup guard"
}
test_interface_lock_open_is_nofollow_private_and_never_truncates_symlink_target() {
  local rc lock_fd='' victim
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  STATE_DIR="$TEST_TMP/state"
  IFACE=wg0
  LOCK="$STATE_DIR/wg0.lock"
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  victim="$TEST_TMP/victim"
  printf 'do-not-truncate\n' > "$victim"
  ln -s -- "$victim" "$LOCK"
  set +e; open_interface_lock lock_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "interface lock symlink must be rejected" || return 1
  assert_eq do-not-truncate "$(<"$victim")" "lock validation must never follow or truncate a symlink" || return 1
  rm -f -- "$LOCK"
  owner_mode() { printf '0:600\n'; }
  interface_lock_fd_identity() { stat -Lc '%d:%i' -- "$LOCK"; }
  open_interface_lock lock_fd || return 1
  [[ "$lock_fd" =~ ^[0-9]+$ ]] || fail "interface lock owner must return a numeric descriptor" || return 1
  if [[ "$(uname -s)" == Linux ]]; then
    assert_eq 600 "$(stat -c '%a' -- "$LOCK")" "created interface lock must be private" || return 1
  fi
  exec {lock_fd}>&-
}
test_core_dump_suppression_precedes_context_and_closes_credential_on_failure() {
  local rc leaked
  new_main_fixture
  printf 'descriptor-only-test-record\n' > "$TEST_TMP/credential"
  exec 9<"$TEST_TMP/credential"
  : > "$TEST_TMP/core-events"
  disable_core_dumps() { printf 'core\n' >> "$TEST_TMP/core-events"; return 1; }
  load_command_context() { printf 'context\n' >> "$TEST_TMP/core-events"; return 1; }
  managed_dispatch_command() { printf 'provider\n' >> "$TEST_TMP/core-events"; }
  set +e; main provision wg0 --dry-run --credential-fd 9 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "core-limit failure must fail before credential use" || return 1
  assert_eq core "$(<"$TEST_TMP/core-events")" \
    "core suppression must precede context, provider, and every child" || return 1
  set +e; IFS= read -r -u 9 leaked 2>/dev/null; rc=$?; set +e
  assert_eq 1 "$rc" "core-limit failure must close the supplied credential descriptor" || return 1

  : > "$TEST_TMP/core-events"
  disable_core_dumps() { printf 'core\n' >> "$TEST_TMP/core-events"; }
  load_command_context() { printf 'context\n' >> "$TEST_TMP/core-events"; return 1; }
  set +e; main wg0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "ordering fixture must stop in context" || return 1
  assert_eq $'core\ncontext' "$(<"$TEST_TMP/core-events")" \
    "core suppression must be established before runtime context"
}
test_reset_context_allows_genuinely_missing_profile_but_not_symlink() {
  local rc
  new_main_fixture
  COMMAND=reset-api-state
  IFACE=wg0
  rm -f -- "$WG_CONF"
  load_command_context || fail "state reset must remain usable when the profile is absent" || return 1
  [[ "$(uname -s)" == MINGW* ]] && return 0
  new_main_fixture
  COMMAND=reset-api-state
  IFACE=wg0
  rm -f -- "$WG_CONF"
  command mkdir -p -- "${WG_CONF%/*}" || return 1
  printf 'target\n' > "$TEST_TMP/missing-profile"
  command ln -s -- "$TEST_TMP/missing-profile" "$WG_CONF" || return 1
  validate_secure_file() {
    [[ "$1" != "$WG_CONF" || ! -L "$WG_CONF" ]]
  }
  set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "state reset must still refuse a profile symlink"
}
test_status_context_validates_existing_state_directory_without_repair() {
  local rc before_mode
  new_main_fixture
  COMMAND=status
  IFACE=wg0
  derive_fixed_runtime_paths
  chmod 755 -- "$STATE_DIR"
  before_mode="$(stat -c '%a' -- "$STATE_DIR")"
  set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "status must refuse an existing insecure runtime state directory" || return 1
  assert_eq "$before_mode" "$(stat -c '%a' -- "$STATE_DIR")" \
    "observational status must never chmod or repair state"
}
test_context_refuses_untrusted_config_parent_before_file_or_parse() {
  local case_name rc real_parent
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  IFACE=wg0
  real_parent="$TEST_TMP/healthcheck.d"
  mkdir -p -- "$real_parent"
  chmod 700 -- "$real_parent"
  CFG="$real_parent/wg0.conf"
  WG_CONF="$TEST_TMP/wg0.conf"
  STATE_DIR="$TEST_TMP/state"
  printf 'AIRVPN_PROFILE_SOURCE=static\n' > "$CFG"
  printf '%s\n' '[Interface]' '[Peer]' 'Endpoint = 192.0.2.10:1637' > "$WG_CONF"
  chmod 600 -- "$CFG" "$WG_CONF"
  derive_fixed_runtime_paths() { :; }
  sanitize_process_environment() { :; }
  is_root() { return 0; }
  log() { :; }
  validate_secure_file() { printf 'file-validation\n' >> "$TEST_TMP/context-events"; }
  parse_healthcheck_config() { printf 'parse\n' >> "$TEST_TMP/context-events"; }
  validate_settings() { printf 'settings\n' >> "$TEST_TMP/context-events"; }
  prepare_state_dir() { printf 'state\n' >> "$TEST_TMP/context-events"; }

  for case_name in mode_0755 mode_0770 wrong_owner symlink; do
    CFG="$real_parent/wg0.conf"
    CONFIG_PARENT_CASE="$case_name"
    if [[ "$case_name" == symlink ]]; then
      ln -s -- "$real_parent" "$TEST_TMP/linked-healthcheck.d"
      CFG="$TEST_TMP/linked-healthcheck.d/wg0.conf"
    fi
    owner_mode() {
      if [[ "$1" == "${CFG%/*}" ]]; then
        case "$CONFIG_PARENT_CASE" in
          mode_0755) printf '0:755\n' ;;
          mode_0770) printf '0:770\n' ;;
          wrong_owner) printf '65534:700\n' ;;
          *) printf '0:700\n' ;;
        esac
      else
        printf '0:600\n'
      fi
    }
    : > "$TEST_TMP/context-events"
    COMMAND=check
    set +e; load_command_context >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$case_name config parent must fail closed" || return 1
    assert_eq '' "$(<"$TEST_TMP/context-events")" \
      "$case_name config parent refusal must precede file validation and parsing" || return 1
    rm -f -- "$TEST_TMP/linked-healthcheck.d"
  done
}
