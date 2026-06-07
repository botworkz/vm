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
Usage: $0 [--compress|--no-compress] [--key <path>] [image-name] [-h|--help]
  Default is --no-compress. botforge-backed packing requires KVM.
USAGE
}

NO_COMPRESS=true
KEY_PATH="$(default_private_key_path)"
IMAGE_NAME="botwork"
IMAGE_NAME_SET=false
MANIFEST_PATH="${REPO_ROOT}/images/manifest.yaml"

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
    -*)
      die "unknown argument: $1"
      ;;
    *)
      if [[ "${IMAGE_NAME_SET}" == "true" ]]; then
        die "only one image-name positional argument is supported"
      fi
      IMAGE_NAME="$1"
      IMAGE_NAME_SET=true
      shift
      ;;
  esac
done

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  die "images manifest not found: ${MANIFEST_PATH}"
fi
if ! grep -Eq "^[[:space:]]{2}${IMAGE_NAME}:[[:space:]]*$" "${MANIFEST_PATH}"; then
  die "unknown image '${IMAGE_NAME}' (not found under images: in ${MANIFEST_PATH})"
fi

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

BOTFORGE_ARGS=(pack --repo-root "${REPO_ROOT}" --key "${KEY_PATH}")
if [[ "${NO_COMPRESS}" == "false" ]]; then
  BOTFORGE_ARGS+=(--compress)
fi

log_info "Running botforge pack via $(botforge_image_ref) in docker compose service"
run_botforge_compose pack -- "${BOTFORGE_ARGS[@]}"

log_info "Pack complete"
