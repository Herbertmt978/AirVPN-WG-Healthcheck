#!/usr/bin/env bash

# Intentional test patterns: dynamic sourcing, immediate trap capture, literal
# generated-helper source, subshell-isolated fixtures, and security-boundary
# function doubles.
# shellcheck disable=SC1090,SC2016,SC2031,SC2034,SC2064,SC2317,SC2329

setup_immutable_docker_fake() {
  DOCKER_FAKE_DIR="$TEST_TMP/docker-fake"
  DOCKER_FAKE_EVENTS="$TEST_TMP/docker-fake-events"
  mkdir -p -- "$DOCKER_FAKE_DIR/names" "$DOCKER_FAKE_DIR/states"
  : > "$DOCKER_FAKE_EVENTS"
  DOCKER_ID_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  DOCKER_ID_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  printf '%s\n' "$DOCKER_ID_A" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/other-client"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  DOCKER_FAKE_INSPECT_MODE=normal

  docker_fake_resolve() {
    local target="${1:?}"
    if [[ "$target" =~ ^[0-9a-f]{64}$ ]]; then
      [[ -f "$DOCKER_FAKE_DIR/states/$target" ]] || return 1
      printf '%s\n' "$target"
    else
      [[ -f "$DOCKER_FAKE_DIR/names/$target" ]] || return 1
      command sed -n '1p' "$DOCKER_FAKE_DIR/names/$target"
    fi
  }
  managed_docker_inspect_identity() {
    local output_variable="${1:?}" target="${2:?}" id state docker_state
    printf 'inspect:%s:%s\n' "${MANAGED_QB_CHECKPOINT:-none}" "$target" >> "$DOCKER_FAKE_EVENTS"
    case "$DOCKER_FAKE_INSPECT_MODE" in
      failure) return 1 ;;
      malformed)
        printf -v "$output_variable" '%s' 'malformed'
        return 0
        ;;
    esac
    id="$(docker_fake_resolve "$target")" || return 1
    state="$(<"$DOCKER_FAKE_DIR/states/$id")" || return 1
    case "$state" in
      running) docker_state=true ;;
      stopped) docker_state=false ;;
      *) return 1 ;;
    esac
    printf -v "$output_variable" '%s|%s' "$id" "$docker_state"
  }
  managed_docker_stop_target() {
    local target="${1:?}" id
    printf 'stop:%s:%s\n' "${MANAGED_QB_CHECKPOINT:-none}" "$target" >> "$DOCKER_FAKE_EVENTS"
    id="$(docker_fake_resolve "$target")" || return 1
    printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$id"
  }
  managed_docker_start_target() {
    local target="${1:?}" id
    printf 'start:%s:%s\n' "${MANAGED_QB_CHECKPOINT:-none}" "$target" >> "$DOCKER_FAKE_EVENTS"
    id="$(docker_fake_resolve "$target")" || return 1
    printf 'running\n' > "$DOCKER_FAKE_DIR/states/$id"
  }
  managed_wait_for_qbittorrent() { return 0; }
  qbittorrent_binding_present() {
    local current_id expected_id
    printf 'binding:%s:%s:%s:%s\n' "$QBITTORRENT_CONTAINER" \
      "$QBITTORRENT_PROCESS_NAME" "$QBITTORRENT_LISTEN_IP" "$QBITTORRENT_LISTEN_PORT" \
      >> "$DOCKER_FAKE_EVENTS"
    current_id="$(docker_fake_resolve "$QBITTORRENT_CONTAINER")" || return 1
    expected_id="${MANAGED_SAFETY_QB_CONTAINER_ID:-${MANAGED_QB_CONTAINER_ID:-$current_id}}"
    [[ "$current_id" == "$expected_id" &&
       "$(<"$DOCKER_FAKE_DIR/states/$current_id")" == running ]]
  }
}

test_managed_docker_identity_inspect_uses_an_unambiguous_template() {
  local inspection expected_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  setup_managed_journal_fixture || return 1
  QBITTORRENT_RESTART_TIMEOUT=10
  managed_docker_available() { return 0; }
  timeout() {
    [[ "$1" == 10 && "$2" == docker && "$3" == container && "$4" == inspect &&
       "$5" == --format && "$7" == qbittorrent ]] || return 1
    printf '%s\n' "$6" > "$TEST_TMP/docker-format"
    printf '%s|true\n' "$expected_id"
  }

  managed_docker_inspect_identity inspection qbittorrent || return 1
  assert_eq "$expected_id|true" "$inspection" \
    "Docker identity inspection must return one strict delimited tuple" || return 1
  assert_eq '{{.Id}}|{{.State.Running}}' "$(<"$TEST_TMP/docker-format")" \
    "Docker template must use an unambiguous literal delimiter"
}

