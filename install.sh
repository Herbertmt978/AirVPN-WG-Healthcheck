#!/bin/bash -p

case "${BASH_SOURCE[0]}" in
  */*) _installer_dir="${BASH_SOURCE[0]%/*}" ;;
  *) _installer_dir=. ;;
esac
SCRIPT_DIR="$(cd -- "$_installer_dir" && pwd -P)" || exit 1
unset _installer_dir

IFACE=wg0
ENABLE_TIMER=0
LIVE_INSTALL=1
SYSTEMCTL_BIN=
INSTALL_OWNER_ARGS=()

usage() {
  printf 'usage: %s [--enable] [iface]\n' "${0##*/}" >&2
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

  case $# in
    0)
      ;;
    1)
      if [[ "$1" == --enable ]]; then
        ENABLE_TIMER=1
      elif [[ "$1" == -* ]]; then
        usage
        return 64
      else
        IFACE="$1"
      fi
      ;;
    2)
      if [[ "$1" != --enable || "$2" == -* ]]; then
        usage
        return 64
      fi
      ENABLE_TIMER=1
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
  for command_name in install mkdir mktemp mv rm chmod chown stat realpath; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      error "required command not found: $command_name"
      return 1
    fi
  done
}

validate_destdir() {
  local requested="${DESTDIR:-}" canonical owner mode

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
  SOURCE_SERVICE="$SCRIPT_DIR/systemd/wg-healthcheck@.service"
  SOURCE_TIMER="$SCRIPT_DIR/systemd/wg-healthcheck@.timer"
  SOURCE_CONFIG="$SCRIPT_DIR/config/wg0.conf.example"

  TARGET_MAIN="$DESTDIR/usr/local/sbin/wg-healthcheck"
  TARGET_HELPER_DIR="$DESTDIR/usr/local/libexec/wg-healthcheck"
  TARGET_HELPER="$TARGET_HELPER_DIR/airvpn-api"
  TARGET_UNIT_DIR="$DESTDIR/etc/systemd/system"
  TARGET_SERVICE="$TARGET_UNIT_DIR/wg-healthcheck@.service"
  TARGET_TIMER="$TARGET_UNIT_DIR/wg-healthcheck@.timer"
  TARGET_CONFIG_DIR="$DESTDIR/etc/wireguard/healthcheck.d"
  TARGET_CONFIG="$TARGET_CONFIG_DIR/${IFACE}.conf"
}

preflight_sources() {
  local source_path
  for source_path in \
    "$SOURCE_MAIN" "$SOURCE_HELPER" "$SOURCE_SERVICE" "$SOURCE_TIMER" "$SOURCE_CONFIG"; do
    if [[ -L "$source_path" || ! -f "$source_path" || ! -r "$source_path" ]]; then
      error "missing or unsafe source file: $source_path"
      return 1
    fi
  done
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

preflight_targets() {
  local path
  local -a directories=(
    "$DESTDIR/usr"
    "$DESTDIR/usr/local"
    "$DESTDIR/usr/local/sbin"
    "$DESTDIR/usr/local/libexec"
    "$TARGET_HELPER_DIR"
    "$DESTDIR/etc"
    "$DESTDIR/etc/systemd"
    "$TARGET_UNIT_DIR"
    "$DESTDIR/etc/wireguard"
    "$TARGET_CONFIG_DIR"
  )
  local -a files=("$TARGET_MAIN" "$TARGET_HELPER" "$TARGET_SERVICE" "$TARGET_TIMER")

  for path in "${directories[@]}"; do
    validate_existing_directory "$path" || return 1
  done
  for path in "${files[@]}"; do
    validate_managed_file_target "$path" || return 1
  done
  validate_existing_config
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
  ensure_directory "$DESTDIR/etc" 0755 0 || return 1
  ensure_directory "$DESTDIR/etc/systemd" 0755 0 || return 1
  ensure_directory "$TARGET_UNIT_DIR" 0755 0 || return 1
  ensure_directory "$DESTDIR/etc/wireguard" 0700 0 || return 1
  ensure_directory "$TARGET_CONFIG_DIR" 0700 1
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

install_artifacts() {
  # Keep every intermediate state retry-safe: the old main ignores a new helper,
  # while the new main is installed only after its helper is available. Units are
  # reloaded only after the complete ordered deployment succeeds.
  atomic_install_file "$SOURCE_HELPER" "$TARGET_HELPER" 0755 || return 1
  atomic_install_file "$SOURCE_MAIN" "$TARGET_MAIN" 0755 || return 1
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

run_live_systemctl() {
  local enable="$1" iface="$2"
  systemctl_exec daemon-reload || return 1
  if (( enable )); then
    systemctl_exec enable --now "wg-healthcheck@${iface}.timer"
  fi
}

main() {
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
    resolve_systemctl || return 1
  fi

  create_layout || return 1
  install_artifacts || return 1

  if (( LIVE_INSTALL )); then
    run_live_systemctl "$ENABLE_TIMER" "$IFACE" || return 1
  elif (( ENABLE_TIMER )); then
    printf 'Staged install complete; --enable was not applied to the host.\n' >&2
  fi

  if (( ENABLE_TIMER && LIVE_INSTALL )); then
    printf 'Installed and enabled wg-healthcheck for %s\n' "$IFACE"
  else
    printf 'Installed wg-healthcheck for %s (timer not enabled)\n' "$IFACE"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
