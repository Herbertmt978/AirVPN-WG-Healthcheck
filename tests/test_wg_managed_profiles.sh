#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, and
# security-boundary function doubles.
# shellcheck disable=SC1090,SC2034,SC2064,SC2317,SC2329

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/wg-healthcheck"
MODULE="$ROOT/libexec/wg-healthcheck-managed"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
  local needle="$1" haystack="$2" message="${3:-text not found}"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing '$needle')"
}

write_valid_test_key() {
  printf '%064d\n' 0 > "$1"
}

source_managed_contract() {
  [[ -f "$MODULE" ]] || fail "managed module is missing" || return 1
  source "$SCRIPT"
  source "$MODULE"
}

test_managed_module_exports_minimal_task4_contract() {
  local function_name
  source_managed_contract || return 1
  for function_name in open_installed_api_key managed_dispatch_command managed_reconcile_pending; do
    declare -F "$function_name" >/dev/null || fail "managed module must export $function_name" || return 1
  done
}

test_managed_module_validation_requires_root_owned_0644_trusted_source() {
  local case_name rc
  source "$SCRIPT"
  declare -F load_managed_module >/dev/null || fail "secure managed-module loader is missing" || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  MANAGED_MODULE="$TEST_TMP/libexec/wg-healthcheck/wg-healthcheck-managed"
  mkdir -p -- "${MANAGED_MODULE%/*}"
  printf 'TEST_MODULE_SOURCED=1\n' > "$MANAGED_MODULE"

  for case_name in secure source_symlink source_owner source_writable source_executable \
      parent_symlink parent_owner parent_writable; do
    unset TEST_MODULE_SOURCED
    MANAGED_MODULE_LOADED=0
    path_is_regular() { [[ "$case_name" != source_symlink ]]; }
    path_is_directory() { return 0; }
    path_is_symlink() {
      [[ "$case_name" == source_symlink && "$1" == "$MANAGED_MODULE" ]] ||
        [[ "$case_name" == parent_symlink && "$1" == "${MANAGED_MODULE%/*}" ]]
    }
    owner_mode() {
      if [[ "$1" == "$MANAGED_MODULE" ]]; then
        case "$case_name" in
          source_owner) printf '1000:644\n' ;;
          source_writable) printf '0:664\n' ;;
          source_executable) printf '0:744\n' ;;
          *) printf '0:644\n' ;;
        esac
      else
        case "$case_name" in
          parent_owner) printf '1000:755\n' ;;
          parent_writable) printf '0:775\n' ;;
          *) printf '0:755\n' ;;
        esac
      fi
    }

    set +e; load_managed_module >/dev/null 2>&1; rc=$?; set +e
    if [[ "$case_name" == secure ]]; then
      assert_eq 0 "$rc" "secure managed module must load" || return 1
      assert_eq 1 "${TEST_MODULE_SOURCED:-0}" "secure module must be sourced" || return 1
    else
      assert_eq 1 "$rc" "$case_name managed module must be rejected" || return 1
      assert_eq 0 "${TEST_MODULE_SOURCED:-0}" "rejected module must never be sourced" || return 1
    fi
  done
}

test_installed_key_rejects_every_unsafe_shape_before_downstream_events() {
  local case_name key_fd rc events parent
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/healthcheck.d"
  AIRVPN_API_KEY_FILE="$parent/wg0.api-key"
  mkdir -p -- "$parent"

  for case_name in missing symlink oversized multiline non_ascii wrong_owner wrong_mode unsafe_parent; do
    rm -f -- "$AIRVPN_API_KEY_FILE"
    case "$case_name" in
      missing) ;;
      oversized)
        printf '%065d\n' 0 > "$AIRVPN_API_KEY_FILE"
        ;;
      multiline)
        { printf '%031d\n' 0; printf '%032d\n' 0; } > "$AIRVPN_API_KEY_FILE"
        ;;
      non_ascii)
        { printf '\303\251'; printf '%062d\n' 0; } > "$AIRVPN_API_KEY_FILE"
        ;;
      *) write_valid_test_key "$AIRVPN_API_KEY_FILE" ;;
    esac
    : > "$TEST_TMP/events"
    path_is_regular() { [[ "$case_name" != missing ]]; }
    path_is_directory() { return 0; }
    path_is_symlink() { [[ "$case_name" == symlink && "$1" == "$AIRVPN_API_KEY_FILE" ]]; }
    owner_mode() {
      if [[ "$1" == "$AIRVPN_API_KEY_FILE" ]]; then
        case "$case_name" in
          wrong_owner) printf '1000:600\n' ;;
          wrong_mode) printf '0:640\n' ;;
          *) printf '0:600\n' ;;
        esac
      else
        case "$case_name" in
          unsafe_parent) printf '0:750\n' ;;
          *) printf '0:700\n' ;;
        esac
      fi
    }
    log() { :; }

    key_fd=
    set +e
    if open_installed_api_key key_fd; then
      printf '%s\n' provider candidate docker network >> "$TEST_TMP/events"
      rc=0
      exec {key_fd}<&-
    else
      rc=$?
    fi
    set +e
    events="$(<"$TEST_TMP/events")"
    assert_eq 1 "$rc" "$case_name installed key must fail closed" || return 1
    assert_eq '' "$events" "$case_name key failure must precede provider/candidate/Docker/network actions" || return 1
  done
}