test_managed_qb_inspection_parser_requires_exact_docker_boolean_tuple() {
  local bad rc parsed_id parsed_state
  local id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  source_managed_contract || return 1

  for bad in "$id|true|" "$id|true||" '|running|stopped' \
      "$id|running" "$id|stopped"; do
    parsed_id='sentinel-id'
    parsed_state='sentinel-state'
    set +e
    managed_qb_parse_inspection parsed_id parsed_state "$bad" >/dev/null 2>&1
    rc=$?
    set +e
    assert_eq 1 "$rc" "Docker inspection tuple '$bad' must be rejected exactly" || return 1
    assert_eq sentinel-id "$parsed_id" "rejected inspection must not overwrite the ID" || return 1
    assert_eq sentinel-state "$parsed_state" \
      "rejected inspection must not overwrite the state" || return 1
  done
}

test_managed_qb_rejects_ambiguous_configured_name_before_every_effect() {
  local active_before backup_before rc
  setup_managed_transaction_fixture || return 1
  QBITTORRENT_CONTAINER="$TRANSACTION_QB_ID"
  active_before="$(sha256sum "$WG_CONF")" || return 1
  backup_before="$(sha256sum "${WG_CONF}.bak-healthcheck")" || return 1
  : > "$TRANSACTION_EVENTS"

  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an ID-shaped managed Docker name must fail closed" || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" \
    "ambiguous managed Docker configuration must fail before qB, backup, exclusion, journal, or network effects" ||
    return 1
  assert_eq "$active_before" "$(sha256sum "$WG_CONF")" \
    "ambiguous managed Docker configuration must preserve active bytes" || return 1
  assert_eq "$backup_before" "$(sha256sum "${WG_CONF}.bak-healthcheck")" \
    "ambiguous managed Docker configuration must preserve backup bytes" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "ambiguous managed Docker configuration must not create recovery state"
}

test_managed_safety_rejects_ambiguous_recorded_name_without_network_guess() {
  local load_rc rc events
  setup_managed_transaction_fixture || return 1
  setup_managed_crash_shape candidate-up candidate present candidate 1 || return 1
  sed -i "s/^qb_container=.*/qb_container=$TRANSACTION_QB_ID/" "$MANAGED_SAFETY"
  : > "$TRANSACTION_EVENTS"

  set +e; managed_safety_load_record >/dev/null 2>&1; load_rc=$?; set +e
  assert_eq 1 "$load_rc" "an ID-shaped recorded Docker name must fail strict parsing" || return 1
  assert_eq '' "${MANAGED_SAFETY_STATE-}" \
    "ambiguous recorded Docker parsing must clear every in-memory safety field" || return 1

  set +e; managed_reconcile_pending >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "an ID-shaped recorded Docker name must invalidate pending safety" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'wg-down:' "$events" \
    "ambiguous recorded Docker identity must fail before network recovery" || return 1
  assert_not_contains 'profile-move:' "$events" \
    "ambiguous recorded Docker identity must not guess at profile restoration" || return 1
  [[ -f "$MANAGED_SAFETY" && -f "$ROTATION_PENDING" ]] ||
    fail "ambiguous recorded evidence must remain available for operator repair"
}

test_managed_containment_never_treats_ambiguous_current_name_as_an_id() {
  local events rc
  setup_managed_journal_fixture || return 1
  setup_immutable_docker_fake
  QBITTORRENT_RESTART_TIMEOUT=10
  QBITTORRENT_CONTAINER="$DOCKER_ID_B"
  MANAGED_SAFETY_QB_INTENT=running
  MANAGED_SAFETY_QB_CONTAINER=qbittorrent
  MANAGED_SAFETY_QB_CONTAINER_ID="$DOCKER_ID_A"
  MANAGED_SAFETY_QB_PROCESS=qbittorrent-nox
  MANAGED_SAFETY_QB_LISTEN_IPV4=192.0.2.2
  MANAGED_SAFETY_QB_LISTEN_PORT=6881
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  : > "$DOCKER_FAKE_EVENTS"

  set +e; managed_qb_contain_recorded_and_current >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "ambiguous current name must make containment incomplete" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "the recorded immutable ID must still be contained" || return 1
  assert_eq running "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "an ID-shaped current name must never be interpreted as an immutable-ID target" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_not_contains "stop:none:$DOCKER_ID_B" "$events" \
    "containment must not issue a Docker mutation for an ambiguous current name"
}

