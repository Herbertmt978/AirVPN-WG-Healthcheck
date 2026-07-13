#!/bin/bash -p

case "${BASH_SOURCE[0]}" in
  */*) _installer_dir="${BASH_SOURCE[0]%/*}" ;;
  *) _installer_dir=. ;;
esac
SCRIPT_DIR="$(cd -- "$_installer_dir" && pwd -P)" || exit 1
unset _installer_dir

IFACE=wg0
ENABLE_TIMER=0
QUIESCE=0
TIMER_WAS_ENABLED=0
QUIESCE_DISABLE_ATTEMPTED=0
QUIESCE_TIMER_DISABLED=0
QUIESCE_FAILURE_REPORTED=0
LIVE_INSTALL=1
SYSTEMCTL_BIN=
INSTALL_OWNER_ARGS=()
SOURCE_SETUP_PACKAGE_FILES=()
TARGET_SETUP_PACKAGE_FILES=()
UPGRADE_LOCK_FDS=()
UPGRADE_LOCK_PATHS=()

usage() {
  printf 'usage: %s [--enable [iface] | --quiesce iface | iface]\n' "${0##*/}" >&2
}

error() {
  printf 'install.sh: %s\n' "$*" >&2
}

validate_interface_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_=+.-]{0,14}$ ]]
}

parse_arguments() {
  IFACE=wg0
  ENABLE_TIMER=0
  QUIESCE=0

  case $# in
    0)
      ;;
    1)
      if [[ "$1" == --enable ]]; then
        ENABLE_TIMER=1
      elif [[ "$1" == --quiesce ]]; then
        usage
        return 64
      elif [[ "$1" == -* ]]; then
        usage
        return 64
      else
        IFACE="$1"
      fi
      ;;
    2)
      if [[ "$2" == -* ]]; then
        usage
        return 64
      fi
      case "$1" in
        --enable) ENABLE_TIMER=1 ;;
        --quiesce) QUIESCE=1 ;;
        *)
          usage
          return 64
          ;;
      esac
      IFACE="$2"
      ;;
    *)
      usage
      return 64
      ;;
  esac

  if ! validate_interface_name "$IFACE"; then
    error "invalid interface name: $IFACE"
    usage
    return 64
  fi
}

require_commands() {
  local command_name
  for command_name in cmp install mkdir mktemp mv rm chmod chown stat realpath; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      error "required command not found: $command_name"
      return 1
    fi
  done
}

require_live_commands() {
  local command_name
  for command_name in flock sleep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      error "required live-install command not found: $command_name"
      return 1
    fi
  done
}

