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
# shellcheck source=scripts/lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"

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

manifest_has "${IMAGE_NAME}" || die "unknown image '${IMAGE_NAME}' (not found under images: in ${MANIFEST_PATH})"
IMAGE_TEMPLATE="images/${IMAGE_NAME}"
if [[ ! -d "${REPO_ROOT}/${IMAGE_TEMPLATE}" ]]; then
  die "image template directory not found: ${REPO_ROOT}/${IMAGE_TEMPLATE}"
fi

build_intermediate() {
  local name="$1"
  local out_name
  local staged
  local template
  local -a botforge_args

  out_name="$(manifest_output "${name}")"
  staged="${BUILD_DIR}/images/${name}.qcow2"
  template="images/${name}"

  if [[ -f "${staged}" ]]; then
    log_info "Reusing cached intermediate image: ${staged}"
    return 0
  fi
  [[ -d "${REPO_ROOT}/${template}" ]] || die "image template directory not found: ${REPO_ROOT}/${template}"

  log_info "Building intermediate image: ${name}"
  botforge_args=(pack --repo-root "${REPO_ROOT}" --key "${KEY_PATH}" --template "${template}")
  run_botforge_compose pack -- "${botforge_args[@]}"

  mkdir -p "${BUILD_DIR}/images"
  [[ -f "${BUILD_DIR}/output/${out_name}" ]] || die "expected intermediate output not found: ${BUILD_DIR}/output/${out_name}"
  mv "${BUILD_DIR}/output/${out_name}" "${staged}"
}

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

read -r -a CHAIN <<< "$(manifest_chain "${IMAGE_NAME}")"
TARGET="${IMAGE_NAME}"
for ancestor in "${CHAIN[@]}"; do
  [[ "${ancestor}" == "${TARGET}" ]] && break
  build_intermediate "${ancestor}"
done

BOTFORGE_ARGS=(pack --repo-root "${REPO_ROOT}" --key "${KEY_PATH}" --template "${IMAGE_TEMPLATE}")
if [[ "${NO_COMPRESS}" == "false" ]]; then
  BOTFORGE_ARGS+=(--compress)
fi

log_info "Running botforge pack via $(botforge_image_ref) in docker compose service (template: ${IMAGE_TEMPLATE})"
run_botforge_compose pack -- "${BOTFORGE_ARGS[@]}"

log_info "Pack complete"