test_installed_key_opens_one_valid_record_on_a_private_descriptor() {
  local count key_fd parent
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/healthcheck.d"
  AIRVPN_API_KEY_FILE="$parent/wg0.api-key"
  mkdir -p -- "$parent"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  path_is_regular() { return 0; }
  path_is_directory() { return 0; }
  path_is_symlink() { return 1; }
  owner_mode() { [[ "$1" == "$AIRVPN_API_KEY_FILE" ]] && printf '0:600\n' || printf '0:700\n'; }
  open_installed_api_key key_fd || return 1
  [[ "$key_fd" =~ ^[0-9]+$ ]] || fail "opened credential descriptor must be numeric" || return 1
  count="$(wc -c <&"$key_fd")"
  exec {key_fd}<&-
  assert_eq 65 "$count" "private descriptor must reference the exact one-record credential"
}

test_fail_closed_dispatch_closes_credential_before_logging() {
  local credential_fd leaked='' rc read_rc
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf 'managed-dispatch-sentinel\n' > "$TEST_TMP/credential"
  exec {credential_fd}<"$TEST_TMP/credential"
  : > "$TEST_TMP/events"
  log() {
    if IFS= read -r -u "$credential_fd" leaked 2>/dev/null; then
      printf 'leaked:%s\n' "$leaked" >> "$TEST_TMP/events"
      return 1
    fi
    printf 'closed-before-log\n' >> "$TEST_TMP/events"
  }

  set +e
  managed_dispatch_command provision dry-run 0 "$credential_fd"
  rc=$?
  set +e
  assert_eq 69 "$rc" "fail-closed managed command must retain its unavailable result" || return 1
  assert_eq closed-before-log "$(<"$TEST_TMP/events")" \
    "fail-closed dispatch must close the credential before any logger child" || return 1
  close_private_fd "$credential_fd" ||
    fail "main's final credential cleanup must remain safe after managed-owner closure" || return 1
  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "fail-closed managed dispatch must leave the credential descriptor closed"
}

test_linux_supplied_credential_fd_is_private_until_managed_owner() {
  local credential_fd events leaked='' rc read_rc sentinel=private-fd-sentinel
  if [[ "$(uname -s)" != Linux ]]; then return 77; fi
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  printf '%s\n' "$sentinel" > "$TEST_TMP/credential"
  exec {credential_fd}<"$TEST_TMP/credential"
  PROBE_FD="$credential_fd"
  : > "$TEST_TMP/events"

  probe_fd_closed_in_child() {
    local stage="$1"
    if ! bash -c '
      fd="$1"
      [[ ! -e "/proc/self/fd/$fd" ]] || exit 1
      if IFS= read -r -u "$fd" value 2>/dev/null; then exit 1; fi
    ' bash "$PROBE_FD"; then
      printf 'leaked:%s\n' "$stage" >> "$TEST_TMP/events"
      return 1
    fi
    printf 'closed:%s\n' "$stage" >> "$TEST_TMP/events"
  }

  derive_fixed_runtime_paths() {
    probe_fd_closed_in_child context || return 1
    CFG="$TEST_TMP/health.conf"
    WG_CONF="$TEST_TMP/wg0.conf"
    STATE_DIR="$TEST_TMP/state"
    LOCK="$STATE_DIR/wg0.lock"
    ROTATION_PENDING="${WG_CONF}.pending-healthcheck"
    MANAGED_MODULE="$TEST_TMP/wg-healthcheck-managed"
  }
  sanitize_process_environment() { probe_fd_closed_in_child environment; }
  is_root() { probe_fd_closed_in_child root-check; }
  validate_secure_file() { probe_fd_closed_in_child stat; }
  parse_healthcheck_config() {
    probe_fd_closed_in_child config || return 1
    AIRVPN_PROFILE_SOURCE=api
    AIRVPN_DEVICE=default
  }
  validate_settings() { probe_fd_closed_in_child settings; }
  prepare_state_dir() { probe_fd_closed_in_child state-dir || return 1; mkdir -p -- "$STATE_DIR"; }
  flock() { probe_fd_closed_in_child lock; }
  log() { probe_fd_closed_in_child log; }
  classify_pending_marker() {
    probe_fd_closed_in_child marker || return 1
    log preflight || return 1
    PENDING_KIND=v1
  }
  reconcile_pending_rotation() {
    probe_fd_closed_in_child reconciliation || return 1
    RECONCILED_PENDING=1
  }
  load_managed_module() {
    probe_fd_closed_in_child module || return 1
    managed_dispatch_command() {
      local received_fd="$4" record
      [[ "$received_fd" == "$PROBE_FD" ]] || return 1
      [[ "$LOCK_FD" != "$received_fd" && -e "/proc/self/fd/$LOCK_FD" ]] || return 1
      IFS= read -r -u "$received_fd" record || return 1
      [[ "$record" == "$sentinel" ]] || return 1
      printf 'owner:%s\n' "$record" >> "$TEST_TMP/events"
    }
  }

  set +e
  main provision wg0 --dry-run --credential-fd "$credential_fd"
  rc=$?
  set +e
  events="$(<"$TEST_TMP/events")"
  assert_eq 0 "$rc" "private descriptor must reach the exact managed owner without preflight leakage" || return 1
  for stage in context environment root-check stat config settings state-dir lock marker log reconciliation module; do
    assert_contains "closed:$stage" "$events" "credential must be absent in $stage child" || return 1
  done
  assert_contains "owner:$sentinel" "$events" \
    "managed owner must receive the original unconsumed credential record" || return 1
  [[ "$events" != *leaked:* ]] || fail "no pre-provider child may inherit the credential descriptor" || return 1

  set +e
  IFS= read -r -u "$credential_fd" leaked 2>/dev/null
  read_rc=$?
  set +e
  assert_eq 1 "$read_rc" "main must close the original credential descriptor before returning" || return 1
  bash -c '[[ ! -e "/proc/self/fd/$1" ]]' bash "$credential_fd" ||
    fail "subsequent children must not inherit the credential descriptor"
}

