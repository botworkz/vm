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
Usage: $0 [--compress|--no-compress] [--key <path>] [-h|--help]
  Default is --no-compress. botforge-backed packing requires KVM.
USAGE
}

NO_COMPRESS=true
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

log_info "Building and staging dependencies/helpers …"
"${SCRIPT_DIR}/build-deps.sh"
ensure_images_loaded

BOTFORGE_ARGS=(pack --repo-root "${REPO_ROOT}" --compose-service "tools-kvm" --key "${KEY_PATH}")
if [[ "${NO_COMPRESS}" == "false" ]]; then
  BOTFORGE_ARGS+=(--compress)
fi

log_info "Running botforge pack via $(botforge_image_ref) in docker compose service"
run_botforge_container --docker-sock --kvm -- "${BOTFORGE_ARGS[@]}"

log_info "Pack complete"