test_managed_qb_immutable_identity_checkpoints_and_exact_restore() {
  local rc events start_count checkpoint parsed_id=sentinel parsed_state=sentinel inspection
  setup_managed_journal_fixture || return 1
  declare -F managed_qb_snapshot >/dev/null ||
    fail "amended Task 7 immutable qB snapshot owner is missing" || return 1
  declare -F managed_qb_containment_checkpoint >/dev/null ||
    fail "amended Task 7 qB containment checkpoint owner is missing" || return 1
  declare -F managed_qb_restore_recorded_intent >/dev/null ||
    fail "amended Task 7 exact qB restore owner is missing" || return 1
  setup_immutable_docker_fake
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10

  inspection="$DOCKER_ID_A|false"
  managed_qb_parse_inspection parsed_id parsed_state "$inspection" || return 1
  assert_eq "$DOCKER_ID_A" "$parsed_id" "inspection parser must replace caller ID output" || return 1
  assert_eq stopped "$parsed_state" "inspection parser must replace caller state output" || return 1
  set +e; managed_qb_parse_inspection parsed_id parsed_id "$inspection" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "inspection parser must reject aliased output variables" || return 1
  set +e; managed_qb_parse_inspection wgmanaged_id parsed_state "$inspection" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "inspection parser must reject internal-name collisions" || return 1

  managed_qb_snapshot || return 1
  assert_eq running "$MANAGED_QB_INTENT" "running intent must be snapshotted" || return 1
  assert_eq "$DOCKER_ID_A" "$MANAGED_QB_CONTAINER_ID" \
    "snapshot must capture the immutable container ID" || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  managed_qb_containment_checkpoint after-stop || return 1

  for checkpoint in after-stop before-down after-down before-install after-install \
      before-up after-up before-network after-network rollback-before-down \
      rollback-after-down rollback-before-install rollback-after-install rollback-before-up \
      rollback-after-up rollback-before-network rollback-after-network rollback-pre-cleanup \
      rollback-post-cleanup; do
    printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
    set +e; managed_qb_containment_checkpoint "$checkpoint" >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "external restart at $checkpoint must fail" || return 1
    assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
      "external restart at $checkpoint must be contained" || return 1
  done

  printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  set +e; managed_qb_containment_checkpoint after-install >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "same-name container recreation must fail" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "recorded immutable target must remain stopped" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "replacement target must be stopped" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_contains "stop:after-install:$DOCKER_ID_A" "$events" \
    "recreation containment must target the recorded immutable ID" || return 1
  assert_contains 'stop:after-install:qbittorrent' "$events" \
    "recreation containment must also target the current configured name" || return 1

  printf '%s\n' "$DOCKER_ID_A" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  QBITTORRENT_LISTEN_PORT=6999
  set +e; managed_qb_containment_checkpoint config-drift >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "configured tuple drift must fail closed" || return 1
  QBITTORRENT_LISTEN_PORT=6881

  DOCKER_FAKE_INSPECT_MODE=malformed
  set +e; managed_qb_containment_checkpoint malformed-inspect >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "malformed inspect must contain and fail" || return 1
  DOCKER_FAKE_INSPECT_MODE=failure
  set +e; managed_qb_containment_checkpoint failed-inspect >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "inspect hard failure must contain and fail" || return 1
  DOCKER_FAKE_INSPECT_MODE=normal
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  : > "$DOCKER_FAKE_EVENTS"
  managed_qb_restore_recorded_intent || return 1
  start_count="$(grep -cFx "start:restore:$DOCKER_ID_A" "$DOCKER_FAKE_EVENTS" || true)"
  assert_eq 1 "$start_count" "running intent restore must own exactly one immutable-ID start" || return 1
  assert_eq running "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "running intent must finish running" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_contains 'binding:qbittorrent:qbittorrent-nox:192.0.2.2:6881' "$events" \
    "restore must prove the recorded TCP/UDP tuple" || return 1

  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  : > "$DOCKER_FAKE_EVENTS"
  set +e; managed_qb_restore_recorded_intent >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "already-running restore target must not be accepted" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "already-running restore target must be contained" || return 1
  assert_not_contains 'start:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "already-running target must never receive a transaction start" || return 1

  rm -f -- "$MANAGED_SAFETY"
  printf 'stopped\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  managed_qb_snapshot || return 1
  assert_eq stopped "$MANAGED_QB_INTENT" "stopped intent must be snapshotted" || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  : > "$DOCKER_FAKE_EVENTS"
  set +e; managed_qb_restore_recorded_intent >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "recorded-stopped client must not become running" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "recorded-stopped external restart must be contained" || return 1
  assert_not_contains 'start:' "$(<"$DOCKER_FAKE_EVENTS")" \
    "stopped intent must never receive a transaction start" || return 1

  rm -f -- "$MANAGED_SAFETY"
  QBITTORRENT_CONTAINER=''
  managed_qb_snapshot || return 1
  assert_eq unmanaged "$MANAGED_QB_INTENT" "empty container config must snapshot unmanaged" || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  managed_qb_restore_recorded_intent || return 1
  QBITTORRENT_CONTAINER=other-client
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
  set +e; managed_qb_restore_recorded_intent >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "unmanaged intent must reject a newly configured target" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "new target under unmanaged intent must be contained" || return 1

  rm -f -- "$MANAGED_SAFETY"
  QBITTORRENT_CONTAINER=qbittorrent
  printf '%s\n' "$DOCKER_ID_A" > "$DOCKER_FAKE_DIR/names/qbittorrent"
  printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_A"
  managed_qb_snapshot || return 1
  managed_safety_prepare || return 1
  managed_safety_clear
  managed_safety_load || return 1
  qbittorrent_binding_present() {
    printf '%s\n' "$DOCKER_ID_B" > "$DOCKER_FAKE_DIR/names/qbittorrent"
    printf 'running\n' > "$DOCKER_FAKE_DIR/states/$DOCKER_ID_B"
    return 0
  }
  : > "$DOCKER_FAKE_EVENTS"
  set +e; managed_qb_verify_recorded_intent final-check >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "ID replacement during binding proof must fail final proof" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_A")" \
    "ID replacement must stop the recorded target" || return 1
  assert_eq stopped "$(<"$DOCKER_FAKE_DIR/states/$DOCKER_ID_B")" \
    "ID replacement must stop the current target" || return 1
  events="$(<"$DOCKER_FAKE_EVENTS")"
  assert_contains "stop:final-check:$DOCKER_ID_A" "$events" \
    "final containment must address the immutable ID" || return 1
  assert_contains 'stop:final-check:qbittorrent' "$events" \
    "final containment must address the configured name"
}

