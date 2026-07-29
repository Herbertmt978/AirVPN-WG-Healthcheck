test_readme_documents_dual_mode_quick_paths_and_manual_timer_decision() {
  local expected
  # These are literal Markdown excerpts, not expandable shell expressions.
  # shellcheck disable=SC2016
  local -a required=(
    'MIT License'
    '## Choose a mode'
    'Static profile mode'
    'API-managed profile mode'
    'Default; credential-free.'
    'Explicit opt-in; API key required.'
    '### Static quick start'
    'sudo ./install.sh wg0'
    'sudo wg-healthcheck-setup --mode static wg0'
    '### API-managed quick start'
    'sudo wg-healthcheck-setup --mode api wg0'
    'hidden terminal prompt'
    'After either path'
    'explicitly decide whether to enable the timer'
    'sudo wg-healthcheck status wg0'
    'sudo systemctl start wg-healthcheck@wg0.service'
    'sudo systemctl enable --now wg-healthcheck@wg0.timer'
    'Leave the timer disabled if the manual result is not healthy or recovered.'
    '[operator guide](docs/operations.md)'
    'independent firewall kill switch'
  )

  assert_file "$README_FILE" || return 1
  for expected in "${required[@]}"; do
    assert_contains "$expected" "$README_FILE" || return 1
  done
}

test_operations_upgrade_quiesces_before_install_and_preserves_recovery_state() {
  local section
  section="$(read_markdown_section "$OPERATIONS_FILE" '## Upgrade and rollback' '## State repair and return to static mode')"
  [[ -n "$section" ]] || { fail 'operations upgrade section is missing'; return 1; }

  # Literal operator-guide shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    'sudo ./install.sh --quiesce wg0' \
    'Then rerun the quiesced installer' \
    'check `wg-healthcheck status wg0`' \
    'run the manual service check' \
    'make a fresh timer decision' || return 1

  [[ "$section" == *'stops the selected timer and worker'* ]] ||
    { fail 'upgrade instructions do not quiesce the selected timer and worker'; return 1; }
  [[ "$section" == *'active shared instances, locks, pending transactions, and safety records'* ]] ||
    { fail 'upgrade instructions do not check shared activity, locks, and recovery state'; return 1; }
  [[ "$section" == *'leaves the timer disabled'* ]] ||
    { fail 'upgrade instructions do not require a disabled timer after quiesce'; return 1; }
  # Literal Markdown contains backticks and is intentionally not expanded.
  # shellcheck disable=SC2016
  [[ "$section" == *'Do not combine `--quiesce` with `--enable`'* && "$section" == *'`DESTDIR` staging'* ]] ||
    fail 'upgrade instructions do not state the quiesce mode exclusions'
  [[ "$section" == *'do not delete a pending or safety marker to force an upgrade'* ]] ||
    fail 'upgrade instructions permit forcing past recovery state'
}

test_operations_package_uninstall_quiesces_every_instance_and_preserves_pending_state() {
  local section
  section="$(read_markdown_section "$OPERATIONS_FILE" '## Disable and uninstall' '## Useful status commands')"
  [[ -n "$section" ]] || { fail 'operations uninstall section is missing'; return 1; }

  # Literal operator-guide shell snippets; expansion would invalidate the assertions.
  # shellcheck disable=SC2016
  assert_ordered_text "$section" \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'mapfile -t timers' \
    "systemctl list-unit-files --type=timer --no-legend --plain 'wg-healthcheck@*.timer'" \
    'mapfile -t services' \
    'sudo systemctl disable --now "${timers[@]}"' \
    'sudo systemctl stop "${services[@]}"' \
    'active="$(systemctl list-units' \
    'Active health-check instances remain; package removal stopped.' \
    'pending="$(sudo find /etc/wireguard' \
    'A pending recovery transaction exists; package removal stopped.' \
    '/etc/systemd/system/wg-healthcheck@.service' \
    '/usr/local/sbin/wg-healthcheck' \
    'sudo systemctl daemon-reload' || return 1

  [[ "$section" == *'never delete a pending marker to force uninstall'* ]] ||
    fail 'uninstall does not preserve pending recovery state'
}

