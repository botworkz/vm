#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

if [[ -t 2 ]]; then
  COLOR_RED='\033[31m'
  COLOR_YELLOW='\033[33m'
  COLOR_GREEN='\033[32m'
  COLOR_RESET='\033[0m'
else
  COLOR_RED=''
  COLOR_YELLOW=''
  COLOR_GREEN=''
  COLOR_RESET=''
fi

log_info() { echo -e "${COLOR_GREEN}==>${COLOR_RESET} $*" >&2; }
log_warn() { echo -e "${COLOR_YELLOW}WARN:${COLOR_RESET} $*" >&2; }
log_error() { echo -e "${COLOR_RED}ERROR:${COLOR_RESET} $*" >&2; }

die() { log_error "$*"; exit 1; }

ensure_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

default_private_key_path() {
  echo "${BUILD_DIR}/packer_ssh_key"
}

ensure_default_keypair() {
  local private_key
  private_key="$(default_private_key_path)"
  mkdir -p "${BUILD_DIR}"
  if [[ ! -f "${private_key}" ]]; then
    log_info "Generating ephemeral keypair at ${private_key}"
    ssh-keygen -t ed25519 -N '' -f "${private_key}" >/dev/null
  elif [[ ! -f "${private_key}.pub" ]]; then
    log_info "Regenerating missing public key at ${private_key}.pub"
    ssh-keygen -y -f "${private_key}" > "${private_key}.pub"
    chmod 0644 "${private_key}.pub"
  fi
}

discover_image() {
  local override="${1:-}"
  local candidates

  if [[ -n "${override}" ]]; then
    [[ -f "${override}" ]] || die "image not found: ${override}"
    realpath "${override}"
    return 0
  fi

  candidates=(
    "${BUILD_DIR}/debian-13-botwork-compressed.qcow2"
    "${BUILD_DIR}/output/debian-13-botwork.qcow2"
    "${BUILD_DIR}/debian-13-botwork.qcow2"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      realpath "${candidate}"
      return 0
    fi
  done

  die "could not auto-discover image under ${BUILD_DIR}"
}