test_managed_qbittorrent_state_is_exact_and_fail_closed() {
  local state rc
  source_managed_contract || return 1
  require_task7_contract || return 1
  TEST_TMP="$(mktemp -d)"
  trap "rm -rf -- '$TEST_TMP'" EXIT
  QBITTORRENT_RESTART_TIMEOUT=10
  QBITTORRENT_CONTAINER=''
  managed_docker_available() { printf 'unexpected\n' >> "$TEST_TMP/docker-events"; return 0; }
  managed_docker_command() { printf 'unexpected\n' >> "$TEST_TMP/docker-events"; return 1; }
  : > "$TEST_TMP/docker-events"
  managed_qbittorrent_state state || return 1
  assert_eq unconfigured "$state" "empty qB configuration must be explicit" || return 1
  assert_eq '' "$(<"$TEST_TMP/docker-events")" "unconfigured qB must not invoke Docker" || return 1

  QBITTORRENT_CONTAINER=qbittorrent
  validate_container_name "$QBITTORRENT_CONTAINER" || return 1
  managed_docker_available() { return 0; }
  managed_docker_command() {
    case "${QB_INSPECT_RESULT:?}" in
      true|false) printf '%s\n' "$QB_INSPECT_RESULT" ;;
      multiline) printf 'true\nfalse\n' ;;
      whitespace) printf ' true\n' ;;
      missing) return 1 ;;
    esac
  }
  QB_INSPECT_RESULT=true
  managed_qbittorrent_state state || return 1
  assert_eq running "$state" "Docker true must map to running" || return 1
  QB_INSPECT_RESULT=false
  managed_qbittorrent_state state || return 1
  assert_eq stopped "$state" "Docker false must map to stopped" || return 1
  for QB_INSPECT_RESULT in multiline whitespace missing; do
    state=sentinel
    set +e; managed_qbittorrent_state state >/dev/null 2>&1; rc=$?; set +e
    assert_eq 1 "$rc" "$QB_INSPECT_RESULT inspect shape must fail closed" || return 1
    assert_eq sentinel "$state" "failed inspect must not overwrite the caller output" || return 1
  done
}

test_managed_live_identity_requires_exact_address_and_peer_key() {
  local rc
  setup_managed_journal_fixture || return 1
  require_task7_contract || return 1
  LIVE_ADDRESS=192.0.2.2/32
  LIVE_PEER=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
  managed_live_interface_address() { printf '%s\n' "$LIVE_ADDRESS"; }
  managed_live_peer_public_key() { printf '%s\n' "$LIVE_PEER"; }
  managed_verify_live_profile_identity "$MANAGED_CANDIDATE" ||
    fail "matching live identity must pass" || return 1

  LIVE_ADDRESS=192.0.2.3/32
  set +e; managed_verify_live_profile_identity "$MANAGED_CANDIDATE" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "changed live interface address must fail" || return 1
  LIVE_ADDRESS=192.0.2.2/32
  LIVE_PEER=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
  set +e; managed_verify_live_profile_identity "$MANAGED_CANDIDATE" >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "changed live peer key must fail"
}