test_linux_module_owner_and_mode_semantics() {
  local rc
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  source "$SCRIPT"
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  MANAGED_MODULE="$TEST_TMP/trusted/wg-healthcheck-managed"
  mkdir -p -- "${MANAGED_MODULE%/*}"
  printf 'LINUX_MODULE_SOURCED=1\n' > "$MANAGED_MODULE"
  chmod 755 -- "${MANAGED_MODULE%/*}"
  chmod 644 -- "$MANAGED_MODULE"

  MANAGED_MODULE_LOADED=0
  load_managed_module || fail "real root-owned 0644 module under 0755 parent must load" || return 1
  assert_eq 1 "${LINUX_MODULE_SOURCED:-0}" "real secure module must be sourced" || return 1

  MANAGED_MODULE_LOADED=0
  chmod 664 -- "$MANAGED_MODULE"
  set +e; load_managed_module >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real group-writable module must fail" || return 1
  chmod 644 -- "$MANAGED_MODULE"
  chown 1 -- "$MANAGED_MODULE"
  MANAGED_MODULE_LOADED=0
  set +e; load_managed_module >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root module must fail"
}

test_linux_installed_key_owner_and_mode_semantics() {
  local key_fd parent rc
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  parent="$TEST_TMP/healthcheck.d"
  AIRVPN_API_KEY_FILE="$parent/wg0.api-key"
  mkdir -p -- "$parent"
  chmod 700 -- "$parent"
  write_valid_test_key "$AIRVPN_API_KEY_FILE"
  chmod 600 -- "$AIRVPN_API_KEY_FILE"

  open_installed_api_key key_fd || fail "real root-owned 0600 key under 0700 parent must open" || return 1
  exec {key_fd}<&-
  chmod 640 -- "$AIRVPN_API_KEY_FILE"
  set +e; open_installed_api_key key_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real wrong-mode key must fail" || return 1
  chmod 600 -- "$AIRVPN_API_KEY_FILE"
  chmod 750 -- "$parent"
  set +e; open_installed_api_key key_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-0700 credential parent must fail" || return 1
  chmod 700 -- "$parent"
  chown 1 -- "$AIRVPN_API_KEY_FILE"
  set +e; open_installed_api_key key_fd >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "real non-root key must fail"
}

tests=(
  test_managed_module_exports_minimal_task4_contract
  test_managed_module_validation_requires_root_owned_0644_trusted_source
  test_installed_key_rejects_every_unsafe_shape_before_downstream_events
  test_installed_key_opens_one_valid_record_on_a_private_descriptor
  test_fail_closed_dispatch_closes_credential_before_logging
  test_linux_supplied_credential_fd_is_private_until_managed_owner
  test_linux_module_owner_and_mode_semantics
  test_linux_installed_key_owner_and_mode_semantics
)

if [[ -n "${WG_MANAGED_TEST_ONLY:-}" ]]; then
  read -r -a tests <<< "$WG_MANAGED_TEST_ONLY"
fi

failures=0
passes=0
skips=0
for test_name in "${tests[@]}"; do
  ("$test_name")
  rc=$?
  case "$rc" in
    0)
      printf 'ok - %s\n' "$test_name"
      passes=$((passes + 1))
      ;;
    77)
      printf 'ok - %s # SKIP requires Linux root ownership semantics\n' "$test_name"
      skips=$((skips + 1))
      ;;
    *)
      printf 'not ok - %s\n' "$test_name"
      failures=$((failures + 1))
      ;;
  esac
done

if (( failures > 0 )); then
  printf '%d test(s) failed; %d passed; %d skipped\n' "$failures" "$passes" "$skips" >&2
  exit 1
fi

printf '%d test(s) passed; %d skipped\n' "$passes" "$skips"