test_operations_rollback_masks_legacy_auto_enable_until_validation() {
  local section
  section="$(read_markdown_section "$OPERATIONS_FILE" '## Upgrade and rollback' '## State repair and return to static mode')"
  [[ -n "$section" ]] || { fail 'operations rollback section is missing'; return 1; }

  assert_ordered_text "$section" \
    'sudo systemctl disable --now wg-healthcheck@wg0.timer' \
    'sudo systemctl stop wg-healthcheck@wg0.service' \
    'sudo systemctl mask --runtime wg-healthcheck@wg0.timer' \
    'if ! sudo ./install.sh wg0; then' \
    'Rollback installer failed; timer remains runtime-masked.' \
    'exit 1' \
    'sudo systemctl start wg-healthcheck@wg0.service' \
    'sudo cat /run/wg-healthcheck/wg0.status' \
    'sudo systemctl unmask --runtime wg-healthcheck@wg0.timer' \
    'sudo systemctl enable --now wg-healthcheck@wg0.timer' || return 1

  [[ "$section" == *'Older installers can enable a timer automatically'* ]] ||
    { fail 'rollback does not identify the legacy auto-enable hazard'; return 1; }
  [[ "$section" == *'reviewed compatible revision'* ]] ||
    { fail 'rollback omits target-revision configuration compatibility'; return 1; }
  [[ "$section" == *'Never continue past a nonzero installer result.'* ]] ||
    { fail 'rollback permits execution after installer failure'; return 1; }
  [[ "$section" == *'keep the timer runtime-masked until the manual health check succeeds'* ]] ||
    fail 'rollback unmasks the timer before validation is complete'
}

test_operations_credential_removal_is_explicit_and_uninstall_preserves_recovery_data() {
  local credential_section uninstall_section
  credential_section="$(read_markdown_section "$OPERATIONS_FILE" '## Credential lifecycle' '## Upgrade and rollback')"
  uninstall_section="$(read_markdown_section "$OPERATIONS_FILE" '## Disable and uninstall' '## Useful status commands')"
  [[ -n "$credential_section" ]] || { fail 'operations credential lifecycle section is missing'; return 1; }
  [[ -n "$uninstall_section" ]] || { fail 'operations uninstall section is missing'; return 1; }

  [[ "$credential_section" == *'--remove-credential --apply'* ]] ||
    fail 'credential removal is not an explicit applied static-mode operation'
  [[ "$credential_section" == *'Normal package removal intentionally preserves the credential and persistent API state'* ]] ||
    fail 'credential lifecycle does not preserve data during ordinary removal'
  [[ "$uninstall_section" == *'Package removal does not remove the WireGuard profile, health-check configuration, credential, pre-managed snapshot, or persistent API state.'* ]] ||
    fail 'uninstall instructions do not preserve operator and API recovery data'
}

test_python_bytecode_is_ignored() {
  assert_file "$GITIGNORE_FILE" || return 1
  grep -Fx -- '__pycache__/' "$GITIGNORE_FILE" >/dev/null ||
    { fail 'Python __pycache__ directories are not ignored'; return 1; }
  grep -Fx -- '*.py[cod]' "$GITIGNORE_FILE" >/dev/null ||
    fail 'Python bytecode files are not ignored'
}

test_repository_text_uses_lf_on_every_platform() {
  assert_file "$GITATTRIBUTES_FILE" || return 1
  grep -Fx -- '* text=auto eol=lf' "$GITATTRIBUTES_FILE" >/dev/null ||
    fail 'repository text does not have a platform-independent LF contract'
}

test_public_repository_docs_are_sanitized_and_complete() {
  local combined_file="$TEST_TMP/public-repository-docs" forbidden required

  assert_file "$README_FILE" || return 1
  assert_file "$OPERATIONS_FILE" || return 1
  assert_file "$LICENSE_FILE" || return 1
  assert_file "$SECURITY_FILE" || return 1
  assert_file "$CONTRIBUTING_FILE" || return 1
  assert_file "$CHANGELOG_FILE" || return 1
  assert_file "$VERSION_FILE" || return 1
  assert_file "$RELEASE_NOTES_FILE" || return 1
  command cat -- \
    "$README_FILE" \
    "$OPERATIONS_FILE" \
    "$LICENSE_FILE" \
    "$SOURCE_CONFIG" \
    "$SECURITY_FILE" \
    "$CONTRIBUTING_FILE" \
    "$CHANGELOG_FILE" \
    "$VERSION_FILE" \
    "$RELEASE_NOTES_FILE" > "$combined_file" || return 1

  # Literal public-documentation shell snippet; expansion would invalidate the assertion.
  # shellcheck disable=SC2016
  for required in \
    'not affiliated with or endorsed by AirVPN' \
    '## Choose a mode' \
    'Static profile mode' \
    'API-managed profile mode' \
    'sudo wg-healthcheck-setup --mode static wg0' \
    'sudo wg-healthcheck-setup --mode api wg0' \
    'Leave the timer disabled if the manual result is not healthy or recovered.' \
    '## Upgrade and rollback' \
    '## Disable and uninstall' \
    'MIT License' \
    '## Security' \
    '| `1.1.x` | Yes |' \
    'private vulnerability-reporting flow' \
    'Never submit WireGuard private keys'; do
    assert_contains "$required" "$combined_file" || return 1
  done

  for forbidden in \
    'Deployment status:' \
    'docs/aegis/'; do
    assert_not_contains "$forbidden" "$combined_file" || return 1
  done

  if grep -Eq '(^|[^0-9])(10\.[0-9]{1,3}(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})([^0-9]|$)' "$combined_file"; then
    fail 'public documentation contains an RFC1918 address'
    return 1
  fi
  if grep -Eq '([A-Za-z]:\\Users\\|/Users/[^/[:space:]]+|/home/[^/[:space:]]+)' "$combined_file"; then
    fail 'public documentation contains a user-home path'
    return 1
  fi
}