test_managed_atomic_profile_install_is_digest_bound_and_durable() {
  local digest endpoint rc actual_mode actual_owner
  local -a events=()
  setup_managed_journal_fixture || return 1
  require_task7_contract || return 1
  managed_sha256_file digest "$MANAGED_CANDIDATE" || return 1
  endpoint="$(configured_endpoint "$MANAGED_CANDIDATE")" || return 1
  : > "$TEST_TMP/install-events"
  managed_copy_profile_bytes() {
    printf 'copy:%s:%s\n' "$1" "$2" >> "$TEST_TMP/install-events"
    command cp -- "$1" "$2"
  }
  managed_sync_file() { printf 'sync:%s:%s\n' "$1" "$(stat -c '%a' "$1")" >> "$TEST_TMP/install-events"; }
  managed_profile_move() { printf 'move:%s:%s\n' "$1" "$2" >> "$TEST_TMP/install-events"; command mv -fT -- "$1" "$2"; }
  managed_sync_artifact_parent() { printf 'directory:%s\n' "$1" >> "$TEST_TMP/install-events"; }

  managed_install_profile_atomically "$MANAGED_CANDIDATE" "$WG_CONF" "$digest" "$endpoint" || return 1
  mapfile -t events < "$TEST_TMP/install-events"
  assert_eq 5 "${#events[@]}" "install must expose five ordered copy/durability effects" || return 1
  assert_contains 'copy:' "${events[0]}" "install must copy into a private temporary first" || return 1
  assert_contains 'sync:' "${events[1]}" "temporary must be synced before rename" || return 1
  assert_contains ':600' "${events[1]}" "temporary must be mode 0600 before sync" || return 1
  assert_contains 'move:' "${events[2]}" "atomic rename must follow temporary verification" || return 1
  assert_eq "sync:$WG_CONF:600" "${events[3]}" "installed active profile must be synced" || return 1
  assert_eq "directory:${WG_CONF%/*}" "${events[4]}" "profile parent must be synced last" || return 1
  managed_verify_profile_binding "$WG_CONF" "$digest" "$endpoint" || return 1
  cmp -s -- "$MANAGED_CANDIDATE" "$WG_CONF" || fail "candidate install must preserve exact bytes" || return 1
  actual_mode="$(stat -c '%a' "$WG_CONF")" || return 1
  assert_eq 600 "$actual_mode" "installed profile must be mode 0600" || return 1
  if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]]; then
    actual_owner="$(stat -c '%u' "$WG_CONF")" || return 1
    assert_eq 0 "$actual_owner" "installed profile must be root-owned" || return 1
  fi

  write_managed_candidate_fixture 203.0.113.20:1637
  chmod 600 -- "$MANAGED_CANDIDATE"
  set +e
  managed_install_profile_atomically "$MANAGED_CANDIDATE" "$WG_CONF" "$digest" "$endpoint" >/dev/null 2>&1
  rc=$?
  set +e
  assert_eq 1 "$rc" "changed staged candidate must fail immediately before install" || return 1
  managed_verify_profile_binding "$WG_CONF" "$digest" "$endpoint"
}