validate_destdir() {
  local requested="${DESTDIR:-}" canonical owner mode

  if (( QUIESCE )) && [[ -n "$requested" ]]; then
    error '--quiesce is available only for a live installation'
    return 64
  fi

  if [[ -z "$requested" ]]; then
    LIVE_INSTALL=1
    DESTDIR=
    if (( EUID != 0 )); then
      error 'live installation must run as root'
      return 1
    fi
    INSTALL_OWNER_ARGS=(-o root -g root)
    return 0
  fi

  LIVE_INSTALL=0
  INSTALL_OWNER_ARGS=()
  if [[ "$requested" != /* || "$requested" == / ]]; then
    error 'DESTDIR must be an absolute staging directory other than /'
    return 1
  fi
  if [[ -L "$requested" || ! -d "$requested" ]]; then
    error 'DESTDIR must be an existing non-symlink directory'
    return 1
  fi
  canonical="$(realpath -e -- "$requested")" || {
    error 'cannot resolve DESTDIR'
    return 1
  }
  if [[ "$canonical" != "$requested" ]]; then
    error 'DESTDIR must not contain symlinks or non-canonical components'
    return 1
  fi
  owner="$(stat -c '%u' -- "$requested")" || return 1
  if [[ "$owner" != "$EUID" ]]; then
    error 'DESTDIR must be owned by the invoking user'
    return 1
  fi
  mode="$(stat -c '%a' -- "$requested")" || return 1
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
    error 'DESTDIR must not be group- or world-writable'
    return 1
  fi
  DESTDIR="$canonical"
}

initialize_paths() {
  SOURCE_MAIN="$SCRIPT_DIR/bin/wg-healthcheck"
  SOURCE_HELPER="$SCRIPT_DIR/libexec/airvpn-api"
  SOURCE_MANAGED_MODULE="$SCRIPT_DIR/libexec/wg-healthcheck-managed"
  SOURCE_SETUP="$SCRIPT_DIR/bin/wg-healthcheck-setup"
  SOURCE_SETUP_PACKAGE="$SCRIPT_DIR/libexec/wg_healthcheck_setup"
  SOURCE_SERVICE="$SCRIPT_DIR/systemd/wg-healthcheck@.service"
  SOURCE_TIMER="$SCRIPT_DIR/systemd/wg-healthcheck@.timer"
  SOURCE_CONFIG="$SCRIPT_DIR/config/wg0.conf.example"
  SOURCE_SETUP_PACKAGE_FILES=(
    "$SOURCE_SETUP_PACKAGE/__init__.py"
    "$SOURCE_SETUP_PACKAGE/application.py"
    "$SOURCE_SETUP_PACKAGE/apply_config.py"
    "$SOURCE_SETUP_PACKAGE/apply_journal.py"
    "$SOURCE_SETUP_PACKAGE/apply_system.py"
    "$SOURCE_SETUP_PACKAGE/cli.py"
    "$SOURCE_SETUP_PACKAGE/clients.py"
    "$SOURCE_SETUP_PACKAGE/credential_state.py"
    "$SOURCE_SETUP_PACKAGE/model.py"
    "$SOURCE_SETUP_PACKAGE/private_io.py"
    "$SOURCE_SETUP_PACKAGE/store.py"
  )

  TARGET_MAIN="$DESTDIR/usr/local/sbin/wg-healthcheck"
  TARGET_SETUP="$DESTDIR/usr/local/sbin/wg-healthcheck-setup"
  TARGET_HELPER_DIR="$DESTDIR/usr/local/libexec/wg-healthcheck"
  TARGET_HELPER="$TARGET_HELPER_DIR/airvpn-api"
  TARGET_MANAGED_MODULE="$TARGET_HELPER_DIR/wg-healthcheck-managed"
  TARGET_SETUP_PACKAGE="$TARGET_HELPER_DIR/wg_healthcheck_setup"
  TARGET_SETUP_PACKAGE_FILES=(
    "$TARGET_SETUP_PACKAGE/__init__.py"
    "$TARGET_SETUP_PACKAGE/application.py"
    "$TARGET_SETUP_PACKAGE/apply_config.py"
    "$TARGET_SETUP_PACKAGE/apply_journal.py"
    "$TARGET_SETUP_PACKAGE/apply_system.py"
    "$TARGET_SETUP_PACKAGE/cli.py"
    "$TARGET_SETUP_PACKAGE/clients.py"
    "$TARGET_SETUP_PACKAGE/credential_state.py"
    "$TARGET_SETUP_PACKAGE/model.py"
    "$TARGET_SETUP_PACKAGE/private_io.py"
    "$TARGET_SETUP_PACKAGE/store.py"
  )
  TARGET_UNIT_DIR="$DESTDIR/etc/systemd/system"
  TARGET_SERVICE="$TARGET_UNIT_DIR/wg-healthcheck@.service"
  TARGET_TIMER="$TARGET_UNIT_DIR/wg-healthcheck@.timer"
  TARGET_CONFIG_DIR="$DESTDIR/etc/wireguard/healthcheck.d"
  TARGET_CONFIG="$TARGET_CONFIG_DIR/${IFACE}.conf"
  TARGET_CREDENTIAL="$TARGET_CONFIG_DIR/${IFACE}.api-key"
  TARGET_PRE_MANAGED="$DESTDIR/etc/wireguard/${IFACE}.conf.pre-managed"
  TARGET_STATE_DIR="$DESTDIR/var/lib/wg-healthcheck"
  TARGET_API_STATE="$TARGET_STATE_DIR/${IFACE}.api-state"

  LIVE_RUNTIME_PARENT="$DESTDIR/run"
  LIVE_RUNTIME_DIR="$LIVE_RUNTIME_PARENT/wg-healthcheck"
  LIVE_SETUP_GUARD="$LIVE_RUNTIME_DIR/${IFACE}.setup-guard"
  LIVE_INTERFACE_LOCK="$LIVE_RUNTIME_DIR/${IFACE}.lock"
  LIVE_PENDING="$DESTDIR/etc/wireguard/${IFACE}.conf.pending-healthcheck"
  LIVE_SAFETY="$DESTDIR/etc/wireguard/${IFACE}.conf.safety-healthcheck"
  LIVE_SETUP_JOURNAL="$TARGET_CONFIG_DIR/${IFACE}.setup-transaction"
}

validate_setup_package_manifest() (
  local index source_path target_path base entry
  local -a source_entries=() target_entries=()
  local -A expected_sources=() expected_targets=()
  local -A seen_sources=() seen_targets=()

  if (( ${#SOURCE_SETUP_PACKAGE_FILES[@]} == 0 ||
        ${#SOURCE_SETUP_PACKAGE_FILES[@]} != ${#TARGET_SETUP_PACKAGE_FILES[@]} )); then
    error 'setup package manifest is empty or inconsistent'
    return 1
  fi
  if [[ -L "$SOURCE_SETUP_PACKAGE" || ! -d "$SOURCE_SETUP_PACKAGE" ||
        ! -r "$SOURCE_SETUP_PACKAGE" || ! -x "$SOURCE_SETUP_PACKAGE" ]]; then
    error "missing or unsafe setup package directory: $SOURCE_SETUP_PACKAGE"
    return 1
  fi

  for (( index=0; index<${#SOURCE_SETUP_PACKAGE_FILES[@]}; index++ )); do
    source_path="${SOURCE_SETUP_PACKAGE_FILES[index]}"
    target_path="${TARGET_SETUP_PACKAGE_FILES[index]}"
    base="${source_path##*/}"
    if [[ -z "$base" || "$source_path" != "$SOURCE_SETUP_PACKAGE/$base" ||
          "$target_path" != "$TARGET_SETUP_PACKAGE/$base" ||
          -n "${expected_sources["$base"]+present}" ]]; then
      error 'setup package manifest contains an invalid or duplicate path'
      return 1
    fi
    if [[ -L "$source_path" || ! -f "$source_path" || ! -r "$source_path" ]]; then
      error "missing or unsafe setup package source: $source_path"
      return 1
    fi
    expected_sources["$base"]=1
    expected_targets["$base"]=1
  done

  shopt -s dotglob nullglob
  source_entries=("$SOURCE_SETUP_PACKAGE"/*)
  for entry in "${source_entries[@]}"; do
    base="${entry##*/}"
    if [[ -L "$entry" || ! -f "$entry" ||
          -z "${expected_sources["$base"]+present}" ||
          -n "${seen_sources["$base"]+present}" ]]; then
      error "unexpected or unsafe setup package source entry: $entry"
      return 1
    fi
    seen_sources["$base"]=1
  done
  if (( ${#seen_sources[@]} != ${#expected_sources[@]} )); then
    error 'setup package source manifest is incomplete'
    return 1
  fi

  if [[ ! -e "$TARGET_SETUP_PACKAGE" && ! -L "$TARGET_SETUP_PACKAGE" ]]; then
    return 0
  fi
  if [[ -L "$TARGET_SETUP_PACKAGE" || ! -d "$TARGET_SETUP_PACKAGE" ||
        ! -r "$TARGET_SETUP_PACKAGE" || ! -x "$TARGET_SETUP_PACKAGE" ]]; then
    error "unsafe setup package target directory: $TARGET_SETUP_PACKAGE"
    return 1
  fi
  target_entries=("$TARGET_SETUP_PACKAGE"/*)
  for entry in "${target_entries[@]}"; do
    base="${entry##*/}"
    if [[ -L "$entry" || ! -f "$entry" ||
          -z "${expected_targets["$base"]+present}" ||
          -n "${seen_targets["$base"]+present}" ]]; then
      error "unexpected or unsafe setup package target entry: $entry"
      return 1
    fi
    seen_targets["$base"]=1
  done
)

preflight_sources() {
  local source_path
  if [[ -L "$SOURCE_SETUP_PACKAGE" || ! -d "$SOURCE_SETUP_PACKAGE" ||
        ! -r "$SOURCE_SETUP_PACKAGE" || ! -x "$SOURCE_SETUP_PACKAGE" ]]; then
    error "missing or unsafe setup package directory: $SOURCE_SETUP_PACKAGE"
    return 1
  fi
  for source_path in \
    "$SOURCE_MAIN" "$SOURCE_HELPER" "$SOURCE_MANAGED_MODULE" "$SOURCE_SETUP" \
    "$SOURCE_SERVICE" "$SOURCE_TIMER" "$SOURCE_CONFIG" \
    "${SOURCE_SETUP_PACKAGE_FILES[@]}"; do
    if [[ -L "$source_path" || ! -f "$source_path" || ! -r "$source_path" ]]; then
      error "missing or unsafe source file: $source_path"
      return 1
    fi
  done
  validate_setup_package_manifest || return 1
}

validate_existing_directory() {
  local path="$1" owner mode expected_owner
  if [[ -L "$path" ]]; then
    error "managed path must not be a symlink: $path"
    return 1
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    error "managed directory path is not a directory: $path"
    return 1
  fi
  [[ -d "$path" ]] || return 0

  owner="$(stat -c '%u' -- "$path")" || return 1
  if (( LIVE_INSTALL )); then expected_owner=0; else expected_owner=$EUID; fi
  if [[ "$owner" != "$expected_owner" ]]; then
    error "managed directory has an unexpected owner: $path"
    return 1
  fi
  mode="$(stat -c '%a' -- "$path")" || return 1
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
    error "managed directory must not be group- or world-writable: $path"
    return 1
  fi
}

validate_managed_file_target() {
  local path="$1" owner expected_owner
  if [[ -L "$path" ]]; then
    error "managed file target must not be a symlink: $path"
    return 1
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    error "managed file target must be a regular file: $path"
    return 1
  fi
  if [[ -f "$path" ]]; then
    owner="$(stat -c '%u' -- "$path")" || return 1
    if (( LIVE_INSTALL )); then expected_owner=0; else expected_owner=$EUID; fi
    if [[ "$owner" != "$expected_owner" ]]; then
      error "managed file target has an unexpected owner: $path"
      return 1
    fi
  fi
}

validate_existing_config() {
  local mode
  [[ -e "$TARGET_CONFIG" || -L "$TARGET_CONFIG" ]] || return 0
  validate_managed_file_target "$TARGET_CONFIG" || return 1
  mode="$(stat -c '%a' -- "$TARGET_CONFIG")" || return 1
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
    error "existing configuration must not be group- or world-writable: $TARGET_CONFIG"
    return 1
  fi
}

validate_preserved_private_file() {
  local path="$1" owner mode links
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" || ! -f "$path" ]]; then
    error "preserved private path is not a regular file: $path"
    return 1
  fi
  owner="$(stat -c '%u' -- "$path")" || return 1
  if [[ "$owner" != "$EUID" ]]; then
    error "preserved private file has an unexpected owner: $path"
    return 1
  fi
  mode="$(stat -c '%a' -- "$path")" || return 1
  links="$(stat -c '%h' -- "$path")" || return 1
  if [[ "$mode" != 600 || "$links" != 1 ]]; then
    error "preserved private file must be mode 0600 with one link: $path"
    return 1
  fi
}

preflight_targets() {
  local path
  local -a directories=(
    "$DESTDIR/usr"
    "$DESTDIR/usr/local"
    "$DESTDIR/usr/local/sbin"
    "$DESTDIR/usr/local/libexec"
    "$TARGET_HELPER_DIR"
    "$TARGET_SETUP_PACKAGE"
    "$DESTDIR/etc"
    "$DESTDIR/etc/systemd"
    "$TARGET_UNIT_DIR"
    "$DESTDIR/etc/wireguard"
    "$TARGET_CONFIG_DIR"
    "$DESTDIR/var"
    "$DESTDIR/var/lib"
    "$TARGET_STATE_DIR"
  )
  local -a files=(
    "$TARGET_MAIN" "$TARGET_SETUP" "$TARGET_HELPER" "$TARGET_MANAGED_MODULE"
    "$TARGET_SERVICE" "$TARGET_TIMER" "${TARGET_SETUP_PACKAGE_FILES[@]}"
  )

  for path in "${directories[@]}"; do
    validate_existing_directory "$path" || return 1
  done
  for path in "${files[@]}"; do
    validate_managed_file_target "$path" || return 1
  done
  validate_existing_config || return 1
  validate_preserved_private_file "$TARGET_CREDENTIAL" || return 1
  validate_preserved_private_file "$TARGET_PRE_MANAGED" || return 1
  validate_preserved_private_file "$TARGET_API_STATE"
}

ensure_directory() {
  local path="$1" mode="$2" enforce_mode="$3"
  if [[ ! -d "$path" ]]; then
    install "${INSTALL_OWNER_ARGS[@]}" -d -m "$mode" -- "$path"
    return
  fi
  if (( enforce_mode )); then
    if (( LIVE_INSTALL )); then
      chown root:root -- "$path" || return 1
    fi
    chmod "$mode" -- "$path"
  fi
}

create_layout() {
  ensure_directory "$DESTDIR/usr" 0755 0 || return 1
  ensure_directory "$DESTDIR/usr/local" 0755 0 || return 1
  ensure_directory "$DESTDIR/usr/local/sbin" 0755 0 || return 1
  ensure_directory "$DESTDIR/usr/local/libexec" 0755 0 || return 1
  ensure_directory "$TARGET_HELPER_DIR" 0755 1 || return 1
  ensure_directory "$TARGET_SETUP_PACKAGE" 0755 1 || return 1
  ensure_directory "$DESTDIR/etc" 0755 0 || return 1
  ensure_directory "$DESTDIR/etc/systemd" 0755 0 || return 1
  ensure_directory "$TARGET_UNIT_DIR" 0755 0 || return 1
  ensure_directory "$DESTDIR/etc/wireguard" 0700 0 || return 1
  ensure_directory "$TARGET_CONFIG_DIR" 0700 1 || return 1
  ensure_directory "$DESTDIR/var" 0755 0 || return 1
  ensure_directory "$DESTDIR/var/lib" 0755 0 || return 1
  ensure_directory "$TARGET_STATE_DIR" 0700 1 || return 1
}

move_into_place() {
  mv -fT -- "$1" "$2"
}

atomic_install_file() (
  local source_path="$1" target_path="$2" mode="$3" parent base temporary=''

  # Invoked indirectly by the scoped EXIT trap below.
  # shellcheck disable=SC2317,SC2329
  cleanup_atomic_temp() {
    [[ -z "$temporary" ]] || rm -f -- "$temporary"
  }
  trap cleanup_atomic_temp EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  parent="${target_path%/*}"
  base="${target_path##*/}"
  temporary="$(mktemp "$parent/.${base}.tmp.XXXXXX")" || return 1

  if ! install "${INSTALL_OWNER_ARGS[@]}" -m "$mode" -- "$source_path" "$temporary"; then
    return 1
  fi
  if ! move_into_place "$temporary" "$target_path"; then
    return 1
  fi
  temporary=''
)

install_setup_package() {
  local index
  for (( index=0; index<${#SOURCE_SETUP_PACKAGE_FILES[@]}; index++ )); do
    atomic_install_file \
      "${SOURCE_SETUP_PACKAGE_FILES[index]}" \
      "${TARGET_SETUP_PACKAGE_FILES[index]}" \
      0644 || return 1
  done
}

publish_inert_upgrade_guard() (
  local target_path="$1" command_name="$2"
  local parent base guard_source='' owner mode links

  # Invoked indirectly by the scoped EXIT trap below.
  # shellcheck disable=SC2317,SC2329
  cleanup_setup_guard_source() {
    [[ -z "$guard_source" ]] || rm -f -- "$guard_source"
  }
  trap cleanup_setup_guard_source EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  parent="${target_path%/*}"
  base="${target_path##*/}"
  guard_source="$(mktemp "$parent/.${base}.upgrade-guard.XXXXXX")" || return 1
  if ! printf '%s\n' \
      '#!/bin/sh' \
      "printf '%s\\n' '${command_name}: installation is incomplete; rerun install.sh' >&2" \
      'exit 75' >"$guard_source"; then
    return 1
  fi

  if [[ -f "$target_path" && ! -L "$target_path" ]]; then
    owner="$(stat -c '%u' -- "$target_path")" || return 1
    mode="$(stat -c '%a' -- "$target_path")" || return 1
    links="$(stat -c '%h' -- "$target_path")" || return 1
    if [[ "$owner" == "$EUID" && "$mode" == 755 && "$links" == 1 ]] &&
       cmp -s -- "$guard_source" "$target_path"; then
      return 0
    fi
  fi

  atomic_install_file "$guard_source" "$target_path" 0755
)

ensure_launcher_directory() {
  ensure_directory "$DESTDIR/usr" 0755 0 || return 1
  ensure_directory "$DESTDIR/usr/local" 0755 0 || return 1
  ensure_directory "$DESTDIR/usr/local/sbin" 0755 0 || return 1
}

publish_runtime_upgrade_guard() {
  if [[ ! -d "${TARGET_MAIN%/*}" ]]; then
    ensure_launcher_directory || return 1
  fi
  publish_inert_upgrade_guard "$TARGET_MAIN" wg-healthcheck
}

publish_setup_upgrade_guard() {
  if [[ ! -d "${TARGET_SETUP%/*}" ]]; then
    ensure_launcher_directory || return 1
  fi
  publish_inert_upgrade_guard "$TARGET_SETUP" wg-healthcheck-setup
}

install_guarded_artifacts() {
  # Both public launchers are inert before this function runs. A partial dependency
  # or package replacement therefore remains non-executable and retry-safe.
  create_layout || return 1
  atomic_install_file "$SOURCE_HELPER" "$TARGET_HELPER" 0755 || return 1
  atomic_install_file "$SOURCE_MANAGED_MODULE" "$TARGET_MANAGED_MODULE" 0644 || return 1
  install_setup_package || return 1
  atomic_install_file "$SOURCE_SERVICE" "$TARGET_SERVICE" 0644 || return 1
  atomic_install_file "$SOURCE_TIMER" "$TARGET_TIMER" 0644 || return 1

  if [[ -e "$TARGET_CONFIG" ]]; then
    if (( LIVE_INSTALL )); then
      chown root:root -- "$TARGET_CONFIG" || return 1
    fi
    chmod 0600 -- "$TARGET_CONFIG"
  else
    atomic_install_file "$SOURCE_CONFIG" "$TARGET_CONFIG" 0600
  fi
}

publish_final_launchers() {
  # Setup is published first. If runtime publication fails, setup can only reach the
  # still-inert runtime guard and the operator can safely rerun the installer.
  atomic_install_file "$SOURCE_SETUP" "$TARGET_SETUP" 0755 || return 1
  atomic_install_file "$SOURCE_MAIN" "$TARGET_MAIN" 0755
}

resolve_systemctl() {
  if [[ -x /usr/bin/systemctl ]]; then
    SYSTEMCTL_BIN=/usr/bin/systemctl
  elif [[ -x /bin/systemctl ]]; then
    SYSTEMCTL_BIN=/bin/systemctl
  else
    error 'systemctl was not found at /usr/bin/systemctl or /bin/systemctl'
    return 1
  fi
}

systemctl_exec() {
  "$SYSTEMCTL_BIN" "$@"
}

flock_exec() {
  command flock "$@"
}

sleep_exec() {
  command sleep "$@"
}

query_unit_activity() {
  local unit="$1" output rc
  if output="$(systemctl_exec is-active --quiet "$unit" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  [[ -z "$output" ]] || return 2
  case "$rc" in
    0) return 0 ;;
    3|4) return 1 ;;
    *) return 2 ;;
  esac
}

refuse_active_instance() {
  local iface="$1" timer service state
  timer="wg-healthcheck@${iface}.timer"
  service="wg-healthcheck@${iface}.service"

  if query_unit_activity "$timer"; then
    error "refusing to install while the instance timer is active: $timer"
    return 1
  else
    state=$?
  fi
  if (( state != 1 )); then
    error "could not prove the instance timer inactive: $timer"
    return 1
  fi

  if query_unit_activity "$service"; then
    error "refusing to install while the instance worker is active: $service"
    return 1
  else
    state=$?
  fi
  if (( state != 1 )); then
    error "could not prove the instance worker inactive: $service"
    return 1
  fi
}

refuse_active_shared_instances() {
  local unit_kind output rc
  for unit_kind in timer service; do
    if output="$(systemctl_exec list-units \
        --type="$unit_kind" \
        --state=active,activating,deactivating,reloading \
        --no-legend --plain --full --no-pager \
        "wg-healthcheck@*.${unit_kind}" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    if (( rc != 0 )); then
      error "could not prove all health-check ${unit_kind} instances inactive"
      return 1
    fi
    if [[ -n "$output" ]]; then
      error "refusing to install while a health-check ${unit_kind} instance is active"
      return 1
    fi
  done
}

wait_for_instance_inactive() {
  local iface="$1" attempt timer_active service_active state
  local timer service unit
  timer="wg-healthcheck@${iface}.timer"
  service="wg-healthcheck@${iface}.service"

  for (( attempt=0; attempt<30; attempt++ )); do
    timer_active=0
    service_active=0
    for unit in "$timer" "$service"; do
      if query_unit_activity "$unit"; then
        state=0
      else
        state=$?
      fi
      case "$state" in
        0)
          if [[ "$unit" == "$timer" ]]; then timer_active=1; else service_active=1; fi
          ;;
        1)
          ;;
        *)
          error "could not prove unit inactive while quiescing: $unit"
          return 1
          ;;
      esac
    done
    if (( ! timer_active && ! service_active )); then
      return 0
    fi
    if (( attempt < 29 )); then
      sleep_exec 1 || return 1
    fi
  done

  error "the timer or worker did not become inactive for interface $iface"
  return 1
}

ensure_upgrade_runtime_directory() {
  local owner mode
  if [[ -L "$LIVE_RUNTIME_PARENT" ]]; then
    error "runtime parent directory must not be a symlink: $LIVE_RUNTIME_PARENT"
    return 1
  fi
  if [[ ! -e "$LIVE_RUNTIME_PARENT" ]]; then
    install "${INSTALL_OWNER_ARGS[@]}" -d -m 0755 -- "$LIVE_RUNTIME_PARENT" || return 1
  fi
  if [[ ! -d "$LIVE_RUNTIME_PARENT" || -L "$LIVE_RUNTIME_PARENT" ]]; then
    error "runtime parent path is not a directory: $LIVE_RUNTIME_PARENT"
    return 1
  fi
  owner="$(stat -c '%u' -- "$LIVE_RUNTIME_PARENT")" || return 1
  mode="$(stat -c '%a' -- "$LIVE_RUNTIME_PARENT")" || return 1
  if [[ "$owner" != "$EUID" || ! "$mode" =~ ^[0-7]{3,4}$ ||
        $(( 8#$mode & 8#022 )) -ne 0 ]]; then
    error "runtime parent directory has unsafe metadata: $LIVE_RUNTIME_PARENT"
    return 1
  fi
  if [[ -L "$LIVE_RUNTIME_DIR" ]]; then
    error "runtime lock directory must not be a symlink: $LIVE_RUNTIME_DIR"
    return 1
  fi
  if [[ ! -e "$LIVE_RUNTIME_DIR" ]]; then
    install "${INSTALL_OWNER_ARGS[@]}" -d -m 0700 -- "$LIVE_RUNTIME_DIR" || return 1
  fi
  if [[ ! -d "$LIVE_RUNTIME_DIR" || -L "$LIVE_RUNTIME_DIR" ]]; then
    error "runtime lock path is not a directory: $LIVE_RUNTIME_DIR"
    return 1
  fi
  owner="$(stat -c '%u' -- "$LIVE_RUNTIME_DIR")" || return 1
  mode="$(stat -c '%a' -- "$LIVE_RUNTIME_DIR")" || return 1
  if [[ "$owner" != "$EUID" || "$mode" != 700 ]]; then
    error "runtime lock directory has unsafe metadata: $LIVE_RUNTIME_DIR"
    return 1
  fi
}

create_upgrade_lock_file() {
  local path="$1"
  ( set -o noclobber; umask 077; : >"$path" ) 2>/dev/null
}

acquire_upgrade_lock_file() {
  local path="$1" create_missing="$2"
  local owner mode links before opened lock_fd=''

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    if (( ! create_missing )); then
      error "upgrade lock disappeared before it could be acquired: $path"
      return 1
    fi
    if create_upgrade_lock_file "$path"; then
      :
    elif [[ ! -e "$path" && ! -L "$path" ]]; then
      error "upgrade lock could not be created safely: $path"
      return 1
    fi
  fi
  if [[ -L "$path" || ! -f "$path" ]]; then
    error "upgrade lock is not a regular non-symlink file: $path"
    return 1
  fi
  owner="$(stat -c '%u' -- "$path")" || return 1
  mode="$(stat -c '%a' -- "$path")" || return 1
  links="$(stat -c '%h' -- "$path")" || return 1
  if [[ "$owner" != "$EUID" || "$mode" != 600 || "$links" != 1 ]]; then
    error "upgrade lock has unsafe metadata: $path"
    return 1
  fi
  before="$(stat -c '%d:%i:%u:%a:%h' -- "$path")" || return 1
  if ! exec {lock_fd}<>"$path"; then
    error "upgrade lock could not be opened safely: $path"
    return 1
  fi
  if [[ -L "$path" || ! -f "$path" ]]; then
    exec {lock_fd}>&-
    error "upgrade lock changed while it was opened: $path"
    return 1
  fi
  opened="$(stat -Lc '%d:%i:%u:%a:%h' -- "/proc/$BASHPID/fd/$lock_fd")" || {
    exec {lock_fd}>&-
    return 1
  }
  if [[ "$opened" != "$before" ||
        "$(stat -c '%d:%i:%u:%a:%h' -- "$path")" != "$before" ]]; then
    exec {lock_fd}>&-
    error "upgrade lock changed while it was opened: $path"
    return 1
  fi
  if ! flock_exec -n -x "$lock_fd"; then
    exec {lock_fd}>&-
    error "refusing to install while an upgrade lock is held: $path"
    return 1
  fi
  UPGRADE_LOCK_FDS+=("$lock_fd")
  UPGRADE_LOCK_PATHS+=("$path")
}

release_upgrade_locks() {
  local index fd rc=0
  for (( index=${#UPGRADE_LOCK_FDS[@]}-1; index>=0; index-- )); do
    fd="${UPGRADE_LOCK_FDS[index]}"
    flock_exec -u "$fd" || rc=1
    exec {fd}>&- || rc=1
  done
  UPGRADE_LOCK_FDS=()
  UPGRADE_LOCK_PATHS=()
  return "$rc"
}

acquire_upgrade_locks() {
  local path nullglob_was_set=0
  local -a setup_guards=() interface_locks=()

  if (( ${#UPGRADE_LOCK_FDS[@]} != 0 || ${#UPGRADE_LOCK_PATHS[@]} != 0 )); then
    error 'upgrade locks are already retained by this installer process'
    return 1
  fi
  ensure_upgrade_runtime_directory || return 1
  acquire_upgrade_lock_file "$LIVE_SETUP_GUARD" 1 || {
    release_upgrade_locks >/dev/null 2>&1 || :
    return 1
  }

  if shopt -q nullglob; then nullglob_was_set=1; fi
  shopt -s nullglob
  setup_guards=("$LIVE_RUNTIME_DIR"/*.setup-guard)
  interface_locks=("$LIVE_RUNTIME_DIR"/*.lock)
  if (( ! nullglob_was_set )); then shopt -u nullglob; fi

  for path in "${setup_guards[@]}"; do
    [[ "$path" == "$LIVE_SETUP_GUARD" ]] && continue
    acquire_upgrade_lock_file "$path" 0 || {
      release_upgrade_locks >/dev/null 2>&1 || :
      return 1
    }
  done
  acquire_upgrade_lock_file "$LIVE_INTERFACE_LOCK" 1 || {
    release_upgrade_locks >/dev/null 2>&1 || :
    return 1
  }
  for path in "${interface_locks[@]}"; do
    [[ "$path" == "$LIVE_INTERFACE_LOCK" ||
       "$path" == "$LIVE_RUNTIME_DIR/airvpn-api.lock" ]] && continue
    acquire_upgrade_lock_file "$path" 0 || {
      release_upgrade_locks >/dev/null 2>&1 || :
      return 1
    }
  done
  if [[ -e "$LIVE_RUNTIME_DIR/airvpn-api.lock" ||
        -L "$LIVE_RUNTIME_DIR/airvpn-api.lock" ]]; then
    acquire_upgrade_lock_file "$LIVE_RUNTIME_DIR/airvpn-api.lock" 0 || {
      release_upgrade_locks >/dev/null 2>&1 || :
      return 1
    }
  fi
}

upgrade_lock_is_retained() {
  local candidate="$1" retained
  for retained in "${UPGRADE_LOCK_PATHS[@]}"; do
    [[ "$retained" == "$candidate" ]] && return 0
  done
  return 1
}

acquire_discovered_upgrade_locks() {
  local candidate nullglob_was_set=0
  local -a setup_guards=() interface_locks=()

  if shopt -q nullglob; then nullglob_was_set=1; fi
  shopt -s nullglob
  setup_guards=("$LIVE_RUNTIME_DIR"/*.setup-guard)
  interface_locks=("$LIVE_RUNTIME_DIR"/*.lock)
  if (( ! nullglob_was_set )); then shopt -u nullglob; fi

  for candidate in "${setup_guards[@]}"; do
    upgrade_lock_is_retained "$candidate" && continue
    acquire_upgrade_lock_file "$candidate" 0 || return 1
  done
  for candidate in "${interface_locks[@]}"; do
    [[ "$candidate" == "$LIVE_RUNTIME_DIR/airvpn-api.lock" ]] && continue
    upgrade_lock_is_retained "$candidate" && continue
    acquire_upgrade_lock_file "$candidate" 0 || return 1
  done
  candidate="$LIVE_RUNTIME_DIR/airvpn-api.lock"
  if [[ -e "$candidate" || -L "$candidate" ]] &&
     ! upgrade_lock_is_retained "$candidate"; then
    acquire_upgrade_lock_file "$candidate" 0 || return 1
  fi
}

stabilize_live_upgrade_after_guards() {
  # The public entrypoints now return 75, so a finite rescan catches operations that
  # crossed the guard-publication boundary without allowing new path-based launches.
  refuse_active_instance "$IFACE" || return 1
  refuse_active_shared_instances || return 1
  acquire_discovered_upgrade_locks || return 1
  refuse_active_instance "$IFACE" || return 1
  refuse_active_shared_instances || return 1
  acquire_discovered_upgrade_locks || return 1
  refuse_recovery_artifacts
}

# Retained for source-compatible installer tests and operator tooling. The probe now
# acquires and retains both administrative and worker locks through publication.
probe_existing_interface_lock() {
  acquire_upgrade_locks
}

refuse_recovery_artifacts() {
  local path
  for path in "$LIVE_PENDING" "$LIVE_SAFETY" "$LIVE_SETUP_JOURNAL"; do
    if [[ -e "$path" || -L "$path" ]]; then
      error "refusing to install while recovery state exists: $path"
      return 1
    fi
  done
}

record_timer_enable_state() {
  local timer="$1" output rc
  if output="$(systemctl_exec is-enabled "$timer" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  case "$output:$rc" in
    enabled:0|enabled-runtime:0)
      TIMER_WAS_ENABLED=1
      ;;
    static:0|indirect:0|generated:0|transient:0|alias:0|linked:0|linked-runtime:0|\
    disabled:1|masked:1|masked-runtime:1|not-found:1)
      TIMER_WAS_ENABLED=0
      ;;
    *)
      error "could not determine the exact enablement state of timer: $timer"
      return 1
      ;;
  esac
}

report_quiesce_failure() {
  (( QUIESCE_DISABLE_ATTEMPTED )) || return 0
  (( ! QUIESCE_FAILURE_REPORTED )) || return 0
  QUIESCE_FAILURE_REPORTED=1
  if (( QUIESCE_TIMER_DISABLED )); then
    error 'upgrade is incomplete; the timer remains disabled; verify the installation before enabling it'
  else
    error 'timer disable was attempted but not confirmed; verify its state and ensure the timer remains disabled'
  fi
}

installer_exit_cleanup() {
  local requested_rc="${1:?}" cleanup_failed=0
  if (( ${#UPGRADE_LOCK_FDS[@]} != 0 || ${#UPGRADE_LOCK_PATHS[@]} != 0 )); then
    release_upgrade_locks || cleanup_failed=1
  fi
  if (( requested_rc != 0 )); then
    report_quiesce_failure
  fi
  if (( requested_rc == 0 && cleanup_failed )); then
    return 1
  fi
  return "$requested_rc"
}

prepare_live_upgrade() {
  local quiesce="$1" iface="$2"
  local timer service
  timer="wg-healthcheck@${iface}.timer"
  service="wg-healthcheck@${iface}.service"

  TIMER_WAS_ENABLED=0
  QUIESCE_DISABLE_ATTEMPTED=0
  QUIESCE_TIMER_DISABLED=0
  QUIESCE_FAILURE_REPORTED=0
  if (( quiesce )); then
    record_timer_enable_state "$timer" || return 1
    QUIESCE_DISABLE_ATTEMPTED=1
    if ! systemctl_exec disable --now "$timer"; then
      report_quiesce_failure
      return 1
    fi
    QUIESCE_TIMER_DISABLED=1
    if ! systemctl_exec stop "$service" ||
       ! wait_for_instance_inactive "$iface" ||
       ! refuse_active_shared_instances ||
       ! probe_existing_interface_lock ||
       ! refuse_active_instance "$iface" ||
       ! refuse_active_shared_instances ||
       ! refuse_recovery_artifacts; then
      release_upgrade_locks >/dev/null 2>&1 || :
      report_quiesce_failure
      return 1
    fi
  else
    refuse_active_instance "$iface" || return 1
    refuse_active_shared_instances || return 1
    if ! probe_existing_interface_lock ||
       ! refuse_active_instance "$iface" ||
       ! refuse_active_shared_instances ||
       ! refuse_recovery_artifacts; then
      release_upgrade_locks >/dev/null 2>&1 || :
      return 1
    fi
  fi
}

run_live_systemctl() {
  local action="$1" iface="$2"
  case "$action" in
    reload) systemctl_exec daemon-reload ;;
    enable) systemctl_exec enable --now "wg-healthcheck@${iface}.timer" ;;
    *) return 64 ;;
  esac
}

main() {
  local install_rc=0
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  export PATH
  umask 077

  parse_arguments "$@" || return $?
  require_commands || return 1
  validate_destdir || return 1
  initialize_paths
  preflight_sources || return 1
  preflight_targets || return 1
  if (( LIVE_INSTALL )); then
    require_live_commands || return 1
    resolve_systemctl || return 1
    prepare_live_upgrade "$QUIESCE" "$IFACE" || return 1
  fi

  if ! publish_runtime_upgrade_guard; then
    install_rc=1
  elif ! publish_setup_upgrade_guard; then
    install_rc=1
  elif (( LIVE_INSTALL )) && ! stabilize_live_upgrade_after_guards; then
    install_rc=1
  elif ! install_guarded_artifacts; then
    install_rc=1
  fi

  if (( LIVE_INSTALL )); then
    if (( install_rc == 0 )) && ! run_live_systemctl reload "$IFACE"; then
      install_rc=1
    fi
    if (( install_rc == 0 )) && ! publish_final_launchers; then
      install_rc=1
    fi
    if ! release_upgrade_locks; then
      install_rc=1
    fi
    if (( install_rc != 0 )); then
      report_quiesce_failure
      return 1
    fi
    if (( ENABLE_TIMER )) && ! run_live_systemctl enable "$IFACE"; then
      return 1
    fi
  else
    if (( install_rc == 0 )) && ! publish_final_launchers; then
      install_rc=1
    fi
    (( install_rc == 0 )) || return 1
    if (( ENABLE_TIMER )); then
      printf 'Staged install complete; --enable was not applied to the host.\n' >&2
    fi
  fi

  if (( QUIESCE )); then
    if (( TIMER_WAS_ENABLED )); then
      printf 'Installed wg-healthcheck for %s; the previously enabled timer remains disabled\n' "$IFACE"
    else
      printf 'Installed wg-healthcheck for %s; the timer remains disabled\n' "$IFACE"
    fi
  elif (( ENABLE_TIMER && LIVE_INSTALL )); then
    printf 'Installed and enabled wg-healthcheck for %s\n' "$IFACE"
  else
    printf 'Installed wg-healthcheck for %s (timer not enabled)\n' "$IFACE"
  fi
}

# Reached only through the scoped traps installed for direct execution below.
# shellcheck disable=SC2317
installer_handle_exit() {
  local requested_rc="$1" cleanup_rc
  trap - EXIT HUP INT TERM
  if installer_exit_cleanup "$requested_rc"; then
    cleanup_rc=0
  else
    cleanup_rc=$?
  fi
  exit "$cleanup_rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  trap 'installer_handle_exit 129' HUP
  trap 'installer_handle_exit 130' INT
  trap 'installer_handle_exit 143' TERM
  trap 'installer_handle_exit "$?"' EXIT
  main "$@"
fi
