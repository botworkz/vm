#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
# shellcheck source=scripts/lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"

usage() {
  cat <<USAGE
Usage: $0 [--image <path>] [--key <path>] [--keep-running] [image-name] [-h|--help]
USAGE
}

IMAGE_OVERRIDE=""
KEY_PATH="$(default_private_key_path)"
KEEP_RUNNING=false
IMAGE_NAME="botwork"
IMAGE_NAME_SET=false
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:-}"
      shift 2
      ;;
    --keep-running)
      KEEP_RUNNING=true
      shift
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

mkdir -p "${BUILD_DIR}"
manifest_has "${IMAGE_NAME}" || die "unknown image '${IMAGE_NAME}' (not found under images: in ${REPO_ROOT}/images/manifest.yaml)"
IMAGE_OUTPUT="$(manifest_output "${IMAGE_NAME}")"
IMAGE_PATH="$(discover_image "${IMAGE_OVERRIDE}" "${IMAGE_OUTPUT}")"
KEY_PATH="$(realpath -m "${KEY_PATH}")"
DEFAULT_KEY_PATH="$(realpath -m "$(default_private_key_path)")"
if [[ "${KEY_PATH}" == "${DEFAULT_KEY_PATH}" ]]; then
  ensure_default_keypair
fi
[[ -f "${KEY_PATH}" ]] || die "private key not found: ${KEY_PATH}"
[[ -f "${KEY_PATH}.pub" ]] || die "public key not found: ${KEY_PATH}.pub"

ensure_command curl
GOSS_VERSION="0.4.9"
GOSS_BIN="${BUILD_DIR}/goss-${GOSS_VERSION}"
if [[ ! -x "${GOSS_BIN}" ]]; then
  BASE="https://github.com/goss-org/goss/releases/download/v${GOSS_VERSION}"
  curl -fsSL -o "${GOSS_BIN}" "${BASE}/goss-linux-amd64"
  curl -fsSL -o "${GOSS_BIN}.sha256" "${BASE}/goss-linux-amd64.sha256"
  HASH="$(awk '{print $1}' "${GOSS_BIN}.sha256")"
  echo "${HASH}  ${GOSS_BIN}" | sha256sum -c - >/dev/null
  chmod +x "${GOSS_BIN}"
fi

if [[ "${IMAGE_NAME}" == "botwork" ]]; then
  log_info "Building dummy-auth-broker:test image for upload"
  docker build -q -t dummy-auth-broker:test \
    -f "${REPO_ROOT}/images/botwork/test/Dockerfile.dummy-auth-broker" \
    "${REPO_ROOT}/images/botwork/test/"
  docker save dummy-auth-broker:test -o "${BUILD_DIR}/dummy-auth-broker.tar"
fi

BOTFORGE_ARGS=(
  test
  --repo-root "${REPO_ROOT}"
  --test-config "${REPO_ROOT}/images/${IMAGE_NAME}/test/test-packed.yaml"
  --base-image "${IMAGE_PATH}"
  --ssh-key "${KEY_PATH}"
  --ssh-host "${SSH_HOST}"
  --ssh-port "${SSH_PORT}"
)
if [[ "${KEEP_RUNNING}" == "true" ]]; then
  BOTFORGE_ARGS+=(--keep-running)
fi

log_info "Running smoke test via botforge ($(botforge_image_ref))"
run_botforge_compose test -- "${BOTFORGE_ARGS[@]}"