test_ci_workflow_is_deterministic_and_smoke_isolated() {
  local expected forbidden smoke
  # Literal workflow expressions and shell variables must not expand in this test.
  # shellcheck disable=SC2016
  local -a required=(
    'push:'
    'pull_request:'
    'workflow_dispatch:'
    'schedule:'
    'permissions:'
    'contents: read'
    'runs-on: ubuntu-${{ matrix.ubuntu }}'
    "ubuntu: ['22.04', '24.04']"
    'group: ci-${{ github.workflow }}-${{ github.ref }}'
    'cancel-in-progress: true'
    'timeout-minutes:'
    "if: github.event_name != 'schedule'"
    "if: github.event_name == 'schedule'"
    'continue-on-error: true'
    'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
    'persist-credentials: false'
    'uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0'
    'PYTHON_BIN="${pythonLocation:?}/bin/python"'
    '"$PYTHON_BIN" -m unittest discover -s tests -p '\''test_*.py'\'' -v'
    '/bin/bash tests/test_wg_healthcheck.sh'
    '/bin/bash tests/test_wg_managed_profiles.sh'
    '/bin/bash tests/test_install.sh'
    '/bin/bash tests/test_release.sh'
    'bash scripts/build-managed-module.sh --check'
    'bash -n bin/wg-healthcheck libexec/wg-healthcheck-managed libexec/wg-healthcheck-managed.d/*.bash install.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/install/*.sh tests/wg_healthcheck/*.sh tests/wg_managed/*.sh'
    'shellcheck -s bash -x -S style bin/wg-healthcheck libexec/wg-healthcheck-managed install.sh scripts/*.sh tests/*.sh tests/lib/wg_healthcheck_test_support.sh tests/lib/wg_managed_test_support.sh tests/wg_healthcheck/*.sh tests/wg_managed/*.sh'
    'shellcheck -s bash -x -S style -e SC2034 libexec/wg-healthcheck-managed.d/*.bash'
    'sudo install -D -m 0755 bin/wg-healthcheck /usr/local/sbin/wg-healthcheck'
    'sudo install -D -m 0755 bin/wg-healthcheck-setup /usr/local/sbin/wg-healthcheck-setup'
    'sudo install -D -m 0755 libexec/airvpn-api /usr/local/libexec/wg-healthcheck/airvpn-api'
    'sudo install -D -m 0644 libexec/wg-healthcheck-managed /usr/local/libexec/wg-healthcheck/wg-healthcheck-managed'
    'sudo install -D -m 0644 libexec/wg_healthcheck_setup/*.py /usr/local/libexec/wg-healthcheck/wg_healthcheck_setup/'
    'systemd-analyze verify systemd/wg-healthcheck@.service systemd/wg-healthcheck@.timer'
    'timeout --signal=TERM 45s python3 libexec/airvpn-api select'
    "--url 'https://airvpn.org/api/status/?format=json'"
    '--port 1637'
    '--timeout 20'
  )

  assert_file "$CI_WORKFLOW" || return 1
  for expected in "${required[@]}"; do
    assert_contains "$expected" "$CI_WORKFLOW" || return 1
  done

  for forbidden in pull_request_target 'secrets.' 'sudo -E' 'sudo --preserve-env' AIRVPN_API_KEY AIRVPN_USERINFO_URL AIRVPN_API_ENV; do
    assert_not_contains "$forbidden" "$CI_WORKFLOW" || return 1
  done

  smoke="$(sed -n '/^  airvpn-api-smoke:/,$p' "$CI_WORKFLOW")"
  [[ -n "$smoke" ]] || { fail 'scheduled smoke job block is missing'; return 1; }
  for forbidden in sudo docker wg-quick --interface; do
    if grep -F -- "$forbidden" <<<"$smoke" >/dev/null; then
      fail "scheduled smoke job contains privileged/runtime dependency: $forbidden"
      return 1
    fi
  done
}
