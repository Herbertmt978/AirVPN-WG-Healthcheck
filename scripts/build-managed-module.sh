#!/usr/bin/env bash

# Rebuild the tracked managed runtime from its fixed, reviewable source slices.
set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly REPO_ROOT
readonly FRAGMENT_DIR="$REPO_ROOT/libexec/wg-healthcheck-managed.d"
readonly RUNTIME_FILE="$REPO_ROOT/libexec/wg-healthcheck-managed"
readonly -a FRAGMENT_MANIFEST=(
  '10-integrity.bash'
  '20-journal-transitions.bash'
  '30-api-state.bash'
  '40-provider-attempt.bash'
  '50-qb-containment.bash'
  '60-profile-effects.bash'
  '70-transaction-recovery.bash'
  '80-admin-commands.bash'
  '90-status-maintenance.bash'
)

private_dir=''
runtime_tmp=''

cleanup() {
  [[ -z "$runtime_tmp" ]] || rm -f -- "$runtime_tmp"
  [[ -z "$private_dir" ]] || rm -rf -- "$private_dir"
}
trap cleanup EXIT

die() {
  printf '%s\n' "build-managed-module.sh: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' "usage: ${0##*/} --check|--write" >&2
  exit 64
}

validate_layout() {
  [[ "$SCRIPT_DIR" == "$REPO_ROOT/scripts" ]] || die 'script path is not the repository scripts directory'
  [[ -d "$FRAGMENT_DIR" && ! -L "$FRAGMENT_DIR" ]] || die 'managed fragment directory is not a real directory'
  [[ -d "${RUNTIME_FILE%/*}" && ! -L "${RUNTIME_FILE%/*}" ]] || die 'managed runtime directory is not a real directory'

  local -a actual_paths=()
  mapfile -d '' actual_paths < <(
    LC_ALL=C find "$FRAGMENT_DIR" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z
  )
  [[ ${#actual_paths[@]} -eq ${#FRAGMENT_MANIFEST[@]} ]] ||
    die 'managed fragment directory does not match the fixed manifest'

  local fragment fragment_path index
  for index in "${!FRAGMENT_MANIFEST[@]}"; do
    fragment="${FRAGMENT_MANIFEST[$index]}"
    [[ "$fragment" =~ ^[0-9]{2}-[a-z0-9-]+\.bash$ ]] || die "invalid manifest entry: $fragment"
    fragment_path="$FRAGMENT_DIR/$fragment"
    [[ "${actual_paths[$index]}" == "$fragment_path" ]] ||
      die 'managed fragment directory does not match the fixed manifest'
    [[ "$fragment_path" == "$FRAGMENT_DIR/"* ]] || die "fragment escapes source directory: $fragment"
    [[ -f "$fragment_path" && ! -L "$fragment_path" ]] || die "fragment is not a regular file: $fragment"
    if LC_ALL=C grep -q $'\r' -- "$fragment_path"; then
      die "fragment is not LF-only: $fragment"
    fi
  done

  if [[ -e "$RUNTIME_FILE" || -L "$RUNTIME_FILE" ]]; then
    [[ -f "$RUNTIME_FILE" && ! -L "$RUNTIME_FILE" ]] || die 'managed runtime is not a regular file'
  elif [[ "$mode" == '--check' ]]; then
    die 'managed runtime is not a regular file'
  fi
}

generate() {
  local output_path="${1:?output path is required}"
  local fragment separator=''

  : > "$output_path"
  for fragment in "${FRAGMENT_MANIFEST[@]}"; do
    printf '%s' "$separator" >> "$output_path"
    LC_ALL=C cat -- "$FRAGMENT_DIR/$fragment" >> "$output_path"
    separator=$'\n'
  done
}

[[ $# -eq 1 ]] || usage
case "$1" in
  --check|--write) mode="$1" ;;
  *) usage ;;
esac

validate_layout

if [[ "$mode" == '--check' ]]; then
  private_dir="$(mktemp -d "${TMPDIR:-/tmp}/wg-healthcheck-managed.XXXXXX")"
  generated_file="$private_dir/wg-healthcheck-managed"
  generate "$generated_file"
  if ! cmp -s -- "$generated_file" "$RUNTIME_FILE"; then
    printf '%s\n' 'managed runtime is out of date; run scripts/build-managed-module.sh --write' >&2
    exit 1
  fi
else
  runtime_tmp="$(mktemp "${RUNTIME_FILE%/*}/.wg-healthcheck-managed.XXXXXX")"
  generate "$runtime_tmp"
  chmod 0644 -- "$runtime_tmp"
  mv -f -- "$runtime_tmp" "$RUNTIME_FILE"
  runtime_tmp=''
fi
