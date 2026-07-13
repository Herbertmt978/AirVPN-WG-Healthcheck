#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

test_proposed_settings_replace_only_country_presence_and_validate_api_cross_fields() {
  local rc before
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  CFG="$TEST_TMP/healthcheck.d/wg0.conf"
  mkdir -p -- "${CFG%/*}"
  chmod 700 -- "${CFG%/*}"
  printf '%s\n' \
    'AIRVPN_PROFILE_SOURCE=static' \
    'AIRVPN_DEVICE=Installed-Device' > "$CFG"
  chmod 600 -- "$CFG"
  before="$(<"$CFG")"
  AIRVPN_DEVICE='Proposed Device'
  AIRVPN_COUNTRIES='NZ AU'
  AIRVPN_WG_PORT=1637
  QBITTORRENT_CONTAINER=qbittorrent
  owner_mode() { printf '0:%s\n' "$(stat -c '%a' -- "$1")"; }
  log() { :; }

  PROPOSED_SETTINGS_READY=0
  set +e; managed_profile_admin_config_is_valid >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "without an override the installed config must contain exactly one country key" || return 1
  PROPOSED_SETTINGS_READY=1
  managed_profile_admin_config_is_valid || return 1
  assert_eq "$before" "$(<"$CFG")" "prospective validation must not rewrite installed settings" || return 1

  AIRVPN_WG_PORT=443
  set +e; managed_profile_admin_config_is_valid >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "prospective validation must enforce the managed port set" || return 1
  AIRVPN_WG_PORT=1637
  QBITTORRENT_CONTAINER="$(printf '%064d' 0)"
  set +e; managed_profile_admin_config_is_valid >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "prospective validation must reject an ambiguous immutable container ID" || return 1
  QBITTORRENT_CONTAINER=qbittorrent
  AIRVPN_DEVICE='-invalid'
  set +e; managed_profile_admin_config_is_valid >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "prospective validation must enforce device grammar" || return 1
  assert_eq "$before" "$(<"$CFG")" "every prospective refusal must remain side-effect free"
}

test_managed_profile_requires_a_private_root_owned_parent() {
  local rc
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then return 77; fi
  source_managed_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  WG_CONF="$TEST_TMP/etc/wireguard/wg0.conf"
  mkdir -p -- "${WG_CONF%/*}"
  chmod 700 -- "${WG_CONF%/*}"
  printf 'bounded profile\n' > "$WG_CONF"
  chmod 600 -- "$WG_CONF"

  managed_profile_file_is_secure "$WG_CONF" || return 1
  chmod 750 -- "${WG_CONF%/*}"
  set +e; managed_profile_file_is_secure "$WG_CONF" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "a non-private WireGuard parent must fail before fd5 admission"
}