test_managed_profile_transaction_orders_every_qb_and_tunnel_effect() {
  local candidate_digest events
  setup_managed_transaction_fixture || return 1
  managed_sha256_file candidate_digest "$MANAGED_CANDIDATE" || return 1
  managed_profile_transaction Alpha-1 1 || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_event_before 'exclude-write' 'journal:prepared' "candidate exclusion must be durable before prepared" || return 1
  assert_event_before 'journal:prepared' 'qb-stop:prepared' "prepared must precede qB stop" || return 1
  assert_event_before 'qb-stop:prepared' 'journal:client-stopped' "qB stop must precede client-stopped" || return 1
  assert_event_before 'journal:client-stopped' 'wg-down:client-stopped:192.0.2.10:1637' "old profile must remain installed for down" || return 1
  assert_event_before 'wg-down:client-stopped:192.0.2.10:1637' 'journal:tunnel-down' "down must precede tunnel-down" || return 1
  assert_event_before 'journal:tunnel-down' 'profile-move:tunnel-down:198.51.100.20:1637' "candidate install must follow tunnel-down" || return 1
  assert_event_before 'profile-move:tunnel-down:198.51.100.20:1637' 'journal:candidate-installed' "durable install must precede candidate-installed" || return 1
  assert_event_before 'journal:candidate-installed' 'wg-up:candidate-installed:198.51.100.20:1637' "candidate-installed must precede up" || return 1
  assert_event_before 'wg-up:candidate-installed:198.51.100.20:1637' 'journal:candidate-up' "up must precede candidate-up" || return 1
  assert_event_before 'journal:candidate-up' 'identity:candidate-up:198.51.100.20:1637' "live identity must follow candidate-up" || return 1
  assert_event_before 'identity:candidate-up:198.51.100.20:1637' 'network:candidate-up:198.51.100.20:1637' "identity must precede tunnel/egress verification" || return 1
  assert_event_before 'network:candidate-up:198.51.100.20:1637' 'speed:candidate-up' "network must precede optional speed" || return 1
  assert_event_before 'speed:candidate-up' 'qb-start:candidate-up' "qB must start only after all network checks" || return 1
  assert_event_before 'qb-start:candidate-up' 'binding:candidate-up:running:198.51.100.20:1637' "running state must precede TCP/UDP ownership proof" || return 1
  assert_event_before 'binding:candidate-up:running:198.51.100.20:1637' 'journal:verified' "binding proof must precede verified" || return 1
  assert_event_before 'journal:verified' 'candidate-delete:verified' "verified must precede candidate cleanup" || return 1
  assert_event_before 'candidate-delete:verified' 'marker-delete:verified' \
    "journal cleanup must follow candidate cleanup" || return 1
  assert_event_before 'marker-delete:verified' 'status:none:recovered:managed_profile_rotation_verified' \
    "success status must follow the safety commit point" || return 1
  assert_event_before 'status:none:recovered:managed_profile_rotation_verified' 'stamp:none' \
    "cooldown follows postcommit status" || return 1
  assert_event_before 'stamp:none' 'exclude-remove:Alpha-1:1000' \
    "pre-exclusion clears only after candidate commit" || return 1
  [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" && ! -e "$MANAGED_SAFETY" ]] ||
    fail "successful transaction must clean candidate, marker, and safety owner" || return 1
  managed_verify_profile_binding "$WG_CONF" "$candidate_digest" 198.51.100.20:1637 || return 1
  assert_eq running "$TRANSACTION_QB_STATE" "previously running qB must be restored" || return 1

  setup_managed_transaction_fixture || return 1
  TRANSACTION_QB_STATE=stopped
  managed_profile_transaction Alpha-1 0 || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'qb-stop:' "$events" "previously stopped qB must not be stopped redundantly" || return 1
  assert_not_contains 'qb-start:' "$events" "previously stopped qB must remain stopped" || return 1
  assert_not_contains 'binding:' "$events" "previously stopped qB needs no listener ownership proof" || return 1
  assert_eq stopped "$TRANSACTION_QB_STATE" "stopped intent must be preserved" || return 1

  setup_managed_transaction_fixture || return 1
  QBITTORRENT_CONTAINER=''
  TRANSACTION_QB_STATE=stopped
  managed_profile_transaction Alpha-1 0 || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_not_contains 'qb-' "$events" "unconfigured qB must have no Docker effects"
}

test_amended_transaction_keeps_a_durable_owner_through_commit_and_finalization() {
  local docker_events
  setup_managed_transaction_fixture || return 1
  setup_immutable_docker_fake
  QBITTORRENT_CONTAINER=qbittorrent
  QBITTORRENT_PROCESS_NAME=qbittorrent-nox
  QBITTORRENT_LISTEN_IP=192.0.2.2
  QBITTORRENT_LISTEN_PORT=6881
  QBITTORRENT_RESTART_DELAY=0
  QBITTORRENT_RESTART_TIMEOUT=10
  managed_safety_move() {
    local state
    state="$(sed -n 's/^state=//p' "${1:?}")" || return 1
    transaction_event "safety:$state"
    command mv -fT -- "$1" "${2:?}"
  }
  managed_unlink_path() {
    local path="${1:?}" safety_state=absent
    [[ ! -f "$MANAGED_SAFETY" ]] || safety_state="$(sed -n 's/^state=//p' "$MANAGED_SAFETY")"
    case "$path" in
      "$MANAGED_CANDIDATE") transaction_event "candidate-delete:safety-$safety_state" ;;
      "$ROTATION_PENDING") transaction_event "marker-delete:safety-$safety_state" ;;
      "$MANAGED_SAFETY") transaction_event "safety-delete:$safety_state" ;;
    esac
    command rm -f -- "$path"
  }

  managed_profile_transaction Alpha-1 0 || return 1
  assert_event_before 'safety:pending' 'journal:prepared' \
    "pending safety must own the transaction before the journal" || return 1
  assert_event_before 'journal:verified' 'candidate-delete:safety-pending' \
    "verified candidate cleanup must remain pending-owned" || return 1
  assert_event_before 'candidate-delete:safety-pending' 'marker-delete:safety-pending' \
    "candidate cleanup must precede journal cleanup" || return 1
  assert_event_before 'marker-delete:safety-pending' 'safety:committed' \
    "safety commit must follow journal cleanup and post-cleanup proof" || return 1
  assert_event_before 'safety:committed' 'status:none:recovered:managed_profile_rotation_verified' \
    "success status must be postcommit bookkeeping" || return 1
  assert_event_before 'safety:committed' 'stamp:none' \
    "rotation cooldown must be postcommit bookkeeping" || return 1
  assert_event_before 'safety:committed' 'safety:finalizing' \
    "committed safety must transition to finalizing" || return 1
  assert_event_before 'safety:finalizing' 'safety-delete:finalizing' \
    "final safety unlink must be the last commit-owner effect" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
    fail "successful finalization must clear every transaction artifact" || return 1
  docker_events="$(<"$DOCKER_FAKE_EVENTS")"
  for checkpoint in after-stop before-down after-down before-install after-install \
      before-up after-up before-network after-network pre-cleanup post-cleanup finalizing; do
    assert_contains "inspect:$checkpoint:qbittorrent" "$docker_events" \
      "checkpoint $checkpoint must inspect immutable qB state" || return 1
  done
}

