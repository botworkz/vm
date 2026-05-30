#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
# shellcheck source=scripts/lib/botworkz.sh
source "${SCRIPT_DIR}/lib/botworkz.sh"
# shellcheck source=scripts/lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"

usage() {
  cat <<USAGE
Usage: $0 [--compress|--no-compress] [--accelerator kvm|tcg|auto] [--key <path>] [-h|--help]
  Default is --no-compress.
USAGE
}

NO_COMPRESS=true
ACCELERATOR="auto"
KEY_PATH="$(default_private_key_path)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compress)
      NO_COMPRESS=false
      shift
      ;;
    --no-compress)
      NO_COMPRESS=true
      shift
      ;;
    --accelerator)
      ACCELERATOR="${2:-}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

ensure_command docker
KEY_PATH="$(realpath -m "${KEY_PATH}")"
DEFAULT_KEY_PATH="$(realpath -m "$(default_private_key_path)")"
if [[ "${KEY_PATH}" == "${DEFAULT_KEY_PATH}" ]]; then
  ensure_default_keypair
fi
[[ -f "${KEY_PATH}" ]] || die "private key not found: ${KEY_PATH}"
[[ -f "${KEY_PATH}.pub" ]] || die "public key not found: ${KEY_PATH}.pub"

if [[ -n "${BOTWORK_SSH_PUBLIC_KEY:-}" ]]; then
  log_info "BOTWORK_SSH_PUBLIC_KEY is only used at deploy time and will be ignored during the build process."
fi
PUBLIC_KEY="$(<"${KEY_PATH}.pub")"

log_info "Building and staging dependencies/helpers …"
"${SCRIPT_DIR}/build-deps.sh"
ensure_images_loaded

SELECTED_ACCEL="$(pick_accelerator "${ACCELERATOR}")"
SERVICE="$(compose_service_for_accel "${SELECTED_ACCEL}")"
PACKER_ACCEL="$(packer_accelerator "${SELECTED_ACCEL}")"
COMPOSE_ARGS=(--project-directory "${REPO_ROOT}" -f "${REPO_ROOT}/compose.yaml")

REL_KEY_PATH="$(repo_relative_path "${KEY_PATH}")"
mkdir -p "${BUILD_DIR}"
[[ "${BUILD_DIR}" == "${REPO_ROOT}/build" ]] || die "will not delete non-standard build directory for safety: ${BUILD_DIR}"
rm -rf "${BUILD_DIR}/output"

HOST_KVM_GID_VALUE="${HOST_KVM_GID:-$(getent group kvm 2>/dev/null | cut -d: -f3 || true)}"
if [[ -z "${HOST_KVM_GID_VALUE}" ]]; then
  HOST_KVM_GID_VALUE="993"
fi

log_info "Running packer init/build in docker compose service: ${SERVICE}"
HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}" HOST_KVM_GID="${HOST_KVM_GID_VALUE}" \
  docker compose "${COMPOSE_ARGS[@]}" run --rm "${SERVICE}" packer init images/

HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}" HOST_KVM_GID="${HOST_KVM_GID_VALUE}" \
  docker compose "${COMPOSE_ARGS[@]}" run --rm "${SERVICE}" packer build \
    -var "accelerator=${PACKER_ACCEL}" \
    -var "ssh_private_key_file=${REL_KEY_PATH}" \
    -var "ssh_public_key=${PUBLIC_KEY}" \
    images/

if [[ "${NO_COMPRESS}" == "false" ]]; then
  SOURCE_IMAGE="$(discover_image "${BUILD_DIR}/output/debian-13-botspace.qcow2")"
  TARGET_IMAGE="${BUILD_DIR}/debian-13-botspace-compressed.qcow2"
  REL_SOURCE_IMAGE="$(repo_relative_path "${SOURCE_IMAGE}")"
  REL_TARGET_IMAGE="$(repo_relative_path "${TARGET_IMAGE}")"
  log_info "Compressing qcow2 image to ${TARGET_IMAGE}"
  HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}" HOST_KVM_GID="${HOST_KVM_GID_VALUE}" \
    docker compose "${COMPOSE_ARGS[@]}" run --rm "${SERVICE}" qemu-img convert -O qcow2 -c "${REL_SOURCE_IMAGE}" "${REL_TARGET_IMAGE}"
fi

log_info "Pack complete"