test_managed_candidate_exclusion_removal_is_exact_and_durable() {
  local key_fd
  source_managed_contract || return 1
  require_task7_contract || return 1
  setup_api_state_fixture || return 1
  managed_api_state_defaults 1000 || return 1
  exec {key_fd}<"$AIRVPN_API_KEY_FILE" || return 1
  managed_api_state_refresh_identity 1000 "$key_fd" || { exec {key_fd}<&-; return 1; }
  exec {key_fd}<&-
  managed_api_state_add_exclusion Alpha-1 1000 || return 1
  managed_api_state_add_exclusion Beta-2 1000 || return 1
  managed_api_state_write || return 1
  managed_api_state_remove_exclusion Alpha-1 1001 || return 1
  managed_api_state_load 1001 || return 1
  assert_eq 1 "${#MANAGED_API_EXCLUDE_NAMES[@]}" "remove must retain unrelated exclusions" || return 1
  assert_eq Beta-2 "${MANAGED_API_EXCLUDE_NAMES[0]}" "remove must delete only the exact server" || return 1
  if grep -F 'Alpha-1' "$AIRVPN_API_STATE_FILE" >/dev/null; then
    fail "removed exclusion must not remain in durable state" || return 1
  fi
  grep -Fx 'exclude_01=Beta-2,22600' "$AIRVPN_API_STATE_FILE" >/dev/null ||
    fail "unrelated exclusion must remain durable"
}

test_managed_transaction_context_and_preexclusion_fail_before_mutation() {
  local rc events backup_before
  setup_managed_transaction_fixture || return 1
  backup_before="$(sha256sum "${WG_CONF}.bak-healthcheck")" || return 1
  CONTEXT_LOCKED=0
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "transaction must require the interface lock" || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" "missing interface lock must precede every effect" || return 1

  CONTEXT_LOCKED=1
  MANAGED_API_LOCK_FD=11
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "transaction must require the global API lock to be released" || return 1
  assert_eq '' "$(<"$TRANSACTION_EVENTS")" "held global API lock must precede every effect" || return 1

  MANAGED_API_LOCK_FD=''
  managed_api_state_write() {
    transaction_event 'exclude-write'
    return 1
  }
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "pre-exclusion persistence failure must abort" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_eq $'qb-inspect:none:running\nexclude-add:Alpha-1:1000\nexclude-write' "$events" \
    "pre-exclusion failure may follow only validation and the immutable read-only snapshot" || return 1
  [[ ! -e "$ROTATION_PENDING" ]] || fail "pre-exclusion failure must not create a journal" || return 1
  assert_eq "$backup_before" "$(sha256sum "${WG_CONF}.bak-healthcheck")" \
    "pre-exclusion failure must not rewrite the backup" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "pre-exclusion failure must not mutate the active profile"
}

test_managed_transaction_identity_ordering_precedes_every_effect() {
  local backup_before case_name events rc
  for case_name in private-key address table; do
    (
      setup_managed_transaction_fixture || exit 1
      case "$case_name" in
        private-key)
          sed -i 's/^PrivateKey = .*/PrivateKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=/' \
            "$MANAGED_CANDIDATE"
          ;;
        address) sed -i 's/^Address = .*/Address = 192.0.2.3\/32/' "$MANAGED_CANDIDATE" ;;
        table) sed -i '/^\[Peer\]/i Table = off' "$MANAGED_CANDIDATE" ;;
      esac
      backup_before="$(sha256sum "${WG_CONF}.bak-healthcheck")" || exit 1
      : > "$TRANSACTION_EVENTS"
      set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name identity mismatch must fail the transaction" || exit 1
      assert_eq '' "$(<"$TRANSACTION_EVENTS")" \
        "$case_name identity mismatch must precede snapshot, backup, exclusion, safety, journal, Docker, and network effects" ||
        exit 1
      assert_eq "$backup_before" "$(sha256sum "${WG_CONF}.bak-healthcheck")" \
        "$case_name identity mismatch must preserve backup bytes" || exit 1
      [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
        fail "$case_name identity mismatch must not create recovery state" || exit 1
    ) || return 1
  done
}

test_managed_transaction_rechecks_backup_identity_before_preexclusion() {
  local events rc
  setup_managed_transaction_fixture || return 1
  eval "$(declare -f managed_prepare_profile_backup | sed '1s/managed_prepare_profile_backup/transaction_original_prepare_profile_backup/')"
  managed_prepare_profile_backup() {
    transaction_original_prepare_profile_backup || return 1
    sed -i 's/^Address = .*/Address = 192.0.2.3\/32/' "${WG_CONF}.bak-healthcheck"
  }
  : > "$TRANSACTION_EVENTS"

  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "post-backup identity mutation must fail the transaction" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'qb-inspect:' "$events" \
    "the permitted read-only qB snapshot must occur before durable backup creation" || return 1
  assert_not_contains 'exclude-' "$events" \
    "backup identity recheck must precede candidate pre-exclusion" || return 1
  assert_not_contains 'journal:' "$events" \
    "backup identity recheck must precede the journal" || return 1
  assert_not_contains 'qb-stop:' "$events" \
    "backup identity recheck must precede qB mutation" || return 1
  assert_not_contains 'wg-down:' "$events" \
    "backup identity recheck must precede network mutation" || return 1
  [[ ! -e "$MANAGED_SAFETY" && ! -e "$ROTATION_PENDING" ]] ||
    fail "backup identity recheck failure must not create recovery state"
}

test_managed_stop_failure_aborts_before_tunnel_downtime() {
  local rc events
  setup_managed_transaction_fixture || return 1
  TRANSACTION_FAIL_ACTION=stop
  TRANSACTION_FAIL_REMAINING=-1
  set +e; managed_profile_transaction Alpha-1 0 >/dev/null 2>&1; rc=$?; set +e
  assert_eq 1 "$rc" "qB stop failure must fail the candidate transaction" || return 1
  events="$(<"$TRANSACTION_EVENTS")"
  assert_contains 'qb-stop:prepared' "$events" "running qB must be stopped after prepared" || return 1
  assert_not_contains 'wg-down:' "$events" "qB stop failure must precede all tunnel downtime" || return 1
  assert_not_contains 'profile-move:' "$events" "qB stop failure must precede candidate install" || return 1
  assert_eq 192.0.2.10:1637 "$(configured_endpoint "$WG_CONF")" \
    "qB stop failure must retain the old active profile"
}

test_managed_every_phase_failure_rolls_back_exact_old_profile() {
  local case_name rc events
  local -a cases=(
    journal-client-stopped down journal-tunnel-down install journal-candidate-installed
    up journal-candidate-up identity network speed start binding journal-verified
    candidate-delete marker-delete
  )
  for case_name in "${cases[@]}"; do
    (
      setup_managed_transaction_fixture || exit 1
      TRANSACTION_FAIL_ACTION="$case_name"
      TRANSACTION_FAIL_REMAINING=1
      set +e; managed_profile_transaction Alpha-1 1 >/dev/null 2>&1; rc=$?; set +e
      assert_eq 1 "$rc" "$case_name failure must fail the candidate transaction" || exit 1
      managed_verify_profile_binding "$WG_CONF" \
        "$(sha256sum "${WG_CONF}.bak-healthcheck" | awk '{print $1}')" \
        192.0.2.10:1637 || fail "$case_name must restore the exact old profile" || exit 1
      cmp -s -- "${WG_CONF}.bak-healthcheck" "$WG_CONF" ||
        fail "$case_name rollback must be byte-for-byte" || exit 1
      [[ ! -e "$ROTATION_PENDING" && ! -e "$MANAGED_CANDIDATE" ]] ||
        fail "$case_name successful rollback must clean its marker and candidate" || exit 1
      assert_eq running "$TRANSACTION_QB_STATE" \
        "$case_name successful rollback must restore prior qB running intent" || exit 1
      events="$(<"$TRANSACTION_EVENTS")"
      assert_not_contains 'exclude-remove:' "$events" \
        "$case_name rollback must retain the failed candidate exclusion" || exit 1
    ) || return 1
  done
}
